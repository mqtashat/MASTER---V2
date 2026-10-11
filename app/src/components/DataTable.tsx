// جدول موحد (P-3): 50 أو 100 صف، الفرز والبحث والتصفية على الخادم، عدد النتائج،
// والضغط على الصف يفتح التفاصيل. فشل الطلب يعرض خطأ وإعادة محاولة لا أصفارًا (U04).
import { ReactNode, useEffect, useRef, useState } from 'react';

export interface Column<T> {
  key: string;
  label: string;
  render?: (row: T) => ReactNode;
  sortable?: boolean;
  num?: boolean;
}

export interface Query { page: number; pageSize: number; sort: string | null; asc: boolean }
export interface Result<T> { rows: T[]; count: number }

export function DataTable<T extends Record<string, unknown>>({ columns, fetcher, deps, onRowClick, rowKey, initialSort }: {
  columns: Column<T>[];
  fetcher: (q: Query) => Promise<Result<T>>;
  deps: unknown[];
  onRowClick?: (row: T) => void;
  rowKey: (row: T) => string | number;
  initialSort?: string;
}) {
  const [q, setQ] = useState<Query>({ page: 0, pageSize: 50, sort: initialSort ?? null, asc: true });
  const [res, setRes] = useState<Result<T> | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0);
  const depKey = JSON.stringify(deps);

  // تغيّر الفلاتر يعيد إلى الصفحة الأولى
  useEffect(() => { setQ((o) => ({ ...o, page: 0 })); }, [depKey]);

  const load = () => {
    const my = ++seq.current;
    setLoading(true); setError(null);
    fetcher(q).then((r) => { if (my === seq.current) setRes(r); })
      .catch((e) => { if (my === seq.current) { setError((e as Error).message); setRes(null); } })
      .finally(() => { if (my === seq.current) setLoading(false); });
  };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(load, [q, depKey]);

  const pages = res ? Math.max(1, Math.ceil(res.count / q.pageSize)) : 1;
  const from = res && res.count ? q.page * q.pageSize + 1 : 0;
  const to = res ? Math.min(res.count, (q.page + 1) * q.pageSize) : 0;

  return (
    <div className="tbl">
      <table>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} className={c.sortable ? 'sortable' : ''} aria-sort={q.sort === c.key ? (q.asc ? 'ascending' : 'descending') : undefined}
                onClick={() => c.sortable && setQ((o) => ({ ...o, sort: c.key, asc: o.sort === c.key ? !o.asc : true, page: 0 }))}>
                {c.label}{q.sort === c.key ? (q.asc ? ' ▲' : ' ▼') : ''}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {error ? (
            <tr><td colSpan={columns.length} className="empty">
              <div>تعذر تحميل البيانات: {error}</div>
              <button className="btn" style={{ marginTop: 8 }} onClick={load}>إعادة المحاولة</button>
            </td></tr>
          ) : loading && !res ? (
            Array.from({ length: 5 }).map((_, i) => (
              <tr key={i}>{columns.map((c) => <td key={c.key}><div className="skeleton" /></td>)}</tr>
            ))
          ) : res && res.rows.length === 0 ? (
            <tr><td colSpan={columns.length} className="empty">لا توجد نتائج ضمن الفلاتر</td></tr>
          ) : (
            res?.rows.map((r) => (
              <tr key={rowKey(r)} className={onRowClick ? 'clickable' : ''} onClick={() => onRowClick?.(r)}
                tabIndex={onRowClick ? 0 : undefined} onKeyDown={(e) => e.key === 'Enter' && onRowClick?.(r)}
                style={loading ? { opacity: 0.5 } : undefined}>
                {columns.map((c) => (
                  <td key={c.key} className={c.num ? 'num' : ''}>{c.render ? c.render(r) : (r[c.key] as ReactNode) ?? ''}</td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
      <div className="pager">
        <span>{res ? <>عرض <span className="num">{from}</span> إلى <span className="num">{to}</span> من <span className="num">{res.count}</span></> : '…'}</span>
        <span className="actions">
          <select className="input" style={{ width: 'auto' }} value={q.pageSize} aria-label="عدد الصفوف"
            onChange={(e) => setQ((o) => ({ ...o, pageSize: Number(e.target.value), page: 0 }))}>
            <option value={50}>50 صفًا</option>
            <option value={100}>100 صف</option>
          </select>
          <button className="btn" disabled={q.page === 0} onClick={() => setQ((o) => ({ ...o, page: o.page - 1 }))}>السابق</button>
          <span>صفحة <span className="num">{q.page + 1}</span> من <span className="num">{pages}</span></span>
          <button className="btn" disabled={q.page + 1 >= pages} onClick={() => setQ((o) => ({ ...o, page: o.page + 1 }))}>التالي</button>
        </span>
      </div>
    </div>
  );
}
