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
