// تنسيق العرض الموحد:
// DATE-001: التاريخ D/M/YYYY والشهر M/YYYY.
// NUM-001 وB060–B062: المبالغ ثلاث منازل، والنسب حتى منزلتين دون أصفار زائدة،
// والكميات بكسورها في التفاصيل والتصدير وعددًا صحيحًا في البطاقات المختصرة فقط (QTY-004).
// الحساب يتم على النص العشري بدقة كاملة (BigInt) لتفادي أخطاء الفاصلة العائمة.
// سياسة تعادل النصف التقنية الموحدة: التقريب بعيدًا عن الصفر.

export type Num = string | number | null | undefined;

/** تحويل عدد عشري نصي إلى [قيمة صحيحة مكبرة، عدد المنازل] */
function parse(v: Num): [bigint, number] | null {
  if (v === null || v === undefined || v === '') return null;
  const s = typeof v === 'number' ? numberToPlain(v) : String(v).trim();
  const m = /^([+-]?)(\d*)(?:\.(\d*))?$/.exec(s);
  if (!m || (m[2] === '' && (m[3] ?? '') === '')) return null;
  const frac = m[3] ?? '';
  const int = BigInt((m[2] || '0') + frac);
  return [m[1] === '-' ? -int : int, frac.length];
}

function numberToPlain(n: number): string {
  if (!Number.isFinite(n)) return '';
  const s = String(n);
  if (!/e/i.test(s)) return s;
  return n.toFixed(20).replace(/\.?0+$/, '');
}

/** تقريب إلى عدد منازل محدد، يعيد نصًا بهذه المنازل بالضبط */
export function roundTo(v: Num, places: number): string | null {
  const p = parse(v);
  if (!p) return null;
  const [int, scale] = p;
  let out: bigint;
  if (scale <= places) {
    out = int * 10n ** BigInt(places - scale);
  } else {
    const div = 10n ** BigInt(scale - places);
    const q = int / div;
    const r = int % div;
    const twice = (r < 0n ? -r : r) * 2n;
    out = twice >= div ? q + (int < 0n ? -1n : 1n) : q;
  }
  const neg = out < 0n;
  const abs = (neg ? -out : out).toString().padStart(places + 1, '0');
  const head = abs.slice(0, abs.length - places);
  const tail = places > 0 ? '.' + abs.slice(abs.length - places) : '';
  const res = head + tail;
  return neg && /[1-9]/.test(res) ? '-' + res : res;
}

/** جمع قيم عشرية بدقتها الأصلية (الإجمالي من الأصل ثم التقريب: B061) */
export function sum(values: Num[]): string {
  let total = 0n;
  let scale = 0;
  const parsed = values.map(parse).filter((x): x is [bigint, number] => !!x);
  for (const [, s] of parsed) scale = Math.max(scale, s);
  for (const [i, s] of parsed) total += i * 10n ** BigInt(scale - s);
  const neg = total < 0n;
  const abs = (neg ? -total : total).toString().padStart(scale + 1, '0');
  const res = scale ? abs.slice(0, abs.length - scale) + '.' + abs.slice(abs.length - scale) : abs;
  return (neg ? '-' : '') + res;
}

function trimZeros(s: string): string {
  return s.includes('.') ? s.replace(/\.?0+$/, '') : s;
}

/** مبلغ: ثلاث منازل دائمًا */
export function fmtAmount(v: Num): string {
  return roundTo(v, 3) ?? '';
}

/** نسبة: حتى منزلتين دون أصفار زائدة */
export function fmtPct(v: Num): string {
  const r = roundTo(v, 2);
  return r === null ? '' : trimZeros(r);
}

/** كمية في التفاصيل والتصدير: كما وردت بكسورها دون أصفار زائدة (QTY-004) */
export function fmtQty(v: Num): string {
  const p = parse(v);
  if (!p) return '';
  return trimZeros(roundTo(v, Math.max(p[1], 0)) ?? '');
}

/** كمية أو رقم متابعة في البطاقات المختصرة: عدد صحيح بلا فواصل */
export function fmtInt(v: Num): string {
  return roundTo(v, 0) ?? '';
}

/** تاريخ يوم: D/M/YYYY */
export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso);
  if (!m) return '';
  return `${Number(m[3])}/${Number(m[2])}/${m[1]}`;
}

/** شهر: M/YYYY */
export function fmtMonth(iso: string | null | undefined): string {
  if (!iso) return '';
  const m = /^(\d{4})-(\d{2})/.exec(iso);
  return m ? `${Number(m[2])}/${m[1]}` : '';
}

/** وقت وتاريخ لسجل العمليات بتوقيت الأردن */
export function fmtDateTime(ts: string | null | undefined): string {
  if (!ts) return '';
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return '';
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Amman', year: 'numeric', month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(d);
  const g = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${Number(g('day'))}/${Number(g('month'))}/${g('year')} ${g('hour')}:${g('minute')}`;
}

/** تحويل D/M/YYYY أو DD/MM/YYYY أو YYYY-MM-DD إلى YYYY-MM-DD؛ يعيد null إن لم يُقرأ */
export function parseDateInput(s: string | null | undefined): string | null {
  if (!s) return null;
  const t = String(s).trim();
  let m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(t);
  if (m) return valid(+m[1], +m[2], +m[3]);
  m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(t);
  if (m) return valid(+m[3], +m[2], +m[1]);
  return null;
}

function valid(y: number, mo: number, d: number): string | null {
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

/** تاريخ اليوم بتوقيت الأردن YYYY-MM-DD */
export function todayIso(): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Amman', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return parts;
}
