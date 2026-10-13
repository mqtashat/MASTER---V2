// الوحدة 5 — الخرائط: استيراد مواقع العملاء، المناطق ونسخها والتداخل، خريطة الفواتير، مقارنة الفترات، انتشار الأصناف.
// MAP-002..015، B063–B071
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;
let docNo = 5000;

// docs: [{cust, date, emp, pay, lat, lng, lines: [[item, ns, np, qty, bonus]]}]
async function add(db, a, kind, docs) {
  const rows = [];
  for (const d of docs) {
    const n = d.num ?? String(docNo++);
    for (const [item, ns, np = 0, qty = 1, bonus = 0] of d.lines) {
      rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20',
        pay_type: d.pay ?? 'فاتورة نقدي', item_number: item, item_name: 'صنف', net_sales: String(ns), net_promotions: String(np),
        quantity: String(qty), bonus: String(bonus), lat: d.lat === undefined ? '' : String(d.lat), lng: d.lng === undefined ? '' : String(d.lng) });
    }
  }
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: kind === 'return' ? RET_COLS : INV_COLS, p_rows: rows });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  assert.deepEqual(its.flatMap((i) => i.errors), []);
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}

// مربعان متجاوران يشتركان في الحد lng = 36: الغربي [31..32]×[35..36] والشرقي [31..32]×[36..37]
const WEST = [[[31, 35], [31, 36], [32, 36], [32, 35]]];
const EAST = [[[31, 36], [31, 37], [32, 37], [32, 36]]];

async function setup(db) {
  const a = await seedAdmin(db);
  const e = {};
  e.sup = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.sup } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01' } });
  const c = {};
  for (const n of ['500', '501', '502', '503', '504']) c[n] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name: 'عميل ' + n } });
  const p = {};
  for (const code of ['A1', 'A2']) {
    p[code] = await db.rpc(a, 'save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
    await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
  }
  return { a, e, c, p };
}
const locs = (db, a, rows, commit = true) => db.rpc(a, 'import_customer_locations', { p_rows: rows.map((r, i) => ({ row: i + 2, ...r })), p_commit: commit });

test('MAP-004 B065: استيراد المواقع بالمعاينة؛ الفراغ لا يمحو، والمجهول خطأ، والأصل يبقى بعد التصحيح', async () => {
  const db = await connect();
  try {
    const { a, c } = await setup(db);
    await locs(db, a, [{ customer_number: '500', lat: '31.5', lng: '35.5' }]);
    const pv = await locs(db, a, [
      { customer_number: '500', lat: '31.6', lng: '35.6' }, { customer_number: '501', lat: '31.5', lng: '36.5' },
      { customer_number: '502', lat: '', lng: '' }, { customer_number: '999', lat: '31', lng: '35' },
      { customer_number: '503', lat: 'abc', lng: '35' }, { customer_number: '504', lat: '0', lng: '0' }], false);
    assert.deepEqual(pv.counts, { new: 1, changed: 1, same: 0, blank: 1, error: 3 });
    assert.match(pv.rows.find((r) => r.customer_number === '999').message, /عرّفه في صفحة العملاء/);
    let [r] = await db.sql('select lat, lng from customers where id = $1', [c['500']]);
    assert.equal(num(r.lat), 31.5, 'المعاينة لا تحفظ');
    await locs(db, a, [{ customer_number: '500', lat: '31.6', lng: '35.6' }, { customer_number: '500', lat: '', lng: '' }]);
    [r] = await db.sql('select lat, lng, orig_lat from customers where id = $1', [c['500']]);
    assert.equal(num(r.lat), 31.6, 'الفراغ لا يمحو');
    // التصحيح اليدوي يغير المعتمد ويبقي الأصل للتدقيق، والإزالة صريحة
    await db.rpc(a, 'set_customer_location', { p_customer: c['500'], p_lat: 31.7, p_lng: 35.7 });
    const [l] = await db.rpc(a, 'customer_locations', { p_opts: { search: '500' } });
    assert.equal(num(l.lat), 31.7);
    assert.equal(num(l.orig_lat), 31.6);
    await db.rpc(a, 'set_customer_location', { p_customer: c['500'], p_lat: null, p_lng: null });
    const missing = await db.rpc(a, 'customer_locations', { p_opts: { state: 'missing' } });
    assert.ok(missing.some((x) => x.customer_number === '500'));
  } finally { await db.close(); }
});

test('MAP-005 B067: التصنيف داخل الحدود، والحد المشترك يحتاج تحديد منطقة، والإسناد الصريح يحسمه', async () => {
  const db = await connect();
  try {
    const { a, e, c } = await setup(db);
    await locs(db, a, [{ customer_number: '500', lat: '31.5', lng: '35.5' }, { customer_number: '501', lat: '31.5', lng: '36.5' },
      { customer_number: '502', lat: '31.5', lng: '36' }, { customer_number: '503', lat: '33', lng: '35' }]);
    const w = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الغربية', color: '#2e7d32', geom: WEST, employee_id: e.r1, valid_from: '2026-01-01' } });
    // المعاينة قبل الحفظ: عدد العملاء الداخلين
    const pv = await db.rpc(a, 'preview_region', { p_id: null, p: { name: 'الشرقية', geom: EAST, valid_from: '2026-01-01' } });
    assert.equal(pv.inside, 2);
    assert.deepEqual(pv.conflicts.map((x) => x.customer_number), ['502']);
    assert.equal((await db.rpc(a, 'regions_list', { p_date: '2026-06-01' })).regions.length, 1, 'المعاينة لا تحفظ');
    const east = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الشرقية', geom: EAST, employee_id: e.r2, valid_from: '2026-01-01' } });
    let l = await db.rpc(a, 'regions_list', { p_date: '2026-06-01' });
    assert.deepEqual(l.regions.map((r) => [r.name, r.customers]), [['الشرقية', 1], ['الغربية', 1]]);
    assert.deepEqual(l.conflicts.map((x) => x.customer_number), ['502']);
    assert.deepEqual(l.counts, { in: 2, none: 1, no_location: 1, conflict: 1 });
    await rejects(db.rpc(a, 'assign_customer_region', { p_customer: c['502'], p_region: w, p_from: '2026-01-01', p_reason: '' }), 'سبب الإسناد');
    await db.rpc(a, 'assign_customer_region', { p_customer: c['502'], p_region: w, p_from: '2026-01-01', p_reason: 'زبون الغربية' });
    l = await db.rpc(a, 'regions_list', { p_date: '2026-06-01' });
    assert.equal(l.conflicts.length, 0);
    assert.equal(l.regions.find((r) => r.id === Number(w) || String(r.id) === String(w)).customers, 2, 'بلا احتساب مزدوج');
    assert.equal(l.regions.find((r) => String(r.id) === String(east)).customers, 1);
  } finally { await db.close(); }
});

test('B068: نسخ الحدود بتاريخ سريان؛ التاريخي يستخدم النسخة السارية والحالي خيار منفصل', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await locs(db, a, [{ customer_number: '500', lat: '31.5', lng: '35.5' }, { customer_number: '501', lat: '31.5', lng: '36.5' }]);
    const id = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'المنطقة', geom: WEST, employee_id: e.r1, valid_from: '2026-01-01' } });
    // توسيع الحدود من 1/7 لتشمل الشرقية
    const BIG = [[[31, 35], [31, 37], [32, 37], [32, 35]]];
    await db.rpc(a, 'save_region', { p_id: id, p: { name: 'المنطقة', geom: BIG, employee_id: e.r1, valid_from: '2026-07-01' } });
    assert.equal((await db.rpc(a, 'regions_list', { p_date: '2026-03-01' })).regions[0].customers, 1);
    assert.equal((await db.rpc(a, 'regions_list', { p_date: '2026-08-01' })).regions[0].customers, 2);
    assert.equal((await db.rpc(a, 'regions_list', { p_date: '2026-08-01' })).regions[0].versions.length, 2);
    await rejects(db.rpc(a, 'save_region', { p_id: id, p: { name: 'المنطقة', geom: WEST, valid_from: '2026-02-01' } }), 'قبل آخر نسخة');
    await rejects(db.rpc(a, 'save_region', { p_id: null, p: { name: 'ناقصة', geom: [[[31, 35], [31, 36]]] } }), 'ثلاث نقاط');
    await db.rpc(a, 'delete_region', { p_id: id, p_reason: 'إلغاء' });
    assert.equal((await db.rpc(a, 'regions_list', {})).regions.length, 0);
  } finally { await db.close(); }
});

test('MAP-002 MAP-014: خريطة الفواتير نقاط للفواتير فقط، وبلا موقع في قائمة، وداخل/خارج منطقة المندوب، والنطاق', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الغربية', geom: WEST, employee_id: e.r1, valid_from: '2026-01-01' } });
    await add(db, a, 'invoice', [
      { cust: '500', date: '2026-09-01', lat: 31.5, lng: 35.5, lines: [['A1', 100], ['A2', 50]] },
      { cust: '501', date: '2026-09-02', lat: 31.5, lng: 36.5, pay: 'فاتورة ذمم', lines: [['A1', 70]] },
      { cust: '502', date: '2026-09-03', lines: [['A1', 30]] },
      { cust: '503', date: '2026-09-03', emp: '21', lat: 31.5, lng: 36.5, lines: [['A1', 10]] }]);
    await add(db, a, 'return', [{ cust: '500', date: '2026-09-04', lat: 31.5, lng: 35.5, lines: [['A1', 20]] }]);
    const m = await db.rpc(a, 'invoice_map', { p_from: '2026-09-01', p_to: '2026-09-30', p_opts: {} });
    assert.equal(m.has_time, false, 'الإصدار الأول بلا وقت إصدار (MAP-012)');
    assert.equal(m.totals.count, 4, 'المرتجعات لا تظهر');
    assert.equal(m.points.length, 3);
    assert.equal(m.missing.length, 1);
    const p500 = m.points.find((x) => x.customer_number === '500');
    assert.equal(num(p500.total), 150, 'نقطة واحدة للفاتورة دون تكرار بتعدد الأصناف');
    assert.equal(p500.in_region, true);
    assert.equal(m.points.find((x) => x.customer_number === '501').in_region, false);
    assert.equal(m.points.find((x) => x.customer_number === '503').in_region, null, 'مندوب بلا منطقة');
    assert.deepEqual([m.totals.in_region, m.totals.out_region], [1, 1]);
    const credit = await db.rpc(a, 'invoice_map', { p_from: '2026-09-01', p_to: '2026-09-30', p_opts: { pay_type: 'credit' } });
    assert.equal(credit.totals.count, 1);
    const only21 = await db.rpc(a, 'invoice_map', { p_from: '2026-09-01', p_to: '2026-09-30', p_opts: { employees: [e.r2] } });
    assert.equal(only21.totals.count, 1);
    await rejects(db.rpc(a, 'invoice_map', { p_from: '2026-01-01', p_to: '2026-09-30', p_opts: {} }), '93');
    // المندوب بنطاق «الذات» يرى فواتيره فقط
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'خرائط', p_perms: [{ page: 'P15', action: 'view' }] });
    const u = await makeUser(db, a, { username: 'rep21', display_name: 'مندوب', data_scope: 'self', template_id: tpl, employee_id: e.r2 });
    const mine = await db.rpc(u, 'invoice_map', { p_from: '2026-09-01', p_to: '2026-09-30', p_opts: {} });
    assert.equal(mine.totals.count, 1);
  } finally { await db.close(); }
});

test('MAP-006 MAP-011 B069: مقارنة الفترات بالمؤشرات وغير المباعين وصفر الأساس', async () => {
  const db = await connect();
  try {
    const { a } = await setup(db);
    await add(db, a, 'invoice', [{ cust: '500', date: '2026-08-05', lines: [['A1', 100]] }]);
    await add(db, a, 'invoice', [{ cust: '500', date: '2026-09-05', lines: [['A1', 200]] }, { cust: '501', date: '2026-09-06', lines: [['A1', 100]] },
      { cust: '501', date: '2026-09-07', lines: [['A1', 60]] }]);
    await add(db, a, 'return', [{ cust: '501', date: '2026-09-08', lines: [['A1', 10]] }]);
    const r = await db.rpc(a, 'period_compare', { p_a_from: '2026-08-01', p_a_to: '2026-08-31', p_b_from: '2026-09-01', p_b_to: '2026-09-30', p_opts: {} });
    assert.equal(num(r.a.sales), 100);
    assert.deepEqual([num(r.b.sales), num(r.b.returns), num(r.b.net), r.b.invoices, r.b.buyers], [360, 10, 350, 3, 2]);
    assert.equal(num(r.b.avg_invoice), 120);
    assert.equal(r.b.new_customers, 1, '501 جديد في أيلول؛ 500 اشترى قبلها');
    assert.equal(r.a.new_customers, 1);
    // عملاء النطاق: من تعامل معهم مندوبو النطاق؛ غير المباعين في آب = 501
    assert.deepEqual([r.a.scope_customers, r.a.unsold], [2, 1]);
    assert.equal(r.equal_length, false);
    assert.ok(r.a.work_days > 0 && r.b.work_days > 0);
    assert.equal(r.b.by_employee.length, 1);
  } finally { await db.close(); }
});

test('MAP-009 B070 B071: انتشار الأصناف نقطة لكل عميل، وبونص فقط ومرتجع فقط فئتان، وقيمة الصنف وحده', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    await locs(db, a, [{ customer_number: '500', lat: '31.5', lng: '35.5' }, { customer_number: '501', lat: '31.5', lng: '36.5' }]);
    await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الغربية', geom: WEST, employee_id: e.r1, valid_from: '2026-01-01' } });
    await add(db, a, 'invoice', [
      // 500: فاتورتان، وتكرار الصنف في السند نفسه يعد فاتورة واحدة؛ والصنف الآخر لا يدخل القيمة
      { cust: '500', date: '2026-09-01', lines: [['A1', 100, 10, 2, 1], ['A1', 50, 0, 1, 0], ['A2', 999]] },
      { cust: '500', date: '2026-09-10', lines: [['A1', 40, 0, 1, 0]] },
      { cust: '501', date: '2026-09-05', lines: [['A1', 0, 0, 0, 3], ['A2', 20]] },
      { cust: '502', date: '2026-09-05', emp: '21', lines: [['A1', 30]] }]);
    await add(db, a, 'return', [{ cust: '503', date: '2026-09-06', lines: [['A1', 15, 0, 1, 0]] }, { cust: '500', date: '2026-09-12', lines: [['A1', 20, 0, 1, 0]] }]);
    const r = await db.rpc(a, 'product_spread', { p_product: p.A1, p_from: '2026-09-01', p_to: '2026-09-30', p_opts: {} });
    const s = r.summary;
    assert.deepEqual([s.buyers, s.invoices, num(s.value), num(s.quantity), num(s.bonus)], [2, 3, 230, 5, 4]);
    assert.deepEqual([s.bonus_only, s.return_only, num(s.returns_value)], [1, 1, 35]);
    const c500 = r.rows.find((x) => x.customer_number === '500');
    assert.deepEqual([c500.category, c500.invoices, num(c500.value), c500.first, c500.last, c500.region], ['buyer', 2, 200, '2026-09-01', '2026-09-10', 'الغربية']);
    assert.equal(r.rows.find((x) => x.customer_number === '501').category, 'bonus_only');
    assert.equal(r.rows.find((x) => x.customer_number === '503').category, 'return_only');
    assert.equal(s.no_location, 2, '502 و503 بلا موقع يبقيان في القائمة والإجمالي');
    // فلتر المندوب والمنطقة معًا
    const r2 = await db.rpc(a, 'product_spread', { p_product: p.A1, p_from: '2026-09-01', p_to: '2026-09-30', p_opts: { employees: [e.r2] } });
    assert.deepEqual(r2.rows.map((x) => x.customer_number), ['502']);
    const r3 = await db.rpc(a, 'product_spread', { p_product: p.A1, p_from: '2026-09-01', p_to: '2026-09-30', p_opts: { region_id: 'none' } });
    assert.deepEqual(r3.rows.map((x) => x.customer_number).sort(), ['501', '502', '503']);
  } finally { await db.close(); }
});

test('الصلاحيات: الاستيراد والمناطق تحتاج صلاحياتها، ونطاق العملاء يُحترم', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await add(db, a, 'invoice', [{ cust: '500', date: '2026-09-01', emp: '21', lines: [['A1', 10]] }]);
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مواقع', p_perms: [{ page: 'P16', action: 'view' }, { page: 'P16', action: 'import' }] });
    const u = await makeUser(db, a, { username: 'rep21', display_name: 'مندوب', data_scope: 'self', template_id: tpl, employee_id: e.r2 });
    const pv = await locs(db, u, [{ customer_number: '500', lat: '31', lng: '35' }, { customer_number: '501', lat: '31', lng: '35' }], false);
    assert.deepEqual([pv.counts.new, pv.counts.error], [1, 1]);
    assert.match(pv.rows[1].message, /خارج نطاق/);
    await rejects(db.rpc(u, 'save_region', { p_id: null, p: { name: 'x', geom: WEST } }), 'صلاحية');
    assert.deepEqual((await db.rpc(u, 'customer_locations', {})).map((x) => x.customer_number), ['500']);
  } finally { await db.close(); }
});
