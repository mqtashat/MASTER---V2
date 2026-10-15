// تدقيق 15/10/2026 — A2 (PERIOD-001، B076، B077): الشهر المغلق يُقرأ من نسخته الحالية، ولا حساب حي لمن ليس فيها،
// والفروقات تشمله. A1 (COMM-008 البندان 5 و6): ذمة مندوب التحصيل غير المسددة آخر السنة تستحق عمولتها عند سدادها في السنة التالية.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;

async function upload(db, a, kind, rows, code = null) {
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: kind === 'collection' ? COL_COLS : INV_COLS,
    p_rows: rows.map((r) => (kind === 'collection'
      ? { row: rowNo++, doc_number: r.n, customer_number: r.cust, doc_date: r.date, employee_number: r.emp, amount: String(r.amount), pay_method: 'نقدي', cheque_no: '' }
      : { row: rowNo++, doc_number: r.n, customer_number: r.cust, doc_date: r.date, employee_number: r.emp, pay_type: r.pay ?? 'فاتورة ذمم',
          item_number: 'A1', item_name: 'صنف', net_sales: String(r.amount), net_promotions: '0', quantity: '1', bonus: '0' })) });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1', [s.batch_id]);
  assert.deepEqual(its.flatMap((i) => i.errors), []);
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })), p_code: code });
}

async function base(db) {
  const a = await seedAdmin(db);
  await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'Sec#2026' });
  const e = {};
  e.s1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.s1 } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01', supervisor_id: e.s1 } });
  const c = {};
  for (const n of ['500', '501']) c[n] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name: 'عميل ' + n } });
  const p = await db.rpc(a, 'save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
  await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
  return { a, e, c };
}
const rule = (db, a, month, members, rate) => db.rpc(a, 'save_commission_rule', { p_id: null, p: { month, name: 'قاعدة ' + month, members,
  tiers: [{ tier: 'A', rep_rate: rate, sup_rate: rate }] } });
const planA = (db, a, month, emp, target) => db.rpc(a, 'save_goal_plan', { p_id: null, p: { month, employee_id: emp, role: 'rep',
  tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target }] } });

test('A2 PERIOD-001/B077: بعد إعادة الفتح والإغلاق الثاني يُقرأ الشهر من النسخة 2 وحدها، ومن ليس فيها لا يُحسب حيًّا ويظهر في الفروقات', async () => {
  const db = await connect();
  try {
    const { a, e } = await base(db);
    const M = '2026-09-01';
    await upload(db, a, 'invoice', [{ n: '1', cust: '500', date: '2026-09-05', emp: '20', amount: 1000 }, { n: '2', cust: '501', date: '2026-09-06', emp: '21', amount: 500 }]);
    await planA(db, a, M, e.r1, 100);
    await planA(db, a, M, e.r2, 100);
    const rid = await rule(db, a, M, [e.s1, e.r1, e.r2], 1);
    assert.equal(await db.rpc(a, 'close_month', { p_month: M, p_note: 'أولى' }), 1);
    let sum = await db.rpc(a, 'commission_summary', { p_month: M });
    assert.ok(sum.rows.some((r) => String(r.employee_id) === String(e.r2)));

    // إعادة الفتح، ونقل سند المندوب ب إلى أ، وحذف خطته وإخراجه من القاعدة، ثم إغلاق ثانٍ لا يشمل ب
    await db.rpc(a, 'reopen_month', { p_month: M, p_reason: 'تصحيح الإسناد', p_code: 'Sec#2026' });
    const d2 = (await db.sql(`select id from docs where doc_number = '2'`))[0].id;
    await db.rpc(a, 'transfer_docs', { p_doc_ids: [d2], p_employee_number: '20', p_reason: 'إسناد خاطئ' });
    const pb = (await db.sql('select id from goal_plans where employee_id = $1', [e.r2]))[0].id;
    await db.rpc(a, 'delete_goal_plan', { p_id: pb, p_reason: 'لا خطة' });
    await db.rpc(a, 'save_commission_rule', { p_id: rid, p_reason: 'إخراج ب', p: { name: 'قاعدة', members: [e.s1, e.r1], tiers: [{ tier: 'A', rep_rate: 1, sup_rate: 1 }] } });
    assert.equal(await db.rpc(a, 'close_month', { p_month: M, p_note: 'ثانية' }), 2);

    sum = await db.rpc(a, 'commission_summary', { p_month: M });
    assert.deepEqual(sum.rows.map((r) => String(r.employee_id)).sort(), [String(e.s1), String(e.r1)].sort());
    assert.equal(num(sum.rows.find((r) => String(r.employee_id) === String(e.r1)).eligible), 1500);
    // لا كشف حي لموظف ليس في النسخة الحالية؛ نسخته السابقة تبقى بطلبها صراحة
    await rejects(db.rpc(a, 'commission_statement', { p_employee: e.r2, p_month: M }), 'غير مشمول في النسخة المعتمدة رقم 2');
    assert.equal(num((await db.rpc(a, 'commission_statement', { p_employee: e.r2, p_month: M, p_version: 1 })).eligible), 500);
    const cards = await db.rpc(a, 'performance_cards', { p_month: M, p_opts: { role: 'all' } });
    assert.ok(!cards.cards.some((c) => String(c.employee.id) === String(e.r2)), 'بطاقة ب من النسخة 1 لا تظهر');
    const goals = await db.rpc(a, 'goals_list', { p_month: M, p_role: 'rep' });
    assert.equal(goals.rows.find((g) => String(g.employee_id) === String(e.r1)).achieved, 'A');

    // حركة جديدة لـ ب بعد الإغلاق برمز الإدارة: تظهر في الفروقات بلا نسخة محفوظة (B077)
    await upload(db, a, 'invoice', [{ n: '3', cust: '501', date: '2026-09-10', emp: '21', amount: 300 }], 'Sec#2026');
    const diff = await db.rpc(a, 'month_diff', { p_month: M });
    assert.equal(diff.version, 2);
    const rowB = diff.rows.find((r) => String(r.employee_id) === String(e.r2));
    assert.equal(rowB.saved, null);
    assert.equal(num(rowB.live.eligible), 300);
  } finally { await db.close(); }
});

test('A1 COMM-008: فاتورة ذمم 20/12 لمندوب تحصيل تُسدَّد 10/1 بعد إغلاق السنة ← عمولتها في كانون الثاني بشريحة كانون الأول ونسبة قاعدته', async () => {
  const db = await connect();
  try {
    const { a, e, c } = await base(db);
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-12-01', p_on: true });
    // للعميل مندوب تحصيل افتتاحي آخر: لا يأخذ تسديد فاتورة مرحّلة (البند 9 للافتتاحي الفعلي فقط)
    await db.rpc(a, 'set_opening_rep', { p_customer: c['500'], p_employee: e.r2, p_from: '2026-01-01' });
    await db.rpc(a, 'save_opening', { p_customer: c['500'], p_year: 2026, p_debit: 200, p_credit: null });
    await upload(db, a, 'invoice', [{ n: '9', cust: '500', date: '2026-12-20', emp: '20', amount: 1000 }]);
    await planA(db, a, '2026-12-01', e.r1, 500);        // كانون الأول: الشريحة A
    await planA(db, a, '2027-01-01', e.r1, 100000);     // كانون الثاني: لا شريحة
    await rule(db, a, '2026-12-01', [e.r1, e.r2], 2);
    await rule(db, a, '2027-01-01', [e.r1, e.r2], 5);
    // تحصيل 400 في 15/12 يسدد الافتتاحي 200 ثم 200 من الفاتورة؛ يبقى 800 مرحّلة
    await upload(db, a, 'collection', [{ n: 'C1', cust: '500', date: '2026-12-15', emp: '20', amount: 400 }]);
    await db.rpc(a, 'commit_year_close', { p_year: 2026, p_replace: [] });
    assert.equal((await db.sql(`select source, debit::text from opening_balances where customer_id = $1 and year = 2027`, [c['500']]))[0].debit, '800');

    // كانون الثاني: تحصيل 1000 يسدد المرحّل 800 (كله من الفاتورة 9) ويبقى 200 رصيدًا دائنًا
    await upload(db, a, 'collection', [{ n: 'C2', cust: '500', date: '2027-01-10', emp: '20', amount: 1000 }]);
    const s = await db.rpc(a, 'commission_statement', { p_employee: e.r1, p_month: '2027-01-01' });
    assert.deepEqual(s.paid.map((x) => [x.number, num(x.paid), x.tier]), [['9', 800, 'A']]);
    assert.equal(num(s.base_commission), 16);          // 800 × 2% بنسبة قاعدة كانون الأول وشريحته
    assert.deepEqual(s.deferred, []);
    const op = await db.rpc(a, 'commission_statement', { p_employee: e.r2, p_month: '2027-01-01' });
    assert.equal(op.paid.length, 0, 'لا تحصيل افتتاحي لمندوب الافتتاحي من فاتورة مرحّلة');

    // كانون الأول نفسه: المسدد 200 من الفاتورة، والمؤجل 800
    const dec = await db.rpc(a, 'commission_statement', { p_employee: e.r1, p_month: '2026-12-01' });
    assert.deepEqual(dec.paid.map((x) => [x.number, num(x.paid)]), [['9', 200]]);
    assert.deepEqual(dec.deferred.map((x) => [x.number, num(x.remaining)]), [['9', 800]]);
    // الذمم والرصيد لا يتغيران: الرصيد الدائن 200
    const r = await db.rpc(a, 'receivables', { p_date: '2027-12-31', p_opts: {} });
    assert.equal(num(r.creditors.find((x) => x.customer_number === '500').balance), -200);
  } finally { await db.close(); }
});

test('A1: افتتاحي فعلي (غير مرحّل) يبقى تحصيله لمندوب الافتتاحي', async () => {
  const db = await connect();
  try {
    const { a, e, c } = await base(db);
    await db.rpc(a, 'set_opening_rep', { p_customer: c['500'], p_employee: e.r2, p_from: '2027-01-01' });
    await db.rpc(a, 'save_opening', { p_customer: c['500'], p_year: 2027, p_debit: 300, p_credit: null });
    await rule(db, a, '2027-01-01', [e.r1, e.r2], 5);
    await planA(db, a, '2027-01-01', e.r2, 1);
    await upload(db, a, 'collection', [{ n: 'C1', cust: '500', date: '2027-01-10', emp: '20', amount: 300 }]);
    const op = await db.rpc(a, 'commission_statement', { p_employee: e.r2, p_month: '2027-01-01' });
    assert.equal(op.paid.reduce((t, x) => t + num(x.paid), 0), 300);
  } finally { await db.close(); }
});
