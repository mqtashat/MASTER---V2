-- =====================================================================
-- ماستر — 0002: إدارة المستخدمين والصلاحيات والرمز السري والإعدادات
-- المراجع: AUTH-001..004، B072–B074، P20، P21.
-- الحسابات تُنشأ في auth.users مباشرة باسم مستخدم (بريد داخلي مشتق)،
-- لأن الإنشاء من المتصفح لا يجوز بمفتاح الخدمة.
-- =====================================================================

create or replace function app.username_email(p_username text) returns text
language sql immutable as $$ select lower(trim(p_username)) || '@master.local' $$;

create or replace function app.validate_password(p_password text) returns void
language plpgsql as $$
begin
  if p_password is null or length(p_password) < 8 then
    perform app.fail('weak_password', 'كلمة المرور يجب ألا تقل عن 8 أحرف');
  end if;
end $$;

-- إنشاء مستخدم في auth بالبنية التي يتوقعها Supabase Auth
create or replace function app.create_auth_user(p_username text, p_password text) returns uuid
language plpgsql security definer set search_path = public, app, auth, extensions as $$
declare
  v_id uuid := gen_random_uuid();
  v_email text := app.username_email(p_username);
begin
  perform app.validate_password(p_password);
  if p_username !~ '^[A-Za-z0-9._-]{3,40}$' then
    perform app.fail('bad_username', 'اسم المستخدم من 3 إلى 40 حرفًا لاتينيًا أو رقمًا أو . _ -');
  end if;
  if exists (select 1 from auth.users where email = v_email) then
    perform app.fail('username_taken', 'اسم المستخدم مستخدم مسبقًا');
  end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token,
                          email_change_token_new, email_change, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          crypt(p_password, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', jsonb_build_object('username', p_username),
          '', '', '', '', now(), now());
  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id::text, v_id,
          jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
          'email', now(), now(), now());
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- تهيئة أول حساب إدارة: مسموحة فقط ما دام لا يوجد أي مستخدم
-- ---------------------------------------------------------------------
create or replace function public.bootstrap_admin(p_username text, p_password text, p_display_name text)
returns uuid language plpgsql security definer set search_path = public, app, auth as $$
declare
  v_id uuid;
begin
  if exists (select 1 from public.app_users) then
    perform app.fail('already_initialized', 'النظام مهيأ مسبقًا');
  end if;
  v_id := app.create_auth_user(p_username, p_password);
  insert into public.app_users (id, username, display_name, is_admin, data_scope)
  values (v_id, lower(trim(p_username)), p_display_name, true, 'all');
  insert into public.audit_log (actor_id, actor_name, entity, entity_id, action, after)
  values (v_id, p_display_name, 'app_users', v_id::text, 'bootstrap_admin',
          jsonb_build_object('username', p_username));
  return v_id;
end $$;

create or replace function public.system_initialized() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users)
$$;

-- ---------------------------------------------------------------------
-- ملف المستخدم الحالي وصلاحياته الفعلية (للواجهة)
-- ---------------------------------------------------------------------
create or replace function public.my_profile() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u public.app_users;
  v_perms jsonb;
begin
  select * into u from public.app_users where id = auth.uid() and active;
  if not found then return null; end if;
  select coalesce(jsonb_object_agg(p.code, acts), '{}') into v_perms
  from (
    select p.code,
           to_jsonb(array(select a from unnest(p.actions) a
                           where u.is_admin
                              or (app.granted(u.id, p.code, 'view') and (a = 'view' or app.granted(u.id, p.code, a))))) as acts
      from public.pages p
  ) p where jsonb_array_length(p.acts) > 0;
  return jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', u.display_name,
    'is_admin', u.is_admin, 'data_scope', u.data_scope, 'employee_id', u.employee_id,
    'employee_name', (select name from public.employees where id = u.employee_id),
    'permissions', v_perms,
    'admin_secret_set', u.is_admin and exists (select 1 from app.admin_secret));
end $$;

-- ---------------------------------------------------------------------
-- إدارة الحسابات (P20)
-- ---------------------------------------------------------------------
create or replace function app.user_json(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'username', u.username, 'display_name', u.display_name, 'employee_id', u.employee_id,
    'is_admin', u.is_admin, 'active', u.active, 'template_id', u.template_id, 'data_scope', u.data_scope,
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('page', o.page_code, 'action', o.action, 'granted', o.granted)
                                              order by o.page_code, o.action)
                             from public.user_permission_overrides o where o.user_id = u.id), '[]'),
    'scope_employees', coalesce((select jsonb_agg(s.employee_id order by s.employee_id)
                                   from public.user_scope_employees s where s.user_id = u.id), '[]'))
  from public.app_users u where u.id = p_id
$$;

-- p_user: {username, password, display_name, employee_id, is_admin, template_id, data_scope,
--          overrides:[{page,action,granted}], scope_employees:[ids]}
create or replace function public.admin_save_user(p_id uuid, p_user jsonb) returns uuid
language plpgsql security definer set search_path = public, app, auth as $$
declare
  v_id uuid := p_id;
  v_before jsonb;
  v_scope text := coalesce(p_user->>'data_scope', 'self');
  v_emp bigint := nullif(p_user->>'employee_id', '')::bigint;
  v_is_admin boolean := coalesce((p_user->>'is_admin')::boolean, false);
  r jsonb;
begin
  perform app.require_perm('P20', case when p_id is null then 'add' else 'edit' end);
  -- منح صفة الإدارة أو سحبها للإدارة فقط
  if v_is_admin and not app.is_admin() then
    perform app.fail('admin_only', 'منح صفة الإدارة للإدارة فقط');
  end if;
  if v_scope in ('self', 'team') and v_emp is null and not v_is_admin then
    perform app.fail('scope_needs_employee', 'نطاق «الذات» أو «الفريق» يتطلب ربط الحساب بموظف');
  end if;
  if coalesce(trim(p_user->>'display_name'), '') = '' then
    perform app.fail('name_required', 'الاسم الظاهر مطلوب');
  end if;

  if v_id is null then
    v_id := app.create_auth_user(p_user->>'username', p_user->>'password');
    insert into public.app_users (id, username, display_name, employee_id, is_admin, template_id, data_scope)
    values (v_id, lower(trim(p_user->>'username')), trim(p_user->>'display_name'), v_emp, v_is_admin,
            nullif(p_user->>'template_id', '')::bigint, v_scope);
  else
    if not exists (select 1 from public.app_users where id = v_id) then
      perform app.fail('not_found', 'الحساب غير موجود');
    end if;
    if (select is_admin from public.app_users where id = v_id) and not app.is_admin() then
      perform app.fail('admin_only', 'تعديل حساب إدارة للإدارة فقط');
    end if;
    if v_id = auth.uid() and not v_is_admin and app.is_admin() then
      perform app.fail('self_demote', 'لا يمكن سحب صفة الإدارة من حسابك الحالي');
    end if;
    v_before := app.user_json(v_id);
    update public.app_users set display_name = trim(p_user->>'display_name'), employee_id = v_emp,
           is_admin = v_is_admin, template_id = nullif(p_user->>'template_id', '')::bigint,
           data_scope = v_scope, updated_at = now()
     where id = v_id;
  end if;

  delete from public.user_permission_overrides where user_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p_user->'overrides', '[]')) loop
    insert into public.user_permission_overrides (user_id, page_code, action, granted)
    values (v_id, r->>'page', r->>'action', (r->>'granted')::boolean);
  end loop;
  delete from public.user_scope_employees where user_id = v_id;
  if v_scope = 'selected' then
    insert into public.user_scope_employees (user_id, employee_id)
    select v_id, x::bigint from jsonb_array_elements_text(coalesce(p_user->'scope_employees', '[]')) x;
  end if;

  perform app.audit('app_users', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, app.user_json(v_id));
  return v_id;
end $$;

create or replace function public.admin_set_user_active(p_id uuid, p_active boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public, app, auth as $$
begin
  perform app.require_perm('P20', 'edit');
  if p_id = auth.uid() then perform app.fail('self_disable', 'لا يمكن تعطيل حسابك الحالي'); end if;
  if (select is_admin from public.app_users where id = p_id) and not app.is_admin() then
    perform app.fail('admin_only', 'تعطيل حساب إدارة للإدارة فقط');
  end if;
  update public.app_users set active = p_active, updated_at = now() where id = p_id;
  update auth.users set banned_until = case when p_active then null else 'infinity'::timestamptz end where id = p_id;
  perform app.audit('app_users', p_id::text, case when p_active then 'enable' else 'disable' end,
                    null, null, p_reason);
end $$;

-- إعادة تعيين كلمة المرور دون إظهار السابقة (AUTH-003)
create or replace function public.admin_reset_password(p_id uuid, p_password text) returns void
language plpgsql security definer set search_path = public, app, auth, extensions as $$
begin
  perform app.require_perm('P20', 'edit');
  if (select is_admin from public.app_users where id = p_id) and not app.is_admin() then
    perform app.fail('admin_only', 'إعادة تعيين كلمة مرور الإدارة للإدارة فقط');
  end if;
  perform app.validate_password(p_password);
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_id;
  perform app.audit('app_users', p_id::text, 'reset_password', null, null);
end $$;

create or replace function public.change_my_password(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, app, auth, extensions as $$
begin
  if not exists (select 1 from auth.users where id = auth.uid() and encrypted_password = crypt(p_old, encrypted_password)) then
    perform app.fail('wrong_password', 'كلمة المرور الحالية غير صحيحة');
  end if;
  perform app.validate_password(p_new);
  update auth.users set encrypted_password = crypt(p_new, gen_salt('bf')), updated_at = now() where id = auth.uid();
  perform app.audit('app_users', auth.uid()::text, 'change_password', null, null);
end $$;

-- قوالب الصلاحيات: p_perms = [{page, action}]
create or replace function public.admin_save_template(p_id bigint, p_name text, p_perms jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_id;
  v_before jsonb;
begin
  perform app.require_perm('P20', case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p_name), '') = '' then perform app.fail('name_required', 'اسم القالب مطلوب'); end if;
  if v_id is null then
    insert into public.permission_templates (name) values (trim(p_name)) returning id into v_id;
  else
    select jsonb_agg(jsonb_build_object('page', page_code, 'action', action)) into v_before
      from public.template_permissions where template_id = v_id;
    update public.permission_templates set name = trim(p_name) where id = v_id;
  end if;
  delete from public.template_permissions where template_id = v_id;
  insert into public.template_permissions (template_id, page_code, action)
  select distinct v_id, x->>'page', x->>'action' from jsonb_array_elements(coalesce(p_perms, '[]')) x
   where exists (select 1 from public.pages pg where pg.code = x->>'page' and (x->>'action') = any (pg.actions));
  perform app.audit('permission_templates', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, coalesce(p_perms, '[]'));
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- الرمز السري للإدارة (AUTH-004)
-- ---------------------------------------------------------------------
create or replace function public.admin_set_secret(p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, app, extensions as $$
begin
  perform app.require_admin();
  if exists (select 1 from app.admin_secret) and not app.check_admin_code(p_old) then
    perform app.fail('wrong_code', 'الرمز السري الحالي غير صحيح');
  end if;
  if p_new is null or length(p_new) < 6 then
    perform app.fail('weak_code', 'الرمز السري يجب ألا يقل عن 6 أحرف');
  end if;
  insert into app.admin_secret (id, hash, set_at, set_by) values (1, crypt(p_new, gen_salt('bf')), now(), auth.uid())
  on conflict (id) do update set hash = excluded.hash, set_at = now(), set_by = auth.uid();
  perform app.audit('admin_secret', '1', 'set', null, null);
end $$;

create or replace function public.admin_verify_secret(p_code text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_admin();
  return app.check_admin_code(p_code);
end $$;

-- ---------------------------------------------------------------------
-- الإعدادات (P21)
-- ---------------------------------------------------------------------
create or replace function public.save_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb;
begin
  perform app.require_perm('P21', 'edit');
  -- إعدادات الإدارة الخاصة (CARD-006، MAP-013) للإدارة وحدها
  if p_key in ('show_path_phrase', 'maps_spend_limit') then perform app.require_admin(); end if;
  select value into v_before from public.settings where key = p_key;
  insert into public.settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform app.audit('settings', p_key, 'update', v_before, p_value);
end $$;

-- القيم الابتدائية المعتمدة:
-- عبارة المسار لا تظهر إلا إذا فعّلتها الإدارة (CARD-006).
-- بداية يوم الخرائط 7:00 بتوقيت الأردن، قابلة للتعديل بتاريخ سريان (B064، DAY-001).
insert into public.settings (key, value) values
  ('show_path_phrase', 'false'),
  ('map_day_start', '[{"from": null, "time": "07:00"}]')
on conflict (key) do nothing;

select app.apply_grants();
