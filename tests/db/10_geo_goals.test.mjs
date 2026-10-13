// الأهداف الجغرافية والتغطية (GOAL-003، اعتماد 13/10/2026): نطاق المنطقة لمقاييس البيع، ومقياس التغطية النسبي.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;
let docNo = 9000;

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
const locs = (db, a, rows) => db.rpc(a, 'import_customer_locations', { p_rows: rows.map((r, i) => ({ row: i + 2, ...r })), p_commit: true });

async function scene(db) {
  const s = await setup(db);
  const { a, e } = s;
  // 500 و501 غرب، 502 شرق؛ 503 بلا موقع. الغربية للمندوب أ والشرقية للمندوب ب
  await locs(db, a, [{ customer_number: '500', lat: '31.5', lng: '35.5' }, { customer_number: '501', lat: '31.6', lng: '35.6' },
    { customer_number: '502', lat: '31.5', lng: '36.5' }]);
  const west = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الغربية', color: '#000000', geom: WEST, employee_id: e.r1, valid_from: '2026-01-01' }, p_code: null });
  const east = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الشرقية', color: '#000000', geom: [[[31, 36.001], [31, 37], [32, 37], [32, 36.001]]], employee_id: e.r2, valid_from: '2026-01-01' }, p_code: null });
  // 501 و503 من عملاء المندوب أ من أشهر سابقة؛ في سبتمبر يشتري 500 (غرب) و502 (شرق)، و501 بونص فقط
  await add(db, a, 'invoice', [
    { cust: '501', date: '2026-07-01', lines: [['A1', 30]] }, { cust: '503', date: '2026-07-01', lines: [['A1', 30]] },
    { cust: '500', date: '2026-09-05', lines: [['A1', 100]] }, { cust: '502', date: '2026-09-06', lines: [['A1', 200]] },
    { cust: '501', date: '2026-09-07', lines: [['A1', 0, 0, 0, 3]] },
  ]);
  return { ...s, west, east };
}
const mv = async (db, emp, metric, f) => num((await db.sql(
  `select app.metric_value($1, 'rep', false, '2026-09-01', '2026-09-30', $2, $3::jsonb) v`, [emp, metric, JSON.stringify(f)]))[0].v);

test('هدف منطقة: صافي المبيعات والعملاء داخل منطقة بموقع العميل المحفوظ', async () => {
  const db = await connect();
  try {
    const { e, west, east } = await scene(db);
    assert.equal(await mv(db, e.r1, 'net_sales', {}), 300);
    assert.equal(await mv(db, e.r1, 'net_sales', { region_id: west }), 100);
    assert.equal(await mv(db, e.r1, 'net_sales', { region_id: east }), 200);
    assert.equal(await mv(db, e.r1, 'customers', { region_id: west }), 1);
  } finally { await db.close(); }
});

test('التغطية: المشترون من عملاء المندوب في منطقته ÷ عملاؤه فيها؛ البونص وحده لا يغطي', async () => {
  const db = await connect();
  try {
    const { a, e, east } = await scene(db);
    // منطقة المندوب أ الغربية: عملاؤه فيها 500 و501 (503 بلا موقع لا يدخل)، اشترى 500 فقط → 50%
    assert.equal(await mv(db, e.r1, 'coverage', {}), 50);
    // منطقة محددة: الشرقية، عملاؤه فيها 502 واشترى → 100%
    assert.equal(await mv(db, e.r1, 'coverage', { region_id: east }), 100);
    // المندوب ب بلا عملاء مرتبطين في منطقته → لا قاعدة (فارغ لا صفر)
    assert.equal(await mv(db, e.r2, 'coverage', {}), null);
    // في خطة: نسبي لا يخفض بالأيام، 50 ≥ 40 فتتحقق الشريحة
    const id = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.r1, role: 'rep',
      tiers: [{ tier: 'A', logic: 'AND' }], components: [{ tier: 'A', metric: 'coverage', target: 40 }, { tier: 'A', metric: 'net_sales', target: 50, filters: { region_id: null } }] } });
    const ev = (await db.rpc(a, 'goal_plan', { p_id: id, p_cutoff: '2026-09-30' })).eval;
    const cov = ev.components.find((c) => c.metric === 'coverage');
    assert.deepEqual([cov.kind, num(cov.final), num(cov.actual), cov.has_path], ['relative', 40, 50, false]);
    assert.equal(cov.label, 'التغطية');
    assert.equal(ev.achieved, 'A');
  } finally { await db.close(); }
});

test('نسبة التنوع: الأصناف المباعة ÷ أصناف القائمة، والشرائح بأهداف لكل شريحة', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await scene(db);
    // صنفان معرّفان (A1، A2)؛ المندوب أ باع A1 فقط في سبتمبر → 50%
    assert.equal(await mv(db, e.r1, 'variety_ratio', {}), 50);
    await add(db, a, 'invoice', [{ cust: '500', date: '2026-09-20', lines: [['A2', 10]] }]);
    assert.equal(await mv(db, e.r1, 'variety_ratio', {}), 100);
    assert.equal(await mv(db, e.r1, 'variety_ratio', { products: [p.A2] }), 100, 'القائمة أصناف المكوّن');
    // B عند 80 وA عند 90: 100% تحقق A
    const id = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.r1, role: 'rep',
      tiers: [{ tier: 'A', logic: 'AND' }, { tier: 'B', logic: 'AND' }],
      components: [{ tier: 'A', metric: 'variety_ratio', target: 90 }, { tier: 'B', metric: 'variety_ratio', target: 80 }] } });
    const ev = (await db.rpc(a, 'goal_plan', { p_id: id, p_cutoff: '2026-09-30' })).eval;
    assert.equal(ev.achieved, 'A');
    assert.equal(ev.components[0].label, 'نسبة التنوع');
  } finally { await db.close(); }
});
