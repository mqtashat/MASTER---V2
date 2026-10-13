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
