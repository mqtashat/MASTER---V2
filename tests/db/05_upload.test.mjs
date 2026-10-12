// الوحدة 2 — الرفع الموحد والسندات: المعاينة والاعتماد والتعليق والاستبعاد وحذف الدفعة والسند والتحرير والنقل
// حالات القبول: D01–D19، D24، D25، D28، وDATA-004..007، TXN-001..004، COL-002، B046–B054
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];

// صف فاتورة/مرتجع بأسماء الحقول التي يرسلها التطبيق
const inv = (row, o = {}) => ({
  row, doc_number: '1001', customer_number: '500', doc_date: '2026-10-01', employee_number: '20', employee_name: 'مندوب',
  customer_name: 'عميل', pay_type: 'فاتورة ذمم', item_number: 'A1', item_name: 'صنف', net_sales: '10', net_promotions: '0',
  quantity: '5', bonus: '0', lat: '32.01', lng: '36.02', ...o,
});
const col = (row, o = {}) => ({
  row, doc_number: '7001', customer_number: '500', doc_date: '2026-10-02', employee_number: '20', employee_name: 'مندوب',
  customer_name: 'عميل', amount: '10', pay_method: 'نقدي', cheque_no: '', ...o,
});

async function setup(db) {
  const a = await seedAdmin(db);
  await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2026-01-01' } });
  await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2026-01-01' } });
  await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '500', name: 'عميل تجريبي' } });
  await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '501', name: 'عميل آخر' } });
  for (const [code, price] of [['A1', '2'], ['A2', '0']]) {
    const p = await db.rpc(a, 'save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
    await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: price, p_date: '2026-01-01' });
  }
  return a;
}

const stage = (db, a, kind, rows, cols) =>
  db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'ملف.xlsx', p_sheet: 'S', p_columns: cols ?? (kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS), p_rows: rows });
const items = (db, batch) => db.sql('select * from batch_items where batch_id = $1 order by seq', [batch]);
const approveAll = async (db, a, batch, code = null, action = 'approve') => {
  const its = await items(db, batch);
  return db.rpc(a, 'upload_resolve', { p_batch: batch, p_decisions: its.map((i) => ({ id: i.id, action })), p_code: code });
};
const docs = (db, kind = 'invoice') => db.sql(`select * from docs where kind = $1 order by id`, [kind]);

test('D01: رفع الملف نفسه مرتين لا يغير ولا يكرر (DATA-004)', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const rows = [inv(2), inv(3, { item_number: 'A2', net_sales: '0', bonus: '1', quantity: '0' }), inv(4, { doc_number: '1002' })];
    const s1 = await stage(db, a, 'invoice', rows);
    assert.equal(s1.docs, 2); assert.equal(s1.new, 2);
    await approveAll(db, a, s1.batch_id);
    const s2 = await stage(db, a, 'invoice', rows);
    assert.equal(s2.unchanged, 2); assert.equal(s2.new, 0);
    const r = await approveAll(db, a, s2.batch_id);
    assert.equal(r.no_change, 2);
    const d = await docs(db);
    assert.equal(d.length, 2);
    assert.equal(d[0].version, 1);
    assert.equal(d[0].total, '10');
    assert.equal(d[0].line_count, 2);
  } finally { await db.close(); }
});

test('D02/B047: صفوف متطابقة: تنبيه، والإبقاء أو استبعاد التكرار قرار صريح', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const s = await stage(db, a, 'invoice', [inv(2), inv(3)]);
    const [it] = await items(db, s.batch_id);
    assert.deepEqual(it.duplicates, [[2, 3]]);
    assert.ok(it.warnings.some((w) => w.message.includes('صفوف متطابقة')));
    assert.equal(it.class, 'new');
    await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: [{ id: it.id, action: 'approve', drop_duplicates: true }] });
    const [d] = await docs(db);
    assert.equal(d.line_count, 1);
    // الإبقاء هو الافتراضي: سند آخر بصفين متطابقين يحفظ الاثنين
    const s2 = await stage(db, a, 'invoice', [inv(2, { doc_number: '1003' }), inv(3, { doc_number: '1003' })]);
    await approveAll(db, a, s2.batch_id);
    const d2 = (await docs(db)).find((x) => x.doc_number === '1003');
    assert.equal(d2.line_count, 2); assert.equal(d2.total, '20');
  } finally { await db.close(); }
});

test('D03/B048: تعديل المفتاح ثم رفع الأصل مطابقة محتملة لا سند ثانٍ؛ D04/B049: التصادم يمنع الحفظ', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const s = await stage(db, a, 'invoice', [inv(2), inv(3, { doc_number: '1002' })]);
    await approveAll(db, a, s.batch_id);
    const [d1, d2] = await docs(db);
    const snap = (await db.sql('select data from doc_versions where doc_id = $1', [d1.id]))[0].data;
    await db.rpc(a, 'save_doc', { p_doc: d1.id, p_data: { ...snap, doc_number: '1001-م' }, p_reason: 'تصحيح الرقم' });
    // التصادم مع سند آخر
    await rejects(db.rpc(a, 'save_doc', { p_doc: d1.id, p_data: { ...snap, doc_number: '1002' } }), 'مستخدم لسند آخر');
    const s2 = await stage(db, a, 'invoice', [inv(2)]);
    const [it] = await items(db, s2.batch_id);
    assert.equal(it.class, 'possible_match');
    assert.equal(it.doc_id, d1.id);
    await approveAll(db, a, s2.batch_id);           // «اعتماد» لا يناسب المطابق المحتمل: يتطلب قرارًا صريحًا
    assert.equal((await items(db, s2.batch_id))[0].outcome, null);
    await db.rpc(a, 'upload_resolve', { p_batch: s2.batch_id, p_decisions: [{ id: it.id, action: 'keep' }] });
    const all = await docs(db);
    assert.equal(all.length, 2);
    assert.equal(all.find((x) => x.id === d1.id).doc_number, '1001-م');
    assert.equal(d2.doc_number, '1002');
  } finally { await db.close(); }
});

test('D05/B053: نسخة ناقصة الأعمدة لا تمحو الكمية أو الموقع أو النوع', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const s = await stage(db, a, 'invoice', [inv(2, { quantity: '5.5' })]);
    await approveAll(db, a, s.batch_id);
    const old12 = INV_COLS.filter((c) => !['Quantity', 'DocumentTypeID', 'Longitude', 'Latitude'].includes(c));
    const row = inv(2); delete row.quantity; delete row.pay_type; delete row.lat; delete row.lng;
    const s2 = await stage(db, a, 'invoice', [row], old12);
    assert.equal(s2.unchanged, 1);
    const s3 = await stage(db, a, 'invoice', [{ ...row, net_sales: '12' }], old12);
    assert.equal(s3.changed, 1);
    await approveAll(db, a, s3.batch_id);
    const [d] = await docs(db);
    assert.equal(d.total, '12');
    assert.equal(d.pay_type, 'فاتورة ذمم');
    assert.equal(d.quantity, '5.5');
    assert.equal(d.lat, '32.01');
    // فاتورة جديدة دون عمود النوع لا يُفترض نوعها
    const s4 = await stage(db, a, 'invoice', [{ ...row, doc_number: '9' }], old12);
    assert.equal(s4.pending, 1);
  } finally { await db.close(); }
});

test('D06/D11/D12/D16/D17: التعليق يمنع اعتماد السند المتأثر فقط، والصحيح يعتمد', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const s = await stage(db, a, 'invoice', [
      inv(2),
      inv(3, { doc_number: '1002', employee_number: '999' }),                      // D11
      inv(4, { doc_number: '1003', pay_type: 'فاتورة آجل' }),                        // D12
      inv(5, { doc_number: '1004', pay_type: '' }),                                  // D12
      inv(6, { doc_number: '1005', item_number: 'Z9' }),                             // صنف غير معرّف
      inv(7, { doc_number: '1006', lat: '', lng: '' }),                              // D06: نقص الموقع لا يمنع
      inv(8, { doc_number: '1007', quantity: '0.5', bonus: '0.5' }),                 // D16
      inv(9, { doc_number: '1008', net_sales: '0', net_promotions: '30', quantity: '0' }), // D17
      inv(10, { doc_number: '' }),                                                   // B050
    ]);
    assert.equal(s.pending, 5);
    const its = await items(db, s.batch_id);
    const msg = (n) => its.find((i) => i.doc_number === n).errors.map((e) => e.message).join(' | ');
    assert.match(msg('1002'), /موظف غير معرّف: 999/);
    assert.match(msg('1003'), /غير مقبولة: فاتورة آجل/);
    assert.match(msg('1004'), /فارغة/);
    assert.match(msg('1005'), /صنف غير معرّف: Z9/);
    assert.equal(its.find((i) => i.doc_number === '1006').class, 'new');
    assert.ok(its.find((i) => i.doc_number === '1008').warnings.some((w) => w.message.includes('كمية صفر')));
    const r = await approveAll(db, a, s.batch_id);
    assert.equal(r.added, 4); assert.equal(r.pending, 5);
    const d = await docs(db);
    assert.equal(d.find((x) => x.doc_number === '1007').quantity, '0.5');
    assert.equal(d.find((x) => x.doc_number === '1006').lat, null);
    // D11: بعد تعريف الموظف وإعادة الفحص يعتمد
    await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '999', name: 'موظف جديد', join_date: '2026-01-01' } });
    const rc = await db.rpc(a, 'upload_recheck', { p_batch: s.batch_id });
    assert.equal(rc.pending, 4); assert.equal(rc.new, 1);
    // تصحيح يدوي للمعلق ثم اعتماده (DATA-005)
    const it3 = its.find((i) => i.doc_number === '1003');
    const fixed = await db.rpc(a, 'upload_fix_item', { p_item: it3.id, p_data: { ...it3.data, lines: it3.data.lines.map((l) => ({ ...l, pay_type: 'فاتورة نقدي' })) } });
    assert.equal(fixed.class, 'new');
    const batchState = await db.sql('select status from upload_batches where id = $1', [s.batch_id]);
    assert.equal(batchState[0].status, 'open');
  } finally { await db.close(); }
});

test('D07: استبعاد سند معلق له نسخة سابقة يبقيها دون تغيير', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [inv(2)])).batch_id);
    const s = await stage(db, a, 'invoice', [inv(2, { net_sales: '15', item_number: 'Z9' })]);
    const [it] = await items(db, s.batch_id);
    assert.equal(it.class, 'pending');
    await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: [{ id: it.id, action: 'exclude' }] });
    const [d] = await docs(db);
    assert.equal(d.total, '10'); assert.equal(d.version, 1);
    assert.equal((await items(db, s.batch_id))[0].outcome, 'excluded');
  } finally { await db.close(); }
});

test('TXN-003: النقل اليدوي محمي عند إعادة رفع الملف القديم حتى الاختيار الصريح', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [inv(2)])).batch_id);
    const [d] = await docs(db);
    const pv = await db.rpc(a, 'preview_transfer', { p_doc_ids: [d.id], p_employee_number: '21' });
    assert.equal(pv.count, 1); assert.equal(pv.total, '10');
    assert.equal(await db.rpc(a, 'transfer_docs', { p_doc_ids: [d.id], p_employee_number: '21', p_reason: 'إعادة إسناد' }), 1);
    const s = await stage(db, a, 'invoice', [inv(2)]);
    const [it] = await items(db, s.batch_id);
    assert.equal(it.class, 'manual_conflict');
    await approveAll(db, a, s.batch_id);                      // الاعتماد العام لا يلغي اليدوي
    let [cur] = await db.sql(`select e.emp_number, d.manual_edit from docs d join employees e on e.id = d.employee_id`);
    assert.equal(cur.emp_number, '21');
    await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: [{ id: it.id, action: 'use_file' }] });
    [cur] = await db.sql(`select e.emp_number, d.manual_edit, d.version from docs d join employees e on e.id = d.employee_id`);
    assert.equal(cur.emp_number, '20'); assert.equal(cur.manual_edit, false); assert.equal(cur.version, 3);
    const vers = await db.sql('select source from doc_versions where doc_id = $1 order by version', [d.id]);
    assert.deepEqual(vers.map((v) => v.source), ['upload', 'transfer', 'upload']);
  } finally { await db.close(); }
});

test('D08/D09/B054: حذف الدفعة تراجع عن أثرها ويعزل المتعارض؛ إعادة رفع المحذوف تتطلب استعادة صريحة', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const b1 = (await stage(db, a, 'invoice', [inv(2), inv(3, { doc_number: '1002' })])).batch_id;
    await approveAll(db, a, b1);
    // الدفعة الثانية: تعدل 1001 وتضيف 1003 و1004، و1002 مطابق
    const b2 = (await stage(db, a, 'invoice', [inv(2, { net_sales: '11' }), inv(3, { doc_number: '1002' }), inv(4, { doc_number: '1003' }), inv(5, { doc_number: '1004' })])).batch_id;
    await approveAll(db, a, b2);
    // تعديل يدوي لاحق على 1004
    const d4 = (await docs(db)).find((x) => x.doc_number === '1004');
    const snap = (await db.sql('select data from doc_versions where doc_id = $1', [d4.id]))[0].data;
    await db.rpc(a, 'save_doc', { p_doc: d4.id, p_data: { ...snap, lines: snap.lines.map((l) => ({ ...l, net_sales: '99' })) } });
    const plan = await db.rpc(a, 'preview_delete_batch', { p_batch: b2 });
    assert.deepEqual(plan.remove.map((x) => x.doc_number), ['1003']);
    assert.deepEqual(plan.revert.map((x) => x.doc_number), ['1001']);
    assert.deepEqual(plan.conflicts.map((x) => x.doc_number), ['1004']);
    assert.equal(plan.unchanged, 1);
    await rejects(db.rpc(a, 'delete_batch', { p_batch: b2, p_reason: '' }), 'سبب');
    await db.rpc(a, 'delete_batch', { p_batch: b2, p_reason: 'ملف خاطئ' });
    const after = await docs(db);
    assert.equal(after.find((x) => x.doc_number === '1001').total, '10');
    assert.equal(after.find((x) => x.doc_number === '1003').status, 'deleted');
    assert.equal(after.find((x) => x.doc_number === '1004').total, '99');
    assert.equal(after.find((x) => x.doc_number === '1004').status, 'active');
    // D09: إعادة رفع المحذوف
    const b3 = (await stage(db, a, 'invoice', [inv(4, { doc_number: '1003' })])).batch_id;
    const [it] = await items(db, b3);
    assert.equal(it.class, 'deleted_before');
    await approveAll(db, a, b3);
    assert.equal((await docs(db)).find((x) => x.doc_number === '1003').status, 'deleted');
    await db.rpc(a, 'upload_resolve', { p_batch: b3, p_decisions: [{ id: it.id, action: 'restore' }] });
    assert.equal((await docs(db)).find((x) => x.doc_number === '1003').status, 'active');
  } finally { await db.close(); }
});

test('D10: إعادة المحاولة بعد اعتماد جزئي لا تكرر ما اعتمد', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const s = await stage(db, a, 'invoice', [inv(2), inv(3, { doc_number: '1002' })]);
    const its = await items(db, s.batch_id);
    await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: [{ id: its[0].id, action: 'approve' }] });
    const r = await approveAll(db, a, s.batch_id);
    assert.equal(r.added, 2);
    assert.equal((await docs(db)).length, 2);
    assert.equal((await db.sql('select count(*)::int n from doc_versions'))[0].n, 2);
  } finally { await db.close(); }
});

test('D18/B046: سند محفوظ بثلاثة بنود يعاد ببندين: فرق ثم استبدال كامل دون دمج', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [inv(2), inv(3, { net_sales: '4' }), inv(4, { item_number: 'A2', net_sales: '6' })])).batch_id);
    const s = await stage(db, a, 'invoice', [inv(2), inv(3, { net_sales: '4' })]);
    assert.equal(s.changed, 1);
    await approveAll(db, a, s.batch_id);
    const [d] = await docs(db);
    assert.equal(d.line_count, 2); assert.equal(d.total, '14');
  } finally { await db.close(); }
});

test('D13/D14/D19/D28/COL-002: التحصيل: الدفع المقبول فقط، والأجزاء المتطابقة والصفرية تجمع كلها', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const parts = [
      ...Array.from({ length: 3 }, (_, i) => col(2 + i, { amount: '22.798' })),
      ...Array.from({ length: 9 }, (_, i) => col(5 + i, { amount: '28.105' })),
      col(14, { amount: '527.349000000000000000' }),
      col(15, { amount: '0' }),
    ];
    const s = await stage(db, a, 'collection', [
      ...parts,
      col(16, { doc_number: '7002', pay_method: '----' }),
      col(17, { doc_number: '7003', pay_method: 'حوالة' }),
      col(18, { doc_number: '7004', pay_method: 'نقدي', cheque_no: '55' }),
    ]);
    assert.equal(s.pending, 2);
    const its = await items(db, s.batch_id);
    assert.equal(its[0].warnings.length, 0, 'لا تنبيه تكرار لأجزاء التحصيل');
    await approveAll(db, a, s.batch_id);
    const d = await docs(db, 'collection');
    assert.equal(d.length, 2);
    assert.equal(d[0].total, '848.688');
    assert.equal(d[0].line_count, 14);
    assert.equal(d[1].pay_methods, 'نقدي'); assert.equal(d[1].cheque_numbers, '55');
    // إعادة الرفع مطابقًا تبقيه سندًا واحدًا بالإجمالي نفسه (DATA-004)
    const s2 = await stage(db, a, 'collection', parts);
    assert.equal(s2.unchanged, 1);
  } finally { await db.close(); }
});

test('D15/RET-008: كمية مرتجع سالبة خطأ بالصف والعمود والقيمة', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const r = inv(2, { quantity: '-2' }); delete r.pay_type;
    const s = await stage(db, a, 'return', [r]);
    const [it] = await items(db, s.batch_id);
    assert.equal(it.class, 'pending');
    assert.deepEqual(it.errors.map((e) => [e.row, e.field, e.value]), [[2, 'Quantity', '-2']]);
  } finally { await db.close(); }
});

test('D24/AUTH-004: اعتماد سند في شهر مقفل للإدارة برمزها فقط', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'sirr-2026' });
    await db.sql(`insert into months (month, status) values ('2026-10-01', 'closed')`);
    const s = await stage(db, a, 'invoice', [inv(2)]);
    await rejects(approveAll(db, a, s.batch_id), 'الرمز السري');
    await approveAll(db, a, s.batch_id, 'sirr-2026');
    const [d] = await docs(db);
    await rejects(db.rpc(a, 'delete_doc', { p_doc: d.id, p_reason: 'x' }), 'شهرًا مقفلًا');
    await db.rpc(a, 'delete_doc', { p_doc: d.id, p_reason: 'x', p_code: 'sirr-2026' });
  } finally { await db.close(); }
});

test('D25/UPLOAD-001: أحدث تاريخ سند منفصل عن آخر رفع، ويتحدث بعد الحذف', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [inv(2, { doc_date: '2026-03-05' }), inv(3, { doc_number: '2', doc_date: '2026-03-09' })])).batch_id);
    let o = await db.rpc(a, 'upload_overview');
    assert.equal(o.invoice.latest_doc_date, '2026-03-09');
    assert.ok(o.invoice.last_upload_at);
    assert.equal(o.collection.latest_doc_date, null);
    const d = (await docs(db)).find((x) => x.doc_date === '2026-03-09');
    await db.rpc(a, 'delete_doc', { p_doc: d.id, p_reason: 'خطأ' });
    o = await db.rpc(a, 'upload_overview');
    assert.equal(o.invoice.latest_doc_date, '2026-03-05');
  } finally { await db.close(); }
});

test('الصلاحيات والنطاق: لا كتابة مباشرة، والمندوب يرى سنداته فقط', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [inv(2), inv(3, { doc_number: '2', employee_number: '21' })])).batch_id);
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مندوب', p_perms: [{ page: 'P06', action: 'view' }] });
    const [e20] = await db.sql(`select id from employees where emp_number = '20'`);
    const u = await makeUser(db, a, { username: 'rep20', display_name: 'مندوب', data_scope: 'self', template_id: tpl, employee_id: e20.id });
    const seen = await db.as(u, 'select doc_number from docs_v');
    assert.deepEqual(seen.map((r) => r.doc_number), ['1001']);
    const lines = await db.as(u, 'select count(*)::int n from doc_lines');
    assert.equal(lines[0].n, 1);
    const res = await db.rpc(u, 'docs_search', { p_kind: 'invoice', p_filters: {}, p_sort: 'doc_number', p_asc: true, p_offset: 0, p_limit: 50 });
    assert.equal(res.summary.count, 1);
    await rejects(db.as(u, `update docs set total = 0`), 'permission denied');
    await rejects(db.rpc(u, 'upload_stage', { p_kind: 'invoice', p_file_name: 'x', p_sheet: 'x', p_columns: INV_COLS, p_rows: [inv(2)] }), 'لا تملك صلاحية');
    const [d2] = await db.sql(`select id from docs where doc_number = '2'`);
    await rejects(db.rpc(u, 'delete_doc', { p_doc: d2.id, p_reason: 'x' }), 'لا تملك صلاحية');
  } finally { await db.close(); }
});

test('B072: مستخدم بنطاق محدود لا يكتب على سندات أو موظفين خارج نطاقه بالرفع أو التعديل أو النقل أو حذف الدفعة', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    const adminBatch = (await stage(db, a, 'invoice', [inv(2), inv(3, { doc_number: '2', employee_number: '21' })])).batch_id;
    await approveAll(db, a, adminBatch);
    const perms = [['P05', 'view'], ['P05', 'import'], ['P05', 'approve'], ['P05', 'delete'], ['P06', 'view'], ['P06', 'edit'], ['P06', 'transfer']]
      .map(([page, action]) => ({ page, action }));
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مندوب برفع', p_perms: perms });
    const [e20] = await db.sql(`select id from employees where emp_number = '20'`);
    const [e21] = await db.sql(`select id from employees where emp_number = '21'`);
    const u = await makeUser(db, a, { username: 'rep20b', display_name: 'مندوب', data_scope: 'self', template_id: tpl, employee_id: e20.id });
    const [d1] = await db.sql(`select id from docs where doc_number = '1001'`);
    const [d2] = await db.sql(`select id from docs where doc_number = '2'`);
    const data1 = { doc_number: '1001', customer_number: '500', doc_date: '2026-10-01', employee_number: '21', pay_type: 'فاتورة ذمم',
      lines: [{ item_number: 'A1', net_sales: '10', net_promotions: '0', quantity: '5', bonus: '0' }] };

    // التعديل والنقل إلى موظف خارج النطاق
    await rejects(db.rpc(u, 'save_doc', { p_doc: d1.id, p_data: data1, p_reason: 'x' }), 'خارج نطاق');
    await rejects(db.rpc(u, 'transfer_docs', { p_doc_ids: [d1.id], p_employee_number: '21' }), 'خارج نطاق');
    await rejects(db.rpc(u, 'preview_transfer', { p_doc_ids: [d1.id], p_employee_number: '21' }), 'خارج نطاق');

    // رفع سند يطابق مفتاح سند موظف آخر لا يستبدله ولا ينقله
    const b = (await stage(db, u, 'invoice', [inv(2, { doc_number: '2', net_sales: '99' })])).batch_id;
    const res = await approveAll(db, u, b);
    assert.match(res.skipped[0].reason, /خارج نطاق/);
    const [d2after] = await db.sql(`select employee_id, total::text from docs where id = $1`, [d2.id]);
    assert.equal(String(d2after.employee_id), String(e21.id));
    assert.equal(d2after.total, '10');

    // تصحيح معلق إلى موظف خارج النطاق
    const bp = (await stage(db, u, 'invoice', [inv(2, { doc_number: '3', employee_number: '' })])).batch_id;
    const [pend] = await items(db, bp);
    await rejects(db.rpc(u, 'upload_fix_item', { p_item: pend.id, p_data: { ...pend.data, lines: pend.data.lines.map((l) => ({ ...l, employee_number: '21' })) } }), 'خارج نطاق');

    // حذف دفعة تشمل سندات موظف آخر
    await rejects(db.rpc(u, 'preview_delete_batch', { p_batch: adminBatch }), 'خارج نطاق');
    await rejects(db.rpc(u, 'delete_batch', { p_batch: adminBatch, p_reason: 'x' }), 'خارج نطاق');
    assert.equal((await docs(db)).filter((d) => d.status === 'active').length, 2);
  } finally { await db.close(); }
});

test('INV-007: البحث والملخص لكامل النتائج، والكمية المكافئة بالسعر التاريخي أو «سعر غير متوفر»', async () => {
  const db = await connect();
  try {
    const a = await setup(db);
    await approveAll(db, a, (await stage(db, a, 'invoice', [
      inv(2), inv(3, { item_number: 'A2', net_sales: '0', net_promotions: '3', quantity: '1' }),
      inv(4, { doc_number: '1002', customer_number: '501', pay_type: 'فاتورة نقدي' }),
    ])).batch_id);
    const all = await db.rpc(a, 'docs_search', { p_kind: 'invoice', p_filters: {}, p_sort: 'doc_number', p_asc: true, p_offset: 0, p_limit: 1 });
    assert.equal(all.rows.length, 1);
    assert.equal(all.summary.count, 2); assert.equal(all.summary.customers, 2); assert.equal(all.summary.total, '23');
    const cash = await db.rpc(a, 'docs_search', { p_kind: 'invoice', p_filters: { pay_type: 'فاتورة نقدي' }, p_offset: 0, p_limit: 50 });
    assert.equal(cash.summary.count, 1);
    const lines = await db.sql(`select item_number, sale_price, equivalent_qty from doc_lines_v order by doc_id, line_no`);
    assert.equal(lines[0].equivalent_qty, '5.0000000000000000');
    assert.equal(lines[1].equivalent_qty, null);   // سعر صفري: لا مكافئة (B059)
  } finally { await db.close(); }
});
