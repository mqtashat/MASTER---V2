// أنواع الحركات وقوالبها: الفواتير والمرتجعات والتحصيلات (INV-009/010، RET-006/007، COL-001).
// القالب يُقرأ بأسماء أعمدته مباشرة دون Mapping يدوي، والنوع يحدده زر الرفع لا الأعمدة (DATA-006، DATA-009).
import { dateCell } from './excel';

export type Kind = 'invoice' | 'return' | 'collection';

export interface KindDef { kind: Kind; one: string; plural: string; button: string }

export const KINDS: KindDef[] = [
  { kind: 'invoice', one: 'فاتورة', plural: 'الفواتير', button: 'فواتير' },
  { kind: 'return', one: 'مرتجع', plural: 'المرتجعات', button: 'مرتجعات' },
  { kind: 'collection', one: 'تحصيل', plural: 'التحصيلات', button: 'تحصيلات' },
];

export const kindDef = (k: string): KindDef => KINDS.find((x) => x.kind === k) ?? KINDS[0];
export const isKind = (k: string | null): k is Kind => !!k && KINDS.some((x) => x.kind === k);

/** الأعمدة المطلوبة لقراءة السند (مطابقة لـ app.required_columns) */
export const REQUIRED: Record<Kind, string[]> = {
  invoice: ['Bonus', 'NetPromotions', 'NetSales', 'CustomerNumber', 'ItemNumber', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber'],
  return: ['Bonus', 'NetPromotions', 'NetSales', 'CustomerNumber', 'ItemNumber', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber'],
  collection: ['القيمة', 'الدفع', 'التاريخ', 'الرقم', 'رقم العميل', 'رقم المندوب'],
};

export const PAY_TYPES = ['فاتورة نقدي', 'فاتورة ذمم'];
export const PAY_METHODS = ['نقدي', 'شيك مؤجل', 'شيك مستحق الدفع'];

/** صف Excel ← حقول السند التي تفهمها قاعدة البيانات */
export function mapUploadRow(kind: Kind, c: Record<string, string>, row: number): Record<string, string | number> {
  if (kind === 'collection') {
    return {
      row, doc_number: c['الرقم'] ?? '', customer_number: c['رقم العميل'] ?? '', doc_date: dateCell(c['التاريخ'] ?? ''),
      employee_number: c['رقم المندوب'] ?? '', employee_name: c['المندوب'] ?? '', customer_name: c['العميل'] ?? '',
      amount: c['القيمة'] ?? '', pay_method: c['الدفع'] ?? '', cheque_no: c['رقم الشيك'] ?? '',
    };
  }
  return {
    row, doc_number: c.DocumentNumber ?? '', customer_number: c.CustomerNumber ?? '', doc_date: dateCell(c.DocumentDate ?? ''),
    employee_number: c.EmployeeNumber ?? '', employee_name: c.EmployeeName ?? '', customer_name: c.Customername ?? '',
    pay_type: c.DocumentTypeID ?? '', item_number: c.ItemNumber ?? '', item_name: c.ItemName ?? '',
    net_sales: c.NetSales ?? '', net_promotions: c.NetPromotions ?? '', quantity: c.Quantity ?? '', bonus: c.Bonus ?? '',
    lat: c.Latitude ?? '', lng: c.Longitude ?? '',
  };
}

/** بند السند بصيغته الموحدة (كما تحفظه قاعدة البيانات) */
export interface DocLine {
  row?: number | null;
  item_number?: string | null; item_name?: string | null;
  net_sales?: string | null; net_promotions?: string | null; quantity?: string | null; bonus?: string | null;
  lat?: string | null; lng?: string | null;
  amount?: string | null; pay_method?: string | null; cheque_no?: string | null;
  employee_number?: string | null; pay_type?: string | null;
}

export interface DocData {
  doc_number: string | null; customer_number: string | null; doc_date: string | null;
  employee_number?: string | null; pay_type?: string | null;
  customer_name?: string | null; employee_name?: string | null;
  lines: DocLine[];
}

/** سند الدفعة كما ورد (الموظف والنوع في الصفوف) ← صيغة التحرير (الموظف والنوع في الترويسة) */
export function toEditable(kind: Kind, d: DocData): DocData {
  const first = d.lines[0] ?? {};
  const out: DocData = {
    doc_number: d.doc_number ?? '', customer_number: d.customer_number ?? '', doc_date: d.doc_date ?? '',
    employee_number: d.employee_number ?? first.employee_number ?? '',
    customer_name: d.customer_name, employee_name: d.employee_name,
    lines: d.lines.map((l) => { const c = { ...l }; delete c.employee_number; delete c.pay_type; return c; }),
  };
  if (kind === 'invoice') out.pay_type = d.pay_type ?? first.pay_type ?? '';
  return out;
}

export const SOURCE_LABELS: Record<string, string> = {
  upload: 'رفع', restore: 'استعادة بعد حذف', manual: 'تعديل يدوي', transfer: 'نقل موظف', delete: 'حذف',
  batch_delete: 'حذف دفعة', batch_revert: 'تراجع بحذف دفعة',
};

export const CLASS_LABELS: Record<string, [string, 'ok' | 'warn' | 'bad' | 'accent' | undefined]> = {
  new: ['جديد', 'ok'],
  unchanged: ['مطابق لا تغيير', undefined],
  changed: ['متغير يحتاج اعتماد استبدال', 'warn'],
  manual_conflict: ['يتعارض مع تعديل يدوي', 'warn'],
  possible_match: ['مطابق محتمل بعد تعديل يدوي', 'accent'],
  deleted_before: ['سبق حذفه', 'bad'],
  pending: ['معلق', 'bad'],
};

export const OUTCOME_LABELS: Record<string, [string, 'ok' | 'warn' | 'bad' | 'accent' | undefined]> = {
  added: ['أضيف', 'ok'], updated: ['حُدّث', 'ok'], restored: ['استعيد', 'ok'], no_change: ['بلا تغيير', undefined],
  kept_existing: ['أُبقي المحفوظ', undefined], excluded: ['مستبعد من الدفعة', undefined],
  removed: ['أزيل بحذف الدفعة', 'bad'], reverted: ['أعيد إلى السابق', 'warn'],
};

export const BATCH_STATUS: Record<string, [string, 'ok' | 'warn' | 'bad' | undefined]> = {
  open: ['غير مكتملة', 'warn'], closed: ['مكتملة', 'ok'], deleted: ['محذوفة', 'bad'],
};
