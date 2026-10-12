// P02 — العملاء وملف العميل (CUS-001..003، B037، B055، B065، B066)
import { useEffect, useState } from 'react';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, todayIso } from '../lib/format';
import { fetchAll, cleanTerm } from '../lib/query';
import { writeSheet } from '../lib/excel';
import { DataTable, Column } from '../components/DataTable';
import { Drawer, Field, Modal, Msg, Badge, useAction, useGuarded } from '../components/ui';
import { ImportWizard, ChangesTable, Counts, PlanError } from '../components/ImportWizard';
import { AuditList } from './Settings';

export interface CustomerRow {
  id: number; customer_number: string; name: string; company_id: string | null; grace_days: number | null;
  effective_grace_days: number; lat: string | null; lng: string | null;
  master_id: number | null; master_number: string | null; master_name: string | null; kind: string;
  [k: string]: unknown;
}

const HEADERS = ['MasterCustomerName', 'MasterCustomerNumber', 'CustomerName', 'CustomerNumber', 'CompanyID', 'فترة السماح'];

export function Customers() {
  const { can } = useAuth();
  const [term, setTerm] = useState('');
  const [kind, setKind] = useState('');
  const [open, setOpen] = useState<CustomerRow | null>(null);
  const [adding, setAdding] = useState(false);
  const [importing, setImporting] = useState(false);
  const [ver, setVer] = useState(0);
  const exportAct = useAction();

  const build = () => {
    let q = sb().from('customers_v').select('*', { count: 'exact' });
    const t = cleanTerm(term);
    if (t) q = /^\d+$/.test(t) ? q.like('customer_number', `${t}%`) : q.ilike('name', `%${t}%`);
    if (kind) q = q.eq('kind', kind);
    return q;
  };

  const columns: Column<CustomerRow>[] = [
    { key: 'customer_number', label: 'الرقم', sortable: true, num: true },
    { key: 'name', label: 'الاسم', sortable: true },
    { key: 'kind', label: 'النوع', render: (r) => <Badge kind={r.kind === 'فرع' ? 'accent' : r.kind === 'رئيسي' ? 'ok' : undefined}>{r.kind}</Badge> },
    { key: 'master_name', label: 'الرئيسي', render: (r) => (r.master_number ? `${r.master_number} — ${r.master_name}` : '') },
    { key: 'effective_grace_days', label: 'السماح (يوم)', num: true, render: (r) => <>{r.effective_grace_days}{r.grace_days === null && <span className="muted small"> افتراضي</span>}</> },
    { key: 'lat', label: 'الموقع', render: (r) => (r.lat ? <Badge kind="ok">محدد</Badge> : <span className="muted small">—</span>) },
  ];

  const doExport = () => exportAct.run(async () => {
    const rows = await fetchAll<CustomerRow>(() => build().order('customer_number'));
    writeSheet(`العملاء ${todayIso()}.xlsx`, 'العملاء والافرع', HEADERS, rows.map((r) => [
      r.master_number ? r.master_name : r.name, r.master_number ?? r.customer_number, r.name, r.customer_number,
      r.company_id, r.grace_days,
    ]));
  });

  return (
    <>
      <div className="page-head">
        <h1>العملاء</h1>
        <div className="actions">
          {can('P02', 'add') && <button className="btn primary" onClick={() => setAdding(true)}>إضافة عميل</button>}
          {can('P02', 'import') && <button className="btn" onClick={() => setImporting(true)}>استيراد</button>}
          {can('P02', 'export') && <button className="btn" disabled={exportAct.busy} onClick={doExport}>{exportAct.busy ? 'جارٍ التصدير…' : 'تصدير'}</button>}
        </div>
      </div>
      {exportAct.error && <Msg kind="bad">{exportAct.error}</Msg>}
      <div className="filters">
        <input className="input" placeholder="بحث برقم العميل أو اسمه" value={term} onChange={(e) => setTerm(e.target.value)} aria-label="بحث" />
        <select className="input" value={kind} onChange={(e) => setKind(e.target.value)} aria-label="النوع" style={{ minWidth: 120 }}>
          <option value="">كل الأنواع</option><option>رئيسي</option><option>فرع</option><option>مستقل</option>
        </select>
        {(term || kind) && <button className="btn link" onClick={() => { setTerm(''); setKind(''); }}>مسح الفلاتر</button>}
      </div>
      <DataTable<CustomerRow> columns={columns} rowKey={(r) => r.id} deps={[term, kind, ver]} initialSort="customer_number"
        onRowClick={setOpen}
        fetcher={async (q) => {
          let b = build();
          if (q.sort) b = b.order(q.sort, { ascending: q.asc });
          const { data, count, error } = await b.range(q.page * q.pageSize, (q.page + 1) * q.pageSize - 1);
          if (error) throw new Error(error.message);
          return { rows: (data ?? []) as CustomerRow[], count: count ?? 0 };
        }} />
      {open && <CustomerFile id={open.id} onClose={() => setOpen(null)} onChanged={() => setVer(ver + 1)} />}
      {adding && <CustomerForm onClose={() => setAdding(false)} onSaved={() => { setAdding(false); setVer(ver + 1); }} />}
      {importing && <ImportWizard spec={customerImportSpec} onClose={() => setImporting(false)} onDone={() => setVer(ver + 1)} />}
    </>
  );
}

function CustomerForm({ row, onClose, onSaved }: { row?: CustomerRow; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    customer_number: row?.customer_number ?? '', name: row?.name ?? '', company_id: row?.company_id ?? '',
    grace_days: row?.grace_days === null || row?.grace_days === undefined ? '' : String(row.grace_days), master_number: '',
  });
  const { busy, error, run } = useAction();
  const save = () => run(async () => { await rpc('save_customer', { p_id: row?.id ?? null, p: f }); onSaved(); });
  return (
    <Modal title={row ? 'تعديل العميل' : 'إضافة عميل'} onClose={onClose}
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="رقم العميل"><input value={f.customer_number} onChange={(e) => setF({ ...f, customer_number: e.target.value })} /></Field>
        <Field label="اسم العميل"><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <Field label="فترة السماح (يوم)" hint="فارغ = 30 يومًا؛ صفر = الاستحقاق بتاريخ السند">
          <input inputMode="numeric" value={f.grace_days} onChange={(e) => setF({ ...f, grace_days: e.target.value })} /></Field>
        <Field label="CompanyID" hint="يُحفظ كما ورد وغير مفعّل"><input value={f.company_id} onChange={(e) => setF({ ...f, company_id: e.target.value })} /></Field>
        {!row && <Field label="رقم العميل الرئيسي (للفرع)" hint="فارغ = عميل مستقل أو رئيسي"><input value={f.master_number} onChange={(e) => setF({ ...f, master_number: e.target.value })} /></Field>}
      </div>
      {row && <p className="small muted">تعديل فترة السماح يسري على الفواتير الجديدة؛ تطبيقه على القديمة إجراء مستقل بمعاينة (B037). تغيير الرئيسي من تبويب «الفروع والرئيسي».</p>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function CustomerFile({ id, onClose, onChanged }: { id: number; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [tab, setTab] = useState('def');
  const [row, setRow] = useState<CustomerRow | null>(null);
  const [branches, setBranches] = useState<CustomerRow[]>([]);
  const [links, setLinks] = useState<{ master_number: string; master_name: string; valid_from: string | null; valid_to: string | null }[]>([]);
  const [editing, setEditing] = useState(false);
  const [ver, setVer] = useState(0);
  const load = useAction();

  const reload = () => load.run(async () => {
    const { data, error } = await sb().from('customers_v').select('*').eq('id', id).single();
    if (error) throw new Error(error.message);
    setRow(data as CustomerRow);
    const b = await sb().from('customers_v').select('*').eq('master_id', id).order('customer_number');
    setBranches((b.data ?? []) as CustomerRow[]);
    const l = await sb().from('customer_master_links').select('valid_from, valid_to, master:customers!customer_master_links_master_id_fkey(customer_number, name)').eq('customer_id', id).order('valid_from', { nullsFirst: true });
    setLinks(((l.data ?? []) as unknown as { valid_from: string | null; valid_to: string | null; master: { customer_number: string; name: string } }[])
      .map((x) => ({ master_number: x.master.customer_number, master_name: x.master.name, valid_from: x.valid_from, valid_to: x.valid_to })));
  });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { reload(); }, [id, ver]);

  const changed = () => { setVer(ver + 1); onChanged(); };

  return (
    <Drawer title={row ? `${row.customer_number} — ${row.name}` : 'ملف العميل'} onClose={onClose}
      actions={row && can('P02', 'edit') && <button className="btn" onClick={() => setEditing(true)}>تعديل</button>}>
      <div className="tabs" role="tablist">
        {[['def', 'التعريف'], ['branches', 'الفروع والرئيسي'], ['location', 'الموقع'], ['log', 'سجل التعديلات']].map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {row && tab === 'def' && (
        <div className="panel">
          <dl className="kv">
            <dt>رقم العميل</dt><dd className="num">{row.customer_number}</dd>
            <dt>الاسم</dt><dd>{row.name}</dd>
            <dt>النوع</dt><dd>{row.kind}</dd>
            {row.master_number && <><dt>الرئيسي</dt><dd>{row.master_number} — {row.master_name}</dd></>}
            <dt>فترة السماح</dt><dd><span className="num">{row.effective_grace_days}</span> يوم {row.grace_days === null && <span className="muted">(الافتراضي)</span>}</dd>
            <dt>CompanyID</dt><dd>{row.company_id ?? '—'} <span className="muted small">غير مفعّل</span></dd>
          </dl>
          <p className="small muted" style={{ marginTop: 10 }}>الحركات وكشف الحساب وشروط التسديد تُضاف إلى ملف العميل مع وحدتي الحركات والحسابات.</p>
        </div>
      )}
      {row && tab === 'branches' && <BranchesTab row={row} branches={branches} links={links} onChanged={changed} />}
      {row && tab === 'location' && <LocationTab row={row} onChanged={changed} />}
      {tab === 'log' && <AuditList entity="customers" entityId={String(id)} />}
      {editing && row && <CustomerForm row={row} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); changed(); }} />}
    </Drawer>
  );
}

function BranchesTab({ row, branches, links, onChanged }: {
  row: CustomerRow; branches: CustomerRow[];
  links: { master_number: string; master_name: string; valid_from: string | null; valid_to: string | null }[];
  onChanged: () => void;
}) {
  const { can } = useAuth();
  const [changing, setChanging] = useState(false);
  return (
    <>
      <div className="panel">
        <div className="page-head"><h3>الارتباط بالرئيسي عبر الزمن</h3>
          {can('P02', 'edit') && <button className="btn" onClick={() => setChanging(true)}>تغيير الرئيسي</button>}</div>
        {links.length === 0 ? <p className="muted small">لا ارتباط؛ العميل {row.kind}.</p> : (
          <div className="tbl"><table><thead><tr><th>الرئيسي</th><th>من</th><th>إلى</th></tr></thead>
            <tbody>{links.map((l, i) => (
              <tr key={i}><td>{l.master_number} — {l.master_name}</td><td className="num">{l.valid_from ? fmtDate(l.valid_from) : 'منذ البداية'}</td><td className="num">{l.valid_to ? fmtDate(l.valid_to) : 'مستمر'}</td></tr>
            ))}</tbody></table></div>
        )}
      </div>
      {branches.length > 0 && (
        <div className="panel">
          <h3>الفروع الحالية ({branches.length})</h3>
          <div className="tbl" style={{ marginTop: 8 }}><table><thead><tr><th>الرقم</th><th>الاسم</th></tr></thead>
            <tbody>{branches.map((b) => <tr key={b.id}><td className="num">{b.customer_number}</td><td>{b.name}</td></tr>)}</tbody></table></div>
        </div>
      )}
      {changing && <ChangeMaster row={row} onClose={() => setChanging(false)} onDone={() => { setChanging(false); onChanged(); }} />}
    </>
  );
}

function ChangeMaster({ row, onClose, onDone }: { row: CustomerRow; onClose: () => void; onDone: () => void }) {
  const [master, setMaster] = useState(row.master_number ?? '');
  const [eff, setEff] = useState('');
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const save = () => run(async () => {
    if (!eff) throw new Error('تاريخ السريان مطلوب');
    await guarded((code) => rpc('change_customer_master', { p_customer: row.id, p_master_number: master || null, p_effective: eff, p_reason: reason || null, p_code: code }));
    onDone();
  });
  return (
    <Modal title="تغيير ارتباط الفرع بالرئيسي" onClose={onClose}
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>التغيير بتاريخ سريان؛ لا يُكتب التاريخ تلقائيًا (B055). أثره على العائلة والكشف والتوزيع يظهر في وحدة الحسابات.</Msg>
      <div className="grid2">
        <Field label="رقم العميل الرئيسي" hint="فارغ = يصبح مستقلًا"><input value={master} onChange={(e) => setMaster(e.target.value)} /></Field>
        <Field label="تاريخ السريان"><input type="date" value={eff} onChange={(e) => setEff(e.target.value)} /></Field>
      </div>
      <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function LocationTab({ row, onChanged }: { row: CustomerRow; onChanged: () => void }) {
  const { can } = useAuth();
  const [lat, setLat] = useState(row.lat ?? '');
  const [lng, setLng] = useState(row.lng ?? '');
  const { busy, error, run } = useAction();
  const editable = can('P02', 'edit') || can('P16', 'edit');
  const save = (remove = false) => run(async () => {
    await rpc('set_customer_location', { p_customer: row.id, p_lat: remove ? null : lat || null, p_lng: remove ? null : lng || null });
    if (remove) { setLat(''); setLng(''); }
    onChanged();
  });
  return (
    <div className="panel" style={{ display: 'grid', gap: 10 }}>
      <p className="small muted">موقع العميل مستقل عن موقع الفاتورة؛ تصحيحه لا ينقل فاتورة قديمة (B066). الإحداثيات تحفظ بدقتها.</p>
      <div className="grid2">
        <Field label="خط العرض (Latitude)"><input dir="ltr" value={lat} disabled={!editable} onChange={(e) => setLat(e.target.value)} /></Field>
        <Field label="خط الطول (Longitude)"><input dir="ltr" value={lng} disabled={!editable} onChange={(e) => setLng(e.target.value)} /></Field>
      </div>
      {row.lat && <a className="small" target="_blank" rel="noreferrer" href={`https://www.google.com/maps?q=${row.lat},${row.lng}`}>فتح الموقع على الخريطة</a>}
      {error && <Msg kind="bad">{error}</Msg>}
      {editable && (
        <div className="actions">
          <button className="btn primary" disabled={busy} onClick={() => save()}>حفظ الموقع</button>
          {row.lat && <button className="btn danger" disabled={busy} onClick={() => save(true)}>إزالة الموقع</button>}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------
// استيراد العملاء
// ---------------------------------------------------------------------
interface CRow { row: number; master_name: string; master_number: string; name: string; customer_number: string; company_id: string; grace_days: string }
interface CPlan {
  errors: PlanError[]; warnings: PlanError[];
  new: { row: number; customer_number: string; name: string; master_number: string | null }[];
  changed: { row: number; customer_number: string; fields: Record<string, [unknown, unknown]> }[];
  link_changes: { row: number; customer_number: string; name: string; current: string | null; new: string | null }[];
  counts: Record<string, number>;
}
type CDec = { link_effective: Record<string, string> };

const customerImportSpec = {
  title: 'استيراد العملاء والفروع',
  requiredHeaders: HEADERS,
  mapRow: (c: Record<string, string>, row: number): CRow => ({
    row, master_name: c['MasterCustomerName'] ?? '', master_number: c['MasterCustomerNumber'] ?? '', name: c['CustomerName'] ?? '',
    customer_number: c['CustomerNumber'] ?? '', company_id: c['CompanyID'] ?? '', grace_days: c['فترة السماح'] ?? '',
  }),
  preview: (rows: CRow[]) => rpc<CPlan>('preview_customer_import', { p_rows: rows }),
  commit: (rows: CRow[], d: CDec, fileName: string, code: string | null) =>
    rpc('commit_customer_import', { p_rows: rows, p_decisions: d, p_file_name: fileName, p_code: code }),
  initialDecisions: { link_effective: {} } as CDec,
  canCommit: (p: CPlan, d: CDec) => (p.link_changes.some((l) => !d.link_effective[l.customer_number]) ? 'حدد تاريخ سريان كل تغيير في ارتباط الفروع' : null),
  renderPlan: (p: CPlan, d: CDec, set: (d: CDec) => void) => (
    <>
      <Counts items={[['جديد', p.counts.new, 'ok'], ['متغير', p.counts.changed, 'warn'], ['تغيير ارتباط', p.counts.link_changes, 'warn'],
        ['مطابق دون تغيير', p.counts.unchanged], ['تنبيهات', p.counts.warnings, 'warn'], ['أخطاء', p.counts.errors, 'bad']]} />
      {p.warnings.length > 0 && (
        <div className="panel"><h3>تنبيهات للمراجعة (لا تمنع الاعتماد)</h3>
          <ul className="small">{p.warnings.map((w, i) => <li key={i}>الصف {w.row}: {w.message}</li>)}</ul></div>
      )}
      {p.link_changes.length > 0 && (
        <div className="panel"><h3>تغييرات ارتباط الفرع بالرئيسي — تتطلب تاريخ سريان (B055)</h3>
          <div className="tbl" style={{ marginTop: 8 }}><table><thead><tr><th>العميل</th><th>الرئيسي الحالي</th><th>الجديد</th><th>تاريخ السريان</th></tr></thead>
            <tbody>{p.link_changes.map((l) => (
              <tr key={l.customer_number}><td>{l.customer_number} — {l.name}</td><td>{l.current ?? 'مستقل'}</td><td>{l.new ?? 'مستقل'}</td>
                <td><input type="date" className="input" value={d.link_effective[l.customer_number] ?? ''}
                  onChange={(e) => set({ link_effective: { ...d.link_effective, [l.customer_number]: e.target.value } })} /></td></tr>
            ))}</tbody></table></div></div>
      )}
      {p.changed.length > 0 && <div className="panel"><h3>تعديلات البيانات</h3><div style={{ marginTop: 8 }}>
        <ChangesTable items={p.changed} keyLabel="رقم العميل" keyField="customer_number" labels={{ name: 'الاسم', company_id: 'CompanyID', grace_days: 'فترة السماح' }} /></div></div>}
      {p.new.length > 0 && <div className="panel"><h3>عملاء جدد ({p.new.length})</h3>
        <div className="small muted">{p.new.slice(0, 30).map((n) => `${n.customer_number} ${n.name}`).join('، ')}{p.new.length > 30 ? ' …' : ''}</div></div>}
    </>
  ),
};
