// B092 — اختبار مالي متكامل بنتائج متوقعة على حساب واحد عبر سلسلة عمليات:
// افتتاحي، فواتير، تحصيل موزع، مرتجع يتجاوز الدين، رصيد دائن يسدد لاحقًا، تعديل تاريخ، نقل مندوب،
// إعادة رفع، تصحيح شهر مقفل برمز الإدارة، وحذف دفعة. بعد كل خطوة تُطابق: الكشف الرسمي، والذمم،
// ورصيد السنة من محرك الحسابات (Ledger)، والبنود المفتوحة.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
const num = (v) => (v === null || v === undefined ? v : Number(v));

let rowNo = 2;
const line = (kind, n, date, amount, emp = '20') => (kind === 'collection'
  ? { row: rowNo++, doc_number: n, customer_number: '500', doc_date: date, employee_number: emp, amount: String(amount), pay_method: 'نقدي', cheque_no: '' }
  : { row: rowNo++, doc_number: n, customer_number: '500', doc_date: date, employee_number: emp, pay_type: 'فاتورة ذمم',
      item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' });

async function upload(db, a, kind, rows, decide = () => 'approve', code = null) {
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS;
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: kind + '.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rows });
  const its = await db.sql('select id, class, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  assert.deepEqual(its.flatMap((i) => i.errors), [], 'لا أخطاء في الدفعة');
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: decide(i.class) })), p_code: code });
  return { batch: s.batch_id, classes: its.map((i) => i.class) };
}

test('B092: سلسلة مالية متكاملة تتطابق فيها السندات والـLedger والرصيد والتوزيع والكشف بعد كل خطوة', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01' } });
    await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01' } });
    const cust = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '500', name: 'عميل الاختبار' } });
    const p = await db.rpc(a, 'save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
    await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
    await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'sirr-2026' });

    // المطابقة: الكشف الرسمي = الذمم = رصيد السنة في المحرك = المتوقع، والبنود المفتوحة تساوي الرصيد المدين
    const check = async (expected, step, openItems) => {
      const s = await db.rpc(a, 'account_statement', { p_customer: cust, p_family: false, p_from: '2026-01-01', p_to: '2026-12-31', p_opts: {} });
      const r = await db.rpc(a, 'receivables', { p_date: '2026-12-31', p_opts: {} });
      const deb = r.debtors.find((d) => d.customer_number === '500');
      const cre = r.creditors.find((d) => d.customer_number === '500');
      const recvBal = deb ? num(deb.balance) : cre ? num(cre.balance) : 0;
      const ledger = num((await db.sql('select app.year_balance($1, 2026) b', [cust]))[0].b);
      assert.equal(num(s.official.final), expected, `${step}: الكشف`);
      assert.equal(recvBal, expected, `${step}: الذمم`);
      assert.equal(ledger, expected, `${step}: محرك الحسابات`);
      const open = (deb?.items ?? []).reduce((t, i) => t + num(i.remaining), 0);
      assert.equal(open, Math.max(expected, 0), `${step}: مجموع البنود المفتوحة`);
      if (openItems) assert.deepEqual((deb?.items ?? []).map((i) => [i.number, num(i.remaining)]), openItems, `${step}: البنود`);
    };

    // 1) افتتاحي 300 ثم فاتورتا ذمم 500 و200
    await db.rpc(a, 'save_opening', { p_customer: cust, p_year: 2026, p_debit: 300, p_credit: null });
    await check(300, 'الافتتاحي');
    const invRows = [line('invoice', '1', '2026-01-05', 500), line('invoice', '2', '2026-01-10', 200)];
    const b1 = await upload(db, a, 'invoice', invRows);
    await check(1000, 'الفواتير');

    // 2) تحصيل 600 يسدد الافتتاحي أولًا ثم الأقدم (FIN-004، COL-008)
    const b2 = await upload(db, a, 'collection', [line('collection', '7', '2026-01-20', 600)]);
    await check(400, 'التحصيل', [['1', 200], ['2', 200]]);

    // 3) مرتجع 450 يتجاوز الدين (الرصيد قبله مدين): يُقيَّد بكامل قيمته فيصبح الرصيد دائنًا 50 (RET-005)
    await upload(db, a, 'return', [line('return', '9', '2026-01-25', 450)]);
    await check(-50, 'المرتجع');
    const cls = await db.sql(`select class from return_classes`);
    assert.deepEqual(cls.map((c) => c.class), ['credit']);

    // 4) فاتورة لاحقة 100 يسدد الرصيد الدائن 50 منها (STMT-009)
    await upload(db, a, 'invoice', [line('invoice', '3', '2026-02-05', 100)]);
    await check(50, 'الرصيد الدائن يسدد لاحقًا', [['3', 50]]);

    // 5) تعديل تاريخ فاتورة: النتيجة النهائية لا تتغير، والتصنيف المحفوظ لا يتبدل بصمت (B035)
    const d2 = (await db.sql(`select id from docs where kind = 'invoice' and doc_number = '2'`))[0].id;
    const snap2 = (await db.sql('select data from doc_versions where doc_id = $1 order by version desc limit 1', [d2]))[0].data;
    await db.rpc(a, 'save_doc', { p_doc: d2, p_data: { ...snap2, doc_date: '2026-01-26' }, p_reason: 'تصحيح التاريخ' });
    await check(50, 'تعديل التاريخ');

    // 6) نقل الفاتورة 1 إلى مندوب آخر: المبالغ والرصيد كما هي، والإسناد يتغير (TXN-002)
    const d1 = (await db.sql(`select id from docs where kind = 'invoice' and doc_number = '1'`))[0].id;
    assert.equal(await db.rpc(a, 'transfer_docs', { p_doc_ids: [d1], p_employee_number: '21', p_reason: 'نقل' }), 1);
    assert.equal((await db.sql('select e.emp_number from docs d join employees e on e.id = d.employee_id where d.id = $1', [d1]))[0].emp_number, '21');
    await check(50, 'نقل المندوب');

    // 7) إعادة رفع ملف الفواتير الأصلي: المعدّل يدويًا محمي، والمفتاح المعدّل مطابقة محتملة؛ لا سند جديد (TXN-003، B048)
    const before = (await db.sql(`select count(*)::int n from docs`))[0].n;
    const re = await upload(db, a, 'invoice', invRows.map((r) => ({ ...r, row: rowNo++ })), (c) => (c === 'approve' || c === 'unchanged' ? 'approve' : 'keep'));
    assert.ok(re.classes.every((c) => c !== 'new'), 'لا سند جديد: ' + re.classes.join(','));
    assert.equal((await db.sql(`select count(*)::int n from docs`))[0].n, before);
    await check(50, 'إعادة الرفع');

    // 8) إقفال كانون الثاني ثم تصحيح فاتورة فيه: دون رمز يرفض، وبرمز الإدارة ينفذ ويُعاد الحساب (AUTH-004، B076)
    await db.sql(`insert into months (month, status) values ('2026-01-01', 'closed')`);
    const snap1 = (await db.sql('select data from doc_versions where doc_id = $1 order by version desc limit 1', [d1]))[0].data;
    const changed = { ...snap1, lines: snap1.lines.map((l) => ({ ...l, net_sales: '550' })) };
    await rejects(db.rpc(a, 'save_doc', { p_doc: d1, p_data: changed, p_reason: 'تصحيح المبلغ' }), 'الرمز السري');
    await check(50, 'رفض تعديل المقفل دون رمز');
    await db.rpc(a, 'save_doc', { p_doc: d1, p_data: changed, p_reason: 'تصحيح المبلغ', p_code: 'sirr-2026' });
    await check(100, 'تصحيح المقفل بالرمز');

    // 9) حذف دفعة التحصيل (في الشهر المقفل) تراجعًا عن أثرها: برمز الإدارة، ويعود الدين
    await rejects(db.rpc(a, 'delete_batch', { p_batch: b2.batch, p_reason: 'تحصيل مكرر' }), 'الرمز السري');
    await db.rpc(a, 'delete_batch', { p_batch: b2.batch, p_reason: 'تحصيل مكرر', p_code: 'sirr-2026' });
    await check(700, 'حذف دفعة التحصيل');

    // السند الأصلي وسجل تعديلاته محفوظان (TXN-003)
    const versions = await db.sql('select source from doc_versions where doc_id = $1 order by version', [d1]);
    assert.deepEqual(versions.map((v) => v.source), ['upload', 'transfer', 'manual']);
    assert.ok(b1.batch);
  } finally { await db.close(); }
});
