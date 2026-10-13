// الوحدة 4 — الأهداف والعمولات: التقويم والأيام، اشتقاق الهدف، المقاييس، الشرائح والمسار، هدف المشرف،
// قواعد العمولة ومصدر النسبة، عمولة التحصيل، المكافآت، قرارات الصرف، الإغلاق وإعادة الفتح والفروق.
// حالات القبول: G01–G41 (acceptance-cases.md)، CAL-002..008، GOAL-004..017، CARD-003..015، COMM-002..008، B013–B027، B075–B077
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const RET_COLS = INV_COLS.filter((c) => c !== 'DocumentTypeID');
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
const num = (v) => (v === null || v === undefined ? v : Number(v));
let rowNo = 2;
let docNo = 1000;

// docs: [{cust, date, emp, pay, lines: [[item, ns, np, qty, bonus]], num}] أو للتحصيل {cust, date, emp, amount}
async function add(db, a, kind, docs) {
  const rows = [];
  for (const d of docs) {
    const n = d.num ?? String(docNo++);
    if (kind === 'collection') {
      rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20',
        amount: String(d.amount), pay_method: 'نقدي', cheque_no: '' });
    } else {
      for (const [item, ns, np = 0, qty = 1, bonus = 0] of d.lines) {
        rows.push({ row: rowNo++, doc_number: n, customer_number: d.cust, doc_date: d.date, employee_number: d.emp ?? '20',
          pay_type: d.pay ?? 'فاتورة ذمم', item_number: item, item_name: 'صنف', net_sales: String(ns), net_promotions: String(np),
          quantity: String(qty), bonus: String(bonus) });
      }
    }
  }
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? RET_COLS : INV_COLS;
  const s = await db.rpc(a, 'upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rows });
  const its = await db.sql('select id, errors from batch_items where batch_id = $1 order by seq', [s.batch_id]);
  const errs = its.flatMap((i) => i.errors);
  assert.deepEqual(errs, [], 'أخطاء رفع: ' + JSON.stringify(errs));
  await db.rpc(a, 'upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}
const inv = (db, a, docs) => add(db, a, 'invoice', docs);
const ret = (db, a, docs) => add(db, a, 'return', docs);
const coll = (db, a, docs) => add(db, a, 'collection', docs);

async function setup(db) {
  const a = await seedAdmin(db);
  const e = {};
  e.sup = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف', join_date: '2025-01-01' } });
  e.r1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أ', join_date: '2025-01-01', supervisor_id: e.sup } });
  e.r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ب', join_date: '2025-01-01', supervisor_id: e.sup } });
  const c = {};
  for (const [n, name, grace] of [['500', 'بقالة', null], ['501', 'سوبرماركت', null], ['502', 'مبيعات نقدية - فرع', null], ['503', 'محل', null],
    ['504', 'كشك', null], ['505', 'مخبز', null]]) {
    c[n] = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: n, name, grace_days: grace } });
  }
  const p = {};
  for (const code of ['A1', 'A2', 'A3', 'A4', 'A5', 'A6']) {
    p[code] = await db.rpc(a, 'save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
    await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
    for (const [t, rr, sr] of [['A', 3, 3], ['B', 2.5, 2.5], ['C', 2, 2], ['X', 1, 1]]) {
      await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'rep_' + t, p_value: String(rr), p_date: '2025-01-01' });
      await db.rpc(a, 'set_product_value', { p_product: p[code], p_kind: 'supervisor_' + t, p_value: String(sr), p_date: '2025-01-01' });
    }
  }
  // أيلول 2026: 30 يومًا منها 4 جمع → 26 يوم عمل؛ عطلة عامة في 1/9 تجعلها 25 (CAL-007)
  await db.rpc(a, 'save_holiday', { p_id: null, p: { start_date: '2026-09-01', name: 'عطلة عامة' } });
  return { a, e, c, p };
}

const plan = (db, a, emp, comps, extra = {}) => db.rpc(a, 'save_goal_plan', { p_id: null, p: {
  month: '2026-09-01', employee_id: emp, role: 'rep',
  tiers: [{ tier: 'A', logic: 'AND' }, { tier: 'B', logic: 'AND' }, { tier: 'C', logic: 'AND' }, { tier: 'X', logic: 'AND' }],
  components: comps, ...extra } });
const evalOf = async (db, a, id, cutoff = '2026-09-30') => (await db.rpc(a, 'goal_plan', { p_id: id, p_cutoff: cutoff })).eval;
const comp = (ev, metric, tier = 'A') => ev.components.find((c) => c.metric === metric && c.tier === tier);
const exc = (db, a, emp, s, e, mode) => db.rpc(a, 'save_exception', { p_id: null, p: { employee_id: emp, start_date: s, end_date: e, mode, reason: 'إجازة' } });

test('CAL-007/CAL-003 G05: 25 يومًا، استثناء ثابت 2 ومتناسب 3 ← أيام 20 وهدف 8800، والترتيب لا يغير', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
    let ev = await evalOf(db, a, id);
    assert.equal(ev.days.D, 25);
    assert.equal(num(comp(ev, 'net_sales').final), 10000);
    // متناسب أولًا ثم ثابت
    await exc(db, a, e.r1, '2026-09-14', '2026-09-16', 'proportional');
    await exc(db, a, e.r1, '2026-09-21', '2026-09-22', 'fixed');
    ev = await evalOf(db, a, id);
    assert.equal(ev.days.total, 20);
    assert.equal(num(comp(ev, 'net_sales').final), 8800);
    assert.equal(num(comp(ev, 'net_sales').original), 10000);
    // العطلة الأسبوعية داخل الاستثناء لا تخصم مرة أخرى؛ والتعارض بين ثابت ومتناسب لليوم نفسه يُظهر
    await rejects(exc(db, a, e.r1, '2026-09-16', '2026-09-17', 'fixed'), 'تعارض');
    // ترتيب معاكس على موظف آخر يعطي النتيجة نفسها
    const id2 = await plan(db, a, e.r2, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
    await exc(db, a, e.r2, '2026-09-21', '2026-09-22', 'fixed');
    await exc(db, a, e.r2, '2026-09-14', '2026-09-16', 'proportional');
    const ev2 = await evalOf(db, a, id2);
    assert.equal(ev2.days.total, 20);
    assert.equal(num(comp(ev2, 'net_sales').final), 8800);
    // GOAL-009: تعطيل التأثر يعيد الأصل دون تخفيض متبقٍ، والأيام تبقى 20
    await db.rpc(a, 'save_goal_plan', { p_id: id2, p: { tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 10000, affected: false }] }, p_reason: 'تعطيل التأثر' });
    const ev3 = await evalOf(db, a, id2);
    assert.equal(num(comp(ev3, 'net_sales').final), 10000);
    assert.equal(ev3.days.total, 20);
    // التعديل يحتاج سببًا (GOAL-001)
    await rejects(db.rpc(a, 'save_goal_plan', { p_id: id2, p: { tiers: [], components: [] } }), 'سبب التعديل');
  } finally { await db.close(); }
});

test('CAL-008 G06: أهلية 10 من 25 بهدف متناسب ← 4000، ثم استثناء متناسب 2 ← 3200 وأيام 8؛ الثابت 10000', async () => {
  const db = await connect();
  try {
    const { a } = await setup(db);
    const emp = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '40', name: 'ملتحق', join_date: '2026-09-17' } });
    const days = await db.rpc(a, 'calendar_month', { p_month: '2026-09-01', p_employee: emp });
    assert.equal(days.emp_days.E, 12);   // 17..30 دون 18 و25 (جمعة)
    await db.rpc(a, 'correct_employment_period', { p_period: (await db.sql('select id from employment_periods where employee_id = $1', [emp]))[0].id,
      p_start: '2026-09-20', p_end: null, p_reason: 'تصحيح' });
    const d2 = await db.rpc(a, 'calendar_month', { p_month: '2026-09-01', p_employee: emp });
    assert.equal(d2.emp_days.E, 10);
    const id = await plan(db, a, emp, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
    let ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'net_sales').final), 4000);
    await exc(db, a, emp, '2026-09-21', '2026-09-22', 'proportional');
    ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'net_sales').final), 3200);
    assert.equal(ev.days.total, 8);
    await db.rpc(a, 'save_goal_plan', { p_id: id, p: { partial_mode: 'fixed', tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 10000 }] }, p_reason: 'ثابت' });
    ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'net_sales').final), 8000);   // B = 10000 ثم الاستثناء المتناسب 10000 × 8 ÷ 10
  } finally { await db.close(); }
});

test('GOAL-008 G07 وB016 G22: هدف العملاء 158.4 ← 159، والنسبي لا يخفض بالأيام', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'customers', target: 180 }, { tier: 'A', metric: 'collection_ratio', target: 80 }]);
    await exc(db, a, e.r1, '2026-09-14', '2026-09-16', 'proportional');
    const ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'customers').final), 159);
    assert.equal(num(comp(ev, 'collection_ratio').final), 80);
    assert.equal(comp(ev, 'collection_ratio').has_path, false);
  } finally { await db.close(); }
});

test('B006/B008–B010 G01–G04 وGOAL-014 G36: الإجمالي والصافي والعملاء والفواتير والتنوع؛ البونص وحده لا يشتري', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [
      { cust: '500', date: '2026-09-02', lines: [['A1', 100, 50]] },
      { cust: '500', date: '2026-09-03', lines: [['A2', 10], ['A3', 10], ['A4', 10], ['A5', 10]] },
      { cust: '500', date: '2026-09-05', lines: [['A1', 5]] },
      { cust: '501', date: '2026-09-03', lines: [['A6', 0, 0, 0, 3]] },
    ]);
    await ret(db, a, [{ cust: '500', date: '2026-09-04', lines: [['A1', 20]] }]);
    const id = await plan(db, a, e.r1, ['net_sales', 'gross_sales', 'customers', 'invoices', 'variety'].map((m) => ({ tier: 'A', metric: m, target: 1 })));
    const ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'gross_sales').actual), 195);
    assert.equal(num(comp(ev, 'net_sales').actual), 175);
    assert.equal(num(comp(ev, 'customers').actual), 1);      // ثلاثة أيام = عميل واحد، والبونص وحده لا يجعل 501 مشتريًا
    assert.equal(num(comp(ev, 'invoices').actual), 3);       // فاتورة البونص فقط لا تدخل
    assert.equal(num(comp(ev, 'variety').actual), 5);        // الصنف السادس ببونص فقط لا يحتسب
    // المباشر فقط أو العروض فقط (B007)
    await db.rpc(a, 'save_goal_plan', { p_id: id, p_reason: 'مباشر', p: { tiers: [{ tier: 'A' }], components: [
      { tier: 'A', metric: 'gross_sales', target: 1, filters: { sale_type: 'direct' } }, { tier: 'A', metric: 'gross_sales', target: 1, filters: { sale_type: 'promo' }, sort: 2 }] } });
    const ev2 = await evalOf(db, a, id);
    assert.deepEqual(ev2.components.map((c) => num(c.actual)), [145, 50]);
  } finally { await db.close(); }
});

test('CARD-004/005 G08/G09 وCARD-003 G10: المطلوب حتى القطع والمسار و«لم يبدأ المسار» و«لا توجد أيام عمل»', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    // أيام العمل في أيلول (بعد عطلة 1/9): 2,3,5,6,7,8,9,10,12,13 ← العاشر 13/9
    await inv(db, a, [{ cust: '500', date: '2026-09-13', lines: [['A1', 4500]] }, { cust: '500', date: '2026-09-14', lines: [['A1', 999]] }]);
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
    let ev = await evalOf(db, a, id, '2026-09-13');
    const c = comp(ev, 'net_sales');
    assert.equal(ev.days.elapsed, 10);
    assert.equal(num(c.required), 4000);
    assert.equal(num(c.pct), 45);
    assert.equal(num(c.path_pct), 112.5);
    assert.equal(num(c.path_diff), 500);
    assert.equal(ev.path_state, 'running');
    // «حتى الأمس» بتاريخ السند: حركة 13/9 لا تدخل عند القطع 12/9
    ev = await evalOf(db, a, id, '2026-09-12');
    assert.equal(num(comp(ev, 'net_sales').actual), 0);
    // قطع قبل أول يوم عمل
    ev = await evalOf(db, a, id, '2026-09-01');
    assert.equal(ev.path_state, 'not_started');
    // استثناء طوال الشهر: لا أيام عمل ولا شريحة تلقائية
    await exc(db, a, e.r1, '2026-09-01', '2026-09-30', 'fixed');
    ev = await evalOf(db, a, id);
    assert.equal(ev.path_state, 'no_days');
    assert.equal(ev.achieved, 'NONE');
    // عبارة المسار إعداد للإدارة (CARD-006)
    let cards = await db.rpc(a, 'performance_cards', { p_month: '2026-09-01', p_opts: { role: 'rep' } });
    assert.equal(cards.show_path_phrase, false);
    await db.rpc(a, 'save_setting', { p_key: 'show_path_phrase', p_value: 'true' });
    cards = await db.rpc(a, 'performance_cards', { p_month: '2026-09-01', p_opts: { role: 'rep' } });
    assert.equal(cards.show_path_phrase, true);
  } finally { await db.close(); }
});

test('EMP-004 G11: حركة بعد آخر يوم عمل لا تدخل الإنجاز ولا العمولة وتبقى ماليًا', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-20', lines: [['A1', 100]] }, { cust: '500', date: '2026-09-21', lines: [['A1', 50]] }]);
    await db.rpc(a, 'end_employment', { p_employee: e.r1, p_last_day: '2026-09-20', p_status: 'مستقيل' });
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    const ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'net_sales').actual), 100);
    assert.equal((await db.sql(`select count(*)::int n from docs where kind = 'invoice' and status = 'active'`))[0].n, 2);
  } finally { await db.close(); }
});

test('GOAL-004 وCARD-015 G32 وB014 G16: AND/OR والشريحة المحققة وشريحة المسار؛ لا شريحة = NONE', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    // 60 عميلًا مختلفًا ومبيعات 4500 حتى 13/9 (10 أيام من 25)
    for (let i = 0; i < 60; i++) await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: String(7000 + i), name: 'ع' + i } });
    await inv(db, a, Array.from({ length: 60 }, (_, i) => ({ cust: String(7000 + i), date: '2026-09-13', lines: [['A1', 75]] })));
    const comps = [{ tier: 'A', metric: 'net_sales', target: 10000 }, { tier: 'A', metric: 'customers', target: 180, sort: 2 },
                   { tier: 'B', metric: 'net_sales', target: 4000 }];
    const id = await plan(db, a, e.r1, comps);
    let ev = await evalOf(db, a, id, '2026-09-13');
    assert.equal(num(comp(ev, 'customers').required), 72);
    assert.equal(ev.path_tier, 'B');           // A: العملاء دون المفترض في AND
    assert.equal(ev.achieved, 'B');            // B: 4500 ≥ 4000
    assert.equal(ev.main.tier, 'A');           // نسبة الإنجاز «من هدف A»
    await db.rpc(a, 'save_goal_plan', { p_id: id, p_reason: 'OR', p: { tiers: [{ tier: 'A', logic: 'OR' }, { tier: 'B' }, { tier: 'C' }, { tier: 'X' }], components: comps } });
    ev = await evalOf(db, a, id, '2026-09-13');
    assert.equal(ev.path_tier, 'A');
    // لا شريحة مستوفاة ولا X مفترضة
    const id2 = await plan(db, a, e.r2, [{ tier: 'A', metric: 'net_sales', target: 100 }, { tier: 'X', metric: 'net_sales', target: null }]);
    const ev2 = await evalOf(db, a, id2);
    assert.equal(ev2.achieved, 'NONE');
    // الهدف الصفري لا يحقق (B013)
    const id3 = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.sup, role: 'supervisor', sup_mode: 'independent',
      tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 0 }] } });
    const ev3 = await evalOf(db, a, id3);
    assert.equal(ev3.components[0].status, 'zero');
    assert.equal(ev3.achieved, 'NONE');
  } finally { await db.close(); }
});

test('GOAL-011 G13 وB001 G12: هدف المشرف مجموع الفريق بحسب أيام التبعية؛ المستقل ثابت', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const sup2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '31', name: 'مشرف ثان', join_date: '2025-01-01' } });
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
    const mk = (emp) => db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: emp, role: 'supervisor',
      tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales' }] } });
    const s1 = await mk(e.sup); const s2 = await mk(sup2);
    // نقل بعد 10 أيام عمل (2..13/9) مع إبقاء السابق: من 14/9 للجديد
    await db.rpc(a, 'transfer_supervisor', { p_employee: e.r1, p_new_supervisor: sup2, p_effective: '2026-09-14' });
    let a1 = comp(await evalOf(db, a, s1), 'net_sales'); let a2 = comp(await evalOf(db, a, s2), 'net_sales');
    assert.equal(num(a1.final), 4000);
    assert.equal(num(a2.final), 6000);
    // حركة 12/9 للقديم و15/9 للجديد؛ لا ازدواج
    await inv(db, a, [{ cust: '500', date: '2026-09-12', lines: [['A1', 30]] }, { cust: '500', date: '2026-09-15', lines: [['A1', 70]] }]);
    a1 = comp(await evalOf(db, a, s1), 'net_sales'); a2 = comp(await evalOf(db, a, s2), 'net_sales');
    assert.equal(num(a1.actual), 30);
    assert.equal(num(a2.actual), 70);
    // المستقل لا يتغير بالنقل
    await db.rpc(a, 'save_goal_plan', { p_id: s1, p_reason: 'مستقل', p: { sup_mode: 'independent', tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 5000 }] } });
    assert.equal(num(comp(await evalOf(db, a, s1), 'net_sales').final), 5000);
  } finally { await db.close(); }
});

test('GOAL-011 G13: نقل كل حركات الشهر 0/10000 ونقل خمسة أيام سابقة 2000/8000', async () => {
  for (const [moveFrom, expOld, expNew] of [['2026-09-01', 0, 10000], ['2026-09-08', 2000, 8000]]) {
    const db = await connect();
    try {
      const { a, e } = await setup(db);
      const sup2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '31', name: 'مشرف ثان', join_date: '2025-01-01' } });
      await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 10000 }]);
      const mk = (emp) => db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: emp, role: 'supervisor',
        tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales' }] } });
      const s1 = await mk(e.sup); const s2 = await mk(sup2);
      await db.rpc(a, 'transfer_supervisor', { p_employee: e.r1, p_new_supervisor: sup2, p_effective: '2026-09-14', p_move_prior: true, p_move_from: moveFrom });
      assert.equal(num(comp(await evalOf(db, a, s1), 'net_sales').final), expOld);
      assert.equal(num(comp(await evalOf(db, a, s2), 'net_sales').final), expNew);
    } finally { await db.close(); }
  }
});

test('GOAL-012..017 G34–G38: العملاء الجدد وإعادة التنشيط والتحصيل النسبي وأساس هدف التحصيل', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [
      { cust: '501', date: '2026-06-10', lines: [['A1', 10]] },               // سبق شراؤه: ليس جديدًا
      { cust: '503', date: '2026-06-01', lines: [['A1', 10]] },               // آخر شراء قبل 90 يومًا: معاد تنشيطه
      { cust: '504', date: '2026-08-15', lines: [['A1', 10]] },               // اشترى خلال 90 يومًا: لا
    ]);
    await inv(db, a, [
      { cust: '500', date: '2026-09-05', lines: [['A1', 1000]] },
      { cust: '501', date: '2026-09-05', lines: [['A1', 1000]] },
      { cust: '503', date: '2026-09-05', lines: [['A1', 1000]] },
      { cust: '504', date: '2026-09-05', lines: [['A1', 1000]] },
      { cust: '505', date: '2026-09-06', emp: '21', lines: [['A1', 500]] },
    ]);
    // تحصيل 3000 مسجل على المندوب أ، منه تحصيل لفاتورة المندوب ب
    await coll(db, a, [{ cust: '500', date: '2026-09-10', amount: 1000 }, { cust: '501', date: '2026-09-10', amount: 1000 },
                       { cust: '505', date: '2026-09-10', amount: 500 }, { cust: '503', date: '2026-09-10', amount: 500 }]);
    const id = await plan(db, a, e.r1, [
      { tier: 'A', metric: 'new_customers', target: 1 }, { tier: 'A', metric: 'reactivated', target: 1, filters: { days: 90 } },
      { tier: 'A', metric: 'collection_ratio', target: 70 }, { tier: 'A', metric: 'collection', target: 1, filters: { basis: 'collector' } },
      { tier: 'B', metric: 'collection', target: 1, filters: { basis: 'invoice_rep' } }]);
    const ev = await evalOf(db, a, id);
    assert.equal(num(comp(ev, 'new_customers').actual), 1);       // 500 فقط
    assert.equal(num(comp(ev, 'reactivated').actual), 1);         // 503
    assert.equal(num(comp(ev, 'collection_ratio').actual), 75);   // 3000 ÷ 4000
    assert.equal(comp(ev, 'collection_ratio').has_path, false);
    assert.equal(num(comp(ev, 'collection').actual), 3000);       // على المسجل في السند
    // أساس مندوب الفاتورة: 1000 + 1000 + 500 (الافتتاحي صفر)، دون 500 لفاتورة المندوب ب
    assert.equal(num(comp(ev, 'collection', 'B').actual), 2500);
  } finally { await db.close(); }
});

// ---------------------------------------------------------------------
// العمولات
// ---------------------------------------------------------------------
const rule = (db, a, members, tiers, month = '2026-09-01', name = 'قاعدة') => db.rpc(a, 'save_commission_rule', { p_id: null, p: {
  month, name, members, tiers: tiers ?? [{ tier: 'A', rep_rate: 3.5, sup_rate: 3 }, { tier: 'B', rep_rate: null, sup_rate: null }, { tier: 'C' }, { tier: 'X' }] } });
const stmt = (db, a, emp, month = '2026-09-01') => db.rpc(a, 'commission_statement', { p_employee: emp, p_month: month });

test('COMM-004 G14/G15/G24 وCOMM-005 G25: النسبة الشهرية ثم نسبة الصنف، الصفر مقصود، الفراغ إعداد ناقص، وغير المشمول ناقص', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 600, 400]] },
                      { cust: '502', date: '2026-09-06', pay: 'فاتورة نقدي', lines: [['A1', 0, 0]] }]);
    await ret(db, a, [{ cust: '500', date: '2026-09-07', lines: [['A1', 100]] }]);
    // غير مشمول بقاعدة: إعداد ناقص بلا حساب (G24)
    let s = await stmt(db, a, e.r1);
    assert.equal(s.status, 'incomplete');
    assert.equal(s.base_commission, null);
    assert.ok(s.warnings.some((w) => w.code === 'no_rule'));
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 100 }]);
    const r = await rule(db, a, [e.r1]);
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.eligible), 900);                       // G25: مباشر وعروض نقدًا وذممًا − مرتجعات
    assert.equal(s.tier_effective, 'A');
    assert.equal(num(s.base_commission), 31.5);               // 900 × 3.5%
    // فراغ النسبة الشهرية يرجع لنسبة الصنف 3% (G14)
    await db.rpc(a, 'save_commission_rule', { p_id: r, p_reason: 'فراغ', p: { name: 'قاعدة', members: [e.r1], tiers: [{ tier: 'A', rep_rate: null }] } });
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.base_commission), 27);
    assert.ok(s.lines.every((l) => l.src === 'product'));
    // الصفر المحدد صفر عمدًا
    await db.rpc(a, 'save_commission_rule', { p_id: r, p_reason: 'صفر', p: { name: 'قاعدة', members: [e.r1], tiers: [{ tier: 'A', rep_rate: 0 }] } });
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.base_commission), 0);
    assert.equal(s.status, 'complete');
    // فراغ نسبة الصنف المطلوبة: إعداد ناقص (G15)
    await db.rpc(a, 'save_commission_rule', { p_id: r, p_reason: 'فراغ', p: { name: 'قاعدة', members: [e.r1], tiers: [{ tier: 'A', rep_rate: null }] } });
    await db.sql(`delete from product_commission_rates where product_id = $1 and role = 'rep' and tier = 'A'`, [p.A1]);
    s = await stmt(db, a, e.r1);
    assert.equal(s.status, 'incomplete');
    const w = s.warnings.find((x) => x.code === 'missing_rate');
    assert.equal(num(w.items[0].value), 900);
    // الموظف في قاعدتين للشهر نفسه ممنوع
    await rejects(rule(db, a, [e.r1], undefined, '2026-09-01', 'أخرى'), 'مشمول بقاعدة أخرى');
  } finally { await db.close(); }
});

test('COMM-006 G26: المشرف 3‰ على فريقه، والشخصية معلقة تمنع الإغلاق حتى نسبة الإدارة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', emp: '20', lines: [['A1', 60000]] }, { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 40000]] },
                      { cust: '503', date: '2026-09-06', emp: '30', lines: [['A1', 5000]] }]);
    for (const emp of [e.r1, e.r2]) await plan(db, a, emp, [{ tier: 'A', metric: 'net_sales', target: 1 }]);
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A' }],
      components: [{ tier: 'A', metric: 'net_sales' }] } });
    await rule(db, a, [e.r1, e.r2, e.sup]);
    let s = await stmt(db, a, e.sup);
    assert.equal(s.role, 'supervisor');
    assert.equal(num(s.team_eligible), 100000);
    assert.equal(num(s.base_commission), 300);
    assert.ok(s.warnings.some((w) => w.code === 'personal_pending' && w.blocking));
    await rejects(db.rpc(a, 'close_month', { p_month: '2026-09-01' }), 'معلّقة');
    await db.rpc(a, 'set_personal_rate', { p_month: '2026-09-01', p_employee: e.sup, p_rate: 2, p_unit: 'pct' });
    s = await stmt(db, a, e.sup);
    assert.equal(num(s.base_commission), 400);   // 300 + 5000 × 2%
    assert.equal(s.status, 'complete');
    // إدراج الشخصية في إنجاز هدفه خيار للإدارة فقط
    const u = await makeUser(db, a, { username: 'goals', display_name: 'محرر أهداف', data_scope: 'all',
      overrides: [{ page: 'P10a', action: 'view', granted: true }, { page: 'P10a', action: 'edit', granted: true }] });
    const sp = (await db.sql('select id from goal_plans where employee_id = $1', [e.sup]))[0].id;
    await rejects(db.rpc(u, 'save_goal_plan', { p_id: sp, p_reason: 'شخصية', p: { include_personal: true, tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales' }] } }), 'للإدارة');
  } finally { await db.close(); }
});

test('COMM-008 G27/G29/G30: عمولة التحصيل بشريحة شهر الفاتورة ولمندوب الفاتورة؛ لا عمولة ثانية', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    for (const m of ['2026-08-01', '2026-09-01', '2026-10-01']) {
      await db.rpc(a, 'save_holiday', { p_id: null, p: { start_date: m, name: 'x' } }).catch(() => {});
      await rule(db, a, [e.r1, e.r2], [{ tier: 'A', rep_rate: 3 }], m, 'ق' + m);
      for (const emp of [e.r1, e.r2]) {
        await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: m, employee_id: emp, role: 'rep', tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'gross_sales', target: 1 }] } });
      }
    }
    // فاتورة آب تحسب على البيع، ثم يُختار المندوب من أيلول وتسدد فيه: لا عمولة ثانية (G30)
    await inv(db, a, [{ cust: '503', date: '2026-08-20', lines: [['A1', 100]] }]);
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-09-01', p_on: true });
    await inv(db, a, [{ cust: '502', date: '2026-09-05', pay: 'فاتورة نقدي', lines: [['A1', 2000]] },
                      { cust: '500', date: '2026-09-06', lines: [['A1', 700], ['A2', 300]] }]);
    // التسديد مسجل على المندوب ب ويبقى لمندوب الفاتورة (G29)
    await coll(db, a, [{ cust: '500', date: '2026-09-20', amount: 600, emp: '21' }, { cust: '503', date: '2026-09-20', amount: 100 }]);
    await coll(db, a, [{ cust: '500', date: '2026-10-05', amount: 400 }]);
    let s = await stmt(db, a, e.r1);
    assert.equal(s.collection_mode, true);
    assert.equal(num(s.eligible), 2600);
    assert.equal(num(s.base_commission), 78);       // (2000 + 600) × 3%
    assert.equal(s.paid.length, 1);
    assert.equal(num(s.paid[0].commission), 18);
    assert.equal(s.deferred.length, 1);
    assert.equal(num(s.deferred[0].remaining), 400);
    const s2 = await stmt(db, a, e.r2);
    assert.equal(num(s2.eligible), 0);
    s = await stmt(db, a, e.r1, '2026-10-01');
    assert.equal(num(s.eligible), 400);
    assert.equal(num(s.base_commission), 12);
    assert.equal(s.deferred.length, 0);
    // غير المختار: أيلول 3000
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-09-01', p_on: false });
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.eligible), 3000);
  } finally { await db.close(); }
});

test('COMM-008 G28/G31: حد عمر الدين (الفارغ 30)، وتحصيل الافتتاحي «لا أحد» أو مندوب للعميل', async () => {
  const db = await connect();
  try {
    const { a, e, c } = await setup(db);
    for (const m of ['2026-09-01', '2026-10-01', '2026-11-01']) {
      await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 3 }], m, 'ق' + m);
      await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: m, employee_id: e.r1, role: 'rep', tiers: [{ tier: 'A' }],
        components: [{ tier: 'A', metric: m === '2026-09-01' ? 'gross_sales' : 'collection', target: 1 }] } });
    }
    await db.rpc(a, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-09-01', p_on: true });
    await inv(db, a, [{ cust: '500', date: '2026-09-01', lines: [['A1', 100]] }, { cust: '501', date: '2026-09-01', lines: [['A1', 100]] }]);
    await coll(db, a, [{ cust: '500', date: '2026-10-31', amount: 100 }, { cust: '501', date: '2026-11-05', amount: 100 }]);
    assert.equal(num((await stmt(db, a, e.r1, '2026-10-01')).base_commission), 3);
    assert.equal(num((await stmt(db, a, e.r1, '2026-11-01')).base_commission), 0);
    // الافتتاحي: «لا أحد» ثم مندوب للعميل؛ النسبة من قاعدة الشهر
    await db.rpc(a, 'save_opening', { p_customer: c['503'], p_year: 2026, p_debit: 1000, p_credit: null });
    await coll(db, a, [{ cust: '503', date: '2026-10-10', amount: 1000 }]);
    assert.equal(num((await stmt(db, a, e.r1, '2026-10-01')).base_commission), 3);
    await db.rpc(a, 'set_opening_rep', { p_customer: c['503'], p_employee: e.r1, p_from: '2026-01-01' });
    const s = await stmt(db, a, e.r1, '2026-10-01');
    assert.equal(num(s.base_commission), 33);
  } finally { await db.close(); }
});

test('B024–B027 G17/G18/G19 وB021: الشريحة اليدوية والإضافات بأساس صريح والتصفير والسالب', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 5000 }, { tier: 'B', metric: 'net_sales', target: 900 }]);
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 10 }, { tier: 'B', rep_rate: 10 }]);
    const adj = (p) => db.rpc(a, 'save_commission_adjustment', { p_employee: e.r1, p_month: '2026-09-01', p });
    let s = await stmt(db, a, e.r1);
    assert.equal(num(s.base_commission), 100);
    await db.rpc(a, 'save_reward', { p_id: null, p: { month: '2026-09-01', name: 'مكافأة B', cond_type: 'tier', tiers: ['B'], value_type: 'fixed', amount: 20, stack_mode: 'STACK' } });
    await adj({ kind: 'add', amount: 10, reason: 'إضافة' });
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.final), 130);
    // معاينة قبل الاعتماد ولا تحفظ
    const pv = await db.rpc(a, 'preview_commission_adjustment', { p_employee: e.r1, p_month: '2026-09-01', p: { kind: 'zero_base' } });
    assert.equal(num(pv.after.final), 30);
    assert.equal(num((await stmt(db, a, e.r1)).final), 130);
    const zb = await adj({ kind: 'zero_base', reason: 'تصفير' });
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.final), 30);
    assert.equal(num(s.base_original), 100);
    await adj({ kind: 'zero_all', reason: 'تصفير كامل' });
    assert.equal(num((await stmt(db, a, e.r1)).final), 0);
    await db.rpc(a, 'cancel_commission_adjustment', { p_id: zb, p_reason: 'إلغاء' });
    await db.sql(`update commission_adjustments set status = 'cancelled' where kind = 'zero_all'`);
    // الإضافة بالنسبة تحتاج أساسًا (G18)
    await rejects(adj({ kind: 'add', pct: 5, reason: 'x' }), 'أساسًا صريحًا');
    const a5 = await adj({ kind: 'add', pct: 5, base: 'base_commission', reason: 'نسبة من الأساسية' });
    assert.equal(num((await stmt(db, a, e.r1)).adjustments_total), 15);
    await db.rpc(a, 'cancel_commission_adjustment', { p_id: a5, p_reason: 'x' });
    await adj({ kind: 'add', pct: 5, base: 'eligible', reason: 'نسبة من المؤهل' });
    assert.equal(num((await stmt(db, a, e.r1)).adjustments_total), 60);
    // الشريحة اليدوية (B021) والمستحق السالب يظهر (G19)
    await adj({ kind: 'manual_tier', tier: 'A', reason: 'قرار' });
    s = await stmt(db, a, e.r1);
    assert.equal(s.tier_calc, 'B');
    assert.equal(s.tier_effective, 'A');
    await adj({ kind: 'deduct', amount: 300, reason: 'خصم' });
    s = await stmt(db, a, e.r1);
    assert.ok(num(s.final) < 0);
    // غير الإدارة لا يقرر لنفسه
    const u = await makeUser(db, a, { username: 'self', display_name: 'مندوب', employee_id: e.r1, data_scope: 'self',
      overrides: [{ page: 'P14', action: 'view', granted: true }, { page: 'P14', action: 'edit', granted: true }] });
    await rejects(db.rpc(u, 'save_commission_adjustment', { p_employee: e.r1, p_month: '2026-09-01', p: { kind: 'add', amount: 1000, reason: 'لي' } }), 'لا تعدّل بياناتك');
  } finally { await db.close(); }
});

test('B023 REWARD-002: STACK يجمع وHIGHEST_ONLY يأخذ الأعلى؛ المقياس شرطًا', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000], ['A2', 1]] }]);
    await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 500 }]);
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 1 }]);
    const rw = (p) => db.rpc(a, 'save_reward', { p_id: null, p: { month: '2026-09-01', ...p } });
    await rejects(rw({ name: 'بلا جمع', cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 5 }), 'طريقة الجمع');
    await rw({ name: 'م1', cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 5, group_name: 'g', stack_mode: 'HIGHEST_ONLY' });
    await rw({ name: 'م2', cond_type: 'metric', metric: 'variety', metric_min: 2, value_type: 'percent', pct: 2, pct_base: 'eligible', group_name: 'g', stack_mode: 'HIGHEST_ONLY' });
    await rw({ name: 'م3', cond_type: 'metric', metric: 'variety', metric_min: 3, value_type: 'fixed', amount: 100, stack_mode: 'STACK' });
    await rw({ name: 'م4', cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 7, stack_mode: 'STACK' });
    await rejects(rw({ name: 'م5', cond_type: 'tier', tiers: ['A'], value_type: 'fixed', amount: 1, group_name: 'g', stack_mode: 'STACK' }), 'طريقة جمع أخرى');
    const s = await stmt(db, a, e.r1);
    assert.equal(num(s.rewards_total), 27.02);     // الأعلى في g: 2% من 1001 = 20.02، و7 بالجمع، و100 غير مستوفاة
    const lst = await db.rpc(a, 'rewards_list', { p_month: '2026-09-01' });
    assert.equal(lst.plans.find((x) => x.name === 'م1').qualified[0].counted, false);
  } finally { await db.close(); }
});

test('PERIOD-001/002 وB075–B077 G20: الإغلاق بنسخة، المغلق محمي ويقرأ من النسخة، الفرق ظاهر، وإعادة الفتح برمز الإدارة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await db.rpc(a, 'admin_set_secret', { p_old: null, p_new: 'Sec#2026' });
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }]);
    const pid = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 500 }]);
    await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales' }] } });
    const r = await rule(db, a, [e.r1, e.sup], [{ tier: 'A', rep_rate: 1, sup_rate: 1 }]);
    const ready = await db.rpc(a, 'month_readiness', { p_month: '2026-09-01' });
    assert.equal(ready.blocking, false);
    const v1 = await db.rpc(a, 'close_month', { p_month: '2026-09-01', p_note: 'إغلاق' });
    assert.equal(v1, 1);
    let s = await stmt(db, a, e.r1);
    assert.equal(s.snapshot, true);
    assert.equal(num(s.final), 10);
    // المغلق محمي: تعديل الهدف والقاعدة يحتاج رمز الإدارة
    await rejects(db.rpc(a, 'save_goal_plan', { p_id: pid, p_reason: 'x', p: { tiers: [{ tier: 'A' }], components: [] } }), 'الرمز السري');
    // تغير المصدر بعد الإغلاق برمز الإدارة: يبقى المحفوظ ويظهر الفرق دون فتح تلقائي
    await db.sql(`update rule_tiers set rep_rate = 2 where rule_id = $1`, [r]);
    s = await stmt(db, a, e.r1);
    assert.equal(num(s.final), 10);
    const d = await db.rpc(a, 'month_diff', { p_month: '2026-09-01' });
    assert.equal(d.rows.length, 1);
    assert.equal(num(d.rows[0].live.final), 20);
    assert.equal((await db.sql(`select status from months where month = '2026-09-01'`))[0].status, 'closed');
    // إعادة الفتح: الإدارة والرمز والسبب، ثم نسخة جديدة وتبقى السابقة
    await rejects(db.rpc(a, 'reopen_month', { p_month: '2026-09-01', p_reason: 'تصحيح', p_code: 'خطأ' }), 'الرمز السري');
    const u = await makeUser(db, a, { username: 'mgr', display_name: 'م', data_scope: 'all', overrides: [{ page: 'P14b', action: 'view', granted: true }] });
    await rejects(db.rpc(u, 'reopen_month', { p_month: '2026-09-01', p_reason: 'x', p_code: 'Sec#2026' }), 'للإدارة');
    await db.rpc(a, 'reopen_month', { p_month: '2026-09-01', p_reason: 'تصحيح النسبة', p_code: 'Sec#2026' });
    assert.equal(num((await stmt(db, a, e.r1)).final), 20);
    assert.equal(await db.rpc(a, 'close_month', { p_month: '2026-09-01', p_note: 'نسخة مصححة' }), 2);
    assert.equal(num((await db.rpc(a, 'commission_statement', { p_employee: e.r1, p_month: '2026-09-01', p_version: 1 })).final), 10);
    assert.equal(num((await stmt(db, a, e.r1)).final), 20);
    const ov = await db.rpc(a, 'months_overview', {});
    const sep = ov.find((m) => m.month === '2026-09-01');
    assert.equal(sep.versions.length, 2);
    assert.equal(sep.versions[0].reopen_reason, 'تصحيح النسبة');
  } finally { await db.close(); }
});

test('COMM-004 G40: إضافة شريحة وإعادة ترتيب: التقييم بالترتيب المحفوظ؛ لا نسبة بالتخمين', async () => {
  const db = await connect();
  try {
    const { a, e, p } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }]);
    const id = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.r1, role: 'rep',
      tiers: [{ tier: 'A', sort: 1 }, { tier: 'S', sort: 2 }, { tier: 'B', sort: 3 }],
      components: [{ tier: 'A', metric: 'net_sales', target: 2000 }, { tier: 'S', metric: 'net_sales', target: 1000 }, { tier: 'B', metric: 'net_sales', target: 500 }] } });
    assert.equal((await evalOf(db, a, id)).achieved, 'S');
    await rule(db, a, [e.r1], [{ tier: 'A', rep_rate: 3 }, { tier: 'S' }, { tier: 'B', rep_rate: 2 }]);
    const s = await stmt(db, a, e.r1);
    assert.equal(s.status, 'incomplete');      // لا نسبة للشريحة الجديدة في القاعدة ولا في الأصناف
    assert.ok(s.warnings.some((w) => w.code === 'missing_rate'));
    await db.rpc(a, 'set_product_value', { p_product: p.A1, p_kind: 'rep_S', p_value: '2.75', p_date: '2025-01-01' });
    assert.equal(num((await stmt(db, a, e.r1)).base_commission), 27.5);
  } finally { await db.close(); }
});

test('REVIEW-001 G41 والنسخ والقوالب GOAL-010 G21 والتعديل الجماعي بمعاينة', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    const m = (await db.sql(`select to_char(date_trunc('month', (now() at time zone 'Asia/Amman')), 'YYYY-MM-DD') m`))[0].m;
    let cm = await db.rpc(a, 'commission_month', { p_month: m });
    assert.equal(cm.review_due, true);
    await db.rpc(a, 'record_rate_review', { p_month: m, p_decision: 'no_change' });
    cm = await db.rpc(a, 'commission_month', { p_month: m });
    assert.equal(cm.review_due, false);
    assert.equal(cm.review.decision, 'no_change');
    // القالب: مكوّن غير متأثر يحتفظ بإعداده عند الاستخدام
    const t = await db.rpc(a, 'save_goal_template', { p_id: null, p_name: 'قالب', p_role: 'rep', p_data: {
      tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 10000 }, { tier: 'A', metric: 'customers', target: 180, affected: false }] } });
    const tpl = (await db.rpc(a, 'goal_templates_list', { p_role: 'rep' }))[0];
    const id = await db.rpc(a, 'save_goal_plan', { p_id: null, p: { month: '2026-09-01', employee_id: e.r1, role: 'rep', template_id: t, ...tpl.data } });
    const plan1 = (await db.rpc(a, 'goal_plan', { p_id: id })).plan;
    assert.deepEqual(plan1.components.map((c) => c.affected), [true, false]);
    // نسخ شهر
    const pv = await db.rpc(a, 'copy_goal_plans', { p_from: '2026-09-01', p_to: '2026-10-01', p_role: 'rep', p_commit: false });
    assert.equal(pv.length, 1);
    await db.rpc(a, 'copy_goal_plans', { p_from: '2026-09-01', p_to: '2026-10-01', p_role: 'rep', p_commit: true });
    assert.equal((await db.sql(`select count(*)::int n from goal_plans where month = '2026-10-01'`))[0].n, 1);
    // تعديل جماعي: معاينة لا تحفظ، ثم اعتماد بسبب
    const b = await db.rpc(a, 'bulk_adjust_goals', { p_plans: `{${id}}`, p_tier: 'A', p_metric: 'net_sales', p_mode: 'percent', p_value: 10, p_commit: false });
    assert.equal(num(b[0].after), 11000);
    assert.equal(num((await db.rpc(a, 'goal_plan', { p_id: id })).plan.components[0].target), 10000);
    await db.rpc(a, 'bulk_adjust_goals', { p_plans: `{${id}}`, p_tier: 'A', p_metric: 'net_sales', p_mode: 'percent', p_value: 10, p_commit: true, p_reason: 'رفع' });
    assert.equal(num((await db.rpc(a, 'goal_plan', { p_id: id })).plan.components[0].target), 11000);
    // تعديل القالب لا يغير الخطط القديمة تلقائيًا؛ التطبيق صريح بمعاينة
    await db.rpc(a, 'save_goal_template', { p_id: t, p_name: 'قالب', p_role: 'rep', p_data: { tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 5 }] } });
    assert.equal(num((await db.rpc(a, 'goal_plan', { p_id: id })).plan.components[0].target), 11000);
    const ap = await db.rpc(a, 'apply_goal_template', { p_template: t, p_plans: `{${id}}`, p_commit: false });
    assert.equal(ap.length, 1);
    await db.rpc(a, 'apply_goal_template', { p_template: t, p_plans: `{${id}}`, p_commit: true, p_reason: 'تحديث' });
    assert.equal(num((await db.rpc(a, 'goal_plan', { p_id: id })).plan.components[0].target), 5);
    // سجل التعديل بالسابق والجديد والسبب
    const log = await db.sql(`select reason from audit_log where entity = 'goal_plans' and entity_id = $1 order by id`, [String(id)]);
    assert.ok(log.some((l) => l.reason === 'رفع'));
  } finally { await db.close(); }
});

test('B072 والصلاحيات: النطاق في البطاقات والكشف؛ المندوب يرى بطاقته فقط ولا يعدّل خطته', async () => {
  const db = await connect();
  try {
    const { a, e } = await setup(db);
    await inv(db, a, [{ cust: '500', date: '2026-09-05', lines: [['A1', 1000]] }, { cust: '501', date: '2026-09-05', emp: '21', lines: [['A1', 1000]] }]);
    const id = await plan(db, a, e.r1, [{ tier: 'A', metric: 'net_sales', target: 500 }]);
    await plan(db, a, e.r2, [{ tier: 'A', metric: 'net_sales', target: 500 }]);
    const u = await makeUser(db, a, { username: 'rep', display_name: 'مندوب', employee_id: e.r1, data_scope: 'self',
      overrides: [{ page: 'P13', action: 'view', granted: true }, { page: 'P10', action: 'view', granted: true }, { page: 'P10', action: 'edit', granted: true },
                  { page: 'P14', action: 'view', granted: true }] });
    const cards = await db.rpc(u, 'performance_cards', { p_month: '2026-09-01', p_opts: { role: 'all' } });
    assert.deepEqual(cards.cards.map((c) => String(c.employee.id)), [String(e.r1)]);
    assert.equal(num(cards.cards[0].summary.net), 1000);
    await rejects(db.rpc(u, 'commission_statement', { p_employee: e.r2, p_month: '2026-09-01' }), 'خارج نطاق');
    await rejects(db.rpc(u, 'save_goal_plan', { p_id: id, p_reason: 'x', p: { tiers: [{ tier: 'A' }], components: [{ tier: 'A', metric: 'net_sales', target: 1 }] } }), 'لا تعدّل بياناتك');
    await rejects(db.rpc(u, 'close_month', { p_month: '2026-09-01' }), 'للإدارة');
    await rejects(db.rpc(u, 'set_collection_rep', { p_employee: e.r1, p_from_month: '2026-09-01', p_on: true }), 'للإدارة');
    // مؤشر النقدية من اسم العميل «مبيعات نقدية» (CARD)
    await inv(db, a, [{ cust: '502', date: '2026-09-06', pay: 'فاتورة نقدي', lines: [['A1', 1000]] }]);
    const c2 = await db.rpc(a, 'performance_cards', { p_month: '2026-09-01', p_opts: { role: 'rep', search: 'مندوب أ' } });
    assert.equal(num(c2.cards[0].summary.cash), 1000);
    assert.equal(num(c2.cards[0].summary.cash_ratio), 50);
  } finally { await db.close(); }
});
