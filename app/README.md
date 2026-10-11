# تطبيق ماستر (الواجهة)

React + TypeScript + Vite، عربي RTL، يتصل بـSupabase بالمفتاح العام فقط.

## التشغيل محليًا

```bash
cd app
npm install
npm run dev        # http://localhost:3000
npm test           # اختبارات التنسيق (التواريخ والأرقام)
npm run build      # فحص الأنواع ثم البناء في dist/
```

الاتصال بقاعدة البيانات: إما متغيرا البيئة `VITE_SUPABASE_URL` و`VITE_SUPABASE_ANON_KEY` (انظر `.env.example`)،
أو شاشة الاتصال التي تظهر عند أول فتح ويُحفظ ما يدخل فيها في المتصفح.

## الرفع إلى Google AI Studio (ملف ZIP)

1. ولّد الملف: `bash app/make_zip.sh` ← ينتج `dist-zip/master-app.zip` (كود المصدر دون `node_modules`).
2. في AI Studio ارفع الملف المضغوط بالطريقة التي جرّبتها سابقًا.
3. اربط Supabase: أدخل عنوان المشروع والمفتاح العام في شاشة الاتصال عند أول فتح، أو كمتغيري بيئة إن أتاحها AI Studio.
4. طبّق قاعدة البيانات أولًا وفق `supabase/README.md`.

## البنية

- `src/lib/` الاتصال والدخول والتنسيق وExcel.
- `src/components/` الجدول الموحد ومعالج الاستيراد والنوافذ وطلب الرمز السري.
- `src/pages/` صفحات النظام بحسب سجل الصفحات P01–P21.
