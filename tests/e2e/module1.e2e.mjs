// اختبار شامل للوحدة 1 في متصفح حقيقي: التهيئة، والاستيراد من الصفحات، والصلاحيات في الواجهة،
// ولقطات شاشة على الحاسوب والهاتف. يشغّل البوابة المحلية وخادم Vite تلقائيًا.
// التشغيل: node e2e/module1.e2e.mjs   (بعد bash local/reset_db.sh)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { ANON_KEY } from '../local/gateway.mjs';
import { makeFixtures } from './fixtures.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(here, '../../app');
const out = path.resolve(here, 'out');
fs.mkdirSync(out, { recursive: true });
const fx = makeFixtures(path.join(out, 'files'));

const vite = spawn('npx', ['vite', '--port', '3100', '--strictPort'], {
  cwd: appDir, env: { ...process.env, VITE_SUPABASE_URL: 'http://localhost:54321', VITE_SUPABASE_ANON_KEY: ANON_KEY }, stdio: 'pipe',
});
await new Promise((r) => { vite.stdout.on('data', (d) => /Local/.test(String(d)) && r()); setTimeout(r, 8000); });

const browser = await chromium.launch();
const errors = [];
const results = [];
const step = async (name, fn) => {
  console.log('… ' + name);
  try { await fn(); results.push(['✔', name]); }
  catch (e) { results.push(['✖', name + ' — ' + e.message.split('\n')[0]]); }
};

try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ar' });
  const page = await ctx.newPage();
  page.setDefaultTimeout(10000);
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.goto('http://localhost:3100/');

  await step('التهيئة الأولى لحساب الإدارة', async () => {
    await page.getByRole('heading', { name: 'تهيئة النظام' }).waitFor();
    await page.getByLabel('اسم المستخدم').fill('admin');
    await page.getByLabel('الاسم الظاهر').fill('الإدارة');
    await page.getByLabel('كلمة المرور', { exact: true }).fill('Admin#2026');
    await page.getByLabel('تأكيد كلمة المرور').fill('Admin#2026');
    await page.getByRole('button', { name: 'إنشاء حساب الإدارة' }).click();
    await page.getByRole('heading', { name: 'الرئيسية' }).waitFor();
  });

  const importFile = async (route, file, extra) => {
    await page.goto('http://localhost:3100/#' + route);
    await page.getByRole('button', { name: 'استيراد' }).click();
    await page.locator('input[type=file]').setInputFiles(file);
    await page.getByText('الصفوف:').waitFor();
    if (extra) await extra();
    await page.getByRole('button', { name: 'اعتماد' }).click();
    await page.getByText('اعتُمد الاستيراد').waitFor();
    await page.getByRole('button', { name: 'تم' }).click();
  };

  await step('استيراد العملاء بالمعاينة (D20، D22)', async () => {
    await importFile('/customers', fx.customers);
    await page.getByRole('cell', { name: 'سوبرماركت تجريبي - فرع' }).waitFor();
    assert.equal(await page.getByRole('cell', { name: '0094' }).count(), 1, 'الصفر البادئ محفوظ');
    await page.screenshot({ path: path.join(out, 'customers-desktop.png') });
  });

  await step('ملف العميل: الفروع والرئيسي', async () => {
    await page.getByRole('cell', { name: 'سوبرماركت تجريبي', exact: true }).click();
    await page.getByRole('tab', { name: 'الفروع والرئيسي' }).click();
    await page.getByText('الفروع الحالية (1)').waitFor();
    await page.getByRole('button', { name: 'إغلاق' }).first().click();
  });

  await step('استيراد الموظفين مع المشرف وفترة منتهية', async () => {
    await importFile('/employees', fx.employees);
    await page.getByRole('cell', { name: 'مندوب تجريبي ب' }).waitFor();
    await page.getByText('1/6/2025 – 31/12/2025').waitFor();
  });

  await step('استيراد المنتجات يطلب تواريخ السريان ثم يعتمد', async () => {
    await importFile('/products', fx.products, async () => {
      assert.ok(await page.getByRole('button', { name: 'اعتماد' }).isDisabled(), 'الاعتماد ممنوع قبل التواريخ');
      for (const l of ['سعر البيع', 'سعر التكلفة', 'التعبئة', 'نسب العمولة']) {
        await page.getByLabel(l, { exact: true }).fill('2026-01-01');
      }
      await page.waitForTimeout(600);
    });
    await page.getByRole('cell', { name: '9.499' }).waitFor();
  });

  await step('إنشاء قالب ومستخدم بصلاحية العملاء عرضًا فقط', async () => {
    await page.goto('http://localhost:3100/#/users');
    await page.getByRole('tab', { name: 'قوالب الصلاحيات' }).click();
    await page.getByRole('button', { name: 'قالب جديد' }).click();
    await page.getByLabel('اسم القالب').fill('مطلع العملاء');
    await page.getByLabel('العملاء — عرض', { exact: true }).check();
    await page.getByRole('dialog').getByRole('button', { name: 'حفظ' }).click();
    await page.getByRole('cell', { name: 'مطلع العملاء' }).waitFor();
    await page.getByRole('tab', { name: 'الحسابات' }).click();
    await page.getByRole('button', { name: 'حساب جديد' }).click();
    await page.getByLabel('اسم المستخدم').fill('viewer1');
    await page.getByLabel('الاسم الظاهر').fill('مطلع');
    await page.getByLabel('كلمة المرور', { exact: true }).fill('Viewer#2026');
    await page.getByLabel('القالب').selectOption({ label: 'مطلع العملاء' });
    await page.getByLabel('النطاق').selectOption('all');
    await page.getByRole('dialog').getByRole('button', { name: 'حفظ' }).click();
    await page.getByRole('cell', { name: 'viewer1' }).waitFor();
  });

  await step('المستخدم المقيد لا يرى إلا المسموح ولا أزرار ممنوعة (A03)', async () => {
    const c2 = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'ar', isMobile: true, hasTouch: true });
    const p2 = await c2.newPage();
    p2.setDefaultTimeout(10000);
    p2.on('pageerror', (e) => errors.push(e.message));
    await p2.goto('http://localhost:3100/');
    await p2.getByLabel('اسم المستخدم').fill('viewer1');
    await p2.getByLabel('كلمة المرور', { exact: true }).fill('Viewer#2026');
    await p2.getByRole('button', { name: 'دخول' }).click();
    await p2.getByRole('heading', { name: 'العملاء' }).waitFor();
    assert.equal(await p2.getByRole('button', { name: 'إضافة عميل' }).count(), 0);
    assert.equal(await p2.getByRole('button', { name: 'استيراد' }).count(), 0);
    await p2.getByRole('cell', { name: '9003' }).waitFor();
    // لا تمرير أفقي للصفحة على الهاتف (U05)
    const overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    assert.ok(overflow <= 1, 'تمرير أفقي للصفحة: ' + overflow);
    await p2.screenshot({ path: path.join(out, 'customers-mobile-390.png'), fullPage: true });
    // رابط مباشر لصفحة ممنوعة يعيد إلى المسموح
    await p2.goto('http://localhost:3100/#/users');
    await p2.getByRole('heading', { name: 'العملاء' }).waitFor();
    await c2.close();
  });

  await step('الإعدادات: عبارة المسار والرمز السري للإدارة', async () => {
    await page.goto('http://localhost:3100/#/settings');
    await page.getByRole('tab', { name: 'إعدادات الإدارة' }).click();
    await page.getByText('الحالة الحالية: لا تظهر').waitFor();
    await page.getByRole('button', { name: 'ضبط الرمز' }).click();
    await page.getByLabel('الرمز الجديد').fill('sirr-2026');
    await page.getByLabel('تأكيد الرمز').fill('sirr-2026');
    await page.getByRole('dialog').getByRole('button', { name: 'حفظ' }).click();
    await page.getByText('مضبوط').waitFor();
    await page.getByRole('tab', { name: 'سجل العمليات' }).click();
    await page.getByRole('cell', { name: 'import_update' }).or(page.getByRole('cell', { name: 'create' })).first().waitFor();
    await page.screenshot({ path: path.join(out, 'settings-log.png') });
  });

  await step('ملف الصنف: سجل الأسعار بتاريخ السريان', async () => {
    await page.goto('http://localhost:3100/#/products');
    await page.getByRole('cell', { name: 'صنف تجريبي 2' }).click();
    await page.getByText('1/1/2026').first().waitFor();
    await page.screenshot({ path: path.join(out, 'product-file.png') });
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
