-- =====================================================================
-- ماستر — 0011: الأداء تحت الحمل (B093)
-- لا تغيير في أي قاعدة أو نتيجة؛ تحسينات تنفيذ فقط بعد قياس 100000 و500000 صف اصطناعي:
-- 1) فهارس لمسارات الأداء والكشوف الأكثر استعمالًا.
-- 2) حفظ نتيجة المقياس وأيام الموظف داخل الطلب الواحد، لأن الشرائح الأربع تعيد حساب المقياس نفسه.
-- 3) تحديث إحصاءات الجداول بعد رفع أو حذف دفعة كبيرة، حتى لا تُخطَّط الاستعلامات على إحصاءات قديمة.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) الفهارس
-- ---------------------------------------------------------------------
create index if not exists docs_emp_date_active on public.docs (employee_id, doc_date) where status = 'active';
create index if not exists docs_cust_date_active on public.docs (customer_id, doc_date) where status = 'active';
create index if not exists docs_kind_date_total on public.docs (kind, doc_date, total) where status = 'active';
create index if not exists doc_lines_product_doc on public.doc_lines (product_id, doc_id);
create index if not exists sup_assign_sup_emp on public.supervisor_assignments (supervisor_id, employee_id);

-- ---------------------------------------------------------------------
-- 2) الحفظ داخل الطلب الواحد
-- المفتاح يتضمن وقت بدء العبارة (statement_timestamp)، فلا تُستعمل قيمة محفوظة في طلب آخر،
-- ولا بعد أي كتابة لاحقة في طلب جديد.
-- ---------------------------------------------------------------------
create or replace function app.memo_table() returns void
language plpgsql as $$
begin
  if to_regclass('pg_temp._memo') is null then
    create temp table _memo (k text primary key, n numeric, j jsonb) on commit drop;
  end if;
end $$;

alter function app.metric_value(bigint, text, boolean, date, date, text, jsonb) rename to metric_value_raw;

create or replace function app.metric_value(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date,
                                            p_metric text, p_f jsonb) returns numeric
language plpgsql security definer set search_path = public, app as $$
declare
  v_k text := concat_ws('|', 'mv', statement_timestamp(), p_emp, p_role, p_personal, p_from, p_to, p_metric, coalesce(p_f, '{}')::text);
  v numeric; v_hit boolean;
begin
  perform app.memo_table();
  select true, n into v_hit, v from _memo where k = v_k;
  if v_hit then return v; end if;
  v := app.metric_value_raw(p_emp, p_role, p_personal, p_from, p_to, p_metric, p_f);
  insert into _memo (k, n) values (v_k, v) on conflict (k) do nothing;
  return v;
end $$;

alter function app.emp_days(bigint, date, date) rename to emp_days_raw;

create or replace function app.emp_days(p_emp bigint, p_month date, p_cutoff date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_k text := concat_ws('|', 'ed', statement_timestamp(), p_emp, p_month, p_cutoff);
  v jsonb;
begin
  perform app.memo_table();
  select j into v from _memo where k = v_k;
  if v is not null then return v; end if;
  v := app.emp_days_raw(p_emp, p_month, p_cutoff);
  insert into _memo (k, j) values (v_k, v) on conflict (k) do nothing;
  return v;
end $$;

alter function app.emp_region_geoms(bigint, date) rename to emp_region_geoms_raw;

-- حدود مناطق الموظف في يوم: تُحسب مرة لكل موظف ويوم داخل الطلب بدل كل سند
create or replace function app.emp_region_geoms(p_emp bigint, p_date date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_k text := concat_ws('|', 'rg', statement_timestamp(), p_emp, p_date);
  v jsonb;
begin
  perform app.memo_table();
  select j into v from _memo where k = v_k;
  if v is not null then return v; end if;
  v := app.emp_region_geoms_raw(p_emp, p_date);
  insert into _memo (k, j) values (v_k, v) on conflict (k) do nothing;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 2ب) حساب العمولة دون استدعاء لكل سطر: النسب دفعة واحدة، واستعلامات عمولة التحصيل
-- محصورة بموظفي النطاق ولا تعمل إن لم يُختر أي مندوب لعمولة التحصيل. النتيجة مطابقة للسابق.
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
  v_any_coll boolean := exists (select 1 from public.collection_reps);
  v_scope bigint[];
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
  -- موظفو النطاق: المندوب نفسه، أو كل من تبع المشرف يومًا؛ شرط ضروري يسبق فحص النطاق الدقيق بالتاريخ
  v_scope := case when v_role = 'supervisor'
                  then array(select distinct employee_id from public.supervisor_assignments where supervisor_id = p_emp)
                  else array[p_emp] end;
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
   where v_any_coll and a.alloc_date between v_m and v_e
     and d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم'
     and d.employee_id = any(v_scope)
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
  -- النسب دفعة واحدة بالترتيب نفسه لـapp.line_rate: لا شريحة = 0، ثم نسبة القاعدة للشريحة والدور،
  -- ثم نسبة الصنف السارية بتاريخ السند، وإلا «missing» (COMM-004، B018، B020)
  update _cm x set rate = y.rate, src = y.src
    from (with em as materialized (select q.m, app.emp_rule(p_emp, q.m) rule_id from (select distinct inv_month m from _cm where src is null) q)
          select c.ctid id,
                 case when c.tier is null or c.tier = 'NONE' then 0 else coalesce(rt.v, pr.rate) end rate,
                 case when c.tier is null or c.tier = 'NONE' then 'no_tier'
                      when rt.v is not null then 'rule'
                      when pr.rate is not null then 'product'
                      else 'missing' end src
            from _cm c
            join em on em.m = c.inv_month
            left join lateral (select case v_role when 'supervisor' then t.sup_rate else t.rep_rate end v
                                 from public.rule_tiers t
                                where t.rule_id = em.rule_id and t.tier = c.tier) rt on true
            left join lateral (select pcr.rate from public.product_commission_rates pcr
                                where pcr.product_id = c.product_id and pcr.role = v_role and pcr.tier = c.tier and pcr.effective_from <= c.doc_date
                                order by pcr.effective_from desc limit 1) pr on c.product_id is not null and rt.v is null
           where c.src is null) y
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
   where v_any_coll and d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم' and d.doc_date <= v_e
     and d.status = 'active' and d.employee_id = any(v_scope)
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

-- ---------------------------------------------------------------------
-- 2ج) تقدير واقعي لعدد سندات موظف في فترة، حتى يختار المخطط الفهرس لا المرور على كل السندات
-- ---------------------------------------------------------------------
alter function app.perf_docs(bigint, text, boolean, date, date) rows 300;

-- ---------------------------------------------------------------------
-- 2د) تقرير الانتشار (B083): آخر شراء بتجميع واحد
-- ---------------------------------------------------------------------
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
  -- آخر شراء لكل مشترٍ بتجميع واحد بدل البحث لكل صف (النتيجة نفسها وبالترتيب نفسه)
  create index if not exists _rl_customer_id on _rl (customer_id);
  select coalesce(jsonb_agg(t.r || jsonb_build_object('status', 'مشترٍ', 'last_date', ld.m) order by t.ord), '[]')
    into v_rows
    from jsonb_array_elements(v->'rows') with ordinality as t(r, ord)
    left join (select customer, max(doc_date) m from _rl group by customer) ld on ld.customer = t.r->>'customer';
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

-- ---------------------------------------------------------------------
-- 2هـ) بنود التقارير: كل الأعمدة والتسميات في إدراج واحد بدل ست تحديثات كاملة
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
  -- كل الأعمدة والتسميات في إدراج واحد؛ العائلة = رئيسي العميل بتاريخ السند (B055) وإلا العميل نفسه
  insert into _rl (kind, doc_id, doc_date, customer_id, employee_id, product_id, pay_type, value, net_sales, promo, qty, bonus,
                   employee, customer, family, product, month, day)
  select d.kind, d.id, d.doc_date, d.customer_id, d.employee_id, l.product_id, d.pay_type,
         coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0), coalesce(l.net_sales, 0), coalesce(l.net_promotions, 0),
         coalesce(l.quantity, 0), coalesce(l.bonus, 0),
         e.emp_number || ' — ' || e.name, c.customer_number || ' — ' || c.name,
         coalesce(m.customer_number || ' — ' || m.name, c.customer_number || ' — ' || c.name),
         p.code || ' — ' || p.name, to_char(d.doc_date, 'YYYY-MM'), d.doc_date
    from public.docs d
    join public.doc_lines l on l.doc_id = d.id
    join public.employees e on e.id = d.employee_id
    join public.customers c on c.id = d.customer_id
    left join public.customer_master_links ml on ml.customer_id = d.customer_id and daterange(ml.valid_from, ml.valid_to, '[]') @> d.doc_date
    left join public.customers m on m.id = ml.master_id
    left join public.products p on p.id = l.product_id
   where d.status = 'active' and d.kind in ('invoice', 'return') and d.kind = any(v_kinds)
     and d.doc_date between v_from and v_to and d.employee_id = any(v_emps)
     and (v_prod is null or l.product_id = v_prod)
     and (v_pay is null or d.kind <> 'invoice' or d.pay_type = v_pay)
     and (s = '' or c.customer_number = s or c.name ilike '%' || s || '%');
  if p_collections and v_prod is null and 'collection' = any(v_kinds) then
    insert into _rl (kind, doc_id, doc_date, customer_id, employee_id, value, net_sales, promo, qty, bonus,
                     employee, customer, family, product, month, day)
    select d.kind, d.id, d.doc_date, d.customer_id, d.employee_id, d.total, 0, 0, 0, 0,
           e.emp_number || ' — ' || e.name, c.customer_number || ' — ' || c.name,
           coalesce(m.customer_number || ' — ' || m.name, c.customer_number || ' — ' || c.name),
           '(تحصيل)', to_char(d.doc_date, 'YYYY-MM'), d.doc_date
      from public.docs d
      join public.employees e on e.id = d.employee_id
      join public.customers c on c.id = d.customer_id
      left join public.customer_master_links ml on ml.customer_id = d.customer_id and daterange(ml.valid_from, ml.valid_to, '[]') @> d.doc_date
      left join public.customers m on m.id = ml.master_id
     where d.status = 'active' and d.kind = 'collection' and d.doc_date between v_from and v_to and d.employee_id = any(v_emps)
       and (s = '' or c.customer_number = s or c.name ilike '%' || s || '%');
  end if;
  if p_need_region or v_region is not null then
    update _rl set region_id = app.customer_region_at(customer_id, doc_date);
    if v_region = 'none' then delete from _rl where region_id is not null;
    elsif v_region is not null then delete from _rl where region_id is distinct from v_region::bigint; end if;
    update _rl r set region = coalesce((select g.name from public.regions g where g.id = r.region_id), 'بلا منطقة');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2و) سياسات القراءة: الصلاحية والنطاق تُحسبان مرة لكل استعلام لا لكل صف (نمط Supabase الموصى به).
-- المعنى مطابق لـapp.can_see_employee: الإدارة والنطاق «الكل» يرون الجميع؛ وإلا الموظف نفسه،
-- و«الفريق» كل من تبع المشرف يومًا، و«المختارون» قائمتهم؛ والحساب المعطل لا يرى شيئًا.
-- ---------------------------------------------------------------------
create or replace function app.visible_emps() returns bigint[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  u public.app_users;
begin
  select * into u from public.app_users where id = auth.uid() and active;
  if not found then return '{}'; end if;
  return array(
    select u.employee_id where u.employee_id is not null
    union
    select s.employee_id from public.supervisor_assignments s
     where u.data_scope = 'team' and u.employee_id is not null and s.supervisor_id = u.employee_id
    union
    select e.employee_id from public.user_scope_employees e
     where u.data_scope = 'selected' and e.user_id = u.id);
end $$;

drop policy if exists docs_read on public.docs;
create policy docs_read on public.docs for select to authenticated
  using (((select app.has_perm('P06')) or (select app.has_perm('P05')))
         and ((select app.scope_is_all()) or employee_id = any((select app.visible_emps())::bigint[])));

drop policy if exists batch_items_read on public.batch_items;
create policy batch_items_read on public.batch_items for select to authenticated
  using ((select app.has_perm('P05'))
         and (employee_id is null or (select app.scope_is_all()) or employee_id = any((select app.visible_emps())::bigint[])));

drop policy if exists employees_read on public.employees;
create policy employees_read on public.employees for select to authenticated
  using (((select app.scope_is_all()) or id = any((select app.visible_emps())::bigint[]))
         and ((select app.has_perm('P03')) or (select app.has_perm('P10')) or (select app.has_perm('P13'))
              or (select app.has_perm('P06')) or (select app.has_perm('P14'))));

drop policy if exists customers_read on public.customers;
create policy customers_read on public.customers for select to authenticated
  using (((select app.has_perm('P02')) or (select app.has_perm('P06')) or (select app.has_perm('P07'))
          or (select app.has_perm('P08')) or (select app.has_perm('P16')))
         and ((select app.scope_is_all())
              or exists (select 1 from public.customer_employee_links l
                          where l.customer_id = customers.id and l.employee_id = any((select app.visible_emps())::bigint[]))));

-- ---------------------------------------------------------------------
-- 2ز) الذمم الحالية: فهارس التخصيص بمفتاح البند، وإجماليات الحسابات بتجميع واحد،
-- والنطاق مرة لكل استعلام. النتيجة مطابقة.
-- ---------------------------------------------------------------------
create index if not exists ledger_allocs_debt_key on app.ledger_allocs (year, debt_key, alloc_date);
create index if not exists ledger_allocs_credit_key on app.ledger_allocs (year, credit_key, alloc_date);

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
       and ((select app.scope_is_all()) or app.can_see_customer(i.account_id))
  ),
  credits as (
    select i.account_id, i.amount - coalesce((select sum(a.amount) from app.ledger_allocs a
                                               where a.year = y and a.credit_key = i.item_key and a.alloc_date <= p_date), 0) remaining
      from app.ledger_items i
     where i.year = y and i.side = 'C' and i.item_date <= p_date
       and (v_accts is null or i.account_id = any(v_accts))
       and ((select app.scope_is_all()) or app.can_see_customer(i.account_id))
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
       and (d.employee_id is null or (select app.scope_is_all()) or app.can_see_employee(d.employee_id))
  ),
  oi_sum as (
    select oi.account_id, sum(oi.remaining) open_total, coalesce(sum(oi.remaining) filter (where oi.overdue), 0) overdue_total,
           max(p_date - oi.item_date) filter (where oi.kind <> 'open_debit') oldest_age
      from open_items oi group by oi.account_id
  ),
  acct as (
    select b.account_id, b.balance, coalesce(s.open_total, 0) open_total, coalesce(s.overdue_total, 0) overdue_total, s.oldest_age
      from bal b left join oi_sum s on s.account_id = b.account_id
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

-- ---------------------------------------------------------------------
-- 2ح) سندات أداء الموظف
-- ---------------------------------------------------------------------
-- سندات أداء الموظف: فرعان منفصلان بدل شرط OR حتى يُستعمل فهرس سندات الموظف بالتاريخ.
-- النتيجة مطابقة للتعريف السابق (EMP-004، EMP-006، B001).
create or replace function app.perf_docs(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date)
returns table (doc_id bigint, part text)
language plpgsql stable security definer set search_path = public, app rows 300 as $$
#variable_conflict use_column
begin
  if p_role = 'rep' then
    return query
    select d.id, 'personal'::text
      from public.docs d
     where d.employee_id = p_emp and d.status = 'active' and d.doc_date between p_from and p_to
       and exists (select 1 from public.employment_periods ep where ep.employee_id = d.employee_id
                      and d.doc_date >= ep.start_date and (ep.end_date is null or d.doc_date <= ep.end_date));
  elsif p_role = 'supervisor' then
    return query
    select d.id, case when d.employee_id = p_emp then 'personal' else 'team' end
      from public.docs d
     where d.employee_id = any(array(select distinct s.employee_id from public.supervisor_assignments s where s.supervisor_id = p_emp)
                               || case when coalesce(p_personal, false) then array[p_emp] else '{}'::bigint[] end)
       and d.status = 'active' and d.doc_date between p_from and p_to
       and exists (select 1 from public.employment_periods ep where ep.employee_id = d.employee_id
                      and d.doc_date >= ep.start_date and (ep.end_date is null or d.doc_date <= ep.end_date))
       and (exists (select 1 from public.supervisor_assignments s
                     where s.employee_id = d.employee_id and s.supervisor_id = p_emp
                       and daterange(s.valid_from, s.valid_to, '[]') @> d.doc_date)
            or (coalesce(p_personal, false) and d.employee_id = p_emp));
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 2ط) الرفع الأول الكبير في قاعدة فارغة: إحصاءات الجداول تُحدَّث في بداية أي طلب اعتماد
-- إذا تغير الجدول منذ آخر تحليل أكثر من نصف حجمه، فلا يُخطَّط على إحصاءات جدول فارغ.
-- الاعتماد يُرسل على دفعات قصيرة، وكل دفعة معاملة مستقلة تُحدِّث عدادات التغيير.
-- ---------------------------------------------------------------------
create or replace function app.analyze_if_stale() returns void
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
begin
  for r in select relid, n_mod_since_analyze, n_live_tup from pg_stat_user_tables
            where relid in ('public.docs'::regclass, 'public.doc_lines'::regclass, 'public.doc_versions'::regclass,
                            'public.batch_items'::regclass, 'public.customer_employee_links'::regclass) loop
    if r.n_mod_since_analyze > 1000 and r.n_mod_since_analyze > r.n_live_tup * 0.5 then
      execute format('analyze %s', r.relid::regclass);
    end if;
  end loop;
end $$;

alter function public.upload_resolve(bigint, jsonb, text) rename to upload_resolve_core;
alter function public.upload_resolve_core(bigint, jsonb, text) set schema app;

create or replace function public.upload_resolve(p_batch bigint, p_decisions jsonb, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
begin
  perform app.analyze_if_stale();
  return app.upload_resolve_core(p_batch, p_decisions, p_code);
end $$;

-- ---------------------------------------------------------------------
-- 3) تحديث الإحصاءات بعد الدفعات الكبيرة
-- ---------------------------------------------------------------------
-- وتحديث الذمم للنطاق المتأثر عند انتهاء الدفعة (B090)، فلا يتحمل أول من يفتح صفحة زمن إعادة الحساب.
create or replace function app.analyze_after_batch() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status is distinct from old.status then
    if new.row_count >= 2000 then
      analyze public.docs;
      analyze public.doc_lines;
      analyze public.batch_items;
      analyze public.doc_versions;
      analyze public.customer_employee_links;
    end if;
    perform app.refresh_ledger();
    if new.row_count >= 2000 then
      analyze app.ledger_accounts;
      analyze app.ledger_items;
      analyze app.ledger_allocs;
    end if;
  end if;
  return new;
end $$;

-- إحصاءات التعريفات بعد استيرادها
create or replace function app.analyze_after_definitions() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.kind = 'customers' then analyze public.customers; analyze public.customer_master_links;
  elsif new.kind = 'employees' then analyze public.employees; analyze public.employment_periods; analyze public.supervisor_assignments;
  else analyze public.products; analyze public.product_prices; analyze public.product_commission_rates;
  end if;
  return new;
end $$;

drop trigger if exists definition_imports_analyze on public.definition_imports;
create trigger definition_imports_analyze after insert on public.definition_imports
  for each row execute function app.analyze_after_definitions();

drop trigger if exists upload_batches_analyze on public.upload_batches;
create trigger upload_batches_analyze after update of status on public.upload_batches
  for each row execute function app.analyze_after_batch();

-- ---------------------------------------------------------------------
-- 4) مهلة الطلب: Supabase يضبط افتراضيًا 8 ثوانٍ للمستخدم المسجل. الاعتماد يُرسل على دفعات قصيرة،
-- لكن عمليات مفردة مثل حذف دفعة شهر كامل أو رفع ملف كبير قد تتجاوزها؛ نرفعها إلى دقيقتين.
-- ---------------------------------------------------------------------
alter role authenticated set statement_timeout = '120s';
notify pgrst, 'reload config';

-- إتاحة دالة النطاق للسياسات
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
                                  'master_of', 'is_closed', 'visible_emps'])
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

select app.apply_grants();
