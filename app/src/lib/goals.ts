// أنواع وحدة الأهداف والعمولات وأدواتها المشتركة: المقاييس، الشرائح وألوانها، الشهر، والموظفون.
import { useEffect, useState } from 'react';
import { sb } from './supabase';
import { fmtAmount, fmtInt, fmtPct, Num, todayIso } from './format';

export type Kind = 'amount' | 'count' | 'relative';
export interface MetricDef { code: string; label: string; kind: Kind; hint: string }

// المقاييس المعتمدة (GOAL-003، B005–B012، GOAL-012..017)
export const METRICS: MetricDef[] = [
  { code: 'net_sales', label: 'صافي المبيعات', kind: 'amount', hint: 'المباشر + العروض ناقص المرتجعات، نقدي وذمم افتراضيًا (B006، B007)' },
  { code: 'gross_sales', label: 'إجمالي المبيعات', kind: 'amount', hint: 'المباشر + العروض قبل المرتجعات' },
  { code: 'collection', label: 'التحصيل', kind: 'amount', hint: 'بأساس مندوب التحصيل أو مندوب الفاتورة المسددة (GOAL-017)' },
  { code: 'quantity', label: 'صافي الكمية', kind: 'amount', hint: 'الكمية الفعلية بالباكيت ناقص المرتجعة؛ البونص منفصل (B011)' },
  { code: 'customers', label: 'العملاء', kind: 'count', hint: 'أرقام عملاء مميزة ببيع موجب؛ الفرع عميل مستقل (B008)' },
  { code: 'invoices', label: 'فواتير البيع', kind: 'count', hint: 'سندات مميزة؛ فاتورة البونص فقط لا تدخل (B010)' },
  { code: 'variety', label: 'تنوع الأصناف', kind: 'count', hint: 'أصناف مختلفة ببيع موجب؛ البونص وحده لا يحتسب (GOAL-014)' },
  { code: 'new_customers', label: 'العملاء الجدد', kind: 'count', hint: 'أول شراء موجب للعميل في النظام كله داخل الفترة (GOAL-012)' },
  { code: 'reactivated', label: 'إعادة التنشيط', kind: 'count', hint: 'لم يشترِ خلال آخر N يومًا قبل الفترة ثم اشترى فيها (GOAL-013)' },
  { code: 'collection_ratio', label: 'التحصيل النسبي %', kind: 'relative', hint: 'تحصيل الشهر ÷ مبيعات الذمم × 100؛ نسبي لا يخفض بالأيام ولا مسار له (GOAL-015)' },
];
export const metricDef = (code: string) => METRICS.find((m) => m.code === code) ?? { code, label: code, kind: 'amount' as Kind, hint: '' };

export interface Filters { products?: number[]; sale_type?: 'all' | 'direct' | 'promo'; pay_type?: 'all' | 'cash' | 'credit'; days?: number | string; basis?: 'collector' | 'invoice_rep' }

export interface PlanTier { tier: string; sort: number; logic: 'AND' | 'OR' }
export interface PlanComponent { tier: string | null; sort: number; metric: string; target: string | number | null; affected: boolean; filters: Filters; label: string | null }
export interface Plan {
  id: number; month: string; employee_id: number; employee_name: string; emp_number: string; role: 'rep' | 'supervisor';
  sup_mode: 'team_sum' | 'independent'; partial_mode: 'proportional' | 'fixed'; include_personal: boolean; note: string | null;
  template_id: number | null; tiers: PlanTier[]; components: PlanComponent[];
}
export interface Days { D: number; E: number; P: number; X: number; total: number; elapsed: number }
export interface EvalComp {
  id: number; tier: string | null; sort: number; metric: string; label: string; kind: Kind; filters: Filters; affected: boolean;
  original: string | null; final: string | null; actual: string | null; status: 'ok' | 'zero' | 'unused'; met: boolean;
  pct: string | null; remaining: string | null; has_path: boolean; required: string | null; path_pct: string | null; path_diff: string | null;
  path_ok: boolean; daily: string | null; expected_today: string | null;
  team: { sum: string; count: number; parts: { employee_id: number; name: string; final: string; days: number; under: number; share: string }[] } | null;
}
export interface Eval {
  plan_id: number; month: string; employee_id: number; role: string; cutoff: string; days: Days;
  path_state: 'running' | 'not_started' | 'no_days'; components: EvalComp[];
  tiers: { tier: string; sort: number; logic: string; components: number; met: boolean; path_ok: boolean }[];
  achieved: string; path_tier: string; main: EvalComp | null;
}

export const ROLE_LABEL: Record<string, string> = { rep: 'مندوب', supervisor: 'مشرف' };

/** أول يوم في الشهر الحالي بتوقيت الأردن */
export function thisMonth(): string { return todayIso().slice(0, 8) + '01'; }
export function monthInput(m: string): string { return m.slice(0, 7); }
export function fromMonthInput(v: string): string { return v ? v + '-01' : thisMonth(); }
export function addMonths(m: string, n: number): string {
  const [y, mo] = m.split('-').map(Number);
  const d = new Date(Date.UTC(y, mo - 1 + n, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`;
}

/** قيمة مقياس بحسب نوعه: المبالغ ثلاث منازل، الأعداد صحيحة، النسب حتى منزلتين */
export function fmtMetric(v: Num, kind: Kind): string {
  if (v === null || v === undefined || v === '') return '—';
  return kind === 'amount' ? fmtAmount(v) : kind === 'count' ? fmtInt(v) : fmtPct(v) + '%';
}

/** رقم متابعة في البطاقة: عدد صحيح بلا فواصل (CARD-004، B060) */
export const fmtFollow = (v: Num) => (v === null || v === undefined ? '—' : fmtInt(v));

export function tierClass(t: string | null | undefined): string {
  if (!t || t === 'NONE') return 'tier none';
  return 'tier t' + (['A', 'B', 'C', 'X'].includes(t) ? t : 'O');
}

export interface Emp { id: number; emp_number: string; name: string; status: string }
export function useEmployees(): Emp[] {
  const [rows, setRows] = useState<Emp[]>([]);
  useEffect(() => {
    sb().from('employees').select('id, emp_number, name, status').order('name').limit(5000).then(({ data }) => setRows((data ?? []) as Emp[]));
  }, []);
  return rows;
}

export interface Product { id: number; code: string; name: string }
export function useProducts(): Product[] {
  const [rows, setRows] = useState<Product[]>([]);
  useEffect(() => {
    sb().from('products').select('id, code, name').order('code').limit(10000).then(({ data }) => setRows((data ?? []) as Product[]));
  }, []);
  return rows;
}

/** وصف نطاق المكوّن المقروء (B005: تعريف ظاهر موحد) */
export function filtersText(f: Filters, products: Product[]): string {
  const parts: string[] = [];
  if (f.sale_type === 'direct') parts.push('المباشر فقط');
  if (f.sale_type === 'promo') parts.push('العروض فقط');
  if (f.pay_type === 'cash') parts.push('النقدي فقط');
  if (f.pay_type === 'credit') parts.push('الذمم فقط');
  if (f.products?.length) parts.push('الأصناف: ' + f.products.map((id) => products.find((p) => p.id === id)?.code ?? id).join('، '));
  if (f.days) parts.push(`N = ${f.days} يومًا`);
  if (f.basis === 'invoice_rep') parts.push('بأساس مندوب الفاتورة');
  if (f.basis === 'collector') parts.push('بأساس مندوب التحصيل');
  return parts.join(' · ');
}

export const WARN_LABEL: Record<string, string> = {
  no_rule: 'إعداد ناقص: لا قاعدة للشهر', missing_rate: 'إعداد ناقص: نسبة صنف فارغة', personal_pending: 'الشخصية معلّقة',
  no_plan: 'لا خطة أهداف', zero_target: 'هدف صفري', tier_not_in_rule: 'شريحة خارج القاعدة',
};

export const SOURCE_LABEL: Record<string, string> = { sale: 'مبيعات', return: 'مرتجعات', paid: 'مسدد من ذمم', opening: 'تحصيل افتتاحي' };
export const SRC_LABEL: Record<string, string> = {
  rule: 'نسبة الشهر', product: 'من الأصناف', missing: 'نسبة فارغة', no_tier: 'لا شريحة', personal: 'نسبة الإدارة الشخصية', pending: 'معلّقة',
};
