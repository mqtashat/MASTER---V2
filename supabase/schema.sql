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

-- دوال الكتابة لا تمس موظفًا خارج نطاق المستخدم (B072)
create or replace function app.require_employee_scope(p_employee bigint) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.can_see_employee(p_employee) then
    perform app.fail('out_of_scope', 'هذا الموظف خارج نطاق بياناتك');
  end if;
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

-- هل يملك الحساب ما لا يملكه المستخدم الحالي: صلاحيةً أو موظفًا خارج نطاقه؟
-- غير الإدارة لا يدير حسابًا فوقه ولا يمنح أكثر مما يملك (B073، AUTH-002).
create or replace function app.exceeds_caller(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  t public.app_users;
begin
  if app.is_admin() then return false; end if;
  select * into t from public.app_users where id = p_user;
  if not found then return false; end if;
  if t.is_admin then return true; end if;
  if exists (select 1 from public.pages p, unnest(p.actions) a
              where app.granted(t.id, p.code, 'view') and (a = 'view' or app.granted(t.id, p.code, a))
                and not app.has_perm(p.code, a)) then
    return true;
  end if;
  if app.scope_is_all() then return false; end if;
  if t.data_scope = 'all' then return true; end if;
  return exists (
    select 1 from (
      select t.employee_id as e
      union all select s.employee_id from public.supervisor_assignments s
                 where t.data_scope = 'team' and s.supervisor_id = t.employee_id
      union all select x.employee_id from public.user_scope_employees x
                 where t.data_scope = 'selected' and x.user_id = t.id
    ) v where v.e is not null and not app.can_see_employee(v.e));
end $$;

create or replace function app.require_not_above_caller(p_user uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.exceeds_caller(p_user) then
    perform app.fail('above_caller', 'الحساب يملك صلاحيات أو نطاقًا لا تملكه؛ الإجراء للإدارة');
  end if;
end $$;

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
    if v_id = auth.uid() and not app.is_admin() then
      perform app.fail('self_edit', 'تعديل حسابك وصلاحياتك للإدارة فقط');
    end if;
    perform app.require_not_above_caller(v_id);
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
  -- غير الإدارة لا يمنح أكثر مما يملك
  perform app.require_not_above_caller(v_id);

  perform app.audit('app_users', v_id::text, case when p_id is null then 'create' else 'update' end,
                    v_before, app.user_json(v_id));
  return v_id;
end $$;

create or replace function public.admin_set_user_active(p_id uuid, p_active boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public, app, auth as $$
begin
  perform app.require_perm('P20', 'edit');
  if p_id = auth.uid() then perform app.fail('self_disable', 'لا يمكن تعطيل حسابك الحالي'); end if;
  if not exists (select 1 from public.app_users where id = p_id) then
    perform app.fail('not_found', 'الحساب غير موجود');
  end if;
  if (select is_admin from public.app_users where id = p_id) and not app.is_admin() then
    perform app.fail('admin_only', 'تعطيل حساب إدارة للإدارة فقط');
  end if;
  perform app.require_not_above_caller(p_id);
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
  if p_id = auth.uid() and not app.is_admin() then
    perform app.fail('self_edit', 'غيّر كلمة مرورك من «تغيير كلمة المرور»');
  end if;
  perform app.require_not_above_caller(p_id);
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
  -- غير الإدارة لا يضع في قالب صلاحية لا يملكها
  if exists (select 1 from jsonb_array_elements(coalesce(p_perms, '[]')) x
              where not app.has_perm(x->>'page', x->>'action')) then
    perform app.fail('above_caller', 'القالب يتضمن صلاحيات لا تملكها؛ الإجراء للإدارة');
  end if;
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

-- دوال الكتابة لا تمس عميلًا خارج نطاق المستخدم (B072)
create or replace function app.require_customer_scope(p_customer bigint) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.can_see_customer(p_customer) then
    perform app.fail('out_of_scope', 'هذا العميل خارج نطاق بياناتك');
  end if;
end $$;

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
    perform app.require_employee_scope(v_id);
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
  perform app.require_employee_scope(p_employee);
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
  perform app.require_employee_scope(p_employee);
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
  perform app.require_employee_scope(v.employee_id);
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
  perform app.require_employee_scope(p_employee);
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
    perform app.require_customer_scope(v_id);
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
  perform app.require_customer_scope(p_customer);
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
  perform app.require_customer_scope(p_customer);
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
  if (exists (select 1 from jsonb_array_elements(v_plan->'changed') c, jsonb_object_keys(c->'fields') k2
               where k2 not in ('name', 'sale', 'cost', 'packing'))
      or exists (select 1 from jsonb_array_elements(v_plan->'new') n, jsonb_object_keys(n->'values') k2
                  where k2 not in ('sale', 'cost', 'packing')))
     and not app.has_perm('P04', 'view_commission') then
    perform app.fail('forbidden', 'الملف يغير نسب العمولة ولا تملك صلاحيتها');
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

-- >>> 0004_transactions.sql
-- =====================================================================
-- ماستر — 0004: الحركات والرفع الموحد
-- السندات (الفواتير والمرتجعات والتحصيلات) وبنودها وإصداراتها، ودفعات الرفع وسنداتها،
-- والمعاينة والاعتماد والتعليق والاستبعاد، وحذف الدفعة والسند، والتحرير والنقل.
-- المراجع: DATA-002..007، DATA-010، TXN-001..004، B046–B054، INV-001..011، RET-001..008،
-- COL-001..014، UPLOAD-001، QTY-002/004، MAP-015، AUTH-004، B076.
-- =====================================================================

-- ---------------------------------------------------------------------
-- أدوات
-- ---------------------------------------------------------------------

-- عدد عشري نصي موحد دون أصفار زائدة؛ اختلاف عدد المنازل النصية لا يُعد تغييرًا
create or replace function app.nnum(p text) returns text
language sql immutable as $$
  select case when p is null or trim(p) = '' then null else trim_scale(trim(p)::numeric)::text end
$$;

create or replace function app.kind_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'invoice' then 'فاتورة' when 'return' then 'مرتجع' when 'collection' then 'تحصيل' end
$$;

-- أعمدة القوالب المعتمدة: المطلوبة لقراءة السند، وكامل القالب (INV-009/010، RET-006/007، COL-001)
create or replace function app.required_columns(p_kind text) returns text[]
language sql immutable as $$
  select case when p_kind = 'collection'
    then array['القيمة', 'الدفع', 'التاريخ', 'الرقم', 'رقم العميل', 'رقم المندوب']
    else array['Bonus', 'NetPromotions', 'NetSales', 'CustomerNumber', 'ItemNumber', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber']
  end
$$;

create or replace function app.all_columns(p_kind text) returns text[]
language sql immutable as $$
  select case p_kind
    when 'invoice' then array['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
                              'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID']
    when 'return' then array['Longitude', 'Latitude', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
                             'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID']
    else array['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب']
  end
$$;

-- ---------------------------------------------------------------------
-- السندات وبنودها وإصداراتها
-- ---------------------------------------------------------------------

-- دفعات الرفع (DATA-002، P05): الحالة محفوظة لإعادة المحاولة دون تكرار ما اعتمد
create table public.upload_batches (
  id               bigserial primary key,
  kind             text not null check (kind in ('invoice', 'return', 'collection')),
  file_name        text,
  sheet_name       text,
  columns          text[] not null,               -- أعمدة الملف كما وردت (B053)
  row_count        int not null,
  status           text not null default 'open' check (status in ('open', 'closed', 'deleted')),
  uploaded_by      uuid,
  uploaded_by_name text,
  uploaded_at      timestamptz not null default now(),
  deleted_at       timestamptz,
  deleted_by       uuid,
  delete_reason    text
);
create index on public.upload_batches (kind, uploaded_at desc);

-- السند: المفتاح رقم السند + رقم العميل + تاريخ السند داخل نوع الحركة (DATA-003)
create table public.docs (
  id                   bigserial primary key,
  kind                 text not null check (kind in ('invoice', 'return', 'collection')),
  doc_number           text not null,
  customer_number      text not null,
  doc_date             date not null,
  orig_doc_number      text not null,              -- المفتاح الأصلي يبقى بعد التعديل (B048)
  orig_customer_number text not null,
  orig_doc_date        date not null,
  customer_id          bigint not null references public.customers(id),
  employee_id          bigint not null references public.employees(id),
  customer_name_src    text,                       -- الاسم كما ورد في الملف
  employee_name_src    text,
  pay_type             text check (pay_type in ('فاتورة نقدي', 'فاتورة ذمم')),   -- الفواتير فقط (INV-011)
  lat                  numeric,                    -- موقع إصدار السند، مستقل عن موقع العميل (INV-004)
  lng                  numeric,
  net_sales            numeric not null default 0,
  net_promotions       numeric not null default 0,
  total                numeric not null default 0, -- المباشر + العروض، أو مجموع أجزاء التحصيل (COL-002)
  quantity             numeric,
  bonus                numeric not null default 0,
  line_count           int not null default 0,
  pay_methods          text,                       -- التحصيلات: أنواع الدفع في السند
  cheque_numbers       text,
  status               text not null default 'active' check (status in ('active', 'deleted')),
  version              int not null default 1,
  manual_edit          boolean not null default false,   -- آخر إصدار من تعديل يدوي أو نقل (TXN-003)
  created_batch_id     bigint references public.upload_batches(id),
  last_batch_id        bigint references public.upload_batches(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  unique (kind, doc_number, customer_number, doc_date)
);
create index on public.docs (kind, status, doc_date);
create index on public.docs (employee_id);
create index on public.docs (customer_id);
create index on public.docs (kind, orig_doc_number, orig_customer_number, orig_doc_date);
create index on public.docs (created_batch_id);
create index on public.docs (last_batch_id);

-- بنود السند أو أجزاء التحصيل: لا هوية مستقلة للبند (B047)، والتكرار الصحيح يحفظ
create table public.doc_lines (
  id              bigserial primary key,
  doc_id          bigint not null references public.docs(id) on delete cascade,
  line_no         int not null,
  product_id      bigint references public.products(id),
  item_number     text,
  item_name_src   text,
  net_sales       numeric,
  net_promotions  numeric,
  quantity        numeric,           -- كما وردت بكسورها (QTY-004)
  bonus           numeric,
  lat             numeric,
  lng             numeric,
  amount          numeric,           -- التحصيلات: قيمة الجزء
  pay_method      text,
  cheque_no       text,
  src_row         int
);
create index on public.doc_lines (doc_id, line_no);
create index on public.doc_lines (product_id);

-- كل إصدارات السند: الأصل وكل تعديل ورفع واستعادة وحذف (TXN-003)
create table public.doc_versions (
  id           bigserial primary key,
  doc_id       bigint not null references public.docs(id) on delete cascade,
  version      int not null,
  source       text not null check (source in ('upload', 'restore', 'manual', 'transfer', 'delete', 'batch_delete', 'batch_revert')),
  batch_id     bigint references public.upload_batches(id),
  data         jsonb not null,
  status       text not null,
  manual_edit  boolean not null default false,
  at           timestamptz not null default now(),
  by_user      uuid,
  by_name      text,
  reason       text,
  unique (doc_id, version)
);

-- سندات الدفعة: تصنيف المعاينة وقرار المستخدم ونتيجته
create table public.batch_items (
  id               bigserial primary key,
  batch_id         bigint not null references public.upload_batches(id),
  seq              int not null,
  doc_number       text,
  customer_number  text,
  doc_date_raw     text,
  doc_date         date,
  employee_number  text,
  employee_id      bigint references public.employees(id),
  customer_name    text,
  rows             int[] not null,
  data             jsonb not null,                -- السند كما ورد أو بعد تصحيحه يدويًا
  norm             jsonb,                         -- السند بعد القراءة والتوحيد (ومع حفظ الأعمدة الغائبة)
  class            text not null check (class in ('new', 'unchanged', 'changed', 'manual_conflict',
                                                  'possible_match', 'deleted_before', 'pending')),
  errors           jsonb not null default '[]',
  warnings         jsonb not null default '[]',
  duplicates       jsonb not null default '[]',
  drop_duplicates  boolean not null default false,
  total            numeric,
  line_count       int,
  doc_id           bigint references public.docs(id),   -- السند المحفوظ المطابق أو الناتج
  outcome          text check (outcome in ('added', 'updated', 'restored', 'no_change', 'kept_existing', 'excluded',
                                           'removed', 'reverted')),
  prev_version     int,                           -- إصدار السند قبل هذه الدفعة
  applied_version  int,                           -- الإصدار الذي أنشأته الدفعة
  conflict_on_delete boolean not null default false,
  fixed            boolean not null default false,
  decided_at       timestamptz,
  decided_by       uuid
);
create index on public.batch_items (batch_id, seq);
create index on public.batch_items (doc_id);

-- ---------------------------------------------------------------------
-- القراءة والتحقق والتوحيد
-- ---------------------------------------------------------------------

-- p_data: {doc_number, customer_number, doc_date, [employee_number, pay_type, customer_name, employee_name], lines: [...]}
-- البند: {row, employee_number, employee_name, customer_name, pay_type, item_number, item_name, net_sales, net_promotions,
--         quantity, bonus, lat, lng} أو للتحصيل {row, employee_number, employee_name, customer_name, amount, pay_method, cheque_no}
-- يعيد {errors, warnings, duplicates, norm}
create or replace function app.validate_doc(p_kind text, p_data jsonb, p_cols text[])
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  e jsonb := '[]'; w jsonb := '[]'; v_dups jsonb := '[]';
  is_col boolean := p_kind = 'collection';
  f_num text := case when is_col then 'الرقم' else 'DocumentNumber' end;
  f_cust text := case when is_col then 'رقم العميل' else 'CustomerNumber' end;
  f_date text := case when is_col then 'التاريخ' else 'DocumentDate' end;
  f_emp text := case when is_col then 'رقم المندوب' else 'EmployeeNumber' end;
  v_lines jsonb := coalesce(p_data->'lines', '[]');
  r0 int := coalesce(nullif(v_lines->0->>'row', '')::int, 0);
  v_num text := nullif(trim(p_data->>'doc_number'), '');
  v_cust text := nullif(trim(p_data->>'customer_number'), '');
  v_date_raw text := nullif(trim(p_data->>'doc_date'), '');
  v_date date;
  v_emp text; v_emps text[];
  v_pay text; v_pays text[];
  v_has_qty boolean := 'Quantity' = any(p_cols);
  v_has_pay boolean := 'DocumentTypeID' = any(p_cols);
  v_out jsonb := '[]';
  l jsonb; nl jsonb; v_row int; v text; i int; vals text[];
  fields text[] := array['net_sales', 'net_promotions', 'quantity', 'bonus'];
  heads  text[] := array['NetSales', 'NetPromotions', 'Quantity', 'Bonus'];
  v_item text; v_lat text; v_lng text; v_pm text;
  v_unknown_items text[] := '{}';
begin
  if jsonb_array_length(v_lines) = 0 then
    e := e || app.err(r0, '—', null, 'السند بلا بنود');
  end if;

  -- الهوية والتاريخ (B050، B051)
  if v_num is null then e := e || app.err(r0, f_num, null, 'رقم السند مفقود؛ يبقى الصف ضمن أخطاء الدفعة دون تجميع'); end if;
  if v_cust is null then
    e := e || app.err(r0, f_cust, null, 'رقم العميل مفقود؛ يبقى الصف ضمن أخطاء الدفعة دون تجميع');
  elsif not exists (select 1 from public.customers where customer_number = v_cust) then
    e := e || app.err(r0, f_cust, v_cust, 'عميل غير معرّف: ' || v_cust || '؛ عرّفه في صفحة العملاء ثم أعد الفحص أو الرفع');
  end if;
  if v_date_raw is null then
    e := e || app.err(r0, f_date, null, 'تاريخ السند مفقود');
  elsif app.is_bad_date(v_date_raw) then
    e := e || app.err(r0, f_date, v_date_raw, 'تاريخ غير مقروء؛ الصيغة المعتمدة يوم/شهر/سنة');
  else
    v_date := app.to_date(v_date_raw);
  end if;

  -- الموظف: واحد للسند (DATA-010)
  if nullif(trim(p_data->>'employee_number'), '') is not null then
    v_emps := array[trim(p_data->>'employee_number')];
  else
    select coalesce(array_agg(distinct trim(x->>'employee_number')), '{}') into v_emps
      from jsonb_array_elements(v_lines) x where nullif(trim(x->>'employee_number'), '') is not null;
  end if;
  if coalesce(array_length(v_emps, 1), 0) = 0 then
    e := e || app.err(r0, f_emp, null, 'رقم الموظف مفقود؛ لا يُسند السند إلى موظف آخر تلقائيًا');
  elsif array_length(v_emps, 1) > 1 then
    e := e || app.err(r0, f_emp, array_to_string(v_emps, '، '), 'أرقام موظفين مختلفة داخل السند نفسه');
  else
    v_emp := v_emps[1];
    if not exists (select 1 from public.employees where emp_number = v_emp) then
      e := e || app.err(r0, f_emp, v_emp, 'موظف غير معرّف: ' || v_emp || '؛ عرّفه في صفحة الموظفين ثم أعد الفحص أو الرفع');
    end if;
  end if;

  -- نوع الفاتورة (INV-011): «فاتورة نقدي» أو «فاتورة ذمم» فقط
  if p_kind = 'invoice' and (v_has_pay or p_data ? 'pay_type') then
    if p_data ? 'pay_type' then
      v_pays := array[coalesce(trim(p_data->>'pay_type'), '')];
    else
      select coalesce(array_agg(distinct coalesce(trim(x->>'pay_type'), '')), '{}') into v_pays from jsonb_array_elements(v_lines) x;
    end if;
    if array_length(v_pays, 1) > 1 then
      e := e || app.err(r0, 'DocumentTypeID', array_to_string(v_pays, '، '), 'نوع الفاتورة مختلف بين صفوف السند');
    elsif coalesce(v_pays[1], '') = '' then
      e := e || app.err(r0, 'DocumentTypeID', null, 'قيمة DocumentTypeID فارغة؛ المقبول «فاتورة نقدي» أو «فاتورة ذمم»');
    elsif v_pays[1] not in ('فاتورة نقدي', 'فاتورة ذمم') then
      e := e || app.err(r0, 'DocumentTypeID', v_pays[1], 'قيمة DocumentTypeID غير مقبولة: ' || v_pays[1] || '؛ المقبول «فاتورة نقدي» أو «فاتورة ذمم»');
    else
      v_pay := v_pays[1];
    end if;
  end if;

  -- البنود
  for l in select value from jsonb_array_elements(v_lines) loop
    v_row := coalesce(nullif(l->>'row', '')::int, 0);
    if is_col then
      v := nullif(trim(l->>'amount'), '');
      if v is null then e := e || app.err(v_row, 'القيمة', null, 'القيمة مفقودة');
      elsif app.is_bad_num(v) then e := e || app.err(v_row, 'القيمة', v, 'مبلغ غير مقروء'); v := null;
      elsif v::numeric < 0 then w := w || app.err(v_row, 'القيمة', v, 'قيمة سالبة تحتاج مراجعة');
      end if;
      v_pm := nullif(trim(l->>'pay_method'), '');
      if v_pm is null then
        e := e || app.err(v_row, 'الدفع', null, 'قيمة الدفع فارغة؛ المقبول «نقدي» أو «شيك مؤجل» أو «شيك مستحق الدفع»');
      elsif v_pm not in ('نقدي', 'شيك مؤجل', 'شيك مستحق الدفع') then
        e := e || app.err(v_row, 'الدفع', v_pm, 'قيمة الدفع ' || v_pm || ' غير مقبولة؛ المقبول «نقدي» أو «شيك مؤجل» أو «شيك مستحق الدفع»');
      end if;
      nl := jsonb_build_object('row', v_row, 'amount', case when v is not null then app.nnum(v) end, 'pay_method', v_pm,
                               'cheque_no', nullif(trim(l->>'cheque_no'), ''));
    else
      v_item := nullif(trim(l->>'item_number'), '');
      if v_item is null then
        e := e || app.err(v_row, 'ItemNumber', null, 'رقم الصنف مفقود');
      elsif not exists (select 1 from public.products where code = v_item) then
        if not v_item = any(v_unknown_items) then
          e := e || app.err(v_row, 'ItemNumber', v_item, 'صنف غير معرّف: ' || v_item || '؛ عرّفه في صفحة المنتجات ثم أعد الفحص أو الرفع');
          v_unknown_items := v_unknown_items || v_item;
        end if;
      end if;
      vals := array[null, null, null, null];
      for i in 1..4 loop
        v := nullif(trim(l->>fields[i]), '');
        if fields[i] = 'quantity' and not v_has_qty then v := null; end if;
        if v is null then
          if fields[i] <> 'quantity' then e := e || app.err(v_row, heads[i], null, 'قيمة مفقودة'); end if;
        elsif app.is_bad_num(v) then
          e := e || app.err(v_row, heads[i], v, case when fields[i] in ('quantity', 'bonus') then 'كمية غير مقروءة' else 'مبلغ غير مقروء' end);
        else
          vals[i] := app.nnum(v);
          if vals[i]::numeric < 0 then
            if p_kind = 'return' then
              e := e || app.err(v_row, heads[i], v, 'قيمة سالبة في المرتجع؛ صحّحها يدويًا قبل الاعتماد دون تحويل آلي للإشارة');
            else
              w := w || app.err(v_row, heads[i], v, 'قيمة سالبة تحتاج مراجعة');
            end if;
          end if;
        end if;
      end loop;
      -- قيمة موجبة مع كمية صفر: تنبيه مراجعة دون اختراع كمية (B052)
      if vals[3] is not null and vals[3]::numeric = 0 and coalesce(vals[1]::numeric, 0) + coalesce(vals[2]::numeric, 0) > 0 then
        w := w || app.err(v_row, 'Quantity', vals[3], 'قيمة بيع موجبة مع كمية صفر؛ مراجعة دون اختراع كمية');
      end if;
      -- الموقع لا يمنع الاعتماد المالي (MAP-015)
      v_lat := nullif(trim(l->>'lat'), ''); v_lng := nullif(trim(l->>'lng'), '');
      if v_lat is not null or v_lng is not null then
        if app.is_bad_num(v_lat) or app.is_bad_num(v_lng) or v_lat is null or v_lng is null
           or v_lat::numeric not between -90 and 90 or v_lng::numeric not between -180 and 180 then
          w := w || app.err(v_row, 'Latitude/Longitude', coalesce(v_lat, '') || ', ' || coalesce(v_lng, ''),
                            'إحداثيات غير صالحة؛ لا تمنع الاعتماد المالي ويبقى السند بلا موقع');
          v_lat := null; v_lng := null;
        else
          v_lat := app.nnum(v_lat); v_lng := app.nnum(v_lng);
        end if;
      end if;
      nl := jsonb_build_object('row', v_row, 'item_number', v_item, 'item_name', nullif(trim(l->>'item_name'), ''),
                               'net_sales', vals[1], 'net_promotions', vals[2], 'quantity', vals[3], 'bonus', vals[4],
                               'lat', v_lat, 'lng', v_lng);
    end if;
    v_out := v_out || jsonb_build_array(nl);
  end loop;

  -- صفوف متطابقة في الفواتير والمرتجعات: تنبيه وقرار صريح (B047). أجزاء التحصيل المتطابقة تجمع كلها (COL-002).
  if not is_col then
    select coalesce(jsonb_agg(to_jsonb(g.rs) order by g.rs[1]), '[]') into v_dups from (
      select array_agg((x->>'row')::int order by (x->>'row')::int) rs
        from jsonb_array_elements(v_out) x group by (x - 'row')::text having count(*) > 1) g;
    for l in select value from jsonb_array_elements(v_dups) loop
      w := w || app.err((l->>0)::int, '—', (select string_agg(value, '، ') from jsonb_array_elements_text(l)),
                        'صفوف متطابقة تحتاج مراجعة: أبقِها أو استبعد التكرار من النسخة الواردة قبل الاعتماد');
    end loop;
  end if;

  return jsonb_build_object('errors', e, 'warnings', w, 'duplicates', v_dups, 'norm', jsonb_build_object(
    'doc_number', v_num, 'customer_number', v_cust, 'doc_date', v_date, 'employee_number', v_emp,
    'customer_name', coalesce(nullif(trim(p_data->>'customer_name'), ''), (select nullif(trim(x->>'customer_name'), '') from jsonb_array_elements(v_lines) x limit 1)),
    'employee_name', coalesce(nullif(trim(p_data->>'employee_name'), ''), (select nullif(trim(x->>'employee_name'), '') from jsonb_array_elements(v_lines) x limit 1)),
    'pay_type', v_pay, 'lines', v_out));
end $$;

-- مقارنة نسختين على الأعمدة الواردة فقط؛ ترتيب البنود لا يغيّر السند
create or replace function app.doc_canon(p_kind text, p_d jsonb, p_cols text[]) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'h', jsonb_build_object('doc_number', p_d->'doc_number', 'customer_number', p_d->'customer_number', 'doc_date', p_d->'doc_date',
                            'employee_number', p_d->'employee_number',
                            'pay_type', case when p_kind = 'invoice' and 'DocumentTypeID' = any(p_cols) then p_d->'pay_type' end),
    'l', coalesce((select jsonb_agg(c order by c::text) from (
      select case when p_kind = 'collection' then
               jsonb_build_object('amount', x->'amount', 'pay_method', x->'pay_method',
                                  'cheque_no', case when 'رقم الشيك' = any(p_cols) then x->'cheque_no' end)
             else
               jsonb_build_object('item_number', x->'item_number', 'net_sales', x->'net_sales', 'net_promotions', x->'net_promotions',
                                  'bonus', x->'bonus', 'quantity', case when 'Quantity' = any(p_cols) then x->'quantity' end,
                                  'lat', case when 'Latitude' = any(p_cols) then x->'lat' end,
                                  'lng', case when 'Longitude' = any(p_cols) then x->'lng' end)
             end c
        from jsonb_array_elements(p_d->'lines') x) s), '[]'))
$$;

-- نسخة ناقصة الأعمدة لا تمحو ما حُفظ من كمية أو موقع أو نوع أو رقم شيك (B053)
create or replace function app.merge_absent(p_kind text, p_new jsonb, p_old jsonb, p_cols text[]) returns jsonb
language plpgsql immutable as $$
declare
  res jsonb := p_new; v_out jsonb := '[]'; l jsonb; m jsonb; k text; n int; seen jsonb := '{}';
  keep_qty boolean := not ('Quantity' = any(p_cols));
  keep_loc boolean := not ('Longitude' = any(p_cols) and 'Latitude' = any(p_cols));
  keep_chq boolean := not ('رقم الشيك' = any(p_cols));
begin
  if p_old is null then return p_new; end if;
  if p_kind = 'invoice' and not ('DocumentTypeID' = any(p_cols)) then
    res := jsonb_set(res, '{pay_type}', coalesce(p_old->'pay_type', 'null'));
  end if;
  if not ('Customername' = any(p_cols) or 'العميل' = any(p_cols)) then
    res := jsonb_set(res, '{customer_name}', coalesce(p_old->'customer_name', 'null'));
  end if;
  if not ('EmployeeName' = any(p_cols) or 'المندوب' = any(p_cols)) then
    res := jsonb_set(res, '{employee_name}', coalesce(p_old->'employee_name', 'null'));
  end if;
  if (p_kind = 'collection' and not keep_chq) or (p_kind <> 'collection' and not keep_qty and not keep_loc) then
    return res;
  end if;
  for l in select value from jsonb_array_elements(res->'lines') loop
    k := case when p_kind = 'collection' then coalesce(l->>'amount', '') || '|' || coalesce(l->>'pay_method', '')
              else coalesce(l->>'item_number', '') end;
    n := coalesce((seen->>k)::int, 0) + 1;
    seen := seen || jsonb_build_object(k, n);
    select x into m from jsonb_array_elements(p_old->'lines') with ordinality t(x, o)
     where (case when p_kind = 'collection' then coalesce(x->>'amount', '') || '|' || coalesce(x->>'pay_method', '')
                 else coalesce(x->>'item_number', '') end) = k
     order by o offset n - 1 limit 1;
    if m is not null then
      if p_kind = 'collection' then
        l := l || jsonb_build_object('cheque_no', m->'cheque_no');
      else
        if keep_qty then l := l || jsonb_build_object('quantity', m->'quantity'); end if;
        if keep_loc then l := l || jsonb_build_object('lat', m->'lat', 'lng', m->'lng'); end if;
      end if;
    end if;
    v_out := v_out || jsonb_build_array(l);
  end loop;
  return jsonb_set(res, '{lines}', v_out);
end $$;

-- استبعاد التكرار الوارد باختيار صريح (B047): يبقى أول صف من كل مجموعة متطابقة
create or replace function app.drop_dup_lines(p_norm jsonb) returns jsonb
language sql immutable as $$
  select jsonb_set(p_norm, '{lines}', coalesce((
    select jsonb_agg(x order by o) from (
      select x, o, row_number() over (partition by (x - 'row')::text order by o) rn
        from jsonb_array_elements(p_norm->'lines') with ordinality t(x, o)) s where rn = 1), '[]'))
$$;

-- الإصدار الحالي للسند بصيغة السند الموحد
create or replace function app.doc_snapshot(p_doc bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select v.data from public.docs d join public.doc_versions v on v.doc_id = d.id and v.version = d.version where d.id = p_doc
$$;

-- كتابة إصدار جديد للسند (أو إنشاؤه) من السند الموحد، مع البنود والمجاميع والإصدار
create or replace function app.write_doc(p_doc bigint, p_kind text, p_norm jsonb, p_status text, p_batch bigint,
                                         p_source text, p_manual boolean, p_reason text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_doc; v_cust bigint; v_emp bigint; v_lat numeric; v_lng numeric; v_ver int;
begin
  select id into v_cust from public.customers where customer_number = p_norm->>'customer_number';
  select id into v_emp from public.employees where emp_number = p_norm->>'employee_number';
  if v_cust is null or v_emp is null then perform app.fail('unknown_ref', 'العميل أو الموظف غير معرّف'); end if;
  select (x->>'lat')::numeric, (x->>'lng')::numeric into v_lat, v_lng
    from jsonb_array_elements(p_norm->'lines') x where x->>'lat' is not null and x->>'lng' is not null limit 1;
  if v_id is null then
    insert into public.docs (kind, doc_number, customer_number, doc_date, orig_doc_number, orig_customer_number, orig_doc_date,
                             customer_id, employee_id, customer_name_src, employee_name_src, pay_type, lat, lng, status,
                             version, manual_edit, created_batch_id, last_batch_id)
    values (p_kind, p_norm->>'doc_number', p_norm->>'customer_number', (p_norm->>'doc_date')::date,
            p_norm->>'doc_number', p_norm->>'customer_number', (p_norm->>'doc_date')::date,
            v_cust, v_emp, p_norm->>'customer_name', p_norm->>'employee_name', p_norm->>'pay_type', v_lat, v_lng, p_status,
            1, p_manual, p_batch, p_batch)
    returning id, version into v_id, v_ver;
  else
    update public.docs set doc_number = p_norm->>'doc_number', customer_number = p_norm->>'customer_number',
           doc_date = (p_norm->>'doc_date')::date, customer_id = v_cust, employee_id = v_emp,
           customer_name_src = p_norm->>'customer_name', employee_name_src = p_norm->>'employee_name',
           pay_type = p_norm->>'pay_type', lat = v_lat, lng = v_lng, status = p_status, version = version + 1,
           manual_edit = p_manual, last_batch_id = coalesce(p_batch, last_batch_id), updated_at = now(),
           deleted_at = case when p_status = 'deleted' then now() end
     where id = v_id returning version into v_ver;
  end if;
  delete from public.doc_lines where doc_id = v_id;
  insert into public.doc_lines (doc_id, line_no, product_id, item_number, item_name_src, net_sales, net_promotions, quantity, bonus,
                                lat, lng, amount, pay_method, cheque_no, src_row)
  select v_id, o, p.id, x->>'item_number', x->>'item_name', (x->>'net_sales')::numeric, (x->>'net_promotions')::numeric,
         (x->>'quantity')::numeric, (x->>'bonus')::numeric, (x->>'lat')::numeric, (x->>'lng')::numeric,
         (x->>'amount')::numeric, x->>'pay_method', x->>'cheque_no', nullif(x->>'row', '')::int
    from jsonb_array_elements(p_norm->'lines') with ordinality t(x, o)
    left join public.products p on p.code = x->>'item_number';
  update public.docs d set
    net_sales = coalesce(s.ns, 0), net_promotions = coalesce(s.np, 0),
    total = case when p_kind = 'collection' then coalesce(s.am, 0) else coalesce(s.ns, 0) + coalesce(s.np, 0) end,
    quantity = s.q, bonus = coalesce(s.b, 0), line_count = s.n, pay_methods = s.pm, cheque_numbers = s.ch
    from (select sum(net_sales) ns, sum(net_promotions) np, sum(amount) am, sum(quantity) q, sum(bonus) b, count(*) n,
                 string_agg(distinct pay_method, '، ') pm, string_agg(distinct cheque_no, '، ') ch
            from public.doc_lines where doc_id = v_id) s
   where d.id = v_id;
  insert into public.doc_versions (doc_id, version, source, batch_id, data, status, manual_edit, by_user, by_name, reason)
  values (v_id, v_ver, p_source, p_batch, p_norm, p_status, p_manual, auth.uid(),
          (select display_name from public.app_users where id = auth.uid()), p_reason);
  if p_status = 'active' then
    insert into public.customer_employee_links (customer_id, employee_id) values (v_cust, v_emp) on conflict do nothing;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- تصنيف سند الدفعة (DATA-004، DATA-005، TXN-003، B048، B053، B054)
-- ---------------------------------------------------------------------
create or replace function app.classify_item(p_item bigint) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  it public.batch_items; b public.upload_batches; d public.docs;
  v jsonb; v_norm jsonb; v_old jsonb; v_class text; v_errors jsonb; v_doc bigint;
begin
  select * into it from public.batch_items where id = p_item;
  select * into b from public.upload_batches where id = it.batch_id;
  v := app.validate_doc(b.kind, it.data, b.columns);
  v_norm := v->'norm'; v_errors := v->'errors';
  if v_norm->>'doc_number' is not null and v_norm->>'customer_number' is not null and v_norm->>'doc_date' is not null then
    select * into d from public.docs
     where kind = b.kind and doc_number = v_norm->>'doc_number' and customer_number = v_norm->>'customer_number'
       and doc_date = (v_norm->>'doc_date')::date;
    if not found then
      -- إعادة رفع الأصل بعد تعديل مفتاحه: مطابقة محتملة (B048)
      select * into d from public.docs
       where kind = b.kind and status = 'active' and orig_doc_number = v_norm->>'doc_number'
         and orig_customer_number = v_norm->>'customer_number' and orig_doc_date = (v_norm->>'doc_date')::date
       order by id limit 1;
      if found then v_class := 'possible_match'; end if;
    end if;
  end if;
  v_doc := d.id;
  if v_doc is not null and d.status = 'active' then
    v_old := app.doc_snapshot(v_doc);
    v_norm := app.merge_absent(b.kind, v_norm, v_old, b.columns);
  end if;
  -- نوع الفاتورة غائب عن ملف لسند جديد: لا يُفترض (INV-011)
  if b.kind = 'invoice' and v_norm->>'pay_type' is null and not (b.columns @> array['DocumentTypeID'])
     and (v_doc is null or d.status <> 'active') then
    v_errors := v_errors || app.err(coalesce((it.rows)[1], 0), 'DocumentTypeID', null,
                                    'عمود DocumentTypeID غير موجود في الملف ولا نوع محفوظ لهذه الفاتورة');
  end if;
  if jsonb_array_length(v_errors) > 0 then
    v_class := 'pending';
  elsif v_class = 'possible_match' then
    null;
  elsif v_doc is not null and d.status = 'deleted' then
    v_class := 'deleted_before';
  elsif v_doc is not null then
    if app.doc_canon(b.kind, v_norm, b.columns) = app.doc_canon(b.kind, v_old, b.columns) then v_class := 'unchanged';
    elsif d.manual_edit then v_class := 'manual_conflict';
    else v_class := 'changed'; end if;
  else
    v_class := 'new';
  end if;
  update public.batch_items set
    class = v_class, errors = v_errors, warnings = v->'warnings', duplicates = v->'duplicates', norm = v_norm,
    doc_number = coalesce(v_norm->>'doc_number', nullif(trim(data->>'doc_number'), '')),
    customer_number = coalesce(v_norm->>'customer_number', nullif(trim(data->>'customer_number'), '')),
    doc_date_raw = nullif(trim(data->>'doc_date'), ''), doc_date = (v_norm->>'doc_date')::date,
    employee_number = v_norm->>'employee_number',
    employee_id = (select id from public.employees where emp_number = v_norm->>'employee_number'),
    customer_name = coalesce((select name from public.customers where customer_number = v_norm->>'customer_number'), v_norm->>'customer_name'),
    total = (select sum(coalesce((x->>'net_sales')::numeric, 0) + coalesce((x->>'net_promotions')::numeric, 0) + coalesce((x->>'amount')::numeric, 0))
               from jsonb_array_elements(v_norm->'lines') x),
    line_count = jsonb_array_length(v_norm->'lines'),
    doc_id = v_doc
   where id = p_item;
  return v_class;
end $$;

-- ملخص الدفعة: أعداد السندات حسب التصنيف والقرار (DATA-005: لا تعرض الدفعة معتمدة وفيها معلق)
create or replace function app.batch_summary(p_batch bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'batch_id', p_batch,
    'rows', (select row_count from public.upload_batches where id = p_batch),
    'docs', count(*),
    'awaiting', count(*) filter (where outcome is null),
    'new', count(*) filter (where outcome is null and class = 'new'),
    'unchanged', count(*) filter (where outcome is null and class = 'unchanged'),
    'changed', count(*) filter (where outcome is null and class = 'changed'),
    'manual_conflict', count(*) filter (where outcome is null and class = 'manual_conflict'),
    'possible_match', count(*) filter (where outcome is null and class = 'possible_match'),
    'deleted_before', count(*) filter (where outcome is null and class = 'deleted_before'),
    'pending', count(*) filter (where outcome is null and class = 'pending'),
    'warnings', count(*) filter (where outcome is null and jsonb_array_length(warnings) > 0),
    'added', count(*) filter (where outcome = 'added'),
    'updated', count(*) filter (where outcome in ('updated', 'restored')),
    'no_change', count(*) filter (where outcome = 'no_change'),
    'kept_existing', count(*) filter (where outcome = 'kept_existing'),
    'excluded', count(*) filter (where outcome = 'excluded'),
    'removed', count(*) filter (where outcome = 'removed'),
    'reverted', count(*) filter (where outcome = 'reverted'),
    'conflicts', count(*) filter (where conflict_on_delete))
  from public.batch_items where batch_id = p_batch
$$;

-- ---------------------------------------------------------------------
-- الرفع: قراءة الملف إلى دفعة محفوظة بمعاينتها
-- ---------------------------------------------------------------------

-- p_rows: صفوف الملف كما قرأها التطبيق (نصوص)، مع رقم الصف في Excel
create or replace function public.upload_stage(p_kind text, p_file_name text, p_sheet text, p_columns jsonb, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_cols text[] := (select coalesce(array_agg(trim(c)), '{}') from jsonb_array_elements_text(p_columns) c);
  v_batch bigint; v_missing text[]; g record; v_seq int := 0; v_id bigint;
begin
  perform app.require_perm('P05', 'import');
  if p_kind not in ('invoice', 'return', 'collection') then perform app.fail('bad_kind', 'نوع الحركة غير معروف'); end if;
  select array_agg(c) into v_missing from unnest(app.required_columns(p_kind)) c where not c = any(v_cols);
  if v_missing is not null then
    perform app.fail('missing_columns', 'أعمدة مطلوبة غير موجودة في الملف: ' || array_to_string(v_missing, '، '));
  end if;
  if coalesce(jsonb_array_length(p_rows), 0) = 0 then perform app.fail('empty', 'الملف لا يحتوي صفوف بيانات'); end if;
  insert into public.upload_batches (kind, file_name, sheet_name, columns, row_count, uploaded_by, uploaded_by_name)
  values (p_kind, p_file_name, p_sheet, v_cols, jsonb_array_length(p_rows), auth.uid(),
          (select display_name from public.app_users where id = auth.uid()))
  returning id into v_batch;
  -- السند = تطابق العناصر الثلاثة (DATA-003)؛ الصف الناقص الهوية يبقى وحده دون تجميع (B050)
  for g in
    select k, jsonb_agg(x order by (x->>'row')::int) lines, array_agg((x->>'row')::int order by (x->>'row')::int) rws,
           min((x->>'row')::int) first_row
      from (select x, case when nullif(trim(x->>'doc_number'), '') is null or nullif(trim(x->>'customer_number'), '') is null
                             or nullif(trim(x->>'doc_date'), '') is null
                           then 'row:' || (x->>'row')
                           else trim(x->>'doc_number') || '|' || trim(x->>'customer_number') || '|' || trim(x->>'doc_date') end k
              from jsonb_array_elements(p_rows) x) s
     group by k order by first_row
  loop
    v_seq := v_seq + 1;
    insert into public.batch_items (batch_id, seq, rows, data, class)
    values (v_batch, v_seq, g.rws, jsonb_build_object('doc_number', g.lines->0->>'doc_number', 'customer_number', g.lines->0->>'customer_number',
                                                      'doc_date', g.lines->0->>'doc_date',
                                                      'lines', (select jsonb_agg(x - 'doc_number' - 'customer_number' - 'doc_date')
                                                                  from jsonb_array_elements(g.lines) x)), 'new')
    returning id into v_id;
    perform app.classify_item(v_id);
  end loop;
  perform app.audit('upload_batches', v_batch::text, 'upload', null,
                    jsonb_build_object('kind', p_kind, 'file', p_file_name, 'rows', jsonb_array_length(p_rows)));
  return app.batch_summary(v_batch);
end $$;

-- تفاصيل سند الدفعة: كامل الوارد مقابل المحفوظ (P05)
create or replace function public.upload_item_detail(p_item bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  it public.batch_items; v_kind text;
begin
  perform app.require_perm('P05', 'view');
  select * into it from public.batch_items where id = p_item;
  if not found then perform app.fail('not_found', 'السند غير موجود في الدفعة'); end if;
  if it.employee_id is not null and not app.can_see_employee(it.employee_id) then
    perform app.fail('forbidden', 'السند خارج نطاق بياناتك');
  end if;
  if it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id)) then
    perform app.fail('forbidden', 'السند المحفوظ خارج نطاق بياناتك');
  end if;
  select kind into v_kind from public.upload_batches where id = it.batch_id;
  return jsonb_build_object('item', to_jsonb(it), 'kind', v_kind,
    'existing', case when it.doc_id is not null then app.doc_snapshot(it.doc_id) end,
    'existing_status', (select status from public.docs where id = it.doc_id),
    'existing_manual', (select manual_edit from public.docs where id = it.doc_id),
    'existing_version', (select version from public.docs where id = it.doc_id));
end $$;

-- تصحيح سند معلق يدويًا ثم إعادة فحصه (DATA-005)
create or replace function public.upload_fix_item(p_item bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  it public.batch_items; v_class text; v_old jsonb;
begin
  perform app.require_perm('P05', 'approve');
  select * into it from public.batch_items where id = p_item for update;
  if not found then perform app.fail('not_found', 'السند غير موجود في الدفعة'); end if;
  if it.outcome is not null then perform app.fail('decided', 'سبق اتخاذ قرار في هذا السند'); end if;
  if (select status from public.upload_batches where id = it.batch_id) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة');
  end if;
  if it.employee_id is not null and not app.can_see_employee(it.employee_id) then
    perform app.fail('forbidden', 'السند خارج نطاق بياناتك');
  end if;
  v_old := it.data;
  update public.batch_items set data = p_data, fixed = true where id = p_item;
  v_class := app.classify_item(p_item);
  -- التصحيح لا ينقل السند إلى موظف أو سند محفوظ خارج النطاق (B072)
  select * into it from public.batch_items where id = p_item;
  if (it.employee_id is not null and not app.can_see_employee(it.employee_id))
     or (it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id))) then
    perform app.fail('forbidden', 'التصحيح يجعل السند خارج نطاق بياناتك');
  end if;
  perform app.audit('upload_batches', it.batch_id::text, 'fix_item', v_old, p_data);
  return jsonb_build_object('class', v_class, 'summary', app.batch_summary(it.batch_id));
end $$;

-- إعادة فحص السندات غير المقررة بعد تعريف رمز ناقص (DATA-010)
create or replace function public.upload_recheck(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
begin
  perform app.require_perm('P05', 'import');
  for x in select id from public.batch_items where batch_id = p_batch and outcome is null order by seq loop
    perform app.classify_item(x.id);
  end loop;
  return app.batch_summary(p_batch);
end $$;

-- قرارات المعاينة. p_decisions: [{id, action, drop_duplicates}]
-- action: approve (جديد/متغير/مطابق) | use_file (اعتماد بيانات الملف بدل التعديل اليدوي أو للمطابق المحتمل)
--         | restore (استعادة صريحة لسبق حذفه) | keep (إبقاء المحفوظ) | exclude (استبعاد من الدفعة)
create or replace function public.upload_resolve(p_batch bigint, p_decisions jsonb, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  dcs jsonb; it public.batch_items; b public.upload_batches; v_class text; v_act text; v_norm jsonb;
  v_doc bigint; v_prev int; v_old_date date; v_skipped jsonb := '[]'; v_outcome text; v_ver int;
begin
  perform app.require_perm('P05', 'approve');
  select * into b from public.upload_batches where id = p_batch for update;
  if not found then perform app.fail('not_found', 'الدفعة غير موجودة'); end if;
  if b.status = 'deleted' then perform app.fail('batch_deleted', 'الدفعة محذوفة'); end if;
  for dcs in select value from jsonb_array_elements(coalesce(p_decisions, '[]')) loop
    select * into it from public.batch_items where id = (dcs->>'id')::bigint and batch_id = p_batch for update;
    if not found or it.outcome is not null then continue; end if;   -- قرار سابق: لا تكرار (إعادة المحاولة بعد الانقطاع)
    if (it.employee_id is not null and not app.can_see_employee(it.employee_id))
       or (it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id))) then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'السند خارج نطاق بياناتك'); continue;
    end if;
    v_act := dcs->>'action';
    if v_act = 'exclude' then
      update public.batch_items set outcome = 'excluded', decided_at = now(), decided_by = auth.uid() where id = it.id;
      continue;
    end if;
    -- إعادة الفحص على البيانات الحالية قبل التنفيذ (DATA-005)
    v_class := app.classify_item(it.id);
    select * into it from public.batch_items where id = it.id;
    if it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id)) then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'السند خارج نطاق بياناتك'); continue;
    end if;
    v_outcome := null; v_doc := it.doc_id; v_norm := it.norm;
    if coalesce((dcs->>'drop_duplicates')::boolean, false) and b.kind <> 'collection' then
      v_norm := app.drop_dup_lines(v_norm);
      update public.batch_items set drop_duplicates = true where id = it.id;
    end if;
    if v_class = 'pending' then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'معلق بأخطاء تمنع الاعتماد'); continue;
    elsif v_act = 'keep' and v_class in ('manual_conflict', 'possible_match', 'deleted_before', 'changed') then
      v_outcome := 'kept_existing';
    elsif v_act = 'approve' and v_class = 'unchanged' then
      v_outcome := 'no_change';
    elsif (v_act = 'approve' and v_class in ('new', 'changed')) or (v_act = 'use_file' and v_class in ('changed', 'manual_conflict', 'possible_match'))
          or (v_act = 'restore' and v_class = 'deleted_before') then
      v_old_date := (select doc_date from public.docs where id = v_doc);
      perform app.guard_dates(array[(v_norm->>'doc_date')::date, v_old_date], p_code);
      if v_doc is not null then
        if exists (select 1 from public.docs where kind = b.kind and id <> v_doc and doc_number = v_norm->>'doc_number'
                     and customer_number = v_norm->>'customer_number' and doc_date = (v_norm->>'doc_date')::date) then
          v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'المفتاح مستخدم لسند آخر (B049)'); continue;
        end if;
        select version into v_prev from public.docs where id = v_doc for update;
      else
        v_prev := null;
      end if;
      v_doc := app.write_doc(v_doc, b.kind, v_norm, 'active', p_batch,
                             case when v_class = 'deleted_before' then 'restore' else 'upload' end, false);
      select version into v_ver from public.docs where id = v_doc;
      v_outcome := case when v_class = 'new' then 'added' when v_class = 'deleted_before' then 'restored' else 'updated' end;
      update public.batch_items set prev_version = v_prev, applied_version = v_ver, doc_id = v_doc where id = it.id;
    else
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'القرار لا يناسب حالة السند الحالية'); continue;
    end if;
    update public.batch_items set outcome = v_outcome, decided_at = now(), decided_by = auth.uid() where id = it.id;
  end loop;
  update public.upload_batches set status = case when exists (select 1 from public.batch_items where batch_id = p_batch and outcome is null)
                                                 then 'open' else 'closed' end
   where id = p_batch;
  perform app.audit('upload_batches', p_batch::text, 'resolve', null, p_decisions);
  return app.batch_summary(p_batch) || jsonb_build_object('skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------
-- حذف الدفعة كتراجع عن أثرها (DATA-007، B054) وحذف السند (TXN-004)
-- ---------------------------------------------------------------------
create or replace function app.batch_delete_plan(p_batch bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  with x as (
    select i.*, d.version cur_version, d.total doc_total, d.doc_date cur_date,
           case
             when i.outcome = 'added' and d.version = i.applied_version then 'remove'
             when i.outcome in ('updated', 'restored') and d.version = i.applied_version then 'revert'
             when i.outcome in ('added', 'updated', 'restored') then 'conflict'
             when i.outcome is null then 'exclude'
             else 'none'
           end act
      from public.batch_items i left join public.docs d on d.id = i.doc_id
     where i.batch_id = p_batch)
  select jsonb_build_object(
    'remove', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                         'customer_number', customer_number, 'doc_date', doc_date, 'total', doc_total) order by seq)
                          from x where act = 'remove'), '[]'),
    'revert', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                         'customer_number', customer_number, 'doc_date', doc_date, 'total', doc_total,
                                         'restore_total', (select sum(coalesce((l->>'net_sales')::numeric, 0) + coalesce((l->>'net_promotions')::numeric, 0)
                                                                      + coalesce((l->>'amount')::numeric, 0))
                                                             from public.doc_versions v, jsonb_array_elements(v.data->'lines') l
                                                            where v.doc_id = x.doc_id and v.version = x.prev_version),
                                         'restore_status', (select status from public.doc_versions v where v.doc_id = x.doc_id and v.version = x.prev_version))
                                         order by seq)
                          from x where act = 'revert'), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                            'customer_number', customer_number, 'doc_date', doc_date) order by seq)
                             from x where act = 'conflict'), '[]'),
    'exclude', (select count(*) from x where act = 'exclude'),
    'unchanged', (select count(*) from x where act = 'none'),
    'remove_total', (select coalesce(sum(doc_total), 0) from x where act = 'remove'),
    'revert_total', (select coalesce(sum(doc_total), 0) from x where act = 'revert'))
$$;

-- حذف الدفعة يمس كل سنداتها، فيلزم أن تكون كلها ضمن نطاق المستخدم (B072)
create or replace function app.require_batch_scope(p_batch bigint) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.scope_is_all() then return; end if;
  if exists (select 1 from public.batch_items i left join public.docs d on d.id = i.doc_id
              where i.batch_id = p_batch
                and ((i.employee_id is not null and not app.can_see_employee(i.employee_id))
                     or (d.id is not null and not app.can_see_employee(d.employee_id)))) then
    perform app.fail('forbidden', 'الدفعة تشمل سندات خارج نطاق بياناتك؛ يحذفها من يملك نطاقها كاملًا');
  end if;
end $$;

create or replace function public.preview_delete_batch(p_batch bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_perm('P05', 'delete');
  perform app.require_batch_scope(p_batch);
  if (select status from public.upload_batches where id = p_batch) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة مسبقًا');
  end if;
  return app.batch_delete_plan(p_batch);
end $$;

create or replace function public.delete_batch(p_batch bigint, p_reason text, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; x jsonb; v_kind text; v_snap record; v_dates date[] := '{}';
begin
  perform app.require_perm('P05', 'delete');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب حذف الدفعة مطلوب'); end if;
  select kind into v_kind from public.upload_batches where id = p_batch for update;
  if not found then perform app.fail('not_found', 'الدفعة غير موجودة'); end if;
  if (select status from public.upload_batches where id = p_batch) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة مسبقًا');
  end if;
  perform app.require_batch_scope(p_batch);
  v_plan := app.batch_delete_plan(p_batch);
  select array_agg(d.doc_date) into v_dates from public.docs d
   where d.id in (select (e->>'doc_id')::bigint from jsonb_array_elements((v_plan->'remove') || (v_plan->'revert')) e);
  v_dates := coalesce(v_dates, '{}') || coalesce((select array_agg((v.data->>'doc_date')::date) from public.doc_versions v
     join public.batch_items i on i.doc_id = v.doc_id and v.version = i.prev_version
    where i.id in (select (e->>'item_id')::bigint from jsonb_array_elements(v_plan->'revert') e)), '{}');
  perform app.guard_dates(v_dates, p_code);
  for x in select value from jsonb_array_elements(v_plan->'remove') loop
    perform app.write_doc((x->>'doc_id')::bigint, v_kind, app.doc_snapshot((x->>'doc_id')::bigint), 'deleted', null, 'batch_delete',
                          false, p_reason);
    update public.batch_items set outcome = 'removed' where id = (x->>'item_id')::bigint;
  end loop;
  for x in select value from jsonb_array_elements(v_plan->'revert') loop
    select v.data, v.status, v.manual_edit into v_snap from public.doc_versions v
      join public.batch_items i on i.doc_id = v.doc_id and v.version = i.prev_version
     where i.id = (x->>'item_id')::bigint;
    perform app.write_doc((x->>'doc_id')::bigint, v_kind, v_snap.data, v_snap.status, null, 'batch_revert', v_snap.manual_edit, p_reason);
    update public.batch_items set outcome = 'reverted' where id = (x->>'item_id')::bigint;
  end loop;
  -- المتعارض يعزل للمراجعة دون حذف أو استعادة إصدار أقدم (B054)
  update public.batch_items set conflict_on_delete = true
   where id in (select (e->>'item_id')::bigint from jsonb_array_elements(v_plan->'conflicts') e);
  update public.batch_items set outcome = 'excluded', decided_at = now(), decided_by = auth.uid()
   where batch_id = p_batch and outcome is null;
  update public.upload_batches set status = 'deleted', deleted_at = now(), deleted_by = auth.uid(), delete_reason = p_reason
   where id = p_batch;
  perform app.audit('upload_batches', p_batch::text, 'delete_batch', null, v_plan, p_reason);
  return v_plan;
end $$;

-- ---------------------------------------------------------------------
-- صفحات الحركات: التحرير الكامل والنقل والحذف (TXN-001، TXN-002، TXN-004، B049، AUTH-004)
-- ---------------------------------------------------------------------
create or replace function app.visible_doc(p_doc bigint) returns public.docs
language plpgsql stable security definer set search_path = public, app as $$
declare
  d public.docs;
begin
  select * into d from public.docs where id = p_doc;
  if not found or d.status <> 'active' then perform app.fail('not_found', 'السند غير موجود أو محذوف'); end if;
  if not app.can_see_employee(d.employee_id) then perform app.fail('forbidden', 'السند خارج نطاق بياناتك'); end if;
  return d;
end $$;

-- p_data بصيغة السند الموحد: {doc_number, customer_number, doc_date, employee_number, pay_type, lines: [...]}
create or replace function public.save_doc(p_doc bigint, p_data jsonb, p_reason text default null, p_code text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare
  d public.docs; v jsonb; v_norm jsonb; v_before jsonb; v_msg text;
begin
  perform app.require_perm('P06', 'edit');
  d := app.visible_doc(p_doc);
  v := app.validate_doc(d.kind, p_data, app.all_columns(d.kind));
  if jsonb_array_length(v->'errors') > 0 then
    select string_agg(case when (e->>'row')::int > 0 then 'البند ' || (e->>'row') || ': ' else '' end || (e->>'message'), ' — ')
      into v_msg from (select e from jsonb_array_elements(v->'errors') e limit 5) s;
    perform app.fail('invalid_doc', v_msg);
  end if;
  v_norm := v->'norm';
  if (select id from public.employees where emp_number = v_norm->>'employee_number') is distinct from d.employee_id then
    perform app.require_perm('P06', 'transfer');
    perform app.require_employee_scope((select id from public.employees where emp_number = v_norm->>'employee_number'));
  end if;
  if d.kind = 'invoice' and v_norm->>'pay_type' is null then
    perform app.fail('invalid_doc', 'نوع الفاتورة مطلوب: «فاتورة نقدي» أو «فاتورة ذمم»');
  end if;
  if exists (select 1 from public.docs where kind = d.kind and id <> d.id and doc_number = v_norm->>'doc_number'
               and customer_number = v_norm->>'customer_number' and doc_date = (v_norm->>'doc_date')::date) then
    perform app.fail('key_collision', 'المفتاح المعدل (رقم السند والعميل والتاريخ) مستخدم لسند آخر؛ لا يُحفظ حتى يُحل التصادم دون دمج');
  end if;
  perform app.guard_dates(array[d.doc_date, (v_norm->>'doc_date')::date], p_code);
  v_before := app.doc_snapshot(d.id);
  if app.doc_canon(d.kind, v_norm, app.all_columns(d.kind)) = app.doc_canon(d.kind, v_before, app.all_columns(d.kind))
     and v_norm->>'customer_name' is not distinct from v_before->>'customer_name' then
    return d.id;   -- لا تغيير
  end if;
  perform app.write_doc(d.id, d.kind, v_norm, 'active', null, 'manual', true, p_reason);
  perform app.audit('docs', d.id::text, 'edit', v_before, v_norm, p_reason);
  return d.id;
end $$;

create or replace function public.preview_transfer(p_doc_ids jsonb, p_employee_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  p_ids bigint[] := (select coalesce(array_agg(x::bigint), '{}') from jsonb_array_elements_text(p_doc_ids) x);
  v_emp public.employees;
begin
  perform app.require_perm('P06', 'transfer');
  select * into v_emp from public.employees where emp_number = trim(p_employee_number);
  if not found then perform app.fail('unknown_employee', 'موظف غير معرّف: ' || coalesce(p_employee_number, '')); end if;
  perform app.require_employee_scope(v_emp.id);
  return (
    select jsonb_build_object(
      'to', jsonb_build_object('emp_number', v_emp.emp_number, 'name', v_emp.name),
      'count', count(*) filter (where d.employee_id <> v_emp.id),
      'already', count(*) filter (where d.employee_id = v_emp.id),
      'total', coalesce(sum(d.total) filter (where d.employee_id <> v_emp.id), 0)::text,
      'from', coalesce((select jsonb_agg(jsonb_build_object('emp_number', e.emp_number, 'name', e.name, 'count', g.n, 'total', g.t::text) order by e.emp_number)
                          from (select employee_id, count(*) n, sum(total) t from public.docs
                                 where id = any(p_ids) and status = 'active' and app.can_see_employee(employee_id) and employee_id <> v_emp.id
                                 group by employee_id) g join public.employees e on e.id = g.employee_id), '[]'))
      from public.docs d where d.id = any(p_ids) and d.status = 'active' and app.can_see_employee(d.employee_id));
end $$;

-- نقل سند أو مجموعة إلى موظف آخر: يتغير الإسناد كاملًا والمبالغ ثابتة (TXN-002)
create or replace function public.transfer_docs(p_doc_ids jsonb, p_employee_number text, p_reason text default null,
                                                p_code text default null)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  p_ids bigint[] := (select coalesce(array_agg(x::bigint), '{}') from jsonb_array_elements_text(p_doc_ids) x);
  v_emp public.employees; d public.docs; v_snap jsonb; n int := 0;
begin
  perform app.require_perm('P06', 'transfer');
  select * into v_emp from public.employees where emp_number = trim(p_employee_number);
  if not found then perform app.fail('unknown_employee', 'موظف غير معرّف: ' || coalesce(p_employee_number, '')); end if;
  perform app.require_employee_scope(v_emp.id);
  perform app.guard_dates((select array_agg(doc_date) from public.docs where id = any(p_ids) and status = 'active'), p_code);
  for d in select * from public.docs where id = any(p_ids) and status = 'active' order by id for update loop
    if not app.can_see_employee(d.employee_id) then perform app.fail('forbidden', 'سند خارج نطاق بياناتك: ' || d.doc_number); end if;
    if d.employee_id = v_emp.id then continue; end if;
    v_snap := app.doc_snapshot(d.id);
    perform app.write_doc(d.id, d.kind, v_snap || jsonb_build_object('employee_number', v_emp.emp_number, 'employee_name', v_emp.name),
                          'active', null, 'transfer', true, p_reason);
    perform app.audit('docs', d.id::text, 'transfer', jsonb_build_object('employee_number', v_snap->>'employee_number'),
                      jsonb_build_object('employee_number', v_emp.emp_number), p_reason);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.delete_doc(p_doc bigint, p_reason text, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  d public.docs;
begin
  if not (app.has_perm('P06', 'delete') or app.has_perm('P05', 'delete')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب حذف السند مطلوب'); end if;
  d := app.visible_doc(p_doc);
  perform app.guard_dates(array[d.doc_date], p_code);
  perform app.write_doc(d.id, d.kind, app.doc_snapshot(d.id), 'deleted', null, 'delete', d.manual_edit, p_reason);
  perform app.audit('docs', d.id::text, 'delete', jsonb_build_object('doc_number', d.doc_number, 'total', d.total), null, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- عروض القراءة (بصلاحيات المستخدم)
-- ---------------------------------------------------------------------
create or replace view public.docs_v with (security_invoker = true) as
select d.id, d.kind, d.doc_number, d.customer_number, d.doc_date, d.customer_id,
       coalesce(c.name, d.customer_name_src) as customer_name, d.customer_name_src,
       d.employee_id, e.emp_number as employee_number, coalesce(e.name, d.employee_name_src) as employee_name,
       d.pay_type, d.lat, d.lng, (d.lat is not null and d.lng is not null) as has_location,
       d.net_sales, d.net_promotions, d.total, d.quantity, d.bonus, d.line_count, d.pay_methods, d.cheque_numbers,
       d.manual_edit, d.version, d.created_batch_id, d.last_batch_id,
       d.orig_doc_number, d.orig_customer_number, d.orig_doc_date,
       (d.doc_number, d.customer_number, d.doc_date) is distinct from (d.orig_doc_number, d.orig_customer_number, d.orig_doc_date) as key_changed,
       d.status, d.created_at, d.updated_at
  from public.docs d
  left join public.customers c on c.id = d.customer_id
  left join public.employees e on e.id = d.employee_id
 where d.status = 'active';

-- البنود مع السعر الطبيعي التاريخي والكمية المكافئة (QTY-002، B058، B059)
create or replace view public.doc_lines_v with (security_invoker = true) as
select l.id, l.doc_id, l.line_no, l.product_id, l.item_number, coalesce(p.name, l.item_name_src) as item_name,
       l.net_sales, l.net_promotions, coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0) as line_total,
       l.quantity, l.bonus, l.lat, l.lng, l.amount, l.pay_method, l.cheque_no, l.src_row,
       pr.price as sale_price,
       case when pr.price > 0 and d.kind <> 'collection' then (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)) / pr.price end as equivalent_qty
  from public.doc_lines l
  join public.docs d on d.id = l.doc_id
  left join public.products p on p.id = l.product_id
  left join lateral (select app.price_at(l.product_id, 'sale', d.doc_date) as price) pr on true;

create or replace view public.upload_batches_v with (security_invoker = true) as
select b.id, b.kind, b.file_name, b.sheet_name, b.row_count, b.status, b.uploaded_by_name, b.uploaded_at,
       b.deleted_at, b.delete_reason, b.columns,
       s.docs, s.added, s.updated, s.no_change, s.kept, s.excluded, s.pending, s.awaiting, s.removed, s.reverted, s.conflicts
  from public.upload_batches b
  left join lateral (
    select count(*) docs,
           count(*) filter (where outcome = 'added') added,
           count(*) filter (where outcome in ('updated', 'restored')) updated,
           count(*) filter (where outcome = 'no_change') no_change,
           count(*) filter (where outcome = 'kept_existing') kept,
           count(*) filter (where outcome = 'excluded') excluded,
           count(*) filter (where outcome is null and class = 'pending') pending,
           count(*) filter (where outcome is null) awaiting,
           count(*) filter (where outcome = 'removed') removed,
           count(*) filter (where outcome = 'reverted') reverted,
           count(*) filter (where conflict_on_delete) conflicts
      from public.batch_items i where i.batch_id = b.id) s on true;

-- البحث في صفحة الحركات مع ملخص كامل النتائج (INV-007، RET-003، COL-005)
-- p_filters: {from, to, number, customer, employee, batch, pay_type, manual, location, pay_method, cheque}
create or replace function public.docs_search(p_kind text, p_filters jsonb, p_sort text default null, p_asc boolean default true,
                                              p_offset int default 0, p_limit int default 50)
returns jsonb language plpgsql stable set search_path = public, app as $$
declare
  f jsonb := coalesce(p_filters, '{}');
  v_where text; v_sort text; v_rows jsonb; v_sum jsonb;
begin
  v_where := format('kind = %L', p_kind);
  if nullif(f->>'from', '') is not null then v_where := v_where || format(' and doc_date >= %L::date', f->>'from'); end if;
  if nullif(f->>'to', '') is not null then v_where := v_where || format(' and doc_date <= %L::date', f->>'to'); end if;
  if nullif(trim(f->>'number'), '') is not null then v_where := v_where || format(' and doc_number like %L', trim(f->>'number') || '%'); end if;
  if nullif(trim(f->>'customer'), '') is not null then
    v_where := v_where || format(' and (customer_number = %L or customer_name ilike %L)', trim(f->>'customer'), '%' || trim(f->>'customer') || '%');
  end if;
  if nullif(trim(f->>'employee'), '') is not null then
    v_where := v_where || format(' and (employee_number = %L or employee_name ilike %L)', trim(f->>'employee'), '%' || trim(f->>'employee') || '%');
  end if;
  if nullif(f->>'batch', '') is not null then
    v_where := v_where || format(' and (created_batch_id = %s or last_batch_id = %s)', (f->>'batch')::bigint, (f->>'batch')::bigint);
  end if;
  if nullif(f->>'pay_type', '') is not null then v_where := v_where || format(' and pay_type = %L', f->>'pay_type'); end if;
  if f->>'manual' = 'yes' then v_where := v_where || ' and manual_edit'; end if;
  if f->>'manual' = 'no' then v_where := v_where || ' and not manual_edit'; end if;
  if f->>'location' = 'yes' then v_where := v_where || ' and has_location'; end if;
  if f->>'location' = 'no' then v_where := v_where || ' and not has_location'; end if;
  if nullif(f->>'pay_method', '') is not null then v_where := v_where || format(' and pay_methods like %L', '%' || (f->>'pay_method') || '%'); end if;
  if nullif(trim(f->>'cheque'), '') is not null then v_where := v_where || format(' and cheque_numbers like %L', '%' || trim(f->>'cheque') || '%'); end if;
  v_sort := case when p_sort in ('doc_number', 'doc_date', 'customer_number', 'customer_name', 'employee_name', 'net_sales',
                                 'net_promotions', 'total', 'quantity', 'bonus', 'pay_type', 'pay_methods', 'line_count')
                 then p_sort else 'doc_date' end;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]'') from (select * from public.docs_v where %s order by %I %s, id %s offset %s %s) t',
                 v_where, v_sort, case when p_asc then 'asc' else 'desc' end, case when p_asc then 'asc' else 'desc' end,
                 greatest(coalesce(p_offset, 0), 0), case when p_limit is null then '' else 'limit ' || p_limit end)
    into v_rows;
  execute format('select jsonb_build_object(''count'', count(*), ''customers'', count(distinct customer_id), ''net_sales'', coalesce(sum(net_sales), 0)::text,
                  ''net_promotions'', coalesce(sum(net_promotions), 0)::text, ''total'', coalesce(sum(total), 0)::text, ''quantity'', sum(quantity)::text,
                  ''bonus'', coalesce(sum(bonus), 0)::text) from public.docs_v where %s', v_where)
    into v_sum;
  return jsonb_build_object('rows', v_rows, 'summary', v_sum);
end $$;

-- ملخص حداثة السندات لكل نوع (UPLOAD-001): أحدث تاريخ سند معتمد وآخر عملية رفع، ضمن نطاق المشاهد
create or replace function public.upload_overview() returns jsonb
language sql stable set search_path = public as $$
  select jsonb_object_agg(k, jsonb_build_object(
    'latest_doc_date', (select max(doc_date) from public.docs where kind = k and status = 'active'),
    'last_upload_at', (select max(uploaded_at) from public.upload_batches where kind = k),
    'last_batch_id', (select id from public.upload_batches where kind = k order by uploaded_at desc, id desc limit 1),
    'open_batches', (select count(*) from public.upload_batches where kind = k and status = 'open')))
  from unnest(array['invoice', 'return', 'collection']) k
$$;

-- سجل إصدارات السند ومصدرها
create or replace function public.doc_history(p_doc bigint) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('version', v.version, 'source', v.source, 'batch_id', v.batch_id,
                  'file_name', b.file_name, 'status', v.status, 'at', v.at, 'by_name', v.by_name, 'reason', v.reason,
                  'employee_number', v.data->>'employee_number', 'doc_number', v.data->>'doc_number',
                  'customer_number', v.data->>'customer_number', 'doc_date', v.data->>'doc_date', 'data', v.data)
                  order by v.version desc), '[]')
    from public.doc_versions v left join public.upload_batches b on b.id = v.batch_id
   where v.doc_id = p_doc and exists (select 1 from public.docs d where d.id = p_doc)
$$;

-- ---------------------------------------------------------------------
-- أمان الصفوف
-- ---------------------------------------------------------------------
alter table public.upload_batches enable row level security;
alter table public.docs           enable row level security;
alter table public.doc_lines      enable row level security;
alter table public.doc_versions   enable row level security;
alter table public.batch_items    enable row level security;

create policy batches_read on public.upload_batches for select to authenticated using (app.has_perm('P05'));
create policy docs_read on public.docs for select to authenticated
  using ((app.has_perm('P06') or app.has_perm('P05')) and app.can_see_employee(employee_id));
create policy doc_lines_read on public.doc_lines for select to authenticated
  using (exists (select 1 from public.docs d where d.id = doc_id));
create policy doc_versions_read on public.doc_versions for select to authenticated
  using (exists (select 1 from public.docs d where d.id = doc_id));
create policy batch_items_read on public.batch_items for select to authenticated
  using (app.has_perm('P05') and (employee_id is null or app.can_see_employee(employee_id)));

select app.apply_grants();

-- >>> 0005_accounts.sql
-- =====================================================================
-- ماستر — 0005: الحسابات والكشف
-- الأرصدة الافتتاحية والإغلاق السنوي، والإشعارات المدينة والدائنة، وسياسة توزيع
-- التحصيل، وتصنيف المرتجعات، ومحرك الذمم (Ledger وFIFO)، وكشف حساب العميل
-- والكشوف المحفوظة، والذمم الحالية.
-- المراجع: STMT-001..010، FIN-001..008، RET-005، RET-010، COL-003/007/008، ALLOC-001/002،
-- B028، B029، B031–B045، AUTH-002، AUTH-004.
--
-- نموذج الحساب:
-- * Ledger مشتق حتميًا من السندات والإشعارات والافتتاحيات، ويُحسب لكل «مجموعة» (رئيسي وفروعه
--   خلال السنة) ولكل سنة على حدة: افتتاح السنة يمثل كل ما قبلها (FIN-002، B038)، فلا تُجمع
--   حركات السنوات السابقة فوقه.
-- * يحفظ ناتج المحرك في جداول app.ledger_* ويُعلَّم المتأثر «متسخًا» بمشغلات على المصادر؛
--   تعيد دوال القراءة حساب المتسخ فقط قبل الإجابة (تحديث تلقائي ضمن النطاق المتأثر، P08).
--   فتح الكشف لا ينشئ قيدًا ولا يغير مصدرًا (STMT-001).
-- * الترتيب: التاريخ ثم الافتتاحي ثم الإشعار المدين فالدائن فالفاتورة فالتحصيل فالمرتجع،
--   ثم رقم السند تصاعديًا بترتيب طبيعي، ثم رقم العميل ثم المعرف الداخلي (FIN-001).
-- * الدائن (تحصيل، إشعار دائن، مرتجع ذمم، افتتاحي دائن) يسدد عند وروده الافتتاحي المدين
--   أولًا بالتساوي بين حسابات النطاق (FIN-004/005/007)، ثم الديون بالأقدم أولًا (COL-008)،
--   والباقي رصيد دائن يسدد الديون اللاحقة ضمن نطاقه تلقائيًا (B033، STMT-009).
-- * المرتجع يصنف عند موضعه بالرصيد الرسمي السابق له (RET-005)، ويحفظ تصنيفه؛ تغير التصنيف
--   المقترح لاحقًا يعرض للمراجعة ولا يطبق بصمت (B035).
-- =====================================================================

insert into public.settings (key, value) values ('accounts_start_year', '2026') on conflict (key) do nothing;

-- سنة بدء الأرصدة إعداد مالي للإدارة وحدها
create or replace function public.save_setting(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb;
begin
  perform app.require_perm('P21', 'edit');
  -- إعدادات الإدارة الخاصة (CARD-006، MAP-013، FIN-002) للإدارة وحدها
  if p_key in ('show_path_phrase', 'maps_spend_limit', 'accounts_start_year') then perform app.require_admin(); end if;
  select value into v_before from public.settings where key = p_key;
  insert into public.settings (key, value, updated_at, updated_by) values (p_key, p_value, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform app.audit('settings', p_key, 'update', v_before, p_value);
end $$;

-- سنة بدء الأرصدة: افتتاحها صفر معتمد (FIN-002)
create or replace function app.start_year() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from public.settings where key = 'accounts_start_year'), 2026)
$$;

-- الجزء الرقمي لرقم السند للترتيب الطبيعي؛ غير الرقمي بعده بترتيب نصي ثابت
create or replace function app.nat_num(p text) returns numeric
language sql immutable as $$
  select case when p ~ '^\s*\d{1,30}\s*$' then trim(p)::numeric end
$$;

create or replace function app.branches_at(p_master bigint, p_date date) returns bigint[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(l.customer_id order by l.customer_id), '{}') from public.customer_master_links l
   where l.master_id = p_master and daterange(l.valid_from, l.valid_to, '[]') @> p_date
$$;

-- =====================================================================
-- الجداول
-- =====================================================================

-- دفعات استيراد الافتتاحيات (FIN-003، FIN-008)
create table public.opening_batches (
  id             bigserial primary key,
  year           int not null,
  file_name      text,
  summary        jsonb not null default '{}',
  status         text not null default 'active' check (status in ('active', 'deleted')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  created_by_name text,
  deleted_at     timestamptz,
  deleted_by     uuid,
  delete_reason  text
);

-- الرصيد الافتتاحي للعميل في سنة: أساس واحد يستبدل ولا يُجمع (FIN-002). غياب الصف = غير محدد.
create table public.opening_balances (
  customer_id  bigint not null references public.customers(id),
  year         int not null check (year between 2000 and 2200),
  debit        numeric not null default 0 check (debit >= 0),     -- مدين: على العميل
  credit       numeric not null default 0 check (credit >= 0),    -- دائن: للعميل
  source       text not null check (source in ('manual', 'import', 'carry')),
  batch_id     bigint references public.opening_batches(id),
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (customer_id, year),
  check (not (debit > 0 and credit > 0))
);

-- أثر كل صف في الدفعة للتراجع عنه (FIN-008): null = لم يكن محددًا
create table public.opening_batch_items (
  id           bigserial primary key,
  batch_id     bigint not null references public.opening_batches(id),
  customer_id  bigint not null references public.customers(id),
  before       jsonb,
  after        jsonb not null,
  reverted     boolean not null default false
);
create index on public.opening_batch_items (batch_id);

-- الإغلاق السنوي وترحيل الأرصدة (B031، B038)
create table public.year_closes (
  year        int primary key,
  closed_at   timestamptz not null default now(),
  closed_by   uuid,
  closed_by_name text,
  reason      text,
  summary     jsonb not null default '{}'
);

-- الإشعارات المدينة والدائنة (B036)
create table public.account_notes (
  id             bigserial primary key,
  kind           text not null check (kind in ('debit', 'credit')),
  note_number    text not null,
  customer_id    bigint not null references public.customers(id),
  note_date      date not null,
  amount         numeric not null check (amount > 0),
  reason         text not null,
  linked_doc_id  bigint references public.docs(id),
  status         text not null default 'active' check (status in ('active', 'deleted')),
  version        int not null default 1,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  updated_at     timestamptz not null default now(),
  updated_by     uuid,
  deleted_at     timestamptz,
  deleted_by     uuid,
  delete_reason  text
);
create unique index account_notes_number on public.account_notes (kind, note_number) where status = 'active';
create index on public.account_notes (customer_id, note_date);

-- سياسة توزيع التحصيل للعميل من تاريخ (B031، B032، ALLOC-001/002).
-- branch_mode للفرع: الفرع فقط (الافتراضي) أو جميع فروع العائلة.
-- include_master للرئيسي: هل تدخل ديونه نفسه توزيع التحصيل (الافتراضي نعم، ALLOC-002).
create table public.customer_alloc_policies (
  id             bigserial primary key,
  customer_id    bigint not null references public.customers(id),
  valid_from     date not null,
  branch_mode    text not null default 'branch' check (branch_mode in ('branch', 'family')),
  include_master boolean not null default true,
  reason         text,
  created_at     timestamptz not null default now(),
  created_by     uuid,
  unique (customer_id, valid_from)
);

-- تصنيف المرتجع المعتمد: ذمم (مؤثر) أو نقدي أو غير مصنف (RET-005، RET-010، B035)
create table public.return_classes (
  doc_id        bigint primary key references public.docs(id) on delete cascade,
  class         text not null check (class in ('credit', 'cash', 'unknown')),
  prev_balance  numeric,
  decided       text not null default 'auto' check (decided in ('auto', 'review')),
  decided_at    timestamptz not null default now(),
  decided_by    uuid
);

-- الكشوف المحفوظة: إعدادات وهويات مخفية، لا نسخة Ledger (STMT-006، B043)
create table public.saved_statements (
  id           bigserial primary key,
  name         text not null,
  customer_id  bigint not null references public.customers(id),
  family       boolean not null default false,
  date_from    date not null,
  date_to      date not null,
  custom       boolean not null default false,
  options      jsonb not null default '{}',
  hidden       text[] not null default '{}',
  fingerprint  text,
  created_by   uuid,
  created_by_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- ناتج المحرك (داخلي، يُقرأ عبر الدوال فقط)
-- ---------------------------------------------------------------------

create table app.ledger_dirty (
  customer_id bigint not null,
  year        int not null,
  primary key (customer_id, year)
);

create table app.ledger_accounts (
  year           int not null,
  account_id     bigint not null,
  group_id       bigint not null,
  opening_known  boolean not null,
  primary key (year, account_id)
);

-- الحركات المؤثرة والمرتجعات بترتيب FIN-001. side: D مدين، C دائن، N مرتجع غير مؤثر
create table app.ledger_items (
  year        int not null,
  group_id    bigint not null,
  item_key    text not null,
  kind        text not null,
  ref_id      bigint not null,
  account_id  bigint not null,
  item_date   date not null,
  prio        int not null,
  sub         int not null,
  nat         numeric,
  num         text,
  cust        text,
  seq         int not null,
  amount      numeric not null,
  side        char(1) not null check (side in ('D', 'C', 'N')),
  employee_id bigint,
  ret_class   text,
  ret_prev    numeric,
  primary key (year, item_key)
);
create index on app.ledger_items (year, account_id);

-- تخصيص الدائن على الديون. mode: immediate عند ورود الدائن، pool من رصيد دائن سابق عند ورود الدين
create table app.ledger_allocs (
  year           int not null,
  group_id       bigint not null,
  credit_key     text not null,
  credit_account bigint not null,
  debt_key       text not null,
  debt_account   bigint not null,
  amount         numeric not null,
  seq            int not null,
  alloc_date     date not null,
  mode           text not null check (mode in ('immediate', 'pool'))
);
create index on app.ledger_allocs (year, debt_account);
create index on app.ledger_allocs (year, credit_account);

-- مرتجعات تغير تصنيفها المقترح عن المعتمد (B035)
create table app.ledger_reclass (
  doc_id        bigint primary key,
  year          int not null,
  account_id    bigint not null,
  current_class text not null,
  proposed      text not null,
  prev_balance  numeric
);

-- =====================================================================
-- تعليم المتأثر (مشغلات على المصادر)
-- =====================================================================

create or replace function app.mark_dirty_years(p_customers bigint[], p_from_year int)
returns void language sql security definer set search_path = public, app as $$
  insert into app.ledger_dirty (customer_id, year)
  select c, y from unnest(p_customers) c,
         generate_series(greatest(coalesce(p_from_year, app.start_year()), app.start_year() - 1),
                         extract(year from app.today())::int + 1) y
  where c is not null
  on conflict do nothing
$$;

create or replace function app.trg_docs_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    insert into app.ledger_dirty select distinct customer_id, extract(year from doc_date)::int from old_rows on conflict do nothing;
  end if;
  if tg_op in ('UPDATE', 'INSERT') then
    insert into app.ledger_dirty select distinct customer_id, extract(year from doc_date)::int from new_rows on conflict do nothing;
  end if;
  return null;
end $$;
create trigger docs_dirty_ins after insert on public.docs referencing new table as new_rows
  for each statement execute function app.trg_docs_dirty();
create trigger docs_dirty_upd after update on public.docs referencing old table as old_rows new table as new_rows
  for each statement execute function app.trg_docs_dirty();
create trigger docs_dirty_del after delete on public.docs referencing old table as old_rows
  for each statement execute function app.trg_docs_dirty();

create or replace function app.trg_notes_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    insert into app.ledger_dirty select distinct customer_id, extract(year from note_date)::int from old_rows on conflict do nothing;
  end if;
  if tg_op in ('UPDATE', 'INSERT') then
    insert into app.ledger_dirty select distinct customer_id, extract(year from note_date)::int from new_rows on conflict do nothing;
  end if;
  return null;
end $$;
create trigger notes_dirty_ins after insert on public.account_notes referencing new table as new_rows
  for each statement execute function app.trg_notes_dirty();
create trigger notes_dirty_upd after update on public.account_notes referencing old table as old_rows new table as new_rows
  for each statement execute function app.trg_notes_dirty();
create trigger notes_dirty_del after delete on public.account_notes referencing old table as old_rows
  for each statement execute function app.trg_notes_dirty();

create or replace function app.trg_openings_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    insert into app.ledger_dirty select distinct customer_id, year from old_rows on conflict do nothing;
  end if;
  if tg_op in ('UPDATE', 'INSERT') then
    insert into app.ledger_dirty select distinct customer_id, year from new_rows on conflict do nothing;
  end if;
  return null;
end $$;
create trigger openings_dirty_ins after insert on public.opening_balances referencing new table as new_rows
  for each statement execute function app.trg_openings_dirty();
create trigger openings_dirty_upd after update on public.opening_balances referencing old table as old_rows new table as new_rows
  for each statement execute function app.trg_openings_dirty();
create trigger openings_dirty_del after delete on public.opening_balances referencing old table as old_rows
  for each statement execute function app.trg_openings_dirty();

-- تغير ارتباط الفروع أو سياسة التوزيع: يتأثر العميل ورئيسه وفروعه في السنوات المعنية
create or replace function app.trg_links_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  for r in select * from (select customer_id, master_id, valid_from from old_rows
                          union all select customer_id, master_id, valid_from from new_rows) x loop
    perform app.mark_dirty_years(array[r.customer_id, r.master_id], extract(year from r.valid_from)::int);
  end loop;
  return null;
end $$;
create trigger links_dirty_upd after update on public.customer_master_links referencing old table as old_rows new table as new_rows
  for each statement execute function app.trg_links_dirty();

create or replace function app.trg_links_dirty_one() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  perform app.mark_dirty_years(array[r.customer_id, r.master_id], extract(year from r.valid_from)::int);
  return null;
end $$;
create trigger links_dirty_ins after insert or delete on public.customer_master_links
  for each row execute function app.trg_links_dirty_one();

create or replace function app.trg_policy_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r public.customer_alloc_policies;
begin
  if tg_op = 'DELETE' then r := old; else r := new; end if;
  perform app.mark_dirty_years(
    array[r.customer_id]
    || coalesce((select array_agg(distinct x) from (select master_id x from public.customer_master_links where customer_id = r.customer_id
                                                    union select customer_id from public.customer_master_links where master_id = r.customer_id) s), '{}'),
    extract(year from r.valid_from)::int);
  return null;
end $$;
create trigger policy_dirty after insert or update or delete on public.customer_alloc_policies
  for each row execute function app.trg_policy_dirty();

-- إغلاق سنة يجعل افتتاح التالية معلومًا لمن لا صف له
create or replace function app.trg_close_dirty() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  y int := coalesce(new.year, old.year) + 1;
begin
  insert into app.ledger_dirty
  select distinct customer_id, y from public.docs where doc_date between make_date(y, 1, 1) and make_date(y, 12, 31)
  union select distinct customer_id, y from public.account_notes where note_date between make_date(y, 1, 1) and make_date(y, 12, 31)
  union select customer_id, y from public.opening_balances where year = y
  union select account_id, y from app.ledger_accounts where year = y
  on conflict do nothing;
  return null;
end $$;
create trigger close_dirty after insert or update or delete on public.year_closes
  for each row execute function app.trg_close_dirty();

-- =====================================================================
-- المحرك
-- =====================================================================

-- هل افتتاح السنة معلوم للعميل؟ صف مسجل، أو سنة البدء (صفر معتمد)، أو أُغلقت السنة السابقة.
-- غياب افتتاح سنة أخرى لا يساوي صفرًا (FIN-002).
create or replace function app.opening_known(p_customer bigint, p_year int) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from public.opening_balances where customer_id = p_customer and year = p_year)
      or p_year = app.start_year()
      or exists (select 1 from public.year_closes where year = p_year - 1) and p_year > app.start_year()
$$;

-- نطاق تصنيف المرتجع (RET-005): الرئيسي يفحص صافي عائلته، والفرع والمستقل حسابه وحده
create or replace function app.class_scope(p_customer bigint, p_date date) returns bigint[]
language sql stable security definer set search_path = public, app as $$
  select case when app.master_of(p_customer, p_date) is null then p_customer || app.branches_at(p_customer, p_date)
              else array[p_customer] end
$$;

-- RET-010: رصيد المرتجع السابق معلوم إذا عُرف افتتاح كل حسابات نطاق تصنيفه
create or replace function app.ret_balance_known(p_customer bigint, p_date date) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from unnest(app.class_scope(p_customer, p_date)) c
                      where not app.opening_known(c, extract(year from p_date)::int))
$$;

create or replace function app.policy_at(p_customer bigint, p_date date) returns public.customer_alloc_policies
language sql stable security definer set search_path = public as $$
  select p.* from public.customer_alloc_policies p
   where p.customer_id = p_customer and p.valid_from <= p_date
   order by p.valid_from desc limit 1
$$;

-- الحسابات المؤهلة لتسديدها من دائن الحساب في تاريخه (B031، B032، ALLOC-002، FIN-004)
create or replace function app.alloc_scope(p_account bigint, p_date date) returns bigint[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  m bigint := app.master_of(p_account, p_date);
  br bigint[];
  pol public.customer_alloc_policies;
  inc boolean;
begin
  if m is null then
    br := app.branches_at(p_account, p_date);
    if coalesce(array_length(br, 1), 0) = 0 then return array[p_account]; end if;
    pol := app.policy_at(p_account, p_date);
    inc := coalesce(pol.include_master, true);
    return case when inc then p_account || br else br end;
  end if;
  pol := app.policy_at(p_account, p_date);
  if coalesce(pol.branch_mode, 'branch') = 'branch' then return array[p_account]; end if;
  inc := coalesce((app.policy_at(m, p_date)).include_master, true);
  return case when inc then m || app.branches_at(m, p_date) else app.branches_at(m, p_date) end;
end $$;

-- أعضاء مجموعة العميل في السنة: كل من ارتبط به أو بفروعه/رئيسه خلالها
create or replace function app.group_members(p_customer bigint, p_year int) returns bigint[]
language sql stable security definer set search_path = public as $$
  with recursive yr as (select daterange(make_date(p_year, 1, 1), make_date(p_year, 12, 31), '[]') r),
  comp(id) as (
    select p_customer
    union
    select case when l.customer_id = c.id then l.master_id else l.customer_id end
      from comp c join public.customer_master_links l on (l.customer_id = c.id or l.master_id = c.id)
      cross join yr where daterange(l.valid_from, l.valid_to, '[]') && yr.r
  )
  select array_agg(id order by id) from comp
$$;

-- تشغيل المحرك لمجموعة وسنة وكتابة الناتج
create or replace function app.run_ledger(p_members bigint[], p_year int) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  y0 date := make_date(p_year, 1, 1);
  y1 date := make_date(p_year, 12, 31);
  v_gid bigint := (select min(x) from unnest(p_members) x);
  e record; dr record; pr record;
  v_rem numeric; v_x numeric; v_scope bigint[]; v_cs bigint[];
  v_bal numeric; v_prop text; v_eff text; v_st public.return_classes;
  v_n int; v_share numeric; v_i int;
begin
  create temp table if not exists _lg_ev (
    seq int, key text, kind text, ref_id bigint, account bigint, d date, prio int, sub int,
    nat numeric, num text, cust text, amount numeric, side char(1), employee bigint, ret_class text, ret_prev numeric
  ) on commit drop;
  create temp table if not exists _lg_debt (key text primary key, account bigint, seq int, is_open boolean, remaining numeric) on commit drop;
  create temp table if not exists _lg_pool (key text primary key, account bigint, seq int, remaining numeric, scope bigint[]) on commit drop;
  create temp table if not exists _lg_alloc (credit_key text, credit_account bigint, debt_key text, debt_account bigint,
                                             amount numeric, seq int, d date, mode text) on commit drop;
  create temp table if not exists _lg_reclass (doc_id bigint, account bigint, cur text, prop text, prev numeric) on commit drop;
  truncate _lg_ev, _lg_debt, _lg_pool, _lg_alloc, _lg_reclass;

  insert into _lg_ev (seq, key, kind, ref_id, account, d, prio, sub, nat, num, cust, amount, side, employee)
  select row_number() over (order by s.d, s.prio, s.sub, s.nat nulls last, s.num, s.cust, s.ref_id)::int, s.*
    from (
      select 'open:' || o.customer_id key, 'open_debit' kind, o.customer_id ref_id, o.customer_id account, y0 d, 0 prio, 0 sub,
             null::numeric nat, null::text num, c.customer_number cust, o.debit amount, 'D'::char(1) side, null::bigint employee
        from public.opening_balances o join public.customers c on c.id = o.customer_id
       where o.year = p_year and o.customer_id = any(p_members) and o.debit > 0
      union all
      select 'open:' || o.customer_id, 'open_credit', o.customer_id, o.customer_id, y0, 0, 1, null, null, c.customer_number, o.credit, 'C', null
        from public.opening_balances o join public.customers c on c.id = o.customer_id
       where o.year = p_year and o.customer_id = any(p_members) and o.credit > 0
      union all
      select 'note:' || n.id, n.kind || '_note', n.id, n.customer_id, n.note_date, case n.kind when 'debit' then 1 else 2 end, 0,
             app.nat_num(n.note_number), n.note_number, c.customer_number, n.amount, case n.kind when 'debit' then 'D' else 'C' end,
             (select employee_id from public.docs where id = n.linked_doc_id)
        from public.account_notes n join public.customers c on c.id = n.customer_id
       where n.status = 'active' and n.customer_id = any(p_members) and n.note_date between y0 and y1
      union all
      select 'doc:' || x.id, x.kind, x.id, x.customer_id, x.doc_date,
             case x.kind when 'invoice' then 3 when 'collection' then 4 else 5 end, 0,
             app.nat_num(x.doc_number), x.doc_number, x.customer_number,
             abs(x.total),
             case when x.kind = 'invoice' then 'D' when x.kind = 'return' then 'R'
                  when x.total < 0 then 'D' else 'C' end,
             x.employee_id
        from public.docs x
       where x.status = 'active' and x.customer_id = any(p_members) and x.doc_date between y0 and y1
         and (x.kind <> 'invoice' or x.pay_type = 'فاتورة ذمم')
         and x.total <> 0
    ) s;

  for e in select * from _lg_ev order by seq loop
    if e.side = 'R' then
      -- تصنيف المرتجع بالرصيد الرسمي قبله في موضعه (RET-005، FIN-001)
      v_cs := app.class_scope(e.account, e.d);
      if exists (select 1 from unnest(v_cs) c where not app.opening_known(c, p_year)) then
        v_prop := 'unknown'; v_bal := null;
      else
        v_bal := coalesce((select sum(remaining) from _lg_debt where account = any(v_cs)), 0)
               - coalesce((select sum(remaining) from _lg_pool where account = any(v_cs)), 0);
        v_prop := case when v_bal > 0 then 'credit' else 'cash' end;
      end if;
      select * into v_st from public.return_classes where doc_id = e.ref_id;
      if not found or v_st.class = 'unknown' then
        v_eff := v_prop;
        if not found or v_prop <> 'unknown' then
          insert into public.return_classes (doc_id, class, prev_balance, decided, decided_at, decided_by)
          values (e.ref_id, v_prop, v_bal, 'auto', now(), null)
          on conflict (doc_id) do update set class = excluded.class, prev_balance = excluded.prev_balance,
                                             decided = 'auto', decided_at = now(), decided_by = null;
        end if;
      else
        v_eff := v_st.class;
        if v_st.class <> v_prop then
          insert into _lg_reclass values (e.ref_id, e.account, v_st.class, v_prop, v_bal);
        end if;
      end if;
      update _lg_ev set ret_class = v_eff, ret_prev = v_bal, side = case when v_eff = 'credit' then 'C' else 'N' end where seq = e.seq;
      if v_eff <> 'credit' then continue; end if;
      e.side := 'C';
    end if;

    if e.side = 'D' then
      insert into _lg_debt values (e.key, e.account, e.seq, e.kind = 'open_debit', e.amount);
      v_rem := e.amount;
      for pr in select * from _lg_pool where remaining > 0 and e.account = any(scope) order by seq loop
        exit when v_rem <= 0;
        v_x := least(pr.remaining, v_rem);
        update _lg_pool set remaining = remaining - v_x where key = pr.key;
        v_rem := v_rem - v_x;
        insert into _lg_alloc values (pr.key, pr.account, e.key, e.account, v_x, e.seq, e.d, 'pool');
      end loop;
      update _lg_debt set remaining = v_rem where key = e.key;
    else
      v_scope := app.alloc_scope(e.account, e.d);
      v_rem := e.amount;
      -- الافتتاحي المدين أولًا، بالتساوي بين حسابات النطاق مع إعادة توزيع الفائض (FIN-004، FIN-005)
      loop
        select count(*) into v_n from _lg_debt where is_open and remaining > 0 and account = any(v_scope);
        exit when v_n = 0 or v_rem <= 0;
        v_share := round(v_rem / v_n, 6);
        if v_share <= 0 then v_share := v_rem; end if;
        if exists (select 1 from _lg_debt where is_open and remaining > 0 and account = any(v_scope) and remaining <= v_share) then
          for dr in select * from _lg_debt where is_open and remaining > 0 and account = any(v_scope) and remaining <= v_share order by seq loop
            insert into _lg_alloc values (e.key, e.account, dr.key, dr.account, dr.remaining, e.seq, e.d, 'immediate');
            update _lg_debt set remaining = 0 where key = dr.key;
            v_rem := v_rem - dr.remaining;
          end loop;
        else
          v_i := 0;
          for dr in select * from _lg_debt where is_open and remaining > 0 and account = any(v_scope) order by seq loop
            v_i := v_i + 1;
            v_x := least(dr.remaining, case when v_i = v_n then v_rem else v_share end);
            insert into _lg_alloc values (e.key, e.account, dr.key, dr.account, v_x, e.seq, e.d, 'immediate');
            update _lg_debt set remaining = remaining - v_x where key = dr.key;
            v_rem := v_rem - v_x;
          end loop;
        end if;
      end loop;
      -- ثم الديون بالأقدم أولًا بين حسابات النطاق (COL-008)
      for dr in select * from _lg_debt where not is_open and remaining > 0 and account = any(v_scope) order by seq loop
        exit when v_rem <= 0;
        v_x := least(dr.remaining, v_rem);
        insert into _lg_alloc values (e.key, e.account, dr.key, dr.account, v_x, e.seq, e.d, 'immediate');
        update _lg_debt set remaining = remaining - v_x where key = dr.key;
        v_rem := v_rem - v_x;
      end loop;
      -- الباقي رصيد دائن لصاحبه يسدد الديون اللاحقة ضمن نطاقه (B033، STMT-009)
      if v_rem > 0 then
        insert into _lg_pool values (e.key, e.account, e.seq, v_rem, v_scope);
      end if;
    end if;
  end loop;

  delete from app.ledger_items where year = p_year and account_id = any(p_members);
  delete from app.ledger_allocs where year = p_year and (credit_account = any(p_members) or debt_account = any(p_members));
  delete from app.ledger_reclass where year = p_year and account_id = any(p_members);
  delete from app.ledger_accounts where year = p_year and account_id = any(p_members);

  insert into app.ledger_accounts select p_year, m, v_gid, app.opening_known(m, p_year) from unnest(p_members) m;
  insert into app.ledger_items
  select p_year, v_gid, key, kind, ref_id, account, d, prio, sub, nat, num, cust, seq, amount, side, employee, ret_class, ret_prev
    from _lg_ev;
  insert into app.ledger_allocs
  select p_year, v_gid, credit_key, credit_account, debt_key, debt_account, amount, seq, d, mode from _lg_alloc where amount > 0;
  insert into app.ledger_reclass select doc_id, p_year, account, cur, prop, prev from _lg_reclass;
end $$;

-- إعادة حساب المتأثر فقط؛ تستدعيها دوال القراءة قبل الإجابة
create or replace function app.refresh_ledger() returns void
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_members bigint[];
begin
  if not exists (select 1 from app.ledger_dirty) then return; end if;
  perform pg_advisory_xact_lock(hashtext('master.ledger_refresh'));
  loop
    select * into r from app.ledger_dirty order by year, customer_id limit 1;
    exit when not found;
    v_members := app.group_members(r.customer_id, r.year);
    perform app.run_ledger(v_members, r.year);
    delete from app.ledger_dirty where year = r.year and customer_id = any(v_members);
  end loop;
end $$;

-- رصيد الحساب في نهاية السنة من ناتج المحرك: الديون المتبقية ناقص رصيده الدائن غير المستخدم
create or replace function app.year_balance(p_account bigint, p_year int) returns numeric
language sql stable security definer set search_path = public, app as $$
  select coalesce((select sum(case side when 'D' then amount when 'C' then -amount else 0 end)
                     from app.ledger_items where year = p_year and account_id = p_account), 0)
       - coalesce((select sum(amount) from app.ledger_allocs where year = p_year and debt_account = p_account), 0)
       + coalesce((select sum(amount) from app.ledger_allocs where year = p_year and credit_account = p_account), 0)
$$;

-- =====================================================================
-- RET-010: المرتجع الذي لا يعرف رصيده السابق يعلق كخطأ يمنع الاعتماد
-- =====================================================================

alter function app.validate_doc(text, jsonb, text[]) rename to validate_doc_base;

create or replace function app.validate_doc(p_kind text, p_data jsonb, p_cols text[])
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.validate_doc_base(p_kind, p_data, p_cols);
  v_cust bigint; v_date date;
begin
  if p_kind <> 'return' then return v; end if;
  select id into v_cust from public.customers where customer_number = v->'norm'->>'customer_number';
  v_date := (v->'norm'->>'doc_date')::date;
  if v_cust is not null and v_date is not null and not app.ret_balance_known(v_cust, v_date) then
    v := jsonb_set(v, '{errors}', (v->'errors') || app.err(coalesce(nullif(p_data->'lines'->0->>'row', '')::int, 0), 'CustomerNumber',
      v->'norm'->>'customer_number',
      'الرصيد السابق للعميل غير معلوم (افتتاح ' || extract(year from v_date)::int || ' غير محدد)؛ لا يصنف المرتجع حتى يُعرف الرصيد. سجّل الافتتاحي أو أغلق السنة السابقة ثم أعد الفحص (RET-010)'));
  end if;
  return v;
end $$;

-- =====================================================================
-- الأرصدة الافتتاحية (FIN-002، FIN-003، FIN-006، FIN-008، B040)
-- =====================================================================

create or replace function app.opening_json(p_customer bigint, p_year int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('debit', debit, 'credit', credit, 'source', source)
    from public.opening_balances where customer_id = p_customer and year = p_year
$$;

create or replace function app.check_year(p_year int) returns void
language plpgsql immutable as $$
begin
  if p_year is null or p_year < 2000 or p_year > 2200 then perform app.fail('bad_year', 'السنة غير صحيحة'); end if;
end $$;

-- إضافة أو تعديل فردي في أي وقت (FIN-002): يستبدل القيمة ولا يجمعها، والتصفير بصفر صريح
create or replace function public.save_opening(p_customer bigint, p_year int, p_debit numeric, p_credit numeric,
                                               p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb;
begin
  perform app.check_year(p_year);
  v_before := app.opening_json(p_customer, p_year);
  perform app.require_perm('P08a', case when v_before is null then 'add' else 'edit' end);
  perform app.require_customer_scope(p_customer);
  if p_debit is null and p_credit is null then
    perform app.fail('opening_blank', 'الخانتان فارغتان: لا تغيير. للتصفير أدخل صفرًا صريحًا');
  end if;
  if coalesce(p_debit, 0) < 0 or coalesce(p_credit, 0) < 0 then
    perform app.fail('opening_negative', 'المبلغ لا يكون سالبًا؛ استعمل خانة المدين أو الدائن');
  end if;
  if coalesce(p_debit, 0) > 0 and coalesce(p_credit, 0) > 0 then
    perform app.fail('opening_both', 'لا يكون الرصيد مدينًا ودائنًا معًا');
  end if;
  perform app.guard_dates(array[make_date(p_year, 1, 1)], p_code);
  insert into public.opening_balances (customer_id, year, debit, credit, source, batch_id, updated_at, updated_by)
  values (p_customer, p_year, coalesce(p_debit, 0), coalesce(p_credit, 0), 'manual', null, now(), auth.uid())
  on conflict (customer_id, year) do update set debit = excluded.debit, credit = excluded.credit, source = 'manual',
                                               batch_id = null, updated_at = now(), updated_by = auth.uid();
  perform app.audit('opening_balances', p_customer || ':' || p_year, case when v_before is null then 'create' else 'update' end,
                    v_before, app.opening_json(p_customer, p_year), p_reason);
end $$;

-- خطة الاستيراد: p_rows [{row, customer_number, customer_name, debit, credit}] نصوصًا كما وردت
create or replace function app.opening_import_plan(p_year int, p_rows jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb; v_out jsonb := '[]';
  v_num text; v_d text; v_c text; v_dn numeric; v_cn numeric; v_cust public.customers;
  v_errs jsonb; v_status text; v_cur public.opening_balances; v_note text;
begin
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_errs := '[]'; v_note := null; v_cur := null; v_cust := null;
    v_num := nullif(trim(r->>'customer_number'), '');
    v_d := nullif(trim(r->>'debit'), ''); v_c := nullif(trim(r->>'credit'), '');
    v_dn := null; v_cn := null;
    if v_num is null then
      v_errs := v_errs || to_jsonb('رقم العميل مفقود'::text);
    else
      select * into v_cust from public.customers where customer_number = v_num;
      if v_cust.id is null then
        v_errs := v_errs || to_jsonb(('عميل غير معرّف: ' || v_num)::text);
      elsif not app.can_see_customer(v_cust.id) then
        v_errs := v_errs || to_jsonb(('العميل ' || v_num || ' خارج نطاق بياناتك')::text);
      end if;
      if (select count(*) from jsonb_array_elements(p_rows) x where trim(x->>'customer_number') = v_num) > 1 then
        v_errs := v_errs || to_jsonb('رقم العميل مكرر في الملف؛ لا تُجمع الصفوف'::text);
      end if;
    end if;
    if v_d is not null then
      if app.is_bad_num(v_d) then v_errs := v_errs || to_jsonb(('قيمة المدين غير رقمية: ' || v_d)::text);
      else v_dn := app.to_num(v_d); if v_dn < 0 then v_errs := v_errs || to_jsonb('مبلغ المدين سالب'::text); end if; end if;
    end if;
    if v_c is not null then
      if app.is_bad_num(v_c) then v_errs := v_errs || to_jsonb(('قيمة الدائن غير رقمية: ' || v_c)::text);
      else v_cn := app.to_num(v_c); if v_cn < 0 then v_errs := v_errs || to_jsonb('مبلغ الدائن سالب'::text); end if; end if;
    end if;
    if coalesce(v_dn, 0) > 0 and coalesce(v_cn, 0) > 0 then
      v_errs := v_errs || to_jsonb('مبلغان موجبان في المدين والدائن معًا'::text);
    end if;
    if v_cust.id is not null then
      select * into v_cur from public.opening_balances where customer_id = v_cust.id and year = p_year;
    end if;
    if jsonb_array_length(v_errs) > 0 then
      v_status := 'error';
    elsif v_d is null and v_c is null then
      v_status := 'blank';
      v_note := 'الخانتان فارغتان: يبقى الرصيد المحفوظ دون تغيير (FIN-006)';
    else
      v_dn := coalesce(v_dn, 0); v_cn := coalesce(v_cn, 0);
      if (v_d is null) <> (v_c is null) then
        v_note := 'الخانة الفارغة تعد صفرًا لوجود رقم في الجهة الأخرى (FIN-006)';
      end if;
      if v_cur.customer_id is null then v_status := 'new';
      elsif v_cur.debit = v_dn and v_cur.credit = v_cn then v_status := 'same';
      elsif v_cur.source = 'manual' then v_status := 'manual_conflict';
      else v_status := 'changed';
      end if;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'row', r->'row', 'customer_number', v_num, 'customer_name', coalesce(v_cust.name, nullif(trim(r->>'customer_name'), '')),
      'customer_id', v_cust.id, 'status', v_status, 'errors', v_errs, 'note', v_note,
      'debit', case when v_status in ('new', 'same', 'changed', 'manual_conflict') then v_dn end,
      'credit', case when v_status in ('new', 'same', 'changed', 'manual_conflict') then v_cn end,
      'current', case when v_cur.customer_id is not null then jsonb_build_object('debit', v_cur.debit, 'credit', v_cur.credit, 'source', v_cur.source) end));
  end loop;
  return v_out;
end $$;

create or replace function public.preview_opening_import(p_year int, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb;
begin
  perform app.check_year(p_year);
  perform app.require_perm('P08a', 'import');
  v_plan := app.opening_import_plan(p_year, p_rows);
  return jsonb_build_object('year', p_year, 'rows', v_plan, 'counts',
    (select jsonb_object_agg(s, n) from (select x->>'status' s, count(*) n from jsonb_array_elements(v_plan) x group by 1) c));
end $$;

-- الاعتماد: يضيف الجديد، ويستبدل المختلف فقط بموافقة صريحة لكل عميل (p_accept أرقام العملاء)،
-- ويبقي اليدوي عند التعارض ما لم يُختر الملف صراحة، ويتجاوز الأخطاء والفارغ (FIN-003)
create or replace function public.commit_opening_import(p_year int, p_rows jsonb, p_accept jsonb, p_file_name text,
                                                        p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; r jsonb; v_batch bigint; v_before jsonb; v_after jsonb;
  v_counts jsonb := '{"added":0,"replaced":0,"kept":0,"same":0,"blank":0,"errors":0}';
  v_acc text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(p_accept, '[]'))), '{}');
  k text;
begin
  perform app.check_year(p_year);
  perform app.require_perm('P08a', 'import');
  v_plan := app.opening_import_plan(p_year, p_rows);
  if exists (select 1 from jsonb_array_elements(v_plan) x
              where x->>'status' = 'new' or (x->>'status' in ('changed', 'manual_conflict') and x->>'customer_number' = any(v_acc))) then
    perform app.guard_dates(array[make_date(p_year, 1, 1)], p_code);
  end if;
  insert into public.opening_batches (year, file_name, created_by, created_by_name)
  values (p_year, p_file_name, auth.uid(), (select display_name from public.app_users where id = auth.uid()))
  returning id into v_batch;
  for r in select value from jsonb_array_elements(v_plan) loop
    k := case r->>'status'
           when 'new' then 'added'
           when 'same' then 'same'
           when 'blank' then 'blank'
           when 'error' then 'errors'
           else case when r->>'customer_number' = any(v_acc) then 'replaced' else 'kept' end end;
    v_counts := jsonb_set(v_counts, array[k], to_jsonb((v_counts->>k)::int + 1));
    if k in ('added', 'replaced') then
      v_before := app.opening_json((r->>'customer_id')::bigint, p_year);
      insert into public.opening_balances (customer_id, year, debit, credit, source, batch_id, updated_at, updated_by)
      values ((r->>'customer_id')::bigint, p_year, (r->>'debit')::numeric, (r->>'credit')::numeric, 'import', v_batch, now(), auth.uid())
      on conflict (customer_id, year) do update set debit = excluded.debit, credit = excluded.credit, source = 'import',
                                                   batch_id = v_batch, updated_at = now(), updated_by = auth.uid();
      v_after := app.opening_json((r->>'customer_id')::bigint, p_year);
      insert into public.opening_batch_items (batch_id, customer_id, before, after)
      values (v_batch, (r->>'customer_id')::bigint, v_before, v_after);
      perform app.audit('opening_balances', (r->>'customer_id') || ':' || p_year, 'import', v_before, v_after, 'دفعة ' || v_batch);
    end if;
  end loop;
  update public.opening_batches set summary = v_counts where id = v_batch;
  perform app.audit('opening_batches', v_batch::text, 'import', null, v_counts);
  return v_counts || jsonb_build_object('batch_id', v_batch);
end $$;

-- خطة حذف الدفعة (FIN-008، DATA-007): يعود كل رصيد إلى ما قبلها إن لم يتغير بعدها
create or replace function app.opening_batch_plan(p_batch bigint) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'customer_id', i.customer_id, 'customer_number', c.customer_number, 'customer_name', c.name,
           'before', i.before, 'after', i.after, 'current', app.opening_json(i.customer_id, b.year),
           'conflict', app.opening_json(i.customer_id, b.year) is distinct from i.after
                       or (select batch_id from public.opening_balances where customer_id = i.customer_id and year = b.year) is distinct from b.id)
         order by c.customer_number), '[]')
    from public.opening_batch_items i
    join public.opening_batches b on b.id = i.batch_id
    join public.customers c on c.id = i.customer_id
   where i.batch_id = p_batch and not i.reverted
$$;

create or replace function public.preview_delete_opening_batch(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b public.opening_batches;
begin
  perform app.require_perm('P08a', 'edit');
  select * into b from public.opening_batches where id = p_batch;
  if not found or b.status <> 'active' then perform app.fail('not_found', 'الدفعة غير موجودة أو محذوفة'); end if;
  return jsonb_build_object('batch', to_jsonb(b), 'items', app.opening_batch_plan(p_batch));
end $$;

create or replace function public.delete_opening_batch(p_batch bigint, p_reason text, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  b public.opening_batches; it jsonb; v_rev int := 0; v_conf int := 0;
begin
  perform app.require_perm('P08a', 'edit');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب حذف الدفعة مطلوب'); end if;
  select * into b from public.opening_batches where id = p_batch for update;
  if not found or b.status <> 'active' then perform app.fail('not_found', 'الدفعة غير موجودة أو محذوفة'); end if;
  for it in select value from jsonb_array_elements(app.opening_batch_plan(p_batch)) loop
    perform app.require_customer_scope((it->>'customer_id')::bigint);
  end loop;
  perform app.guard_dates(array[make_date(b.year, 1, 1)], p_code);
  for it in select value from jsonb_array_elements(app.opening_batch_plan(p_batch)) loop
    if (it->>'conflict')::boolean then
      v_conf := v_conf + 1;   -- تغير بعد الدفعة: يبقى الحالي
      continue;
    end if;
    if it->'before' is null or it->'before' = 'null'::jsonb then
      delete from public.opening_balances where customer_id = (it->>'customer_id')::bigint and year = b.year;
    else
      update public.opening_balances set debit = (it->'before'->>'debit')::numeric, credit = (it->'before'->>'credit')::numeric,
             source = it->'before'->>'source', batch_id = null, updated_at = now(), updated_by = auth.uid()
       where customer_id = (it->>'customer_id')::bigint and year = b.year;
    end if;
    update public.opening_batch_items set reverted = true where batch_id = p_batch and customer_id = (it->>'customer_id')::bigint;
    perform app.audit('opening_balances', (it->>'customer_id') || ':' || b.year, 'batch_revert', it->'after', it->'before', p_reason);
    v_rev := v_rev + 1;
  end loop;
  update public.opening_batches set status = 'deleted', deleted_at = now(), deleted_by = auth.uid(), delete_reason = p_reason
   where id = p_batch;
  perform app.audit('opening_batches', p_batch::text, 'delete', to_jsonb(b), jsonb_build_object('reverted', v_rev, 'kept', v_conf), p_reason);
  return jsonb_build_object('reverted', v_rev, 'kept', v_conf);
end $$;

-- قائمة السنة: افتتاح كل عميل في النطاق ومقارنته بإقفال السنة السابقة (P08a، B038، B040)
create or replace function public.openings_overview(p_year int) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_rows jsonb;
begin
  perform app.check_year(p_year);
  perform app.require_perm('P08a', 'view');
  perform app.refresh_ledger();
  select coalesce(jsonb_agg(x order by x->>'customer_number'), '[]') into v_rows from (
    select jsonb_build_object(
      'customer_id', c.id, 'customer_number', c.customer_number, 'name', c.name,
      'master_number', (select m.customer_number from public.customers m where m.id = app.master_of(c.id, make_date(p_year, 1, 1))),
      'debit', o.debit, 'credit', o.credit, 'source', o.source, 'updated_at', o.updated_at,
      'known', app.opening_known(c.id, p_year),
      'prev_closing', case when la.account_id is not null and la.opening_known then app.year_balance(c.id, p_year - 1) end,
      'prev_known', la.opening_known
    ) x
      from public.customers c
      left join public.opening_balances o on o.customer_id = c.id and o.year = p_year
      left join app.ledger_accounts la on la.account_id = c.id and la.year = p_year - 1
     where app.can_see_customer(c.id)
  ) s;
  return jsonb_build_object('year', p_year, 'start_year', app.start_year(),
    'prev_closed', exists (select 1 from public.year_closes where year = p_year - 1),
    'closed', (select to_jsonb(y) from public.year_closes y where y.year = p_year),
    'rows', v_rows,
    'batches', (select coalesce(jsonb_agg(to_jsonb(b) order by b.id desc), '[]') from public.opening_batches b where b.year = p_year));
end $$;

-- الإغلاق السنوي: معاينة إقفال السنة والافتتاحي المقترح للتالية والفروق (B031، B038)
create or replace function app.year_close_plan(p_year int) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x->>'customer_number'), '[]') from (
    select jsonb_build_object(
      'customer_id', c.id, 'customer_number', c.customer_number, 'name', c.name,
      'known', la.opening_known,
      'closing', case when la.opening_known then app.year_balance(c.id, p_year) end,
      'next', app.opening_json(c.id, p_year + 1),
      'diff', case when la.opening_known and o.customer_id is not null
                   then (o.debit - o.credit) - app.year_balance(c.id, p_year) end
    ) x
      from app.ledger_accounts la
      join public.customers c on c.id = la.account_id
      left join public.opening_balances o on o.customer_id = c.id and o.year = p_year + 1
     where la.year = p_year and app.can_see_customer(c.id)
       and (la.opening_known = false
            or exists (select 1 from app.ledger_items i where i.year = p_year and i.account_id = c.id)
            or exists (select 1 from public.opening_balances ob where ob.customer_id = c.id and ob.year in (p_year, p_year + 1)))
  ) s
$$;

create or replace function public.preview_year_close(p_year int) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.check_year(p_year);
  perform app.require_perm('P08a', 'approve');
  -- كل من له نشاط أو افتتاح في السنة يدخل المعاينة ولو لم يُحسب بعد
  insert into app.ledger_dirty
  select distinct customer_id, p_year from public.docs where doc_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31)
     and customer_id not in (select account_id from app.ledger_accounts where year = p_year)
  union select customer_id, p_year from public.opening_balances where year = p_year
     and customer_id not in (select account_id from app.ledger_accounts where year = p_year)
  union select distinct customer_id, p_year from public.account_notes where note_date between make_date(p_year, 1, 1) and make_date(p_year, 12, 31)
     and customer_id not in (select account_id from app.ledger_accounts where year = p_year)
  on conflict do nothing;
  perform app.refresh_ledger();
  return jsonb_build_object('year', p_year, 'closed', (select to_jsonb(y) from public.year_closes y where y.year = p_year),
                            'rows', app.year_close_plan(p_year));
end $$;

-- الاعتماد: ترحيل الإقفال افتتاحيًا للسنة التالية لمن لا افتتاح له؛ المختلف لا يُستبدل إلا
-- باختيار صريح (p_replace أرقام العملاء) مع سبب؛ القديم لا يضاف مرة ثانية (B038)
create or replace function public.commit_year_close(p_year int, p_replace jsonb, p_reason text default null, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; r jsonb; v_bal numeric; v_before jsonb;
  v_rep text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(p_replace, '[]'))), '{}');
  v_added int := 0; v_replaced int := 0; v_kept int := 0;
begin
  perform app.check_year(p_year);
  perform app.require_perm('P08a', 'approve');
  if not app.scope_is_all() then
    perform app.fail('scope_all_required', 'الإغلاق السنوي يشمل كل العملاء: يحتاج نطاق «الكل»');
  end if;
  perform public.preview_year_close(p_year);
  v_plan := app.year_close_plan(p_year);
  if exists (select 1 from jsonb_array_elements(v_plan) x where not (x->>'known')::boolean) then
    perform app.fail('unknown_openings', 'لا يغلق العام: افتتاح ' || p_year || ' غير محدد لـ'
      || (select string_agg(x->>'customer_number', '، ') from (select x from jsonb_array_elements(v_plan) x where not (x->>'known')::boolean limit 10) s));
  end if;
  if cardinality(v_rep) > 0 and coalesce(trim(p_reason), '') = '' then
    perform app.fail('reason_required', 'استبدال افتتاحي مختلف عن الإقفال يحتاج سببًا (B038)');
  end if;
  perform app.guard_dates(array[make_date(p_year + 1, 1, 1)], p_code);
  for r in select value from jsonb_array_elements(v_plan) loop
    v_bal := (r->>'closing')::numeric;
    if r->'next' is null or r->'next' = 'null'::jsonb then
      insert into public.opening_balances (customer_id, year, debit, credit, source, updated_at, updated_by)
      values ((r->>'customer_id')::bigint, p_year + 1, greatest(v_bal, 0), greatest(-v_bal, 0), 'carry', now(), auth.uid());
      perform app.audit('opening_balances', (r->>'customer_id') || ':' || (p_year + 1), 'carry', null,
                        app.opening_json((r->>'customer_id')::bigint, p_year + 1), 'إغلاق ' || p_year);
      v_added := v_added + 1;
    elsif coalesce((r->>'diff')::numeric, 0) <> 0 and r->>'customer_number' = any(v_rep) then
      v_before := r->'next';
      update public.opening_balances set debit = greatest(v_bal, 0), credit = greatest(-v_bal, 0), source = 'carry',
             batch_id = null, updated_at = now(), updated_by = auth.uid()
       where customer_id = (r->>'customer_id')::bigint and year = p_year + 1;
      perform app.audit('opening_balances', (r->>'customer_id') || ':' || (p_year + 1), 'carry', v_before,
                        app.opening_json((r->>'customer_id')::bigint, p_year + 1), p_reason);
      v_replaced := v_replaced + 1;
    elsif coalesce((r->>'diff')::numeric, 0) <> 0 then
      v_kept := v_kept + 1;
    end if;
  end loop;
  insert into public.year_closes (year, closed_by, closed_by_name, reason, summary)
  values (p_year, auth.uid(), (select display_name from public.app_users where id = auth.uid()), p_reason,
          jsonb_build_object('added', v_added, 'replaced', v_replaced, 'kept', v_kept))
  on conflict (year) do update set closed_at = now(), closed_by = excluded.closed_by, closed_by_name = excluded.closed_by_name,
                                   reason = excluded.reason, summary = excluded.summary;
  perform app.audit('year_closes', p_year::text, 'close', null,
                    jsonb_build_object('added', v_added, 'replaced', v_replaced, 'kept', v_kept), p_reason);
  return jsonb_build_object('added', v_added, 'replaced', v_replaced, 'kept', v_kept);
end $$;

-- =====================================================================
-- الإشعارات المدينة والدائنة (B036)
-- =====================================================================

create or replace function app.note_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(n) - 'created_at' - 'updated_at' - 'created_by' - 'updated_by' from public.account_notes n where n.id = p_id
$$;

-- p: {kind, note_number (فارغ = ترقيم تلقائي), customer_number, note_date, amount, reason, linked_doc_id}
create or replace function public.save_note(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  n public.account_notes; v_id bigint := p_id; v_before jsonb;
  v_kind text := p->>'kind';
  v_num text := nullif(trim(p->>'note_number'), '');
  v_cust bigint; v_date date; v_amount numeric; v_reason text := nullif(trim(p->>'reason'), '');
  v_link bigint := nullif(p->>'linked_doc_id', '')::bigint;
  v_ld public.docs;
begin
  perform app.require_perm('P09', case when p_id is null then 'add' else 'edit' end);
  if p_id is not null then
    select * into n from public.account_notes where id = p_id and status = 'active' for update;
    if not found then perform app.fail('not_found', 'الإشعار غير موجود أو محذوف'); end if;
    perform app.require_customer_scope(n.customer_id);
    v_kind := coalesce(v_kind, n.kind);
  end if;
  if v_kind is null or v_kind not in ('debit', 'credit') then perform app.fail('bad_kind', 'نوع الإشعار مدين أو دائن'); end if;
  select id into v_cust from public.customers where customer_number = trim(p->>'customer_number');
  if v_cust is null then perform app.fail('unknown_customer', 'عميل غير معرّف'); end if;
  perform app.require_customer_scope(v_cust);
  if app.is_bad_date(p->>'note_date') or nullif(trim(p->>'note_date'), '') is null then
    perform app.fail('bad_date', 'تاريخ الإشعار مطلوب بصيغة صحيحة');
  end if;
  v_date := app.to_date(p->>'note_date');
  if app.is_bad_num(p->>'amount') or nullif(trim(p->>'amount'), '') is null then
    perform app.fail('bad_amount', 'قيمة الإشعار مطلوبة رقمًا');
  end if;
  v_amount := app.to_num(p->>'amount');
  if v_amount <= 0 then perform app.fail('bad_amount', 'قيمة الإشعار أكبر من صفر؛ النوع يحدد الاتجاه'); end if;
  if v_reason is null then perform app.fail('reason_required', 'سبب الإشعار مطلوب'); end if;
  if v_link is not null then
    select * into v_ld from public.docs where id = v_link and status = 'active';
    if not found then perform app.fail('bad_link', 'السند المرتبط غير موجود أو محذوف'); end if;
    if not app.can_see_employee(v_ld.employee_id) then perform app.fail('forbidden', 'السند المرتبط خارج نطاق بياناتك'); end if;
  end if;
  perform app.guard_dates(array[v_date, n.note_date], p_code);
  if v_num is null then
    v_num := case v_kind when 'debit' then 'DN-' else 'CN-' end
             || lpad((coalesce((select max(substring(note_number from 4)::int) from public.account_notes
                                 where kind = v_kind and note_number ~ ('^' || case v_kind when 'debit' then 'DN' else 'CN' end || '-\d{1,9}$')), 0) + 1)::text, 4, '0');
  end if;
  if exists (select 1 from public.account_notes where kind = v_kind and note_number = v_num and status = 'active'
               and id is distinct from p_id) then
    perform app.fail('duplicate', 'رقم الإشعار مستخدم لإشعار آخر من النوع نفسه');
  end if;
  if p_id is null then
    insert into public.account_notes (kind, note_number, customer_id, note_date, amount, reason, linked_doc_id, created_by, updated_by)
    values (v_kind, v_num, v_cust, v_date, v_amount, v_reason, v_link, auth.uid(), auth.uid()) returning id into v_id;
  else
    v_before := app.note_json(p_id);
    update public.account_notes set kind = v_kind, note_number = v_num, customer_id = v_cust, note_date = v_date, amount = v_amount,
           reason = v_reason, linked_doc_id = v_link, version = version + 1, updated_at = now(), updated_by = auth.uid()
     where id = p_id;
  end if;
  perform app.audit('account_notes', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.note_json(v_id));
  return v_id;
end $$;

create or replace function public.delete_note(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  n public.account_notes;
begin
  perform app.require_perm('P09', 'delete');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  select * into n from public.account_notes where id = p_id and status = 'active' for update;
  if not found then perform app.fail('not_found', 'الإشعار غير موجود أو محذوف'); end if;
  perform app.require_customer_scope(n.customer_id);
  perform app.guard_dates(array[n.note_date], p_code);
  update public.account_notes set status = 'deleted', deleted_at = now(), deleted_by = auth.uid(), delete_reason = p_reason
   where id = p_id;
  perform app.audit('account_notes', p_id::text, 'delete', app.note_json(p_id) - 'status', null, p_reason);
end $$;

create or replace function public.notes_list(p_filters jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := coalesce(p_filters, '{}');
begin
  perform app.require_perm('P09', 'view');
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'note_number', n.note_number, 'customer_id', n.customer_id,
      'customer_number', c.customer_number, 'customer_name', c.name, 'note_date', n.note_date, 'amount', n.amount,
      'reason', n.reason, 'linked_doc_id', n.linked_doc_id, 'version', n.version,
      'linked_doc', (select jsonb_build_object('kind', d.kind, 'doc_number', d.doc_number, 'doc_date', d.doc_date) from public.docs d where d.id = n.linked_doc_id),
      'status', n.status, 'delete_reason', n.delete_reason)
      order by n.note_date desc, n.id desc), '[]')
    from public.account_notes n join public.customers c on c.id = n.customer_id
   where app.can_see_customer(n.customer_id)
     and (n.status = 'active' or coalesce((f->>'show_deleted')::boolean, false))
     and (f->>'kind' is null or n.kind = f->>'kind')
     and (nullif(f->>'from', '') is null or n.note_date >= (f->>'from')::date)
     and (nullif(f->>'to', '') is null or n.note_date <= (f->>'to')::date)
     and (nullif(f->>'customer_number', '') is null or c.customer_number = f->>'customer_number')
     and (nullif(f->>'search', '') is null or n.note_number ilike '%' || (f->>'search') || '%' or n.reason ilike '%' || (f->>'search') || '%'));
end $$;

-- =====================================================================
-- سياسة التوزيع (B031: للسنة الحالية كاملة أو من تاريخ؛ السنة المغلقة لا تتغير)
-- =====================================================================

create or replace function public.set_alloc_policy(p_customer bigint, p_valid_from date, p_branch_mode text,
                                                   p_include_master boolean, p_reason text default null, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb := (select to_jsonb(x) from app.policy_at(p_customer, coalesce(p_valid_from, app.today())) x);
  v_last int := (select max(year) from public.year_closes);
begin
  perform app.require_perm('P02', 'edit');
  perform app.require_customer_scope(p_customer);
  if p_valid_from is null then perform app.fail('required', 'تاريخ السريان مطلوب'); end if;
  if p_branch_mode not in ('branch', 'family') then perform app.fail('bad_mode', 'نطاق الفرع: الفرع فقط أو جميع الفروع'); end if;
  if v_last is not null and extract(year from p_valid_from)::int <= v_last then
    perform app.fail('year_closed', 'السنة ' || extract(year from p_valid_from)::int || ' مغلقة؛ سياسة التوزيع لا تغير سنة مغلقة');
  end if;
  perform app.guard_dates(array[app.first_closed_in(p_valid_from, app.today())], p_code);
  insert into public.customer_alloc_policies (customer_id, valid_from, branch_mode, include_master, reason, created_by)
  values (p_customer, p_valid_from, p_branch_mode, coalesce(p_include_master, true), p_reason, auth.uid())
  on conflict (customer_id, valid_from) do update set branch_mode = excluded.branch_mode,
         include_master = excluded.include_master, reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  perform app.audit('customer_alloc_policies', p_customer::text, 'set', v_before,
                    jsonb_build_object('valid_from', p_valid_from, 'branch_mode', p_branch_mode, 'include_master', coalesce(p_include_master, true)),
                    p_reason);
end $$;

-- =====================================================================
-- مراجعة إعادة تصنيف المرتجعات (B035)
-- =====================================================================

create or replace function public.return_reviews() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_perm('P06', 'view');
  perform app.refresh_ledger();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'doc_id', d.id, 'doc_number', d.doc_number, 'doc_date', d.doc_date, 'total', d.total,
      'customer_number', d.customer_number, 'customer_name', c.name,
      'current', r.current_class, 'proposed', r.proposed, 'prev_balance', r.prev_balance)
      order by d.doc_date, d.id), '[]')
    from app.ledger_reclass r join public.docs d on d.id = r.doc_id join public.customers c on c.id = d.customer_id
   where d.status = 'active' and app.can_see_employee(d.employee_id));
end $$;

-- تصنيف مرتجعات صفحة السندات بعد تحديث المتأثر
create or replace function public.return_classes_for(p_doc_ids jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_perm('P06', 'view');
  perform app.refresh_ledger();
  return (select coalesce(jsonb_object_agg(r.doc_id, r.class), '{}')
    from public.return_classes r join public.docs d on d.id = r.doc_id
   where r.doc_id in (select value::bigint from jsonb_array_elements_text(coalesce(p_doc_ids, '[]')))
     and app.can_see_employee(d.employee_id));
end $$;

create or replace function public.approve_return_reclass(p_doc_ids jsonb, p_code text default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare
  r record; v_n int := 0;
begin
  perform app.require_perm('P06', 'edit');
  perform app.refresh_ledger();
  for r in select rc.*, d.doc_date, d.employee_id from app.ledger_reclass rc join public.docs d on d.id = rc.doc_id
            where rc.doc_id in (select value::bigint from jsonb_array_elements_text(coalesce(p_doc_ids, '[]'))) loop
    perform app.require_employee_scope(r.employee_id);
    if r.proposed = 'unknown' then
      perform app.fail('unknown_balance', 'الرصيد السابق غير معلوم؛ لا يعاد التصنيف حتى يُعرف (RET-010)');
    end if;
    perform app.guard_dates(array[r.doc_date], p_code);
    update public.return_classes set class = r.proposed, prev_balance = r.prev_balance, decided = 'review',
           decided_at = now(), decided_by = auth.uid()
     where doc_id = r.doc_id;
    insert into app.ledger_dirty values (r.account_id, r.year) on conflict do nothing;
    perform app.audit('return_classes', r.doc_id::text, 'reclassify', jsonb_build_object('class', r.current_class),
                      jsonb_build_object('class', r.proposed, 'prev_balance', r.prev_balance), 'B035');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- =====================================================================
-- كشف حساب العميل (STMT-001..010، B034، B041–B045)
-- =====================================================================

create or replace function app.kind_name(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'invoice' then 'فاتورة' when 'return' then 'مرتجع' when 'collection' then 'تحصيل'
                     when 'debit_note' then 'إشعار مدين' when 'credit_note' then 'إشعار دائن'
                     when 'open_debit' then 'رصيد افتتاحي' when 'open_credit' then 'رصيد افتتاحي'
                     when 'opening' then 'رصيد افتتاحي' when 'transfer' then 'تسوية رصيد دائن' end
$$;

-- p_opts: {kinds: [...], affect: all|affecting|non, search, show_deleted, custom, hidden: [keys]}
create or replace function public.account_statement(p_customer bigint, p_family boolean, p_from date, p_to date, p_opts jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}');
  v_cust public.customers;
  v_master bigint;
  v_head bigint;                -- الحساب أو رئيس العائلة
  y int; yf int; yt int;
  v_fam bigint[];
  v_kinds text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(o->'kinds')), '{}');
  v_affect text := coalesce(nullif(o->>'affect', ''), 'all');
  v_search text := nullif(trim(o->>'search'), '');
  v_custom boolean := coalesce((o->>'custom')::boolean, false);
  v_hidden text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(o->'hidden')), '{}');
  v_warn jsonb := '[]';
  v_prev numeric; v_cprev numeric;
  v_res jsonb;
begin
  perform app.require_perm('P07', 'view');
  if p_from is null or p_to is null or p_from > p_to then perform app.fail('bad_period', 'حدد فترة صحيحة من/إلى'); end if;
  select * into v_cust from public.customers where id = p_customer;
  if not found then perform app.fail('not_found', 'العميل غير موجود'); end if;
  perform app.require_customer_scope(p_customer);
  v_master := app.master_of(p_customer, p_to);
  v_head := case when p_family then coalesce(v_master, p_customer) else p_customer end;
  if v_head <> p_customer then perform app.require_customer_scope(v_head); end if;
  yf := extract(year from p_from)::int; yt := extract(year from p_to)::int;
  if yt - yf > 10 then perform app.fail('bad_period', 'الفترة أطول من عشر سنوات'); end if;

  -- كل حسابات النطاق في سنوات الفترة محسوبة
  insert into app.ledger_dirty
  select c, yy from generate_series(yf, yt) yy,
         unnest(case when p_family then v_head || coalesce((select array_agg(distinct customer_id) from public.customer_master_links where master_id = v_head), '{}')
                     else array[p_customer] end) c
   where not exists (select 1 from app.ledger_accounts la where la.year = yy and la.account_id = c)
  on conflict do nothing;
  perform app.refresh_ledger();

  create temp table if not exists _st (
    key text, yr int, is_open boolean, d date, prio int, sub int, nat numeric, num text, cust text, ref bigint, sub2 int,
    kind text, account bigint, description text, signed numeric, affecting boolean, deleted boolean, doc_id bigint, note_id bigint,
    hideable boolean
  ) on commit drop;
  truncate _st;

  for y in yf..yt loop
    if p_family then
      v_fam := v_head || coalesce((select array_agg(distinct l.customer_id) from public.customer_master_links l
                                    where l.master_id = v_head
                                      and daterange(l.valid_from, l.valid_to, '[]') && daterange(make_date(y, 1, 1), make_date(y, 12, 31), '[]')), '{}');
      -- كل حركة مؤثرة مرة واحدة بقيمتها الكاملة؛ التحصيل صف واحد (COL-003، B034)
      insert into _st
      select i.item_key, y, i.kind like 'open_%', i.item_date, i.prio, i.sub, i.nat, i.num, i.cust, i.ref_id, 0, i.kind, i.account_id, null,
             case i.side when 'D' then i.amount when 'C' then -i.amount else 0 end, i.side <> 'N', false,
             case when i.item_key like 'doc:%' then i.ref_id end, case when i.item_key like 'note:%' then i.ref_id end,
             i.kind not like 'open_%'
        from app.ledger_items i
       where i.year = y and i.account_id = any(v_fam)
         and (i.account_id = v_head or app.master_of(i.account_id, i.item_date) = v_head);
    else
      v_fam := array[p_customer];
      -- ديون الحساب ومرتجعاته غير المؤثرة
      insert into _st
      select i.item_key, y, i.kind like 'open_%', i.item_date, i.prio, i.sub, i.nat, i.num, i.cust, i.ref_id, 0, i.kind, i.account_id, null,
             case i.side when 'D' then i.amount else 0 end, i.side <> 'N', false,
             case when i.item_key like 'doc:%' then i.ref_id end, case when i.item_key like 'note:%' then i.ref_id end,
             i.kind not like 'open_%'
        from app.ledger_items i where i.year = y and i.account_id = p_customer and i.side in ('D', 'N');
      -- دائن الحساب: قيمته ناقص ما خُصص منه فورًا لحسابات أخرى (حصته فقط، B034)
      insert into _st
      select i.item_key, y, i.kind like 'open_%', i.item_date, i.prio, i.sub, i.nat, i.num, i.cust, i.ref_id, 0, i.kind, i.account_id,
             case when x.other > 0 then 'حصة الحساب من ' || app.kind_name(i.kind) || ' بقيمة ' || trim_scale(i.amount)::text
                                     || '؛ خُصص الباقي لحسابات العائلة' end,
             -(i.amount - x.other), true, false,
             case when i.item_key like 'doc:%' then i.ref_id end, case when i.item_key like 'note:%' then i.ref_id end,
             i.kind not like 'open_%'
        from app.ledger_items i
        cross join lateral (select coalesce(sum(a.amount), 0) other from app.ledger_allocs a
                             where a.year = y and a.credit_key = i.item_key and a.debt_account <> p_customer and a.mode = 'immediate') x
       where i.year = y and i.account_id = p_customer and i.side = 'C';
      -- حصة الحساب من دائن حساب آخر في العائلة (كشف الفرع يعرض نصيبه، B034)
      insert into _st
      select i.item_key, y, i.kind like 'open_%', i.item_date, i.prio, i.sub, i.nat, i.num, i.cust, i.ref_id, 0, i.kind, i.account_id,
             'حصة الحساب من ' || app.kind_name(i.kind) || ' ' || coalesce(i.num, '') || ' للحساب ' || c.customer_number
               || ' بقيمة ' || trim_scale(i.amount)::text,
             -s.amt, true, false,
             case when i.item_key like 'doc:%' then i.ref_id end, case when i.item_key like 'note:%' then i.ref_id end,
             i.kind not like 'open_%'
        from (select a.credit_key, sum(a.amount) amt from app.ledger_allocs a
               where a.year = y and a.debt_account = p_customer and a.credit_account <> p_customer and a.mode = 'immediate'
               group by a.credit_key) s
        join app.ledger_items i on i.year = y and i.item_key = s.credit_key
        join public.customers c on c.id = i.account_id;
      -- تسوية رصيد دائن سابق بين حسابات العائلة عند ورود دين لاحق (STMT-009)
      insert into _st
      select 'tr:' || a.credit_key || '>' || a.debt_key, y, false, di.item_date, di.prio, di.sub, di.nat, di.num, di.cust, di.ref_id,
             1, 'transfer', p_customer,
             case when a.credit_account = p_customer
                  then 'استعمال رصيد الحساب الدائن من ' || app.kind_name(ci.kind) || ' ' || coalesce(ci.num, '') || ' لتسديد '
                       || app.kind_name(di.kind) || ' ' || coalesce(di.num, '') || ' للحساب ' || dc.customer_number
                  else 'تسديد ' || app.kind_name(di.kind) || ' ' || coalesce(di.num, '') || ' من الرصيد الدائن للحساب '
                       || cc.customer_number || ' (' || app.kind_name(ci.kind) || ' ' || coalesce(ci.num, '') || ')' end,
             case when a.credit_account = p_customer then a.amount else -a.amount end, true, false, null, null, false
        from app.ledger_allocs a
        join app.ledger_items di on di.year = y and di.item_key = a.debt_key
        join app.ledger_items ci on ci.year = y and ci.item_key = a.credit_key
        join public.customers dc on dc.id = a.debt_account
        join public.customers cc on cc.id = a.credit_account
       where a.year = y and a.mode = 'pool' and a.credit_account <> a.debt_account
         and (a.credit_account = p_customer or a.debt_account = p_customer);
    end if;

    -- الحركات غير المؤثرة: الفاتورة النقدية (B028) والفاتورة بلا نوع
    insert into _st
    select 'doc:' || x.id, y, false, x.doc_date, 3, 0, app.nat_num(x.doc_number), x.doc_number, x.customer_number, x.id, 0,
           'invoice', x.customer_id, null, 0, false, false, x.id, null, true
      from public.docs x
     where x.kind = 'invoice' and x.status = 'active' and x.pay_type is distinct from 'فاتورة ذمم'
       and x.doc_date between make_date(y, 1, 1) and make_date(y, 12, 31)
       and x.customer_id = any(v_fam)
       and (not p_family or x.customer_id = v_head or app.master_of(x.customer_id, x.doc_date) = v_head);

    -- المحذوفات للمراجعة دون أثر مالي (STMT-004، B044)
    if coalesce((o->>'show_deleted')::boolean, false) then
      insert into _st
      select 'doc:' || x.id, y, false, x.doc_date, case x.kind when 'invoice' then 3 when 'collection' then 4 else 5 end, 0,
             app.nat_num(x.doc_number), x.doc_number, x.customer_number, x.id, 0, x.kind, x.customer_id, null, 0, false, true, x.id, null, false
        from public.docs x
       where x.status = 'deleted' and x.doc_date between greatest(p_from, make_date(y, 1, 1)) and least(p_to, make_date(y, 12, 31))
         and x.customer_id = any(v_fam)
         and (not p_family or x.customer_id = v_head or app.master_of(x.customer_id, x.doc_date) = v_head);
      insert into _st
      select 'note:' || n.id, y, false, n.note_date, case n.kind when 'debit' then 1 else 2 end, 0, app.nat_num(n.note_number),
             n.note_number, c.customer_number, n.id, 0, n.kind || '_note', n.customer_id, null, 0, false, true, null, n.id, false
        from public.account_notes n join public.customers c on c.id = n.customer_id
       where n.status = 'deleted' and n.note_date between greatest(p_from, make_date(y, 1, 1)) and least(p_to, make_date(y, 12, 31))
         and n.customer_id = any(v_fam)
         and (not p_family or n.customer_id = v_head or app.master_of(n.customer_id, n.note_date) = v_head);
    end if;

    -- افتتاح غير معلوم: لا يفترض صفرًا (FIN-002)
    v_warn := v_warn || coalesce((select jsonb_agg(jsonb_build_object('code', 'opening_unknown', 'year', y,
                 'message', 'الرصيد الافتتاحي لسنة ' || y || ' غير محدد للحساب ' || c.customer_number || '؛ الأرصدة لا تشمل ما قبل السنة'))
               from app.ledger_accounts la join public.customers c on c.id = la.account_id
              where la.year = y and la.account_id = any(v_fam) and not la.opening_known), '[]');
  end loop;

  -- مرتجع غير مصنف ينبه للمراجعة (RET-005)
  v_warn := v_warn || coalesce((select jsonb_agg(jsonb_build_object('code', 'return_unknown', 'message',
               'المرتجع ' || s.num || ' غير مصنف لعدم معرفة الرصيد السابق؛ بحاجة للمراجعة'))
             from _st s join app.ledger_items i on i.year = s.yr and i.item_key = s.key
            where i.ret_class = 'unknown' and s.d between p_from and p_to), '[]');

  -- الرصيد الحقيقي لكل صف في التسلسل الكامل (B041)، والمخصص بعد استبعاد المخفي (B042)
  create temp table if not exists _st2 (
    key text, yr int, is_open boolean, d date, prio int, sub int, nat numeric, num text, cust text, ref bigint, sub2 int,
    kind text, account bigint, description text, signed numeric, affecting boolean, deleted boolean, doc_id bigint, note_id bigint,
    hideable boolean, csigned numeric, bal numeric, cbal numeric, hidden boolean, rn numeric
  ) on commit drop;
  truncate _st2;
  insert into _st2
  select s.*, case when v_custom and s.key = any(v_hidden) and s.hideable then 0 else s.signed end,
         sum(s.signed) over w,
         sum(case when v_custom and s.key = any(v_hidden) and s.hideable then 0 else s.signed end) over w,
         v_custom and s.key = any(v_hidden) and s.hideable,
         row_number() over (order by s.yr, s.is_open desc, s.d, s.prio, s.sub, s.nat nulls last, s.num, s.cust, s.ref, s.sub2, s.deleted, s.key)
    from _st s
  window w as (partition by s.yr order by s.is_open desc, s.d, s.prio, s.sub, s.nat nulls last, s.num, s.cust, s.ref, s.sub2, s.deleted, s.key
               rows between unbounded preceding and current row);

  -- السابق: افتتاح سنة البداية وحركاتها قبل «من»
  select coalesce(sum(signed), 0), coalesce(sum(csigned), 0) into v_prev, v_cprev
    from _st2 where yr = yf and (is_open or d < p_from);

  -- افتتاح كل سنة لاحقة داخل الفترة صف فرق عن إقفال السابقة؛ القديم لا يجمع مرتين (B038)
  for y in yf + 1..yt loop
    insert into _st2 (key, yr, is_open, d, prio, sub, nat, num, cust, ref, sub2, kind, account, description, signed, affecting, deleted,
                      doc_id, note_id, hideable, csigned, bal, cbal, hidden, rn)
    select 'open:' || y, y, false, make_date(y, 1, 1), -1, 0, null, null, null, 0, 0, 'opening', v_head,
           'رصيد افتتاحي ' || y || ': ' || trim_scale(op.v)::text || '؛ إقفال ' || (y - 1) || ': ' || trim_scale(cl.v)::text,
           op.v - cl.v, true, false, null, null, false, op.v - cl.cv, op.v, op.v, false,
           coalesce((select min(rn) from _st2 where yr = y), (select coalesce(max(rn), 0) + 1 from _st2)) - 0.5
      from (select coalesce(sum(signed), 0) v from _st2 where yr = y and is_open) op,
           (select coalesce((select bal from _st2 where yr = y - 1 order by rn desc limit 1), 0) v,
                   coalesce((select cbal from _st2 where yr = y - 1 order by rn desc limit 1), 0) cv) cl;
  end loop;

  -- صفوف العرض: داخل الفترة ومطابقة للفلاتر (البحث والنوع لا يغيران السابق والنهائي، B041)
  with shown as (
    select s.*,
           (cardinality(v_kinds) = 0 or s.kind = any(v_kinds) or (s.kind in ('open_debit', 'open_credit', 'opening') and 'opening' = any(v_kinds))
              or (s.kind = 'transfer' and 'collection' = any(v_kinds)))
           and (v_affect = 'all' or (v_affect = 'affecting' and s.affecting) or (v_affect = 'non' and not s.affecting))
           and (v_search is null or coalesce(s.num, '') ilike '%' || v_search || '%' or coalesce(s.description, '') ilike '%' || v_search || '%'
                or trim_scale(abs(s.signed))::text = v_search
                or exists (select 1 from public.docs dd where dd.id = s.doc_id and (dd.customer_name_src ilike '%' || v_search || '%'
                                                                                   or trim_scale(dd.total)::text = v_search))) as matched
      from _st2 s
     where not (s.is_open) and s.d between p_from and p_to
  ),
  lines as (
    select s.*, c.customer_number acc_number, c.name acc_name,
           d.total doc_total, d.pay_type, d.pay_methods, d.employee_id, i.ret_class, n.reason note_reason, n.amount note_amount
      from shown s
      left join public.customers c on c.id = s.account
      left join public.docs d on d.id = s.doc_id
      left join app.ledger_items i on i.year = s.yr and i.item_key = s.key and s.kind not in ('transfer', 'opening')
      left join public.account_notes n on n.id = s.note_id
     where s.matched
  )
  select jsonb_build_object(
    'customer', jsonb_build_object('id', v_cust.id, 'customer_number', v_cust.customer_number, 'name', v_cust.name,
       'role', case when v_master is not null then 'فرع' when cardinality(app.branches_at(p_customer, p_to)) > 0 then 'رئيسي' else 'مستقل' end,
       'master', (select jsonb_build_object('id', m.id, 'customer_number', m.customer_number, 'name', m.name) from public.customers m where m.id = v_master),
       'head', (select jsonb_build_object('id', m.id, 'customer_number', m.customer_number, 'name', m.name) from public.customers m where m.id = v_head)),
    'family', p_family, 'from', p_from, 'to', p_to, 'custom', v_custom,
    'filtered', cardinality(v_kinds) > 0 or v_affect <> 'all' or v_search is not null,
    'warnings', v_warn,
    'official', (select jsonb_build_object('prev', v_prev,
                   'debit', coalesce(sum(greatest(signed, 0)), 0), 'credit', coalesce(sum(greatest(-signed, 0)), 0),
                   'final', v_prev + coalesce(sum(signed), 0))
                   from _st2 where not is_open and d between p_from and p_to),
    'custom_totals', case when v_custom then (select jsonb_build_object('prev', v_cprev,
                   'debit', coalesce(sum(greatest(csigned, 0)), 0),
                   'credit', coalesce(sum(greatest(-csigned, 0)), 0),
                   'final', v_cprev + coalesce(sum(csigned), 0),
                   'hidden_count', count(*) filter (where hidden))
                   from _st2 where not is_open and d between p_from and p_to) end,
    'results', (select jsonb_build_object('count', count(*),
                   'debit', coalesce(sum(greatest(signed, 0)) filter (where not hidden), 0),
                   'credit', coalesce(sum(greatest(-signed, 0)) filter (where not hidden), 0)) from lines),
    'fingerprint', (select md5(coalesce(string_agg(key || '|' || d || '|' || coalesce(num, '') || '|' || trim_scale(signed)::text, ';' order by rn), '')
                               || '|' || trim_scale(v_prev)::text)
                      from _st2 where not is_open and d between p_from and p_to and affecting),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
        'key', l.key, 'date', l.d, 'kind', l.kind, 'kind_label', app.kind_name(l.kind), 'number', l.num,
        'account_number', l.acc_number, 'account_name', l.acc_name,
        'description', coalesce(l.description,
           case when l.deleted then 'محذوف — للمراجعة دون أثر مالي'
                when l.kind = 'invoice' and l.pay_type = 'فاتورة ذمم' then 'فاتورة ذمم'
                when l.kind = 'invoice' and l.pay_type = 'فاتورة نقدي' then 'فاتورة نقدي بقيمة ' || trim_scale(l.doc_total)::text || ' — غير مؤثرة'
                when l.kind = 'invoice' then 'فاتورة بلا نوع بقيمة ' || trim_scale(l.doc_total)::text || ' — غير مؤثرة حتى يحدد النوع'
                when l.kind = 'collection' then 'تحصيل' || coalesce(' — ' || l.pay_methods, '')
                when l.kind = 'return' and l.ret_class = 'credit' then 'مرتجع ذمم'
                when l.kind = 'return' and l.ret_class = 'cash' then 'مرتجع نقدي بقيمة ' || trim_scale(l.doc_total)::text || ' — غير مؤثر'
                when l.kind = 'return' then 'مرتجع غير مصنف بقيمة ' || trim_scale(l.doc_total)::text || ' — بحاجة للمراجعة'
                when l.kind in ('debit_note', 'credit_note') then l.note_reason
           end),
        'debit', case when l.signed > 0 then l.signed end, 'credit', case when l.signed < 0 then -l.signed end,
        'balance', l.bal, 'custom_balance', case when v_custom then l.cbal end,
        'affecting', l.affecting, 'deleted', l.deleted, 'hidden', l.hidden, 'hideable', l.hideable,
        'doc_id', l.doc_id, 'note_id', l.note_id) order by l.rn) from lines l), '[]')
  ) into v_res;
  return v_res;
end $$;

-- الكشوف المحفوظة: الاسم والإعدادات والهويات المخفية وبصمة المصدر وقت الحفظ (STMT-006، B043)
create or replace function public.save_statement(p_id bigint, p jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_id; s public.saved_statements;
  v_cust bigint := (p->>'customer_id')::bigint;
  v_st jsonb;
begin
  perform app.require_perm('P07', 'snapshot');
  if coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'اسم الكشف مطلوب'); end if;
  perform app.require_customer_scope(v_cust);
  if p_id is not null then
    select * into s from public.saved_statements where id = p_id;
    if not found then perform app.fail('not_found', 'الكشف المحفوظ غير موجود'); end if;
    if s.created_by is distinct from auth.uid() and not app.is_admin() then
      perform app.fail('forbidden', 'يعدل الكشف المحفوظ صاحبه أو الإدارة');
    end if;
  end if;
  v_st := public.account_statement(v_cust, coalesce((p->>'family')::boolean, false), (p->>'date_from')::date, (p->>'date_to')::date,
                                   coalesce(p->'options', '{}'));
  if v_id is null then
    insert into public.saved_statements (name, customer_id, family, date_from, date_to, custom, options, hidden, fingerprint,
                                         created_by, created_by_name)
    values (trim(p->>'name'), v_cust, coalesce((p->>'family')::boolean, false), (p->>'date_from')::date, (p->>'date_to')::date,
            coalesce((p->>'custom')::boolean, false), coalesce(p->'options', '{}'),
            coalesce((select array_agg(value) from jsonb_array_elements_text(p->'hidden')), '{}'), v_st->>'fingerprint',
            auth.uid(), (select display_name from public.app_users where id = auth.uid()))
    returning id into v_id;
  else
    update public.saved_statements set name = trim(p->>'name'), customer_id = v_cust, family = coalesce((p->>'family')::boolean, false),
           date_from = (p->>'date_from')::date, date_to = (p->>'date_to')::date, custom = coalesce((p->>'custom')::boolean, false),
           options = coalesce(p->'options', '{}'),
           hidden = coalesce((select array_agg(value) from jsonb_array_elements_text(p->'hidden')), '{}'),
           fingerprint = v_st->>'fingerprint', updated_at = now()
     where id = v_id;
  end if;
  perform app.audit('saved_statements', v_id::text, case when p_id is null then 'create' else 'update' end, null, p);
  return v_id;
end $$;

create or replace function public.delete_saved_statement(p_id bigint) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  s public.saved_statements;
begin
  perform app.require_perm('P07', 'snapshot');
  select * into s from public.saved_statements where id = p_id;
  if not found then perform app.fail('not_found', 'الكشف المحفوظ غير موجود'); end if;
  if s.created_by is distinct from auth.uid() and not app.is_admin() then
    perform app.fail('forbidden', 'يحذف الكشف المحفوظ صاحبه أو الإدارة');
  end if;
  delete from public.saved_statements where id = p_id;
  perform app.audit('saved_statements', p_id::text, 'delete', to_jsonb(s), null);
end $$;

-- =====================================================================
-- الذمم الحالية (P08): البنود المفتوحة في تاريخ الرصيد وأعمارها واستحقاقها (B037، B039)
-- =====================================================================

-- p_opts: {customer_id, family, employee_id}
create or replace function public.receivables(p_date date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}');
  y int := extract(year from p_date)::int;
  v_cust bigint := nullif(o->>'customer_id', '')::bigint;
  v_emp bigint := nullif(o->>'employee_id', '')::bigint;
  v_accts bigint[];
  v_res jsonb;
begin
  perform app.require_perm('P08', 'view');
  if p_date is null then perform app.fail('required', 'تاريخ الرصيد مطلوب'); end if;
  if v_cust is not null then
    perform app.require_customer_scope(v_cust);
    v_accts := case when coalesce((o->>'family')::boolean, false)
                    then coalesce(app.master_of(v_cust, p_date), v_cust) || app.branches_at(coalesce(app.master_of(v_cust, p_date), v_cust), p_date)
                    else array[v_cust] end;
    insert into app.ledger_dirty select c, y from unnest(v_accts) c
     where not exists (select 1 from app.ledger_accounts la where la.year = y and la.account_id = c)
    on conflict do nothing;
  end if;
  if v_emp is not null then perform app.require_employee_scope(v_emp); end if;
  perform app.refresh_ledger();

  with debts as (
    select i.*, i.amount - coalesce((select sum(a.amount) from app.ledger_allocs a
                                      where a.year = y and a.debt_key = i.item_key and a.alloc_date <= p_date), 0) remaining,
           case when i.kind = 'open_debit' then null
                else i.item_date + coalesce(c.grace_days, 30) end due
      from app.ledger_items i join public.customers c on c.id = i.account_id
     where i.year = y and i.side = 'D' and i.item_date <= p_date
       and (v_accts is null or i.account_id = any(v_accts))
       and app.can_see_customer(i.account_id)
  ),
  credits as (
    select i.account_id, i.amount - coalesce((select sum(a.amount) from app.ledger_allocs a
                                               where a.year = y and a.credit_key = i.item_key and a.alloc_date <= p_date), 0) remaining
      from app.ledger_items i
     where i.year = y and i.side = 'C' and i.item_date <= p_date
       and (v_accts is null or i.account_id = any(v_accts))
       and app.can_see_customer(i.account_id)
  ),
  bal as (
    select account_id, sum(v) balance from (
      select account_id, remaining v from debts union all select account_id, -remaining from credits) s
     group by account_id
  ),
  open_items as (
    select d.*, (d.due is not null and d.due < p_date) overdue
      from debts d
     where d.remaining > 0
       and (v_emp is null or d.employee_id = v_emp)
       and (d.employee_id is null or app.scope_is_all() or app.can_see_employee(d.employee_id))
  ),
  acct as (
    select b.account_id, b.balance,
           coalesce((select sum(remaining) from open_items oi where oi.account_id = b.account_id), 0) open_total,
           coalesce((select sum(remaining) from open_items oi where oi.account_id = b.account_id and oi.overdue), 0) overdue_total,
           (select max(p_date - oi.item_date) from open_items oi where oi.account_id = b.account_id and oi.kind <> 'open_debit') oldest_age
      from bal b
  )
  select jsonb_build_object(
    'as_of', p_date, 'year', y,
    'summary', jsonb_build_object(
       'remaining', coalesce((select sum(open_total) from acct), 0),
       'overdue', coalesce((select sum(overdue_total) from acct), 0),
       'debtors', (select count(*) from acct where open_total > 0),
       'creditors_total', coalesce((select sum(-balance) from acct where balance < 0), 0),
       'unattributed', coalesce((select sum(remaining) from open_items where employee_id is null), 0)),
    'debtors', coalesce((select jsonb_agg(jsonb_build_object(
        'account_id', a.account_id, 'customer_number', c.customer_number, 'name', c.name,
        'role', case when app.master_of(c.id, p_date) is not null then 'فرع'
                     when cardinality(app.branches_at(c.id, p_date)) > 0 then 'رئيسي' else 'مستقل' end,
        'master_number', (select m.customer_number from public.customers m where m.id = app.master_of(c.id, p_date)),
        'master_name', (select m.name from public.customers m where m.id = app.master_of(c.id, p_date)),
        'grace_days', coalesce(c.grace_days, 30),
        'balance', a.balance, 'open_total', a.open_total, 'overdue_total', a.overdue_total, 'oldest_age', a.oldest_age,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
             'key', oi.item_key, 'kind', oi.kind, 'kind_label', app.kind_name(oi.kind), 'number', oi.num,
             'date', case when oi.kind = 'open_debit' then null else oi.item_date end,
             'due', oi.due, 'age', case when oi.kind = 'open_debit' then null else p_date - oi.item_date end,
             'overdue', oi.overdue, 'amount', oi.amount, 'paid', oi.amount - oi.remaining, 'remaining', oi.remaining,
             'employee_id', oi.employee_id, 'employee_name', (select name from public.employees e where e.id = oi.employee_id),
             'doc_id', case when oi.item_key like 'doc:%' then oi.ref_id end,
             'paid_by', (select coalesce(jsonb_agg(jsonb_build_object(
                   'credit_key', al.credit_key, 'kind', app.kind_name(ci.kind), 'number', ci.num, 'date', ci.item_date,
                   'account_number', cc.customer_number, 'amount', al.amount, 'applied', al.alloc_date) order by al.seq), '[]')
                 from app.ledger_allocs al join app.ledger_items ci on ci.year = y and ci.item_key = al.credit_key
                 join public.customers cc on cc.id = al.credit_account
                where al.year = y and al.debt_key = oi.item_key and al.alloc_date <= p_date)
           ) order by oi.seq), '[]') from open_items oi where oi.account_id = a.account_id)
      ) order by a.overdue_total desc, a.open_total desc, c.customer_number)
      from acct a join public.customers c on c.id = a.account_id where a.open_total > 0), '[]'),
    'creditors', coalesce((select jsonb_agg(jsonb_build_object('account_id', a.account_id, 'customer_number', c.customer_number,
        'name', c.name, 'balance', a.balance) order by a.balance, c.customer_number)
      from acct a join public.customers c on c.id = a.account_id where a.balance < 0 and v_emp is null), '[]'),
    'unknown_openings', coalesce((select jsonb_agg(c.customer_number order by c.customer_number)
      from app.ledger_accounts la join public.customers c on c.id = la.account_id
     where la.year = y and not la.opening_known and app.can_see_customer(c.id)
       and (v_accts is null or la.account_id = any(v_accts))), '[]')
  ) into v_res;
  return v_res;
end $$;

-- =====================================================================
-- أمان الصفوف
-- =====================================================================

alter table public.opening_batches        enable row level security;
alter table public.opening_balances       enable row level security;
alter table public.opening_batch_items    enable row level security;
alter table public.year_closes            enable row level security;
alter table public.account_notes          enable row level security;
alter table public.customer_alloc_policies enable row level security;
alter table public.return_classes         enable row level security;
alter table public.saved_statements       enable row level security;

create policy opening_batches_read on public.opening_batches for select to authenticated using (app.has_perm('P08a'));
create policy openings_read on public.opening_balances for select to authenticated
  using ((app.has_perm('P08a') or app.has_perm('P07')) and app.can_see_customer(customer_id));
create policy opening_items_read on public.opening_batch_items for select to authenticated
  using (app.has_perm('P08a') and app.can_see_customer(customer_id));
create policy year_closes_read on public.year_closes for select to authenticated using (app.has_perm('P08a'));
create policy notes_read on public.account_notes for select to authenticated
  using ((app.has_perm('P09') or app.has_perm('P07')) and app.can_see_customer(customer_id));
create policy policies_read on public.customer_alloc_policies for select to authenticated
  using ((app.has_perm('P02') or app.has_perm('P07')) and app.can_see_customer(customer_id));
create policy return_classes_read on public.return_classes for select to authenticated
  using (app.has_perm('P06') and exists (select 1 from public.docs d where d.id = doc_id and app.can_see_employee(d.employee_id)));
create policy saved_statements_read on public.saved_statements for select to authenticated
  using (app.has_perm('P07') and app.can_see_customer(customer_id));

-- الحسابات الموجودة قبل هذه الوحدة تحسب عند أول قراءة
insert into app.ledger_dirty select distinct customer_id, extract(year from doc_date)::int from public.docs on conflict do nothing;

select app.apply_grants();

-- >>> 0006_goals_commissions.sql
-- =====================================================================
-- ماستر — 0006: الأهداف والعمولات
-- التقويم وأيام العمل والاستثناءات (CAL-002..008)، خطط الأهداف ومكوناتها وقوالبها (GOAL-001..017)،
-- قواعد العمولة الشهرية وشرائحها (COMM-004..008)، المكافآت (REWARD-001/002، B023)، كشف العمولة
-- وتعديلات الصرف (COMM-001..003، B018–B027)، بطاقات الأداء (CARD-001..018)، الأشهر والإغلاق
-- ونسخ الاعتماد (PERIOD-001/002، B075–B077، AUTH-004).
--
-- مبادئ الحساب:
-- * الهدف النهائي يشتق كل مرة من الأصل: B = T×E÷D (متناسب) أو T (ثابت)، ثم B×(E−P)÷E، وأهداف
--   الأعداد تقرب للأعلى مرة واحدة بعد كل التعديلات (CAL-008، CAL-003، GOAL-008، GOAL-009).
-- * الحركات تختار بتاريخ السند داخل الفترة وحتى القطع، وداخل فترات عمل موظف السند (CARD-003، EMP-004).
-- * أعلى شريحة مستوفية بالترتيب المحفوظ هي المحققة؛ الشريحة بلا مكونات لا تشارك؛ الصفر لا يحقق (B013، B014).
-- * العمولة من الحركات الفعلية المؤهلة لا من الهدف (GOAL-007): نسبة الشريحة الشهرية للدور أولًا، وفراغها
--   يرجع لنسبة الصنف بتاريخ السند، وفراغهما معًا إعداد ناقص (COMM-004، B018–B020).
-- * الشهر المغلق يقرأ من نسخته المحفوظة؛ الإغلاق وإعادة الفتح للإدارة، وإعادة الفتح برمزها السري.
-- =====================================================================

-- ---------------------------------------------------------------------
-- التقويم (CAL-007): أيام العمل الأسبوعية والعطل العامة واستثناءات الموظف
-- ---------------------------------------------------------------------

-- أيام العمل بأرقام extract(dow): الأحد 0 … السبت 6. الافتراضي السبت–الخميس والجمعة عطلة.
insert into public.settings (key, value) values ('work_weekdays', '[0, 1, 2, 3, 4, 6]') on conflict (key) do nothing;

create table public.holidays (
  id          bigserial primary key,
  start_date  date not null,
  end_date    date not null,
  name        text not null,
  reason      text,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  check (end_date >= start_date)
);
create index on public.holidays (start_date, end_date);

-- استثناء الموظف الشخصي ونمطه المختار عند إضافته (CAL-002): ثابت أو متناسب
create table public.employee_exceptions (
  id           bigserial primary key,
  employee_id  bigint not null references public.employees(id),
  start_date   date not null,
  end_date     date not null,
  mode         text not null check (mode in ('fixed', 'proportional')),
  reason       text not null,
  status       text not null default 'active' check (status in ('active', 'deleted')),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  check (end_date >= start_date)
);
create index on public.employee_exceptions (employee_id, start_date);

create or replace function app.work_weekdays() returns int[]
language sql stable security definer set search_path = public as $$
  select coalesce((select array_agg(x::int) from public.settings s, jsonb_array_elements_text(s.value) x
                    where s.key = 'work_weekdays'), array[0, 1, 2, 3, 4, 6])
$$;

create or replace function app.month_end(p_month date) returns date
language sql immutable as $$ select (date_trunc('month', p_month) + interval '1 month - 1 day')::date $$;

-- أيام الشهر وحالتها للموظف: عمل في التقويم العام، داخل فترة العمل، استثناء ثابت/متناسب
create or replace function app.emp_day_flags(p_emp bigint, p_month date)
returns table (d date, work boolean, eligible boolean, prop boolean, fixed boolean, holiday text)
language sql stable security definer set search_path = public, app as $$
  with days as (
    select g::date d from generate_series(app.month_of(p_month), app.month_end(p_month), interval '1 day') g
  )
  select x.d,
         extract(dow from x.d)::int = any(app.work_weekdays())
           and not exists (select 1 from public.holidays h where x.d between h.start_date and h.end_date),
         p_emp is not null and exists (select 1 from public.employment_periods p
                                        where p.employee_id = p_emp and x.d >= p.start_date and (p.end_date is null or x.d <= p.end_date)),
         exists (select 1 from public.employee_exceptions e where e.employee_id = p_emp and e.status = 'active'
                    and e.mode = 'proportional' and x.d between e.start_date and e.end_date),
         exists (select 1 from public.employee_exceptions e where e.employee_id = p_emp and e.status = 'active'
                    and e.mode = 'fixed' and x.d between e.start_date and e.end_date),
         (select h.name from public.holidays h where x.d between h.start_date and h.end_date order by h.start_date limit 1)
    from days x
$$;

-- أيام الموظف للشهر (CAL-003، CAL-007، CAL-008، CARD-004):
-- D أيام عمل الشهر، E منها داخل الأهلية، P الاستثناء المتناسب، X كل الاستثناءات،
-- total = E − X أيام الموظف، elapsed المنقضي منها حتى القطع شاملًا يومه.
create or replace function app.emp_days(p_emp bigint, p_month date, p_cutoff date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'D', count(*) filter (where work),
    'E', count(*) filter (where work and eligible),
    'P', count(*) filter (where work and eligible and prop),
    'X', count(*) filter (where work and eligible and (prop or fixed)),
    'total', count(*) filter (where work and eligible and not prop and not fixed),
    'elapsed', count(*) filter (where work and eligible and not prop and not fixed
                                  and d <= coalesce(p_cutoff, app.month_end(p_month))))
  from app.emp_day_flags(p_emp, p_month)
$$;

-- ---------------------------------------------------------------------
-- المقاييس (GOAL-003، B005–B012، GOAL-012..017)
-- ---------------------------------------------------------------------

-- المقاييس المعتمدة: count = عدد كيانات صحيحة يقرب هدفه للأعلى؛ relative = نسبي لا يخفض بالأيام ولا مسار له
create or replace function app.metric_kind(p_metric text) returns text
language sql immutable as $$
  select case
    when p_metric in ('net_sales', 'gross_sales', 'collection', 'quantity') then 'amount'
    when p_metric in ('customers', 'invoices', 'variety', 'new_customers', 'reactivated') then 'count'
    when p_metric in ('collection_ratio') then 'relative'
  end
$$;

create or replace function app.metric_label(p_metric text) returns text
language sql immutable as $$
  select case p_metric
    when 'net_sales' then 'صافي المبيعات' when 'gross_sales' then 'إجمالي المبيعات'
    when 'collection' then 'التحصيل' when 'quantity' then 'صافي الكمية'
    when 'customers' then 'العملاء' when 'invoices' then 'فواتير البيع'
    when 'variety' then 'تنوع الأصناف' when 'new_customers' then 'العملاء الجدد'
    when 'reactivated' then 'إعادة التنشيط' when 'collection_ratio' then 'التحصيل النسبي'
  end
$$;

-- السندات المشمولة بأداء موظف: سندات المندوب نفسه، أو سندات فريق المشرف بحسب تبعيته بتاريخ السند
-- (EMP-006، B001) مع مبيعاته الشخصية عند اختيارها. لا تدخل حركة خارج فترة عمل موظف السند (EMP-004).
create or replace function app.perf_docs(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date)
returns table (doc_id bigint, part text)
language sql stable security definer set search_path = public, app as $$
  select d.id, case when d.employee_id = p_emp then 'personal' else 'team' end
    from public.docs d
   where d.status = 'active' and d.doc_date between p_from and p_to
     and exists (select 1 from public.employment_periods ep where ep.employee_id = d.employee_id
                    and d.doc_date >= ep.start_date and (ep.end_date is null or d.doc_date <= ep.end_date))
     and ((p_role = 'rep' and d.employee_id = p_emp)
       or (p_role = 'supervisor' and (
             exists (select 1 from public.supervisor_assignments s
                      where s.employee_id = d.employee_id and s.supervisor_id = p_emp
                        and daterange(s.valid_from, s.valid_to, '[]') @> d.doc_date)
             or (coalesce(p_personal, false) and d.employee_id = p_emp))))
$$;

-- هل السند داخل نطاق أداء الموظف بتاريخه (للفواتير المسددة لاحقًا في هدف التحصيل وعمولته)
create or replace function app.doc_in_scope(p_doc public.docs, p_emp bigint, p_role text, p_personal boolean) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_doc.status = 'active'
     and exists (select 1 from public.employment_periods ep where ep.employee_id = p_doc.employee_id
                    and p_doc.doc_date >= ep.start_date and (ep.end_date is null or p_doc.doc_date <= ep.end_date))
     and ((p_role = 'rep' and p_doc.employee_id = p_emp)
       or (p_role = 'supervisor' and (
             exists (select 1 from public.supervisor_assignments s
                      where s.employee_id = p_doc.employee_id and s.supervisor_id = p_emp
                        and daterange(s.valid_from, s.valid_to, '[]') @> p_doc.doc_date)
             or (coalesce(p_personal, false) and p_doc.employee_id = p_emp))))
$$;

-- قيمة سطر بيع بحسب نوع البيع المشمول (B006، B007): مباشر NetSales، عروض NetPromotions، أو كلاهما
create or replace function app.line_value(p_ns numeric, p_np numeric, p_sale_type text) returns numeric
language sql immutable as $$
  select case coalesce(p_sale_type, 'all') when 'direct' then coalesce(p_ns, 0) when 'promo' then coalesce(p_np, 0)
              else coalesce(p_ns, 0) + coalesce(p_np, 0) end
$$;

-- هل السند يطابق نوع الدفع المختار: الفاتورة بنوعها، والمرتجع بتصنيفه المالي (RET-005)
create or replace function app.pay_match(p_doc public.docs, p_pay text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case coalesce(p_pay, 'all')
    when 'all' then true
    when 'cash' then case when p_doc.kind = 'invoice' then p_doc.pay_type = 'فاتورة نقدي'
                          else (select class from public.return_classes where doc_id = p_doc.id) = 'cash' end
    when 'credit' then case when p_doc.kind = 'invoice' then p_doc.pay_type = 'فاتورة ذمم'
                            else (select class from public.return_classes where doc_id = p_doc.id) = 'credit' end
  end
$$;

-- التحصيل المسدد لفواتير موظف بأساس «مندوب الفاتورة» (GOAL-017): ما خُصص في الفترة على فواتير ذممه
create or replace function app.paid_on_invoices(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date)
returns numeric language plpgsql security definer set search_path = public, app as $$
declare
  v numeric;
begin
  perform app.refresh_ledger();
  select coalesce(sum(a.amount), 0) into v
    from app.ledger_allocs a
    join public.docs d on a.debt_key = 'doc:' || d.id
   where a.alloc_date between p_from and p_to
     and app.doc_in_scope(d, p_emp, p_role, p_personal);
  return v;
end $$;

-- قيمة مقياس لموظف في مدى (قبل حد القطع). p_f: {products:[ids], sale_type, pay_type, days, basis}
create or replace function app.metric_value(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date,
                                            p_metric text, p_f jsonb) returns numeric
language plpgsql security definer set search_path = public, app as $$
declare
  v_products bigint[] := (select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(p_f->'products', '[]')) x);
  v_sale text := coalesce(p_f->>'sale_type', 'all');
  v_pay text := coalesce(p_f->>'pay_type', 'all');
  v_n int := coalesce(nullif(p_f->>'days', '')::int, 90);
  v numeric; v_den numeric;
begin
  if p_to < p_from then
    return case when app.metric_kind(p_metric) = 'relative' then null else 0 end;
  end if;
  create temp table if not exists _mv_lines (doc_id bigint, kind text, customer_id bigint, doc_date date, product_id bigint,
                                             value numeric, quantity numeric, total numeric) on commit drop;
  truncate _mv_lines;
  insert into _mv_lines
  select d.id, d.kind, d.customer_id, d.doc_date, l.product_id,
         app.line_value(l.net_sales, l.net_promotions, v_sale), coalesce(l.quantity, 0), d.total
    from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s
    join public.docs d on d.id = s.doc_id
    join public.doc_lines l on l.doc_id = d.id
   where d.kind in ('invoice', 'return')
     and app.pay_match(d, v_pay)
     and (v_products is null or l.product_id = any(v_products));

  case p_metric
  when 'net_sales' then
    select coalesce(sum(case kind when 'invoice' then value else -value end), 0) into v from _mv_lines;
  when 'gross_sales' then
    select coalesce(sum(value), 0) into v from _mv_lines where kind = 'invoice';
  when 'quantity' then
    select coalesce(sum(case kind when 'invoice' then quantity else -quantity end), 0) into v from _mv_lines;
  when 'customers' then
    -- عملاء مميزون ببيع موجب؛ البونص وحده أو المرتجع وحده لا يجعله مشتريًا (B008، B009، B012)
    select count(distinct customer_id) into v from _mv_lines where kind = 'invoice' and value > 0;
  when 'invoices' then
    -- فواتير البيع المميزة؛ فاتورة البونص فقط لا تدخل (B010)
    select count(*) into v from (select doc_id from _mv_lines where kind = 'invoice' group by doc_id having sum(value) > 0) x;
  when 'variety' then
    select count(distinct product_id) into v from _mv_lines where kind = 'invoice' and value > 0 and product_id is not null;
  when 'new_customers' then
    -- أول شراء موجب للعميل في النظام كله داخل الفترة (GOAL-012)
    select count(distinct m.customer_id) into v from _mv_lines m
     where m.kind = 'invoice' and m.value > 0
       and not exists (select 1 from public.docs d join public.doc_lines l on l.doc_id = d.id
                        where d.kind = 'invoice' and d.status = 'active' and d.customer_id = m.customer_id
                          and d.doc_date < p_from and coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0) > 0);
  when 'reactivated' then
    -- اشترى سابقًا، ولم يشترِ خلال آخر N يومًا قبل الفترة، ثم اشترى فيها (GOAL-013)
    select count(distinct m.customer_id) into v from _mv_lines m
     where m.kind = 'invoice' and m.value > 0
       and exists (select 1 from public.docs d join public.doc_lines l on l.doc_id = d.id
                    where d.kind = 'invoice' and d.status = 'active' and d.customer_id = m.customer_id
                      and d.doc_date < p_from - v_n and coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0) > 0)
       and not exists (select 1 from public.docs d join public.doc_lines l on l.doc_id = d.id
                        where d.kind = 'invoice' and d.status = 'active' and d.customer_id = m.customer_id
                          and d.doc_date between p_from - v_n and p_from - 1
                          and coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0) > 0);
  when 'collection', 'collection_ratio' then
    if coalesce(p_f->>'basis', 'collector') = 'invoice_rep' then
      v := app.paid_on_invoices(p_emp, p_role, p_personal, p_from, p_to);
    else
      select coalesce(sum(d.total), 0) into v
        from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s join public.docs d on d.id = s.doc_id
       where d.kind = 'collection';
    end if;
    if p_metric = 'collection_ratio' then
      -- تحصيل الشهر ÷ مبيعات الذمم في الشهر نفسه × 100 (GOAL-015)
      select coalesce(sum(d.total), 0) into v_den
        from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s join public.docs d on d.id = s.doc_id
       where d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم';
      v := case when v_den > 0 then v / v_den * 100 end;
    end if;
  else
    perform app.fail('bad_metric', 'مقياس غير معروف: ' || coalesce(p_metric, ''));
  end case;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- خطط الأهداف (GOAL-001..011)
-- ---------------------------------------------------------------------

-- خطة شهرية لموظف: مندوب أو مشرف (محرك واحد للصفحتين GOAL-002)
create table public.goal_plans (
  id                bigserial primary key,
  month             date not null check (extract(day from month) = 1),
  employee_id       bigint not null references public.employees(id),
  role              text not null check (role in ('rep', 'supervisor')),
  sup_mode          text not null default 'team_sum' check (sup_mode in ('team_sum', 'independent')),  -- GOAL-011
  partial_mode      text not null default 'proportional' check (partial_mode in ('proportional', 'fixed')), -- CAL-008
  include_personal  boolean not null default false,       -- مبيعات المشرف الشخصية في إنجازه: خيار الإدارة (COMM-006)
  template_id       bigint,
  note              text,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  updated_at        timestamptz not null default now(),
  updated_by        uuid,
  unique (month, employee_id)
);

-- شرائح الخطة بترتيبها المحفوظ (1 الأعلى) وعلاقة مكوناتها AND/OR (GOAL-004، B014، COMM-004)
create table public.goal_tiers (
  plan_id  bigint not null references public.goal_plans(id) on delete cascade,
  tier     text not null,
  sort     int not null,
  logic    text not null default 'AND' check (logic in ('AND', 'OR')),
  primary key (plan_id, tier)
);

-- مكوّن هدف: مقياس وقيمة ونطاق (B005)؛ tier فارغ = هدف مستقل خارج الشرائح.
-- target فارغ = مكوّن غير مستخدم؛ الصفر يحتاج تصحيحًا ولا يحقق (B013).
create table public.goal_components (
  id        bigserial primary key,
  plan_id   bigint not null references public.goal_plans(id) on delete cascade,
  tier      text,
  sort      int not null default 0,
  metric    text not null,
  target    numeric check (target is null or target >= 0),
  affected  boolean not null default true,     -- «يتأثر بتعديل أيام العمل» (GOAL-009/010)
  filters   jsonb not null default '{}',
  label     text
);
create index on public.goal_components (plan_id);

create table public.goal_templates (
  id          bigserial primary key,
  name        text not null unique,
  role        text not null default 'rep' check (role in ('rep', 'supervisor')),
  data        jsonb not null,                   -- {partial_mode, sup_mode, tiers:[...], components:[...]}
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now()
);

-- الهدف النهائي للمكوّن من أصله (CAL-003، CAL-008، GOAL-008، GOAL-009، B016)
create or replace function app.final_target(p_target numeric, p_metric text, p_affected boolean, p_partial text, p_days jsonb)
returns numeric language plpgsql immutable as $$
declare
  d int := (p_days->>'D')::int; e int := (p_days->>'E')::int; p int := (p_days->>'P')::int;
  b numeric; f numeric;
begin
  if p_target is null then return null; end if;
  if app.metric_kind(p_metric) = 'relative' or not p_affected or d = 0 or e = 0 then
    f := p_target;
  else
    b := case when p_partial = 'fixed' then p_target else p_target * e / d end;
    f := b * (e - p) / e;
  end if;
  if app.metric_kind(p_metric) = 'count' and f > 0 then f := ceil(f); end if;
  return f;
end $$;

create or replace function app.plan_role_page(p_role text) returns text
language sql immutable as $$ select case p_role when 'supervisor' then 'P10a' else 'P10' end $$;

-- ---------------------------------------------------------------------
-- تقييم الخطة (GOAL-004، GOAL-007، CARD-004/005/015، GOAL-011)
-- ---------------------------------------------------------------------

-- حصة هدف مكوّن المندوب للمشرف بحسب أيام العمل ضمن تبعيته له (GOAL-011):
-- الهدف النهائي للمندوب × أيام عمله المنقضية تحت المشرف ÷ إجمالي أيام عمله.
create or replace function app.team_target(p_sup bigint, p_month date, p_tier text, p_metric text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record; c public.goal_components; v_days jsonb; v_total int; v_under int; v_final numeric;
  v_sum numeric := 0; v_parts jsonb := '[]';
begin
  for r in
    select distinct p.* from public.goal_plans p
     join public.supervisor_assignments s on s.employee_id = p.employee_id and s.supervisor_id = p_sup
      and daterange(s.valid_from, s.valid_to, '[]') && daterange(app.month_of(p_month), app.month_end(p_month), '[]')
    where p.month = app.month_of(p_month) and p.role = 'rep'
  loop
    select * into c from public.goal_components
     where plan_id = r.id and tier is not distinct from p_tier and metric = p_metric and target is not null
     order by sort limit 1;
    continue when not found;
    v_days := app.emp_days(r.employee_id, p_month);
    v_total := (v_days->>'total')::int;
    v_final := app.final_target(c.target, c.metric, c.affected, r.partial_mode, v_days);
    select count(*) into v_under from app.emp_day_flags(r.employee_id, p_month) f
     where f.work and f.eligible and not f.prop and not f.fixed
       and exists (select 1 from public.supervisor_assignments s where s.employee_id = r.employee_id and s.supervisor_id = p_sup
                     and daterange(s.valid_from, s.valid_to, '[]') @> f.d);
    if v_total > 0 then
      v_sum := v_sum + v_final * v_under / v_total;
      v_parts := v_parts || jsonb_build_object('employee_id', r.employee_id, 'name', (select name from public.employees where id = r.employee_id),
        'final', v_final, 'days', v_total, 'under', v_under, 'share', v_final * v_under / v_total);
    else
      v_parts := v_parts || jsonb_build_object('employee_id', r.employee_id, 'name', (select name from public.employees where id = r.employee_id),
        'final', v_final, 'days', 0, 'under', 0, 'share', 0);
    end if;
  end loop;
  return jsonb_build_object('sum', case when app.metric_kind(p_metric) = 'count' and v_sum > 0 then ceil(v_sum) else v_sum end,
                            'parts', v_parts, 'count', jsonb_array_length(v_parts));
end $$;

-- تقييم الخطة حتى تاريخ القطع؛ يعيد المكونات والشرائح والأيام والشريحة المحققة وشريحة المسار
create or replace function app.plan_eval(p_plan bigint, p_cutoff date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pl public.goal_plans;
  v_from date; v_to date; v_cut date;
  v_days jsonb; v_total int; v_elapsed int;
  c record; t record; v_comps jsonb := '[]'; v_tiers jsonb := '[]';
  v_final numeric; v_actual numeric; v_team jsonb; v_required numeric; v_met boolean; v_path_ok boolean;
  v_has_path boolean; v_zero boolean; v_status text;
  v_achieved text; v_path_tier text; v_eval_n int; v_met_n int; v_path_n int; v_pathok_n int;
  v_main jsonb;
begin
  select * into pl from public.goal_plans where id = p_plan;
  if not found then return null; end if;
  v_from := pl.month; v_to := app.month_end(pl.month);
  v_cut := least(coalesce(p_cutoff, v_to), v_to);
  v_days := app.emp_days(pl.employee_id, pl.month, v_cut);
  v_total := (v_days->>'total')::int; v_elapsed := (v_days->>'elapsed')::int;

  for c in select * from public.goal_components where plan_id = p_plan order by tier nulls last, sort, id loop
    v_team := null;
    if pl.role = 'supervisor' and pl.sup_mode = 'team_sum' and app.metric_kind(c.metric) <> 'relative' then
      v_team := app.team_target(pl.employee_id, pl.month, c.tier, c.metric);
      v_final := (v_team->>'sum')::numeric;
    else
      v_final := app.final_target(c.target, c.metric, c.affected, pl.partial_mode, v_days);
    end if;
    v_actual := app.metric_value(pl.employee_id, pl.role, pl.include_personal, v_from, v_cut, c.metric, c.filters);
    v_zero := v_final is not null and v_final = 0;
    -- مجموع فريق بلا أعضاء في الشهر: صفر ظاهر غير مستخدم في التقييم
    v_status := case when v_final is null or (v_team is not null and (v_team->>'count')::int = 0) then 'unused'
                     when v_zero then 'zero' else 'ok' end;
    v_met := v_status = 'ok' and v_actual is not null and v_actual >= v_final;
    v_has_path := v_status = 'ok' and app.metric_kind(c.metric) <> 'relative' and v_total > 0;
    v_required := case when v_has_path then v_final * v_elapsed / v_total end;
    v_path_ok := v_has_path and v_elapsed > 0 and v_actual >= v_required;
    v_comps := v_comps || jsonb_build_object(
      'id', c.id, 'tier', c.tier, 'sort', c.sort, 'metric', c.metric, 'label', coalesce(c.label, app.metric_label(c.metric)),
      'kind', app.metric_kind(c.metric), 'filters', c.filters, 'affected', c.affected,
      'original', case when v_team is not null then null else c.target end, 'final', v_final, 'team', v_team,
      'actual', v_actual, 'status', v_status, 'met', v_met,
      'pct', case when v_status = 'ok' and v_final > 0 and v_actual is not null then v_actual / v_final * 100 end,
      'remaining', case when v_status = 'ok' and app.metric_kind(c.metric) <> 'relative' then greatest(v_final - v_actual, 0) end,
      'has_path', v_has_path, 'required', v_required,
      'path_pct', case when v_has_path and v_required > 0 then v_actual / v_required * 100 end,
      'path_diff', case when v_has_path and v_elapsed > 0 then v_actual - v_required end,
      'path_ok', v_path_ok,
      'daily', case when v_has_path and v_total - v_elapsed > 0 then greatest(v_final - v_actual, 0) / (v_total - v_elapsed) end,
      'expected_today', case when v_has_path then v_final * v_elapsed / v_total end);
  end loop;

  -- الشريحة المحققة: أعلى شريحة مستوفية بالترتيب المحفوظ؛ الشريحة بلا مكونات مقيمة لا تشارك
  for t in select * from public.goal_tiers where plan_id = p_plan order by sort loop
    select count(*) filter (where x->>'status' <> 'unused'),
           count(*) filter (where (x->>'met')::boolean),
           count(*) filter (where (x->>'has_path')::boolean),
           count(*) filter (where (x->>'path_ok')::boolean)
      into v_eval_n, v_met_n, v_path_n, v_pathok_n
      from jsonb_array_elements(v_comps) x where x->>'tier' = t.tier;
    v_met := v_eval_n > 0 and case t.logic when 'AND' then v_met_n = v_eval_n else v_met_n > 0 end;
    -- شريحة المسار (CARD-015): كل مكوّن قابل للمسار على المفترض في AND، أو أحدها في OR
    v_path_ok := v_path_n > 0 and v_elapsed > 0 and case t.logic when 'AND' then v_pathok_n = v_path_n else v_pathok_n > 0 end;
    if v_met and v_achieved is null then v_achieved := t.tier; end if;
    if v_path_ok and v_path_tier is null then v_path_tier := t.tier; end if;
    v_tiers := v_tiers || jsonb_build_object('tier', t.tier, 'sort', t.sort, 'logic', t.logic, 'components', v_eval_n,
                                             'met', v_met, 'path_ok', v_path_ok);
  end loop;

  -- المكوّن الممثل لنسبة الإنجاز: أول مكوّن مقيم في أعلى شريحة («من هدف A»)
  select x into v_main from jsonb_array_elements(v_comps) x
    join public.goal_tiers gt on gt.plan_id = p_plan and gt.tier = x->>'tier'
   where x->>'status' = 'ok' order by gt.sort, (x->>'sort')::int limit 1;

  return jsonb_build_object(
    'plan_id', pl.id, 'month', pl.month, 'employee_id', pl.employee_id, 'role', pl.role, 'sup_mode', pl.sup_mode,
    'partial_mode', pl.partial_mode, 'include_personal', pl.include_personal, 'cutoff', v_cut,
    'days', v_days, 'path_state', case when v_total = 0 then 'no_days' when v_elapsed = 0 then 'not_started' else 'running' end,
    'components', v_comps, 'tiers', v_tiers, 'achieved', coalesce(v_achieved, 'NONE'), 'path_tier', coalesce(v_path_tier, 'NONE'),
    'main', v_main);
end $$;

-- ---------------------------------------------------------------------
-- قواعد العمولة الشهرية وإعداداتها (COMM-004..008، B018–B020، REVIEW-001)
-- ---------------------------------------------------------------------

-- قاعدة الشهر: جدول شرائح بترتيبه ونسبة المندوب بالمئة والمشرف بالألف؛ الفراغ = الرجوع لنسبة الصنف
create table public.commission_rules (
  id          bigserial primary key,
  month       date not null check (extract(day from month) = 1),
  name        text not null,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  unique (month, name)
);

create table public.rule_tiers (
  rule_id   bigint not null references public.commission_rules(id) on delete cascade,
  tier      text not null,
  sort      int not null,
  rep_rate  numeric check (rep_rate is null or rep_rate >= 0),   -- بالمئة
  sup_rate  numeric check (sup_rate is null or sup_rate >= 0),   -- بالألف
  primary key (rule_id, tier)
);

-- الموظفون المشمولون: قاعدة واحدة للموظف في الشهر
create table public.rule_members (
  rule_id      bigint not null references public.commission_rules(id) on delete cascade,
  month        date not null,
  employee_id  bigint not null references public.employees(id),
  primary key (rule_id, employee_id),
  unique (month, employee_id)
);

-- مندوبو عمولة التحصيل: يسري الاختيار من شهر تحدده الإدارة (COMM-008)؛ to_month آخر شهر مشمول
create table public.collection_reps (
  id           bigserial primary key,
  employee_id  bigint not null references public.employees(id),
  from_month   date not null check (extract(day from from_month) = 1),
  to_month     date check (to_month is null or to_month >= from_month),
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index on public.collection_reps (employee_id);

-- إعدادات عمولة التحصيل بتاريخ سريان: حد عمر الدين بالأيام بعد الاستحقاق (الفارغ = 30)
create table public.commission_settings (
  id              bigserial primary key,
  key             text not null check (key in ('debt_age_days')),
  value           numeric,
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (key, effective_from)
);

-- عمولة تحصيل الافتتاحي: مندوب لكل عميل أو «لا أحد» (employee_id فارغ) من تاريخ
create table public.opening_collection_reps (
  id              bigserial primary key,
  customer_id     bigint not null references public.customers(id),
  employee_id     bigint references public.employees(id),
  effective_from  date not null,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  unique (customer_id, effective_from)
);

-- نسبة مبيعات المشرف الشخصية لكل شهر بالمئة أو بالألف (COMM-006)
create table public.supervisor_personal_rates (
  month        date not null check (extract(day from month) = 1),
  employee_id  bigint not null references public.employees(id),
  rate         numeric not null check (rate >= 0),
  unit         text not null check (unit in ('pct', 'permille')),
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  primary key (month, employee_id)
);

-- تذكير مراجعة نسب الأصناف أول الشهر وتسجيله (REVIEW-001)
create table public.rate_reviews (
  month       date primary key check (extract(day from month) = 1),
  decision    text not null check (decision in ('no_change', 'edited')),
  note        text,
  at          timestamptz not null default now(),
  by_user     uuid,
  by_name     text
);

-- ---------------------------------------------------------------------
-- المكافآت (REWARD-001/002، B023)
-- ---------------------------------------------------------------------
create table public.reward_plans (
  id           bigserial primary key,
  month        date not null check (extract(day from month) = 1),
  name         text not null,
  role         text not null default 'all' check (role in ('all', 'rep', 'supervisor')),
  employees    bigint[],                       -- فارغ = كل المشمولين بالدور
  cond_type    text not null check (cond_type in ('tier', 'metric')),
  tiers        text[],                         -- الشرائح المحققة المؤهلة
  metric       text,
  metric_min   numeric,
  filters      jsonb not null default '{}',
  value_type   text not null check (value_type in ('fixed', 'percent')),
  amount       numeric,
  pct          numeric,
  pct_base     text check (pct_base in ('eligible', 'base_commission')),
  group_name   text,                           -- مجموعة التداخل
  stack_mode   text not null check (stack_mode in ('STACK', 'HIGHEST_ONLY')),
  note         text,
  status       text not null default 'active' check (status in ('active', 'deleted')),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now()
);
create index on public.reward_plans (month);

-- ---------------------------------------------------------------------
-- قرارات الصرف اليدوية في كشف العمولة (B021، B024–B027)
-- ---------------------------------------------------------------------
create table public.commission_adjustments (
  id           bigserial primary key,
  month        date not null check (extract(day from month) = 1),
  employee_id  bigint not null references public.employees(id),
  kind         text not null check (kind in ('manual_tier', 'add', 'deduct', 'zero_base', 'zero_all')),
  tier         text,
  amount       numeric,
  pct          numeric,
  base         text check (base in ('eligible', 'base_commission')),
  reason       text not null,
  status       text not null default 'active' check (status in ('active', 'cancelled')),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  created_name text,
  cancelled_at timestamptz,
  cancel_reason text
);
create index on public.commission_adjustments (month, employee_id);

-- ---------------------------------------------------------------------
-- نسخ الاعتماد عند الإغلاق (PERIOD-001، B075–B077)
-- ---------------------------------------------------------------------
create table public.month_snapshots (
  month        date not null,
  version      int not null,
  employee_id  bigint not null references public.employees(id),
  statement    jsonb not null,
  card         jsonb,
  created_at   timestamptz not null default now(),
  primary key (month, version, employee_id)
);

create table public.month_versions (
  month       date not null,
  version     int not null,
  closed_at   timestamptz not null default now(),
  closed_by   uuid,
  closed_name text,
  note        text,
  settings    jsonb,                           -- القواعد والمكافآت والإعدادات وقت الإغلاق
  totals      jsonb,
  reopened_at timestamptz,
  reopen_reason text,
  primary key (month, version)
);

-- ---------------------------------------------------------------------
-- أدوات العمولة
-- ---------------------------------------------------------------------

create or replace function app.emp_rule(p_emp bigint, p_month date) returns bigint
language sql stable security definer set search_path = public as $$
  select rule_id from public.rule_members where month = date_trunc('month', p_month)::date and employee_id = p_emp
$$;

create or replace function app.is_collection_rep(p_emp bigint, p_month date) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from public.collection_reps c where c.employee_id = p_emp
                    and app.month_of(p_month) >= c.from_month and (c.to_month is null or app.month_of(p_month) <= c.to_month))
$$;

create or replace function app.debt_age_at(p_date date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.commission_settings where key = 'debt_age_days' and effective_from <= p_date
                    order by effective_from desc limit 1), 30)
$$;

create or replace function app.opening_rep_at(p_customer bigint, p_date date) returns bigint
language sql stable security definer set search_path = public as $$
  select employee_id from public.opening_collection_reps where customer_id = p_customer and effective_from <= p_date
   order by effective_from desc limit 1
$$;

-- دور الموظف في الشهر: من خطته، وإلا مشرف إن كان له فريق في الشهر، وإلا مندوب
create or replace function app.emp_role(p_emp bigint, p_month date) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select role from public.goal_plans where month = app.month_of(p_month) and employee_id = p_emp),
    case when exists (select 1 from public.supervisor_assignments s where s.supervisor_id = p_emp
                         and daterange(s.valid_from, s.valid_to, '[]') && daterange(app.month_of(p_month), app.month_end(p_month), '[]'))
         then 'supervisor' else 'rep' end)
$$;

-- الشريحة اليدوية المعتمدة إن وجدت (B021)
create or replace function app.manual_tier(p_emp bigint, p_month date) returns text
language sql stable security definer set search_path = public, app as $$
  select tier from public.commission_adjustments where month = app.month_of(p_month) and employee_id = p_emp
     and kind = 'manual_tier' and status = 'active' order by created_at desc, id desc limit 1
$$;

-- الشريحة المعتمدة للحساب: من النسخة المحفوظة للشهر المغلق، وإلا المحسوبة ثم اليدوية
create or replace function app.eff_tier(p_emp bigint, p_month date) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_plan bigint; v text;
begin
  if app.is_closed(p_month) then
    select s.statement->>'tier_effective' into v from public.month_snapshots s
     where s.month = app.month_of(p_month) and s.employee_id = p_emp
     order by s.version desc limit 1;
    if found then return v; end if;
  end if;
  v := app.manual_tier(p_emp, p_month);
  if v is not null then return v; end if;
  select id into v_plan from public.goal_plans where month = app.month_of(p_month) and employee_id = p_emp;
  if v_plan is null then return 'NONE'; end if;
  return app.plan_eval(v_plan, app.month_end(p_month))->>'achieved';
end $$;

-- نسبة سطر وفق COMM-004: نسبة الشريحة الشهرية للدور إن حُددت، وإلا نسبة الصنف للشريحة والدور بتاريخ السند
create or replace function app.line_rate(p_rule bigint, p_role text, p_tier text, p_product bigint, p_date date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v numeric;
begin
  if p_tier is null or p_tier = 'NONE' then return jsonb_build_object('rate', 0, 'src', 'no_tier'); end if;
  select case p_role when 'supervisor' then sup_rate else rep_rate end into v
    from public.rule_tiers where rule_id = p_rule and tier = p_tier;
  if v is not null then return jsonb_build_object('rate', v, 'src', 'rule'); end if;
  if p_product is null then return jsonb_build_object('rate', null, 'src', 'missing'); end if;
  v := app.rate_at(p_product, p_role, p_tier, p_date);
  if v is null then return jsonb_build_object('rate', null, 'src', 'missing'); end if;
  return jsonb_build_object('rate', v, 'src', 'product');
end $$;

-- ---------------------------------------------------------------------
-- حساب كشف العمولة (COMM-001..008، B018–B027، GOAL-007)
-- الأساس المؤهل = المباشر + العروض نقدًا وذممًا ناقص المرتجعات بفترتها (COMM-005، B022).
-- مندوب التحصيل: النقدي + المسدد في الشهر من فواتير ذممه − مرتجعاته؛ عمولة المسدد بشريحة شهر الفاتورة
-- وموزعة على أصنافها بنسبة قيمتها؛ لا عمولة بعد حد عمر الدين؛ الفاتورة المحسوبة على البيع لا تحسب ثانية (COMM-008).
-- المشرف: مبيعات فريقه بنسبته بالألف، ومبيعاته الشخصية معلقة حتى تحدد الإدارة نسبتها (COMM-006).
-- ---------------------------------------------------------------------
create or replace function app.commission_calc(p_emp bigint, p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
  v_e date := app.month_end(p_month);
  v_role text := app.emp_role(p_emp, p_month);
  v_rule bigint := app.emp_rule(p_emp, p_month);
  v_plan public.goal_plans;
  v_eval jsonb; v_calc_tier text := 'NONE'; v_manual text; v_tier text;
  v_coll boolean := app.is_collection_rep(p_emp, p_month);
  v_pr public.supervisor_personal_rates;
  v_warn jsonb := '[]'; r record;
  v_eligible numeric; v_team numeric; v_personal numeric; v_base numeric; v_base_orig numeric;
  v_rewards jsonb := '[]'; v_rew_total numeric := 0; v_val numeric; v_ok boolean;
  v_adj jsonb := '[]'; v_adj_total numeric := 0; v_zero_base boolean := false; v_zero_all boolean := false;
  v_final numeric; v_lines jsonb; v_paid jsonb; v_deferred jsonb; v_missing jsonb;
  v_blocking boolean;
begin
  perform app.refresh_ledger();
  create temp table if not exists _cm (source text, part text, doc_id bigint, doc_kind text, doc_number text, doc_date date,
    customer_id bigint, rep_id bigint, product_id bigint, value numeric, paid numeric, tier text, rate numeric, src text,
    unit text, commission numeric, inv_month date) on commit drop;
  truncate _cm;

  select * into v_plan from public.goal_plans where month = v_m and employee_id = p_emp;
  if found then
    v_eval := app.plan_eval(v_plan.id, v_e);
    v_calc_tier := v_eval->>'achieved';
  end if;
  v_manual := app.manual_tier(p_emp, v_m);
  v_tier := coalesce(v_manual, v_calc_tier);

  -- المبيعات والمرتجعات المؤهلة في الشهر (مبيعات ذمم مندوب التحصيل تؤجل حتى سدادها)
  insert into _cm (source, part, doc_id, doc_kind, doc_number, doc_date, customer_id, rep_id, product_id, value, inv_month)
  select case d.kind when 'invoice' then 'sale' else 'return' end, s.part, d.id, d.kind, d.doc_number, d.doc_date, d.customer_id,
         d.employee_id, l.product_id,
         case d.kind when 'invoice' then 1 else -1 end * (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)), v_m
    from app.perf_docs(p_emp, v_role, v_role = 'supervisor', v_m, v_e) s
    join public.docs d on d.id = s.doc_id
    join public.doc_lines l on l.doc_id = d.id
   where d.kind in ('invoice', 'return')
     and not (d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم' and s.part = 'team' and app.is_collection_rep(d.employee_id, d.doc_date))
     and not (d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم' and s.part = 'personal' and v_role = 'rep' and v_coll);

  -- المسدد في الشهر من فواتير ذمم شهور التحصيل، موزعًا على أصناف الفاتورة بنسبة قيمتها
  insert into _cm (source, part, doc_id, doc_kind, doc_number, doc_date, customer_id, rep_id, product_id, value, paid, inv_month)
  select 'paid', case when d.employee_id = p_emp then 'personal' else 'team' end, d.id, d.kind, d.doc_number, d.doc_date,
         d.customer_id, d.employee_id, l.product_id,
         a.amount * (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)) / nullif(t.v, 0), a.amount, app.month_of(d.doc_date)
    from app.ledger_allocs a
    join public.docs d on a.debt_key = 'doc:' || d.id
    join public.customers c on c.id = d.customer_id
    join lateral (select sum(coalesce(x.net_sales, 0) + coalesce(x.net_promotions, 0)) v from public.doc_lines x where x.doc_id = d.id) t on true
    join public.doc_lines l on l.doc_id = d.id
   where a.alloc_date between v_m and v_e
     and d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم'
     and app.doc_in_scope(d, p_emp, v_role, false)
     and (v_role = 'rep' or d.employee_id <> p_emp)
     and app.is_collection_rep(d.employee_id, d.doc_date)
     and a.alloc_date <= d.doc_date + coalesce(c.grace_days, 30) + app.debt_age_at(a.alloc_date)::int
     and t.v <> 0;

  -- تحصيل الافتتاحي للمندوب المختار للعميل (COMM-008 بند 9)
  if v_role = 'rep' then
    insert into _cm (source, part, doc_kind, doc_date, customer_id, rep_id, value, paid, inv_month)
    select 'opening', 'personal', 'opening', a.alloc_date, a.debt_account, p_emp, a.amount, a.amount, v_m
      from app.ledger_allocs a
     where a.debt_key like 'open:%' and a.alloc_date between v_m and v_e
       and app.opening_rep_at(a.debt_account, a.alloc_date) = p_emp;
  end if;

  -- الشريحة: لشهر الفاتورة في المسدد، ولشهر الحركة في غيره
  update _cm set tier = v_tier where inv_month = v_m;
  for r in select distinct inv_month from _cm where tier is null loop
    update _cm set tier = app.eff_tier(p_emp, r.inv_month) where inv_month = r.inv_month and tier is null;
  end loop;

  -- النسب
  if v_role = 'supervisor' then
    select * into v_pr from public.supervisor_personal_rates where month = v_m and employee_id = p_emp;
    update _cm set unit = coalesce(v_pr.unit, 'pct'), rate = v_pr.rate,
                   src = case when v_pr.rate is null then 'pending' else 'personal' end
     where part = 'personal';
    update _cm set unit = 'permille' where part = 'team';
  else
    update _cm set unit = 'pct';
  end if;
  update _cm x set rate = (j->>'rate')::numeric, src = j->>'src'
    from (select ctid id, app.line_rate(app.emp_rule(p_emp, inv_month), v_role, tier, product_id, doc_date) j
            from _cm where src is null) y
   where x.ctid = y.id;
  update _cm set commission = value * rate / case unit when 'pct' then 100 else 1000 end where rate is not null;

  -- غياب القاعدة إعداد ناقص لا يحسب بنسب الأصناف تلقائيًا (COMM-007)
  if v_rule is null then
    v_warn := v_warn || jsonb_build_object('code', 'no_rule', 'blocking', true,
      'message', 'إعداد ناقص: الموظف غير مشمول بقاعدة عمولة لهذا الشهر');
  end if;
  select jsonb_agg(jsonb_build_object('product_id', product_id, 'code', (select code from public.products where id = product_id),
                                      'name', (select name from public.products where id = product_id), 'tier', tier, 'value', v))
    into v_missing
    from (select product_id, tier, sum(value) v from _cm where src = 'missing' group by product_id, tier) m;
  if v_missing is not null then
    v_warn := v_warn || jsonb_build_object('code', 'missing_rate', 'blocking', true, 'items', v_missing,
      'message', 'إعداد ناقص: نسبة عمولة مطلوبة فارغة لأصناف في المبيعات (B020)');
  end if;
  if exists (select 1 from _cm where src = 'pending' and value <> 0) then
    v_warn := v_warn || jsonb_build_object('code', 'personal_pending', 'blocking', true,
      'value', (select sum(value) from _cm where src = 'pending'),
      'message', 'مبيعات المشرف الشخصية معلّقة حتى تحدد الإدارة نسبتها لهذا الشهر (COMM-006)');
  end if;
  if v_plan.id is null then
    v_warn := v_warn || jsonb_build_object('code', 'no_plan', 'blocking', false, 'message', 'لا توجد خطة أهداف للشهر؛ لا شريحة محققة');
  elsif exists (select 1 from jsonb_array_elements(v_eval->'components') x where x->>'status' = 'zero') then
    v_warn := v_warn || jsonb_build_object('code', 'zero_target', 'blocking', false,
      'message', 'مكوّن بهدف صفري يحتاج تصحيحًا أو تعطيلًا؛ لا يحقق شريحة (B013)');
  end if;
  if v_rule is not null and v_tier <> 'NONE'
     and not exists (select 1 from public.rule_tiers where rule_id = v_rule and tier = v_tier) then
    v_warn := v_warn || jsonb_build_object('code', 'tier_not_in_rule', 'blocking', false,
      'message', 'الشريحة ' || v_tier || ' غير معرفة في قاعدة الشهر؛ النسب من الأصناف');
  end if;

  select coalesce(sum(value), 0), coalesce(sum(value) filter (where part = 'team'), 0), coalesce(sum(value) filter (where part = 'personal'), 0)
    into v_eligible, v_team, v_personal from _cm;
  if v_rule is null then
    v_base := null;
  else
    select coalesce(sum(commission), 0) into v_base from _cm;
  end if;
  v_base_orig := v_base;

  -- المكافآت: الشروط ومجموعات التداخل STACK / HIGHEST_ONLY (B023)
  for r in select * from public.reward_plans rp where rp.month = v_m and rp.status = 'active'
             and (rp.role = 'all' or rp.role = v_role) and (rp.employees is null or p_emp = any(rp.employees)) order by id loop
    if r.cond_type = 'tier' then
      v_ok := v_tier = any(coalesce(r.tiers, '{}'));
    else
      v_val := app.metric_value(p_emp, v_role, coalesce(v_plan.include_personal, false), v_m, v_e, r.metric, r.filters);
      v_ok := v_val is not null and v_val >= r.metric_min;
    end if;
    continue when not v_ok;
    v_val := case r.value_type when 'fixed' then r.amount
               else r.pct / 100 * case r.pct_base when 'eligible' then v_eligible else coalesce(v_base, 0) end end;
    v_rewards := v_rewards || jsonb_build_object('id', r.id, 'name', r.name, 'group', r.group_name, 'mode', r.stack_mode,
      'amount', v_val, 'value_type', r.value_type, 'pct', r.pct, 'pct_base', r.pct_base,
      'reason', case r.cond_type when 'tier' then 'الشريحة المحققة ' || v_tier
                 else app.metric_label(r.metric) || ' ' || round(app.metric_value(p_emp, v_role, coalesce(v_plan.include_personal, false), v_m, v_e, r.metric, r.filters), 3)
                      || ' ≥ ' || r.metric_min end, 'counted', true);
  end loop;
  -- في مجموعة HIGHEST_ONLY يحتسب الأعلى فقط
  select coalesce(jsonb_agg(case when x->>'mode' = 'HIGHEST_ONLY' and x->>'group' is not null
                                   and exists (select 1 from jsonb_array_elements(v_rewards) y
                                                where y->>'group' = x->>'group' and y->>'mode' = 'HIGHEST_ONLY'
                                                  and ((y->>'amount')::numeric > (x->>'amount')::numeric
                                                       or ((y->>'amount')::numeric = (x->>'amount')::numeric and (y->>'id')::int < (x->>'id')::int)))
                                 then x || '{"counted": false}' else x end), '[]')
    into v_rewards from jsonb_array_elements(v_rewards) x;
  select coalesce(sum((x->>'amount')::numeric), 0) into v_rew_total from jsonb_array_elements(v_rewards) x where (x->>'counted')::boolean;

  -- الإضافات والخصومات والتصفير (B024–B026)
  for r in select * from public.commission_adjustments where month = v_m and employee_id = p_emp and status = 'active'
             and kind <> 'manual_tier' order by created_at, id loop
    if r.kind in ('add', 'deduct') then
      v_val := coalesce(r.amount, r.pct / 100 * case r.base when 'eligible' then v_eligible else coalesce(v_base_orig, 0) end);
      if r.kind = 'deduct' then v_val := -v_val; end if;
      v_adj_total := v_adj_total + v_val;
    else
      v_val := null;
      if r.kind = 'zero_base' then v_zero_base := true; else v_zero_all := true; end if;
    end if;
    v_adj := v_adj || jsonb_build_object('id', r.id, 'kind', r.kind, 'amount', r.amount, 'pct', r.pct, 'base', r.base,
                                         'value', v_val, 'reason', r.reason, 'by', r.created_name, 'at', r.created_at);
  end loop;
  if v_zero_base then v_base := 0; end if;
  v_final := case when v_zero_all then 0 when v_base is null then null else v_base + v_rew_total + v_adj_total end;

  select coalesce(jsonb_agg(x order by x->>'source', x->>'code', x->>'tier'), '[]') into v_lines from (
    select jsonb_build_object('source', source, 'part', part, 'product_id', product_id,
             'code', (select code from public.products where id = product_id), 'name', (select name from public.products where id = product_id),
             'tier', tier, 'rate', rate, 'unit', unit, 'src', src, 'value', sum(value), 'commission', sum(commission),
             'docs', count(distinct doc_id)) x
      from _cm group by source, part, product_id, tier, rate, unit, src) q;
  select coalesce(jsonb_agg(x order by x->>'date', x->>'number'), '[]') into v_paid from (
    select jsonb_build_object('doc_id', doc_id, 'number', doc_number, 'date', doc_date, 'rep_id', rep_id, 'tier', min(tier),
             'customer', (select customer_number || ' — ' || name from public.customers where id = min(customer_id)),
             'paid', sum(value), 'commission', sum(commission)) x
      from _cm where source in ('paid', 'opening') group by doc_id, doc_number, doc_date, rep_id) q;
  -- الذمم المؤجلة غير المسددة آخر الشهر من فواتير شهور التحصيل: بلا عمولة حتى سدادها
  select coalesce(jsonb_agg(jsonb_build_object('doc_id', d.id, 'number', d.doc_number, 'date', d.doc_date, 'total', d.total,
           'remaining', d.total - coalesce(pd.v, 0), 'rep_id', d.employee_id,
           'customer', (select customer_number || ' — ' || name from public.customers where id = d.customer_id)) order by d.doc_date, d.doc_number), '[]')
    into v_deferred
    from public.docs d
    left join lateral (select sum(a.amount) v from app.ledger_allocs a where a.debt_key = 'doc:' || d.id and a.alloc_date <= v_e) pd on true
   where d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم' and d.doc_date <= v_e
     and app.doc_in_scope(d, p_emp, v_role, false) and (v_role = 'rep' or d.employee_id <> p_emp)
     and app.is_collection_rep(d.employee_id, d.doc_date)
     and d.total - coalesce(pd.v, 0) > 0;

  v_blocking := exists (select 1 from jsonb_array_elements(v_warn) x where (x->>'blocking')::boolean);
  return jsonb_build_object(
    'employee_id', p_emp, 'month', v_m, 'role', v_role, 'rule_id', v_rule,
    'rule_name', (select name from public.commission_rules where id = v_rule),
    'collection_mode', v_coll and v_role = 'rep', 'plan_id', v_plan.id,
    'tier_calc', v_calc_tier, 'tier_manual', v_manual, 'tier_effective', v_tier,
    'eligible', v_eligible, 'team_eligible', v_team, 'personal_eligible', v_personal,
    'personal_rate', case when v_role = 'supervisor' then to_jsonb(v_pr) end,
    'base_commission', v_base, 'base_original', v_base_orig, 'zero_base', v_zero_base, 'zero_all', v_zero_all,
    'rewards', v_rewards, 'rewards_total', v_rew_total, 'adjustments', v_adj, 'adjustments_total', v_adj_total,
    'final', v_final, 'warnings', v_warn, 'blocking', v_blocking, 'status', case when v_blocking then 'incomplete' else 'complete' end,
    'lines', v_lines, 'paid', v_paid, 'deferred', v_deferred,
    'goals', case when v_eval is not null then jsonb_build_object('achieved', v_eval->'achieved', 'components', v_eval->'components', 'days', v_eval->'days') end);
end $$;

-- =====================================================================
-- واجهات القراءة والكتابة
-- =====================================================================

-- غير الإدارة لا يعدّل أهدافه أو عمولته أو استثناءاته بنفسه (قاعدة الصلاحيات: لا يعدّل حسابه)
create or replace function app.require_not_self(p_emp bigint) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.is_admin() and p_emp is not null and p_emp = (select employee_id from public.app_users where id = auth.uid()) then
    perform app.fail('self_edit', 'لا تعدّل بياناتك أنت؛ هذا الإجراء لمن يملك الصلاحية عليك');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- P19 — التقويم
-- ---------------------------------------------------------------------
create or replace function public.calendar_month(p_month date, p_employee bigint default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.has_perm('P19') or app.has_perm('P10') or app.has_perm('P10a') or app.has_perm('P13')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  if p_employee is not null then perform app.require_employee_scope(p_employee); end if;
  return jsonb_build_object(
    'month', app.month_of(p_month), 'weekdays', to_jsonb(app.work_weekdays()),
    'days', (select jsonb_agg(jsonb_build_object('d', d, 'work', work, 'holiday', holiday, 'eligible', eligible, 'prop', prop, 'fixed', fixed) order by d)
               from app.emp_day_flags(p_employee, p_month)),
    'emp_days', case when p_employee is not null then app.emp_days(p_employee, p_month) end,
    'holidays', coalesce((select jsonb_agg(to_jsonb(h) order by h.start_date) from public.holidays h
                           where h.end_date >= app.month_of(p_month) and h.start_date <= app.month_end(p_month)), '[]'),
    'exceptions', coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object('employee_name', em.name, 'emp_number', em.emp_number) order by e.start_date)
                              from public.employee_exceptions e join public.employees em on em.id = e.employee_id
                             where e.status = 'active' and e.end_date >= app.month_of(p_month) and e.start_date <= app.month_end(p_month)
                               and (p_employee is null or e.employee_id = p_employee) and app.can_see_employee(e.employee_id)), '[]'),
    'closed', app.is_closed(p_month));
end $$;

create or replace function public.save_work_weekdays(p_days int[], p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb := (select value from public.settings where key = 'work_weekdays');
begin
  perform app.require_perm('P19', 'edit');
  if p_days is null or exists (select 1 from unnest(p_days) x where x not between 0 and 6) then
    perform app.fail('bad_days', 'أيام العمل غير صحيحة');
  end if;
  insert into public.settings (key, value, updated_at, updated_by)
  values ('work_weekdays', to_jsonb((select array_agg(distinct x order by x) from unnest(p_days) x)), now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  perform app.audit('settings', 'work_weekdays', 'update', v_before, to_jsonb(p_days));
end $$;

-- p: {start_date, end_date, name, reason}
create or replace function public.save_holiday(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.holidays; v_id bigint;
  v_s date := (p->>'start_date')::date; v_e date := coalesce(nullif(p->>'end_date', '')::date, (p->>'start_date')::date);
begin
  perform app.require_perm('P19', 'edit');
  if v_s is null or coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'التاريخ والاسم مطلوبان'); end if;
  if v_e < v_s then perform app.fail('bad_range', 'نهاية العطلة قبل بدايتها'); end if;
  if p_id is not null then
    select * into v_old from public.holidays where id = p_id;
    if not found then perform app.fail('not_found', 'العطلة غير موجودة'); end if;
    perform app.guard_dates(array[app.first_closed_in(least(v_old.start_date, v_s), greatest(v_old.end_date, v_e))], p_code);
    update public.holidays set start_date = v_s, end_date = v_e, name = trim(p->>'name'), reason = p->>'reason' where id = p_id;
    v_id := p_id;
  else
    perform app.guard_dates(array[app.first_closed_in(v_s, v_e)], p_code);
    insert into public.holidays (start_date, end_date, name, reason, created_by)
    values (v_s, v_e, trim(p->>'name'), p->>'reason', auth.uid()) returning id into v_id;
  end if;
  perform app.audit('holidays', v_id::text, case when p_id is null then 'create' else 'update' end, to_jsonb(v_old),
                    (select to_jsonb(h) from public.holidays h where id = v_id));
  return v_id;
end $$;

create or replace function public.delete_holiday(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.holidays;
begin
  perform app.require_perm('P19', 'edit');
  select * into v_old from public.holidays where id = p_id;
  if not found then perform app.fail('not_found', 'العطلة غير موجودة'); end if;
  perform app.guard_dates(array[app.first_closed_in(v_old.start_date, v_old.end_date)], p_code);
  delete from public.holidays where id = p_id;
  perform app.audit('holidays', p_id::text, 'delete', to_jsonb(v_old), null, p_reason);
end $$;

-- استثناء الموظف (CAL-002/003): النمط يختار عند الإضافة؛ تعارض ثابت ومتناسب لليوم نفسه يُظهر ليختار المستخدم
-- p: {employee_id, start_date, end_date, mode, reason}
create or replace function public.save_exception(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.employee_exceptions; v_id bigint;
  v_emp bigint := (p->>'employee_id')::bigint;
  v_s date := (p->>'start_date')::date; v_e date := coalesce(nullif(p->>'end_date', '')::date, (p->>'start_date')::date);
  v_mode text := p->>'mode'; v_conf record;
begin
  if not (app.has_perm('P19', 'edit') or app.has_perm('P03', 'edit')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  if p_id is not null then
    select * into v_old from public.employee_exceptions where id = p_id and status = 'active';
    if not found then perform app.fail('not_found', 'الاستثناء غير موجود'); end if;
    v_emp := v_old.employee_id;
  end if;
  perform app.require_employee_scope(v_emp);
  perform app.require_not_self(v_emp);
  if v_s is null or v_mode not in ('fixed', 'proportional') or coalesce(trim(p->>'reason'), '') = '' then
    perform app.fail('required', 'التاريخ ونمط الأثر (ثابت أو متناسب) والسبب مطلوبة');
  end if;
  if v_e < v_s then perform app.fail('bad_range', 'نهاية الاستثناء قبل بدايته'); end if;
  select * into v_conf from public.employee_exceptions
   where employee_id = v_emp and status = 'active' and id is distinct from p_id and mode <> v_mode
     and daterange(start_date, end_date, '[]') && daterange(v_s, v_e, '[]') limit 1;
  if found then
    perform app.fail('exception_conflict', 'تعارض: الأيام ' || to_char(greatest(v_s, v_conf.start_date), 'FMDD/FMMM/YYYY') || '–'
      || to_char(least(v_e, v_conf.end_date), 'FMDD/FMMM/YYYY') || ' عليها استثناء ' || case v_conf.mode when 'fixed' then 'ثابت' else 'متناسب' end
      || '؛ اختر معاملة واحدة لها بتعديل أحد الاستثناءين');
  end if;
  perform app.guard_dates(array[app.first_closed_in(least(v_s, v_old.start_date), greatest(v_e, v_old.end_date))], p_code);
  if p_id is null then
    insert into public.employee_exceptions (employee_id, start_date, end_date, mode, reason, created_by)
    values (v_emp, v_s, v_e, v_mode, trim(p->>'reason'), auth.uid()) returning id into v_id;
  else
    update public.employee_exceptions set start_date = v_s, end_date = v_e, mode = v_mode, reason = trim(p->>'reason') where id = p_id;
    v_id := p_id;
  end if;
  perform app.audit('employee_exceptions', v_id::text, case when p_id is null then 'create' else 'update' end, to_jsonb(v_old),
                    (select to_jsonb(x) from public.employee_exceptions x where id = v_id), p->>'reason');
  return v_id;
end $$;

create or replace function public.delete_exception(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.employee_exceptions;
begin
  if not (app.has_perm('P19', 'edit') or app.has_perm('P03', 'edit')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  select * into v_old from public.employee_exceptions where id = p_id and status = 'active';
  if not found then perform app.fail('not_found', 'الاستثناء غير موجود'); end if;
  perform app.require_employee_scope(v_old.employee_id);
  perform app.require_not_self(v_old.employee_id);
  if coalesce(trim(p_reason), '') = '' then perform app.fail('required', 'سبب الحذف مطلوب'); end if;
  perform app.guard_dates(array[app.first_closed_in(v_old.start_date, v_old.end_date)], p_code);
  update public.employee_exceptions set status = 'deleted' where id = p_id;
  perform app.audit('employee_exceptions', p_id::text, 'delete', to_jsonb(v_old), null, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- P10 / P10a — خطط الأهداف
-- ---------------------------------------------------------------------

create or replace function app.plan_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(p) || jsonb_build_object(
    'employee_name', e.name, 'emp_number', e.emp_number,
    'tiers', coalesce((select jsonb_agg(jsonb_build_object('tier', t.tier, 'sort', t.sort, 'logic', t.logic) order by t.sort)
                         from public.goal_tiers t where t.plan_id = p.id), '[]'),
    'components', coalesce((select jsonb_agg(jsonb_build_object('tier', c.tier, 'sort', c.sort, 'metric', c.metric, 'target', c.target,
                                                                'affected', c.affected, 'filters', c.filters, 'label', c.label)
                                             order by c.tier nulls last, c.sort, c.id)
                              from public.goal_components c where c.plan_id = p.id), '[]'))
    from public.goal_plans p join public.employees e on e.id = p.employee_id where p.id = p_id
$$;

-- كتابة الشرائح والمكونات من JSON مع التحقق
create or replace function app.write_plan_parts(p_plan bigint, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t jsonb; c jsonb; i int := 0;
begin
  delete from public.goal_tiers where plan_id = p_plan;
  delete from public.goal_components where plan_id = p_plan;
  for t in select * from jsonb_array_elements(coalesce(p->'tiers', '[]')) loop
    i := i + 1;
    if coalesce(trim(t->>'tier'), '') = '' then perform app.fail('required', 'رمز الشريحة مطلوب'); end if;
    insert into public.goal_tiers (plan_id, tier, sort, logic)
    values (p_plan, upper(trim(t->>'tier')), coalesce((t->>'sort')::int, i), coalesce(nullif(t->>'logic', ''), 'AND'));
  end loop;
  i := 0;
  for c in select * from jsonb_array_elements(coalesce(p->'components', '[]')) loop
    i := i + 1;
    if app.metric_kind(c->>'metric') is null then perform app.fail('bad_metric', 'مقياس غير معروف: ' || coalesce(c->>'metric', '')); end if;
    if nullif(c->>'tier', '') is not null and not exists (select 1 from public.goal_tiers where plan_id = p_plan and tier = upper(trim(c->>'tier'))) then
      perform app.fail('bad_tier', 'المكوّن مرتبط بشريحة غير معرفة في الخطة: ' || (c->>'tier'));
    end if;
    if nullif(c->>'target', '') is not null and (c->>'target')::numeric < 0 then perform app.fail('bad_target', 'الهدف لا يكون سالبًا'); end if;
    insert into public.goal_components (plan_id, tier, sort, metric, target, affected, filters, label)
    values (p_plan, upper(nullif(trim(c->>'tier'), '')), coalesce((c->>'sort')::int, i), c->>'metric', nullif(c->>'target', '')::numeric,
            coalesce((c->>'affected')::boolean, true), coalesce(c->'filters', '{}'), nullif(trim(c->>'label'), ''));
  end loop;
end $$;

-- p: {month, employee_id, role, sup_mode, partial_mode, include_personal, note, template_id, tiers:[...], components:[...]}
create or replace function public.save_goal_plan(p_id bigint, p jsonb, p_reason text default null, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.goal_plans; v_before jsonb; v_id bigint;
  v_month date := app.month_of(coalesce((p->>'month')::date, v_old.month));
  v_emp bigint := (p->>'employee_id')::bigint;
  v_role text := coalesce(p->>'role', 'rep');
  v_personal boolean := coalesce((p->>'include_personal')::boolean, false);
begin
  if p_id is not null then
    select * into v_old from public.goal_plans where id = p_id;
    if not found then perform app.fail('not_found', 'الخطة غير موجودة'); end if;
    v_before := app.plan_json(p_id);
    v_month := v_old.month; v_emp := v_old.employee_id; v_role := v_old.role;
    if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب التعديل مطلوب (GOAL-001)'); end if;
  end if;
  perform app.require_perm(app.plan_role_page(v_role), case when p_id is null then 'add' else 'edit' end);
  if v_month is null or v_emp is null then perform app.fail('required', 'الموظف والشهر مطلوبان'); end if;
  perform app.require_employee_scope(v_emp);
  perform app.require_not_self(v_emp);
  perform app.guard_dates(array[v_month], p_code);
  -- إدراج مبيعات المشرف الشخصية في إنجازه خيار للإدارة (COMM-006)
  if v_personal is distinct from coalesce(v_old.include_personal, false) and not app.is_admin() then
    perform app.fail('admin_only', 'إدراج مبيعات المشرف الشخصية في إنجازه خيار للإدارة وحدها');
  end if;
  if p_id is null then
    if exists (select 1 from public.goal_plans where month = v_month and employee_id = v_emp) then
      perform app.fail('duplicate', 'للموظف خطة في هذا الشهر؛ عدّلها بدل إنشاء أخرى');
    end if;
    insert into public.goal_plans (month, employee_id, role, sup_mode, partial_mode, include_personal, template_id, note, created_by, updated_by)
    values (v_month, v_emp, v_role, coalesce(nullif(p->>'sup_mode', ''), 'team_sum'), coalesce(nullif(p->>'partial_mode', ''), 'proportional'),
            v_personal, nullif(p->>'template_id', '')::bigint, p->>'note', auth.uid(), auth.uid())
    returning id into v_id;
  else
    v_id := p_id;
    update public.goal_plans set sup_mode = coalesce(nullif(p->>'sup_mode', ''), sup_mode),
           partial_mode = coalesce(nullif(p->>'partial_mode', ''), partial_mode), include_personal = v_personal,
           note = p->>'note', updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;
  perform app.write_plan_parts(v_id, p);
  perform app.audit('goal_plans', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.plan_json(v_id), p_reason);
  return v_id;
end $$;

-- معاينة الخطة قبل الاعتماد (GOAL-004): تحفظ مؤقتًا وتقيم ثم يتراجع عن الحفظ
create or replace function public.preview_goal_plan(p_id bigint, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_res jsonb; v_id bigint;
begin
  begin
    v_id := public.save_goal_plan(p_id, p, coalesce(p->>'reason', 'معاينة'), null);
    v_res := app.plan_eval(v_id, least(app.today(), app.month_end((select month from public.goal_plans where id = v_id))));
    raise exception using errcode = 'P0002', message = 'preview';
  exception when sqlstate 'P0002' then
    null;
  end;
  return v_res;
end $$;

create or replace function public.delete_goal_plan(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.goal_plans;
begin
  select * into v_old from public.goal_plans where id = p_id;
  if not found then perform app.fail('not_found', 'الخطة غير موجودة'); end if;
  perform app.require_perm(app.plan_role_page(v_old.role), 'delete');
  perform app.require_employee_scope(v_old.employee_id);
  perform app.require_not_self(v_old.employee_id);
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  perform app.guard_dates(array[v_old.month], p_code);
  perform app.audit('goal_plans', p_id::text, 'delete', app.plan_json(p_id), null, p_reason);
  delete from public.goal_plans where id = p_id;
end $$;

-- قائمة الصفحة: الموظفون ضمن النطاق وخططهم للشهر مع الهدف الأصلي والنهائي والأيام والإنجاز والشريحة
create or replace function public.goals_list(p_month date, p_role text, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
  v_cut date := least(app.today(), app.month_end(p_month));
  o jsonb := coalesce(p_opts, '{}');
  r record; v_eval jsonb; v_out jsonb := '[]';
begin
  perform app.require_perm(app.plan_role_page(p_role), 'view');
  for r in
    select e.id, e.emp_number, e.name, e.status, p.id plan_id
      from public.employees e
      left join public.goal_plans p on p.employee_id = e.id and p.month = v_m
     where app.can_see_employee(e.id)
       and (p.id is not null and p.role = p_role
            or p.id is null and app.emp_role(e.id, v_m) = p_role
               and exists (select 1 from public.employment_periods ep where ep.employee_id = e.id
                              and daterange(ep.start_date, ep.end_date, '[]') && daterange(v_m, app.month_end(v_m), '[]')))
       and (coalesce(o->>'search', '') = '' or e.name ilike '%' || (o->>'search') || '%' or e.emp_number = trim(o->>'search'))
       and (nullif(o->>'supervisor_id', '') is null or exists (select 1 from public.supervisor_assignments s
              where s.employee_id = e.id and s.supervisor_id = (o->>'supervisor_id')::bigint
                and daterange(s.valid_from, s.valid_to, '[]') && daterange(v_m, app.month_end(v_m), '[]')))
       and (coalesce(o->>'state', '') = '' or (o->>'state' = 'with_plan') = (p.id is not null))
     order by e.name
  loop
    v_eval := case when r.plan_id is not null then
                case when app.is_closed(v_m) then (select s.card->'eval' from public.month_snapshots s where s.month = v_m and s.employee_id = r.id order by s.version desc limit 1)
                     else app.plan_eval(r.plan_id, v_cut) end end;
    v_out := v_out || jsonb_build_object('employee_id', r.id, 'emp_number', r.emp_number, 'name', r.name, 'status', r.status,
      'plan_id', r.plan_id, 'days', coalesce(v_eval->'days', app.emp_days(r.id, v_m, v_cut)),
      'main', v_eval->'main', 'achieved', v_eval->'achieved', 'path_tier', v_eval->'path_tier',
      'components', (select count(*) from jsonb_array_elements(coalesce(v_eval->'components', '[]')) x where x->>'status' <> 'unused'),
      'zero', exists (select 1 from jsonb_array_elements(coalesce(v_eval->'components', '[]')) x where x->>'status' = 'zero'));
  end loop;
  return jsonb_build_object('month', v_m, 'cutoff', v_cut, 'closed', app.is_closed(v_m), 'rows', v_out);
end $$;

create or replace function public.goal_plan(p_id bigint, p_cutoff date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v public.goal_plans;
begin
  select * into v from public.goal_plans where id = p_id;
  if not found then perform app.fail('not_found', 'الخطة غير موجودة'); end if;
  perform app.require_perm(app.plan_role_page(v.role), 'view');
  perform app.require_employee_scope(v.employee_id);
  return jsonb_build_object('plan', app.plan_json(p_id),
    'eval', app.plan_eval(p_id, coalesce(p_cutoff, least(app.today(), app.month_end(v.month)))),
    'closed', app.is_closed(v.month),
    'rule', (select jsonb_build_object('id', r.id, 'name', r.name, 'tiers',
                (select jsonb_agg(jsonb_build_object('tier', t.tier, 'sort', t.sort) order by t.sort) from public.rule_tiers t where t.rule_id = r.id))
               from public.commission_rules r where r.id = app.emp_rule(v.employee_id, v.month)),
    'has_personal', v.role = 'supervisor' and exists (select 1 from public.docs d where d.employee_id = v.employee_id and d.status = 'active'
                        and d.kind = 'invoice' and d.doc_date between v.month and app.month_end(v.month)));
end $$;

-- القوالب (GOAL-006، GOAL-010): القالب ينسخ إعداد كل مكوّن كما حُفظ
create or replace function public.save_goal_template(p_id bigint, p_name text, p_role text, p_data jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint; v_before jsonb;
begin
  perform app.require_perm(app.plan_role_page(coalesce(p_role, 'rep')), case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p_name), '') = '' then perform app.fail('required', 'اسم القالب مطلوب'); end if;
  if p_id is null then
    insert into public.goal_templates (name, role, data, created_by) values (trim(p_name), coalesce(p_role, 'rep'), p_data, auth.uid())
    returning id into v_id;
  else
    select to_jsonb(t) into v_before from public.goal_templates t where id = p_id;
    update public.goal_templates set name = trim(p_name), data = p_data, updated_at = now() where id = p_id;
    v_id := p_id;
  end if;
  perform app.audit('goal_templates', v_id::text, case when p_id is null then 'create' else 'update' end, v_before,
                    (select to_jsonb(t) from public.goal_templates t where id = v_id));
  return v_id;
end $$;

create or replace function public.delete_goal_template(p_id bigint) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v public.goal_templates;
begin
  select * into v from public.goal_templates where id = p_id;
  if not found then perform app.fail('not_found', 'القالب غير موجود'); end if;
  perform app.require_perm(app.plan_role_page(v.role), 'delete');
  delete from public.goal_templates where id = p_id;
  perform app.audit('goal_templates', p_id::text, 'delete', to_jsonb(v), null);
end $$;

create or replace function public.goal_templates_list(p_role text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.has_perm('P10') or app.has_perm('P10a')) then perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء'); end if;
  return coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object('plans', (select count(*) from public.goal_plans p where p.template_id = t.id))
                                    order by t.name)
                     from public.goal_templates t where p_role is null or t.role = p_role), '[]');
end $$;

-- تحديث خطط سابقة من القالب بإجراء صريح ومعاينة (GOAL-010)؛ المقفل محمي
create or replace function public.apply_goal_template(p_template bigint, p_plans bigint[], p_commit boolean,
                                                      p_reason text default null, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_t public.goal_templates; r record; v_out jsonb := '[]'; v_new jsonb;
begin
  select * into v_t from public.goal_templates where id = p_template;
  if not found then perform app.fail('not_found', 'القالب غير موجود'); end if;
  perform app.require_perm(app.plan_role_page(v_t.role), 'edit');
  for r in select p.*, e.name from public.goal_plans p join public.employees e on e.id = p.employee_id
            where p.id = any(p_plans) order by e.name loop
    perform app.require_employee_scope(r.employee_id);
    v_new := app.plan_json(r.id) || jsonb_build_object('tiers', v_t.data->'tiers', 'components', v_t.data->'components',
               'partial_mode', coalesce(v_t.data->>'partial_mode', r.partial_mode), 'sup_mode', coalesce(v_t.data->>'sup_mode', r.sup_mode));
    v_out := v_out || jsonb_build_object('plan_id', r.id, 'employee', r.name, 'month', r.month, 'closed', app.is_closed(r.month),
      'before', app.plan_json(r.id)->'components', 'after', v_t.data->'components');
    if p_commit then
      perform public.save_goal_plan(r.id, v_new || jsonb_build_object('template_id', p_template), coalesce(p_reason, 'تحديث من القالب ' || v_t.name), p_code);
      update public.goal_plans set template_id = p_template where id = r.id;
    end if;
  end loop;
  return v_out;
end $$;

-- نسخ خطط شهر إلى شهر للموظفين الذين لا خطة لهم فيه (P10: نسخ شهر)
create or replace function public.copy_goal_plans(p_from date, p_to date, p_role text, p_commit boolean, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record; v_out jsonb := '[]';
begin
  perform app.require_perm(app.plan_role_page(p_role), 'add');
  if app.month_of(p_from) = app.month_of(p_to) then perform app.fail('same_month', 'اختر شهرًا مختلفًا'); end if;
  for r in select p.*, e.name from public.goal_plans p join public.employees e on e.id = p.employee_id
            where p.month = app.month_of(p_from) and p.role = p_role and app.can_see_employee(p.employee_id)
            order by e.name loop
    continue when exists (select 1 from public.goal_plans x where x.month = app.month_of(p_to) and x.employee_id = r.employee_id);
    v_out := v_out || jsonb_build_object('employee_id', r.employee_id, 'employee', r.name);
    if p_commit then
      perform public.save_goal_plan(null, app.plan_json(r.id) || jsonb_build_object('month', app.month_of(p_to),
        'include_personal', case when app.is_admin() then r.include_personal else false end), null, p_code);
    end if;
  end loop;
  return v_out;
end $$;

-- تعديل جماعي بمعاينة: قيمة جديدة أو نسبة تغيير لمكوّن (شريحة + مقياس) في خطط مختارة
create or replace function public.bulk_adjust_goals(p_plans bigint[], p_tier text, p_metric text, p_mode text, p_value numeric,
                                                    p_commit boolean, p_reason text default null, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record; v_out jsonb := '[]'; v_new numeric; v_plan jsonb;
begin
  if p_mode not in ('set', 'percent') or p_value is null then perform app.fail('required', 'طريقة التعديل وقيمته مطلوبتان'); end if;
  if p_commit and coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب التعديل مطلوب'); end if;
  for r in select p.id plan_id, p.role, p.month, p.employee_id, e.name, c.target
             from public.goal_plans p join public.employees e on e.id = p.employee_id
             join public.goal_components c on c.plan_id = p.id and c.tier is not distinct from upper(nullif(p_tier, '')) and c.metric = p_metric
            where p.id = any(p_plans) order by e.name loop
    perform app.require_perm(app.plan_role_page(r.role), 'edit');
    perform app.require_employee_scope(r.employee_id);
    v_new := case p_mode when 'set' then p_value else round(coalesce(r.target, 0) * (1 + p_value / 100), 3) end;
    v_out := v_out || jsonb_build_object('plan_id', r.plan_id, 'employee', r.name, 'before', r.target, 'after', v_new, 'closed', app.is_closed(r.month));
    if p_commit then
      v_plan := app.plan_json(r.plan_id);
      v_plan := jsonb_set(v_plan, '{components}', (select jsonb_agg(case when x->>'metric' = p_metric and (x->>'tier') is not distinct from upper(nullif(p_tier, ''))
                                                                      then jsonb_set(x, '{target}', to_jsonb(v_new)) else x end)
                                                       from jsonb_array_elements(v_plan->'components') x));
      perform public.save_goal_plan(r.plan_id, v_plan, p_reason, p_code);
    end if;
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------
-- P11 — قواعد العمولة وإعداداتها الشهرية
-- ---------------------------------------------------------------------

create or replace function app.rule_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(r) || jsonb_build_object(
    'tiers', coalesce((select jsonb_agg(jsonb_build_object('tier', t.tier, 'sort', t.sort, 'rep_rate', t.rep_rate, 'sup_rate', t.sup_rate) order by t.sort)
                         from public.rule_tiers t where t.rule_id = r.id), '[]'),
    'members', coalesce((select jsonb_agg(jsonb_build_object('employee_id', m.employee_id, 'name', e.name, 'emp_number', e.emp_number) order by e.name)
                           from public.rule_members m join public.employees e on e.id = m.employee_id where m.rule_id = r.id), '[]'))
    from public.commission_rules r where r.id = p_id
$$;

create or replace function public.commission_month(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
begin
  perform app.require_perm('P11', 'view');
  return jsonb_build_object(
    'month', v_m, 'closed', app.is_closed(v_m),
    'rules', coalesce((select jsonb_agg(app.rule_json(r.id) order by r.name) from public.commission_rules r where r.month = v_m), '[]'),
    'uncovered', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.name, 'emp_number', e.emp_number) order by e.name)
                             from public.employees e
                            where app.can_see_employee(e.id) and app.emp_rule(e.id, v_m) is null
                              and exists (select 1 from public.employment_periods ep where ep.employee_id = e.id
                                             and daterange(ep.start_date, ep.end_date, '[]') && daterange(v_m, app.month_end(v_m), '[]'))), '[]'),
    'collection_reps', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'employee_id', c.employee_id, 'name', e.name, 'emp_number', e.emp_number,
                                                                     'from_month', c.from_month, 'to_month', c.to_month) order by e.name, c.from_month)
                                   from public.collection_reps c join public.employees e on e.id = c.employee_id where app.can_see_employee(c.employee_id)), '[]'),
    'debt_age', jsonb_build_object('current', app.debt_age_at(app.today()),
       'history', coalesce((select jsonb_agg(to_jsonb(s) order by s.effective_from desc) from public.commission_settings s where s.key = 'debt_age_days'), '[]')),
    'opening_reps', coalesce((select jsonb_agg(jsonb_build_object('customer_id', o.customer_id, 'customer_number', c.customer_number, 'customer', c.name,
                                                                  'employee_id', o.employee_id, 'employee', e.name, 'effective_from', o.effective_from) order by c.customer_number, o.effective_from)
                                from public.opening_collection_reps o join public.customers c on c.id = o.customer_id
                                left join public.employees e on e.id = o.employee_id where app.can_see_customer(o.customer_id)), '[]'),
    'personal_rates', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'name', e.name, 'rate', pr.rate, 'unit', pr.unit,
                         'personal_sales', (select coalesce(sum(d.total), 0) from public.docs d where d.employee_id = e.id and d.status = 'active'
                                              and d.kind = 'invoice' and d.doc_date between v_m and app.month_end(v_m))) order by e.name)
                                  from public.employees e left join public.supervisor_personal_rates pr on pr.employee_id = e.id and pr.month = v_m
                                 where app.can_see_employee(e.id) and app.emp_role(e.id, v_m) = 'supervisor'), '[]'),
    'review', (select to_jsonb(rv) from public.rate_reviews rv where rv.month = v_m),
    'review_due', v_m = app.month_of(app.today()) and not exists (select 1 from public.rate_reviews where month = v_m),
    'default_tiers', to_jsonb(app.default_tiers()));
end $$;

-- p: {month, name, note, tiers:[{tier, sort, rep_rate, sup_rate}], members:[ids]}
create or replace function public.save_commission_rule(p_id bigint, p jsonb, p_reason text default null, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.commission_rules; v_before jsonb; v_id bigint; v_m date; t jsonb; i int := 0; m bigint;
begin
  perform app.require_perm('P11', case when p_id is null then 'add' else 'edit' end);
  if p_id is not null then
    select * into v_old from public.commission_rules where id = p_id;
    if not found then perform app.fail('not_found', 'القاعدة غير موجودة'); end if;
    v_before := app.rule_json(p_id);
    v_m := v_old.month;
    -- لا يعدل قاعدة تشمل موظفين خارج نطاقه
    if exists (select 1 from public.rule_members x where x.rule_id = p_id and not app.can_see_employee(x.employee_id)) then
      perform app.fail('out_of_scope', 'القاعدة تشمل موظفين خارج نطاق بياناتك');
    end if;
  else
    v_m := app.month_of((p->>'month')::date);
  end if;
  if v_m is null or coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'الشهر واسم القاعدة مطلوبان'); end if;
  perform app.guard_dates(array[v_m], p_code);
  if p_id is null then
    insert into public.commission_rules (month, name, note, created_by) values (v_m, trim(p->>'name'), p->>'note', auth.uid()) returning id into v_id;
  else
    update public.commission_rules set name = trim(p->>'name'), note = p->>'note', updated_at = now() where id = p_id;
    v_id := p_id;
  end if;
  delete from public.rule_tiers where rule_id = v_id;
  for t in select * from jsonb_array_elements(coalesce(p->'tiers', '[]')) loop
    i := i + 1;
    if coalesce(trim(t->>'tier'), '') = '' then perform app.fail('required', 'رمز الشريحة مطلوب'); end if;
    insert into public.rule_tiers (rule_id, tier, sort, rep_rate, sup_rate)
    values (v_id, upper(trim(t->>'tier')), coalesce((t->>'sort')::int, i), nullif(t->>'rep_rate', '')::numeric, nullif(t->>'sup_rate', '')::numeric);
  end loop;
  delete from public.rule_members where rule_id = v_id;
  for m in select x::bigint from jsonb_array_elements_text(coalesce(p->'members', '[]')) x loop
    perform app.require_employee_scope(m);
    if exists (select 1 from public.rule_members where month = v_m and employee_id = m) then
      perform app.fail('duplicate_member', 'الموظف ' || (select name from public.employees where id = m) || ' مشمول بقاعدة أخرى في هذا الشهر');
    end if;
    insert into public.rule_members (rule_id, month, employee_id) values (v_id, v_m, m);
  end loop;
  perform app.audit('commission_rules', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.rule_json(v_id), p_reason);
  return v_id;
end $$;

-- معاينة أثر القاعدة على المشمولين قبل الحفظ (P11، COMM-004): العمولة الأساسية قبل وبعد
create or replace function public.preview_commission_rule(p_id bigint, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := coalesce((select month from public.commission_rules where id = p_id), app.month_of((p->>'month')::date));
  v_emps bigint[]; v_before jsonb := '{}'; v_after jsonb := '{}'; e bigint; v_out jsonb := '[]'; v_c jsonb;
begin
  perform app.require_perm('P11', 'view');
  v_emps := array(select distinct x from (
              select x::bigint x from jsonb_array_elements_text(coalesce(p->'members', '[]')) x
              union select employee_id from public.rule_members where rule_id = p_id) q where app.can_see_employee(x));
  foreach e in array v_emps loop
    v_c := app.commission_calc(e, v_m);
    v_before := v_before || jsonb_build_object(e::text, jsonb_build_object('base', v_c->'base_commission', 'tier', v_c->'tier_effective', 'status', v_c->'status'));
  end loop;
  begin
    perform public.save_commission_rule(p_id, p, 'معاينة', null);
    foreach e in array v_emps loop
      v_c := app.commission_calc(e, v_m);
      v_after := v_after || jsonb_build_object(e::text, jsonb_build_object('base', v_c->'base_commission', 'tier', v_c->'tier_effective', 'status', v_c->'status',
                                                                           'warnings', v_c->'warnings'));
    end loop;
    raise exception using errcode = 'P0002', message = 'preview';
  exception when sqlstate 'P0002' then null;
  end;
  foreach e in array v_emps loop
    v_out := v_out || jsonb_build_object('employee_id', e, 'name', (select name from public.employees where id = e),
                                         'before', v_before->e::text, 'after', v_after->e::text);
  end loop;
  return v_out;
end $$;

create or replace function public.delete_commission_rule(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v public.commission_rules;
begin
  perform app.require_perm('P11', 'delete');
  select * into v from public.commission_rules where id = p_id;
  if not found then perform app.fail('not_found', 'القاعدة غير موجودة'); end if;
  if exists (select 1 from public.rule_members x where x.rule_id = p_id and not app.can_see_employee(x.employee_id)) then
    perform app.fail('out_of_scope', 'القاعدة تشمل موظفين خارج نطاق بياناتك');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  perform app.guard_dates(array[v.month], p_code);
  perform app.audit('commission_rules', p_id::text, 'delete', app.rule_json(p_id), null, p_reason);
  delete from public.commission_rules where id = p_id;
end $$;

-- نسخ قواعد شهر إلى شهر لا قواعد فيه (غياب التعيين لا يختار قاعدة سابقة ضمنًا: النسخ إجراء صريح)
create or replace function public.copy_commission_rules(p_from date, p_to date, p_code text default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare
  r record; n int := 0;
begin
  perform app.require_perm('P11', 'add');
  if exists (select 1 from public.commission_rules where month = app.month_of(p_to)) then
    perform app.fail('not_empty', 'للشهر الهدف قواعد؛ النسخ لشهر بلا قواعد فقط');
  end if;
  for r in select id from public.commission_rules where month = app.month_of(p_from) loop
    perform public.save_commission_rule(null, app.rule_json(r.id) || jsonb_build_object('month', app.month_of(p_to),
      'members', coalesce((select jsonb_agg(x->'employee_id') from jsonb_array_elements(app.rule_json(r.id)->'members') x
                            where exists (select 1 from public.employment_periods ep where ep.employee_id = (x->>'employee_id')::bigint
                                            and daterange(ep.start_date, ep.end_date, '[]') && daterange(app.month_of(p_to), app.month_end(p_to), '[]'))), '[]')),
      'نسخ من ' || to_char(p_from, 'FMMM/YYYY'), p_code);
    n := n + 1;
  end loop;
  return n;
end $$;

-- اختيار مندوب لعمولة التحصيل أو إلغاؤه من شهر مفتوح تحدده الإدارة (COMM-008)
create or replace function public.set_collection_rep(p_employee bigint, p_from_month date, p_on boolean, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_from_month); v_cur public.collection_reps;
begin
  perform app.require_admin();
  perform app.guard_dates(array[app.first_closed_in(v_m, null)], p_code);
  select * into v_cur from public.collection_reps where employee_id = p_employee and (to_month is null or to_month >= v_m)
   order by from_month desc limit 1;
  if p_on then
    if found and v_cur.from_month <= v_m then perform app.fail('already', 'المندوب مختار لعمولة التحصيل في هذا الشهر'); end if;
    if found then
      update public.collection_reps set from_month = v_m where id = v_cur.id;
    else
      insert into public.collection_reps (employee_id, from_month, created_by) values (p_employee, v_m, auth.uid());
    end if;
  else
    if not found then perform app.fail('not_selected', 'المندوب غير مختار لعمولة التحصيل'); end if;
    if v_cur.from_month >= v_m then
      delete from public.collection_reps where id = v_cur.id;
    else
      update public.collection_reps set to_month = (v_m - interval '1 month')::date where id = v_cur.id;
    end if;
  end if;
  perform app.audit('collection_reps', p_employee::text, case when p_on then 'select' else 'unselect' end, to_jsonb(v_cur),
                    jsonb_build_object('from_month', v_m, 'on', p_on));
end $$;

-- حد عمر الدين (الفارغ = 30 يومًا) يسري من تاريخ التغيير
create or replace function public.save_debt_age(p_days numeric, p_from date default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := coalesce(p_from, app.today());
begin
  perform app.require_admin();
  if p_days is not null and p_days < 0 then perform app.fail('bad_value', 'عدد الأيام لا يكون سالبًا'); end if;
  if app.is_closed(v_from) then perform app.fail('closed_period', 'تاريخ السريان في شهر مقفل'); end if;
  insert into public.commission_settings (key, value, effective_from, created_by) values ('debt_age_days', p_days, v_from, auth.uid())
  on conflict (key, effective_from) do update set value = excluded.value, created_at = now(), created_by = auth.uid();
  perform app.audit('commission_settings', 'debt_age_days', 'update', null, jsonb_build_object('value', p_days, 'from', v_from));
end $$;

-- مندوب عمولة تحصيل الافتتاحي لعميل، أو «لا أحد» (p_employee فارغ)
create or replace function public.set_opening_rep(p_customer bigint, p_employee bigint, p_from date default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := coalesce(p_from, app.today());
begin
  perform app.require_admin();
  if app.is_closed(v_from) then perform app.fail('closed_period', 'تاريخ السريان في شهر مقفل'); end if;
  insert into public.opening_collection_reps (customer_id, employee_id, effective_from, created_by) values (p_customer, p_employee, v_from, auth.uid())
  on conflict (customer_id, effective_from) do update set employee_id = excluded.employee_id, created_at = now(), created_by = auth.uid();
  perform app.audit('opening_collection_reps', p_customer::text, 'update', null, jsonb_build_object('employee_id', p_employee, 'from', v_from));
end $$;

-- نسبة مبيعات المشرف الشخصية للشهر (COMM-006)؛ الفارغ يحذفها فتعود معلقة
create or replace function public.set_personal_rate(p_month date, p_employee bigint, p_rate numeric, p_unit text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb;
begin
  perform app.require_admin();
  perform app.guard_dates(array[app.month_of(p_month)], p_code);
  select to_jsonb(x) into v_before from public.supervisor_personal_rates x where month = app.month_of(p_month) and employee_id = p_employee;
  if p_rate is null then
    delete from public.supervisor_personal_rates where month = app.month_of(p_month) and employee_id = p_employee;
  else
    if p_unit not in ('pct', 'permille') or p_rate < 0 then perform app.fail('bad_value', 'النسبة ووحدتها (بالمئة أو بالألف) مطلوبتان'); end if;
    insert into public.supervisor_personal_rates (month, employee_id, rate, unit, updated_by) values (app.month_of(p_month), p_employee, p_rate, p_unit, auth.uid())
    on conflict (month, employee_id) do update set rate = excluded.rate, unit = excluded.unit, updated_at = now(), updated_by = auth.uid();
  end if;
  perform app.audit('supervisor_personal_rates', p_employee::text, 'update', v_before, jsonb_build_object('month', app.month_of(p_month), 'rate', p_rate, 'unit', p_unit));
end $$;

-- REVIEW-001: تسجيل مراجعة نسب الأصناف للشهر
create or replace function public.record_rate_review(p_month date, p_decision text, p_note text default null) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_admin();
  if p_decision not in ('no_change', 'edited') then perform app.fail('bad_value', 'اختر «لا تغيير» أو «تم التعديل»'); end if;
  insert into public.rate_reviews (month, decision, note, by_user, by_name)
  values (app.month_of(p_month), p_decision, p_note, auth.uid(), (select display_name from public.app_users where id = auth.uid()))
  on conflict (month) do update set decision = excluded.decision, note = excluded.note, at = now(), by_user = excluded.by_user, by_name = excluded.by_name;
  perform app.audit('rate_reviews', app.month_of(p_month)::text, 'record', null, jsonb_build_object('decision', p_decision, 'note', p_note));
end $$;

-- ---------------------------------------------------------------------
-- P12 — المكافآت
-- ---------------------------------------------------------------------
create or replace function public.save_reward(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.reward_plans; v_id bigint; v_m date; v_emps bigint[]; e bigint;
  v_cond text := p->>'cond_type'; v_vt text := p->>'value_type'; v_mode text := p->>'stack_mode'; v_group text := nullif(trim(p->>'group_name'), '');
begin
  perform app.require_perm('P12', case when p_id is null then 'add' else 'edit' end);
  if p_id is not null then
    select * into v_old from public.reward_plans where id = p_id and status = 'active';
    if not found then perform app.fail('not_found', 'المكافأة غير موجودة'); end if;
  end if;
  v_m := coalesce(v_old.month, app.month_of((p->>'month')::date));
  v_emps := (select array_agg(x::bigint) from jsonb_array_elements_text(p->'employees') x where jsonb_typeof(p->'employees') = 'array');
  if v_m is null or coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'الشهر واسم المكافأة مطلوبان'); end if;
  if coalesce(v_mode, '') not in ('STACK', 'HIGHEST_ONLY') then perform app.fail('stack_required', 'حدد طريقة الجمع صراحة: جمع المستحقات أو الأعلى فقط (B023)'); end if;
  if v_cond = 'tier' and coalesce(jsonb_array_length(p->'tiers'), 0) = 0 then perform app.fail('required', 'اختر الشرائح المؤهلة'); end if;
  if v_cond = 'metric' and (app.metric_kind(p->>'metric') is null or nullif(p->>'metric_min', '') is null) then
    perform app.fail('required', 'المقياس وحده الأدنى مطلوبان');
  end if;
  if coalesce(v_cond, '') not in ('tier', 'metric') then perform app.fail('required', 'نوع الشرط مطلوب'); end if;
  if v_vt = 'fixed' and nullif(p->>'amount', '') is null then perform app.fail('required', 'مبلغ المكافأة مطلوب'); end if;
  if v_vt = 'percent' and (nullif(p->>'pct', '') is null or coalesce(p->>'pct_base', '') not in ('eligible', 'base_commission')) then
    perform app.fail('base_required', 'المكافأة بالنسبة تحتاج نسبة وأساسًا صريحًا (B025)');
  end if;
  if coalesce(v_vt, '') not in ('fixed', 'percent') then perform app.fail('required', 'نوع القيمة مطلوب'); end if;
  if v_group is not null and exists (select 1 from public.reward_plans where month = v_m and status = 'active' and group_name = v_group
                                        and stack_mode <> v_mode and id is distinct from p_id) then
    perform app.fail('group_mode', 'مجموعة التداخل «' || v_group || '» لها طريقة جمع أخرى؛ وحّد الطريقة');
  end if;
  if v_emps is null then
    if not app.scope_is_all() then perform app.fail('out_of_scope', 'مكافأة لكل الموظفين تحتاج نطاق «الكل»؛ اختر موظفين ضمن نطاقك'); end if;
  else
    foreach e in array v_emps loop perform app.require_employee_scope(e); end loop;
  end if;
  perform app.guard_dates(array[v_m], p_code);
  if p_id is null then
    insert into public.reward_plans (month, name, role, employees, cond_type, tiers, metric, metric_min, filters, value_type, amount, pct, pct_base,
                                     group_name, stack_mode, note, created_by)
    values (v_m, trim(p->>'name'), coalesce(nullif(p->>'role', ''), 'all'), v_emps, v_cond,
            (select array_agg(upper(x)) from jsonb_array_elements_text(coalesce(p->'tiers', '[]')) x), p->>'metric',
            nullif(p->>'metric_min', '')::numeric, coalesce(p->'filters', '{}'), v_vt, nullif(p->>'amount', '')::numeric,
            nullif(p->>'pct', '')::numeric, case when v_vt = 'percent' then p->>'pct_base' end, v_group, v_mode, p->>'note', auth.uid())
    returning id into v_id;
  else
    update public.reward_plans set name = trim(p->>'name'), role = coalesce(nullif(p->>'role', ''), 'all'), employees = v_emps, cond_type = v_cond,
           tiers = (select array_agg(upper(x)) from jsonb_array_elements_text(coalesce(p->'tiers', '[]')) x), metric = p->>'metric',
           metric_min = nullif(p->>'metric_min', '')::numeric, filters = coalesce(p->'filters', '{}'), value_type = v_vt,
           amount = nullif(p->>'amount', '')::numeric, pct = nullif(p->>'pct', '')::numeric,
           pct_base = case when v_vt = 'percent' then p->>'pct_base' end, group_name = v_group, stack_mode = v_mode, note = p->>'note', updated_at = now()
     where id = p_id;
    v_id := p_id;
  end if;
  perform app.audit('reward_plans', v_id::text, case when p_id is null then 'create' else 'update' end, to_jsonb(v_old),
                    (select to_jsonb(x) from public.reward_plans x where id = v_id));
  return v_id;
end $$;

create or replace function public.delete_reward(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v public.reward_plans; e bigint;
begin
  perform app.require_perm('P12', 'delete');
  select * into v from public.reward_plans where id = p_id and status = 'active';
  if not found then perform app.fail('not_found', 'المكافأة غير موجودة'); end if;
  if v.employees is null then
    if not app.scope_is_all() then perform app.fail('out_of_scope', 'المكافأة تشمل موظفين خارج نطاقك'); end if;
  else
    foreach e in array v.employees loop perform app.require_employee_scope(e); end loop;
  end if;
  perform app.guard_dates(array[v.month], p_code);
  update public.reward_plans set status = 'deleted', updated_at = now() where id = p_id;
  perform app.audit('reward_plans', p_id::text, 'delete', to_jsonb(v), null, p_reason);
end $$;

-- الخطط ومن يستوفيها وسبب الاستحقاق (P12)
create or replace function public.rewards_list(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); e bigint; v_c jsonb; v_q jsonb := '{}'; x jsonb;
begin
  perform app.require_perm('P12', 'view');
  for e in select id from public.employees where app.can_see_employee(id) loop
    continue when not exists (select 1 from public.reward_plans rp where rp.month = v_m and rp.status = 'active'
                                and (rp.employees is null or e = any(rp.employees)));
    continue when not exists (select 1 from public.employment_periods ep where ep.employee_id = e
                                and daterange(ep.start_date, ep.end_date, '[]') && daterange(v_m, app.month_end(v_m), '[]'));
    v_c := case when app.is_closed(v_m) then (select s.statement from public.month_snapshots s where s.month = v_m and s.employee_id = e order by version desc limit 1)
                else app.commission_calc(e, v_m) end;
    for x in select * from jsonb_array_elements(coalesce(v_c->'rewards', '[]')) loop
      v_q := jsonb_set(v_q, array[x->>'id'], coalesce(v_q->(x->>'id'), '[]') || jsonb_build_object('employee_id', e,
               'name', (select name from public.employees where id = e), 'amount', x->'amount', 'reason', x->'reason', 'counted', x->'counted'));
    end loop;
  end loop;
  return jsonb_build_object('month', v_m, 'closed', app.is_closed(v_m),
    'plans', coalesce((select jsonb_agg(to_jsonb(rp) || jsonb_build_object('qualified', coalesce(v_q->(rp.id::text), '[]'),
                         'employee_names', (select jsonb_agg(name) from public.employees where id = any(rp.employees))) order by rp.name)
                         from public.reward_plans rp where rp.month = v_m and rp.status = 'active'), '[]'));
end $$;

-- ---------------------------------------------------------------------
-- P13 — بطاقات الأداء (CARD-001..018)
-- ---------------------------------------------------------------------

-- ملخص البطاقة: صافي المبيعات والمباشر والعروض والمرتجعات ومؤشر النقدية وعدد الفواتير والتنوع
create or replace function app.card_summary(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with l as (
    select d.id doc_id, d.kind, d.customer_id, l.product_id, coalesce(l.net_sales, 0) ns, coalesce(l.net_promotions, 0) np,
           coalesce(l.quantity, 0) q, ltrim(rtrim(c.name)) like 'مبيعات نقدية%' cash_customer
      from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s
      join public.docs d on d.id = s.doc_id join public.doc_lines l on l.doc_id = d.id
      join public.customers c on c.id = d.customer_id
     where d.kind in ('invoice', 'return') and p_to >= p_from
  ), inv as (select doc_id, sum(ns + np) v from l where kind = 'invoice' group by doc_id)
  select jsonb_build_object(
    'gross', coalesce(sum(ns + np) filter (where kind = 'invoice'), 0),
    'direct', coalesce(sum(ns) filter (where kind = 'invoice'), 0),
    'promo', coalesce(sum(np) filter (where kind = 'invoice'), 0),
    'returns', coalesce(sum(ns + np) filter (where kind = 'return'), 0),
    'net', coalesce(sum(case kind when 'invoice' then ns + np else -(ns + np) end), 0),
    'cash', coalesce(sum(ns + np) filter (where kind = 'invoice' and cash_customer), 0),
    'cash_ratio', case when coalesce(sum(ns + np) filter (where kind = 'invoice'), 0) > 0
                       then sum(ns + np) filter (where kind = 'invoice' and cash_customer) / sum(ns + np) filter (where kind = 'invoice') * 100 end,
    'invoices', (select count(*) from inv where v > 0),
    'customers', count(distinct customer_id) filter (where kind = 'invoice' and ns + np > 0),
    'variety', count(distinct product_id) filter (where kind = 'invoice' and ns + np > 0),
    'quantity', coalesce(sum(case kind when 'invoice' then q else -q end), 0))
  from l
$$;

create or replace function app.card_data(p_emp bigint, p_month date, p_cutoff date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
  v_cut date := least(p_cutoff, app.month_end(p_month));
  v_plan public.goal_plans; v_eval jsonb; v_role text := app.emp_role(p_emp, v_m);
  v_days jsonb; v_rewards jsonb := '[]'; r record; v_val numeric;
begin
  select * into v_plan from public.goal_plans where month = v_m and employee_id = p_emp;
  if found then v_eval := app.plan_eval(v_plan.id, v_cut); end if;
  v_days := coalesce(v_eval->'days', app.emp_days(p_emp, v_m, v_cut));
  for r in select * from public.reward_plans rp where rp.month = v_m and rp.status = 'active'
             and (rp.role = 'all' or rp.role = v_role) and (rp.employees is null or p_emp = any(rp.employees)) order by rp.name loop
    v_val := case when r.cond_type = 'metric'
                  then app.metric_value(p_emp, v_role, coalesce(v_plan.include_personal, false), v_m, v_cut, r.metric, r.filters) end;
    v_rewards := v_rewards || jsonb_build_object('name', r.name, 'cond_type', r.cond_type, 'tiers', r.tiers, 'metric', r.metric,
      'metric_label', app.metric_label(r.metric), 'min', r.metric_min, 'actual', v_val,
      'met', case when r.cond_type = 'tier' then coalesce(v_eval->>'achieved', 'NONE') = any(coalesce(r.tiers, '{}')) else v_val >= r.metric_min end,
      'value_type', r.value_type, 'amount', r.amount, 'pct', r.pct, 'pct_base', r.pct_base);
  end loop;
  return jsonb_build_object(
    'employee', (select jsonb_build_object('id', e.id, 'name', e.name, 'emp_number', e.emp_number, 'status', e.status, 'job_role', e.job_role,
                   'supervisor', (select se.name from public.supervisor_assignments s join public.employees se on se.id = s.supervisor_id
                                   where s.employee_id = e.id and daterange(s.valid_from, s.valid_to, '[]') @> v_cut limit 1))
                   from public.employees e where e.id = p_emp),
    'role', v_role, 'month', v_m, 'cutoff', v_cut, 'eval', v_eval, 'days', v_days,
    'summary', app.card_summary(p_emp, v_role, coalesce(v_plan.include_personal, false), v_m, v_cut),
    'rewards', v_rewards);
end $$;

-- p_opts: {mode: today|yesterday, role: rep|supervisor|all, supervisor_id, status: active|all, search}
create or replace function public.performance_cards(p_month date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}');
  v_m date := app.month_of(p_month);
  v_cut date := case when o->>'mode' = 'yesterday' then app.today() - 1 else app.today() end;
  v_closed boolean := app.is_closed(v_m);
  r record; v_out jsonb := '[]'; v_card jsonb;
begin
  perform app.require_perm('P13', 'view');
  for r in
    select e.* from public.employees e
     where app.can_see_employee(e.id)
       and (coalesce(o->>'status', 'active') = 'all' or e.status = 'نشط')
       and exists (select 1 from public.employment_periods ep where ep.employee_id = e.id
                      and daterange(ep.start_date, ep.end_date, '[]') && daterange(v_m, app.month_end(v_m), '[]'))
       and (coalesce(o->>'role', 'all') = 'all' or app.emp_role(e.id, v_m) = o->>'role')
       and (nullif(o->>'supervisor_id', '') is null or e.id = (o->>'supervisor_id')::bigint
            or exists (select 1 from public.supervisor_assignments s where s.employee_id = e.id and s.supervisor_id = (o->>'supervisor_id')::bigint
                         and daterange(s.valid_from, s.valid_to, '[]') && daterange(v_m, app.month_end(v_m), '[]')))
       and (coalesce(o->>'search', '') = '' or e.name ilike '%' || (o->>'search') || '%' or e.emp_number = trim(o->>'search'))
     order by e.name
  loop
    if v_closed then
      -- الشهر المغلق يقرأ من النسخة المحفوظة (PERIOD-001)
      select s.card into v_card from public.month_snapshots s where s.month = v_m and s.employee_id = r.id order by s.version desc limit 1;
      if v_card is null then continue; end if;
      v_card := v_card || '{"snapshot": true}';
    else
      v_card := app.card_data(r.id, v_m, v_cut);
    end if;
    v_out := v_out || v_card;
  end loop;
  return jsonb_build_object('month', v_m, 'cutoff', least(v_cut, app.month_end(v_m)), 'closed', v_closed,
    'show_path_phrase', coalesce((select value = 'true'::jsonb from public.settings where key = 'show_path_phrase'), false),
    'cards', v_out);
end $$;

-- ---------------------------------------------------------------------
-- P14 — كشف العمولة وحسابات العمولات (COMM-001..003)
-- ---------------------------------------------------------------------

create or replace function public.commission_statement(p_employee bigint, p_month date, p_version int default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); v_s public.month_snapshots; v jsonb;
begin
  perform app.require_perm('P14', 'view');
  perform app.require_employee_scope(p_employee);
  if p_version is not null or app.is_closed(v_m) then
    select * into v_s from public.month_snapshots where month = v_m and employee_id = p_employee
       and (p_version is null or version = p_version) order by version desc limit 1;
    if found then
      return v_s.statement || jsonb_build_object('snapshot', true, 'version', v_s.version, 'snapshot_at', v_s.created_at,
        'employee', (select jsonb_build_object('id', id, 'name', name, 'emp_number', emp_number) from public.employees where id = p_employee),
        'closed', app.is_closed(v_m),
        'versions', (select jsonb_agg(version order by version) from public.month_snapshots where month = v_m and employee_id = p_employee));
    end if;
    if p_version is not null then perform app.fail('not_found', 'لا توجد نسخة محفوظة بهذا الرقم'); end if;
  end if;
  v := app.commission_calc(p_employee, v_m);
  return v || jsonb_build_object('snapshot', false, 'closed', app.is_closed(v_m),
    'employee', (select jsonb_build_object('id', id, 'name', name, 'emp_number', emp_number) from public.employees where id = p_employee),
    'versions', (select jsonb_agg(version order by version) from public.month_snapshots where month = v_m and employee_id = p_employee));
end $$;

-- الموظفون المعنيون بالشهر: خطة أو قاعدة أو حركة أو قرار صرف أو تحصيل مسدد، ومشرفوهم
create or replace function app.month_employees(p_month date) returns setof bigint
language sql stable security definer set search_path = public, app as $$
  with base as (
    select employee_id e from public.goal_plans where month = app.month_of(p_month)
    union select employee_id from public.rule_members where month = app.month_of(p_month)
    union select employee_id from public.commission_adjustments where month = app.month_of(p_month) and status = 'active'
    union select employee_id from public.docs where status = 'active' and doc_date between app.month_of(p_month) and app.month_end(p_month)
    union select d.employee_id from app.ledger_allocs a join public.docs d on a.debt_key = 'doc:' || d.id
           where a.alloc_date between app.month_of(p_month) and app.month_end(p_month)
  )
  select e from base
  union
  select s.supervisor_id from public.supervisor_assignments s join base on base.e = s.employee_id
   where daterange(s.valid_from, s.valid_to, '[]') && daterange(app.month_of(p_month), app.month_end(p_month), '[]')
$$;

create or replace function public.commission_summary(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); v_closed boolean := app.is_closed(v_m);
  e bigint; v jsonb; v_rows jsonb := '[]'; v_cols jsonb := '[]';
begin
  perform app.require_perm('P14', 'view');
  perform app.refresh_ledger();
  for e in select x from app.month_employees(v_m) x join public.employees em on em.id = x where app.can_see_employee(x) order by em.name loop
    if v_closed then
      select s.statement into v from public.month_snapshots s where s.month = v_m and s.employee_id = e order by s.version desc limit 1;
      continue when v is null;
    else
      v := app.commission_calc(e, v_m);
    end if;
    v_rows := v_rows || jsonb_build_object('employee_id', e, 'name', (select name from public.employees where id = e),
      'emp_number', (select emp_number from public.employees where id = e), 'role', v->'role', 'rule_name', v->'rule_name',
      'tier', v->'tier_effective', 'tier_calc', v->'tier_calc', 'eligible', v->'eligible', 'team_eligible', v->'team_eligible',
      'personal_eligible', v->'personal_eligible', 'base', v->'base_commission', 'rewards', v->'rewards_total',
      'adjustments', v->'adjustments_total', 'final', v->'final', 'status', v->'status', 'collection_mode', v->'collection_mode',
      'warnings', v->'warnings',
      'goals', (select coalesce(jsonb_object_agg(coalesce(x->>'tier', '-') || ':' || (x->>'metric'),
                  jsonb_build_object('final', x->'final', 'actual', x->'actual', 'pct', x->'pct', 'kind', x->'kind')), '{}')
                  from jsonb_array_elements(coalesce(v->'goals'->'components', '[]')) x where x->>'status' <> 'unused'));
  end loop;
  -- أعمدة الأهداف الديناميكية بحسب خطط الفترة (COMM-003)
  select coalesce(jsonb_agg(jsonb_build_object('key', k, 'tier', split_part(k, ':', 1), 'metric', split_part(k, ':', 2),
                                               'label', app.metric_label(split_part(k, ':', 2))) order by k), '[]')
    into v_cols from (select distinct jsonb_object_keys(r->'goals') k from jsonb_array_elements(v_rows) r) q;
  return jsonb_build_object('month', v_m, 'closed', v_closed,
    'version', (select version from public.months where month = v_m), 'rows', v_rows, 'goal_columns', v_cols);
end $$;

-- قرارات الصرف (B021، B024–B027): شريحة يدوية، إضافة/خصم بمبلغ أو بنسبة بأساس صريح، تصفير الأساسية، تصفير كامل المستحق
-- p: {kind, tier, amount, pct, base, reason}
create or replace function public.save_commission_adjustment(p_employee bigint, p_month date, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p->>'kind'; v_id bigint; v_m date := app.month_of(p_month);
begin
  perform app.require_perm('P14', 'edit');
  perform app.require_employee_scope(p_employee);
  perform app.require_not_self(p_employee);
  perform app.guard_dates(array[v_m], p_code);
  if coalesce(trim(p->>'reason'), '') = '' then perform app.fail('reason_required', 'السبب مطلوب لكل قرار صرف'); end if;
  if v_kind = 'manual_tier' and coalesce(trim(p->>'tier'), '') = '' then perform app.fail('required', 'اختر الشريحة اليدوية'); end if;
  if v_kind in ('add', 'deduct') then
    if (nullif(p->>'amount', '') is null) = (nullif(p->>'pct', '') is null) then perform app.fail('required', 'أدخل مبلغًا أو نسبة'); end if;
    if nullif(p->>'pct', '') is not null and coalesce(p->>'base', '') not in ('eligible', 'base_commission') then
      perform app.fail('base_required', 'الإضافة بالنسبة تحتاج أساسًا صريحًا: المبيعات المؤهلة أو العمولة الأساسية (B025)');
    end if;
    if coalesce(nullif(p->>'amount', '')::numeric, nullif(p->>'pct', '')::numeric) < 0 then perform app.fail('bad_value', 'القيمة موجبة؛ اختر خصمًا للتخفيض'); end if;
  elsif v_kind not in ('manual_tier', 'zero_base', 'zero_all') then
    perform app.fail('bad_kind', 'نوع القرار غير معروف');
  end if;
  insert into public.commission_adjustments (month, employee_id, kind, tier, amount, pct, base, reason, created_by, created_name)
  values (v_m, p_employee, v_kind, upper(nullif(trim(p->>'tier'), '')),
          case when v_kind in ('add', 'deduct') then nullif(p->>'amount', '')::numeric end,
          case when v_kind in ('add', 'deduct') then nullif(p->>'pct', '')::numeric end,
          case when v_kind in ('add', 'deduct') and nullif(p->>'pct', '') is not null then p->>'base' end,
          trim(p->>'reason'), auth.uid(), (select display_name from public.app_users where id = auth.uid()))
  returning id into v_id;
  perform app.audit('commission_adjustments', v_id::text, 'create', null,
                    (select to_jsonb(x) from public.commission_adjustments x where id = v_id), p->>'reason');
  return v_id;
end $$;

-- معاينة أثر القرار قبل اعتماده: المستحق قبل وبعد
create or replace function public.preview_commission_adjustment(p_employee bigint, p_month date, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_before jsonb; v_after jsonb;
begin
  perform app.require_perm('P14', 'view');
  perform app.require_employee_scope(p_employee);
  v_before := app.commission_calc(p_employee, p_month);
  begin
    perform public.save_commission_adjustment(p_employee, p_month, p || '{"reason": "معاينة"}'::jsonb, null);
    v_after := app.commission_calc(p_employee, p_month);
    raise exception using errcode = 'P0002', message = 'preview';
  exception when sqlstate 'P0002' then null;
  end;
  return jsonb_build_object('before', jsonb_build_object('tier', v_before->'tier_effective', 'base', v_before->'base_commission', 'final', v_before->'final'),
                            'after', jsonb_build_object('tier', v_after->'tier_effective', 'base', v_after->'base_commission', 'final', v_after->'final'));
end $$;

create or replace function public.cancel_commission_adjustment(p_id bigint, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v public.commission_adjustments;
begin
  perform app.require_perm('P14', 'edit');
  select * into v from public.commission_adjustments where id = p_id and status = 'active';
  if not found then perform app.fail('not_found', 'القرار غير موجود'); end if;
  perform app.require_employee_scope(v.employee_id);
  perform app.require_not_self(v.employee_id);
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الإلغاء مطلوب'); end if;
  perform app.guard_dates(array[v.month], p_code);
  update public.commission_adjustments set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_id;
  perform app.audit('commission_adjustments', p_id::text, 'cancel', to_jsonb(v), null, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- P14b — الأشهر والإغلاق (PERIOD-001/002، B075–B077، AUTH-004)
-- ---------------------------------------------------------------------

create or replace function public.months_overview() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_first date;
begin
  perform app.require_perm('P14b', 'view');
  v_first := least(coalesce((select min(month) from public.goal_plans), app.month_of(app.today())),
                   coalesce((select app.month_of(min(doc_date)) from public.docs where status = 'active'), app.month_of(app.today())),
                   coalesce((select min(month) from public.months), app.month_of(app.today())));
  return coalesce((select jsonb_agg(jsonb_build_object('month', g::date, 'status', coalesce(m.status, 'open'), 'version', coalesce(m.version, 0),
            'closed_at', m.closed_at, 'reopened_at', m.reopened_at, 'reopen_reason', m.reopen_reason,
            'plans', (select count(*) from public.goal_plans p where p.month = g::date),
            'rules', (select count(*) from public.commission_rules r where r.month = g::date),
            'versions', (select coalesce(jsonb_agg(jsonb_build_object('version', v.version, 'closed_at', v.closed_at, 'closed_name', v.closed_name,
                                                                      'note', v.note, 'reopened_at', v.reopened_at, 'reopen_reason', v.reopen_reason,
                                                                      'totals', v.totals) order by v.version), '[]')
                           from public.month_versions v where v.month = g::date)) order by g desc)
    from generate_series(v_first, app.month_of(app.today()), interval '1 month') g
    left join public.months m on m.month = g::date), '[]');
end $$;

-- فحص الجاهزية: الكشوف وأخطاؤها المؤثرة (B075، COMM-006/007)
create or replace function public.month_readiness(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); e bigint; v jsonb; v_rows jsonb := '[]';
  v_tot jsonb := jsonb_build_object('eligible', 0, 'base', 0, 'rewards', 0, 'adjustments', 0, 'final', 0);
begin
  perform app.require_perm('P14b', 'view');
  perform app.refresh_ledger();
  for e in select x from app.month_employees(v_m) x join public.employees em on em.id = x order by em.name loop
    v := app.commission_calc(e, v_m);
    v_rows := v_rows || jsonb_build_object('employee_id', e, 'name', (select name from public.employees where id = e), 'role', v->'role',
      'tier', v->'tier_effective', 'final', v->'final', 'blocking', v->'blocking',
      'warnings', v->'warnings');
    v_tot := jsonb_build_object('eligible', (v_tot->>'eligible')::numeric + coalesce((v->>'eligible')::numeric, 0),
                                'base', (v_tot->>'base')::numeric + coalesce((v->>'base_commission')::numeric, 0),
                                'rewards', (v_tot->>'rewards')::numeric + coalesce((v->>'rewards_total')::numeric, 0),
                                'adjustments', (v_tot->>'adjustments')::numeric + coalesce((v->>'adjustments_total')::numeric, 0),
                                'final', (v_tot->>'final')::numeric + coalesce((v->>'final')::numeric, 0));
  end loop;
  return jsonb_build_object('month', v_m, 'closed', app.is_closed(v_m), 'rows', v_rows, 'totals', v_tot,
    'blocking', exists (select 1 from jsonb_array_elements(v_rows) x where (x->>'blocking')::boolean));
end $$;

-- الإغلاق: فحص الأخطاء المؤثرة ← اعتماد الإدارة ← نسخة محفوظة بكل مدخلاتها
create or replace function public.close_month(p_month date, p_note text default null) returns int
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); v_r jsonb; v_ver int; e bigint; v_bad text;
begin
  perform app.require_admin();
  if app.is_closed(v_m) then perform app.fail('already_closed', 'الشهر مغلق'); end if;
  if v_m > app.month_of(app.today()) then perform app.fail('future_month', 'لا يغلق شهر لم يبدأ'); end if;
  v_r := public.month_readiness(v_m);
  if (v_r->>'blocking')::boolean then
    select string_agg((x->>'name') || ': ' || (select string_agg(w->>'message', '، ') from jsonb_array_elements(x->'warnings') w where (w->>'blocking')::boolean), ' | ')
      into v_bad from jsonb_array_elements(v_r->'rows') x where (x->>'blocking')::boolean;
    perform app.fail('not_ready', 'لا يغلق الشهر قبل معالجة الأخطاء المؤثرة: ' || v_bad);
  end if;
  v_ver := coalesce((select version from public.months where month = v_m), 0) + 1;
  for e in select (x->>'employee_id')::bigint from jsonb_array_elements(v_r->'rows') x loop
    insert into public.month_snapshots (month, version, employee_id, statement, card)
    values (v_m, v_ver, e, app.commission_calc(e, v_m), app.card_data(e, v_m, app.month_end(v_m)));
  end loop;
  insert into public.month_versions (month, version, closed_by, closed_name, note, settings, totals)
  values (v_m, v_ver, auth.uid(), (select display_name from public.app_users where id = auth.uid()), p_note,
          jsonb_build_object(
            'rules', (select jsonb_agg(app.rule_json(id)) from public.commission_rules where month = v_m),
            'plans', (select jsonb_agg(app.plan_json(id)) from public.goal_plans where month = v_m),
            'rewards', (select jsonb_agg(to_jsonb(r)) from public.reward_plans r where month = v_m and status = 'active'),
            'collection_reps', (select jsonb_agg(to_jsonb(c)) from public.collection_reps c
                                 where v_m >= c.from_month and (c.to_month is null or v_m <= c.to_month)),
            'personal_rates', (select jsonb_agg(to_jsonb(x)) from public.supervisor_personal_rates x where month = v_m),
            'debt_age_days', app.debt_age_at(app.month_end(v_m)), 'work_weekdays', to_jsonb(app.work_weekdays())),
          v_r->'totals');
  insert into public.months (month, status, version, closed_at, closed_by) values (v_m, 'closed', v_ver, now(), auth.uid())
  on conflict (month) do update set status = 'closed', version = v_ver, closed_at = now(), closed_by = auth.uid();
  perform app.audit('months', v_m::text, 'close', null, jsonb_build_object('version', v_ver, 'totals', v_r->'totals'), p_note);
  return v_ver;
end $$;

-- إعادة الفتح للإدارة برمزها السري وبسبب (AUTH-004، B076)؛ النسخ السابقة تبقى للمراجعة
create or replace function public.reopen_month(p_month date, p_reason text, p_code text default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
begin
  perform app.require_admin();
  if not app.is_closed(v_m) then perform app.fail('not_closed', 'الشهر مفتوح'); end if;
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب إعادة الفتح مطلوب'); end if;
  if not app.check_admin_code(p_code) then
    perform app.fail('closed_period_code', 'إعادة فتح شهر مقفل تحتاج الرمز السري للإدارة');
  end if;
  update public.months set status = 'open', reopened_at = now(), reopen_reason = p_reason where month = v_m;
  update public.month_versions set reopened_at = now(), reopen_reason = p_reason
   where month = v_m and version = (select version from public.months where month = v_m);
  perform app.audit('months', v_m::text, 'reopen', null, null, p_reason);
end $$;

-- الفروق بين الحساب الحالي من المصادر والنسخة المحفوظة (B076، B077)
create or replace function public.month_diff(p_month date, p_version int default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
  v_ver int := coalesce(p_version, (select max(version) from public.month_snapshots where month = v_m));
  r record; v jsonb; v_out jsonb := '[]';
begin
  perform app.require_perm('P14b', 'view');
  if v_ver is null then return jsonb_build_object('month', v_m, 'version', null, 'rows', '[]'); end if;
  for r in select s.*, e.name from public.month_snapshots s join public.employees e on e.id = s.employee_id
            where s.month = v_m and s.version = v_ver and app.can_see_employee(s.employee_id) order by e.name loop
    v := app.commission_calc(r.employee_id, v_m);
    if (v->>'final') is distinct from (r.statement->>'final') or (v->>'eligible')::numeric is distinct from (r.statement->>'eligible')::numeric
       or (v->>'tier_effective') is distinct from (r.statement->>'tier_effective') then
      v_out := v_out || jsonb_build_object('employee_id', r.employee_id, 'name', r.name,
        'saved', jsonb_build_object('tier', r.statement->'tier_effective', 'eligible', r.statement->'eligible', 'base', r.statement->'base_commission', 'final', r.statement->'final'),
        'live', jsonb_build_object('tier', v->'tier_effective', 'eligible', v->'eligible', 'base', v->'base_commission', 'final', v->'final'));
    end if;
  end loop;
  return jsonb_build_object('month', v_m, 'version', v_ver, 'closed', app.is_closed(v_m), 'rows', v_out);
end $$;

-- ---------------------------------------------------------------------
-- الصفحات والصلاحيات
-- ---------------------------------------------------------------------
update public.pages set actions = '{view,approve}' where code = 'P14b';

alter table public.holidays                  enable row level security;
alter table public.employee_exceptions       enable row level security;
alter table public.goal_plans                enable row level security;
alter table public.goal_tiers                enable row level security;
alter table public.goal_components           enable row level security;
alter table public.goal_templates            enable row level security;
alter table public.commission_rules          enable row level security;
alter table public.rule_tiers                enable row level security;
alter table public.rule_members              enable row level security;
alter table public.collection_reps           enable row level security;
alter table public.commission_settings       enable row level security;
alter table public.opening_collection_reps   enable row level security;
alter table public.supervisor_personal_rates enable row level security;
alter table public.rate_reviews              enable row level security;
alter table public.reward_plans              enable row level security;
alter table public.commission_adjustments    enable row level security;
alter table public.month_snapshots           enable row level security;
alter table public.month_versions            enable row level security;

create policy holidays_read on public.holidays for select to authenticated using (true);
create policy exceptions_read on public.employee_exceptions for select to authenticated
  using ((app.has_perm('P19') or app.has_perm('P03')) and app.can_see_employee(employee_id));
create policy plans_read on public.goal_plans for select to authenticated
  using (app.has_perm(app.plan_role_page(role)) and app.can_see_employee(employee_id));
create policy gtiers_read on public.goal_tiers for select to authenticated
  using (exists (select 1 from public.goal_plans p where p.id = plan_id));
create policy gcomps_read on public.goal_components for select to authenticated
  using (exists (select 1 from public.goal_plans p where p.id = plan_id));
create policy templates_goal_read on public.goal_templates for select to authenticated using (app.has_perm('P10') or app.has_perm('P10a'));
create policy rules_read on public.commission_rules for select to authenticated using (app.has_perm('P11'));
create policy rtiers_read on public.rule_tiers for select to authenticated using (app.has_perm('P11'));
create policy rmembers_read on public.rule_members for select to authenticated using (app.has_perm('P11') and app.can_see_employee(employee_id));
create policy creps_read on public.collection_reps for select to authenticated using (app.has_perm('P11') and app.can_see_employee(employee_id));
create policy csettings_read on public.commission_settings for select to authenticated using (app.has_perm('P11'));
create policy oreps_read on public.opening_collection_reps for select to authenticated using (app.has_perm('P11') and app.can_see_customer(customer_id));
create policy prates_read on public.supervisor_personal_rates for select to authenticated using (app.has_perm('P11') and app.can_see_employee(employee_id));
create policy reviews_read on public.rate_reviews for select to authenticated using (app.has_perm('P11'));
create policy rewards_read on public.reward_plans for select to authenticated using (app.has_perm('P12'));
create policy adjustments_read on public.commission_adjustments for select to authenticated
  using (app.has_perm('P14') and app.can_see_employee(employee_id));
create policy snapshots_read on public.month_snapshots for select to authenticated
  using ((app.has_perm('P14') or app.has_perm('P13')) and app.can_see_employee(employee_id));
create policy mversions_read on public.month_versions for select to authenticated using (app.has_perm('P14b'));

select app.apply_grants();

-- >>> 0007_maps.sql
-- =====================================================================
-- 0007 — الخرائط: مواقع العملاء، المناطق والأسواق، خريطة الفواتير، مقارنة الفترات، انتشار الأصناف
-- MAP-001..015، B063–B071، CAL-001، DAY-001، UX-005
-- العرض الجغرافي لا ينشئ حركة مالية ولا يغيّر مستندًا أو Ledger (MAP-007).
-- =====================================================================

-- ---------------------------------------------------------------------
-- مواقع العملاء (MAP-004، B065): الأصل المستورد يحفظ للتدقيق، والمعتمد (lat/lng) للعرض
-- ---------------------------------------------------------------------
alter table public.customers add column if not exists orig_lat numeric;
alter table public.customers add column if not exists orig_lng numeric;

-- حالة الموقع: صالح، مفقود، غير صالح (صفر أو خارج النطاق)
create or replace function app.loc_state(p_lat numeric, p_lng numeric) returns text
language sql immutable as $$
  select case when p_lat is null or p_lng is null then 'missing'
              when p_lat not between -90 and 90 or p_lng not between -180 and 180 or (p_lat = 0 and p_lng = 0) then 'invalid'
              else 'ok' end
$$;

-- الصفوف: [{row, customer_number, name, lat, lng}]؛ المطابقة برقم العميل، الفراغ لا يمحو، المجهول يحتاج تعريفًا أولًا
create or replace function public.import_customer_locations(p_rows jsonb, p_commit boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; c public.customers; v_lat numeric; v_lng numeric; v_kind text;
  v_out jsonb := '[]'; v_counts jsonb := '{"new":0,"changed":0,"same":0,"blank":0,"error":0}'; v_msg text;
begin
  perform app.require_perm('P16', 'import');
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_msg := null; v_lat := null; v_lng := null;
    select * into c from public.customers where customer_number = trim(r->>'customer_number');
    if not found then
      v_kind := 'error'; v_msg := 'عميل غير معروف؛ عرّفه في صفحة العملاء أولًا';
    elsif not app.can_see_customer(c.id) then
      v_kind := 'error'; v_msg := 'العميل خارج نطاق بياناتك';
    elsif coalesce(trim(r->>'lat'), '') = '' and coalesce(trim(r->>'lng'), '') = '' then
      v_kind := 'blank';
    elsif app.is_bad_num(r->>'lat') or app.is_bad_num(r->>'lng') or coalesce(trim(r->>'lat'), '') = '' or coalesce(trim(r->>'lng'), '') = '' then
      v_kind := 'error'; v_msg := 'إحداثيات غير مقروءة؛ خط العرض وخط الطول معًا';
    else
      v_lat := trim(r->>'lat')::numeric; v_lng := trim(r->>'lng')::numeric;
      if app.loc_state(v_lat, v_lng) <> 'ok' then
        v_kind := 'error'; v_msg := 'إحداثيات خارج النطاق أو صفرية';
      elsif c.lat is null then v_kind := 'new';
      elsif c.lat = v_lat and c.lng = v_lng then v_kind := 'same';
      else v_kind := 'changed';
      end if;
    end if;
    v_counts := jsonb_set(v_counts, array[v_kind], to_jsonb((v_counts->>v_kind)::int + 1));
    v_out := v_out || jsonb_build_object('row', r->'row', 'customer_number', r->>'customer_number', 'name_src', r->>'name',
      'customer_id', c.id, 'name', c.name, 'kind', v_kind, 'message', v_msg, 'old_lat', c.lat, 'old_lng', c.lng, 'lat', v_lat, 'lng', v_lng);
    if p_commit and v_kind in ('new', 'changed') then
      update public.customers set lat = v_lat, lng = v_lng, orig_lat = v_lat, orig_lng = v_lng,
             location_updated_at = now(), updated_at = now() where id = c.id;
      perform app.audit('customers', c.id::text, 'import_location', jsonb_build_object('lat', c.lat, 'lng', c.lng),
                        jsonb_build_object('lat', v_lat, 'lng', v_lng));
    end if;
  end loop;
  return jsonb_build_object('counts', v_counts, 'rows', v_out, 'committed', p_commit);
end $$;

-- ---------------------------------------------------------------------
-- المناطق والأسواق (MAP-005، B067، B068): نسخ حدود وإسناد بتاريخ سريان
-- geom: مصفوفة مضلعات، كل مضلع مصفوفة نقاط [lat, lng]
-- ---------------------------------------------------------------------
create table public.regions (
  id          bigserial primary key,
  name        text not null,
  color       text not null default '#1f5fa8',
  note        text,
  status      text not null default 'active' check (status in ('active', 'deleted')),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now()
);

create table public.region_versions (
  id             bigserial primary key,
  region_id      bigint not null references public.regions(id) on delete cascade,
  valid_from     date not null,
  geom           jsonb not null,
  min_lat numeric, max_lat numeric, min_lng numeric, max_lng numeric,
  employee_id    bigint references public.employees(id),     -- مندوب المنطقة
  supervisor_id  bigint references public.employees(id),     -- أو مجموعة مشرف
  created_at     timestamptz not null default now(),
  created_by     uuid,
  unique (region_id, valid_from)
);

-- إسناد صريح لعميل في تداخل أو حد مشترك (B067)؛ region_id فارغ = بلا منطقة
create table public.region_assignments (
  id           bigserial primary key,
  customer_id  bigint not null references public.customers(id),
  region_id    bigint references public.regions(id),
  valid_from   date not null,
  reason       text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  unique (customer_id, valid_from)
);

-- نقطة داخل مضلع (Ray casting)؛ الحد يعد داخلًا فيظهر الحد المشترك تداخلًا يحتاج تحديدًا
create or replace function app.in_ring(p_lat numeric, p_lng numeric, p_ring jsonb) returns boolean
language plpgsql immutable as $$
declare
  n int := jsonb_array_length(p_ring); i int; j int; yi numeric; xi numeric; yj numeric; xj numeric; v_in boolean := false;
begin
  if n < 3 then return false; end if;
  j := n - 1;
  for i in 0 .. n - 1 loop
    yi := (p_ring->i->>0)::numeric; xi := (p_ring->i->>1)::numeric;
    yj := (p_ring->j->>0)::numeric; xj := (p_ring->j->>1)::numeric;
    -- على الضلع
    if (p_lat - yi) * (xj - xi) = (p_lng - xi) * (yj - yi)
       and p_lat between least(yi, yj) and greatest(yi, yj) and p_lng between least(xi, xj) and greatest(xi, xj) then
      return true;
    end if;
    if ((yi > p_lat) <> (yj > p_lat)) and (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) then
      v_in := not v_in;
    end if;
    j := i;
  end loop;
  return v_in;
end $$;

create or replace function app.in_geom(p_lat numeric, p_lng numeric, p_geom jsonb) returns boolean
language sql immutable as $$
  select coalesce(bool_or(app.in_ring(p_lat, p_lng, g)), false) from jsonb_array_elements(p_geom) g
$$;

-- النسخة السارية لكل منطقة نشطة في تاريخ
create or replace function app.region_versions_at(p_date date)
returns setof public.region_versions language sql stable security definer set search_path = public as $$
  select distinct on (v.region_id) v.* from public.region_versions v join public.regions r on r.id = v.region_id
   where r.status = 'active' and v.valid_from <= p_date
   order by v.region_id, v.valid_from desc, v.id desc
$$;

-- منطقة العميل في تاريخ: الإسناد الصريح أولًا، ثم الاحتواء؛ أكثر من منطقة = يحتاج تحديد منطقة
create or replace function app.customer_regions(p_date date)
returns table (customer_id bigint, region_id bigint, state text, candidates bigint[])
language sql stable security definer set search_path = public, app as $$
  with v as (select * from app.region_versions_at(p_date)),
  m as (
    select c.id cid, app.loc_state(c.lat, c.lng) ls,
           coalesce(array_agg(v.region_id order by v.region_id)
                      filter (where v.region_id is not null and app.in_geom(c.lat, c.lng, v.geom)), '{}') regs
      from public.customers c
      left join v on app.loc_state(c.lat, c.lng) = 'ok'
                 and c.lat between v.min_lat and v.max_lat and c.lng between v.min_lng and v.max_lng
     group by c.id, c.lat, c.lng
  ),
  a as (
    select distinct on (x.customer_id) x.customer_id, x.region_id from public.region_assignments x
     where x.valid_from <= p_date order by x.customer_id, x.valid_from desc, x.id desc
  )
  select m.cid,
         case when a.customer_id is not null then a.region_id when cardinality(m.regs) = 1 then m.regs[1] end,
         case when a.customer_id is not null then case when a.region_id is null then 'none' else 'assigned' end
              when m.ls <> 'ok' then 'no_location'
              when cardinality(m.regs) = 0 then 'none'
              when cardinality(m.regs) = 1 then 'in'
              else 'conflict' end,
         m.regs
    from m left join a on a.customer_id = m.cid
$$;

-- منطقة عميل واحد في تاريخ (للاستخدام لكل سند دون حساب كل العملاء)
create or replace function app.customer_region_at(p_customer bigint, p_date date) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  a public.region_assignments; c public.customers; v_ids bigint[];
begin
  select * into a from public.region_assignments x where x.customer_id = p_customer and x.valid_from <= p_date
   order by x.valid_from desc, x.id desc limit 1;
  if found then return a.region_id; end if;
  select * into c from public.customers where id = p_customer;
  if app.loc_state(c.lat, c.lng) <> 'ok' then return null; end if;
  select array_agg(v.region_id) into v_ids from app.region_versions_at(p_date) v
   where c.lat between v.min_lat and v.max_lat and c.lng between v.min_lng and v.max_lng and app.in_geom(c.lat, c.lng, v.geom);
  return case when cardinality(v_ids) = 1 then v_ids[1] end;
end $$;

-- مناطق الموظف (مندوب المنطقة أو مجموعة مشرفه) في تاريخ
create or replace function app.emp_region_geoms(p_emp bigint, p_date date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(v.geom), '[]') from app.region_versions_at(p_date) v
   where v.employee_id = p_emp
      or (v.supervisor_id is not null and (v.supervisor_id = p_emp or exists (
            select 1 from public.supervisor_assignments s where s.employee_id = p_emp and s.supervisor_id = v.supervisor_id
               and daterange(s.valid_from, s.valid_to, '[]') @> p_date)))
$$;

-- موقع إصدار الفاتورة داخل مناطق مندوبها؟ null = لا منطقة مسندة أو لا موقع
create or replace function app.doc_in_region(p_emp bigint, p_date date, p_lat numeric, p_lng numeric) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when app.loc_state(p_lat, p_lng) <> 'ok' then null
              when jsonb_array_length(g) = 0 then null
              else exists (select 1 from jsonb_array_elements(g) x where app.in_geom(p_lat, p_lng, x)) end
    from (select app.emp_region_geoms(p_emp, p_date) g) q
$$;

-- الموظفون في النطاق: المسموح ∩ المختارون ∩ فريق المشرف المختار
create or replace function app.scope_emps(p_opts jsonb, p_from date, p_to date) returns bigint[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(e.id), '{}') from public.employees e
   where app.can_see_employee(e.id)
     and (coalesce(jsonb_array_length(case when jsonb_typeof(p_opts->'employees') = 'array' then p_opts->'employees' end), 0) = 0
          or e.id in (select x::bigint from jsonb_array_elements_text(p_opts->'employees') x))
     and (nullif(p_opts->>'supervisor_id', '') is null or e.id = (p_opts->>'supervisor_id')::bigint
          or exists (select 1 from public.supervisor_assignments s where s.employee_id = e.id and s.supervisor_id = (p_opts->>'supervisor_id')::bigint
                        and daterange(s.valid_from, s.valid_to, '[]') && daterange(p_from, p_to, '[]')))
$$;

create or replace function app.geom_bbox(p_geom jsonb) returns numeric[]
language sql immutable as $$
  select array[min((p->>0)::numeric), max((p->>0)::numeric), min((p->>1)::numeric), max((p->>1)::numeric)]
    from jsonb_array_elements(p_geom) g, jsonb_array_elements(g) p
$$;

create or replace function app.region_json(p_id bigint, p_date date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(r) || jsonb_build_object(
    'version', (select to_jsonb(v) || jsonb_build_object('employee', (select name from public.employees where id = v.employee_id),
                                                         'supervisor', (select name from public.employees where id = v.supervisor_id))
                  from app.region_versions_at(p_date) v where v.region_id = r.id),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'valid_from', v.valid_from, 'employee_id', v.employee_id,
                                                              'supervisor_id', v.supervisor_id, 'points', (select count(*) from jsonb_array_elements(v.geom) g, jsonb_array_elements(g) p))
                                           order by v.valid_from desc), '[]') from public.region_versions v where v.region_id = r.id))
    from public.regions r where r.id = p_id
$$;

-- p: {name, color, note, geom, employee_id, supervisor_id, valid_from}؛ تغير الحدود أو الإسناد ينشئ نسخة بتاريخ السريان
create or replace function public.save_region(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint; v_before jsonb; v_cur public.region_versions; v_from date := coalesce(nullif(p->>'valid_from', '')::date, app.today());
  v_geom jsonb := p->'geom'; v_bb numeric[]; g jsonb; pt jsonb;
  v_emp bigint := nullif(p->>'employee_id', '')::bigint; v_sup bigint := nullif(p->>'supervisor_id', '')::bigint;
begin
  perform app.require_perm('P17', case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'اسم المنطقة مطلوب'); end if;
  if jsonb_typeof(v_geom) <> 'array' or jsonb_array_length(v_geom) = 0 then perform app.fail('bad_geom', 'ارسم حدود المنطقة أو استوردها'); end if;
  for g in select * from jsonb_array_elements(v_geom) loop
    if jsonb_typeof(g) <> 'array' or jsonb_array_length(g) < 3 then perform app.fail('bad_geom', 'كل مضلع يحتاج ثلاث نقاط على الأقل'); end if;
    for pt in select * from jsonb_array_elements(g) loop
      if app.is_bad_num(pt->>0) or app.is_bad_num(pt->>1) or app.loc_state((pt->>0)::numeric, (pt->>1)::numeric) <> 'ok' then
        perform app.fail('bad_geom', 'نقطة حدود غير صالحة');
      end if;
    end loop;
  end loop;
  if v_emp is not null then perform app.require_employee_scope(v_emp); end if;
  if v_sup is not null then perform app.require_employee_scope(v_sup); end if;
  perform app.guard_dates(array[v_from], p_code);
  v_bb := app.geom_bbox(v_geom);
  if p_id is null then
    insert into public.regions (name, color, note, created_by) values (trim(p->>'name'), coalesce(nullif(p->>'color', ''), '#1f5fa8'), p->>'note', auth.uid())
    returning id into v_id;
  else
    select * into v_cur from app.region_versions_at('infinity'::date) where region_id = p_id;
    if not exists (select 1 from public.regions where id = p_id and status = 'active') then perform app.fail('not_found', 'المنطقة غير موجودة'); end if;
    v_before := app.region_json(p_id, app.today());
    update public.regions set name = trim(p->>'name'), color = coalesce(nullif(p->>'color', ''), color), note = p->>'note', updated_at = now() where id = p_id;
    v_id := p_id;
  end if;
  if v_cur.id is null or v_cur.geom <> v_geom or v_cur.employee_id is distinct from v_emp or v_cur.supervisor_id is distinct from v_sup then
    if v_cur.id is not null and v_from < v_cur.valid_from then
      perform app.fail('bad_date', 'تاريخ السريان قبل آخر نسخة؛ النسخ التاريخية تبقى كما هي');
    end if;
    insert into public.region_versions (region_id, valid_from, geom, min_lat, max_lat, min_lng, max_lng, employee_id, supervisor_id, created_by)
    values (v_id, v_from, v_geom, v_bb[1], v_bb[2], v_bb[3], v_bb[4], v_emp, v_sup, auth.uid())
    on conflict (region_id, valid_from) do update set geom = excluded.geom, min_lat = excluded.min_lat, max_lat = excluded.max_lat,
       min_lng = excluded.min_lng, max_lng = excluded.max_lng, employee_id = excluded.employee_id, supervisor_id = excluded.supervisor_id,
       created_at = now(), created_by = auth.uid();
  end if;
  perform app.audit('regions', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.region_json(v_id, v_from));
  return v_id;
end $$;

-- معاينة أثر الحدود قبل الحفظ: العملاء الداخلون والخارجون والتداخلات الجديدة
create or replace function public.preview_region(p_id bigint, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_date date := greatest(coalesce(nullif(p->>'valid_from', '')::date, app.today()), app.today());
  v_before jsonb; v_after jsonb; v_rid bigint;
begin
  perform app.require_perm('P17', 'view');
  select coalesce(jsonb_object_agg(customer_id::text, jsonb_build_object('r', region_id, 's', state)), '{}') into v_before
    from app.customer_regions(v_date) where app.can_see_customer(customer_id);
  begin
    v_rid := public.save_region(p_id, p || jsonb_build_object('valid_from', v_date), null);
    select coalesce(jsonb_object_agg(customer_id::text, jsonb_build_object('r', region_id, 's', state, 'c', candidates)), '{}') into v_after
      from app.customer_regions(v_date) where app.can_see_customer(customer_id);
    raise exception using errcode = 'P0002', message = 'preview';
  exception when sqlstate 'P0002' then null;
  end;
  return jsonb_build_object(
    'inside', (select count(*) from jsonb_each(v_after) a where (a.value->'c') @> to_jsonb(v_rid)),
    'added', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from jsonb_each(v_after) a join public.customers c on c.id = a.key::bigint
               where (a.value->'c') @> to_jsonb(v_rid) and coalesce((v_before->a.key->>'r')::bigint, -1) <> v_rid
                 and (p_id is null or not exists (select 1 from app.customer_regions(v_date) z where z.customer_id = c.id and p_id = any(z.candidates)))), '[]'),
    'removed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from app.customer_regions(v_date) z join public.customers c on c.id = z.customer_id
               where p_id is not null and p_id = any(z.candidates) and app.can_see_customer(c.id)
                 and not ((v_after->c.id::text->'c') @> to_jsonb(p_id))), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from jsonb_each(v_after) a join public.customers c on c.id = a.key::bigint
               where a.value->>'s' = 'conflict' and (a.value->'c') @> to_jsonb(v_rid)), '[]'));
end $$;

create or replace function public.delete_region(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_perm('P17', 'delete');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  if not exists (select 1 from public.regions where id = p_id and status = 'active') then perform app.fail('not_found', 'المنطقة غير موجودة'); end if;
  perform app.audit('regions', p_id::text, 'delete', app.region_json(p_id, app.today()), null, p_reason);
  update public.regions set status = 'deleted', updated_at = now() where id = p_id;
end $$;

-- إسناد صريح لعميل (حل التداخل أو استثناء من المنطقة)
create or replace function public.assign_customer_region(p_customer bigint, p_region bigint, p_from date, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := coalesce(p_from, app.today());
begin
  perform app.require_perm('P17', 'edit');
  perform app.require_customer_scope(p_customer);
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الإسناد مطلوب'); end if;
  insert into public.region_assignments (customer_id, region_id, valid_from, reason, created_by) values (p_customer, p_region, v_from, p_reason, auth.uid())
  on conflict (customer_id, valid_from) do update set region_id = excluded.region_id, reason = excluded.reason, created_at = now(), created_by = auth.uid();
  perform app.audit('region_assignments', p_customer::text, 'assign', null, jsonb_build_object('region_id', p_region, 'from', v_from), p_reason);
end $$;

-- قائمة المناطق في تاريخ (التاريخي) أو اليوم (الوضع الحالي)، وعدد عملائها، وما يحتاج تحديد منطقة
create or replace function public.regions_list(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_date date := coalesce(p_date, app.today());
begin
  perform app.require_perm('P17', 'view');
  create temp table if not exists _cr (customer_id bigint, region_id bigint, state text, candidates bigint[]) on commit drop;
  truncate _cr;
  insert into _cr select * from app.customer_regions(v_date) z where app.can_see_customer(z.customer_id);
  return jsonb_build_object('date', v_date,
    'regions', coalesce((select jsonb_agg(app.region_json(r.id, v_date) || jsonb_build_object(
                  'customers', (select count(*) from _cr where _cr.region_id = r.id)) order by r.name)
                  from public.regions r where r.status = 'active'), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name,
                    'candidates', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name)) from public.regions g where g.id = any(_cr.candidates)))
                    order by c.customer_number) from _cr join public.customers c on c.id = _cr.customer_id where _cr.state = 'conflict'), '[]'),
    'counts', (select jsonb_build_object('in', count(*) filter (where state in ('in', 'assigned')), 'none', count(*) filter (where state = 'none'),
                      'no_location', count(*) filter (where state = 'no_location'), 'conflict', count(*) filter (where state = 'conflict')) from _cr));
end $$;

-- ---------------------------------------------------------------------
-- P16 — مواقع العملاء
-- p_opts: {search, region_id, employee_id, state: all|ok|missing|invalid, date}
-- ---------------------------------------------------------------------
create or replace function public.customer_locations(p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_date date := coalesce(nullif(o->>'date', '')::date, app.today()); s text := trim(coalesce(o->>'search', ''));
begin
  perform app.require_perm('P16', 'view');
  return coalesce((select jsonb_agg(x order by x->>'customer_number') from (
    select jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name,
             'master_number', v.master_number, 'master_name', v.master_name, 'kind', v.kind,
             'lat', c.lat, 'lng', c.lng, 'orig_lat', c.orig_lat, 'orig_lng', c.orig_lng, 'state', app.loc_state(c.lat, c.lng),
             'updated_at', c.location_updated_at, 'region_id', z.region_id, 'region_state', z.state,
             'region', (select name from public.regions where id = z.region_id)) x
      from public.customers c
      join public.customers_v v on v.id = c.id
      join app.customer_regions(v_date) z on z.customer_id = c.id
     where app.can_see_customer(c.id)
       and (s = '' or c.customer_number = s or c.name ilike '%' || s || '%')
       and (nullif(o->>'region_id', '') is null or (o->>'region_id' = 'none' and z.region_id is null) or z.region_id::text = o->>'region_id')
       and (nullif(o->>'employee_id', '') is null or exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = (o->>'employee_id')::bigint))
       and (coalesce(o->>'state', 'all') = 'all' or app.loc_state(c.lat, c.lng) = o->>'state')
     limit 20000) q), '[]');
end $$;

-- ---------------------------------------------------------------------
-- P15 — خريطة الفواتير (MAP-002، MAP-014: الفواتير فقط؛ MAP-012: لا وقت إصدار في الإصدار الأول)
-- p_opts: {employees:[ids], supervisor_id, region_id, pay_type: all|cash|credit, loc: all|ok|missing}
-- ---------------------------------------------------------------------
create or replace function public.invoice_map(p_from date, p_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_emps bigint[];
begin
  perform app.require_perm('P15', 'view');
  if p_from is null or p_to is null or p_to < p_from then perform app.fail('bad_period', 'حدد فترة صحيحة'); end if;
  if p_to - p_from > 92 then perform app.fail('period_too_long', 'الفترة القصوى للخريطة 93 يومًا'); end if;
  v_emps := app.scope_emps(o, p_from, p_to);
  create temp table if not exists _im (j jsonb, ok boolean) on commit drop;
  truncate _im;
  insert into _im
  select jsonb_build_object('id', d.id, 'number', d.doc_number, 'date', d.doc_date, 'pay_type', d.pay_type,
           'customer_id', d.customer_id, 'customer_number', c.customer_number, 'customer', c.name, 'employee_id', d.employee_id, 'employee', e.name,
           'total', d.total, 'quantity', d.quantity, 'bonus', d.bonus, 'lat', d.lat, 'lng', d.lng, 'loc', app.loc_state(d.lat, d.lng),
           'cust_lat', c.lat, 'cust_lng', c.lng, 'in_region', app.doc_in_region(d.employee_id, d.doc_date, d.lat, d.lng)),
         app.loc_state(d.lat, d.lng) = 'ok'
    from public.docs d join public.customers c on c.id = d.customer_id join public.employees e on e.id = d.employee_id
   where d.kind = 'invoice' and d.status = 'active' and d.doc_date between p_from and p_to and d.employee_id = any(v_emps)
     and (coalesce(o->>'pay_type', 'all') = 'all' or (o->>'pay_type' = 'cash' and d.pay_type = 'فاتورة نقدي') or (o->>'pay_type' = 'credit' and d.pay_type = 'فاتورة ذمم'))
     and (nullif(o->>'region_id', '') is null or app.customer_region_at(d.customer_id, d.doc_date)::text = o->>'region_id')
     and (coalesce(o->>'loc', 'all') = 'all' or (o->>'loc' = 'ok') = (app.loc_state(d.lat, d.lng) = 'ok'))
   limit 50000;
  return jsonb_build_object('from', p_from, 'to', p_to, 'has_time', false,
    'points', coalesce((select jsonb_agg(j order by j->>'date', j->>'number') from _im where ok), '[]'),
    'missing', coalesce((select jsonb_agg(j order by j->>'date', j->>'number') from _im where not ok), '[]'),
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'emp_number', e.emp_number) order by e.name)
                             from public.employees e where e.id in (select (j->>'employee_id')::bigint from _im)), '[]'),
    'totals', (select jsonb_build_object('count', count(*), 'total', coalesce(sum((j->>'total')::numeric), 0),
                 'quantity', coalesce(sum((j->>'quantity')::numeric), 0), 'bonus', coalesce(sum((j->>'bonus')::numeric), 0),
                 'with_location', count(*) filter (where ok), 'missing', count(*) filter (where not ok),
                 'in_region', count(*) filter (where (j->>'in_region')::boolean), 'out_region', count(*) filter (where not (j->>'in_region')::boolean))
                 from _im));
end $$;

-- ---------------------------------------------------------------------
-- P17a — مقارنة الفترات (MAP-006، MAP-011، B069)
-- ---------------------------------------------------------------------
create or replace function app.work_days_between(p_from date, p_to date) returns int
language sql stable security definer set search_path = public, app as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g
   where extract(dow from g)::int = any(app.work_weekdays())
     and not exists (select 1 from public.holidays h where g::date between h.start_date and h.end_date)
$$;

-- عملاء النطاق: من تعامل معهم موظفو النطاق، أو عملاء المنطقة المختارة
create or replace function app.period_metrics(p_from date, p_to date, p_emps bigint[], p_region text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  create temp table if not exists _pd (id bigint, kind text, customer_id bigint, employee_id bigint, total numeric, in_region boolean) on commit drop;
  truncate _pd;
  insert into _pd
  select d.id, d.kind, d.customer_id, d.employee_id, d.total,
         case when d.kind = 'invoice' then app.doc_in_region(d.employee_id, d.doc_date, d.lat, d.lng) end
    from public.docs d
   where d.status = 'active' and d.kind in ('invoice', 'return') and d.doc_date between p_from and p_to and d.employee_id = any(p_emps)
     and (p_region is null or app.customer_region_at(d.customer_id, d.doc_date)::text = p_region);
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', p_to - p_from + 1, 'work_days', app.work_days_between(p_from, p_to),
    'sales', coalesce(sum(total) filter (where kind = 'invoice'), 0),
    'returns', coalesce(sum(total) filter (where kind = 'return'), 0),
    'net', coalesce(sum(case kind when 'invoice' then total else -total end), 0),
    'invoices', count(*) filter (where kind = 'invoice' and total > 0),
    'customers', count(distinct customer_id),
    'buyers', count(distinct customer_id) filter (where kind = 'invoice' and total > 0),
    'avg_invoice', case when count(*) filter (where kind = 'invoice' and total > 0) > 0
                        then sum(total) filter (where kind = 'invoice' and total > 0) / count(*) filter (where kind = 'invoice' and total > 0) end,
    'new_customers', (select count(distinct p.customer_id) from _pd p where p.kind = 'invoice' and p.total > 0
                        and not exists (select 1 from public.docs o where o.customer_id = p.customer_id and o.kind = 'invoice' and o.status = 'active'
                                          and o.total > 0 and o.doc_date < p_from)),
    'in_region', count(*) filter (where kind = 'invoice' and in_region),
    'out_region', count(*) filter (where kind = 'invoice' and in_region = false),
    'no_region', count(*) filter (where kind = 'invoice' and in_region is null))
  into v from _pd;
  -- غير المباعين: عملاء النطاق بلا شراء موجب في الفترة (MAP-011)
  v := v || jsonb_build_object('scope_customers', q.n, 'unsold', q.n - (v->>'buyers')::int)
    from (select count(*) n from public.customers c
           where app.can_see_customer(c.id)
             and (p_region is not null or exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = any(p_emps)))
             and (p_region is null or app.customer_region_at(c.id, p_to)::text = p_region)) q;
  v := v || jsonb_build_object('by_employee', coalesce((select jsonb_agg(jsonb_build_object('employee_id', x.employee_id, 'name', e.name,
            'sales', x.s, 'returns', x.r, 'net', x.s - x.r, 'invoices', x.n, 'buyers', x.b) order by e.name)
            from (select employee_id, coalesce(sum(total) filter (where kind = 'invoice'), 0) s, coalesce(sum(total) filter (where kind = 'return'), 0) r,
                         count(*) filter (where kind = 'invoice' and total > 0) n, count(distinct customer_id) filter (where kind = 'invoice' and total > 0) b
                    from _pd group by employee_id) x join public.employees e on e.id = x.employee_id), '[]'));
  return v;
end $$;

-- p_opts: {employees, supervisor_id, region_id}
create or replace function public.period_compare(p_a_from date, p_a_to date, p_b_from date, p_b_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_a jsonb; v_b jsonb;
begin
  perform app.require_perm('P17a', 'view');
  if p_a_to < p_a_from or p_b_to < p_b_from then perform app.fail('bad_period', 'حدد فترتين صحيحتين'); end if;
  if greatest(p_a_to - p_a_from, p_b_to - p_b_from) > 366 then perform app.fail('period_too_long', 'الفترة القصوى سنة'); end if;
  v_a := app.period_metrics(p_a_from, p_a_to, app.scope_emps(o, p_a_from, p_a_to), nullif(o->>'region_id', ''));
  v_b := app.period_metrics(p_b_from, p_b_to, app.scope_emps(o, p_b_from, p_b_to), nullif(o->>'region_id', ''));
  return jsonb_build_object('a', v_a, 'b', v_b, 'equal_length', (p_a_to - p_a_from) = (p_b_to - p_b_from));
end $$;

-- ---------------------------------------------------------------------
-- P17b — انتشار الأصناف (MAP-008، MAP-009، B070، B071)
-- p_opts: {employees, supervisor_id, region_id, search, current: bool}
-- ---------------------------------------------------------------------
create or replace function public.product_spread(p_product bigint, p_from date, p_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_emps bigint[]; v_rdate date; s text := trim(coalesce(o->>'search', ''));
begin
  perform app.require_perm('P17b', 'view');
  if p_product is null then perform app.fail('required', 'اختر صنفًا'); end if;
  if p_from is null or p_to is null or p_to < p_from then perform app.fail('bad_period', 'حدد فترة صحيحة'); end if;
  v_emps := app.scope_emps(o, p_from, p_to);
  -- المنطقة تتبع موقع العميل المعتمد بالنسخة السارية آخر الفترة، أو الوضع الحالي صراحة (B068)
  v_rdate := case when (o->>'current')::boolean then app.today() else p_to end;
  create temp table if not exists _ps (doc_id bigint, kind text, customer_id bigint, employee_id bigint, doc_date date, v numeric, q numeric, b numeric) on commit drop;
  truncate _ps;
  insert into _ps
  select d.id, d.kind, d.customer_id, d.employee_id, d.doc_date, sum(coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)),
         sum(coalesce(l.quantity, 0)), sum(coalesce(l.bonus, 0))
    from public.docs d join public.doc_lines l on l.doc_id = d.id
   where d.status = 'active' and d.kind in ('invoice', 'return') and l.product_id = p_product
     and d.doc_date between p_from and p_to and d.employee_id = any(v_emps)
   group by d.id;
  create temp table if not exists _pr (customer_id bigint, region_id bigint, state text) on commit drop;
  truncate _pr;
  insert into _pr select z.customer_id, z.region_id, z.state from app.customer_regions(v_rdate) z where z.customer_id in (select customer_id from _ps);
  return (
    with c as (
      select p.customer_id,
             sum(v) filter (where kind = 'invoice') val, sum(q) filter (where kind = 'invoice') qty, sum(b) filter (where kind = 'invoice') bonus,
             count(distinct doc_id) filter (where kind = 'invoice' and v > 0) inv,
             bool_or(kind = 'invoice' and v > 0) bought, bool_or(kind = 'invoice' and b > 0) got_bonus,
             sum(v) filter (where kind = 'return') rv, sum(q) filter (where kind = 'return') rq,
             min(doc_date) filter (where kind = 'invoice' and v > 0) first_d, max(doc_date) filter (where kind = 'invoice' and v > 0) last_d,
             array_agg(distinct employee_id) emps, array_agg(distinct doc_id) docs
        from _ps p group by p.customer_id
    ), r as (
      select c.*, cu.customer_number, cu.name, cv.kind ckind, cv.master_number, cu.lat, cu.lng, app.loc_state(cu.lat, cu.lng) ls,
             pr.region_id, pr.state rstate, (select name from public.regions where id = pr.region_id) region,
             case when c.bought then 'buyer' when c.got_bonus then 'bonus_only' else 'return_only' end cat
        from c join public.customers cu on cu.id = c.customer_id join public.customers_v cv on cv.id = c.customer_id
        left join _pr pr on pr.customer_id = c.customer_id
       where (nullif(o->>'region_id', '') is null or (o->>'region_id' = 'none' and pr.region_id is null) or pr.region_id::text = o->>'region_id')
         and (s = '' or cu.customer_number = s or cu.name ilike '%' || s || '%')
    )
    select jsonb_build_object('product', (select jsonb_build_object('id', id, 'code', code, 'name', name) from public.products where id = p_product),
      'from', p_from, 'to', p_to, 'region_date', v_rdate,
      'summary', jsonb_build_object(
        'buyers', count(*) filter (where cat = 'buyer'),
        'invoices', (select count(distinct doc_id) from _ps x where x.kind = 'invoice' and x.v > 0 and x.customer_id in (select customer_id from r)),
        'value', coalesce(sum(val), 0), 'quantity', coalesce(sum(qty), 0), 'bonus', coalesce(sum(bonus), 0),
        'returns_value', coalesce(sum(rv), 0), 'returns_qty', coalesce(sum(rq), 0),
        'bonus_only', count(*) filter (where cat = 'bonus_only'), 'return_only', count(*) filter (where cat = 'return_only'),
        'no_location', count(*) filter (where ls <> 'ok'), 'no_region', count(*) filter (where region_id is null)),
      'rows', coalesce(jsonb_agg(jsonb_build_object('customer_id', customer_id, 'customer_number', customer_number, 'name', name,
        'kind', ckind, 'master_number', master_number, 'lat', lat, 'lng', lng, 'loc', ls, 'region_id', region_id, 'region', region, 'region_state', rstate,
        'category', cat, 'value', coalesce(val, 0), 'quantity', coalesce(qty, 0), 'bonus', coalesce(bonus, 0), 'invoices', inv,
        'returns_value', coalesce(rv, 0), 'returns_qty', coalesce(rq, 0), 'first', first_d, 'last', last_d,
        'employees', (select jsonb_agg(name order by name) from public.employees where id = any(emps)), 'docs', to_jsonb(docs))
        order by cat, val desc nulls last, customer_number), '[]'))
    from r);
end $$;

-- ---------------------------------------------------------------------
-- الصلاحيات والقراءة
-- ---------------------------------------------------------------------
alter table public.regions            enable row level security;
alter table public.region_versions    enable row level security;
alter table public.region_assignments enable row level security;
create policy regions_read on public.regions for select to authenticated using (app.has_perm('P17') or app.has_perm('P15') or app.has_perm('P16'));
create policy region_versions_read on public.region_versions for select to authenticated using (app.has_perm('P17'));
create policy region_assignments_read on public.region_assignments for select to authenticated using (app.has_perm('P17'));

select app.apply_grants();
