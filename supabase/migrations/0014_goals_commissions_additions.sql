-- =====================================================================
-- 0014 — إضافات الأهداف والعمولات (اعتماد 15/10/2026) وإصلاحات التدقيق (A3، A4، B1–B6)
-- GOAL-018/019، REWARD-003/004، COMM-009..012، PRD-009. يُشغَّل بعد 0013، ويمكن إعادة تشغيله دون أثر.
-- لا تتغير عمولة أو هدف لموظف إلا بما نصت عليه القرارات: ترتيب الشرائح، فلاتر هدف المشرف، منطقة التحصيل،
-- نسبة التنوع والتغطية دون تقريب قبل المقارنة، وتثبيت المستحق النهائي لثلاث منازل.
-- =====================================================================

-- ---------------------------------------------------------------------
-- الجداول والأعمدة
-- ---------------------------------------------------------------------
-- المكافآت: سريان لأكثر من شهر (REWARD-004) ومستويات تجاوز هدف A (REWARD-003)
alter table public.reward_plans add column if not exists to_month date;
alter table public.reward_plans add column if not exists over_levels jsonb;
alter table public.reward_plans drop constraint if exists reward_plans_cond_type_check;
alter table public.reward_plans add constraint reward_plans_cond_type_check check (cond_type in ('tier', 'metric', 'over_target'));
alter table public.reward_plans drop constraint if exists reward_plans_to_month_check;
alter table public.reward_plans add constraint reward_plans_to_month_check
  check (to_month is null or (extract(day from to_month) = 1 and to_month >= month));
create index if not exists reward_plans_range on public.reward_plans (month, to_month);

-- القاعدة التصاعدية (COMM-010): نسبة إضافية لكل خطوة مبيعات فوق حد، بسقف
alter table public.commission_rules add column if not exists prog_threshold numeric check (prog_threshold is null or prog_threshold >= 0);
alter table public.commission_rules add column if not exists prog_step numeric check (prog_step is null or prog_step > 0);
alter table public.commission_rules add column if not exists prog_add numeric check (prog_add is null or prog_add > 0);
alter table public.commission_rules add column if not exists prog_cap numeric check (prog_cap is null or prog_cap > 0);

-- استثناءات الموظف داخل القاعدة (COMM-009)
alter table public.rule_members add column if not exists min_sales numeric check (min_sales is null or min_sales >= 0);
alter table public.rule_members add column if not exists manual_rate numeric check (manual_rate is null or manual_rate >= 0);

-- مجموعات الأصناف العامة (PRD-009) ومستويات نسبة التنوع بحصص المجموعات (COMM-011)
create table if not exists public.product_groups (
  id          bigserial primary key,
  name        text not null,
  status      text not null default 'active' check (status in ('active', 'deleted')),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now()
);
create unique index if not exists product_groups_name on public.product_groups (lower(name)) where status = 'active';

create table if not exists public.product_group_members (
  group_id    bigint not null references public.product_groups(id) on delete cascade,
  product_id  bigint not null references public.products(id),
  primary key (group_id, product_id)
);
create index if not exists product_group_members_product on public.product_group_members (product_id);

-- مستوى: كل مجموعة مذكورة في min_shares {معرّف المجموعة: الحد الأدنى لحصتها من المبيعات المؤهلة %} يجب أن تبلغ حدها
create table if not exists public.rule_diversification_levels (
  id          bigserial primary key,
  rule_id     bigint not null references public.commission_rules(id) on delete cascade,
  sort        int not null,
  add_rate    numeric not null check (add_rate > 0),
  min_shares  jsonb not null
);
create index if not exists rule_diversification_rule on public.rule_diversification_levels (rule_id, sort);

alter table public.product_groups              enable row level security;
alter table public.product_group_members       enable row level security;
alter table public.rule_diversification_levels enable row level security;
drop policy if exists pgroups_read on public.product_groups;
create policy pgroups_read on public.product_groups for select to authenticated
  using (app.has_perm('P04') or app.has_perm('P11'));
drop policy if exists pgmembers_read on public.product_group_members;
create policy pgmembers_read on public.product_group_members for select to authenticated
  using (app.has_perm('P04') or app.has_perm('P11'));
drop policy if exists rdiv_read on public.rule_diversification_levels;
create policy rdiv_read on public.rule_diversification_levels for select to authenticated using (app.has_perm('P11'));

-- ---------------------------------------------------------------------
-- مساعدات
-- ---------------------------------------------------------------------
-- سريان المكافأة في شهر: من شهر البداية إلى شهر النهاية (أو الشهر نفسه) (REWARD-004)
create or replace function app.reward_in(p_from date, p_to date, p_month date) returns boolean
language sql immutable as $$ select p_from <= p_month and coalesce(p_to, p_from) >= p_month $$;

-- ترتيب الشرائح (GOAL-018): للمقياس نفسه بالفلاتر نفسها يكون هدف الشريحة الأعلى ترتيبًا أكبر من هدف ما دونها أو مساويًا
create or replace function app.check_tier_order(p_tiers jsonb, p_components jsonb) returns void
language plpgsql stable set search_path = public, app as $$
declare
  r record;
begin
  with t as (
    select upper(trim(x->>'tier')) tier, coalesce((x->>'sort')::int, o::int) sort
      from jsonb_array_elements(coalesce(p_tiers, '[]')) with ordinality a(x, o)),
  c as (
    select upper(nullif(trim(x->>'tier'), '')) tier, x->>'metric' metric, coalesce(x->'filters', '{}'::jsonb) f, nullif(x->>'target', '')::numeric target
      from jsonb_array_elements(coalesce(p_components, '[]')) x),
  j as (select c.metric, c.f, c.target, t.tier, t.sort from c join t on t.tier = c.tier where c.target is not null)
  select hi.tier hi_tier, lo.tier lo_tier, hi.metric, hi.target hi_t, lo.target lo_t into r
    from j hi join j lo on hi.metric = lo.metric and hi.f = lo.f and hi.sort < lo.sort and lo.target > hi.target
   order by hi.sort, lo.sort limit 1;
  if found then
    perform app.fail('tier_order', 'ترتيب الشرائح (GOAL-018): هدف الشريحة ' || r.lo_tier || ' (' || r.lo_t || ') أكبر من هدف الشريحة الأعلى '
      || r.hi_tier || ' (' || r.hi_t || ') لمقياس «' || app.metric_label(r.metric) || '»؛ يجب أن يكون هدف الأعلى أكبر أو مساويًا');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- مجموعات الأصناف العامة (PRD-009): تُعرَّف في صفحة المنتجات وتُستعمل في مكافأة التنويع
-- ---------------------------------------------------------------------
create or replace function public.save_product_group(p_id bigint, p_name text, p_products bigint[]) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint; v_before jsonb;
begin
  perform app.require_perm('P04', case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p_name), '') = '' then perform app.fail('required', 'اسم المجموعة مطلوب'); end if;
  if coalesce(cardinality(p_products), 0) = 0 then perform app.fail('required', 'اختر صنفًا واحدًا على الأقل'); end if;
  if exists (select 1 from public.product_groups where status = 'active' and lower(name) = lower(trim(p_name)) and id is distinct from p_id) then
    perform app.fail('duplicate', 'اسم المجموعة مستعمل');
  end if;
  if p_id is not null then
    select jsonb_build_object('name', g.name, 'products', (select coalesce(jsonb_agg(m.product_id order by m.product_id), '[]')
                                                              from public.product_group_members m where m.group_id = g.id))
      into v_before from public.product_groups g where g.id = p_id and g.status = 'active';
    if v_before is null then perform app.fail('not_found', 'المجموعة غير موجودة'); end if;
    update public.product_groups set name = trim(p_name), updated_at = now() where id = p_id;
    v_id := p_id;
    delete from public.product_group_members where group_id = v_id;
  else
    insert into public.product_groups (name, created_by) values (trim(p_name), auth.uid()) returning id into v_id;
  end if;
  insert into public.product_group_members (group_id, product_id) select v_id, x from (select distinct unnest(p_products) x) q;
  perform app.audit('product_groups', v_id::text, case when p_id is null then 'create' else 'update' end, v_before,
                    jsonb_build_object('name', trim(p_name), 'products', to_jsonb(p_products)));
  return v_id;
end $$;

create or replace function public.delete_product_group(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v public.product_groups;
begin
  perform app.require_perm('P04', 'edit');
  select * into v from public.product_groups where id = p_id and status = 'active';
  if not found then perform app.fail('not_found', 'المجموعة غير موجودة'); end if;
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  if exists (select 1 from public.rule_diversification_levels l where l.min_shares ? p_id::text) then
    perform app.fail('group_in_use', 'المجموعة مستعملة في قاعدة عمولة؛ أزلها من القاعدة أولًا');
  end if;
  update public.product_groups set status = 'deleted', updated_at = now() where id = p_id;
  perform app.audit('product_groups', p_id::text, 'delete', to_jsonb(v), null, p_reason);
end $$;

create or replace function public.product_groups_list() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.has_perm('P04') or app.has_perm('P11')) then perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
            'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name) order by p.code), '[]')
                           from public.product_group_members m join public.products p on p.id = m.product_id where m.group_id = g.id),
            'used', exists (select 1 from public.rule_diversification_levels l where l.min_shares ? g.id::text)) order by g.name)
            from public.product_groups g where g.status = 'active'), '[]');
end $$;

-- ---------------------------------------------------------------------
-- A4: التحصيل المسدد لفواتير موظف بأساس «مندوب الفاتورة» يحترم المنطقة (GOAL-017، 0.10.0):
-- منطقة العميل بموقعه المحفوظ (أو إسناده الصريح) في تاريخ الفاتورة
-- ---------------------------------------------------------------------
create or replace function app.paid_on_invoices(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date, p_region bigint)
returns numeric language plpgsql security definer set search_path = public, app as $$
declare
  v numeric;
begin
  perform app.refresh_ledger();
  select coalesce(sum(a.amount), 0) into v
    from app.ledger_allocs a
    join public.docs d on a.debt_key = 'doc:' || d.id
   where a.alloc_date between p_from and p_to
     and app.doc_in_scope(d, p_emp, p_role, p_personal)
     and (p_region is null or app.customer_region_at(d.customer_id, d.doc_date) = p_region);
  return v;
end $$;

-- ---------------------------------------------------------------------
-- المكافآت: سريان لأكثر من شهر (REWARD-004)، ومكافأة تجاوز هدف A الأصلي بمستويات (REWARD-003)
-- over_levels: [{kind: amount|percent, over, reward}]؛ المستوى المحقق الأعلى فقط يُصرف.
-- ---------------------------------------------------------------------
create or replace function public.save_reward(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_old public.reward_plans; v_id bigint; v_m date; v_to date; v_emps bigint[]; e bigint; l jsonb;
  v_cond text := p->>'cond_type'; v_vt text := p->>'value_type'; v_mode text := p->>'stack_mode'; v_group text := nullif(trim(p->>'group_name'), '');
  v_role text := coalesce(nullif(p->>'role', ''), 'all'); v_levels jsonb := p->'over_levels';
begin
  perform app.require_perm('P12', case when p_id is null then 'add' else 'edit' end);
  if p_id is not null then
    select * into v_old from public.reward_plans where id = p_id and status = 'active';
    if not found then perform app.fail('not_found', 'المكافأة غير موجودة'); end if;
  end if;
  v_m := coalesce(v_old.month, app.month_of((p->>'month')::date));
  v_to := case when nullif(p->>'to_month', '') is null then null else app.month_of((p->>'to_month')::date) end;
  if v_to is not null and v_to < v_m then perform app.fail('bad_range', 'شهر نهاية السريان قبل شهر البداية'); end if;
  if v_to = v_m then v_to := null; end if;
  v_emps := (select array_agg(x::bigint) from jsonb_array_elements_text(p->'employees') x where jsonb_typeof(p->'employees') = 'array');
  if v_m is null or coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'الشهر واسم المكافأة مطلوبان'); end if;
  if coalesce(v_mode, '') not in ('STACK', 'HIGHEST_ONLY') then perform app.fail('stack_required', 'حدد طريقة الجمع صراحة: جمع المستحقات أو الأعلى فقط (B023)'); end if;
  if coalesce(v_cond, '') not in ('tier', 'metric', 'over_target') then perform app.fail('required', 'نوع الشرط مطلوب'); end if;
  if v_cond = 'tier' and coalesce(jsonb_array_length(p->'tiers'), 0) = 0 then perform app.fail('required', 'اختر الشرائح المؤهلة'); end if;
  if v_cond = 'metric' and (app.metric_kind(p->>'metric') is null or nullif(p->>'metric_min', '') is null) then
    perform app.fail('required', 'المقياس وحده الأدنى مطلوبان');
  end if;
  if v_cond = 'over_target' then
    if v_role <> 'rep' then perform app.fail('over_role', 'مكافأة تجاوز هدف A للمندوبين فقط (REWARD-003)'); end if;
    if jsonb_typeof(v_levels) is distinct from 'array' or jsonb_array_length(v_levels) = 0 then
      perform app.fail('required', 'أدخل مستوى تجاوز واحدًا على الأقل');
    end if;
    for l in select * from jsonb_array_elements(v_levels) loop
      if coalesce(l->>'kind', '') not in ('amount', 'percent') or nullif(l->>'over', '') is null or (l->>'over')::numeric <= 0
         or nullif(l->>'reward', '') is null or (l->>'reward')::numeric <= 0 then
        perform app.fail('bad_level', 'كل مستوى يحتاج نوع التجاوز (مبلغ أو نسبة) وقيمته ومبلغ المكافأة، وكلها أكبر من صفر');
      end if;
    end loop;
    v_vt := 'fixed';
  else
    if v_vt = 'fixed' and nullif(p->>'amount', '') is null then perform app.fail('required', 'مبلغ المكافأة مطلوب'); end if;
    if v_vt = 'percent' and (nullif(p->>'pct', '') is null or coalesce(p->>'pct_base', '') not in ('eligible', 'base_commission')) then
      perform app.fail('base_required', 'المكافأة بالنسبة تحتاج نسبة وأساسًا صريحًا (B025)');
    end if;
    if coalesce(v_vt, '') not in ('fixed', 'percent') then perform app.fail('required', 'نوع القيمة مطلوب'); end if;
  end if;
  if v_group is not null and exists (select 1 from public.reward_plans where status = 'active' and group_name = v_group
                                        and stack_mode <> v_mode and id is distinct from p_id
                                        and daterange(month, coalesce(to_month, month), '[]') && daterange(v_m, coalesce(v_to, v_m), '[]')) then
    perform app.fail('group_mode', 'مجموعة التداخل «' || v_group || '» لها طريقة جمع أخرى؛ وحّد الطريقة');
  end if;
  if v_emps is null then
    if not app.scope_is_all() then perform app.fail('out_of_scope', 'مكافأة لكل الموظفين تحتاج نطاق «الكل»؛ اختر موظفين ضمن نطاقك'); end if;
  else
    foreach e in array v_emps loop perform app.require_employee_scope(e); end loop;
  end if;
  perform app.guard_dates(array(select g::date from generate_series(v_m, coalesce(v_to, v_m), interval '1 month') g), p_code);
  if p_id is null then
    insert into public.reward_plans (month, to_month, name, role, employees, cond_type, tiers, metric, metric_min, filters, value_type, amount, pct, pct_base,
                                     over_levels, group_name, stack_mode, note, created_by)
    values (v_m, v_to, trim(p->>'name'), v_role, v_emps, v_cond,
            case when v_cond = 'tier' then (select array_agg(upper(x)) from jsonb_array_elements_text(coalesce(p->'tiers', '[]')) x) end,
            case when v_cond = 'metric' then p->>'metric' end, case when v_cond = 'metric' then nullif(p->>'metric_min', '')::numeric end,
            coalesce(p->'filters', '{}'), v_vt, case when v_cond <> 'over_target' then nullif(p->>'amount', '')::numeric end,
            case when v_cond <> 'over_target' then nullif(p->>'pct', '')::numeric end,
            case when v_vt = 'percent' and v_cond <> 'over_target' then p->>'pct_base' end,
            case when v_cond = 'over_target' then v_levels end, v_group, v_mode, p->>'note', auth.uid())
    returning id into v_id;
  else
    update public.reward_plans set to_month = v_to, name = trim(p->>'name'), role = v_role, employees = v_emps, cond_type = v_cond,
           tiers = case when v_cond = 'tier' then (select array_agg(upper(x)) from jsonb_array_elements_text(coalesce(p->'tiers', '[]')) x) end,
           metric = case when v_cond = 'metric' then p->>'metric' end,
           metric_min = case when v_cond = 'metric' then nullif(p->>'metric_min', '')::numeric end,
           filters = coalesce(p->'filters', '{}'), value_type = v_vt,
           amount = case when v_cond <> 'over_target' then nullif(p->>'amount', '')::numeric end,
           pct = case when v_cond <> 'over_target' then nullif(p->>'pct', '')::numeric end,
           pct_base = case when v_vt = 'percent' and v_cond <> 'over_target' then p->>'pct_base' end,
           over_levels = case when v_cond = 'over_target' then v_levels end,
           group_name = v_group, stack_mode = v_mode, note = p->>'note', updated_at = now()
     where id = p_id;
    v_id := p_id;
  end if;
  perform app.audit('reward_plans', v_id::text, case when p_id is null then 'create' else 'update' end, to_jsonb(v_old),
                    (select to_jsonb(x) from public.reward_plans x where id = v_id));
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- جدول إدخال جماعي لأهداف الموظفين (GOAL-019): هيكل واحد للشهر (شرائح ومكوّنات) يُعمَّم على الكل أو البعض،
-- والأرقام تُدخل لكل موظف في جدول. كل صف يمر بقواعد الحفظ نفسها (الصلاحية، النطاق، الشهر المقفل، ترتيب الشرائح).
-- p_structure: {partial_mode, sup_mode, tiers:[{tier, logic}], components:[{key, tier, metric, filters, affected, label}]}
-- p_rows: [{employee_id, targets: {key: رقم أو فارغ}}]. المعاينة (p_commit = false) لا تحفظ شيئًا.
-- ---------------------------------------------------------------------
create or replace function public.bulk_save_goal_plans(p_month date, p_role text, p_structure jsonb, p_rows jsonb, p_commit boolean,
                                                       p_reason text default null, p_code text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); r jsonb; v_emp bigint; v_plan public.goal_plans; v_payload jsonb; v_comps jsonb;
  v_out jsonb := '[]'; v_err text; v_state text; v_before jsonb; v_after jsonb;
  v_new int := 0; v_changed int := 0; v_same int := 0; v_failed int := 0;
begin
  if p_role not in ('rep', 'supervisor') then perform app.fail('bad_role', 'الدور غير معروف'); end if;
  if p_commit and coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحفظ مطلوب (GOAL-001)'); end if;
  if jsonb_typeof(p_structure->'tiers') is distinct from 'array' or jsonb_typeof(p_structure->'components') is distinct from 'array' then
    perform app.fail('required', 'حدد شرائح الهيكل ومكوّناته');
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_emp := (r->>'employee_id')::bigint;
    v_err := null; v_state := null; v_before := null; v_after := null;
    select * into v_plan from public.goal_plans where month = v_m and employee_id = v_emp;
    v_before := case when v_plan.id is not null then app.plan_json(v_plan.id)->'components' end;
    v_comps := coalesce((select jsonb_agg(jsonb_build_object('tier', c->>'tier', 'metric', c->>'metric', 'filters', coalesce(c->'filters', '{}'),
                                          'affected', coalesce(c->'affected', 'true'::jsonb), 'label', c->'label', 'sort', ord,
                                          'target', (r->'targets')->(c->>'key')) order by ord)
                           from jsonb_array_elements(p_structure->'components') with ordinality t(c, ord)), '[]');
    v_payload := jsonb_build_object('month', v_m, 'employee_id', v_emp, 'role', p_role,
                   'partial_mode', coalesce(p_structure->>'partial_mode', 'proportional'), 'sup_mode', coalesce(p_structure->>'sup_mode', 'team_sum'),
                   'tiers', p_structure->'tiers', 'components', v_comps);
    if v_plan.id is not null then
      v_payload := v_payload || jsonb_build_object('include_personal', v_plan.include_personal, 'note', v_plan.note);
    end if;
    begin
      perform public.save_goal_plan(v_plan.id, v_payload, coalesce(nullif(trim(p_reason), ''), 'معاينة'), p_code);
      v_after := (select app.plan_json(id)->'components' from public.goal_plans where month = v_m and employee_id = v_emp);
      v_state := case when v_before is null then 'new' when v_before = v_after then 'same' else 'changed' end;
      -- المعاينة، وما لا تغيير فيه، يتراجع حفظه فلا ضجيج في سجل العمليات
      if not p_commit or v_state = 'same' then raise exception using errcode = 'P0002', message = 'preview'; end if;
    exception
      when sqlstate 'P0002' then null;
      when others then v_err := sqlerrm; v_failed := v_failed + 1; v_state := 'error';
    end;
    if v_state = 'new' then v_new := v_new + 1; elsif v_state = 'changed' then v_changed := v_changed + 1; elsif v_state = 'same' then v_same := v_same + 1; end if;
    v_out := v_out || jsonb_build_object('employee_id', v_emp, 'name', (select name from public.employees where id = v_emp),
                                         'state', v_state, 'error', v_err, 'before', v_before, 'after', v_after);
  end loop;
  if p_commit and v_failed > 0 then
    perform app.fail('bulk_failed', 'تعذر حفظ ' || v_failed || ' صفًا ولم يُحفظ شيء؛ عاين الجدول وصحح أخطاء الصفوف');
  end if;
  return jsonb_build_object('month', v_m, 'committed', p_commit, 'rows', v_out,
                            'counts', jsonb_build_object('new', v_new, 'changed', v_changed, 'same', v_same, 'error', v_failed));
end $$;

-- ---------------------------------------------------------------------
-- إلغاء كل قرارات صرف الشهر المفتوح دفعة واحدة (COMM-012، B021): بسبب ومعاينة، وضمن نطاق المستخدم
-- ---------------------------------------------------------------------
create or replace function public.cancel_month_adjustments(p_month date, p_reason text, p_commit boolean) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); r record; v_total int := 0; v_skipped int := 0; v_per jsonb := '{}'; v_names jsonb := '{}';
  v_self bigint := (select employee_id from public.app_users where id = auth.uid());
begin
  perform app.require_perm('P14', 'edit');
  if app.is_closed(v_m) then
    perform app.fail('month_closed', 'الشهر مغلق؛ أعد فتحه برمز الإدارة السري أولًا ثم ألغِ القرارات (COMM-012، PERIOD-002)');
  end if;
  if p_commit and coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الإلغاء مطلوب'); end if;
  for r in select a.*, e.name from public.commission_adjustments a join public.employees e on e.id = a.employee_id
            where a.month = v_m and a.status = 'active' and app.can_see_employee(a.employee_id) order by e.name, a.id loop
    if not app.is_admin() and r.employee_id = v_self then v_skipped := v_skipped + 1; continue; end if;
    v_total := v_total + 1;
    v_per := jsonb_set(v_per, array[r.employee_id::text], to_jsonb(coalesce((v_per->>r.employee_id::text)::int, 0) + 1));
    v_names := jsonb_set(v_names, array[r.employee_id::text], to_jsonb(r.name));
    if p_commit then
      update public.commission_adjustments set status = 'cancelled', cancelled_at = now(), cancel_reason = trim(p_reason) where id = r.id;
      perform app.audit('commission_adjustments', r.id::text, 'cancel', to_jsonb(r) - 'name', null, 'إلغاء جماعي: ' || trim(p_reason));
    end if;
  end loop;
  return jsonb_build_object('month', v_m, 'committed', p_commit, 'count', v_total, 'skipped_self', v_skipped,
    'employees', coalesce((select jsonb_agg(jsonb_build_object('employee_id', k::bigint, 'name', v_names->k, 'count', (v_per->>k)::int) order by v_names->>k)
                             from jsonb_object_keys(v_per) k), '[]'));
end $$;

-- ---------------------------------------------------------------------
-- الدوال المعدّلة (نصوصها كاملة): ترتيب الشرائح، فلاتر هدف المشرف، منطقة التحصيل، المكافآت، قواعد العمولة
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.write_plan_parts(p_plan bigint, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  t jsonb; c jsonb; i int := 0;
begin
  perform app.check_tier_order(p->'tiers', p->'components');
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
end $function$;

CREATE OR REPLACE FUNCTION public.save_goal_template(p_id bigint, p_name text, p_role text, p_data jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_id bigint; v_before jsonb;
begin
  perform app.require_perm(app.plan_role_page(coalesce(p_role, 'rep')), case when p_id is null then 'add' else 'edit' end);
  perform app.check_tier_order(p_data->'tiers', p_data->'components');
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
end $function$;

CREATE OR REPLACE FUNCTION app.team_target_f(p_sup bigint, p_month date, p_tier text, p_metric text, p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
       and filters = coalesce(p_filters, '{}'::jsonb)
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
      v_parts := v_parts || jsonb_build_object('employee_id', r.employee_id, 'name', case when app.can_see_employee(r.employee_id) then (select name from public.employees where id = r.employee_id) end,
          'hidden', not app.can_see_employee(r.employee_id),
        'final', v_final, 'days', v_total, 'under', v_under, 'share', v_final * v_under / v_total);
    else
      v_parts := v_parts || jsonb_build_object('employee_id', r.employee_id, 'name', case when app.can_see_employee(r.employee_id) then (select name from public.employees where id = r.employee_id) end,
          'hidden', not app.can_see_employee(r.employee_id),
        'final', v_final, 'days', 0, 'under', 0, 'share', 0);
    end if;
  end loop;
  return jsonb_build_object('sum', case when app.metric_kind(p_metric) = 'count' and v_sum > 0 then ceil(v_sum) else v_sum end,
                            'parts', v_parts, 'count', jsonb_array_length(v_parts));
end $function$;

CREATE OR REPLACE FUNCTION app.plan_eval(p_plan bigint, p_cutoff date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
      v_team := app.team_target_f(pl.employee_id, pl.month, c.tier, c.metric, c.filters);
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
end $function$;

CREATE OR REPLACE FUNCTION app.metric_value_raw(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date, p_metric text, p_f jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_products bigint[] := (select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(p_f->'products', '[]')) x);
  v_sale text := coalesce(p_f->>'sale_type', 'all');
  v_pay text := coalesce(p_f->>'pay_type', 'all');
  v_n int := coalesce(nullif(p_f->>'days', '')::int, 90);
  v_region bigint := nullif(p_f->>'region_id', '')::bigint;
  v_regions bigint[];
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
     and (v_products is null or l.product_id = any(v_products))
     and (v_region is null or app.customer_region_at(d.customer_id, d.doc_date) = v_region);

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
      v := app.paid_on_invoices(p_emp, p_role, p_personal, p_from, p_to, v_region);
    else
      select coalesce(sum(d.total), 0) into v
        from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s join public.docs d on d.id = s.doc_id
       where d.kind = 'collection'
         and (v_region is null or app.customer_region_at(d.customer_id, d.doc_date) = v_region);
    end if;
    if p_metric = 'collection_ratio' then
      -- تحصيل الشهر ÷ مبيعات الذمم في الشهر نفسه × 100 (GOAL-015)
      select coalesce(sum(d.total), 0) into v_den
        from app.perf_docs(p_emp, p_role, p_personal, p_from, p_to) s join public.docs d on d.id = s.doc_id
       where d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم'
         and (v_region is null or app.customer_region_at(d.customer_id, d.doc_date) = v_region);
      v := case when v_den > 0 then v / v_den * 100 end;
    end if;
  when 'variety_ratio' then
    select count(distinct product_id) into v from _mv_lines where kind = 'invoice' and value > 0 and product_id is not null;
    -- القائمة أصناف المكوّن المختارة عند تعريفه (طلب محمد 13/10/2026)؛ بلا قائمة لا قاعدة مقارنة
    v_den := cardinality(v_products);
    v := case when v_den > 0 then (v / v_den * 100) end;
  when 'coverage' then
    -- التغطية (اعتماد 13/10/2026): عملاء الموظف في منطقته ممن اشتروا ببيع موجب ÷ كل عملاء الموظف في منطقته × 100.
    -- المنطقة المختارة في المكوّن، وإلا مناطق الموظف المسندة إليه (أو لفريقه) في نهاية المدى؛ العميل بموقعه المحفوظ.
    v_regions := case when v_region is not null then array[v_region] else app.emp_regions(p_emp, p_role, p_to) end;
    select count(*), count(*) filter (where exists (select 1 from _mv_lines m where m.customer_id = c.id and m.kind = 'invoice' and m.value > 0))
      into v_den, v
      from public.customers c
     where app.customer_region_at(c.id, p_to) = any(v_regions)
       and exists (select 1 from public.customer_employee_links l where l.customer_id = c.id
                    and (l.employee_id = p_emp
                         or (p_role = 'supervisor' and exists (select 1 from public.supervisor_assignments s
                               where s.employee_id = l.employee_id and s.supervisor_id = p_emp
                                 and daterange(s.valid_from, s.valid_to, '[]') && daterange(p_from, p_to, '[]')))));
    v := case when v_den > 0 then (v / v_den * 100) end;
  else
    perform app.fail('bad_metric', 'مقياس غير معروف: ' || coalesce(p_metric, ''));
  end case;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.rewards_list(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_m date := app.month_of(p_month); e bigint; v_c jsonb; v_q jsonb := '{}'; x jsonb;
begin
  perform app.require_perm('P12', 'view');
  for e in select id from public.employees where app.can_see_employee(id) loop
    continue when not exists (select 1 from public.reward_plans rp where app.reward_in(rp.month, rp.to_month, v_m) and rp.status = 'active'
                                and (rp.employees is null or e = any(rp.employees)));
    continue when not exists (select 1 from public.employment_periods ep where ep.employee_id = e
                                and daterange(ep.start_date, ep.end_date, '[]') && daterange(v_m, app.month_end(v_m), '[]'));
    v_c := case when app.is_closed(v_m) then (select s.statement from public.month_snapshots s where s.month = v_m and s.employee_id = e and s.version = app.month_version(v_m))
                else app.commission_calc(e, v_m) end;
    for x in select * from jsonb_array_elements(coalesce(v_c->'rewards', '[]')) loop
      v_q := jsonb_set(v_q, array[x->>'id'], coalesce(v_q->(x->>'id'), '[]') || jsonb_build_object('employee_id', e,
               'name', (select name from public.employees where id = e), 'amount', x->'amount', 'reason', x->'reason', 'counted', x->'counted'));
    end loop;
  end loop;
  return jsonb_build_object('month', v_m, 'closed', app.is_closed(v_m),
    'plans', coalesce((select jsonb_agg(to_jsonb(rp) || jsonb_build_object('qualified', coalesce(v_q->(rp.id::text), '[]'),
                         'employee_names', (select jsonb_agg(name order by name) from public.employees where id = any(rp.employees) and app.can_see_employee(id)),
                           'hidden_employees', (select count(*) from public.employees where id = any(rp.employees) and not app.can_see_employee(id))) order by rp.name)
                         from public.reward_plans rp where app.reward_in(rp.month, rp.to_month, v_m) and rp.status = 'active'), '[]'));
end $function$;

CREATE OR REPLACE FUNCTION public.close_month(p_month date, p_note text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
            'rewards', (select jsonb_agg(to_jsonb(r)) from public.reward_plans r where app.reward_in(r.month, r.to_month, v_m) and r.status = 'active'),
            'collection_reps', (select jsonb_agg(to_jsonb(c)) from public.collection_reps c
                                 where v_m >= c.from_month and (c.to_month is null or v_m <= c.to_month)),
            'personal_rates', (select jsonb_agg(to_jsonb(x)) from public.supervisor_personal_rates x where month = v_m),
            'debt_age_days', app.debt_age_at(app.month_end(v_m)), 'work_weekdays', to_jsonb(app.work_weekdays())),
          v_r->'totals');
  insert into public.months (month, status, version, closed_at, closed_by) values (v_m, 'closed', v_ver, now(), auth.uid())
  on conflict (month) do update set status = 'closed', version = v_ver, closed_at = now(), closed_by = auth.uid();
  perform app.audit('months', v_m::text, 'close', null, jsonb_build_object('version', v_ver, 'totals', v_r->'totals'), p_note);
  return v_ver;
end $function$;

CREATE OR REPLACE FUNCTION app.rule_json(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select to_jsonb(r) || jsonb_build_object(
    'tiers', coalesce((select jsonb_agg(jsonb_build_object('tier', t.tier, 'sort', t.sort, 'rep_rate', t.rep_rate, 'sup_rate', t.sup_rate) order by t.sort)
                         from public.rule_tiers t where t.rule_id = r.id), '[]'),
    'members', coalesce((select jsonb_agg(jsonb_build_object('employee_id', m.employee_id, 'name', e.name, 'emp_number', e.emp_number, 'min_sales', m.min_sales, 'manual_rate', m.manual_rate) order by e.name)
                           from public.rule_members m join public.employees e on e.id = m.employee_id where m.rule_id = r.id), '[]'),
    'diversification', coalesce((select jsonb_agg(jsonb_build_object('add_rate', d.add_rate, 'shares', d.min_shares) order by d.sort)
                                   from public.rule_diversification_levels d where d.rule_id = r.id), '[]'))
    from public.commission_rules r where r.id = p_id
$function$;

CREATE OR REPLACE FUNCTION public.commission_month(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_m date := app.month_of(p_month);
begin
  perform app.require_perm('P11', 'view');
  return jsonb_build_object(
    'month', v_m, 'closed', app.is_closed(v_m),
    'rules', coalesce((select jsonb_agg(j || jsonb_build_object('members', app.visible_members(j->'members'),
                           'hidden_members', jsonb_array_length(j->'members') - jsonb_array_length(app.visible_members(j->'members'))) order by r.name)
                           from public.commission_rules r cross join lateral app.rule_json(r.id) j where r.month = v_m), '[]'),
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
                         'personal_sales', (select coalesce(sum(case d.kind when 'invoice' then 1 else -1 end * (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0))), 0)
                                              from public.docs d join public.doc_lines l on l.doc_id = d.id
                                             where d.employee_id = e.id and d.status = 'active' and d.kind in ('invoice', 'return')
                                               and d.doc_date between v_m and app.month_end(v_m)
                                               and exists (select 1 from public.employment_periods ep where ep.employee_id = e.id
                                                            and d.doc_date between ep.start_date and coalesce(ep.end_date, date '9999-12-31')))) order by e.name)
                                  from public.employees e left join public.supervisor_personal_rates pr on pr.employee_id = e.id and pr.month = v_m
                                 where app.can_see_employee(e.id) and app.emp_role(e.id, v_m) = 'supervisor'), '[]'),
    'review', (select to_jsonb(rv) from public.rate_reviews rv where rv.month = v_m),
    'review_due', v_m = app.month_of(app.today()) and not exists (select 1 from public.rate_reviews where month = v_m),
    'default_tiers', to_jsonb(app.default_tiers()));
end $function$;

CREATE OR REPLACE FUNCTION public.save_commission_rule(p_id bigint, p jsonb, p_reason text DEFAULT NULL::text, p_code text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_old public.commission_rules; v_before jsonb; v_id bigint; v_m date; t jsonb; i int := 0; m bigint; mj jsonb; lv jsonb; lv_i int := 0; g text; v_max_rep numeric; v_max_sup numeric; v_max_add numeric; v_cap numeric;
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
  -- القاعدة التصاعدية (COMM-010): الخطوة والزيادة والسقف معًا أو لا شيء
  if (nullif(p->>'prog_step', '') is null) <> (nullif(p->>'prog_add', '') is null) or (nullif(p->>'prog_step', '') is null) <> (nullif(p->>'prog_cap', '') is null) then
    perform app.fail('prog_incomplete', 'القاعدة التصاعدية تحتاج الخطوة والنسبة الإضافية والسقف معًا');
  end if;
  perform app.guard_dates(array[v_m], p_code);
  if p_id is null then
    insert into public.commission_rules (month, name, note, created_by, prog_threshold, prog_step, prog_add, prog_cap)
    values (v_m, trim(p->>'name'), p->>'note', auth.uid(), nullif(p->>'prog_threshold', '')::numeric, nullif(p->>'prog_step', '')::numeric,
            nullif(p->>'prog_add', '')::numeric, nullif(p->>'prog_cap', '')::numeric) returning id into v_id;
  else
    update public.commission_rules set name = trim(p->>'name'), note = p->>'note', updated_at = now(),
           prog_threshold = nullif(p->>'prog_threshold', '')::numeric, prog_step = nullif(p->>'prog_step', '')::numeric,
           prog_add = nullif(p->>'prog_add', '')::numeric, prog_cap = nullif(p->>'prog_cap', '')::numeric where id = p_id;
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
  for mj in select x from jsonb_array_elements(coalesce(p->'members', '[]')) x loop
    m := case when jsonb_typeof(mj) = 'object' then (mj->>'employee_id')::bigint else (mj #>> '{}')::bigint end;
    perform app.require_employee_scope(m);
    if exists (select 1 from public.rule_members where month = v_m and employee_id = m) then
      perform app.fail('duplicate_member', 'الموظف ' || (select name from public.employees where id = m) || ' مشمول بقاعدة أخرى في هذا الشهر');
    end if;
    insert into public.rule_members (rule_id, month, employee_id, min_sales, manual_rate)
    values (v_id, v_m, m, case when jsonb_typeof(mj) = 'object' then nullif(mj->>'min_sales', '')::numeric end,
            case when jsonb_typeof(mj) = 'object' then nullif(mj->>'manual_rate', '')::numeric end);
  end loop;
  -- مستويات التنويع بحصص مجموعات الأصناف (COMM-011): مجموعات عامة لا تتقاطع أصنافها، والنسب الكلية لا تتجاوز الحد
  delete from public.rule_diversification_levels where rule_id = v_id;
  for lv in select x from jsonb_array_elements(coalesce(p->'diversification', '[]')) x loop
    lv_i := lv_i + 1;
    if nullif(lv->>'add_rate', '') is null or (lv->>'add_rate')::numeric <= 0 then perform app.fail('bad_level', 'نسبة إضافة مستوى التنويع أكبر من صفر'); end if;
    if jsonb_typeof(lv->'shares') is distinct from 'object' or lv->'shares' = '{}'::jsonb then
      perform app.fail('bad_level', 'مستوى التنويع يحتاج مجموعة واحدة على الأقل بحد أدنى لحصتها');
    end if;
    for g in select k from jsonb_object_keys(lv->'shares') k loop
      if not exists (select 1 from public.product_groups where id = g::bigint and status = 'active') then perform app.fail('bad_group', 'مجموعة أصناف غير معرفة في مستوى التنويع'); end if;
      if (lv->'shares'->>g)::numeric <= 0 or (lv->'shares'->>g)::numeric > 100 then perform app.fail('bad_level', 'حصة المجموعة بين 0 و100%'); end if;
    end loop;
    insert into public.rule_diversification_levels (rule_id, sort, add_rate, min_shares) values (v_id, lv_i, (lv->>'add_rate')::numeric, lv->'shares');
  end loop;
  if exists (select 1 from (select pm.product_id, count(distinct kg.k) n
                              from public.rule_diversification_levels dl
                              cross join lateral jsonb_object_keys(dl.min_shares) kg(k)
                              join public.product_group_members pm on pm.group_id = kg.k::bigint
                             where dl.rule_id = v_id group by pm.product_id) q where n > 1) then
    perform app.fail('groups_overlap', 'صنف واحد لا يكون في مجموعتين من مجموعات التنويع في القاعدة نفسها');
  end if;
  select max(rep_rate), max(sup_rate) into v_max_rep, v_max_sup from public.rule_tiers where rule_id = v_id;
  select coalesce(max(add_rate), 0) into v_max_add from public.rule_diversification_levels where rule_id = v_id;
  v_cap := coalesce(nullif(p->>'prog_cap', '')::numeric, 0);
  if coalesce(v_max_rep, 0) + v_cap + v_max_add > 100 or coalesce(v_max_sup, 0) + v_cap + v_max_add > 1000 then
    perform app.fail('rate_over_limit', 'مجموع أعلى نسبة شريحة والسقف التصاعدي وأعلى نسبة تنويع يتجاوز الحد (100% للمندوب، 1000‰ للمشرف)');
  end if;
  perform app.audit('commission_rules', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.rule_json(v_id), p_reason);
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.copy_commission_rules(p_from date, p_to date, p_code text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  r record; n int := 0;
begin
  perform app.require_perm('P11', 'add');
  if exists (select 1 from public.commission_rules where month = app.month_of(p_to)) then
    perform app.fail('not_empty', 'للشهر الهدف قواعد؛ النسخ لشهر بلا قواعد فقط');
  end if;
  for r in select id from public.commission_rules where month = app.month_of(p_from) loop
    perform public.save_commission_rule(null, app.rule_json(r.id) || jsonb_build_object('month', app.month_of(p_to),
      'members', coalesce((select jsonb_agg(x) from jsonb_array_elements(app.rule_json(r.id)->'members') x
                            where exists (select 1 from public.employment_periods ep where ep.employee_id = (x->>'employee_id')::bigint
                                            and daterange(ep.start_date, ep.end_date, '[]') && daterange(app.month_of(p_to), app.month_end(p_to), '[]'))), '[]')),
      'نسخ من ' || to_char(p_from, 'FMMM/YYYY'), p_code);
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.preview_commission_rule(p_id bigint, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  v_m date := coalesce((select month from public.commission_rules where id = p_id), app.month_of((p->>'month')::date));
  v_emps bigint[]; v_before jsonb := '{}'; v_after jsonb := '{}'; e bigint; v_out jsonb := '[]'; v_c jsonb;
begin
  perform app.require_perm('P11', 'view');
  v_emps := array(select distinct x from (
              select case when jsonb_typeof(x) = 'object' then (x->>'employee_id')::bigint else (x #>> '{}')::bigint end x from jsonb_array_elements(coalesce(p->'members', '[]')) x
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
end $function$;

-- حساب العمولة: الاستثناءات والتصاعدية والتنويع ومكافأة تجاوز A وتثبيت المستحق ثلاث منازل وتحذير غياب قاعدة شهر الفاتورة
CREATE OR REPLACE FUNCTION app.commission_calc(p_emp bigint, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
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
  v_mem public.rule_members; v_rr public.commission_rules; v_prog numeric := 0; v_div numeric := 0; v_div_level int;
  v_below boolean := false; v_elig0 numeric := 0; v_shares jsonb := '{}'; lv record; gp record; v_lvl_ok boolean;
  v_oc jsonb; v_lvl jsonb; v_ov_amt numeric; v_ov_reason text; v_over numeric;
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

  -- المسدد من ذمم السنة السابقة المرحّلة افتتاحيًا (A1، COMM-008)
  insert into _cm (source, part, doc_id, doc_kind, doc_number, doc_date, customer_id, rep_id, product_id, value, paid, inv_month)
  select 'paid', case when d.employee_id = p_emp then 'personal' else 'team' end, d.id, d.kind, d.doc_number, d.doc_date,
         d.customer_id, d.employee_id, l.product_id,
         a.amount * (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)) / nullif(t.v, 0), a.amount, app.month_of(d.doc_date)
    from app.carry_allocs(v_m, v_e) a
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
      from (select a0.debt_key, a0.debt_account, a0.amount, a0.alloc_date from app.ledger_allocs a0
             where a0.debt_key like 'open:%' and a0.alloc_date between v_m and v_e and not app.is_carry(a0.debt_account, a0.alloc_date)
            union all
            select c.debt_key, c.debt_account, c.amount, c.alloc_date from app.carry_allocs(v_m, v_e) c where c.debt_key like 'open:%') a
     where true
       and app.opening_rep_at(a.debt_account, a.alloc_date) = p_emp;
  end if;

  -- الشريحة: لشهر الفاتورة في المسدد، ولشهر الحركة في غيره
  update _cm set tier = v_tier where inv_month = v_m;
  for r in select distinct inv_month from _cm where tier is null loop
    update _cm set tier = app.eff_tier(p_emp, r.inv_month) where inv_month = r.inv_month and tier is null;
  end loop;

  -- استثناءات الموظف داخل القاعدة والقاعدة التصاعدية ومكافأة التنويع (COMM-009..011): تُحسب من مبيعات الشهر المؤهلة
  select * into v_mem from public.rule_members where month = v_m and employee_id = p_emp;
  select * into v_rr from public.commission_rules where id = v_rule;
  select coalesce(sum(value), 0) into v_elig0 from _cm;
  if v_rr.prog_step is not null and v_rr.prog_add is not null and v_rr.prog_cap is not null and v_elig0 > coalesce(v_rr.prog_threshold, 0) then
    v_prog := least(v_rr.prog_cap, floor((v_elig0 - coalesce(v_rr.prog_threshold, 0)) / v_rr.prog_step) * v_rr.prog_add);
  end if;
  if v_rule is not null then
    select coalesce(jsonb_object_agg(q.gid::text, case when v_elig0 > 0 then round(q.sales / v_elig0 * 100, 2) else 0 end), '{}') into v_shares
      from (select k.gid, coalesce((select sum(c.value) from _cm c where c.product_id in
                                      (select product_id from public.product_group_members where group_id = k.gid)), 0) sales
              from (select distinct kg.k::bigint gid from public.rule_diversification_levels dl
                      cross join lateral jsonb_object_keys(dl.min_shares) kg(k) where dl.rule_id = v_rule) k) q;
    if v_elig0 > 0 then
      for lv in select * from public.rule_diversification_levels where rule_id = v_rule order by sort loop
        v_lvl_ok := true;
        for gp in select k.key::text gid, k.value::numeric mn from jsonb_each_text(lv.min_shares) k loop
          v_lvl_ok := v_lvl_ok and coalesce((v_shares->>gp.gid)::numeric, 0) >= gp.mn;
        end loop;
        if v_lvl_ok then v_div := lv.add_rate; v_div_level := lv.sort; exit; end if;
      end loop;
    end if;
  end if;

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
  -- نسبة يدوية للموظف في القاعدة تحل محل نسبة الشريحة لسطور شهر القاعدة (COMM-009)؛ للمشرف على حصة الفريق فقط
  if v_mem.manual_rate is not null then
    update _cm set rate = v_mem.manual_rate, src = 'manual' where inv_month = v_m and (v_role = 'rep' or part = 'team') and src is distinct from 'pending';
  end if;
  -- النسبة التصاعدية ونسبة التنويع تضافان إلى نسبة الشريحة من القاعدة (COMM-010، COMM-011)
  if v_prog + v_div > 0 then
    update _cm set rate = rate + v_prog + v_div where src = 'rule' and inv_month = v_m and rate is not null;
  end if;
  update _cm set commission = value * rate / case unit when 'pct' then 100 else 1000 end where rate is not null;

  -- غياب القاعدة إعداد ناقص لا يحسب بنسب الأصناف تلقائيًا (COMM-007)
  if v_rule is null then
    v_warn := v_warn || jsonb_build_object('code', 'no_rule', 'blocking', true,
      'message', 'إعداد ناقص: الموظف غير مشمول بقاعدة عمولة لهذا الشهر');
  end if;
  if exists (select 1 from _cm where source = 'paid' and app.emp_rule(p_emp, inv_month) is null) then
    v_warn := v_warn || jsonb_build_object('code', 'no_rule_paid_month', 'blocking', true,
      'months', (select jsonb_agg(distinct m) from (select inv_month m from _cm where source = 'paid' and app.emp_rule(p_emp, inv_month) is null) x),
      'message', 'إعداد ناقص: لا قاعدة عمولة لشهر فاتورة مسدَّدة في هذا الشهر؛ لا تحتسب بنسب الأصناف تلقائيًا (COMM-007)');
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
  v_below := v_mem.min_sales is not null and v_eligible < v_mem.min_sales;
  if v_below then
    v_warn := v_warn || jsonb_build_object('code', 'below_min_sales', 'blocking', false,
      'message', 'المبيعات المؤهلة دون الحد الأدنى للموظف في القاعدة (' || v_mem.min_sales || ')؛ العمولة الأساسية صفر وتبقى المكافآت والقرارات (COMM-009)');
  end if;

  -- المكافآت: الشروط ومجموعات التداخل STACK / HIGHEST_ONLY (B023)
  for r in select * from public.reward_plans rp where app.reward_in(rp.month, rp.to_month, v_m) and rp.status = 'active'
             and (rp.role = 'all' or rp.role = v_role) and (rp.employees is null or p_emp = any(rp.employees)) order by id loop
    v_ov_amt := null; v_ov_reason := null;
    if r.cond_type = 'tier' then
      v_ok := v_tier = any(coalesce(r.tiers, '{}'));
    elsif r.cond_type = 'over_target' then
      -- تجاوز هدف A الأصلي بصافي المبيعات (REWARD-003): أعلى مستوى محقق فقط
      v_ok := false;
      select x into v_oc from jsonb_array_elements(coalesce(v_eval->'components', '[]')) x
       where x->>'tier' = 'A' and x->>'metric' = 'net_sales' and x->>'original' is not null order by (x->>'sort')::int limit 1;
      if v_oc is null or coalesce((v_oc->>'original')::numeric, 0) <= 0 then
        v_warn := v_warn || jsonb_build_object('code', 'over_target_no_a', 'blocking', false,
          'message', 'مكافأة «' || r.name || '» تحتاج هدفًا أصليًا لصافي المبيعات في الشريحة A في خطة الموظف');
      else
        v_over := coalesce((v_oc->>'actual')::numeric, 0) - (v_oc->>'original')::numeric;
        select l into v_lvl from jsonb_array_elements(r.over_levels) l
         where v_over >= case l->>'kind' when 'amount' then (l->>'over')::numeric else (v_oc->>'original')::numeric * (l->>'over')::numeric / 100 end
         order by case l->>'kind' when 'amount' then (l->>'over')::numeric else (v_oc->>'original')::numeric * (l->>'over')::numeric / 100 end desc,
                  (l->>'reward')::numeric desc limit 1;
        if v_lvl is not null then
          v_ok := true; v_ov_amt := (v_lvl->>'reward')::numeric;
          v_ov_reason := 'تجاوز هدف A الأصلي (' || round((v_oc->>'original')::numeric, 3) || ') بـ ' || round(v_over, 3)
                         || ' ← مستوى ' || case v_lvl->>'kind' when 'amount' then (v_lvl->>'over') || ' مبلغًا' else (v_lvl->>'over') || '%' end;
        end if;
      end if;
    else
      v_val := app.metric_value(p_emp, v_role, coalesce(v_plan.include_personal, false), v_m, v_e, r.metric, r.filters);
      v_ok := v_val is not null and v_val >= r.metric_min;
    end if;
    continue when not v_ok;
    v_val := case when r.cond_type = 'over_target' then v_ov_amt when r.value_type = 'fixed' then r.amount
               else r.pct / 100 * case r.pct_base when 'eligible' then v_eligible else coalesce(v_base, 0) end end;
    v_rewards := v_rewards || jsonb_build_object('id', r.id, 'name', r.name, 'group', r.group_name, 'mode', r.stack_mode,
      'amount', v_val, 'value_type', r.value_type, 'pct', r.pct, 'pct_base', r.pct_base,
      'reason', case r.cond_type when 'tier' then 'الشريحة المحققة ' || v_tier when 'over_target' then v_ov_reason
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
  if v_zero_base or v_below then v_base := 0; end if;
  v_final := round(case when v_zero_all then 0 when v_base is null then null else v_base + v_rew_total + v_adj_total end, 3);

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
    left join lateral (select coalesce((select sum(a.amount) from app.ledger_allocs a where a.debt_key = 'doc:' || d.id and a.alloc_date <= v_e), 0)
                               + coalesce((select sum(c.amount) from app.carry_allocs(make_date(extract(year from v_e)::int, 1, 1), v_e) c
                                            where c.debt_key = 'doc:' || d.id), 0) v) pd on true
   where v_any_coll and d.kind = 'invoice' and d.pay_type = 'فاتورة ذمم' and d.doc_date <= v_e
     and d.status = 'active' and d.employee_id = any(v_scope)
     and app.doc_in_scope(d, p_emp, v_role, false) and (v_role = 'rep' or d.employee_id <> p_emp)
     and app.is_collection_rep(d.employee_id, d.doc_date)
     and d.doc_date + coalesce((select cu.grace_days from public.customers cu where cu.id = d.customer_id), 30) + app.debt_age_at(v_e)::int > v_e
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
    'rule_tiers', (select coalesce(jsonb_agg(t.tier order by t.sort), '[]') from public.rule_tiers t where t.rule_id = v_rule),
    'extras', jsonb_build_object('prog', v_prog, 'div', v_div, 'div_level', v_div_level, 'shares', v_shares,
                                 'manual_rate', v_mem.manual_rate, 'min_sales', v_mem.min_sales, 'below_min', v_below),
    'goals', case when v_eval is not null then jsonb_build_object('achieved', v_eval->'achieved', 'components', v_eval->'components', 'days', v_eval->'days') end);
end $function$;

select app.apply_grants();
notify pgrst, 'reload schema';
