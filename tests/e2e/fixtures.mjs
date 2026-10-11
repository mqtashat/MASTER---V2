// ملفات اختبار اصطناعية بأعمدة القوالب المعتمدة (لا بيانات حقيقية — القاعدة 6)
import * as XLSX from 'xlsx';
import fs from 'node:fs';
import path from 'node:path';

export function writeXlsx(file, sheet, headers, rows) {
  const ws = XLSX.utils.aoa_to_sheet([headers, ...rows]);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, sheet);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  XLSX.writeFile(wb, file);
  return file;
}

export function makeFixtures(dir) {
  const customers = writeXlsx(path.join(dir, 'customers.xlsx'), 'العملاء والافرع',
    ['MasterCustomerName', 'MasterCustomerNumber', 'CustomerName', 'CustomerNumber', 'CompanyID', 'فترة السماح'],
    [
      ['سوبرماركت تجريبي', '9001', 'سوبرماركت تجريبي', '9001', '2', ''],
      ['سوبرماركت تجريبي', '9001', 'سوبرماركت تجريبي - فرع', '9002', '2', '15'],
      ['محل اختبار', '9003', 'محل اختبار', '9003', '2', '0'],
      ['بقالة نموذج', '', 'بقالة نموذج', '0094', '2', ''],
    ]);
  const employees = writeXlsx(path.join(dir, 'employees.xlsx'), 'الموظفين',
    ['الرقم الوظيفي', 'اسم الموظف', 'الدور الوظيفي', 'الراتب الأساسي', 'تاريخ الالتحاق', 'الحالة', 'تاريخ الحالة الفعلي', 'معرف المشرف'],
    [
      ['801', 'مشرف تجريبي', 'مشرف', '', '01/01/2025', 'نشط', '', ''],
      ['802', 'مندوب تجريبي أ', 'مندوب مبيعات', '', '01/06/2025', 'نشط', '', '801'],
      ['803', 'مندوب تجريبي ب', 'مندوب مبيعات', '', '01/06/2025', 'مستقيل', '31/12/2025', '801'],
    ]);
  const T = ['A', 'B', 'C', 'X'];
  const products = writeXlsx(path.join(dir, 'products.xlsx'), 'المنتجات',
    ['كود الصنف', 'اسم الصنف (عربي)', 'سعر البيع', 'سعر التكلفة', 'عدد الحبات في الكرتونة', ...T.map((t) => 'عمولة المندوب ' + t), ...T.map((t) => 'عمولة المشرف ' + t)],
    [
      ['T01', 'صنف تجريبي 1', 2, 1.5, 24, 2.5, 2, 1.5, 1, 3, 2.5, 2, 1],
      ['T02', 'صنف تجريبي 2', 9.499, 7, 1, 2.5, 2, 1.5, 1, 3, 2.5, 2, 1],
    ]);
  return { customers, employees, products };
}

// ملفات حركات اصطناعية للوحدة 2 بأعمدة القوالب المعتمدة (INV-009، RET-006، COL-001)؛ القيم نصوص كما في ملفات المصدر
const INV_HEAD = ['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
  'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID'];
const COL_HEAD = ['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب'];

export function makeModule2Fixtures(dir) {
  const inv = (doc, cust, emp, type, item, ns, np, qty, bonus) =>
    ['36.0244851', '32.0109996', type, bonus, np, qty, ns, 'عميل', cust, 'صنف', item, 'مندوب', emp, '01/10/2026', doc, '2'];
  const invoices = writeXlsx(path.join(dir, 'invoices.xlsx'), 'عروض الفواتير', INV_HEAD, [
    inv('5001', '9001', '802', 'فاتورة ذمم', 'T01', '20.000', '0.000', '10', '0'),
    inv('5001', '9001', '802', 'فاتورة ذمم', 'T02', '0.000', '18.989', '2', '1'),
    inv('5002', '9003', '999', 'فاتورة نقدي', 'T01', '4.000', '0.000', '2', '0'),
    inv('5003', '9002', '802', 'فاتورة آجل', 'T01', '6.000', '0.000', '3', '0'),
    inv('5004', '0094', '802', 'فاتورة نقدي', 'T01', '11.000', '0.000', '5.5', '0.5'),
  ]);
  const col = (doc, amount, pay, cheque) => [amount, cheque, pay, '02/10/2026', doc, 'سوبرماركت تجريبي', '9001', 'مندوب', '802'];
  const collections = writeXlsx(path.join(dir, 'collections.xlsx'), 'التحصيلات', COL_HEAD, [
    col('7001', '22.79800000000000000000', 'نقدي', ''),
    col('7001', '22.79800000000000000000', 'نقدي', ''),
    col('7001', '22.79800000000000000000', 'نقدي', ''),
    col('7001', '0', 'نقدي', ''),
    col('7001', '31.606', 'شيك مؤجل', '123456'),
    col('7002', '10', '----', ''),
  ]);
  return { invoices, collections };
}
