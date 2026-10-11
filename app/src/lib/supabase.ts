// الاتصال بـSupabase: من متغيرات البيئة أولًا، وإلا من شاشة الاتصال (تحفظ في المتصفح).
// المفتاح المستخدم هو المفتاح العام anon فقط؛ لا يوضع مفتاح الخدمة في التطبيق إطلاقًا.
import { createClient, SupabaseClient } from '@supabase/supabase-js';

const LS_KEY = 'master.connection';

export interface Connection { url: string; anonKey: string }

export function getConnection(): Connection | null {
  const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
  if (url && anonKey) return { url, anonKey };
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) {
      const c = JSON.parse(raw) as Connection;
      if (c.url && c.anonKey) return c;
    }
  } catch { /* التخزين غير متاح */ }
  return null;
}

export function connectionFromEnv(): boolean {
  return !!(import.meta.env.VITE_SUPABASE_URL && import.meta.env.VITE_SUPABASE_ANON_KEY);
}

export function saveConnection(c: Connection) {
  try { localStorage.setItem(LS_KEY, JSON.stringify(c)); } catch { /* التخزين غير متاح */ }
}

export function clearConnection() {
  try { localStorage.removeItem(LS_KEY); } catch { /* التخزين غير متاح */ }
}

let client: SupabaseClient | null = null;

export function sb(): SupabaseClient {
  if (!client) {
    const c = getConnection();
    if (!c) throw new Error('لم يُضبط الاتصال بقاعدة البيانات');
    client = createClient(c.url, c.anonKey, { auth: { persistSession: true, autoRefreshToken: true } });
  }
  return client;
}

export function resetClient() { client = null; }

/** اسم المستخدم يتحول إلى بريد داخلي، كما في قاعدة البيانات (app.username_email) */
export function usernameEmail(username: string): string {
  return `${username.trim().toLowerCase()}@master.local`;
}

/** خطأ من قاعدة البيانات برسالة عربية مقروءة */
export class DbError extends Error {
  code?: string;
  constructor(message: string, code?: string) { super(message); this.code = code; }
}

export function asDbError(e: unknown): DbError {
  const anyE = e as { message?: string; details?: string; code?: string; hint?: string };
  const msg = anyE?.message || 'حدث خطأ غير متوقع';
  if (/Failed to fetch|NetworkError/i.test(msg)) return new DbError('تعذر الاتصال بالخادم؛ تحقق من الشبكة وأعد المحاولة', 'network');
  if (/permission denied/i.test(msg)) return new DbError('لا تملك صلاحية هذا الإجراء', 'forbidden');
  return new DbError(msg, anyE?.details || anyE?.code);
}

/** استدعاء دالة في قاعدة البيانات مع تحويل الخطأ */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await sb().rpc(fn, args);
  if (error) throw asDbError(error);
  return data as T;
}
