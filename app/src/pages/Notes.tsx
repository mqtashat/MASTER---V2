// P09 — الإشعارات المدينة والدائنة (B036، FIN-007): المدين يزيد الذمم والدائن يخفضها ويخصص كالتحصيل.
// العميل والتاريخ والرقم والقيمة والسبب وربط اختياري بسند؛ معاينة الأثر ثم اعتماد. لا يدخل المبيعات
// أو الأهداف أو العمولة، ولا ضريبة مضافة.
import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { rpc, sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { kindDef } from '../lib/docs';
import { CustomerPicker, loadCustomer, PickedCustomer } from '../components/CustomerPicker';
import { Badge, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { AuditList } from './Settings';

interface Note {
  id: number; kind: 'debit' | 'credit'; note_number: string; customer_id: number; customer_number: string; customer_name: string;
  note_date: string; amount: string; reason: string; linked_doc_id: number | null; version: number;
  linked_doc: { kind: 'invoice' | 'return' | 'collection'; doc_number: string; doc_date: string } | null; status: string; delete_reason: string | null;
}

const KIND: Record<string, string> = { debit: 'إشعار مدين', credit: 'إشعار دائن' };

export function Notes() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const [f, setF] = useState<Record<string, string | boolean>>({});
  const [rows, setRows] = useState<Note[] | null>(null);
  const [edit, setEdit] = useState<Note | 'new' | null>(null);
  const [del, setDel] = useState<Note | null>(null);
  const [ver, setVer] = useState(0);
  const load = useAction();

  useEffect(() => { load.run(async () => setRows(await rpc<Note[]>('notes_list', { p_filters: f }))); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [JSON.stringify(f), ver]);
  useEffect(() => {
    const id = Number(params.get('open'));
    if (id && rows) { const n = rows.find((x) => x.id === id); if (n) setEdit(n); setParams({}, { replace: true }); }
  }, [params, rows, setParams]);

  const set = (k: string, v: string | boolean) => setF((o) => ({ ...o, [k]: v }));
  const debit = (rows ?? []).filter((r) => r.status === 'active' && r.kind === 'debit').reduce((s, r) => s + Number(r.amount), 0);
  const credit = (rows ?? []).filter((r) => r.status === 'active' && r.kind === 'credit').reduce((s, r) => s + Number(r.amount), 0);

  const doExport = () => writeSheet(`الإشعارات ${todayIso()}.xlsx`, 'الإشعارات', ['النوع', 'الرقم', 'التاريخ', 'رقم العميل', 'العميل', 'القيمة', 'السبب', 'السند المرتبط', 'الحالة'],
    (rows ?? []).map((r) => [KIND[r.kind], r.note_number, fmtDate(r.note_date), r.customer_number, r.customer_name, fmtAmount(r.amount), r.reason,
      r.linked_doc ? `${kindDef(r.linked_doc.kind).one} ${r.linked_doc.doc_number}` : null, r.status === 'active' ? 'فعال' : 'محذوف']));

  return (
    <>
      <div className="page-head">
        <h1>الإشعارات المدينة والدائنة</h1>
        <div className="actions">
          {can('P09', 'export') && <button className="btn" onClick={doExport}>تصدير Excel</button>}
          {can('P09', 'add') && <button className="btn primary" onClick={() => setEdit('new')}>إشعار جديد</button>}
        </div>
      </div>
      <div className="filters">
        <select className="input" value={(f.kind as string) ?? ''} onChange={(e) => set('kind', e.target.value)} aria-label="النوع">
          <option value="">المدين والدائن</option><option value="debit">إشعار مدين</option><option value="credit">إشعار دائن</option>
        </select>
        <label className="small muted">من <input className="input" type="date" value={(f.from as string) ?? ''} onChange={(e) => set('from', e.target.value)} aria-label="من تاريخ" /></label>
        <label className="small muted">إلى <input className="input" type="date" value={(f.to as string) ?? ''} onChange={(e) => set('to', e.target.value)} aria-label="إلى تاريخ" /></label>
        <input className="input" placeholder="رقم العميل" value={(f.customer_number as string) ?? ''} onChange={(e) => set('customer_number', e.target.value.trim())} aria-label="رقم العميل" />
        <input className="input" placeholder="رقم الإشعار أو السبب" value={(f.search as string) ?? ''} onChange={(e) => set('search', e.target.value)} aria-label="بحث" />
        <label className="small"><input type="checkbox" checked={!!f.show_deleted} onChange={(e) => set('show_deleted', e.target.checked)} /> إظهار المحذوف</label>
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {rows && (
        <div className="stats">
          <div className="stat"><div className="l">العدد</div><div className="v num">{rows.length}</div></div>
          <div className="stat"><div className="l">المدين (يزيد الذمم)</div><div className="v num">{fmtAmount(String(debit))}</div></div>
          <div className="stat"><div className="l">الدائن (يخفض الذمم)</div><div className="v num">{fmtAmount(String(credit))}</div></div>
        </div>
      )}
      <div className="tbl"><table>
        <thead><tr><th>النوع</th><th>الرقم</th><th>التاريخ</th><th>العميل</th><th className="num">القيمة</th><th>السبب</th><th>السند المرتبط</th><th></th></tr></thead>
        <tbody>{!rows ? <tr><td colSpan={8}><div className="skeleton" /></td></tr> : rows.length === 0 ? <tr><td colSpan={8} className="empty">لا إشعارات ضمن الفلاتر</td></tr> : rows.map((r) => (
          <tr key={r.id} className={r.status === 'deleted' ? 'row-muted' : ''}>
            <td><Badge kind={r.kind === 'debit' ? 'warn' : 'ok'}>{KIND[r.kind]}</Badge>{r.status === 'deleted' && <> <Badge kind="bad">محذوف</Badge></>}</td>
            <td className="num">{r.note_number}</td><td className="num">{fmtDate(r.note_date)}</td>
            <td><span className="num">{r.customer_number}</span> — {r.customer_name}</td>
            <td className="num">{fmtAmount(r.amount)}</td><td>{r.reason}{r.delete_reason && <span className="muted small"> (سبب الحذف: {r.delete_reason})</span>}</td>
            <td className="small">{r.linked_doc ? `${kindDef(r.linked_doc.kind).one} ${r.linked_doc.doc_number} — ${fmtDate(r.linked_doc.doc_date)}` : ''}</td>
            <td className="actions">{r.status === 'active' && <>
              {can('P09', 'edit') && <button className="btn link" onClick={() => setEdit(r)}>تعديل</button>}
              {can('P09', 'delete') && <button className="btn link" onClick={() => setDel(r)}>حذف</button>}
            </>}</td>
          </tr>
        ))}</tbody></table></div>
      {edit && <NoteForm note={edit === 'new' ? null : edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); setVer(ver + 1); }} />}
      {del && <DeleteNote note={del} onClose={() => setDel(null)} onDone={() => { setDel(null); setVer(ver + 1); }} />}
    </>
  );
}

function NoteForm({ note, onClose, onDone }: { note: Note | null; onClose: () => void; onDone: () => void }) {
  const { can } = useAuth();
  const [kind, setKind] = useState<'debit' | 'credit'>(note?.kind ?? 'debit');
  const [cust, setCust] = useState<PickedCustomer | null>(null);
  const [number, setNumber] = useState(note?.note_number ?? '');
  const [date, setDate] = useState(note?.note_date ?? todayIso());
  const [amount, setAmount] = useState(note?.amount ?? '');
  const [reason, setReason] = useState(note?.reason ?? '');
  const [link, setLink] = useState<string>(note?.linked_doc_id ? String(note.linked_doc_id) : '');
  const [docs, setDocs] = useState<{ id: number; kind: 'invoice' | 'return' | 'collection'; doc_number: string; doc_date: string; total: string }[]>([]);
  const [confirm, setConfirm] = useState(false);
  const [tab, setTab] = useState('form');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();

  useEffect(() => { if (note) loadCustomer(note.customer_id).then(setCust); }, [note]);
  useEffect(() => {
    if (!cust) { setDocs([]); return; }
    sb().from('docs').select('id, kind, doc_number, doc_date, total').eq('customer_id', cust.id).eq('status', 'active')
      .order('doc_date', { ascending: false }).limit(100).then(({ data }) => setDocs((data ?? []) as typeof docs));
  }, [cust]);

  const save = () => run(async () => {
    await guarded((code) => rpc('save_note', { p_id: note?.id ?? null, p: {
      kind, note_number: number, customer_number: cust?.customer_number, note_date: date, amount, reason, linked_doc_id: link || null,
    }, p_code: code }));
    onDone();
  });
  const valid = cust && date && Number(amount) > 0 && reason.trim();
  return (
    <Modal title={note ? `تعديل ${KIND[note.kind]} ${note.note_number}` : 'إشعار جديد'} onClose={onClose} footer={tab !== 'form' ? undefined : confirm ? <>
      <button className="btn primary" disabled={busy} onClick={save}>اعتماد</button>
      <button className="btn" onClick={() => setConfirm(false)}>رجوع</button></> : <>
      <button className="btn primary" disabled={!valid} onClick={() => setConfirm(true)}>معاينة الأثر</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      {note && (
        <div className="tabs" role="tablist" style={{ marginBottom: 10 }}>
          <button role="tab" aria-selected={tab === 'form'} onClick={() => setTab('form')}>البيانات</button>
          <button role="tab" aria-selected={tab === 'log'} onClick={() => setTab('log')}>سجل التعديلات</button>
        </div>
      )}
      {tab === 'log' && note && can('P21') ? <AuditList entity="account_notes" entityId={String(note.id)} /> : tab === 'log' ? <p className="muted">سجل العمليات يحتاج صلاحية صفحة الإعدادات.</p> : confirm ? (
        <>
          <Msg kind={kind === 'debit' ? 'warn' : 'ok'}>{KIND[kind]} بقيمة <span className="num">{fmtAmount(amount)}</span> بتاريخ <span className="num">{fmtDate(date)}</span> للعميل {cust?.customer_number} — {cust?.name}: {kind === 'debit' ? 'يزيد الذمم' : 'يخفض الذمم ويُخصص على الديون كالتحصيل: الافتتاحي أولًا ثم الأقدم'}.</Msg>
          <p className="small muted">لا يدخل المبيعات أو الأهداف أو العمولات، ولا تضاف إليه ضريبة.</p>
        </>
      ) : (
        <div style={{ display: 'grid', gap: 10 }}>
          <fieldset className="plain"><legend>النوع</legend>
            <div className="actions">
              <label><input type="radio" checked={kind === 'debit'} onChange={() => setKind('debit')} /> إشعار مدين — يزيد الذمم</label>
              <label><input type="radio" checked={kind === 'credit'} onChange={() => setKind('credit')} /> إشعار دائن — يخفض الذمم</label>
            </div>
          </fieldset>
          <Field label="العميل"><CustomerPicker value={cust} onChange={(c) => { setCust(c); setLink(''); }} /></Field>
          <div className="grid3">
            <Field label="رقم الإشعار" hint="فارغ = ترقيم تلقائي"><input value={number} onChange={(e) => setNumber(e.target.value)} /></Field>
            <Field label="التاريخ"><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
            <Field label="القيمة"><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
          </div>
          <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <Field label="سند مرتبط (اختياري)">
            <select value={link} onChange={(e) => setLink(e.target.value)} disabled={!cust}>
              <option value="">بلا ربط</option>
              {docs.map((d) => <option key={d.id} value={d.id}>{kindDef(d.kind).one} {d.doc_number} — {fmtDate(d.doc_date)} — {fmtAmount(d.total)}</option>)}
            </select>
          </Field>
        </div>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function DeleteNote({ note, onClose, onDone }: { note: Note; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const del = () => run(async () => { await guarded((code) => rpc('delete_note', { p_id: note.id, p_reason: reason, p_code: code })); onDone(); });
  return (
    <Modal title={`حذف ${KIND[note.kind]} ${note.note_number}`} onClose={onClose} footer={<>
      <button className="btn danger" disabled={busy || !reason.trim()} onClick={del}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>يزول أثر الإشعار من الذمم والكشف، ويبقى ظاهرًا في سجل المحذوفات للمراجعة دون أثر مالي.</Msg>
      <Field label="سبب الحذف"><input value={reason} onChange={(e) => setReason(e.target.value)} autoFocus /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
