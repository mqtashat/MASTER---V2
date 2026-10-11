// الوحدة 1 — العملاء والمنتجات
// حالات القبول: D20، D22، D23 (الجزء المتاح)، B055، PRD-006، PRICE-002، PRICE-003، B019
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin } from './helpers.mjs';

const crow = (n, o) => ({ row: n, master_name: '', master_number: '', name: '', customer_number: '', company_id: '2', grace_days: '', ...o });

test('D20/CUS-003: الرئيسي الفارغ مستقل، واسم الرئيسي المختلف يعتمد اسم سجله مع تنبيه', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const rows = [
      crow(2, { customer_number: '500', name: 'سوبر ماركت الأمل', master_number: '500', master_name: 'سوبر ماركت الأمل' }),
      crow(3, { customer_number: '501', name: 'الأمل - فرع 2', master_number: '500', master_name: 'الأمل الرئيسي' }),
      crow(4, { customer_number: '600', name: 'مستقل', master_number: '' }),
    ];
    const pv = await db.rpc(a, 'preview_customer_import', { p_rows: rows });
    assert.equal(pv.counts.new, 3);
    assert.equal(pv.counts.warnings, 1);
    assert.match(pv.warnings[0].message, /يُعتمد اسم السجل/);
    await db.rpc(a, 'commit_customer_import', { p_rows: rows, p_decisions: {}, p_file_name: 'العملاء.xls' });
    const v = await db.sql('select customer_number, kind, master_name, effective_grace_days from customers_v order by 1');
    assert.deepEqual(v, [
      { customer_number: '500', kind: 'رئيسي', master_name: null, effective_grace_days: 30 },
      { customer_number: '501', kind: 'فرع', master_name: 'سوبر ماركت الأمل', effective_grace_days: 30 },
      { customer_number: '600', kind: 'مستقل', master_name: null, effective_grace_days: 30 },
    ]);
  } finally { await db.close(); }
});

test('D22/B037: فترة السماح السالبة مرفوضة والفارغة 30 والصفر صفر', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const pv = await db.rpc(a, 'preview_customer_import', { p_rows: [
      crow(2, { customer_number: '1', name: 'أ', grace_days: '-5' }),
      crow(3, { customer_number: '2', name: 'ب', grace_days: '7.5' }),
      crow(4, { customer_number: '3', name: 'ج', grace_days: '0' }),
      crow(5, { customer_number: '4', name: 'د', grace_days: '' }),
    ] });
    assert.deepEqual(pv.errors.map((e) => e.row), [2, 3]);
    await rejects(db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '9', name: 'x', grace_days: '-5' } }), 'فترة السماح');
    await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '10', name: 'صفر', grace_days: '0' } });
    const v = await db.sql(`select effective_grace_days from customers_v where customer_number = '10'`);
    assert.equal(v[0].effective_grace_days, 0);
  } finally { await db.close(); }
});

test('أرقام العملاء نصوص بأصفارها البادئة، وغياب العميل عن ملف لاحق لا يحذفه', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    await db.rpc(a, 'commit_customer_import', { p_rows: [crow(2, { customer_number: '0012', name: 'صفر بادئ' }), crow(3, { customer_number: '12', name: 'دونه' })], p_decisions: {}, p_file_name: 'f' });
    await db.rpc(a, 'commit_customer_import', { p_rows: [crow(2, { customer_number: '12', name: 'دونه' })], p_decisions: {}, p_file_name: 'f' });
    const v = await db.sql('select customer_number from customers order by 1');
    assert.deepEqual(v.map((x) => x.customer_number), ['0012', '12']);
  } finally { await db.close(); }
});

test('B055: تغيير ارتباط الفرع بتاريخ سريان، وإعادة الاستيراد تطلبه', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const rows = [crow(2, { customer_number: '700', name: 'رئيسي 1' }), crow(3, { customer_number: '701', name: 'رئيسي 2' }),
                  crow(4, { customer_number: '702', name: 'فرع', master_number: '700' })];
    await db.rpc(a, 'commit_customer_import', { p_rows: rows, p_decisions: {}, p_file_name: 'f' });
    const moved = rows.map((r) => (r.customer_number === '702' ? { ...r, master_number: '701' } : r));
    const pv = await db.rpc(a, 'preview_customer_import', { p_rows: moved });
    assert.deepEqual(pv.link_changes.map((l) => [l.current, l.new]), [['700', '701']]);
    await rejects(db.rpc(a, 'commit_customer_import', { p_rows: moved, p_decisions: {}, p_file_name: 'f' }), 'تاريخ سريان');
    await db.rpc(a, 'commit_customer_import', { p_rows: moved, p_decisions: { link_effective: { 702: '2026-03-01' } }, p_file_name: 'f' });
    const m = async (d) => (await db.sql(`select m.customer_number from customers c join customers m on m.id = app.master_of(c.id, $1::date) where c.customer_number = '702'`, [d]))[0]?.customer_number;
    assert.equal(await m('2026-02-28'), '700');
    assert.equal(await m('2026-03-01'), '701');
    // الرئيسي الذي هو فرع لغيره مرفوض
    await rejects(db.rpc(a, 'change_customer_master', { p_customer: (await db.sql(`select id from customers where customer_number='700'`))[0].id, p_master_number: '702', p_effective: '2026-04-01' }), 'فرع لعميل آخر');
  } finally { await db.close(); }
});

test('B065: الموقع يُزال صراحة فقط، والإحداثيات بدقتها', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const c = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '800', name: 'موقع' } });
    await db.rpc(a, 'set_customer_location', { p_customer: c, p_lat: '31.8564427', p_lng: '35.9374996' });
    const v = await db.sql('select lat, lng from customers where id = $1', [c]);
    assert.deepEqual(v[0], { lat: '31.8564427', lng: '35.9374996' });
    await rejects(db.rpc(a, 'set_customer_location', { p_customer: c, p_lat: '31.8', p_lng: null }), 'معًا');
  } finally { await db.close(); }
});

const prow = (n, o) => ({ row: n, code: '', name: '', sale: '', cost: '', packing: '',
  rep_A: '', rep_B: '', rep_C: '', rep_X: '', supervisor_A: '', supervisor_B: '', supervisor_C: '', supervisor_X: '', ...o });

test('PRD-006/PRICE-002: استيراد المنتجات بتواريخ السريان، وإعادة الرفع لا تنشئ أسعارًا وهمية', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const rows = [prow(2, { code: '101', name: 'تراوبي', sale: '9.499', cost: '7', packing: '24', rep_A: '2.5', rep_B: '2', rep_C: '1.5', rep_X: '1', supervisor_A: '3', supervisor_B: '2.5', supervisor_C: '2', supervisor_X: '1' })];
    const dates = { sale: '2026-01-01', cost: '2026-01-01', packing: '2026-01-01', rates: '2026-01-01' };
    const pv0 = await db.rpc(a, 'preview_product_import', { p_rows: rows, p_dates: {} });
    assert.deepEqual(pv0.needs_dates.sort(), ['cost', 'packing', 'rates', 'sale']);
    await rejects(db.rpc(a, 'commit_product_import', { p_rows: rows, p_dates: {}, p_file_name: 'f' }), 'تاريخ السريان');
    await db.rpc(a, 'commit_product_import', { p_rows: rows, p_dates: dates, p_file_name: 'المنتجات.xlsx' });
    const n0 = (await db.sql('select count(*)::int n from product_prices'))[0].n;
    // الملف نفسه مرة ثانية بتاريخ آخر: لا تغيير (المقارنة بالسعر الساري في التاريخ المختار)
    const pv = await db.rpc(a, 'preview_product_import', { p_rows: rows, p_dates: { sale: '2026-02-01', cost: '2026-02-01', packing: '2026-02-01', rates: '2026-02-01' } });
    assert.equal(pv.counts.unchanged, 1);
    await db.rpc(a, 'commit_product_import', { p_rows: rows, p_dates: { sale: '2026-02-01', cost: '2026-02-01', packing: '2026-02-01', rates: '2026-02-01' }, p_file_name: 'f' });
    assert.equal((await db.sql('select count(*)::int n from product_prices'))[0].n, n0);
    // سعر جديد من 15/2 ثم تصحيح السعر في التاريخ نفسه
    const r2 = [{ ...rows[0], sale: '10' }];
    await db.rpc(a, 'commit_product_import', { p_rows: r2, p_dates: { sale: '2026-02-15' }, p_file_name: 'f' });
    const r3 = [{ ...rows[0], sale: '10.5' }];
    const pv3 = await db.rpc(a, 'preview_product_import', { p_rows: r3, p_dates: { sale: '2026-02-15' } });
    assert.deepEqual(pv3.changed[0].fields.sale, [10, 10.5]);
    await db.rpc(a, 'commit_product_import', { p_rows: r3, p_dates: { sale: '2026-02-15' }, p_file_name: 'f' });
    const hist = await db.sql(`select price, effective_from from product_prices where kind = 'sale' order by effective_from`);
    assert.deepEqual(hist, [{ price: '9.499', effective_from: '2026-01-01' }, { price: '10.5', effective_from: '2026-02-15' }]);
    // السعر بتاريخ الحركة: أحدث تاريخ لا يتجاوزها
    const at = await db.sql(`select app.price_at(p.id, 'sale', '2026-02-14') a, app.price_at(p.id, 'sale', '2026-02-15') b, app.price_at(p.id, 'sale', '2025-12-31') c from products p`);
    assert.deepEqual(at[0], { a: '9.499', b: '10.5', c: null });
  } finally { await db.close(); }
});

test('PRD-006: الخلية الفارغة لا تمسح، والكود المكرر المتعارض خطأ، والقيم السالبة مرفوضة', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const d = { sale: '2026-01-01', cost: '2026-01-01', packing: '2026-01-01', rates: '2026-01-01' };
    await db.rpc(a, 'commit_product_import', { p_rows: [prow(2, { code: '200', name: 'صنف', sale: '2', cost: '1', packing: '12' })], p_dates: d, p_file_name: 'f' });
    const pv = await db.rpc(a, 'preview_product_import', { p_rows: [prow(2, { code: '200', name: 'صنف', sale: '', cost: '', packing: '' })], p_dates: d });
    assert.equal(pv.counts.unchanged, 1);
    const bad = await db.rpc(a, 'preview_product_import', { p_rows: [
      prow(2, { code: '300', name: 'أ', sale: '2' }), prow(3, { code: '300', name: 'أ', sale: '3' }),
      prow(4, { code: '301', name: 'ب', sale: '-1' }), prow(5, { code: '302', name: 'ج', packing: '0' }),
      prow(6, { code: '303', name: 'د', sale: 'abc' }),
    ], p_dates: d });
    assert.equal(bad.counts.errors, 4);
    // السعر الصفري مقبول (يظهر «سعر غير متوفر» للمكافئة لاحقًا)
    const z = await db.rpc(a, 'preview_product_import', { p_rows: [prow(2, { code: '304', name: 'هـ', sale: '0' })], p_dates: d });
    assert.equal(z.counts.errors, 0);
  } finally { await db.close(); }
});

test('PRICE-003 وصلاحية التكلفة والعمولة: تُخفى عمّن لا يملكها', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const d = { sale: '2026-01-01', cost: '2026-01-01', packing: '2026-01-01', rates: '2026-01-01' };
    await db.rpc(a, 'commit_product_import', { p_rows: [prow(2, { code: '400', name: 'صنف', sale: '2', cost: '1.25', packing: '12', rep_A: '2.5' })], p_dates: d, p_file_name: 'f' });
    const u = await db.rpc(a, 'admin_save_user', { p_id: null, p_user: { username: 'sales1', password: 'Pass#2026x', display_name: 'مبيعات', data_scope: 'all',
      overrides: [{ page: 'P04', action: 'view', granted: true }] } });
    const v = await db.as(u, 'select sale_price, cost_price, rates from products_v');
    assert.deepEqual(v[0], { sale_price: '2', cost_price: null, rates: null });
    assert.equal((await db.as(u, `select count(*)::int n from product_prices where kind = 'cost'`))[0].n, 0);
    const va = await db.as(a, 'select cost_price, rates from products_v');
    assert.deepEqual(va[0], { cost_price: '1.25', rates: { rep_A: 2.5 } });
  } finally { await db.close(); }
});

test('حذف قيمة مؤرخة إجراء صريح بسبب', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const p = await db.rpc(a, 'save_product', { p_id: null, p_code: '500', p_name: 'صنف' });
    await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'packing', p_value: 24, p_date: '2026-01-01' });
    await rejects(db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'packing', p_value: 0, p_date: '2026-02-01' }), 'أكبر من صفر');
    await rejects(db.rpc(a, 'remove_product_value', { p_product: p, p_kind: 'packing', p_date: '2026-01-01', p_reason: '' }), 'سبب');
    await db.rpc(a, 'remove_product_value', { p_product: p, p_kind: 'packing', p_date: '2026-01-01', p_reason: 'خطأ' });
    assert.equal((await db.sql('select count(*)::int n from product_packing'))[0].n, 0);
  } finally { await db.close(); }
});
