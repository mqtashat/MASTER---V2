// اختبار شامل للوحدة 6 في متصفح حقيقي: بطاقات التقارير، المبيعات التفصيلية بالتجميع والترتيب والتصدير، التقرير المخصص
// وحفظه وإعادة فتحه، ملخص الإدارة، التحصيل والذمم، الانتشار وغير المشترين، الجودة والعمولات والأداء، الطباعة،
// وفشل الطلب دون نتيجة قديمة (U04)، والهاتف. البيانات تُهيأ عبر دوال قاعدة البيانات نفسها كمستخدم الإدارة.
// التشغيل: node e2e/module6.e2e.mjs   (بعد bash local/reset_db.sh)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import pg from 'pg';
import XLSX from 'xlsx';
import { ANON_KEY } from '../local/gateway.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '../../app');
const out = path.resolve(here, 'out');
fs.mkdirSync(out, { recursive: true });
const BASE = 'http://localhost:3106/';

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
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
async function coll(docs) {
  const rows = docs.map(([num, cust, date, emp, amount]) => ({ row: rowNo++, doc_number: num, customer_number: cust, doc_date: date, employee_number: emp,
    amount: String(amount), pay_method: 'نقدي', cheque_no: '' }));
  const s = await rpc('upload_stage', { p_kind: 'collection', p_file_name: 'c.xlsx', p_sheet: 'S', p_columns: COL_COLS, p_rows: rows });
  const its = (await db.query('select id from batch_items where batch_id = $1', [s.batch_id])).rows;
  await rpc('upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}
async function inv(docs, kind = 'invoice') {
  const rows = docs.map(([num, cust, date, emp, amount, lat = '', lng = '']) => ({ row: rowNo++, doc_number: num, customer_number: cust, doc_date: date,
    employee_number: emp, pay_type: kind === 'invoice' ? 'فاتورة نقدي' : undefined, item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '2', bonus: '0',
    lat: String(lat), lng: String(lng) }));
  const s = await rpc('upload_stage', { p_kind: kind, p_file_name: 'f.xlsx', p_sheet: 'S', p_columns: kind === 'invoice' ? INV_COLS : INV_COLS.filter((c) => c !== 'DocumentTypeID'), p_rows: rows });
  const its = (await db.query('select id, errors from batch_items where batch_id = $1', [s.batch_id])).rows;
  assert.equal(its.flatMap((i) => i.errors).length, 0, 'أخطاء في التهيئة');
  await rpc('upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}


const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Amman' }).format(new Date());
const cur = today.slice(0, 8) + '01';

const e = {};
e.sup = await rpc('save_employee', { p_id: null, p: { emp_number: '30', name: 'مشرف المنطقة', join_date: '2025-01-01' } });
e.r1 = await rpc('save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب أول', join_date: '2025-01-01', supervisor_id: e.sup } });
e.r2 = await rpc('save_employee', { p_id: null, p: { emp_number: '21', name: 'مندوب ثان', join_date: '2025-01-01', supervisor_id: e.sup } });
for (const [n, name] of [['500', 'بقالة'], ['501', 'سوبرماركت'], ['502', 'مخبز'], ['503', 'صيدلية']]) await rpc('save_customer', { p_id: null, p: { customer_number: n, name } });
const prod = await rpc('save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
await rpc('set_product_value', { p_product: prod, p_kind: 'sale', p_value: '1', p_date: '2025-01-01' });
// 503 عميل المندوب الأول من فاتورة قديمة ولم يشترِ هذا الشهر
await inv([['9', '503', '2025-06-01', '20', 50]]);
await inv([['1', '500', cur, '20', 100], ['2', '501', cur, '20', 300], ['3', '502', cur, '21', 200]]);
await inv([['R1', '500', cur, '20', 40]], 'return');
await coll([['C1', '501', cur, '20', 120]]);

const vite = spawn('npx', ['vite', '--port', '3106', '--strictPort'], {
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
  catch (err) { results.push(['✖', name + ' — ' + err.message.split('\n').slice(0, 3).join(' | ')]); await shot?.(`m6-fail-${results.length}.png`); }
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
  await ctx.addInitScript(() => { window.print = () => { window.__printed = (window.__printed || 0) + 1; }; });
  const page = await ctx.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', (x) => errors.push(x.message));
  page.on('console', (m) => m.type() === 'error' && !/Failed to load resource|status of 500/.test(m.text()) && errors.push(m.text()));
  page.on('response', (r) => r.status() >= 400 && !/fonts\.g/.test(r.url()) && !(r.status() === 500 && /report_run/.test(r.url())) && errors.push(r.status() + ' ' + r.url()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  const dialog = () => page.locator('.modal');
  const doc = () => page.locator('.report-doc');
  const stat = (l) => doc().locator('.stat').filter({ has: page.locator('.l', { hasText: l }) }).locator('.v');
  const card = (t) => page.locator('.report-card').filter({ hasText: t });
  const runIt = async () => { await page.getByRole('button', { name: 'تشغيل التقرير' }).click(); await doc().waitFor(); };

  await step('الدخول وبطاقات التقارير الثمانية والمخصص', async () => {
    await login(page);
    await page.getByRole('button', { name: 'التقارير', exact: true }).click();
    await page.getByRole('link', { name: 'التقارير', exact: true }).click();
    await page.getByRole('heading', { name: 'التقارير' }).waitFor();
    assert.equal(await page.locator('.report-card').count(), 9);
    assert.equal(await page.getByText('قيد البناء').count(), 0);
    await page.screenshot({ path: path.join(out, 'm6-cards.png'), fullPage: true });
  });

  await step('المبيعات التفصيلية: تجميع بالعميل، الإجمالي، الترتيب بالنقر، والتصدير الكامل', async () => {
    await card('المبيعات التفصيلية').click();
    await page.getByRole('group', { name: 'التجميع حسب' }).getByLabel('العميل').check();
    await runIt();
    assert.equal(await stat('صافي المبيعات').textContent(), '560.000');
    assert.equal(await doc().locator('tbody tr').count(), 3);
    await doc().locator('tfoot').getByText('560.000').waitFor();
    await doc().getByRole('button', { name: 'العميل' }).click();
    const first = async () => (await doc().locator('tbody tr').first().locator('td').first().textContent()).trim();
    const a = await first();
    await doc().getByRole('button', { name: /العميل/ }).click();
    assert.notEqual(await first(), a, 'الترتيب ينعكس');
    await doc().getByText('تعريف المقاييس ومصدرها').waitFor();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'تصدير Excel' }).click()]);
    const wb = XLSX.read(fs.readFileSync(await dl.path()));
    const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1 });
    assert.equal(rows[0][0], 'العميل');
    assert.ok(rows.some((r) => r[0] === 'الإجمالي'));
    await page.screenshot({ path: path.join(out, 'm6-sales.png'), fullPage: true });
  });

  await step('التقرير المخصص: أعمدة ومقاييس وترتيب، وحفظه باسم ثم إعادة فتحه', async () => {
    await page.getByRole('button', { name: 'كل التقارير' }).click();
    await card('تقرير مخصص').click();
    const dims = page.getByRole('group', { name: 'الأعمدة (التجميع)' });
    await dims.getByLabel('الموظف').uncheck();
    await dims.getByLabel('العميل').check();
    const meas = page.getByRole('group', { name: 'المقاييس' });
    await meas.getByLabel('المبيعات', { exact: true }).uncheck();
    await meas.getByLabel('المرتجعات', { exact: true }).uncheck();
    await meas.getByLabel('التحصيلات').check();
    await page.getByLabel('الترتيب حسب').selectOption('collections');
    await runIt();
    assert.match(await doc().locator('tbody tr').first().textContent(), /501/);
    assert.equal(await doc().locator('thead th').count(), 3);
    await page.getByRole('button', { name: 'حفظ الإعدادات' }).click();
    await dialog().getByLabel('اسم التقرير').fill('تحصيل العملاء');
    await dialog().getByRole('button', { name: 'حفظ' }).click();
    await page.getByText('— تحصيل العملاء').waitFor();
    await page.getByRole('button', { name: 'كل التقارير' }).click();
    await page.getByRole('button', { name: 'تحصيل العملاء' }).click();
    assert.equal(await page.getByRole('group', { name: 'المقاييس' }).getByLabel('التحصيلات').isChecked(), true);
    await runIt();
    await page.screenshot({ path: path.join(out, 'm6-custom.png'), fullPage: true });
  });

  await step('ملخص الإدارة والتحصيل والذمم', async () => {
    await page.getByRole('button', { name: 'كل التقارير' }).click();
    await card('ملخص الإدارة').click();
    await runIt();
    await doc().getByRole('row').filter({ hasText: 'صافي المبيعات' }).getByText('560.000').first().waitFor();
    assert.equal(await stat('التحصيلات').textContent(), '120.000');
    await page.screenshot({ path: path.join(out, 'm6-management.png'), fullPage: true });
    await page.getByRole('button', { name: 'كل التقارير' }).click();
    await card('التحصيل والذمم').click();
    await runIt();
    assert.equal(await stat('المحصل في الفترة').textContent(), '120.000');
    await doc().getByRole('heading', { name: 'المحصل حسب الموظف' }).waitFor();
  });

  await step('الانتشار: تنبيه المجموعة غير المعلومة، ثم غير المشترين لمندوب محدد', async () => {
    await page.getByRole('button', { name: 'كل التقارير' }).click();
    await card('الانتشار والعملاء').click();
    await runIt();
    await doc().getByText('غير المشترين لا يُحسبون إلا لمجموعة معلومة', { exact: false }).waitFor();
    await page.getByRole('button', { name: 'المندوبون' }).click();
    await page.locator('.multi-pop').getByLabel(/مندوب أول/).check();
    await page.getByRole('button', { name: /المندوبون/ }).click();
    await runIt();
    await doc().getByRole('row').filter({ hasText: '503' }).getByText('غير مشترٍ').waitFor();
    await page.screenshot({ path: path.join(out, 'm6-spread.png'), fullPage: true });
  });

  await step('الجودة والعمولات والأداء تعمل، والطباعة', async () => {
    for (const t of ['جودة البيانات والتعديلات', 'العمولات والمكافآت', 'أداء المندوبين والمشرفين']) {
      await page.getByRole('button', { name: 'كل التقارير' }).click();
      await card(t).click();
      await runIt();
    }
    await doc().getByRole('row').filter({ hasText: 'مندوب أول' }).first().waitFor();
    await page.getByRole('button', { name: 'طباعة / PDF' }).click();
    assert.equal(await page.evaluate(() => window.__printed), 1);
    await page.emulateMedia({ media: 'print' });
    await page.screenshot({ path: path.join(out, 'm6-print.png'), fullPage: true });
    await page.emulateMedia({ media: 'screen' });
  });

  await step('U04: فشل الطلب يعرض رسالة وإعادة محاولة دون نتيجة قديمة', async () => {
    let fail = true;
    await page.route('**/rpc/report_run', (r) => (fail ? (fail = false, r.fulfill({ status: 500, contentType: 'application/json', body: '{"message":"انقطع الاتصال"}' })) : r.continue()));
    await page.getByRole('button', { name: 'تشغيل التقرير' }).click();
    await page.getByRole('alert').getByText('انقطع الاتصال').waitFor();
    assert.equal(await doc().count(), 0, 'لا نتيجة قديمة');
    await page.getByRole('button', { name: 'إعادة المحاولة' }).click();
    await doc().waitFor();
    await page.unroute('**/rpc/report_run');
  });

  await step('الهاتف 390: التقارير دون تمرير أفقي للصفحة', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(15000);
    p2.on('pageerror', (x) => errors.push(x.message));
    await login(p2);
    await p2.goto(BASE + '#/reports');
    await p2.locator('.report-card').first().waitFor();
    let overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 1, `تمرير أفقي في البطاقات: ${overflow}`);
    await p2.screenshot({ path: path.join(out, 'm6-cards-mobile-390.png'), fullPage: true });
    await p2.locator('.report-card').filter({ hasText: 'المبيعات التفصيلية' }).click();
    await p2.getByRole('button', { name: 'تشغيل التقرير' }).click();
    await p2.locator('.report-doc').waitFor();
    overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 1, `تمرير أفقي في النتيجة: ${overflow}`);
    await p2.screenshot({ path: path.join(out, 'm6-sales-mobile-390.png'), fullPage: true });
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
