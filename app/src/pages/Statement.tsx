// P07 — كشف حساب العميل (STMT-001..010، FIN-001، B034، B041–B045).
// الصفحة للقراءة والعرض والتصدير: لا تنشئ قيدًا ولا تعيد FIFO. الرسمي من Ledger، والمخصص
// يخفي حركات من نسخة العرض فقط ويعيد حساب أرقامه. الطباعة وExcel لكل الحركات المطابقة للفلاتر.
import { useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { rpc, sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, todayIso } from '../lib/format';
import { writeSheet } from '../lib/excel';
import { docLink, Statement as Stmt, StmtLine, StmtOptions, STMT_KINDS, stmtTypeLabel, useCompany, Company } from '../lib/accounts';
import { CustomerPicker, loadCustomer, PickedCustomer } from '../components/CustomerPicker';
import { Field, Modal, Msg, useAction } from '../components/ui';

interface Saved {
  id: number; name: string; customer_id: number; family: boolean; date_from: string; date_to: string; custom: boolean;
  options: Partial<StmtOptions>; hidden: string[]; fingerprint: string | null; created_by_name: string | null; updated_at: string;
}

const PAGE = 100;
const EMPTY: StmtOptions = { kinds: [], affect: 'all', search: '', show_deleted: false, custom: false, hidden: [] };

export function Statement() {
  const { can } = useAuth();
  const [params] = useSearchParams();
  const [cust, setCust] = useState<PickedCustomer | null>(null);
  const [family, setFamily] = useState(false);
  const [from, setFrom] = useState(`${todayIso().slice(0, 4)}-01-01`);
  const [to, setTo] = useState(todayIso());
  const [opts, setOpts] = useState<StmtOptions>(EMPTY);
  const [data, setData] = useState<Stmt | null>(null);
  const [page, setPage] = useState(0);
  const [saved, setSaved] = useState<Saved[]>([]);
  const [openSaved, setOpenSaved] = useState<Saved | null>(null);
  const [saving, setSaving] = useState(false);
  const [preview, setPreview] = useState(false);
  const [compare, setCompare] = useState(false);
  const load = useAction();

  // فتح كشف عميل من رابط (ملف العميل أو الذمم)
  useEffect(() => {
    const id = Number(params.get('customer'));
    if (id) loadCustomer(id).then((c) => { if (c) { setCust(c); setFamily(params.get('family') === '1'); } });
  }, [params]);

  const loadSaved = () => sb().from('saved_statements').select('*').order('updated_at', { ascending: false })
    .then(({ data: d }) => setSaved((d ?? []) as Saved[]));
  useEffect(() => { loadSaved(); }, []);

  const optKey = JSON.stringify(opts);
  useEffect(() => {
    if (!cust) { setData(null); return; }
    load.run(async () => {
      const r = await rpc<Stmt>('account_statement', { p_customer: cust.id, p_family: family, p_from: from, p_to: to, p_opts: opts });
      setData(r); setPage(0);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cust?.id, family, from, to, optKey]);

  const set = <K extends keyof StmtOptions>(k: K, v: StmtOptions[K]) => setOpts((o) => ({ ...o, [k]: v }));
  const toggleKind = (k: string) => set('kinds', opts.kinds.includes(k) ? opts.kinds.filter((x) => x !== k) : [...opts.kinds, k]);
  const toggleHide = (key: string) => set('hidden', opts.hidden.includes(key) ? opts.hidden.filter((x) => x !== key) : [...opts.hidden, key]);

  const applySaved = async (s: Saved) => {
    const c = await loadCustomer(s.customer_id);
    if (!c) return;
    setCust(c); setFamily(s.family); setFrom(s.date_from); setTo(s.date_to);
    setOpts({ ...EMPTY, ...s.options, custom: s.custom, hidden: s.hidden });
    setOpenSaved(s);
  };

  const lines = data?.lines ?? [];
  const pages = Math.max(1, Math.ceil(lines.length / PAGE));
  const shown = lines.slice(page * PAGE, (page + 1) * PAGE);
  const custom = data?.custom ?? false;
  const totals = custom ? data!.custom_totals! : data?.official;
  const changedSinceSave = openSaved && data && openSaved.customer_id === data.customer.id && openSaved.fingerprint !== data.fingerprint;

  return (
    <>
      <div className="page-head">
        <h1>كشف حساب العميل</h1>
        <div className="actions">
          {saved.length > 0 && (
            <select className="input" style={{ width: 'auto' }} value="" aria-label="الكشوف المحفوظة"
              onChange={(e) => { const s = saved.find((x) => x.id === Number(e.target.value)); if (s) applySaved(s); }}>
              <option value="">الكشوف المحفوظة…</option>
              {saved.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          )}
          {data && can('P07', 'snapshot') && <button className="btn" onClick={() => setSaving(true)}>حفظ الكشف</button>}
          {data && can('P07', 'export') && <button className="btn" onClick={() => exportExcel(data, cust!)}>تصدير Excel</button>}
          {data && can('P07', 'print') && <button className="btn primary" onClick={() => setPreview(true)}>معاينة وطباعة</button>}
        </div>
      </div>

      <div className="panel" style={{ display: 'grid', gap: 10 }}>
        <div className="grid2">
          <Field label="العميل"><CustomerPicker value={cust} onChange={(c) => { setCust(c); setOpenSaved(null); setOpts((o) => ({ ...o, hidden: [] })); }} /></Field>
          <fieldset className="plain">
            <legend>النطاق</legend>
            <div className="actions">
              <label><input type="radio" name="scope" checked={!family} onChange={() => setFamily(false)} /> هذا الحساب فقط</label>
              <label><input type="radio" name="scope" checked={family} onChange={() => setFamily(true)} /> العائلة كاملة</label>
            </div>
          </fieldset>
        </div>
        <div className="filters" style={{ marginBottom: 0 }}>
          <label className="small muted">من <input className="input" type="date" value={from} onChange={(e) => setFrom(e.target.value)} aria-label="من تاريخ" /></label>
          <label className="small muted">إلى <input className="input" type="date" value={to} onChange={(e) => setTo(e.target.value)} aria-label="إلى تاريخ" /></label>
          <div className="tabs" role="tablist" aria-label="نوع الكشف" style={{ border: 0, padding: 0 }}>
            <button role="tab" aria-selected={!opts.custom} onClick={() => set('custom', false)}>رسمي</button>
            <button role="tab" aria-selected={opts.custom} onClick={() => set('custom', true)}>مخصص</button>
          </div>
          <select className="input" value={opts.affect} onChange={(e) => set('affect', e.target.value as StmtOptions['affect'])} aria-label="التأثير على الذمم">
            <option value="all">المؤثر وغير المؤثر</option><option value="affecting">المؤثر في الذمم</option><option value="non">غير المؤثر</option>
          </select>
          <input className="input" placeholder="بحث: رقم أو بيان أو قيمة" value={opts.search} onChange={(e) => set('search', e.target.value)} aria-label="بحث داخل الحركات" />
          <label className="small"><input type="checkbox" checked={opts.show_deleted} onChange={(e) => set('show_deleted', e.target.checked)} /> إظهار المحذوفات للمراجعة</label>
        </div>
        <div className="actions" role="group" aria-label="نوع الحركة">
          {STMT_KINDS.map(([k, l]) => (
            <label key={k} className="small"><input type="checkbox" checked={opts.kinds.includes(k)} onChange={() => toggleKind(k)} /> {l}</label>
          ))}
          {(opts.kinds.length > 0 || opts.affect !== 'all' || opts.search) && (
            <button className="btn link" onClick={() => setOpts((o) => ({ ...o, kinds: [], affect: 'all', search: '' }))}>مسح الفلاتر</button>
          )}
        </div>
      </div>

      {!cust && <div className="panel muted" style={{ marginTop: 12 }}>اختر عميلًا لعرض كشفه.</div>}
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {data && (
        <div style={{ marginTop: 12 }}>
          {changedSinceSave && <Msg>تغيرت البيانات منذ الحفظ؛ الأرقام المعروضة محدثة من المصدر، والإخفاء محفوظ بهويات الحركات (B043).</Msg>}
          {data.warnings.map((w, i) => <Msg key={i}>{w.message}</Msg>)}
          <div className="page-head" style={{ marginBottom: 6 }}>
            <div>
              <strong>{stmtTypeLabel(data)}</strong> · {data.family ? `العائلة كاملة — الرئيسي ${data.customer.head.customer_number} ${data.customer.head.name}` : `حساب ${data.customer.customer_number} فقط (${data.customer.role})`}
              <span className="muted small"> · من <span className="num">{fmtDate(data.from)}</span> إلى <span className="num">{fmtDate(data.to)}</span></span>
            </div>
            {custom && <button className="btn link" onClick={() => setCompare(!compare)} aria-expanded={compare}>{compare ? 'إخفاء المقارنة' : 'مقارنة الرسمي بالمخصص'}</button>}
          </div>
          <div className="stats" aria-label="ملخص الكشف">
            <div className="stat"><div className="l">الرصيد السابق</div><div className="v num">{fmtAmount(totals!.prev)}</div></div>
            <div className="stat"><div className="l">المدين</div><div className="v num">{fmtAmount(totals!.debit)}</div></div>
            <div className="stat"><div className="l">الدائن</div><div className="v num">{fmtAmount(totals!.credit)}</div></div>
            <div className="stat"><div className="l">الرصيد النهائي{custom ? ' (مخصص)' : ''}</div><div className="v num">{fmtAmount(totals!.final)}</div></div>
            {data.filtered && (
              <div className="stat"><div className="l">نتائج الفلتر: <span className="num">{data.results.count}</span> حركة</div>
                <div className="v num small">مدين {fmtAmount(data.results.debit)} · دائن {fmtAmount(data.results.credit)}</div></div>
            )}
          </div>
          {custom && compare && (
            <div className="tbl" style={{ marginBottom: 10 }}><table>
              <thead><tr><th></th><th>السابق</th><th>المدين</th><th>الدائن</th><th>النهائي</th></tr></thead>
              <tbody>
                {[['الرسمي', data.official], ['المخصص', data.custom_totals!]].map(([l, t]) => (
                  <tr key={l as string}><td>{l as string}</td>{(['prev', 'debit', 'credit', 'final'] as const).map((k) => <td key={k} className="num">{fmtAmount((t as Stmt['official'])[k])}</td>)}</tr>
                ))}
                <tr><td>الحركات المخفية</td><td colSpan={4} className="num">{data.custom_totals!.hidden_count}</td></tr>
              </tbody></table></div>
          )}
          <StatementTable data={data} rows={shown} onToggle={toggleHide} />
          {pages > 1 && (
            <div className="pager">
              <span>عرض <span className="num">{page * PAGE + 1}</span> إلى <span className="num">{Math.min(lines.length, (page + 1) * PAGE)}</span> من <span className="num">{lines.length}</span>؛ الطباعة وExcel لكل الحركات</span>
              <span className="actions">
                <button className="btn" disabled={page === 0} onClick={() => setPage(page - 1)}>السابق</button>
                <button className="btn" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>التالي</button>
              </span>
            </div>
          )}
        </div>
      )}
      {saving && data && <SaveModal data={data} opts={opts} existing={openSaved} onClose={() => setSaving(false)}
        onSaved={(s) => { setSaving(false); loadSaved(); setOpenSaved(s); }} />}
      {preview && data && <PrintPreview data={data} onClose={() => setPreview(false)} />}
    </>
  );
}

function StatementTable({ data, rows, onToggle }: { data: Stmt; rows: StmtLine[]; onToggle: (k: string) => void }) {
  const custom = data.custom;
  return (
    <div className="tbl">
      <table>
        <thead><tr>
          <th>التاريخ</th><th>النوع</th><th>الرقم</th><th>البيان</th>{data.family && <th>الحساب</th>}
          <th className="num">مدين</th><th className="num">دائن</th><th className="num">الرصيد</th>
          {custom && <th className="num">الرصيد المخصص</th>}<th></th>
        </tr></thead>
        <tbody>
          {rows.length === 0 ? <tr><td colSpan={10} className="empty">لا حركات ضمن الفترة والفلاتر</td></tr> : rows.map((l) => {
            const link = docLink(l);
            return (
              <tr key={l.key} className={(l.hidden ? 'row-hidden ' : '') + (!l.affecting ? 'row-muted' : '')}>
                <td className="num">{fmtDate(l.date)}</td>
                <td>{l.kind_label}{l.deleted && <span className="badge bad" style={{ marginInlineStart: 4 }}>محذوف</span>}</td>
                <td className="num">{l.number ?? ''}</td>
                <td>{l.description}</td>
                {data.family && <td className="small"><span className="num">{l.account_number}</span> {l.account_name}</td>}
                <td className="num">{l.debit ? fmtAmount(l.debit) : ''}</td>
                <td className="num">{l.credit ? fmtAmount(l.credit) : ''}</td>
                <td className="num">{fmtAmount(l.balance)}</td>
                {custom && <td className="num">{l.hidden ? <span className="muted small">مخفية</span> : fmtAmount(l.custom_balance)}</td>}
                <td className="actions">
                  {custom && l.hideable && <button className="btn link" onClick={() => onToggle(l.key)}>{l.hidden ? 'إعادة' : 'إخفاء'}</button>}
                  {link && !l.deleted && <Link to={link} className="small">فتح</Link>}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function SaveModal({ data, opts, existing, onClose, onSaved }: {
  data: Stmt; opts: StmtOptions; existing: Saved | null; onClose: () => void; onSaved: (s: Saved) => void;
}) {
  const [name, setName] = useState(existing?.name ?? `كشف ${data.customer.name}`);
  const { busy, error, run } = useAction();
  const save = (asNew: boolean) => run(async () => {
    const id = await rpc<number>('save_statement', { p_id: asNew ? null : existing!.id, p: {
      name, customer_id: data.customer.id, family: data.family, date_from: data.from, date_to: data.to, custom: opts.custom,
      hidden: opts.hidden, options: { kinds: opts.kinds, affect: opts.affect, search: opts.search, show_deleted: opts.show_deleted, custom: opts.custom, hidden: opts.hidden },
    } });
    const { data: s } = await sb().from('saved_statements').select('*').eq('id', id).single();
    onSaved(s as Saved);
  });
  return (
    <Modal title="حفظ الكشف" onClose={onClose} footer={<>
      {existing && <button className="btn primary" disabled={busy || !name.trim()} onClick={() => save(false)}>تحديث «{existing.name}»</button>}
      <button className={'btn' + (existing ? '' : ' primary')} disabled={busy || !name.trim()} onClick={() => save(true)}>حفظ كشف جديد</button>
      <button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Msg>يُحفظ العميل والنطاق والفترة والفلاتر والحركات المخفية فقط؛ ليس نسخة مالية ثابتة. عند تغير المصدر يظهر تنبيه وتحدث الأرقام (B043).</Msg>
      <Field label="اسم الكشف"><input value={name} onChange={(e) => setName(e.target.value)} autoFocus /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// المعاينة والطباعة (STMT-007، PRINT-002/003): الشركة من الإعدادات، والعميل والفترة والنطاق
// والملخص والحركات، وأسفلها إجمالي المبلغ المطلوب فقط. لا عمود مندوب ولا تواقيع ولا تذييل.
// ---------------------------------------------------------------------
function PrintPreview({ data, onClose }: { data: Stmt; onClose: () => void }) {
  const company = useCompany();
  return (
    <Modal title="معاينة كشف الحساب" wide onClose={onClose} footer={<>
      <button className="btn primary" onClick={() => window.print()}>إرسال للطابعة / حفظ PDF</button>
      <button className="btn" onClick={onClose}>إغلاق</button></>}>
      <p className="small muted no-print">لحفظ PDF اختر «حفظ بتنسيق PDF» في نافذة الطباعة؛ الوثيقة تطابق المعاينة وتشمل كل الحركات المطابقة.</p>
      <StatementDoc data={data} company={company} />
    </Modal>
  );
}

export function StatementDoc({ data, company }: { data: Stmt; company: Company }) {
  const custom = data.custom;
  const t = custom ? data.custom_totals! : data.official;
  const rows = useMemo(() => data.lines.filter((l) => !(custom && l.hidden)), [data, custom]);
  return (
    <div className="print-doc" dir="rtl">
      <div className="doc-head">
        <div>
          {company.name && <div className="doc-company">{company.name}</div>}
          {company.tax_no && <div className="small">الرقم الضريبي: <span className="num">{company.tax_no}</span></div>}
          {company.phone && <div className="small">الهاتف: <span className="num">{company.phone}</span></div>}
          {company.header && <div className="small" style={{ whiteSpace: 'pre-line' }}>{company.header}</div>}
        </div>
        {company.logo && <img src={company.logo} alt="شعار الشركة" className="doc-logo" />}
      </div>
      <h2 className="doc-title">كشف حساب عميل — {stmtTypeLabel(data)}</h2>
      <div className="doc-meta">
        <div>العميل: <span className="num">{data.customer.customer_number}</span> — {data.customer.name}</div>
        <div>النطاق: {data.family ? `العائلة كاملة (الرئيسي ${data.customer.head.customer_number} — ${data.customer.head.name})` : 'هذا الحساب فقط'}</div>
        <div>الفترة: من <span className="num">{fmtDate(data.from)}</span> إلى <span className="num">{fmtDate(data.to)}</span></div>
      </div>
      <table className="doc-summary"><tbody><tr>
        <td>الرصيد السابق<br /><span className="num">{fmtAmount(t.prev)}</span></td>
        <td>المدين<br /><span className="num">{fmtAmount(t.debit)}</span></td>
        <td>الدائن<br /><span className="num">{fmtAmount(t.credit)}</span></td>
        <td>الرصيد النهائي<br /><span className="num">{fmtAmount(t.final)}</span></td>
      </tr></tbody></table>
      <table className="doc-table">
        <thead><tr><th>التاريخ</th><th>النوع</th><th>الرقم</th><th>البيان</th>{data.family && <th>الحساب</th>}<th>مدين</th><th>دائن</th><th>الرصيد</th></tr></thead>
        <tbody>
          {rows.map((l) => (
            <tr key={l.key}>
              <td className="num">{fmtDate(l.date)}</td><td>{l.kind_label}</td><td className="num">{l.number ?? ''}</td><td>{l.description}</td>
              {data.family && <td className="num">{l.account_number}</td>}
              <td className="num">{l.debit ? fmtAmount(l.debit) : ''}</td><td className="num">{l.credit ? fmtAmount(l.credit) : ''}</td>
              <td className="num">{fmtAmount(custom ? l.custom_balance : l.balance)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="doc-total">إجمالي المبلغ المطلوب: <span className="num">{fmtAmount(t.final)}</span></div>
    </div>
  );
}

function exportExcel(data: Stmt, cust: PickedCustomer) {
  const custom = data.custom;
  const t = custom ? data.custom_totals! : data.official;
  const rows = data.lines.filter((l) => !(custom && l.hidden));
  const head: (string | number | null)[][] = [
    [stmtTypeLabel(data), null, null, null, null, null, null, null],
    [`العميل: ${data.customer.customer_number} — ${data.customer.name}`, null, null, null, null, null, null, null],
    [`النطاق: ${data.family ? 'العائلة كاملة' : 'هذا الحساب فقط'} · الفترة ${fmtDate(data.from)} – ${fmtDate(data.to)}`, null, null, null, null, null, null, null],
    ['الرصيد السابق', fmtAmount(t.prev), 'المدين', fmtAmount(t.debit), 'الدائن', fmtAmount(t.credit), 'النهائي', fmtAmount(t.final)],
    [null, null, null, null, null, null, null, null],
    ['التاريخ', 'النوع', 'الرقم', 'البيان', 'الحساب', 'مدين', 'دائن', 'الرصيد'],
  ];
  const body = rows.map((l) => [fmtDate(l.date), l.kind_label, l.number, l.description, l.account_number,
    l.debit ? fmtAmount(l.debit) : null, l.credit ? fmtAmount(l.credit) : null, fmtAmount(custom ? l.custom_balance : l.balance)]);
  const [h0, ...rest] = head;
  writeSheet(`كشف ${cust.customer_number} ${data.from} ${data.to}.xlsx`, 'كشف الحساب', h0.map((x) => (x === null ? '' : String(x))), [...rest, ...body]);
}
