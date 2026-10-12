// P21 — الإعدادات وسجل العمليات (AUTH-003، AUTH-004، CARD-006، B064، DAY-001)
import { useEffect, useState } from 'react';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, fmtDateTime } from '../lib/format';
import { cleanTerm } from '../lib/query';
import { DataTable, Column } from '../components/DataTable';
import { Field, Modal, Msg, useAction } from '../components/ui';

interface Setting { key: string; value: unknown }

export function Settings() {
  const { profile, can } = useAuth();
  const [tab, setTab] = useState('general');
  return (
    <>
      <div className="page-head"><h1>الإعدادات وسجل العمليات</h1></div>
      <div className="tabs" role="tablist" style={{ marginBottom: 12 }}>
        {[['general', 'عام'], ['mapday', 'يوم الخرائط'], ...(profile?.is_admin ? [['admin', 'إعدادات الإدارة']] : []), ['log', 'سجل العمليات']].map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {tab === 'general' && <General editable={can('P21', 'edit')} />}
      {tab === 'mapday' && <MapDay editable={can('P21', 'edit')} />}
      {tab === 'admin' && profile?.is_admin && <AdminSettings />}
      {tab === 'log' && <AuditLog />}
    </>
  );
}

function useSettings(ver: number) {
  const [s, setS] = useState<Record<string, unknown>>({});
  useEffect(() => {
    sb().from('settings').select('key, value').then(({ data }) => setS(Object.fromEntries(((data ?? []) as Setting[]).map((x) => [x.key, x.value]))));
  }, [ver]);
  return s;
}

function General({ editable }: { editable: boolean }) {
  const [ver, setVer] = useState(0);
  const s = useSettings(ver);
  const [name, setName] = useState('');
  const [header, setHeader] = useState('');
  const { busy, error, run } = useAction();
  const [saved, setSaved] = useState(false);
  useEffect(() => { setName((s.company_name as string) ?? ''); setHeader((s.document_header as string) ?? ''); }, [s]);
  const save = () => run(async () => {
    await rpc('save_setting', { p_key: 'company_name', p_value: name });
    await rpc('save_setting', { p_key: 'document_header', p_value: header });
    setSaved(true); setVer(ver + 1);
  });
  return (
    <div className="panel" style={{ display: 'grid', gap: 10, maxWidth: 640 }}>
      <Field label="اسم الشركة"><input value={name} disabled={!editable} onChange={(e) => { setName(e.target.value); setSaved(false); }} /></Field>
      <Field label="ترويسة الوثائق المطبوعة" hint="تظهر أعلى كشف الحساب والوثائق؛ أسطر الترويسة وفق PRINT-002">
        <textarea rows={3} value={header} disabled={!editable} onChange={(e) => { setHeader(e.target.value); setSaved(false); }} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
      {saved && <Msg kind="ok">حُفظت الإعدادات.</Msg>}
      {editable && <div><button className="btn primary" disabled={busy} onClick={save}>حفظ</button></div>}
    </div>
  );
}

interface DayStart { from: string | null; time: string }

function MapDay({ editable }: { editable: boolean }) {
  const [ver, setVer] = useState(0);
  const s = useSettings(ver);
  const list = ((s.map_day_start as DayStart[]) ?? []).slice().sort((a, b) => (a.from ?? '').localeCompare(b.from ?? ''));
  const [from, setFrom] = useState('');
  const [time, setTime] = useState('07:00');
  const { busy, error, run } = useAction();
  const add = () => run(async () => {
    if (!from) throw new Error('تاريخ السريان مطلوب');
    if (!/^\d{2}:\d{2}$/.test(time)) throw new Error('الوقت بصيغة ساعة:دقيقة');
    const next = [...list.filter((x) => x.from !== from), { from, time }];
    await rpc('save_setting', { p_key: 'map_day_start', p_value: next });
    setVer(ver + 1); setFrom('');
  });
  const end = (t: string) => {
    const [h, m] = t.split(':').map(Number);
    const mins = (h * 60 + m + 24 * 60 - 1) % (24 * 60);
    return `${String(Math.floor(mins / 60)).padStart(2, '0')}:${String(mins % 60).padStart(2, '0')}`;
  };
  return (
    <div className="panel" style={{ display: 'grid', gap: 10, maxWidth: 720 }}>
      <Msg>يوم الخرائط بتوقيت الأردن: يبدأ في الوقت المحدد وينتهي آخر دقيقة قبل بداية اليوم التالي، بلا فجوة. الإعداد للخرائط فقط؛ لا يغيّر تاريخ السند المالي أو تقويم الأهداف (B064). التغيير بتاريخ سريان ويبقى الأقدم كما هو (DAY-001).</Msg>
      <div className="tbl"><table><thead><tr><th>ساري من</th><th>بداية اليوم</th><th>نهاية اليوم</th></tr></thead>
        <tbody>{list.map((x, i) => (
          <tr key={i}><td className="num">{x.from ? fmtDate(x.from) : 'منذ البداية'}</td><td className="num">{x.time}</td><td className="num">{end(x.time)}:59 من اليوم التالي</td></tr>
        ))}</tbody></table></div>
      {editable && (
        <div className="grid3" style={{ alignItems: 'end' }}>
          <Field label="ساري من"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="بداية اليوم"><input type="time" value={time} onChange={(e) => setTime(e.target.value)} /></Field>
          <div><button className="btn primary" disabled={busy} onClick={add}>إضافة تعديل بتاريخ سريان</button></div>
        </div>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </div>
  );
}

function AdminSettings() {
  const { reload, profile } = useAuth();
  const [ver, setVer] = useState(0);
  const s = useSettings(ver);
  const [limit, setLimit] = useState('');
  const { busy, error, run } = useAction();
  const [secret, setSecret] = useState(false);
  useEffect(() => { setLimit(s.maps_spend_limit === undefined || s.maps_spend_limit === null ? '' : String(s.maps_spend_limit)); }, [s]);
  const togglePath = () => run(async () => { await rpc('save_setting', { p_key: 'show_path_phrase', p_value: !(s.show_path_phrase === true) }); setVer(ver + 1); });
  const saveLimit = () => run(async () => {
    if (limit && !/^\d+(\.\d+)?$/.test(limit)) throw new Error('الحد رقم موجب');
    await rpc('save_setting', { p_key: 'maps_spend_limit', p_value: limit ? Number(limit) : null });
    setVer(ver + 1);
  });
  return (
    <div style={{ display: 'grid', gap: 12, maxWidth: 720 }}>
      <div className="panel" style={{ display: 'grid', gap: 8 }}>
        <h2>«متقدم/متأخر» في بطاقات الأداء</h2>
        <p className="small muted">إظهار عبارة المسار أو إخفاؤها إعداد عام للإدارة وحدها ويسري على الجميع (CARD-006). طريقة حساب المطلوب حتى المتابعة لا تتغير.</p>
        <div className="actions"><span>الحالة الحالية: <b>{s.show_path_phrase === true ? 'تظهر' : 'لا تظهر'}</b></span>
          <button className="btn" disabled={busy} onClick={togglePath}>{s.show_path_phrase === true ? 'إخفاء' : 'إظهار'}</button></div>
      </div>
      <div className="panel" style={{ display: 'grid', gap: 8 }}>
        <h2>حد الإنفاق لحساب Google Maps</h2>
        <p className="small muted">حد شهري للتنبيه (MAP-013). ضبط الحد الفعلي والتنبيه يتم أيضًا في حساب Google Cloud نفسه.</p>
        <div className="grid2" style={{ alignItems: 'end' }}>
          <Field label="الحد الشهري (دولار)"><input inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} /></Field>
          <div><button className="btn primary" disabled={busy} onClick={saveLimit}>حفظ</button></div>
        </div>
      </div>
      <div className="panel" style={{ display: 'grid', gap: 8 }}>
        <h2>الرمز السري للإدارة</h2>
        <p className="small muted">لازم لفتح الشهر المقفل وأي تعديل على بيانات فترة مقفلة (AUTH-004). تضعه الإدارة لنفسها ولا يُعرض كنص.</p>
        <div className="actions"><span>{profile?.admin_secret_set ? 'مضبوط' : 'غير مضبوط بعد'}</span>
          <button className="btn" onClick={() => setSecret(true)}>{profile?.admin_secret_set ? 'تغيير الرمز' : 'ضبط الرمز'}</button></div>
      </div>
      {error && <Msg kind="bad">{error}</Msg>}
      {secret && <SecretForm isSet={!!profile?.admin_secret_set} onClose={() => setSecret(false)} onDone={() => { setSecret(false); reload(); }} />}
    </div>
  );
}

function SecretForm({ isSet, onClose, onDone }: { isSet: boolean; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ old: '', n: '', c: '' });
  const { busy, error, run } = useAction();
  const save = () => run(async () => {
    if (f.n !== f.c) throw new Error('الرمزان غير متطابقين');
    await rpc('admin_set_secret', { p_old: isSet ? f.old : null, p_new: f.n });
    onDone();
  });
  return (
    <Modal title="الرمز السري للإدارة" onClose={onClose}
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      {isSet && <Field label="الرمز الحالي"><input type="password" autoComplete="off" value={f.old} onChange={(e) => setF({ ...f, old: e.target.value })} /></Field>}
      <Field label="الرمز الجديد" hint="6 أحرف على الأقل"><input type="password" autoComplete="off" value={f.n} onChange={(e) => setF({ ...f, n: e.target.value })} /></Field>
      <Field label="تأكيد الرمز"><input type="password" autoComplete="off" value={f.c} onChange={(e) => setF({ ...f, c: e.target.value })} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// سجل العمليات
// ---------------------------------------------------------------------
interface AuditRow { id: number; at: string; actor_name: string | null; entity: string; entity_id: string | null; action: string; before: unknown; after: unknown; reason: string | null; [k: string]: unknown }

const ENTITY_LABELS: Record<string, string> = {
  customers: 'عميل', employees: 'موظف', employment_periods: 'فترة عمل', products: 'صنف', app_users: 'مستخدم',
  permission_templates: 'قالب صلاحيات', settings: 'إعداد', admin_secret: 'الرمز السري',
};

function AuditLog() {
  const [term, setTerm] = useState('');
  const [entity, setEntity] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [open, setOpen] = useState<AuditRow | null>(null);
  const cols: Column<AuditRow>[] = [
    { key: 'at', label: 'الوقت', sortable: true, render: (r) => <span className="num">{fmtDateTime(r.at)}</span> },
    { key: 'actor_name', label: 'المستخدم' },
    { key: 'entity', label: 'الكيان', render: (r) => `${ENTITY_LABELS[r.entity] ?? r.entity} ${r.entity_id ?? ''}` },
    { key: 'action', label: 'الإجراء' },
    { key: 'reason', label: 'السبب' },
  ];
  return (
    <>
      <div className="filters">
        <input className="input" placeholder="بحث باسم المستخدم أو الإجراء" value={term} onChange={(e) => setTerm(e.target.value)} />
        <select className="input" value={entity} onChange={(e) => setEntity(e.target.value)} style={{ minWidth: 140 }}>
          <option value="">كل الكيانات</option>
          {Object.entries(ENTITY_LABELS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
        </select>
        <label className="small muted">من <input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} /></label>
        <label className="small muted">إلى <input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} /></label>
      </div>
      <DataTable<AuditRow> columns={cols} rowKey={(r) => r.id} deps={[term, entity, from, to]} onRowClick={setOpen}
        fetcher={async (q) => {
          let b = sb().from('audit_log').select('*', { count: 'exact' });
          const t = cleanTerm(term);
          if (t) b = b.or(`actor_name.ilike.%${t}%,action.ilike.%${t}%`);
          if (entity) b = b.eq('entity', entity);
          if (from) b = b.gte('at', from);
          if (to) b = b.lt('at', new Date(new Date(to).getTime() + 86400000).toISOString().slice(0, 10));
          b = b.order(q.sort ?? 'at', { ascending: q.sort ? q.asc : false });
          const { data, count, error } = await b.range(q.page * q.pageSize, (q.page + 1) * q.pageSize - 1);
          if (error) throw new Error(error.message);
          return { rows: (data ?? []) as AuditRow[], count: count ?? 0 };
        }} />
      {open && (
        <Modal title="تفاصيل العملية" onClose={() => setOpen(null)} wide>
          <dl className="kv"><dt>الوقت</dt><dd className="num">{fmtDateTime(open.at)}</dd><dt>المستخدم</dt><dd>{open.actor_name}</dd>
            <dt>الكيان</dt><dd>{ENTITY_LABELS[open.entity] ?? open.entity} {open.entity_id}</dd><dt>الإجراء</dt><dd>{open.action}</dd>
            {open.reason && <><dt>السبب</dt><dd>{open.reason}</dd></>}</dl>
          <div className="grid2">
            <div><h3>السابق</h3><pre className="small" style={{ whiteSpace: 'pre-wrap', direction: 'ltr' }}>{open.before ? JSON.stringify(open.before, null, 2) : '—'}</pre></div>
            <div><h3>الجديد</h3><pre className="small" style={{ whiteSpace: 'pre-wrap', direction: 'ltr' }}>{open.after ? JSON.stringify(open.after, null, 2) : '—'}</pre></div>
          </div>
        </Modal>
      )}
    </>
  );
}

/** سجل تعديلات كيان محدد (يُعرض في ملف العميل أو الموظف أو الصنف) */
export function AuditList({ entity, entityId }: { entity: string; entityId: string }) {
  const { can } = useAuth();
  const [rows, setRows] = useState<AuditRow[] | null>(null);
  useEffect(() => {
    if (!can('P21')) return;
    sb().from('audit_log').select('*').eq('entity', entity).eq('entity_id', entityId).order('at', { ascending: false }).limit(100)
      .then(({ data }) => setRows((data ?? []) as AuditRow[]));
  }, [entity, entityId, can]);
  if (!can('P21')) return <div className="panel muted small">عرض سجل التعديلات يتطلب صلاحية «الإعدادات وسجل العمليات».</div>;
  if (!rows) return <div className="panel muted small">…</div>;
  if (!rows.length) return <div className="panel muted small">لا توجد تعديلات مسجلة.</div>;
  return (
    <div className="tbl"><table><thead><tr><th>الوقت</th><th>المستخدم</th><th>الإجراء</th><th>السبب</th></tr></thead>
      <tbody>{rows.map((r) => <tr key={r.id}><td className="num">{fmtDateTime(r.at)}</td><td>{r.actor_name}</td><td>{r.action}</td><td>{r.reason}</td></tr>)}</tbody></table></div>
  );
}
