// P11 «قواعد العمولة»: قواعد الشهر بشرائحها (نسبة المندوب بالمئة والمشرف بالألف) ومشموليها،
// ومعاينة الأثر قبل الحفظ، ونسخ شهر، ومن لا قاعدة له (إعداد ناقص). وللإدارة: مندوبو عمولة التحصيل (COMM-008)،
// وحد عمر الدين بتاريخ سريان، ومندوب تحصيل الافتتاحي لكل عميل، ونسبة المشرف الشخصية (COMM-006)،
// وتذكير مراجعة نسب الأصناف أول الشهر (REVIEW-001).
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, fmtMonth, fmtPct, todayIso } from '../lib/format';
import { addMonths, fromMonthInput, monthInput, thisMonth, tierClass, useEmployees, WARN_LABEL } from '../lib/goals';
import { Badge, Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { CustomerPicker, PickedCustomer } from '../components/CustomerPicker';
import { AuditList } from './Settings';

interface RuleTier { tier: string; sort: number; rep_rate: string | number | null; sup_rate: string | number | null }
interface Member { employee_id: number; name: string; emp_number: string }
interface Rule { id: number; month: string; name: string; note: string | null; tiers: RuleTier[]; members: Member[]; hidden_members?: number }
interface MonthRes {
  month: string; closed: boolean; rules: Rule[]; uncovered: Member[];
  collection_reps: { id: number; employee_id: number; name: string; emp_number: string; from_month: string; to_month: string | null }[];
  debt_age: { current: string | number | null; history: { value: string | number | null; effective_from: string }[] };
  opening_reps: { customer_id: number; customer_number: string; customer: string; employee_id: number | null; employee: string | null; effective_from: string }[];
  personal_rates: { employee_id: number; name: string; rate: string | number | null; unit: 'pct' | 'permille' | null; personal_sales: string | number }[];
  review: { decision: string; note: string | null; at: string; by_name: string | null } | null;
  review_due: boolean; default_tiers: string[];
}

export function CommissionRules() {
  const { can, profile } = useAuth();
  const admin = !!profile?.is_admin;
  const [month, setMonth] = useState(thisMonth());
  const [d, setD] = useState<MonthRes | null>(null);
  const [ver, setVer] = useState(0);
  const [tab, setTab] = useState('rules');
  const [edit, setEdit] = useState<Rule | 'new' | null>(null);
  const [log, setLog] = useState<Rule | null>(null);
  const [del, setDel] = useState<Rule | null>(null);
  const [copy, setCopy] = useState(false);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<MonthRes>('commission_month', { p_month: month }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, ver]);
  const refresh = () => setVer(ver + 1);

  return (
    <>
      <div className="page-head">
        <h1>قواعد العمولة</h1>
        <div className="actions">
          {can('P11', 'add') && <button className="btn" onClick={() => setCopy(true)}>نسخ من شهر</button>}
          {can('P11', 'add') && <button className="btn primary" onClick={() => setEdit('new')}>قاعدة جديدة</button>}
        </div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        {d?.closed && <Badge kind="warn">شهر مغلق</Badge>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && admin && d.review_due && <ReviewReminder month={month} onDone={refresh} />}
      {d && d.review && <p className="small muted">مراجعة نسب الأصناف لهذا الشهر: {d.review.decision === 'no_change' ? 'لا تغيير' : 'تم التعديل'} — {d.review.by_name} {fmtDateTime(d.review.at)}{d.review.note && ` · ${d.review.note}`}</p>}
      <div className="tabs" role="tablist" style={{ marginBottom: 10 }}>
        <button role="tab" aria-selected={tab === 'rules'} onClick={() => setTab('rules')}>القواعد</button>
        <button role="tab" aria-selected={tab === 'collection'} onClick={() => setTab('collection')}>عمولة التحصيل</button>
        <button role="tab" aria-selected={tab === 'personal'} onClick={() => setTab('personal')}>نسب المشرفين الشخصية</button>
      </div>
      {d && tab === 'rules' && (
        <>
          {d.uncovered.length > 0 && <Msg>إعداد ناقص: {d.uncovered.length} موظف بلا قاعدة لهذا الشهر فتبقى عمولتهم غير مكتملة: {d.uncovered.map((u) => u.name).join('، ')}</Msg>}
          {d.rules.length === 0 ? <div className="panel empty">لا قواعد لهذا الشهر. غياب القاعدة لا يختار قاعدة سابقة ضمنًا؛ أنشئ قاعدة أو انسخ من شهر.</div> : d.rules.map((r) => (
            <div key={r.id} className="panel">
              <div className="page-head" style={{ marginBottom: 6 }}>
                <h2>{r.name}</h2>
                <div className="actions">
                  <button className="btn link" onClick={() => setLog(r)}>السجل</button>
                  {can('P11', 'edit') && <button className="btn" onClick={() => setEdit(r)}>تعديل</button>}
                  {can('P11', 'delete') && <button className="btn danger" onClick={() => setDel(r)}>حذف</button>}
                </div>
              </div>
              {r.note && <p className="small muted">{r.note}</p>}
              <table className="inner" style={{ maxWidth: 520 }}>
                <thead><tr><th>الشريحة</th><th className="num">المندوب %</th><th className="num">المشرف ‰</th></tr></thead>
                <tbody>{r.tiers.map((t) => (
                  <tr key={t.tier}><td><b className={tierClass(t.tier)}>{t.tier}</b></td>
                    <td className="num">{t.rep_rate === null ? <span className="muted">من الأصناف</span> : fmtPct(t.rep_rate)}</td>
                    <td className="num">{t.sup_rate === null ? <span className="muted">من الأصناف</span> : fmtPct(t.sup_rate)}</td></tr>
                ))}</tbody>
              </table>
              <p className="small" style={{ marginBottom: 0 }}>المشمولون ({r.members.length + (r.hidden_members ?? 0)}): {r.members.map((m) => m.name).join('، ') || '—'}{r.hidden_members ? ` و${r.hidden_members} خارج نطاقك` : ''}</p>
            </div>
          ))}
          <p className="small muted">نسبة الشريحة الفارغة تعني استخدام نسبة الصنف بحسب تاريخ السند؛ ونسبة الصنف الفارغة تجعل العمولة غير مكتملة.</p>
        </>
      )}
      {d && tab === 'collection' && <CollectionTab d={d} month={month} admin={admin} onDone={refresh} />}
      {d && tab === 'personal' && <PersonalTab d={d} month={month} admin={admin} onDone={refresh} />}
      {edit && <RuleEditor month={month} rule={edit === 'new' ? null : edit} defaults={d?.default_tiers ?? ['A', 'B', 'C', 'X']} onClose={() => setEdit(null)} onDone={() => { setEdit(null); refresh(); }} />}
      {log && <Drawer title={`سجل القاعدة «${log.name}»`} onClose={() => setLog(null)}><AuditList entity="commission_rules" entityId={String(log.id)} /></Drawer>}
      {del && <DeleteRule rule={del} onClose={() => setDel(null)} onDone={() => { setDel(null); refresh(); }} />}
      {copy && <CopyRules month={month} onClose={() => setCopy(false)} onDone={() => { setCopy(false); refresh(); }} />}
    </>
  );
}

function ReviewReminder({ month, onDone }: { month: string; onDone: () => void }) {
  const [note, setNote] = useState('');
  const { busy, error, run } = useAction();
  const go = (decision: string) => run(async () => { await rpc('record_rate_review', { p_month: month, p_decision: decision, p_note: note || null }); onDone(); });
  return (
    <div className="msg warn">
      <b>تذكير أول الشهر:</b> راجع نسب عمولة الأصناف لشهر {fmtMonth(month)} ثم سجّل القرار.
      <div className="actions" style={{ marginTop: 6 }}>
        <input className="input" style={{ width: 'auto', minWidth: 220 }} placeholder="ملاحظة (اختياري)" value={note} onChange={(e) => setNote(e.target.value)} aria-label="ملاحظة المراجعة" />
        <button className="btn" disabled={busy} onClick={() => go('no_change')}>لا تغيير</button>
        <button className="btn" disabled={busy} onClick={() => go('edited')}>تم التعديل</button>
      </div>
      {error && <Msg kind="bad">{error}</Msg>}
    </div>
  );
}

interface PreviewRow { employee_id: number; name: string; before: { base: string | null; tier: string | null; status: string }; after: { base: string | null; tier: string | null; status: string; warnings: { code: string; message: string }[] } }

function RuleEditor({ month, rule, defaults, onClose, onDone }: { month: string; rule: Rule | null; defaults: string[]; onClose: () => void; onDone: () => void }) {
  const emps = useEmployees();
  const [name, setName] = useState(rule?.name ?? '');
  const [note, setNote] = useState(rule?.note ?? '');
  const [tiers, setTiers] = useState<RuleTier[]>(rule?.tiers ?? defaults.map((t, i) => ({ tier: t, sort: i + 1, rep_rate: '', sup_rate: '' })));
  const [members, setMembers] = useState<number[]>(rule?.members.map((m) => Number(m.employee_id)) ?? []);
  const [search, setSearch] = useState('');
  const [pv, setPv] = useState<PreviewRow[] | null>(null);
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const payload = () => ({ month, name, note, tiers: tiers.map((t, i) => ({ ...t, sort: i + 1, rep_rate: t.rep_rate ?? '', sup_rate: t.sup_rate ?? '' })), members });
  const change = (fn: () => void) => { fn(); setPv(null); };
  const preview = () => run(async () => setPv(await rpc<PreviewRow[]>('preview_commission_rule', { p_id: rule?.id ?? null, p: payload() })));
  const save = () => run(async () => { await guarded((code) => rpc('save_commission_rule', { p_id: rule?.id ?? null, p: payload(), p_reason: rule ? reason : null, p_code: code })); onDone(); });
  const shown = emps.filter((e) => e.status === 'نشط' || members.includes(Number(e.id))).filter((e) => !search || e.name.includes(search) || e.emp_number === search.trim());
  return (
    <Modal wide title={rule ? `تعديل «${rule.name}»` : `قاعدة جديدة — ${fmtMonth(month)}`} onClose={onClose} footer={<>
      <button className="btn" disabled={busy} onClick={preview}>معاينة الأثر</button>
      <button className="btn primary" disabled={busy || !name.trim() || (!!rule && !reason.trim())} onClick={save}>حفظ</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="اسم القاعدة"><input value={name} onChange={(e) => change(() => setName(e.target.value))} /></Field>
        <Field label="ملاحظة"><input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      </div>
      <h3>الشرائح</h3>
      <div className="tbl"><table className="edit-grid">
        <thead><tr><th>الشريحة</th><th>نسبة المندوب %</th><th>نسبة المشرف ‰</th><th></th></tr></thead>
        <tbody>{tiers.map((t, i) => (
          <tr key={i}>
            <td><input className="input" style={{ width: 70 }} value={t.tier} aria-label="الشريحة" onChange={(e) => change(() => setTiers(tiers.map((x, j) => (j === i ? { ...x, tier: e.target.value.toUpperCase() } : x))))} /></td>
            <td><input className="input" inputMode="decimal" placeholder="من الأصناف" value={t.rep_rate ?? ''} aria-label="نسبة المندوب" onChange={(e) => change(() => setTiers(tiers.map((x, j) => (j === i ? { ...x, rep_rate: e.target.value } : x))))} /></td>
            <td><input className="input" inputMode="decimal" placeholder="من الأصناف" value={t.sup_rate ?? ''} aria-label="نسبة المشرف" onChange={(e) => change(() => setTiers(tiers.map((x, j) => (j === i ? { ...x, sup_rate: e.target.value } : x))))} /></td>
            <td><button className="btn link" onClick={() => change(() => setTiers(tiers.filter((_, j) => j !== i)))}>حذف</button></td>
          </tr>
        ))}</tbody></table></div>
      <div><button className="btn" onClick={() => change(() => setTiers([...tiers, { tier: '', sort: tiers.length + 1, rep_rate: '', sup_rate: '' }]))}>إضافة شريحة</button></div>
      <h3>المشمولون ({members.length}) <span className="small muted">— قاعدة واحدة للموظف في الشهر</span></h3>
      <input className="input" placeholder="بحث بالاسم أو الرقم" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="بحث الموظفين" />
      <div className="member-grid">{shown.map((e) => (
        <label key={e.id} className="check"><input type="checkbox" checked={members.includes(Number(e.id))}
          onChange={(ev) => change(() => setMembers(ev.target.checked ? [...members, Number(e.id)] : members.filter((x) => x !== Number(e.id))))} /> {e.emp_number} — {e.name}</label>
      ))}</div>
      {pv && (
        <div className="panel">
          <h3>الأثر على العمولة الأساسية</h3>
          {pv.length === 0 ? <p className="muted small">لا مشمولين.</p> : (
            <table className="inner"><thead><tr><th>الموظف</th><th>الشريحة</th><th className="num">قبل</th><th className="num">بعد</th><th>الحالة بعد</th></tr></thead>
              <tbody>{pv.map((r) => (
                <tr key={r.employee_id}><td>{r.name}</td><td><b className={tierClass(r.after?.tier)}>{r.after?.tier ?? '—'}</b></td>
                  <td className="num diff-old">{r.before?.base === null || r.before?.base === undefined ? 'غير مكتملة' : fmtAmount(r.before.base)}</td>
                  <td className="num diff-new">{r.after?.base === null || r.after?.base === undefined ? 'غير مكتملة' : fmtAmount(r.after.base)}</td>
                  <td className="wrap small">{r.after?.status === 'complete' ? <Badge kind="ok">مكتملة</Badge> : (r.after?.warnings ?? []).map((w) => WARN_LABEL[w.code] ?? w.message).join('، ')}</td></tr>
              ))}</tbody></table>
          )}
        </div>
      )}
      {rule && <Field label="سبب التعديل"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function DeleteRule({ rule, onClose, onDone }: { rule: Rule; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const go = () => run(async () => { await guarded((code) => rpc('delete_commission_rule', { p_id: rule.id, p_reason: reason, p_code: code })); onDone(); });
  return (
    <Modal title={`حذف «${rule.name}»`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={go}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>يصبح مشمولوها ({rule.members.length}) بلا قاعدة فتظهر عمولتهم غير مكتملة.</Msg>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function CopyRules({ month, onClose, onDone }: { month: string; onClose: () => void; onDone: () => void }) {
  const [from, setFrom] = useState(addMonths(month, -1));
  const [n, setN] = useState<number | null>(null);
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const go = () => run(async () => { setN(await guarded((code) => rpc<number>('copy_commission_rules', { p_from: from, p_to: month, p_code: code }))); });
  return (
    <Modal title={`نسخ القواعد إلى ${fmtMonth(month)}`} onClose={onClose} footer={n === null
      ? <><button className="btn primary" disabled={busy} onClick={go}>نسخ</button><button className="btn" onClick={onClose}>إلغاء</button></>
      : <button className="btn primary" onClick={onDone}>تم</button>}>
      <Field label="من شهر"><input type="month" value={monthInput(from)} onChange={(e) => setFrom(fromMonthInput(e.target.value))} /></Field>
      <p className="small muted">يُنسخ لشهر بلا قواعد فقط، ويُنقل من المشمولين من له فترة عمل في الشهر الجديد.</p>
      {n !== null && <Msg kind="ok">نُسخت {n} قاعدة.</Msg>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// عمولة التحصيل (COMM-008) وحد عمر الدين ومندوبو الافتتاحي
// ---------------------------------------------------------------------
function CollectionTab({ d, month, admin, onDone }: { d: MonthRes; month: string; admin: boolean; onDone: () => void }) {
  const emps = useEmployees();
  const [emp, setEmp] = useState('');
  const [days, setDays] = useState('');
  const [from, setFrom] = useState(todayIso());
  const [cust, setCust] = useState<PickedCustomer | null>(null);
  const [orep, setOrep] = useState('');
  const [ofrom, setOfrom] = useState(todayIso());
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const active = d.collection_reps.filter((c) => c.from_month <= month && (!c.to_month || c.to_month >= month));
  const toggle = (employee: number, on: boolean) => run(async () => { await guarded((code) => rpc('set_collection_rep', { p_employee: employee, p_from_month: month, p_on: on, p_code: code })); setEmp(''); onDone(); });
  return (
    <>
      <div className="panel">
        <h2>مندوبو عمولة التحصيل في {fmtMonth(month)}</h2>
        <p className="small muted">عمولة المندوب المختار تُحسب على ما سُدد من فواتيره خلال الشهر ضمن مهلة الاستحقاق وحد عمر الدين، بشريحة شهر الفاتورة، وتبقى الذمم غير المسددة مؤجلة حتى سدادها. يسري الاختيار من الشهر المحدد.</p>
        {active.length === 0 ? <p className="muted">لا مندوبين مختارين لهذا الشهر.</p> : (
          <table className="inner" style={{ maxWidth: 640 }}><thead><tr><th>المندوب</th><th>من</th><th>إلى</th><th></th></tr></thead>
            <tbody>{active.map((c) => (
              <tr key={c.id}><td>{c.emp_number} — {c.name}</td><td className="num">{fmtMonth(c.from_month)}</td><td className="num">{c.to_month ? fmtMonth(c.to_month) : 'مستمر'}</td>
                <td>{admin && <button className="btn link" disabled={busy} onClick={() => toggle(c.employee_id, false)}>إيقاف من هذا الشهر</button>}</td></tr>
            ))}</tbody></table>
        )}
        {admin && (
          <div className="actions" style={{ marginTop: 8 }}>
            <select className="input" style={{ width: 'auto' }} value={emp} onChange={(e) => setEmp(e.target.value)} aria-label="المندوب">
              <option value="">اختر مندوبًا</option>
              {emps.filter((e) => e.status === 'نشط' && !active.some((a) => String(a.employee_id) === String(e.id))).map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}
            </select>
            <button className="btn primary" disabled={busy || !emp} onClick={() => toggle(Number(emp), true)}>اختيار من {fmtMonth(month)}</button>
          </div>
        )}
      </div>
      <div className="panel">
        <h2>حد عمر الدين</h2>
        <p>الحالي: <b className="num">{d.debt_age.current === null ? '30 (الافتراضي)' : String(d.debt_age.current)}</b> يومًا بعد الاستحقاق؛ السداد بعده لا يستحق عمولة.</p>
        {d.debt_age.history.length > 0 && <p className="small muted">السجل: {d.debt_age.history.map((h) => `${h.value ?? 'افتراضي'} من ${fmtDate(h.effective_from)}`).join(' · ')}</p>}
        {admin && (
          <div className="actions">
            <input className="input" style={{ width: 120 }} inputMode="numeric" placeholder="فارغ = 30" value={days} onChange={(e) => setDays(e.target.value)} aria-label="عدد الأيام" />
            <input className="input" style={{ width: 'auto' }} type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="يسري من" />
            <button className="btn" disabled={busy} onClick={() => run(async () => { await rpc('save_debt_age', { p_days: days === '' ? null : days, p_from: from }); setDays(''); onDone(); })}>حفظ</button>
          </div>
        )}
      </div>
      <div className="panel">
        <h2>مندوب عمولة تحصيل الافتتاحي</h2>
        <p className="small muted">تحصيل الرصيد الافتتاحي يمنح عمولة للمندوب المحدد للعميل بنسبة شريحته في قاعدة الشهر، أو لا أحد.</p>
        {d.opening_reps.length > 0 && (
          <table className="inner"><thead><tr><th>العميل</th><th>المندوب</th><th>من</th></tr></thead>
            <tbody>{d.opening_reps.map((o, i) => <tr key={i}><td>{o.customer_number} — {o.customer}</td><td>{o.employee ?? 'لا أحد'}</td><td className="num">{fmtDate(o.effective_from)}</td></tr>)}</tbody></table>
        )}
        {admin && (
          <div className="grid3" style={{ marginTop: 8, alignItems: 'end' }}>
            <CustomerPicker value={cust} onChange={setCust} />
            <Field label="المندوب"><select value={orep} onChange={(e) => setOrep(e.target.value)}><option value="">لا أحد</option>
              {emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}</select></Field>
            <Field label="يسري من"><input type="date" value={ofrom} onChange={(e) => setOfrom(e.target.value)} /></Field>
            <div><button className="btn primary" disabled={busy || !cust} onClick={() => run(async () => { await rpc('set_opening_rep', { p_customer: cust!.id, p_employee: orep || null, p_from: ofrom }); setCust(null); onDone(); })}>حفظ</button></div>
          </div>
        )}
      </div>
      {error && <Msg kind="bad">{error}</Msg>}
    </>
  );
}

function PersonalTab({ d, month, admin, onDone }: { d: MonthRes; month: string; admin: boolean; onDone: () => void }) {
  const [vals, setVals] = useState<Record<number, { rate: string; unit: string }>>({});
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const get = (p: MonthRes['personal_rates'][number]) => vals[p.employee_id] ?? { rate: p.rate === null ? '' : String(p.rate), unit: p.unit ?? 'pct' };
  const save = (p: MonthRes['personal_rates'][number]) => run(async () => {
    const v = get(p);
    await guarded((code) => rpc('set_personal_rate', { p_month: month, p_employee: p.employee_id, p_rate: v.rate === '' ? null : v.rate, p_unit: v.unit, p_code: code }));
    onDone();
  });
  return (
    <div className="panel">
      <h2>نسب مبيعات المشرفين الشخصية — {fmtMonth(month)}</h2>
      <p className="small muted">مبيعات المشرف الشخصية تنتظر نسبة الإدارة لهذا الشهر؛ وحتى تحديدها تبقى عمولته معلّقة وغير مكتملة.</p>
      {d.personal_rates.length === 0 ? <p className="muted">لا مشرفين في هذا الشهر.</p> : (
        <table className="inner"><thead><tr><th>المشرف</th><th className="num">مبيعاته الشخصية</th><th>النسبة</th><th>الوحدة</th><th></th></tr></thead>
          <tbody>{d.personal_rates.map((p) => {
            const v = get(p);
            return (
              <tr key={p.employee_id}><td>{p.name}</td><td className="num">{fmtAmount(p.personal_sales)}</td>
                <td>{admin ? <input className="input" style={{ width: 100 }} inputMode="decimal" value={v.rate} aria-label="النسبة"
                  onChange={(e) => setVals({ ...vals, [p.employee_id]: { ...v, rate: e.target.value } })} /> : p.rate === null ? <Badge kind="warn">معلّقة</Badge> : fmtPct(p.rate)}</td>
                <td>{admin ? <select className="input" style={{ width: 'auto' }} value={v.unit} aria-label="الوحدة" onChange={(e) => setVals({ ...vals, [p.employee_id]: { ...v, unit: e.target.value } })}>
                  <option value="pct">بالمئة %</option><option value="permille">بالألف ‰</option></select> : p.unit === 'permille' ? '‰' : p.unit ? '%' : ''}</td>
                <td>{admin && <button className="btn link" disabled={busy} onClick={() => save(p)}>حفظ</button>}</td></tr>
            );
          })}</tbody></table>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </div>
  );
}
