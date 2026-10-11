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
