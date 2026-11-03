// live/demo.mjs: the browser live demo. Every few seconds it runs one real user journey against the running demo -
// brokered login through the legacy IdP (authorization code + PKCE), a JWT-validated API call, a server-side
// introspection at the resource server, a refresh, and a logout that must end the session - and streams the results
// to http://127.0.0.1:8098/ so an audience watches continuity while someone flips the active color.
//
// No dependencies: Node >= 18 (global fetch), run through scripts/live-demo.sh, which supplies the client secret,
// the legacy user password and the demo CA.
import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';

const KC = (net) => `https://kc-${net}.localtest.me/keycloak/realms/demo`;
const CB = (net) => `https://app.localtest.me/login/oauth2/code/bc-${net}`;
const API = 'https://api.localtest.me';
const CLIENT = process.env.LIVE_CLIENT || 'testclient-bc';
const SECRET = process.env.TESTCLIENT_BC_SECRET || '';
const USER = process.env.DEMO_USER || 'user0042';
const PASSWORD = process.env.LEGACY_USER_PASSWORD || '';
const INTERVAL = Number(process.env.INTERVAL_MS || 2500);
const PORT = Number(process.env.PORT || 8098);
const KEEP = 60;

if (!SECRET || !PASSWORD) {
  console.error('live demo: TESTCLIENT_BC_SECRET and LEGACY_USER_PASSWORD must be set (use scripts/live-demo.sh)');
  process.exit(2);
}

class Jar {
  constructor() { this.m = new Map(); }
  add(res) {
    for (const c of res.headers.getSetCookie?.() || []) {
      const kv = c.split(';')[0], i = kv.indexOf('=');
      if (i > 0) this.m.set(kv.slice(0, i), kv.slice(i + 1));
    }
  }
  get header() { return [...this.m].map(([k, v]) => `${k}=${v}`).join('; '); }
}

async function hop(url, init, jar, stop = () => false) {
  let u = url, cur = init;
  for (let i = 0; i < 15; i++) {
    const headers = { accept: 'text/html', ...(cur.headers || {}) };
    if (jar.header) headers.cookie = jar.header;
    const res = await fetch(u, { ...cur, redirect: 'manual', headers });
    jar.add(res);
    const loc = res.headers.get('location');
    if (res.status >= 300 && res.status < 400 && loc) {
      const next = new URL(loc, u).toString();
      if (stop(next)) return { res, url: next, body: '' };
      u = next;
      cur = {}; // a redirect is always followed with a GET, as a browser does
      continue;
    }
    return { res, url: u, body: await res.text() };
  }
  throw new Error('too many redirects');
}

const form = (o) => new URLSearchParams(o).toString();
const basic = Buffer.from(`${CLIENT}:${SECRET}`).toString('base64');

async function login(net) {
  const verifier = crypto.randomBytes(32).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  const jar = new Jar();
  const cb = CB(net);
  const auth = `${KC(net)}/protocol/openid-connect/auth?client_id=${CLIENT}&response_type=code&scope=openid%20tenant`
    + `&state=${crypto.randomBytes(8).toString('hex')}&kc_idp_hint=legacy-${net}`
    + `&redirect_uri=${encodeURIComponent(cb)}&code_challenge=${challenge}&code_challenge_method=S256`;

  const first = await hop(auth, {}, jar);
  const csrf = /name="_csrf"[^>]*?value="([^"]+)"/.exec(first.body)?.[1];
  if (!csrf) throw new Error(`no legacy login form (stopped at ${first.url})`);

  const posted = await hop(first.url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: form({ username: USER, password: PASSWORD, _csrf: csrf }),
  }, jar, (u) => u.startsWith(cb));
  if (!posted.url.startsWith(cb)) throw new Error(`login stopped at ${posted.url}`);
  const code = new URL(posted.url).searchParams.get('code');
  if (!code) throw new Error('callback without code');

  const res = await fetch(`${KC(net)}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { authorization: `Basic ${basic}`, 'content-type': 'application/x-www-form-urlencoded' },
    body: form({ grant_type: 'authorization_code', code, redirect_uri: cb, code_verifier: verifier }),
  });
  const tok = await res.json();
  if (!res.ok) throw new Error(`token ${res.status} ${tok.error || ''}`);
  return { net, jar, tok };
}

const bearer = (t) => ({ authorization: `Bearer ${t}` });
const ms = (t0) => Math.round((Number(process.hrtime.bigint()) - t0) / 1e5) / 10;

async function step(name, fn, out) {
  const t0 = Number(process.hrtime.bigint());
  try {
    const v = await fn();
    out[name] = { ok: true, ms: ms(t0) };
    return v;
  } catch (e) {
    out[name] = { ok: false, ms: ms(t0), error: String(e.message || e) };
    throw e;
  }
}

async function cycle() {
  const c = { at: new Date().toISOString(), steps: {} };
  const net = c.net = Math.random() < 0.5 ? 'net1' : 'net2';
  try {
    const { jar, tok } = await step('login', () => login(net), c.steps);
    c.sub = (() => { try { return JSON.parse(Buffer.from(tok.id_token.split('.')[1], 'base64url')).sub; } catch { return null; } })();
    c.iss = (() => { try { return JSON.parse(Buffer.from(tok.id_token.split('.')[1], 'base64url')).iss; } catch { return null; } })();

    const jwt = await step('jwt', async () => {
      const r = await fetch(`${API}/api/jwt`, { headers: bearer(tok.access_token) });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json().catch(() => ({}));
    }, c.steps);
    c.jwtSub = jwt.sub || jwt.user || null;

    const intro = await step('introspect', async () => {
      const r = await fetch(`${API}/api/introspect`, { headers: bearer(tok.access_token) });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return body;
    }, c.steps);
    c.introActive = intro.active === true;
    if (!c.introActive) throw new Error('introspection answered active:false');

    await step('refresh', async () => {
      const r = await fetch(`${KC(net)}/protocol/openid-connect/token`, {
        method: 'POST',
        headers: { authorization: `Basic ${basic}`, 'content-type': 'application/x-www-form-urlencoded' },
        body: form({ grant_type: 'refresh_token', refresh_token: tok.refresh_token }),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json();
    }, c.steps);

    await step('logout', async () => {
      const u = `${KC(net)}/protocol/openid-connect/logout?client_id=${CLIENT}&id_token_hint=${tok.id_token}`;
      await hop(u, {}, jar, (x) => !x.includes('/keycloak/') && !x.includes('legacy-'));
    }, c.steps);

    // the logout must have ended the session: the same refresh token may not work any more
    await step('logged_out', async () => {
      const r = await fetch(`${KC(net)}/protocol/openid-connect/token`, {
        method: 'POST',
        headers: { authorization: `Basic ${basic}`, 'content-type': 'application/x-www-form-urlencoded' },
        body: form({ grant_type: 'refresh_token', refresh_token: tok.refresh_token }),
      });
      const b = await r.json().catch(() => ({}));
      if (r.ok) throw new Error('refresh still works after logout');
      if (b.error !== 'invalid_grant') throw new Error(`expected invalid_grant, got ${b.error || r.status}`);
    }, c.steps);

    c.ok = true;
  } catch (e) {
    c.ok = false;
    c.error = String(e.message || e);
  }
  return c;
}

// --- stats over the last KEEP cycles
const cycles = [];
function pct(a, p) {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y), i = Math.min(s.length - 1, Math.ceil(p * s.length) - 1);
  return s[i];
}
function snapshot() {
  const steps = ['login', 'jwt', 'introspect', 'refresh', 'logout', 'logged_out'];
  const per = {};
  for (const s of steps) {
    const xs = cycles.map((c) => c.steps[s]).filter((x) => x && x.ok).map((x) => x.ms);
    const bad = cycles.filter((c) => c.steps[s] && !c.steps[s].ok).length;
    per[s] = { n: xs.length, p50: pct(xs, 0.5), p95: pct(xs, 0.95), bad, ok: bad === 0 && xs.length > 0 };
  }
  const ok = cycles.filter((c) => c.ok).length;
  return {
    cycles: cycles.length,
    ok,
    failed: cycles.length - ok,
    introActive: cycles.filter((c) => c.introActive).length,
    per,
    recent: cycles.slice(-12).map((c) => ({ at: c.at, net: c.net, ok: c.ok, error: c.error, ms: c.steps.login?.ms, steps: c.steps })),
  };
}

const sse = new Set();
const send = (obj) => { const s = `data: ${JSON.stringify(obj)}\n\n`; for (const r of sse) r.write(s); };

async function loop() {
  const c = await cycle();
  cycles.push(c);
  if (cycles.length > KEEP) cycles.shift();
  send(snapshot());
  setTimeout(loop, Math.max(250, INTERVAL - 0));
}

const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Keycloak blue/green - live</title>
<style>
:root{--ink:#f0efec;--muted:#8d8b84;--ok:#0ca30c;--bad:#e34948;--warn:#fab219;--card:#1a1a19;--line:#2c2c2a}
*{box-sizing:border-box}body{margin:0;background:#0d0d0d;color:var(--ink);font:15px/1.45 system-ui,Segoe UI,Roboto,sans-serif}
header{padding:18px 24px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:14px}
h1{font-size:18px;margin:0;font-weight:650}.sub{color:var(--muted);font-size:13px}
main{padding:18px 24px;display:grid;gap:14px;grid-template-columns:repeat(4,minmax(0,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
.k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.v{font-size:26px;font-weight:650;font-variant-numeric:tabular-nums;margin-top:4px}
.pill{display:inline-block;padding:2px 10px;border-radius:999px;font-size:13px;font-weight:600}
.p-ok{background:rgba(12,163,12,.15);color:#57d257}.p-bad{background:rgba(227,73,72,.15);color:#ff8a89}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:14px}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-weight:600;font-size:12px}
td.num{text-align:right}.wide{grid-column:span 4}
#log{font:12px/1.5 ui-monospace,Consolas,monospace;color:var(--muted);max-height:230px;overflow:auto}
#log b{color:var(--ink)}.bad{color:#ff8a89}.good{color:#57d257}
canvas{width:100%;height:90px;display:block}
</style></head><body>
<header><h1>Keycloak blue/green - live</h1><span id="status" class="pill p-bad">starting</span>
<span class="sub" id="who"></span><span class="sub" style="margin-left:auto"><a href="/report.html" style="color:#8fb8ff">pre-generated report (all five cases)</a></span></header>
<main>
<div class="card"><div class="k">cycles</div><div class="v" id="cycles">0</div></div>
<div class="card"><div class="k">failed</div><div class="v" id="failed">0</div></div>
<div class="card"><div class="k">introspection active</div><div class="v" id="active">0</div></div>
<div class="card"><div class="k">login p95</div><div class="v" id="p95">-</div></div>
<div class="card wide"><div class="k">last cycles (network latency, ms)</div><canvas id="spark" width="1200" height="90"></canvas></div>
<div class="card wide"><table><tr><th>step</th><th class="num">n</th><th class="num">p50</th><th class="num">p95</th><th class="num">errors</th></tr><tbody id="steps"></tbody></table></div>
<div class="card wide"><div class="k">live log</div><div id="log"></div></div>
</main>
<script>
const S = (id) => document.getElementById(id);
const f = (x) => (x == null ? '-' : Math.round(x) + ' ms');
let recent = [];
new EventSource('/events').onmessage = (ev) => {
  const d = JSON.parse(ev.data);
  S('cycles').textContent = d.cycles; S('failed').textContent = d.failed;
  S('active').textContent = d.introActive; S('p95').textContent = f(d.per.login.p95);
  S('status').className = 'pill ' + (d.failed ? 'p-bad' : 'p-ok');
  S('status').textContent = d.failed ? 'FAILING' : 'all good';
  S('steps').innerHTML = Object.entries(d.per).map(([k, v]) =>
    '<tr><td>' + k + '</td><td class="num">' + v.n + '</td><td class="num">' + f(v.p50) + '</td><td class="num">' + f(v.p95) +
    '</td><td class="num' + (v.bad ? ' bad' : '') + '">' + v.bad + '</td></tr>').join('');
  recent = d.recent;
  const l = d.recent.map((c) => '<div class="' + (c.ok ? 'good' : 'bad') + '">' + c.at.slice(11, 19) + ' ' + c.net +
    (c.ok ? ' ok' : ' ' + c.error) + ' login ' + f(c.steps.login && c.steps.login.ms) + '</div>').join('');
  S('log').innerHTML = l;
  draw(d.recent.map((c) => (c.steps.login ? c.steps.login.ms : 0)));
};
function draw(xs) {
  const c = S('spark'), ctx = c.getContext('2d'), w = c.width, h = c.height;
  ctx.clearRect(0, 0, w, h);
  if (!xs.length) return;
  const max = Math.max(50, ...xs), bw = w / Math.max(12, xs.length);
  xs.forEach((x, i) => { const bh = (x / max) * (h - 10); ctx.fillStyle = x > 500 ? '#e34948' : '#2a78d6';
    ctx.fillRect(i * bw + 1, h - bh, Math.max(2, bw - 2), bh); });
}
</script></body></html>`;

http.createServer((req, res) => {
  if (req.url === '/report.html') { // the pre-generated report, so one browser tab carries the whole story
    const f = process.env.REPORT || 'out/report.html';
    if (fs.existsSync(f)) {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(fs.readFileSync(f));
    } else {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end(`no pre-generated report at ${f}: run "bash scripts/report.sh" first`);
    }
    return;
  }
  if (req.url === '/events') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.write(`data: ${JSON.stringify(snapshot())}\n\n`);
    sse.add(res);
    req.on('close', () => sse.delete(res));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(page);
}).listen(PORT, '127.0.0.1', () => {
  console.log(`live demo: http://127.0.0.1:${PORT}/  (user ${USER}, client ${CLIENT}, every ${INTERVAL} ms)`);
  loop();
});
