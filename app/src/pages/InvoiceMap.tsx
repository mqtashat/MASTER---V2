// P15 «خريطة الفواتير والمسار» (MAP-002، MAP-003، MAP-010، MAP-012، MAP-014، B063):
// نقطة لكل فاتورة بموقع إصدارها ولون مندوبها، الفواتير فقط، وفلاتر قابلة للطي. الإصدار الأول بلا وقت إصدار:
// نقاط فقط دون ترتيب زيارات. الحركات بلا موقع تبقى في الإجماليات وفي قائمة قابلة للفتح والتصحيح.
import { useEffect, useMemo, useState } from 'react';
import { rpc, sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtQty, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { useEmployees } from '../lib/goals';
import { colorOf, EmpMulti, MapPoint, MapView, popupEl, Region } from '../lib/maps';
import { Badge, Msg, useAction } from '../components/ui';

interface Pt {
  id: number; number: string; date: string; pay_type: string; customer_id: number; customer_number: string; customer: string;
  employee_id: number; employee: string; total: string; quantity: string | null; bonus: string; lat: string | null; lng: string | null; loc: string;
  cust_lat: string | null; cust_lng: string | null; in_region: boolean | null;
}
interface Res { points: Pt[]; missing: Pt[]; employees: { id: number; name: string; emp_number: string }[]; has_time: boolean;
  totals: { count: number; total: string; quantity: string; bonus: string; with_location: number; missing: number; in_region: number; out_region: number } }

export function useRegions(): Region[] {
  const [rows, setRows] = useState<Region[]>([]);
  useEffect(() => { sb().from('regions').select('id, name, color').eq('status', 'active').order('name').then(({ data }) => setRows((data ?? []) as Region[])); }, []);
  return rows;
}

export function InvoiceMap() {
  const { can } = useAuth();
  const emps = useEmployees();
  const regions = useRegions();
  const [f, setF] = useState({ from: todayIso(), to: todayIso(), employees: [] as number[], supervisor_id: '', region_id: '', pay_type: 'all', loc: 'all' });
  const [open, setOpen] = useState(true);
  const [d, setD] = useState<Res | null>(null);
  const [sel, setSel] = useState<string | number | null>(null);
  const [showMissing, setShowMissing] = useState(false);
  const load = useAction();
  useEffect(() => {
    let live = true;
    load.run(async () => { const r = await rpc<Res>('invoice_map', { p_from: f.from, p_to: f.to, p_opts: f }); if (live) { setD(r); setSel(null); } });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(f)]);

  const empIndex = useMemo(() => new Map((d?.employees ?? []).map((e, i) => [Number(e.id), i])), [d]);
  const points: MapPoint[] = useMemo(() => {
    if (!d) return [];
    const pts: MapPoint[] = d.points.map((p) => ({
      id: p.id, lat: Number(p.lat), lng: Number(p.lng), color: colorOf(empIndex.get(Number(p.employee_id)) ?? 0), title: `${p.number} — ${p.customer}`,
      popup: () => popupEl(`فاتورة ${p.number}`, [
        ['التاريخ', fmtDate(p.date)], ['النوع', p.pay_type], ['العميل', `${p.customer_number} — ${p.customer}`], ['المندوب', p.employee],
        ['المبلغ', fmtAmount(p.total)], ['الكمية', fmtQty(p.quantity)], ['البونص', fmtQty(p.bonus)],
        ['المنطقة', p.in_region === null ? 'لا منطقة مسندة للمندوب' : p.in_region ? 'داخل منطقة المندوب' : 'خارج منطقة المندوب'],
        ['الإحداثيات', `${p.lat}, ${p.lng}`]],
        [{ text: 'فتح السند', href: `#/transactions?kind=invoice&open=${p.id}` },
          ...(p.cust_lat ? [{ text: 'موقع العميل', onClick: () => setSel('c' + p.customer_id) }] : [])]),
    }));
    // موقع العميل المحفوظ عند طلبه من نافذة السند (أيقونة العميل)
    if (typeof sel === 'string' && sel.startsWith('c')) {
      const p = d.points.find((x) => 'c' + x.customer_id === sel);
      if (p?.cust_lat) pts.push({ id: sel, lat: Number(p.cust_lat), lng: Number(p.cust_lng), color: '#000000', title: 'موقع العميل المحفوظ: ' + p.customer,
        popup: () => popupEl('موقع العميل المحفوظ', [['العميل', `${p.customer_number} — ${p.customer}`]]) });
    }
    return pts;
  }, [d, empIndex, sel]);

  const doExport = () => d && writeSheet(`خريطة الفواتير ${f.from} - ${f.to}.xlsx`, 'الفواتير',
    ['رقم السند', 'التاريخ', 'النوع', 'رقم العميل', 'العميل', 'المندوب', 'المبلغ', 'الكمية', 'البونص', 'Latitude', 'Longitude', 'حالة الموقع', 'المنطقة'],
    [...d.points, ...d.missing].map((p) => [p.number, fmtDate(p.date), p.pay_type, p.customer_number, p.customer, p.employee, Number(p.total),
      p.quantity === null ? null : Number(p.quantity), Number(p.bonus), p.lat === null ? null : Number(p.lat), p.lng === null ? null : Number(p.lng),
      p.loc === 'ok' ? 'صالح' : p.loc === 'missing' ? 'مفقود' : 'غير صالح', p.in_region === null ? '' : p.in_region ? 'داخل' : 'خارج']));

  return (
    <>
      <div className="page-head">
        <h1>خريطة الفواتير</h1>
        <div className="actions">
          <button className="btn" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'إخفاء الفلاتر' : 'الفلاتر'}</button>
          {can('P15', 'export') && <button className="btn" disabled={!d} onClick={doExport}>تصدير Excel</button>}
        </div>
      </div>
      {open && (
        <div className="filters">
          <label className="check">من <input className="input" type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} aria-label="من تاريخ" /></label>
          <label className="check">إلى <input className="input" type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} aria-label="إلى تاريخ" /></label>
          <EmpMulti emps={emps} value={f.employees} onChange={(v) => setF({ ...f, employees: v })} />
          <select className="input" value={f.supervisor_id} onChange={(e) => setF({ ...f, supervisor_id: e.target.value })} aria-label="المجموعة">
            <option value="">كل المجموعات</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
          <select className="input" value={f.region_id} onChange={(e) => setF({ ...f, region_id: e.target.value })} aria-label="المنطقة">
            <option value="">كل المناطق</option>{regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
          <select className="input" value={f.pay_type} onChange={(e) => setF({ ...f, pay_type: e.target.value })} aria-label="نوع البيع">
            <option value="all">نقدي وذمم</option><option value="cash">نقدي</option><option value="credit">ذمم</option></select>
          <select className="input" value={f.loc} onChange={(e) => setF({ ...f, loc: e.target.value })} aria-label="حالة الموقع">
            <option value="all">كل حالات الموقع</option><option value="ok">بموقع صالح</option><option value="missing">بلا موقع صالح</option></select>
        </div>
      )}
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && (
        <div className="stats">
          <div className="stat"><div className="l">الفواتير</div><div className="v num">{d.totals.count}</div></div>
          <div className="stat"><div className="l">المبلغ</div><div className="v num">{fmtAmount(d.totals.total)}</div></div>
          <div className="stat"><div className="l">على الخريطة</div><div className="v num">{d.totals.with_location}</div></div>
          <div className="stat"><div className="l">بلا موقع صالح</div><div className="v num">{d.totals.missing}</div></div>
          <div className="stat"><div className="l">داخل / خارج المنطقة</div><div className="v num">{d.totals.in_region} / {d.totals.out_region}</div></div>
        </div>
      )}
      {d && !d.has_time && <p className="small muted">وقت الإصدار غير متوفر في ملف الفواتير؛ تُعرض النقاط فقط دون ترتيب زيارات أو مسار.</p>}
      <MapView points={points} selected={sel} onSelect={setSel} fitKey={JSON.stringify(f) + (d ? d.totals.count : '')}>
        {d && d.employees.length > 0 && (
          <div className="map-legend">{d.employees.map((e, i) => <span key={e.id}><i style={{ background: colorOf(i) }} /> {e.name}</span>)}</div>
        )}
      </MapView>
      {d && d.missing.length > 0 && (
        <div className="panel" style={{ marginTop: 12 }}>
          <button className="btn link" aria-expanded={showMissing} onClick={() => setShowMissing(!showMissing)}>فواتير بلا موقع صالح ({d.missing.length})</button>
          {showMissing && (
            <table className="inner"><thead><tr><th>السند</th><th>التاريخ</th><th>العميل</th><th>المندوب</th><th className="num">المبلغ</th><th>الحالة</th></tr></thead>
              <tbody>{d.missing.map((p) => (
                <tr key={p.id}><td><a href={`#/transactions?kind=invoice&open=${p.id}`}>{p.number}</a></td><td className="num">{fmtDate(p.date)}</td>
                  <td>{p.customer_number} — {p.customer}</td><td>{p.employee}</td><td className="num">{fmtAmount(p.total)}</td>
                  <td><Badge kind="warn">{p.loc === 'missing' ? 'مفقود' : 'غير صالح'}</Badge></td></tr>
              ))}</tbody></table>
          )}
        </div>
      )}
    </>
  );
}
