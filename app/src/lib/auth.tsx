// الجلسة وملف المستخدم وصلاحياته (AUTH-001..003). الواجهة تخفي غير المسموح،
// والخادم يمنعه في كل الأحوال (RLS ودوال محمية).
import { createContext, useCallback, useContext, useEffect, useState, ReactNode } from 'react';
import { sb, rpc, usernameEmail, asDbError } from './supabase';

export interface Profile {
  id: string;
  username: string;
  display_name: string;
  is_admin: boolean;
  data_scope: 'all' | 'team' | 'selected' | 'self';
  employee_id: number | null;
  employee_name: string | null;
  permissions: Record<string, string[]>;
  admin_secret_set: boolean;
}

interface AuthState {
  loading: boolean;
  profile: Profile | null;
  signIn: (username: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  reload: () => Promise<void>;
  can: (page: string, action?: string) => boolean;
}

const Ctx = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<Profile | null>(null);

  const reload = useCallback(async () => {
    const { data } = await sb().auth.getSession();
    if (!data.session) { setProfile(null); return; }
    try {
      const p = await rpc<Profile | null>('my_profile');
      if (!p) { await sb().auth.signOut(); setProfile(null); return; }
      setProfile(p);
    } catch {
      setProfile(null);
    }
  }, []);

  useEffect(() => {
    reload().finally(() => setLoading(false));
    const { data } = sb().auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') setProfile(null);
    });
    return () => data.subscription.unsubscribe();
  }, [reload]);

  const signIn = async (username: string, password: string) => {
    const { error } = await sb().auth.signInWithPassword({ email: usernameEmail(username), password });
    if (error) {
      if (/invalid login credentials/i.test(error.message)) throw new Error('اسم المستخدم أو كلمة المرور غير صحيحة');
      if (/banned/i.test(error.message)) throw new Error('هذا الحساب معطّل');
      throw asDbError(error);
    }
    const p = await rpc<Profile | null>('my_profile');
    if (!p) { await sb().auth.signOut(); throw new Error('هذا الحساب معطّل أو غير مفعّل'); }
    setProfile(p);
  };

  const signOut = async () => { await sb().auth.signOut(); setProfile(null); };

  const can = useCallback((page: string, action = 'view') => {
    if (!profile) return false;
    if (profile.is_admin) return true;
    return (profile.permissions[page] || []).includes(action);
  }, [profile]);

  return <Ctx.Provider value={{ loading, profile, signIn, signOut, reload, can }}>{children}</Ctx.Provider>;
}

export function useAuth(): AuthState {
  const v = useContext(Ctx);
  if (!v) throw new Error('AuthProvider مفقود');
  return v;
}
