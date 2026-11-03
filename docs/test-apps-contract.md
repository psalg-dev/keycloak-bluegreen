# Contract: test client app, test resource server, k6, report

Shared by three parallel work items (apps, k6+gate, report). Change it only by agreement; everything below is
binding for names, paths, hosts, and log-line fields.

## Why
Measure what real relying parties see during a cutover, not only what k6 sees calling Keycloak directly:
token **introspection** failure rate, **back-channel** and **front-channel logout** delivery, token **refresh**
through a real OAuth2 client library, and browser login flows end to end.

## Hosts (ingress-nginx, demo CA, same patterns as the rest of the repo)
| Host | Backend | Namespace |
|---|---|---|
| `app.localtest.me` | `testclient` Service :80 -> pod :8080 | `apps` |
| `api.localtest.me` | `testresource` Service :80 -> pod :8080 | `apps` |

Keycloak back-channel calls go to the in-cluster Service URL (`http://testclient.apps.svc:8080/...`), not via the
ingress. Both apps run 1 replica (ponytail: in-memory sessions; they are instruments, not what is under test).
Both apps are Spring Boot 4.1.2, built as **GraalVM native images**, with a JVM fallback build arg for debugging.

## Keycloak clients (realm `demo`, config-cli online stage, `config/online/70-test-apps.json`)
| clientId | type | purpose | logout |
|---|---|---|---|
| `testclient-bc` | confidential, standard flow, PKCE S256 | browser login via the test client | back-channel: `http://testclient.apps.svc:8080/logout/connect/back-channel/{registrationId}` (Spring Security OIDC back-channel), `backchannel.logout.session.required=true` |
| `testclient-fc` | confidential, standard flow, PKCE S256 | same app, second registration | front-channel: `https://app.localtest.me/frontchannel-logout` (`frontchannelLogout: true`, `frontchannel.logout.url`) |
| `testresource` | confidential, service account only | introspection caller | none |

Redirect URIs: `https://app.localtest.me/login/oauth2/code/{registrationId}`; post-logout: `https://app.localtest.me/`.
Client secrets: Secret `test-apps` in ns `apps` AND ns `keycloak` (keys `testclient-bc`, `testclient-fc`, `testresource`),
generated once by `scripts/up.sh`, injected into config-cli via `$(env:...)`.
The `testclient-*` clients get the `tenant` optional scope and the `login_ctx` mapper, like `k6-app`.

## Test client (`testclient`) Spring registrations
Four registrations: `bc-net1`, `bc-net2` (client `testclient-bc`) and `fc-net1`, `fc-net2` (client `testclient-fc`).
Issuer per net: `https://kc-netN.localtest.me/keycloak/realms/demo`, each adding `kc_idp_hint=legacy-netN` to the
authorization request. Spring's `OAuth2AuthorizedClientManager` refreshes tokens transparently, so a refresh failure
(`invalid_grant`) shows up as a failed `/call/*`, re-authentication is NOT automatic, and the client logs it.

### Endpoints (all JSON unless noted)
| Method + path | Behaviour |
|---|---|
| `GET /login/{registrationId}` | starts login (redirect into Spring's `/oauth2/authorization/{registrationId}`) |
| `GET /me` | 200 `{sub, iss, sid, registration, login_ctx, tenant}` when logged in; 401 when not |
| `GET /call/jwt` | uses (refreshing if needed) the access token to call `https://api.localtest.me/api/jwt`; returns `{status, upstream_status, refreshed, error}` |
| `GET /call/introspect` | same, against `/api/introspect` |
| `POST /logout` (CSRF token from `/me` response header `X-CSRF-TOKEN`) | RP-initiated logout: redirect to Keycloak end_session (with `id_token_hint`, `post_logout_redirect_uri`) |
| `POST /logout/connect/back-channel/{registrationId}` | Spring Security back-channel logout endpoint (logout token from Keycloak) |
| `GET /frontchannel-logout?iss=..&sid=..` | invalidates the local session with that sid; returns 200 (plain) |
| `GET /actuator/health` | readiness |

### Test client log lines (stdout, one JSON object per line, field `app` always set)
```
{"app":"testclient","t":"<ISO-8601 ms UTC>","event":"login","registration":"bc-net1","sub":..,"sid":..,"iss":..}
{"app":"testclient","t":..,"event":"call","target":"jwt|introspect","status":200,"upstream_status":200,"refreshed":true|false,"latency_ms":12,"error":null|"invalid_grant"|"..","sid":..,"registration":..}
{"app":"testclient","t":..,"event":"refresh","registration":..,"sid":..,"ok":true|false,"error":null|"invalid_grant"|..,"latency_ms":..}
{"app":"testclient","t":..,"event":"backchannel_logout","registration":..,"sid":..,"sub":..,"iss":..,"ok":true|false,"error":null|".."}
{"app":"testclient","t":..,"event":"frontchannel_logout","sid":..,"iss":..,"found_session":true|false}
{"app":"testclient","t":..,"event":"logout_initiated","registration":..,"sid":..}
```

## Test resource server (`testresource`)
### Endpoints
| Path | Behaviour |
|---|---|
| `GET /api/jwt` | Bearer JWT, validated locally against JWKS of the token's issuer; trusted issuers exactly the two `kc-netN` ones (`JwtIssuerAuthenticationManagerResolver`). 200 `{sub, iss, tenant}` / 401 |
| `GET /api/introspect` | Bearer token, validated by calling Keycloak's introspection endpoint (`/protocol/openid-connect/token/introspect`) of the token's issuer as client `testresource`, EVERY request (no cache: we measure Keycloak). 200 `{active:true, sub, iss}` / 401 when inactive / 503 when introspection itself failed |
| `GET /actuator/health` | readiness |

### Log lines
```
{"app":"testresource","t":..,"event":"request","path":"/api/jwt|/api/introspect","status":200,"latency_ms":..,"iss":..,"sub":..,"error":null|".."}
{"app":"testresource","t":..,"event":"introspection","issuer":..,"http_status":200|5xx|0,"active":true|false|null,"latency_ms":..,"error":null|"timeout"|"connect"|"5xx"|".."}
```

## k6 (new scenario `app`, in addition to the existing ones)
Each VU: pick net1|net2 and bc|fc, browse `https://app.localtest.me/login/{bc|fc}-netN` through the whole redirect
chain (Keycloak -> legacy IdP form -> back), then `/me`, then every 5 s alternate `/call/jwt` and `/call/introspect`
for a random 30-120 s, then `POST /logout` following the chain like a browser. For `fc` sessions, k6 fetches every
`<iframe src>` on Keycloak's logout page (the front-channel URLs) like a browser would. Then `/me` must be 401.
k6 line schema: the existing one (top of `load/k6/flows.js`) with `scenario:"app"` and steps
`app_login_*`, `app_me`, `app_call_jwt`, `app_call_introspect`, `app_logout_*`, `app_frontchannel`, `app_me_after_logout`.
Collection: `load.sh collect` also writes the two apps' stdout JSON lines to `out/apps.jsonl`
(`kubectl logs` with `--since-time` of the load start).

## Failure modes the report must quantify (ids are stable, used by gate + report + docs/failure-modes.md)
| id | definition | source |
|---|---|---|
| `http_5xx` | any response >= 500 (Keycloak, IdP, apps) | k6 |
| `net_error` | status 0 not caused by the k6 stop | k6 |
| `login_failed` | a login (direct or via app) that does not end with tokens / an app session | k6 |
| `inflight_login_broken` | a login whose hops straddle a flip and that fails | k6 + events |
| `refresh_lost_session` | refresh -> `invalid_grant` (direct or via the app's client manager) | k6, testclient |
| `refresh_other_error` | refresh fails for any other reason | k6, testclient |
| `introspection_error` | introspection call failed (5xx/timeout/connect) | testresource |
| `introspection_false_inactive` | introspection says inactive for a token whose session is alive (not logged out) | testresource + k6 |
| `jwt_rejected` | resource server rejects a JWT from a live session (signature/issuer) | testresource |
| `issuer_mismatch` | token `iss` not the one of its network | k6 |
| `sub_changed` | same user, different `sub` | k6 |
| `logout_not_effective` | refresh/introspection still OK after logout completed | k6 + testresource |
| `backchannel_missing` | RP-initiated logout of a `bc` session without a matching back-channel logout at the app within 10 s | k6 + testclient |
| `backchannel_late` | delivered, but > 2 s after the logout | k6 + testclient |
| `frontchannel_failed` | an `fc` logout whose front-channel URL was missing from the page or did not end the app session | k6 + testclient |
| `latency_regression` | p95 latency of a step in the cutover window > 2x its pre-switch baseline | k6 |

Every mode is reported per scenario as count, rate (per relevant attempts), and time distribution relative to the
case's events (switch, copy_point, promoted, replay_done, rollback ...).
