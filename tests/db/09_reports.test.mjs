// الوحدة 6 — التقارير: الثمانية الجاهزة (B078–B085) والمخصص (UX-003) والإعدادات المحفوظة والصلاحيات ونطاق البيانات.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;
let docNo = 7000;

// docs: [{cust, date, emp, pay, lat, lng, amount (تحصيل), lines: [[item, ns, np, qty, bonus]]}]
async function add(db, a, kind, docs) {
  const rows = [];
  for (const d of docs) {
    const n = d.num ?? String(docNo++);
    if (kind === 'collection') {
      rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20', amount: String(d.amount), pay_method: 'نقدي', cheque_no: '' });
      continue;
    }
    for (const [item, ns, np = 0, qty = 1, bonus = 0] of d.lines) {
      rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20',
        pay_type: d.pay ?? 'فاتورة نقدي', item_number: item, item_name: 'صنف', net_sales: String(ns), net_promotions: String(np),
        quantity: String(qty), bonus: String(bonus), lat: d.lat === undefined ? '' : String(d.lat), lng: d.lng === undefined ? '' : String(d.lng) });
    }
  }
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS;
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rows });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  assert.deepEqual(its.flatMap((i) => i.errors), []);
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}

async function setup(db) {
  const a = await seedAdmin(db);
  const e = {};
  e.sup = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.sup } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01' } });
  const c = {};
  for (const n of ['500', '501', '502', '503']) c[n] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name: 'عميل ' + n } });
  const p = {};
  for (const code of ['A1', 'A2']) {
    p[code] = await db.rpc(a, 'save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
    await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
  }
  // سبتمبر: 500 (أ) فاتورتان، 501 (أ) ذمم، 502 (ب)؛ مرتجع على A1؛ تحصيل؛ وأغسطس للمقارنة
  await add(db, a, 'invoice', [
    { cust: '500', date: '2026-09-05', lines: [['A1', 100, 10, 2, 1], ['A2', 50, 0, 1]] },
    { cust: '500', date: '2026-09-12', lines: [['A1', 40, 0, 1]] },
    { cust: '501', date: '2026-09-07', pay: 'فاتورة ذمم', lines: [['A2', 200, 0, 4]] },
    { cust: '502', date: '2026-09-08', emp: '21', lines: [['A1', 300, 0, 6]] },
    { cust: '500', date: '2026-08-10', lines: [['A1', 80, 0, 2]] },
  ]);
  await add(db, a, 'return', [{ cust: '500', date: '2026-09-20', lines: [['A1', 30, 0, 1]] }]);
  await add(db, a, 'collection', [{ cust: '501', date: '2026-09-25', amount: 120 }]);
  return { a, e, c, p };
}
const run = (db, u, report, opts) => db.rpc(u, 'report_run', { p_report: report, p_opts: { from: '2026-09-01', to: '2026-09-30', ...opts } });

test('B080: المبيعات التفصيلية بالتجميع والفلاتر، والإجماليات من المحرك نفسه', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    const byEmp = await run(db, a, 'sales', {});
    assert.equal(num(byEmp.totals.sales_value), 700);
    assert.equal(num(byEmp.totals.returns_value), 30);
    assert.equal(num(byEmp.totals.net_value), 670);
    assert.equal(num(byEmp.totals.promotions), 10);
    assert.equal(byEmp.totals.invoices, 4);
    assert.equal(byEmp.totals.customers, 3);
    assert.deepEqual(byEmp.rows.map((r) => [r.employee, num(r.net_value)]), [['20 — مندوب أ', 370], ['21 — مندوب ب', 300]]);
    const byProd = await run(db, a, 'sales', { group_by: ['product'], sort: 'product', desc: false });
    assert.deepEqual(byProd.rows.map((r) => [r.product, num(r.sales_value), num(r.sales_qty), num(r.bonus)]),
      [['A1 — صنف A1', 450, 9, 1], ['A2 — صنف A2', 250, 5, 0]]);
    const credit = await run(db, a, 'sales', { pay_type: 'فاتورة ذمم', kinds: ['invoice'] });
    assert.equal(num(credit.totals.sales_value), 200);
    const onlyA2 = await run(db, a, 'sales', { product_id: p.A2, group_by: ['customer'] });
    assert.deepEqual(onlyA2.rows.map((r) => r.customer).sort(), ['500 — عميل 500', '501 — عميل 501']);
    const r2 = await run(db, a, 'sales', { employees: [e.r2] });
    assert.equal(num(r2.totals.net_value), 300);
    const byMonth = await run(db, a, 'sales', { from: '2026-08-01', group_by: ['month'], sort: 'month', desc: false });
    assert.deepEqual(byMonth.rows.map((r) => r.month), ['2026-08', '2026-09']);
    assert.equal(byMonth.months.length, 2);
  } finally { await db.close(); }
});

test('UX-003: التقرير المخصص بأبعاد ومقاييس معتمدة فقط، والترتيب، والتحصيلات بلا صنف', async () => {
  const db = await connect();
  try {
    const { a } = await setup(db);
    const r = await run(db, a, 'custom', { dims: ['customer'], measures: ['net_value', 'collections', 'invoices'], sort: 'net_value', desc: true });
    assert.deepEqual(r.rows.map((x) => x.customer), ['502 — عميل 502', '501 — عميل 501', '500 — عميل 500']);
    assert.equal(num(r.rows.find((x) => x.customer === '501 — عميل 501').collections), 120);
    assert.equal(r.columns.map((c) => c.key).join(), 'customer,net_value,collections,invoices');
    assert.equal(r.summary.length, 3);
    await rejects(run(db, a, 'custom', { dims: ['customer'], measures: ['sum(total)'] }), 'غير معتمد');
    await rejects(run(db, a, 'custom', { dims: ['customer; drop table docs'], measures: ['net_value'] }), 'غير معتمد');
    await rejects(run(db, a, 'custom', { dims: ['customer'], measures: [] }), 'مقياسًا');
    const tot = await run(db, a, 'custom', { dims: [], measures: ['sales_value', 'avg_invoice'] });
    assert.deepEqual(tot.rows, []);
    assert.equal(num(tot.totals.avg_invoice), 175);
  } finally { await db.close(); }
});

test('B078 B081 B082: ملخص الإدارة بالمقارنة، والتحصيل والذمم، والمرتجعات بنسبتها للبيع', async () => {
  const db = await connect();
  try {
    const { a } = await setup(db);
    const m = await run(db, a, 'management', {});
    // الفترة السابقة بطول 30 يومًا: 2–31 أغسطس، وفيها فاتورة 10 أغسطس
    const net = m.rows.find((r) => r.metric === 'صافي المبيعات');
    assert.deepEqual([num(net.current), num(net.previous), num(net.change), num(net.pct)], [670, 80, 590, 737.5]);
    assert.equal(num(m.rows.find((r) => r.metric === 'التحصيلات').current), 120);
    assert.equal(num(m.summary.find((s) => s.label.startsWith('الذمم')).value), 80, 'ذمم 501: 200 − 120');
    const col = await run(db, a, 'collections', {});
    assert.equal(num(col.summary[0].value), 120);
    assert.deepEqual(col.rows.map((r) => [r.customer, num(r.open_total)]), [['501 — عميل 501', 80]]);
    assert.deepEqual(col.extra.rows.map((r) => [r.employee, num(r.collections)]), [['20 — مندوب أ', 120]]);
    const ret = await run(db, a, 'returns', {});
    assert.deepEqual(ret.rows.map((r) => [r.product, num(r.returns_value), num(r.sales_value), num(r.return_ratio)]), [['A1 — صنف A1', 30, 450, 6.67]]);
    const retCust = await run(db, a, 'returns', { group_by: ['customer'] });
    assert.equal(retCust.rows.length, 1, 'لا يظهر من لا مرتجع له');
  } finally { await db.close(); }
});

test('B083: الانتشار والمشترون، وغير المشترين لمجموعة معلومة فقط', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    // 503 مرتبط بالمندوب أ من فاتورة سابقة ولم يشترِ في سبتمبر
    await add(db, a, 'invoice', [{ cust: '503', date: '2026-07-01', lines: [['A1', 10, 0, 1]] }]);
    const all = await run(db, a, 'spread', {});
    assert.equal(all.rows.length, 3);
    assert.ok(all.notice);
    assert.equal(all.summary[1].value, null);
    const r1 = await run(db, a, 'spread', { employees: [e.r1] });
    assert.deepEqual(r1.rows.map((r) => [r.customer, r.status, r.invoices]),
      [['500 — عميل 500', 'مشترٍ', 2], ['501 — عميل 501', 'مشترٍ', 1], ['503 — عميل 503', 'غير مشترٍ', 0]]);
    assert.equal(r1.rows[2].last_date, '2026-07-01');
    assert.equal(r1.notice, null);
  } finally { await db.close(); }
});

test('B079 B084 B085: الأداء والعمولات من المحركات الرسمية، وجودة البيانات والتعديلات', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.r1, role: 'rep',
      tiers: [{ tier: 'A', logic: 'AND' }], components: [{ tier: 'A', metric: 'net_sales', target: 100 }] } });
    await db.rpc(a, 'save_commission_rule', { p_id: null, p: { month: '2026-09-01', name: 'عامة', tiers: [{ tier: 'A', rep_rate: 1 }, { tier: 'B' }, { tier: 'C' }, { tier: 'X' }], members: [e.r1] } });
    const perf = await run(db, a, 'performance', {});
    const p1 = perf.rows.find((r) => r.employee === '20 — مندوب أ');
    assert.equal(p1.achieved, 'A');
    assert.equal(num(p1.net_value), 370);
    assert.equal(p1.invoices, 3);
    const comm = await run(db, a, 'commissions', {});
    const c1 = comm.rows.find((r) => r.employee === '20 — مندوب أ');
    assert.equal(c1.tier, 'A');
    assert.ok(num(c1.final) > 0);
    // تعديل يدوي ثم تقرير الجودة: فواتير بلا موقع وتعديل واحد
    const [d] = await db.sql(`select id from docs where customer_number = '502' and kind = 'invoice'`);
    await db.rpc(a, 'transfer_docs', { p_doc_ids: [d.id], p_employee_number: '20', p_reason: 'تصحيح' });
    const today = (await db.sql('select app.today()::text t'))[0].t;
    const q = await db.rpc(a, 'report_run', { p_report: 'quality', p_opts: { from: '2026-09-01', to: today } });
    assert.equal(q.rows.find((r) => r.item === 'نقل سندات بين الموظفين').count, 1);
    assert.equal(q.extra.rows[0].reason, 'تصحيح');
    const q9 = await run(db, a, 'quality', {});
    assert.equal(q9.rows.find((r) => r.item === 'فواتير الفترة بلا موقع إصدار صالح').count, 4);
    assert.equal(q9.rows.find((r) => r.item === 'عملاء بلا موقع صالح').count, 3);
  } finally { await db.close(); }
});

test('الصلاحيات والنطاق والمحفوظ: التقارير لا توسع الصلاحيات، والإعدادات المحفوظة لصاحبها', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'تقارير', p_perms: [{ page: 'P18', action: 'view' }] });
    const u = await makeUser(db, a, { username: 'rep21', display_name: 'مندوب', data_scope: 'self', template_id: tpl, employee_id: e.r2 });
    const mine = await run(db, u, 'sales', {});
    assert.equal(num(mine.totals.net_value), 300, 'نطاق الذات');
    const asked = await run(db, u, 'sales', { employees: [e.r1] });
    assert.equal(num(asked.totals.sales_value), 0, 'طلب موظف خارج النطاق لا يوسعه');
    await rejects(run(db, u, 'commissions', {}), '');
    await rejects(run(db, u, 'collections', {}), '');
    await rejects(run(db, u, 'performance', {}), 'الأهداف أو العمولات');
    const m = await run(db, u, 'management', {});
    assert.equal(m.summary.find((s) => s.label.startsWith('الذمم')).value, null, 'الذمم تتطلب صلاحيتها');
    const none = await makeUser(db, a, { username: 'none', display_name: 'بلا', data_scope: 'all' });
    await rejects(run(db, none, 'sales', {}), '');
    await rejects(run(db, a, 'bogus', {}), 'غير معروف');
    await rejects(db.rpc(a, 'report_run', { p_report: 'sales', p_opts: { from: '2026-09-30', to: '2026-09-01' } }), 'فترة');
    // المحفوظ
    const id = await db.rpc(u, 'save_report', { p_id: null, p_name: 'مبيعاتي', p_report: 'sales', p_config: { group_by: ['product'] } });
    await rejects(db.rpc(u, 'save_report', { p_id: null, p_name: 'مبيعاتي', p_report: 'sales', p_config: {} }), 'بهذا الاسم');
    assert.equal((await db.as(u, 'select count(*)::int n from saved_reports'))[0].n, 1);
    assert.equal((await db.as(a, 'select count(*)::int n from saved_reports'))[0].n, 0, 'لا يرى محفوظات غيره');
    await rejects(db.rpc(a, 'delete_saved_report', { p_id: id }), 'غير موجود');
    await db.rpc(u, 'save_report', { p_id: id, p_name: 'مبيعاتي حسب الصنف', p_report: 'sales', p_config: { group_by: ['product'] } });
    await db.rpc(u, 'delete_saved_report', { p_id: id });
  } finally { await db.close(); }
});
