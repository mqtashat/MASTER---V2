-- =====================================================================
-- 0008 — التقارير: ثمانية تقارير جاهزة (B078–B085) وتقرير مخصص (UX-003)
-- التقارير تقرأ من المحركات الرسمية (السندات، Ledger الحسابات، الأهداف، العمولات) ولا تنشئ معادلات مالية مستقلة،
-- ولا توسع الصلاحيات: كل تقرير يشترط صلاحية P18 وصلاحية الصفحة التي يقرأ منها، ونطاق البيانات نفسه.
-- =====================================================================

-- إعدادات التقارير المحفوظة باسم لكل مستخدم
create table public.saved_reports (
  id          bigserial primary key,
  user_id     uuid not null default auth.uid(),
  name        text not null,
  report      text not null,
  config      jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, name)
);

create or replace function public.save_report(p_id bigint, p_name text, p_report text, p_config jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare v_id bigint;
begin
  perform app.require_perm('P18', 'view');
  if coalesce(trim(p_name), '') = '' then perform app.fail('required', 'اسم التقرير مطلوب'); end if;
  if p_report not in ('management', 'performance', 'sales', 'collections', 'returns', 'spread', 'commissions', 'quality', 'custom') then
    perform app.fail('bad_report', 'تقرير غير معروف');
  end if;
  if p_id is null then
    if exists (select 1 from public.saved_reports where user_id = auth.uid() and name = trim(p_name)) then
      perform app.fail('duplicate', 'يوجد تقرير محفوظ بهذا الاسم');
    end if;
    insert into public.saved_reports (user_id, name, report, config) values (auth.uid(), trim(p_name), p_report, coalesce(p_config, '{}'))
    returning id into v_id;
  else
    update public.saved_reports set name = trim(p_name), report = p_report, config = coalesce(p_config, '{}'), updated_at = now()
     where id = p_id and user_id = auth.uid() returning id into v_id;
    if v_id is null then perform app.fail('not_found', 'التقرير المحفوظ غير موجود'); end if;
  end if;
  return v_id;
end $$;

create or replace function public.delete_saved_report(p_id bigint) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  delete from public.saved_reports where id = p_id and user_id = auth.uid();
  if not found then perform app.fail('not_found', 'التقرير المحفوظ غير موجود'); end if;
end $$;

-- ---------------------------------------------------------------------
-- بنود الحركة ضمن الفلاتر والنطاق: الفواتير والمرتجعات بالبند، والتحصيلات بالسند عند طلبها
-- o: {from, to, employees, supervisor_id, region_id, product_id, search, pay_type, kinds}
-- ---------------------------------------------------------------------
create or replace function app.rep_lines(o jsonb, p_need_region boolean, p_collections boolean) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := (o->>'from')::date; v_to date := (o->>'to')::date;
  v_emps bigint[]; v_region text := nullif(o->>'region_id', ''); v_prod bigint := nullif(o->>'product_id', '')::bigint;
  s text := trim(coalesce(o->>'search', '')); v_pay text := nullif(o->>'pay_type', '');
  v_kinds text[] := case when jsonb_typeof(o->'kinds') = 'array' and jsonb_array_length(o->'kinds') > 0
                         then array(select jsonb_array_elements_text(o->'kinds')) else array['invoice', 'return', 'collection'] end;
begin
  if v_from is null or v_to is null or v_to < v_from then perform app.fail('bad_period', 'حدد فترة صحيحة'); end if;
  if v_to - v_from > 731 then perform app.fail('period_too_long', 'الفترة القصوى سنتان'); end if;
  v_emps := app.scope_emps(o, v_from, v_to);
  create temp table if not exists _rl (kind text, doc_id bigint, doc_date date, customer_id bigint, employee_id bigint, product_id bigint,
    pay_type text, value numeric, net_sales numeric, promo numeric, qty numeric, bonus numeric, region_id bigint,
    employee text, customer text, family text, product text, region text, month text, day date) on commit drop;
  truncate _rl;
  insert into _rl (kind, doc_id, doc_date, customer_id, employee_id, product_id, pay_type, value, net_sales, promo, qty, bonus)
  select d.kind, d.id, d.doc_date, d.customer_id, d.employee_id, l.product_id, d.pay_type,
         coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0), coalesce(l.net_sales, 0), coalesce(l.net_promotions, 0),
         coalesce(l.quantity, 0), coalesce(l.bonus, 0)
    from public.docs d join public.doc_lines l on l.doc_id = d.id
   where d.status = 'active' and d.kind in ('invoice', 'return') and d.kind = any(v_kinds)
     and d.doc_date between v_from and v_to and d.employee_id = any(v_emps)
     and (v_prod is null or l.product_id = v_prod)
     and (v_pay is null or d.kind <> 'invoice' or d.pay_type = v_pay);
  if p_collections and v_prod is null and 'collection' = any(v_kinds) then
    insert into _rl (kind, doc_id, doc_date, customer_id, employee_id, value, net_sales, promo, qty, bonus)
    select d.kind, d.id, d.doc_date, d.customer_id, d.employee_id, d.total, 0, 0, 0, 0
      from public.docs d
     where d.status = 'active' and d.kind = 'collection' and d.doc_date between v_from and v_to and d.employee_id = any(v_emps);
  end if;
  if s <> '' then
    delete from _rl r using public.customers c
     where c.id = r.customer_id and not (c.customer_number = s or c.name ilike '%' || s || '%');
  end if;
  if p_need_region or v_region is not null then
    update _rl set region_id = app.customer_region_at(customer_id, doc_date);
    if v_region = 'none' then delete from _rl where region_id is not null;
    elsif v_region is not null then delete from _rl where region_id is distinct from v_region::bigint; end if;
    update _rl r set region = g.name from public.regions g where g.id = r.region_id;
    update _rl set region = 'بلا منطقة' where region is null;
  end if;
  update _rl r set employee = e.emp_number || ' — ' || e.name from public.employees e where e.id = r.employee_id;
  update _rl r set customer = c.customer_number || ' — ' || c.name from public.customers c where c.id = r.customer_id;
  update _rl r set family = coalesce((select m.customer_number || ' — ' || m.name from public.customers m where m.id = app.master_of(r.customer_id, r.doc_date)), r.customer);
  update _rl r set product = p.code || ' — ' || p.name from public.products p where p.id = r.product_id;
  update _rl set product = '(تحصيل)' where kind = 'collection';
  update _rl set month = to_char(doc_date, 'YYYY-MM'), day = doc_date;
end $$;

-- الأبعاد والمقاييس المعتمدة فقط (لا محرر معادلات حر)
create or replace function app.rep_dim(p text) returns text
language sql immutable as $$
  select case p when 'employee' then 'employee' when 'customer' then 'customer' when 'family' then 'family' when 'product' then 'product'
                when 'region' then 'region' when 'pay_type' then 'pay_type' when 'kind' then 'kind' when 'month' then 'month' when 'day' then 'day' end
$$;

create or replace function app.rep_measure(p text) returns text
language sql immutable as $$
  select case p
    when 'sales_value'   then 'coalesce(sum(value) filter (where kind = ''invoice''), 0)'
    when 'direct_sales'  then 'coalesce(sum(net_sales) filter (where kind = ''invoice''), 0)'
    when 'promotions'    then 'coalesce(sum(promo) filter (where kind = ''invoice''), 0)'
    when 'returns_value' then 'coalesce(sum(value) filter (where kind = ''return''), 0)'
    when 'net_value'     then 'coalesce(sum(value) filter (where kind = ''invoice''), 0) - coalesce(sum(value) filter (where kind = ''return''), 0)'
    when 'sales_qty'     then 'coalesce(sum(qty) filter (where kind = ''invoice''), 0)'
    when 'returns_qty'   then 'coalesce(sum(qty) filter (where kind = ''return''), 0)'
    when 'bonus'         then 'coalesce(sum(bonus) filter (where kind = ''invoice''), 0)'
    when 'invoices'      then 'count(distinct doc_id) filter (where kind = ''invoice'')'
    when 'returns_count' then 'count(distinct doc_id) filter (where kind = ''return'')'
    when 'customers'     then 'count(distinct customer_id) filter (where kind = ''invoice'' and value > 0)'
    when 'products'      then 'count(distinct product_id) filter (where kind = ''invoice'' and value > 0)'
    when 'avg_invoice'   then 'round(coalesce(sum(value) filter (where kind = ''invoice''), 0) / nullif(count(distinct doc_id) filter (where kind = ''invoice''), 0), 3)'
    when 'return_ratio'  then 'round(coalesce(sum(value) filter (where kind = ''return''), 0) * 100 / nullif(sum(value) filter (where kind = ''invoice''), 0), 2)'
    when 'collections'   then 'coalesce(sum(value) filter (where kind = ''collection''), 0)'
  end
$$;

create or replace function app.rep_label(p text) returns text
language sql immutable as $$
  select case p
    when 'employee' then 'الموظف' when 'customer' then 'العميل' when 'family' then 'العائلة (الرئيسي)' when 'product' then 'الصنف'
    when 'region' then 'المنطقة' when 'pay_type' then 'نوع الفاتورة' when 'kind' then 'نوع الحركة' when 'month' then 'الشهر' when 'day' then 'اليوم'
    when 'sales_value' then 'المبيعات' when 'direct_sales' then 'المبيعات المباشرة' when 'promotions' then 'العروض'
    when 'returns_value' then 'المرتجعات' when 'net_value' then 'صافي المبيعات' when 'sales_qty' then 'الكمية المباعة'
    when 'returns_qty' then 'الكمية المرتجعة' when 'bonus' then 'البونص' when 'invoices' then 'عدد الفواتير'
    when 'returns_count' then 'عدد المرتجعات' when 'customers' then 'العملاء المشترون' when 'products' then 'الأصناف المختلفة'
    when 'avg_invoice' then 'متوسط الفاتورة' when 'return_ratio' then 'نسبة المرتجع للبيع %' when 'collections' then 'التحصيلات'
  end
$$;

create or replace function app.rep_kind(p text) returns text
language sql immutable as $$
  select case when p in ('sales_value', 'direct_sales', 'promotions', 'returns_value', 'net_value', 'avg_invoice', 'collections') then 'money'
              when p in ('sales_qty', 'returns_qty', 'bonus') then 'qty' when p = 'return_ratio' then 'pct'
              when p in ('invoices', 'returns_count', 'customers', 'products') then 'count' when p = 'day' then 'date' else 'text' end
$$;

-- تجميع _rl بأبعاد ومقاييس معتمدة؛ الترتيب بأي عمود مختار
create or replace function app.rep_cube(p_dims text[], p_measures text[], p_sort text, p_desc boolean, p_having text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_dims text[] := '{}'; v_meas text[] := '{}'; x text; v_sel text; v_rows jsonb; v_tot jsonb; v_order text;
begin
  foreach x in array coalesce(p_dims, '{}') loop
    if app.rep_dim(x) is null then perform app.fail('bad_column', 'عمود غير معتمد: ' || x); end if;
    if not x = any(v_dims) then v_dims := v_dims || x; end if;
  end loop;
  foreach x in array coalesce(p_measures, '{}') loop
    if app.rep_measure(x) is null then perform app.fail('bad_column', 'مقياس غير معتمد: ' || x); end if;
    if not x = any(v_meas) then v_meas := v_meas || x; end if;
  end loop;
  if cardinality(v_meas) = 0 then perform app.fail('required', 'اختر مقياسًا واحدًا على الأقل'); end if;
  if cardinality(v_dims) > 4 then perform app.fail('too_many', 'التجميع بأربعة أبعاد على الأكثر'); end if;
  select string_agg(format('%s as %I', app.rep_measure(m), m), ', ') into v_sel from unnest(v_meas) m;
  v_order := case when p_sort is not null and (p_sort = any(v_dims) or p_sort = any(v_meas))
                  then format('%I %s nulls last', p_sort, case when p_desc then 'desc' else 'asc' end)
                       || coalesce((select ', ' || string_agg(format('%I', d), ', ') from unnest(v_dims) d), '')
                  else coalesce((select string_agg(format('%I', d), ', ') from unnest(v_dims) d), '1') end;
  if cardinality(v_dims) > 0 then
    execute format('select coalesce(jsonb_agg(to_jsonb(q) order by %s), ''[]'') from (select %s, %s from _rl group by %s %s) q',
      v_order, (select string_agg(format('%I', d), ', ') from unnest(v_dims) d), v_sel,
      (select string_agg(format('%I', d), ', ') from unnest(v_dims) d), coalesce('having ' || p_having, '')) into v_rows;
  else
    v_rows := '[]';
  end if;
  execute format('select to_jsonb(q) from (select %s from _rl) q', v_sel) into v_tot;
  return jsonb_build_object(
    'columns', (select jsonb_agg(jsonb_build_object('key', c, 'label', app.rep_label(c), 'kind', app.rep_kind(c)) order by o)
                  from unnest(v_dims || v_meas) with ordinality t(c, o)),
    'rows', v_rows, 'totals', v_tot);
end $$;

create or replace function app.rep_arr(p jsonb) returns text[]
language sql immutable as $$
  select case when jsonb_typeof(p) = 'array' then array(select jsonb_array_elements_text(p)) else '{}'::text[] end
$$;

-- حالة الأشهر التي تغطيها الفترة: مفتوح أو مغلق بنسخته
create or replace function app.rep_months(p_from date, p_to date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('month', m::date, 'closed', app.is_closed(m::date),
           'version', (select version from public.months x where x.month = m::date)) order by m), '[]')
    from generate_series(app.month_of(p_from), app.month_of(p_to), interval '1 month') m
$$;

-- ---------------------------------------------------------------------
-- التقارير الجاهزة
-- ---------------------------------------------------------------------

-- B078 ملخص الإدارة: مبيعات ومرتجعات وصافي وتحصيل وذمم وإنجاز ومقارنة بالفترة السابقة بالطول نفسه
create or replace function app.rep_management(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := (o->>'from')::date; v_to date := (o->>'to')::date; v_len int; a jsonb; b jsonb;
  v_coll numeric; v_pcoll numeric; v_rec jsonb; v_goals jsonb; v_rows jsonb := '[]'; k text; lbl text;
begin
  v_len := v_to - v_from + 1;
  a := app.period_metrics(v_from, v_to, app.scope_emps(o, v_from, v_to), nullif(o->>'region_id', ''));
  b := app.period_metrics(v_from - v_len, v_from - 1, app.scope_emps(o, v_from - v_len, v_from - 1), nullif(o->>'region_id', ''));
  select coalesce(sum(total) filter (where doc_date between v_from and v_to), 0), coalesce(sum(total) filter (where doc_date < v_from), 0)
    into v_coll, v_pcoll from public.docs
   where kind = 'collection' and status = 'active' and doc_date between v_from - v_len and v_to
     and employee_id = any(app.scope_emps(o, v_from - v_len, v_to));
  for k, lbl in select * from (values ('sales', 'المبيعات'), ('returns', 'المرتجعات'), ('net', 'صافي المبيعات'), ('invoices', 'عدد الفواتير'),
                                      ('buyers', 'العملاء المشترون'), ('new_customers', 'العملاء الجدد'), ('avg_invoice', 'متوسط الفاتورة')) t loop
    v_rows := v_rows || jsonb_build_object('metric', lbl, 'unit', case when k in ('sales', 'returns', 'net', 'avg_invoice') then 'money' else 'count' end,
      'current', a->k, 'previous', b->k,
      'change', coalesce((a->>k)::numeric, 0) - coalesce((b->>k)::numeric, 0),
      'pct', case when coalesce((b->>k)::numeric, 0) = 0 then null else round(((a->>k)::numeric - (b->>k)::numeric) * 100 / abs((b->>k)::numeric), 2) end);
  end loop;
  v_rows := v_rows || jsonb_build_object('metric', 'التحصيلات', 'current', v_coll, 'previous', v_pcoll, 'change', v_coll - v_pcoll,
      'pct', case when v_pcoll = 0 then null else round((v_coll - v_pcoll) * 100 / abs(v_pcoll), 2) end);
  if app.has_perm('P08', 'view') then v_rec := public.receivables(v_to, '{}')->'summary'; end if;
  if app.has_perm('P10', 'view') then
    select jsonb_build_object('employees', count(*), 'with_plan', count(*) filter (where x->>'plan_id' is not null),
             'achieved', count(*) filter (where x->>'plan_id' is not null and coalesce(x->>'achieved', 'NONE') <> 'NONE'))
      into v_goals from jsonb_array_elements(public.goals_list(app.month_of(v_to), 'rep')->'rows') x;
  end if;
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'صافي المبيعات', 'value', a->'net', 'kind', 'money'),
      jsonb_build_object('label', 'المرتجعات', 'value', a->'returns', 'kind', 'money'),
      jsonb_build_object('label', 'التحصيلات', 'value', v_coll, 'kind', 'money'),
      jsonb_build_object('label', 'الذمم المتبقية في ' || to_char(v_to, 'DD/MM/YYYY'), 'value', v_rec->'remaining', 'kind', 'money'),
      jsonb_build_object('label', 'المتأخر', 'value', v_rec->'overdue', 'kind', 'money'),
      jsonb_build_object('label', 'مندوبون حققوا شريحة', 'value', case when v_goals is null then null else (v_goals->>'achieved') || ' من ' || (v_goals->>'with_plan') end, 'kind', 'text')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'metric', 'label', 'المؤشر', 'kind', 'text'),
      jsonb_build_object('key', 'current', 'label', to_char(v_from, 'DD/MM') || '–' || to_char(v_to, 'DD/MM/YYYY'), 'kind', 'auto'),
      jsonb_build_object('key', 'previous', 'label', 'الفترة السابقة ' || to_char(v_from - v_len, 'DD/MM') || '–' || to_char(v_from - 1, 'DD/MM/YYYY'), 'kind', 'auto'),
      jsonb_build_object('key', 'change', 'label', 'الفرق', 'kind', 'auto'),
      jsonb_build_object('key', 'pct', 'label', 'التغير %', 'kind', 'pct')),
    'rows', v_rows,
    'definitions', jsonb_build_array(
      'المبيعات = المبيعات المباشرة + العروض في الفواتير الفعالة؛ الصافي = المبيعات − المرتجعات.',
      'التحصيلات = مجموع سندات التحصيل في الفترة ضمن نطاق الموظفين.',
      'الذمم والمتأخر من محرك الحسابات الرسمي في تاريخ نهاية الفترة' || case when v_rec is null then ' (تتطلب صلاحية الذمم).' else '.' end,
      'الفترة السابقة بالطول نفسه مباشرة قبل الفترة المختارة.'));
end $$;

-- B079 أداء المندوبين والمشرفين لشهر نهاية الفترة
create or replace function app.rep_performance(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of((o->>'to')::date); v_to date := (date_trunc('month', v_m) + interval '1 month - 1 day')::date;
  v_goals jsonb := '[]'; v_comm jsonb; v_cube jsonb; v_rows jsonb; v_emps bigint[];
begin
  if not (app.has_perm('P10', 'view') or app.has_perm('P14', 'view')) then
    perform app.fail('forbidden', 'تقرير الأداء يتطلب صلاحية الأهداف أو العمولات');
  end if;
  v_emps := app.scope_emps(o, v_m, v_to);
  perform app.rep_lines(o || jsonb_build_object('from', v_m, 'to', v_to), false, false);
  v_cube := app.rep_cube(array['employee'], array['net_value', 'sales_value', 'returns_value', 'invoices', 'customers', 'sales_qty', 'bonus'], null, false);
  if app.has_perm('P10', 'view') then
    select coalesce(jsonb_agg(x || '{"role": "rep"}'), '[]') into v_goals from jsonb_array_elements(public.goals_list(v_m, 'rep')->'rows') x;
    if app.has_perm('P10a', 'view') then
      v_goals := v_goals || (select coalesce(jsonb_agg(x || '{"role": "supervisor"}'), '[]') from jsonb_array_elements(public.goals_list(v_m, 'supervisor')->'rows') x);
    end if;
  end if;
  if app.has_perm('P14', 'view') then v_comm := public.commission_summary(v_m)->'rows'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee', e.emp_number || ' — ' || e.name,
           'role', case when exists (select 1 from jsonb_array_elements(v_goals) g where (g->>'employee_id')::bigint = e.id and g->>'plan_id' is not null and g->>'role' = 'supervisor')
                          or exists (select 1 from jsonb_array_elements(coalesce(v_comm, '[]')) c where (c->>'employee_id')::bigint = e.id and c->>'role' = 'supervisor')
                        then 'مشرف' else 'مندوب' end,
           'achieved', (select g->>'achieved' from jsonb_array_elements(v_goals) g where (g->>'employee_id')::bigint = e.id and g->>'plan_id' is not null limit 1),
           'path_tier', (select g->>'path_tier' from jsonb_array_elements(v_goals) g where (g->>'employee_id')::bigint = e.id and g->>'plan_id' is not null limit 1),
           'net_value', coalesce((r->>'net_value')::numeric, 0), 'invoices', coalesce((r->>'invoices')::int, 0),
           'customers', coalesce((r->>'customers')::int, 0), 'sales_qty', coalesce((r->>'sales_qty')::numeric, 0),
           'commission', (select (c->>'final')::numeric from jsonb_array_elements(coalesce(v_comm, '[]')) c where (c->>'employee_id')::bigint = e.id),
           'status', (select case c->>'status' when 'incomplete' then 'غير مكتمل' when 'complete' then 'مكتمل' end
                        from jsonb_array_elements(coalesce(v_comm, '[]')) c where (c->>'employee_id')::bigint = e.id))
         order by e.name), '[]')
    into v_rows
    from public.employees e
    left join lateral (select x r from jsonb_array_elements(v_cube->'rows') x where x->>'employee' = e.emp_number || ' — ' || e.name) q on true
   where e.id = any(v_emps)
     and (q.r is not null or exists (select 1 from jsonb_array_elements(v_goals) g where (g->>'employee_id')::bigint = e.id and g->>'plan_id' is not null)
          or exists (select 1 from jsonb_array_elements(coalesce(v_comm, '[]')) c where (c->>'employee_id')::bigint = e.id));
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'الشهر', 'value', to_char(v_m, 'MM/YYYY'), 'kind', 'text'),
      jsonb_build_object('label', 'صافي المبيعات', 'value', v_cube->'totals'->'net_value', 'kind', 'money'),
      jsonb_build_object('label', 'الفواتير', 'value', v_cube->'totals'->'invoices', 'kind', 'count'),
      jsonb_build_object('label', 'العمولات المستحقة', 'value', (select sum((x->>'commission')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'employee', 'label', 'الموظف', 'kind', 'text'), jsonb_build_object('key', 'role', 'label', 'الدور', 'kind', 'text'),
      jsonb_build_object('key', 'achieved', 'label', 'الشريحة المحققة', 'kind', 'tier'), jsonb_build_object('key', 'path_tier', 'label', 'شريحة المسار', 'kind', 'tier'),
      jsonb_build_object('key', 'net_value', 'label', 'صافي المبيعات', 'kind', 'money'), jsonb_build_object('key', 'invoices', 'label', 'الفواتير', 'kind', 'count'),
      jsonb_build_object('key', 'customers', 'label', 'العملاء المشترون', 'kind', 'count'), jsonb_build_object('key', 'sales_qty', 'label', 'الكمية', 'kind', 'qty'),
      jsonb_build_object('key', 'commission', 'label', 'العمولة المستحقة', 'kind', 'money'), jsonb_build_object('key', 'status', 'label', 'حالة الكشف', 'kind', 'text')),
    'rows', v_rows,
    'definitions', jsonb_build_array(
      'الشريحة المحققة وشريحة المسار من محرك الأهداف لشهر نهاية الفترة (CARD-004).',
      'العمولة المستحقة من كشف العمولات الرسمي، أو من نسخة الإغلاق إن كان الشهر مغلقًا' || case when v_comm is null then ' (تتطلب صلاحية كشف العمولات).' else '.' end,
      'المبيعات والفواتير والعملاء من السندات الفعالة ضمن نطاقك.'));
end $$;

-- B080 المبيعات التفصيلية بتجميع يختاره المستخدم
create or replace function app.rep_sales(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_dims text[] := app.rep_arr(o->'group_by'); v jsonb;
begin
  if cardinality(v_dims) = 0 then v_dims := array['employee']; end if;
  perform app.rep_lines(o, 'region' = any(v_dims), false);
  v := app.rep_cube(v_dims, array['sales_value', 'direct_sales', 'promotions', 'returns_value', 'net_value', 'sales_qty', 'bonus', 'invoices', 'customers'],
                    coalesce(nullif(o->>'sort', ''), 'net_value'), coalesce((o->>'desc')::boolean, true));
  return v || jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'المبيعات', 'value', v->'totals'->'sales_value', 'kind', 'money'),
      jsonb_build_object('label', 'المرتجعات', 'value', v->'totals'->'returns_value', 'kind', 'money'),
      jsonb_build_object('label', 'صافي المبيعات', 'value', v->'totals'->'net_value', 'kind', 'money'),
      jsonb_build_object('label', 'الفواتير', 'value', v->'totals'->'invoices', 'kind', 'count'),
      jsonb_build_object('label', 'العملاء المشترون', 'value', v->'totals'->'customers', 'kind', 'count')),
    'definitions', jsonb_build_array(
      'المبيعات = المباشر + العروض لبنود الفواتير الفعالة؛ الكمية كما وردت والبونص كمية مجانية.',
      'المنطقة بحسب موقع العميل المعتمد ونسخة الحدود السارية بتاريخ السند؛ العائلة بالرئيسي في تاريخ السند.',
      'عدد الفواتير والعملاء في سطر الإجمالي فريد على مستوى الفترة كلها، فلا يساوي بالضرورة مجموع الأسطر.'));
end $$;

-- B081 التحصيل والذمم: الأرصدة والبنود المفتوحة والاستحقاق والتأخر والمحصل، والافتتاحي غير المفصل منفصلًا
create or replace function app.rep_collections(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_to date := (o->>'to')::date; v_emps bigint[] := app.scope_emps(o, (o->>'from')::date, v_to); v_rec jsonb; v_one bigint; v_coll jsonb; v_rows jsonb;
begin
  perform app.require_perm('P08', 'view');
  if cardinality(v_emps) = 1 and (coalesce(jsonb_array_length(case when jsonb_typeof(o->'employees') = 'array' then o->'employees' end), 0) > 0
                                   or nullif(o->>'supervisor_id', '') is not null) then v_one := v_emps[1]; end if;
  v_rec := public.receivables(v_to, case when v_one is null then '{}'::jsonb else jsonb_build_object('employee_id', v_one) end);
  perform app.rep_lines(o || '{"kinds": ["collection"]}', false, true);
  v_coll := app.rep_cube(array['employee'], array['collections'], 'collections', true);
  select coalesce(jsonb_agg(jsonb_build_object(
           'customer', d->>'customer_number' || ' — ' || (d->>'name'), 'role', d->>'role', 'master', d->>'master_number',
           'grace_days', d->'grace_days', 'balance', d->'balance', 'open_total', d->'open_total', 'overdue_total', d->'overdue_total',
           'oldest_age', d->'oldest_age',
           'opening', (select coalesce(sum((i->>'remaining')::numeric), 0) from jsonb_array_elements(d->'items') i where i->>'kind' = 'open_debit'),
           'open_items', jsonb_array_length(d->'items'))
         order by (d->>'overdue_total')::numeric desc, d->>'customer_number'), '[]')
    into v_rows from jsonb_array_elements(v_rec->'debtors') d
   where nullif(o->>'search', '') is null or d->>'customer_number' = trim(o->>'search') or d->>'name' ilike '%' || trim(o->>'search') || '%';
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'المحصل في الفترة', 'value', v_coll->'totals'->'collections', 'kind', 'money'),
      jsonb_build_object('label', 'الذمم المتبقية', 'value', v_rec->'summary'->'remaining', 'kind', 'money'),
      jsonb_build_object('label', 'المتأخر', 'value', v_rec->'summary'->'overdue', 'kind', 'money'),
      jsonb_build_object('label', 'العملاء المدينون', 'value', v_rec->'summary'->'debtors', 'kind', 'count'),
      jsonb_build_object('label', 'افتتاحي غير مفصل متبقٍ', 'value', (select sum((x->>'opening')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money'),
      jsonb_build_object('label', 'أرصدة دائنة', 'value', v_rec->'summary'->'creditors_total', 'kind', 'money')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'customer', 'label', 'العميل', 'kind', 'text'), jsonb_build_object('key', 'role', 'label', 'النوع', 'kind', 'text'),
      jsonb_build_object('key', 'balance', 'label', 'الرصيد', 'kind', 'money'), jsonb_build_object('key', 'open_total', 'label', 'المفتوح', 'kind', 'money'),
      jsonb_build_object('key', 'overdue_total', 'label', 'المتأخر', 'kind', 'money'), jsonb_build_object('key', 'opening', 'label', 'منه افتتاحي غير مفصل', 'kind', 'money'),
      jsonb_build_object('key', 'oldest_age', 'label', 'أقدم عمر (يوم)', 'kind', 'count'), jsonb_build_object('key', 'grace_days', 'label', 'المهلة', 'kind', 'count'),
      jsonb_build_object('key', 'open_items', 'label', 'البنود المفتوحة', 'kind', 'count')),
    'rows', v_rows,
    'extra', jsonb_build_object('title', 'المحصل حسب الموظف', 'columns', v_coll->'columns', 'rows', v_coll->'rows'),
    'definitions', jsonb_build_array(
      'الأرصدة والبنود المفتوحة والاستحقاق من محرك الحسابات الرسمي (FIFO) في تاريخ نهاية الفترة.',
      'المتأخر = البنود التي تجاوزت مهلة العميل (30 يومًا عند عدم التحديد).',
      'الافتتاحي غير المفصل يظهر منفصلًا لأنه بلا تاريخ فاتورة.',
      'المحصل = سندات التحصيل في الفترة؛ قد يسدد مبيعات فترات سابقة.'));
end $$;

-- B082 المرتجعات: قيم وكميات ونسبة للبيع، دون اختلاق سبب غير وارد
create or replace function app.rep_returns(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_dims text[] := app.rep_arr(o->'group_by'); v jsonb;
begin
  if cardinality(v_dims) = 0 then v_dims := array['product']; end if;
  perform app.rep_lines(o, 'region' = any(v_dims), false);
  v := app.rep_cube(v_dims, array['returns_value', 'returns_qty', 'returns_count', 'sales_value', 'sales_qty', 'return_ratio'],
                    coalesce(nullif(o->>'sort', ''), 'returns_value'), coalesce((o->>'desc')::boolean, true),
                    'count(*) filter (where kind = ''return'') > 0');
  return v || jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'قيمة المرتجعات', 'value', v->'totals'->'returns_value', 'kind', 'money'),
      jsonb_build_object('label', 'الكمية المرتجعة', 'value', v->'totals'->'returns_qty', 'kind', 'qty'),
      jsonb_build_object('label', 'سندات المرتجع', 'value', v->'totals'->'returns_count', 'kind', 'count'),
      jsonb_build_object('label', 'نسبة المرتجع للبيع %', 'value', v->'totals'->'return_ratio', 'kind', 'pct')),
    'definitions', jsonb_build_array(
      'نسبة المرتجع = قيمة المرتجع ÷ المبيعات في الفترة والتجميع نفسيهما × 100؛ تظهر فارغة عند غياب المبيعات.',
      'لا يُعرض سبب للمرتجع لأن ملف المرتجعات لا يتضمنه.',
      'التصنيف المالي للمرتجع (نقدي/مؤثر) في صفحة الذمم ولا يغير هذه القيم.'));
end $$;

-- B083 الانتشار والعملاء: المشترون وتكرار الشراء والأصناف، وغير المشترين ضمن مجموعة معلومة صريحة
create or replace function app.rep_spread(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := (o->>'from')::date; v_to date := (o->>'to')::date; v_emps bigint[]; v jsonb; v_rows jsonb; v_non jsonb := '[]';
  v_known boolean := coalesce(jsonb_array_length(case when jsonb_typeof(o->'employees') = 'array' then o->'employees' end), 0) > 0
                     or nullif(o->>'supervisor_id', '') is not null or nullif(o->>'region_id', '') is not null;
begin
  v_emps := app.scope_emps(o, v_from, v_to);
  perform app.rep_lines(o || '{"kinds": ["invoice"]}', false, false);
  v := app.rep_cube(array['customer'], array['invoices', 'sales_value', 'sales_qty', 'products'], 'sales_value', true,
                    'sum(value) filter (where kind = ''invoice'') > 0');
  select coalesce(jsonb_agg(r || jsonb_build_object('status', 'مشترٍ',
           'last_date', (select max(doc_date) from _rl x where x.customer = r->>'customer'))), '[]')
    into v_rows from jsonb_array_elements(v->'rows') r;
  if v_known then
    select coalesce(jsonb_agg(jsonb_build_object('customer', c.customer_number || ' — ' || c.name, 'invoices', 0, 'sales_value', 0, 'sales_qty', 0,
             'products', 0, 'status', 'غير مشترٍ',
             'last_date', (select max(d.doc_date) from public.docs d where d.customer_id = c.id and d.kind = 'invoice' and d.status = 'active' and d.total > 0))
           order by c.customer_number), '[]')
      into v_non from public.customers c
     where app.can_see_customer(c.id)
       and (nullif(o->>'region_id', '') is not null
            or exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = any(v_emps)))
       and (nullif(o->>'region_id', '') is null
            or coalesce(app.customer_region_at(c.id, v_to)::text, 'none') = o->>'region_id')
       and (nullif(o->>'search', '') is null or c.customer_number = trim(o->>'search') or c.name ilike '%' || trim(o->>'search') || '%')
       and not exists (select 1 from _rl x where x.customer_id = c.id and x.value > 0);
  end if;
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'العملاء المشترون', 'value', jsonb_array_length(v_rows), 'kind', 'count'),
      jsonb_build_object('label', 'غير المشترين في المجموعة', 'value', case when v_known then jsonb_array_length(v_non) end, 'kind', 'count'),
      jsonb_build_object('label', 'متوسط الفواتير للمشتري', 'value', case when jsonb_array_length(v_rows) > 0
                           then round((v->'totals'->>'invoices')::numeric / jsonb_array_length(v_rows), 2) end, 'kind', 'number'),
      jsonb_build_object('label', 'الأصناف المختلفة المباعة', 'value', v->'totals'->'products', 'kind', 'count')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'customer', 'label', 'العميل', 'kind', 'text'), jsonb_build_object('key', 'status', 'label', 'الحالة', 'kind', 'text'),
      jsonb_build_object('key', 'invoices', 'label', 'مرات الشراء (فواتير)', 'kind', 'count'), jsonb_build_object('key', 'sales_value', 'label', 'المبيعات', 'kind', 'money'),
      jsonb_build_object('key', 'sales_qty', 'label', 'الكمية', 'kind', 'qty'), jsonb_build_object('key', 'products', 'label', 'الأصناف المختلفة', 'kind', 'count'),
      jsonb_build_object('key', 'last_date', 'label', 'آخر شراء', 'kind', 'date')),
    'rows', v_rows || v_non,
    'notice', case when not v_known then 'غير المشترين لا يُحسبون إلا لمجموعة معلومة: اختر موظفين أو مجموعة أو منطقة.' end,
    'definitions', jsonb_build_array(
      'المشتري: عميل له بيع موجب في الفترة ضمن الفلاتر؛ البونص وحده لا يجعل العميل مشتريًا.',
      'غير المشترين: عملاء المجموعة المختارة (عملاء الموظفين المختارين أو المنطقة) دون بيع موجب في الفترة، ضمن صلاحيتك فقط.',
      'آخر شراء لغير المشتري من كل تاريخه، ولا يتقيد بالفترة.'));
end $$;

-- B084 العمولات والمكافآت: المحسوب والتعديلات والمستحق ونسخة الاعتماد
create or replace function app.rep_commissions(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_m date := app.month_of((o->>'to')::date); v jsonb; v_emps bigint[]; v_rows jsonb;
begin
  perform app.require_perm('P14', 'view');
  v := public.commission_summary(v_m);
  v_emps := app.scope_emps(o, v_m, (date_trunc('month', v_m) + interval '1 month - 1 day')::date);
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee', (r->>'emp_number') || ' — ' || (r->>'name'), 'role', case r->>'role' when 'supervisor' then 'مشرف' else 'مندوب' end,
           'rule_name', r->'rule_name', 'tier', r->'tier', 'base', r->'base', 'rewards', r->'rewards', 'adjustments', r->'adjustments',
           'final', r->'final', 'status', case r->>'status' when 'incomplete' then 'غير مكتمل' when 'complete' then 'مكتمل' else r->>'status' end,
           'warnings', (select string_agg(w->>'message', '، ') from jsonb_array_elements(coalesce(r->'warnings', '[]')) w))
         order by r->>'name'), '[]')
    into v_rows from jsonb_array_elements(v->'rows') r where (r->>'employee_id')::bigint = any(v_emps);
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'الشهر', 'value', to_char(v_m, 'MM/YYYY') || case when (v->>'closed')::boolean then ' — مغلق (النسخة ' || (v->>'version') || ')' else ' — مفتوح' end, 'kind', 'text'),
      jsonb_build_object('label', 'العمولة الأساسية', 'value', (select sum((x->>'base')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money'),
      jsonb_build_object('label', 'المكافآت', 'value', (select sum((x->>'rewards')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money'),
      jsonb_build_object('label', 'التعديلات', 'value', (select sum((x->>'adjustments')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money'),
      jsonb_build_object('label', 'المستحق النهائي', 'value', (select sum((x->>'final')::numeric) from jsonb_array_elements(v_rows) x), 'kind', 'money')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'employee', 'label', 'الموظف', 'kind', 'text'), jsonb_build_object('key', 'role', 'label', 'الدور', 'kind', 'text'),
      jsonb_build_object('key', 'rule_name', 'label', 'القاعدة', 'kind', 'text'), jsonb_build_object('key', 'tier', 'label', 'الشريحة', 'kind', 'tier'),
      jsonb_build_object('key', 'base', 'label', 'الأساسية', 'kind', 'money'), jsonb_build_object('key', 'rewards', 'label', 'المكافآت', 'kind', 'money'),
      jsonb_build_object('key', 'adjustments', 'label', 'التعديلات', 'kind', 'money'), jsonb_build_object('key', 'final', 'label', 'المستحق', 'kind', 'money'),
      jsonb_build_object('key', 'status', 'label', 'الحالة', 'kind', 'text'), jsonb_build_object('key', 'warnings', 'label', 'تنبيهات المراجعة', 'kind', 'text')),
    'rows', v_rows,
    'definitions', jsonb_build_array(
      'القيم من كشف العمولات الرسمي بترتيب B024؛ الشهر المغلق يُقرأ من نسخة الإغلاق.',
      'التعديلات قرارات صرف معتمدة بسببها؛ تفاصيل كل موظف في كشف العمولات.'));
end $$;

-- B085 جودة البيانات والتعديلات
create or replace function app.rep_quality(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := (o->>'from')::date; v_to date := (o->>'to')::date; v_emps bigint[] := app.scope_emps(o, v_from, v_to);
  v_rows jsonb := '[]'; v_ready jsonb; v_sum jsonb; v_changes jsonb;
begin
  -- البنود: [{area, item, count, note}]
  v_rows := v_rows || jsonb_build_object('area', 'الرفع', 'item', 'دفعات مفتوحة لم تُعتمد',
              'count', (select count(*) from public.upload_batches where status = 'open'), 'note', 'تحتاج قرارًا في صفحة الرفع');
  v_rows := v_rows || jsonb_build_object('area', 'الرفع', 'item', 'سندات معلقة في دفعات مفتوحة',
              'count', (select count(*) from public.batch_items i join public.upload_batches b on b.id = i.batch_id
                         where b.status = 'open' and i.class = 'pending' and i.outcome is null
                           and (i.employee_id is null or i.employee_id = any(v_emps))), 'note', 'خطأ أو نقص يمنع الاعتماد');
  v_rows := v_rows || jsonb_build_object('area', 'المواقع', 'item', 'عملاء بلا موقع صالح',
              'count', (select count(*) from public.customers c where app.loc_state(c.lat, c.lng) <> 'ok'
                          and exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = any(v_emps))), 'note', 'مواقع العملاء');
  v_rows := v_rows || jsonb_build_object('area', 'المواقع', 'item', 'فواتير الفترة بلا موقع إصدار صالح',
              'count', (select count(*) from public.docs d where d.kind = 'invoice' and d.status = 'active' and d.doc_date between v_from and v_to
                          and d.employee_id = any(v_emps) and app.loc_state(d.lat, d.lng) <> 'ok'), 'note', 'تبقى في الإجماليات بلا نقطة');
  v_rows := v_rows || jsonb_build_object('area', 'المواقع', 'item', 'عملاء يحتاجون تحديد منطقة',
              'count', (select count(*) from app.customer_regions(v_to) r where r.state = 'conflict' and app.can_see_customer(r.customer_id)), 'note', 'المناطق والأسواق');
  v_rows := v_rows || jsonb_build_object('area', 'الحسابات', 'item', 'عملاء افتتاحيتهم غير معلومة',
              'count', case when app.has_perm('P08', 'view') then jsonb_array_length(public.receivables(v_to, '{}')->'unknown_openings') end, 'note', 'تعلق تصنيف المرتجعات');
  if app.has_perm('P14b', 'view') then
    v_ready := public.month_readiness(app.month_of(v_to));
    v_rows := v_rows || jsonb_build_object('area', 'الإعدادات', 'item', 'موظفون بإعداد ناقص يمنع إغلاق ' || to_char(app.month_of(v_to), 'MM/YYYY'),
                'count', (select count(*) from jsonb_array_elements(v_ready->'rows') x where (x->>'blocking')::boolean),
                'note', (select string_agg(distinct w->>'message', '، ') from jsonb_array_elements(v_ready->'rows') x, jsonb_array_elements(x->'warnings') w where (w->>'blocking')::boolean));
  end if;
  -- التعديلات اليدوية والنقل والحذف في الفترة على سندات ضمن النطاق
  select jsonb_build_object('manual', count(*) filter (where v.source = 'manual'), 'transfer', count(*) filter (where v.source = 'transfer'),
           'delete', count(*) filter (where v.source in ('delete', 'batch_delete')))
    into v_sum from public.doc_versions v join public.docs d on d.id = v.doc_id
   where v.source in ('manual', 'transfer', 'delete', 'batch_delete') and v.at::date between v_from and v_to and d.employee_id = any(v_emps);
  v_rows := v_rows || jsonb_build_object('area', 'التعديلات', 'item', 'تعديلات يدوية على السندات', 'count', v_sum->'manual', 'note', 'بسبب مسجل')
                   || jsonb_build_object('area', 'التعديلات', 'item', 'نقل سندات بين الموظفين', 'count', v_sum->'transfer', 'note', '')
                   || jsonb_build_object('area', 'التعديلات', 'item', 'حذف سندات', 'count', v_sum->'delete', 'note', '');
  select coalesce(jsonb_agg(jsonb_build_object('at', v.at, 'doc', app.kind_name(d.kind) || ' ' || d.doc_number, 'customer', d.customer_number,
           'source', case v.source when 'manual' then 'تعديل' when 'transfer' then 'نقل' else 'حذف' end, 'by_name', v.by_name, 'reason', v.reason)
           order by v.at desc), '[]')
    into v_changes from (select * from public.doc_versions v where v.source in ('manual', 'transfer', 'delete', 'batch_delete')
                          and v.at::date between v_from and v_to order by v.at desc limit 500) v
    join public.docs d on d.id = v.doc_id where d.employee_id = any(v_emps);
  return jsonb_build_object(
    'summary', jsonb_build_array(
      jsonb_build_object('label', 'بنود تحتاج معالجة', 'value', (select count(*) from jsonb_array_elements(v_rows) x where x->>'area' <> 'التعديلات' and coalesce((x->>'count')::int, 0) > 0), 'kind', 'count'),
      jsonb_build_object('label', 'تعديلات ونقل وحذف في الفترة', 'value', (v_sum->>'manual')::int + (v_sum->>'transfer')::int + (v_sum->>'delete')::int, 'kind', 'count')),
    'columns', jsonb_build_array(
      jsonb_build_object('key', 'area', 'label', 'المجال', 'kind', 'text'), jsonb_build_object('key', 'item', 'label', 'البند', 'kind', 'text'),
      jsonb_build_object('key', 'count', 'label', 'العدد', 'kind', 'count'), jsonb_build_object('key', 'note', 'label', 'ملاحظة', 'kind', 'text')),
    'rows', v_rows,
    'extra', jsonb_build_object('title', 'سجل التعديل والنقل والحذف في الفترة',
      'columns', jsonb_build_array(jsonb_build_object('key', 'at', 'label', 'الوقت', 'kind', 'datetime'), jsonb_build_object('key', 'doc', 'label', 'السند', 'kind', 'text'),
        jsonb_build_object('key', 'customer', 'label', 'العميل', 'kind', 'text'), jsonb_build_object('key', 'source', 'label', 'العملية', 'kind', 'text'),
        jsonb_build_object('key', 'by_name', 'label', 'بواسطة', 'kind', 'text'), jsonb_build_object('key', 'reason', 'label', 'السبب', 'kind', 'text')),
      'rows', v_changes),
    'definitions', jsonb_build_array(
      'كل بند يقرأ من مصدره الحالي؛ القيمة الفارغة تعني أن البند يتطلب صلاحية غير متاحة لك.',
      'التعديلات من سجل إصدارات السندات، وتُعرض أحدث 500 عملية.'));
end $$;

-- التقرير المخصص: أبعاد ومقاييس معتمدة وفلاتر وتجميع وترتيب (UX-003)
create or replace function app.rep_custom(o jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_dims text[] := app.rep_arr(o->'dims'); v_meas text[] := app.rep_arr(o->'measures'); v jsonb;
begin
  perform app.rep_lines(o, 'region' = any(v_dims), 'collections' = any(v_meas));
  v := app.rep_cube(v_dims, v_meas, nullif(o->>'sort', ''), coalesce((o->>'desc')::boolean, true));
  return v || jsonb_build_object(
    'summary', (select coalesce(jsonb_agg(jsonb_build_object('label', app.rep_label(m), 'value', v->'totals'->m, 'kind', app.rep_kind(m))), '[]')
                  from unnest(v_meas) m),
    'definitions', (select coalesce(jsonb_agg(app.rep_label(m) || ': ' || case m
        when 'sales_value' then 'المباشر + العروض لبنود الفواتير.' when 'net_value' then 'المبيعات − المرتجعات.'
        when 'return_ratio' then 'المرتجع ÷ المبيعات × 100.' when 'customers' then 'عملاء لهم بيع موجب.'
        when 'collections' then 'سندات التحصيل (بلا صنف).' when 'avg_invoice' then 'المبيعات ÷ عدد الفواتير.'
        else 'من السندات الفعالة ضمن الفلاتر ونطاقك.' end), '[]') from unnest(v_meas) m));
end $$;

-- ---------------------------------------------------------------------
-- نقطة التشغيل الموحدة: p_opts = {from, to, employees, supervisor_id, region_id, product_id, search, pay_type, group_by, dims, measures, sort, desc}
-- ---------------------------------------------------------------------
create or replace function public.report_run(p_report text, p_opts jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare o jsonb := coalesce(p_opts, '{}'); v jsonb;
begin
  perform app.require_perm('P18', 'view');
  if nullif(o->>'from', '') is null or nullif(o->>'to', '') is null or (o->>'to')::date < (o->>'from')::date then
    perform app.fail('bad_period', 'حدد فترة صحيحة');
  end if;
  v := case p_report
    when 'management'  then app.rep_management(o)
    when 'performance' then app.rep_performance(o)
    when 'sales'       then app.rep_sales(o)
    when 'collections' then app.rep_collections(o)
    when 'returns'     then app.rep_returns(o)
    when 'spread'      then app.rep_spread(o)
    when 'commissions' then app.rep_commissions(o)
    when 'quality'     then app.rep_quality(o)
    when 'custom'      then app.rep_custom(o)
  end;
  if v is null then perform app.fail('bad_report', 'تقرير غير معروف'); end if;
  return v || jsonb_build_object('report', p_report, 'from', o->>'from', 'to', o->>'to', 'generated_at', now(),
    'months', app.rep_months((o->>'from')::date, (o->>'to')::date),
    'last_upload', (select jsonb_object_agg(k, (select max(uploaded_at) from public.upload_batches where kind = k))
                      from unnest(array['invoice', 'return', 'collection']) k));
end $$;

-- ---------------------------------------------------------------------
-- أمان الصفوف
-- ---------------------------------------------------------------------
alter table public.saved_reports enable row level security;
create policy saved_reports_own on public.saved_reports for select to authenticated using (user_id = auth.uid());

select app.apply_grants();
