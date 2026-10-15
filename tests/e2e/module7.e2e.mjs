// اختبار شامل لإضافات الأهداف والعمولات (15/10/2026) في متصفح حقيقي: جدول الأهداف الجماعي بمعاينة وخطأ ترتيب الشرائح،
// مجموعات الأصناف في صفحة المنتجات، مكافأة تجاوز هدف A بمستويات وسريان لشهرين، قاعدة عمولة بحد أدنى للمبيعات
// وتصاعدية، بطاقة الأداء ببطاقات الشرائح، قائمة الشريحة اليدوية، إلغاء كل قرارات الشهر، وصفحة البداية للمندوب.
// التشغيل: node e2e/module7.e2e.mjs   (بعد bash local/reset_db.sh)
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
const BASE = 'http://localhost:3107/';

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
  const rows = docs.map(([num, cust, date, emp, amount, item = 'A1']) => ({ row: rowNo++, doc_number: num, customer_number: cust, doc_date: date,
    employee_number: emp, pay_type: 'فاتورة نقدي', item_number: item, item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' }));
  const s = await rpc('upload_stage', { p_kind: 'invoice', p_file_name: 'invoice.xlsx', p_sheet: 'S', p_columns: INV_COLS, p_rows: rows });
  const its = (await db.query('select id, errors from batch_items where batch_id = $1', [s.batch_id])).rows;
  assert.equal(its.flatMap((i) => i.errors).length, 0, 'أخطاء في التهيئة');
  await rpc('upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}

const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Amman' }).format(new Date());
const cur = today.slice(0, 8) + '01';
const nextD = new Date(Date.UTC(+cur.slice(0, 4), +cur.slice(5, 7), 1));
const next = `${nextD.getUTCFullYear()}-${String(nextD.getUTCMonth() + 1).padStart(2, '0')}-01`;
const curInput = cur.slice(0, 7);
const d = (m, day) => m.slice(0, 8) + String(day).padStart(2, '0');

const e = {};
e.sup = await rpc('save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف المنطقة', join_date: '2025-01-01' } });
e.r1 = await rpc('save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أول', join_date: '2025-01-01', supervisor_id: e.sup } });
e.r2 = await rpc('save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ثان', join_date: '2025-01-01', supervisor_id: e.sup } });
for (const [n, name] of [['500', 'بقالة'], ['501', 'سوبرماركت']]) await rpc('save_customer', { p_id: null, p: { customer_number: n, name } });
const prod = {};
for (const code of ['A1', 'A2']) {
  prod[code] = await rpc('save_product', { p_id: null, p_code: code, p_name: 'صنف ' + code });
  await rpc('set_product_value', { p_product: prod[code], p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
}
await inv([['1', '500', d(cur, 2), '20', 1700], ['2', '501', d(cur, 3), '21', 300, 'A2']]);

const vite = spawn('npx', ['vite', '--port', '3107', '--strictPort'], {
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
  catch (err) { results.push(['✖', name + ' — ' + err.message.split('\n')[0]]); await shot?.(`m7-fail-${results.length}.png`); }
};
const login = async (p, user = 'admin', pass = 'Admin#2026', heading = 'الرئيسية') => {
  await p.goto(BASE);
  await p.getByLabel('اسم المستخدم').fill(user);
  await p.getByLabel('كلمة المرور', { exact: true }).fill(pass);
  await p.getByRole('button', { name: 'دخول' }).click();
  if (heading) await p.getByRole('heading', { name: heading }).waitFor();
};

try {
  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 }, locale: 'ar', acceptDownloads: true });
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', (x) => errors.push(x.message));
  page.on('console', (m) => m.type() === 'error' && !/status of 400/.test(m.text()) && errors.push(m.text()));
  // الرفض المتوقع: حفظ الجدول الجماعي بخطأ ترتيب الشرائح (معاينة تعرضه فلا 400 للمعاينة)، فأي 400 آخر خطأ
  page.on('response', (r) => r.status() === 400 && errors.push('400 ' + r.url()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  const dialog = () => page.locator('.modal');
  const drawer = () => page.locator('.drawer');

  await step('جدول الأهداف الجماعي: هيكل A/B/C/X، قيم موحدة، خطأ ترتيب الشرائح في المعاينة ثم اعتماد الكل بسبب واحد', async () => {
    await login(page);
    await page.goto(BASE + '#/goals');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('button', { name: 'جدول الأهداف الجماعي' }).click();
    await dialog().getByLabel('بحث الموظفين').waitFor();
    await dialog().getByRole('button', { name: 'اختيار الظاهر' }).click();
    for (const [tier, v, i] of [['A', '1000', 1], ['B', '800', 2], ['C', '500', 3], ['X', '100', 4]]) {
      await dialog().getByLabel(`قيمة موحدة ${tier} | صافي المبيعات | ${i}`).fill(v);
    }
    await dialog().getByRole('button', { name: 'تعميم' }).click();
    // مخالفة الترتيب لموظف: هدف B أكبر من A
    await dialog().getByLabel('مندوب ثان B | صافي المبيعات | 2').fill('1500');
    await dialog().getByRole('button', { name: 'معاينة', exact: true }).click();
    await dialog().getByText('خطأ: 1').waitFor();
    await dialog().getByText(/ترتيب الشرائح/).first().waitFor();
    assert.equal(await dialog().getByRole('button', { name: /اعتماد الكل/ }).isDisabled(), true);
    await page.screenshot({ path: path.join(out, 'm7-grid-error.png'), fullPage: true });
    await dialog().getByLabel('مندوب ثان B | صافي المبيعات | 2').fill('800');
    await dialog().getByRole('button', { name: 'معاينة', exact: true }).click();
    await dialog().getByText('جديدة: 2').waitFor();
    await dialog().getByLabel('سبب الحفظ (إلزامي للاعتماد)').fill('أهداف الشهر');
    await page.screenshot({ path: path.join(out, 'm7-grid.png'), fullPage: true });
    await dialog().getByRole('button', { name: /اعتماد الكل/ }).click();
    await dialog().waitFor({ state: 'detached' });
    const n = (await db.query(`select count(*)::int n from goal_plans where month = $1`, [cur])).rows[0].n;
    assert.equal(n, 2);
  });

  await step('مجموعات الأصناف في صفحة المنتجات: إنشاء مجموعة باختيار الأصناف', async () => {
    await page.goto(BASE + '#/products');
    await page.getByRole('button', { name: 'مجموعات الأصناف' }).click();
    await drawer().getByRole('button', { name: 'مجموعة جديدة' }).click();
    await dialog().getByLabel('اسم المجموعة').fill('المكسرات');
    await dialog().getByRole('button', { name: 'اختيار الظاهر' }).click();
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await dialog().waitFor({ state: 'detached' });
    await drawer().getByText('المكسرات').waitFor();
    const g = (await db.query(`select count(*)::int n from product_group_members`)).rows[0].n;
    assert.equal(g, 2);
    await page.screenshot({ path: path.join(out, 'm7-groups.png'), fullPage: true });
  });

  await step('مكافأة تجاوز هدف A: مستوى بمبلغ 200 ومكافأة 30، تسري لشهرين، فتظهر لمندوب تجاوز بـ700', async () => {
    await page.goto(BASE + '#/rewards');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('button', { name: 'مكافأة جديدة' }).click();
    await dialog().getByLabel('الاسم').fill('تجاوز A');
    await dialog().getByLabel('نوع الشرط').selectOption('over_target');
    await dialog().getByLabel('يسري حتى شهر').fill(next.slice(0, 7));
    await dialog().getByLabel('قيمة التجاوز').fill('200');
    await dialog().getByLabel('مبلغ مكافأة المستوى').fill('30');
    await dialog().getByLabel('طريقة الجمع').selectOption('STACK');
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await page.getByRole('heading', { name: 'تجاوز A' }).waitFor();
    await page.getByText('تجاوز هدف A الأصلي لصافي المبيعات').waitFor();
    await page.getByRole('row').filter({ hasText: 'مندوب أول' }).getByText('30.000').waitFor();
    await page.screenshot({ path: path.join(out, 'm7-rewards.png'), fullPage: true });
    // الشهر التالي ضمن السريان
    await page.getByLabel('الشهر').fill(next.slice(0, 7));
    await page.getByRole('heading', { name: 'تجاوز A' }).waitFor();
  });

  await step('قاعدة عمولة بحد أدنى للمبيعات لموظف وقاعدة تصاعدية، وتظهر في القائمة', async () => {
    await page.goto(BASE + '#/commission-rules');
    await page.getByLabel('الشهر').fill(curInput);
    await page.getByRole('button', { name: 'قاعدة جديدة' }).click();
    await dialog().getByLabel('اسم القاعدة').fill('قاعدة الشهر');
    await dialog().getByLabel('نسبة المندوب').first().fill('2');
    await dialog().getByLabel('نسبة المندوب').nth(1).fill('1.5');
    await dialog().getByLabel('نسبة المندوب').nth(2).fill('1');
    await dialog().getByLabel('نسبة المندوب').nth(3).fill('0.5');
    for (const t of ['A', 'B', 'C', 'X']) await dialog().getByLabel('نسبة المشرف').nth(['A', 'B', 'C', 'X'].indexOf(t)).fill('2');
    await dialog().getByText('20 — مندوب أول').click();
    await dialog().getByText('30 — مشرف المنطقة').click();
    await dialog().getByText('استثناءات المشمولين').click();
    await dialog().getByLabel('حد أدنى مندوب أول').fill('5000');
    await dialog().getByText('القاعدة التصاعدية (اختياري)').click();
    await dialog().getByLabel('حد التصاعد').fill('1000');
    await dialog().getByLabel('خطوة التصاعد').fill('500');
    await dialog().getByLabel('إضافة التصاعد').fill('0.25');
    await dialog().getByLabel('سقف التصاعد').fill('1');
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.getByText(/قاعدة تصاعدية/).waitFor();
    await page.getByText(/حد أدنى 5000\.000/).waitFor();
    const r = (await db.query(`select prog_cap::text c, (select min_sales::text from rule_members m where m.rule_id = r.id and m.employee_id = $1) m from commission_rules r where month = $2`, [e.r1, cur])).rows[0];
    assert.deepEqual([r.c, r.m], ['1', '5000']);
    await page.screenshot({ path: path.join(out, 'm7-rules.png'), fullPage: true });
  });

  await step('كشف العمولات: الحد الأدنى يصفّر الأساسية ويظهر في الكشف، والشريحة اليدوية قائمة من شرائح القاعدة، وإلغاء كل القرارات', async () => {
    await page.goto(BASE + '#/commissions');
    await page.getByLabel('الشهر').fill(curInput);
    const row = page.getByRole('row').filter({ hasText: 'مندوب أول' });
    await row.click();
    await drawer().getByText('مراحل الحساب').waitFor();
    await drawer().getByText(/لم يُبلغ، فالأساسية صفر/).waitFor();
    await drawer().getByText(/دون الحد الأدنى للمبيعات/).first().waitFor();
    await drawer().getByRole('button', { name: 'قرار صرف' }).click();
    await dialog().getByLabel('القرار').selectOption('manual_tier');
    const opts = await dialog().getByLabel('الشريحة').locator('option').allTextContents();
    assert.deepEqual(opts.map((x) => x.trim()).filter(Boolean).filter((x) => x !== 'اختر'), ['A', 'B', 'C', 'X'], JSON.stringify(opts));
    // قرار إضافة ثم إلغاء الكل
    await dialog().getByLabel('القرار').selectOption('add');
    await dialog().getByLabel('المبلغ').fill('10');
    await dialog().getByLabel('السبب').fill('جهد');
    await dialog().getByRole('button', { name: 'معاينة' }).click();
    await dialog().getByRole('button', { name: 'اعتماد' }).click();
    await drawer().getByText('جهد').waitFor();
    await drawer().getByRole('button', { name: 'إغلاق' }).click();
    await page.getByRole('button', { name: 'إلغاء كل قرارات الشهر' }).click();
    await dialog().getByText(/تُلغى 1 قرارًا/).waitFor();
    await dialog().getByLabel('السبب (إلزامي)').fill('قرارات اختبار');
    await dialog().getByRole('button', { name: /إلغاء الكل/ }).click();
    await dialog().waitFor({ state: 'detached' });
    const n = (await db.query(`select count(*)::int n from commission_adjustments where status = 'active'`)).rows[0].n;
    assert.equal(n, 0);
  });

  await step('بطاقات الأداء: بطاقات الشرائح A وB وC دون X، «من هدف A»، أرقام صحيحة، وتحكم الإدارة بعبارة المسار', async () => {
    await page.goto(BASE + '#/cards');
    await page.getByLabel('الشهر').fill(curInput);
    const card = page.locator(`.perf-card[data-employee="${e.r1}"]`);
    await card.waitFor();
    assert.equal(await card.locator('.tile').count(), 3);
    assert.equal(await card.locator('.tile', { hasText: 'X' }).count(), 0);
    await card.getByText('من هدف A').waitFor();
    assert.ok(!/\d,\d{3}|\.\d{3}/.test(await card.locator('.tiles').innerText()), 'أرقام البطاقة صحيحة بلا فواصل أو كسور');
    assert.equal(await page.getByText(/متقدم بـ|متأخر بـ/).count(), 0, 'العبارة مخفية افتراضيًا');
    await page.getByRole('button', { name: 'خيارات العرض' }).click();
    await page.locator('.pop').getByLabel('متقدم/متأخر (للجميع)').click();
    await page.getByRole('button', { name: 'خيارات العرض' }).click();
    await page.waitForTimeout(800);
    assert.equal((await db.query(`select value::text v from settings where key = 'show_path_phrase'`)).rows[0].v, 'true');
    await page.screenshot({ path: path.join(out, 'm7-cards.png'), fullPage: true });
    await page.getByRole('button', { name: 'خيارات العرض' }).click();
    await page.locator('.pop').getByLabel('أهداف الشرائح').uncheck();
    assert.equal(await card.locator('.tile').count(), 0);
    await page.locator('.pop').getByLabel('أهداف الشرائح').check();
  });

  await step('صفحة البداية: مندوب له صلاحية البطاقات يبدأ ببطاقته', async () => {
    await rpc('admin_save_user', { p_id: null, p_user: { username: 'rep1', password: 'Rep#2026xx', display_name: 'مندوب', employee_id: e.r1, data_scope: 'self',
      overrides: [{ page: 'P13', action: 'view', granted: true }, { page: 'P01', action: 'view', granted: true }] } });
    const c2 = await browser.newContext({ viewport: { width: 1366, height: 900 }, locale: 'ar' });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(15000);
    p2.on('pageerror', (x) => errors.push(x.message));
    await login(p2, 'rep1', 'Rep#2026xx', 'بطاقات الأداء');
    assert.match(p2.url(), /#\/cards/);
    await c2.close();
  });

  await step('الهاتف 390: البطاقات وجدول الأهداف دون تمرير أفقي للصفحة', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(15000);
    p2.on('pageerror', (x) => errors.push(x.message));
    await login(p2);
    for (const [route, f] of [['/cards', 'm7-cards-mobile-390.png'], ['/commission-rules', 'm7-rules-mobile-390.png'], ['/rewards', 'm7-rewards-mobile-390.png']]) {
      await p2.goto(BASE + '#' + route);
      await p2.waitForTimeout(1200);
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
