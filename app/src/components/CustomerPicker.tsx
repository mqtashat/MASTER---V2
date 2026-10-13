// اختيار العميل بالرقم أو الاسم (STMT-002): الرقم الرقمي مطابقة دقيقة لا احتواء جزئي،
// ويظهر الرقم والاسم والنوع بعد الاختيار. الرقم معرّف نصي بأصفاره البادئة.
import { useEffect, useRef, useState } from 'react';
import { sb } from '../lib/supabase';
import { cleanTerm } from '../lib/query';
import { Badge } from './ui';

export interface PickedCustomer { id: number; customer_number: string; name: string; kind: string; master_number: string | null; master_name: string | null }

export function CustomerPicker({ value, onChange, label = 'العميل' }: {
  value: PickedCustomer | null; onChange: (c: PickedCustomer | null) => void; label?: string;
}) {
  const [term, setTerm] = useState('');
  const [list, setList] = useState<PickedCustomer[]>([]);
  const [open, setOpen] = useState(false);
  const seq = useRef(0);

  useEffect(() => {
    const t = cleanTerm(term);
    if (!t) { setList([]); return; }
    const my = ++seq.current;
    const h = setTimeout(async () => {
      let q = sb().from('customers_v').select('id, customer_number, name, kind, master_number, master_name').limit(20);
      q = /^\d+$/.test(t) ? q.eq('customer_number', t) : q.ilike('name', `%${t}%`);
      const { data } = await q.order('customer_number');
      if (my === seq.current) { setList((data ?? []) as PickedCustomer[]); setOpen(true); }
    }, 250);
    return () => clearTimeout(h);
  }, [term]);

  if (value) {
    return (
      <div className="picked">
        <span className="num">{value.customer_number}</span> — {value.name}{' '}
        <Badge kind={value.kind === 'فرع' ? 'accent' : value.kind === 'رئيسي' ? 'ok' : undefined}>{value.kind}</Badge>
        {value.master_number && <span className="muted small"> الرئيسي: {value.master_number} — {value.master_name}</span>}
        <button className="btn link" onClick={() => { onChange(null); setTerm(''); }}>تغيير</button>
      </div>
    );
  }
  return (
    <div className="picker">
      <input className="input" placeholder="رقم العميل (مطابقة دقيقة) أو اسمه" value={term} aria-label={label}
        onChange={(e) => setTerm(e.target.value)} onFocus={() => list.length && setOpen(true)} />
      {open && term && (
        <ul className="picker-list" role="listbox">
          {list.length === 0 ? <li className="muted small">لا نتائج</li> : list.map((c) => (
            <li key={c.id} role="option" aria-selected={false} tabIndex={0}
              onClick={() => { onChange(c); setOpen(false); }} onKeyDown={(e) => e.key === 'Enter' && (onChange(c), setOpen(false))}>
              <span className="num">{c.customer_number}</span> — {c.name} <span className="muted small">{c.kind}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** جلب عميل واحد بمعرّفه لعرضه في المختار */
export async function loadCustomer(id: number): Promise<PickedCustomer | null> {
  const { data } = await sb().from('customers_v').select('id, customer_number, name, kind, master_number, master_name').eq('id', id).maybeSingle();
  return (data as PickedCustomer) ?? null;
}
