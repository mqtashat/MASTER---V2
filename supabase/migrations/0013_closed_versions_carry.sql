-- =====================================================================
-- 0013 — قراءة الشهر المغلق من نسخته الحالية، وعمولة تحصيل الذمم المرحّلة بين السنتين
-- تدقيق 15/10/2026: A2 (PERIOD-001، B076، B077) وA1 (COMM-008 البندان 5 و6).
-- =====================================================================

-- ---------------------------------------------------------------------
-- A2: الشهر المغلق يُقرأ من نسخته الحالية (رقم النسخة في months)، لا من آخر نسخة لكل موظف.
-- موظف بلا نسخة في الإصدار الحالي لا يُحسب حيًّا؛ يظهر في فروقات الشهر (B077).
-- ---------------------------------------------------------------------
create or replace function app.month_version(p_month date) returns int
language sql stable security definer set search_path = public, app as $$
  select version from public.months where month = app.month_of(p_month) and status = 'closed'
$$;

-- أسماء مندوبي فريق المشرف في تقييم محفوظ تُخفى عن مشاهد لا يراهم (B072، تكملة 0012)
create or replace function app.mask_eval(e jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when e is null or coalesce(jsonb_typeof(e->'components'), '') <> 'array' then e
    else jsonb_set(e, '{components}', coalesce((select jsonb_agg(
           case when jsonb_typeof(c->'team'->'parts') = 'array' then
             jsonb_set(c, '{team,parts}', coalesce((select jsonb_agg(
               case when app.can_see_employee((p->>'employee_id')::bigint) then p
                    else p || '{"name": null, "hidden": true}' end order by o)
               from jsonb_array_elements(c->'team'->'parts') with ordinality t(p, o)), '[]'))
           else c end order by n)
         from jsonb_array_elements(e->'components') with ordinality s(c, n)), '[]'))
  end
$$;

do $$
declare v_src text; v_new text;
begin
  -- الشريحة المعتمدة للشهر المغلق
  select pg_get_functiondef('app.eff_tier(bigint, date)'::regprocedure) into v_src;
  v_new := replace(v_src, 'order by s.version desc limit 1', 'and s.version = app.month_version(p_month)');
  if v_new = v_src then raise exception 'eff_tier: نص غير مطابق'; end if;
  execute v_new;

  -- قائمة الأهداف
  select pg_get_functiondef('public.goals_list(date, text, jsonb)'::regprocedure) into v_src;
  v_new := replace(v_src,
    $q$(select s.card->'eval' from public.month_snapshots s where s.month = v_m and s.employee_id = r.id order by s.version desc limit 1)$q$,
    $q$(select app.mask_eval(s.card->'eval') from public.month_snapshots s where s.month = v_m and s.employee_id = r.id and s.version = app.month_version(v_m))$q$);
  if v_new = v_src then raise exception 'goals_list: نص غير مطابق'; end if;
  execute v_new;

  -- المكافآت ومستوفوها
  select pg_get_functiondef('public.rewards_list(date)'::regprocedure) into v_src;
  v_new := replace(v_src, 'and s.employee_id = e order by version desc limit 1', 'and s.employee_id = e and s.version = app.month_version(v_m)');
  if v_new = v_src then raise exception 'rewards_list: نص غير مطابق'; end if;
  execute v_new;

  -- بطاقات الأداء
  select pg_get_functiondef('public.performance_cards(date, jsonb)'::regprocedure) into v_src;
  v_new := replace(v_src,
    $q$select s.card into v_card from public.month_snapshots s where s.month = v_m and s.employee_id = r.id order by s.version desc limit 1;$q$,
    $q$select s.card into v_card from public.month_snapshots s where s.month = v_m and s.employee_id = r.id and s.version = app.month_version(v_m);$q$);
  v_new := replace(v_new, $q$v_card := v_card || '{"snapshot": true}';$q$,
    $q$v_card := jsonb_set(v_card || '{"snapshot": true}', '{eval}', coalesce(app.mask_eval(v_card->'eval'), 'null'));$q$);
  if v_new not like '%app.month_version(v_m);%' or v_new not like '%mask_eval%' then raise exception 'performance_cards: نص غير مطابق'; end if;
  execute v_new;

  -- ملخص العمولات
  select pg_get_functiondef('public.commission_summary(date)'::regprocedure) into v_src;
  v_new := replace(v_src, 'and s.employee_id = e order by s.version desc limit 1', 'and s.employee_id = e and s.version = app.month_version(v_m)');
  if v_new = v_src then raise exception 'commission_summary: نص غير مطابق'; end if;
  execute v_new;
end $$;

-- كشف الموظف: النسخة المطلوبة أو النسخة الحالية للشهر المغلق؛ لا حساب حي لشهر مغلق
create or replace function public.commission_statement(p_employee bigint, p_month date, p_version int default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month); v_s public.month_snapshots; v jsonb; v_ver int;
begin
  perform app.require_perm('P14', 'view');
  perform app.require_employee_scope(p_employee);
  v_ver := coalesce(p_version, app.month_version(v_m));
  if v_ver is not null then
    select * into v_s from public.month_snapshots where month = v_m and employee_id = p_employee and version = v_ver;
    if found then
      return v_s.statement || jsonb_build_object('snapshot', true, 'version', v_s.version, 'snapshot_at', v_s.created_at,
        'goals', app.mask_eval(v_s.statement->'goals'),
        'employee', (select jsonb_build_object('id', id, 'name', name, 'emp_number', emp_number) from public.employees where id = p_employee),
        'closed', app.is_closed(v_m),
        'versions', (select jsonb_agg(version order by version) from public.month_snapshots where month = v_m and employee_id = p_employee));
    end if;
    if p_version is not null then perform app.fail('not_found', 'لا توجد نسخة محفوظة بهذا الرقم'); end if;
    perform app.fail('not_in_version', 'الموظف غير مشمول في النسخة المعتمدة رقم ' || v_ver
      || ' لهذا الشهر؛ أي حركة له بعد الإغلاق تظهر في فروقات الشهر في صفحة الأشهر والإغلاق');
  end if;
  v := app.commission_calc(p_employee, v_m);
  return v || jsonb_build_object('snapshot', false, 'closed', app.is_closed(v_m),
    'employee', (select jsonb_build_object('id', id, 'name', name, 'emp_number', emp_number) from public.employees where id = p_employee),
    'versions', (select jsonb_agg(version order by version) from public.month_snapshots where month = v_m and employee_id = p_employee));
end $$;

-- الفروقات: مقابل النسخة الحالية للشهر، وتشمل من له حساب حي وليس في النسخة (B077)
create or replace function public.month_diff(p_month date, p_version int default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_m date := app.month_of(p_month);
  v_ver int := coalesce(p_version, (select version from public.months where month = v_m and version > 0),
                        (select max(version) from public.month_snapshots where month = v_m));
  r record; v jsonb; v_out jsonb := '[]'; e bigint;
begin
  perform app.require_perm('P14b', 'view');
  if v_ver is null then return jsonb_build_object('month', v_m, 'version', null, 'rows', '[]'); end if;
  for r in select s.*, em.name from public.month_snapshots s join public.employees em on em.id = s.employee_id
            where s.month = v_m and s.version = v_ver and app.can_see_employee(s.employee_id) order by em.name loop
    v := app.commission_calc(r.employee_id, v_m);
    if (v->>'final') is distinct from (r.statement->>'final') or (v->>'eligible')::numeric is distinct from (r.statement->>'eligible')::numeric
       or (v->>'tier_effective') is distinct from (r.statement->>'tier_effective') then
      v_out := v_out || jsonb_build_object('employee_id', r.employee_id, 'name', r.name,
        'saved', jsonb_build_object('tier', r.statement->'tier_effective', 'eligible', r.statement->'eligible', 'base', r.statement->'base_commission', 'final', r.statement->'final'),
        'live', jsonb_build_object('tier', v->'tier_effective', 'eligible', v->'eligible', 'base', v->'base_commission', 'final', v->'final'));
    end if;
  end loop;
  for e in select x from app.month_employees(v_m) x join public.employees em on em.id = x
            where app.can_see_employee(x)
              and not exists (select 1 from public.month_snapshots s where s.month = v_m and s.version = v_ver and s.employee_id = x)
            order by em.name loop
    v := app.commission_calc(e, v_m);
    v_out := v_out || jsonb_build_object('employee_id', e, 'name', (select name from public.employees where id = e), 'saved', null,
      'live', jsonb_build_object('tier', v->'tier_effective', 'eligible', v->'eligible', 'base', v->'base_commission', 'final', v->'final'));
  end loop;
  return jsonb_build_object('month', v_m, 'version', v_ver, 'closed', app.is_closed(v_m), 'rows', v_out);
end $$;

-- ---------------------------------------------------------------------
-- A1: الذمة غير المسددة آخر السنة تُرحَّل إلى السنة التالية رصيدًا افتتاحيًا (source = carry)، فيُسدَّد
-- الافتتاحي في محرك الحسابات. يُعاد هنا ربط كل تسديد للافتتاحي المرحّل ببنود السنة السابقة المفتوحة
-- عند إقفالها، بترتيب سدادها نفسه (الافتتاحي ثم الأقدم، FIN-004، COL-008)، فتستحق فاتورة مندوب التحصيل
-- عمولتها في شهر سدادها بشريحة شهرها (COMM-008 البندان 5 و6). ما يقع على افتتاحي سابق أو يزيد على البنود
-- المفتوحة يبقى تحصيل افتتاحي (البند 9). مستوى ترحيل واحد: ذمة أقدم من سنة تتجاوز عمر الدين أصلًا.
-- لا يتغير الكشف ولا الذمم ولا الرصيد.
-- ---------------------------------------------------------------------
create index if not exists ledger_allocs_open_date on app.ledger_allocs (alloc_date) where debt_key like 'open:%';

create or replace function app.is_carry(p_customer bigint, p_date date) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from public.opening_balances o where o.customer_id = p_customer
                    and o.year = extract(year from p_date)::int and o.source = 'carry')
$$;

create or replace function app.carry_allocs_raw(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a record; p record; v_out jsonb := '[]'; v_lo numeric; v_hi numeric; v_cum numeric; v_x numeric; v_mapped numeric;
begin
  for a in
    with k as (
      select distinct x.year, x.debt_key, x.debt_account from app.ledger_allocs x
       where x.debt_key like 'open:%' and x.alloc_date between p_from and p_to
         and app.is_carry(x.debt_account, x.alloc_date)),
    al as (
      select x.*, coalesce(sum(x.amount) over (partition by x.year, x.debt_key order by x.seq, x.credit_key
                                                 rows between unbounded preceding and 1 preceding), 0) off
        from app.ledger_allocs x join k on k.year = x.year and k.debt_key = x.debt_key)
    select * from al where alloc_date between p_from and p_to order by debt_account, seq, credit_key
  loop
    v_lo := a.off; v_hi := a.off + a.amount; v_cum := 0; v_mapped := 0;
    -- بنود السنة السابقة المفتوحة عند إقفالها، بترتيب السداد
    for p in
      select i.item_key, i.amount - coalesce((select sum(z.amount) from app.ledger_allocs z
                                               where z.year = i.year and z.debt_key = i.item_key), 0) rem
        from app.ledger_items i
       where i.year = a.year - 1 and i.account_id = a.debt_account and i.side = 'D'
       order by i.seq
    loop
      continue when p.rem <= 0;
      v_x := least(v_hi, v_cum + p.rem) - greatest(v_lo, v_cum);
      if v_x > 0 then
        v_out := v_out || jsonb_build_object('debt_key', p.item_key, 'debt_account', a.debt_account, 'amount', v_x, 'alloc_date', a.alloc_date);
        v_mapped := v_mapped + v_x;
      end if;
      v_cum := v_cum + p.rem;
      exit when v_cum >= v_hi;
    end loop;
    if a.amount - v_mapped > 0 then
      v_out := v_out || jsonb_build_object('debt_key', a.debt_key, 'debt_account', a.debt_account, 'amount', a.amount - v_mapped, 'alloc_date', a.alloc_date);
    end if;
  end loop;
  return v_out;
end $$;

create or replace function app.carry_allocs(p_from date, p_to date)
returns table (debt_key text, debt_account bigint, amount numeric, alloc_date date)
language plpgsql security definer set search_path = public, app as $$
declare
  v_k text := concat_ws('|', 'ca', statement_timestamp(), p_from, p_to);
  v jsonb;
begin
  perform app.memo_table();
  select j into v from _memo where k = v_k;
  if v is null then
    v := app.carry_allocs_raw(p_from, p_to);
    insert into _memo (k, j) values (v_k, v) on conflict (k) do nothing;
  end if;
  return query select x.debt_key, x.debt_account, x.amount, x.alloc_date
                 from jsonb_to_recordset(v) x(debt_key text, debt_account bigint, amount numeric, alloc_date date);
end $$;

do $$
declare v_src text; v_new text; v_paid text; i int; j int;
begin
  select pg_get_functiondef('app.commission_calc(bigint, date)'::regprocedure) into v_src;

  -- 1) المسدد: نسخة ثانية من استعلام المسدد مصدرها التسديدات المرحّلة
  i := strpos(v_src, '  insert into _cm (source, part, doc_id, doc_kind, doc_number, doc_date, customer_id, rep_id, product_id, value, paid, inv_month)');
  j := strpos(v_src, 'and t.v <> 0;');
  if i = 0 or j = 0 or j < i then raise exception 'commission_calc: موضع المسدد غير مطابق'; end if;
  v_paid := substr(v_src, i, j - i + length('and t.v <> 0;'));
  if strpos(v_paid, '    from app.ledger_allocs a') = 0 then raise exception 'commission_calc: مصدر المسدد غير مطابق'; end if;
  v_new := substr(v_src, 1, j + length('and t.v <> 0;') - 1)
        || E'\n\n  -- المسدد من ذمم السنة السابقة المرحّلة افتتاحيًا (A1، COMM-008)\n'
        || replace(v_paid, '    from app.ledger_allocs a', '    from app.carry_allocs(v_m, v_e) a')
        || substr(v_src, j + length('and t.v <> 0;'));

  -- 2) تحصيل الافتتاحي: الافتتاحي غير المرحّل، وما لم يُربط ببند فاتورة من المرحّل
  v_src := v_new;
  v_new := replace(v_src,
    E'      from app.ledger_allocs a\n     where a.debt_key like ''open:%'' and a.alloc_date between v_m and v_e',
    E'      from (select a0.debt_key, a0.debt_account, a0.amount, a0.alloc_date from app.ledger_allocs a0\n'
    || E'             where a0.debt_key like ''open:%'' and a0.alloc_date between v_m and v_e and not app.is_carry(a0.debt_account, a0.alloc_date)\n'
    || E'            union all\n'
    || E'            select c.debt_key, c.debt_account, c.amount, c.alloc_date from app.carry_allocs(v_m, v_e) c where c.debt_key like ''open:%'') a\n'
    || E'     where true');
  if v_new = v_src then raise exception 'commission_calc: موضع الافتتاحي غير مطابق'; end if;

  -- 3) المؤجل: المسدد من الفاتورة يشمل التسديدات المرحّلة
  v_src := v_new;
  v_new := replace(v_src,
    $q$left join lateral (select sum(a.amount) v from app.ledger_allocs a where a.debt_key = 'doc:' || d.id and a.alloc_date <= v_e) pd on true$q$,
    $q$left join lateral (select coalesce((select sum(a.amount) from app.ledger_allocs a where a.debt_key = 'doc:' || d.id and a.alloc_date <= v_e), 0)
                             + coalesce((select sum(c.amount) from app.carry_allocs(make_date(extract(year from v_e)::int, 1, 1), v_e) c
                                          where c.debt_key = 'doc:' || d.id), 0) v) pd on true$q$);
  if v_new = v_src then raise exception 'commission_calc: موضع المؤجل غير مطابق'; end if;
  execute v_new;
end $$;

select app.apply_grants();
notify pgrst, 'reload schema';
