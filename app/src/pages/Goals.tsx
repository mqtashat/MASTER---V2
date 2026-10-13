// P10 «أهداف المندوبين» وP10a «أهداف المشرفين»: محرك أهداف واحد (GOAL-002).
// القائمة: الشهر والمجموعة/الموظف وحالة الخطة، الهدف الأصلي والنهائي وأيام العمل والإنجاز والشريحة.
// الأفعال: إنشاء خطة، استخدام قالب، نسخ شهر، تعديل فردي/جماعي مع معاينة، تصدير.
// المحرر: مكونات بقياس وقيمة ونطاق، شرائح A/B/C/X بترتيب محفوظ، AND/OR، «يتأثر بتعديل أيام العمل»،
// والشهر الجزئي متناسب افتراضيًا أو ثابت؛ هدف المشرف مجموع الفريق افتراضيًا أو مستقل (GOAL-011).
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, fmtMonth, fmtPct } from '../lib/format';
import { writeSheet } from '../lib/excel';
import {
  addMonths, Eval, EvalComp, Filters, filtersText, fmtMetric, fromMonthInput, METRICS, metricDef, monthInput, Plan, PlanComponent,
  PlanTier, Product, thisMonth, tierClass, useEmployees, useProducts,
} from '../lib/goals';
import { Badge, Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { AuditList } from './Settings';

type Role = 'rep' | 'supervisor';
interface Row {
  employee_id: number; emp_number: string; name: string; status: string; plan_id: number | null;
  days: { D: number; E: number; total: number; elapsed: number }; main: EvalComp | null; achieved: string | null; path_tier: string | null;
  components: number; zero: boolean;
}
interface ListRes { month: string; cutoff: string; closed: boolean; rows: Row[] }
interface Template { id: number; name: string; role: Role; data: Partial<Plan>; plans: number }

const pageOf = (role: Role) => (role === 'supervisor' ? 'P10a' : 'P10');

export function RepGoals() { return <Goals role="rep" />; }
export function SupervisorGoals() { return <Goals role="supervisor" />; }

function Goals({ role }: { role: Role }) {
  const { can } = useAuth();
  const page = pageOf(role);
  const [month, setMonth] = useState(thisMonth());
  const [f, setF] = useState<{ search: string; state: string; supervisor_id: string }>({ search: '', state: '', supervisor_id: '' });
  const [res, setRes] = useState<ListRes | null>(null);
  const [ver, setVer] = useState(0);
  const [sel, setSel] = useState<number[]>([]);
  const [edit, setEdit] = useState<{ planId: number | null; employeeId: number | null } | null>(null);
  const [view, setView] = useState<number | null>(null);
  const [dlg, setDlg] = useState<'copy' | 'bulk' | 'templates' | null>(null);
  const emps = useEmployees();
  const load = useAction();

  useEffect(() => {
    let live = true;
    load.run(async () => { const r = await rpc<ListRes>('goals_list', { p_month: month, p_role: role, p_opts: f }); if (live) { setRes(r); setSel([]); } });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [month, role, JSON.stringify(f), ver]);

  const refresh = () => setVer(ver + 1);
  const rows = res?.rows ?? [];
  const doExport = () => writeSheet(`${role === 'rep' ? 'أهداف المندوبين' : 'أهداف المشرفين'} ${fmtMonth(month).replace('/', '-')}.xlsx`, 'الأهداف',
    ['الرقم', 'الموظف', 'الحالة', 'أيام الشهر', 'أيام الموظف', 'المنقضي', 'المكوّن الرئيسي', 'الهدف الأصلي', 'الهدف النهائي', 'المحقق', 'الإنجاز %', 'الشريحة المحققة', 'شريحة المسار'],
    rows.map((r) => [r.emp_number, r.name, r.plan_id ? 'لها خطة' : 'بلا خطة', r.days.D, r.days.total, r.days.elapsed,
      r.main ? `${r.main.tier ?? ''} ${r.main.label}` : null, r.main?.original ?? null, r.main?.final ?? null, r.main?.actual ?? null,
      r.main?.pct ? fmtPct(r.main.pct) : null, r.achieved, r.path_tier]));

  return (
    <>
      <div className="page-head">
        <h1>{role === 'rep' ? 'أهداف المندوبين' : 'أهداف المشرفين'}</h1>
        <div className="actions">
          {can(page, 'export') && <button className="btn" onClick={doExport}>تصدير Excel</button>}
          {can(page, 'add') && <button className="btn" onClick={() => setDlg('copy')}>نسخ شهر</button>}
          {can(page, 'edit') && <button className="btn" disabled={!sel.length} onClick={() => setDlg('bulk')}>تعديل جماعي ({sel.length})</button>}
          <button className="btn" onClick={() => setDlg('templates')}>القوالب</button>
          {can(page, 'add') && <button className="btn primary" onClick={() => setEdit({ planId: null, employeeId: null })}>خطة جديدة</button>}
        </div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        {role === 'rep' && (
          <select className="input" value={f.supervisor_id} onChange={(e) => setF({ ...f, supervisor_id: e.target.value })} aria-label="المجموعة">
            <option value="">كل المجموعات</option>
            {emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}
          </select>
        )}
        <select className="input" value={f.state} onChange={(e) => setF({ ...f, state: e.target.value })} aria-label="حالة الخطة">
          <option value="">كل الحالات</option><option value="with_plan">لها خطة</option><option value="no_plan">بلا خطة</option>
        </select>
        <input className="input" placeholder="بحث بالاسم أو الرقم" value={f.search} onChange={(e) => setF({ ...f, search: e.target.value })} aria-label="بحث" />
        {res && <span className="count">حتى {fmtDate(res.cutoff)}{res.closed && ' · شهر مغلق (النسخة المحفوظة)'}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      <div className="tbl"><table>
        <thead><tr><th><input type="checkbox" aria-label="تحديد الكل" checked={!!rows.length && sel.length === rows.filter((r) => r.plan_id).length}
          onChange={(e) => setSel(e.target.checked ? rows.filter((r) => r.plan_id).map((r) => r.plan_id!) : [])} /></th>
          <th>الموظف</th><th>الخطة</th><th className="num">أيام الشهر</th><th className="num">أيام الموظف</th><th className="num">المنقضي</th>
          <th>المكوّن الرئيسي</th><th className="num">الأصلي</th><th className="num">النهائي</th><th className="num">المحقق</th><th className="num">الإنجاز</th>
          <th>المحققة</th><th>المسار</th></tr></thead>
        <tbody>{!res ? <tr><td colSpan={13}><div className="skeleton" /></td></tr> : rows.length === 0 ? <tr><td colSpan={13} className="empty">لا موظفين ضمن الفلاتر</td></tr> : rows.map((r) => (
          <tr key={r.employee_id} className="clickable" onClick={() => (r.plan_id ? setView(r.plan_id) : can(page, 'add') && setEdit({ planId: null, employeeId: r.employee_id }))}>
            <td onClick={(e) => e.stopPropagation()}>{r.plan_id && <input type="checkbox" aria-label={'تحديد ' + r.name} checked={sel.includes(r.plan_id)}
              onChange={(e) => setSel(e.target.checked ? [...sel, r.plan_id!] : sel.filter((x) => x !== r.plan_id))} />}</td>
            <td><span className="num">{r.emp_number}</span> — {r.name}</td>
            <td>{r.plan_id ? <>{r.components} مكوّن{r.zero && <> <Badge kind="bad">هدف صفري</Badge></>}</> : <Badge kind="warn">بلا خطة</Badge>}</td>
            <td className="num">{r.days.D}</td><td className="num">{r.days.total}</td><td className="num">{r.days.elapsed}</td>
            <td>{r.main ? <>{r.main.tier && <b className={tierClass(r.main.tier)}>{r.main.tier}</b>} {r.main.label}</> : ''}</td>
            <td className="num">{r.main ? fmtMetric(r.main.original, r.main.kind) : ''}</td>
            <td className="num">{r.main ? fmtMetric(r.main.final, r.main.kind) : ''}</td>
            <td className="num">{r.main ? fmtMetric(r.main.actual, r.main.kind) : ''}</td>
            <td className="num">{r.main?.pct ? fmtPct(r.main.pct) + '%' : ''}</td>
            <td>{r.plan_id && <b className={tierClass(r.achieved)}>{r.achieved}</b>}</td>
            <td>{r.plan_id && <b className={tierClass(r.path_tier)}>{r.path_tier}</b>}</td>
          </tr>
        ))}</tbody></table></div>
      {view && <PlanView planId={view} onClose={() => setView(null)} onEdit={() => { setEdit({ planId: view, employeeId: null }); setView(null); }} onDeleted={() => { setView(null); refresh(); }} />}
      {edit && <PlanEditor role={role} month={month} planId={edit.planId} employeeId={edit.employeeId}
        candidates={rows.filter((r) => !r.plan_id)} onClose={() => setEdit(null)} onDone={(id) => { setEdit(null); refresh(); setView(id); }} />}
      {dlg === 'copy' && <CopyMonth role={role} month={month} onClose={() => setDlg(null)} onDone={() => { setDlg(null); refresh(); }} />}
      {dlg === 'bulk' && <BulkAdjust plans={sel} onClose={() => setDlg(null)} onDone={() => { setDlg(null); refresh(); }} />}
      {dlg === 'templates' && <Templates role={role} plans={sel} onClose={() => setDlg(null)} onDone={() => { setDlg(null); refresh(); }} />}
    </>
  );
}

// ---------------------------------------------------------------------
// عرض الخطة وتقييمها
// ---------------------------------------------------------------------
interface PlanRes { plan: Plan; eval: Eval; closed: boolean; rule: { id: number; name: string; tiers: { tier: string; sort: number }[] } | null; has_personal: boolean }

function PlanView({ planId, onClose, onEdit, onDeleted }: { planId: number; onClose: () => void; onEdit: () => void; onDeleted: () => void }) {
  const { can } = useAuth();
  const [d, setD] = useState<PlanRes | null>(null);
  const [tab, setTab] = useState('eval');
  const [del, setDel] = useState(false);
  const products = useProducts();
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<PlanRes>('goal_plan', { p_id: planId }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [planId]);
  const page = d ? pageOf(d.plan.role) : 'P10';
  return (
    <Drawer title={d ? `خطة ${d.plan.employee_name} — ${fmtMonth(d.plan.month)}` : 'الخطة'} onClose={onClose} actions={d && <>
      {can(page, 'edit') && <button className="btn primary" onClick={onEdit}>تعديل</button>}
      {can(page, 'delete') && <button className="btn danger" onClick={() => setDel(true)}>حذف</button>}</>}>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && (
        <>
          <div className="tabs" role="tablist">
            <button role="tab" aria-selected={tab === 'eval'} onClick={() => setTab('eval')}>الإنجاز</button>
            <button role="tab" aria-selected={tab === 'log'} onClick={() => setTab('log')}>سجل التعديلات</button>
          </div>
          {tab === 'log' ? <AuditList entity="goal_plans" entityId={String(planId)} /> : (
            <>
              {d.closed && <Msg>الشهر مغلق؛ تعديل الخطة للإدارة برمزها، والنتائج المعتمدة في نسخة الإغلاق.</Msg>}
              <EvalView ev={d.eval} plan={d.plan} products={products} />
            </>
          )}
        </>
      )}
      {del && d && <DeletePlan plan={d.plan} onClose={() => setDel(false)} onDone={onDeleted} />}
    </Drawer>
  );
}

export function EvalView({ ev, plan, products }: { ev: Eval; plan?: Plan; products: Product[] }) {
  const tiers = ev.tiers;
  const indep = ev.components.filter((c) => !c.tier);
  const sentence = (t: Eval['tiers'][number]) => {
    const cs = ev.components.filter((c) => c.tier === t.tier && c.status !== 'unused');
    if (!cs.length) return 'بلا مكونات — لا تشارك';
    return cs.map((c) => `${c.label} ${c.met ? '✓' : '✗'}`).join(t.logic === 'AND' ? ' و ' : ' أو ');
  };
  return (
    <>
      <dl className="kv">
        <dt>حتى</dt><dd className="num">{fmtDate(ev.cutoff)}</dd>
        <dt>أيام الشهر / داخل العمل</dt><dd className="num">{ev.days.D} / {ev.days.E}</dd>
        <dt>الاستثناءات (متناسب / الكل)</dt><dd className="num">{ev.days.P} / {ev.days.X}</dd>
        <dt>أيام الموظف / المنقضي</dt><dd className="num">{ev.days.total} / {ev.days.elapsed}</dd>
        {plan && <><dt>الشهر الجزئي</dt><dd>{plan.partial_mode === 'fixed' ? 'هدف ثابت' : 'متناسب مع فترة العمل'}</dd></>}
        {plan?.role === 'supervisor' && <><dt>هدف المشرف</dt><dd>{plan.sup_mode === 'team_sum' ? 'مجموع أهداف الفريق' : 'هدف مستقل'}{plan.include_personal && ' · يشمل مبيعاته الشخصية'}</dd></>}
        <dt>الشريحة المحققة</dt><dd><b className={tierClass(ev.achieved)}>{ev.achieved}</b></dd>
        <dt>شريحة المسار</dt><dd><b className={tierClass(ev.path_tier)}>{ev.path_tier}</b>{ev.path_state === 'not_started' && <span className="muted small"> — لم يبدأ المسار</span>}{ev.path_state === 'no_days' && <span className="muted small"> — لا توجد أيام عمل</span>}</dd>
      </dl>
      {tiers.map((t) => (
        <div key={t.tier} className="panel">
          <h3><b className={tierClass(t.tier)}>{t.tier}</b> <span className="muted small">({t.logic === 'AND' ? 'جميع الشروط' : 'شرط واحد يكفي'})</span>{' '}
            {t.met ? <Badge kind="ok">محققة</Badge> : <Badge>غير محققة</Badge>}</h3>
          <p className="small muted" style={{ margin: '4px 0' }}>{sentence(t)}</p>
          <CompTable comps={ev.components.filter((c) => c.tier === t.tier)} products={products} />
        </div>
      ))}
      {indep.length > 0 && <div className="panel"><h3>أهداف مستقلة</h3><CompTable comps={indep} products={products} /></div>}
    </>
  );
}

function CompTable({ comps, products }: { comps: EvalComp[]; products: Product[] }) {
  if (!comps.length) return <p className="muted small">لا مكونات</p>;
  return (
    <div className="tbl"><table>
      <thead><tr><th>المكوّن</th><th className="num">الأصلي</th><th className="num">النهائي</th><th className="num">المحقق</th><th className="num">الإنجاز</th>
        <th className="num">المطلوب حتى القطع</th><th className="num">المسار</th><th></th></tr></thead>
      <tbody>{comps.map((c) => (
        <tr key={c.id} className={c.status === 'zero' ? 'zero' : c.status === 'unused' ? 'row-muted' : ''}>
          <td className="wrap">{c.label}{!c.affected && <span className="muted small"> · لا يتأثر بالأيام</span>}
            {filtersText(c.filters, products) && <div className="small muted">{filtersText(c.filters, products)}</div>}
            {c.team && <details><summary className="small">مجموع الفريق ({c.team.count})</summary>
              <table className="inner"><tbody>{c.team.parts.map((p) => <tr key={p.employee_id}><td>{p.name}</td><td className="num">{fmtMetric(p.final, c.kind)}</td>
                <td className="num small">{p.under}/{p.days} يوم</td><td className="num">{fmtMetric(p.share, c.kind)}</td></tr>)}</tbody></table></details>}</td>
          <td className="num">{fmtMetric(c.original, c.kind)}</td><td className="num">{fmtMetric(c.final, c.kind)}</td>
          <td className="num">{fmtMetric(c.actual, c.kind)}</td><td className="num">{c.pct ? fmtPct(c.pct) + '%' : ''}</td>
          <td className="num">{c.has_path ? fmtMetric(c.required, c.kind) : '—'}</td><td className="num">{c.path_pct ? fmtPct(c.path_pct) + '%' : ''}</td>
          <td>{c.status === 'unused' ? <Badge>غير مستخدم</Badge> : c.status === 'zero' ? <Badge kind="bad">هدف صفري يحتاج تصحيحًا</Badge> : c.met ? <Badge kind="ok">محقق</Badge> : null}</td>
        </tr>
      ))}</tbody></table></div>
  );
}

function DeletePlan({ plan, onClose, onDone }: { plan: Plan; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const del = () => run(async () => { await guarded((code) => rpc('delete_goal_plan', { p_id: plan.id, p_reason: reason, p_code: code })); onDone(); });
  return (
    <Modal title={`حذف خطة ${plan.employee_name}`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={del}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// محرر الخطة
// ---------------------------------------------------------------------
const DEFAULT_TIERS: PlanTier[] = ['A', 'B', 'C', 'X'].map((t, i) => ({ tier: t, sort: i + 1, logic: 'AND' }));
const newComp = (tier: string | null, sort: number): PlanComponent => ({ tier, sort, metric: 'net_sales', target: '', affected: true, filters: {}, label: null });

function PlanEditor({ role, month, planId, employeeId, candidates, onClose, onDone }: {
  role: Role; month: string; planId: number | null; employeeId: number | null; candidates: Row[]; onClose: () => void; onDone: (id: number) => void;
}) {
  const { profile } = useAuth();
  const products = useProducts();
  const [emp, setEmp] = useState<string>(employeeId ? String(employeeId) : '');
  const [plan, setPlan] = useState<Partial<Plan>>({ partial_mode: 'proportional', sup_mode: 'team_sum', include_personal: false, tiers: DEFAULT_TIERS, components: [] });
  const [templates, setTemplates] = useState<Template[]>([]);
  const [hasPersonal, setHasPersonal] = useState(false);
  const [preview, setPreview] = useState<Eval | null>(null);
  const [reason, setReason] = useState('');
  const [tplName, setTplName] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();

  useEffect(() => {
    rpc<Template[]>('goal_templates_list', { p_role: role }).then(setTemplates).catch(() => setTemplates([]));
    if (planId) rpc<PlanRes>('goal_plan', { p_id: planId }).then((r) => { setPlan(r.plan); setHasPersonal(r.has_personal); setEmp(String(r.plan.employee_id)); });
  }, [planId, role]);

  const tiers = plan.tiers ?? [];
  const comps = plan.components ?? [];
  const setComps = (c: PlanComponent[]) => { setPlan({ ...plan, components: c }); setPreview(null); };
  const setTiers = (t: PlanTier[]) => { setPlan({ ...plan, tiers: t.map((x, i) => ({ ...x, sort: i + 1 })) }); setPreview(null); };
  const payload = () => ({ ...plan, month, employee_id: Number(emp), role, components: comps.map((c, i) => ({ ...c, sort: i + 1 })) });
  const useTemplate = (id: string) => {
    const t = templates.find((x) => String(x.id) === id);
    if (t) { setPlan({ ...plan, ...t.data, template_id: t.id }); setPreview(null); }
  };
  const doPreview = () => run(async () => setPreview(await rpc<Eval>('preview_goal_plan', { p_id: planId, p: { ...payload(), reason: 'معاينة' } })));
  const save = () => run(async () => {
    const id = await guarded((code) => rpc<number>('save_goal_plan', { p_id: planId, p: payload(), p_reason: planId ? reason : null, p_code: code }));
    onDone(id);
  });
  const saveTemplate = () => run(async () => {
    await rpc('save_goal_template', { p_id: null, p_name: tplName, p_role: role, p_data: { partial_mode: plan.partial_mode, sup_mode: plan.sup_mode, tiers, components: comps } });
    setTplName(''); setTemplates(await rpc<Template[]>('goal_templates_list', { p_role: role }));
  });
  const move = (i: number, d: number) => { const t = [...tiers]; const [x] = t.splice(i, 1); t.splice(i + d, 0, x); setTiers(t); };
  const valid = !!emp && (!planId || reason.trim());

  return (
    <Modal wide title={planId ? 'تعديل الخطة' : `خطة جديدة — ${fmtMonth(month)}`} onClose={onClose} footer={<>
      <button className="btn" disabled={busy || !emp} onClick={doPreview}>معاينة النتيجة</button>
      <button className="btn primary" disabled={busy || !valid} onClick={save}>اعتماد الخطة</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid3">
        <Field label="الموظف">
          <select value={emp} disabled={!!planId} onChange={(e) => setEmp(e.target.value)}>
            <option value="">اختر</option>
            {(planId ? [{ employee_id: plan.employee_id!, emp_number: plan.emp_number!, name: plan.employee_name! }] : candidates).map((c) =>
              <option key={c.employee_id} value={c.employee_id}>{c.emp_number} — {c.name}</option>)}
          </select>
        </Field>
        {!planId && (
          <Field label="استخدام قالب">
            <select defaultValue="" onChange={(e) => useTemplate(e.target.value)}>
              <option value="">بلا قالب</option>{templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </Field>
        )}
        <Field label="الشهر الجزئي (التحاق/مغادرة)">
          <select value={plan.partial_mode} onChange={(e) => { setPlan({ ...plan, partial_mode: e.target.value as Plan['partial_mode'] }); setPreview(null); }}>
            <option value="proportional">متناسب مع فترة العمل (الافتراضي)</option><option value="fixed">هدف ثابت</option>
          </select>
        </Field>
      </div>
      {role === 'supervisor' && (
        <div className="grid2">
          <Field label="هدف المشرف" hint="مجموع الفريق يتعدل بنقل المندوبين حسب أيامهم؛ المستقل لا يتغير تلقائيًا">
            <select value={plan.sup_mode} onChange={(e) => { setPlan({ ...plan, sup_mode: e.target.value as Plan['sup_mode'] }); setPreview(null); }}>
              <option value="team_sum">مجموع أهداف الفريق (الافتراضي)</option><option value="independent">هدف مستقل</option>
            </select>
          </Field>
          {(profile?.is_admin && (hasPersonal || plan.include_personal)) ? (
            <label className="check"><input type="checkbox" checked={!!plan.include_personal} onChange={(e) => setPlan({ ...plan, include_personal: e.target.checked })} /> إدراج مبيعاته الشخصية في إنجازه (خيار الإدارة)</label>
          ) : <p className="small muted">مبيعات المشرف الشخصية مستبعدة من إنجازه افتراضيًا؛ إدراجها خيار للإدارة عند وجودها.</p>}
        </div>
      )}

      <h3>الشرائح بترتيبها (الأعلى أولًا)</h3>
      <div className="tbl"><table className="edit-grid">
        <thead><tr><th>الترتيب</th><th>الشريحة</th><th>علاقة مكوناتها</th><th></th></tr></thead>
        <tbody>{tiers.map((t, i) => (
          <tr key={i}>
            <td className="num">{i + 1}</td>
            <td><input className="input" style={{ width: 70 }} value={t.tier} aria-label="رمز الشريحة"
              onChange={(e) => { const old = t.tier; const v = e.target.value.toUpperCase(); setPlan({ ...plan, tiers: tiers.map((x, j) => (j === i ? { ...x, tier: v } : x)),
                components: comps.map((c) => (c.tier === old ? { ...c, tier: v } : c)) }); }} /></td>
            <td><select className="input" value={t.logic} onChange={(e) => setTiers(tiers.map((x, j) => (j === i ? { ...x, logic: e.target.value as 'AND' | 'OR' } : x)))} aria-label="العلاقة">
              <option value="AND">AND — جميع الشروط</option><option value="OR">OR — شرط واحد يكفي</option></select></td>
            <td className="actions">
              <button className="btn link" disabled={i === 0} onClick={() => move(i, -1)}>أعلى</button>
              <button className="btn link" disabled={i === tiers.length - 1} onClick={() => move(i, 1)}>أدنى</button>
              <button className="btn link" onClick={() => setPlan({ ...plan, tiers: tiers.filter((_, j) => j !== i), components: comps.filter((c) => c.tier !== t.tier) })}>إلغاء</button>
            </td>
          </tr>
        ))}</tbody></table></div>
      <div><button className="btn" onClick={() => setTiers([...tiers, { tier: '', sort: tiers.length + 1, logic: 'AND' }])}>إضافة شريحة</button></div>

      {[...tiers.map((t) => t.tier), null].map((tier) => (
        <div key={tier ?? 'indep'} className="panel">
          <h3>{tier ? <>مكونات <b className={tierClass(tier)}>{tier}</b></> : 'أهداف مستقلة (خارج الشرائح)'}</h3>
          {comps.map((c, i) => c.tier !== tier ? null : (
            <CompEditor key={i} c={c} products={products} onChange={(n) => setComps(comps.map((x, j) => (j === i ? n : x)))} onRemove={() => setComps(comps.filter((_, j) => j !== i))} />
          ))}
          <button className="btn" onClick={() => setComps([...comps, newComp(tier, comps.length + 1)])}>إضافة مكوّن</button>
        </div>
      ))}
      <p className="small muted">المكوّن الفارغ القيمة غير مستخدم؛ الصفر يحتاج تصحيحًا أو تعطيلًا ولا يصنع تحقيقًا. المقاييس النسبية لا يخفض هدفها بالأيام، وأهداف الأعداد تقرب للأعلى مرة واحدة بعد كل التعديلات.</p>

      {preview && <div className="panel"><h3>المعاينة قبل الاعتماد</h3><EvalView ev={preview} products={products} /></div>}
      {planId && <Field label="سبب التعديل"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
      <div className="actions">
        <input className="input" style={{ width: 'auto' }} placeholder="اسم قالب جديد" value={tplName} onChange={(e) => setTplName(e.target.value)} aria-label="اسم القالب" />
        <button className="btn" disabled={busy || !tplName.trim()} onClick={saveTemplate}>حفظ كقالب</button>
      </div>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function CompEditor({ c, products, onChange, onRemove }: { c: PlanComponent; products: Product[]; onChange: (c: PlanComponent) => void; onRemove: () => void }) {
  const def = metricDef(c.metric);
  const f = c.filters ?? {};
  const setF = (n: Partial<Filters>) => onChange({ ...c, filters: { ...f, ...n } });
  const codes = (f.products ?? []).map((id) => products.find((p) => p.id === id)?.code ?? '').join(' ');
  return (
    <div className="comp-row">
      <Field label="المقياس" hint={def.hint}>
        <select value={c.metric} onChange={(e) => onChange({ ...c, metric: e.target.value, filters: {} })}>
          {METRICS.map((m) => <option key={m.code} value={m.code}>{m.label}</option>)}
        </select>
      </Field>
      <Field label={def.kind === 'relative' ? 'الهدف %' : 'الهدف'}><input inputMode="decimal" value={c.target ?? ''} onChange={(e) => onChange({ ...c, target: e.target.value })} /></Field>
      {['net_sales', 'gross_sales', 'quantity', 'customers', 'invoices', 'variety'].includes(c.metric) && <>
        <Field label="نوع البيع"><select value={f.sale_type ?? 'all'} onChange={(e) => setF({ sale_type: e.target.value as Filters['sale_type'] })}>
          <option value="all">المباشر والعروض</option><option value="direct">المباشر فقط</option><option value="promo">العروض فقط</option></select></Field>
        <Field label="الدفع"><select value={f.pay_type ?? 'all'} onChange={(e) => setF({ pay_type: e.target.value as Filters['pay_type'] })}>
          <option value="all">نقدي وذمم</option><option value="cash">نقدي</option><option value="credit">ذمم</option></select></Field>
        <Field label="أصناف (أكواد)" hint="فارغ = كل الأصناف">
          <input defaultValue={codes} onBlur={(e) => setF({ products: e.target.value.split(/[\s,،]+/).filter(Boolean)
            .map((code) => products.find((p) => p.code === code)?.id).filter((x): x is number => !!x) })} />
        </Field>
      </>}
      {c.metric === 'reactivated' && <Field label="N يومًا"><input inputMode="numeric" value={f.days ?? 90} onChange={(e) => setF({ days: e.target.value })} /></Field>}
      {['collection', 'collection_ratio'].includes(c.metric) && (
        <Field label="أساس التحصيل"><select value={f.basis ?? 'collector'} onChange={(e) => setF({ basis: e.target.value as Filters['basis'] })}>
          <option value="collector">مندوب التحصيل في السند</option><option value="invoice_rep">مندوب الفاتورة المسددة</option></select></Field>
      )}
      {def.kind !== 'relative' && <label className="check"><input type="checkbox" checked={c.affected} onChange={(e) => onChange({ ...c, affected: e.target.checked })} /> يتأثر بتعديل أيام العمل</label>}
      <button className="btn link" onClick={onRemove}>حذف المكوّن</button>
    </div>
  );
}

// ---------------------------------------------------------------------
// نسخ شهر، تعديل جماعي، القوالب
// ---------------------------------------------------------------------
function CopyMonth({ role, month, onClose, onDone }: { role: Role; month: string; onClose: () => void; onDone: () => void }) {
  const [from, setFrom] = useState(addMonths(month, -1));
  const [pv, setPv] = useState<{ employee: string }[] | null>(null);
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  useEffect(() => { run(async () => setPv(await rpc('copy_goal_plans', { p_from: from, p_to: month, p_role: role, p_commit: false }))); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [from]);
  const go = () => run(async () => { await guarded((code) => rpc('copy_goal_plans', { p_from: from, p_to: month, p_role: role, p_commit: true, p_code: code })); onDone(); });
  return (
    <Modal title={`نسخ الخطط إلى ${fmtMonth(month)}`} onClose={onClose} footer={<><button className="btn primary" disabled={busy || !pv?.length} onClick={go}>نسخ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="من شهر"><input type="month" value={monthInput(from)} onChange={(e) => setFrom(fromMonthInput(e.target.value))} /></Field>
      {pv && (pv.length ? <Msg kind="ok">تُنسخ خطط {pv.length} موظف بلا خطة في الشهر الحالي: {pv.map((x) => x.employee).join('، ')}. يحتفظ كل مكوّن بإعداده.</Msg>
        : <Msg>لا خطط للنسخ: إما لا خطط في الشهر المصدر أو للجميع خطط في هذا الشهر.</Msg>)}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function BulkAdjust({ plans, onClose, onDone }: { plans: number[]; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ tier: 'A', metric: 'net_sales', mode: 'percent', value: '' });
  const [pv, setPv] = useState<{ plan_id: number; employee: string; before: string; after: string }[] | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const args = () => ({ p_plans: plans, p_tier: f.tier, p_metric: f.metric, p_mode: f.mode, p_value: f.value });
  const preview = () => run(async () => setPv(await rpc('bulk_adjust_goals', { ...args(), p_commit: false })));
  const go = () => run(async () => { await guarded((code) => rpc('bulk_adjust_goals', { ...args(), p_commit: true, p_reason: reason, p_code: code })); onDone(); });
  const kind = metricDef(f.metric).kind;
  return (
    <Modal title={`تعديل جماعي — ${plans.length} خطة`} onClose={onClose} footer={<>
      <button className="btn" disabled={busy || f.value === ''} onClick={preview}>معاينة</button>
      <button className="btn primary" disabled={busy || !pv || !reason.trim()} onClick={go}>اعتماد</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="الشريحة" hint="فارغ = الأهداف المستقلة"><input value={f.tier} onChange={(e) => { setF({ ...f, tier: e.target.value.toUpperCase() }); setPv(null); }} /></Field>
        <Field label="المقياس"><select value={f.metric} onChange={(e) => { setF({ ...f, metric: e.target.value }); setPv(null); }}>{METRICS.map((m) => <option key={m.code} value={m.code}>{m.label}</option>)}</select></Field>
        <Field label="الطريقة"><select value={f.mode} onChange={(e) => { setF({ ...f, mode: e.target.value }); setPv(null); }}><option value="percent">تغيير بنسبة %</option><option value="set">قيمة جديدة</option></select></Field>
        <Field label="القيمة"><input inputMode="decimal" value={f.value} onChange={(e) => { setF({ ...f, value: e.target.value }); setPv(null); }} /></Field>
      </div>
      {pv && (pv.length ? <table className="inner"><thead><tr><th>الموظف</th><th>قبل</th><th>بعد</th></tr></thead>
        <tbody>{pv.map((r) => <tr key={r.plan_id}><td>{r.employee}</td><td className="num diff-old">{fmtMetric(r.before, kind)}</td><td className="num diff-new">{fmtMetric(r.after, kind)}</td></tr>)}</tbody></table>
        : <Msg>لا يوجد هذا المكوّن في الخطط المختارة.</Msg>)}
      <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function Templates({ role, plans, onClose, onDone }: { role: Role; plans: number[]; onClose: () => void; onDone: () => void }) {
  const { can } = useAuth();
  const [list, setList] = useState<Template[] | null>(null);
  const [apply, setApply] = useState<Template | null>(null);
  const [pv, setPv] = useState<{ plan_id: number; employee: string; closed: boolean }[] | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const load = () => run(async () => setList(await rpc<Template[]>('goal_templates_list', { p_role: role })));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);
  const preview = (t: Template) => run(async () => { setApply(t); setPv(await rpc('apply_goal_template', { p_template: t.id, p_plans: plans, p_commit: false })); });
  const go = () => run(async () => { await guarded((code) => rpc('apply_goal_template', { p_template: apply!.id, p_plans: plans, p_commit: true, p_reason: reason, p_code: code })); onDone(); });
  const del = (t: Template) => run(async () => { await rpc('delete_goal_template', { p_id: t.id }); load(); });
  return (
    <Modal wide title="قوالب الأهداف" onClose={onClose}>
      <p className="small muted">القالب ينشئ مكونات قابلة للتعديل ويحتفظ كل مكوّن بإعداده. تعديل القالب لا يغيّر الخطط القديمة تلقائيًا؛ تحديثها باختيارها ومعاينة التغييرات.</p>
      {list && (list.length === 0 ? <p className="muted">لا قوالب. احفظ خطة كقالب من محرر الخطة.</p> : (
        <table className="inner"><thead><tr><th>القالب</th><th>المكونات</th><th>خطط منه</th><th></th></tr></thead>
          <tbody>{list.map((t) => (
            <tr key={t.id}><td>{t.name}</td><td className="small">{(t.data.components ?? []).map((c) => `${c.tier ?? ''} ${metricDef(c.metric).label} ${c.target ?? ''}`).join('، ')}</td>
              <td className="num">{t.plans}</td>
              <td className="actions">{can(pageOf(role), 'edit') && <button className="btn link" disabled={!plans.length} onClick={() => preview(t)}>تطبيق على المختارة ({plans.length})</button>}
                {can(pageOf(role), 'delete') && <button className="btn link" onClick={() => del(t)}>حذف</button>}</td></tr>
          ))}</tbody></table>
      ))}
      {apply && pv && (
        <div className="panel">
          <h3>معاينة تطبيق «{apply.name}»</h3>
          <p className="small">تُستبدل الشرائح والمكونات في {pv.length} خطة: {pv.map((x) => x.employee + (x.closed ? ' (شهر مقفل)' : '')).join('، ')}</p>
          <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          <button className="btn primary" disabled={busy || !reason.trim()} onClick={go}>اعتماد التحديث</button>
        </div>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
