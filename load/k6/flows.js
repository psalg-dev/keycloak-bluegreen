// flows.js: load for the Keycloak blue-green demo (PLAN.md Slice 4). Run: k6 run --log-format=raw flows.js
//
// Every request logs ONE JSON line via console.log. scripts/gate.sh reads exactly these fields:
//   t_start, t_end  ISO-8601 UTC with ms (same format as `t` in out/events.jsonl)
//   scenario        login | refresh | relogin (silent re-login of a refresh session after invalid_grant) | logout | reads
//   step            login hops:  login_kc_auth, login_legacy_authorize, login_legacy_form, login_legacy_post,
//                                login_kc_broker, login_kc_first_broker, login_kc_other, login_legacy_other, login_token
//                   others:      refresh, logout, logout_probe, discovery, jwks
//   status          HTTP status, 0 = network error
//   error           OAuth `error` of a token-endpoint response (e.g. "invalid_grant"), else null
//   login_id        id of a login; on refresh/logout/logout_probe lines, the login that minted the token used
//   user, net       userNNNN (null on reads), net1|net2
//   sub, iss        from the access token on token lines (iss also = discovery `issuer`), else null
//   claims          {login_ctx, tenant} from the access token, else nulls
// Scenario `app` (browser through the test client app, docs/test-apps-contract.md) uses the same fields; its steps:
//   app_login_start|_authorization|_callback|_other (app hops), app_login_<hop above without login_> (KC/IdP hops),
//   app_me, app_call_jwt, app_call_introspect, app_logout_start|_kc|_legacy|_done, app_frontchannel, app_me_after_logout
//   and adds (app lines only): registration (bc-net1 ...), sid (from /me, null before it),
//   upstream_status (calls: the resource server's status from the app's JSON); `error` on calls = the app's JSON error,
//   initiator (logout lines app_logout_*, app_frontchannel, app_me_after_logout): app = POST /logout at the app (Spring
//   ends its session first, then Keycloak), kc = the browser goes to Keycloak's end_session directly, like a logout in
//   another app or the account console, so only the back-/front-channel call can end the app session.
//   app_logout_start = the first logout request (app: POST /logout, kc: GET end_session).
//   sub, iss, claims on app_me lines come from the /me response.
// Env: K6_APP_SECRET, LEGACY_USER_PASSWORD (required); LOGIN_RATE (5/s), REFRESH_VUS (10), LOGOUT_VUS (4), APP_VUS (6,
// 0 = no app scenario), DURATION (60m, a cap: load.sh stop ends the run).
import http from 'k6/http';
import { sleep } from 'k6';
import exec from 'k6/execution';
import { parseHTML } from 'k6/html';
import encoding from 'k6/encoding';
// A browser's Accept: text/html first (Spring and the legacy IdP redirect to their login page only for HTML clients),
// */* last. A bare 'text/html' got 406 from the test client's text/plain pages (/, /frontchannel-logout); browsers don't.
const HTML = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

const SECRET = __ENV.K6_APP_SECRET;
const PASSWORD = __ENV.LEGACY_USER_PASSWORD;
const LOGIN_RATE = Number(__ENV.LOGIN_RATE || 5);
const DURATION = __ENV.DURATION || '60m';
const REDIRECT = 'https://app.localtest.me/cb';
const PROBE_EVERY = 5; // s, refresh + logout_probe period
const LOGOUT_EVERY = 30; // s of probing between logouts: one logout per VU every ~45 s (login + think + 30 s)
// Refresh VUs: odd ones keep ONE session for the whole run (the "born before switch / copy point" rules need long-lived
// sessions); even ones start a fresh session every ROTATE_SECONDS, so sessions are also born on the new color (the
// rollback rules judge those). With all-long-lived sessions a rollback gate had 0 green-born sessions to look at.
const ROTATE_SECONDS = Number(__ENV.ROTATE_SECONDS || 60);
const APP = 'https://app.localtest.me';
const APP_VUS = Number(__ENV.APP_VUS || 6);

export const options = {
  scenarios: {
    // up to ~21 s per login (think time), so VUs ~ rate x 25
    login: { executor: 'constant-arrival-rate', exec: 'login', rate: LOGIN_RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: LOGIN_RATE * 25, maxVUs: LOGIN_RATE * 50 },
    refresh: { executor: 'constant-vus', exec: 'refresh', vus: Number(__ENV.REFRESH_VUS || 10), duration: DURATION },
    logout: { executor: 'constant-vus', exec: 'logout', vus: Number(__ENV.LOGOUT_VUS || 4), duration: DURATION },
    reads: { executor: 'constant-arrival-rate', exec: 'reads', rate: 1, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: 2, maxVUs: 5 },
  },
};
if (APP_VUS > 0) options.scenarios.app = { executor: 'constant-vus', exec: 'app', vus: APP_VUS, duration: DURATION };

export function setup() {
  if (!SECRET || !PASSWORD) exec.test.abort('K6_APP_SECRET and LEGACY_USER_PASSWORD must be set');
}

// per-VU state (module scope is per VU)
let seq = 0;
let held = null; // refresh scenario: this VU's session for the whole run
const probes = []; // logout scenario: logged-out sessions, probed until the end

const rand = (n) => Math.floor(Math.random() * n);
const now = () => new Date().toISOString();
const kc = (net) => `https://kc-${net}.localtest.me/keycloak/realms/demo`;
const qs = (o) => Object.keys(o).map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(o[k])}`).join('&');
const safe = (f) => { try { return f(); } catch (e) { return null; } };

// A browser: one user + one network + its own cookie jar. 80% linked users 1-4000, 20% new 4001-5000.
function newSession() {
  const n = Math.random() < 0.8 ? 1 + rand(4000) : 4001 + rand(1000);
  return { user: `user${String(n).padStart(4, '0')}`, net: Math.random() < 0.5 ? 'net1' : 'net2',
    jar: new http.CookieJar(), login_id: null, rt: null, idt: null, lost: false };
}

// x: extra fields (override); app sessions (s.reg set) always add registration + sid
function log(s, scenario, step, t0, res, c, x) {
  console.log(JSON.stringify(Object.assign({ t_start: t0, t_end: now(), scenario, step, status: res.status, error: oauthError(res),
    login_id: s.login_id || null, user: s.user || null, net: s.net, sub: c.sub || null, iss: c.iss || null,
    claims: { login_ctx: c.login_ctx || null, tenant: c.tenant || null } },
  s.reg ? Object.assign({ registration: s.reg, sid: s.sid || null }, s.initiator ? { initiator: s.initiator } : {}) : {}, x)));
}

export function oauthError(res) {
  if (res.status < 400 || !String(res.headers['Content-Type'] || '').includes('json')) return null;
  return safe(() => res.json('error')) || null;
}

export function jwt(t) {
  return safe(() => JSON.parse(encoding.b64decode(t.split('.')[1], 'rawurl', 's'))) || {};
}

function claimsOf(body) {
  const at = jwt(body.access_token || ''), id = jwt(body.id_token || '');
  return { sub: at.sub || id.sub, iss: at.iss, login_ctx: at.login_ctx, tenant: at.tenant };
}

export function stepOf(method, url) {
  const m = url.match(/^https?:\/\/([^/]+)([^?#]*)/) || [];
  const host = m[1] || '', path = m[2] || '';
  if (host.startsWith('legacy-')) {
    if (path === '/oauth2/authorize') return 'login_legacy_authorize';
    if (path === '/login') return method === 'POST' ? 'login_legacy_post' : 'login_legacy_form';
    return 'login_legacy_other';
  }
  if (path.endsWith('/protocol/openid-connect/auth')) return 'login_kc_auth';
  if (/\/broker\/[^/]+\/endpoint$/.test(path)) return 'login_kc_broker';
  if (path.includes('first-broker-login')) return 'login_kc_first_broker';
  return 'login_kc_other';
}

export function abs(loc, base) {
  if (/^https?:\/\//.test(loc)) return loc;
  if (loc.startsWith('/')) return base.match(/^https?:\/\/[^/]+/)[0] + loc;
  return base.replace(/[^/]*([?#].*)?$/, '') + loc;
}

export function param(url, name) {
  const m = url.match(new RegExp(`[?&#]${name}=([^&#]*)`));
  return m ? decodeURIComponent(m[1]) : null;
}

// first <form> of a page -> {method, action, fields} with every input as-is, or null
export function formOf(html, url) {
  const form = parseHTML(html).find('form').first();
  if (form.size() === 0) return null;
  const fields = {};
  form.find('input').toArray().forEach((el) => { if (el.attr('name')) fields[el.attr('name')] = el.attr('value') || ''; });
  return { method: (form.attr('method') || 'POST').toUpperCase(), action: abs(form.attr('action') || url, url), fields };
}

function token(s, scenario, step, form) {
  const t0 = now();
  const res = http.post(`${kc(s.net)}/protocol/openid-connect/token`,
    Object.assign({ client_id: 'k6-app', client_secret: SECRET }, form), { redirects: 0, tags: { name: step } });
  const body = (res.status === 200 && safe(() => res.json())) || {};
  log(s, scenario, step, t0, res, res.status === 200 ? claimsOf(body) : {});
  return { status: res.status, error: oauthError(res), body };
}

// Walk a browser login from url: manual redirects, forms submitted as-is, the legacy password form filled after think
// time. One logged line per hop, named stepFn(method, url). Returns the redirect Location for which done(loc, url) holds
// (url = the request that answered it), or null on an error status / dead end.
function hops(s, scenario, url, stepFn, done) {
  let method = 'GET', body = null;
  for (let hop = 0; hop < 14; hop++) {
    const step = stepFn(method, url), t0 = now();
    // Accept: text/html, or Spring answers 401 instead of redirecting to /login
    const res = http.request(method, url, body, { redirects: 0, jar: s.jar, headers: { Accept: HTML }, tags: { name: step } });
    log(s, scenario, step, t0, res, {});
    if (res.status === 0 || res.status >= 400) return null;
    if (res.status >= 300) {
      const loc = abs(res.headers.Location || '', url);
      if (done(loc, url)) return loc;
      method = 'GET'; url = loc; body = null;
      continue;
    }
    // 200: Spring's login form, or a first-broker-login / review-profile form -> submit it as-is
    const f = formOf(res.body, url);
    if (!f) return null; // dead end (error page)
    if ('password' in f.fields) {
      if (!step.endsWith('login_legacy_form') || url.includes('error')) return null; // KC's own login form, or wrong password
      sleep(Math.random() * 20); // think time 0-20 s
      f.fields.username = s.user; f.fields.password = PASSWORD;
    }
    method = f.method; url = f.action; body = f.fields;
  }
  return null;
}

// Brokered auth-code flow for k6-app, then the code exchange. Returns true when s holds fresh tokens.
function doLogin(s, scenario) {
  s.login_id = `${exec.vu.idInTest}-${++seq}`;
  s.rt = null;
  const q = { client_id: 'k6-app', response_type: 'code', scope: 'openid tenant', redirect_uri: REDIRECT,
    state: `${s.login_id}-${rand(1e9)}`, nonce: String(rand(1e9)), kc_idp_hint: `legacy-${s.net}` };
  const loc = hops(s, scenario, `${kc(s.net)}/protocol/openid-connect/auth?${qs(q)}`, stepOf, (l) => l.startsWith(REDIRECT));
  const code = loc && param(loc, 'code');
  const t = code ? token(s, scenario, 'login_token', { grant_type: 'authorization_code', code, redirect_uri: REDIRECT }) : null;
  if (!t || t.status !== 200) return false;
  s.rt = t.body.refresh_token; s.idt = t.body.id_token;
  return true;
}

export function login() {
  doLogin(newSession(), 'login');
}

// Hold a session, refresh every 5 s; invalid_grant -> silent re-login (same jar = legacy SSO).
// Even VUs rotate to a brand-new session every ROTATE_SECONDS (see above).
export function refresh() {
  if (held && exec.vu.idInTest % 2 === 0 && Date.now() - held.since > ROTATE_SECONDS * 1000) held = null;
  if (!held) { held = newSession(); held.since = Date.now(); }
  if (!held.rt && !doLogin(held, held.lost ? 'relogin' : 'refresh')) { sleep(PROBE_EVERY); return; }
  sleep(PROBE_EVERY);
  const t = token(held, 'refresh', 'refresh', { grant_type: 'refresh_token', refresh_token: held.rt });
  if (t.status === 200) held.rt = t.body.refresh_token || held.rt;
  else if (t.error === 'invalid_grant') { held.lost = true; doLogin(held, 'relogin'); }
}

// Log in, RP-initiated logout with id_token_hint, then keep probing every logged-out refresh token until the end.
export function logout() {
  const s = newSession();
  if (doLogin(s, 'logout')) {
    sleep(1 + Math.random() * 2);
    let method = 'GET', url = `${kc(s.net)}/protocol/openid-connect/logout?${qs({ id_token_hint: s.idt, client_id: 'k6-app' })}`, body = null;
    // Brokered logout is a browser round trip: Keycloak redirects to the legacy IdP's logout, which redirects back to
    // Keycloak's broker logout_response; only then is the Keycloak session gone. Follow redirects like a browser and
    // submit a logout-confirm form as-is if one is shown. (Stopping at the first 302 left the session alive.)
    for (let i = 0; i < 8; i++) {
      const t0 = now();
      const res = http.request(method, url, body, { redirects: 0, jar: s.jar, headers: { Accept: HTML }, tags: { name: 'logout' } });
      log(s, 'logout', 'logout', t0, res, {});
      if (res.status >= 300 && res.status < 400 && res.headers.Location) {
        method = 'GET'; url = abs(res.headers.Location, url); body = null;
        continue;
      }
      const f = res.status === 200 ? formOf(res.body, url) : null;
      if (!f) break;
      method = f.method; url = f.action; body = f.fields;
    }
    probes.push(s);
  }
  const end = Date.now() + LOGOUT_EVERY * 1000;
  while (Date.now() < end) {
    sleep(PROBE_EVERY);
    // ponytail: probes grow ~2/min per VU; cap them if a run gets much longer than 10 min
    probes.forEach((p) => token(p, 'logout', 'logout_probe', { grant_type: 'refresh_token', refresh_token: p.rt }));
  }
}

export function reads() {
  ['net1', 'net2'].forEach((net) => {
    let t0 = now();
    let res = http.get(`${kc(net)}/.well-known/openid-configuration`, { tags: { name: 'discovery' } });
    log({ net }, 'reads', 'discovery', t0, res, { iss: res.status === 200 ? safe(() => res.json('issuer')) : null });
    t0 = now();
    res = http.get(`${kc(net)}/protocol/openid-connect/certs`, { tags: { name: 'jwks' } });
    log({ net }, 'reads', 'jwks', t0, res, {});
  });
}

// ---- scenario `app`: a browser using the test client app (docs/test-apps-contract.md)

// which registration + logout initiator: (VU id + iteration) % 8 -> net1/net2 x bc/fc x app/kc, so the split stays
// even whatever VU ids k6 assigns
export function appPick(i) {
  const net = i % 2 ? 'net2' : 'net1';
  return { net, reg: `${Math.floor(i / 2) % 2 ? 'fc' : 'bc'}-${net}`, initiator: Math.floor(i / 4) % 2 ? 'kc' : 'app' };
}

export function appStepOf(method, url) {
  if (!url.startsWith(`${APP}/`)) return `app_${stepOf(method, url)}`;
  const path = url.slice(APP.length).replace(/[?#].*$/, '');
  if (path.startsWith('/login/oauth2/code/')) return 'app_login_callback';
  if (path.startsWith('/oauth2/authorization/')) return 'app_login_authorization';
  if (path.startsWith('/login/')) return 'app_login_start';
  return 'app_login_other';
}

export function logoutStepOf(url) {
  if (url.startsWith(`${APP}/`)) return /^[^?#]*\/logout([?#]|$)/.test(url.slice(APP.length)) ? 'app_logout_start' : 'app_logout_done';
  return /^https?:\/\/legacy-/.test(url) ? 'app_logout_legacy' : 'app_logout_kc';
}

export function iframesOf(html, url) {
  return parseHTML(html).find('iframe').toArray().map((el) => el.attr('src')).filter((x) => x).map((x) => abs(x, url));
}

export function hdr(res, name) { // k6 canonicalizes header names (X-Csrf-Token); match case-insensitively
  const k = Object.keys(res.headers || {}).find((h) => h.toLowerCase() === name.toLowerCase());
  return k ? res.headers[k] : null;
}

// GET an app JSON endpoint. Accept: application/json, so an anonymous request gets the contract's 401, not a login redirect.
function appGet(s, step, path) {
  const t0 = now();
  const res = http.get(APP + path, { redirects: 0, jar: s.jar, headers: { Accept: 'application/json' }, tags: { name: step } });
  return { t0, res, b: safe(() => res.json()) || {} };
}

export function app() {
  const pick = appPick(exec.vu.idInTest + exec.vu.iterationInScenario);
  const s = Object.assign(newSession(), { net: pick.net, reg: pick.reg });
  s.login_id = `${exec.vu.idInTest}-${++seq}`;
  // login: app -> Spring /oauth2/authorization -> Keycloak -> legacy IdP form -> Keycloak -> app callback (code
  // exchange happens in the app); stop after the callback's redirect
  hops(s, 'app', `${APP}/login/${s.reg}`, appStepOf, (loc, url) => appStepOf('GET', url) === 'app_login_callback');
  let r = appGet(s, 'app_me', '/me');
  if (r.res.status === 200) { s.sid = r.b.sid; s.csrf = hdr(r.res, 'X-CSRF-TOKEN'); }
  log(s, 'app', 'app_me', r.t0, r.res, r.b);
  if (r.res.status !== 200) { sleep(PROBE_EVERY); return; } // login failed (gate: app_login_ok)

  const end = Date.now() + (30 + Math.random() * 90) * 1000;
  for (let n = 0; Date.now() < end; n++) {
    sleep(PROBE_EVERY);
    const target = n % 2 ? 'introspect' : 'jwt';
    r = appGet(s, `app_call_${target}`, `/call/${target}`);
    log(s, 'app', `app_call_${target}`, r.t0, r.res, {}, { upstream_status: r.b.upstream_status ?? null, error: r.b.error || null });
  }

  // Logout like a browser. initiator app: POST /logout (CSRF header) -> Keycloak end_session -> legacy IdP logout ->
  // Keycloak -> post_logout_redirect_uri on the app. initiator kc: GET Keycloak end_session with the browser's Keycloak
  // cookies only (no id_token_hint, so Keycloak shows its logout-confirm form, submitted as-is) while the app still holds
  // its session; ends on Keycloak's "logged out" page. On a page: load every <iframe> (front-channel logout URLs),
  // submit a form (logout confirm) or follow #continue (what the front-channel page's script does).
  s.initiator = pick.initiator;
  const kcInit = s.initiator === 'kc';
  let method = kcInit ? 'GET' : 'POST', url = kcInit ? `${kc(s.net)}/protocol/openid-connect/logout` : `${APP}/logout`;
  let headers = kcInit ? { Accept: HTML } : { Accept: HTML, 'X-CSRF-TOKEN': s.csrf || '' }, body = null;
  for (let i = 0; i < 10; i++) {
    const step = i === 0 ? 'app_logout_start' : logoutStepOf(url), t0 = now();
    const res = http.request(method, url, body, { redirects: 0, jar: s.jar, headers, tags: { name: step } });
    log(s, 'app', step, t0, res, {});
    headers = { Accept: HTML };
    if (step === 'app_logout_done') break; // back on the app: logout chain complete
    if (res.status >= 300 && res.status < 400 && res.headers.Location) {
      method = 'GET'; url = abs(res.headers.Location, url); body = null;
      continue;
    }
    if (res.status !== 200) break;
    iframesOf(res.body, url).forEach((src) => {
      const f0 = now();
      log(s, 'app', 'app_frontchannel', f0, http.get(src, { redirects: 0, jar: s.jar, headers: { Accept: HTML }, tags: { name: 'app_frontchannel' } }), {});
    });
    const f = formOf(res.body, url);
    const next = f ? null : parseHTML(res.body).find('#continue').attr('href');
    if (f) { method = f.method; url = f.action; body = f.fields; } else if (next) { method = 'GET'; url = abs(next, url); body = null; } else break;
  }
  r = appGet(s, 'app_me_after_logout', '/me');
  log(s, 'app', 'app_me_after_logout', r.t0, r.res, {});
  sleep(1);
}
