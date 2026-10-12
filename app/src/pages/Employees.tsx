// P03 — الموظفون والفرق (EMP-001..006، B001–B004). لا راتب في واجهة التشغيل (B003).
import { useEffect, useState } from 'react';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, todayIso } from '../lib/format';
import { fetchAll, cleanTerm } from '../lib/query';
import { writeSheet, dateCell } from '../lib/excel';
import { DataTable, Column } from '../components/DataTable';
import { Drawer, Field, Modal, Msg, Badge, useAction, useGuarded } from '../components/ui';
import { ImportWizard, ChangesTable, Counts, PlanError } from '../components/ImportWizard';
import { AuditList } from './Settings';

interface Period { id: number; start: string; end: string | null }
export interface EmployeeRow {
  id: number; emp_number: string; name: string; job_role: string | null; status: string; status_date: string | null;
  first_join_date: string | null; periods: Period[] | null; supervisor_id: number | null; supervisor_number: string | null; supervisor_name: string | null;
  [k: string]: unknown;
}

const HEADERS = ['الرقم الوظيفي', 'اسم الموظف', 'الدور الوظيفي', 'الراتب الأساسي', 'تاريخ الالتحاق', 'الحالة', 'تاريخ الحالة الفعلي', 'معرف المشرف'];
const REQUIRED = HEADERS.filter((h) => h !== 'الراتب الأساسي');

export function Employees() {
  const { can } = useAuth();
  const [term, setTerm] = useState('');
  const [status, setStatus] = useState('');
  const [open, setOpen] = useState<number | null>(null);
  const [adding, setAdding] = useState(false);
  const [importing, setImporting] = useState(false);
  const [ver, setVer] = useState(0);
  const exp = useAction();

  const build = () => {
    let q = sb().from('employees_v').select('*', { count: 'exact' });
    const t = cleanTerm(term);
    if (t) q = /^\d+$/.test(t) ? q.like('emp_number', `${t}%`) : q.ilike('name', `%${t}%`);
    if (status) q = q.eq('status', status);
    return q;
  };

  const cols: Column<EmployeeRow>[] = [
    { key: 'emp_number', label: 'الرقم', sortable: true, num: true },
    { key: 'name', label: 'الاسم', sortable: true },
    { key: 'job_role', label: 'الدور', sortable: true },
    { key: 'status', label: 'الحالة', render: (r) => <Badge kind={r.status === 'نشط' ? 'ok' : 'warn'}>{r.status}</Badge> },
    { key: 'periods', label: 'فترات العمل', render: (r) => (r.periods ?? []).map((p) => `${fmtDate(p.start)} – ${p.end ? fmtDate(p.end) : 'مستمرة'}`).join('، ') },
    { key: 'supervisor_name', label: 'المشرف الحالي', render: (r) => (r.supervisor_number ? `${r.supervisor_number} — ${r.supervisor_name}` : '') },
  ];

  const doExport = () => exp.run(async () => {
    const rows = await fetchAll<EmployeeRow>(() => build().order('emp_number'));
    writeSheet(`الموظفين ${todayIso()}.xlsx`, 'الموظفين', HEADERS, rows.map((r) => [
      r.emp_number, r.name, r.job_role, null, r.first_join_date ? fmtDate(r.first_join_date) : null, r.status,
      r.status_date ? fmtDate(r.status_date) : null, r.supervisor_number,
    ]));
  });

  return (
    <>
      <div className="page-head">
        <h1>الموظفون والفرق</h1>
        <div className="actions">
          {can('P03', 'add') && <button className="btn primary" onClick={() => setAdding(true)}>إضافة موظف</button>}
          {can('P03', 'import') && <button className="btn" onClick={() => setImporting(true)}>استيراد</button>}
          {can('P03', 'export') && <button className="btn" disabled={exp.busy} onClick={doExport}>تصدير</button>}
        </div>
      </div>
      {exp.error && <Msg kind="bad">{exp.error}</Msg>}
      <div className="filters">
        <input className="input" placeholder="بحث بالرقم أو الاسم" value={term} onChange={(e) => setTerm(e.target.value)} />
        <select className="input" value={status} onChange={(e) => setStatus(e.target.value)} style={{ minWidth: 120 }}>
          <option value="">كل الحالات</option><option>نشط</option><option>مستقيل</option><option>موقوف</option>
        </select>
      </div>
      <DataTable<EmployeeRow> columns={cols} rowKey={(r) => r.id} deps={[term, status, ver]} initialSort="emp_number" onRowClick={(r) => setOpen(r.id)}
        fetcher={async (q) => {
          let b = build();
          if (q.sort) b = b.order(q.sort, { ascending: q.asc });
          const { data, count, error } = await b.range(q.page * q.pageSize, (q.page + 1) * q.pageSize - 1);
          if (error) throw new Error(error.message);
          return { rows: (data ?? []) as EmployeeRow[], count: count ?? 0 };
        }} />
      <p className="small muted">إنشاء موظف لا ينشئ حساب دخول له؛ الحسابات من «المستخدمون والصلاحيات».</p>
      {open !== null && <EmployeeFile id={open} onClose={() => setOpen(null)} onChanged={() => setVer(ver + 1)} />}
      {adding && <EmployeeForm onClose={() => setAdding(false)} onSaved={() => { setAdding(false); setVer(ver + 1); }} />}
      {importing && <ImportWizard spec={employeeImportSpec} onClose={() => setImporting(false)} onDone={() => setVer(ver + 1)} />}
    </>
  );
}

function useEmployeeOptions() {
  const [opts, setOpts] = useState<{ id: number; emp_number: string; name: string }[]>([]);
  useEffect(() => {
    sb().from('employees').select('id, emp_number, name').order('emp_number').then(({ data }) => setOpts((data ?? []) as typeof opts));
  }, []);
  return opts;
}

function EmployeeForm({ row, onClose, onSaved }: { row?: EmployeeRow; onClose: () => void; onSaved: () => void }) {
  const opts = useEmployeeOptions();
  const [f, setF] = useState({ emp_number: row?.emp_number ?? '', name: row?.name ?? '', job_role: row?.job_role ?? '', join_date: '', supervisor_id: '' });
  const { busy, error, run } = useAction();
  const save = () => run(async () => { await rpc('save_employee', { p_id: row?.id ?? null, p: f }); onSaved(); });
  return (
    <Modal title={row ? 'تعديل الموظف' : 'إضافة موظف'} onClose={onClose}
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="الرقم الوظيفي"><input value={f.emp_number} onChange={(e) => setF({ ...f, emp_number: e.target.value })} /></Field>
        <Field label="الاسم"><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <Field label="الدور الوظيفي" hint="مثل: مندوب مبيعات، مشرف، سائق"><input value={f.job_role} onChange={(e) => setF({ ...f, job_role: e.target.value })} list="roles" /></Field>
        {!row && <Field label="تاريخ الالتحاق" hint="مشمول في فترة العمل"><input type="date" value={f.join_date} onChange={(e) => setF({ ...f, join_date: e.target.value })} /></Field>}
        {!row && <Field label="المشرف (اختياري)"><select value={f.supervisor_id} onChange={(e) => setF({ ...f, supervisor_id: e.target.value })}>
          <option value="">—</option>{opts.map((o) => <option key={o.id} value={o.id}>{o.emp_number} — {o.name}</option>)}</select></Field>}
      </div>
      <datalist id="roles"><option>مندوب مبيعات</option><option>مشرف</option><option>سائق</option></datalist>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function EmployeeFile({ id, onClose, onChanged }: { id: number; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [tab, setTab] = useState('def');
  const [row, setRow] = useState<EmployeeRow | null>(null);
  const [sups, setSups] = useState<{ number: string; name: string; from: string | null; to: string | null }[]>([]);
  const [team, setTeam] = useState<{ emp_number: string; name: string }[]>([]);
  const [ver, setVer] = useState(0);
  const [editing, setEditing] = useState(false);
  const [dlg, setDlg] = useState<string | null>(null);
  const load = useAction();

  useEffect(() => {
    load.run(async () => {
      const { data, error } = await sb().from('employees_v').select('*').eq('id', id).single();
      if (error) throw new Error(error.message);
      setRow(data as EmployeeRow);
      const s = await sb().from('supervisor_assignments').select('valid_from, valid_to, sup:employees!supervisor_assignments_supervisor_id_fkey(emp_number, name)').eq('employee_id', id).order('valid_from', { nullsFirst: true });
      setSups(((s.data ?? []) as unknown as { valid_from: string | null; valid_to: string | null; sup: { emp_number: string; name: string } }[])
        .map((x) => ({ number: x.sup.emp_number, name: x.sup.name, from: x.valid_from, to: x.valid_to })));
      const t = await sb().from('employees_v').select('emp_number, name').eq('supervisor_id', id).order('emp_number');
      setTeam((t.data ?? []) as typeof team);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, ver]);

  const changed = () => { setVer(ver + 1); setDlg(null); onChanged(); };
  const open = row?.periods?.find((p) => !p.end);

  return (
    <Drawer title={row ? `${row.emp_number} — ${row.name}` : 'ملف الموظف'} onClose={onClose}
      actions={row && can('P03', 'edit') && <button className="btn" onClick={() => setEditing(true)}>تعديل</button>}>
      <div className="tabs" role="tablist">
        {[['def', 'التعريف'], ['periods', 'فترات العمل'], ['sups', 'المشرفون عبر الزمن'], ['log', 'سجل التعديل']].map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {row && tab === 'def' && (
        <div className="panel">
          <dl className="kv">
            <dt>الرقم الوظيفي</dt><dd className="num">{row.emp_number}</dd><dt>الاسم</dt><dd>{row.name}</dd>
            <dt>الدور</dt><dd>{row.job_role ?? '—'}</dd><dt>الحالة</dt><dd>{row.status}{row.status_date && <> — <span className="num">{fmtDate(row.status_date)}</span></>}</dd>
            <dt>المشرف الحالي</dt><dd>{row.supervisor_number ? `${row.supervisor_number} — ${row.supervisor_name}` : '—'}</dd>
          </dl>
          {team.length > 0 && <><h3 style={{ marginTop: 12 }}>الفريق الحالي ({team.length})</h3>
            <div className="small">{team.map((t) => `${t.emp_number} ${t.name}`).join('، ')}</div></>}
          <p className="small muted" style={{ marginTop: 10 }}>أيام العمل والاستثناءات والأهداف وروابط الأداء تُضاف مع وحدة الأهداف.</p>
        </div>
      )}
      {row && tab === 'periods' && (
        <div className="panel" style={{ display: 'grid', gap: 10 }}>
          <p className="small muted">بداية الفترة وآخر يوم عمل كلاهما مشمول (EMP-003). لا تداخل بين فترتين، ولو في يوم واحد (EMP-005).</p>
          <div className="tbl"><table><thead><tr><th>من</th><th>آخر يوم عمل</th><th></th></tr></thead>
            <tbody>{(row.periods ?? []).map((p) => (
              <tr key={p.id}><td className="num">{fmtDate(p.start)}</td><td className="num">{p.end ? fmtDate(p.end) : 'مستمرة'}</td>
                <td>{can('P03', 'edit') && <button className="btn link" onClick={() => setDlg('correct:' + p.id)}>تصحيح</button>}</td></tr>
            ))}</tbody></table></div>
          {can('P03', 'edit') && <div className="actions">
            {open ? <button className="btn" onClick={() => setDlg('end')}>إنهاء فترة العمل</button>
                  : <button className="btn" onClick={() => setDlg('reactivate')}>إعادة التنشيط</button>}
          </div>}
        </div>
      )}
      {row && tab === 'sups' && (
        <div className="panel" style={{ display: 'grid', gap: 10 }}>
          <div className="tbl"><table><thead><tr><th>المشرف</th><th>من</th><th>إلى</th></tr></thead>
            <tbody>{sups.length === 0 ? <tr><td colSpan={3} className="empty">لا مشرف مسجل</td></tr> : sups.map((s, i) => (
              <tr key={i}><td>{s.number} — {s.name}</td><td className="num">{s.from ? fmtDate(s.from) : 'منذ البداية'}</td><td className="num">{s.to ? fmtDate(s.to) : 'مستمر'}</td></tr>
            ))}</tbody></table></div>
          {can('P03', 'transfer') && <div><button className="btn" onClick={() => setDlg('transfer')}>نقل لمشرف آخر</button></div>}
        </div>
      )}
      {tab === 'log' && <AuditList entity="employees" entityId={String(id)} />}
      {editing && row && <EmployeeForm row={row} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); changed(); }} />}
      {row && dlg === 'end' && <EndDialog row={row} onClose={() => setDlg(null)} onDone={changed} />}
      {row && dlg === 'reactivate' && <ReactivateDialog row={row} onClose={() => setDlg(null)} onDone={changed} />}
      {row && dlg?.startsWith('correct:') && <CorrectDialog period={row.periods!.find((p) => 'correct:' + p.id === dlg)!} onClose={() => setDlg(null)} onDone={changed} />}
      {row && dlg === 'transfer' && <TransferDialog row={row} onClose={() => setDlg(null)} onDone={changed} />}
    </Drawer>
  );
}

function EndDialog({ row, onClose, onDone }: { row: EmployeeRow; onClose: () => void; onDone: () => void }) {
  const [d, setD] = useState(''); const [st, setSt] = useState('مستقيل'); const [reason, setReason] = useState('');
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    await guarded((code) => rpc('end_employment', { p_employee: row.id, p_last_day: d, p_status: st, p_reason: reason || null, p_code: code }));
    onDone();
  });
  return (
    <Modal title="إنهاء فترة العمل" onClose={onClose} footer={<><button className="btn primary" disabled={busy || !d} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="آخر يوم عمل" hint="مشمول؛ خارج الأهلية من اليوم التالي"><input type="date" value={d} onChange={(e) => setD(e.target.value)} /></Field>
        <Field label="الحالة"><select value={st} onChange={(e) => setSt(e.target.value)}><option>مستقيل</option><option>موقوف</option></select></Field>
      </div>
      <Field label="السبب (اختياري)"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <p className="small muted">لا يحذف تغيير الحالة سندًا أو أثرًا ماليًا.</p>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function ReactivateDialog({ row, onClose, onDone }: { row: EmployeeRow; onClose: () => void; onDone: () => void }) {
  const [d, setD] = useState(todayIso()); const [reason, setReason] = useState('');
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    await guarded((code) => rpc('reactivate_employee', { p_employee: row.id, p_start: d, p_reason: reason || null, p_code: code }));
    onDone();
  });
  return (
    <Modal title="إعادة التنشيط" onClose={onClose} footer={<><button className="btn primary" disabled={busy || !d} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="تبدأ الأهلية من" hint="التاريخ المختار مشمول، ويجب أن يلي آخر يوم عمل سابق"><input type="date" value={d} onChange={(e) => setD(e.target.value)} /></Field>
      <Field label="السبب (اختياري)"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function CorrectDialog({ period, onClose, onDone }: { period: Period; onClose: () => void; onDone: () => void }) {
  const [s, setS] = useState(period.start); const [e, setE] = useState(period.end ?? ''); const [reason, setReason] = useState('');
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    await guarded((code) => rpc('correct_employment_period', { p_period: period.id, p_start: s, p_end: e || null, p_reason: reason, p_code: code }));
    onDone();
  });
  return (
    <Modal title="تصحيح فترة عمل" onClose={onClose} footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>تُسجَّل القيم السابقة والجديدة والسبب، وتُحترم حماية الأشهر المقفلة. أثر التصحيح على الأهداف والحركات المؤهلة يُعاد احتسابه في وحدة الأهداف.</Msg>
      <div className="grid2">
        <Field label="من"><input type="date" value={s} onChange={(ev) => setS(ev.target.value)} /></Field>
        <Field label="آخر يوم عمل" hint="فارغ = مستمرة"><input type="date" value={e} onChange={(ev) => setE(ev.target.value)} /></Field>
      </div>
      <Field label="سبب التصحيح"><input value={reason} onChange={(ev) => setReason(ev.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function TransferDialog({ row, onClose, onDone }: { row: EmployeeRow; onClose: () => void; onDone: () => void }) {
  const opts = useEmployeeOptions().filter((o) => o.id !== row.id);
  const [sup, setSup] = useState(''); const [eff, setEff] = useState(''); const [move, setMove] = useState(false); const [from, setFrom] = useState(''); const [reason, setReason] = useState('');
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    if (!sup || !eff) throw new Error('المشرف الجديد وتاريخ السريان مطلوبان');
    await guarded((code) => rpc('transfer_supervisor', { p_employee: row.id, p_new_supervisor: Number(sup), p_effective: eff, p_move_prior: move, p_move_from: move ? from : null, p_reason: reason || null, p_code: code }));
    onDone();
  });
  return (
    <Modal title="نقل لمشرف آخر" onClose={onClose} footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <p className="small">المشرف الحالي: <b>{row.supervisor_number ? `${row.supervisor_number} — ${row.supervisor_name}` : 'لا يوجد'}</b></p>
      <div className="grid2">
        <Field label="المشرف الجديد"><select value={sup} onChange={(e) => setSup(e.target.value)}><option value="">—</option>{opts.map((o) => <option key={o.id} value={o.id}>{o.emp_number} — {o.name}</option>)}</select></Field>
        <Field label="تاريخ السريان" hint="الحركات من هذا التاريخ للمشرف الجديد"><input type="date" value={eff} onChange={(e) => setEff(e.target.value)} /></Field>
      </div>
      <label className="check"><input type="checkbox" checked={move} onChange={(e) => setMove(e.target.checked)} /> نقل الحركات السابقة إلى المشرف الجديد لفترة محددة (الافتراضي إبقاؤها للقديم)</label>
      {move && <Field label="نقل الحركات من تاريخ" hint="«من — إلى»: من هذا التاريخ حتى تاريخ السريان"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>}
      <Field label="السبب (اختياري)"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <p className="small muted">لا تُحتسب الحركة للمشرفين معًا، ولا يتغير المندوب المسجل في السند. أثر النقل على أهداف المشرف المشتقة من فريقه ومبيعات الطرفين وعمولاتهما يظهر مع وحدة الأهداف.</p>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// استيراد الموظفين
// ---------------------------------------------------------------------
interface ERow { row: number; emp_number: string; name: string; job_role: string; join_date: string; status: string; status_date: string; supervisor_number: string }
interface EPlan {
  errors: PlanError[];
  new: { row: number; emp_number: string; name: string }[];
  changed: { row: number; emp_number: string; fields: Record<string, [unknown, unknown]> }[];
  status_changes: { row: number; emp_number: string; kind: string; status: string; date: string | null }[];
  supervisor_changes: { row: number; emp_number: string; name: string; current: string | null; new: string }[];
  conflicts: { row: number; emp_number: string; message: string }[];
  counts: Record<string, number>;
}
type EDec = { supervisor_effective: Record<string, string>; move_prior_from: Record<string, string> };

const employeeImportSpec = {
  title: 'استيراد الموظفين',
  requiredHeaders: REQUIRED,
  mapRow: (c: Record<string, string>, row: number): ERow => ({
    row, emp_number: c['الرقم الوظيفي'] ?? '', name: c['اسم الموظف'] ?? '', job_role: c['الدور الوظيفي'] ?? '',
    join_date: dateCell(c['تاريخ الالتحاق'] ?? ''), status: c['الحالة'] ?? '', status_date: dateCell(c['تاريخ الحالة الفعلي'] ?? ''),
    supervisor_number: c['معرف المشرف'] ?? '',
  }),
  preview: (rows: ERow[]) => rpc<EPlan>('preview_employee_import', { p_rows: rows }),
  commit: (rows: ERow[], d: EDec, fileName: string, code: string | null) =>
    rpc('commit_employee_import', { p_rows: rows, p_decisions: d, p_file_name: fileName, p_code: code }),
  initialDecisions: { supervisor_effective: {}, move_prior_from: {} } as EDec,
  canCommit: (p: EPlan, d: EDec) => (p.supervisor_changes.some((s) => !d.supervisor_effective[s.emp_number]) ? 'حدد تاريخ سريان كل تغيير مشرف (B004)' : null),
  renderPlan: (p: EPlan, d: EDec, set: (d: EDec) => void) => (
    <>
      <Counts items={[['جديد', p.counts.new, 'ok'], ['متغير', p.counts.changed, 'warn'], ['تغيير حالة', p.counts.status_changes, 'warn'],
        ['تغيير مشرف', p.counts.supervisor_changes, 'warn'], ['تعارض للمراجعة', p.counts.conflicts, 'warn'], ['مطابق', p.counts.unchanged], ['أخطاء', p.counts.errors, 'bad']]} />
      <p className="small muted">عمود الراتب إن ورد لا يُستورد (B003). غياب موظف عن الملف لا يحذفه، وإعادة الاستيراد لا تمحو فترات العمل أو الاستثناءات.</p>
      {p.conflicts.length > 0 && <div className="panel"><h3>تعارضات تظهر للمراجعة ولا تُطبَّق تلقائيًا (EMP-005)</h3>
        <ul className="small">{p.conflicts.map((c, i) => <li key={i}>الصف {c.row} — {c.emp_number}: {c.message}</li>)}</ul></div>}
      {p.supervisor_changes.length > 0 && (
        <div className="panel"><h3>تغيير المشرف — يتطلب تاريخ سريان (B004)</h3>
          <div className="tbl" style={{ marginTop: 8 }}><table><thead><tr><th>الموظف</th><th>الحالي</th><th>الجديد</th><th>تاريخ السريان</th><th>نقل السابق من (اختياري)</th></tr></thead>
            <tbody>{p.supervisor_changes.map((s) => (
              <tr key={s.emp_number}><td>{s.emp_number} — {s.name}</td><td>{s.current ?? '—'}</td><td>{s.new}</td>
                <td><input type="date" className="input" value={d.supervisor_effective[s.emp_number] ?? ''} onChange={(e) => set({ ...d, supervisor_effective: { ...d.supervisor_effective, [s.emp_number]: e.target.value } })} /></td>
                <td><input type="date" className="input" value={d.move_prior_from[s.emp_number] ?? ''} onChange={(e) => {
                  const m = { ...d.move_prior_from }; if (e.target.value) m[s.emp_number] = e.target.value; else delete m[s.emp_number];
                  set({ ...d, move_prior_from: m });
                }} /></td></tr>
            ))}</tbody></table></div></div>
      )}
      {p.status_changes.length > 0 && <div className="panel"><h3>تغييرات الحالة</h3>
        <ul className="small">{p.status_changes.map((s, i) => <li key={i}>{s.emp_number}: {s.kind === 'end' ? `إنهاء — آخر يوم عمل ${fmtDate(s.date)}` : s.kind === 'reactivate' ? `عودة من ${fmtDate(s.date)}` : `الحالة ${s.status}`}</li>)}</ul></div>}
      {p.changed.length > 0 && <div className="panel"><h3>تعديلات البيانات</h3><div style={{ marginTop: 8 }}>
        <ChangesTable items={p.changed} keyLabel="الرقم" keyField="emp_number" labels={{ name: 'الاسم', job_role: 'الدور' }} /></div></div>}
      {p.new.length > 0 && <div className="panel"><h3>موظفون جدد ({p.new.length})</h3><div className="small muted">{p.new.map((n) => `${n.emp_number} ${n.name}`).join('، ')}</div></div>}
    </>
  ),
};
