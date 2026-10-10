# جولة اعتماد — حسم وحدة الكمية وقبول الكسور — 7/10/2026

| الحقل | القيمة |
|---|---|
| التاريخ | 2026-10-07 |
| الحالة | معتمد من المستخدم |
| الأولوية | تتقدم على النصوص الأقدم عند التعارض |
| المصدر الأصلي | `docs/MASTER-SPEC.md` (رأس الملف) |
| الملفات المتأثرة | [05-products-and-commission-rates.md](../../10-spec/05-products-and-commission-rates.md)، [06-invoices.md](../../10-spec/06-invoices.md)، [07-returns.md](../../10-spec/07-returns.md)، [02-data-units-and-upload.md](../../10-spec/02-data-units-and-upload.md)، [P05-unified-upload.md](../../20-ux/pages/P05-unified-upload.md)، [P13-performance-cards.md](../../20-ux/pages/P13-performance-cards.md) |
| دُمج في | [05-products-and-commission-rates.md](../../10-spec/05-products-and-commission-rates.md) (UNIT-002)، [02-data-units-and-upload.md](../../10-spec/02-data-units-and-upload.md)، [06-invoices.md](../../10-spec/06-invoices.md)، [07-returns.md](../../10-spec/07-returns.md)، [11-goals-commissions-permissions.md](../../10-spec/11-goals-commissions-permissions.md) (GOAL-008) — 2026-10-10 |

> النص أدناه منقول حرفيًا من المرجع الأصلي دون تعديل في الصياغة.

## حسم وحدة الكمية وقبول الكسور — 7/10/2026
أكد المستخدم أن Quantity = 0.5 تعني نصف باكيت، وأن كميات جميع الأصناف موحّدة بوحدة البيع (الباكيت). تبقى Quantity كمية البيع دون Bonus، والبونص مستقل وبالوحدة نفسها. الكسور صحيحة، وتُحفظ كما وردت وتُقبل عند الاستيراد والتعديل للفواتير والمرتجعات والبونص، دون تحويل إلى كراتين أو تقريب إلى عدد صحيح أو تعليق السند لمجرد وجود كسر. هذا يحسم ملاحظة الصفوف الكسرية في الملف ويتقدم على أي شرط سابق يفرض الكميات الصحيحة فقط. تفاصيل السندات والكميات الفعلية والتصدير تظهر الكسر عند وجوده، مثل 0.5 و5.5؛ عرض الأرقام الصحيحة المختصر في بطاقات الأداء لا يغيّر قيم المصدر والحسابات.
