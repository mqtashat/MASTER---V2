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
