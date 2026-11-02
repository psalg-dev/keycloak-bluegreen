// Offline check of flows.js helpers (no network):
//   docker run --rm -v "$PWD/load/k6:/s" grafana/k6:2.3.0 run --quiet /s/selfcheck.js   -> exit 0
import exec from 'k6/execution';
import { stepOf, abs, param, formOf, jwt, oauthError } from './flows.js';

export const options = { iterations: 1, vus: 1 };

const SPRING_LOGIN = `<html><body><form class="login-form" method="post" action="/login">
  <input type="text" id="username" name="username" autofocus><input type="password" id="password" name="password">
  <input name="_csrf" type="hidden" value="Zx9-tok" /><button type="submit">Sign in</button></form></body></html>`;
const KC_FORM = `<form id="kc-update-profile-form" action="https://kc-net2.localtest.me/keycloak/realms/demo/login-actions/first-broker-login?session_code=a&amp;tab_id=b" method="post">
  <input type="text" name="email" value="user4500@legacy.example"/><input type="submit" value="Submit"/></form>`;

export default function () {
  const L = 'https://legacy-net1.localtest.me', K = 'https://kc-net1.localtest.me/keycloak/realms/demo';
  const checks = [
    [stepOf('GET', `${K}/protocol/openid-connect/auth?client_id=k6-app`), 'login_kc_auth'],
    [stepOf('GET', `${L}/oauth2/authorize?x=1`), 'login_legacy_authorize'],
    [stepOf('GET', `${L}/login`), 'login_legacy_form'],
    [stepOf('POST', `${L}/login`), 'login_legacy_post'],
    [stepOf('GET', `${K}/broker/legacy-net1/endpoint?code=c`), 'login_kc_broker'],
    [stepOf('GET', `${K}/login-actions/first-broker-login?x`), 'login_kc_first_broker'],
    [stepOf('GET', `${K}/login-actions/required-action?x`), 'login_kc_other'],
    [abs('/login', `${L}/oauth2/authorize?a=b`), `${L}/login`],
    [abs('https://x.example/a', L), 'https://x.example/a'],
    [abs('next?q=1', `${K}/login-actions/foo?x=1`), `${K}/login-actions/next?q=1`],
    [param('https://app.localtest.me/cb?state=s&code=a%2Fb&iss=x', 'code'), 'a/b'],
    [param('https://app.localtest.me/cb?error=x', 'code'), null],
    [JSON.stringify(formOf(SPRING_LOGIN, `${L}/login`)),
      JSON.stringify({ method: 'POST', action: `${L}/login`, fields: { username: '', password: '', _csrf: 'Zx9-tok' } })],
    [formOf(KC_FORM, K).action, `https://kc-net2.localtest.me/keycloak/realms/demo/login-actions/first-broker-login?session_code=a&tab_id=b`],
    [formOf(KC_FORM, K).fields.email, 'user4500@legacy.example'],
    [formOf('<p>We are sorry</p>', K), null],
    [jwt('h.eyJpc3MiOiJodHRwczovL2tjLW5ldDEiLCJsb2dpbl9jdHgiOiJ2MSJ9.s').login_ctx, 'v1'],
    [JSON.stringify(jwt('garbage')), '{}'],
    [oauthError({ status: 400, headers: { 'Content-Type': 'application/json' }, json: (k) => ({ error: 'invalid_grant' })[k] }), 'invalid_grant'],
    [oauthError({ status: 502, headers: { 'Content-Type': 'text/html' } }), null],
  ];
  const bad = checks.map(([got, want], i) => [i, got, want]).filter(([, got, want]) => got !== want);
  bad.forEach(([i, got, want]) => console.error(`check ${i}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  if (bad.length) exec.test.abort(`${bad.length} selfcheck(s) failed`);
  console.log(`selfcheck: ${checks.length} ok`);
}
