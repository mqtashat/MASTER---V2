// اختبار شامل للوحدة 5 في متصفح حقيقي: استيراد مواقع العملاء بمعاينة وتعديل موقع يدويًا، رسم منطقة بالنقر واستيراد حدودها
// ومعاينة المتأثرين، خريطة الفواتير بإجمالياتها وقائمة غير المحدد موقعها، مقارنة الفترات، انتشار صنف، ولقطات على الحاسوب والهاتف.
// البيانات الأساسية تُهيأ عبر دوال قاعدة البيانات نفسها كمستخدم الإدارة.
// التشغيل: node e2e/module5.e2e.mjs   (بعد bash local/reset_db.sh)
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
const BASE = 'http://localhost:3105/';

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
  const rows = docs.map(([num, cust, date, emp, amount, lat = '', lng = '']) => ({ row: rowNo++, doc_number: num, customer_number: cust, doc_date: date,
    employee_number: emp, pay_type: 'فاتورة نقدي', item_number: 'A1', item_name: 'صنف', net_sales: String(amount), net_promotions: '0', quantity: '2', bonus: '0',
    lat: String(lat), lng: String(lng) }));
  const s = await rpc('upload_stage', { p_kind: 'invoice', p_file_name: 'invoice.xlsx', p_sheet: 'S', p_columns: INV_COLS, p_rows: rows });
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
await rpc('import_customer_locations', { p_rows: [{ row: '2', customer_number: '500', lat: '31.5', lng: '35.5' }, { row: '3', customer_number: '501', lat: '31.5', lng: '36.5' }], p_commit: true });
// المنطقة الغربية [31..32]×[35..36] للمندوب الأول؛ الشرقية تُرسم من الواجهة للمندوب الثاني
await rpc('save_region', { p_id: null, p: { name: 'الغربية', color: '#2e7d32', geom: [[[31, 35], [31, 36], [32, 36], [32, 35]]], employee_id: e.r1, valid_from: cur }, p_code: null });
// فواتير الشهر الحالي: 1 داخل منطقة مندوبها، 2 داخل الشرقية بعد رسمها، 3 خارج الغربية، 4 بلا موقع
await inv([['1', '500', cur, '20', 100, 31.5, 35.5], ['2', '501', cur, '21', 200, 31.5, 36.5], ['3', '501', cur, '20', 300, 31.5, 36.5], ['4', '502', cur, '21', 400]]);

fs.writeFileSync(path.join(out, 'east.geojson'), JSON.stringify({ type: 'FeatureCollection', features: [{ type: 'Feature', properties: {},
  geometry: { type: 'Polygon', coordinates: [[[36.01, 31], [37, 31], [37, 32], [36.01, 32], [36.01, 31]]] } }] }));
const wb = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([['CustomerNumber', 'Customername', 'Latitude', 'Longitude'], ['500', 'بقالة', '31.5', '35.5'], ['502', 'مخبز', '31.6', '36.6'], ['999', 'مجهول', '31', '35']]), 'S');
XLSX.writeFile(wb, path.join(out, 'locations.xlsx'));

const vite = spawn('npx', ['vite', '--port', '3105', '--strictPort'], {
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
  catch (err) { results.push(['✖', name + ' — ' + err.message.split('\n').slice(0, 3).join(' | ')]); await shot?.(`m5-fail-${results.length}.png`); }
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
  page.on('console', (m) => m.type() === 'error' && !/Failed to load resource/.test(m.text()) && errors.push(m.text()));
  page.on('response', (r) => r.status() >= 400 && !/tile\.openstreetmap|fonts\.g/.test(r.url()) && errors.push(r.status() + ' ' + r.url()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  const dialog = () => page.locator('.modal');
  const side = () => page.locator('.map-list');

  await step('الدخول وظهور صفحات الخرائط الخمس في القائمة', async () => {
    await login(page);
    await page.getByRole('button', { name: 'الخرائط' }).click();
    for (const n of ['خريطة الفواتير والمسار', 'مواقع العملاء', 'المناطق والأسواق', 'مقارنة الفترات', 'انتشار الأصناف']) {
      await page.getByRole('link', { name: n, exact: true }).waitFor();
    }
    assert.equal(await page.getByText('قيد البناء').count(), 0);
  });

  await step('مواقع العملاء: استيراد بمعاينة (جديد 1، خطأ 1، الفارغ لا يمحو) ثم اعتماد', async () => {
    await page.goto(BASE + '#/locations');
    await page.getByText('4 عميل · 2 على الخريطة · 2 بلا موقع صالح').waitFor();
    await page.locator('.map-wrap[data-points="2"]').waitFor();
    await page.getByRole('button', { name: 'استيراد المواقع' }).click();
    await dialog().getByLabel('ملف المواقع').setInputFiles(path.join(out, 'locations.xlsx'));
    await dialog().getByText('جديد: 1').waitFor();
    await dialog().getByText('خطأ: 1').waitFor();
    await dialog().getByText('بلا تغيير: 1').waitFor();
    await page.screenshot({ path: path.join(out, 'm5-import.png'), fullPage: true });
    await dialog().getByRole('button', { name: 'اعتماد (1)' }).click();
    await dialog().getByText('اعتُمد الاستيراد.').waitFor();
    await dialog().getByRole('button', { name: 'تم' }).click();
    await page.getByText('4 عميل · 3 على الخريطة · 1 بلا موقع صالح').waitFor();
  });

  await step('تعديل موقع عميل بلا موقع يدويًا', async () => {
    await page.getByRole('tab', { name: 'المفقود' }).click();
    await side().getByRole('row').filter({ hasText: '503' }).getByRole('button', { name: 'تعديل' }).click();
    await dialog().getByLabel('خط العرض').fill('31.4');
    await dialog().getByLabel('خط الطول').fill('35.4');
    await dialog().locator('.map-wrap[data-points="1"]').waitFor();
    await dialog().getByRole('button', { name: 'حفظ الموقع' }).click();
    await page.getByText('لا عملاء ضمن الفلاتر').waitFor();
    await page.getByRole('tab', { name: 'الكل' }).click();
    await page.getByText('4 عميل · 4 على الخريطة · 0 بلا موقع صالح').waitFor();
    await page.screenshot({ path: path.join(out, 'm5-locations.png'), fullPage: true });
  });

  await step('المناطق: نقطة بالنقر على الخريطة، ثم حدود من GeoJSON، معاينة المتأثرين وحفظ', async () => {
    await page.goto(BASE + '#/regions');
    await side().getByText('الغربية').waitFor();
    await side().getByText('2 عميل').waitFor();
    await page.getByRole('button', { name: 'منطقة جديدة' }).click();
    const box = await page.locator('.map-wrap').first().boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await page.locator('.vertex').first().waitFor();
    assert.equal(await page.locator('.vertex').count(), 1);
    await side().getByRole('button', { name: 'مسح الحدود' }).click();
    await side().locator('input[type=file]').setInputFiles(path.join(out, 'east.geojson'));
    await page.locator('.vertex').nth(3).waitFor();
    await side().getByLabel('الاسم', { exact: true }).fill('الشرقية');
    await side().getByLabel('يسري من').fill(cur);
    await side().getByLabel('المندوب').selectOption(String(e.r2));
    await side().getByRole('button', { name: 'معاينة المتأثرين' }).click();
    await side().getByText(/داخل الحدود: 2 عميل/).waitFor();
    await page.screenshot({ path: path.join(out, 'm5-region-editor.png'), fullPage: true });
    await side().getByRole('button', { name: 'حفظ' }).click();
    await side().locator('.region-row').filter({ hasText: 'الشرقية' }).getByText('2 عميل').waitFor();
    await page.getByText(/داخل مناطق 4/).waitFor();
    await page.screenshot({ path: path.join(out, 'm5-regions.png'), fullPage: true });
    await side().locator('.region-row').filter({ hasText: 'الشرقية' }).getByRole('link', { name: 'العملاء' }).click();
    await page.getByRole('heading', { name: 'مواقع العملاء' }).waitFor();
    await page.getByText('2 عميل · 2 على الخريطة').waitFor();
  });

  await step('خريطة الفواتير: الإجماليات وداخل/خارج المنطقة وقائمة بلا موقع وتصدير', async () => {
    await page.goto(BASE + '#/map');
    await page.getByLabel('من تاريخ').fill(cur);
    await page.getByLabel('إلى تاريخ').fill(today);
    const stat = (l) => page.locator('.stat').filter({ has: page.locator('.l', { hasText: l }) }).locator('.v');
    await page.waitForFunction(() => [...document.querySelectorAll('.stat .v')].some((x) => x.textContent === '4'));
    assert.equal(await stat('على الخريطة').textContent(), '3', 'على الخريطة');
    assert.equal(await stat('داخل / خارج المنطقة').textContent(), '2 / 1', 'داخل/خارج');
    await page.locator('.map-wrap[data-points="3"]').waitFor();
    await page.getByRole('button', { name: 'فواتير بلا موقع صالح (1)' }).click();
    await page.getByRole('link', { name: '4', exact: true }).waitFor();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'تصدير Excel' }).click()]);
    const rows = XLSX.utils.sheet_to_json(XLSX.read(fs.readFileSync(await dl.path())).Sheets['الفواتير']);
    assert.equal(rows.length, 4);
    await page.screenshot({ path: path.join(out, 'm5-invoice-map.png'), fullPage: true });
  });

  await step('مقارنة الفترات: شهران، «جديد» عند صفر الأساس، ومتوسط يوم العمل', async () => {
    await page.goto(BASE + '#/compare');
    const net = page.getByRole('row').filter({ hasText: 'صافي المبيعات' });
    await net.getByText('جديد').waitFor();
    await net.getByText(/1,000\.000|1000\.000/).first().waitFor();
    await page.getByRole('heading', { name: 'حسب المندوب' }).waitFor();
    await page.getByLabel('متوسط يوم العمل').check();
    await net.getByText('/ يوم عمل').waitFor();
    await page.screenshot({ path: path.join(out, 'm5-compare.png'), fullPage: true });
  });

  await step('انتشار صنف: المشترون والقائمة المتزامنة مع الخريطة والتصدير', async () => {
    await page.goto(BASE + '#/spread');
    await page.getByLabel('الصنف').selectOption(String(prod));
    const stat = (l) => page.locator('.stat').filter({ has: page.locator('.l', { hasText: l }) }).locator('.v');
    await stat('العملاء المشترون').getByText('3').waitFor();
    assert.equal(await side().locator('tbody tr').count(), 3);
    await side().getByRole('row').filter({ hasText: '501' }).click();
    await side().locator('tr.row-sel').waitFor();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByRole('button', { name: 'تصدير Excel' }).click()]);
    // الأسماء العربية للتنزيل لا تصل إلى Chromium دون واجهة؛ نتحقق من المحتوى
    const rows = XLSX.utils.sheet_to_json(XLSX.read(fs.readFileSync(await dl.path())).Sheets['الانتشار']);
    assert.equal(rows.length, 3);
    await page.screenshot({ path: path.join(out, 'm5-spread.png'), fullPage: true });
  });

  await step('هدف تغطية منطقة ونسبة تنوع في محرر الخطة بمعاينة', async () => {
    await page.goto(BASE + '#/goals');
    await page.getByLabel('الشهر').fill(cur.slice(0, 7));
    await page.getByRole('button', { name: 'خطة جديدة' }).click();
    const dlg = page.locator('.modal');
    await dlg.getByLabel('الموظف').selectOption(String(e.r1));
    await dlg.getByRole('button', { name: 'إضافة مكوّن' }).first().click();
    await dlg.getByLabel('المقياس').selectOption('coverage');
    await dlg.getByLabel('المنطقة').selectOption({ label: 'الغربية' });
    await dlg.getByLabel('الهدف %').fill('40');
    await dlg.getByRole('button', { name: 'معاينة النتيجة' }).click();
    await dlg.getByText('المعاينة قبل الاعتماد').waitFor();
    await dlg.getByText('المنطقة: الغربية').first().waitFor();
    await page.screenshot({ path: path.join(out, 'm5-coverage-goal.png'), fullPage: true });
    await dlg.getByRole('button', { name: 'إغلاق' }).first().click();
  });

  await step('الهاتف 390: صفحات الخرائط دون تمرير أفقي للصفحة', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(15000);
    p2.on('pageerror', (x) => errors.push(x.message));
    await login(p2);
    for (const route of ['/map', '/locations', '/regions', '/compare', '/spread']) {
      await p2.goto(BASE + '#' + route);
      await p2.waitForTimeout(1500);
      const overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 1, `تمرير أفقي للصفحة في ${route}: ${overflow}`);
      await p2.screenshot({ path: path.join(out, `m5${route.replace('/', '-')}-mobile-390.png`), fullPage: true });
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
