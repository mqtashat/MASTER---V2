// الهيكل العام: شاشة الاتصال ← التهيئة الأولى ← الدخول ← التطبيق بقائمة الوحدات المسموحة.
import { useEffect, useState } from 'react';
import { HashRouter, Link, NavLink, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { AuthProvider, useAuth } from './lib/auth';
import { getConnection } from './lib/supabase';
import { PAGES, MODULES } from './lib/pages';
import { CodeProvider, Loading } from './components/ui';
import { ConnectionScreen, LoginScreen, BootstrapScreen, ChangePassword } from './pages/Auth';
import { Home } from './pages/Home';
import { Customers } from './pages/Customers';
import { Employees } from './pages/Employees';
import { Products } from './pages/Products';
import { Users } from './pages/Users';
import { Settings } from './pages/Settings';
import { Upload } from './pages/Upload';
import { Transactions } from './pages/Transactions';
import { Statement } from './pages/Statement';
import { Receivables } from './pages/Receivables';
import { Openings } from './pages/Openings';
import { Notes } from './pages/Notes';
import { RepGoals, SupervisorGoals } from './pages/Goals';
import { CommissionRules } from './pages/CommissionRules';
import { Rewards } from './pages/Rewards';
import { Cards } from './pages/Cards';
import { Commissions } from './pages/Commissions';
import { Months } from './pages/Months';
import { Calendar } from './pages/Calendar';
import { InvoiceMap } from './pages/InvoiceMap';
import { Locations } from './pages/Locations';
import { Regions } from './pages/Regions';
import { Compare } from './pages/Compare';
import { Spread } from './pages/Spread';
import { Reports } from './pages/Reports';
import { rpc } from './lib/supabase';

export function App() {
  const [connected, setConnected] = useState(!!getConnection());
  if (!connected) return <ConnectionScreen onDone={() => setConnected(true)} />;
  return (
    <AuthProvider>
      <CodeProvider>
        <HashRouter>
          <Gate />
        </HashRouter>
      </CodeProvider>
    </AuthProvider>
  );
}

function Gate() {
  const { loading, profile } = useAuth();
  const [initialized, setInitialized] = useState<boolean | null>(null);
  useEffect(() => {
    rpc<boolean>('system_initialized').then(setInitialized).catch(() => setInitialized(true));
  }, []);
  if (loading || initialized === null) return <div className="wrap" style={{ paddingTop: 40 }}><Loading /></div>;
  if (!initialized) return <BootstrapScreen onDone={() => setInitialized(true)} />;
  if (!profile) return <LoginScreen />;
  return <Shell />;
}

const COMPONENTS: Record<string, () => JSX.Element> = {
  P01: Home, P02: Customers, P03: Employees, P04: Products, P05: Upload, P06: Transactions,
  P07: Statement, P08: Receivables, P08a: Openings, P09: Notes,
  P10: RepGoals, P10a: SupervisorGoals, P11: CommissionRules, P12: Rewards, P13: Cards, P14: Commissions, P14b: Months,
  P15: InvoiceMap, P16: Locations, P17: Regions, P17a: Compare, P17b: Spread, P18: Reports,
  P19: Calendar, P20: Users, P21: Settings,
};

function Shell() {
  const { profile, can, signOut } = useAuth();
  const [menu, setMenu] = useState(false);
  const [pw, setPw] = useState(false);
  const loc = useLocation();
  useEffect(() => { setMenu(false); }, [loc.pathname]);

  const allowed = PAGES.filter((p) => can(p.code));
  // نقطة البداية: أول صفحة مسموحة إن لم تكن الرئيسية مسموحة (P-1)
  const start = can('P01') ? '/' : allowed[0]?.path ?? '/none';

  // شريط جانبي ثابت بكل الوحدات وصفحاتها المسموحة (UX-008)؛ على الهاتف درج يفتح بزر القائمة
  return (
    <div className={'app' + (menu ? ' menu-open' : '')}>
      <div className="mobile-bar no-print">
        <button className="btn" aria-expanded={menu} aria-controls="side-nav" onClick={() => setMenu(!menu)}>القائمة</button>
        <Link to={start} className="brand">ماستر</Link>
      </div>
      {menu && <div className="scrim no-print" onClick={() => setMenu(false)} />}
      <aside id="side-nav" className="sidebar no-print" onClick={(e) => { if ((e.target as HTMLElement).closest('a')) setMenu(false); }}>
        <div className="side-head"><Link to={start} className="brand">ماستر</Link></div>
        <nav className="side-scroll" aria-label="القائمة الرئيسية">
          {can('P01') && <NavLink className="side-link" to="/" end>الرئيسية</NavLink>}
          {MODULES.map((m) => {
            const items = allowed.filter((p) => p.module === m);
            if (!items.length) return null;
            const active = items.some((p) => p.path === loc.pathname);
            return (
              <div key={m} className={'side-group' + (active ? ' active' : '')}>
                <div className="side-title">{m}</div>
                <ul>{items.map((p) => (
                  <li key={p.code}><NavLink className="side-link" to={p.path}>{p.name}{!p.ready && <span className="muted small"> — قيد البناء</span>}</NavLink></li>
                ))}</ul>
              </div>
            );
          })}
        </nav>
        <div className="side-foot user-chip">
          <span>{profile!.display_name}</span>
          <button className="btn link" onClick={() => setPw(true)}>كلمة المرور</button>
          <button className="btn link" onClick={signOut}>خروج</button>
        </div>
      </aside>
      <main className="wrap">
        <Routes>
          {allowed.map((p) => {
            const C = COMPONENTS[p.code];
            return <Route key={p.code} path={p.path} element={C ? <C /> : <NotReady name={p.name} />} />;
          })}
          <Route path="/none" element={<div className="panel">لا توجد صفحات مسموحة لهذا الحساب. تواصل مع الإدارة.</div>} />
          <Route path="*" element={<Navigate to={start} replace />} />
        </Routes>
      </main>
      {pw && <ChangePassword onClose={() => setPw(false)} />}
    </div>
  );
}

function NotReady({ name }: { name: string }) {
  return (
    <div className="panel">
      <h1>{name}</h1>
      <p className="muted">هذه الصفحة ضمن وحدات البناء التالية، وتُضاف في تحديث قادم.</p>
    </div>
  );
}
