// اختبار شامل للوحدة 2 في متصفح حقيقي: الرفع الموحد بالأزرار الثلاثة، والمعاينة والتعليق والتصحيح والاستبعاد،
// وصفحة السندات (الملخص والتفاصيل والتعديل والنقل والتصدير)، وحماية التعديل اليدوي عند إعادة الرفع،
// وأجزاء التحصيل، وحذف الدفعة، ولقطات على الحاسوب والهاتف. يشغّل البوابة المحلية وخادم Vite تلقائيًا.
// التشغيل: node e2e/module2.e2e.mjs   (بعد bash local/reset_db.sh)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { ANON_KEY } from '../local/gateway.mjs';
import * as XLSX from 'xlsx';
import { makeFixtures, makeModule2Fixtures } from './fixtures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '../../app');
const out = path.resolve(here, 'out');
fs.mkdirSync(out, { recursive: true });
const fx = { ...makeFixtures(path.join(out, 'files')), ...makeModule2Fixtures(path.join(out, 'files')) };
const BASE = 'http://localhost:3101/';

const vite = spawn('npx', ['vite', '--port', '3101', '--strictPort'], {
  cwd: appDir, env: { ...process.env, VITE_SUPABASE_URL: 'http://localhost:54321', VITE_SUPABASE_ANON_KEY: ANON_KEY }, stdio: 'pipe',
});
await new Promise((r) => { vite.stdout.on('data', (d) => /Local/.test(String(d)) && r()); setTimeout(r, 8000); });

const browser = await chromium.launch();
const errors = [];
const results = [];
const step = async (name, fn) => {
  console.log('… ' + name);
  try { await fn(); results.push(['✔', name]); }
  catch (e) {
    results.push(['✖', name + ' — ' + e.message.split('\n')[0]]);
    await shot?.(`fail-${results.length}.png`);
  }
};
let shot = null;

try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ar', acceptDownloads: true });
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  shot = (f) => page.screenshot({ path: path.join(out, f), fullPage: true }).catch(() => {});
  await page.goto(BASE);

  const importFile = async (route, file, extra) => {
    await page.goto(BASE + '#' + route);
    await page.getByRole('button', { name: 'استيراد', exact: true }).click();
    await page.locator('input[type=file]').setInputFiles(file);
    await page.getByText('الصفوف:').waitFor();
    if (extra) await extra();
    await page.getByRole('button', { name: 'اعتماد' }).click();
    await page.getByText('اعتُمد الاستيراد').waitFor();
    await page.getByRole('button', { name: 'تم' }).click();
  };
  const dialog = () => page.locator('.modal');
  // الضغط على زر النوع يفتح اختيار الملف مباشرة (DATA-006)
  const upload = async (button, file) => {
    await page.goto(BASE + '#/upload');
    const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.getByRole('button', { name: button, exact: true }).click()]);
    await chooser.setFiles(file);
    await page.getByRole('button', { name: 'رجوع' }).waitFor();
  };
  const itemRow = (doc) => page.getByRole('row').filter({ has: page.getByRole('cell', { name: doc, exact: true }) });

  await step('التهيئة واستيراد التعريفات', async () => {
    await page.getByLabel('اسم المستخدم').fill('admin');
    await page.getByLabel('الاسم الظاهر').fill('الإدارة');
    await page.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
    await page.getByLabel('تأكيد كلمة المرور').fill('Admin#2026');
    await page.getByRole('button', { name: 'إنشاء حساب الإدارة' }).click();
    await page.getByRole('heading', { name: 'الرئيسية' }).waitFor();
    await importFile('/customers', fx.customers);
    await importFile('/employees', fx.employees);
    await importFile('/products', fx.products, async () => {
      for (const l of ['سعر البيع', 'سعر التكلفة', 'التعبئة', 'نسب العمولة']) await page.getByLabel(l, { exact: true }).fill('2026-01-01');
      await page.waitForTimeout(600);
    });
  });

  await step('رفع فواتير: معاينة الجديد والمعلق بالسبب (D11، D12، D16)', async () => {
    await upload('فواتير', fx.invoices);
    await page.getByRole('heading', { name: /دفعة الفواتير/ }).waitFor();
    await page.getByRole('tab', { name: /^الكل/ }).click();
    await itemRow('5002').getByText('موظف غير معرّف: 999').waitFor();
    await itemRow('5003').getByText(/غير مقبولة: فاتورة آجل/).waitFor();
    await itemRow('5001').getByText('جديد').waitFor();
    await page.screenshot({ path: path.join(out, 'm2-upload-preview.png'), fullPage: true });
  });

  await step('اعتماد الصحيح فقط؛ الدفعة لا تعرض مكتملة وفيها معلق (DATA-005)', async () => {
    await page.getByRole('button', { name: /اعتماد الصحيح/ }).click();
    await page.getByText(/الدفعة غير مكتملة: 2 سند بانتظار قرار، منها 2 معلق/).waitFor();
    await page.getByRole('tab', { name: /^الكل/ }).click();
    await itemRow('5001').getByText('أضيف').waitFor();
  });

  await step('تصحيح معلق يدويًا وإعادة فحصه ثم اعتماده، واستبعاد آخر', async () => {
    await itemRow('5003').click();
    await dialog().getByText('قيمة DocumentTypeID غير مقبولة').waitFor();
    await dialog().getByRole('button', { name: 'تصحيح يدوي' }).click();
    await dialog().getByLabel('نوع الفاتورة (DocumentTypeID)').selectOption('فاتورة نقدي');
    await dialog().getByRole('button', { name: 'حفظ وإعادة الفحص' }).click();
    await dialog().getByRole('button', { name: 'اعتماد', exact: true }).click();
    await dialog().waitFor({ state: 'detached' });
    await itemRow('5002').click();
    await dialog().getByRole('button', { name: 'استبعاد من الدفعة' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.getByRole('tab', { name: /^الكل/ }).click();
    await itemRow('5003').getByText('أضيف').waitFor();
    await itemRow('5002').getByText('مستبعد من الدفعة').waitFor();
    await page.getByText('مكتملة', { exact: true }).waitFor();
  });

  await step('صفحة الفواتير: الملخص لكامل النتائج والتفاصيل بالكسور (INV-007، D29)', async () => {
    await page.goto(BASE + '#/transactions?kind=invoice');
    await page.getByLabel('ملخص كامل النتائج').getByText('55.989').waitFor();
    await page.getByRole('cell', { name: '5004', exact: true }).click();
    await page.getByRole('cell', { name: '5.5', exact: true }).waitFor();
    await page.getByRole('cell', { name: '0.5', exact: true }).waitFor();
    await page.getByRole('cell', { name: '5.5', exact: true }).first().waitFor();
    await page.screenshot({ path: path.join(out, 'm2-invoice-drawer.png') });
  });

  await step('تعديل كامل بمعاينة الفروق ثم حماية التعديل (TXN-001)', async () => {
    await page.getByRole('button', { name: 'تعديل' }).click();
    await dialog().getByLabel('المباشر NetSales 1').fill('12');
    await dialog().getByRole('button', { name: 'معاينة الفروق' }).click();
    await dialog().getByText(/تتغير المبالغ أو الأصناف/).waitFor();
    await dialog().getByLabel('سبب التعديل').fill('تصحيح مبلغ');
    await dialog().getByRole('button', { name: 'حفظ التعديل' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.getByText('معدل يدويًا — محمي من إعادة الرفع').waitFor();
    await page.getByRole('tab', { name: 'المصدر والإصدارات' }).click();
    await page.getByRole('cell', { name: 'تعديل يدوي' }).waitFor();
    await page.getByRole('button', { name: 'إغلاق' }).first().click();
  });

  await step('نقل فاتورة إلى موظف آخر بمعاينة العدد والمبلغ (TXN-002)', async () => {
    await page.getByLabel('تحديد 5001').check();
    await page.getByRole('button', { name: 'نقل المحدد إلى موظف' }).click();
    await dialog().getByLabel('رقم الموظف الجديد').fill('803');
    await dialog().getByRole('button', { name: 'معاينة' }).click();
    await dialog().getByText('38.989').first().waitFor();
    await dialog().getByRole('button', { name: 'تأكيد النقل' }).click();
    await dialog().waitFor({ state: 'detached' });
    await itemRow('5001').getByText('مندوب تجريبي ب').waitFor();
  });

  await step('إعادة رفع الملف: المعدل يدويًا محمي حتى الاختيار الصريح (TXN-003، D01)', async () => {
    await upload('فواتير', fx.invoices);
    await page.getByRole('tab', { name: /^الكل/ }).click();
    await itemRow('5001').getByText('يتعارض مع تعديل يدوي').waitFor();
    await itemRow('5004').getByText('يتعارض مع تعديل يدوي').waitFor();
    await page.getByRole('button', { name: /اعتماد الصحيح \(0\)/ }).waitFor();
    await itemRow('5001').click();
    await dialog().getByText('المحفوظ — معدل يدويًا').waitFor();
    await dialog().getByRole('button', { name: 'إبقاء المعدل يدويًا' }).click();
    await dialog().waitFor({ state: 'detached' });
    await page.goto(BASE + '#/transactions?kind=invoice');
    await itemRow('5001').getByText('مندوب تجريبي ب').waitFor();
  });

  await step('التحصيلات: الأجزاء المتطابقة والصفرية تجمع، و«----» معلق (COL-002، D13، D28)', async () => {
    await upload('تحصيلات', fx.collections);
    await page.getByRole('tab', { name: /^الكل/ }).click();
    await itemRow('7002').getByText(/قيمة الدفع ---- غير مقبولة/).waitFor();
    await page.getByRole('button', { name: /اعتماد الصحيح/ }).click();
    await page.getByText(/الدفعة غير مكتملة/).waitFor();
    await page.goto(BASE + '#/transactions?kind=collection');
    await page.getByRole('cell', { name: '100.000' }).waitFor();
    await page.getByRole('cell', { name: '7001', exact: true }).click();
    await page.getByText('صفر', { exact: true }).waitFor();
    await page.screenshot({ path: path.join(out, 'm2-collection-drawer.png') });
    await page.getByRole('button', { name: 'إغلاق' }).first().click();
  });

  await step('تصدير جميع فواتير فترة بالتفاصيل (INV-008)', async () => {
    await page.goto(BASE + '#/transactions?kind=invoice');
    await page.getByRole('button', { name: 'تصدير Excel' }).click();
    await dialog().getByText(/جميع الفواتير فترة/).click();
    await dialog().getByLabel('من تاريخ').fill('2026-10-01');
    await dialog().getByLabel('إلى تاريخ').fill('2026-10-31');
    await dialog().getByText(/تفاصيل: صف لكل بند/).click();
    const [dl] = await Promise.all([page.waitForEvent('download'), dialog().getByRole('button', { name: 'تصدير', exact: true }).click()]);
    // Chromium دون واجهة يسمي تنزيلات blob «download»، فنتحقق من محتوى الملف لا اسمه
    const wb = XLSX.read(fs.readFileSync(await dl.path()));
    const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1 });
    assert.equal(wb.SheetNames[0], 'الفواتير');
    assert.ok(rows[0].includes('رقم الصنف'), 'عمود الصنف في التفاصيل');
    assert.equal(new Set(rows.slice(1).map((r) => String(r[0]))).size, 3, 'ثلاثة سندات');
    await dialog().getByText('صدر 3 سند بكامل بنودها.').waitFor();
    await dialog().getByRole('button', { name: 'إغلاق' }).last().click();
  });

  await step('حذف دفعة التحصيلات بمعاينة ما يزال (DATA-007)، والملخص الجانبي يتحدث (D25)', async () => {
    await page.goto(BASE + '#/upload?tab=log');
    await page.getByRole('tab', { name: 'سجل الرفع' }).click();
    await itemRow('collections.xlsx').getByRole('button', { name: 'حذف الدفعة' }).click();
    await dialog().getByText('السندات التي ستزال (1)').waitFor();
    await dialog().getByLabel('سبب الحذف').fill('ملف تجريبي');
    await dialog().getByRole('button', { name: 'تأكيد حذف الدفعة' }).click();
    await dialog().waitFor({ state: 'detached' });
    await itemRow('collections.xlsx').getByText('محذوفة').waitFor();
    const side = page.getByLabel('حداثة السندات');
    await side.getByRole('row').filter({ hasText: 'التحصيلات' }).getByRole('cell', { name: '—' }).first().waitFor();
    await side.getByRole('row').filter({ hasText: 'الفواتير' }).getByRole('cell', { name: '1/10/2026', exact: true }).waitFor();
    await page.screenshot({ path: path.join(out, 'm2-upload-log.png'), fullPage: true });
  });

  await step('الهاتف 390: صفحة الفواتير والرفع دون تمرير أفقي للصفحة (U05)', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(10000);
    p2.on('pageerror', (e) => errors.push(e.message));
    await p2.goto(BASE);
    await p2.getByLabel('اسم المستخدم').fill('admin');
    await p2.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
    await p2.getByRole('button', { name: 'دخول' }).click();
    await p2.getByRole('heading', { name: 'الرئيسية' }).waitFor();
    for (const [route, shot] of [['/transactions?kind=invoice', 'm2-invoices-mobile-390.png'], ['/upload', 'm2-upload-mobile-390.png']]) {
      await p2.goto(BASE + '#' + route);
      await p2.waitForTimeout(800);
      const overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 1, `تمرير أفقي للصفحة في ${route}: ${overflow}`);
      await p2.screenshot({ path: path.join(out, shot), fullPage: true });
    }
    await c2.close();
  });
} finally {
  await browser.close();
  vite.kill();
}

for (const [s, n] of results) console.log(s, n);
const relevant = errors.filter((e) => !/favicon|fonts.googleapis/.test(e));
if (relevant.length) console.log('أخطاء المتصفح:', relevant.slice(0, 5));
const failed = results.filter(([s]) => s === '✖').length + (relevant.length ? 1 : 0);
console.log(failed ? `فشل ${failed}` : 'نجحت كل الخطوات');
process.exit(failed ? 1 : 0);
