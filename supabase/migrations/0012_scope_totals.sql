-- =====================================================================
-- 0012 — نطاق البيانات في الإغلاق والمكافآت والقواعد، ومنع تكرار مبيعات الفريق في الإجماليات
-- تدقيق 15/10/2026: A5 (B072، AUTH-002) وA6 (COMM-003). لا تتغير أي عمولة أو هدف لموظف.
-- =====================================================================

-- ---------------------------------------------------------------------
-- جاهزية الإغلاق: موظفو نطاق المستخدم فقط (B072)، والمؤهلة دون تكرار مبيعات الفريق (COMM-003):
-- مبيعات المندوب تظهر في صفه وفي حصة فريق مشرفه، فالإجمالي = مجموع المبيعات الشخصية لكل صف.
-- ---------------------------------------------------------------------
create or replace function public.month_readiness(p_month date) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); e bigint; v jsonb; v_rows jsonb := '[]';
  v_tot jsonb := jsonb_build_object('eligible', 0, 'base', 0, 'rewards', 0, 'adjustments', 0, 'final', 0);
begin
  perform app.require_perm('P14b', 'view');
  perform app.refresh_ledger();
  for e in select x from app.month_employees(v_m) x join public.employees em on em.id = x
            where app.can_see_employee(x) order by em.name loop
    v := app.commission_calc(e, v_m);
    v_rows := v_rows || jsonb_build_object('employee_id', e, 'name', (select name from public.employees where id = e), 'role', v->'role',
      'tier', v->'tier_effective', 'final', v->'final', 'blocking', v->'blocking',
      'warnings', v->'warnings');
    v_tot := jsonb_build_object('eligible', (v_tot->>'eligible')::numeric + coalesce((v->>'personal_eligible')::numeric, 0),
                                'base', (v_tot->>'base')::numeric + coalesce((v->>'base_commission')::numeric, 0),
                                'rewards', (v_tot->>'rewards')::numeric + coalesce((v->>'rewards_total')::numeric, 0),
                                'adjustments', (v_tot->>'adjustments')::numeric + coalesce((v->>'adjustments_total')::numeric, 0),
                                'final', (v_tot->>'final')::numeric + coalesce((v->>'final')::numeric, 0));
  end loop;
  return jsonb_build_object('month', v_m, 'closed', app.is_closed(v_m), 'rows', v_rows, 'totals', v_tot,
    'blocking', exists (select 1 from jsonb_array_elements(v_rows) x where (x->>'blocking')::boolean));
end $$;

-- ---------------------------------------------------------------------
-- نظرة الأشهر: إجماليات النسخ للمستخدم ذي النطاق الكامل فقط، وعدد الخطط ضمن نطاقه (B072)
-- ---------------------------------------------------------------------
create or replace function public.months_overview() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_first date; v_all boolean := app.scope_is_all();
begin
  perform app.require_perm('P14b', 'view');
  v_first := least(coalesce((select min(month) from public.goal_plans), app.month_of(app.today())),
                   coalesce((select app.month_of(min(doc_date)) from public.docs where status = 'active'), app.month_of(app.today())),
                   coalesce((select min(month) from public.months), app.month_of(app.today())));
  return coalesce((select jsonb_agg(jsonb_build_object('month', g::date, 'status', coalesce(m.status, 'open'), 'version', coalesce(m.version, 0),
            'closed_at', m.closed_at, 'reopened_at', m.reopened_at, 'reopen_reason', m.reopen_reason,
            'plans', (select count(*) from public.goal_plans p where p.month = g::date and app.can_see_employee(p.employee_id)),
            'rules', (select count(*) from public.commission_rules r where r.month = g::date),
            'versions', (select coalesce(jsonb_agg(jsonb_build_object('version', v.version, 'closed_at', v.closed_at, 'closed_name', v.closed_name,
                                                                      'note', v.note, 'reopened_at', v.reopened_at, 'reopen_reason', v.reopen_reason,
                                                                      'totals', case when v_all then v.totals end) order by v.version), '[]')
                           from public.month_versions v where v.month = g::date)) order by g desc)
    from generate_series(v_first, app.month_of(app.today()), interval '1 month') g
    left join public.months m on m.month = g::date), '[]');
end $$;

-- ---------------------------------------------------------------------
-- القراءة المباشرة للجداول:
-- نسخ الإغلاق تحمل أهداف كل الموظفين ونسب المشرفين وإجماليات الشركة ← للنطاق الكامل فقط.
-- كشوف الشهر المغلق ← بصلاحية كشف العمولات لا بطاقة الأداء وحدها (AUTH-002: بطاقة فقط = لا وصول للعمولات)؛
-- البطاقة تقرأ نسختها عبر دوالها المحمية.
-- ---------------------------------------------------------------------
drop policy if exists mversions_read on public.month_versions;
create policy mversions_read on public.month_versions for select to authenticated
  using (app.has_perm('P14b') and (select app.scope_is_all()));

drop policy if exists snapshots_read on public.month_snapshots;
create policy snapshots_read on public.month_snapshots for select to authenticated
  using (app.has_perm('P14') and app.can_see_employee(employee_id));

-- ---------------------------------------------------------------------
-- أسماء خارج النطاق لا تظهر: أعضاء القواعد، والمشمولون بالمكافآت، وتفاصيل فريق المشرف (B072).
-- العدد يبقى ظاهرًا حتى لا يُفهم أن القاعدة أو المكافأة بلا أعضاء.
-- ---------------------------------------------------------------------
create or replace function app.visible_members(p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(p, '[]')) x
                    where app.can_see_employee((x->>'employee_id')::bigint)), '[]')
$$;

do $$
declare v_src text;
begin
  -- commission_month: يُستبدل مصدر أعضاء القاعدة بالمرئيين فقط مع عدد المخفيين
  select pg_get_functiondef('public.commission_month(date)'::regprocedure) into v_src;
  v_src := replace(v_src,
    $q$'rules', coalesce((select jsonb_agg(app.rule_json(r.id) order by r.name) from public.commission_rules r where r.month = v_m), '[]'),$q$,
    $q$'rules', coalesce((select jsonb_agg(j || jsonb_build_object('members', app.visible_members(j->'members'),
                         'hidden_members', jsonb_array_length(j->'members') - jsonb_array_length(app.visible_members(j->'members'))) order by r.name)
                         from public.commission_rules r cross join lateral app.rule_json(r.id) j where r.month = v_m), '[]'),$q$);
  if v_src not like '%hidden_members%' then raise exception 'commission_month: نص الاستبدال غير مطابق'; end if;
  execute v_src;

  -- rewards_list: أسماء المشمولين ضمن النطاق وعدد من خارجه
  select pg_get_functiondef('public.rewards_list(date)'::regprocedure) into v_src;
  v_src := replace(v_src,
    $q$'employee_names', (select jsonb_agg(name) from public.employees where id = any(rp.employees))$q$,
    $q$'employee_names', (select jsonb_agg(name order by name) from public.employees where id = any(rp.employees) and app.can_see_employee(id)),
                         'hidden_employees', (select count(*) from public.employees where id = any(rp.employees) and not app.can_see_employee(id))$q$);
  if v_src not like '%hidden_employees%' then raise exception 'rewards_list: نص الاستبدال غير مطابق'; end if;
  execute v_src;

  -- team_target: حصة المندوب خارج النطاق تبقى في المجموع دون اسمه ورقمه
  select pg_get_functiondef('app.team_target(bigint, date, text, text)'::regprocedure) into v_src;
  v_src := replace(v_src,
    $q$'name', (select name from public.employees where id = r.employee_id),$q$,
    $q$'name', case when app.can_see_employee(r.employee_id) then (select name from public.employees where id = r.employee_id) end,
        'hidden', not app.can_see_employee(r.employee_id),$q$);
  if v_src not like '%''hidden''%' then raise exception 'team_target: نص الاستبدال غير مطابق'; end if;
  execute v_src;
end $$;

select app.apply_grants();
notify pgrst, 'reload schema';
