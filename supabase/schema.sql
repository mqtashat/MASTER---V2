-- ماستر: ملف قاعدة البيانات المجمّع — مولَّد آليًا من supabase/migrations، لا تعدّله يدويًا.

-- >>> 0001_foundation.sql
-- =====================================================================
-- ماستر — 0001: الأساس
-- الإضافات، المخطط الداخلي app، سجل العمليات، الإعدادات، الأشهر وحمايتها،
-- سجل الصفحات، الموظفون وفترات العمل والمشرفون، المستخدمون والصلاحيات.
-- المراجع: B072–B077، AUTH-001..004، PERIOD-001/002، EMP-003..006، B001–B004.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;

create schema if not exists app;
grant usage on schema app to authenticated, anon;

-- ---------------------------------------------------------------------
-- أدوات عامة
-- ---------------------------------------------------------------------

-- تاريخ اليوم بتوقيت الأردن
create or replace function app.today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Amman')::date $$;

-- أول يوم في شهر التاريخ
create or replace function app.month_of(d date) returns date
language sql immutable as $$ select date_trunc('month', d)::date $$;

-- رفع خطأ برسالة عربية ورمز ثابت يقرؤه التطبيق
create or replace function app.fail(p_code text, p_message text) returns void
language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_message, detail = p_code;
end $$;

-- ---------------------------------------------------------------------
-- الموظفون وفترات العمل والمشرفون (EMP-003..006، B001–B004)
-- ---------------------------------------------------------------------

create table public.employees (
  id            bigserial primary key,
  emp_number    text not null unique,            -- الرقم الوظيفي نصًا مع الأصفار البادئة
  name          text not null,
  job_role      text,                             -- الدور الوظيفي كما ورد (مندوب مبيعات، مشرف، سائق…)
  status        text not null default 'نشط' check (status in ('نشط', 'مستقيل', 'موقوف')),
  status_date   date,                             -- «تاريخ الحالة الفعلي»: آخر يوم عمل عند الإنهاء
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
comment on table public.employees is 'الموظفون. الراتب خارج النطاق (B003).';

-- فترة عمل شاملة الطرفين؛ النهاية الفارغة = مستمرة (EMP-003/005)
create table public.employment_periods (
  id           bigserial primary key,
  employee_id  bigint not null references public.employees(id),
  start_date   date not null,
  end_date     date,
  created_at   timestamptz not null default now(),
  check (end_date is null or end_date >= start_date),
  exclude using gist (employee_id with =, daterange(start_date, end_date, '[]') with &&)
);
create index on public.employment_periods (employee_id, start_date);

-- تبعية المندوب للمشرف عبر الزمن، شاملة الطرفين (EMP-006)
create table public.supervisor_assignments (
  id            bigserial primary key,
  employee_id   bigint not null references public.employees(id),
  supervisor_id bigint not null references public.employees(id),
  valid_from    date,                             -- الفارغ = منذ البداية
  valid_to      date,                             -- الفارغ = مستمرة
  created_at    timestamptz not null default now(),
  check (employee_id <> supervisor_id),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  exclude using gist (employee_id with =, daterange(valid_from, valid_to, '[]') with &&)
);
create index on public.supervisor_assignments (supervisor_id);

-- سجل عمليات نقل المندوب بين المشرفين (B001، EMP-006)
create table public.supervisor_transfers (
  id               bigserial primary key,
  employee_id      bigint not null references public.employees(id),
  old_supervisor_id bigint references public.employees(id),
  new_supervisor_id bigint references public.employees(id),
  effective_date   date not null,
  move_prior       boolean not null default false,   -- الافتراضي إبقاء السابق
  move_from        date,                              -- بداية فترة النقل «من — إلى»
  reason           text,
  created_at       timestamptz not null default now(),
  created_by       uuid
);

-- ---------------------------------------------------------------------
-- المستخدمون والصلاحيات (B072–B074، AUTH-001..003)
-- ---------------------------------------------------------------------

create table public.pages (
  code     text primary key,
  name     text not null,
  module   text not null,
  sort     int  not null,
  actions  text[] not null
);

create table public.permission_templates (
  id          bigserial primary key,
  name        text not null unique,
  created_at  timestamptz not null default now()
);

create table public.template_permissions (
  template_id bigint not null references public.permission_templates(id) on delete cascade,
  page_code   text   not null references public.pages(code),
  action      text   not null,
  primary key (template_id, page_code, action)
);

create table public.app_users (
  id            uuid primary key,                   -- = auth.users.id
  username      text not null unique,
  display_name  text not null,
  employee_id   bigint references public.employees(id),
  is_admin      boolean not null default false,
  active        boolean not null default true,
  template_id   bigint references public.permission_templates(id),
  data_scope    text not null default 'self' check (data_scope in ('all', 'team', 'selected', 'self')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- استثناء صريح للمستخدم يتقدم على القالب (B073)
create table public.user_permission_overrides (
  user_id    uuid not null references public.app_users(id) on delete cascade,
  page_code  text not null references public.pages(code),
  action     text not null,
  granted    boolean not null,
  primary key (user_id, page_code, action)
);

-- المندوبون المختارون لنطاق «مندوبون محددون» (B072)
create table public.user_scope_employees (
  user_id     uuid   not null references public.app_users(id) on delete cascade,
  employee_id bigint not null references public.employees(id),
  primary key (user_id, employee_id)
);

-- ---------------------------------------------------------------------
-- سجل العمليات (AUTH-003، TXN-003): إضافة فقط، لا تعديل ولا حذف
-- ---------------------------------------------------------------------

create table public.audit_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,
  actor_name  text,
  entity      text not null,
  entity_id   text,
  action      text not null,
  before      jsonb,
  after       jsonb,
  reason      text
);
create index on public.audit_log (entity, entity_id);
create index on public.audit_log (at desc);
create index on public.audit_log (actor_id);

-- ---------------------------------------------------------------------
-- الإعدادات العامة
-- ---------------------------------------------------------------------

create table public.settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

-- ---------------------------------------------------------------------
-- الأشهر وحالتها (PERIOD-001/002، AUTH-004، B075–B077)
-- ---------------------------------------------------------------------

create table public.months (
  month       date primary key check (extract(day from month) = 1),
  status      text not null default 'open' check (status in ('open', 'closed')),
  version     int  not null default 0,               -- رقم نسخة الاعتماد بعد كل إغلاق
  closed_at   timestamptz,
  closed_by   uuid,
  reopened_at timestamptz,
  reopen_reason text
);

-- الرمز السري للإدارة (AUTH-004): محفوظ مُجزّأً، لا يُقرأ من الواجهة
create table app.admin_secret (
  id       int primary key default 1 check (id = 1),
  hash     text not null,
  set_at   timestamptz not null default now(),
  set_by   uuid
);
revoke all on app.admin_secret from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- دوال المستخدم الحالي والصلاحيات
-- ---------------------------------------------------------------------

create or replace function app.uid() returns uuid
language sql stable as $$ select auth.uid() $$;

create or replace function app.me() returns public.app_users
language sql stable security definer set search_path = public, app as $$
  select u.* from public.app_users u where u.id = auth.uid() and u.active
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select u.is_admin from public.app_users u where u.id = auth.uid() and u.active), false)
$$;

-- منح فعل واحد دون شرط العرض
create or replace function app.granted(p_user uuid, p_page text, p_action text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select o.granted from public.user_permission_overrides o
      where o.user_id = p_user and o.page_code = p_page and o.action = p_action),
    exists (select 1 from public.app_users u
              join public.template_permissions t on t.template_id = u.template_id
             where u.id = p_user and t.page_code = p_page and t.action = p_action)
  )
$$;

-- الصلاحية الفعلية: الإدارة كاملة؛ غير الممنوح ممنوع؛ العرض لازم لبقية الأفعال (AUTH-002، B073)
create or replace function app.has_perm(p_page text, p_action text default 'view') returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid() and active;
  if not found then return false; end if;
  if u.is_admin then return true; end if;
  if not app.granted(u.id, p_page, 'view') then return false; end if;
  return p_action = 'view' or app.granted(u.id, p_page, p_action);
end $$;

create or replace function app.require_perm(p_page text, p_action text) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.has_perm(p_page, p_action) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
end $$;

create or replace function app.require_admin() returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_admin() then
    perform app.fail('admin_only', 'هذا الإجراء للإدارة فقط');
  end if;
end $$;

-- نطاق البيانات: هل يرى المستخدم هذا الموظف؟ (B072)
create or replace function app.can_see_employee(p_employee bigint) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid() and active;
  if not found then return false; end if;
  if u.is_admin or u.data_scope = 'all' then return true; end if;
  if p_employee is null then return false; end if;
  if u.employee_id = p_employee then return true; end if;
  if u.data_scope = 'team' and u.employee_id is not null then
    return exists (select 1 from public.supervisor_assignments s
                    where s.supervisor_id = u.employee_id and s.employee_id = p_employee);
  end if;
  if u.data_scope = 'selected' then
    return exists (select 1 from public.user_scope_employees e
                    where e.user_id = u.id and e.employee_id = p_employee);
  end if;
  return false;
end $$;

create or replace function app.scope_is_all() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select u.is_admin or u.data_scope = 'all'
                     from public.app_users u where u.id = auth.uid() and u.active), false)
$$;

-- ---------------------------------------------------------------------
-- سجل العمليات
-- ---------------------------------------------------------------------

create or replace function app.audit(p_entity text, p_entity_id text, p_action text,
                                     p_before jsonb, p_after jsonb, p_reason text default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  insert into public.audit_log (actor_id, actor_name, entity, entity_id, action, before, after, reason)
  values (auth.uid(),
          (select display_name from public.app_users where id = auth.uid()),
          p_entity, p_entity_id, p_action, p_before, p_after, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- حماية الفترات المقفلة (AUTH-004، B076)
-- ---------------------------------------------------------------------

create or replace function app.is_closed(d date) returns boolean
language sql stable security definer set search_path = public, app as $$
  select d is not null and exists (select 1 from public.months m
                                    where m.month = app.month_of(d) and m.status = 'closed')
$$;

create or replace function app.check_admin_code(p_code text) returns boolean
language sql stable security definer set search_path = public, app, extensions as $$
  select p_code is not null
     and exists (select 1 from app.admin_secret s where s.hash = crypt(p_code, s.hash))
$$;

-- أي تعديل يمس تاريخًا في شهر مقفل: الإدارة فقط وبرمزها السري
create or replace function app.guard_dates(p_dates date[], p_code text) returns void
language plpgsql stable security definer set search_path = public, app as $$
declare
  d date;
begin
  foreach d in array coalesce(p_dates, '{}') loop
    if app.is_closed(d) then
      if not app.is_admin() then
        perform app.fail('closed_period', 'التعديل يمس شهرًا مقفلًا (' || to_char(d, 'FMMM/YYYY') || '): للإدارة فقط برمزها السري');
      end if;
      if not app.check_admin_code(p_code) then
        perform app.fail('closed_period_code', 'التعديل يمس شهرًا مقفلًا (' || to_char(d, 'FMMM/YYYY') || '): الرمز السري للإدارة مطلوب أو غير صحيح');
      end if;
    end if;
  end loop;
end $$;

-- الشهر المقفل الأقدم ضمن مدى (أو null)
create or replace function app.first_closed_in(p_from date, p_to date) returns date
language sql stable security definer set search_path = public, app as $$
  select min(m.month) from public.months m
   where m.status = 'closed'
     and m.month >= app.month_of(coalesce(p_from, '1900-01-01'))
     and m.month <= coalesce(p_to, '9999-12-01')
$$;

-- ---------------------------------------------------------------------
-- الصلاحيات على مستوى قاعدة البيانات: تُستدعى في آخر كل ترحيل.
-- القراءة من الجداول للمستخدم المسجل (وتقيّدها سياسات RLS)، ولا كتابة مباشرة؛
-- الكتابة عبر دوال public المحمية فقط. دوال app الداخلية غير متاحة إلا
-- دوال القراءة التي تستعملها السياسات والعروض.
-- ---------------------------------------------------------------------
create or replace function app.apply_grants() returns void
language plpgsql as $$
declare
  f record;
begin
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke insert, update, delete, truncate on all tables in schema public from authenticated, anon';
  execute 'revoke all on all tables in schema app from public, anon, authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated';
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname = any (array['today', 'month_of', 'uid', 'is_admin', 'has_perm', 'can_see_employee',
                                  'can_see_customer', 'scope_is_all', 'price_at', 'packing_at', 'rate_at',
                                  'master_of', 'is_closed'])
  loop
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
  -- ما يحتاجه الزائر قبل الدخول
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('bootstrap_admin', 'system_initialized')
  loop
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- سجل الصفحات وأفعالها (AUTH-002)
-- ---------------------------------------------------------------------

insert into public.pages (code, name, module, sort, actions) values
  ('P01',  'الرئيسية',                         'الرئيسية',           10,  '{view}'),
  ('P02',  'العملاء',                          'البيانات',           20,  '{view,add,edit,import,export,print}'),
  ('P03',  'الموظفون والفرق',                  'البيانات',           30,  '{view,add,edit,import,export,transfer}'),
  ('P04',  'المنتجات والأسعار',                'البيانات',           40,  '{view,add,edit,import,export,view_cost,view_commission}'),
  ('P05',  'الرفع الموحد وسجله',               'البيانات',           50,  '{view,import,approve,delete}'),
  ('P06',  'الفواتير والمرتجعات والتحصيلات',   'البيانات',           60,  '{view,edit,delete,transfer,export,print}'),
  ('P07',  'كشف حساب العميل',                  'الحسابات',           70,  '{view,export,print,snapshot}'),
  ('P08',  'الذمم الحالية',                    'الحسابات',           80,  '{view,export,print}'),
  ('P08a', 'الافتتاحيات والإغلاق السنوي',      'الحسابات',           85,  '{view,add,edit,import,export,approve}'),
  ('P09',  'الإشعارات المدينة والدائنة',       'الحسابات',           90,  '{view,add,edit,delete,export}'),
  ('P10',  'أهداف المندوبين',                  'الأهداف والعمولات',  100, '{view,add,edit,delete,import,export}'),
  ('P10a', 'أهداف المشرفين',                   'الأهداف والعمولات',  105, '{view,add,edit,delete,export}'),
  ('P11',  'قواعد العمولة',                    'الأهداف والعمولات',  110, '{view,add,edit,delete}'),
  ('P12',  'المكافآت',                         'الأهداف والعمولات',  120, '{view,add,edit,delete}'),
  ('P13',  'بطاقات الأداء',                    'الأهداف والعمولات',  130, '{view,print}'),
  ('P14',  'كشف العمولات',                     'الأهداف والعمولات',  140, '{view,edit,approve,recalc,export,print}'),
  ('P14b', 'الأشهر والإغلاق',                  'الأهداف والعمولات',  145, '{view}'),
  ('P15',  'خريطة الفواتير والمسار',           'الخرائط',            150, '{view,export,print}'),
  ('P16',  'مواقع العملاء',                    'الخرائط',            160, '{view,edit,import,export}'),
  ('P17',  'المناطق والأسواق',                 'الخرائط',            170, '{view,add,edit,delete}'),
  ('P17a', 'مقارنة الفترات',                   'الخرائط',            175, '{view,export,print}'),
  ('P17b', 'انتشار الأصناف',                   'الخرائط',            178, '{view,export,print}'),
  ('P18',  'التقارير',                         'التقارير',           180, '{view,export,print,snapshot}'),
  ('P19',  'التقويم',                          'الإعدادات',          190, '{view,edit}'),
  ('P20',  'المستخدمون والصلاحيات',            'الإعدادات',          200, '{view,add,edit}'),
  ('P21',  'الإعدادات وسجل العمليات',          'الإعدادات',          210, '{view,edit}');

-- ---------------------------------------------------------------------
-- أمان الصفوف (RLS): القراءة بالصلاحية والنطاق؛ الكتابة عبر الدوال فقط
-- ---------------------------------------------------------------------

alter table public.employees               enable row level security;
alter table public.employment_periods      enable row level security;
alter table public.supervisor_assignments  enable row level security;
alter table public.supervisor_transfers    enable row level security;
alter table public.pages                   enable row level security;
alter table public.permission_templates    enable row level security;
alter table public.template_permissions    enable row level security;
alter table public.app_users               enable row level security;
alter table public.user_permission_overrides enable row level security;
alter table public.user_scope_employees    enable row level security;
alter table public.audit_log               enable row level security;
alter table public.settings                enable row level security;
alter table public.months                  enable row level security;

create policy employees_read on public.employees for select to authenticated
  using (app.can_see_employee(id) and (app.has_perm('P03') or app.has_perm('P10') or app.has_perm('P13')
         or app.has_perm('P06') or app.has_perm('P14')));
create policy periods_read on public.employment_periods for select to authenticated
  using (app.has_perm('P03') and app.can_see_employee(employee_id));
create policy sup_read on public.supervisor_assignments for select to authenticated
  using (app.has_perm('P03') and app.can_see_employee(employee_id));
create policy transfers_read on public.supervisor_transfers for select to authenticated
  using (app.has_perm('P03') and app.can_see_employee(employee_id));
create policy pages_read on public.pages for select to authenticated using (true);
create policy templates_read on public.permission_templates for select to authenticated using (app.has_perm('P20'));
create policy template_perms_read on public.template_permissions for select to authenticated using (app.has_perm('P20'));
create policy users_read on public.app_users for select to authenticated
  using (id = auth.uid() or app.has_perm('P20'));
create policy overrides_read on public.user_permission_overrides for select to authenticated
  using (user_id = auth.uid() or app.has_perm('P20'));
create policy scope_read on public.user_scope_employees for select to authenticated
  using (user_id = auth.uid() or app.has_perm('P20'));
create policy audit_read on public.audit_log for select to authenticated using (app.has_perm('P21'));
create policy settings_read on public.settings for select to authenticated using (true);
create policy months_read on public.months for select to authenticated using (true);

select app.apply_grants();

-- >>> 0002_users_settings.sql
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

-- >>> 0003_definitions.sql
-- =====================================================================
-- ماستر — 0003: التعريفات الأساسية
-- العملاء والفروع (CUS-001..003، B037، B055، B065، B066)
-- المنتجات والأسعار والتكلفة والتعبئة ونسب العمولة (PRD-001..008، PRICE-001..003، B019، B056، B057)
-- إدارة الموظفين وفتراتهم والمشرفين (EMP-001..006، B001–B004)
-- الاستيراد بالمعاينة ثم الاعتماد لكل تعريف من صفحته (DATA-001، DATA-009)
-- =====================================================================

-- ---------------------------------------------------------------------
-- أدوات قراءة القيم الواردة من الملفات (يرسلها التطبيق نصوصًا)
-- ---------------------------------------------------------------------

-- تاريخ بصيغة YYYY-MM-DD؛ الفارغ = null؛ غير الصالح يرفع خطأ يلتقطه المستدعي
create or replace function app.to_date(p text) returns date
language plpgsql immutable as $$
begin
  if p is null or trim(p) = '' then return null; end if;
  if trim(p) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'bad date'; end if;
  return trim(p)::date;
end $$;

create or replace function app.is_bad_date(p text) returns boolean
language plpgsql immutable as $$
begin
  perform app.to_date(p);
  return false;
exception when others then
  return true;
end $$;

create or replace function app.is_bad_num(p text) returns boolean
language plpgsql immutable as $$
begin
  if p is null or trim(p) = '' then return false; end if;
  perform trim(p)::numeric;
  return false;
exception when others then
  return true;
end $$;

create or replace function app.to_num(p text) returns numeric
language sql immutable as $$ select nullif(trim(p), '')::numeric $$;

create or replace function app.err(p_row int, p_field text, p_value text, p_message text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('row', p_row, 'field', p_field, 'value', p_value, 'message', p_message)
$$;

-- سجل دفعات استيراد التعريفات
create table public.definition_imports (
  id          bigserial primary key,
  kind        text not null check (kind in ('employees', 'customers', 'products')),
  file_name   text,
  at          timestamptz not null default now(),
  by_user     uuid,
  summary     jsonb not null
);

-- =====================================================================
-- العملاء والفروع
-- =====================================================================

create table public.customers (
  id               bigserial primary key,
  customer_number  text not null unique,           -- نص مع الأصفار البادئة
  name             text not null,
  company_id       text,                           -- يحفظ ويصدّر كما ورد، غير مفعّل (CUS-002)
  grace_days       int check (grace_days >= 0),    -- الفارغ = 30 يومًا (B037)
  lat              numeric,                        -- موقع العميل مستقل عن موقع الفاتورة (B066)
  lng              numeric,
  location_updated_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index customers_name_idx on public.customers using gin (to_tsvector('simple', name));
create index customers_name_trgm_prefix on public.customers (name text_pattern_ops);

-- ارتباط الفرع بالرئيسي عبر الزمن (B055): لا ارتباط = مستقل أو رئيسي
create table public.customer_master_links (
  id           bigserial primary key,
  customer_id  bigint not null references public.customers(id),
  master_id    bigint not null references public.customers(id),
  valid_from   date,                 -- الفارغ = منذ البداية
  valid_to     date,
  created_at   timestamptz not null default now(),
  check (customer_id <> master_id),
  check (valid_to is null or valid_from is null or valid_to >= valid_from),
  exclude using gist (customer_id with =, daterange(valid_from, valid_to, '[]') with &&)
);
create index on public.customer_master_links (master_id);

-- العملاء الذين تعامل معهم كل موظف (تملؤه الحركات) لنطاق رؤية العملاء
create table public.customer_employee_links (
  customer_id  bigint not null references public.customers(id),
  employee_id  bigint not null references public.employees(id),
  primary key (customer_id, employee_id)
);
create index on public.customer_employee_links (employee_id);

create or replace function app.master_of(p_customer bigint, p_date date) returns bigint
language sql stable security definer set search_path = public as $$
  select l.master_id from public.customer_master_links l
   where l.customer_id = p_customer
     and daterange(l.valid_from, l.valid_to, '[]') @> p_date
$$;

create or replace function app.can_see_customer(p_customer bigint) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.scope_is_all()
      or exists (select 1 from public.customer_employee_links l
                  where l.customer_id = p_customer and app.can_see_employee(l.employee_id))
$$;

-- =====================================================================
-- المنتجات
-- =====================================================================

create table public.products (
  id          bigserial primary key,
  code        text not null unique,          -- كود الصنف نصًا
  name        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- سعر البيع والتكلفة للباكيت بتاريخ سريان (PRICE-001..003)
create table public.product_prices (
  id             bigserial primary key,
  product_id     bigint not null references public.products(id),
  kind           text not null check (kind in ('sale', 'cost')),
  price          numeric not null check (price >= 0),
  effective_from date not null,
  recorded_at    timestamptz not null default now(),
  recorded_by    uuid,
  unique (product_id, kind, effective_from)
);

-- عدد الباكيتات في الكرتونة بتاريخ سريان (PRD-007، B057)
create table public.product_packing (
  id                 bigserial primary key,
  product_id         bigint not null references public.products(id),
  packets_per_carton numeric not null check (packets_per_carton > 0),
  effective_from     date not null,
  recorded_at        timestamptz not null default now(),
  recorded_by        uuid,
  unique (product_id, effective_from)
);

-- نسب عمولة الصنف لكل شريحة ودور بتاريخ سريان (PRD-002..004، B019، B020)
-- المندوب بالمئة، والمشرف بالألف. غياب السطر = فارغ (إعداد ناقص عند الحاجة).
create table public.product_commission_rates (
  id             bigserial primary key,
  product_id     bigint not null references public.products(id),
  role           text not null check (role in ('rep', 'supervisor')),
  tier           text not null,
  rate           numeric not null check (rate >= 0),
  effective_from date not null,
  recorded_at    timestamptz not null default now(),
  recorded_by    uuid,
  unique (product_id, role, tier, effective_from)
);

create or replace function app.price_at(p_product bigint, p_kind text, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select price from public.product_prices
   where product_id = p_product and kind = p_kind and effective_from <= p_date
   order by effective_from desc limit 1
$$;

create or replace function app.packing_at(p_product bigint, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select packets_per_carton from public.product_packing
   where product_id = p_product and effective_from <= p_date
   order by effective_from desc limit 1
$$;

create or replace function app.rate_at(p_product bigint, p_role text, p_tier text, p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select rate from public.product_commission_rates
   where product_id = p_product and role = p_role and tier = p_tier and effective_from <= p_date
   order by effective_from desc limit 1
$$;

-- الشرائح الافتراضية في ملف المنتجات بالترتيب من الأعلى (PRD-002)
create or replace function app.default_tiers() returns text[]
language sql immutable as $$ select array['A', 'B', 'C', 'X'] $$;

-- =====================================================================
-- عروض القراءة (تعمل بصلاحيات المستخدم: security_invoker)
-- =====================================================================

create or replace view public.employees_v with (security_invoker = true) as
select e.id, e.emp_number, e.name, e.job_role, e.status, e.status_date,
       (select p.start_date from public.employment_periods p where p.employee_id = e.id order by p.start_date limit 1) as first_join_date,
       (select jsonb_agg(jsonb_build_object('id', p.id, 'start', p.start_date, 'end', p.end_date) order by p.start_date)
          from public.employment_periods p where p.employee_id = e.id) as periods,
       s.supervisor_id, se.emp_number as supervisor_number, se.name as supervisor_name,
       e.created_at, e.updated_at
  from public.employees e
  left join public.supervisor_assignments s
         on s.employee_id = e.id and daterange(s.valid_from, s.valid_to, '[]') @> app.today()
  left join public.employees se on se.id = s.supervisor_id;

create or replace view public.customers_v with (security_invoker = true) as
select c.id, c.customer_number, c.name, c.company_id, c.grace_days,
       coalesce(c.grace_days, 30) as effective_grace_days,
       c.lat, c.lng,
       m.id as master_id, m.customer_number as master_number, m.name as master_name,
       exists (select 1 from public.customer_master_links b
                where b.master_id = c.id and daterange(b.valid_from, b.valid_to, '[]') @> app.today()) as has_branches,
       case when m.id is not null then 'فرع'
            when exists (select 1 from public.customer_master_links b
                          where b.master_id = c.id and daterange(b.valid_from, b.valid_to, '[]') @> app.today()) then 'رئيسي'
            else 'مستقل' end as kind,
       c.created_at, c.updated_at
  from public.customers c
  left join public.customer_master_links l
         on l.customer_id = c.id and daterange(l.valid_from, l.valid_to, '[]') @> app.today()
  left join public.customers m on m.id = l.master_id;

create or replace view public.products_v with (security_invoker = true) as
select p.id, p.code, p.name,
       app.price_at(p.id, 'sale', app.today()) as sale_price,
       case when app.has_perm('P04', 'view_cost') then app.price_at(p.id, 'cost', app.today()) end as cost_price,
       app.packing_at(p.id, app.today()) as packets_per_carton,
       case when app.has_perm('P04', 'view_commission') then
         (select jsonb_object_agg(r.role || '_' || r.tier, r.rate)
            from (select distinct on (role, tier) role, tier, rate from public.product_commission_rates
                   where product_id = p.id and effective_from <= app.today()
                   order by role, tier, effective_from desc) r)
       end as rates,
       p.created_at, p.updated_at
  from public.products p;

-- =====================================================================
-- أمان الصفوف
-- =====================================================================
alter table public.definition_imports        enable row level security;
alter table public.customers                 enable row level security;
alter table public.customer_master_links     enable row level security;
alter table public.customer_employee_links   enable row level security;
alter table public.products                  enable row level security;
alter table public.product_prices            enable row level security;
alter table public.product_packing           enable row level security;
alter table public.product_commission_rates  enable row level security;

create policy def_imports_read on public.definition_imports for select to authenticated
  using ((kind = 'employees' and app.has_perm('P03', 'import'))
      or (kind = 'customers' and app.has_perm('P02', 'import'))
      or (kind = 'products'  and app.has_perm('P04', 'import')));
create policy customers_read on public.customers for select to authenticated
  using ((app.has_perm('P02') or app.has_perm('P06') or app.has_perm('P07') or app.has_perm('P08') or app.has_perm('P16'))
         and app.can_see_customer(id));
create policy cml_read on public.customer_master_links for select to authenticated
  using (app.has_perm('P02') and app.can_see_customer(customer_id));
create policy cel_read on public.customer_employee_links for select to authenticated
  using (app.can_see_employee(employee_id));
create policy products_read on public.products for select to authenticated
  using (app.has_perm('P04') or app.has_perm('P06') or app.has_perm('P10') or app.has_perm('P17b'));
create policy prices_read on public.product_prices for select to authenticated
  using (app.has_perm('P04') and (kind = 'sale' or app.has_perm('P04', 'view_cost')));
create policy packing_read on public.product_packing for select to authenticated using (app.has_perm('P04'));
create policy rates_read on public.product_commission_rates for select to authenticated
  using (app.has_perm('P04', 'view_commission') or app.has_perm('P11'));

-- =====================================================================
-- الموظفون: الإضافة والتعديل والفترات والمشرف
-- =====================================================================

create or replace function app.employee_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(v) - 'created_at' - 'updated_at' from public.employees_v v where v.id = p_id
$$;

-- p: {emp_number, name, job_role, join_date (للجديد), supervisor_id (للجديد، اختياري)}
create or replace function public.save_employee(p_id bigint, p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_id;
  v_before jsonb;
  v_num text := trim(p->>'emp_number');
  v_name text := trim(p->>'name');
begin
  perform app.require_perm('P03', case when p_id is null then 'add' else 'edit' end);
  if coalesce(v_num, '') = '' then perform app.fail('required', 'الرقم الوظيفي مطلوب'); end if;
  if coalesce(v_name, '') = '' then perform app.fail('required', 'اسم الموظف مطلوب'); end if;
  if exists (select 1 from public.employees where emp_number = v_num and id is distinct from p_id) then
    perform app.fail('duplicate', 'الرقم الوظيفي مستخدم لموظف آخر');
  end if;
  if v_id is null then
    if app.to_date(p->>'join_date') is null then perform app.fail('required', 'تاريخ الالتحاق مطلوب'); end if;
    insert into public.employees (emp_number, name, job_role) values (v_num, v_name, nullif(trim(p->>'job_role'), ''))
    returning id into v_id;
    insert into public.employment_periods (employee_id, start_date) values (v_id, app.to_date(p->>'join_date'));
    if nullif(p->>'supervisor_id', '') is not null then
      insert into public.supervisor_assignments (employee_id, supervisor_id, valid_from)
      values (v_id, (p->>'supervisor_id')::bigint, null);
    end if;
  else
    v_before := app.employee_json(v_id);
    update public.employees set emp_number = v_num, name = v_name, job_role = nullif(trim(p->>'job_role'), ''),
           updated_at = now() where id = v_id;
  end if;
  perform app.audit('employees', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, app.employee_json(v_id));
  return v_id;
end $$;

-- إنهاء فترة العمل: آخر يوم عمل مشمول (EMP-003)
create or replace function public.end_employment(p_employee bigint, p_last_day date, p_status text,
                                                 p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_period public.employment_periods;
  v_before jsonb := app.employee_json(p_employee);
begin
  perform app.require_perm('P03', 'edit');
  if p_status not in ('مستقيل', 'موقوف') then perform app.fail('bad_status', 'الحالة يجب أن تكون مستقيل أو موقوف'); end if;
  select * into v_period from public.employment_periods where employee_id = p_employee and end_date is null;
  if not found then perform app.fail('no_open_period', 'لا توجد فترة عمل مفتوحة لهذا الموظف'); end if;
  if p_last_day < v_period.start_date then
    perform app.fail('end_before_start', 'آخر يوم عمل يسبق بداية الفترة');
  end if;
  perform app.guard_dates(array[p_last_day + 1], p_code);
  if app.first_closed_in(p_last_day + 1, app.today()) is not null then
    perform app.guard_dates(array[app.first_closed_in(p_last_day + 1, app.today())], p_code);
  end if;
  update public.employment_periods set end_date = p_last_day where id = v_period.id;
  update public.employees set status = p_status, status_date = p_last_day, updated_at = now() where id = p_employee;
  perform app.audit('employees', p_employee::text, 'end_employment', v_before, app.employee_json(p_employee), p_reason);
end $$;

-- إعادة التنشيط: فترة جديدة من التاريخ المختار (مشمول) دون تداخل (EMP-003/005)
create or replace function public.reactivate_employee(p_employee bigint, p_start date,
                                                      p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb := app.employee_json(p_employee);
begin
  perform app.require_perm('P03', 'edit');
  if exists (select 1 from public.employment_periods where employee_id = p_employee and end_date is null) then
    perform app.fail('already_active', 'للموظف فترة عمل مفتوحة');
  end if;
  if exists (select 1 from public.employment_periods where employee_id = p_employee and end_date >= p_start) then
    perform app.fail('overlap', 'تاريخ العودة يتداخل مع فترة عمل سابقة؛ يجب أن يلي آخر يوم عمل');
  end if;
  perform app.guard_dates(array[p_start], p_code);
  insert into public.employment_periods (employee_id, start_date) values (p_employee, p_start);
  update public.employees set status = 'نشط', status_date = p_start, updated_at = now() where id = p_employee;
  perform app.audit('employees', p_employee::text, 'reactivate', v_before, app.employee_json(p_employee), p_reason);
end $$;

-- تصحيح فترة سابقة (EMP-005): منع النهاية قبل البداية والتداخل، وحماية المقفل
create or replace function public.correct_employment_period(p_period bigint, p_start date, p_end date,
                                                            p_reason text, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v public.employment_periods;
  v_before jsonb;
begin
  perform app.require_perm('P03', 'edit');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب التصحيح مطلوب'); end if;
  select * into v from public.employment_periods where id = p_period;
  if not found then perform app.fail('not_found', 'الفترة غير موجودة'); end if;
  if p_end is not null and p_end < p_start then perform app.fail('end_before_start', 'النهاية تسبق البداية'); end if;
  if exists (select 1 from public.employment_periods o
              where o.employee_id = v.employee_id and o.id <> v.id
                and daterange(o.start_date, o.end_date, '[]') && daterange(p_start, p_end, '[]')) then
    perform app.fail('overlap', 'الفترة المصححة تتداخل مع فترة أخرى للموظف نفسه');
  end if;
  -- كل يوم يتغير وضعه بين الفترتين القديمة والجديدة قد يمس شهرًا مقفلًا
  perform app.guard_dates(array[app.first_closed_in(least(v.start_date, p_start),
                                                    greatest(coalesce(v.end_date, app.today()), coalesce(p_end, app.today())))],
                          p_code);
  v_before := app.employee_json(v.employee_id);
  update public.employment_periods set start_date = p_start, end_date = p_end where id = p_period;
  update public.employees e set
    status = case when exists (select 1 from public.employment_periods where employee_id = e.id and end_date is null)
                  then 'نشط' else e.status end,
    status_date = coalesce((select max(end_date) from public.employment_periods where employee_id = e.id
                             and not exists (select 1 from public.employment_periods x where x.employee_id = e.id and x.end_date is null)),
                           e.status_date),
    updated_at = now()
   where e.id = v.employee_id;
  perform app.audit('employment_periods', p_period::text, 'correct',
                    jsonb_build_object('start', v.start_date, 'end', v.end_date),
                    jsonb_build_object('start', p_start, 'end', p_end), p_reason);
end $$;

-- نقل المندوب لمشرف آخر (B001، EMP-006): الافتراضي إبقاء السابق؛
-- النقل يجعل الحركات من «move_from» تتبع المشرف الجديد.
create or replace function app.apply_supervisor_change(p_employee bigint, p_new_sup bigint, p_effective date,
                                                       p_move_prior boolean, p_move_from date, p_reason text)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_cut date := case when p_move_prior then p_move_from else p_effective end;
  v_cur public.supervisor_assignments;
begin
  if p_new_sup = p_employee then perform app.fail('self_supervisor', 'لا يكون الموظف مشرفًا على نفسه'); end if;
  if p_move_prior and (p_move_from is null or p_move_from > p_effective) then
    perform app.fail('bad_move_range', 'بداية نقل الحركات السابقة يجب أن تسبق تاريخ السريان أو تساويه');
  end if;
  if exists (select 1 from public.supervisor_assignments
              where employee_id = p_employee and valid_from is not null and valid_from > v_cut) then
    perform app.fail('later_assignment', 'توجد تبعية مسجلة بعد هذا التاريخ؛ عدّلها أولًا');
  end if;
  select * into v_cur from public.supervisor_assignments
   where employee_id = p_employee and daterange(valid_from, valid_to, '[]') @> v_cut;
  if found then
    if v_cur.valid_from is not null and v_cur.valid_from >= v_cut then
      -- التبعية الحالية تبدأ في يوم القطع نفسه: تستبدل
      delete from public.supervisor_assignments where id = v_cur.id;
    else
      update public.supervisor_assignments set valid_to = v_cut - 1 where id = v_cur.id;
    end if;
  end if;
  if p_new_sup is not null then
    insert into public.supervisor_assignments (employee_id, supervisor_id, valid_from)
    values (p_employee, p_new_sup, v_cut);
  end if;
  insert into public.supervisor_transfers (employee_id, old_supervisor_id, new_supervisor_id, effective_date,
                                           move_prior, move_from, reason, created_by)
  values (p_employee, v_cur.supervisor_id, p_new_sup, p_effective, coalesce(p_move_prior, false),
          case when p_move_prior then p_move_from end, p_reason, auth.uid());
end $$;

create or replace function public.transfer_supervisor(p_employee bigint, p_new_supervisor bigint, p_effective date,
                                                      p_move_prior boolean default false, p_move_from date default null,
                                                      p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb := app.employee_json(p_employee);
  v_cut date := case when p_move_prior then p_move_from else p_effective end;
begin
  perform app.require_perm('P03', 'transfer');
  if p_effective is null then perform app.fail('required', 'تاريخ السريان مطلوب'); end if;
  perform app.guard_dates(array[app.first_closed_in(v_cut, app.today())], p_code);
  perform app.apply_supervisor_change(p_employee, p_new_supervisor, p_effective, p_move_prior, p_move_from, p_reason);
  perform app.audit('employees', p_employee::text, 'transfer_supervisor', v_before, app.employee_json(p_employee), p_reason);
end $$;

-- =====================================================================
-- استيراد الموظفين (EMP-001، EMP-005، B004)
-- الصفوف: [{row, emp_number, name, job_role, join_date, status, status_date, supervisor_number}]
-- =====================================================================

create or replace function app.employee_import_plan(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb;
  v_errors jsonb := '[]';
  v_new jsonb := '[]';
  v_changed jsonb := '[]';
  v_status jsonb := '[]';
  v_conflicts jsonb := '[]';
  v_sup jsonb := '[]';
  v_unchanged int := 0;
  e public.employees;
  v_row int; v_num text; v_name text; v_role text; v_status_txt text; v_sup_num text;
  v_join date; v_sdate date;
  v_open public.employment_periods;
  v_last_end date; v_first_start date;
  v_cur_sup text;
  v_fields jsonb;
  v_file_nums text[];
begin
  -- تكرار الرقم ببيانات متعارضة داخل الملف
  for r in
    select jsonb_build_object('num', trim(x->>'emp_number'), 'rows', jsonb_agg((x->>'row')::int))
      from jsonb_array_elements(p_rows) x
     where coalesce(trim(x->>'emp_number'), '') <> ''
     group by trim(x->>'emp_number')
    having count(distinct (coalesce(trim(x->>'name'), ''), coalesce(trim(x->>'job_role'), ''), coalesce(x->>'join_date', ''),
                           coalesce(trim(x->>'status'), ''), coalesce(x->>'status_date', ''), coalesce(trim(x->>'supervisor_number'), ''))) > 1
  loop
    v_errors := v_errors || app.err((r->'rows'->>0)::int, 'الرقم الوظيفي', r->>'num',
                                    'الرقم مكرر في الملف ببيانات متعارضة (الصفوف ' || (select string_agg(x, '، ') from jsonb_array_elements_text(r->'rows') x) || ')');
  end loop;

  select array_agg(distinct trim(x->>'emp_number')) into v_file_nums from jsonb_array_elements(p_rows) x;

  for r in select distinct on (trim(x->>'emp_number')) x from jsonb_array_elements(p_rows) x
            order by trim(x->>'emp_number'), (x->>'row')::int
  loop
    v_row := (r->>'row')::int;
    v_num := trim(r->>'emp_number'); v_name := trim(r->>'name'); v_role := nullif(trim(r->>'job_role'), '');
    v_status_txt := coalesce(nullif(trim(r->>'status'), ''), 'نشط');
    v_sup_num := nullif(trim(r->>'supervisor_number'), '');
    if coalesce(v_num, '') = '' then
      v_errors := v_errors || app.err(v_row, 'الرقم الوظيفي', null, 'الرقم الوظيفي مطلوب'); continue;
    end if;
    if coalesce(v_name, '') = '' then
      v_errors := v_errors || app.err(v_row, 'اسم الموظف', null, 'اسم الموظف مطلوب'); continue;
    end if;
    if v_status_txt not in ('نشط', 'مستقيل', 'موقوف') then
      v_errors := v_errors || app.err(v_row, 'الحالة', v_status_txt, 'الحالة غير معروفة؛ المقبول: نشط، مستقيل، موقوف'); continue;
    end if;
    if app.is_bad_date(r->>'join_date') then
      v_errors := v_errors || app.err(v_row, 'تاريخ الالتحاق', r->>'join_date', 'تاريخ غير مقروء'); continue;
    end if;
    if app.is_bad_date(r->>'status_date') then
      v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', r->>'status_date', 'تاريخ غير مقروء'); continue;
    end if;
    v_join := app.to_date(r->>'join_date'); v_sdate := app.to_date(r->>'status_date');
    if v_sup_num = v_num then
      v_errors := v_errors || app.err(v_row, 'معرف المشرف', v_sup_num, 'لا يكون الموظف مشرفًا على نفسه'); continue;
    end if;
    if v_sup_num is not null and not exists (select 1 from public.employees where emp_number = v_sup_num)
       and not (v_sup_num = any (v_file_nums)) then
      v_errors := v_errors || app.err(v_row, 'معرف المشرف', v_sup_num, 'المشرف غير معرّف في النظام ولا في الملف'); continue;
    end if;

    select * into e from public.employees where emp_number = v_num;
    if not found then
      if v_join is null then
        v_errors := v_errors || app.err(v_row, 'تاريخ الالتحاق', null, 'تاريخ الالتحاق مطلوب للموظف الجديد'); continue;
      end if;
      if v_status_txt <> 'نشط' and v_sdate is null then
        v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', null, 'آخر يوم عمل مطلوب لحالة ' || v_status_txt); continue;
      end if;
      if v_status_txt <> 'نشط' and v_sdate < v_join then
        v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', r->>'status_date', 'آخر يوم عمل يسبق تاريخ الالتحاق'); continue;
      end if;
      v_new := v_new || jsonb_build_object('row', v_row, 'emp_number', v_num, 'name', v_name, 'job_role', v_role,
                                           'join_date', v_join, 'status', v_status_txt, 'status_date', v_sdate,
                                           'supervisor_number', v_sup_num);
      continue;
    end if;

    -- موظف موجود
    v_fields := '{}';
    if e.name is distinct from v_name then v_fields := v_fields || jsonb_build_object('name', jsonb_build_array(e.name, v_name)); end if;
    if e.job_role is distinct from v_role then v_fields := v_fields || jsonb_build_object('job_role', jsonb_build_array(e.job_role, v_role)); end if;
    if v_fields <> '{}' then
      v_changed := v_changed || jsonb_build_object('row', v_row, 'emp_number', v_num, 'fields', v_fields);
    end if;

    select * into v_open from public.employment_periods where employee_id = e.id and end_date is null;
    select max(end_date), min(start_date) into v_last_end, v_first_start from public.employment_periods where employee_id = e.id;
    if v_join is not null and v_first_start is not null and v_join <> v_first_start then
      v_conflicts := v_conflicts || jsonb_build_object('row', v_row, 'emp_number', v_num,
        'message', 'تاريخ الالتحاق في الملف ' || to_char(v_join, 'FMDD/FMMM/YYYY') || ' يختلف عن المحفوظ '
                   || to_char(v_first_start, 'FMDD/FMMM/YYYY') || '؛ يُصحَّح من ملف الموظف ولا يُستبدل تلقائيًا');
    end if;
    if v_open.id is not null and v_status_txt <> 'نشط' then
      if v_sdate is null then
        v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', null, 'آخر يوم عمل مطلوب لحالة ' || v_status_txt);
      elsif v_sdate < v_open.start_date then
        v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', r->>'status_date', 'آخر يوم عمل يسبق بداية فترة العمل المفتوحة');
      else
        v_status := v_status || jsonb_build_object('row', v_row, 'emp_number', v_num, 'kind', 'end',
                                                   'status', v_status_txt, 'date', v_sdate);
      end if;
    elsif v_open.id is null and v_status_txt = 'نشط' then
      if v_sdate is null then
        v_errors := v_errors || app.err(v_row, 'تاريخ الحالة الفعلي', null, 'تاريخ العودة مطلوب لإعادة التنشيط');
      elsif v_sdate <= v_last_end then
        v_conflicts := v_conflicts || jsonb_build_object('row', v_row, 'emp_number', v_num,
          'message', 'تاريخ العودة يتداخل مع فترة سابقة تنتهي ' || to_char(v_last_end, 'FMDD/FMMM/YYYY'));
      else
        v_status := v_status || jsonb_build_object('row', v_row, 'emp_number', v_num, 'kind', 'reactivate',
                                                   'status', 'نشط', 'date', v_sdate);
      end if;
    elsif v_open.id is null and v_status_txt <> 'نشط' and v_sdate is distinct from v_last_end then
      v_conflicts := v_conflicts || jsonb_build_object('row', v_row, 'emp_number', v_num,
        'message', 'آخر يوم عمل في الملف ' || coalesce(to_char(v_sdate, 'FMDD/FMMM/YYYY'), 'فارغ') || ' يختلف عن المحفوظ '
                   || to_char(v_last_end, 'FMDD/FMMM/YYYY') || '؛ يُصحَّح من ملف الموظف');
    elsif v_status_txt <> e.status and v_open.id is null then
      v_status := v_status || jsonb_build_object('row', v_row, 'emp_number', v_num, 'kind', 'status', 'status', v_status_txt, 'date', v_sdate);
    end if;

    select se.emp_number into v_cur_sup from public.supervisor_assignments s join public.employees se on se.id = s.supervisor_id
     where s.employee_id = e.id and daterange(s.valid_from, s.valid_to, '[]') @> app.today();
    if v_sup_num is not null and v_sup_num is distinct from v_cur_sup then
      v_sup := v_sup || jsonb_build_object('row', v_row, 'emp_number', v_num, 'name', v_name,
                                           'current', v_cur_sup, 'new', v_sup_num);
    end if;

    if v_fields = '{}' and v_sup_num is not distinct from coalesce(v_cur_sup, v_sup_num)
       and not exists (select 1 from jsonb_array_elements(v_status) s where s->>'emp_number' = v_num)
       and not exists (select 1 from jsonb_array_elements(v_sup) s where s->>'emp_number' = v_num) then
      v_unchanged := v_unchanged + 1;
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'status_changes', v_status,
                            'supervisor_changes', v_sup, 'conflicts', v_conflicts, 'errors', v_errors,
                            'unchanged', v_unchanged,
                            'counts', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', jsonb_array_length(v_new),
                                                         'changed', jsonb_array_length(v_changed),
                                                         'status_changes', jsonb_array_length(v_status),
                                                         'supervisor_changes', jsonb_array_length(v_sup),
                                                         'conflicts', jsonb_array_length(v_conflicts),
                                                         'errors', jsonb_array_length(v_errors), 'unchanged', v_unchanged));
end $$;

create or replace function public.preview_employee_import(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_perm('P03', 'import');
  return app.employee_import_plan(p_rows);
end $$;

-- p_decisions: {"supervisor_effective": {"<num>": "YYYY-MM-DD"}, "move_prior_from": {"<num>": "YYYY-MM-DD"}}
create or replace function public.commit_employee_import(p_rows jsonb, p_decisions jsonb, p_file_name text,
                                                         p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb;
  x jsonb;
  v_id bigint;
  v_eff date;
  v_from date;
begin
  perform app.require_perm('P03', 'import');
  v_plan := app.employee_import_plan(p_rows);
  if jsonb_array_length(v_plan->'errors') > 0 then
    perform app.fail('import_errors', 'في الملف أخطاء تمنع الاعتماد؛ صحّحها ثم أعد الرفع');
  end if;

  -- الجدد أولًا (قد يكون بعضهم مشرفين لغيرهم)
  for x in select * from jsonb_array_elements(v_plan->'new') loop
    insert into public.employees (emp_number, name, job_role, status, status_date)
    values (x->>'emp_number', x->>'name', x->>'job_role', x->>'status', (x->>'status_date')::date)
    returning id into v_id;
    insert into public.employment_periods (employee_id, start_date, end_date)
    values (v_id, (x->>'join_date')::date, case when x->>'status' <> 'نشط' then (x->>'status_date')::date end);
    perform app.audit('employees', v_id::text, 'import_create', null, x);
  end loop;
  for x in select * from jsonb_array_elements(v_plan->'new') where value->>'supervisor_number' is not null loop
    insert into public.supervisor_assignments (employee_id, supervisor_id, valid_from)
    select e.id, s.id, null from public.employees e, public.employees s
     where e.emp_number = x->>'emp_number' and s.emp_number = x->>'supervisor_number';
  end loop;

  for x in select * from jsonb_array_elements(v_plan->'changed') loop
    select id into v_id from public.employees where emp_number = x->>'emp_number';
    update public.employees set
      name = coalesce(x->'fields'->'name'->>1, name),
      job_role = case when x->'fields' ? 'job_role' then x->'fields'->'job_role'->>1 else job_role end,
      updated_at = now()
     where id = v_id;
    perform app.audit('employees', v_id::text, 'import_update', null, x->'fields');
  end loop;

  for x in select * from jsonb_array_elements(v_plan->'status_changes') loop
    select id into v_id from public.employees where emp_number = x->>'emp_number';
    if x->>'kind' = 'end' then
      perform app.guard_dates(array[app.first_closed_in((x->>'date')::date + 1, app.today())], p_code);
      update public.employment_periods set end_date = (x->>'date')::date where employee_id = v_id and end_date is null;
      update public.employees set status = x->>'status', status_date = (x->>'date')::date, updated_at = now() where id = v_id;
    elsif x->>'kind' = 'reactivate' then
      perform app.guard_dates(array[(x->>'date')::date], p_code);
      insert into public.employment_periods (employee_id, start_date) values (v_id, (x->>'date')::date);
      update public.employees set status = 'نشط', status_date = (x->>'date')::date, updated_at = now() where id = v_id;
    else
      update public.employees set status = x->>'status', updated_at = now() where id = v_id;
    end if;
    perform app.audit('employees', v_id::text, 'import_status', null, x);
  end loop;

  -- تغيير المشرف يتطلب تاريخ سريان يحدده المستخدم (B004)
  for x in select * from jsonb_array_elements(v_plan->'supervisor_changes') loop
    v_eff := app.to_date(p_decisions->'supervisor_effective'->>(x->>'emp_number'));
    if v_eff is null then
      perform app.fail('effective_required', 'تاريخ سريان تغيير المشرف مطلوب للموظف ' || (x->>'emp_number'));
    end if;
    v_from := app.to_date(p_decisions->'move_prior_from'->>(x->>'emp_number'));
    select id into v_id from public.employees where emp_number = x->>'emp_number';
    perform app.guard_dates(array[app.first_closed_in(coalesce(v_from, v_eff), app.today())], p_code);
    perform app.apply_supervisor_change(v_id, (select id from public.employees where emp_number = x->>'new'),
                                        v_eff, v_from is not null, v_from, 'استيراد ملف الموظفين');
    perform app.audit('employees', v_id::text, 'import_supervisor', jsonb_build_object('supervisor', x->>'current'),
                      jsonb_build_object('supervisor', x->>'new', 'effective', v_eff, 'move_from', v_from));
  end loop;

  insert into public.definition_imports (kind, file_name, by_user, summary)
  values ('employees', p_file_name, auth.uid(), v_plan->'counts');
  return v_plan->'counts';
end $$;

-- =====================================================================
-- العملاء: الإضافة والتعديل وتغيير الرئيسي والاستيراد
-- =====================================================================

create or replace function app.customer_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(v) - 'created_at' - 'updated_at' - 'has_branches' from public.customers_v v where v.id = p_id
$$;

-- p: {customer_number, name, company_id, grace_days, master_number (للجديد فقط)}
create or replace function public.save_customer(p_id bigint, p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_id;
  v_before jsonb;
  v_num text := trim(p->>'customer_number');
  v_name text := trim(p->>'name');
  v_grace text := nullif(trim(p->>'grace_days'), '');
  v_master bigint;
begin
  perform app.require_perm('P02', case when p_id is null then 'add' else 'edit' end);
  if coalesce(v_num, '') = '' then perform app.fail('required', 'رقم العميل مطلوب'); end if;
  if coalesce(v_name, '') = '' then perform app.fail('required', 'اسم العميل مطلوب'); end if;
  if v_grace is not null and v_grace !~ '^\d+$' then
    perform app.fail('bad_grace', 'فترة السماح عدد أيام صحيح غير سالب، أو فارغة (30 يومًا)');
  end if;
  if exists (select 1 from public.customers where customer_number = v_num and id is distinct from p_id) then
    perform app.fail('duplicate', 'رقم العميل مستخدم لعميل آخر');
  end if;
  if v_id is null then
    insert into public.customers (customer_number, name, company_id, grace_days)
    values (v_num, v_name, nullif(trim(p->>'company_id'), ''), v_grace::int) returning id into v_id;
    if nullif(trim(p->>'master_number'), '') is not null and trim(p->>'master_number') <> v_num then
      select id into v_master from public.customers where customer_number = trim(p->>'master_number');
      if v_master is null then perform app.fail('unknown_master', 'رقم العميل الرئيسي غير معرّف'); end if;
      if app.master_of(v_master, app.today()) is not null then
        perform app.fail('master_is_branch', 'العميل الرئيسي المحدد فرع لعميل آخر');
      end if;
      insert into public.customer_master_links (customer_id, master_id, valid_from) values (v_id, v_master, null);
    end if;
  else
    v_before := app.customer_json(v_id);
    update public.customers set customer_number = v_num, name = v_name,
           company_id = nullif(trim(p->>'company_id'), ''), grace_days = v_grace::int, updated_at = now()
     where id = v_id;
  end if;
  perform app.audit('customers', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, app.customer_json(v_id));
  return v_id;
end $$;

-- تغيير ارتباط الفرع بالرئيسي بتاريخ سريان (B055). p_master_number فارغ = يصبح مستقلًا.
create or replace function app.apply_master_change(p_customer bigint, p_master bigint, p_effective date)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_cur public.customer_master_links;
begin
  if p_master = p_customer then perform app.fail('self_master', 'لا يكون العميل رئيسيًا لنفسه'); end if;
  if p_master is not null and app.master_of(p_master, p_effective) is not null then
    perform app.fail('master_is_branch', 'العميل الرئيسي المحدد فرع لعميل آخر');
  end if;
  if p_master is not null and exists (select 1 from public.customer_master_links
                                       where master_id = p_customer and daterange(valid_from, valid_to, '[]') @> p_effective) then
    perform app.fail('customer_has_branches', 'العميل رئيسي لفروع؛ لا يصبح فرعًا قبل فك فروعه');
  end if;
  if exists (select 1 from public.customer_master_links
              where customer_id = p_customer and valid_from is not null and valid_from > p_effective) then
    perform app.fail('later_link', 'يوجد ارتباط مسجل بعد هذا التاريخ؛ عدّله أولًا');
  end if;
  select * into v_cur from public.customer_master_links
   where customer_id = p_customer and daterange(valid_from, valid_to, '[]') @> p_effective;
  if found then
    if v_cur.valid_from is not null and v_cur.valid_from >= p_effective then
      delete from public.customer_master_links where id = v_cur.id;
    else
      update public.customer_master_links set valid_to = p_effective - 1 where id = v_cur.id;
    end if;
  end if;
  if p_master is not null then
    insert into public.customer_master_links (customer_id, master_id, valid_from) values (p_customer, p_master, p_effective);
  end if;
end $$;

create or replace function public.change_customer_master(p_customer bigint, p_master_number text, p_effective date,
                                                         p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb := app.customer_json(p_customer);
  v_master bigint;
begin
  perform app.require_perm('P02', 'edit');
  if p_effective is null then perform app.fail('required', 'تاريخ السريان مطلوب'); end if;
  if nullif(trim(p_master_number), '') is not null then
    select id into v_master from public.customers where customer_number = trim(p_master_number);
    if v_master is null then perform app.fail('unknown_master', 'رقم العميل الرئيسي غير معرّف'); end if;
  end if;
  perform app.guard_dates(array[app.first_closed_in(p_effective, app.today())], p_code);
  perform app.apply_master_change(p_customer, v_master, p_effective);
  perform app.audit('customers', p_customer::text, 'change_master', v_before, app.customer_json(p_customer), p_reason);
end $$;

-- إزالة الموقع صراحة أو تعيينه (B065)
create or replace function public.set_customer_location(p_customer bigint, p_lat numeric, p_lng numeric)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb;
begin
  if not (app.has_perm('P16', 'edit') or app.has_perm('P02', 'edit')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  if (p_lat is null) <> (p_lng is null) then perform app.fail('bad_location', 'خط العرض وخط الطول معًا أو لا شيء'); end if;
  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then
    perform app.fail('bad_location', 'إحداثيات خارج النطاق');
  end if;
  select jsonb_build_object('lat', lat, 'lng', lng) into v_before from public.customers where id = p_customer;
  update public.customers set lat = p_lat, lng = p_lng, location_updated_at = now(), updated_at = now() where id = p_customer;
  perform app.audit('customers', p_customer::text, case when p_lat is null then 'remove_location' else 'set_location' end,
                    v_before, jsonb_build_object('lat', p_lat, 'lng', p_lng));
end $$;

-- الصفوف: [{row, master_name, master_number, name, customer_number, company_id, grace_days}]
create or replace function app.customer_import_plan(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb;
  v_errors jsonb := '[]'; v_warnings jsonb := '[]';
  v_new jsonb := '[]'; v_changed jsonb := '[]'; v_links jsonb := '[]';
  v_unchanged int := 0;
  c public.customers;
  v_row int; v_num text; v_name text; v_mnum text; v_grace text; v_comp text;
  v_fields jsonb; v_cur_master text; v_master_name text; v_master_file_name text;
  v_file jsonb := '{}';   -- رقم -> صف الملف
begin
  for r in
    select jsonb_build_object('num', trim(x->>'customer_number'), 'rows', jsonb_agg((x->>'row')::int))
      from jsonb_array_elements(p_rows) x
     where coalesce(trim(x->>'customer_number'), '') <> ''
     group by trim(x->>'customer_number')
    having count(distinct (coalesce(trim(x->>'name'), ''), coalesce(trim(x->>'master_number'), ''),
                           coalesce(trim(x->>'company_id'), ''), coalesce(trim(x->>'grace_days'), ''))) > 1
  loop
    v_errors := v_errors || app.err((r->'rows'->>0)::int, 'CustomerNumber', r->>'num', 'رقم العميل مكرر في الملف ببيانات متعارضة');
  end loop;

  select coalesce(jsonb_object_agg(k, v), '{}') into v_file from (
    select distinct on (trim(x->>'customer_number')) trim(x->>'customer_number') k, x v
      from jsonb_array_elements(p_rows) x where coalesce(trim(x->>'customer_number'), '') <> ''
     order by trim(x->>'customer_number'), (x->>'row')::int) s;

  for r in select value from jsonb_each(v_file) loop
    v_row := (r->>'row')::int;
    v_num := trim(r->>'customer_number'); v_name := trim(r->>'name');
    v_mnum := nullif(trim(r->>'master_number'), '');
    if v_mnum = v_num then v_mnum := null; end if;            -- الرئيسي = نفسه: ليس فرعًا
    v_grace := nullif(trim(r->>'grace_days'), '');
    v_comp := nullif(trim(r->>'company_id'), '');
    if coalesce(v_name, '') = '' then
      v_errors := v_errors || app.err(v_row, 'CustomerName', null, 'اسم العميل مطلوب'); continue;
    end if;
    if v_grace is not null and v_grace !~ '^\d+(\.0+)?$' then
      v_errors := v_errors || app.err(v_row, 'فترة السماح', v_grace, 'فترة السماح عدد أيام صحيح غير سالب، أو فارغة (30 يومًا)'); continue;
    end if;
    v_grace := case when v_grace is null then null else (v_grace::numeric)::int::text end;
    if v_mnum is not null then
      if not (v_file ? v_mnum) and not exists (select 1 from public.customers where customer_number = v_mnum) then
        v_errors := v_errors || app.err(v_row, 'MasterCustomerNumber', v_mnum, 'العميل الرئيسي غير معرّف في النظام ولا في الملف'); continue;
      end if;
      if v_file ? v_mnum and nullif(trim(v_file->v_mnum->>'master_number'), '') is not null
         and trim(v_file->v_mnum->>'master_number') <> v_mnum then
        v_errors := v_errors || app.err(v_row, 'MasterCustomerNumber', v_mnum, 'العميل الرئيسي المحدد فرع لعميل آخر'); continue;
      end if;
      -- CUS-003: اختلاف اسم الرئيسي يعتمد اسم سجله، مع تنبيه
      v_master_file_name := nullif(trim(r->>'master_name'), '');
      v_master_name := coalesce(trim(v_file->v_mnum->>'name'), (select name from public.customers where customer_number = v_mnum));
      if v_master_file_name is not null and v_master_file_name is distinct from v_master_name then
        v_warnings := v_warnings || app.err(v_row, 'MasterCustomerName', v_master_file_name,
                                            'اسم الرئيسي يختلف عن اسمه في سجله «' || v_master_name || '»؛ يُعتمد اسم السجل');
      end if;
    end if;

    select * into c from public.customers where customer_number = v_num;
    if not found then
      v_new := v_new || jsonb_build_object('row', v_row, 'customer_number', v_num, 'name', v_name, 'company_id', v_comp,
                                           'grace_days', v_grace, 'master_number', v_mnum);
      continue;
    end if;
    v_fields := '{}';
    if c.name is distinct from v_name then v_fields := v_fields || jsonb_build_object('name', jsonb_build_array(c.name, v_name)); end if;
    if c.company_id is distinct from v_comp then v_fields := v_fields || jsonb_build_object('company_id', jsonb_build_array(c.company_id, v_comp)); end if;
    if c.grace_days::text is distinct from v_grace then
      v_fields := v_fields || jsonb_build_object('grace_days', jsonb_build_array(c.grace_days, v_grace));
    end if;
    if v_fields <> '{}' then
      v_changed := v_changed || jsonb_build_object('row', v_row, 'customer_number', v_num, 'fields', v_fields);
    end if;
    select m.customer_number into v_cur_master from public.customers m where m.id = app.master_of(c.id, app.today());
    if v_cur_master is distinct from v_mnum then
      v_links := v_links || jsonb_build_object('row', v_row, 'customer_number', v_num, 'name', v_name,
                                               'current', v_cur_master, 'new', v_mnum);
    end if;
    if v_fields = '{}' and v_cur_master is not distinct from v_mnum then v_unchanged := v_unchanged + 1; end if;
  end loop;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'link_changes', v_links,
                            'warnings', v_warnings, 'errors', v_errors, 'unchanged', v_unchanged,
                            'counts', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', jsonb_array_length(v_new),
                                                         'changed', jsonb_array_length(v_changed),
                                                         'link_changes', jsonb_array_length(v_links),
                                                         'warnings', jsonb_array_length(v_warnings),
                                                         'errors', jsonb_array_length(v_errors), 'unchanged', v_unchanged));
end $$;

create or replace function public.preview_customer_import(p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_perm('P02', 'import');
  return app.customer_import_plan(p_rows);
end $$;

-- p_decisions: {"link_effective": {"<num>": "YYYY-MM-DD"}}
create or replace function public.commit_customer_import(p_rows jsonb, p_decisions jsonb, p_file_name text,
                                                         p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; x jsonb; v_id bigint; v_eff date;
begin
  perform app.require_perm('P02', 'import');
  v_plan := app.customer_import_plan(p_rows);
  if jsonb_array_length(v_plan->'errors') > 0 then
    perform app.fail('import_errors', 'في الملف أخطاء تمنع الاعتماد؛ صحّحها ثم أعد الرفع');
  end if;
  for x in select * from jsonb_array_elements(v_plan->'new') loop
    insert into public.customers (customer_number, name, company_id, grace_days)
    values (x->>'customer_number', x->>'name', x->>'company_id', (x->>'grace_days')::int);
  end loop;
  -- روابط الجدد منذ البداية (بعد إضافة الجميع لأن الرئيسي قد يكون جديدًا)
  for x in select * from jsonb_array_elements(v_plan->'new') where value->>'master_number' is not null loop
    insert into public.customer_master_links (customer_id, master_id, valid_from)
    select c.id, m.id, null from public.customers c, public.customers m
     where c.customer_number = x->>'customer_number' and m.customer_number = x->>'master_number';
  end loop;
  for x in select * from jsonb_array_elements(v_plan->'changed') loop
    update public.customers set
      name = case when x->'fields' ? 'name' then x->'fields'->'name'->>1 else name end,
      company_id = case when x->'fields' ? 'company_id' then x->'fields'->'company_id'->>1 else company_id end,
      grace_days = case when x->'fields' ? 'grace_days' then (x->'fields'->'grace_days'->>1)::int else grace_days end,
      updated_at = now()
     where customer_number = x->>'customer_number' returning id into v_id;
    perform app.audit('customers', v_id::text, 'import_update', null, x->'fields');
  end loop;
  for x in select * from jsonb_array_elements(v_plan->'link_changes') loop
    v_eff := app.to_date(p_decisions->'link_effective'->>(x->>'customer_number'));
    if v_eff is null then
      perform app.fail('effective_required', 'تاريخ سريان تغيير الرئيسي مطلوب للعميل ' || (x->>'customer_number'));
    end if;
    perform app.guard_dates(array[app.first_closed_in(v_eff, app.today())], p_code);
    select id into v_id from public.customers where customer_number = x->>'customer_number';
    perform app.apply_master_change(v_id, (select id from public.customers where customer_number = x->>'new'), v_eff);
    perform app.audit('customers', v_id::text, 'import_master', jsonb_build_object('master', x->>'current'),
                      jsonb_build_object('master', x->>'new', 'effective', v_eff));
  end loop;
  insert into public.definition_imports (kind, file_name, by_user, summary)
  values ('customers', p_file_name, auth.uid(), v_plan->'counts');
  return v_plan->'counts';
end $$;

-- =====================================================================
-- المنتجات: الإضافة والتعديل والقيم المؤرخة والاستيراد
-- =====================================================================

create or replace function public.save_product(p_id bigint, p_code text, p_name text) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_id;
  v_before jsonb;
begin
  perform app.require_perm('P04', case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p_code), '') = '' or coalesce(trim(p_name), '') = '' then
    perform app.fail('required', 'كود الصنف واسمه مطلوبان');
  end if;
  if exists (select 1 from public.products where code = trim(p_code) and id is distinct from p_id) then
    perform app.fail('duplicate', 'كود الصنف مستخدم لصنف آخر');
  end if;
  if v_id is null then
    insert into public.products (code, name) values (trim(p_code), trim(p_name)) returning id into v_id;
  else
    select jsonb_build_object('code', code, 'name', name) into v_before from public.products where id = v_id;
    update public.products set code = trim(p_code), name = trim(p_name), updated_at = now() where id = v_id;
  end if;
  perform app.audit('products', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, jsonb_build_object('code', trim(p_code), 'name', trim(p_name)));
  return v_id;
end $$;

-- تعيين قيمة مؤرخة: kind = sale | cost | packing | rep_<tier> | supervisor_<tier>
-- قيمة مختلفة في التاريخ نفسه تُحفظ كتصحيح لذلك التاريخ (PRICE-002)
create or replace function app.set_product_value(p_product bigint, p_kind text, p_value numeric, p_date date)
returns text language plpgsql security definer set search_path = public, app as $$
declare
  v_old numeric;
  v_role text; v_tier text;
begin
  if p_value is null then return 'skip'; end if;
  if p_kind in ('sale', 'cost') then
    v_old := app.price_at(p_product, p_kind, p_date);
    if v_old = p_value then return 'same'; end if;
    insert into public.product_prices (product_id, kind, price, effective_from, recorded_by)
    values (p_product, p_kind, p_value, p_date, auth.uid())
    on conflict (product_id, kind, effective_from) do update set price = excluded.price, recorded_at = now(), recorded_by = auth.uid();
  elsif p_kind = 'packing' then
    v_old := app.packing_at(p_product, p_date);
    if v_old = p_value then return 'same'; end if;
    insert into public.product_packing (product_id, packets_per_carton, effective_from, recorded_by)
    values (p_product, p_value, p_date, auth.uid())
    on conflict (product_id, effective_from) do update set packets_per_carton = excluded.packets_per_carton, recorded_at = now(), recorded_by = auth.uid();
  else
    v_role := split_part(p_kind, '_', 1); v_tier := split_part(p_kind, '_', 2);
    if v_role not in ('rep', 'supervisor') or v_tier = '' then perform app.fail('bad_kind', 'نوع قيمة غير معروف'); end if;
    v_old := app.rate_at(p_product, v_role, v_tier, p_date);
    if v_old = p_value then return 'same'; end if;
    insert into public.product_commission_rates (product_id, role, tier, rate, effective_from, recorded_by)
    values (p_product, v_role, v_tier, p_value, p_date, auth.uid())
    on conflict (product_id, role, tier, effective_from) do update set rate = excluded.rate, recorded_at = now(), recorded_by = auth.uid();
  end if;
  return 'set';
end $$;

create or replace function app.kind_perm(p_kind text) returns text
language sql immutable as $$
  select case when p_kind = 'cost' then 'view_cost' when p_kind in ('sale', 'packing') then 'edit' else 'view_commission' end
$$;

create or replace function public.set_product_value(p_product bigint, p_kind text, p_value numeric, p_date date,
                                                    p_reason text default null, p_code text default null)
returns text language plpgsql security definer set search_path = public, app as $$
declare
  v_res text;
  v_old numeric;
begin
  perform app.require_perm('P04', 'edit');
  perform app.require_perm('P04', app.kind_perm(p_kind));
  if p_date is null then perform app.fail('required', 'تاريخ السريان مطلوب'); end if;
  if p_value is null or p_value < 0 or (p_kind = 'packing' and p_value <= 0) then
    perform app.fail('bad_value', case when p_kind = 'packing' then 'عدد الباكيتات في الكرتونة يجب أن يكون أكبر من صفر'
                                       else 'القيمة يجب ألا تكون سالبة' end);
  end if;
  perform app.guard_dates(array[app.first_closed_in(p_date, app.today())], p_code);
  v_old := case when p_kind in ('sale', 'cost') then app.price_at(p_product, p_kind, p_date)
                when p_kind = 'packing' then app.packing_at(p_product, p_date)
                else app.rate_at(p_product, split_part(p_kind, '_', 1), split_part(p_kind, '_', 2), p_date) end;
  v_res := app.set_product_value(p_product, p_kind, p_value, p_date);
  if v_res = 'set' then
    perform app.audit('products', p_product::text, 'set_' || p_kind,
                      jsonb_build_object('value', v_old, 'date', p_date), jsonb_build_object('value', p_value, 'date', p_date), p_reason);
  end if;
  return v_res;
end $$;

-- حذف قيمة مؤرخة صراحة (الفراغ لا يمحو دون إجراء صريح)
create or replace function public.remove_product_value(p_product bigint, p_kind text, p_date date,
                                                       p_reason text, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  n int;
begin
  perform app.require_perm('P04', 'edit');
  perform app.require_perm('P04', app.kind_perm(p_kind));
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  perform app.guard_dates(array[app.first_closed_in(p_date, app.today())], p_code);
  if p_kind in ('sale', 'cost') then
    delete from public.product_prices where product_id = p_product and kind = p_kind and effective_from = p_date;
  elsif p_kind = 'packing' then
    delete from public.product_packing where product_id = p_product and effective_from = p_date;
  else
    delete from public.product_commission_rates
     where product_id = p_product and role = split_part(p_kind, '_', 1) and tier = split_part(p_kind, '_', 2) and effective_from = p_date;
  end if;
  get diagnostics n = row_count;
  if n = 0 then perform app.fail('not_found', 'لا توجد قيمة بهذا التاريخ'); end if;
  perform app.audit('products', p_product::text, 'remove_' || p_kind, jsonb_build_object('date', p_date), null, p_reason);
end $$;

-- الصفوف: [{row, code, name, sale, cost, packing, rep_A, rep_B, rep_C, rep_X, supervisor_A, ...}]
-- p_dates: {"sale": d, "cost": d, "packing": d, "rates": d}
create or replace function app.product_import_plan(p_rows jsonb, p_dates jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb;
  v_errors jsonb := '[]'; v_new jsonb := '[]'; v_changed jsonb := '[]';
  v_unchanged int := 0; v_needs jsonb := '[]';
  p public.products;
  v_row int; v_code text; v_name text;
  v_kinds text[] := array['sale', 'cost', 'packing'];
  k text; v_val text; v_num numeric; v_old numeric; v_date date;
  v_fields jsonb; v_values jsonb;
  t text;
begin
  foreach t in array app.default_tiers() loop
    v_kinds := v_kinds || ('rep_' || t) || ('supervisor_' || t);
  end loop;

  for r in
    select jsonb_build_object('code', trim(x->>'code'), 'rows', jsonb_agg((x->>'row')::int))
      from jsonb_array_elements(p_rows) x where coalesce(trim(x->>'code'), '') <> ''
     group by trim(x->>'code') having count(distinct (x - 'row')) > 1
  loop
    v_errors := v_errors || app.err((r->'rows'->>0)::int, 'كود الصنف', r->>'code', 'كود الصنف مكرر في الملف ببيانات متعارضة');
  end loop;

  for r in select distinct on (trim(x->>'code')) x from jsonb_array_elements(p_rows) x
            order by trim(x->>'code'), (x->>'row')::int
  loop
    v_row := (r->>'row')::int; v_code := trim(r->>'code'); v_name := trim(r->>'name');
    if coalesce(v_code, '') = '' then v_errors := v_errors || app.err(v_row, 'كود الصنف', null, 'كود الصنف مطلوب'); continue; end if;
    v_values := '{}';
    foreach k in array v_kinds loop
      v_val := nullif(trim(r->>k), '');
      if app.is_bad_num(v_val) then
        v_errors := v_errors || app.err(v_row, k, v_val, 'قيمة غير رقمية'); v_values := null; exit;
      end if;
      v_num := app.to_num(v_val);
      if v_num is not null and (v_num < 0 or (k = 'packing' and v_num <= 0)) then
        v_errors := v_errors || app.err(v_row, k, v_val,
                                        case when k = 'packing' then 'عدد الباكيتات في الكرتونة يجب أن يكون أكبر من صفر' else 'قيمة سالبة' end);
        v_values := null; exit;
      end if;
      if v_num is not null then v_values := v_values || jsonb_build_object(k, v_num); end if;
    end loop;
    if v_values is null then continue; end if;

    select * into p from public.products where code = v_code;
    if not found then
      if coalesce(v_name, '') = '' then v_errors := v_errors || app.err(v_row, 'اسم الصنف', null, 'اسم الصنف مطلوب'); continue; end if;
      v_new := v_new || jsonb_build_object('row', v_row, 'code', v_code, 'name', v_name, 'values', v_values);
      continue;
    end if;
    v_fields := '{}';
    if v_name is not null and v_name <> p.name then
      v_fields := v_fields || jsonb_build_object('name', jsonb_build_array(p.name, v_name));
    end if;
    for k in select jsonb_object_keys(v_values) loop
      v_date := app.to_date(p_dates->>(case when k in ('sale', 'cost', 'packing') then k else 'rates' end));
      v_old := case when k in ('sale', 'cost') then app.price_at(p.id, k, coalesce(v_date, app.today()))
                    when k = 'packing' then app.packing_at(p.id, coalesce(v_date, app.today()))
                    else app.rate_at(p.id, split_part(k, '_', 1), split_part(k, '_', 2), coalesce(v_date, app.today())) end;
      if v_old is distinct from (v_values->>k)::numeric then
        v_fields := v_fields || jsonb_build_object(k, jsonb_build_array(v_old, (v_values->>k)::numeric));
      end if;
    end loop;
    if v_fields = '{}' then v_unchanged := v_unchanged + 1;
    else v_changed := v_changed || jsonb_build_object('row', v_row, 'code', v_code, 'fields', v_fields);
    end if;
  end loop;

  -- الفئات التي تحتاج تاريخ سريان ولم يُحدَّد لها
  for k in select unnest(array['sale', 'cost', 'packing', 'rates']) loop
    if app.to_date(p_dates->>k) is null and (
         exists (select 1 from jsonb_array_elements(v_new) n, jsonb_object_keys(n->'values') vk
                  where (k = 'rates' and vk not in ('sale', 'cost', 'packing')) or vk = k)
      or exists (select 1 from jsonb_array_elements(v_changed) c, jsonb_object_keys(c->'fields') fk
                  where (k = 'rates' and fk not in ('sale', 'cost', 'packing', 'name')) or fk = k)) then
      v_needs := v_needs || to_jsonb(k);
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'errors', v_errors, 'unchanged', v_unchanged,
                            'needs_dates', v_needs,
                            'counts', jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', jsonb_array_length(v_new),
                                                         'changed', jsonb_array_length(v_changed),
                                                         'errors', jsonb_array_length(v_errors), 'unchanged', v_unchanged));
end $$;

create or replace function public.preview_product_import(p_rows jsonb, p_dates jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  perform app.require_perm('P04', 'import');
  v := app.product_import_plan(p_rows, p_dates);
  -- إخفاء التكلفة ونسب العمولة عمّن لا يملك صلاحيتها
  if not app.has_perm('P04', 'view_cost') or not app.has_perm('P04', 'view_commission') then
    v := jsonb_set(v, '{changed}', coalesce((select jsonb_agg(jsonb_set(c, '{fields}',
            coalesce((select jsonb_object_agg(k, val) from jsonb_each(c->'fields') f(k, val)
                       where (k <> 'cost' or app.has_perm('P04', 'view_cost'))
                         and (k in ('sale', 'cost', 'packing', 'name') or app.has_perm('P04', 'view_commission'))), '{}')))
            from jsonb_array_elements(v->'changed') c), '[]'));
  end if;
  return v;
end $$;

create or replace function public.commit_product_import(p_rows jsonb, p_dates jsonb, p_file_name text,
                                                        p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; x jsonb; k text; v_id bigint; d date;
begin
  perform app.require_perm('P04', 'import');
  v_plan := app.product_import_plan(p_rows, p_dates);
  if jsonb_array_length(v_plan->'errors') > 0 then
    perform app.fail('import_errors', 'في الملف أخطاء تمنع الاعتماد؛ صحّحها ثم أعد الرفع');
  end if;
  if jsonb_array_length(v_plan->'needs_dates') > 0 then
    perform app.fail('dates_required', 'حدد تاريخ السريان لكل فئة متغيرة: ' ||
                     (select string_agg(case x2 when 'sale' then 'سعر البيع' when 'cost' then 'سعر التكلفة'
                                                when 'packing' then 'التعبئة' else 'نسب العمولة' end, '، ')
                        from jsonb_array_elements_text(v_plan->'needs_dates') x2));
  end if;
  -- تغيير التكلفة أو النسب يتطلب صلاحية رؤيتها
  if (exists (select 1 from jsonb_array_elements(v_plan->'changed') c where c->'fields' ? 'cost')
      or exists (select 1 from jsonb_array_elements(v_plan->'new') n where n->'values' ? 'cost'))
     and not app.has_perm('P04', 'view_cost') then
    perform app.fail('forbidden', 'الملف يغير سعر التكلفة ولا تملك صلاحيته');
  end if;
  foreach k in array array['sale', 'cost', 'packing', 'rates'] loop
    d := app.to_date(p_dates->>k);
    if d is not null then perform app.guard_dates(array[app.first_closed_in(d, app.today())], p_code); end if;
  end loop;

  for x in select * from jsonb_array_elements(v_plan->'new') loop
    insert into public.products (code, name) values (x->>'code', x->>'name') returning id into v_id;
    for k in select jsonb_object_keys(x->'values') loop
      perform app.set_product_value(v_id, k, (x->'values'->>k)::numeric,
                                    app.to_date(p_dates->>(case when k in ('sale', 'cost', 'packing') then k else 'rates' end)));
    end loop;
    perform app.audit('products', v_id::text, 'import_create', null, x);
  end loop;
  for x in select * from jsonb_array_elements(v_plan->'changed') loop
    select id into v_id from public.products where code = x->>'code';
    for k in select jsonb_object_keys(x->'fields') loop
      if k = 'name' then
        update public.products set name = x->'fields'->'name'->>1, updated_at = now() where id = v_id;
      else
        perform app.set_product_value(v_id, k, (x->'fields'->k->>1)::numeric,
                                      app.to_date(p_dates->>(case when k in ('sale', 'cost', 'packing') then k else 'rates' end)));
      end if;
    end loop;
    perform app.audit('products', v_id::text, 'import_update', null, x->'fields');
  end loop;
  insert into public.definition_imports (kind, file_name, by_user, summary)
  values ('products', p_file_name, auth.uid(), v_plan->'counts' || jsonb_build_object('dates', p_dates));
  return v_plan->'counts';
end $$;

-- سجل القيم المؤرخة لصنف (لصفحة ملف المنتج)
create or replace function public.product_history(p_product bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_perm('P04', 'view');
  return jsonb_build_object(
    'sale', (select coalesce(jsonb_agg(jsonb_build_object('date', effective_from, 'value', price) order by effective_from), '[]')
               from public.product_prices where product_id = p_product and kind = 'sale'),
    'cost', case when app.has_perm('P04', 'view_cost') then
              (select coalesce(jsonb_agg(jsonb_build_object('date', effective_from, 'value', price) order by effective_from), '[]')
                 from public.product_prices where product_id = p_product and kind = 'cost') end,
    'packing', (select coalesce(jsonb_agg(jsonb_build_object('date', effective_from, 'value', packets_per_carton) order by effective_from), '[]')
                  from public.product_packing where product_id = p_product),
    'rates', case when app.has_perm('P04', 'view_commission') then
               (select coalesce(jsonb_agg(jsonb_build_object('role', role, 'tier', tier, 'date', effective_from, 'value', rate)
                                          order by role, tier, effective_from), '[]')
                  from public.product_commission_rates where product_id = p_product) end);
end $$;

select app.apply_grants();
