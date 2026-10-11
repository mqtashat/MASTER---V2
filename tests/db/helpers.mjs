// أدوات اختبار قاعدة البيانات: اتصال بصلاحية المالك للتهيئة، واتصال «كمستخدم» عبر
// الدور authenticated ومطالبة JWT كما يفعل Supabase، داخل معاملة تُلغى بعد كل اختبار.
import pg from 'pg';

pg.types.setTypeParser(1700, (v) => (v === null ? null : v)); // numeric كنص للحفاظ على الدقة
pg.types.setTypeParser(1082, (v) => v);                          // date كنص YYYY-MM-DD

export const conn = {
  host: process.env.PGHOST || '/tmp',
  port: Number(process.env.PGPORT || 54322),
  user: 'postgres',
  database: process.env.PGDATABASE || 'master_test',
};

export async function connect() {
  const c = new pg.Client(conn);
  await c.connect();
  await c.query('begin');
  return {
    c,
    // تنفيذ بصلاحية المالك (للتهيئة)
    async sql(text, params = []) {
      await c.query('reset role');
      await c.query(`select set_config('request.jwt.claims', '', true)`);
      return (await c.query(text, params)).rows;
    },
    // تنفيذ كمستخدم مسجل
    async as(uid, text, params = []) {
      await c.query('set local role authenticated');
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: uid, role: 'authenticated' })]);
      try {
        await c.query('savepoint s');
        const r = (await c.query(text, params)).rows;
        await c.query('release savepoint s');
        return r;
      } catch (e) {
        await c.query('rollback to savepoint s');
        throw e;
      } finally {
        await c.query('reset role');
      }
    },
    async rpc(uid, fn, args = {}) {
      const keys = Object.keys(args);
      const call = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
      const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
      const rows = uid ? await this.as(uid, call, vals) : await this.sql(call, vals);
      return rows[0].r;
    },
    async close() {
      await c.query('rollback');
      await c.end();
    },
  };
}

// يتوقع فشلًا برسالة تحتوي النص المعطى
export async function rejects(promise, includes) {
  try {
    await promise;
  } catch (e) {
    if (includes && !String(e.message).includes(includes)) {
      throw new Error(`رسالة غير متوقعة: «${e.message}»، المتوقع أن تحتوي «${includes}»`);
    }
    return e;
  }
  throw new Error(`كان متوقعًا الرفض${includes ? `: ${includes}` : ''}`);
}

// إنشاء إدارة ومستخدمين للاختبار
export async function seedAdmin(db) {
  const id = await db.rpc(null, 'bootstrap_admin', { p_username: 'admin', p_password: 'Admin#2026', p_display_name: 'الإدارة' });
  return id;
}

export async function makeUser(db, adminId, user) {
  return db.rpc(adminId, 'admin_save_user', { p_id: null, p_user: { password: 'Pass#2026x', ...user } });
}
