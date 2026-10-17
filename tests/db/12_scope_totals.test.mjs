// تدقيق 15/10/2026 — A5 (B072، AUTH-002) وA6 (COMM-003): نطاق البيانات في الإغلاق والمكافآت والقواعد وتفاصيل الفريق،
// وقراءة الكشف المغلق بصلاحية العمولات لا البطاقة وحدها، وإجمالي المؤهلة دون تكرار مبيعات الفريق.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const num = (v) => (v === null || v === undefined ? v : Number(v));
const MONTH = '2026-09-01';

async function sales(db, a, rows) {
  let r = 2;
  const s = await db.rpc(a, 'upload_stage', { p_kind: 'invoice', p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: INV_COLS,
    p_rows: rows.map(([n, cust, emp, amount]) => ({ row: r++, doc_number: n, customer_number: cust, doc_date: '2026-09-05', employee_number: emp,
      pay_type: 'فاتورة ذمم', item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' })) });
  const its = await db.sql('select id from batch_items where batch_id = $1', [s.batch_id]);
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}

// مشرفان: الأول ومندوباه 20 و21، والثاني ومندوبه 22. مبيعات 1000 و500 و700؛ لا مبيعات شخصية للمشرفين.
async function setup(db) {
  const a = await seedAdmin(db);
  const e = {};
  e.s1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف أول', join_date: '2025-01-01' } });
  e.s2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '31', name: 'مشرف ثان', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.s1 } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01', supervisor_id: e.s1 } });
  e.r3 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '22', name: 'مندوب ج', join_date: '2025-01-01', supervisor_id: e.s2 } });
  for (const n of ['500', '501', '502']) await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name: 'عميل ' + n } });
  const p = await db.rpc(a, 'save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
  await db.rpc(a, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
  await sales(db, a, [['1', '500', '20', 1000], ['2', '501', '21', 500], ['3', '502', '22', 700]]);
  for (const emp of [e.r1, e.r2, e.r3]) {
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: MONTH, employee_id: emp, role: 'rep', tiers: [{ tier: 'A' }],
      components: [{ tier: 'A', metric: 'net_sales', target: 400 }] } });
  }
  for (const emp of [e.s1, e.s2]) {
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: MONTH, employee_id: emp, role: 'supervisor', tiers: [{ tier: 'A' }],
      components: [{ tier: 'A', metric: 'net_sales' }] } });
  }
  await db.rpc(a, 'save_commission_rule', { p_id: null, p: { month: MONTH, name: 'قاعدة الشهر', members: [e.s1, e.s2, e.r1, e.r2, e.r3],
    tiers: [{ tier: 'A', rep_rate: 1, sup_rate: 1 }] } });
  return { a, e };
}

const ALL_VIEW = ['P10', 'P10a', 'P11', 'P12', 'P13', 'P14', 'P14b'].map((page) => ({ page, action: 'view', granted: true }));

test('A6 COMM-003: إجمالي المؤهلة في الجاهزية ونسخة الإغلاق لا يكرر مبيعات الفريق', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const sum = await db.rpc(a, 'commission_summary', { p_month: MONTH });
    // صف المشرف يحمل مبيعات فريقه، والإجمالي غير المكرر هو مجموع المبيعات الشخصية
    assert.equal(num(sum.rows.find((r) => String(r.employee_id) === String(e.s1)).eligible), 1500);
    assert.equal(sum.rows.reduce((t, r) => t + num(r.personal_eligible), 0), 2200);
    const ready = await db.rpc(a, 'month_readiness', { p_month: MONTH });
    assert.equal(ready.blocking, false);
    assert.equal(num(ready.totals.eligible), 2200);
    await db.rpc(a, 'close_month', { p_month: MONTH, p_note: 'إغلاق' });
    const v = (await db.sql(`select totals from month_versions where month = $1`, [MONTH]))[0].totals;
    assert.equal(num(v.eligible), 2200);
  } finally { await db.close(); }
});

test('A5 B072: نطاق الفريق في الجاهزية ونظرة الأشهر والقواعد والمكافآت؛ ونسخ الإغلاق للنطاق الكامل فقط', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'save_reward', { p_id: null, p: { month: MONTH, name: 'مكافأة', role: 'rep', employees: [e.r1, e.r3],
      cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 10, stack_mode: 'STACK' } });
    const team = await makeUser(db, a, { username: 'team', display_name: 'مشرف', employee_id: e.s1, data_scope: 'team', overrides: ALL_VIEW });

    const ready = await db.rpc(team, 'month_readiness', { p_month: MONTH });
    assert.deepEqual(ready.rows.map((r) => r.name).sort(), ['مشرف أول', 'مندوب أ', 'مندوب ب']);
    assert.equal(num(ready.totals.eligible), 1500);

    const rules = await db.rpc(team, 'commission_month', { p_month: MONTH });
    assert.deepEqual(rules.rules[0].members.map((m) => m.name).sort(), ['مشرف أول', 'مندوب أ', 'مندوب ب']);
    assert.equal(rules.rules[0].hidden_members, 2);

    const rw = await db.rpc(team, 'rewards_list', { p_month: MONTH });
    assert.deepEqual(rw.plans[0].employee_names, ['مندوب أ']);
    assert.equal(num(rw.plans[0].hidden_employees), 1);
    assert.deepEqual(rw.plans[0].qualified.map((q) => q.name), ['مندوب أ']);

    await db.rpc(a, 'close_month', { p_month: MONTH, p_note: 'إغلاق' });
    const ovTeam = (await db.rpc(team, 'months_overview', {})).find((m) => m.month === MONTH);
    assert.equal(ovTeam.versions[0].totals, null);
    assert.equal(ovTeam.plans, 3);
    const ovAdmin = (await db.rpc(a, 'months_overview', {})).find((m) => m.month === MONTH);
    assert.equal(num(ovAdmin.versions[0].totals.eligible), 2200);
    assert.equal(ovAdmin.plans, 5);
    // القراءة المباشرة لنسخ الإغلاق (أهداف الجميع ونسبهم) للنطاق الكامل فقط
    assert.equal((await db.as(team, 'select count(*)::int n from month_versions'))[0].n, 0);
    const allUser = await makeUser(db, a, { username: 'all', display_name: 'محاسب', data_scope: 'all', overrides: ALL_VIEW });
    assert.equal((await db.as(allUser, 'select count(*)::int n from month_versions'))[0].n, 1);
  } finally { await db.close(); }
});

test('A5 AUTH-002: بطاقة الأداء وحدها لا تقرأ كشف العمولة المغلق، والبطاقة نفسها تعمل من النسخة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'close_month', { p_month: MONTH, p_note: 'إغلاق' });
    const cardOnly = await makeUser(db, a, { username: 'card', display_name: 'مندوب', employee_id: e.r1, data_scope: 'self',
      overrides: [{ page: 'P13', action: 'view', granted: true }] });
    assert.equal((await db.as(cardOnly, 'select count(*)::int n from month_snapshots'))[0].n, 0);
    const cards = await db.rpc(cardOnly, 'performance_cards', { p_month: MONTH, p_opts: { role: 'all' } });
    assert.equal(cards.cards.length, 1);
    assert.equal(cards.cards[0].snapshot, true);
    // صاحب صلاحية كشف العمولات يقرأ نسخته ضمن نطاقه
    const withP14 = await makeUser(db, a, { username: 'p14', display_name: 'مندوب', employee_id: e.r1, data_scope: 'self',
      overrides: [{ page: 'P14', action: 'view', granted: true }] });
    assert.equal((await db.as(withP14, 'select count(*)::int n from month_snapshots'))[0].n, 1);
  } finally { await db.close(); }
});

test('A5: تفاصيل فريق المشرف لا تُظهر اسم مندوب خارج نطاق المشاهد، والمجموع كما هو', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const sel = await makeUser(db, a, { username: 'sel', display_name: 'محدد', data_scope: 'selected', scope_employees: [e.s1], overrides: ALL_VIEW });
    const pid = (await db.sql(`select id from goal_plans where employee_id = $1`, [e.s1]))[0].id;
    const comp = (g) => g.eval.components.find((c) => c.metric === 'net_sales');
    const adminView = comp(await db.rpc(a, 'goal_plan', { p_id: pid, p_cutoff: '2026-09-30' }));
    const selView = comp(await db.rpc(sel, 'goal_plan', { p_id: pid, p_cutoff: '2026-09-30' }));
    assert.equal(num(selView.final), num(adminView.final));
    assert.equal(num(selView.final), 800);
    assert.deepEqual(adminView.team.parts.map((x) => x.name).sort(), ['مندوب أ', 'مندوب ب']);
    assert.deepEqual(selView.team.parts.map((x) => [x.name, x.hidden]), [[null, true], [null, true]]);
  } finally { await db.close(); }
});
