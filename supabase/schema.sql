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
    if not app.can_see_employee((select id from public.employees where emp_number = v_norm->>'employee_number')) then
      perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك');
    end if;
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
  if not app.can_see_employee(v_emp.id) then perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك'); end if;
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
  if not app.can_see_employee(v_emp.id) then perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك'); end if;
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
