// أدوات استعلام مشتركة: الجلب الكامل على دفعات للتصدير (B045: تصدير كامل النطاق).
import { asDbError } from './supabase';

type Builder = { range: (a: number, b: number) => PromiseLike<{ data: unknown[] | null; error: unknown }> };

export async function fetchAll<T>(make: () => Builder, batch = 1000): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += batch) {
    const { data, error } = await make().range(from, from + batch - 1);
    if (error) throw asDbError(error);
    out.push(...((data ?? []) as T[]));
    if (!data || data.length < batch) break;
  }
  return out;
}

/** تنظيف نص البحث من محارف PostgREST الخاصة */
export function cleanTerm(s: string): string {
  return s.trim().replace(/[%,()*\\]/g, ' ').replace(/\s+/g, ' ');
}
