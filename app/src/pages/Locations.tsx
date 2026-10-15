// P16 «مواقع العملاء» (MAP-004، B065، B066): خريطة وقائمة متزامنتان، بحث ومنطقة ومندوب وحالة الموقع،
// استيراد القالب بمعاينة الجديد والمتغير والناقص، وتصحيح نقطة بمعاينة الأصل والجديد، والإزالة صراحة.
// الأصل المستورد يبقى للتدقيق، وموقع العميل لا يحل محل موقع الفاتورة.
import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDateTime } from '../lib/format';
import { readSheet, writeSheet } from '../lib/excel';
import { useEmployees } from '../lib/goals';
import { LOC_LABEL, MapPoint, MapView, popupEl, REGION_STATE_LABEL } from '../lib/maps';
import { useRegions } from './InvoiceMap';
import { Badge, Field, Modal, Msg, useAction } from '../components/ui';

interface Row {
  id: number; customer_number: string; name: string; master_number: string | null; master_name: string | null; kind: string;
  lat: string | null; lng: string | null; orig_lat: string | null; orig_lng: string | null; state: 'ok' | 'missing' | 'invalid';
  updated_at: string | null; region_id: number | null; region_state: string; region: string | null;
}
const STATE_COLOR: Record<string, string> = { in: '#2e7d32', assigned: '#2e7d32', none: '#1f5fa8', conflict: '#ef6c00' };

export function Locations() {
  const { can } = useAuth();
  const emps = useEmployees();
  const regions = useRegions();
  const [params] = useSearchParams();
  const [o, setO] = useState({ search: '', region_id: params.get('region') ?? '', employee_id: '', state: 'all' });
  const [rows, setRows] = useState<Row[] | null>(null);
  const [ver, setVer] = useState(0);
  const [sel, setSel] = useState<number | null>(null);
  const [edit, setEdit] = useState<Row | null>(null);
  const [imp, setImp] = useState(false);
  const load = useAction();
  useEffect(() => {
    let live = true;
    load.run(async () => { const r = await rpc<Row[]>('customer_locations', { p_opts: o }); if (live) setRows(r); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(o), ver]);

  const points: MapPoint[] = useMemo(() => (rows ?? []).filter((r) => r.state === 'ok').map((r) => ({
    id: r.id, lat: Number(r.lat), lng: Number(r.lng), color: STATE_COLOR[r.region_state] ?? '#1f5fa8', title: `${r.customer_number} — ${r.name}`,
    popup: () => popupEl(`${r.customer_number} — ${r.name}`, [['النوع', r.kind], ['الرئيسي', r.master_name], ['المنطقة', r.region ?? REGION_STATE_LABEL[r.region_state]],
      ['الإحداثيات', `${r.lat}, ${r.lng}`], ['الأصل المستورد', r.orig_lat ? `${r.orig_lat}, ${r.orig_lng}` : null]],
      [{ text: 'كشف الحساب', href: `#/statement?customer=${r.id}` }]),
  })), [rows]);
  const counts = useMemo(() => ({ ok: (rows ?? []).filter((r) => r.state === 'ok').length, bad: (rows ?? []).filter((r) => r.state !== 'ok').length }), [rows]);
  const doExport = () => rows && writeSheet('مواقع العملاء.xlsx', 'المواقع', ['رقم العميل', 'اسم العميل', 'النوع', 'الرئيسي', 'خط العرض', 'خط الطول', 'الحالة', 'المنطقة'],
    rows.map((r) => [r.customer_number, r.name, r.kind, r.master_number, r.lat === null ? null : Number(r.lat), r.lng === null ? null : Number(r.lng),
      LOC_LABEL[r.state], r.region ?? REGION_STATE_LABEL[r.region_state]]));

  return (
    <>
      <div className="page-head">
        <h1>مواقع العملاء</h1>
        <div className="actions">
          {can('P16', 'export') && <button className="btn" disabled={!rows} onClick={doExport}>تصدير Excel</button>}
          {can('P16', 'import') && <button className="btn primary" onClick={() => setImp(true)}>استيراد المواقع</button>}
        </div>
      </div>
      <div className="filters">
        <input className="input" placeholder="بحث بالرقم أو الاسم" value={o.search} onChange={(e) => setO({ ...o, search: e.target.value })} aria-label="بحث" />
        <select className="input" value={o.region_id} onChange={(e) => setO({ ...o, region_id: e.target.value })} aria-label="المنطقة">
          <option value="">كل المناطق</option><option value="none">بلا منطقة</option>{regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
        <select className="input" value={o.employee_id} onChange={(e) => setO({ ...o, employee_id: e.target.value })} aria-label="المندوب">
          <option value="">كل المندوبين</option>{emps.map((e) => <option key={e.id} value={e.id}>{e.name}</option>)}</select>
        <div className="tabs" role="tablist">
          {[['all', 'الكل'], ['ok', 'بموقع'], ['missing', 'المفقود'], ['invalid', 'غير الصحيح']].map(([k, t]) => (
            <button key={k} role="tab" aria-selected={o.state === k} onClick={() => setO({ ...o, state: k })}>{t}</button>))}
        </div>
        {rows && <span className="count">{rows.length} عميل · {counts.ok} على الخريطة · {counts.bad} بلا موقع صالح</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      <div className="map-split">
        <MapView points={points} selected={sel} onSelect={(id) => setSel(Number(id))} fitKey={JSON.stringify(o) + ver} height="70vh" />
        <div className="map-list">
          {!rows ? <div className="skeleton" /> : rows.length === 0 ? <p className="empty">لا عملاء ضمن الفلاتر</p> : (
            <table className="inner"><tbody>{rows.slice(0, 1000).map((r) => (
              <tr key={r.id} className={'clickable' + (sel === r.id ? ' row-sel' : '')} onClick={() => setSel(r.id)}>
                <td><span className="num">{r.customer_number}</span> — {r.name}{r.kind === 'فرع' && <span className="small muted"> · فرع {r.master_number}</span>}
                  <div className="small muted">{r.region ?? REGION_STATE_LABEL[r.region_state]}</div></td>
                <td>{r.state !== 'ok' && <Badge kind="warn">{LOC_LABEL[r.state]}</Badge>}</td>
                <td>{(can('P16', 'edit') || can('P02', 'edit')) && <button className="btn link" onClick={(e) => { e.stopPropagation(); setEdit(r); }}>تعديل</button>}</td>
              </tr>
            ))}</tbody></table>
          )}
          {rows && rows.length > 1000 && <p className="small muted">تُعرض أول 1000؛ ضيّق البحث أو صدّر الكل.</p>}
        </div>
      </div>
      {edit && <EditLocation r={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); setVer(ver + 1); }} />}
      {imp && <ImportLocations onClose={() => setImp(false)} onDone={() => { setImp(false); setVer(ver + 1); }} />}
    </>
  );
}

function EditLocation({ r, onClose, onDone }: { r: Row; onClose: () => void; onDone: () => void }) {
  const [lat, setLat] = useState(r.lat ?? '');
  const [lng, setLng] = useState(r.lng ?? '');
  const { busy, error, run } = useAction();
  const valid = lat !== '' && lng !== '' && Number.isFinite(Number(lat)) && Number.isFinite(Number(lng));
  const save = (remove: boolean) => run(async () => {
    await rpc('set_customer_location', { p_customer: r.id, p_lat: remove ? null : lat, p_lng: remove ? null : lng });
    onDone();
  });
  const pt: MapPoint[] = valid ? [{ id: 'new', lat: Number(lat), lng: Number(lng), color: '#ef6c00', title: 'الموقع الجديد' }] : [];
  const old: MapPoint[] = r.state === 'ok' ? [{ id: 'old', lat: Number(r.lat), lng: Number(r.lng), color: '#9e9e9e', title: 'الموقع الحالي' }] : [];
  return (
    <Modal wide title={`موقع ${r.customer_number} — ${r.name}`} onClose={onClose} footer={<>
      <button className="btn primary" disabled={busy || !valid} onClick={() => save(false)}>حفظ الموقع</button>
      {r.lat && <button className="btn danger" disabled={busy} onClick={() => save(true)}>إزالة الموقع</button>}
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="خط العرض"><input inputMode="decimal" value={lat} onChange={(e) => setLat(e.target.value)} /></Field>
        <Field label="خط الطول"><input inputMode="decimal" value={lng} onChange={(e) => setLng(e.target.value)} /></Field>
      </div>
      <p className="small muted">الحالي: {r.lat ? `${r.lat}, ${r.lng}` : 'لا موقع'}{r.orig_lat && ` · الأصل المستورد: ${r.orig_lat}, ${r.orig_lng}`}{r.updated_at && ` · آخر تحديث ${fmtDateTime(r.updated_at)}`}.
        انقر على الخريطة لاختيار النقطة. الإزالة لا تحذف العميل ولا حركاته، ولا ينتقل موقع فاتورة تاريخية مع نقطة العميل.</p>
      <PickOnMap points={[...old, ...pt]} onPick={(a, b) => { setLat(String(a)); setLng(String(b)); }} />
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

/** خريطة صغيرة يختار فيها المستخدم نقطة بالنقر */
function PickOnMap({ points, onPick }: { points: MapPoint[]; onPick: (lat: number, lng: number) => void }) {
  const [g, setG] = useState<[number, number][][]>([[]]);
  useEffect(() => { const last = g[0][g[0].length - 1]; if (last) { onPick(last[0], last[1]); setG([[]]); } /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [g]);
  return <MapView points={points} cluster={false} editGeom={g} onEditGeom={setG} height={320} fitKey={points.map((p) => p.id).join()} />;
}

interface ImpRow { row: number; customer_number: string; name: string | null; name_src: string | null; kind: string; message: string | null; old_lat: string | null; old_lng: string | null; lat: string | null; lng: string | null }
const KIND_LABEL: Record<string, string> = { new: 'جديد', changed: 'متغير', same: 'بلا تغيير', blank: 'فارغ — لا يمحو', error: 'خطأ' };

// يُستعمل أيضًا من صفحة العملاء (CUS-004)
export function ImportLocations({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [pv, setPv] = useState<{ counts: Record<string, number>; rows: ImpRow[] } | null>(null);
  const [done, setDone] = useState(false);
  const { busy, error, setError, run } = useAction();
  const pick = (c: Record<string, string>, ...keys: string[]) => keys.map((k) => c[k]).find((v) => v !== undefined) ?? '';
  const read = (file: File) => run(async () => {
    const s = await readSheet(file);
    if (!s.headers.some((h) => ['رقم العميل', 'CustomerNumber'].includes(h))) { setError('أعمدة القالب: رقم العميل، اسم العميل، خط العرض، خط الطول'); return; }
    const r = s.rows.map((x) => ({ row: String(x.row), customer_number: pick(x.cells, 'رقم العميل', 'CustomerNumber'), name: pick(x.cells, 'اسم العميل', 'إسم العميل', 'Customername'),
      lat: pick(x.cells, 'خط العرض', 'Latitude'), lng: pick(x.cells, 'خط الطول', 'Longitude') }));
    setRows(r);
    setPv(await rpc('import_customer_locations', { p_rows: r, p_commit: false }));
  });
  const commit = () => run(async () => { await rpc('import_customer_locations', { p_rows: rows, p_commit: true }); setDone(true); });
  // تنبيه فقط دون تبديل (CUS-004): خط العرض أكبر من خط الطول يدل غالبًا على عمودين معكوسين في الملف
  const swapped = new Set((pv?.rows ?? []).filter((r) => r.lat !== null && r.lng !== null && Number(r.lat) > Number(r.lng)).map((r) => r.row));
  const template = () => writeSheet('قالب مواقع العملاء.xlsx', 'المواقع', ['رقم العميل', 'اسم العميل', 'خط العرض', 'خط الطول'], []);
  return (
    <Modal wide title="استيراد مواقع العملاء" onClose={onClose} footer={done ? <button className="btn primary" onClick={onDone}>تم</button> : <>
      <button className="btn primary" disabled={busy || !pv || !(pv.counts.new + pv.counts.changed)} onClick={commit}>اعتماد ({pv ? pv.counts.new + pv.counts.changed : 0})</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <p className="small muted">المطابقة برقم العميل. الاسم للمراجعة فقط. الخانة الفارغة لا تمحو موقعًا محفوظًا، والعميل غير المعروف يحتاج تعريفًا في صفحة العملاء أولًا.
        <button className="btn link" onClick={template}>تنزيل القالب</button></p>
      {!done && <input type="file" accept=".xlsx,.xls" aria-label="ملف المواقع" onChange={(e) => e.target.files?.[0] && read(e.target.files[0])} />}
      {pv && (
        <>
          {swapped.size > 0 && <Msg kind="warn">يبدو أن خط العرض وخط الطول معكوسان في {swapped.size} صفًا؛ راجع الملف قبل الاعتماد.</Msg>}
          <div className="actions">{Object.entries(pv.counts).map(([k, v]) => <Badge key={k} kind={k === 'error' ? 'bad' : k === 'new' || k === 'changed' ? 'ok' : undefined}>{KIND_LABEL[k]}: {v}</Badge>)}</div>
          <div className="tbl" style={{ maxHeight: 360 }}><table>
            <thead><tr><th>الصف</th><th>العميل</th><th>الحالة</th><th>الحالي</th><th>الجديد</th><th>ملاحظة</th></tr></thead>
            <tbody>{pv.rows.map((r) => (
              <tr key={r.row} className={r.kind === 'error' ? 'zero' : r.kind === 'same' || r.kind === 'blank' ? 'row-muted' : ''}>
                <td className="num">{r.row}</td><td>{r.customer_number} — {r.name ?? r.name_src}</td><td>{KIND_LABEL[r.kind]}{swapped.has(r.row) && <> <Badge kind="warn">معكوس؟</Badge></>}</td>
                <td className="num">{r.old_lat ? `${r.old_lat}, ${r.old_lng}` : ''}</td><td className="num">{r.lat ? `${r.lat}, ${r.lng}` : ''}</td><td className="wrap">{r.message}</td></tr>
            ))}</tbody></table></div>
        </>
      )}
      {done && <Msg kind="ok">اعتُمد الاستيراد.</Msg>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
