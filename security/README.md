# Security gate (Jenkins `kc-security`, `kc-kcwarden`)

`scripts/security/run.sh [probe...]` runs the probes (default: all) and writes `out/security/summary.txt` + `junit.xml`.
Each probe prints `PASS|WARN|FAIL <probe>: <evidence>`; any FAIL fails the build. Tool images: `tools.env`.
Probes only read, or clean up after themselves (throwaway realm `secprobe-*`, throwaway pods `secprobe-np-*`).

| Probe | Attacks | Why it matters here | Expected |
|---|---|---|---|
| issuer | Spoofed `X-Forwarded-Host/Proto/Port/Prefix`, `Forwarded`, `X-Original-Host`, `X-Forwarded-Server`, Host with port / upper case / trailing dot, via the ingress, on Keycloak (demo, master) and legacy IdP discovery; unknown Host | `hostname-strict=false`: the issuer follows the forwarded host; one issuer per host is the contract | issuer unchanged; non-canonical Host gets exactly 421 (edge `server-snippet`, `scripts/up.sh`); unknown host gets the ingress 404 |
| netpol | Unlabelled pod (ns keycloak), labelled pod (ns default) to `kc-active`, color Services, pod IPs :8080/:9000 | A direct connection can set `X-Forwarded-Host` itself = forge the issuer | blocked; labelled pod in ns keycloak gets through (documented trust boundary) |
| redirect | `redirect_uri` (other host, suffix, `.evil` suffix, userinfo `@`, backslash, traversal, scheme, port, wildcard) for `k6-app`; same for `post_logout_redirect_uri` | Open redirect = code/token theft, phishing | 400, never a redirect |
| dcr | Anonymous dynamic client registration (`openid-connect`, `default`), demo + master, with spoofed `X-Forwarded-For` | Anyone could register clients | 401/403 (Trusted Hosts policy). A created client is deleted at once and reported |
| admin | `/keycloak/admin` console + REST, `/keycloak/metrics`, `/keycloak/health` on both hosts | Admin surface reachable from wherever the hosts are | metrics/health 404. Admin public: **user decision**, `EXPECT_ADMIN_PUBLIC` (default `true` = WARN) |
| grants | Password grant, client_credentials, implicit (`token`, `id_token`) with `k6-app` | Only the code flow is intended; per-client flags of all clients are audited by kcwarden | refused; `k6-app` confidential |
| bruteforce | Realm config; bad logins for a non-existent user (master) and existing vs unknown user (throwaway realm) | Password spraying on master (temp-admin); user enumeration | brute-force protection on (master, demo); one uniform error; no timing gap (`BRUTEFORCE_TIMING_RATIO`, 3x). After the online stage master `admin-cli` has no direct grants, so the master attempts are expected to get `unauthorized_client` before any user lookup (uniform by construction; the enumeration check that matters is the throwaway realm) |
| tokens | net1 token at net2; `alg=none`; HS256 signed with the RS256 public key; refresh token after RP-initiated logout | Issuer binding between networks; JWT validation; logout must kill the session (the blue/green replay exists for this) | all rejected (401 / `invalid_grant`) |
| cookies | Flags of `AUTH_SESSION_ID`, `KC_RESTART`, `KEYCLOAK_IDENTITY`, `KEYCLOAK_SESSION`; CSP, X-Frame-Options, Referrer-Policy, nosniff, HSTS on login pages and the ingress | Session theft, clickjacking, downgrade | Secure + SameSite (+ HttpOnly except `KEYCLOAK_SESSION`); headers present. `EXPECT_HSTS` (default `true`) |
| tls | testssl.sh on both hosts | Edge TLS config | no TLS < 1.2, no weak ciphers, no finding >= `TLS_MIN_SEVERITY` (HIGH); accepted ids in `testssl-accept.txt` |
| nuclei | keycloak-tagged templates (CVEs, exposed panels/config, alg none) | Known Keycloak issues | nothing >= `NUCLEI_MIN_SEVERITY` (medium) |
| zap | ZAP baseline (passive) on demo account console + login page | Generic web hardening | no WARN/FAIL beyond `zap-rules.conf` (INFO entries are justified). WARN -> WARN, `ZAP_FAIL_ON_WARN=true` -> FAIL |
| trivy | Image of the active color + legacy IdP image | Vulnerable OS/Java packages | no fixable `TRIVY_SEVERITY` (HIGH,CRITICAL) |
| kcversion | Running Keycloak version vs OSV (`org.keycloak:keycloak-services`) | Keycloak's own CVEs | nothing >= `KC_CVE_MIN_SEVERITY` (HIGH); lower = WARN |

`scripts/security/kcwarden.sh` (job `kc-kcwarden`): kcwarden audit of realms master + demo, gate at `KCWARDEN_MIN_SEVERITY`
(HIGH). Accepted findings: `kcwarden-ignore.yaml`, one justification per entry.

Edge hardening the probes rely on (`scripts/up.sh` + `k8s/edge/ingress-nginx.yaml`, controller-wide): 421 for a Host that
is not the exact lower-case host; `Forwarded`, `X-Forwarded-Prefix/-Ssl/-Server`, `X-Original-Host`, `X-Host` stripped
before any backend; `Permissions-Policy` on every response.
