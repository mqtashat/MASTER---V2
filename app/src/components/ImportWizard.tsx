// معالج استيراد التعريفات من صفحاتها (CUS-001، EMP-001، PRD-005):
// اختيار الملف ← فحص الأعمدة ← معاينة الجديد والمتغير والمطابق والأخطاء ← قرارات (تواريخ السريان) ← اعتماد.
import { ReactNode, useState } from 'react';
import { Modal, Msg, useAction, useGuarded } from './ui';
import { readSheet, missingHeaders, Sheet } from '../lib/excel';

export interface PlanError { row: number; field: string; value: string | null; message: string }

export interface ImportSpec<R, P extends { errors: PlanError[] }, D> {
  title: string;
  requiredHeaders: string[];
  mapRow: (cells: Record<string, string>, row: number) => R;
  preview: (rows: R[], decisions: D) => Promise<P>;
  commit: (rows: R[], decisions: D, fileName: string, code: string | null) => Promise<unknown>;
  initialDecisions: D;
  renderPlan: (plan: P, decisions: D, setDecisions: (d: D) => void) => ReactNode;
  canCommit?: (plan: P, decisions: D) => string | null;   // سبب المنع إن وجد
  /** إعادة المعاينة عند تغير القرارات (مثل تواريخ السريان في المنتجات) */
  repreviewOnDecision?: boolean;
}

export function ImportWizard<R, P extends { errors: PlanError[] }, D>({ spec, onClose, onDone }: {
  spec: ImportSpec<R, P, D>; onClose: () => void; onDone: () => void;
}) {
  const [file, setFile] = useState<File | null>(null);
  const [sheet, setSheet] = useState<Sheet | null>(null);
  const [rows, setRows] = useState<R[]>([]);
  const [plan, setPlan] = useState<P | null>(null);
  const [decisions, setDecisions] = useState<D>(spec.initialDecisions);
  const [done, setDone] = useState<unknown>(null);
  const { busy, error, setError, run } = useAction();
  const guarded = useGuarded();

  const pick = (f: File | null) => run(async () => {
    setFile(f); setPlan(null); setSheet(null); setDone(null);
    if (!f) return;
    const s = await readSheet(f);
    const miss = missingHeaders(s, spec.requiredHeaders);
    if (miss.length) throw new Error('أعمدة مطلوبة غير موجودة في الملف: ' + miss.join('، '));
    if (!s.rows.length) throw new Error('الملف لا يحتوي صفوف بيانات');
    const mapped = s.rows.map((r) => spec.mapRow(r.cells, r.row));
    setSheet(s); setRows(mapped);
    setPlan(await spec.preview(mapped, decisions));
  });

  const updateDecisions = (d: D) => {
    setDecisions(d);
    if (spec.repreviewOnDecision && rows.length) run(async () => setPlan(await spec.preview(rows, d)));
  };

  const commit = () => run(async () => {
    const r = await guarded((code) => spec.commit(rows, decisions, file?.name ?? '', code));
    setDone(r ?? true);
    onDone();
  });

  const blocked = plan ? (plan.errors.length ? 'في الملف أخطاء تمنع الاعتماد؛ صحّحها في الملف ثم أعد اختياره' : spec.canCommit?.(plan, decisions) ?? null) : null;

  return (
    <Modal title={spec.title} onClose={onClose} wide
      footer={done ? <button className="btn primary" onClick={onClose}>تم</button> : (
        <>
          <button className="btn primary" disabled={!plan || !!blocked || busy} onClick={commit}>{busy ? 'جارٍ التنفيذ…' : 'اعتماد'}</button>
          <button className="btn" onClick={onClose}>إلغاء</button>
          {blocked && <span className="small muted">{blocked}</span>}
        </>
      )}>
      {!done && (
        <label className="field">
          <span>ملف Excel</span>
          <input type="file" accept=".xls,.xlsx" onChange={(e) => { setError(null); pick(e.target.files?.[0] ?? null); }} />
          <small>الأعمدة المطلوبة: {spec.requiredHeaders.join('، ')}</small>
        </label>
      )}
      {error && <Msg kind="bad">{error}</Msg>}
      {busy && !plan && <div className="muted">جارٍ القراءة والفحص…</div>}
      {done ? (
        <Msg kind="ok">اعتُمد الاستيراد وحُفظ في سجل العمليات.</Msg>
      ) : plan && sheet ? (
        <>
          <div className="small muted">الملف: {file?.name} — الورقة: {sheet.sheetName} — الصفوف: <span className="num">{rows.length}</span></div>
          {plan.errors.length > 0 && (
            <div className="panel">
              <h3 style={{ color: 'var(--bad)' }}>أخطاء تمنع الاعتماد ({plan.errors.length})</h3>
              <div className="tbl" style={{ marginTop: 8 }}>
                <table><thead><tr><th>الصف</th><th>العمود</th><th>القيمة</th><th>المشكلة وطريقة التصحيح</th></tr></thead>
                  <tbody>{plan.errors.map((e, i) => (
                    <tr key={i}><td className="num">{e.row}</td><td>{e.field}</td><td>{e.value ?? '—'}</td><td className="wrap">{e.message}</td></tr>
                  ))}</tbody></table>
              </div>
            </div>
          )}
          {spec.renderPlan(plan, decisions, updateDecisions)}
        </>
      ) : null}
    </Modal>
  );
}

/** جدول تغييرات حقلية: السابق والجديد */
export function ChangesTable({ items, keyLabel, keyField, labels }: {
  items: { row: number; fields: Record<string, [unknown, unknown]>; [k: string]: unknown }[];
  keyLabel: string; keyField: string; labels: Record<string, string>;
}) {
  if (!items.length) return null;
  return (
    <div className="tbl"><table>
      <thead><tr><th>الصف</th><th>{keyLabel}</th><th>الحقل</th><th>السابق</th><th>الجديد</th></tr></thead>
      <tbody>{items.flatMap((it) => Object.entries(it.fields).map(([f, [a, b]], i) => (
        <tr key={String(it[keyField]) + f}>
          <td className="num">{i === 0 ? it.row : ''}</td><td>{i === 0 ? String(it[keyField]) : ''}</td>
          <td>{labels[f] ?? f}</td><td className="num">{a === null || a === undefined ? '—' : String(a)}</td>
          <td className="num">{b === null || b === undefined ? '—' : String(b)}</td>
        </tr>
      )))}</tbody>
    </table></div>
  );
}

export function Counts({ items }: { items: [string, number | undefined, ('ok' | 'warn' | 'bad')?][] }) {
  return (
    <div className="stats">
      {items.map(([l, v, k]) => (
        <div className="stat" key={l}><div className="l">{l}</div>
          <div className="v num" style={k ? { color: `var(--${k === 'ok' ? 'ok' : k === 'warn' ? 'warn' : 'bad'})` } : undefined}>{v ?? 0}</div></div>
      ))}
    </div>
  );
}
