// أنواع وحدة الحسابات وأدواتها المشتركة: كشف الحساب والذمم وبيانات الشركة للطباعة.
import { useEffect, useState } from 'react';
import { sb } from './supabase';

export interface StmtLine {
  key: string; date: string; kind: string; kind_label: string; number: string | null;
  account_number: string | null; account_name: string | null; description: string | null;
  debit: string | null; credit: string | null; balance: string | null; custom_balance: string | null;
  affecting: boolean; deleted: boolean; hidden: boolean; hideable: boolean; doc_id: number | null; note_id: number | null;
}
export interface Totals { prev: string; debit: string; credit: string; final: string; hidden_count?: number }
export interface Statement {
  customer: { id: number; customer_number: string; name: string; role: string;
    master: { id: number; customer_number: string; name: string } | null;
    head: { id: number; customer_number: string; name: string } };
  family: boolean; from: string; to: string; custom: boolean; filtered: boolean;
  warnings: { code: string; message: string }[];
  official: Totals; custom_totals: Totals | null; results: { count: number; debit: string; credit: string };
  fingerprint: string; lines: StmtLine[];
}
export interface StmtOptions { kinds: string[]; affect: 'all' | 'affecting' | 'non'; search: string; show_deleted: boolean; custom: boolean; hidden: string[] }

export const STMT_KINDS: [string, string][] = [
  ['invoice', 'الفواتير'], ['collection', 'التحصيلات'], ['return', 'المرتجعات'],
  ['debit_note', 'الإشعارات المدينة'], ['credit_note', 'الإشعارات الدائنة'], ['opening', 'الافتتاحي'],
];

/** وصف نوع الكشف في المعاينة والمخرجات (B045) */
export function stmtTypeLabel(s: Pick<Statement, 'custom' | 'filtered'>): string {
  return [s.custom ? 'كشف مخصص' : 'كشف رسمي', s.filtered ? 'مفلتر' : null].filter(Boolean).join(' — ');
}

/** وجهة فتح السند في محرره المسموح بدل تعديل الرصيد من الكشف */
export function docLink(l: Pick<StmtLine, 'kind' | 'doc_id' | 'note_id'>): string | null {
  if (l.doc_id && ['invoice', 'return', 'collection'].includes(l.kind)) return `/transactions?kind=${l.kind}&open=${l.doc_id}`;
  if (l.note_id) return `/notes?open=${l.note_id}`;
  return null;
}

export interface Company { name: string; tax_no: string; phone: string; logo: string; header: string }

export function useCompany(): Company {
  const [c, setC] = useState<Company>({ name: '', tax_no: '', phone: '', logo: '', header: '' });
  useEffect(() => {
    sb().from('settings').select('key, value').in('key', ['company_name', 'company_tax_no', 'company_phone', 'company_logo', 'document_header'])
      .then(({ data }) => {
        const m = Object.fromEntries(((data ?? []) as { key: string; value: unknown }[]).map((x) => [x.key, typeof x.value === 'string' ? x.value : '']));
        setC({ name: m.company_name ?? '', tax_no: m.company_tax_no ?? '', phone: m.company_phone ?? '', logo: m.company_logo ?? '', header: m.document_header ?? '' });
      });
  }, []);
  return c;
}

export function yearStart(): string {
  const y = new Date().getFullYear();
  return `${y}-01-01`;
}
