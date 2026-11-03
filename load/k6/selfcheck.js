// Offline check of flows.js helpers (no network):
//   docker run --rm -v "$PWD/load/k6:/s" grafana/k6:2.3.0 run --quiet /s/selfcheck.js   -> exit 0
import exec from 'k6/execution';
import { stepOf, abs, param, formOf, jwt, oauthError, appPick, appStepOf, logoutStepOf, iframesOf, hdr } from './flows.js';

export const options = { iterations: 1, vus: 1 };

const SPRING_LOGIN = `<html><body><form class="login-form" method="post" action="/login">
  <input type="text" id="username" name="username" autofocus><input type="password" id="password" name="password">
  <input name="_csrf" type="hidden" value="Zx9-tok" /><button type="submit">Sign in</button></form></body></html>`;
const KC_FORM = `<form id="kc-update-profile-form" action="https://kc-net2.localtest.me/keycloak/realms/demo/login-actions/first-broker-login?session_code=a&amp;tab_id=b" method="post">
  <input type="text" name="email" value="user4500@legacy.example"/><input type="submit" value="Submit"/></form>`;

const KC_FC_PAGE = `<html><body><p>Logging out</p>
  <iframe src="https://app.localtest.me/frontchannel-logout?iss=https%3A%2F%2Fkc-net1.localtest.me%2Fkeycloak%2Frealms%2Fdemo&amp;sid=s-1" style="display:none"></iframe>
  <iframe src="/keycloak/realms/demo/other" style="display:none"></iframe>
  <a id="continue" class="btn" href="https://app.localtest.me/">Continue</a></body></html>`;

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
    // app scenario
    [[0, 1, 2, 3, 4, 7].map((i) => appPick(i).reg).join(), 'bc-net1,bc-net2,fc-net1,fc-net2,bc-net1,fc-net2'],
    [[0, 3, 4, 7, 8, 12].map((i) => appPick(i).initiator).join(), 'app,app,kc,kc,app,kc'],
    // one VU's 8 consecutive iterations cover every registration x initiator once
    [new Set([5, 6, 7, 8, 9, 10, 11, 12].map((i) => `${appPick(i).reg}/${appPick(i).initiator}`)).size, 8],
    [appStepOf('GET', 'https://app.localtest.me/login/bc-net1'), 'app_login_start'],
    [appStepOf('GET', 'https://app.localtest.me/oauth2/authorization/bc-net1'), 'app_login_authorization'],
    [appStepOf('GET', 'https://app.localtest.me/login/oauth2/code/fc-net2?code=c&state=s'), 'app_login_callback'],
    [appStepOf('GET', 'https://app.localtest.me/'), 'app_login_other'],
    [appStepOf('GET', `${K}/protocol/openid-connect/auth?client_id=testclient-bc`), 'app_login_kc_auth'],
    [appStepOf('POST', `${L}/login`), 'app_login_legacy_post'],
    [logoutStepOf('https://app.localtest.me/logout'), 'app_logout_start'],
    [logoutStepOf('https://app.localtest.me/'), 'app_logout_done'],
    [logoutStepOf('https://app.localtest.me/login?logout'), 'app_logout_done'],
    [logoutStepOf(`${K}/protocol/openid-connect/logout?id_token_hint=x`), 'app_logout_kc'],
    [logoutStepOf(`${L}/connect/logout?id_token_hint=x`), 'app_logout_legacy'],
    [iframesOf(KC_FC_PAGE, `${K}/protocol/openid-connect/logout`).join(' '),
      `https://app.localtest.me/frontchannel-logout?iss=https%3A%2F%2Fkc-net1.localtest.me%2Fkeycloak%2Frealms%2Fdemo&sid=s-1 https://kc-net1.localtest.me/keycloak/realms/demo/other`],
    [iframesOf(SPRING_LOGIN, L).length, 0],
    [hdr({ headers: { 'X-Csrf-Token': 'tok' } }, 'X-CSRF-TOKEN'), 'tok'],
    [hdr({ headers: {} }, 'X-CSRF-TOKEN'), null],
  ];
  const bad = checks.map(([got, want], i) => [i, got, want]).filter(([, got, want]) => got !== want);
  bad.forEach(([i, got, want]) => console.error(`check ${i}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`));
  if (bad.length) exec.test.abort(`${bad.length} selfcheck(s) failed`);
  console.log(`selfcheck: ${checks.length} ok`);
}
