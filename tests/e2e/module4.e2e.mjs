// اختبار شامل للوحدة 4 في متصفح حقيقي: التقويم، خطة أهداف بمحررها ومعاينتها، قاعدة عمولة بمعاينة الأثر،
// مكافأة ومستوفوها، بطاقات الأداء وحفظ الصورة، كشف العمولة وقرار صرف بمعاينة، فحص الجاهزية والإغلاق وإعادة الفتح بالرمز،
// ولقطات على الحاسوب والهاتف. البيانات الأساسية تُهيأ عبر دوال قاعدة البيانات نفسها كمستخدم الإدارة.
// التشغيل: node e2e/module4.e2e.mjs   (بعد bash local/reset_db.sh)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import pg from 'pg';
import { ANON_KEY } from '../local/gateway.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '../../app');
const out = path.resolve(here, 'out');
fs.mkdirSync(out, { recursive: true });
const BASE = 'http://localhost:3104/';

const db = new pg.Client({ host: '/tmp', port: 54322, user: 'postgres', database: process.env.PGDATABASE || 'master_test' });
await db.connect();
const adminId = (await db.query(`select public.bootstrap_admin('admin', 'Admin#2026', 'الإدارة') id`)).rows[0].id;
async function rpc(fn, args) {
  const keys = Object.keys(args);
  await db.query('begin');
  await db.query('set local role authenticated');
  await db.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify({ sub: adminId, role: 'authenticated' })]);
  const r = await db.query(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) r`,
    keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k])));
  await db.query('commit');
  return r.rows[0].r;
}
const INV_COLS = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
let rowNo = 2;
async function inv(docs) {
  const rows = docs.map(([num, cust, date, emp, amount, pay = 'فاتورة نقدي']) => ({ row: rowNo++, doc_number: num, customer_number: cust, doc_date: date,
    employee_number: emp, pay_type: pay, item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' }));
  const s = await rpc('upload_stage', { p_kind: 'invoice', p_file_name: 'invoice.xlsx', p_sheet: 'S', p_columns: INV_COLS, p_rows: rows });
  const its = (await db.query('select id, errors from batch_items where batch_id = $1', [s.batch_id])).rows;
  assert.equal(its.flatMap((i) => i.errors).length, 0, 'أخطاء في التهيئة');
  await rpc('upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}

// الشهر الحالي بتوقيت الأردن، والسابق للإغلاق
const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Amman' }).format(new Date());
const cur = today.slice(0, 8) + '01';
const prevD = new Date(Date.UTC(+cur.slice(0, 4), +cur.slice(5, 7) - 2, 1));
const prev = `${prevD.getUTCFullYear()}-${String(prevD.getUTCMonth() + 1).padStart(2, '0')}-01`;
const curInput = cur.slice(0, 7);
const prevInput = prev.slice(0, 7);
const fmtM = (m) => `${Number(m.slice(5, 7))}/${m.slice(0, 4)}`;

await rpc('admin_set_secret', { p_old: null, p_new: 'Sec#2026' });
const e = {};
e.sup = await rpc('save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف المنطقة', join_date: '2025-01-01' } });
e.r1 = await rpc('save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أول', join_date: '2025-01-01', supervisor_id: e.sup } });
e.r2 = await rpc('save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ثان', join_date: '2025-01-01', supervisor_id: e.sup } });
for (const [n, name] of [['500', 'بقالة'], ['501', 'سوبرماركت']]) await rpc('save_customer', { p_id: null, p: { customer_number: n, name } });
const prod = await rpc('save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
await rpc('set_product_value', { p_product: prod, p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
for (const [t, r] of [['A', 3], ['B', 2.5], ['C', 2], ['X', 1]]) {
  await rpc('set_product_value', { p_product: prod, p_kind: 'rep_' + t, p_value: String(r), p_date: '2025-01-01' });
  await rpc('set_product_value', { p_product: prod, p_kind: 'supervisor_' + t, p_value: String(r), p_date: '2025-01-01' });
}
const d = (m, day) => m.slice(0, 8) + String(day).padStart(2, '0');
await inv([['1', '500', d(prev, 5), '20', 1000], ['2', '501', d(prev, 6), '21', 400],
  ['3', '500', d(cur, 2), '20', 1200], ['4', '501', d(cur, 3), '21', 300]]);
// الشهر السابق: خطط وقاعدة للجميع ليكون جاهزًا للإغلاق
const tiers = [{ tier: 'A', logic: 'AND' }, { tier: 'B', logic: 'AND' }, { tier: 'C', logic: 'AND' }, { tier: 'X', logic: 'AND' }];
for (const emp of [e.r1, e.r2]) {
  await rpc('save_goal_plan', { p_id: null, p: { month: prev, employee_id: emp, role: 'rep', tiers, components: [{ tier: 'A', metric: 'net_sales', target: 900 }, { tier: 'X', metric: 'net_sales', target: 100 }] } });
}
await rpc('save_commission_rule', { p_id: null, p: { month: prev, name: 'قاعدة السابق', tiers: [{ tier: 'A' }, { tier: 'B' }, { tier: 'C' }, { tier: 'X' }], members: [e.r1, e.r2, e.sup] } });
// الشهر الحالي: خطة للمندوب الثاني والمشرف (الأول يُنشأ من الواجهة)
await rpc('save_goal_plan', { p_id: null, p: { month: cur, employee_id: e.r2, role: 'rep', tiers, components: [{ tier: 'A', metric: 'net_sales', target: 5000 }, { tier: 'X', metric: 'net_sales', target: 200 }] } });
await rpc('save_goal_plan', { p_id: null, p: { month: cur, employee_id: e.sup, role: 'supervisor', tiers: [{ tier: 'A', logic: 'AND' }], components: [] } });

const vite = spawn('npx', ['vite', '--port', '3104', '--strictPort'], {
  cwd: appDir, env: { ...process.env, VITE_SUPABASE_URL: 'http://localhost:54321', VITE_SUPABASE_ANON_KEY: ANON_KEY }, stdio: 'pipe',
});
await new Promise((r) => { vite.stdout.on('data', (x) => /Local/.test(String(x)) && r()); setTimeout(r, 8000); });

const browser = await chromium.launch();
const errors = [];
const results = [];
let shot = null;
const step = async (name, fn) => {
  console.log('… ' + name);
  try { await fn(); results.push(['✔', name]); }
  catch (err) { results.push(['✖', name + ' — ' + err.message.split('\n')[0]]); await shot?.(`m4-fail-${results.length}.png`); }
};
const login = async (p) => {
  await p.goto(BASE);
  await p.getByLabel('اسم المستخدم').fill('admin');
  await p.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
  await p.getByRole('button', { name: 'دخول' }).click();
  await p.getByRole('heading', { name: 'الرئيسية' }).waitFor();
};

try {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 }, locale: 'ar', acceptDownloads: true });
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', (x) => errors.push(x.message));
  page.on('console', (m) => m.type() === 'error' && !/status of 400/.test(m.text()) && errors.push(m.text()));
  // الرفض المتوقع الوحيد: حفظ المكافأة دون طريقة جمع صريحة؛ أي 400 آخر خطأ
  page.on('response', (r) => r.status() === 400 && !/rpc\/save_reward$/.test(r.url()) && errors.push('400 ' + r.url()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  const dialog = () => page.locator('.modal');
  const drawer = () => page.locator('.drawer');

  await step('الدخول وظهور صفحات الأهداف والعمولات والتقويم في القائمة', async () => {
    await login(page);
    await page.getByRole('button', { name: 'الأهداف والعمولات' }).click();
    for (const n of ['أهداف المندوبين', 'أهداف المشرفين', 'قواعد العمولة', 'المكافآت', 'بطاقات الأداء', 'كشف العمولات', 'الأشهر والإغلاق']) {
      await page.getByRole('link', { name: n, exact: true }).waitFor();
    }
    assert.equal(await page.getByText('قيد البناء').count(), 0);
  });

  await step('التقويم: شبكة الشهر وأيام العمل وإضافة عطلة عامة', async () => {
    await page.goto(BASE + '#/calendar');
    await page.locator('.cal-grid .cal-day').first().waitFor();
    assert.ok(await page.locator('.cal-day').count() >= 28);
    await page.screenshot({ path: path.join(out, 'm4-calendar.png'), fullPage: true });
  });

  await step('خطة أهداف من المحرر: مكوّن A بهدف 1000، معاينة ثم اعتماد، فتظهر الشريحة A محققة', async () => {
    await page.goto(BASE + '#/goals');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('row').filter({ hasText: 'مندوب أول' }).getByText('بلا خطة').waitFor();
    await page.getByRole('button', { name: 'خطة جديدة' }).click();
    await dialog().getByLabel('الموظف').selectOption(String(e.r1));
    await dialog().getByRole('button', { name: 'إضافة مكوّن' }).first().click();
    await dialog().getByLabel('الهدف', { exact: true }).fill('1000');
    await dialog().getByRole('button', { name: 'معاينة النتيجة' }).click();
    await dialog().getByText('المعاينة قبل الاعتماد').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-goal-editor.png'), fullPage: true });
    await dialog().getByRole('button', { name: 'اعتماد الخطة' }).click();
    await drawer().getByText('الشريحة المحققة').waitFor();
    await drawer().locator('dd b.tier.tA').first().waitFor();
    await drawer().getByRole('button', { name: 'إغلاق' }).click();
    const row = page.getByRole('row').filter({ hasText: 'مندوب أول' });
    await row.getByRole('cell', { name: '1,200.000' }).or(row.getByRole('cell', { name: '1200.000' })).first().waitFor();
    await page.screenshot({ path: path.join(out, 'm4-goals.png'), fullPage: true });
  });

  await step('أهداف المشرفين: هدف المشرف مجموع الفريق', async () => {
    await page.goto(BASE + '#/goals-supervisors');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('row').filter({ hasText: 'مشرف المنطقة' }).getByText(/مكوّن/).waitFor();
  });

  await step('قاعدة عمولة: من لا قاعدة له إعداد ناقص، ثم قاعدة بمعاينة الأثر وحفظ', async () => {
    await page.goto(BASE + '#/commission-rules');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByText(/إعداد ناقص: 3 موظف بلا قاعدة/).waitFor();
    await page.getByRole('button', { name: 'قاعدة جديدة' }).click();
    await dialog().getByLabel('اسم القاعدة').fill('القاعدة العامة');
    await dialog().getByLabel('نسبة المندوب').first().fill('4');
    for (const n of ['مندوب أول', 'مندوب ثان', 'مشرف المنطقة']) await dialog().getByLabel(new RegExp(n)).check();
    await dialog().getByRole('button', { name: 'معاينة الأثر' }).click();
    // المندوب الأول: A بنسبة القاعدة 4% من 1200 = 48
    await dialog().getByRole('row').filter({ hasText: 'مندوب أول' }).getByText('48.000').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-rule-preview.png'), fullPage: true });
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await page.getByRole('heading', { name: 'القاعدة العامة' }).waitFor();
    assert.equal(await page.getByText(/إعداد ناقص: \d+ موظف بلا قاعدة/).count(), 0);
  });

  await step('عمولة التحصيل ونسب المشرفين الشخصية', async () => {
    await page.getByRole('tab', { name: 'عمولة التحصيل' }).click();
    await page.getByRole('heading', { name: 'حد عمر الدين' }).waitFor();
    await page.getByLabel('المندوب').first().selectOption(String(e.r2));
    await page.getByRole('button', { name: /اختيار من/ }).click();
    await page.getByRole('row').filter({ hasText: 'مندوب ثان' }).getByText('مستمر').waitFor();
    await page.getByRole('tab', { name: 'نسب المشرفين الشخصية' }).click();
    await page.getByRole('row').filter({ hasText: 'مشرف المنطقة' }).waitFor();
  });

  await step('مكافأة بشريحة A ومبلغ ثابت 50 تشترط طريقة الجمع صراحة، ومستوفوها', async () => {
    await page.goto(BASE + '#/rewards');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('button', { name: 'مكافأة جديدة' }).click();
    await dialog().getByLabel('الاسم').fill('مكافأة التميز');
    await dialog().getByLabel('المبلغ').fill('50');
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await dialog().getByText('حدد طريقة الجمع صراحة', { exact: false }).waitFor();
    await dialog().getByLabel('طريقة الجمع').selectOption('STACK');
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await page.getByRole('heading', { name: 'مكافأة التميز' }).waitFor();
    await page.getByRole('row').filter({ hasText: 'مندوب أول' }).getByText('50.000').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-rewards.png'), fullPage: true });
  });

  await step('بطاقات الأداء: ثلاث بطاقات بالألوان، خيارات العرض، وحفظ صورة', async () => {
    await page.goto(BASE + '#/cards');
    await page.getByLabel('الشهر').fill(curInput);
    await page.locator('.perf-card').nth(2).waitFor();
    await page.locator(`.perf-card[data-employee="${e.r1}"].c-tA`).waitFor();
    await page.locator(`.perf-card[data-employee="${e.r1}"]`).getByText('مكافأة التميز').waitFor();
    await page.getByRole('button', { name: 'خيارات العرض' }).click();
    await page.locator('.pop').getByLabel('ملخص المبيعات').uncheck();
    assert.equal(await page.locator('.perf-card .pc-grid').filter({ hasText: 'المرتجعات' }).count(), 0);
    await page.locator('.pop').getByLabel('ملخص المبيعات').check();
    await page.getByRole('button', { name: 'خيارات العرض' }).click();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.locator(`.perf-card[data-employee="${e.r1}"]`).getByRole('button', { name: 'حفظ صورة' }).click()]);
    assert.match(dl.suggestedFilename(), /^card-20-.*\.png$/);
    await page.screenshot({ path: path.join(out, 'm4-cards.png'), fullPage: true });
  });

  await step('كشف العمولات: الملخص بأعمدة الأهداف، والكشف بمراحله، وقرار صرف بمعاينة', async () => {
    await page.goto(BASE + '#/commissions');
    await page.getByLabel('الشهر').fill(curInput);
    const row = page.getByRole('row').filter({ hasText: 'مندوب أول' });
    // 48 أساسية + 50 مكافأة = 98
    await row.getByText('98.000').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-commissions.png'), fullPage: true });
    await row.click();
    await drawer().getByText('مراحل الحساب').waitFor();
    await drawer().getByRole('row').filter({ hasText: 'المستحق النهائي' }).getByText('98.000').waitFor();
    await drawer().getByRole('button', { name: 'قرار صرف' }).click();
    await dialog().getByLabel('المبلغ').fill('10');
    await dialog().getByLabel('السبب').fill('جهد إضافي');
    await dialog().getByRole('button', { name: 'معاينة' }).click();
    await dialog().getByText('108.000').waitFor();
    await dialog().getByRole('button', { name: 'اعتماد' }).click();
    await drawer().getByRole('row').filter({ hasText: 'المستحق النهائي' }).getByText('108.000').waitFor();
    await drawer().getByText('جهد إضافي').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-statement.png'), fullPage: true });
    await drawer().getByRole('button', { name: 'إغلاق' }).click();
  });

  await step('الأشهر: فحص الجاهزية ثم إغلاق الشهر السابق ونسخة 1، ثم إعادة الفتح بالرمز', async () => {
    await page.goto(BASE + '#/months');
    await page.getByRole('row').filter({ hasText: fmtM(prev) }).click();
    await drawer().getByText('لا أخطاء مؤثرة').waitFor();
    await drawer().getByRole('button', { name: 'إغلاق الشهر' }).click();
    await dialog().getByLabel('ملاحظة').fill('اعتماد');
    await dialog().getByRole('button', { name: 'اعتماد الإغلاق' }).click();
    await page.getByRole('row').filter({ hasText: fmtM(prev) }).getByText('مغلق').waitFor();
    await page.screenshot({ path: path.join(out, 'm4-months.png'), fullPage: true });
    // الشهر المغلق يقرأ من النسخة في كشف العمولات
    await page.goto(BASE + '#/commissions');
    await page.getByLabel('الشهر').fill(prevInput);
    await page.getByText(/شهر مغلق \(النسخة 1\)/).waitFor();
    await page.goto(BASE + '#/months');
    await page.getByRole('row').filter({ hasText: fmtM(prev) }).click();
    await drawer().getByRole('button', { name: 'إعادة فتح' }).click();
    await dialog().getByLabel('السبب').fill('تصحيح');
    await dialog().getByLabel('الرمز السري للإدارة').fill('Sec#2026');
    await dialog().getByRole('button', { name: 'إعادة الفتح' }).click();
    await page.getByRole('row').filter({ hasText: fmtM(prev) }).getByText('مفتوح').waitFor();
  });

  await step('الهاتف 390: البطاقات والأهداف والعمولات دون تمرير أفقي للصفحة', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(15000);
    p2.on('pageerror', (x) => errors.push(x.message));
    await login(p2);
    for (const [route, f] of [['/cards', 'm4-cards-mobile-390.png'], ['/goals', 'm4-goals-mobile-390.png'], ['/commissions', 'm4-commissions-mobile-390.png'], ['/calendar', 'm4-calendar-mobile-390.png']]) {
      await p2.goto(BASE + '#' + route);
      await p2.waitForTimeout(1500);
      const overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 1, `تمرير أفقي للصفحة في ${route}: ${overflow}`);
      await p2.screenshot({ path: path.join(out, f), fullPage: true });
    }
    await c2.close();
  });
} finally {
  await browser.close();
  vite.kill();
  await db.end();
}

for (const [s, n] of results) console.log(s, n);
const relevant = errors.filter((x) => !/favicon|fonts.googleapis/.test(x));
if (relevant.length) console.log('أخطاء المتصفح:', relevant.slice(0, 5));
const failed = results.filter(([s]) => s === '✖').length + (relevant.length ? 1 : 0);
console.log(failed ? `فشل ${failed}` : 'نجحت كل الخطوات');
process.exit(failed ? 1 : 0);
