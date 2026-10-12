// شاشات الاتصال والتهيئة الأولى والدخول وتغيير كلمة المرور (B074: حساب شخصي وكلمة مرور).
import { FormEvent, useState } from 'react';
import { useAuth } from '../lib/auth';
import { rpc, saveConnection, resetClient, usernameEmail, sb } from '../lib/supabase';
import { Field, Modal, Msg, useAction } from '../components/ui';

export function ConnectionScreen({ onDone }: { onDone: () => void }) {
  const [url, setUrl] = useState('');
  const [key, setKey] = useState('');
  const { busy, error, run } = useAction();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      const u = url.trim().replace(/\/+$/, '');
      if (!/^https:\/\/.+/.test(u)) throw new Error('العنوان يجب أن يبدأ بـ https://');
      const r = await fetch(`${u}/rest/v1/rpc/system_initialized`, {
        method: 'POST', headers: { apikey: key.trim(), Authorization: `Bearer ${key.trim()}`, 'Content-Type': 'application/json' }, body: '{}',
      }).catch(() => null);
      if (!r || !r.ok) throw new Error('تعذر الاتصال بالمشروع؛ تحقق من العنوان والمفتاح العام، ومن تطبيق ملف قاعدة البيانات');
      saveConnection({ url: u, anonKey: key.trim() });
      resetClient();
      onDone();
    });
  };
  return (
    <div className="center-card">
      <form className="panel" onSubmit={submit} style={{ display: 'grid', gap: 10 }}>
        <h1>ماستر — الاتصال بقاعدة البيانات</h1>
        <p className="muted small">أدخل عنوان مشروع Supabase ومفتاحه العام (anon public). يُحفظ في هذا المتصفح فقط.</p>
        <Field label="عنوان المشروع (Project URL)"><input dir="ltr" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://xxxx.supabase.co" required /></Field>
        <Field label="المفتاح العام (anon public key)"><input dir="ltr" value={key} onChange={(e) => setKey(e.target.value)} required /></Field>
        {error && <Msg kind="bad">{error}</Msg>}
        <button className="btn primary" disabled={busy}>{busy ? 'جارٍ التحقق…' : 'اتصال'}</button>
      </form>
    </div>
  );
}

export function BootstrapScreen({ onDone }: { onDone: () => void }) {
  const [f, setF] = useState({ username: '', name: '', password: '', confirm: '' });
  const { busy, error, run } = useAction();
  const { reload } = useAuth();
  const submit = (e: FormEvent) => {
    e.preventDefault();
    run(async () => {
      if (f.password !== f.confirm) throw new Error('كلمتا المرور غير متطابقتين');
      await rpc('bootstrap_admin', { p_username: f.username, p_password: f.password, p_display_name: f.name });
      const { error: err } = await sb().auth.signInWithPassword({ email: usernameEmail(f.username), password: f.password });
      if (err) throw err;
      await reload();
      onDone();
    });
  };
  return (
    <div className="center-card">
      <form className="panel" onSubmit={submit} style={{ display: 'grid', gap: 10 }}>
        <h1>تهيئة النظام</h1>
        <p className="muted small">لا يوجد أي حساب بعد. أنشئ حساب الإدارة الأول (Admin) بكامل الصلاحيات. تُتاح هذه الشاشة مرة واحدة فقط.</p>
        <Field label="اسم المستخدم" hint="أحرف لاتينية أو أرقام، من 3 إلى 40"><input dir="ltr" value={f.username} onChange={(e) => setF({ ...f, username: e.target.value })} required autoComplete="username" /></Field>
        <Field label="الاسم الظاهر"><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} required /></Field>
        <Field label="كلمة المرور" hint="8 أحرف على الأقل"><input type="password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} required autoComplete="new-password" /></Field>
        <Field label="تأكيد كلمة المرور"><input type="password" value={f.confirm} onChange={(e) => setF({ ...f, confirm: e.target.value })} required autoComplete="new-password" /></Field>
        {error && <Msg kind="bad">{error}</Msg>}
        <button className="btn primary" disabled={busy}>إنشاء حساب الإدارة</button>
      </form>
    </div>
  );
}

export function LoginScreen() {
  const { signIn } = useAuth();
  const [u, setU] = useState('');
  const [p, setP] = useState('');
  const { busy, error, run } = useAction();
  return (
    <div className="center-card">
      <form className="panel" style={{ display: 'grid', gap: 10 }}
        onSubmit={(e) => { e.preventDefault(); run(() => signIn(u, p)); }}>
        <h1>ماستر</h1>
        <Field label="اسم المستخدم"><input dir="ltr" value={u} onChange={(e) => setU(e.target.value)} required autoComplete="username" autoFocus /></Field>
        <Field label="كلمة المرور"><input type="password" value={p} onChange={(e) => setP(e.target.value)} required autoComplete="current-password" /></Field>
        {error && <Msg kind="bad">{error}</Msg>}
        <button className="btn primary" disabled={busy}>{busy ? 'جارٍ الدخول…' : 'دخول'}</button>
      </form>
    </div>
  );
}

export function ChangePassword({ onClose }: { onClose: () => void }) {
  const [f, setF] = useState({ old: '', n: '', c: '' });
  const [ok, setOk] = useState(false);
  const { busy, error, run } = useAction();
  const submit = () => run(async () => {
    if (f.n !== f.c) throw new Error('كلمتا المرور الجديدتان غير متطابقتين');
    await rpc('change_my_password', { p_old: f.old, p_new: f.n });
    setOk(true);
  });
  return (
    <Modal title="تغيير كلمة المرور" onClose={onClose}
      footer={ok ? <button className="btn primary" onClick={onClose}>تم</button> :
        <><button className="btn primary" disabled={busy} onClick={submit}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      {ok ? <Msg kind="ok">تم تغيير كلمة المرور.</Msg> : (
        <>
          <Field label="كلمة المرور الحالية"><input type="password" value={f.old} onChange={(e) => setF({ ...f, old: e.target.value })} autoComplete="current-password" /></Field>
          <Field label="الجديدة" hint="8 أحرف على الأقل"><input type="password" value={f.n} onChange={(e) => setF({ ...f, n: e.target.value })} autoComplete="new-password" /></Field>
          <Field label="تأكيد الجديدة"><input type="password" value={f.c} onChange={(e) => setF({ ...f, c: e.target.value })} autoComplete="new-password" /></Field>
          {error && <Msg kind="bad">{error}</Msg>}
        </>
      )}
    </Modal>
  );
}
