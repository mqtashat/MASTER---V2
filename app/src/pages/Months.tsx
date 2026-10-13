// P14b «الأشهر والإغلاق» (PERIOD-001/002، B075–B077): حالة كل شهر ونسخه، وفحص الجاهزية قبل الإغلاق
// (الأخطاء المؤثرة تمنع الإغلاق)، والإغلاق باعتماد الإدارة إلى نسخة محفوظة، وإعادة الفتح برمز الإدارة وسبب،
// ومقارنة الحساب الحالي بالنسخة المحفوظة.
import { useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDateTime, fmtMonth } from '../lib/format';
import { ROLE_LABEL, tierClass, WARN_LABEL } from '../lib/goals';
import { Badge, Drawer, Field, Modal, Msg, useAction } from '../components/ui';

type N = string | number | null;
interface Version { version: number; closed_at: string; closed_name: string | null; note: string | null; reopened_at: string | null; reopen_reason: string | null; totals: Record<string, N> | null }
interface MonthRow { month: string; status: 'open' | 'closed'; version: number; closed_at: string | null; reopened_at: string | null; reopen_reason: string | null; plans: number; rules: number; versions: Version[] }
interface Readiness { month: string; closed: boolean; blocking: boolean; totals: Record<string, N>; rows: { employee_id: number; name: string; role: string; tier: string | null; final: N; blocking: boolean; warnings: { code: string; blocking: boolean; message: string }[] }[] }
interface Diff { version: number | null; rows: { employee_id: number; name: string; saved: Record<string, N>; live: Record<string, N> }[] }

export function Months() {
  const { profile } = useAuth();
  const admin = !!profile?.is_admin;
  const [rows, setRows] = useState<MonthRow[] | null>(null);
  const [ver, setVer] = useState(0);
  const [open, setOpen] = useState<MonthRow | null>(null);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<MonthRow[]>('months_overview'); if (live) setRows(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [ver]);
  return (
    <>
      <div className="page-head"><h1>الأشهر والإغلاق</h1></div>
      <p className="small muted">إغلاق الشهر يحفظ نسخة معتمدة من الكشوف والبطاقات والقواعد؛ بعدها لا يُعدَّل ما يخصه إلا برمز الإدارة، وتبقى النسخ السابقة للمراجعة بعد إعادة الفتح.</p>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      <div className="tbl"><table>
        <thead><tr><th>الشهر</th><th>الحالة</th><th className="num">النسخة</th><th className="num">الخطط</th><th className="num">القواعد</th><th>آخر إغلاق</th><th>آخر إعادة فتح</th></tr></thead>
        <tbody>{!rows ? <tr><td colSpan={7}><div className="skeleton" /></td></tr> : rows.map((m) => (
          <tr key={m.month} className="clickable" onClick={() => setOpen(m)}>
            <td className="num">{fmtMonth(m.month)}</td>
            <td>{m.status === 'closed' ? <Badge kind="accent">مغلق</Badge> : <Badge>مفتوح</Badge>}</td>
            <td className="num">{m.version || '—'}</td><td className="num">{m.plans}</td><td className="num">{m.rules}</td>
            <td className="small">{m.closed_at ? fmtDateTime(m.closed_at) : ''}</td>
            <td className="small wrap">{m.reopened_at ? `${fmtDateTime(m.reopened_at)} — ${m.reopen_reason ?? ''}` : ''}</td>
          </tr>
        ))}</tbody></table></div>
      {open && <MonthView m={open} admin={admin} onClose={() => setOpen(null)} onChanged={() => { setOpen(null); setVer(ver + 1); }} />}
    </>
  );
}

function MonthView({ m, admin, onClose, onChanged }: { m: MonthRow; admin: boolean; onClose: () => void; onChanged: () => void }) {
  const [tab, setTab] = useState(m.status === 'closed' ? 'versions' : 'ready');
  const [r, setR] = useState<Readiness | null>(null);
  const [diff, setDiff] = useState<Diff | null>(null);
  const [dlg, setDlg] = useState<'close' | 'reopen' | null>(null);
  const load = useAction();
  useEffect(() => {
    if (tab === 'ready' && !r) load.run(async () => setR(await rpc<Readiness>('month_readiness', { p_month: m.month })));
    if (tab === 'diff' && !diff) load.run(async () => setDiff(await rpc<Diff>('month_diff', { p_month: m.month })));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab]);
  const closed = m.status === 'closed';
  return (
    <Drawer title={`شهر ${fmtMonth(m.month)}`} onClose={onClose} actions={admin && (closed
      ? <button className="btn danger" onClick={() => setDlg('reopen')}>إعادة فتح</button>
      : <button className="btn primary" disabled={!r || r.blocking} onClick={() => setDlg('close')}>إغلاق الشهر</button>)}>
      <div className="tabs" role="tablist">
        <button role="tab" aria-selected={tab === 'ready'} onClick={() => setTab('ready')}>فحص الجاهزية</button>
        <button role="tab" aria-selected={tab === 'versions'} onClick={() => setTab('versions')}>النسخ ({m.versions.length})</button>
        {m.versions.length > 0 && <button role="tab" aria-selected={tab === 'diff'} onClick={() => setTab('diff')}>الفروق عن المحفوظ</button>}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {tab === 'ready' && (!r ? <div className="skeleton" /> : (
        <>
          {r.blocking ? <Msg kind="bad">توجد أخطاء مؤثرة تمنع الإغلاق؛ عالجها في قواعد العمولة أو نسب الأصناف أو نسب المشرفين ثم أعد الفحص.</Msg>
            : <Msg kind="ok">لا أخطاء مؤثرة. {closed ? '' : 'يمكن إغلاق الشهر.'}</Msg>}
          <div className="stats">
            <div className="stat"><div className="l">المؤهلة</div><div className="v num">{fmtAmount(r.totals.eligible)}</div></div>
            <div className="stat"><div className="l">الأساسية</div><div className="v num">{fmtAmount(r.totals.base)}</div></div>
            <div className="stat"><div className="l">المكافآت</div><div className="v num">{fmtAmount(r.totals.rewards)}</div></div>
            <div className="stat"><div className="l">النهائي</div><div className="v num">{fmtAmount(r.totals.final)}</div></div>
          </div>
          <table className="inner"><thead><tr><th>الموظف</th><th>الدور</th><th>الشريحة</th><th className="num">النهائي</th><th>الملاحظات</th></tr></thead>
            <tbody>{r.rows.map((x) => (
              <tr key={x.employee_id} className={x.blocking ? 'zero' : ''}><td>{x.name}</td><td>{ROLE_LABEL[x.role] ?? x.role}</td>
                <td><b className={tierClass(x.tier)}>{x.tier ?? 'NONE'}</b></td><td className="num">{x.final === null ? '—' : fmtAmount(x.final)}</td>
                <td className="wrap small">{x.warnings.map((w) => (w.blocking ? '⛔ ' : '') + (WARN_LABEL[w.code] ?? w.message)).join('، ')}</td></tr>
            ))}</tbody></table>
        </>
      ))}
      {tab === 'versions' && (m.versions.length === 0 ? <p className="muted">لم يُغلق هذا الشهر بعد.</p> : (
        <table className="inner"><thead><tr><th>النسخة</th><th>الإغلاق</th><th className="num">النهائي</th><th>ملاحظة</th><th>إعادة الفتح</th></tr></thead>
          <tbody>{m.versions.map((v) => (
            <tr key={v.version}><td className="num">{v.version}</td><td className="small">{fmtDateTime(v.closed_at)} — {v.closed_name}</td>
              <td className="num">{fmtAmount(v.totals?.final ?? null)}</td><td className="wrap">{v.note}</td>
              <td className="wrap small">{v.reopened_at ? `${fmtDateTime(v.reopened_at)} — ${v.reopen_reason}` : ''}</td></tr>
          ))}</tbody></table>
      ))}
      {tab === 'diff' && (!diff ? <div className="skeleton" /> : diff.rows.length === 0 ? <Msg kind="ok">الحساب الحالي مطابق للنسخة {diff.version}.</Msg> : (
        <>
          <p className="small muted">الفروق بين النسخة المحفوظة {diff.version} والحساب الحالي من المصادر.</p>
          <table className="inner"><thead><tr><th>الموظف</th><th>الشريحة</th><th className="num">المؤهلة</th><th className="num">النهائي</th></tr></thead>
            <tbody>{diff.rows.map((x) => (
              <tr key={x.employee_id}><td>{x.name}</td>
                <td><span className="diff-old">{String(x.saved.tier ?? 'NONE')}</span> ← <span className="diff-new">{String(x.live.tier ?? 'NONE')}</span></td>
                <td className="num"><span className="diff-old">{fmtAmount(x.saved.eligible)}</span> ← <span className="diff-new">{fmtAmount(x.live.eligible)}</span></td>
                <td className="num"><span className="diff-old">{fmtAmount(x.saved.final)}</span> ← <span className="diff-new">{fmtAmount(x.live.final)}</span></td></tr>
            ))}</tbody></table>
        </>
      ))}
      {dlg === 'close' && <CloseDlg month={m.month} onClose={() => setDlg(null)} onDone={onChanged} />}
      {dlg === 'reopen' && <ReopenDlg month={m.month} onClose={() => setDlg(null)} onDone={onChanged} />}
    </Drawer>
  );
}

function CloseDlg({ month, onClose, onDone }: { month: string; onClose: () => void; onDone: () => void }) {
  const [note, setNote] = useState('');
  const { busy, error, run } = useAction();
  const go = () => run(async () => { await rpc('close_month', { p_month: month, p_note: note || null }); onDone(); });
  return (
    <Modal title={`إغلاق ${fmtMonth(month)}`} onClose={onClose} footer={<><button className="btn primary" disabled={busy} onClick={go}>اعتماد الإغلاق</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>تُحفظ نسخة معتمدة لكل كشف وبطاقة. بعد الإغلاق لا يُعدَّل ما يخص الشهر إلا برمز الإدارة.</Msg>
      <Field label="ملاحظة"><input value={note} onChange={(e) => setNote(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function ReopenDlg({ month, onClose, onDone }: { month: string; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const [code, setCode] = useState('');
  const { busy, error, run } = useAction();
  const go = () => run(async () => { await rpc('reopen_month', { p_month: month, p_reason: reason, p_code: code }); onDone(); });
  return (
    <Modal title={`إعادة فتح ${fmtMonth(month)}`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim() || !code} onClick={go}>إعادة الفتح</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>تبقى النسخة الحالية محفوظة للمراجعة، ويُنشأ إغلاق لاحق نسخة جديدة.</Msg>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <Field label="الرمز السري للإدارة"><input type="password" autoComplete="off" value={code} onChange={(e) => setCode(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
