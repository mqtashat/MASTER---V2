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
  P19: Calendar, P20: Users, P21: Settings,
};

function Shell() {
  const { profile, can, signOut } = useAuth();
  const [open, setOpen] = useState<string | null>(null);
  const [burger, setBurger] = useState(false);
  const [pw, setPw] = useState(false);
  const loc = useLocation();
  useEffect(() => { setOpen(null); setBurger(false); }, [loc.pathname]);

  const allowed = PAGES.filter((p) => can(p.code));
  // نقطة البداية: أول صفحة مسموحة إن لم تكن الرئيسية مسموحة (P-1)
  const start = can('P01') ? '/' : allowed[0]?.path ?? '/none';

  return (
    <>
      <header className="top">
        <div className="wrap">
          <Link to={start} className="brand">ماستر</Link>
          <button className="btn burger" aria-expanded={burger} onClick={() => setBurger(!burger)}>القائمة</button>
          <nav className={'modules' + (burger ? ' open' : '')} aria-label="القائمة الرئيسية">
            {can('P01') && <div className={'menu' + (loc.pathname === '/' ? ' active' : '')}><NavLink to="/" end>الرئيسية</NavLink></div>}
            {MODULES.map((m) => {
              const items = allowed.filter((p) => p.module === m);
              if (!items.length) return null;
              const active = items.some((p) => p.path === loc.pathname);
              return (
                <div key={m} className={'menu' + (active ? ' active' : '')}>
                  <button aria-expanded={open === m} onClick={() => setOpen(open === m ? null : m)}>{m}</button>
                  {open === m && (
                    <ul>{items.map((p) => (
                      <li key={p.code}><NavLink to={p.path}>{p.name}{!p.ready && <span className="muted small"> — قيد البناء</span>}</NavLink></li>
                    ))}</ul>
                  )}
                </div>
              );
            })}
          </nav>
          <span className="spacer" />
          <span className="user-chip">
            <span>{profile!.display_name}</span>
            <button className="btn link" onClick={() => setPw(true)}>كلمة المرور</button>
            <button className="btn link" onClick={signOut}>خروج</button>
          </span>
        </div>
      </header>
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
    </>
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
