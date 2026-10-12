// P01 — الرئيسية: ملخص ما هو متاح حاليًا ضمن صلاحية المستخدم.
// مؤشرات المبيعات والذمم والإنجاز تُضاف مع وحدات الحركات والحسابات والأهداف.
import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { sb } from '../lib/supabase';
import { useAuth } from '../lib/auth';

export function Home() {
  const { profile, can } = useAuth();
  const [counts, setCounts] = useState<Record<string, number | null>>({});
  useEffect(() => {
    const tables: [string, string][] = [];
    if (can('P02')) tables.push(['customers', 'العملاء']);
    if (can('P03')) tables.push(['employees', 'الموظفون']);
    if (can('P04')) tables.push(['products', 'الأصناف']);
    Promise.all(tables.map(async ([t]) => {
      const { count } = await sb().from(t).select('id', { count: 'exact', head: true });
      return [t, count ?? null] as const;
    })).then((r) => setCounts(Object.fromEntries(r)));
  }, [can]);
  return (
    <>
      <div className="page-head"><h1>الرئيسية</h1><span className="meta">مرحبًا {profile?.display_name}</span></div>
      <div className="stats">
        {can('P02') && <Link to="/customers" className="stat" style={{ textDecoration: 'none', color: 'inherit' }}><div className="l">العملاء</div><div className="v num">{counts.customers ?? '…'}</div></Link>}
        {can('P03') && <Link to="/employees" className="stat" style={{ textDecoration: 'none', color: 'inherit' }}><div className="l">الموظفون</div><div className="v num">{counts.employees ?? '…'}</div></Link>}
        {can('P04') && <Link to="/products" className="stat" style={{ textDecoration: 'none', color: 'inherit' }}><div className="l">الأصناف</div><div className="v num">{counts.products ?? '…'}</div></Link>}
      </div>
      <div className="panel small muted">مؤشرات المبيعات والتحصيل والذمم والإنجاز تظهر هنا بعد بناء وحدات الحركات والحسابات والأهداف.</div>
    </>
  );
}
