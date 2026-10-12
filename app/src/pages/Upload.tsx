// P05 — الرفع الموحد وسجله (DATA-002..007، UPLOAD-001، TXN-004، B046–B054)
// ثلاثة أزرار تحدد النوع وتفتح اختيار الملف ← قراءة وفحص ← معاينة السندات والفروق ← اعتماد الصحيح ومعالجة المعلق ← النتيجة.
import { useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, fmtQty, todayIso } from '../lib/format';
import { fetchAll } from '../lib/query';
import { readSheet, writeSheet } from '../lib/excel';
import { BATCH_STATUS, CLASS_LABELS, DocData, isKind, Kind, KINDS, kindDef, mapUploadRow, OUTCOME_LABELS, REQUIRED, toEditable } from '../lib/docs';
import { Badge, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { Counts, PlanError } from '../components/ImportWizard';
import { DataTable, Column } from '../components/DataTable';
import { DocEditor } from '../components/DocEditor';

interface Overview { [k: string]: { latest_doc_date: string | null; last_upload_at: string | null; last_batch_id: number | null; open_batches: number } }

export function Upload() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const preset = params.get('kind');
  const batchId = params.get('batch') ? Number(params.get('batch')) : null;
  const [tab, setTab] = useState<'new' | 'log'>(params.get('tab') === 'log' ? 'log' : 'new');
  const [logKind, setLogKind] = useState('');
  const [ver, setVer] = useState(0);
  const [overview, setOverview] = useState<Overview | null>(null);

  useEffect(() => { rpc<Overview>('upload_overview').then(setOverview).catch(() => setOverview(null)); }, [ver]);

  // الدفعة المفتوحة جزء من العنوان: الرجوع والرابط المباشر يعيدانها
  const openBatch = (id: number | null) => {
    const p = new URLSearchParams(params);
    if (id) p.set('batch', String(id)); else p.delete('batch');
    setParams(p);
  };

  return (
    <>
      <div className="page-head"><h1>الرفع الموحد وسجله</h1></div>
      <div className="side-layout">
        <aside className="panel side-summary" aria-label="حداثة السندات">
          <h3>حداثة السندات المعتمدة</h3>
          <div className="tbl" style={{ marginTop: 8 }}><table>
            <thead><tr><th>النوع</th><th>أحدث تاريخ سند</th><th>آخر رفع</th><th /></tr></thead>
            <tbody>{KINDS.map((k) => {
              const o = overview?.[k.kind];
              return (
                <tr key={k.kind}>
                  <td>{k.plural}</td>
                  <td className="num">{o?.latest_doc_date ? fmtDate(o.latest_doc_date) : '—'}</td>
                  <td className="num">{o?.last_upload_at ? fmtDateTime(o.last_upload_at) : '—'}</td>
                  <td><button className="btn link" onClick={() => { openBatch(null); setTab('log'); setLogKind(k.kind); }}>السجل</button></td>
                </tr>
              );
            })}</tbody></table></div>
          <p className="small muted" style={{ marginTop: 6 }}>أحدث تاريخ سند لا يثبت اكتمال الأيام السابقة؛ المعلق والمستبعد لا يدخلان فيه.</p>
        </aside>
        <section style={{ minWidth: 0 }}>
          {batchId ? (
            <BatchView id={batchId} onBack={() => { openBatch(null); setVer(ver + 1); }} onChanged={() => setVer(ver + 1)} />
          ) : (
            <>
              <div className="tabs" role="tablist" style={{ marginBottom: 12 }}>
                <button role="tab" aria-selected={tab === 'new'} onClick={() => setTab('new')}>رفع جديد</button>
                <button role="tab" aria-selected={tab === 'log'} onClick={() => setTab('log')}>سجل الرفع</button>
              </div>
              {tab === 'new' && (can('P05', 'import')
                ? <NewUpload preset={isKind(preset) ? preset : null} onStaged={(id) => { setVer(ver + 1); openBatch(id); }} />
                : <div className="panel muted">لا تملك صلاحية رفع الملفات.</div>)}
              {tab === 'log' && <BatchLog kind={logKind} setKind={setLogKind} ver={ver} onOpen={openBatch} onChanged={() => setVer(ver + 1)} />}
            </>
          )}
        </section>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------
// رفع جديد: ثلاثة أزرار، الضغط يحدد النوع ويفتح اختيار الملف (DATA-006)
// ---------------------------------------------------------------------
function NewUpload({ preset, onStaged }: { preset: Kind | null; onStaged: (id: number) => void }) {
  const input = useRef<HTMLInputElement>(null);
  const [kind, setKind] = useState<Kind | null>(preset);
  const { busy, error, run } = useAction();

  const choose = (k: Kind) => { setKind(k); if (input.current) { input.current.value = ''; input.current.click(); } };
  const picked = (f: File | null) => run(async () => {
    if (!f || !kind) return;
    const s = await readSheet(f);
    const have = s.headers.map((h) => h.trim()).filter(Boolean);
    const miss = REQUIRED[kind].filter((h) => !have.includes(h));
    if (miss.length) throw new Error(`ملف ${kindDef(kind).plural}: أعمدة مطلوبة غير موجودة: ${miss.join('، ')}`);
    if (!s.rows.length) throw new Error('الملف لا يحتوي صفوف بيانات');
    const rows = s.rows.map((r) => mapUploadRow(kind, r.cells, r.row));
    const res = await rpc<{ batch_id: number }>('upload_stage', { p_kind: kind, p_file_name: f.name, p_sheet: s.sheetName, p_columns: have, p_rows: rows });
    onStaged(res.batch_id);
  });

  return (
    <div className="panel" style={{ display: 'grid', gap: 12 }}>
      <div className="actions upload-buttons">
        {KINDS.map((k) => (
          <button key={k.kind} className={'btn big' + (kind === k.kind ? ' primary' : '')} disabled={busy} onClick={() => choose(k.kind)}>{k.button}</button>
        ))}
      </div>
      <input ref={input} type="file" accept=".xls,.xlsx" hidden aria-label="ملف الرفع" data-testid="upload-input" onChange={(e) => picked(e.target.files?.[0] ?? null)} />
      {preset && !busy && <p className="small muted">النوع المحدد: {kindDef(preset).plural}. اضغط الزر لاختيار الملف.</p>}
      {busy && <Msg>جارٍ قراءة ملف {kind ? kindDef(kind).plural : ''} وفحصه…</Msg>}
      {error && <Msg kind="bad">{error}</Msg>}
      <p className="small muted">المسار: اختيار الملف ← قراءة وفحص ← معاينة السندات والفروق ← اعتماد الصحيح ومعالجة المعلق ← نتيجة الرفع. تحفظ الدفعة ومعاينتها؛ مغادرة الصفحة لا تعتمد ولا تحذف شيئًا.</p>
    </div>
  );
}

// ---------------------------------------------------------------------
// معاينة الدفعة وقراراتها
// ---------------------------------------------------------------------
interface Batch {
  id: number; kind: Kind; file_name: string; sheet_name: string; row_count: number; status: string; uploaded_by_name: string;
  uploaded_at: string; delete_reason: string | null; docs: number; added: number; updated: number; no_change: number; kept: number;
  excluded: number; pending: number; awaiting: number; removed: number; reverted: number; conflicts: number;
  [k: string]: unknown;
}

export interface Item {
  id: number; seq: number; doc_number: string | null; customer_number: string | null; doc_date: string | null; doc_date_raw: string | null;
  employee_number: string | null; customer_name: string | null; rows: number[]; class: string; errors: PlanError[]; warnings: PlanError[];
  duplicates: number[][]; total: string | null; line_count: number; doc_id: number | null; outcome: string | null;
  conflict_on_delete: boolean; drop_duplicates: boolean; fixed: boolean;
}

const GROUPS: [string, string, (i: Item) => boolean][] = [
  ['all', 'الكل', () => true],
  ['awaiting', 'بانتظار قرار', (i) => !i.outcome],
  ['pending', 'معلق', (i) => !i.outcome && i.class === 'pending'],
  ['review', 'يحتاج مراجعة', (i) => !i.outcome && ['changed', 'manual_conflict', 'possible_match', 'deleted_before'].includes(i.class)],
  ['warn', 'تنبيهات', (i) => !i.outcome && i.warnings.length > 0],
  ['done', 'مقرر', (i) => !!i.outcome],
];

function BatchView({ id, onBack, onChanged }: { id: number; onBack: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [batch, setBatch] = useState<Batch | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [group, setGroup] = useState('awaiting');
  const [open, setOpen] = useState<Item | null>(null);
  const [result, setResult] = useState<Record<string, number> | null>(null);
  const [ver, setVer] = useState(0);
  const load = useAction();
  const act = useAction();
  const guarded = useGuarded();

  useEffect(() => {
    load.run(async () => {
      const { data, error } = await sb().from('upload_batches_v').select('*').eq('id', id).single();
      if (error) throw new Error(error.message);
      setBatch(data as Batch);
      setItems(await fetchAll<Item>(() => sb().from('batch_items')
        .select('id, seq, doc_number, customer_number, doc_date, doc_date_raw, employee_number, customer_name, rows, class, errors, warnings, duplicates, total, line_count, doc_id, outcome, conflict_on_delete, drop_duplicates, fixed')
        .eq('batch_id', id).order('seq')));
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, ver]);

  const refresh = () => { setVer(ver + 1); onChanged(); };
  const k = batch ? kindDef(batch.kind) : null;
  const live = batch && batch.status !== 'deleted';
  const eligible = (items ?? []).filter((i) => !i.outcome && ['new', 'changed', 'unchanged'].includes(i.class));

  const approveCorrect = () => act.run(async () => {
    const r = await guarded((code) => rpc<Record<string, number>>('upload_resolve', {
      p_batch: id, p_decisions: eligible.map((i) => ({ id: i.id, action: 'approve', drop_duplicates: i.drop_duplicates })), p_code: code,
    }));
    setResult(r); refresh();
  });
  const recheck = () => act.run(async () => { await rpc('upload_recheck', { p_batch: id }); refresh(); });

  const exportErrors = () => {
    const rows = (items ?? []).filter((i) => i.errors.length || i.warnings.length).flatMap((i) => [
      ...i.errors.map((e) => [i.doc_number, i.customer_number, i.doc_date_raw, e.row, e.field, e.value, 'خطأ يمنع الاعتماد', e.message]),
      ...i.warnings.map((e) => [i.doc_number, i.customer_number, i.doc_date_raw, e.row, e.field, e.value, 'تنبيه', e.message]),
    ]);
    writeSheet(`تقرير أخطاء الدفعة ${id} ${todayIso()}.xlsx`, 'الأخطاء', ['رقم السند', 'رقم العميل', 'التاريخ', 'الصف', 'العمود', 'القيمة', 'النوع', 'المشكلة'],
      rows.map((r) => r.map((v) => (v === null || v === undefined ? '' : (v as string | number)))));
  };

  const shown = (items ?? []).filter((GROUPS.find((g) => g[0] === group) ?? GROUPS[0])[2]);

  return (
    <div style={{ display: 'grid', gap: 12 }}>
      <div className="page-head">
        <div className="actions" style={{ alignItems: 'center' }}>
          <button className="btn" onClick={onBack}>رجوع</button>
          {batch && <h2>دفعة {k?.plural}: {batch.file_name}</h2>}
          {batch && <Badge kind={BATCH_STATUS[batch.status]?.[1]}>{BATCH_STATUS[batch.status]?.[0]}</Badge>}
        </div>
        {batch && <span className="meta">الورقة {batch.sheet_name} — رفعها {batch.uploaded_by_name} في <span className="num">{fmtDateTime(batch.uploaded_at)}</span></span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {batch && items && (
        <>
          <Counts items={[
            ['صفوف الملف', batch.row_count], ['السندات', batch.docs],
            ['جديد', items.filter((i) => !i.outcome && i.class === 'new').length, 'ok'],
            ['مطابق لا تغيير', items.filter((i) => !i.outcome && i.class === 'unchanged').length],
            ['متغير', items.filter((i) => !i.outcome && i.class === 'changed').length, 'warn'],
            ['تعارض مع يدوي', items.filter((i) => !i.outcome && i.class === 'manual_conflict').length, 'warn'],
            ['مطابق محتمل', items.filter((i) => !i.outcome && i.class === 'possible_match').length, 'warn'],
            ['سبق حذفه', items.filter((i) => !i.outcome && i.class === 'deleted_before').length, 'bad'],
            ['معلق', batch.pending, 'bad'],
          ]} />
          <Counts items={[['اعتُمد جديدًا', batch.added, 'ok'], ['حُدّث', batch.updated, 'ok'], ['بلا تغيير', batch.no_change],
            ['أُبقي المحفوظ', batch.kept], ['مستبعد', batch.excluded], ...(batch.status === 'deleted'
              ? [['أزيل', batch.removed, 'bad'], ['أعيد للسابق', batch.reverted, 'warn'], ['متعارض للمراجعة', batch.conflicts, 'warn']] as [string, number, 'bad' | 'warn'][]
              : [])]} />
          {batch.status === 'deleted' && <Msg kind="bad">حُذفت هذه الدفعة: {batch.delete_reason}{batch.conflicts ? ` — ${batch.conflicts} سند عدّل لاحقًا عُزل للمراجعة دون حذف أو استعادة.` : ''}</Msg>}
          {result && (
            <Msg kind={batch.pending || batch.awaiting ? 'warn' : 'ok'}>
              نتيجة الاعتماد: أضيف {batch.added}، حُدّث {batch.updated}، بلا تغيير {batch.no_change}.
              {batch.awaiting > 0 ? ` الدفعة غير مكتملة: ${batch.awaiting} سند بانتظار قرار، منها ${batch.pending} معلق.` : ' اكتملت الدفعة.'}
            </Msg>
          )}
          {act.error && <Msg kind="bad">{act.error}</Msg>}
          {live && (
            <div className="actions">
              {can('P05', 'approve') && <button className="btn primary" disabled={!eligible.length || act.busy} onClick={approveCorrect}>
                {`اعتماد الصحيح (${eligible.length})`}</button>}
              {can('P05', 'import') && batch.awaiting > 0 && <button className="btn" disabled={act.busy} onClick={recheck}>إعادة الفحص</button>}
              <button className="btn" onClick={exportErrors}>تنزيل تقرير الأخطاء</button>
            </div>
          )}
          <div className="tabs" role="tablist">
            {GROUPS.map(([g, l, f]) => (
              <button key={g} role="tab" aria-selected={group === g} onClick={() => setGroup(g)}>{l} (<span className="num">{items.filter(f).length}</span>)</button>
            ))}
          </div>
          <div className="tbl"><table>
            <thead><tr><th>رقم السند</th><th>العميل</th><th>التاريخ</th><th>{batch.kind === 'collection' ? 'المندوب' : 'الموظف'}</th><th>الصفوف</th><th>المبلغ</th><th>الحالة</th><th>المطلوب</th></tr></thead>
            <tbody>
              {shown.length === 0 && <tr><td colSpan={8} className="empty">لا سندات في هذا التصنيف</td></tr>}
              {shown.map((i) => (
                <tr key={i.id} className="clickable" tabIndex={0} onClick={() => setOpen(i)} onKeyDown={(e) => e.key === 'Enter' && setOpen(i)}>
                  <td className="num">{i.doc_number ?? '—'}</td>
                  <td>{i.customer_number ?? '—'}{i.customer_name ? ` — ${i.customer_name}` : ''}</td>
                  <td className="num">{i.doc_date ? fmtDate(i.doc_date) : i.doc_date_raw ?? '—'}</td>
                  <td className="num">{i.employee_number ?? '—'}</td>
                  <td className="num">{i.rows.length}</td>
                  <td className="num">{fmtAmount(i.total)}</td>
                  <td>{i.outcome ? <Badge kind={OUTCOME_LABELS[i.outcome]?.[1]}>{OUTCOME_LABELS[i.outcome]?.[0]}</Badge>
                    : <Badge kind={CLASS_LABELS[i.class]?.[1]}>{CLASS_LABELS[i.class]?.[0]}</Badge>}
                    {i.conflict_on_delete && <> <Badge kind="warn">متعارض للمراجعة</Badge></>}</td>
                  <td className="wrap small">{i.errors[0]?.message ?? i.warnings[0]?.message ?? ''}{i.errors.length > 1 ? ` (+${i.errors.length - 1})` : ''}</td>
                </tr>
              ))}
            </tbody>
          </table></div>
        </>
      )}
      {open && batch && <ItemDetail item={open} kind={batch.kind} live={!!live} onClose={() => setOpen(null)} onChanged={() => { refresh(); }} />}
    </div>
  );
}

// ---------------------------------------------------------------------
// تفاصيل السند في الدفعة: كامل الوارد مقابل المحفوظ، والأخطاء بالسطر والعمود والقيمة، والقرار
// ---------------------------------------------------------------------
interface Detail {
  item: Item & { data: DocData; norm: DocData | null };
  kind: Kind; existing: DocData | null; existing_status: string | null; existing_manual: boolean | null;
}

function ItemDetail({ item, kind, live, onClose, onChanged }: { item: Item; kind: Kind; live: boolean; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [d, setD] = useState<Detail | null>(null);
  const [editing, setEditing] = useState<DocData | null>(null);
  const [dropDup, setDropDup] = useState(item.drop_duplicates);
  const [deleting, setDeleting] = useState(false);
  const [ver, setVer] = useState(0);
  const load = useAction();
  const act = useAction();
  const guarded = useGuarded();
  useEffect(() => { load.run(async () => setD(await rpc<Detail>('upload_item_detail', { p_item: item.id }))); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [item.id, ver]);

  const it = d?.item;
  const decide = (action: string) => act.run(async () => {
    const r = await guarded((code) => rpc<{ skipped: { reason: string }[] }>('upload_resolve', {
      p_batch: (it as unknown as { batch_id: number }).batch_id, p_decisions: [{ id: item.id, action, drop_duplicates: dropDup }], p_code: code,
    }));
    if (r.skipped?.length) throw new Error(r.skipped[0].reason);
    onChanged(); onClose();
  });
  const saveFix = () => act.run(async () => {
    if (!editing) return;
    await rpc('upload_fix_item', { p_item: item.id, p_data: editing });
    setEditing(null); setVer(ver + 1); onChanged();
  });

  const approver = can('P05', 'approve') && live && it && !it.outcome;
  const cls = it?.class ?? item.class;
  const title = `${kindDef(kind).one} ${item.doc_number ?? '—'} — عميل ${item.customer_number ?? '—'}`;

  return (
    <Modal title={title} onClose={onClose} wide
      footer={approver ? (
        <>
          {cls === 'pending' && !editing && <>
            <button className="btn primary" onClick={() => setEditing(toEditable(kind, it!.data))}>تصحيح يدوي</button>
            <button className="btn" onClick={onClose}>إبقاء معلقًا</button>
            <button className="btn danger" disabled={act.busy} onClick={() => decide('exclude')}>استبعاد من الدفعة</button>
          </>}
          {cls === 'pending' && editing && <>
            <button className="btn primary" disabled={act.busy} onClick={saveFix}>حفظ وإعادة الفحص</button>
            <button className="btn" onClick={() => setEditing(null)}>إلغاء التصحيح</button>
          </>}
          {['new', 'changed', 'unchanged'].includes(cls) && <button className="btn primary" disabled={act.busy} onClick={() => decide('approve')}>
            {cls === 'changed' ? 'اعتماد الاستبدال الكامل' : 'اعتماد'}</button>}
          {['manual_conflict', 'possible_match'].includes(cls) && <>
            <button className="btn" disabled={act.busy} onClick={() => decide('keep')}>إبقاء المعدل يدويًا</button>
            <button className="btn primary" disabled={act.busy} onClick={() => decide('use_file')}>اعتماد بيانات الملف بدلًا منه</button>
          </>}
          {cls === 'deleted_before' && <>
            <button className="btn primary" disabled={act.busy} onClick={() => decide('restore')}>استعادة صريحة</button>
            <button className="btn" disabled={act.busy} onClick={() => decide('keep')}>إبقاؤه محذوفًا</button>
          </>}
          {cls !== 'pending' && <button className="btn" disabled={act.busy} onClick={() => decide('exclude')}>استبعاد من الدفعة</button>}
        </>
      ) : it && it.doc_id && ['added', 'updated', 'restored'].includes(it.outcome ?? '') && (can('P05', 'delete') || can('P06', 'delete')) ? (
        <button className="btn danger" onClick={() => setDeleting(true)}>حذف هذا السند</button>
      ) : undefined}>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {act.error && <Msg kind="bad">{act.error}</Msg>}
      {it && (
        <>
          <div className="actions" style={{ alignItems: 'center' }}>
            <Badge kind="accent">{kindDef(kind).plural}</Badge>
            {it.outcome ? <Badge kind={OUTCOME_LABELS[it.outcome]?.[1]}>{OUTCOME_LABELS[it.outcome]?.[0]}</Badge>
              : <Badge kind={CLASS_LABELS[cls]?.[1]}>{CLASS_LABELS[cls]?.[0]}</Badge>}
            <span className="small muted">صفوف المصدر: <span className="num">{it.rows.join('، ')}</span></span>
            {it.fixed && <Badge>صُحّح يدويًا</Badge>}
          </div>
          {cls === 'manual_conflict' && !it.outcome && <Msg>لهذا السند تعديل يدوي محفوظ؛ يبقى المعدل هو المعتمد إلى أن تختار صراحة اعتماد بيانات الملف (TXN-003).</Msg>}
          {cls === 'possible_match' && !it.outcome && <Msg>هذا المفتاح هو المفتاح الأصلي لسند عُدّل مفتاحه يدويًا؛ مطابقة محتملة للمراجعة، لا سند ثانٍ ولا إلغاء آلي للتصحيح (B048).</Msg>}
          {cls === 'deleted_before' && !it.outcome && <Msg kind="bad">سبق حذف هذا السند؛ لا يعود إلا باستعادة صريحة (B054).</Msg>}
          {cls === 'changed' && !it.outcome && <Msg>تختلف بيانات السند عن المحفوظ؛ الاعتماد يستبدل السند كاملًا بتفاصيله الواردة دون دمج للبنود (B046).</Msg>}
          {it.errors.length > 0 && <IssueTable title={`أخطاء تمنع الاعتماد (${it.errors.length})`} rows={it.errors} bad />}
          {it.warnings.length > 0 && <IssueTable title={`تنبيهات للمراجعة (${it.warnings.length})`} rows={it.warnings} />}
          {it.duplicates.length > 0 && !it.outcome && (
            <label className="check"><input type="checkbox" checked={dropDup} onChange={(e) => setDropDup(e.target.checked)} />
              استبعاد التكرار الوارد (يبقى أول صف من كل مجموعة متطابقة)؛ الافتراضي إبقاؤها كلها</label>
          )}
          {editing ? (
            <div className="panel"><h3>تصحيح السند المعلق</h3><div style={{ marginTop: 8 }}><DocEditor kind={kind} value={editing} onChange={setEditing} /></div></div>
          ) : (
            <div className={d?.existing ? 'grid2' : ''} style={{ gap: 12 }}>
              {d?.existing && <LinesPanel title={`المحفوظ${d.existing_status === 'deleted' ? ' (محذوف)' : ''}${d.existing_manual ? ' — معدل يدويًا' : ''}`} kind={kind} data={d.existing} />}
              <LinesPanel title="الوارد في الملف" kind={kind} data={(it.norm && it.norm.lines?.length ? it.norm : toEditable(kind, it.data))} />
            </div>
          )}
        </>
      )}
      {deleting && it?.doc_id && <DeleteDocModal docId={it.doc_id} label={title} onClose={() => setDeleting(false)} onDone={() => { setDeleting(false); onChanged(); onClose(); }} />}
    </Modal>
  );
}

function IssueTable({ title, rows, bad }: { title: string; rows: PlanError[]; bad?: boolean }) {
  return (
    <div className="panel">
      <h3 style={bad ? { color: 'var(--bad)' } : undefined}>{title}</h3>
      <div className="tbl" style={{ marginTop: 8 }}><table>
        <thead><tr><th>الصف</th><th>العمود</th><th>القيمة</th><th>المشكلة وطريقة التصحيح</th></tr></thead>
        <tbody>{rows.map((e, i) => <tr key={i}><td className="num">{e.row || '—'}</td><td>{e.field}</td><td className="num">{e.value ?? '—'}</td><td className="wrap">{e.message}</td></tr>)}</tbody>
      </table></div>
    </div>
  );
}

function LinesPanel({ title, kind, data }: { title: string; kind: Kind; data: DocData }) {
  const isCol = kind === 'collection';
  return (
    <div className="panel" style={{ minWidth: 0 }}>
      <h3>{title}</h3>
      <dl className="kv" style={{ marginTop: 6 }}>
        <dt>رقم السند</dt><dd className="num">{data.doc_number ?? '—'}</dd>
        <dt>العميل</dt><dd>{data.customer_number ?? '—'}{data.customer_name ? ` — ${data.customer_name}` : ''}</dd>
        <dt>التاريخ</dt><dd className="num">{data.doc_date ? fmtDate(data.doc_date) || data.doc_date : '—'}</dd>
        <dt>{isCol ? 'المندوب' : 'الموظف'}</dt><dd>{data.employee_number ?? '—'}{data.employee_name ? ` — ${data.employee_name}` : ''}</dd>
        {kind === 'invoice' && <><dt>النوع</dt><dd>{data.pay_type ?? '—'}</dd></>}
      </dl>
      <div className="tbl" style={{ marginTop: 8 }}><table>
        <thead><tr><th>الصف</th>{isCol ? <><th>القيمة</th><th>الدفع</th><th>رقم الشيك</th></> : <><th>الصنف</th><th>المباشر</th><th>العروض</th><th>الكمية</th><th>البونص</th><th>الموقع</th></>}</tr></thead>
        <tbody>{data.lines.map((l, i) => (
          <tr key={i} className={isCol && Number(l.amount) === 0 ? 'zero' : ''}>
            <td className="num">{l.row ?? '—'}</td>
            {isCol ? <><td className="num">{fmtAmount(l.amount) || l.amount}</td><td>{l.pay_method}</td><td>{l.cheque_no}</td></> : <>
              <td>{l.item_number}{l.item_name ? ` — ${l.item_name}` : ''}</td>
              <td className="num">{fmtAmount(l.net_sales) || l.net_sales}</td><td className="num">{fmtAmount(l.net_promotions) || l.net_promotions}</td>
              <td className="num">{fmtQty(l.quantity) || l.quantity}</td><td className="num">{fmtQty(l.bonus) || l.bonus}</td>
              <td className="small">{l.lat && l.lng ? 'محدد' : '—'}</td></>}
          </tr>
        ))}</tbody>
      </table></div>
    </div>
  );
}

// ---------------------------------------------------------------------
// سجل الرفع: الملف والنوع والرافع والتاريخ والحالة والأعداد، وحذف أثر الدفعة
// ---------------------------------------------------------------------
function BatchLog({ kind, setKind, ver, onOpen, onChanged }: { kind: string; setKind: (k: string) => void; ver: number; onOpen: (id: number) => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [deleting, setDeleting] = useState<Batch | null>(null);
  const columns: Column<Batch>[] = [
    { key: 'uploaded_at', label: 'التاريخ', sortable: true, render: (r) => <span className="num">{fmtDateTime(r.uploaded_at)}</span> },
    { key: 'kind', label: 'النوع', render: (r) => kindDef(r.kind).plural },
    { key: 'file_name', label: 'الملف', sortable: true },
    { key: 'uploaded_by_name', label: 'الرافع' },
    { key: 'status', label: 'الحالة', render: (r) => <Badge kind={BATCH_STATUS[r.status]?.[1]}>{BATCH_STATUS[r.status]?.[0]}</Badge> },
    { key: 'row_count', label: 'الصفوف', num: true },
    { key: 'docs', label: 'السندات', num: true },
    { key: 'added', label: 'جديد', num: true },
    { key: 'updated', label: 'محدث', num: true },
    { key: 'pending', label: 'معلق', num: true },
    { key: 'excluded', label: 'مستبعد', num: true },
    { key: 'actions', label: '', render: (r) => (
      <span className="actions" onClick={(e) => e.stopPropagation()}>
        <button className="btn link" onClick={() => onOpen(r.id)}>فتح</button>
        {can('P05', 'delete') && r.status !== 'deleted' && <button className="btn link" style={{ color: 'var(--bad)' }} onClick={() => setDeleting(r)}>حذف الدفعة</button>}
      </span>
    ) },
  ];
  return (
    <>
      <div className="filters">
        <select className="input" value={kind} onChange={(e) => setKind(e.target.value)} aria-label="النوع">
          <option value="">كل الأنواع</option>{KINDS.map((k) => <option key={k.kind} value={k.kind}>{k.plural}</option>)}
        </select>
      </div>
      <DataTable<Batch> columns={columns} rowKey={(r) => r.id} deps={[kind, ver]} onRowClick={(r) => onOpen(r.id)}
        fetcher={async (q) => {
          let b = sb().from('upload_batches_v').select('*', { count: 'exact' });
          if (kind) b = b.eq('kind', kind);
          // الافتراضي: الأحدث أولًا
          b = q.sort ? b.order(q.sort, { ascending: q.asc }) : b.order('uploaded_at', { ascending: false });
          b = b.order('id', { ascending: false });
          const { data, count, error } = await b.range(q.page * q.pageSize, (q.page + 1) * q.pageSize - 1);
          if (error) throw new Error(error.message);
          return { rows: (data ?? []) as Batch[], count: count ?? 0 };
        }} />
      {deleting && <DeleteBatchModal batch={deleting} onClose={() => setDeleting(null)} onDone={() => { setDeleting(null); onChanged(); }} />}
    </>
  );
}

interface DeletePlan {
  remove: { doc_number: string; customer_number: string; doc_date: string; total: string }[];
  revert: { doc_number: string; customer_number: string; doc_date: string; total: string; restore_total: string | null; restore_status: string }[];
  conflicts: { doc_number: string; customer_number: string; doc_date: string }[];
  exclude: number; unchanged: number; remove_total: string; revert_total: string;
}

function DeleteBatchModal({ batch, onClose, onDone }: { batch: Batch; onClose: () => void; onDone: () => void }) {
  const [plan, setPlan] = useState<DeletePlan | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  useEffect(() => { run(async () => setPlan(await rpc<DeletePlan>('preview_delete_batch', { p_batch: batch.id }))); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [batch.id]);
  const go = () => run(async () => {
    if (!reason.trim()) throw new Error('سبب حذف الدفعة مطلوب');
    await guarded((code) => rpc('delete_batch', { p_batch: batch.id, p_reason: reason, p_code: code }));
    onDone();
  });
  const key = (x: { doc_number: string; customer_number: string; doc_date: string }) => `${x.doc_number} / ${x.customer_number} / ${fmtDate(x.doc_date)}`;
  return (
    <Modal title={`حذف دفعة: ${batch.file_name}`} onClose={onClose} wide
      footer={<><button className="btn danger" disabled={busy || !plan} onClick={go}>تأكيد حذف الدفعة</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>حذف الدفعة تراجع عن أثر هذه الرفعة فقط، لا تراجع أعمى: الجديد يزال، والمعدّل يعود إلى نسخته السابقة، والمعدّل لاحقًا يعزل للمراجعة (DATA-007، B054).</Msg>
      {plan && (
        <>
          <Counts items={[['يزال', plan.remove.length, 'bad'], ['يستعاد إلى السابق', plan.revert.length, 'warn'], ['متعارض للمراجعة', plan.conflicts.length, 'warn'],
            ['مطابق بلا أثر', plan.unchanged], ['معلق يستبعد', plan.exclude]]} />
          <p className="small">مبالغ الجديد الذي سيزال: <span className="num">{fmtAmount(plan.remove_total)}</span> — مبالغ المعدّل الحالية: <span className="num">{fmtAmount(plan.revert_total)}</span></p>
          {plan.remove.length > 0 && <details open={plan.remove.length <= 10}><summary>السندات التي ستزال ({plan.remove.length})</summary>
            <ul className="small">{plan.remove.map((x) => <li key={key(x)}>{key(x)} — <span className="num">{fmtAmount(x.total)}</span></li>)}</ul></details>}
          {plan.revert.length > 0 && <details open={plan.revert.length <= 10}><summary>السندات التي تعود إلى نسختها السابقة ({plan.revert.length})</summary>
            <ul className="small">{plan.revert.map((x) => <li key={key(x)}>{key(x)}: <span className="num">{fmtAmount(x.total)}</span> ← <span className="num">{fmtAmount(x.restore_total)}</span>{x.restore_status === 'deleted' ? ' (يعود محذوفًا)' : ''}</li>)}</ul></details>}
          {plan.conflicts.length > 0 && <details open><summary>عُدّلت بعد الدفعة: لا تحذف ولا تستعاد تلقائيًا ({plan.conflicts.length})</summary>
            <ul className="small">{plan.conflicts.map((x) => <li key={key(x)}>{key(x)}</li>)}</ul></details>}
          <Field label="سبب الحذف"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        </>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

/** حذف سند واحد (TXN-004): معاينة السند والمبلغ ثم التأكيد بسبب */
export function DeleteDocModal({ docId, label, onClose, onDone }: { docId: number; label: string; onClose: () => void; onDone: () => void }) {
  const [doc, setDoc] = useState<{ total: string; line_count: number; doc_date: string } | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  useEffect(() => { sb().from('docs_v').select('total, line_count, doc_date').eq('id', docId).single().then(({ data }) => setDoc(data as typeof doc)); }, [docId]);
  const go = () => run(async () => {
    if (!reason.trim()) throw new Error('سبب حذف السند مطلوب');
    await guarded((code) => rpc('delete_doc', { p_doc: docId, p_reason: reason, p_code: code }));
    onDone();
  });
  return (
    <Modal title={`حذف ${label}`} onClose={onClose}
      footer={<><button className="btn danger" disabled={busy} onClick={go}>تأكيد الحذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>يزال السند بكامل تفاصيله من البيانات الفعالة دون استعادة نسخة أقدم؛ يبقى أصله وسجل الإجراء. إعادة رفعه لاحقًا تظهر «سبق حذفه».</Msg>
      {doc && <p className="small">المبلغ المتأثر: <span className="num">{fmtAmount(doc.total)}</span> — البنود: <span className="num">{doc.line_count}</span> — التاريخ: <span className="num">{fmtDate(doc.doc_date)}</span></p>}
      <Field label="سبب الحذف"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

export function UploadLink({ kind }: { kind: Kind }) {
  return <Link className="btn" to={`/upload?kind=${kind}`}>رفع {kindDef(kind).button}</Link>;
}
