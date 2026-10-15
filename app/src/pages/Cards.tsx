// P13 «بطاقات الأداء» (CARD-001..018): بطاقة لكل موظف بالشريحة المحققة وشريحة المسار ولونيهما، ونسبة الإنجاز «من هدف A»،
// وبطاقات الأهداف A وB وC المتجاورة (X مخفية) بثلاثة أسطر لكل منها، والهدف الأصلي والنهائي وأيام العمل، والمطلوب حتى اليوم
// ونسبة المسار وحالتاه، وسطر صافي المبيعات والأيام، وأرقام المتابعة صحيحة بلا فواصل (CARD-004/010/018).
// قائمة «تفاصيل البطاقة» تُحفظ في المتصفح لكل مستخدم (CARD-016)، وعبارة «متقدم/متأخر» للإدارة وحدها ويسري اختيارها على الجميع (CARD-006/018).
import { useEffect, useRef, useState } from 'react';
import { toPng } from 'html-to-image';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, fmtMonth, fmtPct } from '../lib/format';
import { Days, Eval, EvalComp, fmtFollow, fmtMetric, fromMonthInput, monthInput, ROLE_LABEL, thisMonth, tierClass, useEmployees } from '../lib/goals';
import { Badge, Msg, useAction } from '../components/ui';

interface Summary { gross: string; direct: string; promo: string; returns: string; net: string; cash: string; cash_ratio: string | null; invoices: number; customers: number; variety: number; quantity: string }
interface CardReward { name: string; cond_type: string; tiers: string[] | null; metric_label: string | null; min: string | null; actual: string | null; met: boolean; value_type: string; amount: string | null; pct: string | null }
interface Card {
  employee: { id: number; name: string; emp_number: string; status: string; job_role: string | null; supervisor: string | null };
  role: string; month: string; cutoff: string; eval: Eval | null; days: Days; summary: Summary; rewards: CardReward[]; snapshot?: boolean;
}
interface Res { month: string; cutoff: string; closed: boolean; show_path_phrase: boolean; cards: Card[] }

// عناصر قائمة «تفاصيل البطاقة» (CARD-016)؛ «متقدم/متأخر» للإدارة وحدها فلا تظهر هنا لغيرها
const OPTIONS: { key: string; label: string }[] = [
  { key: 'pct', label: 'نسبة الإنجاز' }, { key: 'achieved', label: 'الشريحة المحققة' }, { key: 'pathtier', label: 'شريحة المسار' },
  { key: 'netline', label: 'سطر صافي المبيعات والأيام' }, { key: 'cash', label: 'النقدية' },
  { key: 'targets', label: 'الهدف الأصلي والنهائي وأيام العمل' }, { key: 'tiles', label: 'أهداف الشرائح' },
  { key: 'required', label: 'المطلوب حتى اليوم ونسبة المسار' }, { key: 'plan', label: 'أقسام الخطة' },
  { key: 'summary', label: 'ملخص المبيعات' }, { key: 'indicators', label: 'المؤشرات' }, { key: 'rewards', label: 'المكافآت' },
  { key: 'image', label: 'زر حفظ الصورة' },
];
const STORE = 'master.cards.view2';
const DEFAULTS: Record<string, boolean> = Object.fromEntries(OPTIONS.map((o) => [o.key, o.key !== 'plan']));
function loadView(): Record<string, boolean> {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(STORE) ?? '{}') }; } catch { return { ...DEFAULTS }; }
}

export function Cards() {
  const { profile, can } = useAuth();
  const emps = useEmployees();
  const [month, setMonth] = useState(thisMonth());
  const [o, setO] = useState({ mode: 'today', role: 'all', supervisor_id: '', status: 'active', search: '' });
  const [d, setD] = useState<Res | null>(null);
  const [view, setView] = useState(loadView);
  const [menu, setMenu] = useState(false);
  const [ver, setVer] = useState(0);
  const load = useAction();
  const phrase = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<Res>('performance_cards', { p_month: month, p_opts: o }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, JSON.stringify(o), ver]);
  const toggle = (k: string) => { const n = { ...view, [k]: !view[k] }; setView(n); try { localStorage.setItem(STORE, JSON.stringify(n)); } catch { /* تخزين المتصفح غير متاح */ } };
  const pathAllowed = !!d?.show_path_phrase;
  // تغيير عبارة المسار للإدارة وحدها ويسري على الجميع (CARD-006)
  const togglePhrase = () => phrase.run(async () => { await rpc('save_setting', { p_key: 'show_path_phrase', p_value: !pathAllowed }); setVer(ver + 1); });
  const canImage = can('P13', 'print');

  return (
    <>
      <div className="page-head">
        <h1>بطاقات الأداء</h1>
        <div className="actions" style={{ position: 'relative' }}>
          <button className="btn" aria-expanded={menu} onClick={() => setMenu(!menu)}>خيارات العرض</button>
          {menu && (
            <div className="pop">
              {OPTIONS.filter((x) => x.key !== 'image' || canImage).map((x) => (
                <label key={x.key} className="check"><input type="checkbox" checked={!!view[x.key]} onChange={() => toggle(x.key)} /> {x.label}</label>
              ))}
              {profile?.is_admin && (
                <label className="check"><input type="checkbox" checked={pathAllowed} disabled={phrase.busy} onChange={togglePhrase} /> متقدم/متأخر (للجميع)</label>
              )}
            </div>
          )}
        </div>
      </div>
      {phrase.error && <Msg kind="bad">{phrase.error}</Msg>}
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        <select className="input" value={o.mode} onChange={(e) => setO({ ...o, mode: e.target.value })} aria-label="حتى">
          <option value="today">اليوم</option><option value="yesterday">أمس</option></select>
        <select className="input" value={o.role} onChange={(e) => setO({ ...o, role: e.target.value })} aria-label="الدور">
          <option value="all">الكل</option><option value="rep">المندوبون</option><option value="supervisor">المشرفون</option></select>
        <select className="input" value={o.supervisor_id} onChange={(e) => setO({ ...o, supervisor_id: e.target.value })} aria-label="الفريق">
          <option value="">كل الفرق</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
        <select className="input" value={o.status} onChange={(e) => setO({ ...o, status: e.target.value })} aria-label="الحالة">
          <option value="active">فعال</option><option value="all">الكل</option></select>
        <input className="input" placeholder="بحث بالاسم أو الرقم" value={o.search} onChange={(e) => setO({ ...o, search: e.target.value })} aria-label="بحث" />
        {d && <span className="count">{d.cards.length} بطاقة · حتى {fmtDate(d.cutoff)}{d.closed && ' · شهر مغلق (النسخة المحفوظة)'}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {!d ? <div className="panel"><div className="skeleton" /></div> : d.cards.length === 0 ? <div className="panel empty">لا بطاقات ضمن الفلاتر.</div> : (
        <div className="cards">{d.cards.map((c) => <PerfCard key={c.employee.id} c={c} view={{ ...view, image: view.image && canImage }} phraseOn={pathAllowed} />)}</div>
      )}
    </>
  );
}

const val = (v: string | null, kind: EvalComp['kind']) => (kind === 'relative' ? fmtMetric(v, kind) : fmtFollow(v));

/** عبارة المسار المختصرة «متقدم بـ500» (CARD-004): عدد صحيح بلا فواصل */
function pathPhrase(m: EvalComp, ev: Eval): string | null {
  if (!m.has_path || ev.path_state !== 'running' || m.path_diff === null) return null;
  const diff = Number(m.path_diff);
  return diff >= 0 ? `متقدم بـ${fmtFollow(m.path_diff)}` : `متأخر بـ${fmtFollow(String(-diff))}`;
}

/** مكوّن الشريحة الممثل في بطاقتها: من مقياس المكوّن الرئيسي إن وُجد، وإلا أول مكوّن مقيَّم فيها */
function tileComp(ev: Eval, tier: string, main: EvalComp | null): EvalComp | null {
  const inTier = ev.components.filter((x) => x.tier === tier && x.status !== 'unused');
  return inTier.find((x) => main && x.metric === main.metric) ?? inTier[0] ?? null;
}

function PerfCard({ c, view, phraseOn }: { c: Card; view: Record<string, boolean>; phraseOn: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState(false);
  const ev = c.eval;
  const m = ev?.main ?? null;
  const achieved = ev?.achieved ?? null;
  const s = c.summary;
  // متوسط فواتير البيع لكل يوم عمل منقضٍ: عدد صحيح مقرَّب (5.8 تصبح 6) مع العدد الكلي (CARD-018)
  const perDay = c.days.elapsed > 0 ? Math.round(Number(s.invoices) / c.days.elapsed) : null;
  const save = async () => {
    if (!ref.current) return;
    setBusy(true);
    try {
      const url = await toPng(ref.current, { pixelRatio: 2, backgroundColor: '#ffffff', filter: (n) => !(n instanceof HTMLElement && n.classList.contains('no-capture')) });
      const a = document.createElement('a');
      a.href = url; a.download = `card-${c.employee.emp_number}-${c.month.slice(0, 7)}.png`; a.click();
    } finally { setBusy(false); }
  };
  const pct = m?.pct ? Math.max(0, Math.min(100, Number(m.pct))) : 0;
  const tiles = ev ? ev.tiers.filter((t) => t.tier !== 'X').map((t) => ({ t, x: tileComp(ev, t.tier, m) })).filter((q) => q.x) : [];
  const remainingDays = Math.max(c.days.total - c.days.elapsed, 0);
  const stateText = !ev ? null : ev.path_state === 'no_days' ? 'لا توجد أيام عمل' : ev.path_state === 'not_started' ? 'لم يبدأ المسار' : null;
  return (
    <div ref={ref} className={'perf-card ' + (ev ? tierClass(achieved).replace('tier ', 'c-') : 'c-none')} data-employee={c.employee.id}>
      <div className="pc-head">
        <div>
          <div className="pc-name">{c.employee.name}</div>
          <div className="small muted"><span className="num">{c.employee.emp_number}</span> · {ROLE_LABEL[c.role] ?? c.role}{c.employee.supervisor && ` · فريق ${c.employee.supervisor}`}</div>
        </div>
        <div className="pc-tiers">
          {ev ? <>
            {view.achieved && <span className="small muted">المحققة <b className={tierClass(achieved) + ' big' + (achieved === 'NONE' ? ' none-light' : '')} title="الشريحة المحققة">{achieved}</b></span>}
            {view.pathtier && <span className="small muted">المسار <b className={tierClass(ev.path_tier)}>{ev.path_tier}</b></span>}
          </> : <Badge kind="warn">بلا خطة</Badge>}
        </div>
      </div>
      <div className="small muted">{fmtMonth(c.month)} · حتى {fmtDate(c.cutoff)}{c.snapshot && ' · نسخة الإغلاق'}{c.employee.status !== 'نشط' && ` · ${c.employee.status}`}</div>
      {view.pct && m && (
        <div className="pc-main">
          <div className="pc-row"><b className="num big">{m.pct ? fmtPct(m.pct) + '%' : '—'}</b><span className="small">من هدف {m.tier ?? m.label}</span></div>
          <div className="bar" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}><span style={{ width: pct + '%' }} /></div>
        </div>
      )}
      {view.tiles && tiles.length > 0 && (
        <div className="tiles">
          {tiles.map(({ t, x }) => (
            <div key={t.tier} className={'tile ' + tierClass(t.tier).replace('tier ', 'tl-') + (x!.met ? ' met' : '')}>
              <div className="tile-r"><b className={tierClass(t.tier)}>{t.tier}</b><b className="num">{val(x!.final, x!.kind)}</b></div>
              <div className="tile-r"><span>المحقق</span><b className="num">{val(x!.actual, x!.kind)}</b></div>
              <div className="tile-r"><span>المتبقي</span><b className="num">{val(x!.remaining, x!.kind)}</b></div>
              {x!.has_path && <div className="tile-r"><span>المفترض اليوم</span><b className="num">{val(x!.expected_today, x!.kind)}</b></div>}
              {x!.has_path && x!.daily && <div className="tile-r"><span>المطلوب يوميًا</span><b className="num">{val(x!.daily, x!.kind)}</b></div>}
            </div>
          ))}
        </div>
      )}
      {view.targets && m && (
        <div className="pc-row small"><span>الهدف الأصلي <b className="num">{m.original === null ? '—' : val(m.original, m.kind)}</b> · النهائي <b className="num">{val(m.final, m.kind)}</b></span>
          <span>أيام العمل <b className="num">{c.days.total}</b></span></div>
      )}
      {view.required && m && (
        <div className="pc-row small">
          {stateText ? <b>{stateText}</b> : <span>المطلوب حتى اليوم <b className="num">{val(m.required, m.kind)}</b>{m.path_pct && <> · المسار <b className="num">{fmtPct(m.path_pct)}%</b></>}</span>}
          {phraseOn && pathPhrase(m, ev!) && <b className={Number(m.path_diff) >= 0 ? 'ok-text' : 'bad-text'}>{pathPhrase(m, ev!)}</b>}
        </div>
      )}
      {view.netline && (
        <div className="pc-row"><span>صافي المبيعات <b className="num">{fmtFollow(s.net)}</b></span>
          <span>الأيام <b className="num">{c.days.total}</b> · المنقضي <b className="num">{c.days.elapsed}</b> · المتبقي <b className="num">{remainingDays}</b></span></div>
      )}
      {view.cash && <div className="pc-row small"><span>النقدية <b className="num">{fmtFollow(s.cash)}</b></span><span className="num">{s.cash_ratio === null ? '—' : fmtPct(s.cash_ratio) + '%'}</span></div>}
      {view.plan && ev && ev.components.filter((x) => x.status !== 'unused').length > 0 && (
        <table className="inner small"><tbody>{ev.components.filter((x) => x.status !== 'unused').map((x) => (
          <tr key={x.id}><td>{x.tier ?? '—'}</td><td>{x.label}</td><td className="num">{val(x.actual, x.kind)} / {val(x.final, x.kind)}</td><td>{x.met ? '✓' : ''}</td></tr>
        ))}</tbody></table>
      )}
      {view.summary && (
        <div className="pc-grid">
          <span>المباشر</span><b className="num">{fmtFollow(s.direct)}</b>
          <span>العروض</span><b className="num">{fmtFollow(s.promo)}</b>
          <span>المرتجعات</span><b className="num">{fmtFollow(s.returns)}</b>
        </div>
      )}
      {view.indicators && (
        <div className="pc-grid">
          <span>الفواتير</span><b className="num">{s.invoices}</b>
          <span>فواتير/يوم</span><b className="num">{perDay === null ? '—' : perDay}</b>
          <span>العملاء</span><b className="num">{s.customers}</b>
          <span>التنوع</span><b className="num">{s.variety}</b>
          <span>الكمية</span><b className="num">{fmtFollow(s.quantity)}</b>
        </div>
      )}
      {view.rewards && c.rewards.length > 0 && (
        <div className="small">{c.rewards.map((r, i) => (
          <div key={i}>{r.met ? '✓' : '○'} {r.name}{r.cond_type === 'metric' && r.min !== null && <span className="muted"> ({fmtFollow(r.actual)} / {fmtFollow(r.min)})</span>}</div>
        ))}</div>
      )}
      {view.image && <div className="no-capture pc-foot"><button className="btn link" disabled={busy} onClick={save}>حفظ صورة</button></div>}
    </div>
  );
}
