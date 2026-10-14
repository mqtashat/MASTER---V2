// مولّد بيانات اصطناعية حتمية (بذرة ثابتة) بتوزيع يشبه العينة الحقيقية لشهر 1/2026
// (INV-013): نحو 2.6 صف للفاتورة، و98% نقدي، وربع الصفوف عروض، و6% بونص فقط، وكسور قليلة،
// ومرتجعات قليلة، وتحصيلات لفواتير الذمم. لا بيانات حقيقية (القاعدة 6).

export function rng(seed = 20260101) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

const pad = (n, w) => String(n).padStart(w, '0');
const iso = (d) => d.toISOString().slice(0, 10);

/** التعريفات: مشرفان أو أكثر، ومندوبون، وعملاء بعائلات، وأصناف بأسعار */
export function definitions({ reps, customersPerRep = 200, products = 69 }) {
  const sups = Math.max(2, Math.ceil(reps / 13));
  const employees = [];
  for (let s = 0; s < sups; s++) employees.push({ num: String(900 + s), name: `مشرف تجريبي ${s + 1}`, role: 'مشرف', sup: '' });
  for (let r = 0; r < reps; r++) employees.push({ num: String(100 + r), name: `مندوب تجريبي ${r + 1}`, role: 'مندوب مبيعات', sup: String(900 + (r % sups)) });

  const customers = [];
  const nCust = reps * customersPerRep;
  for (let i = 0; i < nCust; i++) {
    const num = String(10000 + i);
    // عائلات: كل 100 عميل فيها رئيسي له 6 فروع تقريبًا
    const isBranch = i % 100 >= 1 && i % 100 <= 6;
    const master = isBranch ? String(10000 + i - (i % 100)) : num;
    customers.push({ num, name: `عميل تجريبي ${i + 1}`, master, masterName: `عميل تجريبي ${Number(master) - 10000 + 1}` });
  }

  const R = rng(7);
  const items = [];
  for (let p = 0; p < products; p++) {
    items.push({ code: String(100 + p), name: `صنف تجريبي ${p + 1}`, price: (Math.round((0.5 + R() * 12) * 1000) / 1000).toFixed(3),
      cost: null, packing: [1, 6, 12, 24][p % 4] });
  }
  items.forEach((it) => { it.cost = (Number(it.price) * 0.72).toFixed(3); });
  return { employees, customers, items, sups };
}

/** حركات شهر واحد بصيغة الصفوف التي يرسلها التطبيق إلى upload_stage */
export function monthRows({ year, month, reps, rowsPerMonth, customersPerRep = 200, items, seed }) {
  const R = rng(seed ?? year * 100 + month);
  const days = [];
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  for (let d = 1; d <= last; d++) {
    const dt = new Date(Date.UTC(year, month - 1, d));
    if (dt.getUTCDay() !== 5) days.push(iso(dt));     // الجمعة عطلة
  }
  const active = items.slice(0, Math.min(items.length, 39));
  const perRepDay = rowsPerMonth / reps / days.length;
  const invoices = []; const returns = []; const collections = [];
  let row = 1;
  const credits = [];
  for (let r = 0; r < reps; r++) {
    const emp = String(100 + r);
    let seq = 0;
    for (const day of days) {
      let lines = Math.round(perRepDay * (0.7 + R() * 0.6));
      while (lines > 0) {
        const n = Math.min(lines, 1 + Math.floor(R() * 4));
        lines -= n;
        seq++;
        const docNo = `${emp}${pad(month, 2)}${pad(seq, 4)}`;
        const credit = R() < 0.02;
        // عملاء المندوب: شريحته من العملاء، و3% من خارجها
        const ci = R() < 0.97 ? r * customersPerRep + Math.floor(R() * customersPerRep) : Math.floor(R() * reps * customersPerRep);
        const cust = String(10000 + ci);
        const lat = (31.9 + R() * 0.1).toFixed(7); const lng = (35.85 + R() * 0.12).toFixed(7);
        const used = new Set();
        let docTotal = 0;
        for (let k = 0; k < n; k++) {
          let it = active[Math.floor(R() * active.length)];
          while (used.has(it.code)) it = active[(active.indexOf(it) + 1) % active.length];
          used.add(it.code);
          const kind = R();
          const qty = R() < 0.02 ? (Math.floor(R() * 10) + 0.5) : 1 + Math.floor(R() * 12);
          let ns = 0, np = 0, bonus = 0;
          if (kind < 0.06) { bonus = 1 + Math.floor(R() * 3); }                       // بونص فقط
          else if (kind < 0.32) { np = Math.round(qty * Number(it.price) * 0.9 * 1000) / 1000; } // عروض
          else { ns = Math.round(qty * Number(it.price) * 1000) / 1000; }
          docTotal += ns + np;
          invoices.push({ row: row++, doc_number: docNo, customer_number: cust, doc_date: day, employee_number: emp,
            employee_name: `مندوب تجريبي ${r + 1}`, customer_name: `عميل تجريبي ${ci + 1}`, pay_type: credit ? 'فاتورة ذمم' : 'فاتورة نقدي',
            item_number: it.code, item_name: it.name, net_sales: String(ns), net_promotions: String(np),
            quantity: kind < 0.06 ? '0' : String(qty), bonus: String(bonus), lat, lng });
        }
        if (credit && docTotal > 0) credits.push({ emp, r, cust, ci, day, total: docTotal });
        // مرتجع نادر لصنف اشتراه العميل
        if (R() < 0.005) {
          const it = active[Math.floor(R() * active.length)];
          const q = 1 + Math.floor(R() * 3);
          returns.push({ row: returns.length + 1, doc_number: `${emp}${pad(month, 2)}9${pad(returns.length, 3)}`, customer_number: cust, doc_date: day,
            employee_number: emp, employee_name: `مندوب تجريبي ${r + 1}`, customer_name: `عميل تجريبي ${ci + 1}`,
            item_number: it.code, item_name: it.name, net_sales: String(Math.round(q * Number(it.price) * 1000) / 1000), net_promotions: '0',
            quantity: String(q), bonus: '0', lat, lng });
        }
      }
    }
  }
  // تحصيل معظم فواتير الذمم خلال الشهر نفسه أو جزئيًا
  let cseq = 0;
  for (const c of credits) {
    if (R() < 0.15) continue;
    const part = R() < 0.8 ? c.total : Math.round(c.total * 0.5 * 1000) / 1000;
    const di = Math.min(days.length - 1, days.indexOf(c.day) + 1 + Math.floor(R() * 5));
    cseq++;
    const cheque = R() < 0.1;
    collections.push({ row: collections.length + 1, doc_number: `${c.emp}${pad(month, 2)}7${pad(cseq, 4)}`, customer_number: c.cust,
      doc_date: days[di], employee_number: c.emp, employee_name: `مندوب تجريبي ${c.r + 1}`, customer_name: `عميل تجريبي ${c.ci + 1}`,
      amount: part.toFixed(3), pay_method: cheque ? 'شيك مؤجل' : 'نقدي', cheque_no: cheque ? String(500000 + cseq) : '' });
  }
  return { invoices, returns, collections };
}
