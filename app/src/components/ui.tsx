// مكونات عامة: نافذة، لوحة جانبية، حقل، رسالة، طلب الرمز السري للإدارة (AUTH-004).
import { cloneElement, createContext, isValidElement, ReactElement, ReactNode, useCallback, useContext, useEffect, useId, useRef, useState } from 'react';
import { DbError } from '../lib/supabase';

export function Modal({ title, onClose, children, footer, wide }: {
  title: string; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean;
}) {
  useEscape(onClose);
  return (
    <div className="overlay" role="dialog" aria-modal="true" aria-label={title} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={'modal' + (wide ? ' wide' : '')}>
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="btn link" onClick={onClose} aria-label="إغلاق">إغلاق</button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  );
}

export function Drawer({ title, onClose, children, actions }: {
  title: ReactNode; onClose: () => void; children: ReactNode; actions?: ReactNode;
}) {
  useEscape(onClose);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <aside className="drawer" role="dialog" aria-modal="true">
        <div className="drawer-head">
          <h2>{title}</h2>
          <div className="actions">{actions}<button className="btn" onClick={onClose}>إغلاق</button></div>
        </div>
        <div className="drawer-body">{children}</div>
      </aside>
    </div>
  );
}

function useEscape(onClose: () => void) {
  const ref = useRef(onClose);
  ref.current = onClose;
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') ref.current(); };
    window.addEventListener('keydown', h);
    return () => window.removeEventListener('keydown', h);
  }, []);
}

export function Field({ label, children, hint, error }: { label: string; children: ReactNode; hint?: string; error?: string }) {
  // الاسم المقروء للحقل هو التسمية وحدها؛ التلميح والخطأ مرتبطان بـaria-describedby
  const id = useId();
  const note = error || hint;
  const child = isValidElement(children)
    ? cloneElement(children as ReactElement<Record<string, unknown>>, { id, 'aria-describedby': note ? id + '-note' : undefined, 'aria-invalid': error ? true : undefined })
    : children;
  return (
    <div className={'field' + (error ? ' err' : '')}>
      <label htmlFor={id}>{label}</label>
      {child}
      {note && <small id={id + '-note'} style={error ? { color: 'var(--bad)' } : undefined}>{note}</small>}
    </div>
  );
}

export function Msg({ kind = 'warn', children }: { kind?: 'ok' | 'warn' | 'bad'; children: ReactNode }) {
  return <div className={'msg ' + kind} role={kind === 'bad' ? 'alert' : 'status'}>{children}</div>;
}

export function Badge({ kind, children }: { kind?: 'ok' | 'warn' | 'bad' | 'accent'; children: ReactNode }) {
  return <span className={'badge' + (kind ? ' ' + kind : '')}>{children}</span>;
}

/** تنفيذ إجراء مع عرض الخطأ وحالة الانتظار */
export function useAction() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const run = useCallback(async <T,>(fn: () => Promise<T>): Promise<T | undefined> => {
    setBusy(true); setError(null);
    try { return await fn(); }
    catch (e) { setError((e as Error).message); return undefined; }
    finally { setBusy(false); }
  }, []);
  return { busy, error, setError, run };
}

// ---------------------------------------------------------------------
// طلب الرمز السري عند المساس بشهر مقفل (AUTH-004): يُطلب من الإدارة ثم يعاد الإجراء.
// ---------------------------------------------------------------------
type Asker = () => Promise<string | null>;
const CodeCtx = createContext<Asker | null>(null);

export function CodeProvider({ children }: { children: ReactNode }) {
  const [pending, setPending] = useState<((v: string | null) => void) | null>(null);
  const [code, setCode] = useState('');
  const ask: Asker = useCallback(() => new Promise((resolve) => { setCode(''); setPending(() => resolve); }), []);
  const done = (v: string | null) => { pending?.(v); setPending(null); };
  return (
    <CodeCtx.Provider value={ask}>
      {children}
      {pending && (
        <Modal title="الرمز السري للإدارة" onClose={() => done(null)}
          footer={<><button className="btn primary" onClick={() => done(code)} disabled={!code}>متابعة</button>
                   <button className="btn" onClick={() => done(null)}>إلغاء</button></>}>
          <Msg>هذا الإجراء يمس شهرًا مقفلًا؛ لا يُنفذ إلا بالرمز السري للإدارة.</Msg>
          <Field label="الرمز السري">
            <input type="password" autoFocus value={code} onChange={(e) => setCode(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && code && done(code)} autoComplete="off" />
          </Field>
        </Modal>
      )}
    </CodeCtx.Provider>
  );
}

/** ينفذ fn(code)؛ إذا رُفض لأنه يمس شهرًا مقفلًا يطلب الرمز ويعيد المحاولة */
export function useGuarded() {
  const ask = useContext(CodeCtx);
  return useCallback(async <T,>(fn: (code: string | null) => Promise<T>): Promise<T> => {
    try {
      return await fn(null);
    } catch (e) {
      if (e instanceof DbError && e.code === 'closed_period_code' && ask) {
        const code = await ask();
        if (!code) throw new Error('أُلغي الإجراء');
        return fn(code);
      }
      throw e;
    }
  }, [ask]);
}

export function Loading() {
  return <div className="panel"><div className="skeleton" style={{ width: '40%' }} /><div className="skeleton" style={{ width: '70%', marginTop: 8 }} /></div>;
}
