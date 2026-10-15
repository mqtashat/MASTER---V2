// P12 «المكافآت»: خطط الشهر بشرطها (شريحة محققة أو حد أدنى لمقياس) وقيمتها (مبلغ ثابت أو نسبة بأساس صريح)،
// ومجموعة التداخل بطريقة جمع صريحة (جمع المستحقات أو الأعلى فقط، B023)، ومن يستوفيها وسبب الاستحقاق.
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtMonth, fmtPct } from '../lib/format';
import { Filters, fmtMetric, fromMonthInput, METRICS, metricDef, monthInput, thisMonth, useEmployees } from '../lib/goals';
import { Badge, Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { AuditList } from './Settings';

interface Reward {
  id: number; month: string; name: string; role: 'all' | 'rep' | 'supervisor'; employees: number[] | null; employee_names: string[] | null; hidden_employees?: number;
  cond_type: 'tier' | 'metric'; tiers: string[] | null; metric: string | null; metric_min: string | number | null; filters: Filters;
  value_type: 'fixed' | 'percent'; amount: string | number | null; pct: string | number | null; pct_base: 'eligible' | 'base_commission' | null;
  group_name: string | null; stack_mode: 'STACK' | 'HIGHEST_ONLY'; note: string | null;
  qualified: { employee_id: number; name: string; amount: string; reason: string; counted: boolean }[];
}

const ROLE_TEXT = { all: 'المندوبون والمشرفون', rep: 'المندوبون', supervisor: 'المشرفون' };
const BASE_TEXT = { eligible: 'المبيعات المؤهلة', base_commission: 'العمولة الأساسية' };

export function condText(r: Pick<Reward, 'cond_type' | 'tiers' | 'metric' | 'metric_min'>): string {
  if (r.cond_type === 'tier') return 'الشريحة المحققة: ' + (r.tiers ?? []).join(' أو ');
  const def = metricDef(r.metric ?? '');
  return `${def.label} ≥ ${fmtMetric(r.metric_min, def.kind)}`;
}
export function valueText(r: Pick<Reward, 'value_type' | 'amount' | 'pct' | 'pct_base'>): string {
  return r.value_type === 'fixed' ? fmtAmount(r.amount) : `${fmtPct(r.pct)}% من ${BASE_TEXT[r.pct_base ?? 'eligible']}`;
}

export function Rewards() {
  const { can } = useAuth();
  const [month, setMonth] = useState(thisMonth());
  const [d, setD] = useState<{ closed: boolean; plans: Reward[] } | null>(null);
  const [ver, setVer] = useState(0);
  const [edit, setEdit] = useState<Reward | 'new' | null>(null);
  const [del, setDel] = useState<Reward | null>(null);
  const [log, setLog] = useState<Reward | null>(null);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<{ closed: boolean; plans: Reward[] }>('rewards_list', { p_month: month }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, ver]);
  const refresh = () => setVer(ver + 1);
  return (
    <>
      <div className="page-head">
        <h1>المكافآت</h1>
        <div className="actions">{can('P12', 'add') && <button className="btn primary" onClick={() => setEdit('new')}>مكافأة جديدة</button>}</div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        {d?.closed && <Badge kind="warn">شهر مغلق (من النسخة المحفوظة)</Badge>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && (d.plans.length === 0 ? <div className="panel empty">لا مكافآت لهذا الشهر.</div> : d.plans.map((r) => (
        <div key={r.id} className="panel">
          <div className="page-head" style={{ marginBottom: 6 }}>
            <h2>{r.name}</h2>
            <div className="actions">
              <button className="btn link" onClick={() => setLog(r)}>السجل</button>
              {can('P12', 'edit') && <button className="btn" onClick={() => setEdit(r)}>تعديل</button>}
              {can('P12', 'delete') && <button className="btn danger" onClick={() => setDel(r)}>حذف</button>}
            </div>
          </div>
          <dl className="kv">
            <dt>الشرط</dt><dd>{condText(r)}</dd>
            <dt>القيمة</dt><dd>{valueText(r)}</dd>
            <dt>المشمولون</dt><dd>{r.employee_names?.length || r.hidden_employees ? [...(r.employee_names ?? []), ...(r.hidden_employees ? [`${r.hidden_employees} خارج نطاقك`] : [])].join('، ') : ROLE_TEXT[r.role]}</dd>
            <dt>التداخل</dt><dd>{r.group_name ? `مجموعة «${r.group_name}» — ` : ''}{r.stack_mode === 'STACK' ? 'جمع المستحقات' : 'الأعلى فقط'}</dd>
            {r.note && <><dt>ملاحظة</dt><dd>{r.note}</dd></>}
          </dl>
          <h3 style={{ marginTop: 8 }}>المستوفون ({r.qualified.length})</h3>
          {r.qualified.length === 0 ? <p className="muted small">لا أحد حتى الآن.</p> : (
            <table className="inner"><thead><tr><th>الموظف</th><th>السبب</th><th className="num">المبلغ</th><th></th></tr></thead>
              <tbody>{r.qualified.map((q) => (
                <tr key={q.employee_id} className={q.counted ? '' : 'row-hidden'}><td>{q.name}</td><td className="wrap">{q.reason}</td>
                  <td className="num">{fmtAmount(q.amount)}</td><td>{!q.counted && <Badge>لا تُحتسب: الأعلى فقط</Badge>}</td></tr>
              ))}</tbody></table>
          )}
        </div>
      )))}
      {edit && <RewardEditor month={month} reward={edit === 'new' ? null : edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); refresh(); }} />}
      {del && <DeleteReward reward={del} onClose={() => setDel(null)} onDone={() => { setDel(null); refresh(); }} />}
      {log && <Drawer title={`سجل «${log.name}»`} onClose={() => setLog(null)}><AuditList entity="reward_plans" entityId={String(log.id)} /></Drawer>}
    </>
  );
}

function RewardEditor({ month, reward, onClose, onDone }: { month: string; reward: Reward | null; onClose: () => void; onDone: () => void }) {
  const emps = useEmployees();
  const [f, setF] = useState({
    name: reward?.name ?? '', role: reward?.role ?? 'all', cond_type: reward?.cond_type ?? 'tier', tiers: (reward?.tiers ?? ['A']).join(' '),
    metric: reward?.metric ?? 'net_sales', metric_min: reward?.metric_min === null || reward?.metric_min === undefined ? '' : String(reward.metric_min),
    value_type: reward?.value_type ?? 'fixed', amount: reward?.amount === null || reward?.amount === undefined ? '' : String(reward.amount),
    pct: reward?.pct === null || reward?.pct === undefined ? '' : String(reward.pct), pct_base: reward?.pct_base ?? '',
    group_name: reward?.group_name ?? '', stack_mode: reward?.stack_mode ?? '', note: reward?.note ?? '',
  });
  const [employees, setEmployees] = useState<number[]>((reward?.employees ?? []).map(Number));
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const set = (n: Partial<typeof f>) => setF({ ...f, ...n });
  const save = () => run(async () => {
    const p = { ...f, month, tiers: f.tiers.split(/[\s,،]+/).filter(Boolean), employees: employees.length ? employees : null,
      filters: reward?.filters ?? {}, pct_base: f.pct_base || null, stack_mode: f.stack_mode || null };
    await guarded((code) => rpc('save_reward', { p_id: reward?.id ?? null, p, p_code: code }));
    onDone();
  });
  return (
    <Modal wide title={reward ? `تعديل «${reward.name}»` : `مكافأة جديدة — ${fmtMonth(month)}`} onClose={onClose}
      footer={<><button className="btn primary" disabled={busy || !f.name.trim()} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid3">
        <Field label="الاسم"><input value={f.name} onChange={(e) => set({ name: e.target.value })} /></Field>
        <Field label="الدور"><select value={f.role} onChange={(e) => set({ role: e.target.value as Reward['role'] })}>
          <option value="all">المندوبون والمشرفون</option><option value="rep">المندوبون</option><option value="supervisor">المشرفون</option></select></Field>
        <Field label="نوع الشرط"><select value={f.cond_type} onChange={(e) => set({ cond_type: e.target.value as Reward['cond_type'] })}>
          <option value="tier">شريحة محققة</option><option value="metric">حد أدنى لمقياس</option></select></Field>
        {f.cond_type === 'tier' ? (
          <Field label="الشرائح المؤهلة" hint="مثل: A B"><input value={f.tiers} onChange={(e) => set({ tiers: e.target.value.toUpperCase() })} /></Field>
        ) : <>
          <Field label="المقياس" hint={metricDef(f.metric).hint}><select value={f.metric} onChange={(e) => set({ metric: e.target.value })}>{METRICS.map((m) => <option key={m.code} value={m.code}>{m.label}</option>)}</select></Field>
          <Field label="الحد الأدنى"><input inputMode="decimal" value={f.metric_min} onChange={(e) => set({ metric_min: e.target.value })} /></Field>
        </>}
        <Field label="نوع القيمة"><select value={f.value_type} onChange={(e) => set({ value_type: e.target.value as Reward['value_type'] })}>
          <option value="fixed">مبلغ ثابت</option><option value="percent">نسبة</option></select></Field>
        {f.value_type === 'fixed' ? <Field label="المبلغ"><input inputMode="decimal" value={f.amount} onChange={(e) => set({ amount: e.target.value })} /></Field> : <>
          <Field label="النسبة %"><input inputMode="decimal" value={f.pct} onChange={(e) => set({ pct: e.target.value })} /></Field>
          <Field label="أساس النسبة" hint="مطلوب صراحة (B025)"><select value={f.pct_base} onChange={(e) => set({ pct_base: e.target.value })}>
            <option value="">اختر</option><option value="eligible">المبيعات المؤهلة</option><option value="base_commission">العمولة الأساسية</option></select></Field>
        </>}
        <Field label="مجموعة التداخل" hint="المكافآت بنفس المجموعة تُجمع بطريقة واحدة"><input value={f.group_name} onChange={(e) => set({ group_name: e.target.value })} /></Field>
        <Field label="طريقة الجمع" hint="مطلوبة صراحة (B023)"><select value={f.stack_mode} onChange={(e) => set({ stack_mode: e.target.value })}>
          <option value="">اختر</option><option value="STACK">جمع المستحقات</option><option value="HIGHEST_ONLY">الأعلى فقط</option></select></Field>
        <Field label="ملاحظة"><input value={f.note} onChange={(e) => set({ note: e.target.value })} /></Field>
      </div>
      <details>
        <summary>موظفون محددون ({employees.length || 'الكل ضمن الدور'})</summary>
        <div className="member-grid">{emps.filter((e) => e.status === 'نشط' || employees.includes(Number(e.id))).map((e) => (
          <label key={e.id} className="check"><input type="checkbox" checked={employees.includes(Number(e.id))}
            onChange={(ev) => setEmployees(ev.target.checked ? [...employees, Number(e.id)] : employees.filter((x) => x !== Number(e.id)))} /> {e.emp_number} — {e.name}</label>
        ))}</div>
      </details>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function DeleteReward({ reward, onClose, onDone }: { reward: Reward; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const go = () => run(async () => { await guarded((code) => rpc('delete_reward', { p_id: reward.id, p_reason: reason, p_code: code })); onDone(); });
  return (
    <Modal title={`حذف «${reward.name}»`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={go}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
