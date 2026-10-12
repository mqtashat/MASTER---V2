// الوحدة 3 — الحسابات والكشف: Ledger وFIFO وتصنيف المرتجعات والافتتاحيات والإغلاق السنوي والإشعارات والكشف والذمم
// حالات القبول: F01–F20، F24–F33، D27، وSTMT-001..010، FIN-001..008، RET-005، RET-010، B028–B045
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];

let rowNo = 2;
// [kind, number, customer, date, amount, extra]
const iso = (d) => d.split('/').reverse().join('-');
function rowsOf(kind, docs) {
  return docs.map(([num, cust, dmy, amount, o = {}]) => [num, cust, iso(dmy), amount, o]).map(([num, cust, date, amount, o]) => (kind === 'collection'
    ? { row: rowNo++, doc_number: num, customer_number: cust, doc_date: date, employee_number: o.emp ?? '20', amount: String(amount), pay_method: 'نقدي', cheque_no: '' }
    : { row: rowNo++, doc_number: num, customer_number: cust, doc_date: date, employee_number: o.emp ?? '20', pay_type: o.pay ?? 'فاتورة ذمم',
        item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' }));
}

async function add(db, a, kind, docs) {
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS;
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rowsOf(kind, docs) });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  const errs = its.flatMap((i) => i.errors);
  if (errs.length) { if (process.env.DBG) console.log(JSON.stringify(errs)); return { errors: errs, batch: s.batch_id }; }
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
  return { errors: [], batch: s.batch_id };
}
const inv = (db, a, docs) => add(db, a, 'invoice', docs);
const coll = (db, a, docs) => add(db, a, 'collection', docs);
const ret = (db, a, docs) => add(db, a, 'return', docs);

async function setup(db) {
  const a = await seedAdmin(db);
  await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2026-01-01' } });
  await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2026-01-01' } });
  const ids = {};
  for (const [num, master, grace] of [['500', null, null], ['501', null, '0'], ['600', null, null], ['601', '600', null], ['602', '600', null]]) {
    ids[num] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: num, name: 'عميل ' + num, master_number: master, grace_days: grace } });
  }
  const p = await db.rpc(a, 'save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
  await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: '1', p_date: '2026-01-01' });
  return { a, ids };
}

const stmt = (db, a, cust, family, from, to, opts = {}) =>
  db.rpc(a, 'account_statement', { p_customer: cust, p_family: family, p_from: from, p_to: to, p_opts: opts });
const recv = (db, a, date, opts = {}) => db.rpc(a, 'receivables', { p_date: date, p_opts: opts });
const num = (v) => (v === null || v === undefined ? v : Number(v));
const items = (r, cust) => r.debtors.find((d) => d.customer_number === cust)?.items ?? [];

test('F01/STMT-003: الافتتاحي ثم فاتورة وتحصيل ومرتجع: 600 ثم 400 ثم 350', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 500, p_credit: null });
    await inv(db, a, [['1', '500', '01/09/2026', 100]]);
    await coll(db, a, [['1', '500', '02/09/2026', 200]]);
    await ret(db, a, [['1', '500', '03/09/2026', 50]]);
    const s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s.official.prev), 500);
    assert.deepEqual(s.lines.map((l) => num(l.balance)), [600, 400, 350]);
    assert.equal(num(s.official.debit), 100);
    assert.equal(num(s.official.credit), 250);
    assert.equal(num(s.official.final), 350);
    assert.equal(s.lines[2].description, 'مرتجع ذمم');
    // الفترة من بداية السنة: الافتتاحي في السابق لا كحركة جديدة
    const s2 = await stmt(db, a, ids['500'], false, '2026-01-01', '2026-12-31');
    assert.equal(num(s2.official.prev), 500);
    assert.equal(num(s2.official.final), 350);
    // فتح الكشف لا يغير المصدر ويعطي النتيجة نفسها (STMT-001، F25)
    const s3 = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(s3.fingerprint, s.fingerprint);
  } finally { await db.close(); }
});

test('F02/B028: الفاتورة النقدية غير مؤثرة وتظهر للمراجعة؛ والفلتر لا يغير السابق والنهائي (F18/B041)', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '500', '01/09/2026', 100, { pay: 'فاتورة نقدي' }], ['2', '500', '02/09/2026', 70]]);
    await coll(db, a, [['5', '500', '03/09/2026', 20]]);
    const s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(s.lines.length, 3);
    const cash = s.lines.find((l) => l.number === '1');
    assert.equal(cash.affecting, false);
    assert.equal(cash.debit, null);
    assert.match(cash.description, /نقدي.*غير مؤثرة/);
    assert.equal(num(s.official.final), 50);
    const f = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30', { kinds: ['invoice'], affect: 'affecting' });
    assert.equal(f.filtered, true);
    assert.equal(f.lines.length, 1);
    assert.equal(num(f.results.debit), 70);
    assert.equal(num(f.official.final), 50);
    assert.equal(num(f.lines[0].balance), 70); // الرصيد الحقيقي في التسلسل الكامل
    const r = await recv(db, a, '2026-09-30');
    assert.equal(items(r, '500').length, 1);
    assert.equal(num(items(r, '500')[0].remaining), 50);
  } finally { await db.close(); }
});

test('F04/F05/F26/RET-005/STMT-009: تصنيف المرتجع بكامل قيمته واستعمال الرصيد الدائن لاحقًا', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '500', '01/09/2026', 20]]);
    await ret(db, a, [['1', '500', '02/09/2026', 50], ['2', '501', '02/09/2026', 50]]);
    await inv(db, a, [['2', '500', '05/09/2026', 100]]);
    const s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.deepEqual(s.lines.map((l) => num(l.balance)), [20, -30, 70]);
    const cls = await db.sql(`select r.class, r.prev_balance, d.customer_number from return_classes r join docs d on d.id = r.doc_id order by d.customer_number`);
    assert.deepEqual(cls.map((c) => [c.customer_number, c.class, num(c.prev_balance)]), [['500', 'credit', 20], ['501', 'cash', 0]]);
    const r = await recv(db, a, '2026-09-30');
    assert.equal(num(items(r, '500')[0].remaining), 70);
    assert.equal(num(items(r, '500')[0].paid), 30);
    assert.equal(r.creditors.length, 0);
    const s501 = await stmt(db, a, ids['501'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s501.official.final), 0);
    assert.match(s501.lines[0].description, /مرتجع نقدي/);
    // رصيد دائن قائم ثم مرتجع: نقدي، يبقى الرصيد
    const r2 = await recv(db, a, '2026-09-03');
    assert.equal(num(r2.creditors.find((c) => c.customer_number === '500').balance), -30);
  } finally { await db.close(); }
});

test('FIN-001: ترتيب اليوم الواحد يحسم تصنيف المرتجعات بالتتابع', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await ret(db, a, [['9', '500', '01/09/2026', 20]]);
    await coll(db, a, [['9', '500', '01/09/2026', 100]]);
    await inv(db, a, [['9', '500', '01/09/2026', 100]]);
    await inv(db, a, [['10', '501', '01/09/2026', 100]]);
    await coll(db, a, [['10', '501', '01/09/2026', 60]]);
    await ret(db, a, [['10', '501', '01/09/2026', 50]]);
    const s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-01');
    assert.deepEqual(s.lines.map((l) => l.kind), ['invoice', 'collection', 'return']);
    assert.equal(num(s.official.final), 0);
    assert.match(s.lines[2].description, /نقدي/);
    const s2 = await stmt(db, a, ids['501'], false, '2026-09-01', '2026-09-01');
    assert.deepEqual(s2.lines.map((l) => num(l.balance)), [100, 40, -10]);
  } finally { await db.close(); }
});

test('F06/F10/FIN-004/COL-008: الافتتاحي أولًا ثم الأقدم، والزائد دائن للديون اللاحقة', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 100, p_credit: null });
    await inv(db, a, [['1', '500', '01/09/2026', 80], ['2', '500', '02/09/2026', 120]]);
    await coll(db, a, [['1', '500', '03/09/2026', 150]]);
    let r = await recv(db, a, '2026-09-03');
    assert.deepEqual(items(r, '500').map((i) => [i.kind, num(i.remaining)]), [['invoice', 30], ['invoice', 120]]);
    const paid = items(r, '500')[0].paid_by;
    assert.equal(paid.length, 1); assert.equal(num(paid[0].amount), 50);
    // تحصيل زائد: الدين صفر و50 دائن تسدد الفاتورة اللاحقة
    await coll(db, a, [['2', '500', '04/09/2026', 200]]);
    r = await recv(db, a, '2026-09-04');
    assert.equal(items(r, '500').length, 0);
    assert.equal(num(r.creditors[0].balance), -50);
    await inv(db, a, [['3', '500', '06/09/2026', 70]]);
    r = await recv(db, a, '2026-09-06');
    assert.equal(num(items(r, '500')[0].remaining), 20);
    assert.equal(items(r, '500')[0].paid_by[0].number, '2');
    // الذمم في تاريخ سابق لا تتأثر بالحركات اللاحقة
    r = await recv(db, a, '2026-09-02');
    assert.deepEqual(items(r, '500').map((i) => [i.kind, num(i.remaining)]), [['open_debit', 100], ['invoice', 80], ['invoice', 120]]);
    assert.equal(items(r, '500')[0].age, null); // الافتتاحي بلا عمر مختلق (B039)
  } finally { await db.close(); }
});

test('F07/F11/B034: تحصيل الرئيسي على فواتير الفروع بالأقدم؛ كشف العائلة صف واحد وكشف الفرع نصيبه', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '601', '01/09/2026', 100], ['2', '602', '03/09/2026', 150], ['3', '601', '05/09/2026', 200]]);
    await coll(db, a, [['1', '600', '06/09/2026', 300]]);
    const r = await recv(db, a, '2026-09-30');
    assert.deepEqual(items(r, '601').map((i) => num(i.remaining)), [150]);
    assert.equal(items(r, '602').length, 0);
    const fam = await stmt(db, a, ids['601'], true, '2026-09-01', '2026-09-30');
    assert.equal(fam.customer.head.customer_number, '600');
    assert.equal(fam.lines.filter((l) => l.kind === 'collection').length, 1);
    assert.equal(num(fam.lines.find((l) => l.kind === 'collection').credit), 300);
    assert.equal(num(fam.official.final), 150);
    const b1 = await stmt(db, a, ids['601'], false, '2026-09-01', '2026-09-30');
    const share = b1.lines.find((l) => l.kind === 'collection');
    assert.equal(num(share.credit), 150);
    assert.match(share.description, /حصة الحساب/);
    assert.equal(num(b1.official.final), 150);
    const b2 = await stmt(db, a, ids['602'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(b2.official.final), 0);
    const m = await stmt(db, a, ids['600'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(m.official.final), 0);
    assert.equal(m.lines[0].credit, null);
    assert.match(m.lines[0].description, /حصة الحساب.*خُصص الباقي/);
  } finally { await db.close(); }
});

test('F08/F09/F12/B031: سياسة الفرع «الفرع فقط» افتراضيًا و«جميع الفروع» من تاريخ', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '602', '01/09/2026', 100], ['2', '601', '02/09/2026', 100]]);
    await coll(db, a, [['1', '601', '03/09/2026', 50]]);
    let r = await recv(db, a, '2026-09-30');
    assert.equal(num(items(r, '601')[0].remaining), 50);
    assert.equal(num(items(r, '602')[0].remaining), 100);
    await db.rpc(a, 'set_alloc_policy', { p_customer: ids['601'], p_valid_from: '2026-01-01', p_branch_mode: 'family', p_include_master: true });
    r = await recv(db, a, '2026-09-30');
    assert.equal(num(items(r, '601')[0].remaining), 100);
    assert.equal(num(items(r, '602')[0].remaining), 50);
    // السنة المغلقة لا تتغير سياستها
    await db.sql(`insert into year_closes (year) values (2026)`);
    await rejects(db.rpc(a, 'set_alloc_policy', { p_customer: ids['601'], p_valid_from: '2026-06-01', p_branch_mode: 'branch', p_include_master: true }), 'مغلقة');
  } finally { await db.close(); }
});

test('F30/ALLOC-002: ديون الرئيسي تدخل التوزيع افتراضيًا، ويمكن استبعادها', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '600', '01/09/2026', 100], ['2', '601', '03/09/2026', 150]]);
    await coll(db, a, [['1', '600', '05/09/2026', 200]]);
    let r = await recv(db, a, '2026-09-30');
    assert.equal(items(r, '600').length, 0);
    assert.equal(num(items(r, '601')[0].remaining), 50);
    await db.rpc(a, 'set_alloc_policy', { p_customer: ids['600'], p_valid_from: '2026-01-01', p_branch_mode: 'branch', p_include_master: false });
    r = await recv(db, a, '2026-09-30');
    assert.equal(num(items(r, '600')[0].remaining), 100);
    assert.equal(items(r, '601').length, 0);
    // الباقي 50 رصيد دائن للرئيسي لا يسدد دينه بحسب السياسة
    const m = await stmt(db, a, ids['600'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(m.official.final), 50);
  } finally { await db.close(); }
});

test('F27/F28/FIN-005: تحصيل العائلة يقسم على الافتتاحيات بالتساوي ثم الأقدم', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'set_alloc_policy', { p_customer: ids['600'], p_valid_from: '2026-01-01', p_branch_mode: 'branch', p_include_master: false });
    await db.rpc(a, 'save_opening', { p_customer: ids['601'], p_year: 2026, p_debit: 100, p_credit: null });
    await db.rpc(a, 'save_opening', { p_customer: ids['602'], p_year: 2026, p_debit: 100, p_credit: null });
    await inv(db, a, [['1', '601', '01/02/2026', 300], ['2', '602', '01/03/2026', 500]]);
    await coll(db, a, [['1', '600', '01/04/2026', 400]]);
    let r = await recv(db, a, '2026-04-30');
    assert.deepEqual(items(r, '601').map((i) => [i.kind, num(i.remaining)]), [['invoice', 100]]);
    assert.deepEqual(items(r, '602').map((i) => [i.kind, num(i.remaining)]), [['invoice', 500]]);
    // F28: افتتاحي الرئيسي 300 والفرع 100، تحصيل 400 → 200 لكل، وفائض الفرع يعاد للرئيسي
    await db.rpc(a, 'set_alloc_policy', { p_customer: ids['600'], p_valid_from: '2026-01-01', p_branch_mode: 'branch', p_include_master: true });
    await db.rpc(a, 'save_opening', { p_customer: ids['600'], p_year: 2026, p_debit: 300, p_credit: null });
    await db.rpc(a, 'save_opening', { p_customer: ids['602'], p_year: 2026, p_debit: 0, p_credit: 0 });
    for (const d of await db.sql(`select id from docs`)) await db.rpc(a, 'delete_doc', { p_doc: d.id, p_reason: 'إعادة المثال' });
    await coll(db, a, [['2', '600', '01/04/2026', 400]]);
    r = await recv(db, a, '2026-04-30');
    assert.equal(items(r, '600').length, 0);
    assert.equal(items(r, '601').length, 0);
    const alloc = await db.sql(`select debt_account, amount from app.ledger_allocs where year = 2026 order by debt_account`);
    assert.deepEqual(alloc.map((x) => num(x.amount)), [300, 100]);
  } finally { await db.close(); }
});

test('F29/F17/B036/FIN-007: الإشعارات: المدين يزيد والدائن يخصص كالتحصيل', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 100, p_credit: null });
    await inv(db, a, [['1', '500', '01/09/2026', 200]]);
    const cn = await db.rpc(a, 'save_note', { p_id: null, p: { kind: 'credit', customer_number: '500', note_date: '2026-09-02', amount: '150', reason: 'خصم' } });
    let r = await recv(db, a, '2026-09-30');
    assert.deepEqual(items(r, '500').map((i) => [i.kind, num(i.remaining)]), [['invoice', 150]]);
    const dn = await db.rpc(a, 'save_note', { p_id: null, p: { kind: 'debit', customer_number: '500', note_date: '2026-09-03', amount: '40', reason: 'فرق سعر' } });
    const s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s.official.final), 190);
    assert.deepEqual(s.lines.map((l) => l.kind), ['invoice', 'credit_note', 'debit_note']);
    const notes = await db.rpc(a, 'notes_list', { p_filters: {} });
    assert.deepEqual(notes.map((n) => n.note_number).sort(), ['CN-0001', 'DN-0001']);
    // لا يدخل المبيعات: السندات لم تتغير
    assert.equal((await db.sql(`select count(*)::int n from docs`))[0].n, 1);
    await rejects(db.rpc(a, 'save_note', { p_id: null, p: { kind: 'debit', customer_number: '500', note_date: '2026-09-03', amount: '0', reason: 'x' } }), 'أكبر من صفر');
    await rejects(db.rpc(a, 'save_note', { p_id: null, p: { kind: 'debit', customer_number: '500', note_date: '2026-09-03', amount: '5', reason: '' } }), 'سبب الإشعار');
    await db.rpc(a, 'delete_note', { p_id: dn, p_reason: 'خطأ' });
    await db.rpc(a, 'save_note', { p_id: cn, p: { customer_number: '500', note_date: '2026-09-02', amount: '50', reason: 'خصم معدل' } });
    const s2 = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30', { show_deleted: true });
    assert.equal(num(s2.official.final), 250);
    assert.ok(s2.lines.some((l) => l.deleted && l.kind === 'debit_note'));
    // شهر مقفل: للإدارة برمزها
    await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'sirr-2026' });
    await db.sql(`insert into months (month, status) values ('2026-09-01', 'closed')`);
    await rejects(db.rpc(a, 'save_note', { p_id: null, p: { kind: 'debit', customer_number: '500', note_date: '2026-09-05', amount: '5', reason: 'x' } }), 'شهرًا مقفلًا');
  } finally { await db.close(); }
});

test('F19/F20/F31/B042/STMT-010: الكشف المخصص: الإخفاء داخل الفترة وقبلها، وهوية مستقرة بعد التعديل', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 400, p_credit: null });
    await coll(db, a, [['0', '500', '15/08/2026', 100]]);
    await inv(db, a, [['1', '500', '01/09/2026', 100]]);
    await coll(db, a, [['1', '500', '02/09/2026', 200]]);
    await ret(db, a, [['1', '500', '03/09/2026', 50]]);
    const off = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(off.official.prev), 300);
    assert.equal(num(off.official.final), 150);
    const colKey = off.lines.find((l) => l.kind === 'collection').key;
    const c1 = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30', { custom: true, hidden: [colKey] });
    assert.deepEqual([c1.custom_totals.prev, c1.custom_totals.debit, c1.custom_totals.credit, c1.custom_totals.final].map(num), [300, 100, 50, 350]);
    assert.equal(num(c1.official.final), 150);
    const augKey = (await stmt(db, a, ids['500'], false, '2026-08-01', '2026-08-31')).lines[0].key;
    const c2 = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30', { custom: true, hidden: [colKey, augKey] });
    assert.equal(num(c2.custom_totals.prev), 400);
    assert.equal(num(c2.custom_totals.final), 450);
    // حفظ الكشف ثم تعديل السند المخفي: الهوية والإخفاء باقيان والبصمة تتغير (B043، B044)
    const sid = await db.rpc(a, 'save_statement', { p_id: null, p: { name: 'كشف نهائي', customer_id: ids['500'], date_from: '2026-09-01', date_to: '2026-09-30', custom: true, hidden: [colKey], options: { custom: true, hidden: [colKey] } } });
    const [saved] = await db.sql('select * from saved_statements where id = $1', [sid]);
    const docId = Number(colKey.split(':')[1]);
    const d = (await db.rpc(a, 'doc_history', { p_doc: docId }));
    assert.ok(d);
    await db.rpc(a, 'save_doc', { p_doc: docId, p_data: { doc_number: '1A', customer_number: '500', doc_date: '2026-09-02', employee_number: '20', lines: [{ row: 1, amount: '200', pay_method: 'نقدي' }] } });
    const after = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30', { custom: true, hidden: saved.hidden });
    const ln = after.lines.find((l) => l.key === colKey);
    assert.equal(ln.number, '1A');
    assert.equal(ln.hidden, true);
    assert.notEqual(after.fingerprint, saved.fingerprint);
    // الإخفاء في كشف العائلة لا يمتد لكشف الفرع (STMT-010): كل كشف بقائمته
    await inv(db, a, [['7', '601', '01/09/2026', 30]]);
    const fam = await stmt(db, a, ids['601'], true, '2026-09-01', '2026-09-30', { custom: true, hidden: ['doc:x'] });
    const k = fam.lines[0].key;
    const fam2 = await stmt(db, a, ids['601'], true, '2026-09-01', '2026-09-30', { custom: true, hidden: [k] });
    assert.equal(fam2.lines[0].hidden, true);
    const br = await stmt(db, a, ids['601'], false, '2026-09-01', '2026-09-30', { custom: true, hidden: [] });
    assert.equal(br.lines[0].hidden, false);
  } finally { await db.close(); }
});

test('STMT-009: رصيد دائن للرئيسي يسدد فاتورة فرع لاحقة بصف تسوية في الكشفين', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await coll(db, a, [['1', '600', '01/09/2026', 200]]);
    await inv(db, a, [['1', '601', '05/09/2026', 100]]);
    const b = await stmt(db, a, ids['601'], false, '2026-09-01', '2026-09-30');
    assert.deepEqual(b.lines.map((l) => [l.kind, num(l.debit), num(l.credit), num(l.balance)]),
      [['invoice', 100, null, 100], ['transfer', null, 100, 0]]);
    const m = await stmt(db, a, ids['600'], false, '2026-09-01', '2026-09-30');
    assert.deepEqual(m.lines.map((l) => num(l.balance)), [-200, -100]);
    const f = await stmt(db, a, ids['600'], true, '2026-09-01', '2026-09-30');
    assert.equal(f.lines.length, 2);
    assert.equal(num(f.official.final), -100);
    // قبل الفاتورة: الفرع صفر والرئيسي 200 دائن
    const r = await recv(db, a, '2026-09-03');
    assert.equal(num(r.creditors.find((c) => c.customer_number === '600').balance), -200);
  } finally { await db.close(); }
});

test('F16/B035: تعديل قديم يغير تصنيف مرتجع لاحق: يعرض للمراجعة ولا يطبق بصمت', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '500', '01/09/2026', 100]]);
    await ret(db, a, [['1', '500', '05/09/2026', 50]]);
    let s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s.official.final), 50);
    const [invDoc] = await db.sql(`select id from docs where kind = 'invoice'`);
    await db.rpc(a, 'delete_doc', { p_doc: invDoc.id, p_reason: 'خطأ' });
    const rv = await db.rpc(a, 'return_reviews', {});
    assert.equal(rv.length, 1);
    assert.deepEqual([rv[0].current, rv[0].proposed, num(rv[0].prev_balance)], ['credit', 'cash', 0]);
    s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s.official.final), -50); // التصنيف المعتمد باقٍ حتى المراجعة
    assert.equal(await db.rpc(a, 'approve_return_reclass', { p_doc_ids: [rv[0].doc_id] }), 1);
    s = await stmt(db, a, ids['500'], false, '2026-09-01', '2026-09-30');
    assert.equal(num(s.official.final), 0);
    assert.equal((await db.rpc(a, 'return_reviews', {})).length, 0);
    const [log] = await db.sql(`select * from audit_log where entity = 'return_classes'`);
    assert.equal(log.after.class, 'cash');
  } finally { await db.close(); }
});

test('D27/RET-010: مرتجع رصيده السابق غير معلوم يعلق حتى يعرف الرصيد', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    const r1 = await ret(db, a, [['1', '500', '05/01/2027', 50]]);
    assert.ok(r1.errors.some((e) => e.message.includes('RET-010')));
    // فرع: يكفي افتتاحه؛ رئيسي: يلزم افتتاح عائلته كلها
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2027, p_debit: 80, p_credit: null });
    await db.rpc(a, 'upload_recheck', { p_batch: r1.batch });
    const [it] = await db.sql('select errors from batch_items where batch_id = $1', [r1.batch]);
    assert.equal(it.errors.length, 0);
    await db.rpc(a, 'save_opening', { p_customer: ids['600'], p_year: 2027, p_debit: 0, p_credit: 0 });
    const r2 = await ret(db, a, [['2', '600', '05/01/2027', 10]]);
    assert.ok(r2.errors.some((e) => e.message.includes('RET-010')));
    // سنة البدء 2026 صفر معتمد: لا تعليق
    const r3 = await ret(db, a, [['3', '600', '05/01/2026', 10]]);
    assert.equal(r3.errors.length, 0);
    // إغلاق 2026 يجعل افتتاح 2027 معلومًا
    await db.rpc(a, 'commit_year_close', { p_year: 2026, p_replace: [] });
    const r4 = await ret(db, a, [['2', '600', '05/01/2027', 10]]);
    assert.equal(r4.errors.length, 0);
  } finally { await db.close(); }
});

test('F13/B038/B040: الإغلاق السنوي يرحل الإقفال ولا يجمع القديم مرتين', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '500', '01/06/2026', 500], ['2', '501', '01/06/2026', 90]]);
    await db.rpc(a, 'save_opening', { p_customer: ids['501'], p_year: 2027, p_debit: 100, p_credit: null });
    const p = await db.rpc(a, 'preview_year_close', { p_year: 2026 });
    const row = (n) => p.rows.find((r) => r.customer_number === n);
    assert.equal(num(row('500').closing), 500);
    assert.equal(num(row('501').diff), 10);
    await rejects(db.rpc(a, 'commit_year_close', { p_year: 2026, p_replace: ['501'] }), 'سببًا');
    const res = await db.rpc(a, 'commit_year_close', { p_year: 2026, p_replace: [] });
    assert.deepEqual([res.added, res.kept], [1, 1]);
    const ob = await db.sql(`select c.customer_number, o.debit, o.source from opening_balances o join customers c on c.id = o.customer_id where year = 2027 order by 1`);
    assert.deepEqual(ob.map((o) => [o.customer_number, num(o.debit), o.source]), [['500', 500, 'carry'], ['501', 100, 'manual']]);
    await inv(db, a, [['3', '500', '10/01/2027', 20]]);
    const s = await stmt(db, a, ids['500'], false, '2026-01-01', '2027-12-31');
    assert.equal(num(s.official.final), 520);
    const open = s.lines.find((l) => l.kind === 'opening');
    assert.equal(num(open.debit), null); assert.equal(num(open.credit), null);
    const s501 = await stmt(db, a, ids['501'], false, '2026-01-01', '2027-12-31');
    assert.equal(num(s501.official.final), 100);
    assert.equal(num(s501.lines.find((l) => l.kind === 'opening').debit), 10);
    const s27 = await stmt(db, a, ids['500'], false, '2027-01-01', '2027-12-31');
    assert.equal(num(s27.official.prev), 500);
    // تعديل افتتاح سنة سابقة يعرض أثره على التالية دون إعادة كتابتها (B040)
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 50, p_credit: null });
    const ov = await db.rpc(a, 'openings_overview', { p_year: 2027 });
    const o500 = ov.rows.find((r) => r.customer_number === '500');
    assert.equal(num(o500.debit), 500);
    assert.equal(num(o500.prev_closing), 550);
  } finally { await db.close(); }
});

test('F14/F32/F33/FIN-003/FIN-006/FIN-008: استيراد الافتتاحيات ومعاينته وحماية اليدوي وحذف الدفعة', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await db.rpc(a, 'save_opening', { p_customer: ids['501'], p_year: 2027, p_debit: 70, p_credit: null });
    await db.rpc(a, 'save_opening', { p_customer: ids['600'], p_year: 2027, p_debit: 0, p_credit: 30 });
    await db.sql(`update opening_balances set source = 'import' where customer_id = $1`, [ids['600']]);
    const rows = [
      { row: 2, customer_number: '500', debit: '500', credit: '' },
      { row: 3, customer_number: '501', debit: '90', credit: '0' },
      { row: 4, customer_number: '600', debit: '0', credit: '' },
      { row: 5, customer_number: '601', debit: '', credit: '' },
      { row: 6, customer_number: '602', debit: '5', credit: '5' },
      { row: 7, customer_number: '999', debit: '1', credit: '' },
      { row: 8, customer_number: '602', debit: '-1', credit: '' },
    ];
    const pv = await db.rpc(a, 'preview_opening_import', { p_year: 2027, p_rows: rows });
    assert.deepEqual(pv.rows.map((r) => r.status), ['new', 'manual_conflict', 'changed', 'blank', 'error', 'error', 'error']);
    assert.match(pv.rows[0].note, /صفرًا/);
    const res = await db.rpc(a, 'commit_opening_import', { p_year: 2027, p_rows: rows, p_accept: ['600'], p_file_name: 'افتتاحيات 2027.xlsx' });
    assert.deepEqual([res.added, res.replaced, res.kept, res.blank, res.errors], [1, 1, 1, 1, 3]);
    const ob = async () => Object.fromEntries((await db.sql(`select c.customer_number n, o.debit, o.credit from opening_balances o join customers c on c.id = o.customer_id where year = 2027`)).map((o) => [o.n, [num(o.debit), num(o.credit)]]));
    assert.deepEqual(await ob(), { 500: [500, 0], 501: [70, 0], 600: [0, 0] });
    // تعديل لاحق لأحد صفوف الدفعة يبقى عند حذفها
    await db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2027, p_debit: 450, p_credit: 0 });
    const pd = await db.rpc(a, 'preview_delete_opening_batch', { p_batch: res.batch_id });
    assert.deepEqual(pd.items.map((i) => [i.customer_number, i.conflict]), [['500', true], ['600', false]]);
    const dl = await db.rpc(a, 'delete_opening_batch', { p_batch: res.batch_id, p_reason: 'ملف خاطئ' });
    assert.deepEqual([dl.reverted, dl.kept], [1, 1]);
    assert.deepEqual(await ob(), { 500: [450, 0], 501: [70, 0], 600: [0, 30] });
    // الفردي: الخانتان الفارغتان لا تصفران، والجهتان الموجبتان مرفوضتان
    await rejects(db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2027, p_debit: null, p_credit: null }), 'صفرًا صريحًا');
    await rejects(db.rpc(a, 'save_opening', { p_customer: ids['500'], p_year: 2027, p_debit: 1, p_credit: 1 }), 'معًا');
    const log = await db.sql(`select * from audit_log where entity = 'opening_balances' and entity_id = $1 order by id`, [`${ids['500']}:2027`]);
    assert.deepEqual(log.map((l) => l.action), ['import', 'update']);
  } finally { await db.close(); }
});

test('F15/B037: الاستحقاق = التاريخ + السماح، والمتأخر في الذمم', async () => {
  const db = await connect();
  try {
    const { a } = await setup(db);
    await inv(db, a, [['1', '501', '10/12/2026', 10], ['2', '500', '10/12/2026', 10]]);
    const r = await recv(db, a, '2026-12-31');
    assert.equal(items(r, '501')[0].due, '2026-12-10');
    assert.equal(items(r, '501')[0].overdue, true);
    assert.equal(items(r, '500')[0].due, '2027-01-09');
    assert.equal(items(r, '500')[0].overdue, false);
    assert.equal(num(r.summary.overdue), 10);
    assert.equal(num(r.summary.remaining), 20);
  } finally { await db.close(); }
});

test('الصلاحيات والنطاق: الكشف والذمم والافتتاحيات والإشعارات', async () => {
  const db = await connect();
  try {
    const { a, ids } = await setup(db);
    await inv(db, a, [['1', '500', '01/09/2026', 10, { emp: '20' }], ['2', '501', '01/09/2026', 10, { emp: '21' }]]);
    const [e20] = await db.sql(`select id from employees where emp_number = '20'`);
    const [t] = await db.sql(`insert into permission_templates (name) values ('حسابات') returning id`);
    await db.sql(`insert into template_permissions (template_id, page_code, action) values ($1, 'P07', 'view'), ($1, 'P08', 'view'), ($1, 'P08a', 'view'), ($1, 'P09', 'view')`, [t.id]);
    const u = await makeUser(db, a, { username: 'rep20', display_name: 'مندوب', employee_id: e20.id, data_scope: 'self', template_id: t.id });
    await stmt(db, u, ids['500'], false, '2026-09-01', '2026-09-30');
    await rejects(stmt(db, u, ids['501'], false, '2026-09-01', '2026-09-30'), 'خارج نطاق');
    const r = await recv(db, u, '2026-09-30');
    assert.deepEqual(r.debtors.map((d) => d.customer_number), ['500']);
    await rejects(db.rpc(u, 'save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 1, p_credit: null }), 'لا تملك صلاحية');
    await rejects(db.rpc(u, 'save_note', { p_id: null, p: { kind: 'debit', customer_number: '500', note_date: '2026-09-03', amount: '5', reason: 'x' } }), 'لا تملك صلاحية');
    await rejects(db.rpc(u, 'commit_year_close', { p_year: 2026, p_replace: [] }), 'لا تملك صلاحية');
    // لا وصول مباشر لناتج المحرك
    await rejects(db.as(u, 'select * from app.ledger_items'), 'permission denied');
  } finally { await db.close(); }
});
