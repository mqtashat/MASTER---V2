// اختبار الحمل والأداء والاسترجاع (B092–B094) على بيانات اصطناعية.
// التحميل يمر بمسار التطبيق نفسه (دوال الاستيراد والرفع الموحد)، ثم تُقاس الاستعلامات المعتادة،
// ثم تُختبر إعادة المحاولة بعد الانقطاع، وإعادة الرفع، وحذف دفعة، والنسخ الاحتياطي والاستعادة.
// التشغيل: node load/load.mjs --rows 100000 --months 7 --out out/load-100k.json
import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { definitions, monthRows } from './generate.mjs';

pg.types.setTypeParser(1700, (v) => v);
pg.types.setTypeParser(1082, (v) => v);

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
const ROWS = Number(arg('rows', 100000));
const MONTHS = Number(arg('months', 7));
const YEAR = 2026;
const DB = process.env.PGDATABASE || 'master_load';
const OUT = arg('out', `load/out/load-${ROWS}.json`);
const REPS = Math.max(4, Math.round(ROWS / MONTHS / 560));
const PER_MONTH = Math.round(ROWS / MONTHS);
const conn = { host: '/tmp', port: 54322, user: 'postgres', database: DB };

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const result = { rows_target: ROWS, months: MONTHS, reps: REPS, started: new Date().toISOString(), load: [], queries: [], recovery: [], counts: {} };

// ---------------------------------------------------------------------
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const REUSE = process.argv.includes('--reuse');
if (!REUSE) execFileSync('bash', [path.join(root, 'tests/local/reset_db.sh')], { env: { ...process.env, PGDATABASE: DB }, stdio: 'inherit' });

const pool = new pg.Pool({ ...conn, max: 4 });
let ADMIN = null;

/** استدعاء دالة كمستخدم مسجل في معاملة مستقلة تُعتمد */
async function rpc(uid, fn, args = {}) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    if (uid) {
      await c.query('set local role authenticated');
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: uid, role: 'authenticated' })]);
    }
    const keys = Object.keys(args);
    const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
    const r = await c.query(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, vals);
    await c.query('commit');
    return r.rows[0].r;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally { c.release(); }
}
const sql = async (q, p = []) => (await pool.query(q, p)).rows;
const timed = async (fn) => { const t = performance.now(); const v = await fn(); return [performance.now() - t, v]; };

const defs = definitions({ reps: REPS });
const T = ['A', 'B', 'C', 'X'];
const files = [];
let repIds = [], supIds = [];
const loadIds = async () => {
  const ids = Object.fromEntries((await sql('select emp_number, id from employees')).map((r) => [r.emp_number, r.id]));
  repIds = defs.employees.filter((e) => e.role !== 'مشرف').map((e) => ids[e.num]);
  supIds = defs.employees.filter((e) => e.role === 'مشرف').map((e) => ids[e.num]);
};
if (REUSE) {
  ADMIN = (await sql('select id from app_users where is_admin limit 1'))[0].id;
  for (let m = 1; m <= MONTHS; m++) files.push({ m, month: `${YEAR}-${String(m).padStart(2, '0')}-01`, data: monthRows({ year: YEAR, month: m, reps: REPS, rowsPerMonth: PER_MONTH, items: defs.items }) });
} else {
// ---------------------------------------------------------------------
// التعريفات عبر الاستيراد
// ---------------------------------------------------------------------
ADMIN = await rpc(null, 'bootstrap_admin', { p_username: 'admin', p_password: 'Admin#2026', p_display_name: 'الإدارة' });
await rpc(ADMIN, 'admin_set_secret', { p_old: null, p_new: 'sirr-2026' });

let [ms] = await timed(() => rpc(ADMIN, 'commit_employee_import', { p_rows: defs.employees.map((e, i) => ({
  row: i + 2, emp_number: e.num, name: e.name, job_role: e.role, join_date: '2025-01-01', status: 'نشط', status_date: '', supervisor_number: e.sup,
})), p_decisions: {}, p_file_name: 'employees.xlsx' }));
result.load.push({ step: `استيراد ${defs.employees.length} موظفًا`, ms });

[ms] = await timed(() => rpc(ADMIN, 'commit_customer_import', { p_rows: defs.customers.map((c, i) => ({
  row: i + 2, master_name: c.masterName, master_number: c.master, name: c.name, customer_number: c.num, company_id: '2', grace_days: '',
})), p_decisions: {}, p_file_name: 'customers.xlsx' }));
result.load.push({ step: `استيراد ${defs.customers.length} عميلًا`, ms });

[ms] = await timed(() => rpc(ADMIN, 'commit_product_import', { p_rows: defs.items.map((it, i) => {
  const r = { row: i + 2, code: it.code, name: it.name, sale: it.price, cost: it.cost, packing: String(it.packing) };
  T.forEach((t, k) => { r['rep_' + t] = String([2.5, 2, 1.5, 1][k]); r['supervisor_' + t] = String([3, 2.5, 2, 1][k]); });
  return r;
}), p_dates: { sale: '2025-01-01', cost: '2025-01-01', packing: '2025-01-01', rates: '2025-01-01' }, p_file_name: 'products.xlsx' }));
result.load.push({ step: `استيراد ${defs.items.length} صنفًا`, ms });


await loadIds();
// ---------------------------------------------------------------------
// الحركات: ملف لكل نوع لكل شهر عبر الرفع الموحد
// ---------------------------------------------------------------------
for (let m = 1; m <= MONTHS; m++) {
  const month = `${YEAR}-${String(m).padStart(2, '0')}-01`;
  const data = monthRows({ year: YEAR, month: m, reps: REPS, rowsPerMonth: PER_MONTH, items: defs.items });
  files.push({ m, month, data });
  for (const [kind, rows] of [['invoice', data.invoices], ['return', data.returns], ['collection', data.collections]]) {
    if (!rows.length) continue;
    const cols = kind === 'collection'
      ? ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب']
      : ['Longitude', 'Latitude', ...(kind === 'invoice' ? ['DocumentTypeID'] : []), 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
         'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
    const [t1, s] = await timed(() => rpc(ADMIN, 'upload_stage', { p_kind: kind, p_file_name: `${kind}-${m}.xlsx`, p_sheet: 'S', p_columns: cols, p_rows: rows }));
    const ids = (await sql('select id from batch_items where batch_id = $1 order by seq', [s.batch_id])).map((x) => ({ id: x.id, action: 'approve' }));
    // الاعتماد على دفعات من 500 سند كما تفعل الواجهة
    const [t2, r] = await timed(async () => {
      const tot = {};
      for (let i = 0; i < ids.length; i += 500) {
        const part = await rpc(ADMIN, 'upload_resolve', { p_batch: s.batch_id, p_decisions: ids.slice(i, i + 500) });
        for (const [k, v] of Object.entries(part)) if (typeof v === 'number') tot[k] = (tot[k] ?? 0) + v;
      }
      return tot;
    });
    result.load.push({ step: `رفع ${kind} شهر ${m}: ${rows.length} صفًا / ${s.docs} سندًا`, stage_ms: t1, resolve_ms: t2, pending: s.pending ?? 0,
      added: r.added ?? null });
    log(`month ${m} ${kind}: rows ${rows.length} docs ${s.docs} stage ${Math.round(t1)}ms resolve ${Math.round(t2)}ms pending ${s.pending}`);
  }
  // الأهداف والقاعدة لكل شهر (لبطاقات الأداء والعمولات)
  await rpc(ADMIN, 'save_commission_rule', { p_id: null, p: { month, name: 'قاعدة الشهر', members: [...repIds, ...supIds],
    tiers: T.map((t) => ({ tier: t, rep_rate: null, sup_rate: null })) } });
  for (const id of repIds) {
    await rpc(ADMIN, 'save_goal_plan', { p_id: null, p: { month, employee_id: id, role: 'rep', tiers: T.map((t) => ({ tier: t, logic: 'AND' })),
      components: T.map((t, k) => ({ tier: t, metric: 'net_sales', target: [6000, 5000, 4000, 3000][k] })) } });
  }
  for (const id of supIds) {
    await rpc(ADMIN, 'save_goal_plan', { p_id: null, p: { month, employee_id: id, role: 'supervisor', sup_mode: 'team_sum',
      tiers: T.map((t) => ({ tier: t, logic: 'AND' })), components: T.map((t) => ({ tier: t, metric: 'net_sales' })) } });
  }
}

}
await loadIds();
const counts = (await sql(`select kind, count(*)::int docs, sum(line_count)::int lines, sum(total) total from docs where status = 'active' group by kind order by kind`));
result.counts = { docs: counts, doc_lines: (await sql('select count(*)::int n from doc_lines'))[0].n,
  customers: (await sql('select count(*)::int n from customers'))[0].n,
  families: (await sql('select count(distinct master_id)::int n from customer_master_links'))[0].n,
  branches: (await sql('select count(*)::int n from customer_master_links'))[0].n,
  active_customers: (await sql(`select count(distinct customer_id)::int n from docs where status = 'active'`))[0].n,
  employees: (await sql('select count(*)::int n from employees'))[0].n,
  products: (await sql('select count(*)::int n from products'))[0].n,
  years: (await sql(`select array_agg(distinct extract(year from doc_date)::int) y from docs`))[0].y,
  multi_line_docs: (await sql(`select count(*)::int n from docs where line_count > 1`))[0].n,
  no_location_docs: (await sql(`select count(*)::int n from docs where lat is null and kind <> 'collection'`))[0].n };
log('counts', JSON.stringify(result.counts));

// ---------------------------------------------------------------------
// قياس الاستعلامات المعتادة (B093): ثلاث مرات، الوسيط
// ---------------------------------------------------------------------
const lastM = `${YEAR}-${String(MONTHS).padStart(2, '0')}-01`;
const lastEnd = new Date(Date.UTC(YEAR, MONTHS, 0)).toISOString().slice(0, 10);
const PM = Math.max(1, MONTHS - 1);
const prevM = `${YEAR}-${String(PM).padStart(2, '0')}-01`;
const prevEnd = new Date(Date.UTC(YEAR, PM, 0)).toISOString().slice(0, 10);
const yearFrom = `${YEAR}-01-01`;
const topCredit = (await sql(`select customer_id, count(*) n from docs where kind = 'invoice' and pay_type = 'فاتورة ذمم' group by 1 order by 2 desc limit 1`))[0]?.customer_id;
const master = (await sql(`select master_id from customer_master_links limit 1`))[0]?.master_id;
const topProduct = (await sql(`select product_id from doc_lines where product_id is not null group by 1 order by count(*) desc limit 1`))[0]?.product_id;
const busyDay = (await sql(`select doc_date from docs where kind = 'invoice' and doc_date >= $1 group by 1 order by count(*) desc limit 1`, [lastM]))[0]?.doc_date;

const Q = [
  ['جدول', 'الفواتير: الصفحة الأولى بلا فلتر', () => rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: {}, p_offset: 0, p_limit: 50 })],
  ['جدول', 'الفواتير: شهر ومندوب', () => rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: { from: lastM, to: lastEnd, employee: '100' }, p_offset: 0, p_limit: 50 })],
  ['جدول', 'الفواتير: ترتيب بالمبلغ', () => rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: {}, p_sort: 'total', p_asc: false, p_offset: 0, p_limit: 100 })],
  ['جدول', 'الفواتير: الصفحة 50', () => rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: {}, p_offset: 2450, p_limit: 50 })],
  ['جدول', 'التحصيلات: الصفحة الأولى', () => rpc(ADMIN, 'docs_search', { p_kind: 'collection', p_filters: {}, p_offset: 0, p_limit: 50 })],
  ['جدول', 'العملاء: بحث بالاسم', () => sql(`select * from customers_v where name ilike '%تجريبي 12%' order by customer_number limit 50`)],
  ['كشف', 'كشف حساب أكثر عميل ذمم (السنة)', () => rpc(ADMIN, 'account_statement', { p_customer: topCredit, p_family: false, p_from: yearFrom, p_to: lastEnd, p_opts: {} })],
  ['كشف', 'كشف عائلة (رئيسي وفروعه)', () => rpc(ADMIN, 'account_statement', { p_customer: master, p_family: true, p_from: yearFrom, p_to: lastEnd, p_opts: {} })],
  ['كشف', 'الذمم الحالية', () => rpc(ADMIN, 'receivables', { p_date: lastEnd, p_opts: {} })],
  ['أداء', 'بطاقات الأداء (كل المندوبين)', () => rpc(ADMIN, 'performance_cards', { p_month: lastM, p_opts: { role: 'rep' } })],
  ['أداء', 'ملخص العمولات', () => rpc(ADMIN, 'commission_summary', { p_month: lastM })],
  ['أداء', 'كشف عمولة مندوب', () => rpc(ADMIN, 'commission_statement', { p_employee: repIds[0], p_month: lastM })],
  ['أداء', 'كشف عمولة مشرف', () => rpc(ADMIN, 'commission_statement', { p_employee: supIds[0], p_month: lastM })],
  ['أداء', 'قائمة الأهداف', () => rpc(ADMIN, 'goals_list', { p_month: lastM, p_role: 'rep', p_opts: {} })],
  ['أداء', 'جاهزية إغلاق الشهر', () => rpc(ADMIN, 'month_readiness', { p_month: lastM })],
  ['خرائط', 'خريطة الفواتير ليوم', () => rpc(ADMIN, 'invoice_map', { p_from: busyDay, p_to: busyDay, p_opts: {} })],
  ['خرائط', 'خريطة الفواتير لشهر', () => rpc(ADMIN, 'invoice_map', { p_from: lastM, p_to: lastEnd, p_opts: {} })],
  ['خرائط', 'مقارنة شهرين', () => rpc(ADMIN, 'period_compare', { p_a_from: prevM, p_a_to: prevEnd, p_b_from: lastM, p_b_to: lastEnd, p_opts: {} })],
  ['خرائط', 'انتشار صنف لشهر', () => rpc(ADMIN, 'product_spread', { p_product: topProduct, p_from: lastM, p_to: lastEnd, p_opts: {} })],
  ...['management', 'performance', 'sales', 'collections', 'returns', 'spread', 'commissions', 'quality'].map((r) =>
    ['تقرير', `تقرير ${r} لشهر`, () => rpc(ADMIN, 'report_run', { p_report: r, p_opts: { from: lastM, to: lastEnd, ...(r === 'sales' ? { group: 'employee' } : {}) } })]),
  ['تقرير', 'تقرير المبيعات للسنة حسب الصنف', () => rpc(ADMIN, 'report_run', { p_report: 'sales', p_opts: { from: yearFrom, to: lastEnd, group: 'product' } })],
  ['تقرير', 'تقرير مخصص: الموظف × الشهر', () => rpc(ADMIN, 'report_run', { p_report: 'custom', p_opts: { from: yearFrom, to: lastEnd,
    dimensions: ['employee', 'month'], measures: ['sales_value', 'returns_value', 'net_value', 'invoices', 'customers'] } })],
];
for (const [cat, name, fn] of Q) {
  const times = [];
  let err = null; let cold = null;
  for (let i = 0; i < 6; i++) {
    try { const [t] = await timed(fn); if (i === 0) cold = t; else times.push(t); } catch (e) { err = e.message; break; }
  }
  times.sort((a, b) => a - b);
  const median = times.length ? times[Math.floor(times.length / 2)] : null;
  const p95 = times.length ? times[Math.min(times.length - 1, Math.ceil(times.length * 0.95) - 1)] : null;
  const target = cat === 'كشف' ? 3000 : 2000;
  result.queries.push({ cat, name, cold_ms: cold, median_ms: median, p95_ms: p95, target_ms: target, ok: median !== null && median <= target, error: err });
  log(`${cat} | ${name}: ${median === null ? 'ERROR ' + err : 'cold ' + Math.round(cold) + 'ms, median ' + Math.round(median) + 'ms, p95 ' + Math.round(p95) + 'ms'}`);
}

// ---------------------------------------------------------------------
// الاسترجاع وسلامة البيانات (B092، B094، D10)
// ---------------------------------------------------------------------
async function recovery(name, fn) {
  try { const [t, detail] = await timed(fn); result.recovery.push({ name, ok: true, ms: t, detail }); log('✔', name, Math.round(t) + 'ms'); }
  catch (e) { result.recovery.push({ name, ok: false, error: e.message }); log('✖', name, e.message); }
}
const assert = (c, m) => { if (!c) throw new Error(m); };

// D10: انقطاع بعد اعتماد جزء من الدفعة ثم إعادة المحاولة بالقرارات كاملة: لا تكرار
await recovery('D10: انقطاع بعد اعتماد نصف الدفعة ثم إعادة المحاولة', async () => {
  const m = MONTHS + 1 <= 12 ? MONTHS + 1 : MONTHS;
  const extra = monthRows({ year: YEAR, month: m, reps: Math.min(REPS, 6), rowsPerMonth: 3000, items: defs.items, seed: 99 }).invoices
    .map((r) => ({ ...r, doc_number: 'R' + r.doc_number }));
  const before = (await sql(`select count(*)::int n from docs`))[0].n;
  const cols = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername', 'CustomerNumber',
    'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
  const s = await rpc(ADMIN, 'upload_stage', { p_kind: 'invoice', p_file_name: 'interrupted.xlsx', p_sheet: 'S', p_columns: cols, p_rows: extra });
  const ids = (await sql('select id from batch_items where batch_id = $1 order by seq', [s.batch_id])).map((x) => ({ id: x.id, action: 'approve' }));
  await rpc(ADMIN, 'upload_resolve', { p_batch: s.batch_id, p_decisions: ids.slice(0, Math.floor(ids.length / 2)) });
  await rpc(ADMIN, 'upload_resolve', { p_batch: s.batch_id, p_decisions: ids });   // إعادة المحاولة بالكامل
  const after = (await sql(`select count(*)::int n from docs`))[0].n;
  assert(after - before === s.docs, `المتوقع إضافة ${s.docs} سندًا، أضيف ${after - before}`);
  const dup = (await sql(`select count(*)::int n from (select kind, doc_number, customer_number, doc_date from docs group by 1,2,3,4 having count(*) > 1) x`))[0].n;
  assert(dup === 0, 'سندات مكررة: ' + dup);
  return { docs: s.docs };
});

// قسم 6: الحساب التزايدي للذمم يطابق إعادة حساب كاملة من الصفر لكل الحسابات
await recovery('FIFO التزايدي يطابق إعادة الحساب الكاملة', async () => {
  const snap = `select account_id, year, coalesce(sum(case side when 'D' then amount else -amount end), 0)::text b from app.ledger_items group by 1, 2 order by 1, 2`;
  const allocs = `select md5(string_agg(year || ':' || credit_key || '>' || debt_key || '=' || amount || '@' || alloc_date, ',' order by year, credit_key, debt_key, seq)) h from app.ledger_allocs`;
  await rpc(ADMIN, 'receivables', { p_date: `${YEAR}-12-31`, p_opts: {} });   // يضمن تحديث التزايدي
  const a1 = await sql(snap); const h1 = (await sql(allocs))[0].h;
  const [t] = await timed(async () => {
    await sql(`insert into app.ledger_dirty select distinct customer_id, extract(year from doc_date)::int from docs on conflict do nothing`);
    await sql(`select app.refresh_ledger()`);
  });
  const a2 = await sql(snap); const h2 = (await sql(allocs))[0].h;
  assert(JSON.stringify(a1) === JSON.stringify(a2), 'أرصدة البنود تختلف بعد إعادة الحساب الكاملة');
  assert(h1 === h2, 'التخصيصات تختلف بعد إعادة الحساب الكاملة');
  return { accounts: a1.length, full_recompute_ms: t };
});

// D01: إعادة رفع ملف شهر كامل: كله «بلا تغيير»
await recovery('D01: إعادة رفع ملف فواتير شهر كامل', async () => {
  const f = files[files.length - 1];
  const cols = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername', 'CustomerNumber',
    'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
  const before = (await sql(`select count(*)::int n, sum(total) t from docs where status = 'active'`))[0];
  const [ts, s] = await timed(() => rpc(ADMIN, 'upload_stage', { p_kind: 'invoice', p_file_name: 'again.xlsx', p_sheet: 'S', p_columns: cols, p_rows: f.data.invoices }));
  assert(s.new === 0 && s.changed === 0, `جديد ${s.new} ومتغير ${s.changed}`);
  const ids = (await sql('select id from batch_items where batch_id = $1 order by seq', [s.batch_id])).map((x) => ({ id: x.id, action: 'approve' }));
  const [tr] = await timed(() => rpc(ADMIN, 'upload_resolve', { p_batch: s.batch_id, p_decisions: ids }));
  const after = (await sql(`select count(*)::int n, sum(total) t from docs where status = 'active'`))[0];
  assert(before.n === after.n && before.t === after.t, 'تغير العدد أو المجموع');
  return { unchanged: s.unchanged, stage_ms: ts, resolve_ms: tr };
});

// B094: تطابق التصدير — مجموع صفحات الجدول = الملخص
await recovery('B094: تطابق التصدير الكامل مع ملخص الجدول', async () => {
  const f = { from: prevM, to: prevEnd };
  const first = await rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: f, p_offset: 0, p_limit: 1 });
  const total = Number(first.summary.count);
  let n = 0; let sum = 0;
  for (let off = 0; off < total; off += 1000) {
    const page = await rpc(ADMIN, 'docs_search', { p_kind: 'invoice', p_filters: f, p_offset: off, p_limit: 1000 });
    n += page.rows.length; for (const r of page.rows) sum += Number(r.total);
  }
  const db = (await sql(`select count(*)::int n, sum(total) t from docs where kind = 'invoice' and status = 'active' and doc_date between $1 and $2`, [prevM, prevEnd]))[0];
  assert(n === db.n, `عدد التصدير ${n} ≠ ${db.n}`);
  assert(Math.abs(sum - Number(db.t)) < 0.01 && first.summary.total === db.t, `مجموع التصدير ${sum} / الملخص ${first.summary.total} ≠ ${db.t}`);
  return { rows: n };
});

// B094: نسخ احتياطي ثم استعادة في قاعدة جديدة ومطابقة البصمة
await recovery('B094: النسخ الاحتياطي والاستعادة', async () => {
  const fp = `select (select count(*) from docs) d, (select count(*) from doc_lines) l, (select coalesce(sum(total),0) from docs where status='active') t,
                     (select count(*) from customers) c, (select count(*) from audit_log) a, (select count(*) from goal_plans) g`;
  const a = (await sql(fp))[0];
  const dump = `/tmp/master-load-${ROWS}.dump`;
  const [tDump] = await timed(async () => execFileSync('pg_dump', ['-h', '/tmp', '-p', '54322', '-U', 'postgres', '-Fc', '-f', dump, DB]));
  const restoreDb = DB + '_restore';
  execFileSync('psql', ['-h', '/tmp', '-p', '54322', '-U', 'postgres', '-qAt', '-c', `drop database if exists ${restoreDb} with (force)`, '-c', `create database ${restoreDb}`]);
  const [tRestore] = await timed(async () => execFileSync('pg_restore', ['-h', '/tmp', '-p', '54322', '-U', 'postgres', '-d', restoreDb, dump]));
  const p2 = new pg.Pool({ ...conn, database: restoreDb, max: 1 });
  const b = (await p2.query(fp)).rows[0];
  await p2.end();
  execFileSync('psql', ['-h', '/tmp', '-p', '54322', '-U', 'postgres', '-qAt', '-c', `drop database if exists ${restoreDb} with (force)`]);
  const size = fs.statSync(dump).size; fs.unlinkSync(dump);
  assert(JSON.stringify(a) === JSON.stringify(b), `البصمة مختلفة: ${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`);
  return { dump_ms: tDump, restore_ms: tRestore, dump_mb: Math.round(size / 1048576) };
});

// تعدد المستخدمين: ثمانية طلبات متزامنة لصفحات مختلفة
await recovery('B093: ثمانية مستخدمين متزامنين', async () => {
  const p8 = new pg.Pool({ ...conn, max: 8 });
  const t0 = performance.now();
  const one = async (fn, args) => {
    const c = await p8.connect();
    try {
      await c.query('begin'); await c.query('set local role authenticated');
      await c.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: ADMIN, role: 'authenticated' })]);
      const keys = Object.keys(args); const vals = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
      const t = performance.now();
      await c.query(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})`, vals);
      await c.query('commit');
      return performance.now() - t;
    } finally { c.release(); }
  };
  const times = await Promise.all([
    one('docs_search', { p_kind: 'invoice', p_filters: {}, p_offset: 0, p_limit: 50 }),
    one('docs_search', { p_kind: 'invoice', p_filters: { employee: '101' }, p_offset: 0, p_limit: 50 }),
    one('account_statement', { p_customer: topCredit, p_family: false, p_from: yearFrom, p_to: lastEnd, p_opts: {} }),
    one('receivables', { p_date: lastEnd, p_opts: {} }),
    one('performance_cards', { p_month: prevM, p_opts: { role: 'rep' } }),
    one('commission_summary', { p_month: prevM }),
    one('report_run', { p_report: 'management', p_opts: { from: prevM, to: prevEnd } }),
    one('invoice_map', { p_from: prevM, p_to: prevEnd, p_opts: {} }),
  ]);
  await p8.end();
  return { wall_ms: performance.now() - t0, max_ms: Math.max(...times) };
});

// حذف دفعة شهر كامل تراجعًا (DATA-007) ثم التحقق
await recovery('DATA-007: حذف دفعة فواتير شهر كامل', async () => {
  const b = (await sql(`select id from upload_batches where kind = 'invoice' and file_name = $1`, [`invoice-${MONTHS}.xlsx`]))[0].id;
  const pv = await rpc(ADMIN, 'preview_delete_batch', { p_batch: b });
  const n0 = (await sql(`select count(*)::int n from docs where status = 'active' and kind = 'invoice'`))[0].n;
  await rpc(ADMIN, 'delete_batch', { p_batch: b, p_reason: 'اختبار الحمل' });
  const n1 = (await sql(`select count(*)::int n from docs where status = 'active' and kind = 'invoice'`))[0].n;
  return { removed: n0 - n1, preview_remove: pv.remove?.length ?? null };
});

result.finished = new Date().toISOString();
result.db_size_mb = Math.round(Number((await sql(`select pg_database_size($1) s`, [DB]))[0].s) / 1048576);
fs.mkdirSync(path.dirname(path.resolve(OUT)), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(result, null, 2));
log('written', OUT);
await pool.end();
