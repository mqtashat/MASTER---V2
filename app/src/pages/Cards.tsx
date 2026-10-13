// P13 «بطاقات الأداء» (CARD-001..018): بطاقة لكل موظف بالشريحة المحققة وشريحة المسار ولونيهما،
// والمكوّن الرئيسي بهدفه النهائي ومحققه ونسبته والمطلوب يوميًا، وملخص المبيعات والمؤشرات أرقام متابعة صحيحة،
// والمكافآت. الفلاتر: الشهر واليوم/أمس والدور والفريق والحالة والبحث. قائمة العرض تُحفظ في المتصفح،
// وعبارة المسار تظهر حسب إعداد الإدارة. حفظ البطاقة صورة دون أزرار التحكم.
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

const OPTIONS: { key: string; label: string; admin?: boolean }[] = [
  { key: 'main', label: 'المكوّن الرئيسي' }, { key: 'components', label: 'كل المكونات' }, { key: 'summary', label: 'ملخص المبيعات' },
  { key: 'indicators', label: 'المؤشرات' }, { key: 'days', label: 'الأيام' }, { key: 'rewards', label: 'المكافآت' },
  { key: 'path', label: 'عبارة المسار' },
];
const STORE = 'master.cards.view';
function loadView(): Record<string, boolean> {
  try { return { main: true, components: false, summary: true, indicators: true, days: true, rewards: true, path: true, ...JSON.parse(localStorage.getItem(STORE) ?? '{}') }; }
  catch { return { main: true, summary: true, indicators: true, days: true, rewards: true, path: true }; }
}

export function Cards() {
  const { profile } = useAuth();
  const emps = useEmployees();
  const [month, setMonth] = useState(thisMonth());
  const [o, setO] = useState({ mode: 'today', role: 'all', supervisor_id: '', status: 'active', search: '' });
  const [d, setD] = useState<Res | null>(null);
  const [view, setView] = useState(loadView);
  const [menu, setMenu] = useState(false);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<Res>('performance_cards', { p_month: month, p_opts: o }); if (live) setD(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, JSON.stringify(o)]);
  const toggle = (k: string) => { const n = { ...view, [k]: !view[k] }; setView(n); try { localStorage.setItem(STORE, JSON.stringify(n)); } catch { /* تخزين المتصفح غير متاح */ } };
  const pathAllowed = !!d?.show_path_phrase;

  return (
    <>
      <div className="page-head">
        <h1>بطاقات الأداء</h1>
        <div className="actions" style={{ position: 'relative' }}>
          <button className="btn" aria-expanded={menu} onClick={() => setMenu(!menu)}>خيارات العرض</button>
          {menu && (
            <div className="pop">
              {OPTIONS.filter((x) => x.key !== 'path' || pathAllowed).map((x) => (
                <label key={x.key} className="check"><input type="checkbox" checked={!!view[x.key]} onChange={() => toggle(x.key)} /> {x.label}</label>
              ))}
              {!pathAllowed && profile?.is_admin && <p className="small muted">عبارة المسار مخفية من الإعدادات.</p>}
            </div>
          )}
        </div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        <select className="input" value={o.mode} onChange={(e) => setO({ ...o, mode: e.target.value })} aria-label="حتى">
          <option value="today">حتى اليوم</option><option value="yesterday">حتى أمس</option></select>
        <select className="input" value={o.role} onChange={(e) => setO({ ...o, role: e.target.value })} aria-label="الدور">
          <option value="all">المندوبون والمشرفون</option><option value="rep">المندوبون</option><option value="supervisor">المشرفون</option></select>
        <select className="input" value={o.supervisor_id} onChange={(e) => setO({ ...o, supervisor_id: e.target.value })} aria-label="الفريق">
          <option value="">كل الفرق</option>{emps.map((e) => <option key={e.id} value={e.id}>فريق {e.name}</option>)}</select>
        <select className="input" value={o.status} onChange={(e) => setO({ ...o, status: e.target.value })} aria-label="الحالة">
          <option value="active">النشطون</option><option value="all">الكل</option></select>
        <input className="input" placeholder="بحث بالاسم أو الرقم" value={o.search} onChange={(e) => setO({ ...o, search: e.target.value })} aria-label="بحث" />
        {d && <span className="count">{d.cards.length} بطاقة · حتى {fmtDate(d.cutoff)}{d.closed && ' · شهر مغلق (النسخة المحفوظة)'}</span>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {!d ? <div className="panel"><div className="skeleton" /></div> : d.cards.length === 0 ? <div className="panel empty">لا بطاقات ضمن الفلاتر.</div> : (
        <div className="cards">{d.cards.map((c) => <PerfCard key={c.employee.id} c={c} view={{ ...view, path: view.path && pathAllowed }} />)}</div>
      )}
    </>
  );
}

function pathPhrase(m: EvalComp, ev: Eval): string | null {
  if (!m.has_path || ev.path_state !== 'running' || m.path_diff === null) return null;
  const diff = Number(m.path_diff);
  if (diff >= 0) return `متقدم على المسار بـ ${fmtMetric(m.path_diff, m.kind)}`;
  return `متأخر عن المسار بـ ${fmtMetric(String(-diff), m.kind)}`;
}

function PerfCard({ c, view }: { c: Card; view: Record<string, boolean> }) {
  const ref = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState(false);
  const ev = c.eval;
  const m = ev?.main ?? null;
  const achieved = ev?.achieved ?? null;
  const s = c.summary;
  const perDay = c.days.elapsed > 0 ? (Number(s.invoices) / c.days.elapsed) : null;
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
  return (
    <div ref={ref} className={'perf-card ' + (ev ? tierClass(achieved).replace('tier ', 'c-') : 'c-none')} data-employee={c.employee.id}>
      <div className="pc-head">
        <div>
          <div className="pc-name">{c.employee.name}</div>
          <div className="small muted"><span className="num">{c.employee.emp_number}</span> · {ROLE_LABEL[c.role] ?? c.role}{c.employee.supervisor && ` · فريق ${c.employee.supervisor}`}</div>
        </div>
        <div className="pc-tiers">
          {ev ? <><b className={tierClass(achieved) + ' big'} title="الشريحة المحققة">{achieved}</b>
            <span className="small muted">المسار <b className={tierClass(ev.path_tier)}>{ev.path_tier}</b></span></> : <Badge kind="warn">بلا خطة</Badge>}
        </div>
      </div>
      <div className="small muted">{fmtMonth(c.month)} · حتى {fmtDate(c.cutoff)}{c.snapshot && ' · نسخة الإغلاق'}{c.employee.status !== 'نشط' && ` · ${c.employee.status}`}</div>
      {view.main && m && (
        <div className="pc-main">
          <div className="small">{m.tier && <b className={tierClass(m.tier)}>{m.tier}</b>} {m.label}</div>
          <div className="pc-row"><span>الهدف</span><b className="num">{m.kind === 'relative' ? fmtMetric(m.final, m.kind) : fmtFollow(m.final)}</b></div>
          <div className="pc-row"><span>المحقق</span><b className="num">{m.kind === 'relative' ? fmtMetric(m.actual, m.kind) : fmtFollow(m.actual)}</b></div>
          <div className="bar" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}><span style={{ width: pct + '%' }} /></div>
          <div className="pc-row small"><span>الإنجاز {m.pct ? fmtPct(m.pct) + '%' : '—'}</span><span>المتبقي <span className="num">{m.kind === 'relative' ? fmtMetric(m.remaining, m.kind) : fmtFollow(m.remaining)}</span></span></div>
          {m.daily && <div className="pc-row small"><span>المطلوب يوميًا</span><span className="num">{fmtFollow(m.daily)}</span></div>}
          {view.path && pathPhrase(m, ev!) && <div className={'small ' + (Number(m.path_diff) >= 0 ? 'ok-text' : 'bad-text')}>{pathPhrase(m, ev!)}</div>}
        </div>
      )}
      {view.components && ev && ev.components.filter((x) => x !== m && x.status !== 'unused').length > 0 && (
        <table className="inner small"><tbody>{ev.components.filter((x) => x !== m && x.id !== m?.id && x.status !== 'unused').map((x) => (
          <tr key={x.id}><td>{x.tier ?? '—'}</td><td>{x.label}</td><td className="num">{fmtMetric(x.actual, x.kind)} / {fmtMetric(x.final, x.kind)}</td><td>{x.met ? '✓' : ''}</td></tr>
        ))}</tbody></table>
      )}
      {view.summary && (
        <div className="pc-grid">
          <span>الصافي</span><b className="num">{fmtFollow(s.net)}</b>
          <span>المباشر</span><b className="num">{fmtFollow(s.direct)}</b>
          <span>العروض</span><b className="num">{fmtFollow(s.promo)}</b>
          <span>المرتجعات</span><b className="num">{fmtFollow(s.returns)}</b>
        </div>
      )}
      {view.indicators && (
        <div className="pc-grid">
          <span>الفواتير</span><b className="num">{s.invoices}</b>
          <span>فواتير/يوم</span><b className="num">{perDay === null ? '—' : fmtPct(perDay.toFixed(2))}</b>
          <span>العملاء</span><b className="num">{s.customers}</b>
          <span>التنوع</span><b className="num">{s.variety}</b>
          <span>الكمية</span><b className="num">{fmtFollow(s.quantity)}</b>
          <span>النقدية</span><b className="num">{s.cash_ratio === null ? '—' : fmtPct(s.cash_ratio) + '%'}</b>
        </div>
      )}
      {view.days && <div className="small muted">أيام العمل {c.days.total} · المنقضي {c.days.elapsed}{c.days.X ? ` · استثناءات ${c.days.X}` : ''}</div>}
      {view.rewards && c.rewards.length > 0 && (
        <div className="small">{c.rewards.map((r, i) => (
          <div key={i}>{r.met ? '✓' : '○'} {r.name}{r.cond_type === 'metric' && r.min !== null && <span className="muted"> ({fmtFollow(r.actual)} / {fmtFollow(r.min)})</span>}</div>
        ))}</div>
      )}
      <div className="no-capture pc-foot"><button className="btn link" disabled={busy} onClick={save}>حفظ صورة</button></div>
    </div>
  );
}
