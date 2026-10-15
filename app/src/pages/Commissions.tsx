// P14 «كشف العمولات» وP14a «حسابات العمولات»: ملخص الشهر لكل موظف بأعمدة أهداف ديناميكية (COMM-003)،
// وكشف الموظف بمراحل الحساب بالترتيب المعتمد (B024): المبيعات المؤهلة ← الشريحة المحسوبة ← الشريحة اليدوية ←
// العمولة الأساسية بسطورها ← تصفير الأساسية ← المكافآت ← الإضافات والخصومات ← تصفير كامل المستحق ← النهائي.
// قرارات الصرف بسبب ومعاينة قبل الاعتماد، والمسدد والمؤجل لعمولة التحصيل، والأخطاء المؤثرة.
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtDateTime, fmtMonth, fmtPct } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { fmtMetric, fromMonthInput, Kind, monthInput, ROLE_LABEL, SOURCE_LABEL, SRC_LABEL, thisMonth, tierClass, WARN_LABEL } from '../lib/goals';
import { Badge, Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';

type N = string | number | null;
interface Warn { code: string; blocking: boolean; message: string; items?: { code: string; name: string }[] }
interface SumRow {
  employee_id: number; name: string; emp_number: string; role: string; rule_name: string | null; tier: string | null; tier_calc: string | null;
  eligible: N; team_eligible: N; personal_eligible: N; base: N; rewards: N; adjustments: N; final: N; status: string; collection_mode: boolean;
  warnings: Warn[]; goals: Record<string, { final: N; actual: N; pct: N; kind: Kind }>;
}
interface SumRes { month: string; closed: boolean; version: number | null; rows: SumRow[]; goal_columns: { key: string; tier: string; metric: string; label: string }[] }

export function Commissions() {
  const { can } = useAuth();
  const [month, setMonth] = useState(thisMonth());
  const [d, setD] = useState<SumRes | null>(null);
  const [ver, setVer] = useState(0);
  const [open, setOpen] = useState<number | null>(null);
  const [search, setSearch] = useState('');
  const [onlyBad, setOnlyBad] = useState(false);
  const load = useAction();
  useEffect(() => { let live = true; setD(null); load.run(async () => { const r = await rpc<SumRes>('commission_summary', { p_month: month }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, ver]);
  const rows = (d?.rows ?? []).filter((r) => (!search || r.name.includes(search) || r.emp_number === search.trim()) && (!onlyBad || r.status !== 'complete'));
  const cols = d?.goal_columns ?? [];
  const total = (k: keyof SumRow) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0);
  const doExport = () => writeSheet(`العمولات ${fmtMonth(month).replace('/', '-')}.xlsx`, 'العمولات',
    ['الرقم', 'الموظف', 'الدور', 'القاعدة', 'الشريحة', ...cols.flatMap((c) => [`${c.tier} ${c.label} — الهدف`, `${c.tier} ${c.label} — المحقق`]),
      'المبيعات المؤهلة', 'العمولة الأساسية', 'المكافآت', 'الإضافات والخصومات', 'المستحق النهائي', 'الحالة', 'التنبيهات'],
    rows.map((r) => [r.emp_number, r.name, ROLE_LABEL[r.role] ?? r.role, r.rule_name, r.tier,
      ...cols.flatMap((c) => [r.goals[c.key]?.final ?? null, r.goals[c.key]?.actual ?? null].map((v) => (v === null ? null : Number(v)))),
      num(r.eligible), num(r.base), num(r.rewards), num(r.adjustments), num(r.final), r.status === 'complete' ? 'مكتملة' : 'غير مكتملة',
      r.warnings.map((w) => w.message).join('؛ ')]));

  return (
    <>
      <div className="page-head">
        <h1>كشف العمولات</h1>
        <div className="actions">{can('P14', 'export') && <button className="btn" disabled={!d} onClick={doExport}>تصدير Excel</button>}</div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        <input className="input" placeholder="بحث بالاسم أو الرقم" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="بحث" />
        <label className="check"><input type="checkbox" checked={onlyBad} onChange={(e) => setOnlyBad(e.target.checked)} /> غير المكتملة فقط</label>
        {d && <span className="count">{rows.length} موظف{d.closed && ` · شهر مغلق (النسخة ${d.version})`}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {d && (
        <div className="stats">
          <div className="stat"><div className="l">المبيعات المؤهلة دون تكرار الفريق</div><div className="v num">{fmtAmount(total('personal_eligible'))}</div></div>
          <div className="stat"><div className="l">العمولة الأساسية</div><div className="v num">{fmtAmount(total('base'))}</div></div>
          <div className="stat"><div className="l">المكافآت</div><div className="v num">{fmtAmount(total('rewards'))}</div></div>
          <div className="stat"><div className="l">المستحق النهائي</div><div className="v num">{fmtAmount(total('final'))}</div></div>
          <div className="stat"><div className="l">غير مكتملة</div><div className="v num">{(d.rows ?? []).filter((r) => r.status !== 'complete').length}</div></div>
        </div>
      )}
      <div className="tbl"><table>
        <thead><tr><th>الموظف</th><th>الدور</th><th>القاعدة</th><th>الشريحة</th>
          {cols.map((c) => <th key={c.key} className="num">{c.tier !== '-' && <b className={tierClass(c.tier)}>{c.tier}</b>} {c.label}</th>)}
          <th className="num">المؤهلة</th><th className="num">الأساسية</th><th className="num">المكافآت</th><th className="num">القرارات</th><th className="num">النهائي</th><th>الحالة</th></tr></thead>
        <tbody>{!d ? <tr><td colSpan={10 + cols.length}><div className="skeleton" /></td></tr> : rows.length === 0 ? <tr><td colSpan={10 + cols.length} className="empty">لا موظفين لهذا الشهر</td></tr> : rows.map((r) => (
          <tr key={r.employee_id} className="clickable" onClick={() => setOpen(r.employee_id)}>
            <td><span className="num">{r.emp_number}</span> — {r.name}{r.collection_mode && <> <Badge kind="accent">تحصيل</Badge></>}</td>
            <td>{ROLE_LABEL[r.role] ?? r.role}</td><td>{r.rule_name ?? <span className="muted">—</span>}</td>
            <td><b className={tierClass(r.tier)}>{r.tier ?? 'NONE'}</b>{r.tier_calc !== r.tier && <span className="small muted"> (محسوبة {r.tier_calc ?? 'NONE'})</span>}</td>
            {cols.map((c) => { const g = r.goals[c.key]; return <td key={c.key} className="num">{g ? <>{fmtMetric(g.actual, g.kind)} / {fmtMetric(g.final, g.kind)}</> : ''}</td>; })}
            <td className="num">{fmtAmount(r.eligible)}</td><td className="num">{r.base === null ? '—' : fmtAmount(r.base)}</td>
            <td className="num">{fmtAmount(r.rewards)}</td><td className="num">{fmtAmount(r.adjustments)}</td>
            <td className="num"><b>{r.final === null ? '—' : fmtAmount(r.final)}</b></td>
            <td>{r.status === 'complete' ? <Badge kind="ok">مكتملة</Badge> : <Badge kind="bad" >غير مكتملة</Badge>}
              {r.warnings.filter((w) => !w.blocking).length > 0 && <> <Badge kind="warn">{r.warnings.filter((w) => !w.blocking).length} تنبيه</Badge></>}</td>
          </tr>
        ))}</tbody></table></div>
      {open && <Statement employeeId={open} month={month} onClose={() => setOpen(null)} onChanged={() => setVer(ver + 1)} />}
    </>
  );
}

const num = (v: N) => (v === null || v === undefined ? null : Number(v));

// ---------------------------------------------------------------------
// كشف الموظف
// ---------------------------------------------------------------------
interface Line { source: string; part: string; product_id: number | null; code: string | null; name: string | null; tier: string | null; rate: N; unit: string | null; src: string; value: N; commission: N; docs: number }
interface Adj { id: number; kind: string; amount: N; pct: N; base: string | null; value: N; reason: string; by: string | null; at: string }
interface Stmt {
  employee_id: number; month: string; role: string; rule_name: string | null; collection_mode: boolean; tier_calc: string | null; tier_manual: string | null; tier_effective: string | null;
  eligible: N; team_eligible: N; personal_eligible: N; personal_rate: { rate: N; unit: string } | null; base_commission: N; base_original: N; zero_base: boolean; zero_all: boolean;
  rewards: { id: number; name: string; amount: N; reason: string; counted: boolean; mode: string; group: string | null }[]; rewards_total: N;
  adjustments: Adj[]; adjustments_total: N; final: N; warnings: Warn[]; status: string; lines: Line[];
  paid: { doc_id: number; number: string; date: string; tier: string | null; customer: string; paid: N; commission: N }[];
  deferred: { doc_id: number; number: string; date: string; total: N; remaining: N; customer: string }[];
  goals: { achieved: string; components: { id: number; tier: string | null; label: string; final: N; actual: N; pct: N; kind: Kind; status: string; met: boolean }[]; days: { total: number; elapsed: number } } | null;
  snapshot: boolean; version?: number; snapshot_at?: string; closed: boolean; versions: number[] | null; employee: { id: number; name: string; emp_number: string };
}
const KIND_LABEL: Record<string, string> = { manual_tier: 'شريحة يدوية', add: 'إضافة', deduct: 'خصم', zero_base: 'تصفير العمولة الأساسية', zero_all: 'تصفير كامل المستحق' };
const partLabel = (part: string, role: string) => (part === 'team' ? 'الفريق' : role === 'supervisor' ? 'مبيعاته الشخصية' : 'مبيعاته');

function Statement({ employeeId, month, onClose, onChanged }: { employeeId: number; month: string; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [s, setS] = useState<Stmt | null>(null);
  const [version, setVersion] = useState<number | null>(null);
  const [ver, setVer] = useState(0);
  const [adj, setAdj] = useState(false);
  const [cancel, setCancel] = useState<Adj | null>(null);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<Stmt>('commission_statement', { p_employee: employeeId, p_month: month, p_version: version }); if (live) setS(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [employeeId, month, version, ver]);
  const changed = () => { setVer(ver + 1); onChanged(); };
  const pctText = (l: Line) => l.rate === null ? '—' : `${fmtPct(l.rate)}${l.unit === 'permille' ? '‰' : '%'}`;
  const editable = s && !s.snapshot && can('P14', 'edit');
  return (
    <Drawer title={s ? `كشف عمولة ${s.employee.name} — ${fmtMonth(month)}` : 'كشف العمولة'} onClose={onClose} actions={<>
      {s?.versions && s.versions.length > 0 && (
        <select className="input" style={{ width: 'auto' }} value={version ?? ''} onChange={(e) => setVersion(e.target.value ? Number(e.target.value) : null)} aria-label="النسخة">
          <option value="">{s.closed ? 'آخر نسخة معتمدة' : 'الحساب الحالي'}</option>
          {s.versions.map((v) => <option key={v} value={v}>النسخة {v}</option>)}
        </select>
      )}
      {can('P14', 'print') && <button className="btn" onClick={() => window.print()}>طباعة</button>}
      {editable && <button className="btn primary" onClick={() => setAdj(true)}>قرار صرف</button>}</>}>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {s && (
        <div className="print-doc">
          {/* رأس الوثيقة المطبوعة: النوع والموظف والفترة والنسخة (PRINT-001) */}
          <div className="print-only">
            <h2 className="doc-title">كشف عمولة — {fmtMonth(month)}</h2>
            <div className="doc-meta">
              <div>الموظف: <span className="num">{s.employee.emp_number}</span> — {s.employee.name} · {ROLE_LABEL[s.role] ?? s.role}</div>
              <div>{s.snapshot ? `النسخة المعتمدة رقم ${s.version}` : 'الحساب الحالي — غير معتمد'} · تاريخ الطباعة: <span className="num">{fmtDateTime(new Date().toISOString())}</span></div>
            </div>
          </div>
          {s.snapshot && <Msg>نسخة معتمدة رقم {s.version} محفوظة في {fmtDateTime(s.snapshot_at)}؛ لا تتغير بتعديل المصادر.</Msg>}
          {s.warnings.map((w, i) => (
            <Msg key={i} kind={w.blocking ? 'bad' : 'warn'}>
              <b>{WARN_LABEL[w.code] ?? w.code}:</b> {w.message}{w.items?.length ? ' — ' + w.items.map((x) => `${x.code} ${x.name}`).join('، ') : ''}
            </Msg>
          ))}
          <dl className="kv">
            <dt>الموظف</dt><dd>{s.employee.emp_number} — {s.employee.name} · {ROLE_LABEL[s.role] ?? s.role}</dd>
            <dt>القاعدة</dt><dd>{s.rule_name ?? '—'}{s.collection_mode && ' · عمولة تحصيل'}</dd>
            <dt>الحالة</dt><dd>{s.status === 'complete' ? <Badge kind="ok">مكتملة</Badge> : <Badge kind="bad">غير مكتملة</Badge>}</dd>
          </dl>
          <h3 style={{ marginTop: 10 }}>مراحل الحساب</h3>
          <table className="doc-table stages"><tbody>
            <tr><td>1. المبيعات المؤهلة</td><td className="num">{fmtAmount(s.eligible)}</td>
              <td className="small">{s.role === 'supervisor' && <>الفريق {fmtAmount(s.team_eligible)} · الشخصية {fmtAmount(s.personal_eligible)}{s.personal_rate && ` بنسبة ${fmtPct(s.personal_rate.rate)}${s.personal_rate.unit === 'permille' ? '‰' : '%'}`}</>}</td></tr>
            <tr><td>2. الشريحة المحسوبة</td><td><b className={tierClass(s.tier_calc)}>{s.tier_calc ?? 'NONE'}</b></td><td className="small">من الأهداف</td></tr>
            <tr><td>3. الشريحة اليدوية</td><td>{s.tier_manual ? <b className={tierClass(s.tier_manual)}>{s.tier_manual}</b> : '—'}</td><td className="small">المعتمدة: <b className={tierClass(s.tier_effective)}>{s.tier_effective ?? 'NONE'}</b></td></tr>
            <tr><td>4. العمولة الأساسية</td><td className="num">{s.base_original === null ? 'غير مكتملة' : fmtAmount(s.base_original)}</td><td className="small">مجموع السطور أدناه</td></tr>
            <tr><td>5. تصفير الأساسية</td><td className="num">{s.zero_base ? fmtAmount(0) : '—'}</td><td className="small">{s.zero_base ? 'مطبق' : ''}</td></tr>
            <tr><td>6. المكافآت</td><td className="num">{fmtAmount(s.rewards_total)}</td><td className="small">{s.rewards.filter((r) => r.counted).map((r) => r.name).join('، ')}</td></tr>
            <tr><td>7. الإضافات والخصومات</td><td className="num">{fmtAmount(s.adjustments_total)}</td><td className="small">{s.adjustments.filter((a) => a.kind === 'add' || a.kind === 'deduct').length} قرار</td></tr>
            <tr><td>8. تصفير كامل المستحق</td><td className="num">{s.zero_all ? fmtAmount(0) : '—'}</td><td className="small">{s.zero_all ? 'مطبق' : ''}</td></tr>
            <tr className="total"><td><b>المستحق النهائي</b></td><td className="num"><b>{s.final === null ? 'غير مكتمل' : fmtAmount(s.final)}</b></td><td></td></tr>
          </tbody></table>

          {s.goals && (
            <>
              <h3 style={{ marginTop: 10 }}>الأهداف — المحققة <b className={tierClass(s.goals.achieved)}>{s.goals.achieved}</b></h3>
              <table className="doc-table"><thead><tr><th>الشريحة</th><th>المكوّن</th><th>الهدف</th><th>المحقق</th><th>الإنجاز</th><th></th></tr></thead>
                <tbody>{s.goals.components.filter((c) => c.status !== 'unused').map((c) => (
                  <tr key={c.id}><td>{c.tier ?? '—'}</td><td>{c.label}</td><td className="num">{fmtMetric(c.final, c.kind)}</td><td className="num">{fmtMetric(c.actual, c.kind)}</td>
                    <td className="num">{c.pct ? fmtPct(c.pct) + '%' : ''}</td><td>{c.met ? '✓' : ''}</td></tr>
                ))}</tbody></table>
            </>
          )}

          <h3 style={{ marginTop: 10 }}>سطور العمولة الأساسية</h3>
          {s.lines.length === 0 ? <p className="muted small">لا سطور.</p> : (
            <table className="doc-table"><thead><tr><th>المصدر</th><th>الجزء</th><th>الصنف</th><th>الشريحة</th><th>النسبة</th><th>من</th><th className="num">القيمة</th><th className="num">العمولة</th><th className="num">سندات</th></tr></thead>
              <tbody>{s.lines.map((l, i) => (
                <tr key={i} className={l.src === 'missing' || l.src === 'pending' || l.src === 'no_tier' ? 'zero' : ''}>
                  <td>{SOURCE_LABEL[l.source] ?? l.source}</td><td>{partLabel(l.part, s.role)}</td><td>{l.code ? `${l.code} ${l.name}` : '—'}</td>
                  <td>{l.tier ?? '—'}</td><td className="num">{pctText(l)}</td><td className="small">{SRC_LABEL[l.src] ?? l.src}</td>
                  <td className="num">{fmtAmount(l.value)}</td><td className="num">{l.commission === null ? '—' : fmtAmount(l.commission)}</td><td className="num">{l.docs}</td></tr>
              ))}</tbody></table>
          )}

          {s.rewards.length > 0 && (
            <>
              <h3 style={{ marginTop: 10 }}>المكافآت</h3>
              <table className="doc-table"><thead><tr><th>المكافأة</th><th>السبب</th><th>الجمع</th><th className="num">المبلغ</th></tr></thead>
                <tbody>{s.rewards.map((r) => (
                  <tr key={r.id} className={r.counted ? '' : 'row-hidden'}><td>{r.name}</td><td>{r.reason}</td><td className="small">{r.group ? r.group + ' · ' : ''}{r.mode === 'STACK' ? 'جمع' : 'الأعلى فقط'}</td>
                    <td className="num">{fmtAmount(r.amount)}</td></tr>
                ))}</tbody></table>
            </>
          )}

          <h3 style={{ marginTop: 10 }}>قرارات الصرف</h3>
          {s.adjustments.length === 0 ? <p className="muted small">لا قرارات.</p> : (
            <table className="doc-table"><thead><tr><th>القرار</th><th>القيمة</th><th>السبب</th><th>بواسطة</th><th className="no-print"></th></tr></thead>
              <tbody>{s.adjustments.map((a) => (
                <tr key={a.id}><td>{KIND_LABEL[a.kind] ?? a.kind}</td>
                  <td className="num">{a.kind === 'add' || a.kind === 'deduct' ? <>{fmtAmount(a.value)}{a.pct !== null && <span className="small muted"> ({fmtPct(a.pct)}% من {a.base === 'eligible' ? 'المؤهلة' : 'الأساسية'})</span>}</> : ''}</td>
                  <td className="wrap">{a.reason}</td><td className="small">{a.by} {fmtDateTime(a.at)}</td>
                  <td className="no-print">{editable && <button className="btn link" onClick={() => setCancel(a)}>إلغاء</button>}</td></tr>
              ))}</tbody></table>
          )}

          {s.paid.length > 0 && (
            <>
              <h3 style={{ marginTop: 10 }}>المسدد من الذمم خلال الشهر</h3>
              <table className="doc-table"><thead><tr><th>الفاتورة</th><th>التاريخ</th><th>العميل</th><th>الشريحة</th><th className="num">المسدد</th><th className="num">العمولة</th></tr></thead>
                <tbody>{s.paid.map((p, i) => (
                  <tr key={i}><td className="num">{p.number ?? 'افتتاحي'}</td><td className="num">{fmtDate(p.date)}</td><td>{p.customer}</td><td>{p.tier ?? '—'}</td>
                    <td className="num">{fmtAmount(p.paid)}</td><td className="num">{p.commission === null ? '—' : fmtAmount(p.commission)}</td></tr>
                ))}</tbody></table>
            </>
          )}
          {s.deferred.length > 0 && (
            <>
              <h3 style={{ marginTop: 10 }}>ذمم مؤجلة غير مسددة (بلا عمولة حتى سدادها)</h3>
              <table className="doc-table"><thead><tr><th>الفاتورة</th><th>التاريخ</th><th>العميل</th><th className="num">القيمة</th><th className="num">المتبقي</th></tr></thead>
                <tbody>{s.deferred.map((p) => (
                  <tr key={p.doc_id}><td className="num">{p.number}</td><td className="num">{fmtDate(p.date)}</td><td>{p.customer}</td>
                    <td className="num">{fmtAmount(p.total)}</td><td className="num">{fmtAmount(p.remaining)}</td></tr>
                ))}</tbody></table>
            </>
          )}
        </div>
      )}
      {adj && s && <AdjustmentForm s={s} onClose={() => setAdj(false)} onDone={() => { setAdj(false); changed(); }} />}
      {cancel && <CancelAdj a={cancel} onClose={() => setCancel(null)} onDone={() => { setCancel(null); changed(); }} />}
    </Drawer>
  );
}

interface Pv { before: { tier: string | null; base: N; final: N }; after: { tier: string | null; base: N; final: N } }

function AdjustmentForm({ s, onClose, onDone }: { s: Stmt; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ kind: 'add', tier: '', by: 'amount', amount: '', pct: '', base: '', reason: '' });
  const [pv, setPv] = useState<Pv | null>(null);
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const set = (n: Partial<typeof f>) => { setF({ ...f, ...n }); setPv(null); };
  const payload = () => ({ kind: f.kind, tier: f.tier || null, amount: f.by === 'amount' ? f.amount : null, pct: f.by === 'pct' ? f.pct : null,
    base: f.by === 'pct' ? f.base || null : null, reason: f.reason });
  const preview = () => run(async () => setPv(await rpc<Pv>('preview_commission_adjustment', { p_employee: s.employee_id, p_month: s.month, p: payload() })));
  const save = () => run(async () => { await guarded((code) => rpc('save_commission_adjustment', { p_employee: s.employee_id, p_month: s.month, p: payload(), p_code: code })); onDone(); });
  const money = f.kind === 'add' || f.kind === 'deduct';
  return (
    <Modal title={`قرار صرف — ${s.employee.name}`} onClose={onClose} footer={<>
      <button className="btn" disabled={busy} onClick={preview}>معاينة</button>
      <button className="btn primary" disabled={busy || !pv || !f.reason.trim()} onClick={save}>اعتماد</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="القرار"><select value={f.kind} onChange={(e) => set({ kind: e.target.value })}>
        {Object.entries(KIND_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
      {f.kind === 'manual_tier' && <Field label="الشريحة" hint="تحل محل المحسوبة وتبقى المحسوبة ظاهرة"><input value={f.tier} onChange={(e) => set({ tier: e.target.value.toUpperCase() })} /></Field>}
      {money && <>
        <Field label="بـ"><select value={f.by} onChange={(e) => set({ by: e.target.value })}><option value="amount">مبلغ</option><option value="pct">نسبة</option></select></Field>
        {f.by === 'amount' ? <Field label="المبلغ"><input inputMode="decimal" value={f.amount} onChange={(e) => set({ amount: e.target.value })} /></Field> : <>
          <Field label="النسبة %"><input inputMode="decimal" value={f.pct} onChange={(e) => set({ pct: e.target.value })} /></Field>
          <Field label="الأساس" hint="مطلوب صراحة (B025)"><select value={f.base} onChange={(e) => set({ base: e.target.value })}>
            <option value="">اختر</option><option value="eligible">المبيعات المؤهلة</option><option value="base_commission">العمولة الأساسية</option></select></Field>
        </>}
      </>}
      <Field label="السبب"><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      {pv && (
        <table className="inner"><thead><tr><th></th><th>الشريحة</th><th className="num">الأساسية</th><th className="num">النهائي</th></tr></thead>
          <tbody>
            <tr><td>قبل</td><td>{pv.before.tier ?? 'NONE'}</td><td className="num diff-old">{fmtAmount(pv.before.base)}</td><td className="num diff-old">{fmtAmount(pv.before.final)}</td></tr>
            <tr><td>بعد</td><td>{pv.after.tier ?? 'NONE'}</td><td className="num diff-new">{fmtAmount(pv.after.base)}</td><td className="num diff-new">{fmtAmount(pv.after.final)}</td></tr>
          </tbody></table>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function CancelAdj({ a, onClose, onDone }: { a: Adj; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const go = () => run(async () => { await guarded((code) => rpc('cancel_commission_adjustment', { p_id: a.id, p_reason: reason, p_code: code })); onDone(); });
  return (
    <Modal title={`إلغاء قرار «${KIND_LABEL[a.kind]}»`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={go}>إلغاء القرار</button><button className="btn" onClick={onClose}>رجوع</button></>}>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
