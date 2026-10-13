// P17b «انتشار الأصناف» (MAP-008، MAP-009، B070، B071): صنف وفترة (شهر، أسبوع السبت–الجمعة، أو مخصصة)
// ومندوبون أو مجموعة ومنطقة وعميل. نقطة لكل عميل أو فرع بموقعه المعتمد، وخريطة وقائمة متزامنتان،
// و«بونص فقط» و«مرتجع فقط» فئتان لا تضيفان مشتريًا، وغير المحدد موقعه في القائمة والإجمالي بلا نقطة، وExcel كامل.
import { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtQty, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { useEmployees, useProducts } from '../lib/goals';
import { EmpMulti, LOC_LABEL, MapPoint, MapView, monthRange, popupEl, REGION_STATE_LABEL, weekOf } from '../lib/maps';
import { useRegions } from './InvoiceMap';
import { Badge, Msg, useAction } from '../components/ui';

type N = string | number | null;
interface Row {
  customer_id: number; customer_number: string; name: string; kind: string; master_number: string | null; lat: N; lng: N; loc: string;
  region_id: number | null; region: string | null; region_state: string | null; category: 'buyer' | 'bonus_only' | 'return_only';
  value: N; quantity: N; bonus: N; invoices: number; returns_value: N; returns_qty: N; first: string | null; last: string | null; employees: string[]; docs: number[];
}
interface Res { product: { id: number; code: string; name: string }; from: string; to: string; region_date: string; rows: Row[];
  summary: { buyers: number; invoices: number; value: N; quantity: N; bonus: N; returns_value: N; returns_qty: N; bonus_only: number; return_only: number; no_location: number; no_region: number } }

const CAT: Record<string, { label: string; color: string }> = {
  buyer: { label: 'مشترٍ', color: '#2e7d32' }, bonus_only: { label: 'استلم بونص فقط', color: '#ef6c00' }, return_only: { label: 'مرتجع فقط', color: '#b3261e' },
};

export function Spread() {
  const { can } = useAuth();
  const emps = useEmployees();
  const products = useProducts();
  const regions = useRegions();
  const [product, setProduct] = useState('');
  const [mode, setMode] = useState<'month' | 'week' | 'custom'>('month');
  const [anchor, setAnchor] = useState(todayIso());
  const [range, setRange] = useState({ from: '', to: '' });
  const [o, setO] = useState({ employees: [] as number[], supervisor_id: '', region_id: '', search: '', current: false });
  const [d, setD] = useState<Res | null>(null);
  const [sel, setSel] = useState<number | null>(null);
  const load = useAction();
  const [from, to] = mode === 'custom' ? [range.from, range.to] : mode === 'week' ? weekOf(anchor) : monthRange(anchor);
  useEffect(() => {
    if (!product || !from || !to) return;
    let live = true;
    load.run(async () => { const r = await rpc<Res>('product_spread', { p_product: Number(product), p_from: from, p_to: to, p_opts: o }); if (live) { setD(r); setSel(null); } });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [product, from, to, JSON.stringify(o)]);

  const points: MapPoint[] = useMemo(() => (d?.rows ?? []).filter((r) => r.loc === 'ok').map((r) => ({
    id: r.customer_id, lat: Number(r.lat), lng: Number(r.lng), color: CAT[r.category].color, title: `${r.customer_number} — ${r.name}`,
    popup: () => popupEl(`${r.customer_number} — ${r.name}`, [['النوع', r.kind + (r.master_number ? ' من ' + r.master_number : '')], ['الفئة', CAT[r.category].label],
      ['الكمية', fmtQty(r.quantity)], ['القيمة', fmtAmount(r.value)], ['البونص', fmtQty(r.bonus)], ['الفواتير', String(r.invoices)],
      ['أول / آخر شراء', r.first ? `${fmtDate(r.first)} / ${fmtDate(r.last)}` : null], ['المندوبون', r.employees.join('، ')],
      ['المرتجع', Number(r.returns_value) ? fmtAmount(r.returns_value) : null]],
      [{ text: 'فواتير العميل', href: `#/transactions?kind=invoice&q=${r.customer_number}` }]),
  })), [d]);
  const s = d?.summary;
  const doExport = () => d && writeSheet(`انتشار ${d.product.code} ${from} - ${to}.xlsx`, 'الانتشار',
    ['رقم العميل', 'العميل', 'النوع', 'الرئيسي', 'الفئة', 'الكمية', 'القيمة', 'البونص', 'الفواتير', 'أول شراء', 'آخر شراء', 'المرتجع قيمة', 'المرتجع كمية', 'المندوبون', 'المنطقة', 'حالة الموقع', 'Latitude', 'Longitude'],
    d.rows.map((r) => [r.customer_number, r.name, r.kind, r.master_number, CAT[r.category].label, Number(r.quantity), Number(r.value), Number(r.bonus), r.invoices,
      r.first ? fmtDate(r.first) : null, r.last ? fmtDate(r.last) : null, Number(r.returns_value), Number(r.returns_qty), r.employees.join('، '),
      r.region ?? REGION_STATE_LABEL[r.region_state ?? 'none'], LOC_LABEL[r.loc], r.lat === null ? null : Number(r.lat), r.lng === null ? null : Number(r.lng)]));

  return (
    <>
      <div className="page-head">
        <h1>انتشار الأصناف</h1>
        <div className="actions">{can('P17b', 'export') && <button className="btn" disabled={!d} onClick={doExport}>تصدير Excel</button>}</div>
      </div>
      <div className="filters">
        <select className="input" value={product} onChange={(e) => setProduct(e.target.value)} aria-label="الصنف">
          <option value="">اختر صنفًا</option>{products.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.name}</option>)}</select>
        <div className="tabs" role="tablist">{([['month', 'شهر'], ['week', 'أسبوع'], ['custom', 'فترة']] as const).map(([k, t]) => (
          <button key={k} role="tab" aria-selected={mode === k} onClick={() => setMode(k)}>{t}</button>))}</div>
        {mode === 'custom' ? <>
          <input className="input" type="date" value={range.from} onChange={(e) => setRange({ ...range, from: e.target.value })} aria-label="من تاريخ" />
          <input className="input" type="date" value={range.to} onChange={(e) => setRange({ ...range, to: e.target.value })} aria-label="إلى تاريخ" />
        </> : <input className="input" type="date" value={anchor} onChange={(e) => setAnchor(e.target.value)} aria-label="تاريخ ضمن الفترة" />}
        <EmpMulti emps={emps} value={o.employees} onChange={(v) => setO({ ...o, employees: v })} />
        <select className="input" value={o.supervisor_id} onChange={(e) => setO({ ...o, supervisor_id: e.target.value })} aria-label="المجموعة">
          <option value="">كل المجموعات</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
        <select className="input" value={o.region_id} onChange={(e) => setO({ ...o, region_id: e.target.value })} aria-label="المنطقة">
          <option value="">كل المناطق</option><option value="none">بلا منطقة</option>{regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
        <input className="input" placeholder="بحث عن عميل" value={o.search} onChange={(e) => setO({ ...o, search: e.target.value })} aria-label="بحث عن عميل" />
        <label className="check"><input type="checkbox" checked={o.current} onChange={(e) => setO({ ...o, current: e.target.checked })} /> المناطق بالوضع الحالي</label>
        {from && to && <span className="count">من {fmtDate(from)} إلى {fmtDate(to)}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {!product && <div className="panel empty">اختر صنفًا لعرض انتشاره.</div>}
      {s && (
        <div className="stats">
          <div className="stat"><div className="l">العملاء المشترون</div><div className="v num">{s.buyers}</div></div>
          <div className="stat"><div className="l">الفواتير</div><div className="v num">{s.invoices}</div></div>
          <div className="stat"><div className="l">قيمة الصنف</div><div className="v num">{fmtAmount(s.value)}</div></div>
          <div className="stat"><div className="l">الكمية</div><div className="v num">{fmtQty(s.quantity)}</div></div>
          <div className="stat"><div className="l">البونص</div><div className="v num">{fmtQty(s.bonus)}</div></div>
          <div className="stat"><div className="l">المرتجع</div><div className="v num">{fmtAmount(s.returns_value)}</div></div>
          <div className="stat"><div className="l">بونص فقط / مرتجع فقط</div><div className="v num">{s.bonus_only} / {s.return_only}</div></div>
          <div className="stat"><div className="l">بلا موقع / بلا منطقة</div><div className="v num">{s.no_location} / {s.no_region}</div></div>
        </div>
      )}
      {product && (
        <div className="map-split">
          <MapView points={points} selected={sel} onSelect={(id) => setSel(Number(id))} fitKey={product + from + to + JSON.stringify(o)} height="65vh">
            <div className="map-legend">{Object.values(CAT).map((c) => <span key={c.label}><i style={{ background: c.color }} /> {c.label}</span>)}</div>
          </MapView>
          <div className="map-list">
            {d && (d.rows.length === 0 ? <p className="empty">لا حركات لهذا الصنف ضمن الفلاتر</p> : (
              <table className="inner"><thead><tr><th>العميل</th><th className="num">الكمية</th><th className="num">القيمة</th><th></th></tr></thead>
                <tbody>{d.rows.map((r) => (
                  <tr key={r.customer_id} className={'clickable' + (sel === r.customer_id ? ' row-sel' : '')} onClick={() => setSel(r.customer_id)}>
                    <td><span className="num">{r.customer_number}</span> — {r.name}<div className="small muted">{r.region ?? REGION_STATE_LABEL[r.region_state ?? 'none']} · {r.invoices} فاتورة</div></td>
                    <td className="num">{fmtQty(r.quantity)}</td><td className="num">{fmtAmount(r.value)}</td>
                    <td>{r.category !== 'buyer' && <Badge kind="warn">{CAT[r.category].label}</Badge>}{r.loc !== 'ok' && <Badge>{LOC_LABEL[r.loc]}</Badge>}</td></tr>
                ))}</tbody></table>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
