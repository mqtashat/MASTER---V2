// بوابة محلية تحاكي Supabase للاختبار الشامل في المتصفح:
// /rest/v1 → PostgREST، و/auth/v1 → دخول بكلمة المرور من auth.users ورموز JWT.
// للاختبار المحلي فقط؛ لا تُستخدم في التشغيل.
import http from 'node:http';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import pg from '../node_modules/pg/lib/index.js';

export const JWT_SECRET = 'local-test-secret-at-least-32-characters-long';
const PORT = Number(process.env.GATEWAY_PORT || 54321);
const PGRST_PORT = 54330;
const DB = process.env.PGDATABASE || 'master_test';

const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
export function sign(payload) {
  const h = b64({ alg: 'HS256', typ: 'JWT' });
  const p = b64(payload);
  const s = crypto.createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${s}`;
}
function verify(token) {
  const [h, p, s] = String(token || '').split('.');
  if (!s) return null;
  const ok = crypto.createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest('base64url') === s;
  return ok ? JSON.parse(Buffer.from(p, 'base64url').toString()) : null;
}
export const ANON_KEY = sign({ role: 'anon', iss: 'local', exp: 4102444800 });

const pool = new pg.Pool({ host: '/tmp', port: 54322, user: 'postgres', database: DB });
const refresh = new Map();

function session(user) {
  const exp = Math.floor(Date.now() / 1000) + 3600;
  const access = sign({ sub: user.id, role: 'authenticated', aud: 'authenticated', email: user.email, exp });
  const rt = crypto.randomBytes(16).toString('hex');
  refresh.set(rt, user);
  return { access_token: access, token_type: 'bearer', expires_in: 3600, expires_at: exp, refresh_token: rt,
    user: { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, app_metadata: {}, user_metadata: {} } };
}

const pgrst = spawn('/opt/pgrst/postgrest', [], {
  env: { ...process.env, PGRST_DB_URI: `postgres://authenticator:authenticator@localhost:54322/${DB}?host=/tmp`,
    PGRST_DB_SCHEMAS: 'public', PGRST_DB_ANON_ROLE: 'anon', PGRST_JWT_SECRET: JWT_SECRET, PGRST_SERVER_PORT: String(PGRST_PORT),
    PGRST_DB_CHANNEL_ENABLED: 'false', PGRST_LOG_LEVEL: 'error' },
  stdio: 'inherit',
});
process.on('exit', () => pgrst.kill());

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET,POST,PATCH,PUT,DELETE,OPTIONS', 'Access-Control-Expose-Headers': 'Content-Range, Content-Profile' };
const send = (res, code, body) => { res.writeHead(code, { ...cors, 'Content-Type': 'application/json' }); res.end(body === undefined ? '' : JSON.stringify(body)); };
const readBody = (req) => new Promise((r) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => r(d)); });

http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204, cors); return res.end(); }
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname === '/auth/v1/token') {
      const body = JSON.parse((await readBody(req)) || '{}');
      if (url.searchParams.get('grant_type') === 'password') {
        const { rows } = await pool.query(
          `select id, email, banned_until from auth.users where email = $1 and encrypted_password = extensions.crypt($2, encrypted_password)`,
          [String(body.email).toLowerCase(), body.password]);
        if (!rows.length) return send(res, 400, { error: 'invalid_grant', error_description: 'Invalid login credentials', msg: 'Invalid login credentials' });
        if (rows[0].banned_until && new Date(rows[0].banned_until) > new Date()) return send(res, 400, { error: 'user_banned', msg: 'User is banned' });
        return send(res, 200, session(rows[0]));
      }
      if (url.searchParams.get('grant_type') === 'refresh_token') {
        const u = refresh.get(body.refresh_token);
        if (!u) return send(res, 400, { error: 'invalid_grant', msg: 'Invalid Refresh Token' });
        return send(res, 200, session(u));
      }
    }
    if (url.pathname === '/auth/v1/user') {
      const t = verify((req.headers.authorization || '').replace(/^Bearer /, ''));
      if (!t?.sub) return send(res, 401, { msg: 'invalid token' });
      return send(res, 200, { id: t.sub, aud: 'authenticated', role: 'authenticated', email: t.email });
    }
    if (url.pathname === '/auth/v1/logout') return send(res, 204);
    if (url.pathname.startsWith('/rest/v1/')) {
      const target = `http://127.0.0.1:${PGRST_PORT}${url.pathname.slice('/rest/v1'.length)}${url.search}`;
      const body = ['GET', 'HEAD'].includes(req.method) ? undefined : await readBody(req);
      const headers = { ...req.headers }; delete headers.host; delete headers['content-length'];
      const r = await fetch(target, { method: req.method, headers, body });
      const out = Buffer.from(await r.arrayBuffer());
      const h = { ...cors };
      r.headers.forEach((v, k) => { if (!['content-encoding', 'transfer-encoding', 'connection'].includes(k) && !k.startsWith('access-control-')) h[k] = v; });
      res.writeHead(r.status, h); return res.end(out);
    }
    send(res, 404, { msg: 'not found' });
  } catch (e) {
    send(res, 500, { msg: String(e.message || e) });
  }
}).listen(PORT, () => console.log(`gateway on ${PORT}; anon key: ${ANON_KEY}`));
