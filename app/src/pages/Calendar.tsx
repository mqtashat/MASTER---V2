// P19 — التقويم (CAL-007، CAL-002/003): أيام العمل الأسبوعية، العطل العامة بيوم أو مدى وسبب، واستثناءات الموظف
// بنمط ثابت/متناسب يختار عند الإضافة، ومعاينة أيام الأساس والأهلية والشخصي والنهائي. تعديل التقويم لا يغير تاريخ سند.
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtDate, fmtMonth } from '../lib/format';
import { Days, fromMonthInput, monthInput, thisMonth, useEmployees } from '../lib/goals';
import { Badge, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';

const DOW = ['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];
const ORDER = [6, 0, 1, 2, 3, 4, 5];   // يبدأ الأسبوع بالسبت

interface Holiday { id: number; start_date: string; end_date: string; name: string; reason: string | null }
interface Exception { id: number; employee_id: number; employee_name: string; emp_number: string; start_date: string; end_date: string; mode: 'fixed' | 'proportional'; reason: string }
interface Cal {
  month: string; weekdays: number[]; closed: boolean; emp_days: Days | null; holidays: Holiday[]; exceptions: Exception[];
  days: { d: string; work: boolean; holiday: string | null; eligible: boolean; prop: boolean; fixed: boolean }[];
}

export function Calendar() {
  const { can } = useAuth();
  const emps = useEmployees();
  const [month, setMonth] = useState(thisMonth());
  const [emp, setEmp] = useState('');
  const [cal, setCal] = useState<Cal | null>(null);
  const [ver, setVer] = useState(0);
  const [hol, setHol] = useState<Holiday | 'new' | null>(null);
  const [exc, setExc] = useState<Exception | 'new' | null>(null);
  const [week, setWeek] = useState(false);
  const load = useAction();
  const edit = can('P19', 'edit');

  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<Cal>('calendar_month', { p_month: month, p_employee: emp ? Number(emp) : null }); if (live) setCal(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [month, emp, ver]);

  const first = cal?.days[0]?.d;
  const lead = first ? ORDER.indexOf(new Date(first + 'T00:00:00Z').getUTCDay()) : 0;
  const done = () => { setHol(null); setExc(null); setWeek(false); setVer(ver + 1); };

  return (
    <>
      <div className="page-head">
        <h1>التقويم</h1>
        <div className="actions">
          {edit && <button className="btn" onClick={() => setWeek(true)}>أيام العمل الأسبوعية</button>}
          {edit && <button className="btn" onClick={() => setHol('new')}>عطلة عامة</button>}
          {edit && <button className="btn primary" onClick={() => setExc('new')}>استثناء موظف</button>}
        </div>
      </div>
      <div className="filters">
        <input className="input" type="month" value={monthInput(month)} onChange={(e) => setMonth(fromMonthInput(e.target.value))} aria-label="الشهر" />
        <select className="input" value={emp} onChange={(e) => setEmp(e.target.value)} aria-label="الموظف">
          <option value="">التقويم العام</option>
          {emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}
        </select>
        {cal?.closed && <Badge kind="warn">شهر مقفل: التعديل للإدارة برمزها</Badge>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {cal && (
        <>
          <p className="small muted">الفترة {fmtDate(cal.days[0]?.d)} – {fmtDate(cal.days[cal.days.length - 1]?.d)} · أيام العمل: {ORDER.filter((d) => cal.weekdays.includes(d)).map((d) => DOW[d]).join('، ')}</p>
          {cal.emp_days && (
            <div className="stats">
              <div className="stat"><div className="l">أيام عمل الشهر (D)</div><div className="v num">{cal.emp_days.D}</div></div>
              <div className="stat"><div className="l">داخل فترة العمل (E)</div><div className="v num">{cal.emp_days.E}</div></div>
              <div className="stat"><div className="l">استثناء متناسب (P)</div><div className="v num">{cal.emp_days.P}</div></div>
              <div className="stat"><div className="l">كل الاستثناءات (X)</div><div className="v num">{cal.emp_days.X}</div></div>
              <div className="stat"><div className="l">أيام الموظف النهائية</div><div className="v num">{cal.emp_days.total}</div></div>
            </div>
          )}
          <div className="cal-grid" role="grid" aria-label={'تقويم ' + fmtMonth(cal.month)}>
            {ORDER.map((d) => <div key={d} className="cal-dow">{DOW[d]}</div>)}
            {Array.from({ length: lead }).map((_, i) => <div key={'x' + i} />)}
            {cal.days.map((d) => {
              const cls = ['cal-day', d.work ? 'work' : 'off', emp && !d.eligible ? 'inel' : '', d.prop ? 'prop' : '', d.fixed ? 'fixed' : ''].join(' ');
              return (
                <div key={d.d} className={cls} role="gridcell">
                  <span className="num">{Number(d.d.slice(8))}</span>
                  {d.holiday && <span className="small">{d.holiday}</span>}
                  {!d.holiday && !d.work && <span className="small muted">عطلة</span>}
                  {emp && !d.eligible && <span className="small muted">خارج فترة العمل</span>}
                  {d.prop && <span className="small">استثناء متناسب</span>}
                  {d.fixed && <span className="small">استثناء ثابت</span>}
                </div>
              );
            })}
          </div>
          <div className="grid2" style={{ marginTop: 12 }}>
            <div className="panel">
              <h2>العطل العامة في الشهر</h2>
              {cal.holidays.length === 0 ? <p className="muted small">لا عطل عامة</p> : (
                <table className="inner"><tbody>{cal.holidays.map((h) => (
                  <tr key={h.id}><td className="num">{fmtDate(h.start_date)}{h.end_date !== h.start_date && ' – ' + fmtDate(h.end_date)}</td><td>{h.name}</td>
                    <td className="small muted">{h.reason}</td><td>{edit && <button className="btn link" onClick={() => setHol(h)}>تعديل</button>}</td></tr>
                ))}</tbody></table>
              )}
            </div>
            <div className="panel">
              <h2>استثناءات الموظفين</h2>
              {cal.exceptions.length === 0 ? <p className="muted small">لا استثناءات</p> : (
                <table className="inner"><tbody>{cal.exceptions.map((x) => (
                  <tr key={x.id}><td>{x.employee_name}</td><td className="num">{fmtDate(x.start_date)}{x.end_date !== x.start_date && ' – ' + fmtDate(x.end_date)}</td>
                    <td><Badge kind={x.mode === 'fixed' ? 'accent' : 'warn'}>{x.mode === 'fixed' ? 'ثابت' : 'متناسب'}</Badge></td><td className="small muted">{x.reason}</td>
                    <td>{edit && <button className="btn link" onClick={() => setExc(x)}>تعديل</button>}</td></tr>
                ))}</tbody></table>
              )}
            </div>
          </div>
          <p className="small muted">العطلة العامة في يوم عمل تقلل أيام الأساس ويبقى الهدف الأصلي كما هو؛ الاستثناء الثابت يستبعد الأيام دون تخفيض الهدف، والمتناسب يخفض المكونات المتأثرة بنسبة الأيام (CAL-002/003/007). حركات العطل والاستثناءات تبقى ضمن الإنجاز والعمولة.</p>
        </>
      )}
      {week && cal && <WeekForm days={cal.weekdays} onClose={() => setWeek(false)} onDone={done} />}
      {hol && <HolidayForm h={hol === 'new' ? null : hol} onClose={() => setHol(null)} onDone={done} />}
      {exc && <ExceptionForm x={exc === 'new' ? null : exc} defaultEmp={emp} onClose={() => setExc(null)} onDone={done} />}
    </>
  );
}

function WeekForm({ days, onClose, onDone }: { days: number[]; onClose: () => void; onDone: () => void }) {
  const [sel, setSel] = useState<number[]>(days);
  const { busy, error, run } = useAction();
  const save = () => run(async () => { await rpc('save_work_weekdays', { p_days: sel }); onDone(); });
  return (
    <Modal title="أيام العمل الأسبوعية" onClose={onClose} footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="actions">{ORDER.map((d) => (
        <label key={d} className="check"><input type="checkbox" checked={sel.includes(d)} onChange={(e) => setSel(e.target.checked ? [...sel, d] : sel.filter((x) => x !== d))} /> {DOW[d]}</label>
      ))}</div>
      <Msg>يتغير حساب أيام العمل والأهداف في الأشهر المفتوحة؛ الأشهر المغلقة تبقى بنسختها المحفوظة.</Msg>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function HolidayForm({ h, onClose, onDone }: { h: Holiday | null; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ start_date: h?.start_date ?? '', end_date: h?.end_date ?? '', name: h?.name ?? '', reason: h?.reason ?? '' });
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const save = () => run(async () => { await guarded((code) => rpc('save_holiday', { p_id: h?.id ?? null, p: f, p_code: code })); onDone(); });
  const del = () => run(async () => { await guarded((code) => rpc('delete_holiday', { p_id: h!.id, p_reason: 'حذف', p_code: code })); onDone(); });
  return (
    <Modal title={h ? 'تعديل عطلة عامة' : 'عطلة عامة'} onClose={onClose} footer={<>
      <button className="btn primary" disabled={busy || !f.start_date || !f.name.trim()} onClick={save}>حفظ</button>
      {h && <button className="btn danger" disabled={busy} onClick={del}>حذف</button>}
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="من"><input type="date" value={f.start_date} onChange={(e) => setF({ ...f, start_date: e.target.value })} /></Field>
        <Field label="إلى" hint="فارغ = يوم واحد"><input type="date" value={f.end_date} onChange={(e) => setF({ ...f, end_date: e.target.value })} /></Field>
      </div>
      <Field label="الاسم"><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
      <Field label="السبب"><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

export function ExceptionForm({ x, defaultEmp, onClose, onDone }: { x: Exception | null; defaultEmp?: string; onClose: () => void; onDone: () => void }) {
  const emps = useEmployees();
  const [f, setF] = useState({ employee_id: x ? String(x.employee_id) : defaultEmp ?? '', start_date: x?.start_date ?? '', end_date: x?.end_date ?? '',
    mode: x?.mode ?? '', reason: x?.reason ?? '' });
  const [delReason, setDelReason] = useState('');
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const save = () => run(async () => { await guarded((code) => rpc('save_exception', { p_id: x?.id ?? null, p: f, p_code: code })); onDone(); });
  const del = () => run(async () => { await guarded((code) => rpc('delete_exception', { p_id: x!.id, p_reason: delReason, p_code: code })); onDone(); });
  return (
    <Modal title={x ? 'تعديل استثناء موظف' : 'استثناء موظف'} onClose={onClose} footer={<>
      <button className="btn primary" disabled={busy || !f.employee_id || !f.start_date || !f.mode || !f.reason.trim()} onClick={save}>حفظ</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="الموظف">
        <select value={f.employee_id} disabled={!!x} onChange={(e) => setF({ ...f, employee_id: e.target.value })}>
          <option value="">اختر</option>{emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}
        </select>
      </Field>
      <div className="grid2">
        <Field label="من"><input type="date" value={f.start_date} onChange={(e) => setF({ ...f, start_date: e.target.value })} /></Field>
        <Field label="إلى" hint="فارغ = يوم واحد"><input type="date" value={f.end_date} onChange={(e) => setF({ ...f, end_date: e.target.value })} /></Field>
      </div>
      <fieldset className="plain"><legend>أثر الاستثناء على الهدف (يُختار لكل استثناء)</legend>
        <label className="check"><input type="radio" checked={f.mode === 'fixed'} onChange={() => setF({ ...f, mode: 'fixed' })} /> هدف ثابت — تستبعد الأيام دون تخفيض الهدف</label>
        <label className="check"><input type="radio" checked={f.mode === 'proportional'} onChange={() => setF({ ...f, mode: 'proportional' })} /> متناسب مع الأيام — يخفض المكونات المتأثرة بنسبة الأيام</label>
      </fieldset>
      <Field label="السبب"><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
      {x && (
        <details><summary>حذف الاستثناء</summary>
          <div className="actions" style={{ marginTop: 6 }}>
            <input className="input" style={{ width: 'auto' }} placeholder="سبب الحذف" value={delReason} onChange={(e) => setDelReason(e.target.value)} aria-label="سبب الحذف" />
            <button className="btn danger" disabled={busy || !delReason.trim()} onClick={del}>حذف</button>
          </div>
        </details>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
