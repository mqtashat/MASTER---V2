// P04 — المنتجات والأسعار (PRD-001..008، PRICE-001..003، B019، B020، B056، B057، B059، DATA-011)
import { useEffect, useState } from 'react';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { fmtAmount, fmtDate, fmtPct, todayIso } from '../lib/format';
import { fetchAll, cleanTerm } from '../lib/query';
import { writeSheet } from '../lib/excel';
import { DataTable, Column } from '../components/DataTable';
import { Drawer, Field, Modal, Msg, useAction, useGuarded } from '../components/ui';
import { ImportWizard, ChangesTable, Counts, PlanError } from '../components/ImportWizard';
import { AuditList } from './Settings';
import { ProductPicker } from './Goals';
import { useProducts } from '../lib/goals';

const TIERS = ['A', 'B', 'C', 'X'];
const RATE_KEYS = [...TIERS.map((t) => 'rep_' + t), ...TIERS.map((t) => 'supervisor_' + t)];
const HEADERS = ['كود الصنف', 'اسم الصنف (عربي)', 'سعر البيع', 'سعر التكلفة', 'عدد الحبات في الكرتونة',
  ...TIERS.map((t) => 'عمولة المندوب ' + t), ...TIERS.map((t) => 'عمولة المشرف ' + t)];

interface ProductRow { id: number; code: string; name: string; sale_price: string | null; cost_price: string | null;
  packets_per_carton: string | null; rates: Record<string, number> | null; [k: string]: unknown }

const KIND_LABEL: Record<string, string> = { sale: 'سعر البيع', cost: 'سعر التكلفة', packing: 'عدد الباكيتات في الكرتونة', name: 'الاسم',
  ...Object.fromEntries(TIERS.flatMap((t) => [['rep_' + t, `عمولة المندوب ${t} (%)`], ['supervisor_' + t, `عمولة المشرف ${t} (‰)`]])) };

export function Products() {
  const { can } = useAuth();
  const [term, setTerm] = useState('');
  const [open, setOpen] = useState<number | null>(null);
  const [adding, setAdding] = useState(false);
  const [importing, setImporting] = useState(false);
  const [groupsOpen, setGroupsOpen] = useState(false);
  const [ver, setVer] = useState(0);
  const exp = useAction();
  const [expDate, setExpDate] = useState(todayIso());

  const build = () => {
    let q = sb().from('products_v').select('*', { count: 'exact' });
    const t = cleanTerm(term);
    if (t) q = q.or(`code.ilike.${t}%,name.ilike.%${t}%`);
    return q;
  };

  const cols: Column<ProductRow>[] = [
    { key: 'code', label: 'الكود', sortable: true, num: true },
    { key: 'name', label: 'الصنف', sortable: true },
    { key: 'sale_price', label: 'سعر الباكيت', num: true, render: (r) => r.sale_price === null || Number(r.sale_price) === 0 ? <span className="muted small">سعر غير متوفر</span> : fmtAmount(r.sale_price) },
    ...(can('P04', 'view_cost') ? [{ key: 'cost_price', label: 'التكلفة', num: true, render: (r: ProductRow) => fmtAmount(r.cost_price) } as Column<ProductRow>] : []),
    { key: 'packets_per_carton', label: 'باكيت/كرتونة', num: true, render: (r) => r.packets_per_carton ? fmtPct(r.packets_per_carton) : '—' },
    ...(can('P04', 'view_commission') ? [{ key: 'rates', label: 'المندوب A/B/C/X %', render: (r: ProductRow) => TIERS.map((t) => r.rates?.['rep_' + t] ?? '—').join(' / ') } as Column<ProductRow>] : []),
  ];

  // التصدير بنفس أعمدة ملف المنتجات القابلة لإعادة الاستيراد، بالأسعار السارية بتاريخ مختار (PRD-008)
  const doExport = () => exp.run(async () => {
    const rows = await fetchAll<{ id: number; code: string; name: string }>(() => build().order('code'));
    const at = expDate || todayIso();
    const [prices, packing, rates] = await Promise.all([
      fetchAll<{ product_id: number; kind: string; price: string; effective_from: string }>(() => sb().from('product_prices').select('product_id, kind, price, effective_from').lte('effective_from', at).order('effective_from')),
      fetchAll<{ product_id: number; packets_per_carton: string; effective_from: string }>(() => sb().from('product_packing').select('product_id, packets_per_carton, effective_from').lte('effective_from', at).order('effective_from')),
      can('P04', 'view_commission') ? fetchAll<{ product_id: number; role: string; tier: string; rate: string; effective_from: string }>(() => sb().from('product_commission_rates').select('product_id, role, tier, rate, effective_from').lte('effective_from', at).order('effective_from')) : Promise.resolve([]),
    ]);
    const last = new Map<string, string>();
    prices.forEach((p) => last.set(`${p.product_id}:${p.kind}`, p.price));
    packing.forEach((p) => last.set(`${p.product_id}:packing`, p.packets_per_carton));
    rates.forEach((r) => last.set(`${r.product_id}:${r.role}_${r.tier}`, r.rate));
    writeSheet(`المنتجات ${at}.xlsx`, 'المنتجات', HEADERS, rows.map((r) => [
      r.code, r.name, last.get(`${r.id}:sale`) ?? null, last.get(`${r.id}:cost`) ?? null, last.get(`${r.id}:packing`) ?? null,
      ...RATE_KEYS.map((k) => last.get(`${r.id}:${k}`) ?? null),
    ]));
  });

  return (
    <>
      <div className="page-head">
        <h1>المنتجات والأسعار</h1>
        <div className="actions">
          {can('P04', 'add') && <button className="btn primary" onClick={() => setAdding(true)}>إضافة صنف</button>}
          {can('P04', 'import') && <button className="btn" onClick={() => setImporting(true)}>استيراد</button>}
          <button className="btn" onClick={() => setGroupsOpen(true)}>مجموعات الأصناف</button>
          {can('P04', 'export') && <>
            <label className="small muted">الأسعار السارية بتاريخ <input type="date" className="input" style={{ width: 'auto' }} value={expDate} onChange={(e) => setExpDate(e.target.value)} /></label>
            <button className="btn" disabled={exp.busy} onClick={doExport}>تصدير</button>
          </>}
        </div>
      </div>
      {exp.error && <Msg kind="bad">{exp.error}</Msg>}
      <div className="filters"><input className="input" placeholder="بحث بالكود أو الاسم" value={term} onChange={(e) => setTerm(e.target.value)} /></div>
      <DataTable<ProductRow> columns={cols} rowKey={(r) => r.id} deps={[term, ver]} initialSort="code" onRowClick={(r) => setOpen(r.id)}
        fetcher={async (q) => {
          let b = build();
          if (q.sort) b = b.order(q.sort, { ascending: q.asc });
          const { data, count, error } = await b.range(q.page * q.pageSize, (q.page + 1) * q.pageSize - 1);
          if (error) throw new Error(error.message);
          return { rows: (data ?? []) as ProductRow[], count: count ?? 0 };
        }} />
      <p className="small muted">سعر البيع والتكلفة للباكيت وشاملان للضريبة؛ لا ضريبة في النظام (DATA-011). عمولة المندوب بالمئة والمشرف بالألف.</p>
      {open !== null && <ProductFile id={open} onClose={() => setOpen(null)} onChanged={() => setVer(ver + 1)} />}
      {adding && <ProductForm onClose={() => setAdding(false)} onSaved={() => { setAdding(false); setVer(ver + 1); }} />}
      {groupsOpen && <ProductGroups onClose={() => setGroupsOpen(false)} />}
      {importing && <ImportWizard spec={productImportSpec} onClose={() => setImporting(false)} onDone={() => setVer(ver + 1)} />}
    </>
  );
}

function ProductForm({ row, onClose, onSaved }: { row?: { id: number; code: string; name: string }; onClose: () => void; onSaved: () => void }) {
  const [code, setCode] = useState(row?.code ?? ''); const [name, setName] = useState(row?.name ?? '');
  const { busy, error, run } = useAction();
  const save = () => run(async () => { await rpc('save_product', { p_id: row?.id ?? null, p_code: code, p_name: name }); onSaved(); });
  return (
    <Modal title={row ? 'تعديل الصنف' : 'إضافة صنف'} onClose={onClose} footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <div className="grid2">
        <Field label="كود الصنف"><input value={code} onChange={(e) => setCode(e.target.value)} /></Field>
        <Field label="اسم الصنف"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
      </div>
      {!row && <p className="small muted">الأسعار والتعبئة ونسب العمولة تُضاف بتاريخ سريان من ملف الصنف.</p>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

interface Hist { sale: { date: string; value: string }[]; cost: { date: string; value: string }[] | null;
  packing: { date: string; value: string }[]; rates: { role: string; tier: string; date: string; value: string }[] | null }

function ProductFile({ id, onClose, onChanged }: { id: number; onClose: () => void; onChanged: () => void }) {
  const { can } = useAuth();
  const [tab, setTab] = useState('def');
  const [p, setP] = useState<{ id: number; code: string; name: string } | null>(null);
  const [h, setH] = useState<Hist | null>(null);
  const [ver, setVer] = useState(0);
  const [editing, setEditing] = useState(false);
  const [setting, setSetting] = useState<string | null>(null);
  const [removing, setRemoving] = useState<{ kind: string; date: string } | null>(null);
  const load = useAction();
  useEffect(() => {
    load.run(async () => {
      const { data, error } = await sb().from('products').select('id, code, name').eq('id', id).single();
      if (error) throw new Error(error.message);
      setP(data as typeof p);
      setH(await rpc<Hist>('product_history', { p_product: id }));
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, ver]);
  const changed = () => { setVer(ver + 1); setSetting(null); setRemoving(null); onChanged(); };

  const HistTable = ({ kind, items, unit }: { kind: string; items: { date: string; value: string }[]; unit?: string }) => (
    <div className="panel">
      <div className="page-head"><h3>{KIND_LABEL[kind]}{unit ? ` (${unit})` : ''}</h3>
        {can('P04', 'edit') && <button className="btn" onClick={() => setSetting(kind)}>إضافة/تصحيح بتاريخ</button>}</div>
      {items.length === 0 ? <p className="small muted">{kind === 'sale' ? 'سعر غير متوفر — لا تُحسب كمية مكافئة (B059)' : 'غير محدد'}</p> : (
        <div className="tbl"><table><thead><tr><th>ساري من</th><th>القيمة</th><th></th></tr></thead>
          <tbody>{items.map((x) => <tr key={x.date}><td className="num">{fmtDate(x.date)}</td><td className="num">{kind === 'packing' ? fmtPct(x.value) : kind.includes('_') ? fmtPct(x.value) : fmtAmount(x.value)}</td>
            <td>{can('P04', 'edit') && <button className="btn link" onClick={() => setRemoving({ kind, date: x.date })}>حذف</button>}</td></tr>)}</tbody></table></div>
      )}
    </div>
  );

  return (
    <Drawer title={p ? `${p.code} — ${p.name}` : 'ملف الصنف'} onClose={onClose}
      actions={p && can('P04', 'edit') && <button className="btn" onClick={() => setEditing(true)}>تعديل</button>}>
      <div className="tabs" role="tablist">
        {[['def', 'الأسعار والتعبئة'], ...(can('P04', 'view_commission') ? [['rates', 'نسب العمولة']] : []), ['log', 'سجل التعديل']].map(([k, l]) => (
          <button key={k} role="tab" aria-selected={tab === k} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      {h && tab === 'def' && <>
        <Msg>كل حركة تأخذ القيمة السارية بتاريخها: أحدث تاريخ سريان لا يتجاوز تاريخ الحركة. التعديل لا يغير مبالغ الفواتير المستوردة (PRICE-001..003).</Msg>
        <HistTable kind="sale" items={h.sale} unit="للباكيت" />
        {h.cost && <HistTable kind="cost" items={h.cost} unit="للباكيت" />}
        <HistTable kind="packing" items={h.packing} />
      </>}
      {h?.rates && tab === 'rates' && (
        <>
          <Msg>نسبة الصفر تعني لا عمولة عمدًا؛ غياب النسبة عند الحاجة إليها إعداد ناقص مع تنبيه (B020). التعديل بتاريخ سريان؛ الرجعي لا يغير الأشهر المقفلة إلا برمز الإدارة (B019).</Msg>
          {RATE_KEYS.map((k) => <HistTable key={k} kind={k} items={h.rates!.filter((r) => `${r.role}_${r.tier}` === k)} />)}
        </>
      )}
      {tab === 'log' && <AuditList entity="products" entityId={String(id)} />}
      {editing && p && <ProductForm row={p} onClose={() => setEditing(false)} onSaved={() => { setEditing(false); changed(); }} />}
      {setting && <SetValue productId={id} kind={setting} onClose={() => setSetting(null)} onDone={changed} />}
      {removing && <RemoveValue productId={id} {...removing} onClose={() => setRemoving(null)} onDone={changed} />}
    </Drawer>
  );
}

function SetValue({ productId, kind, onClose, onDone }: { productId: number; kind: string; onClose: () => void; onDone: () => void }) {
  const [v, setV] = useState(''); const [d, setD] = useState(todayIso()); const [reason, setReason] = useState('');
  const [res, setRes] = useState<string | null>(null);
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    const r = await guarded((code) => rpc<string>('set_product_value', { p_product: productId, p_kind: kind, p_value: v, p_date: d, p_reason: reason || null, p_code: code }));
    if (r === 'same') setRes('القيمة مطابقة للسارية في هذا التاريخ؛ لم يُنشأ سجل إضافي.'); else onDone();
  });
  return (
    <Modal title={KIND_LABEL[kind]} onClose={onClose} footer={<><button className="btn primary" disabled={busy || !v || !d} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إغلاق</button></>}>
      <div className="grid2">
        <Field label="القيمة"><input inputMode="decimal" value={v} onChange={(e) => setV(e.target.value)} /></Field>
        <Field label="ساري من" hint="ماضٍ أو حالي أو مستقبلي"><input type="date" value={d} onChange={(e) => setD(e.target.value)} /></Field>
      </div>
      <Field label="السبب (اختياري)"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      <p className="small muted">إذا وُجدت قيمة مختلفة بالتاريخ نفسه تُحفظ تصحيحًا لذلك التاريخ دون قيمتين متعارضتين (PRICE-002).</p>
      {res && <Msg kind="ok">{res}</Msg>}
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function RemoveValue({ productId, kind, date, onClose, onDone }: { productId: number; kind: string; date: string; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction(); const guarded = useGuarded();
  const save = () => run(async () => {
    await guarded((code) => rpc('remove_product_value', { p_product: productId, p_kind: kind, p_date: date, p_reason: reason, p_code: code }));
    onDone();
  });
  return (
    <Modal title="حذف قيمة مؤرخة" onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason} onClick={save}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <p>حذف {KIND_LABEL[kind]} الساري من <span className="num">{fmtDate(date)}</span>. تعود الحركات في فترته إلى القيمة السابقة إن وجدت.</p>
      <Field label="السبب"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

// ---------------------------------------------------------------------
// استيراد المنتجات (PRD-006، PRICE-002)
// ---------------------------------------------------------------------
type PRow = Record<string, string | number> & { row: number };
interface PPlan { errors: PlanError[]; new: { row: number; code: string; name: string }[];
  changed: { row: number; code: string; fields: Record<string, [unknown, unknown]> }[]; needs_dates: string[]; counts: Record<string, number> }
type PDec = { sale: string; cost: string; packing: string; rates: string };

const productImportSpec = {
  title: 'استيراد المنتجات',
  requiredHeaders: HEADERS,
  mapRow: (c: Record<string, string>, row: number): PRow => {
    const r: PRow = { row, code: c['كود الصنف'] ?? '', name: c['اسم الصنف (عربي)'] ?? '', sale: c['سعر البيع'] ?? '',
      cost: c['سعر التكلفة'] ?? '', packing: c['عدد الحبات في الكرتونة'] ?? '' };
    TIERS.forEach((t) => { r['rep_' + t] = c['عمولة المندوب ' + t] ?? ''; r['supervisor_' + t] = c['عمولة المشرف ' + t] ?? ''; });
    return r;
  },
  preview: (rows: PRow[], d: PDec) => rpc<PPlan>('preview_product_import', { p_rows: rows, p_dates: d }),
  commit: (rows: PRow[], d: PDec, fileName: string, code: string | null) =>
    rpc('commit_product_import', { p_rows: rows, p_dates: d, p_file_name: fileName, p_code: code }),
  initialDecisions: { sale: '', cost: '', packing: '', rates: '' } as PDec,
  repreviewOnDecision: true,
  canCommit: (p: PPlan) => (p.needs_dates.length ? 'حدد تاريخ سريان لكل فئة متغيرة' : null),
  renderPlan: (p: PPlan, d: PDec, set: (d: PDec) => void) => (
    <>
      <div className="panel">
        <h3>تواريخ السريان</h3>
        <p className="small muted">يقارن النظام كل قيمة مرفوعة بالقيمة السارية في التاريخ المختار، لا بقيمة اليوم؛ المطابق لا يُنشئ سجلًا إضافيًا (PRICE-002).</p>
        <div className="grid2" style={{ marginTop: 8 }}>
          {([['sale', 'سعر البيع'], ['cost', 'سعر التكلفة'], ['packing', 'التعبئة'], ['rates', 'نسب العمولة']] as const).map(([k, l]) => (
            <Field key={k} label={l} error={p.needs_dates.includes(k) ? 'مطلوب' : undefined}>
              <input type="date" value={d[k]} onChange={(e) => set({ ...d, [k]: e.target.value })} /></Field>
          ))}
        </div>
      </div>
      <Counts items={[['جديد', p.counts.new, 'ok'], ['متغير', p.counts.changed, 'warn'], ['مطابق', p.counts.unchanged], ['أخطاء', p.counts.errors, 'bad']]} />
      <p className="small muted">غياب صنف عن الملف لا يحذفه، والخلية الفارغة لا تمسح القيمة الحالية (PRD-006).</p>
      {p.changed.length > 0 && <div className="panel"><h3>التغييرات (السابق والجديد)</h3><div style={{ marginTop: 8 }}>
        <ChangesTable items={p.changed} keyLabel="الكود" keyField="code" labels={KIND_LABEL} /></div></div>}
      {p.new.length > 0 && <div className="panel"><h3>أصناف جديدة ({p.new.length})</h3><div className="small muted">{p.new.map((n) => `${n.code} ${n.name}`).join('، ')}</div></div>}
    </>
  ),
};

// مجموعات الأصناف العامة (PRD-009): تُعرَّف هنا مرة واحدة وتُستعمل في مكافأة التنويع بحصص المجموعات في قواعد العمولة
interface PGroup { id: number; name: string; products: { id: number; code: string; name: string }[]; used: boolean }

function ProductGroups({ onClose }: { onClose: () => void }) {
  const { can } = useAuth();
  const [groups, setGroups] = useState<PGroup[] | null>(null);
  const [edit, setEdit] = useState<PGroup | 'new' | null>(null);
  const [del, setDel] = useState<PGroup | null>(null);
  const [ver, setVer] = useState(0);
  const load = useAction();
  useEffect(() => { let live = true; load.run(async () => { const r = await rpc<PGroup[]>('product_groups_list'); if (live) setGroups(r); }); return () => { live = false; }; /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [ver]);
  return (
    <Drawer title="مجموعات الأصناف" onClose={onClose} actions={can('P04', 'add') ? <button className="btn primary" onClick={() => setEdit('new')}>مجموعة جديدة</button> : undefined}>
      {load.error && <Msg kind="bad">{load.error}</Msg>}
      <p className="small muted">مجموعات عامة للأصناف تُستعمل في مكافأة التنويع بحصص المجموعات داخل قواعد العمولة. صنف واحد يمكن أن يكون في أكثر من مجموعة، لكن لا يُجمع صنف في مجموعتين ضمن القاعدة نفسها.</p>
      {!groups ? <div className="skeleton" /> : groups.length === 0 ? <div className="panel empty">لا مجموعات بعد.</div> : groups.map((g) => (
        <div key={g.id} className="panel">
          <div className="page-head" style={{ marginBottom: 6 }}>
            <h3>{g.name} <span className="small muted">({g.products.length} صنف){g.used && ' · مستعملة في قاعدة'}</span></h3>
            <div className="actions">
              {can('P04', 'edit') && <button className="btn" onClick={() => setEdit(g)}>تعديل</button>}
              {can('P04', 'edit') && <button className="btn danger" disabled={g.used} onClick={() => setDel(g)}>حذف</button>}
            </div>
          </div>
          <p className="small">{g.products.map((p) => `${p.code} — ${p.name}`).join('، ')}</p>
        </div>
      ))}
      {edit && <GroupForm group={edit === 'new' ? null : edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); setVer(ver + 1); }} />}
      {del && <GroupDelete group={del} onClose={() => setDel(null)} onDone={() => { setDel(null); setVer(ver + 1); }} />}
    </Drawer>
  );
}

function GroupForm({ group, onClose, onDone }: { group: PGroup | null; onClose: () => void; onDone: () => void }) {
  const products = useProducts();
  const [name, setName] = useState(group?.name ?? '');
  const [ids, setIds] = useState<number[]>((group?.products ?? []).map((p) => Number(p.id)));
  const { busy, error, run } = useAction();
  const save = () => run(async () => { await rpc('save_product_group', { p_id: group?.id ?? null, p_name: name, p_products: `{${ids.join(',')}}` }); onDone(); });
  return (
    <Modal wide title={group ? `تعديل «${group.name}»` : 'مجموعة أصناف جديدة'} onClose={onClose}
      footer={<><button className="btn primary" disabled={busy || !name.trim() || !ids.length} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="اسم المجموعة"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
      <ProductPicker products={products} value={ids} onChange={setIds} label="أصناف المجموعة" hint="اختر الأصناف المنتمية للمجموعة" />
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function GroupDelete({ group, onClose, onDone }: { group: PGroup; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const go = () => run(async () => { await rpc('delete_product_group', { p_id: group.id, p_reason: reason }); onDone(); });
  return (
    <Modal title={`حذف «${group.name}»`} onClose={onClose} footer={<><button className="btn danger" disabled={busy || !reason.trim()} onClick={go}>حذف</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="السبب"><input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
