// P06 — الفواتير والمرتجعات والتحصيلات (INV-007/008، RET-003/004، COL-005/006، TXN-001..004)
// وجهات مستقلة بفلاتر الفترة والرقم والعميل والمندوب والحالة، وملخص لكامل النتائج، وتفاصيل جانبية،
// وتعديل كامل ونقل فردي أو جماعي وحذف وتصدير المعروض أو فترة مستقلة.
import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, fmtQty, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { DocData, isKind, Kind, KINDS, kindDef, PAY_METHODS, PAY_TYPES, SOURCE_LABELS } from '../lib/docs';
import { DataTable, Column } from '../components/DataTable';
import { Badge, Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { DocDiff, DocEditor } from '../components/DocEditor';
import { AuditList } from './Settings';
import { DeleteDocModal, UploadLink } from './Upload';

export interface DocRow {
  id: number; kind: Kind; doc_number: string; customer_number: string; doc_date: string; customer_id: number; customer_name: string;
  employee_id: number; employee_number: string; employee_name: string; pay_type: string | null; lat: string | null; lng: string | null;
  has_location: boolean; net_sales: string; net_promotions: string; total: string; quantity: string | null; bonus: string;
  line_count: number; pay_methods: string | null; cheque_numbers: string | null; manual_edit: boolean; version: number;
  created_batch_id: number | null; last_batch_id: number | null; key_changed: boolean;
  orig_doc_number: string; orig_customer_number: string; orig_doc_date: string;
  [k: string]: unknown;
}

interface Summary { count: number; customers: number; net_sales: string; net_promotions: string; total: string; quantity: string | null; bonus: string }
type Filters = Record<string, string>;

const search = (kind: Kind, f: Filters, sort: string | null, asc: boolean, offset: number, limit: number | null) =>
  rpc<{ rows: DocRow[]; summary: Summary }>('docs_search', { p_kind: kind, p_filters: f, p_sort: sort, p_asc: asc, p_offset: offset, p_limit: limit });

export function Transactions() {
  const { can } = useAuth();
  const [params, setParams] = useSearchParams();
  const kind: Kind = isKind(params.get('kind')) ? (params.get('kind') as Kind) : 'invoice';
  const [filters, setFilters] = useState<Filters>({});
  const [summary, setSummary] = useState<Summary | null>(null);
  const [pageRows, setPageRows] = useState<DocRow[]>([]);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [open, setOpen] = useState<number | null>(null);
  const [transfer, setTransfer] = useState<number[] | null>(null);
  const [exporting, setExporting] = useState(false);
  const [more, setMore] = useState(false);
  const [ver, setVer] = useState(0);
  const selAll = useAction();

  useEffect(() => { setFilters({}); setSelected(new Set()); setOpen(null); }, [kind]);
  // فتح سند من رابط (كشف الحساب والذمم): ?kind=…&open=ID
  useEffect(() => {
    const id = Number(params.get('open'));
    if (id) { setOpen(id); setParams({ kind }, { replace: true }); }
  }, [params, kind, setParams]);
  const [classes, setClasses] = useState<Record<number, string>>({});
  const setF = (k: string, v: string) => { setFilters((o) => ({ ...o, [k]: v })); setSelected(new Set()); };
  const k = kindDef(kind);
  const isCol = kind === 'collection';

  const toggle = (id: number) => setSelected((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  const selectAllResults = () => selAll.run(async () => {
    const r = await search(kind, filters, null, true, 0, null);
    setSelected(new Set(r.rows.map((x) => x.id)));
  });

  const columns: Column<DocRow>[] = useMemo(() => {
    const c: Column<DocRow>[] = [];
    if (can('P06', 'transfer')) c.push({ key: 'sel', label: '', render: (r) => (
      <input type="checkbox" aria-label={`تحديد ${r.doc_number}`} checked={selected.has(r.id)} onClick={(e) => e.stopPropagation()} onChange={() => toggle(r.id)} />
    ) });
    c.push(
      { key: 'doc_number', label: 'الرقم', sortable: true, num: true },
      { key: 'doc_date', label: 'التاريخ', sortable: true, render: (r) => <span className="num">{fmtDate(r.doc_date)}</span> },
      { key: 'customer_name', label: 'العميل', sortable: true, render: (r) => <><span className="num">{r.customer_number}</span> — {r.customer_name}</> },
      { key: 'employee_name', label: isCol ? 'المندوب/المحصل' : 'المندوب', sortable: true, render: (r) => <>{r.employee_name} <span className="muted small num">{r.employee_number}</span></> },
    );
    if (kind === 'invoice') c.push({ key: 'pay_type', label: 'نقدي/ذمم', sortable: true, render: (r) => (r.pay_type === 'فاتورة ذمم' ? 'ذمم' : r.pay_type === 'فاتورة نقدي' ? 'نقدي' : '—') });
    if (isCol) {
      c.push(
        { key: 'pay_methods', label: 'الدفع', sortable: true },
        { key: 'cheque_numbers', label: 'رقم الشيك', render: (r) => <span className="num">{r.cheque_numbers ?? ''}</span> },
        { key: 'line_count', label: 'الأجزاء', num: true, sortable: true },
        { key: 'total', label: 'الإجمالي', num: true, sortable: true, render: (r) => fmtAmount(r.total) },
      );
    } else {
      c.push(
        { key: 'net_sales', label: 'المباشر', num: true, sortable: true, render: (r) => fmtAmount(r.net_sales) },
        { key: 'net_promotions', label: 'العروض', num: true, sortable: true, render: (r) => fmtAmount(r.net_promotions) },
        { key: 'total', label: 'الإجمالي', num: true, sortable: true, render: (r) => fmtAmount(r.total) },
        { key: 'quantity', label: 'الكمية', num: true, sortable: true, render: (r) => fmtQty(r.quantity) },
        { key: 'bonus', label: 'البونص', num: true, sortable: true, render: (r) => fmtQty(r.bonus) },
      );
      if (kind === 'invoice') c.push({ key: 'has_location', label: 'الموقع', render: (r) => (r.has_location
        ? <a href={`https://www.google.com/maps?q=${r.lat},${r.lng}`} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>فتح</a>
        : <span className="muted small">غير متوفر</span>) });
      if (kind === 'return') c.push({ key: 'class', label: 'التصنيف المالي', render: (r) => <ReturnClass cls={classes[r.id]} /> });
    }
    c.push({ key: 'manual_edit', label: '', render: (r) => (r.manual_edit ? <Badge kind="accent">معدل يدويًا</Badge> : null) });
    return c;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind, selected, can, classes]);

  return (
    <>
      <div className="page-head">
        <h1>{k.plural}</h1>
        <div className="actions">
          {can('P05', 'import') && <UploadLink kind={kind} />}
          {can('P06', 'export') && <button className="btn" onClick={() => setExporting(true)}>تصدير Excel</button>}
        </div>
      </div>
      <div className="tabs" role="tablist" style={{ marginBottom: 10 }}>
        {KINDS.map((x) => (
          <button key={x.kind} role="tab" aria-selected={kind === x.kind} onClick={() => setParams({ kind: x.kind })}>{x.plural}</button>
        ))}
      </div>
      <div className="filters">
        <label className="small muted">من <input className="input" type="date" value={filters.from ?? ''} onChange={(e) => setF('from', e.target.value)} aria-label="من تاريخ" /></label>
        <label className="small muted">إلى <input className="input" type="date" value={filters.to ?? ''} onChange={(e) => setF('to', e.target.value)} aria-label="إلى تاريخ" /></label>
        <input className="input" placeholder="رقم السند" value={filters.number ?? ''} onChange={(e) => setF('number', e.target.value)} aria-label="رقم السند" />
        <input className="input" placeholder="العميل: رقمه أو اسمه" value={filters.customer ?? ''} onChange={(e) => setF('customer', e.target.value)} aria-label="العميل" />
        <input className="input" placeholder={isCol ? 'المندوب/المحصل' : 'المندوب'} value={filters.employee ?? ''} onChange={(e) => setF('employee', e.target.value)} aria-label="المندوب" />
        {kind === 'invoice' && (
          <select className="input" value={filters.pay_type ?? ''} onChange={(e) => setF('pay_type', e.target.value)} aria-label="نوع الفاتورة">
            <option value="">نقدي وذمم</option>{PAY_TYPES.map((p) => <option key={p}>{p}</option>)}
          </select>
        )}
        {isCol && (
          <select className="input" value={filters.pay_method ?? ''} onChange={(e) => setF('pay_method', e.target.value)} aria-label="الدفع">
            <option value="">كل طرق الدفع</option>{PAY_METHODS.map((p) => <option key={p}>{p}</option>)}
          </select>
        )}
        <button className="btn link" onClick={() => setMore(!more)} aria-expanded={more}>{more ? 'إخفاء الفلاتر الإضافية' : 'فلاتر إضافية'}</button>
        {Object.values(filters).some(Boolean) && <button className="btn link" onClick={() => { setFilters({}); setSelected(new Set()); }}>مسح الفلاتر</button>}
      </div>
      {more && (
        <div className="filters">
          <input className="input" placeholder="رقم دفعة الرفع" inputMode="numeric" value={filters.batch ?? ''} onChange={(e) => setF('batch', e.target.value.replace(/\D/g, ''))} aria-label="دفعة الرفع" />
          <select className="input" value={filters.manual ?? ''} onChange={(e) => setF('manual', e.target.value)} aria-label="التعديل اليدوي">
            <option value="">المعدل وغير المعدل</option><option value="yes">معدل يدويًا</option><option value="no">غير معدل</option>
          </select>
          {kind === 'invoice' && (
            <select className="input" value={filters.location ?? ''} onChange={(e) => setF('location', e.target.value)} aria-label="الموقع">
              <option value="">بموقع وبدونه</option><option value="yes">له موقع</option><option value="no">بلا موقع</option>
            </select>
          )}
          {isCol && <input className="input" placeholder="رقم الشيك" value={filters.cheque ?? ''} onChange={(e) => setF('cheque', e.target.value)} aria-label="رقم الشيك" />}
        </div>
      )}
      {summary && (
        <div className="stats" aria-label="ملخص كامل النتائج">
          <div className="stat"><div className="l">عدد {k.plural}</div><div className="v num">{summary.count}</div></div>
          <div className="stat"><div className="l">العملاء</div><div className="v num">{summary.customers}</div></div>
          {!isCol && <div className="stat"><div className="l">المباشر</div><div className="v num">{fmtAmount(summary.net_sales)}</div></div>}
          {!isCol && <div className="stat"><div className="l">العروض</div><div className="v num">{fmtAmount(summary.net_promotions)}</div></div>}
          <div className="stat"><div className="l">الإجمالي</div><div className="v num">{fmtAmount(summary.total)}</div></div>
          {!isCol && <div className="stat"><div className="l">الكمية</div><div className="v num">{fmtQty(summary.quantity)}</div></div>}
          {!isCol && <div className="stat"><div className="l">البونص</div><div className="v num">{fmtQty(summary.bonus)}</div></div>}
        </div>
      )}
      {can('P06', 'transfer') && (
        <div className="actions" style={{ marginBottom: 8, alignItems: 'center' }}>
          <span className="small muted">المحدد: <span className="num">{selected.size}</span></span>
          <button className="btn" disabled={selAll.busy} onClick={selectAllResults}>تحديد جميع نتائج البحث</button>
          {selected.size > 0 && <button className="btn link" onClick={() => setSelected(new Set())}>إلغاء التحديد</button>}
          <button className="btn primary" disabled={!selected.size} onClick={() => setTransfer([...selected])}>نقل المحدد إلى موظف</button>
          {selAll.error && <span className="small" style={{ color: 'var(--bad)' }}>{selAll.error}</span>}
        </div>
      )}
      <DataTable<DocRow> columns={columns} rowKey={(r) => r.id} deps={[kind, filters, ver]} initialSort="doc_date" onRowClick={(r) => setOpen(r.id)}
        fetcher={async (q) => {
          const r = await search(kind, filters, q.sort, q.asc, q.page * q.pageSize, q.pageSize);
          setSummary(r.summary); setPageRows(r.rows);
          if (kind === 'return' && r.rows.length) {
            rpc<Record<number, string>>('return_classes_for', { p_doc_ids: r.rows.map((x) => x.id) }).then(setClasses).catch(() => setClasses({}));
          }
          return { rows: r.rows, count: r.summary.count };
        }} />
      {open && <DocFile id={open} kind={kind} onClose={() => setOpen(null)} onChanged={() => setVer(ver + 1)} onTransfer={(id) => setTransfer([id])} />}
      {transfer && <TransferModal ids={transfer} onClose={() => setTransfer(null)} onDone={() => { setTransfer(null); setSelected(new Set()); setVer(ver + 1); }} />}
      {exporting && <ExportModal kind={kind} pageRows={pageRows} onClose={() => setExporting(false)} />}
    </>
  );
}

// تصنيف المرتجع نقديًا أو ذممًا وفق الرصيد السابق (RET-005)
function ReturnClass({ cls }: { cls?: string }) {
  if (cls === 'credit') return <Badge kind="accent">ذمم</Badge>;
  if (cls === 'cash') return <Badge>نقدي</Badge>;
  if (cls === 'unknown') return <Badge kind="warn">غير مصنف</Badge>;
  return <span className="muted small">—</span>;
}

// ---------------------------------------------------------------------
// تفاصيل السند: البنود أو الأجزاء، والمصدر والإصدارات، وسجل التعديلات
// ---------------------------------------------------------------------
interface LineRow {
  id: number; line_no: number; item_number: string | null; item_name: string | null; net_sales: string | null; net_promotions: string | null;
  line_total: string | null; quantity: string | null; bonus: string | null; lat: string | null; lng: string | null;
  amount: string | null; pay_method: string | null; cheque_no: string | null; src_row: number | null;
  sale_price: string | null; equivalent_qty: string | null;
}
interface Version { version: number; source: string; batch_id: number | null; file_name: string | null; status: string; at: string; by_name: string | null; reason: string | null; employee_number: string; data: DocData }

function DocFile({ id, kind, onClose, onChanged, onTransfer }: { id: number; kind: Kind; onClose: () => void; onChanged: () => void; onTransfer: (id: number) => void }) {
  const { can } = useAuth();
  const [tab, setTab] = useState('lines');
  const [doc, setDoc] = useState<DocRow | null>(null);
  const [lines, setLines] = useState<LineRow[]>([]);
  const [hist, setHist] = useState<Version[]>([]);
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [ver, setVer] = useState(0);
  const load = useAction();
  const isCol = kind === 'collection';

  useEffect(() => {
    load.run(async () => {
      const { data, error } = await sb().from('docs_v').select('*').eq('id', id).maybeSingle();
      if (error) throw new Error(error.message);
      if (!data) throw new Error('السند غير موجود أو حُذف');
      setDoc(data as DocRow);
      const l = await sb().from('doc_lines_v').select('*').eq('doc_id', id).order('line_no');
      setLines((l.data ?? []) as LineRow[]);
      setHist(await rpc<Version[]>('doc_history', { p_doc: id }));
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, ver]);

  const changed = () => { setVer(ver + 1); onChanged(); };
  const title = doc ? `${kindDef(kind).one} ${doc.doc_number}` : kindDef(kind).one;

  return (
    <Drawer title={title} onClose={onClose}
      actions={doc && <>
        {can('P06', 'edit') && <button className="btn" onClick={() => setEditing(true)}>تعديل</button>}
        {can('P06', 'transfer') && <button className="btn" onClick={() => onTransfer(doc.id)}>نقل</button>}
        {can('P06', 'delete') && <button className="btn danger" onClick={() => setDeleting(true)}>حذف</button>}
      </>}>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {doc && (
        <>
          <div className="panel">
            <dl className="kv">
              <dt>رقم السند</dt><dd className="num">{doc.doc_number}</dd>
              <dt>التاريخ</dt><dd className="num">{fmtDate(doc.doc_date)}</dd>
              <dt>العميل</dt><dd><span className="num">{doc.customer_number}</span> — {doc.customer_name}</dd>
              <dt>{isCol ? 'المندوب/المحصل' : 'المندوب'}</dt><dd>{doc.employee_name} <span className="num muted">{doc.employee_number}</span></dd>
              {kind === 'invoice' && <><dt>النوع</dt><dd>{doc.pay_type}</dd></>}
              {isCol ? <><dt>الدفع</dt><dd>{doc.pay_methods}{doc.cheque_numbers ? ` — شيك ${doc.cheque_numbers}` : ''}</dd></> : <>
                <dt>المباشر</dt><dd className="num">{fmtAmount(doc.net_sales)}</dd><dt>العروض</dt><dd className="num">{fmtAmount(doc.net_promotions)}</dd>
                <dt>الكمية</dt><dd className="num">{fmtQty(doc.quantity)}</dd><dt>البونص</dt><dd className="num">{fmtQty(doc.bonus)}</dd></>}
              <dt>الإجمالي</dt><dd className="num"><b>{fmtAmount(doc.total)}</b></dd>
              {kind === 'invoice' && <><dt>موقع الإصدار</dt><dd>{doc.has_location
                ? <a href={`https://www.google.com/maps?q=${doc.lat},${doc.lng}`} target="_blank" rel="noreferrer">فتح الموقع</a>
                : <span className="muted">غير متوفر في المصدر؛ لا يمنع الأثر المالي</span>}</dd></>}
              {doc.key_changed && <><dt>المفتاح الأصلي</dt><dd className="num">{doc.orig_doc_number} / {doc.orig_customer_number} / {fmtDate(doc.orig_doc_date)}</dd></>}
              <dt>الحالة</dt><dd>{doc.manual_edit ? <Badge kind="accent">معدل يدويًا — محمي من إعادة الرفع</Badge> : <Badge>كما في آخر رفع</Badge>}</dd>
            </dl>
          </div>
          <div className="tabs" role="tablist">
            {[['lines', isCol ? 'الأجزاء' : 'البنود'], ['versions', 'المصدر والإصدارات'], ['log', 'سجل التعديلات']].map(([t, l]) => (
              <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}>{l}</button>
            ))}
          </div>
          {tab === 'lines' && (isCol ? (
            <div className="tbl"><table>
              <thead><tr><th>#</th><th>القيمة</th><th>الدفع</th><th>رقم الشيك</th><th>صف المصدر</th></tr></thead>
              <tbody>
                {lines.map((l) => (
                  <tr key={l.id} className={Number(l.amount) === 0 ? 'zero' : ''}>
                    <td className="num">{l.line_no}</td>
                    <td className="num">{fmtAmount(l.amount)}{Number(l.amount) === 0 && <> <Badge kind="warn">صفر</Badge></>}</td>
                    <td>{l.pay_method}</td><td className="num">{l.cheque_no}</td><td className="num">{l.src_row}</td>
                  </tr>
                ))}
                <tr><td colSpan={1}><b>المجموع</b></td><td className="num"><b>{fmtAmount(doc.total)}</b></td><td colSpan={3} className="small muted">يظهر السند مرة واحدة بمجموع أجزائه (COL-002/003)</td></tr>
              </tbody></table></div>
          ) : (
            <div className="tbl"><table>
              <thead><tr><th>الصنف</th><th>المباشر</th><th>العروض</th><th>الإجمالي</th><th>Quantity</th><th>البونص</th><th>الكمية المكافئة</th><th>السعر التاريخي</th></tr></thead>
              <tbody>{lines.map((l) => (
                <tr key={l.id}>
                  <td><span className="num">{l.item_number}</span> — {l.item_name}</td>
                  <td className="num">{fmtAmount(l.net_sales)}</td><td className="num">{fmtAmount(l.net_promotions)}</td>
                  <td className="num">{fmtAmount(l.line_total)}</td><td className="num">{fmtQty(l.quantity)}</td><td className="num">{fmtQty(l.bonus)}</td>
                  <td className="num">{l.equivalent_qty !== null ? fmtQty(roundQty(l.equivalent_qty)) : <span className="muted small">سعر غير متوفر</span>}</td>
                  <td className="num">{l.sale_price !== null && Number(l.sale_price) > 0 ? fmtAmount(l.sale_price) : <span className="muted small">سعر غير متوفر</span>}</td>
                </tr>
              ))}</tbody></table></div>
          ))}
          {tab === 'versions' && (
            <div className="tbl"><table>
              <thead><tr><th>الإصدار</th><th>المصدر</th><th>الملف/الدفعة</th><th>الموظف</th><th>الوقت</th><th>بواسطة</th><th>السبب</th></tr></thead>
              <tbody>{hist.map((h) => (
                <tr key={h.version}>
                  <td className="num">{h.version}{h.version === doc.version && <> <Badge kind="ok">الحالي</Badge></>}</td>
                  <td>{SOURCE_LABELS[h.source] ?? h.source}{h.status === 'deleted' ? ' (محذوف)' : ''}</td>
                  <td>{h.file_name ?? '—'}{h.batch_id ? <span className="muted small num"> #{h.batch_id}</span> : ''}</td>
                  <td className="num">{h.employee_number}</td>
                  <td className="num">{fmtDateTime(h.at)}</td><td>{h.by_name}</td><td className="wrap">{h.reason}</td>
                </tr>
              ))}</tbody></table></div>
          )}
          {tab === 'log' && <AuditList entity="docs" entityId={String(id)} />}
        </>
      )}
      {editing && doc && hist[0] && <EditDoc doc={doc} kind={kind} current={hist.find((h) => h.version === doc.version)?.data ?? hist[0].data}
        onClose={() => setEditing(false)} onSaved={() => { setEditing(false); changed(); }} />}
      {deleting && doc && <DeleteDocModal docId={doc.id} label={title} onClose={() => setDeleting(false)} onDone={() => { setDeleting(false); onChanged(); onClose(); }} />}
    </Drawer>
  );
}

/** الكمية المكافئة للعرض: حتى ثلاث منازل دون أصفار زائدة */
function roundQty(v: string): string {
  const n = Number(v);
  return Number.isFinite(n) ? String(Math.round(n * 1000) / 1000) : v;
}

// ---------------------------------------------------------------------
// التعديل الكامل: الترويسة والبنود ثم مقارنة قبل/بعد ثم الحفظ (TXN-001، B049، AUTH-004)
// ---------------------------------------------------------------------
function EditDoc({ doc, kind, current, onClose, onSaved }: { doc: DocRow; kind: Kind; current: DocData; onClose: () => void; onSaved: () => void }) {
  const [draft, setDraft] = useState<DocData>(() => JSON.parse(JSON.stringify(current)) as DocData);
  const [step, setStep] = useState<'edit' | 'diff'>('edit');
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const save = () => run(async () => {
    await guarded((code) => rpc('save_doc', { p_doc: doc.id, p_data: draft, p_reason: reason || null, p_code: code }));
    onSaved();
  });
  return (
    <Modal title={`تعديل ${kindDef(kind).one} ${doc.doc_number}`} onClose={onClose} wide
      footer={step === 'edit'
        ? <><button className="btn primary" onClick={() => setStep('diff')}>معاينة الفروق</button><button className="btn" onClick={onClose}>إلغاء</button></>
        : <><button className="btn primary" disabled={busy} onClick={save}>حفظ التعديل</button><button className="btn" onClick={() => setStep('edit')}>رجوع للتحرير</button></>}>
      {step === 'edit' ? <DocEditor kind={kind} value={draft} onChange={setDraft} /> : (
        <>
          <DocDiff kind={kind} before={current} after={draft} />
          <Field label="سبب التعديل"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <p className="small muted">التعديل اليدوي يحفظ إصدارًا جديدًا مع بقاء الأصل، ويُحمى عند إعادة رفع الملف حتى تختار صراحة اعتماد بياناته (TXN-003). تصادم المفتاح مع سند آخر يمنع الحفظ.</p>
        </>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// النقل الفردي أو الجماعي إلى موظف آخر بمعاينة العدد والمبلغ (TXN-002)
// ---------------------------------------------------------------------
interface TransferPreview { to: { emp_number: string; name: string }; count: number; already: number; total: string; from: { emp_number: string; name: string; count: number; total: string }[] }

function TransferModal({ ids, onClose, onDone }: { ids: number[]; onClose: () => void; onDone: () => void }) {
  const [emp, setEmp] = useState('');
  const [emps, setEmps] = useState<{ emp_number: string; name: string }[]>([]);
  const [pv, setPv] = useState<TransferPreview | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, setError, run } = useAction();
  const guarded = useGuarded();
  useEffect(() => { sb().from('employees').select('emp_number, name').order('emp_number').limit(2000).then(({ data }) => setEmps(data ?? [])); }, []);
  const preview = () => run(async () => setPv(await rpc<TransferPreview>('preview_transfer', { p_doc_ids: ids, p_employee_number: emp })));
  const go = () => run(async () => {
    await guarded((code) => rpc('transfer_docs', { p_doc_ids: ids, p_employee_number: emp, p_reason: reason || null, p_code: code }));
    onDone();
  });
  return (
    <Modal title={`نقل ${ids.length === 1 ? 'سند' : `${ids.length} سندات`} إلى موظف آخر`} onClose={onClose}
      footer={pv ? <><button className="btn primary" disabled={busy || !pv.count} onClick={go}>تأكيد النقل</button><button className="btn" onClick={() => setPv(null)}>تغيير الموظف</button></>
        : <><button className="btn primary" disabled={busy || !emp.trim()} onClick={preview}>معاينة</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      {!pv ? (
        <Field label="رقم الموظف الجديد">
          <input list="emp-list" value={emp} onChange={(e) => { setEmp(e.target.value); setError(null); }} />
        </Field>
      ) : (
        <>
          <Msg>تنتقل السندات وأثرها كاملًا إلى {pv.to.emp_number} — {pv.to.name}؛ المبالغ ومجموع الشركة ثابتة. نقل التحصيل لا يغير بائع الفواتير التي سددها.</Msg>
          <p>عدد السندات: <b className="num">{pv.count}</b> — المبلغ: <b className="num">{fmtAmount(pv.total)}</b>{pv.already ? <span className="small muted"> ({pv.already} لدى الموظف نفسه أصلًا)</span> : ''}</p>
          <div className="tbl"><table><thead><tr><th>من الموظف</th><th>السندات</th><th>المبلغ</th></tr></thead>
            <tbody>{pv.from.map((f) => <tr key={f.emp_number}><td>{f.emp_number} — {f.name}</td><td className="num">{f.count}</td><td className="num">{fmtAmount(f.total)}</td></tr>)}</tbody></table></div>
          <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        </>
      )}
      <datalist id="emp-list">{emps.map((e) => <option key={e.emp_number} value={e.emp_number}>{e.name}</option>)}</datalist>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// تصدير Excel: الجدول المعروض أو جميع سندات فترة، ملخصًا أو تفاصيل (INV-008، RET-004، COL-006)
// ---------------------------------------------------------------------
function ExportModal({ kind, pageRows, onClose }: { kind: Kind; pageRows: DocRow[]; onClose: () => void }) {
  const [scope, setScope] = useState<'shown' | 'period'>('shown');
  const [shape, setShape] = useState<'summary' | 'detail'>('summary');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [done, setDone] = useState<string | null>(null);
  const { busy, error, run } = useAction();
  const isCol = kind === 'collection';
  const k = kindDef(kind);

  const go = () => run(async () => {
    let rows = pageRows;
    if (scope === 'period') {
      if (!from || !to) throw new Error('حدد الفترة من تاريخ إلى تاريخ');
      rows = (await search(kind, { from, to }, 'doc_date', true, 0, null)).rows;
    }
    const head = ['رقم السند', 'التاريخ', 'رقم العميل', 'العميل', isCol ? 'رقم المندوب' : 'رقم الموظف', isCol ? 'المندوب' : 'الموظف',
      ...(kind === 'invoice' ? ['نوع الفاتورة'] : [])];
    const headVals = (r: DocRow) => [r.doc_number, fmtDate(r.doc_date), r.customer_number, r.customer_name, r.employee_number, r.employee_name,
      ...(kind === 'invoice' ? [r.pay_type] : [])];
    const num = (v: string | null) => (v === null || v === undefined || v === '' ? null : Number(v));
    const label = scope === 'period' ? `${from} إلى ${to}` : `المعروض ${todayIso()}`;
    if (shape === 'summary') {
      const cols = isCol ? ['الدفع', 'رقم الشيك', 'الأجزاء', 'الإجمالي'] : ['المباشر', 'العروض', 'الإجمالي', 'Quantity', 'البونص'];
      writeSheet(`${k.plural} ${label}.xlsx`, k.plural, [...head, ...cols], rows.map((r) => [...headVals(r),
        ...(isCol ? [r.pay_methods, r.cheque_numbers, r.line_count, num(r.total)] : [num(r.net_sales), num(r.net_promotions), num(r.total), num(r.quantity), num(r.bonus)])]));
    } else {
      const lines: (LineRow & { doc_id: number })[] = [];
      const ids = rows.map((r) => r.id);
      for (let i = 0; i < ids.length; i += 200) {
        const { data, error: e } = await sb().from('doc_lines_v').select('*').in('doc_id', ids.slice(i, i + 200)).order('doc_id').order('line_no');
        if (e) throw new Error(e.message);
        lines.push(...((data ?? []) as (LineRow & { doc_id: number })[]));
      }
      const byDoc = new Map(rows.map((r) => [r.id, r]));
      const order = new Map(ids.map((id, i) => [id, i]));
      lines.sort((a, b) => (order.get(a.doc_id)! - order.get(b.doc_id)!) || a.line_no - b.line_no);
      const cols = isCol ? ['القيمة', 'الدفع', 'رقم الشيك'] : ['رقم الصنف', 'اسم الصنف', 'المباشر', 'العروض', 'الإجمالي', 'Quantity', 'البونص', 'Latitude', 'Longitude'];
      writeSheet(`${k.plural} تفاصيل ${label}.xlsx`, k.plural, [...head, ...cols], lines.map((l) => [...headVals(byDoc.get(l.doc_id)!),
        ...(isCol ? [num(l.amount), l.pay_method, l.cheque_no]
          : [l.item_number, l.item_name, num(l.net_sales), num(l.net_promotions), num(l.line_total), num(l.quantity), num(l.bonus), num(l.lat), num(l.lng)])]));
    }
    setDone(`صدر ${rows.length} سند${shape === 'detail' ? ' بكامل بنودها' : ''}.`);
  });

  return (
    <Modal title={`تصدير ${k.plural}`} onClose={onClose}
      footer={<><button className="btn primary" disabled={busy} onClick={go}>{busy ? 'جارٍ التصدير…' : 'تصدير'}</button><button className="btn" onClick={onClose}>إغلاق</button></>}>
      <fieldset className="plain"><legend>النطاق</legend>
        <label className="check"><input type="radio" checked={scope === 'shown'} onChange={() => setScope('shown')} /> الجدول المعروض (<span className="num">{pageRows.length}</span> سند بالفلاتر والترتيب الحاليين)</label>
        <label className="check"><input type="radio" checked={scope === 'period'} onChange={() => setScope('period')} /> جميع {k.plural} فترة حسب تاريخ السند، ضمن صلاحياتك، ولو لم تظهر في الصفحة</label>
      </fieldset>
      {scope === 'period' && (
        <div className="grid2">
          <Field label="من تاريخ"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="إلى تاريخ"><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        </div>
      )}
      {scope === 'period' && <p className="small muted">نطاق الفترة مستقل عن فلاتر الشاشة؛ قد يختلف العدد والمجموع عن المعروض بصورة صحيحة.</p>}
      <fieldset className="plain"><legend>شكل الملف</legend>
        <label className="check"><input type="radio" checked={shape === 'summary'} onChange={() => setShape('summary')} /> ملخص: صف لكل سند</label>
        <label className="check"><input type="radio" checked={shape === 'detail'} onChange={() => setShape('detail')} /> تفاصيل: صف لكل {isCol ? 'جزء' : 'بند'}</label>
      </fieldset>
      {done && <Msg kind="ok">{done}</Msg>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
