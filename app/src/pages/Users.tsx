// P20 — المستخدمون والصلاحيات (AUTH-001..004، B072–B074)
// المحرر: بيانات الدخول ← ربط موظف ← قالب ← استثناءات صفحة/إجراء ← نطاق البيانات ← معاينة ← حفظ.
import { useEffect, useMemo, useState } from 'react';
import { sb, rpc } from '../lib/supabase';
import { useAuth } from '../lib/auth';
import { PAGES, ACTION_LABELS, SCOPE_LABELS } from '../lib/pages';
import { Field, Modal, Msg, Badge, useAction } from '../components/ui';

interface PageRow { code: string; name: string; module: string; sort: number; actions: string[] }
interface UserRow { id: string; username: string; display_name: string; employee_id: number | null; is_admin: boolean; active: boolean; template_id: number | null; data_scope: string }
interface Template { id: number; name: string }
type Perm = { page: string; action: string };
type Override = Perm & { granted: boolean };

export function Users() {
  const { can, profile } = useAuth();
  const [tab, setTab] = useState('users');
  const [users, setUsers] = useState<UserRow[]>([]);
  const [templates, setTemplates] = useState<Template[]>([]);
  const [pages, setPages] = useState<PageRow[]>([]);
  const [emps, setEmps] = useState<{ id: number; emp_number: string; name: string }[]>([]);
  const [editUser, setEditUser] = useState<UserRow | 'new' | null>(null);
  const [editTpl, setEditTpl] = useState<Template | 'new' | null>(null);
  const [ver, setVer] = useState(0);
  const act = useAction();

  useEffect(() => {
    act.run(async () => {
      const [u, t, p, e] = await Promise.all([
        sb().from('app_users').select('*').order('username'),
        sb().from('permission_templates').select('id, name').order('name'),
        sb().from('pages').select('*').order('sort'),
        sb().from('employees').select('id, emp_number, name').order('emp_number'),
      ]);
      setUsers((u.data ?? []) as UserRow[]); setTemplates((t.data ?? []) as Template[]);
      setPages((p.data ?? []) as PageRow[]); setEmps((e.data ?? []) as typeof emps);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ver]);

  const toggleActive = (u: UserRow) => act.run(async () => {
    await rpc('admin_set_user_active', { p_id: u.id, p_active: !u.active, p_reason: null });
    setVer(ver + 1);
  });

  const empName = (id: number | null) => { const e = emps.find((x) => x.id === id); return e ? `${e.emp_number} — ${e.name}` : '—'; };

  return (
    <>
      <div className="page-head">
        <h1>المستخدمون والصلاحيات</h1>
        <div className="actions">
          {tab === 'users' && can('P20', 'add') && <button className="btn primary" onClick={() => setEditUser('new')}>حساب جديد</button>}
          {tab === 'templates' && can('P20', 'add') && <button className="btn primary" onClick={() => setEditTpl('new')}>قالب جديد</button>}
        </div>
      </div>
      <div className="tabs" role="tablist" style={{ marginBottom: 12 }}>
        <button role="tab" aria-selected={tab === 'users'} onClick={() => setTab('users')}>الحسابات</button>
        <button role="tab" aria-selected={tab === 'templates'} onClick={() => setTab('templates')}>قوالب الصلاحيات</button>
      </div>
      {act.error && <Msg kind="bad">{act.error}</Msg>}
      {tab === 'users' && (
        <div className="tbl"><table>
          <thead><tr><th>اسم المستخدم</th><th>الاسم</th><th>الموظف المرتبط</th><th>القالب</th><th>النطاق</th><th>الحالة</th><th></th></tr></thead>
          <tbody>{users.map((u) => (
            <tr key={u.id}>
              <td className="num">{u.username}</td><td>{u.display_name} {u.is_admin && <Badge kind="accent">إدارة</Badge>}</td>
              <td>{empName(u.employee_id)}</td><td>{templates.find((t) => t.id === u.template_id)?.name ?? '—'}</td>
              <td>{u.is_admin ? 'الكل' : SCOPE_LABELS[u.data_scope]}</td>
              <td>{u.active ? <Badge kind="ok">فعّال</Badge> : <Badge kind="bad">معطّل</Badge>}</td>
              <td className="actions">
                {can('P20', 'edit') && <button className="btn link" onClick={() => setEditUser(u)}>تعديل</button>}
                {can('P20', 'edit') && u.id !== profile?.id && <button className="btn link" onClick={() => toggleActive(u)}>{u.active ? 'تعطيل' : 'تفعيل'}</button>}
              </td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
      {tab === 'templates' && (
        <div className="tbl"><table>
          <thead><tr><th>القالب</th><th>عدد الحسابات</th><th></th></tr></thead>
          <tbody>{templates.length === 0 ? <tr><td colSpan={3} className="empty">لا توجد قوالب بعد</td></tr> : templates.map((t) => (
            <tr key={t.id}><td>{t.name}</td><td className="num">{users.filter((u) => u.template_id === t.id).length}</td>
              <td>{can('P20', 'edit') && <button className="btn link" onClick={() => setEditTpl(t)}>تعديل</button>}</td></tr>
          ))}</tbody>
        </table></div>
      )}
      <p className="small muted">غير الممنوح ممنوع، والعرض لازم لأفعال الصفحة. الصلاحيات تُطبَّق في الخادم والتصدير والطباعة والبحث والتفاصيل، لا إخفاء واجهة فقط. فتح الشهر المقفل وتعديله للإدارة وحدها برمزها السري (AUTH-004).</p>
      {editUser && <UserEditor user={editUser === 'new' ? null : editUser} pages={pages} templates={templates} emps={emps}
        onClose={() => setEditUser(null)} onSaved={() => { setEditUser(null); setVer(ver + 1); }} />}
      {editTpl && <TemplateEditor tpl={editTpl === 'new' ? null : editTpl} pages={pages}
        onClose={() => setEditTpl(null)} onSaved={() => { setEditTpl(null); setVer(ver + 1); }} />}
    </>
  );
}

function PermMatrix({ pages, isOn, toggle, overrideOf }: {
  pages: PageRow[]; isOn: (p: string, a: string) => boolean; toggle: (p: string, a: string) => void;
  overrideOf?: (p: string, a: string) => boolean | undefined;
}) {
  const allActions = useMemo(() => Array.from(new Set(pages.flatMap((p) => p.actions))), [pages]);
  return (
    <div className="tbl perm-grid" style={{ maxHeight: 420 }}><table>
      <thead><tr><th>الصفحة</th>{allActions.map((a) => <th key={a}>{ACTION_LABELS[a] ?? a}</th>)}</tr></thead>
      <tbody>{pages.map((p) => (
        <tr key={p.code}><td>{p.name} <span className="muted small">{p.code}</span></td>
          {allActions.map((a) => (
            <td key={a}>{p.actions.includes(a) ? (
              <input type="checkbox" checked={isOn(p.code, a)} onChange={() => toggle(p.code, a)}
                aria-label={`${p.name} — ${ACTION_LABELS[a] ?? a}`}
                style={overrideOf?.(p.code, a) !== undefined ? { outline: '2px solid var(--warn)' } : undefined} />
            ) : null}</td>
          ))}</tr>
      ))}</tbody>
    </table></div>
  );
}

function TemplateEditor({ tpl, pages, onClose, onSaved }: { tpl: Template | null; pages: PageRow[]; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(tpl?.name ?? '');
  const [perms, setPerms] = useState<Set<string>>(new Set());
  const { busy, error, run } = useAction();
  useEffect(() => {
    if (!tpl) return;
    sb().from('template_permissions').select('page_code, action').eq('template_id', tpl.id)
      .then(({ data }) => setPerms(new Set(((data ?? []) as { page_code: string; action: string }[]).map((x) => `${x.page_code}:${x.action}`))));
  }, [tpl]);
  const toggle = (p: string, a: string) => {
    const s = new Set(perms); const k = `${p}:${a}`;
    if (s.has(k)) { s.delete(k); if (a === 'view') [...s].filter((x) => x.startsWith(p + ':')).forEach((x) => s.delete(x)); }
    else { s.add(k); s.add(`${p}:view`); }
    setPerms(s);
  };
  const save = () => run(async () => {
    const list: Perm[] = [...perms].map((k) => { const [page, action] = k.split(':'); return { page, action }; });
    await rpc('admin_save_template', { p_id: tpl?.id ?? null, p_name: name, p_perms: list });
    onSaved();
  });
  return (
    <Modal title={tpl ? 'تعديل قالب الصلاحيات' : 'قالب صلاحيات جديد'} onClose={onClose} wide
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <Field label="اسم القالب"><input value={name} onChange={(e) => setName(e.target.value)} /></Field>
      <PermMatrix pages={pages} isOn={(p, a) => perms.has(`${p}:${a}`)} toggle={toggle} />
      <p className="small muted">منح أي إجراء يمنح العرض تلقائيًا؛ إزالة العرض تزيل بقية إجراءات الصفحة.</p>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}

function UserEditor({ user, pages, templates, emps, onClose, onSaved }: {
  user: UserRow | null; pages: PageRow[]; templates: Template[]; emps: { id: number; emp_number: string; name: string }[];
  onClose: () => void; onSaved: () => void;
}) {
  const { profile } = useAuth();
  const [f, setF] = useState({
    username: user?.username ?? '', password: '', display_name: user?.display_name ?? '',
    employee_id: user?.employee_id ? String(user.employee_id) : '', is_admin: user?.is_admin ?? false,
    template_id: user?.template_id ? String(user.template_id) : '', data_scope: user?.data_scope ?? 'self',
  });
  const [tplPerms, setTplPerms] = useState<Set<string>>(new Set());
  const [overrides, setOverrides] = useState<Map<string, boolean>>(new Map());
  const [scopeEmps, setScopeEmps] = useState<Set<number>>(new Set());
  const [newPw, setNewPw] = useState('');
  const { busy, error, run } = useAction();
  const [pwMsg, setPwMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    sb().from('user_permission_overrides').select('page_code, action, granted').eq('user_id', user.id)
      .then(({ data }) => setOverrides(new Map(((data ?? []) as { page_code: string; action: string; granted: boolean }[]).map((o) => [`${o.page_code}:${o.action}`, o.granted]))));
    sb().from('user_scope_employees').select('employee_id').eq('user_id', user.id)
      .then(({ data }) => setScopeEmps(new Set(((data ?? []) as { employee_id: number }[]).map((x) => x.employee_id))));
  }, [user]);
  useEffect(() => {
    if (!f.template_id) { setTplPerms(new Set()); return; }
    sb().from('template_permissions').select('page_code, action').eq('template_id', Number(f.template_id))
      .then(({ data }) => setTplPerms(new Set(((data ?? []) as { page_code: string; action: string }[]).map((x) => `${x.page_code}:${x.action}`))));
  }, [f.template_id]);

  const granted = (k: string) => overrides.has(k) ? overrides.get(k)! : tplPerms.has(k);
  // الفعلية: العرض لازم لبقية الأفعال
  const effective = (p: string, a: string) => f.is_admin || (granted(`${p}:view`) && (a === 'view' || granted(`${p}:${a}`)));
  const toggle = (p: string, a: string) => {
    const k = `${p}:${a}`; const m = new Map(overrides);
    const want = !granted(k);
    if (want === tplPerms.has(k)) m.delete(k); else m.set(k, want);
    setOverrides(m);
  };

  const save = () => run(async () => {
    const ov: Override[] = [...overrides].map(([k, g]) => { const [page, action] = k.split(':'); return { page, action, granted: g }; });
    await rpc('admin_save_user', { p_id: user?.id ?? null, p_user: {
      ...f, employee_id: f.employee_id || null, template_id: f.template_id || null, overrides: ov, scope_employees: [...scopeEmps],
    } });
    onSaved();
  });
  const resetPw = () => run(async () => { await rpc('admin_reset_password', { p_id: user!.id, p_password: newPw }); setNewPw(''); setPwMsg('تم تعيين كلمة المرور الجديدة.'); });

  const visible = PAGES.filter((p) => effective(p.code, 'view'));

  return (
    <Modal title={user ? `تعديل الحساب ${user.username}` : 'حساب جديد'} onClose={onClose} wide
      footer={<><button className="btn primary" disabled={busy} onClick={save}>حفظ</button><button className="btn" onClick={onClose}>إلغاء</button></>}>
      <h3>1. بيانات الدخول</h3>
      <div className="grid3">
        <Field label="اسم المستخدم"><input dir="ltr" value={f.username} disabled={!!user} onChange={(e) => setF({ ...f, username: e.target.value })} autoComplete="off" /></Field>
        <Field label="الاسم الظاهر"><input value={f.display_name} onChange={(e) => setF({ ...f, display_name: e.target.value })} /></Field>
        {!user ? <Field label="كلمة المرور" hint="8 أحرف على الأقل"><input type="password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} autoComplete="new-password" /></Field>
          : <Field label="إعادة تعيين كلمة المرور" hint="لا تُعرض كلمة المرور السابقة"><div className="actions"><input type="password" className="input" style={{ width: 160 }} value={newPw} onChange={(e) => setNewPw(e.target.value)} autoComplete="new-password" />
              <button type="button" className="btn" disabled={busy || newPw.length < 8} onClick={resetPw}>تعيين</button></div></Field>}
      </div>
      {pwMsg && <Msg kind="ok">{pwMsg}</Msg>}
      <h3>2. ربط موظف (اختياري)</h3>
      <Field label="الموظف" hint="لازم لنطاق «الذات» و«فريق المشرف»"><select value={f.employee_id} onChange={(e) => setF({ ...f, employee_id: e.target.value })}>
        <option value="">— بدون —</option>{emps.map((e) => <option key={e.id} value={e.id}>{e.emp_number} — {e.name}</option>)}</select></Field>
      {profile?.is_admin && <label className="check"><input type="checkbox" checked={f.is_admin} disabled={user?.id === profile.id} onChange={(e) => setF({ ...f, is_admin: e.target.checked })} /> حساب إدارة (كامل الصلاحيات)</label>}
      {!f.is_admin && <>
        <h3>3. قالب الصلاحيات</h3>
        <Field label="القالب"><select value={f.template_id} onChange={(e) => setF({ ...f, template_id: e.target.value })}>
          <option value="">— بدون —</option>{templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</select></Field>
        <h3>4. استثناءات صفحة/إجراء</h3>
        <p className="small muted">الاستثناء الصريح للمستخدم يتقدم على القالب (B073)؛ المربعات المؤطرة استثناءات.</p>
        <PermMatrix pages={pages} isOn={(p, a) => granted(`${p}:${a}`)} toggle={toggle} overrideOf={(p, a) => overrides.get(`${p}:${a}`)} />
        <h3>5. نطاق البيانات</h3>
        <Field label="النطاق"><select value={f.data_scope} onChange={(e) => setF({ ...f, data_scope: e.target.value })}>
          {Object.entries(SCOPE_LABELS).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
        {f.data_scope === 'selected' && (
          <div className="panel" style={{ maxHeight: 200, overflowY: 'auto' }}>
            {emps.map((e) => (
              <label key={e.id} className="check" style={{ display: 'flex' }}><input type="checkbox" checked={scopeEmps.has(e.id)}
                onChange={() => { const s = new Set(scopeEmps); s.has(e.id) ? s.delete(e.id) : s.add(e.id); setScopeEmps(s); }} /> {e.emp_number} — {e.name}</label>
            ))}
          </div>
        )}
      </>}
      <h3>6. معاينة ما سيراه المستخدم</h3>
      <div className="panel small">
        {visible.length === 0 ? <span className="muted">لا صفحات مسموحة.</span> : visible.map((p) => (
          <div key={p.code}><b>{p.name}</b>: {(pages.find((x) => x.code === p.code)?.actions ?? []).filter((a) => effective(p.code, a)).map((a) => ACTION_LABELS[a] ?? a).join('، ')}</div>
        ))}
        <div className="muted" style={{ marginTop: 6 }}>النطاق: {f.is_admin ? 'الكل' : SCOPE_LABELS[f.data_scope]}</div>
      </div>
      {error && <Msg kind="bad">{error}</Msg>}
    </Modal>
  );
}
