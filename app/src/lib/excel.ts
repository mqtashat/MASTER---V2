// قراءة ملفات Excel (xls وxlsx) وكتابتها. القوالب تُقرأ بأسماء أعمدتها المتفق عليها
// مباشرة دون Mapping يدوي (DATA-009)، والمعرّفات نصوص بأصفارها البادئة.
import * as XLSX from 'xlsx';
import { parseDateInput } from './format';

export interface Sheet {
  headers: string[];
  rows: { row: number; cells: Record<string, string> }[];
  sheetName: string;
}

/** تحويل خلية إلى نص دون فقد دقة أو أصفار بادئة */
function cellText(c: XLSX.CellObject | undefined): string {
  if (!c || c.v === undefined || c.v === null) return '';
  if (c.t === 'n') {
    // تاريخ مخزن رقمًا في Excel
    if (c.z && /[dmy]/i.test(String(c.z)) && !/0\.0/.test(String(c.z))) {
      const d = XLSX.SSF.parse_date_code(c.v as number);
      if (d) return `${d.y}-${String(d.m).padStart(2, '0')}-${String(d.d).padStart(2, '0')}`;
    }
    const n = c.v as number;
    return Number.isInteger(n) ? String(n) : String(n);
  }
  if (c.t === 'd' && c.v instanceof Date) {
    const d = c.v;
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }
  return String(c.v).trim();
}

export async function readSheet(file: File): Promise<Sheet> {
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(buf, { type: 'array', cellDates: false, cellNF: true, raw: false });
  const sheetName = wb.SheetNames[0];
  const ws = wb.Sheets[sheetName];
  if (!ws || !ws['!ref']) return { headers: [], rows: [], sheetName };
  const range = XLSX.utils.decode_range(ws['!ref']);
  const headers: string[] = [];
  for (let c = range.s.c; c <= range.e.c; c++) {
    headers.push(cellText(ws[XLSX.utils.encode_cell({ r: range.s.r, c })]));
  }
  const rows: Sheet['rows'] = [];
  for (let r = range.s.r + 1; r <= range.e.r; r++) {
    const cells: Record<string, string> = {};
    let any = false;
    for (let c = range.s.c; c <= range.e.c; c++) {
      const h = headers[c - range.s.c];
      if (!h) continue;
      const v = cellText(ws[XLSX.utils.encode_cell({ r, c })]);
      if (v !== '') any = true;
      cells[h] = v;
    }
    if (any) rows.push({ row: r + 1, cells });   // رقم الصف كما يظهر في Excel
  }
  return { headers, rows, sheetName };
}

/** الأعمدة المطلوبة الغائبة عن الملف */
export function missingHeaders(sheet: Sheet, required: string[]): string[] {
  const have = new Set(sheet.headers.map((h) => h.trim()));
  return required.filter((h) => !have.has(h));
}

/** قراءة تاريخ من خلية مصدر: يعيد YYYY-MM-DD، أو النص الأصلي إن لم يُقرأ ليظهر خطأً في المعاينة */
export function dateCell(v: string): string {
  if (!v) return '';
  return parseDateInput(v) ?? v;
}

export function writeSheet(fileName: string, sheetName: string, headers: string[], rows: (string | number | null)[][]) {
  const ws = XLSX.utils.aoa_to_sheet([headers, ...rows.map((r) => r.map((v) => (v === null ? '' : v)))]);
  ws['!cols'] = headers.map((h) => ({ wch: Math.max(12, h.length + 4) }));
  const wb = XLSX.utils.book_new();
  wb.Workbook = { Views: [{ RTL: true }] };
  XLSX.utils.book_append_sheet(wb, ws, sheetName.slice(0, 31));
  XLSX.writeFile(wb, fileName);
}
