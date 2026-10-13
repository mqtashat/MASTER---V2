-- =====================================================================
-- 0009 — الأهداف الجغرافية والتغطية (GOAL-003، اعتماد محمد 13/10/2026)
-- • نطاق المنطقة لأي مقياس بيع أو تحصيل: الحركات على عملاء المنطقة فقط، والعميل بموقعه المحفوظ
--   (أو إسناده الصريح) بنسخة الحدود السارية في تاريخ السند. مثال: صافي مبيعات 10,000 داخل منطقة.
-- • مقياس «التغطية %» النسبي: من اشترى ببيع موجب من عملاء الموظف في منطقته ÷ كل عملاء الموظف في منطقته.
--   لا يخفض بالأيام ولا مسار له، والبونص وحده أو المرتجع وحده لا يجعل العميل مشتريًا.
-- • مقياس «نسبة التنوع %» النسبي (طلب محمد 13/10/2026): الأصناف المختلفة المباعة ببيع موجب ÷ أصناف القائمة × 100؛
--   القائمة أصناف المكوّن المختارة، وإلا كل الأصناف المعرّفة. الشرائح بأهداف لكل شريحة (مثلًا B ≥ 80، A ≥ 90).
-- =====================================================================

create or replace function app.metric_kind(p_metric text) returns text
language sql immutable as $$
  select case
    when p_metric in ('net_sales', 'gross_sales', 'collection', 'quantity') then 'amount'
    when p_metric in ('customers', 'invoices', 'variety', 'new_customers', 'reactivated') then 'count'
    when p_metric in ('collection_ratio', 'coverage', 'variety_ratio') then 'relative'
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
    when 'coverage' then 'التغطية' when 'variety_ratio' then 'نسبة التنوع'
  end
$$;

-- مناطق الموظف في تاريخ: المسندة إليه، أو لفريقه (للمشرف)، أو لمجموعة مشرفه
create or replace function app.emp_regions(p_emp bigint, p_role text, p_date date) returns bigint[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct v.region_id), '{}') from app.region_versions_at(p_date) v
   where v.employee_id = p_emp or v.supervisor_id = p_emp
      or (p_role = 'supervisor' and exists (select 1 from public.supervisor_assignments s
            where s.supervisor_id = p_emp and s.employee_id = v.employee_id and daterange(s.valid_from, s.valid_to, '[]') @> p_date))
      or (v.supervisor_id is not null and exists (select 1 from public.supervisor_assignments s
            where s.employee_id = p_emp and s.supervisor_id = v.supervisor_id and daterange(s.valid_from, s.valid_to, '[]') @> p_date))
$$;

-- قيمة مقياس لموظف في مدى (قبل حد القطع). p_f: {products:[ids], sale_type, pay_type, days, basis, region_id}
-- region_id يحصر الحركات في عملاء المنطقة بموقعهم المحفوظ (أو إسنادهم الصريح) في تاريخ السند
create or replace function app.metric_value(p_emp bigint, p_role text, p_personal boolean, p_from date, p_to date,
                                            p_metric text, p_f jsonb) returns numeric
language plpgsql security definer set search_path = public, app as $$
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
      v := app.paid_on_invoices(p_emp, p_role, p_personal, p_from, p_to);
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
    v_den := coalesce(cardinality(v_products), (select count(*) from public.products));
    v := case when v_den > 0 then round(v / v_den * 100, 2) end;
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
    v := case when v_den > 0 then round(v / v_den * 100, 2) end;
  else
    perform app.fail('bad_metric', 'مقياس غير معروف: ' || coalesce(p_metric, ''));
  end case;
  return v;
end $$;

-- محرر الأهداف يحتاج أسماء المناطق لاختيار نطاق المكوّن
drop policy if exists regions_read on public.regions;
create policy regions_read on public.regions for select to authenticated
  using (app.has_perm('P17') or app.has_perm('P15') or app.has_perm('P16') or app.has_perm('P10') or app.has_perm('P10a'));

select app.apply_grants();
