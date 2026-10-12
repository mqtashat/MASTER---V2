// الوحدة 1 — حدود الصلاحيات ونطاق البيانات في دوال الكتابة
// المراجع: B072، B073، AUTH-002، PRICE-003، B019
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin, makeUser } from './helpers.mjs';

const P20 = [{ page: 'P20', action: 'view' }, { page: 'P20', action: 'add' }, { page: 'P20', action: 'edit' }];

test('استيراد المنتجات لا يغير نسب العمولة دون صلاحية رؤيتها', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    await db.rpc(a, 'commit_product_import', {
      p_rows: [{ row: 2, code: 'A1', name: 'صنف', sale: '1', rep_A: '2' }],
      p_dates: { sale: '2026-01-01', rates: '2026-01-01' }, p_file_name: 'f',
    });
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مستورد', p_perms: [
      { page: 'P04', action: 'view' }, { page: 'P04', action: 'edit' }, { page: 'P04', action: 'import' }] });
    const u = await makeUser(db, a, { username: 'imp', display_name: 'مستورد', data_scope: 'all', template_id: tpl });
    await rejects(db.rpc(u, 'commit_product_import', {
      p_rows: [{ row: 2, code: 'A1', rep_A: '9' }], p_dates: { rates: '2026-02-01' }, p_file_name: 'f',
    }), 'نسب العمولة');
    await rejects(db.rpc(u, 'commit_product_import', {
      p_rows: [{ row: 2, code: 'B1', name: 'جديد', sale: '1', supervisor_A: '3' }],
      p_dates: { sale: '2026-02-01', rates: '2026-02-01' }, p_file_name: 'f',
    }), 'نسب العمولة');
    // تغيير سعر البيع وحده مسموح
    await db.rpc(u, 'commit_product_import', {
      p_rows: [{ row: 2, code: 'A1', sale: '5' }], p_dates: { sale: '2026-02-01' }, p_file_name: 'f',
    });
    const r = await db.sql(`select app.rate_at(id, 'rep', 'A', '2026-03-01') as rate, app.price_at(id, 'sale', '2026-03-01') as sale
                              from products where code = 'A1'`);
    assert.deepEqual(r, [{ rate: '2', sale: '5' }]);
  } finally { await db.close(); }
});

test('صاحب صلاحية المستخدمين لا يرفع صلاحياته ولا يمنح أكثر مما يملك (B073)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مدير حسابات', p_perms: [...P20, { page: 'P02', action: 'view' }] });
    const m = await makeUser(db, a, { username: 'mgr', display_name: 'مدير', data_scope: 'all', template_id: tpl });

    // لا يعدّل حسابه
    await rejects(db.rpc(m, 'admin_save_user', { p_id: m, p_user: { display_name: 'مدير', data_scope: 'all', template_id: tpl,
      overrides: [{ page: 'P21', action: 'view', granted: true }] } }), 'للإدارة فقط');
    await rejects(db.rpc(m, 'admin_reset_password', { p_id: m, p_password: 'Other#2026x' }), 'تغيير كلمة المرور');

    // لا يمنح غيره صلاحية لا يملكها، ولا يضعها في قالب
    await rejects(makeUser(db, m, { username: 'usr1', display_name: 'س', data_scope: 'all',
      overrides: [{ page: 'P02', action: 'view', granted: true }, { page: 'P02', action: 'edit', granted: true }] }), 'لا تملكه');
    await rejects(db.rpc(m, 'admin_save_template', { p_id: null, p_name: 'كامل', p_perms: [{ page: 'P21', action: 'view' }] }), 'لا تملكها');
    await rejects(db.rpc(m, 'admin_save_template', { p_id: tpl, p_name: 'مدير حسابات', p_perms: [...P20, { page: 'P04', action: 'view' }] }), 'لا تملكها');

    // ويمنح ما يملكه
    const u2 = await makeUser(db, m, { username: 'usr2', display_name: 'ص', data_scope: 'all',
      overrides: [{ page: 'P02', action: 'view', granted: true }] });
    assert.deepEqual((await db.rpc(u2, 'my_profile')).permissions, { P02: ['view'] });

    // ولا يدير حسابًا يملك ما لا يملكه هو
    const tplHi = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'أعلى', p_perms: [{ page: 'P21', action: 'view' }] });
    const hi = await makeUser(db, a, { username: 'high', display_name: 'أعلى', data_scope: 'all', template_id: tplHi });
    await rejects(db.rpc(m, 'admin_reset_password', { p_id: hi, p_password: 'Other#2026x' }), 'لا تملكه');
    await rejects(db.rpc(m, 'admin_set_user_active', { p_id: hi, p_active: false }), 'لا تملكه');
    await rejects(db.rpc(m, 'admin_save_user', { p_id: hi, p_user: { display_name: 'تغيير', data_scope: 'all' } }), 'لا تملكه');
  } finally { await db.close(); }
});

test('صاحب صلاحية المستخدمين لا يوسّع النطاق خارج نطاقه (B072)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const e1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '1', name: 'أ', join_date: '2026-01-01' } });
    const e2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '2', name: 'ب', join_date: '2026-01-01' } });
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مدير', p_perms: P20 });
    const m = await makeUser(db, a, { username: 'mgr', display_name: 'مدير', data_scope: 'selected', scope_employees: [e1], template_id: tpl });
    await rejects(makeUser(db, m, { username: 'wrk1', display_name: 'س', data_scope: 'all' }), 'لا تملكه');
    await rejects(makeUser(db, m, { username: 'wrk2', display_name: 'س', data_scope: 'selected', scope_employees: [e1, e2] }), 'لا تملكه');
    await makeUser(db, m, { username: 'wrk3', display_name: 'س', data_scope: 'self', employee_id: e1 });
  } finally { await db.close(); }
});

test('دوال التعديل ترفض العميل والموظف خارج نطاق المستخدم (B072)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const e1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '1', name: 'أ', join_date: '2026-01-01' } });
    const e2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '2', name: 'ب', join_date: '2026-01-01' } });
    const c1 = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '100', name: 'عميل أ' } });
    const c2 = await db.rpc(a, 'save_customer', { p_id: null, p: { customer_number: '200', name: 'عميل ب' } });
    await db.sql('insert into customer_employee_links (customer_id, employee_id) values ($1, $2), ($3, $4)', [c1, e1, c2, e2]);
    const tpl = await db.rpc(a, 'admin_save_template', { p_id: null, p_name: 'مندوب', p_perms: [
      { page: 'P02', action: 'view' }, { page: 'P02', action: 'edit' },
      { page: 'P03', action: 'view' }, { page: 'P03', action: 'edit' }, { page: 'P03', action: 'transfer' }] });
    const u = await makeUser(db, a, { username: 'rep', display_name: 'مندوب', data_scope: 'self', employee_id: e1, template_id: tpl });

    await db.rpc(u, 'save_customer', { p_id: c1, p: { customer_number: '100', name: 'عميل أ معدل' } });
    await rejects(db.rpc(u, 'save_customer', { p_id: c2, p: { customer_number: '200', name: 'x' } }), 'خارج نطاق');
    await rejects(db.rpc(u, 'set_customer_location', { p_customer: c2, p_lat: 31.9, p_lng: 35.9 }), 'خارج نطاق');
    await rejects(db.rpc(u, 'change_customer_master', { p_customer: c2, p_master_number: '100', p_effective: '2026-02-01' }), 'خارج نطاق');

    await db.rpc(u, 'save_employee', { p_id: e1, p: { emp_number: '1', name: 'أ معدل' } });
    await rejects(db.rpc(u, 'save_employee', { p_id: e2, p: { emp_number: '2', name: 'x' } }), 'خارج نطاق');
    await rejects(db.rpc(u, 'end_employment', { p_employee: e2, p_last_day: '2026-03-01', p_status: 'مستقيل' }), 'خارج نطاق');
    await rejects(db.rpc(u, 'transfer_supervisor', { p_employee: e2, p_new_supervisor: e1, p_effective: '2026-03-01' }), 'خارج نطاق');
    const per = await db.sql('select id from employment_periods where employee_id = $1', [e2]);
    await rejects(db.rpc(u, 'correct_employment_period', { p_period: per[0].id, p_start: '2026-01-02', p_end: null, p_reason: 'x' }), 'خارج نطاق');
  } finally { await db.close(); }
});
