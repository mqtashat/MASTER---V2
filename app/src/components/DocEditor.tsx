// محرر السند: الترويسة وكل البنود أو الأجزاء، مع إضافة بند وإزالته (TXN-001)،
// ومقارنة قبل/بعد وأثر الحقول المتغيرة قبل الحفظ (P06).
import { Fragment } from 'react';
import { DocData, DocLine, Kind, PAY_METHODS, PAY_TYPES } from '../lib/docs';
import { fmtAmount, fmtDate, fmtQty, parseDateInput, sum } from '../lib/format';
import { Field } from './ui';

const INV_FIELDS: [keyof DocLine, string, string][] = [
  ['item_number', 'رقم الصنف', '8em'], ['net_sales', 'المباشر NetSales', '7em'], ['net_promotions', 'العروض NetPromotions', '7em'],
  ['quantity', 'الكمية Quantity', '6em'], ['bonus', 'البونص Bonus', '6em'], ['lat', 'Latitude', '7em'], ['lng', 'Longitude', '7em'],
];

export function DocEditor({ kind, value, onChange }: { kind: Kind; value: DocData; onChange: (d: DocData) => void }) {
  const isCol = kind === 'collection';
  const set = (patch: Partial<DocData>) => onChange({ ...value, ...patch });
  const setLine = (i: number, patch: Partial<DocLine>) => set({ lines: value.lines.map((l, j) => (j === i ? { ...l, ...patch } : l)) });
  const addLine = () => set({ lines: [...value.lines, isCol ? { amount: '', pay_method: 'نقدي', cheque_no: '' } : { item_number: '', net_sales: '0', net_promotions: '0', quantity: '', bonus: '0' }] });
  const removeLine = (i: number) => set({ lines: value.lines.filter((_, j) => j !== i) });
  const total = isCol ? sum(value.lines.map((l) => l.amount ?? null)) : sum(value.lines.flatMap((l) => [l.net_sales ?? null, l.net_promotions ?? null]));

  return (
    <div style={{ display: 'grid', gap: 10 }}>
      <div className="grid3">
        <Field label="رقم السند"><input value={value.doc_number ?? ''} onChange={(e) => set({ doc_number: e.target.value })} /></Field>
        <Field label="رقم العميل"><input value={value.customer_number ?? ''} onChange={(e) => set({ customer_number: e.target.value })} /></Field>
        <Field label="تاريخ السند" hint="يوم/شهر/سنة">
          <input value={value.doc_date && /^\d{4}-/.test(value.doc_date) ? fmtDate(value.doc_date) : value.doc_date ?? ''}
            onChange={(e) => set({ doc_date: parseDateInput(e.target.value) ?? e.target.value })} /></Field>
        <Field label={isCol ? 'رقم المندوب' : 'رقم الموظف'}><input value={value.employee_number ?? ''} onChange={(e) => set({ employee_number: e.target.value })} /></Field>
        {kind === 'invoice' && (
          <Field label="نوع الفاتورة (DocumentTypeID)">
            <select value={value.pay_type ?? ''} onChange={(e) => set({ pay_type: e.target.value })}>
              <option value="">—</option>{PAY_TYPES.map((p) => <option key={p}>{p}</option>)}
            </select></Field>
        )}
      </div>
      <div className="tbl">
        <table className="edit-grid">
          <thead><tr><th>#</th>
            {isCol ? <><th>القيمة</th><th>الدفع</th><th>رقم الشيك</th></> : INV_FIELDS.map(([, l]) => <th key={l}>{l}</th>)}
            <th /></tr></thead>
          <tbody>
            {value.lines.map((l, i) => (
              <tr key={i}>
                <td className="num">{i + 1}</td>
                {isCol ? (
                  <>
                    <td><input className="input" style={{ minWidth: '8em' }} inputMode="decimal" aria-label={`القيمة ${i + 1}`} value={l.amount ?? ''} onChange={(e) => setLine(i, { amount: e.target.value })} /></td>
                    <td><select className="input" aria-label={`الدفع ${i + 1}`} value={l.pay_method ?? ''} onChange={(e) => setLine(i, { pay_method: e.target.value })}>
                      <option value="">—</option>{PAY_METHODS.map((p) => <option key={p}>{p}</option>)}</select></td>
                    <td><input className="input" style={{ minWidth: '7em' }} aria-label={`رقم الشيك ${i + 1}`} value={l.cheque_no ?? ''} onChange={(e) => setLine(i, { cheque_no: e.target.value })} /></td>
                  </>
                ) : INV_FIELDS.map(([f, lbl, w]) => (
                  <td key={f}><input className="input" style={{ minWidth: w }} dir="ltr" aria-label={`${lbl} ${i + 1}`} value={(l[f] as string | null) ?? ''}
                    onChange={(e) => setLine(i, { [f]: e.target.value } as Partial<DocLine>)} /></td>
                ))}
                <td><button className="btn link" onClick={() => removeLine(i)} aria-label={`إزالة البند ${i + 1}`}>إزالة</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="actions" style={{ alignItems: 'center' }}>
        <button className="btn" onClick={addLine}>{isCol ? 'إضافة جزء' : 'إضافة بند'}</button>
        <span className="small muted">الإجمالي المشتق من البنود: <span className="num">{fmtAmount(total)}</span></span>
      </div>
    </div>
  );
}

/** الحقول المتغيرة وأثرها، قبل الحفظ */
export function DocDiff({ kind, before, after }: { kind: Kind; before: DocData; after: DocData }) {
  const isCol = kind === 'collection';
  const head: [string, string | null | undefined, string | null | undefined][] = [
    ['رقم السند', before.doc_number, after.doc_number],
    ['رقم العميل', before.customer_number, after.customer_number],
    ['تاريخ السند', fmtDate(before.doc_date), fmtDate(after.doc_date)],
    [isCol ? 'رقم المندوب' : 'رقم الموظف', before.employee_number, after.employee_number],
    ...(kind === 'invoice' ? [['نوع الفاتورة', before.pay_type, after.pay_type] as [string, string | null | undefined, string | null | undefined]] : []),
  ];
  const changedHead = head.filter(([, a, b]) => (a ?? '') !== (b ?? ''));
  const lineKey = (l: DocLine) => (isCol ? [l.amount, l.pay_method, l.cheque_no] : [l.item_number, l.net_sales, l.net_promotions, l.quantity, l.bonus])
    .map((v) => (v === null || v === undefined || v === '' ? '' : String(Number(v)) === 'NaN' ? String(v) : String(Number(v)))).join('|');
  const locKey = (l: DocLine) => `${l.lat ?? ''}|${l.lng ?? ''}`;
  const linesChanged = before.lines.map(lineKey).sort().join('\n') !== after.lines.map(lineKey).sort().join('\n');
  const locChanged = !isCol && before.lines.map(locKey).join('\n') !== after.lines.map(locKey).join('\n');
  const tot = (d: DocData) => (isCol ? sum(d.lines.map((l) => l.amount ?? null)) : sum(d.lines.flatMap((l) => [l.net_sales ?? null, l.net_promotions ?? null])));

  const impacts: string[] = [];
  if (linesChanged) impacts.push('تتغير المبالغ أو الأصناف: يتغير الأثر المالي والمبيعات والأهداف والعمولات وفق قواعد كل وحدة.');
  if (changedHead.some(([l]) => l.startsWith('رقم الموظف') || l.startsWith('رقم المندوب'))) impacts.push('ينتقل السند وأثره كاملًا إلى الموظف الجديد؛ مجموع الشركة ثابت (TXN-002).');
  if (changedHead.some(([l]) => l === 'رقم السند' || l === 'رقم العميل' || l === 'تاريخ السند')) impacts.push('يتغير مفتاح السند؛ يحفظ المفتاح الأصلي وتظهر إعادة رفع الأصل مطابقة محتملة (B048).');
  if (changedHead.some(([l]) => l === 'تاريخ السند')) impacts.push('تتغير فترة السند في الكشف والأهداف.');
  if (changedHead.some(([l]) => l === 'نوع الفاتورة')) impacts.push('يتغير أثر الفاتورة على الذمم: الذمم تزيد الرصيد والنقدية لا تنشئ دينًا (B028).');
  if (locChanged) impacts.push('تصحيح الموقع يمس الخرائط فقط دون أثر مالي.');

  return (
    <div style={{ display: 'grid', gap: 10 }}>
      {changedHead.length > 0 && (
        <div className="tbl"><table><thead><tr><th>الحقل</th><th>قبل</th><th>بعد</th></tr></thead>
          <tbody>{changedHead.map(([l, a, b]) => <tr key={l}><td>{l}</td><td className="num diff-old">{a || '—'}</td><td className="num diff-new">{b || '—'}</td></tr>)}</tbody></table></div>
      )}
      <div className="grid2">
        {([['قبل', before], ['بعد', after]] as [string, DocData][]).map(([t, d]) => (
          <div key={t}>
            <h3>{t} — <span className="num">{d.lines.length}</span> {isCol ? 'جزء' : 'بند'}، الإجمالي <span className="num">{fmtAmount(tot(d))}</span></h3>
            <div className="tbl" style={{ marginTop: 6 }}><table>
              <thead><tr>{isCol ? <><th>القيمة</th><th>الدفع</th><th>الشيك</th></> : <><th>الصنف</th><th>المباشر</th><th>العروض</th><th>الكمية</th><th>البونص</th></>}</tr></thead>
              <tbody>{d.lines.map((l, i) => (
                <tr key={i}>{isCol ? <><td className="num">{fmtAmount(l.amount)}</td><td>{l.pay_method}</td><td>{l.cheque_no}</td></> : (
                  <Fragment><td>{l.item_number}</td><td className="num">{fmtAmount(l.net_sales)}</td><td className="num">{fmtAmount(l.net_promotions)}</td>
                    <td className="num">{fmtQty(l.quantity)}</td><td className="num">{fmtQty(l.bonus)}</td></Fragment>
                )}</tr>
              ))}</tbody></table></div>
          </div>
        ))}
      </div>
      {impacts.length ? <ul className="small" style={{ margin: 0 }}>{impacts.map((x) => <li key={x}>{x}</li>)}</ul>
        : <p className="small muted">لا تغيير في الحقول المؤثرة.</p>}
    </div>
  );
}
