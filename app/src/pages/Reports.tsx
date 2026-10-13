// P18 «التقارير» (B078–B085، UX-003): بطاقات ثمانية تقارير جاهزة وتقرير مخصص. المسار الموحد:
// اختيار التقرير ← الفترة والنطاق والفلاتر ← تشغيل ← ملخص وجدول ← حفظ الإعدادات/طباعة/PDF/Excel.
// كل تقرير يعرض تعريف مقاييسه ومصدره وآخر رفع وحالة أشهره؛ لا معادلات مستقلة ولا إرسال تلقائي.
// فشل الطلب يُظهر رسالة وإعادة محاولة ولا يُبقي نتيجة قديمة (U04).
import { useEffect, useMemo, useState } from 'react';
import { rpc, sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, fmtMonth, fmtPct, fmtQty, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { useEmployees, useProducts } from '../lib/goals';
import { EmpMulti, monthRange } from '../lib/maps';
import { useRegions } from './InvoiceMap';
import { Field, Modal, Msg, useAction } from '../components/ui';

type Key = 'management' | 'performance' | 'sales' | 'collections' | 'returns' | 'spread' | 'commissions' | 'quality' | 'custom';
const REPORTS: { key: Key; title: string; text: string; group?: boolean; page?: string }[] = [
  { key: 'management', title: 'ملخص الإدارة', text: 'مبيعات ومرتجعات وصافي وتحصيل وذمم وإنجاز ومقارنة بالفترة السابقة.' },
  { key: 'performance', title: 'أداء المندوبين والمشرفين', text: 'الشرائح والمسار والمبيعات والعملاء والكميات والعمولة لشهر نهاية الفترة.' },
  { key: 'sales', title: 'المبيعات التفصيلية', text: 'حسب الموظف أو العميل أو العائلة أو الصنف أو المنطقة أو نوع الفاتورة أو الشهر.', group: true },
  { key: 'collections', title: 'التحصيل والذمم', text: 'الأرصدة والبنود المفتوحة والتأخر والمحصل، والافتتاحي غير المفصل منفصلًا.', page: 'P08' },
  { key: 'returns', title: 'المرتجعات', text: 'القيم والكميات ونسبتها للبيع حسب الصنف أو العميل أو المندوب.', group: true },
  { key: 'spread', title: 'الانتشار والعملاء', text: 'المشترون وتكرار الشراء والأصناف، وغير المشترين ضمن مجموعة معلومة.' },
  { key: 'commissions', title: 'العمولات والمكافآت', text: 'المحسوب والمكافآت والتعديلات والمستحق وحالة نسخة الشهر.', page: 'P14' },
  { key: 'quality', title: 'جودة البيانات والتعديلات', text: 'دفعات ومعلقات ومواقع وإعدادات ناقصة وتعديل ونقل وحذف.' },
];
const DIMS: [string, string][] = [['employee', 'الموظف'], ['customer', 'العميل'], ['family', 'العائلة (الرئيسي)'], ['product', 'الصنف'],
  ['region', 'المنطقة'], ['pay_type', 'نوع الفاتورة'], ['kind', 'نوع الحركة'], ['month', 'الشهر'], ['day', 'اليوم']];
const MEASURES: [string, string][] = [['sales_value', 'المبيعات'], ['direct_sales', 'المبيعات المباشرة'], ['promotions', 'العروض'],
  ['returns_value', 'المرتجعات'], ['net_value', 'صافي المبيعات'], ['sales_qty', 'الكمية المباعة'], ['returns_qty', 'الكمية المرتجعة'],
  ['bonus', 'البونص'], ['invoices', 'عدد الفواتير'], ['returns_count', 'عدد المرتجعات'], ['customers', 'العملاء المشترون'],
  ['products', 'الأصناف المختلفة'], ['avg_invoice', 'متوسط الفاتورة'], ['return_ratio', 'نسبة المرتجع للبيع %'], ['collections', 'التحصيلات']];

interface Col { key: string; label: string; kind: string }
type Row = Record<string, unknown>;
interface Res {
  report: Key; from: string; to: string; generated_at: string; columns: Col[]; rows: Row[]; totals?: Row;
  summary: { label: string; value: unknown; kind: string }[]; definitions: string[]; notice?: string | null;
  extra?: { title: string; columns: Col[]; rows: Row[] };
  months: { month: string; closed: boolean; version: number | null }[]; last_upload: Record<string, string | null>;
}
interface Opts {
  from: string; to: string; employees: number[]; supervisor_id: string; region_id: string; product_id: string; search: string;
  pay_type: string; group_by: string[]; dims: string[]; measures: string[]; sort: string; desc: boolean;
}
interface Saved { id: number; name: string; report: Key; config: Partial<Opts> }

const fresh = (): Opts => {
  const [from, to] = monthRange(todayIso());
  return { from, to, employees: [], supervisor_id: '', region_id: '', product_id: '', search: '', pay_type: '', group_by: [], dims: ['employee'],
    measures: ['sales_value', 'returns_value', 'net_value'], sort: '', desc: true };
};

export function fmtCell(v: unknown, kind: string): string {
  if (v === null || v === undefined || v === '') return '—';
  switch (kind) {
    case 'money': return fmtAmount(v as string);
    case 'qty': return fmtQty(v as string);
    case 'pct': return fmtPct(v as string) + '%';
    case 'date': return fmtDate(String(v));
    case 'datetime': return fmtDateTime(String(v));
    case 'tier': return v === 'NONE' ? 'لا شريحة' : String(v);
    default: return String(v);
  }
}
const cellValue = (v: unknown, kind: string) => (v === null || v === undefined ? null
  : ['money', 'qty', 'pct', 'count', 'number'].includes(kind) ? Number(v) : kind === 'date' ? fmtDate(String(v)) : kind === 'datetime' ? fmtDateTime(String(v)) : String(v));
// عمود «auto» يأخذ وحدته من الصف (ملخص الإدارة: مبالغ وأعداد في عمود واحد)
const kindOf = (c: Col, r: Row) => (c.kind === 'auto' ? String(r.unit ?? 'number') : c.kind);
const KIND_LABEL: Record<string, string> = { invoice: 'فاتورة', return: 'مرتجع', collection: 'تحصيل' };

export function Reports() {
  const { can } = useAuth();
  const [key, setKey] = useState<Key | null>(null);
  const [o, setO] = useState<Opts>(fresh);
  const [saved, setSaved] = useState<Saved[]>([]);
  const [savedVer, setSavedVer] = useState(0);
  const [savedId, setSavedId] = useState<number | null>(null);
  useEffect(() => {
    sb().from('saved_reports').select('id, name, report, config').order('name').then(({ data }) => setSaved((data ?? []) as Saved[]));
  }, [savedVer]);
  const open = (k: Key, cfg?: Partial<Opts>, id?: number) => { setKey(k); setO({ ...fresh(), ...(cfg ?? {}) }); setSavedId(id ?? null); };
  const visible = REPORTS.filter((r) => !r.page || can(r.page, 'view'));

  if (!key) {
    return (
      <>
        <div className="page-head"><h1>التقارير</h1></div>
        <div className="report-cards">
          {visible.map((r) => (
            <button key={r.key} className="report-card" onClick={() => open(r.key)}>
              <b>{r.title}</b><span className="small muted">{r.text}</span>
            </button>
          ))}
          <button className="report-card custom" onClick={() => open('custom')}>
            <b>تقرير مخصص</b><span className="small muted">اختر الأعمدة والمقاييس والتجميع والترتيب والفلاتر، واحفظه باسم.</span>
          </button>
        </div>
        {saved.length > 0 && (
          <div className="panel" style={{ marginTop: 12 }}>
            <h3>تقاريري المحفوظة</h3>
            <table className="inner"><tbody>{saved.map((s) => (
              <tr key={s.id}><td><button className="btn link" onClick={() => open(s.report, s.config, s.id)}>{s.name}</button></td>
                <td className="small muted">{s.report === 'custom' ? 'تقرير مخصص' : REPORTS.find((r) => r.key === s.report)?.title}</td>
                <td><button className="btn link" onClick={() => rpc('delete_saved_report', { p_id: s.id }).then(() => setSavedVer((v) => v + 1))}>حذف</button></td></tr>
            ))}</tbody></table>
          </div>
        )}
      </>
    );
  }
  const def = REPORTS.find((r) => r.key === key);
  return <ReportView k={key} title={def?.title ?? 'تقرير مخصص'} grouped={!!def?.group} o={o} setO={setO} savedId={savedId}
    savedName={saved.find((s) => s.id === savedId)?.name} onBack={() => setKey(null)} onSaved={(id) => { setSavedId(id); setSavedVer((v) => v + 1); }} />;
}

function ReportView({ k, title, grouped, o, setO, savedId, savedName, onBack, onSaved }: {
  k: Key; title: string; grouped: boolean; o: Opts; setO: (o: Opts) => void; savedId: number | null; savedName?: string;
  onBack: () => void; onSaved: (id: number) => void;
}) {
  const { can } = useAuth();
  const emps = useEmployees();
  const products = useProducts();
  const regions = useRegions();
  const [res, setRes] = useState<Res | null>(null);
  const [filters, setFilters] = useState(true);
  const [save, setSave] = useState(false);
  const [sort, setSort] = useState<{ key: string; desc: boolean } | null>(null);
  const load = useAction();
  const set = (n: Partial<Opts>) => setO({ ...o, ...n });
  const payload = () => {
    const p: Record<string, unknown> = { from: o.from, to: o.to, employees: o.employees, supervisor_id: o.supervisor_id, region_id: o.region_id,
      product_id: o.product_id, search: o.search, pay_type: o.pay_type };
    if (grouped) Object.assign(p, { group_by: o.group_by });
    if (k === 'custom') Object.assign(p, { dims: o.dims, measures: o.measures, sort: o.sort, desc: o.desc });
    return p;
  };
  // لا نتيجة قديمة: تُمسح قبل كل تشغيل وعند الفشل
  const go = () => { setRes(null); setSort(null); load.run(async () => setRes(await rpc<Res>('report_run', { p_report: k, p_opts: payload() }))); };
  const toggle = (arr: string[], v: string) => (arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v]);

  const rows = useMemo(() => {
    if (!res) return [];
    if (!sort) return res.rows;
    const kind = res.columns.find((c) => c.key === sort.key)?.kind ?? 'text';
    const num = ['money', 'qty', 'pct', 'count', 'number', 'auto'].includes(kind);
    return [...res.rows].sort((a, b) => {
      const x = a[sort.key]; const y = b[sort.key];
      if (x === null || x === undefined) return 1;
      if (y === null || y === undefined) return -1;
      const c = num ? Number(x) - Number(y) : String(x).localeCompare(String(y), 'ar');
      return sort.desc ? -c : c;
    });
  }, [res, sort]);
  const show = (r: Row, c: Col) => (c.key === 'kind' ? KIND_LABEL[String(r[c.key])] ?? r[c.key] : r[c.key]);

  const doExport = () => {
    if (!res) return;
    const meta = [`${title} — من ${fmtDate(res.from)} إلى ${fmtDate(res.to)} — أُنشئ ${fmtDateTime(res.generated_at)}`];
    writeSheet(`report-${k}-${res.from}-${res.to}.xlsx`, title.slice(0, 31), res.columns.map((c) => c.label),
      [...rows.map((r) => res.columns.map((c) => cellValue(show(r, c), kindOf(c, r)) as string | number | null)),
        ...(res.totals ? [res.columns.map((c, i) => (i === 0 ? 'الإجمالي' : c.key in res.totals! ? cellValue(res.totals![c.key], c.kind) as string | number | null : null))] : []),
        [], [meta[0]], ...res.definitions.map((d) => [d])]);
  };

  return (
    <>
      <div className="page-head no-print">
        <h1><button className="btn link" onClick={onBack} aria-label="كل التقارير">التقارير</button> / {title}{savedName && <span className="small muted"> — {savedName}</span>}</h1>
        <div className="actions">
          <button className="btn" aria-expanded={filters} onClick={() => setFilters(!filters)}>{filters ? 'إخفاء الفلاتر' : 'الفلاتر'}</button>
          <button className="btn" onClick={() => setSave(true)}>حفظ الإعدادات</button>
          {can('P18', 'print') && <button className="btn" disabled={!res} onClick={() => window.print()}>طباعة / PDF</button>}
          {can('P18', 'export') && <button className="btn" disabled={!res} onClick={doExport}>تصدير Excel</button>}
        </div>
      </div>
      {filters && (
        <div className="panel no-print report-filters">
          <div className="filters">
            <label className="check">من <input className="input" type="date" value={o.from} onChange={(e) => set({ from: e.target.value })} aria-label="من تاريخ" /></label>
            <label className="check">إلى <input className="input" type="date" value={o.to} onChange={(e) => set({ to: e.target.value })} aria-label="إلى تاريخ" /></label>
            <button className="btn link" onClick={() => { const [f, t] = monthRange(todayIso()); set({ from: f, to: t }); }}>الشهر الحالي</button>
            <EmpMulti emps={emps} value={o.employees} onChange={(v) => set({ employees: v })} />
            <select className="input" value={o.supervisor_id} onChange={(e) => set({ supervisor_id: e.target.value })} aria-label="المجموعة">
              <option value="">كل المجموعات</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
            <select className="input" value={o.region_id} onChange={(e) => set({ region_id: e.target.value })} aria-label="المنطقة">
              <option value="">كل المناطق</option><option value="none">بلا منطقة</option>{regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
            {!['performance', 'commissions', 'quality', 'management'].includes(k) && <>
              <input className="input" placeholder="عميل: رقم أو اسم" value={o.search} onChange={(e) => set({ search: e.target.value })} aria-label="العميل" />
              {k !== 'collections' && <select className="input" value={o.product_id} onChange={(e) => set({ product_id: e.target.value })} aria-label="الصنف">
                <option value="">كل الأصناف</option>{products.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.name}</option>)}</select>}
              {(k === 'sales' || k === 'custom') && <select className="input" value={o.pay_type} onChange={(e) => set({ pay_type: e.target.value })} aria-label="نوع الفاتورة">
                <option value="">نقدي وذمم</option><option value="فاتورة نقدي">نقدي</option><option value="فاتورة ذمم">ذمم</option></select>}
            </>}
          </div>
          {grouped && (
            <fieldset className="chips"><legend>التجميع حسب</legend>
              {DIMS.filter(([d]) => d !== 'kind').map(([d, l]) => <label key={d} className="check"><input type="checkbox" checked={o.group_by.includes(d)} onChange={() => set({ group_by: toggle(o.group_by, d) })} /> {l}</label>)}
            </fieldset>
          )}
          {k === 'custom' && <>
            <fieldset className="chips"><legend>الأعمدة (التجميع)</legend>
              {DIMS.map(([d, l]) => <label key={d} className="check"><input type="checkbox" checked={o.dims.includes(d)} onChange={() => set({ dims: toggle(o.dims, d) })} /> {l}</label>)}
            </fieldset>
            <fieldset className="chips"><legend>المقاييس</legend>
              {MEASURES.map(([m, l]) => <label key={m} className="check"><input type="checkbox" checked={o.measures.includes(m)} onChange={() => set({ measures: toggle(o.measures, m) })} /> {l}</label>)}
            </fieldset>
            <div className="filters">
              <select className="input" value={o.sort} onChange={(e) => set({ sort: e.target.value })} aria-label="الترتيب حسب">
                <option value="">الترتيب: بالأعمدة</option>{[...DIMS, ...MEASURES].filter(([x]) => o.dims.includes(x) || o.measures.includes(x)).map(([x, l]) => <option key={x} value={x}>{l}</option>)}</select>
              <select className="input" value={o.desc ? 'desc' : 'asc'} onChange={(e) => set({ desc: e.target.value === 'desc' })} aria-label="اتجاه الترتيب">
                <option value="desc">تنازلي</option><option value="asc">تصاعدي</option></select>
            </div>
          </>}
          <div className="actions"><button className="btn primary" disabled={load.busy} onClick={go}>{load.busy ? 'جارٍ التشغيل…' : 'تشغيل التقرير'}</button></div>
        </div>
      )}
      {load.error && <Msg kind="bad">{load.error} <button className="btn link" onClick={go}>إعادة المحاولة</button></Msg>}
      {load.busy && <div className="skeleton" />}
      {res && (
        <div className="print-doc report-doc">
          <div className="report-head">
            <h2>{title}</h2>
            <div className="small muted">من {fmtDate(res.from)} إلى {fmtDate(res.to)} · أُنشئ {fmtDateTime(res.generated_at)}
              {' · '}آخر رفع: فواتير {fmtDateTime(res.last_upload.invoice) || '—'}، مرتجعات {fmtDateTime(res.last_upload.return) || '—'}، تحصيلات {fmtDateTime(res.last_upload.collection) || '—'}
              {' · '}الأشهر: {res.months.map((m) => `${fmtMonth(m.month)} ${m.closed ? `مغلق (النسخة ${m.version})` : 'مفتوح'}`).join('، ')}</div>
          </div>
          {res.notice && <Msg>{res.notice}</Msg>}
          {res.summary.length > 0 && (
            <div className="stats">{res.summary.map((s) => (
              <div key={s.label} className="stat"><div className="l">{s.label}</div><div className="v num">{fmtCell(s.value, s.kind)}</div></div>))}</div>
          )}
          <ResultTable columns={res.columns} rows={rows} totals={res.totals} show={show} sort={sort} onSort={(key) => setSort(sort?.key === key ? { key, desc: !sort.desc } : { key, desc: true })} />
          {res.extra && <><h3 style={{ marginTop: 14 }}>{res.extra.title}</h3><ResultTable columns={res.extra.columns} rows={res.extra.rows} show={(r, c) => r[c.key]} /></>}
          <details className="defs" open><summary>تعريف المقاييس ومصدرها</summary><ul>{res.definitions.map((d) => <li key={d}>{d}</li>)}</ul></details>
        </div>
      )}
      {save && <SaveDlg k={k} config={payload() as Partial<Opts>} id={savedId} name={savedName} onClose={() => setSave(false)} onDone={(id) => { setSave(false); onSaved(id); }} />}
    </>
  );
}

function ResultTable({ columns, rows, totals, show, sort, onSort }: {
  columns: Col[]; rows: Row[]; totals?: Row; show: (r: Row, c: Col) => unknown; sort?: { key: string; desc: boolean } | null; onSort?: (k: string) => void;
}) {
  const [limit, setLimit] = useState(500);
  if (rows.length === 0) return <p className="empty">لا نتائج مطابقة.</p>;
  const numeric = (c: Col) => ['money', 'qty', 'pct', 'count', 'number', 'auto'].includes(c.kind);
  return (
    <div className="tbl"><table>
      <thead><tr>{columns.map((c) => (
        <th key={c.key} className={numeric(c) ? 'num' : ''} aria-sort={sort?.key === c.key ? (sort.desc ? 'descending' : 'ascending') : undefined}>
          {onSort ? <button className="th-sort" onClick={() => onSort(c.key)}>{c.label}{sort?.key === c.key ? (sort.desc ? ' ▼' : ' ▲') : ''}</button> : c.label}</th>))}</tr></thead>
      <tbody>{rows.slice(0, limit).map((r, i) => (
        <tr key={i}>{columns.map((c) => <td key={c.key} className={numeric(c) ? 'num' : c.kind === 'tier' ? '' : 'wrap'}>
          {c.kind === 'tier' && r[c.key] && r[c.key] !== 'NONE' ? <b className={'tier t' + String(r[c.key])}>{String(r[c.key])}</b> : fmtCell(show(r, c), kindOf(c, r))}</td>)}</tr>
      ))}</tbody>
      {totals && <tfoot><tr>{columns.map((c, i) => <td key={c.key} className={numeric(c) ? 'num' : ''}><b>{i === 0 ? 'الإجمالي' : c.key in totals ? fmtCell(totals[c.key], c.kind) : ''}</b></td>)}</tr></tfoot>}
      {rows.length > limit && <caption className="no-print"><button className="btn link" onClick={() => setLimit(rows.length)}>عرض كل الصفوف ({rows.length})</button> — التصدير يشمل الكل دائمًا</caption>}
    </table></div>
  );
}

function SaveDlg({ k, config, id, name, onClose, onDone }: { k: Key; config: Partial<Opts>; id: number | null; name?: string; onClose: () => void; onDone: (id: number) => void }) {
  const [n, setN] = useState(name ?? '');
  const [asNew, setAsNew] = useState(!id);
  const { busy, error, run } = useAction();
  const go = () => run(async () => onDone(await rpc<number>('save_report', { p_id: asNew ? null : id, p_name: n, p_report: k, p_config: config })));
  return (
    <Modal title="حفظ إعدادات التقرير" onClose={onClose} footer={<><button className="btn primary" disabled={busy || !n.trim()} onClick={go}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="اسم التقرير"><input autoFocus value={n} onChange={(e) => setN(e.target.value)} /></Field>
      {id && <label className="check"><input type="checkbox" checked={asNew} onChange={(e) => setAsNew(e.target.checked)} /> حفظ كتقرير جديد</label>}
      <p className="small muted">تُحفظ الفترة والفلاتر والأعمدة والترتيب؛ النتائج تُحسب من جديد عند كل تشغيل. المحفوظ يظهر لك وحدك.</p>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
