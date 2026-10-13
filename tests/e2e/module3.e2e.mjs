// اختبار شامل للوحدة 3 في متصفح حقيقي: كشف الحساب الرسمي والمخصص والمحفوظ والعائلة، والمعاينة وPDF وExcel،
// والذمم و«كيف سُدد؟»، والافتتاحيات باستيراد ومعاينة، والإغلاق السنوي، والإشعارات، وتصنيف المرتجع في صفحة السندات،
// ولقطات على الحاسوب والهاتف. البيانات الأساسية تُهيأ عبر دوال قاعدة البيانات نفسها كمستخدم الإدارة.
// التشغيل: node e2e/module3.e2e.mjs   (بعد bash local/reset_db.sh)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import pg from 'pg';
import * as XLSX from 'xlsx';
import { ANON_KEY } from '../local/gateway.mjs';
import { writeXlsx } from './fixtures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '../../app');
const out = path.resolve(here, 'out');
fs.mkdirSync(out, { recursive: true });
const BASE = 'http://localhost:3102/';

// ---------------------------------------------------------------------
// التهيئة عبر الدوال المحمية كمستخدم الإدارة
// ---------------------------------------------------------------------
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
const COL_COLS = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];
let rowNo = 2;
async function add(kind, docs) {
  const rows = docs.map(([num, cust, date, amount, pay = 'فاتورة ذمم']) => (kind === 'collection'
    ? { row: rowNo++, doc_number: num, customer_number: cust, doc_date: date, employee_number: '20', amount: String(amount), pay_method: 'نقدي', cheque_no: '' }
    : { row: rowNo++, doc_number: num, customer_number: cust, doc_date: date, employee_number: '20', pay_type: pay, item_number: 'A1', item_name: 'صنف',
        net_sales: String(amount), net_promotions: '0', quantity: '1', bonus: '0' }));
  const cols = kind === 'collection' ? COL_COLS : kind === 'return' ? INV_COLS.filter((c) => c !== 'DocumentTypeID') : INV_COLS;
  const s = await rpc('upload_stage', { p_kind: kind, p_file_name: kind + '.xlsx', p_sheet: 'S', p_columns: cols, p_rows: rows });
  const its = (await db.query('select id, errors from batch_items where batch_id = $1', [s.batch_id])).rows;
  assert.equal(its.flatMap((i) => i.errors).length, 0, 'أخطاء في التهيئة');
  await rpc('upload_resolve', { p_batch: s.batch_id, p_decisions: its.map((i) => ({ id: i.id, action: 'approve' })) });
}
await rpc('save_setting', { p_key: 'company_name', p_value: JSON.stringify('شركة الاختبار') });
await rpc('save_setting', { p_key: 'company_tax_no', p_value: JSON.stringify('123456789') });
await rpc('save_employee', { p_id: null, p: { emp_number: '20', name: 'مندوب تجريبي', join_date: '2026-01-01' } });
const ids = {};
for (const [num, name, master] of [['500', 'بقالة الاختبار', null], ['600', 'سوبرماركت رئيسي', null], ['601', 'سوبرماركت فرع أ', '600'], ['602', 'سوبرماركت فرع ب', '600']]) {
  ids[num] = await rpc('save_customer', { p_id: null, p: { customer_number: num, name, master_number: master } });
}
const prod = await rpc('save_product', { p_id: null, p_code: 'A1', p_name: 'صنف' });
await rpc('set_product_value', { p_product: prod, p_kind: 'sale', p_value: '1', p_date: '2026-01-01' });
await rpc('save_opening', { p_customer: ids['500'], p_year: 2026, p_debit: 500, p_credit: null });
await add('invoice', [['1', '500', '2026-09-01', 100], ['2', '500', '2026-09-04', 80, 'فاتورة نقدي'],
  ['10', '601', '2026-09-01', 100], ['11', '602', '2026-09-03', 150], ['12', '601', '2026-09-05', 200]]);
await add('collection', [['1', '500', '2026-09-02', 200], ['20', '600', '2026-09-06', 300]]);
await add('return', [['1', '500', '2026-09-03', 50]]);

const vite = spawn('npx', ['vite', '--port', '3102', '--strictPort'], {
  cwd: appDir, env: { ...process.env, VITE_SUPABASE_URL: 'http://localhost:54321', VITE_SUPABASE_ANON_KEY: ANON_KEY }, stdio: 'pipe',
});
await new Promise((r) => { vite.stdout.on('data', (d) => /Local/.test(String(d)) && r()); setTimeout(r, 8000); });

const browser = await chromium.launch();
const errors = [];
const results = [];
let shot = null;
const step = async (name, fn) => {
  console.log('… ' + name);
  try { await fn(); results.push(['✔', name]); }
  catch (e) { results.push(['✖', name + ' — ' + e.message.split('\n')[0]]); await shot?.(`m3-fail-${results.length}.png`); }
};

try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ar', acceptDownloads: true });
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  const dialog = () => page.locator('.modal');
  const stat = (label) => page.locator('.stat').filter({ hasText: label }).locator('.v');
  const pick = async (num) => {
    await page.getByLabel('العميل').first().fill(num);
    await page.locator('.picker-list li').filter({ hasText: num }).first().click();
  };
  const period = async (from, to) => {
    await page.getByLabel('من تاريخ').fill(from);
    await page.getByLabel('إلى تاريخ').fill(to);
  };

  await step('الدخول وظهور صفحات الحسابات في القائمة', async () => {
    await page.goto(BASE);
    await page.getByLabel('اسم المستخدم').fill('admin');
    await page.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
    await page.getByRole('button', { name: 'دخول' }).click();
    await page.getByRole('heading', { name: 'الرئيسية' }).waitFor();
    await page.getByRole('button', { name: 'الحسابات' }).click();
    for (const n of ['كشف حساب العميل', 'الذمم الحالية', 'الافتتاحيات والإغلاق السنوي', 'الإشعارات المدينة والدائنة']) {
      await page.getByRole('link', { name: n, exact: true }).waitFor();
    }
  });

  await step('الكشف الرسمي: 600 ثم 400 ثم 350 والنقدية غير مؤثرة (F01، F02)', async () => {
    await page.goto(BASE + '#/statement');
    await pick('500');
    await period('2026-09-01', '2026-09-30');
    await page.getByText('كشف رسمي').first().waitFor();
    await stat('الرصيد السابق').filter({ hasText: '500.000' }).waitFor();
    await stat('الرصيد النهائي').filter({ hasText: '350.000' }).waitFor();
    const balances = await page.locator('.tbl tbody tr td:nth-child(7)').allInnerTexts();
    assert.deepEqual(balances, ['600.000', '400.000', '350.000', '350.000']);
    await page.getByRole('row').filter({ hasText: 'فاتورة نقدي' }).getByText('غير مؤثرة').waitFor();
    await page.screenshot({ path: path.join(out, 'm3-statement.png'), fullPage: true });
  });

  await step('الفلتر لا يغير السابق والنهائي ويظهر إجمالي النتائج منفصلًا (F18)', async () => {
    await page.getByLabel('الفواتير').check();
    await page.getByText(/نتائج الفلتر/).waitFor();
    await stat('الرصيد النهائي').filter({ hasText: '350.000' }).waitFor();
    assert.equal(await page.locator('.tbl tbody tr').count(), 2);
    await page.getByRole('button', { name: 'مسح الفلاتر' }).click();
  });

  await step('المخصص: إخفاء التحصيل داخل الفترة 550 والرسمي ثابت، ثم الحفظ والفتح (F19، STMT-006)', async () => {
    await page.getByRole('tab', { name: 'مخصص' }).click();
    await page.getByRole('row').filter({ hasText: 'تحصيل' }).getByRole('button', { name: 'إخفاء' }).click();
    await stat('الرصيد النهائي (مخصص)').filter({ hasText: '550.000' }).waitFor();
    await page.getByRole('button', { name: 'مقارنة الرسمي بالمخصص' }).click();
    await page.getByRole('row').filter({ hasText: 'الرسمي' }).getByRole('cell', { name: '350.000' }).waitFor();
    await page.getByRole('button', { name: 'حفظ الكشف' }).click();
    await dialog().getByLabel('اسم الكشف').fill('كشف بقالة الاختبار - نهائي');
    await dialog().getByRole('button', { name: 'حفظ كشف جديد' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.goto(BASE + '#/statement');
    await page.reload();
    await page.getByLabel('الكشوف المحفوظة').selectOption({ label: 'كشف بقالة الاختبار - نهائي' });
    await stat('الرصيد النهائي (مخصص)').filter({ hasText: '550.000' }).waitFor();
    await page.getByRole('row').filter({ hasText: 'تحصيل' }).getByRole('button', { name: 'إعادة' }).waitFor();
  });

  await step('المعاينة والطباعة وPDF: الشركة والرقم الضريبي وإجمالي المطلوب فقط، بلا مندوب ولا تواقيع (STMT-007، F40، F41)', async () => {
    await page.getByRole('button', { name: 'معاينة وطباعة' }).click();
    const doc = page.locator('.print-doc');
    await doc.getByText('شركة الاختبار').waitFor();
    await doc.getByText('123456789').waitFor();
    await doc.getByText('كشف حساب عميل — كشف مخصص').waitFor();
    await doc.getByText('إجمالي المبلغ المطلوب: 550.000').waitFor();
    const text = await doc.innerText();
    assert.ok(!/المندوب|توقيع|بيانات توضيحية|نموذج للمراجعة/.test(text), 'نص غير مسموح في الوثيقة');
    assert.ok(!text.includes('200.000'), 'التحصيل المخفي لا يظهر في المخصص');
    await page.emulateMedia({ media: 'print' });
    await page.screenshot({ path: path.join(out, 'm3-statement-print.png'), fullPage: true });
    await page.pdf({ path: path.join(out, 'm3-statement.pdf'), format: 'A4' });
    await page.emulateMedia({ media: 'screen' });
    assert.ok(fs.statSync(path.join(out, 'm3-statement.pdf')).size > 5000);
    await dialog().getByRole('button', { name: 'إغلاق' }).last().click();
  });

  await step('Excel الكشف يشمل كل الحركات وأرقام المخصص', async () => {
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'تصدير Excel' }).click()]);
    const wb = XLSX.read(fs.readFileSync(await dl.path()));
    const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1 });
    assert.equal(rows[0][0], 'كشف مخصص');
    const body = rows.slice(rows.findIndex((r) => r[0] === 'التاريخ') + 1);
    assert.equal(body.length, 3);
    assert.equal(body[body.length - 1][7], '550.000');
  });

  await step('كشف العائلة: التحصيل صف واحد، وكشف الفرع حصته (F11، B034)', async () => {
    await page.goto(BASE + '#/statement');
    await page.reload();
    await pick('601');
    await period('2026-09-01', '2026-09-30');
    await page.getByLabel('العائلة كاملة').check();
    await page.getByText(/العائلة كاملة — الرئيسي 600/).waitFor();
    assert.equal(await page.getByRole('row').filter({ hasText: 'تحصيل' }).count(), 1);
    await page.getByRole('row').filter({ hasText: 'تحصيل' }).getByRole('cell', { name: '300.000' }).waitFor();
    await stat('الرصيد النهائي').filter({ hasText: '150.000' }).waitFor();
    await page.getByLabel('هذا الحساب فقط').check();
    await page.getByRole('row').filter({ hasText: 'حصة الحساب' }).getByRole('cell', { name: '150.000' }).first().waitFor();
    await page.screenshot({ path: path.join(out, 'm3-statement-branch.png'), fullPage: true });
  });

  await step('الذمم: البنود المفتوحة و«كيف سُدد؟» (P08، COL-008)', async () => {
    await page.goto(BASE + '#/receivables');
    await page.getByLabel('تاريخ الرصيد').fill('2026-09-30');
    await stat('إجمالي المتبقي').filter({ hasText: '500.000' }).waitFor();
    await page.getByRole('row').filter({ hasText: 'سوبرماركت فرع أ' }).first().click();
    await page.getByRole('row').filter({ hasText: '12' }).getByRole('button', { name: 'كيف سُدد؟' }).click();
    await dialog().getByRole('cell', { name: '50.000' }).waitFor();
    await dialog().getByText('تحصيل').first().waitFor();
    await page.screenshot({ path: path.join(out, 'm3-receivables.png'), fullPage: true });
    await dialog().getByRole('button', { name: 'إغلاق' }).click();
  });

  await step('الإشعار الدائن بمعاينة الأثر ثم اعتماد، ويظهر في الكشف (P09، F17)', async () => {
    await page.goto(BASE + '#/notes');
    await page.getByRole('button', { name: 'إشعار جديد' }).click();
    await dialog().getByLabel('إشعار دائن — يخفض الذمم').check();
    await dialog().getByLabel('العميل').fill('500');
    await dialog().locator('.picker-list li').first().click();
    await dialog().getByLabel('التاريخ').fill('2026-09-10');
    await dialog().getByLabel('القيمة').fill('25');
    await dialog().getByLabel('السبب').fill('خصم تجاري');
    await dialog().getByRole('button', { name: 'معاينة الأثر' }).click();
    await dialog().getByText(/يخفض الذمم ويُخصص على الديون/).waitFor();
    await dialog().getByRole('button', { name: 'اعتماد' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.getByRole('cell', { name: 'CN-0001' }).waitFor();
    await page.goto(BASE + '#/statement?customer=' + ids['500']);
    await period('2026-09-01', '2026-09-30');
    await stat('الرصيد النهائي').filter({ hasText: '325.000' }).waitFor();
  });

  await step('تصنيف المرتجع ظاهر في صفحة السندات (RET-005)', async () => {
    await page.goto(BASE + '#/transactions?kind=return');
    await page.getByRole('row').filter({ hasText: 'بقالة الاختبار' }).getByText('ذمم').waitFor();
  });

  await step('استيراد افتتاحيات 2027 بمعاينة: الجديد والفارغ والخطأ (FIN-003، FIN-006)', async () => {
    const file = writeXlsx(path.join(out, 'files', 'openings-2027.xlsx'), 'افتتاحيات 2027', ['رقم العميل', 'اسم العميل', 'مدين — على العميل', 'دائن — للعميل'],
      [['601', 'فرع أ', '120', ''], ['602', 'فرع ب', '', ''], ['999', 'مجهول', '5', ''], ['600', 'رئيسي', '5', '5']]);
    await page.goto(BASE + '#/openings');
    await page.getByLabel('السنة').selectOption('2027');
    await page.getByRole('button', { name: 'استيراد بمعاينة' }).click();
    await dialog().locator('input[type=file]').setInputFiles(file);
    await dialog().getByText(/جديد: 1/).waitFor();
    await dialog().getByText(/خطأ: 2/).waitFor();
    await dialog().getByText('الخانة الفارغة تعد صفرًا', { exact: false }).waitFor();
    await dialog().getByRole('button', { name: 'اعتماد الاستيراد' }).click();
    await dialog().getByText(/اكتمل: أضيف 1/).waitFor();
    await dialog().getByRole('button', { name: 'تم' }).click();
    await page.getByRole('row').filter({ hasText: 'سوبرماركت فرع أ' }).getByRole('cell', { name: '120.000' }).waitFor();
    await page.screenshot({ path: path.join(out, 'm3-openings.png'), fullPage: true });
  });

  await step('إغلاق سنة 2026: الإقفال والفروق والترحيل (B031، B038، F13)', async () => {
    await page.getByLabel('السنة').selectOption('2026');
    await page.getByRole('button', { name: 'إغلاق سنة 2026' }).click();
    await dialog().getByRole('row').filter({ hasText: 'سوبرماركت فرع أ' }).getByText('استبدال بالإقفال').waitFor();
    await dialog().getByRole('row').filter({ hasText: 'بقالة الاختبار' }).getByText('يُرحّل').waitFor();
    await page.screenshot({ path: path.join(out, 'm3-year-close.png'), fullPage: true });
    await dialog().getByRole('button', { name: 'اعتماد الإغلاق والترحيل' }).click();
    await dialog().getByText(/رُحّل \d+ رصيدًا افتتاحيًا إلى 2027، واستبدل 0، وأبقي 1/).waitFor();
    await dialog().getByRole('button', { name: 'تم' }).click();
    await page.getByLabel('السنة').selectOption('2027');
    await page.getByRole('row').filter({ hasText: 'بقالة الاختبار' }).getByRole('cell', { name: '325.000' }).first().waitFor();
    // افتتاح 601 المستورد 120 يبقى، وإقفاله 150 (300 ناقص 150 من تحصيل الرئيسي)، فيظهر الفرق -30
    const r601 = page.getByRole('row').filter({ hasText: 'سوبرماركت فرع أ' });
    await r601.getByRole('cell', { name: '150.000', exact: true }).waitFor();
    await r601.getByText('-30.000', { exact: true }).waitFor();
  });

  await step('الهاتف 390: الكشف والذمم دون تمرير أفقي للصفحة', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(10000);
    p2.on('pageerror', (e) => errors.push(e.message));
    await p2.goto(BASE);
    await p2.getByLabel('اسم المستخدم').fill('admin');
    await p2.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
    await p2.getByRole('button', { name: 'دخول' }).click();
    await p2.getByRole('heading', { name: 'الرئيسية' }).waitFor();
    for (const [route, f] of [[`/statement?customer=${ids['500']}`, 'm3-statement-mobile-390.png'], ['/receivables', 'm3-receivables-mobile-390.png'], ['/openings', 'm3-openings-mobile-390.png']]) {
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
const relevant = errors.filter((e) => !/favicon|fonts.googleapis/.test(e));
if (relevant.length) console.log('أخطاء المتصفح:', relevant.slice(0, 5));
const failed = results.filter(([s]) => s === '✖').length + (relevant.length ? 1 : 0);
console.log(failed ? `فشل ${failed}` : 'نجحت كل الخطوات');
process.exit(failed ? 1 : 0);
