// P08a — الافتتاحيات والإغلاق السنوي (FIN-002، FIN-003، FIN-006، FIN-008، B031، B038–B040).
// السنة تختار أولًا؛ 2026 يبدأ بصفر معتمد. القالب: رقم العميل/اسمه/مدين/دائن. الفراغ لا يمحو، والصفر
// الصريح يصفر، ولا مدين ودائن موجبان معًا. الإغلاق يرحل الإقفال افتتاحيًا للتالية ولا يجمع القديم مرتين.
import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, todayIso } from '../lib/format';
import { readSheet, writeSheet, missingHeaders } from '../lib/excel';
import { Badge, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';

const HEADERS = ['رقم العميل', 'اسم العميل', 'مدين — على العميل', 'دائن — للعميل'];
const SOURCE: Record<string, string> = { manual: 'يدوي', import: 'استيراد', carry: 'ترحيل الإغلاق' };

interface Row {
  customer_id: number; customer_number: string; name: string; master_number: string | null;
  debit: string | null; credit: string | null; source: string | null; updated_at: string | null;
  known: boolean; prev_closing: string | null; prev_known: boolean | null;
}
interface Batch { id: number; year: number; file_name: string | null; summary: Record<string, number>; status: string; created_at: string; created_by_name: string | null; delete_reason: string | null }
interface Overview { year: number; start_year: number; prev_closed: boolean; closed: { closed_at: string; closed_by_name: string } | null; rows: Row[]; batches: Batch[] }

const signed = (r: { debit: string | null; credit: string | null }) => (r.debit === null ? null : Number(r.debit) - Number(r.credit));

export function Openings() {
  const { can } = useAuth();
  const thisYear = Number(todayIso().slice(0, 4));
  const [year, setYear] = useState(thisYear);
  const [data, setData] = useState<Overview | null>(null);
  const [term, setTerm] = useState('');
  const [onlyDiff, setOnlyDiff] = useState(false);
  const [edit, setEdit] = useState<Row | null>(null);
  const [importing, setImporting] = useState(false);
  const [closing, setClosing] = useState(false);
  const [delBatch, setDelBatch] = useState<Batch | null>(null);
  const [ver, setVer] = useState(0);
  const load = useAction();

  useEffect(() => { load.run(async () => setData(await rpc<Overview>('openings_overview', { p_year: year }))); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [year, ver]);

  const rows = useMemo(() => (data?.rows ?? []).filter((r) => {
    if (term && !r.customer_number.startsWith(term.trim()) && !r.name.includes(term.trim())) return false;
    if (onlyDiff) { const s = signed(r); return r.prev_closing !== null && s !== null && Math.abs(s - Number(r.prev_closing)) > 0.0005; }
    return true;
  }), [data, term, onlyDiff]);

  const template = () => {
    writeSheet(`افتتاحيات ${year}.xlsx`, `افتتاحيات ${year}`, HEADERS, (data?.rows ?? []).map((r) => [r.customer_number, r.name, r.debit, r.credit]));
  };
  const doExport = () => {
    writeSheet(`افتتاحيات ${year} — مقارنة.xlsx`, `افتتاحيات ${year}`, [...HEADERS, 'المصدر', `إقفال ${year - 1}`, 'الفرق'],
      rows.map((r) => { const s = signed(r); return [r.customer_number, r.name, r.debit, r.credit, r.source ? SOURCE[r.source] : 'غير محدد',
        r.prev_closing, r.prev_closing !== null && s !== null ? fmtAmount(String(s - Number(r.prev_closing))) : null]; }));
  };

  return (
    <>
      <div className="page-head">
        <h1>الافتتاحيات والإغلاق السنوي</h1>
        <div className="actions">
          <button className="btn" onClick={template}>تنزيل القالب</button>
          {can('P08a', 'import') && <button className="btn" onClick={() => setImporting(true)}>استيراد بمعاينة</button>}
          {can('P08a', 'export') && <button className="btn" onClick={doExport}>تصدير</button>}
          {can('P08a', 'approve') && <button className="btn primary" onClick={() => setClosing(true)}>إغلاق سنة {year}</button>}
        </div>
      </div>
      <div className="filters">
        <label className="small muted">السنة{' '}
          <select className="input" value={year} onChange={(e) => setYear(Number(e.target.value))} aria-label="السنة">
            {Array.from({ length: 6 }, (_, i) => thisYear + 1 - i).filter((y) => y >= 2026).map((y) => <option key={y}>{y}</option>)}
          </select>
        </label>
        <span className="small">تاريخ الافتتاح <span className="num">{fmtDate(`${year}-01-01`)}</span></span>
        <input className="input" placeholder="رقم العميل أو اسمه" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="بحث" />
        <label className="small"><input type="checkbox" checked={onlyDiff} onChange={(e) => setOnlyDiff(e.target.checked)} /> المختلف عن إقفال {year - 1} فقط</label>
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {data && (
        <>
          {year === data.start_year && <Msg kind="ok">افتتاح {year} صفر معتمد لكل العملاء (FIN-002)؛ تبقى الإضافة والتعديل لأي عميل متاحين.</Msg>}
          {year > data.start_year && !data.prev_closed && <Msg>لم تُغلق سنة {year - 1} بعد: من لا افتتاح مسجل له في {year} رصيده غير معلوم، ومرتجعاته تُعلّق حتى يُعرف (RET-010).</Msg>}
          {data.closed && <Msg kind="ok">أُغلقت سنة {year} في {fmtDateTime(data.closed.closed_at)} بواسطة {data.closed.closed_by_name}.</Msg>}
          <div className="tbl"><table>
            <thead><tr><th>العميل</th><th className="num">مدين — على العميل</th><th className="num">دائن — للعميل</th><th>المصدر</th>
              {year > data.start_year && <><th className="num">إقفال {year - 1}</th><th className="num">الفرق</th></>}<th></th></tr></thead>
            <tbody>
              {rows.length === 0 ? <tr><td colSpan={7} className="empty">لا عملاء ضمن البحث</td></tr> : rows.slice(0, 500).map((r) => {
                const s = signed(r);
                const diff = r.prev_closing !== null && s !== null ? s - Number(r.prev_closing) : null;
                return (
                  <tr key={r.customer_id}>
                    <td><span className="num">{r.customer_number}</span> — {r.name}{r.master_number && <span className="muted small"> (فرع {r.master_number})</span>}</td>
                    <td className="num">{r.debit !== null ? fmtAmount(r.debit) : ''}</td>
                    <td className="num">{r.credit !== null ? fmtAmount(r.credit) : ''}</td>
                    <td>{r.source ? SOURCE[r.source] : r.known ? <span className="muted small">{year === data.start_year ? 'صفر معتمد' : 'صفر بعد الإغلاق'}</span> : <Badge kind="warn">غير محدد</Badge>}</td>
                    {year > data.start_year && <>
                      <td className="num">{r.prev_closing !== null ? fmtAmount(r.prev_closing) : <span className="muted small">{r.prev_known === false ? 'غير معلوم' : '—'}</span>}</td>
                      <td className="num">{diff !== null && Math.abs(diff) > 0.0005 ? <Badge kind="warn">{fmtAmount(String(diff))}</Badge> : ''}</td>
                    </>}
                    <td className="actions">
                      {(can('P08a', 'add') || can('P08a', 'edit')) && <button className="btn link" onClick={() => setEdit(r)}>{r.source ? 'تعديل' : 'إضافة'}</button>}
                      <Link className="small" to={`/statement?customer=${r.customer_id}`}>الكشف</Link>
                    </td>
                  </tr>
                );
              })}
            </tbody></table></div>
          {rows.length > 500 && <p className="small muted">يعرض أول 500؛ ضيّق البحث، والتصدير والقالب يشملان كامل النطاق.</p>}
          {data.batches.length > 0 && (
            <div className="panel" style={{ marginTop: 12 }}>
              <h3>دفعات الاستيراد لسنة {year}</h3>
              <div className="tbl" style={{ marginTop: 8 }}><table><thead><tr><th>#</th><th>الملف</th><th>التاريخ</th><th>بواسطة</th><th>النتيجة</th><th>الحالة</th><th></th></tr></thead>
                <tbody>{data.batches.map((b) => (
                  <tr key={b.id}><td className="num">{b.id}</td><td>{b.file_name}</td><td className="num">{fmtDateTime(b.created_at)}</td><td>{b.created_by_name}</td>
                    <td className="small">أضيف {b.summary.added ?? 0} · استبدل {b.summary.replaced ?? 0} · أبقي {b.summary.kept ?? 0} · أخطاء {b.summary.errors ?? 0}</td>
                    <td>{b.status === 'deleted' ? <Badge kind="bad">محذوفة: {b.delete_reason}</Badge> : <Badge kind="ok">فعالة</Badge>}</td>
                    <td>{b.status === 'active' && can('P08a', 'edit') && <button className="btn link" onClick={() => setDelBatch(b)}>حذف الدفعة</button>}</td></tr>
                ))}</tbody></table></div>
            </div>
          )}
        </>
      )}
      {edit && <EditOpening row={edit} year={year} onClose={() => setEdit(null)} onDone={() => { setEdit(null); setVer(ver + 1); }} />}
      {importing && <ImportOpenings year={year} onClose={() => setImporting(false)} onDone={() => { setImporting(false); setVer(ver + 1); }} />}
      {closing && <YearClose year={year} onClose={() => setClosing(false)} onDone={() => { setClosing(false); setVer(ver + 1); }} />}
      {delBatch && <DeleteBatch batch={delBatch} onClose={() => setDelBatch(null)} onDone={() => { setDelBatch(null); setVer(ver + 1); }} />}
    </>
  );
}

export function EditOpening({ row, year, onClose, onDone }: {
  row: { customer_id: number; customer_number: string; name: string; debit: string | null; credit: string | null }; year: number;
  onClose: () => void; onDone: () => void;
}) {
  const [debit, setDebit] = useState(row.debit ?? '');
  const [credit, setCredit] = useState(row.credit ?? '');
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const nd = debit.trim() === '' ? null : Number(debit);
  const nc = credit.trim() === '' ? null : Number(credit);
  const save = () => run(async () => {
    if ((debit.trim() && Number.isNaN(nd)) || (credit.trim() && Number.isNaN(nc))) throw new Error('المبلغ رقم غير سالب');
    await guarded((code) => rpc('save_opening', { p_customer: row.customer_id, p_year: year, p_debit: nd, p_credit: nc, p_reason: reason || null, p_code: code }));
    onDone();
  });
  const before = row.debit === null ? 'غير محدد' : `مدين ${fmtAmount(row.debit)} / دائن ${fmtAmount(row.credit)}`;
  const after = nd === null && nc === null ? 'لا تغيير' : `مدين ${fmtAmount(String(nd ?? 0))} / دائن ${fmtAmount(String(nc ?? 0))}`;
  return (
    <Modal title={`الرصيد الافتتاحي ${year} — ${row.customer_number} ${row.name}`} onClose={onClose} footer={<>
      <button className="btn primary" disabled={busy || (nd === null && nc === null)} onClick={save}>اعتماد</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>القيمة الجديدة تستبدل السابقة ولا تُجمع معها، وتاريخ أثرها 1/1/{year}. للتصفير أدخل صفرًا صريحًا؛ الخانة الفارغة مع رقم في الأخرى تعد صفرًا.</Msg>
      <div className="grid2">
        <Field label="مدين — على العميل"><input inputMode="decimal" value={debit} onChange={(e) => setDebit(e.target.value)} /></Field>
        <Field label="دائن — للعميل"><input inputMode="decimal" value={credit} onChange={(e) => setCredit(e.target.value)} /></Field>
      </div>
      <Field label="السبب (اختياري)"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <p className="small">السابق: <strong>{before}</strong> ← الجديد: <strong>{after}</strong></p>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

interface PlanRow {
  row: number; customer_number: string | null; customer_name: string | null; customer_id: number | null; status: string; errors: string[];
  note: string | null; debit: string | null; credit: string | null; current: { debit: string; credit: string; source: string } | null;
}
const STATUS: Record<string, [string, 'ok' | 'warn' | 'bad' | 'accent' | undefined]> = {
  new: ['جديد', 'ok'], same: ['مطابق', undefined], changed: ['مختلف', 'warn'], manual_conflict: ['تعارض مع يدوي', 'accent'],
  blank: ['فارغ: يبقى المحفوظ', undefined], error: ['خطأ', 'bad'],
};

function ImportOpenings({ year, onClose, onDone }: { year: number; onClose: () => void; onDone: () => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [plan, setPlan] = useState<PlanRow[] | null>(null);
  const [accept, setAccept] = useState<Set<string>>(new Set());
  const [result, setResult] = useState<Record<string, number> | null>(null);
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const fileYear = file?.name.match(/(20\d{2})/)?.[1];

  const pick = (f: File | null) => run(async () => {
    setFile(f); setPlan(null); setResult(null);
    if (!f) return;
    const s = await readSheet(f);
    const miss = missingHeaders(s, HEADERS);
    if (miss.length) throw new Error('أعمدة القالب غير موجودة: ' + miss.join('، '));
    const r = s.rows.map((x) => ({ row: String(x.row), customer_number: x.cells[HEADERS[0]], customer_name: x.cells[HEADERS[1]], debit: x.cells[HEADERS[2]], credit: x.cells[HEADERS[3]] }));
    setRows(r);
    const p = await rpc<{ rows: PlanRow[] }>('preview_opening_import', { p_year: year, p_rows: r });
    setPlan(p.rows); setAccept(new Set());
  });
  const commit = () => run(async () => {
    const r = await guarded((code) => rpc<Record<string, number>>('commit_opening_import', { p_year: year, p_rows: rows, p_accept: [...accept], p_file_name: file?.name ?? null, p_code: code }));
    setResult(r);
  });
  const counts = (plan ?? []).reduce<Record<string, number>>((m, r) => ({ ...m, [r.status]: (m[r.status] ?? 0) + 1 }), {});
  return (
    <Modal title={`استيراد افتتاحيات ${year}`} wide onClose={result ? onDone : onClose} footer={result
      ? <button className="btn primary" onClick={onDone}>تم</button>
      : <><button className="btn primary" disabled={busy || !plan} onClick={commit}>اعتماد الاستيراد</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      {result ? (
        <Msg kind="ok">اكتمل: أضيف {result.added}، استبدل {result.replaced}، أبقي {result.kept}، مطابق {result.same}، فارغ {result.blank}، أخطاء {result.errors} (الدفعة {result.batch_id}).</Msg>
      ) : (
        <>
          <Msg>المطابقة برقم العميل وسنة {year} المختارة في الواجهة. الجديد يضاف، والمختلف والمتعارض مع تعديل يدوي لا يُستبدلان إلا بتحديدهما صراحة، والأخطاء تبقي المحفوظ.</Msg>
          <Field label="ملف القالب (xlsx/xls)"><input type="file" accept=".xlsx,.xls" onChange={(e) => pick(e.target.files?.[0] ?? null)} /></Field>
          {fileYear && Number(fileYear) !== year && <Msg kind="bad">اسم الملف يذكر سنة {fileYear} والسنة المختارة {year}؛ تحقق قبل الاعتماد. السنة تؤخذ من الواجهة لا من اسم الملف.</Msg>}
          {plan && (
            <>
              <p className="small">{Object.entries(counts).map(([k, n]) => `${STATUS[k][0]}: ${n}`).join(' · ')}</p>
              <div className="tbl" style={{ maxHeight: 420, overflow: 'auto' }}><table>
                <thead><tr><th>الصف</th><th>العميل</th><th>الحالة</th><th className="num">المحفوظ</th><th className="num">الملف</th><th>ملاحظة</th></tr></thead>
                <tbody>{plan.map((r) => (
                  <tr key={r.row} className={r.status === 'changed' || r.status === 'manual_conflict' ? 'diff-new' : ''}>
                    <td className="num">{r.row}</td>
                    <td><span className="num">{r.customer_number}</span> {r.customer_name}</td>
                    <td><Badge kind={STATUS[r.status][1]}>{STATUS[r.status][0]}</Badge>
                      {(r.status === 'changed' || r.status === 'manual_conflict') && (
                        <label className="small" style={{ display: 'block' }}><input type="checkbox" checked={accept.has(r.customer_number!)}
                          onChange={() => setAccept((s) => { const n = new Set(s); if (n.has(r.customer_number!)) n.delete(r.customer_number!); else n.add(r.customer_number!); return n; })} /> اعتماد قيمة الملف</label>
                      )}</td>
                    <td className="num">{r.current ? `${fmtAmount(r.current.debit)} / ${fmtAmount(r.current.credit)}` : '—'}</td>
                    <td className="num">{r.debit !== null ? `${fmtAmount(r.debit)} / ${fmtAmount(r.credit)}` : ''}</td>
                    <td className="small">{[...r.errors, r.note].filter(Boolean).join('؛ ')}</td>
                  </tr>
                ))}</tbody></table></div>
            </>
          )}
        </>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

interface BatchItem { customer_id: number; customer_number: string; customer_name: string; before: { debit: string; credit: string } | null; after: { debit: string; credit: string }; current: { debit: string; credit: string } | null; conflict: boolean }

function DeleteBatch({ batch, onClose, onDone }: { batch: Batch; onClose: () => void; onDone: () => void }) {
  const [items, setItems] = useState<BatchItem[] | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { run(async () => setItems((await rpc<{ items: BatchItem[] }>('preview_delete_opening_batch', { p_batch: batch.id })).items)); }, [batch.id]);
  const del = () => run(async () => {
    await guarded((code) => rpc('delete_opening_batch', { p_batch: batch.id, p_reason: reason, p_code: code }));
    onDone();
  });
  const v = (x: { debit: string; credit: string } | null) => (x ? `${fmtAmount(x.debit)} / ${fmtAmount(x.credit)}` : 'غير محدد');
  return (
    <Modal title={`حذف دفعة الافتتاحيات ${batch.id}`} wide onClose={onClose} footer={<>
      <button className="btn danger" disabled={busy || !reason.trim() || !items} onClick={del}>حذف الدفعة والتراجع عن أثرها</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>يعود كل رصيد غيّرته الدفعة إلى ما قبلها؛ الرصيد الذي تغيّر بعدها يبقى كما هو (FIN-008).</Msg>
      {items && (
        <div className="tbl" style={{ maxHeight: 360, overflow: 'auto' }}><table><thead><tr><th>العميل</th><th className="num">قبل الدفعة</th><th className="num">من الدفعة</th><th className="num">الحالي</th><th>النتيجة</th></tr></thead>
          <tbody>{items.map((i) => (
            <tr key={i.customer_id}><td><span className="num">{i.customer_number}</span> {i.customer_name}</td><td className="num">{v(i.before)}</td><td className="num">{v(i.after)}</td><td className="num">{v(i.current)}</td>
              <td>{i.conflict ? <Badge kind="warn">تغير بعد الدفعة: يبقى</Badge> : <Badge kind="ok">يعود لما قبلها</Badge>}</td></tr>
          ))}</tbody></table></div>
      )}
      <Field label="سبب الحذف"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

interface CloseRow { customer_id: number; customer_number: string; name: string; known: boolean; closing: string | null; next: { debit: string; credit: string; source: string } | null; diff: string | null }

function YearClose({ year, onClose, onDone }: { year: number; onClose: () => void; onDone: () => void }) {
  const [rows, setRows] = useState<CloseRow[] | null>(null);
  const [closed, setClosed] = useState<{ closed_at: string } | null>(null);
  const [replace, setReplace] = useState<Set<string>>(new Set());
  const [reason, setReason] = useState('');
  const [result, setResult] = useState<{ added: number; replaced: number; kept: number } | null>(null);
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { run(async () => { const p = await rpc<{ rows: CloseRow[]; closed: { closed_at: string } | null }>('preview_year_close', { p_year: year }); setRows(p.rows); setClosed(p.closed); }); }, [year]);
  const unknown = (rows ?? []).filter((r) => !r.known);
  const diffs = (rows ?? []).filter((r) => r.diff !== null && Math.abs(Number(r.diff)) > 0.0005);
  const commit = () => run(async () => {
    setResult(await guarded((code) => rpc<{ added: number; replaced: number; kept: number }>('commit_year_close', { p_year: year, p_replace: [...replace], p_reason: reason || null, p_code: code })));
  });
  return (
    <Modal title={`إغلاق السنة المالية ${year}`} wide onClose={result ? onDone : onClose} footer={result
      ? <button className="btn primary" onClick={onDone}>تم</button>
      : <><button className="btn primary" disabled={busy || !rows || unknown.length > 0 || (replace.size > 0 && !reason.trim())} onClick={commit}>اعتماد الإغلاق والترحيل</button>
          <button className="btn" onClick={onClose}>إلغاء</button></>}>
      {result ? <Msg kind="ok">رُحّل {result.added} رصيدًا افتتاحيًا إلى {year + 1}، واستبدل {result.replaced}، وأبقي {result.kept} مختلفًا كما هو.</Msg> : (
        <>
          <Msg>إقفال كل عميل في 31/12/{year} يصبح افتتاحه في 1/1/{year + 1}؛ لا يضاف الدين القديم فوق الافتتاحي مرة ثانية. الافتتاحي المسجل المختلف يبقى ما لم تختر استبداله بسبب (B038). إغلاق السنة المالية مستقل عن إغلاق أشهر العمولة.</Msg>
          {closed && <Msg>سبق إغلاق هذه السنة؛ إعادة الإغلاق ترحّل غير المرحّل وتعرض الفروق دون استبدال صامت.</Msg>}
          {unknown.length > 0 && <Msg kind="bad">لا يغلق العام: افتتاح {year} غير محدد لـ{unknown.length} حساب ({unknown.slice(0, 8).map((r) => r.customer_number).join('، ')}).</Msg>}
          {rows && (
            <>
              <p className="small">الحسابات: <span className="num">{rows.length}</span> · الفروق مع افتتاح {year + 1} المسجل: <span className="num">{diffs.length}</span></p>
              <div className="tbl" style={{ maxHeight: 400, overflow: 'auto' }}><table>
                <thead><tr><th>العميل</th><th className="num">إقفال {year}</th><th className="num">افتتاح {year + 1} المسجل</th><th className="num">الفرق</th><th>الإجراء</th></tr></thead>
                <tbody>{rows.map((r) => {
                  const hasDiff = r.diff !== null && Math.abs(Number(r.diff)) > 0.0005;
                  return (
                    <tr key={r.customer_id} className={hasDiff ? 'diff-new' : ''}>
                      <td><span className="num">{r.customer_number}</span> {r.name}</td>
                      <td className="num">{r.closing !== null ? fmtAmount(r.closing) : 'غير معلوم'}</td>
                      <td className="num">{r.next ? `${fmtAmount(String(Number(r.next.debit) - Number(r.next.credit)))} (${SOURCE[r.next.source]})` : '—'}</td>
                      <td className="num">{hasDiff ? fmtAmount(r.diff) : ''}</td>
                      <td className="small">{!r.next ? 'يُرحّل' : hasDiff
                        ? <label><input type="checkbox" checked={replace.has(r.customer_number)} onChange={() => setReplace((s) => { const n = new Set(s); if (n.has(r.customer_number)) n.delete(r.customer_number); else n.add(r.customer_number); return n; })} /> استبدال بالإقفال</label>
                        : 'مطابق'}</td>
                    </tr>
                  );
                })}</tbody></table></div>
              {replace.size > 0 && <Field label="سبب استبدال الافتتاحي المختلف"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
            </>
          )}
        </>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
