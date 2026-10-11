// الوحدة 1 — المستخدمون والصلاحيات والرمز السري
// حالات القبول: A01، A03، A04، A06، A07، D24 (جزء التعريفات)، AUTH-001..004
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

test('تهيئة الإدارة مرة واحدة فقط (AUTH-001)', async () => {
  const db = await connect();
  try {
    assert.equal(await db.rpc(null, 'system_initialized'), false);
    await seedAdmin(db);
    assert.equal(await db.rpc(null, 'system_initialized'), true);
    await rejects(db.rpc(null, 'bootstrap_admin', { p_username: 'x2', p_password: 'Admin#2026', p_display_name: 'x' }), 'مهيأ مسبقًا');
  } finally { await db.close(); }
});

test('الإدارة كاملة الصلاحيات، والحساب العادي غير الممنوح ممنوع (B073)', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const prof = await db.rpc(admin, 'my_profile');
    assert.equal(prof.is_admin, true);
    assert.ok(prof.permissions.P20.includes('add'));
    const u = await makeUser(db, admin, { username: 'acc1', display_name: 'محاسب', data_scope: 'all' });
    const p2 = await db.rpc(u, 'my_profile');
    assert.deepEqual(p2.permissions, {});
    await rejects(db.rpc(u, 'save_customer', { p_id: null, p: { customer_number: '1', name: 'عميل' } }), 'لا تملك صلاحية');
  } finally { await db.close(); }
});

test('A06: قالب الدور ثم استثناء المستخدم الصريح مقدم عليه', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const tpl = await db.rpc(admin, 'admin_save_template', {
      p_id: null, p_name: 'محاسب',
      p_perms: [{ page: 'P02', action: 'view' }, { page: 'P02', action: 'edit' }, { page: 'P02', action: 'export' }],
    });
    const u = await makeUser(db, admin, {
      username: 'acc2', display_name: 'محاسب 2', data_scope: 'all', template_id: tpl,
      overrides: [{ page: 'P02', action: 'export', granted: false }, { page: 'P02', action: 'add', granted: true }],
    });
    const p = await db.rpc(u, 'my_profile');
    assert.deepEqual([...p.permissions.P02].sort(), ['add', 'edit', 'view']);
  } finally { await db.close(); }
});

test('A03: صفحة مسموحة وإجراء ممنوع يرفض في الخادم', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const tpl = await db.rpc(admin, 'admin_save_template', { p_id: null, p_name: 'عرض فقط', p_perms: [{ page: 'P02', action: 'view' }] });
    const u = await makeUser(db, admin, { username: 'viewer', display_name: 'مطلع', data_scope: 'all', template_id: tpl });
    await db.rpc(admin, 'save_customer', { p_id: null, p: { customer_number: '100', name: 'عميل' } });
    const rows = await db.as(u, 'select customer_number from public.customers');
    assert.equal(rows.length, 1);
    await rejects(db.rpc(u, 'save_customer', { p_id: null, p: { customer_number: '101', name: 'آخر' } }), 'لا تملك صلاحية');
    // ولا كتابة مباشرة على الجدول
    await rejects(db.as(u, `insert into public.customers (customer_number, name) values ('9', 'x')`), 'permission denied');
  } finally { await db.close(); }
});

test('الإجراء دون العرض لا يكفي (العرض لازم لأفعال الصفحة)', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const tpl = await db.rpc(admin, 'admin_save_template', { p_id: null, p_name: 'تعديل بلا عرض', p_perms: [{ page: 'P02', action: 'edit' }] });
    const u = await makeUser(db, admin, { username: 'odd', display_name: 'x', data_scope: 'all', template_id: tpl });
    const p = await db.rpc(u, 'my_profile');
    assert.equal(p.permissions.P02, undefined);
  } finally { await db.close(); }
});

test('A01: نطاق «مندوبون محددون» لا يكشف الثالث', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const ids = {};
    for (const n of ['10', '11', '12', '13']) {
      ids[n] = await db.rpc(admin, 'save_employee', { p_id: null, p: { emp_number: n, name: 'موظف ' + n, join_date: '2026-01-01' } });
    }
    const tpl = await db.rpc(admin, 'admin_save_template', { p_id: null, p_name: 'مشرف', p_perms: [{ page: 'P03', action: 'view' }] });
    const sup = await makeUser(db, admin, {
      username: 'sup1', display_name: 'مشرف', employee_id: ids['10'], data_scope: 'selected',
      template_id: tpl, scope_employees: [ids['11'], ids['12']],
    });
    const seen = (await db.as(sup, 'select emp_number from public.employees order by emp_number')).map((r) => r.emp_number);
    assert.deepEqual(seen, ['10', '11', '12']);
    const v = await db.as(sup, 'select count(*)::int n from public.employees_v');
    assert.equal(v[0].n, 3);
  } finally { await db.close(); }
});

test('نطاق «الفريق» يتبع التبعية للمشرف، و«الذات» نفسه فقط', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const s = await db.rpc(admin, 'save_employee', { p_id: null, p: { emp_number: '50', name: 'المشرف', job_role: 'مشرف', join_date: '2026-01-01' } });
    const r1 = await db.rpc(admin, 'save_employee', { p_id: null, p: { emp_number: '51', name: 'مندوب 1', join_date: '2026-01-01', supervisor_id: s } });
    await db.rpc(admin, 'save_employee', { p_id: null, p: { emp_number: '52', name: 'مندوب 2', join_date: '2026-01-01' } });
    const tpl = await db.rpc(admin, 'admin_save_template', { p_id: null, p_name: 'فريق', p_perms: [{ page: 'P03', action: 'view' }] });
    const su = await makeUser(db, admin, { username: 'sup', display_name: 'مشرف', employee_id: s, data_scope: 'team', template_id: tpl });
    const ru = await makeUser(db, admin, { username: 'rep', display_name: 'مندوب', employee_id: r1, data_scope: 'self', template_id: tpl });
    assert.deepEqual((await db.as(su, 'select emp_number from employees order by 1')).map((r) => r.emp_number), ['50', '51']);
    assert.deepEqual((await db.as(ru, 'select emp_number from employees order by 1')).map((r) => r.emp_number), ['51']);
    await rejects(makeUser(db, admin, { username: 'bad', display_name: 'x', data_scope: 'self' }), 'يتطلب ربط الحساب بموظف');
  } finally { await db.close(); }
});

test('A04: تعطيل الحساب يمنع الوصول ويحفظ السجل', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const u = await makeUser(db, admin, { username: 'gone', display_name: 'سيعطل', data_scope: 'all', overrides: [{ page: 'P02', action: 'view', granted: true }] });
    assert.ok(await db.rpc(u, 'my_profile'));
    await db.rpc(admin, 'admin_set_user_active', { p_id: u, p_active: false, p_reason: 'انتهاء العمل' });
    assert.equal(await db.rpc(u, 'my_profile'), null);
    const banned = await db.sql('select banned_until from auth.users where id = $1', [u]);
    assert.ok(banned[0].banned_until);
    assert.equal((await db.as(u, 'select * from customers')).length, 0);
    const log = await db.sql(`select action, reason from audit_log where entity = 'app_users' and entity_id = $1 order by id`, [u]);
    assert.deepEqual(log.map((l) => l.action), ['create', 'disable']);
    await rejects(db.rpc(admin, 'admin_set_user_active', { p_id: admin, p_active: false }), 'لا يمكن تعطيل حسابك');
  } finally { await db.close(); }
});

test('كلمة المرور: الحد الأدنى، وإعادة التعيين لا تظهر القديمة، وتغيير المستخدم لكلمته', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    await rejects(makeUser(db, admin, { username: 'short', display_name: 'x', data_scope: 'all', password: '123' }), 'لا تقل عن 8');
    const u = await makeUser(db, admin, { username: 'pwuser', display_name: 'x', data_scope: 'all' });
    await db.rpc(admin, 'admin_reset_password', { p_id: u, p_password: 'NewPass#1' });
    await rejects(db.rpc(u, 'change_my_password', { p_old: 'wrong-old', p_new: 'Another#22' }), 'غير صحيحة');
    await db.rpc(u, 'change_my_password', { p_old: 'NewPass#1', p_new: 'Another#22' });
    const ok = await db.sql(`select encrypted_password = extensions.crypt('Another#22', encrypted_password) ok from auth.users where id = $1`, [u]);
    assert.equal(ok[0].ok, true);
  } finally { await db.close(); }
});

test('A07 وCARD-006: إعداد عبارة المسار للإدارة وحدها', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const u = await makeUser(db, admin, { username: 'set', display_name: 'إعدادات', data_scope: 'all',
      overrides: [{ page: 'P21', action: 'view', granted: true }, { page: 'P21', action: 'edit', granted: true }] });
    await rejects(db.rpc(u, 'save_setting', { p_key: 'show_path_phrase', p_value: false }), 'للإدارة فقط');
    await db.rpc(u, 'save_setting', { p_key: 'company_name', p_value: JSON.stringify('شركة') });
    await db.rpc(admin, 'save_setting', { p_key: 'show_path_phrase', p_value: false });
    const v = await db.sql(`select value from settings where key = 'show_path_phrase'`);
    assert.equal(v[0].value, false);
  } finally { await db.close(); }
});

test('AUTH-004: الرمز السري للإدارة وحماية الشهر المقفل في التعريفات (D24)', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    const p = await db.rpc(admin, 'save_product', { p_id: null, p_code: '101', p_name: 'صنف' });
    await db.rpc(admin, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 2, p_date: '2026-01-01' });
    await db.sql(`insert into months (month, status) values ('2026-01-01', 'closed')`);
    // لا رمز مضبوط بعد: الرفض
    await rejects(db.rpc(admin, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 3, p_date: '2026-01-15' }), 'الرمز السري');
    await db.rpc(admin, 'admin_set_secret', { p_old: null, p_new: 'sirr-2026' });
    await rejects(db.rpc(admin, 'admin_set_secret', { p_old: 'wrong', p_new: 'x-new-code' }), 'غير صحيح');
    await rejects(db.rpc(admin, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 3, p_date: '2026-01-15', p_code: 'wrong' }), 'الرمز السري');
    assert.equal(await db.rpc(admin, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 3, p_date: '2026-01-15', p_code: 'sirr-2026' }), 'set');
    // مستخدم غير إداري لا يعدل المقفل حتى بالرمز
    const u = await makeUser(db, admin, { username: 'pricer', display_name: 'x', data_scope: 'all',
      overrides: [{ page: 'P04', action: 'view', granted: true }, { page: 'P04', action: 'edit', granted: true }] });
    await rejects(db.rpc(u, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 4, p_date: '2026-01-20', p_code: 'sirr-2026' }), 'للإدارة فقط');
    // الشهر المفتوح يكفيه الصلاحية العادية
    assert.equal(await db.rpc(u, 'set_product_value', { p_product: p, p_kind: 'sale', p_value: 4, p_date: '2026-02-01' }), 'set');
    // الرمز لا يُقرأ من الواجهة
    await rejects(db.as(admin, 'select * from app.admin_secret'), 'permission denied');
  } finally { await db.close(); }
});

test('سجل العمليات لا يعدله أحد', async () => {
  const db = await connect();
  try {
    const admin = await seedAdmin(db);
    await rejects(db.as(admin, `delete from audit_log`), 'permission denied');
    await rejects(db.as(admin, `update audit_log set reason = 'x'`), 'permission denied');
  } finally { await db.close(); }
});
