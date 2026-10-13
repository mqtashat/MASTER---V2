// P17 «المناطق والأسواق» (MAP-005، B067، B068): قائمة المناطق بألوانها وإسنادها وتاريخ سريانها،
// ورسم الحدود على الخريطة (نقر يضيف نقطة، سحب يحرّك، نقر مزدوج يحذف) أو استيراد KML/GeoJSON،
// ومعاينة العملاء المتأثرين قبل الحفظ، وقائمة «يحتاج تحديد منطقة» بإسناد صريح. التاريخي بنسخته، والحالي خيار منفصل.
import { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, todayIso } from '../lib/format';
import { useEmployees } from '../lib/goals';
import { Geom, MapPolygon, MapView, parseBoundary } from '../lib/maps';
import { Badge, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';

interface Version { id: number; valid_from: string; geom: Geom; employee_id: number | null; supervisor_id: number | null; employee: string | null; supervisor: string | null }
interface Region { id: number; name: string; color: string; note: string | null; version: Version | null; versions: { id: number; valid_from: string; points: number }[]; customers: number }
interface Conflict { id: number; customer_number: string; name: string; candidates: { id: number; name: string }[] }
interface Res { date: string; regions: Region[]; conflicts: Conflict[]; counts: { in: number; none: number; no_location: number; conflict: number } }
interface Draft { id: number | null; name: string; color: string; note: string; geom: Geom; employee_id: string; supervisor_id: string; valid_from: string }

export function Regions() {
  const { can } = useAuth();
  const emps = useEmployees();
  const [date, setDate] = useState('');
  const [d, setD] = useState<Res | null>(null);
  const [ver, setVer] = useState(0);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [del, setDel] = useState<Region | null>(null);
  const [assign, setAssign] = useState<Conflict | null>(null);
  const load = useAction();
  useEffect(() => {
    let live = true;
    load.run(async () => { const r = await rpc<Res>('regions_list', { p_date: date || null }); if (live) setD(r); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date, ver]);

  const polys: MapPolygon[] = useMemo(() => (d?.regions ?? []).filter((r) => r.version && r.id !== draft?.id)
    .map((r) => ({ id: r.id, geom: r.version!.geom, color: r.color, name: r.name, dashed: !!draft })), [d, draft]);
  const startEdit = (r: Region | null) => setDraft(r ? {
    id: r.id, name: r.name, color: r.color, note: r.note ?? '', geom: r.version?.geom ?? [[]], employee_id: r.version?.employee_id ? String(r.version.employee_id) : '',
    supervisor_id: r.version?.supervisor_id ? String(r.version.supervisor_id) : '', valid_from: todayIso(),
  } : { id: null, name: '', color: '#1f5fa8', note: '', geom: [[]], employee_id: '', supervisor_id: '', valid_from: todayIso() });

  return (
    <>
      <div className="page-head">
        <h1>المناطق والأسواق</h1>
        <div className="actions">{can('P17', 'add') && !draft && <button className="btn primary" onClick={() => startEdit(null)}>منطقة جديدة</button>}</div>
      </div>
      <div className="filters">
        <label className="check">الحدود والإسناد في <input className="input" type="date" value={date} onChange={(e) => setDate(e.target.value)} aria-label="تاريخ الحدود" /></label>
        {date ? <button className="btn link" onClick={() => setDate('')}>الوضع الحالي</button> : <Badge kind="accent">الوضع الحالي</Badge>}
        {d && <span className="count">داخل مناطق {d.counts.in} · بلا منطقة {d.counts.none} · بلا موقع {d.counts.no_location} · يحتاج تحديد {d.counts.conflict}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      <div className="map-split">
        <MapView polygons={polys} editGeom={draft?.geom ?? null} onEditGeom={(g) => draft && setDraft({ ...draft, geom: g })} height="70vh" fitKey={String(d?.regions.length) + date} />
        <div className="map-list">
          {draft ? <RegionEditor draft={draft} setDraft={setDraft} emps={emps} onDone={() => { setDraft(null); setVer(ver + 1); }} /> : (
            <>
              {d?.regions.length === 0 && <p className="empty">لا مناطق. ارسم منطقة أو استورد حدودها.</p>}
              {d?.regions.map((r) => (
                <div key={r.id} className="region-row">
                  <div><i className="swatch" style={{ background: r.color }} /> <b>{r.name}</b> <span className="small muted">{r.customers} عميل</span></div>
                  <div className="small muted">{r.version ? <>{r.version.employee ? 'المندوب ' + r.version.employee : r.version.supervisor ? 'فريق ' + r.version.supervisor : 'بلا إسناد'} · من {fmtDate(r.version.valid_from)} · {r.versions.length} نسخة</> : 'لا نسخة سارية في هذا التاريخ'}</div>
                  <div className="actions">
                    <a className="btn link" href={`#/locations?region=${r.id}`}>العملاء</a>
                    {can('P17', 'edit') && <button className="btn link" onClick={() => startEdit(r)}>تعديل الحدود والإسناد</button>}
                    {can('P17', 'delete') && <button className="btn link" onClick={() => setDel(r)}>حذف</button>}
                  </div>
                </div>
              ))}
              {d && d.conflicts.length > 0 && (
                <div className="panel" style={{ marginTop: 10 }}>
                  <h3>يحتاج تحديد منطقة ({d.conflicts.length})</h3>
                  <p className="small muted">عملاء على حد مشترك أو داخل منطقتين؛ لا يُحتسبون في أي منهما حتى الإسناد الصريح.</p>
                  <table className="inner"><tbody>{d.conflicts.map((c) => (
                    <tr key={c.id}><td>{c.customer_number} — {c.name}</td><td className="small">{c.candidates.map((x) => x.name).join(' / ')}</td>
                      <td>{can('P17', 'edit') && <button className="btn link" onClick={() => setAssign(c)}>إسناد</button>}</td></tr>
                  ))}</tbody></table>
                </div>
              )}
            </>
          )}
        </div>
      </div>
      {del && <DeleteRegion r={del} onClose={() => setDel(null)} onDone={() => { setDel(null); setVer(ver + 1); }} />}
      {assign && <AssignDlg c={assign} onClose={() => setAssign(null)} onDone={() => { setAssign(null); setVer(ver + 1); }} />}
    </>
  );
}

interface Pv { inside: number; added: { id: number; customer_number: string; name: string }[]; removed: { customer_number: string; name: string }[]; conflicts: { customer_number: string; name: string }[] }

function RegionEditor({ draft, setDraft, emps, onDone }: { draft: Draft; setDraft: (d: Draft | null) => void; emps: { id: number; name: string; emp_number: string }[]; onDone: () => void }) {
  const [pv, setPv] = useState<Pv | null>(null);
  const { busy, error, setError, run } = useAction();
  const guarded = useGuarded();
  const set = (n: Partial<Draft>) => { setDraft({ ...draft, ...n }); setPv(null); };
  const geom = draft.geom.filter((r) => r.length > 0);
  const pts = geom.reduce((s, r) => s + r.length, 0);
  const payload = () => ({ ...draft, geom });
  const preview = () => run(async () => setPv(await rpc<Pv>('preview_region', { p_id: draft.id, p: payload() })));
  const save = () => run(async () => { await guarded((code) => rpc('save_region', { p_id: draft.id, p: payload(), p_code: code })); onDone(); });
  const importFile = async (f: File) => {
    try { set({ geom: parseBoundary(await f.text(), f.name) }); } catch (e) { setError((e as Error).message); }
  };
  return (
    <div className="panel">
      <h3>{draft.id ? 'تعديل المنطقة' : 'منطقة جديدة'}</h3>
      <Field label="الاسم"><input value={draft.name} onChange={(e) => set({ name: e.target.value })} /></Field>
      <div className="grid2">
        <Field label="اللون"><input type="color" value={draft.color} onChange={(e) => set({ color: e.target.value })} /></Field>
        <Field label="يسري من" hint="تغير الحدود أو الإسناد ينشئ نسخة؛ القديمة تبقى للتاريخي"><input type="date" value={draft.valid_from} onChange={(e) => set({ valid_from: e.target.value })} /></Field>
        <Field label="المندوب"><select value={draft.employee_id} onChange={(e) => set({ employee_id: e.target.value })}><option value="">—</option>
          {emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}</select></Field>
        <Field label="أو مجموعة مشرف"><select value={draft.supervisor_id} onChange={(e) => set({ supervisor_id: e.target.value })}><option value="">—</option>
          {emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select></Field>
      </div>
      <Field label="ملاحظة"><input value={draft.note} onChange={(e) => set({ note: e.target.value })} /></Field>
      <p className="small"><b>وضع تحرير الحدود:</b> انقر على الخريطة لإضافة نقطة، واسحب النقطة لتحريكها، وانقر مرتين لحذفها. النقاط: <span className="num">{pts}</span></p>
      <div className="actions">
        <button className="btn" onClick={() => set({ geom: [...draft.geom.filter((r) => r.length), []] })} disabled={!pts}>مضلع إضافي</button>
        <button className="btn" onClick={() => set({ geom: [[]] })} disabled={!pts}>مسح الحدود</button>
        <label className="btn">استيراد KML/GeoJSON<input type="file" accept=".kml,.geojson,.json" hidden onChange={(e) => e.target.files?.[0] && importFile(e.target.files[0])} /></label>
      </div>
      {pv && (
        <div className="msg ok">
          داخل الحدود: <b>{pv.inside}</b> عميل · يدخلون: {pv.added.length} · يخرجون: {pv.removed.length}
          {pv.conflicts.length > 0 && <> · <b>يحتاج تحديد منطقة: {pv.conflicts.length}</b> ({pv.conflicts.slice(0, 5).map((c) => c.name).join('، ')})</>}
        </div>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
      <div className="actions">
        <button className="btn" disabled={busy || pts < 3} onClick={preview}>معاينة المتأثرين</button>
        <button className="btn primary" disabled={busy || !pv || !draft.name.trim()} onClick={save}>حفظ</button>
        <button className="btn" onClick={() => setDraft(null)}>إلغاء</button>
      </div>
    </div>
  );
}

function DeleteRegion({ r, onClose, onDone }: { r: Region; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  return (
    <Modal title={`حذف «${r.name}»`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={() => run(async () => { await rpc('delete_region', { p_id: r.id, p_reason: reason }); onDone(); })}>حذف</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <p className="small">يصبح عملاؤها ({r.customers}) بلا منطقة؛ مواقعهم وحركاتهم لا تتغير.</p>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function AssignDlg({ c, onClose, onDone }: { c: Conflict; onClose: () => void; onDone: () => void }) {
  const [region, setRegion] = useState(String(c.candidates[0]?.id ?? ''));
  const [from, setFrom] = useState(todayIso());
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const go = () => run(async () => { await rpc('assign_customer_region', { p_customer: c.id, p_region: region || null, p_from: from, p_reason: reason }); onDone(); });
  return (
    <Modal title={`إسناد ${c.customer_number} — ${c.name}`} onClose={onClose} footer={<><button className="btn primary" disabled={busy || !reason.trim()} onClick={go}>إسناد</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="المنطقة"><select value={region} onChange={(e) => setRegion(e.target.value)}>
        {c.candidates.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}<option value="">بلا منطقة</option></select></Field>
      <Field label="يسري من"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
      <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
