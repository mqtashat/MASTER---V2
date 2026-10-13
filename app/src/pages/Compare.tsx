// P17a «مقارنة الفترات» (MAP-006، MAP-011، B069): يومان أو أسبوعان (السبت–الجمعة) أو شهران أو فترتان مخصصتان،
// بنطاق مندوب أو مجموعة أو منطقة. قيم مطلقة وتغير ونسبة، ومتوسط يوم عمل اختياري؛ صفر الأساس يعرض «جديد»
// أو «لا توجد قاعدة مقارنة». «غير المباعين» عملاء النطاق الذين لم يشتروا خلال الفترة.
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtPct, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { useEmployees } from '../lib/goals';
import { EmpMulti, monthRange, shiftDays, weekOf } from '../lib/maps';
import { useRegions } from './InvoiceMap';
import { Msg, useAction } from '../components/ui';

type N = string | number | null;
interface Period { from: string; to: string; days: number; work_days: number; [k: string]: N | unknown }
interface Res { a: Period & { by_employee: Emp[] }; b: Period & { by_employee: Emp[] }; equal_length: boolean }
interface Emp { employee_id: number; name: string; sales: N; returns: N; net: N; invoices: number; buyers: number }

const METRICS: { key: string; label: string; money?: boolean; perDay?: boolean }[] = [
  { key: 'sales', label: 'المبيعات', money: true, perDay: true }, { key: 'returns', label: 'المرتجعات', money: true, perDay: true },
  { key: 'net', label: 'صافي المبيعات', money: true, perDay: true }, { key: 'invoices', label: 'عدد الفواتير', perDay: true },
  { key: 'customers', label: 'العملاء الفريدون' }, { key: 'avg_invoice', label: 'متوسط الفاتورة', money: true },
  { key: 'new_customers', label: 'العملاء الجدد' }, { key: 'buyers', label: 'العملاء النشطون (المشترون)' },
  { key: 'unsold', label: 'غير المباعين' }, { key: 'in_region', label: 'فواتير داخل المنطقة' }, { key: 'out_region', label: 'فواتير خارج المنطقة' },
];

type Mode = 'day' | 'week' | 'month' | 'custom';
function periods(mode: Mode, anchor: string): [[string, string], [string, string]] {
  if (mode === 'day') return [[shiftDays(anchor, -1), shiftDays(anchor, -1)], [anchor, anchor]];
  if (mode === 'week') { const b = weekOf(anchor); return [[shiftDays(b[0], -7), shiftDays(b[1], -7)], b]; }
  const b = monthRange(anchor);
  return [monthRange(shiftDays(b[0], -1)), b];
}

export function change(a: N, b: N): { diff: number; pct: string } {
  const x = Number(a ?? 0); const y = Number(b ?? 0);
  if (x === 0) return { diff: y - x, pct: y === 0 ? 'لا توجد قاعدة مقارنة' : 'جديد' };
  return { diff: y - x, pct: (y - x >= 0 ? '+' : '') + fmtPct(((y - x) / Math.abs(x)) * 100) + '%' };
}

export function Compare() {
  const { can } = useAuth();
  const emps = useEmployees();
  const regions = useRegions();
  const [mode, setMode] = useState<Mode>('month');
  const [anchor, setAnchor] = useState(todayIso());
  const [custom, setCustom] = useState({ af: '', at: '', bf: '', bt: '' });
  const [o, setO] = useState({ employees: [] as number[], supervisor_id: '', region_id: '' });
  const [perDay, setPerDay] = useState(false);
  const [d, setD] = useState<Res | null>(null);
  const load = useAction();
  const [[af, at], [bf, bt]] = mode === 'custom' ? [[custom.af, custom.at], [custom.bf, custom.bt]] : periods(mode, anchor);
  useEffect(() => {
    if (!af || !at || !bf || !bt) return;
    let live = true;
    load.run(async () => { const r = await rpc<Res>('period_compare', { p_a_from: af, p_a_to: at, p_b_from: bf, p_b_to: bt, p_opts: o }); if (live) setD(r); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [af, at, bf, bt, JSON.stringify(o)]);

  const val = (p: Period, m: typeof METRICS[number]): N => {
    const v = p[m.key] as N;
    if (!perDay || !m.perDay) return v;
    return p.work_days ? Number(v ?? 0) / p.work_days : null;
  };
  const fmt = (v: N, m: typeof METRICS[number]) => (v === null || v === undefined ? '—' : m.money || (perDay && m.perDay) ? fmtAmount(v) : String(v));
  const doExport = () => d && writeSheet(`مقارنة ${af} و${bf}.xlsx`, 'المقارنة', ['المؤشر', `${af} – ${at}`, `${bf} – ${bt}`, 'الفرق', 'التغير'],
    METRICS.map((m) => { const c = change(val(d.a, m), val(d.b, m)); return [m.label, Number(val(d.a, m) ?? 0), Number(val(d.b, m) ?? 0), c.diff, c.pct]; }));

  return (
    <>
      <div className="page-head">
        <h1>مقارنة الفترات</h1>
        <div className="actions">{can('P17a', 'export') && <button className="btn" disabled={!d} onClick={doExport}>تصدير Excel</button>}</div>
      </div>
      <div className="filters">
        <div className="tabs" role="tablist">{([['day', 'يومان'], ['week', 'أسبوعان'], ['month', 'شهران'], ['custom', 'مخصص']] as [Mode, string][]).map(([k, t]) => (
          <button key={k} role="tab" aria-selected={mode === k} onClick={() => setMode(k)}>{t}</button>))}</div>
        {mode !== 'custom' ? (
          <label className="check">الفترة الحالية تشمل <input className="input" type="date" value={anchor} onChange={(e) => setAnchor(e.target.value)} aria-label="تاريخ المرجع" /></label>
        ) : <>
          <label className="check">الأولى <input className="input" type="date" value={custom.af} onChange={(e) => setCustom({ ...custom, af: e.target.value })} aria-label="بداية الأولى" />
            <input className="input" type="date" value={custom.at} onChange={(e) => setCustom({ ...custom, at: e.target.value })} aria-label="نهاية الأولى" /></label>
          <label className="check">الثانية <input className="input" type="date" value={custom.bf} onChange={(e) => setCustom({ ...custom, bf: e.target.value })} aria-label="بداية الثانية" />
            <input className="input" type="date" value={custom.bt} onChange={(e) => setCustom({ ...custom, bt: e.target.value })} aria-label="نهاية الثانية" /></label>
        </>}
        <EmpMulti emps={emps} value={o.employees} onChange={(v) => setO({ ...o, employees: v })} />
        <select className="input" value={o.supervisor_id} onChange={(e) => setO({ ...o, supervisor_id: e.target.value })} aria-label="المجموعة">
          <option value="">كل المجموعات</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
        <select className="input" value={o.region_id} onChange={(e) => setO({ ...o, region_id: e.target.value })} aria-label="المنطقة">
          <option value="">كل المناطق</option>{regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
        <label className="check"><input type="checkbox" checked={perDay} onChange={(e) => setPerDay(e.target.checked)} /> متوسط يوم العمل</label>
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && !d.equal_length && <Msg>الفترتان مختلفتا الطول ({d.a.days} و{d.b.days} يومًا)؛ استخدم «متوسط يوم العمل» لمقارنة عادلة.</Msg>}
      {d && (
        <div className="tbl"><table>
          <thead><tr><th>المؤشر</th>
            <th className="num">{fmtDate(d.a.from)} – {fmtDate(d.a.to)}<div className="small">{d.a.days} يومًا · {d.a.work_days} يوم عمل</div></th>
            <th className="num">{fmtDate(d.b.from)} – {fmtDate(d.b.to)}<div className="small">{d.b.days} يومًا · {d.b.work_days} يوم عمل</div></th>
            <th className="num">الفرق</th><th className="num">التغير</th><th style={{ minWidth: 140 }}></th></tr></thead>
          <tbody>{METRICS.map((m) => {
            const a = val(d.a, m); const b = val(d.b, m); const c = change(a, b);
            const max = Math.max(Math.abs(Number(a ?? 0)), Math.abs(Number(b ?? 0))) || 1;
            return (
              <tr key={m.key}><td>{m.label}{perDay && m.perDay && <span className="small muted"> / يوم عمل</span>}</td>
                <td className="num">{fmt(a, m)}</td><td className="num">{fmt(b, m)}</td>
                <td className={'num ' + (c.diff > 0 ? 'ok-text' : c.diff < 0 ? 'bad-text' : '')}>{m.money || (perDay && m.perDay) ? fmtAmount(c.diff) : c.diff}</td>
                <td className="num">{c.pct}</td>
                <td><div className="cmp-bars"><span style={{ width: (Math.abs(Number(a ?? 0)) / max) * 100 + '%' }} className="a" /><span style={{ width: (Math.abs(Number(b ?? 0)) / max) * 100 + '%' }} className="b" /></div></td></tr>
            );
          })}</tbody></table></div>
      )}
      {d && (
        <div className="panel" style={{ marginTop: 12 }}>
          <h3>حسب المندوب</h3>
          <div style={{ overflowX: 'auto' }}><table className="inner"><thead><tr><th>المندوب</th><th className="num">صافي الأولى</th><th className="num">صافي الثانية</th><th className="num">التغير</th><th className="num">فواتير الأولى</th><th className="num">فواتير الثانية</th></tr></thead>
            <tbody>{[...new Set([...d.a.by_employee, ...d.b.by_employee].map((x) => x.employee_id))].map((id) => {
              const x = d.a.by_employee.find((e) => e.employee_id === id); const y = d.b.by_employee.find((e) => e.employee_id === id);
              return <tr key={id}><td>{(x ?? y)!.name}</td><td className="num">{fmtAmount(x?.net ?? 0)}</td><td className="num">{fmtAmount(y?.net ?? 0)}</td>
                <td className="num">{change(x?.net ?? 0, y?.net ?? 0).pct}</td><td className="num">{x?.invoices ?? 0}</td><td className="num">{y?.invoices ?? 0}</td></tr>;
            })}</tbody></table></div>
        </div>
      )}
    </>
  );
}
