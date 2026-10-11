// الوحدة 1 — الموظفون وفترات العمل والمشرفون والاستيراد
// المراجع: EMP-003، EMP-005، EMP-006، B001، B004
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { connect, rejects, seedAdmin } from './helpers.mjs';

const row = (n, o) => ({ row: n, emp_number: '', name: '', job_role: 'مندوب مبيعات', join_date: '', status: 'نشط', status_date: '', supervisor_number: '', ...o });

test('EMP-003: آخر يوم عمل مشمول؛ العودة في اليوم نفسه تتداخل (EMP-005)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const e = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '20', name: 'أحمد', join_date: '2026-12-10' } });
    await rejects(db.rpc(a, 'end_employment', { p_employee: e, p_last_day: '2026-12-09', p_status: 'مستقيل' }), 'يسبق بداية الفترة');
    await db.rpc(a, 'end_employment', { p_employee: e, p_last_day: '2026-12-20', p_status: 'مستقيل' });
    const p = await db.sql('select start_date, end_date from employment_periods where employee_id = $1', [e]);
    assert.deepEqual(p, [{ start_date: '2026-12-10', end_date: '2026-12-20' }]);
    await rejects(db.rpc(a, 'reactivate_employee', { p_employee: e, p_start: '2026-12-20' }), 'يتداخل');
    await db.rpc(a, 'reactivate_employee', { p_employee: e, p_start: '2026-12-21' });
    const st = await db.sql('select status from employees where id = $1', [e]);
    assert.equal(st[0].status, 'نشط');
    assert.equal((await db.sql('select count(*)::int n from employment_periods where employee_id = $1', [e]))[0].n, 2);
  } finally { await db.close(); }
});

test('EMP-005: تصحيح فترة سابقة يمنع التداخل والنهاية قبل البداية ويتطلب سببًا', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const e = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '21', name: 'سامي', join_date: '2026-01-01' } });
    await db.rpc(a, 'end_employment', { p_employee: e, p_last_day: '2026-03-31', p_status: 'مستقيل' });
    await db.rpc(a, 'reactivate_employee', { p_employee: e, p_start: '2026-05-01' });
    const [p1] = await db.sql('select id from employment_periods where employee_id = $1 order by start_date limit 1', [e]);
    await rejects(db.rpc(a, 'correct_employment_period', { p_period: p1.id, p_start: '2026-01-01', p_end: '2026-05-01', p_reason: 'x' }), 'تتداخل');
    await rejects(db.rpc(a, 'correct_employment_period', { p_period: p1.id, p_start: '2026-02-01', p_end: '2026-01-15', p_reason: 'x' }), 'تسبق');
    await rejects(db.rpc(a, 'correct_employment_period', { p_period: p1.id, p_start: '2026-01-01', p_end: '2026-04-15', p_reason: '' }), 'سبب');
    await db.rpc(a, 'correct_employment_period', { p_period: p1.id, p_start: '2026-01-01', p_end: '2026-04-15', p_reason: 'خطأ إدخال' });
    const log = await db.sql(`select before, after, reason from audit_log where entity = 'employment_periods'`);
    assert.equal(log[0].reason, 'خطأ إدخال');
    assert.equal(log[0].before.end, '2026-03-31');
  } finally { await db.close(); }
});

test('B001/EMP-006: نقل المندوب — الإبقاء افتراضي، والنقل من تاريخ «من»', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const s1 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '1', name: 'مشرف قديم', join_date: '2026-01-01' } });
    const s2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '2', name: 'مشرف جديد', join_date: '2026-01-01' } });
    const r = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '30', name: 'مندوب', join_date: '2026-01-01', supervisor_id: s1 } });
    await db.rpc(a, 'transfer_supervisor', { p_employee: r, p_new_supervisor: s2, p_effective: '2026-12-15' });
    const sup = async (d) => (await db.sql(`select supervisor_id from supervisor_assignments where employee_id = $1 and daterange(valid_from, valid_to, '[]') @> $2::date`, [r, d]))[0]?.supervisor_id;
    assert.equal(await sup('2026-12-14'), String(s1));
    assert.equal(await sup('2026-12-15'), String(s2));
    // نقل السابق لفترة محددة: من 1/12
    const r2 = await db.rpc(a, 'save_employee', { p_id: null, p: { emp_number: '31', name: 'مندوب 2', join_date: '2026-01-01', supervisor_id: s1 } });
    await db.rpc(a, 'transfer_supervisor', { p_employee: r2, p_new_supervisor: s2, p_effective: '2026-12-15', p_move_prior: true, p_move_from: '2026-12-01' });
    const sup2 = async (d) => (await db.sql(`select supervisor_id from supervisor_assignments where employee_id = $1 and daterange(valid_from, valid_to, '[]') @> $2::date`, [r2, d]))[0]?.supervisor_id;
    assert.equal(await sup2('2026-11-30'), String(s1));
    assert.equal(await sup2('2026-12-01'), String(s2));
    const t = await db.sql('select move_prior, move_from from supervisor_transfers where employee_id = $1', [r2]);
    assert.deepEqual(t, [{ move_prior: true, move_from: '2026-12-01' }]);
    await rejects(db.rpc(a, 'transfer_supervisor', { p_employee: r2, p_new_supervisor: s1, p_effective: '2026-12-10', p_move_prior: true, p_move_from: '2026-12-20' }), 'تسبق تاريخ السريان');
  } finally { await db.close(); }
});

test('استيراد الموظفين: معاينة ثم اعتماد، وتغيير المشرف يتطلب تاريخ سريان (B004)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const rows = [
      row(2, { emp_number: '99', name: 'مشرف', job_role: 'مشرف', join_date: '2025-01-01' }),
      row(3, { emp_number: '98', name: 'مشرف ب', job_role: 'مشرف', join_date: '2025-01-01' }),
      row(4, { emp_number: '12', name: 'محمد', join_date: '2025-06-01', supervisor_number: '99' }),
      row(5, { emp_number: '13', name: 'سعيد', join_date: '2025-06-01', status: 'مستقيل', status_date: '2025-12-31', supervisor_number: '99' }),
    ];
    const pv = await db.rpc(a, 'preview_employee_import', { p_rows: rows });
    assert.equal(pv.counts.new, 4);
    assert.equal(pv.counts.errors, 0);
    await db.rpc(a, 'commit_employee_import', { p_rows: rows, p_decisions: {}, p_file_name: 'الموظفين.xlsx' });
    const e13 = await db.sql(`select e.status, p.end_date from employees e join employment_periods p on p.employee_id = e.id where e.emp_number = '13'`);
    assert.deepEqual(e13, [{ status: 'مستقيل', end_date: '2025-12-31' }]);
    // إعادة الرفع نفسه: لا تغيير
    const pv2 = await db.rpc(a, 'preview_employee_import', { p_rows: rows });
    assert.equal(pv2.counts.unchanged, 4);
    assert.equal(pv2.counts.new + pv2.counts.changed + pv2.counts.supervisor_changes, 0);
    // تغيير مشرف 12 إلى 98: يظهر الحالي والجديد، ويطلب تاريخ السريان
    const rows3 = [row(2, { emp_number: '12', name: 'محمد', join_date: '2025-06-01', supervisor_number: '98' })];
    const pv3 = await db.rpc(a, 'preview_employee_import', { p_rows: rows3 });
    assert.deepEqual(pv3.supervisor_changes.map((x) => [x.current, x.new]), [['99', '98']]);
    await rejects(db.rpc(a, 'commit_employee_import', { p_rows: rows3, p_decisions: {}, p_file_name: 'f' }), 'تاريخ سريان');
    await db.rpc(a, 'commit_employee_import', { p_rows: rows3, p_decisions: { supervisor_effective: { 12: '2026-02-01' } }, p_file_name: 'f' });
    const hist = await db.sql(`select s.emp_number sup, a.valid_from, a.valid_to from supervisor_assignments a join employees e on e.id = a.employee_id join employees s on s.id = a.supervisor_id where e.emp_number = '12' order by a.valid_from nulls first`);
    assert.deepEqual(hist, [{ sup: '99', valid_from: null, valid_to: '2026-01-31' }, { sup: '98', valid_from: '2026-02-01', valid_to: null }]);
    // غياب موظف عن الملف لا يحذفه
    assert.equal((await db.sql('select count(*)::int n from employees'))[0].n, 4);
  } finally { await db.close(); }
});

test('استيراد الموظفين: الأخطاء والتعارضات لا تُطبَّق تلقائيًا (EMP-005)', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    await db.rpc(a, 'commit_employee_import', { p_rows: [row(2, { emp_number: '40', name: 'خالد', join_date: '2026-01-01' })], p_decisions: {}, p_file_name: 'f' });
    const bad = [
      row(2, { emp_number: '41', name: 'جديد', join_date: '' }),
      row(3, { emp_number: '42', name: 'x', join_date: '2026-01-01', supervisor_number: '777' }),
      row(4, { emp_number: '43', name: 'y', join_date: '2026-13-45' }),
      row(5, { emp_number: '44', name: 'z', join_date: '2026-01-01', status: 'إجازة' }),
      row(6, { emp_number: '45', name: 'a', join_date: '2026-01-01' }),
      row(7, { emp_number: '45', name: 'b', join_date: '2026-01-01' }),
    ];
    const pv = await db.rpc(a, 'preview_employee_import', { p_rows: bad });
    const msgs = pv.errors.map((e) => e.message).join(' | ');
    assert.match(msgs, /تاريخ الالتحاق مطلوب/);
    assert.match(msgs, /المشرف غير معرّف/);
    assert.match(msgs, /تاريخ غير مقروء/);
    assert.match(msgs, /الحالة غير معروفة/);
    assert.match(msgs, /مكرر في الملف/);
    await rejects(db.rpc(a, 'commit_employee_import', { p_rows: bad, p_decisions: {}, p_file_name: 'f' }), 'أخطاء تمنع الاعتماد');
    // تاريخ التحاق مختلف عن المحفوظ: تعارض للمراجعة دون استبدال
    const pv2 = await db.rpc(a, 'preview_employee_import', { p_rows: [row(2, { emp_number: '40', name: 'خالد', join_date: '2025-05-05' })] });
    assert.equal(pv2.counts.conflicts, 1);
    await db.rpc(a, 'commit_employee_import', { p_rows: [row(2, { emp_number: '40', name: 'خالد', join_date: '2025-05-05' })], p_decisions: {}, p_file_name: 'f' });
    const p = await db.sql(`select start_date from employment_periods p join employees e on e.id = p.employee_id where e.emp_number = '40'`);
    assert.equal(p[0].start_date, '2026-01-01');
  } finally { await db.close(); }
});

test('استيراد الموظفين: الاستقالة ثم العودة عبر الملف', async () => {
  const db = await connect();
  try {
    const a = await seedAdmin(db);
    const base = row(2, { emp_number: '60', name: 'ليث', join_date: '2026-01-01' });
    await db.rpc(a, 'commit_employee_import', { p_rows: [base], p_decisions: {}, p_file_name: 'f' });
    const end = { ...base, status: 'مستقيل', status_date: '2026-03-10' };
    const pv = await db.rpc(a, 'preview_employee_import', { p_rows: [end] });
    assert.deepEqual(pv.status_changes.map((s) => s.kind), ['end']);
    await db.rpc(a, 'commit_employee_import', { p_rows: [end], p_decisions: {}, p_file_name: 'f' });
    const back = { ...base, status: 'نشط', status_date: '2026-04-01' };
    await db.rpc(a, 'commit_employee_import', { p_rows: [back], p_decisions: {}, p_file_name: 'f' });
    const ps = await db.sql(`select start_date, end_date from employment_periods p join employees e on e.id = p.employee_id where e.emp_number = '60' order by start_date`);
    assert.deepEqual(ps, [{ start_date: '2026-01-01', end_date: '2026-03-10' }, { start_date: '2026-04-01', end_date: null }]);
  } finally { await db.close(); }
});
