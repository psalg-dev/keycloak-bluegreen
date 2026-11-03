# Test apps: testclient + testresource

Instruments for the cutover demos: what a real OIDC relying party and a resource server see while Keycloak switches.
Binding names, endpoints and log lines: [test-apps-contract.md](test-apps-contract.md). This page covers how to use
them and the decisions the contract left open.

| App | Source | Image | URL |
|---|---|---|---|
| `testclient` (Spring Security OAuth2 client) | `testclient/` | `images/testclient/Dockerfile` | `https://app.localtest.me` |
| `testresource` (Spring Security resource server) | `testresource/` | `images/testresource/Dockerfile` | `https://api.localtest.me` |

Both: Spring Boot 4.1.2, Java 25, GraalVM native images (distroless), 1 replica in ns `apps`.

## Bring-up
`scripts/up.sh` does everything (idempotent): ns `apps`, Secrets `demo-ca` + `localtest-tls` (`scripts/certs.sh`),
Secret `test-apps` (generated once, copied to ns `keycloak` for config-cli), image builds (tests run inside the build),
`kind load`, `k8s/apps/test-apps.yaml.tpl`, rollout wait. The Keycloak clients come from
`config/online/70-test-apps.json` (`scripts/config.sh online <color>`).

**`config.sh` needs Secret `test-apps` in ns `keycloak`.** On a cluster brought up before the test apps existed, run
`scripts/up.sh` once (it creates the Secret before any config stage); otherwise the config-cli pod cannot start.

Debug build on the JVM instead of native: `docker build --build-arg MODE=jvm -f images/testclient/Dockerfile testclient`.

## Using testclient
```
GET  /login/bc-net1 | bc-net2 | fc-net1 | fc-net2   -> Keycloak (kc_idp_hint=legacy-netN) -> legacy IdP -> back
GET  /me                                            -> {sub, iss, sid, registration, login_ctx, tenant} + header X-CSRF-TOKEN
GET  /call/jwt, /call/introspect                    -> {status, upstream_status, refreshed, error}
POST /logout  (header X-CSRF-TOKEN)                 -> Keycloak end_session (id_token_hint, post_logout_redirect_uri)
```
`/call/*` status: the resource server's status when the call was made; `401` when no access token could be obtained
(`error`: `invalid_grant` = the refresh token's session is gone on Keycloak; afterwards `client_authorization_required`,
re-authentication is not automatic); `502` + `upstream_status: 0` when the resource server was unreachable.

Logs: `kubectl -n apps logs deploy/testclient | grep '^{"app"'` (one JSON object per line, schema in the contract).

## Decisions the contract left open
- **One back-channel URL, two registrations.** `testclient-bc` is one Keycloak client but two Spring registrations
  (`bc-net1`, `bc-net2`) whose issuers differ; Spring checks the logout token's `iss` against the registration named in
  the path. Keycloak therefore calls the alias `http://testclient.apps.svc:8080/logout/connect/back-channel/bc`;
  `BackChannelLogoutFilter` reads the token's `iss` (unverified) to pick `bc-netN`, then Spring's own endpoint verifies
  it as usual. `/logout/connect/back-channel/bc-net1|bc-net2` work directly too.
- **Refreshes must happen inside a 30-120 s k6 session.** `testclient-*` get `access.token.lifespan` 60 s and the
  client manager refreshes 30 s before expiry, so a session refreshes about every 30 s, and a token reaching the
  resource server has at least 30 s left (introspection never sees an expired token from a live session).
- **TLS trust.** SSL bundle `demo-ca` (`/etc/demo-ca/ca.crt` from Secret `demo-ca`). testresource and testclient's
  `/call/*` client use it explicitly. Spring Security builds some testclient HTTP clients internally (the back-channel
  logout-token JWKS decoder cannot be configured), so testclient also installs the bundle as the JVM default SSLContext.
- **Introspection** is called from the `/api/introspect` controller, not Spring's opaque-token filter: Spring turns an
  introspection failure into 500, the contract wants 503 (failure) vs 401 (inactive). Only the two trusted issuers'
  endpoints are ever called; any other `iss` is 401 `untrusted_issuer` without a call.
- Service `testclient` listens on 80 (ingress) and 8080 (Keycloak's back-channel URL in the contract).
