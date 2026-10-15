// إضافات الأهداف والعمولات 15/10/2026 (0014): GOAL-018 ترتيب الشرائح، GOAL-019 الجدول الجماعي، A3 فلاتر هدف المشرف،
// A4 منطقة التحصيل بأساس مندوب الفاتورة، REWARD-003/004 تجاوز هدف A وتعدد الأشهر، COMM-009 استثناءات الموظف،
// COMM-010 التصاعدية، COMM-011 التنويع بحصص المجموعات، COMM-012 إلغاء قرارات الشهر، PRD-009 المجموعات، B1–B6.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;
let docNo = 5000;
const M = '2026-09-01';

async function add(db, a, kind, docs) {
  const rows = [];
  for (const d of docs) {
    const n = d.num ?? String(docNo++);
    if (kind === 'collection') {
      rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20', amount: String(d.amount), pay_method: 'نقدي', cheque_no: '' });
    } else {
      for (const [item, ns, np = 0, qty = 1, bonus = 0] of d.lines) {
        rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20', pay_type: d.pay ?? 'فاتورة ذمم',
          item_number: item, item_name: 'صنف', net_sales: String(ns), net_promotions: String(np), quantity: String(qty), bonus: String(bonus) });
      }
    }
  }
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS;
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rows });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  assert.deepEqual(its.flatMap((i) => i.errors), [], 'أخطاء رفع');
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}
const inv = (db, a, docs) => add(db, a, 'invoice', docs);

async function setup(db) {
  const a = await seedAdmin(db);
  const e = {};
  e.sup = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.sup } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01', supervisor_id: e.sup } });
  const c = {};
  for (const n of ['500', '501', '502', '503']) c[n] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name: 'عميل ' + n } });
  const p = {};
  for (const code of ['A1', 'A2', 'A3']) {
    p[code] = await db.rpc(a, 'save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
    await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
  }
  return { a, e, c, p };
}
const tiersABC = [{ tier: 'A', logic: 'AND' }, { tier: 'B', logic: 'AND' }, { tier: 'C', logic: 'AND' }];
const plan = (db, a, emp, comps, month = M, extra = {}) => db.rpc(a, 'save_goal_plan', { p_id: null, p: {
  month, employee_id: emp, role: 'rep', tiers: tiersABC, components: comps, ...extra } });
const evalOf = async (db, a, id, cutoff = '2026-09-30') => (await db.rpc(a, 'goal_plan', { p_id: id, p_cutoff: cutoff })).eval;
const rule = (db, a, members, tiers, extra = {}, month = M) => db.rpc(a, 'save_commission_rule', { p_id: null, p: {
  month, name: 'قاعدة ' + month, members, tiers: tiers ?? [{ tier: 'A', rep_rate: 2, sup_rate: 2 }], ...extra } });
const stmt = (db, a, emp, month = M) => db.rpc(a, 'commission_statement', { p_employee: emp, p_month: month });

test('GOAL-018: ترتيب الشرائح يمنع الحفظ في الخطة والقالب والتعديل الجماعي؛ والمساواة وفلاتر مختلفة مسموحة', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    await rejects(plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 1000 }, { tier: 'B', metric: 'net_sales', target: 1500 }]), 'ترتيب الشرائح');
    // المساواة مسموحة، والمكوّنات بفلاتر مختلفة لا تُقارن، والهدف الفارغ لا يدخل المقارنة
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 1000 }, { tier: 'B', metric: 'net_sales', target: 1000 },
      { tier: 'C', metric: 'net_sales', target: 5000, filters: { products: [p.A1] } }, { tier: 'B', metric: 'customers', target: null }]);
    assert.ok(id);
    await rejects(db.rpc(a, 'save_goal_template', { p_id: null, p_name: 'قالب خاطئ', p_role: 'rep', p_data: { tiers: tiersABC,
      components: [{ tier: 'A', metric: 'customers', target: 10 }, { tier: 'C', metric: 'customers', target: 20 }] } }), 'ترتيب الشرائح');
    const id2 = await plan(db, a, e.r2, [{ tier: 'A', metric: 'net_sales', target: 1000 }, { tier: 'B', metric: 'net_sales', target: 800 }]);
    await rejects(db.rpc(a, 'bulk_adjust_goals', { p_plans: `{${id2}}`, p_tier: 'B', p_metric: 'net_sales', p_mode: 'set', p_value: 2000, p_commit: true, p_reason: 'اختبار' }), 'ترتيب الشرائح');
  } finally { await db.close(); }
});

test('A3 GOAL-011: هدف المشرف من مجموع فريقه يطابق فلاتر المكوّن: مكوّن مجموعة أصناف يجمع أهداف المكوّن نفسه فقط', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    for (const r of [e.r1, e.r2]) {
      await plan(db, a, r, [{ tier: 'A', metric: 'net_sales', target: 10000, sort: 1 },
        { tier: 'A', metric: 'net_sales', target: 2000, sort: 2, filters: { products: [p.A1] } }]);
    }
    const sid = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: M, employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A' }],
      components: [{ tier: 'A', metric: 'net_sales', sort: 1 }, { tier: 'A', metric: 'net_sales', sort: 2, filters: { products: [p.A1] } }] } });
    const ev = await evalOf(db, a, sid);
    const finals = ev.components.sort((x, y) => x.sort - y.sort).map((c) => num(c.final));
    assert.deepEqual(finals, [20000, 4000]);
    // مكوّن بفلاتر لا مطابق لها عند المندوبين: لا أعضاء فيه فيكون غير مستخدم
    const sid2 = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-10-01', employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A' }],
      components: [{ tier: 'A', metric: 'net_sales', filters: { products: [p.A2] } }] } });
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 777 }], '2026-10-01');
    const ev2 = await evalOf(db, a, sid2, '2026-10-31');
    assert.equal(ev2.components[0].status, 'unused');
  } finally { await db.close(); }
});

test('A4 GOAL-017: هدف التحصيل بأساس مندوب الفاتورة يحترم المنطقة، ونسبة التحصيل ببسط ومقام من المنطقة نفسها', async () => {
  const db = await connect();
  try {
    const { a, e, c } = await setup(db);
    await db.rpc(a, 'import_customer_locations', { p_rows: [{ row: 2, customer_number: '500', lat: '31.5', lng: '35.5' },
      { row: 3, customer_number: '501', lat: '31.5', lng: '36.5' }], p_commit: true });
    const west = await db.rpc(a, 'save_region', { p_id: null, p: { name: 'الغربية', color: '#000000', geom: [[[31, 35], [31, 36], [32, 36], [32, 35]]],
      employee_id: e.r1, valid_from: '2026-01-01' }, p_code: null });
    await inv(db, a, [{ cust: '500', date: '2026-09-02', lines: [['A1', 1000]] }, { cust: '501', date: '2026-09-02', lines: [['A1', 1000]] }]);
    await add(db, a, 'collection', [{ cust: '500', date: '2026-09-10', amount: 600 }, { cust: '501', date: '2026-09-10', amount: 400 }]);
    const id = await plan(db, a, e.r1, [
      { tier: 'A', metric: 'collection', target: 1, sort: 1, filters: { basis: 'invoice_rep', region_id: west } },
      { tier: 'A', metric: 'collection', target: 1, sort: 2, filters: { basis: 'invoice_rep' } },
      { tier: 'A', metric: 'collection_ratio', target: 1, sort: 3, filters: { basis: 'invoice_rep', region_id: west } }]);
    const ev = await evalOf(db, a, id);
    const by = (s) => ev.components.find((x) => x.sort === s);
    assert.equal(num(by(1).actual), 600);
    assert.equal(num(by(2).actual), 1000);
    assert.equal(num(by(3).actual), 60);
    assert.ok(c);
  } finally { await db.close(); }
});

test('REWARD-003/004: مكافأة تجاوز هدف A الأصلي بمستويات (مبلغ أو نسبة) لأعلى مستوى فقط، وتُقيَّم في كل شهر منفردًا', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1700]] }, { cust: '501', date: '2026-10-05', lines: [['A1', 2600]] }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 1000 }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 2000 }], '2026-10-01');
    const levels = [{ kind: 'amount', over: 200, reward: 30 }, { kind: 'percent', over: 50, reward: 100 }];
    const rid = await db.rpc(a, 'save_reward', { p_id: null, p: { month: M, to_month: '2026-10-01', name: 'تجاوز A', role: 'rep', employees: null,
      cond_type: 'over_target', over_levels: levels, stack_mode: 'STACK' } });
    // أيلول: تجاوز 700 ← المستويان محققان، الأعلى عتبة (50% من 1000 = 500) فيُصرف 100
    let s = await stmt(db, a, e.r1);
    assert.deepEqual(s.rewards.map((r) => [num(r.amount), r.counted]), [[100, true]]);
    // تشرين الأول: تجاوز 600 من 2000 ← مستوى المبلغ 200 فقط (50% = 1000 لم يتحقق) فيُصرف 30
    s = await stmt(db, a, e.r1, '2026-10-01');
    assert.deepEqual(s.rewards.map((r) => num(r.amount)), [30]);
    // تشرين الثاني خارج السريان
    assert.deepEqual((await stmt(db, a, e.r1, '2026-11-01')).rewards, []);
    // الصفحة تعرضها في الشهرين
    assert.equal((await db.rpc(a, 'rewards_list', { p_month: '2026-10-01' })).plans.length, 1);
    assert.equal((await db.rpc(a, 'rewards_list', { p_month: '2026-11-01' })).plans.length, 0);
    // التحقق: للمندوبين فقط، ومستوى صحيح، وشهر نهاية بعد البداية
    await rejects(db.rpc(a, 'save_reward', { p_id: null, p: { month: M, name: 'x', role: 'all', cond_type: 'over_target', over_levels: levels, stack_mode: 'STACK' } }), 'للمندوبين فقط');
    await rejects(db.rpc(a, 'save_reward', { p_id: null, p: { month: M, name: 'x', role: 'rep', cond_type: 'over_target', over_levels: [{ kind: 'amount', over: 0, reward: 5 }], stack_mode: 'STACK' } }), 'أكبر من صفر');
    await rejects(db.rpc(a, 'save_reward', { p_id: rid, p: { name: 'x', role: 'rep', to_month: '2026-08-01', cond_type: 'over_target', over_levels: levels, stack_mode: 'STACK' } }), 'قبل شهر البداية');
    // موظف بلا هدف A لصافي المبيعات: لا مكافأة وتنبيه
    const s2 = await stmt(db, a, e.r2);
    assert.deepEqual(s2.rewards, []);
  } finally { await db.close(); }
});

test('COMM-009: حد أدنى للمبيعات يصفّر الأساسية فقط وتبقى المكافآت؛ ونسبة يدوية تحل محل نسبة الشريحة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }, { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 1000]] }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    await db.rpc(a, 'save_reward', { p_id: null, p: { month: M, name: 'مكافأة الشريحة', role: 'rep', cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 25, stack_mode: 'STACK' } });
    await rule(db, a, [{ employee_id: e.r1, min_sales: 1500 }, { employee_id: e.r2, manual_rate: 7 }]);
    const s1 = await stmt(db, a, e.r1);
    assert.equal(num(s1.base_original), 20);                     // 1000 × 2%
    assert.equal(num(s1.base_commission), 0);                    // دون الحد الأدنى 1500
    assert.equal(num(s1.rewards_total), 25);
    assert.equal(num(s1.final), 25);
    assert.ok(s1.warnings.some((w) => w.code === 'below_min_sales' && !w.blocking));
    assert.equal(s1.extras.below_min, true);
    // نسبة يدوية 7% لموظف بلا خطة ولا شريحة
    const s2 = await stmt(db, a, e.r2);
    assert.equal(s2.tier_effective, 'NONE');
    assert.equal(num(s2.base_commission), 70);
    assert.ok(s2.lines.every((l) => l.src === 'manual'));
    // بلوغ الحد الأدنى يرفع التصفير
    await inv(db, a, [{ cust: '502', date: '2026-09-06', lines: [['A1', 600]] }]);
    assert.equal(num((await stmt(db, a, e.r1)).base_commission), 32);
  } finally { await db.close(); }
});

test('COMM-010: القاعدة التصاعدية: نسبة إضافية لكل خطوة فوق الحد بسقف على كل المبيعات المؤهلة، والتحقق من الاكتمال والحد', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 14500]] }, { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 11200]] }]);
    for (const r of [e.r1, e.r2]) await plan(db, a, r, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    await rule(db, a, [e.r1, e.r2], [{ tier: 'A', rep_rate: 2 }], { prog_threshold: 10000, prog_step: 1000, prog_add: 0.5, prog_cap: 2 });
    const s1 = await stmt(db, a, e.r1);          // 4 خطوات × 0.5 = 2 (السقف 2) ← 4%
    assert.equal(num(s1.extras.prog), 2);
    assert.equal(num(s1.base_commission), 580);
    const s2 = await stmt(db, a, e.r2);          // خطوة واحدة ← 2.5%
    assert.equal(num(s2.extras.prog), 0.5);
    assert.equal(num(s2.base_commission), 280);
    await rejects(rule(db, a, [], [{ tier: 'A', rep_rate: 2 }], { prog_step: 1000 }, '2026-10-01'), 'معًا');
    await rejects(rule(db, a, [], [{ tier: 'A', rep_rate: 99 }], { prog_threshold: 0, prog_step: 1000, prog_add: 0.5, prog_cap: 2 }, '2026-10-01'), 'يتجاوز الحد');
  } finally { await db.close(); }
});

test('PRD-009 وCOMM-011: مجموعات أصناف عامة ومستويات تنويع بحصصها تضيف نسبة إلى نسبة الشريحة؛ لا تقاطع بين المجموعات', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    const g1 = await db.rpc(a, 'save_product_group', { p_id: null, p_name: 'المكسرات', p_products: `{${p.A1},${p.A2}}` });
    const g2 = await db.rpc(a, 'save_product_group', { p_id: null, p_name: 'الحلويات', p_products: `{${p.A3}}` });
    await rejects(db.rpc(a, 'save_product_group', { p_id: null, p_name: 'المكسرات', p_products: `{${p.A3}}` }), 'مستعمل');
    assert.equal((await db.rpc(a, 'product_groups_list', {})).length, 2);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 600], ['A2', 100], ['A3', 300]] },
      { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 900], ['A3', 100]] }]);
    for (const r of [e.r1, e.r2]) await plan(db, a, r, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    const div = [{ add_rate: 1, shares: { [g1]: 30, [g2]: 20 } }, { add_rate: 0.5, shares: { [g1]: 30 } }];
    const rid = await rule(db, a, [e.r1, e.r2], [{ tier: 'A', rep_rate: 2 }], { diversification: div });
    const s1 = await stmt(db, a, e.r1);   // g1 = 70% وg2 = 30% ← المستوى الأول: 2 + 1 = 3%
    assert.equal(num(s1.extras.div), 1);
    assert.equal(num(s1.base_commission), 30);
    assert.equal(num(s1.extras.shares[g1]), 70);
    const s2 = await stmt(db, a, e.r2);   // g2 = 10% < 20 ← المستوى الثاني: 2.5%
    assert.equal(num(s2.extras.div), 0.5);
    assert.equal(num(s2.extras.div_level), 2);
    assert.equal(num(s2.base_commission), 25);
    // المجموعة المستعملة في قاعدة لا تُحذف
    await rejects(db.rpc(a, 'delete_product_group', { p_id: g1, p_reason: 'x' }), 'مستعملة');
    // تقاطع أصناف مجموعتين في القاعدة نفسها
    const g3 = await db.rpc(a, 'save_product_group', { p_id: null, p_name: 'مختلطة', p_products: `{${p.A1}}` });
    await rejects(rule(db, a, [], [{ tier: 'A', rep_rate: 2 }], { diversification: [{ add_rate: 1, shares: { [g1]: 30, [g3]: 10 } }] }, '2026-10-01'), 'مجموعتين');
    await rejects(rule(db, a, [], [{ tier: 'A', rep_rate: 99.5 }], { diversification: [{ add_rate: 1, shares: { [g1]: 30 } }] }, '2026-10-01'), 'يتجاوز الحد');
    // حفظ القاعدة نفسها يحتفظ بالمستويات، ونسخها لشهر يحمل التنويع والاستثناءات
    assert.equal((await db.rpc(a, 'commission_month', { p_month: M })).rules[0].diversification.length, 2);
    await db.rpc(a, 'delete_commission_rule', { p_id: rid, p_reason: 'تنظيف' });
    await db.rpc(a, 'delete_product_group', { p_id: g1, p_reason: 'لم تعد مستعملة' });
  } finally { await db.close(); }
});

test('COMM-009/010/011 ونسخ القواعد: النسخ لشهر آخر يحمل الاستثناءات والتصاعدية والتنويع', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    const g1 = await db.rpc(a, 'save_product_group', { p_id: null, p_name: 'ج', p_products: `{${p.A1}}` });
    await rule(db, a, [{ employee_id: e.r1, min_sales: 500, manual_rate: 3 }], [{ tier: 'A', rep_rate: 2 }],
      { prog_threshold: 100, prog_step: 50, prog_add: 0.1, prog_cap: 1, diversification: [{ add_rate: 0.5, shares: { [g1]: 40 } }] });
    assert.equal(await db.rpc(a, 'copy_commission_rules', { p_from: M, p_to: '2026-10-01' }), 1);
    const r = (await db.rpc(a, 'commission_month', { p_month: '2026-10-01' })).rules[0];
    assert.equal(num(r.members[0].min_sales), 500);
    assert.equal(num(r.members[0].manual_rate), 3);
    assert.equal(num(r.prog_cap), 1);
    assert.equal(r.diversification.length, 1);
  } finally { await db.close(); }
});

test('COMM-012: إلغاء كل قرارات الشهر المفتوح دفعة واحدة بسبب ومعاينة؛ والمغلق يحتاج فتحه', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'Sec#2026' });
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }, { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 1000]] }]);
    await rule(db, a, [e.sup, e.r1, e.r2], [{ tier: 'A', rep_rate: 2, sup_rate: 2 }]);
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: M, employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales' }] } });
    for (const r of [e.r1, e.r2]) await plan(db, a, r, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    for (const r of [e.r1, e.r2]) await db.rpc(a, 'save_commission_adjustment', { p_employee: r, p_month: M, p: { kind: 'add', amount: 10, reason: 'جهد' } });
    await db.rpc(a, 'save_commission_adjustment', { p_employee: e.r1, p_month: M, p: { kind: 'deduct', amount: 3, reason: 'خصم' } });
    const pv = await db.rpc(a, 'cancel_month_adjustments', { p_month: M, p_reason: null, p_commit: false });
    assert.equal(pv.count, 3);
    assert.deepEqual(pv.employees.map((x) => x.count).sort(), [1, 2]);
    assert.equal(num((await stmt(db, a, e.r1)).adjustments_total), 7);   // المعاينة لا تغير شيئًا
    await rejects(db.rpc(a, 'cancel_month_adjustments', { p_month: M, p_reason: '', p_commit: true }), 'سبب الإلغاء');
    await db.rpc(a, 'cancel_month_adjustments', { p_month: M, p_reason: 'قرارات خاطئة', p_commit: true });
    assert.equal(num((await stmt(db, a, e.r1)).adjustments_total), 0);
    assert.equal(num((await stmt(db, a, e.r2)).final), 20);
    assert.equal((await db.sql(`select count(*)::int n from commission_adjustments where status = 'active'`))[0].n, 0);
    await db.rpc(a, 'close_month', { p_month: M, p_note: 'إغلاق' });
    await rejects(db.rpc(a, 'cancel_month_adjustments', { p_month: M, p_reason: 'x', p_commit: false }), 'مغلق');
  } finally { await db.close(); }
});

test('GOAL-019: الجدول الجماعي: معاينة بحالات جديد/متغير/بلا تغيير/خطأ، والاعتماد كله أو لا شيء بسبب واحد', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const structure = { partial_mode: 'proportional', tiers: [{ tier: 'A', logic: 'AND' }, { tier: 'B', logic: 'AND' }],
      components: [{ key: 'a_net', tier: 'A', metric: 'net_sales' }, { key: 'b_net', tier: 'B', metric: 'net_sales' }, { key: 'a_cust', tier: 'A', metric: 'customers' }] };
    const rows = [{ employee_id: e.r1, targets: { a_net: 1000, b_net: 800, a_cust: 10 } }, { employee_id: e.r2, targets: { a_net: 2000, b_net: 3000, a_cust: 10 } }];
    let pv = await db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: rows, p_commit: false });
    assert.deepEqual(pv.rows.map((r) => r.state), ['new', 'error']);
    assert.match(pv.rows[1].error, /ترتيب الشرائح/);
    assert.equal((await db.sql('select count(*)::int n from goal_plans'))[0].n, 0);
    await rejects(db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: rows, p_commit: true, p_reason: 'تعميم' }), 'لم يُحفظ شيء');
    assert.equal((await db.sql('select count(*)::int n from goal_plans'))[0].n, 0);
    await rejects(db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: [rows[0]], p_commit: true }), 'سبب الحفظ');
    rows[1].targets.b_net = 1500;
    const done = await db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: rows, p_commit: true, p_reason: 'أهداف أيلول' });
    assert.deepEqual(done.counts, { new: 2, changed: 0, same: 0, error: 0 });
    assert.equal((await db.sql('select count(*)::int n from goal_plans'))[0].n, 2);
    // إعادة الحفظ نفسه: بلا تغيير ولا ضجيج في سجل العمليات
    const audits = (await db.sql(`select count(*)::int n from audit_log where entity = 'goal_plans'`))[0].n;
    const again = await db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: rows, p_commit: true, p_reason: 'إعادة' });
    assert.deepEqual(again.counts, { new: 0, changed: 0, same: 2, error: 0 });
    assert.equal((await db.sql(`select count(*)::int n from audit_log where entity = 'goal_plans'`))[0].n, audits);
    // تعديل رقم واحد: متغير لصف واحد، والمكوّن الفارغ غير مستخدم
    rows[0].targets.a_net = 1200; rows[0].targets.a_cust = null;
    const ch = await db.rpc(a, 'bulk_save_goal_plans', { p_month: M, p_role: 'rep', p_structure: structure, p_rows: rows, p_commit: true, p_reason: 'تعديل' });
    assert.deepEqual(ch.counts, { new: 0, changed: 1, same: 1, error: 0 });
    const id1 = (await db.sql('select id from goal_plans where employee_id = $1', [e.r1]))[0].id;
    const ev = await evalOf(db, a, id1);
    assert.equal(ev.components.find((c) => c.metric === 'customers').status, 'unused');
  } finally { await db.close(); }
});

test('B6 B060: نسبة التنويع تقارن بالهدف دون تقريب مسبق (66.666… لا تحقق 66.67)', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 100], ['A2', 100]] }]);
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'variety_ratio', target: 66.67, filters: { products: [p.A1, p.A2, p.A3] } },
      { tier: 'B', metric: 'variety_ratio', target: 66.66, filters: { products: [p.A1, p.A2, p.A3] } }]);
    const ev = await evalOf(db, a, id);
    assert.equal(ev.components.find((c) => c.tier === 'A').met, false);
    assert.equal(ev.components.find((c) => c.tier === 'B').met, true);
  } finally { await db.close(); }
});

test('B2 B062: المستحق النهائي يثبت لثلاث منازل مرة واحدة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 0.33333 }]);
    const s = await stmt(db, a, e.r1);
    assert.equal(String(num(s.base_commission)), '3.3333');
    assert.equal(String(num(s.final)), '3.333');
  } finally { await db.close(); }
});

test('B1 COMM-007: تسديد فاتورة من شهر بلا قاعدة للموظف إعداد ناقص يمنع الإغلاق ولا يُحسب بنسب الأصناف', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-08-01', p_on: true });
    await inv(db, a, [{ cust: '500', date: '2026-08-10', lines: [['A1', 1000]] }]);
    await add(db, a, 'collection', [{ cust: '500', date: '2026-09-05', amount: 1000 }]);
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 2 }]);       // قاعدة أيلول فقط
    const s = await stmt(db, a, e.r1);
    const w = s.warnings.find((x) => x.code === 'no_rule_paid_month');
    assert.ok(w && w.blocking);
    assert.equal(s.status, 'incomplete');
  } finally { await db.close(); }
});

test('B4: قائمة المؤجل لا تضم فاتورة تجاوزت عمر الدين (لن تستحق عمولة)', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-03-01', p_on: true });
    await inv(db, a, [{ cust: '500', date: '2026-03-01', lines: [['A1', 1000]] }, { cust: '501', date: '2026-09-20', lines: [['A1', 500]] }]);
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 2 }]);
    const s = await stmt(db, a, e.r1);
    assert.deepEqual(s.deferred.map((x) => num(x.remaining)), [500]);
  } finally { await db.close(); }
});

test('B3: مبيعات المشرف الشخصية في صفحة القواعد صافية المرتجعات (5000 − 1000 = 4000)', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', emp: '30', lines: [['A1', 5000]] }]);
    await add(db, a, 'return', [{ cust: '500', date: '2026-09-08', emp: '30', pay: 'فاتورة نقدي', lines: [['A1', 1000]] }]);
    const m = await db.rpc(a, 'commission_month', { p_month: M });
    assert.equal(num(m.personal_rates.find((x) => String(x.employee_id) === String(e.sup)).personal_sales), 4000);
  } finally { await db.close(); }
});
