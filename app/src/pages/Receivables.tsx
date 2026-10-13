// P08 — الذمم الحالية (B037، B039، STMT-009، جولات 7/10/2026): تاريخ الرصيد والعميل/العائلة والمندوب
// ضمن النطاق المسموح. المدينون بالمتبقي والمتأخر والمستحق، والدائنون منفصلون لا يسقط رصيدهم.
// فتح الحساب يعرض البنود المفتوحة وتفسير «كيف سُدد؟». الافتتاحي بلا عمر أو مندوب مختلق.
import { Fragment, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { rpc, sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { CustomerPicker, PickedCustomer } from '../components/CustomerPicker';
import { Badge, Modal, Msg, useAction, useGuarded } from '../components/ui';

interface PaidBy { credit_key: string; kind: string; number: string | null; date: string; account_number: string; amount: string; applied: string }
interface Item {
  key: string; kind: string; kind_label: string; number: string | null; date: string | null; due: string | null; age: number | null;
  overdue: boolean; amount: string; paid: string; remaining: string; employee_id: number | null; employee_name: string | null;
  doc_id: number | null; paid_by: PaidBy[];
}
interface Debtor {
  account_id: number; customer_number: string; name: string; role: string; master_number: string | null; master_name: string | null;
  grace_days: number; balance: string; open_total: string; overdue_total: string; oldest_age: number | null; items: Item[];
}
interface Recv {
  as_of: string; year: number;
  summary: { remaining: string; overdue: string; debtors: number; creditors_total: string; unattributed: string };
  debtors: Debtor[]; creditors: { account_id: number; customer_number: string; name: string; balance: string }[];
  unknown_openings: string[];
}
interface Review { doc_id: number; doc_number: string; doc_date: string; total: string; customer_number: string; customer_name: string; current: string; proposed: string; prev_balance: string | null }

const CLASS: Record<string, string> = { credit: 'ذمم', cash: 'نقدي', unknown: 'غير مصنف' };

export function Receivables() {
  const { can } = useAuth();
  const [date, setDate] = useState(todayIso());
  const [cust, setCust] = useState<PickedCustomer | null>(null);
  const [family, setFamily] = useState(true);
  const [emp, setEmp] = useState('');
  const [emps, setEmps] = useState<{ id: number; emp_number: string; name: string }[]>([]);
  const [data, setData] = useState<Recv | null>(null);
  const [tab, setTab] = useState<'debtors' | 'creditors' | 'reviews'>('debtors');
  const [open, setOpen] = useState<Set<number>>(new Set());
  const [paid, setPaid] = useState<Item | null>(null);
  const [overdueOnly, setOverdueOnly] = useState(false);
  const [ver, setVer] = useState(0);
  const load = useAction();

  useEffect(() => {
    sb().from('employees').select('id, emp_number, name').order('emp_number').then(({ data: d }) => setEmps((d ?? []) as typeof emps));
  }, []);
  useEffect(() => {
    load.run(async () => {
      setData(await rpc<Recv>('receivables', { p_date: date, p_opts: { customer_id: cust?.id ?? null, family, employee_id: emp ? Number(emp) : null } }));
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date, cust?.id, family, emp, ver]);

  const debtors = (data?.debtors ?? []).filter((d) => !overdueOnly || Number(d.overdue_total) > 0);
  const toggle = (id: number) => setOpen((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; });

  const doExport = () => {
    if (!data) return;
    const rows: (string | number | null)[][] = [];
    for (const d of debtors) for (const i of d.items) {
      rows.push([d.customer_number, d.name, d.role, d.master_number, i.kind_label, i.number, fmtDate(i.date), fmtDate(i.due), i.age,
        fmtAmount(i.amount), fmtAmount(i.paid), fmtAmount(i.remaining), i.overdue ? 'متأخر' : '', i.employee_name ?? 'غير منسوب']);
    }
    writeSheet(`الذمم ${date}.xlsx`, 'الذمم', ['رقم العميل', 'العميل', 'النوع', 'الرئيسي', 'البند', 'الرقم', 'التاريخ', 'الاستحقاق', 'العمر',
      'الأصل', 'المسدد', 'المتبقي', 'الحالة', 'المندوب'], rows);
  };

  return (
    <>
      <div className="page-head">
        <h1>الذمم الحالية</h1>
        <div className="actions">{data && can('P08', 'export') && <button className="btn" onClick={doExport}>تصدير Excel</button>}</div>
      </div>
      <div className="filters">
        <label className="small muted">تاريخ الرصيد <input className="input" type="date" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} aria-label="تاريخ الرصيد" /></label>
        <div style={{ minWidth: 280 }}><CustomerPicker value={cust} onChange={setCust} /></div>
        {cust && <label className="small"><input type="checkbox" checked={family} onChange={(e) => setFamily(e.target.checked)} /> العائلة كاملة</label>}
        <select className="input" value={emp} onChange={(e) => setEmp(e.target.value)} aria-label="المندوب">
          <option value="">كل المندوبين</option>
          {emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}
        </select>
        <label className="small"><input type="checkbox" checked={overdueOnly} onChange={(e) => setOverdueOnly(e.target.checked)} /> المتأخر فقط</label>
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {data && (
        <>
          {data.unknown_openings.length > 0 && <Msg>افتتاح {data.year} غير محدد لـ<span className="num">{data.unknown_openings.length}</span> حساب؛ أرصدتها لا تشمل ما قبل السنة: {data.unknown_openings.slice(0, 10).join('، ')}</Msg>}
          <div className="stats" aria-label="ملخص الذمم">
            <div className="stat"><div className="l">إجمالي المتبقي</div><div className="v num">{fmtAmount(data.summary.remaining)}</div></div>
            <div className="stat"><div className="l">المتأخر</div><div className="v num" style={{ color: 'var(--bad)' }}>{fmtAmount(data.summary.overdue)}</div></div>
            <div className="stat"><div className="l">حسابات مدينة</div><div className="v num">{data.summary.debtors}</div></div>
            <div className="stat"><div className="l">أرصدة دائنة للعملاء</div><div className="v num">{fmtAmount(data.summary.creditors_total)}</div></div>
            <div className="stat"><div className="l">غير منسوب لمندوب</div><div className="v num">{fmtAmount(data.summary.unattributed)}</div></div>
          </div>
          <div className="tabs" role="tablist" style={{ marginBottom: 10 }}>
            <button role="tab" aria-selected={tab === 'debtors'} onClick={() => setTab('debtors')}>المدينون ({debtors.length})</button>
            <button role="tab" aria-selected={tab === 'creditors'} onClick={() => setTab('creditors')}>الدائنون ({data.creditors.length})</button>
            {can('P06') && <button role="tab" aria-selected={tab === 'reviews'} onClick={() => setTab('reviews')}>مراجعة تصنيف المرتجعات</button>}
          </div>
          {tab === 'debtors' && (
            <div className="tbl"><table>
              <thead><tr><th>العميل</th><th>النوع</th><th className="num">الرصيد</th><th className="num">المتبقي المفتوح</th><th className="num">المتأخر</th><th className="num">عمر أقدم فاتورة</th><th></th></tr></thead>
              <tbody>
                {debtors.length === 0 ? <tr><td colSpan={7} className="empty">لا ذمم مفتوحة ضمن الفلاتر</td></tr> : debtors.map((d) => (
                  <Fragment key={d.account_id}>
                    <tr className={'clickable' + (Number(d.overdue_total) > 0 ? ' row-overdue' : '')} onClick={() => toggle(d.account_id)} tabIndex={0}
                      onKeyDown={(e) => e.key === 'Enter' && toggle(d.account_id)} aria-expanded={open.has(d.account_id)}>
                      <td><span className="num">{d.customer_number}</span> — {d.name}{d.master_number && <span className="muted small"> (الرئيسي {d.master_number})</span>}</td>
                      <td>{d.role}</td>
                      <td className="num">{fmtAmount(d.balance)}</td>
                      <td className="num">{fmtAmount(d.open_total)}</td>
                      <td className="num">{Number(d.overdue_total) > 0 ? <>{fmtAmount(d.overdue_total)} <Badge kind="bad">متأخر</Badge></> : '—'}</td>
                      <td className="num">{d.oldest_age ?? '—'}</td>
                      <td><Link to={`/statement?customer=${d.account_id}`} onClick={(e) => e.stopPropagation()} className="small">الكشف</Link></td>
                    </tr>
                    {open.has(d.account_id) && (
                      <tr><td colSpan={7} style={{ background: 'var(--surface-2)' }}>
                        <table className="inner"><thead><tr><th>البند</th><th>الرقم</th><th>التاريخ</th><th>الاستحقاق</th><th className="num">العمر</th>
                          <th className="num">الأصل</th><th className="num">المسدد</th><th className="num">المتبقي</th><th>المندوب</th><th></th></tr></thead>
                          <tbody>{d.items.map((i) => (
                            <tr key={i.key} className={i.overdue ? 'row-overdue' : ''}>
                              <td>{i.kind === 'open_debit' ? 'افتتاحي' : i.kind_label}{i.overdue && <> <Badge kind="bad">متأخر</Badge></>}</td>
                              <td className="num">{i.number ?? ''}</td><td className="num">{fmtDate(i.date)}</td><td className="num">{fmtDate(i.due)}</td>
                              <td className="num">{i.age ?? ''}</td><td className="num">{fmtAmount(i.amount)}</td><td className="num">{fmtAmount(i.paid)}</td>
                              <td className="num">{fmtAmount(i.remaining)}</td><td>{i.employee_name ?? <span className="muted small">غير منسوب</span>}</td>
                              <td>{i.paid_by.length > 0 && <button className="btn link" onClick={() => setPaid(i)}>كيف سُدد؟</button>}</td>
                            </tr>
                          ))}</tbody></table>
                        <p className="small muted" style={{ margin: '6px 0 0' }}>فترة السماح <span className="num">{d.grace_days}</span> يومًا؛ الاستحقاق = التاريخ + السماح.</p>
                      </td></tr>
                    )}
                  </Fragment>
                ))}
              </tbody></table></div>
          )}
          {tab === 'creditors' && (
            <>
              <Msg kind="ok">الرصيد الدائن يسدد ديون العميل اللاحقة تلقائيًا بالأقدم أولًا ضمن نطاقه، ولا يصرف نقدًا (STMT-009).</Msg>
              <div className="tbl"><table><thead><tr><th>العميل</th><th className="num">الرصيد الدائن</th><th></th></tr></thead>
                <tbody>{data.creditors.length === 0 ? <tr><td colSpan={3} className="empty">لا أرصدة دائنة</td></tr> : data.creditors.map((c) => (
                  <tr key={c.account_id}><td><span className="num">{c.customer_number}</span> — {c.name}</td><td className="num">{fmtAmount(String(-Number(c.balance)))}</td>
                    <td><Link to={`/statement?customer=${c.account_id}`} className="small">الكشف</Link></td></tr>
                ))}</tbody></table></div>
            </>
          )}
          {tab === 'reviews' && <ReturnReviews onChanged={() => setVer(ver + 1)} />}
        </>
      )}
      {paid && (
        <Modal title={`كيف سُدد ${paid.kind === 'open_debit' ? 'الافتتاحي' : paid.kind_label + ' ' + (paid.number ?? '')}؟`} onClose={() => setPaid(null)}>
          <p className="small">الأصل <span className="num">{fmtAmount(paid.amount)}</span> · المسدد <span className="num">{fmtAmount(paid.paid)}</span> · المتبقي <span className="num">{fmtAmount(paid.remaining)}</span></p>
          <div className="tbl"><table><thead><tr><th>السند الدائن</th><th>الرقم</th><th>تاريخه</th><th>من حساب</th><th>تاريخ التسديد</th><th className="num">المبلغ</th></tr></thead>
            <tbody>{paid.paid_by.map((p, i) => (
              <tr key={i}><td>{p.kind}</td><td className="num">{p.number ?? ''}</td><td className="num">{fmtDate(p.date)}</td><td className="num">{p.account_number}</td>
                <td className="num">{fmtDate(p.applied)}</td><td className="num">{fmtAmount(p.amount)}</td></tr>
            ))}</tbody></table></div>
          <p className="small muted">التوزيع نتيجة محسوبة: الافتتاحي أولًا ثم الأقدم (FIN-004، COL-008)؛ لا ينشئ تحصيلات إضافية.</p>
        </Modal>
      )}
    </>
  );
}

// مراجعة إعادة التصنيف (B035): تصحيح قديم غيّر الرصيد السابق لمرتجع لاحق
function ReturnReviews({ onChanged }: { onChanged: () => void }) {
  const { can } = useAuth();
  const [rows, setRows] = useState<Review[] | null>(null);
  const [sel, setSel] = useState<Set<number>>(new Set());
  const { busy, error, run } = useAction();
  const guarded = useGuarded();
  const load = () => run(async () => { setRows(await rpc<Review[]>('return_reviews')); setSel(new Set()); });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { load(); }, []);
  const approve = () => run(async () => {
    await guarded((code) => rpc('approve_return_reclass', { p_doc_ids: [...sel], p_code: code }));
    await load(); onChanged();
  });
  return (
    <div className="panel">
      <Msg>تصنيف المرتجع المعتمد لا يتغير بصمت. إذا غيّر تصحيح سابق الرصيد قبل المرتجع يظهر هنا الفرق للمراجعة قبل اعتماد إعادة التصنيف (B035).</Msg>
      {error && <Msg kind="bad">{error}</Msg>}
      {rows && rows.length === 0 && <p className="muted">لا مرتجعات تحتاج مراجعة.</p>}
      {rows && rows.length > 0 && (
        <>
          <div className="tbl"><table><thead><tr><th></th><th>المرتجع</th><th>التاريخ</th><th>العميل</th><th className="num">القيمة</th><th>المعتمد</th><th>المقترح</th><th className="num">الرصيد السابق الآن</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.doc_id}>
                <td><input type="checkbox" aria-label={`تحديد ${r.doc_number}`} checked={sel.has(r.doc_id)} disabled={r.proposed === 'unknown'}
                  onChange={() => setSel((s) => { const n = new Set(s); if (n.has(r.doc_id)) n.delete(r.doc_id); else n.add(r.doc_id); return n; })} /></td>
                <td className="num"><Link to={`/transactions?kind=return&open=${r.doc_id}`}>{r.doc_number}</Link></td>
                <td className="num">{fmtDate(r.doc_date)}</td><td><span className="num">{r.customer_number}</span> — {r.customer_name}</td>
                <td className="num">{fmtAmount(r.total)}</td><td>{CLASS[r.current]}</td><td><strong>{CLASS[r.proposed]}</strong></td>
                <td className="num">{r.prev_balance === null ? 'غير معلوم' : fmtAmount(r.prev_balance)}</td>
              </tr>
            ))}</tbody></table></div>
          {can('P06', 'edit') && <div style={{ marginTop: 8 }}><button className="btn primary" disabled={busy || !sel.size} onClick={approve}>اعتماد إعادة التصنيف للمحدد</button></div>}
        </>
      )}
    </div>
  );
}
