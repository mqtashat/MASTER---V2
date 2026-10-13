-- =====================================================================
-- 0007 — الخرائط: مواقع العملاء، المناطق والأسواق، خريطة الفواتير، مقارنة الفترات، انتشار الأصناف
-- MAP-001..015، B063–B071، CAL-001، DAY-001، UX-005
-- العرض الجغرافي لا ينشئ حركة مالية ولا يغيّر مستندًا أو Ledger (MAP-007).
-- =====================================================================

-- ---------------------------------------------------------------------
-- مواقع العملاء (MAP-004، B065): الأصل المستورد يحفظ للتدقيق، والمعتمد (lat/lng) للعرض
-- ---------------------------------------------------------------------
alter table public.customers add column if not exists orig_lat numeric;
alter table public.customers add column if not exists orig_lng numeric;

-- حالة الموقع: صالح، مفقود، غير صالح (صفر أو خارج النطاق)
create or replace function app.loc_state(p_lat numeric, p_lng numeric) returns text
language sql immutable as $$
  select case when p_lat is null or p_lng is null then 'missing'
              when p_lat not between -90 and 90 or p_lng not between -180 and 180 or (p_lat = 0 and p_lng = 0) then 'invalid'
              else 'ok' end
$$;

-- الصفوف: [{row, customer_number, name, lat, lng}]؛ المطابقة برقم العميل، الفراغ لا يمحو، المجهول يحتاج تعريفًا أولًا
create or replace function public.import_customer_locations(p_rows jsonb, p_commit boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; c public.customers; v_lat numeric; v_lng numeric; v_kind text;
  v_out jsonb := '[]'; v_counts jsonb := '{"new":0,"changed":0,"same":0,"blank":0,"error":0}'; v_msg text;
begin
  perform app.require_perm('P16', 'import');
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    v_msg := null; v_lat := null; v_lng := null;
    select * into c from public.customers where customer_number = trim(r->>'customer_number');
    if not found then
      v_kind := 'error'; v_msg := 'عميل غير معروف؛ عرّفه في صفحة العملاء أولًا';
    elsif not app.can_see_customer(c.id) then
      v_kind := 'error'; v_msg := 'العميل خارج نطاق بياناتك';
    elsif coalesce(trim(r->>'lat'), '') = '' and coalesce(trim(r->>'lng'), '') = '' then
      v_kind := 'blank';
    elsif app.is_bad_num(r->>'lat') or app.is_bad_num(r->>'lng') or coalesce(trim(r->>'lat'), '') = '' or coalesce(trim(r->>'lng'), '') = '' then
      v_kind := 'error'; v_msg := 'إحداثيات غير مقروءة؛ خط العرض وخط الطول معًا';
    else
      v_lat := trim(r->>'lat')::numeric; v_lng := trim(r->>'lng')::numeric;
      if app.loc_state(v_lat, v_lng) <> 'ok' then
        v_kind := 'error'; v_msg := 'إحداثيات خارج النطاق أو صفرية';
      elsif c.lat is null then v_kind := 'new';
      elsif c.lat = v_lat and c.lng = v_lng then v_kind := 'same';
      else v_kind := 'changed';
      end if;
    end if;
    v_counts := jsonb_set(v_counts, array[v_kind], to_jsonb((v_counts->>v_kind)::int + 1));
    v_out := v_out || jsonb_build_object('row', r->'row', 'customer_number', r->>'customer_number', 'name_src', r->>'name',
      'customer_id', c.id, 'name', c.name, 'kind', v_kind, 'message', v_msg, 'old_lat', c.lat, 'old_lng', c.lng, 'lat', v_lat, 'lng', v_lng);
    if p_commit and v_kind in ('new', 'changed') then
      update public.customers set lat = v_lat, lng = v_lng, orig_lat = v_lat, orig_lng = v_lng,
             location_updated_at = now(), updated_at = now() where id = c.id;
      perform app.audit('customers', c.id::text, 'import_location', jsonb_build_object('lat', c.lat, 'lng', c.lng),
                        jsonb_build_object('lat', v_lat, 'lng', v_lng));
    end if;
  end loop;
  return jsonb_build_object('counts', v_counts, 'rows', v_out, 'committed', p_commit);
end $$;

-- ---------------------------------------------------------------------
-- المناطق والأسواق (MAP-005، B067، B068): نسخ حدود وإسناد بتاريخ سريان
-- geom: مصفوفة مضلعات، كل مضلع مصفوفة نقاط [lat, lng]
-- ---------------------------------------------------------------------
create table public.regions (
  id          bigserial primary key,
  name        text not null,
  color       text not null default '#1f5fa8',
  note        text,
  status      text not null default 'active' check (status in ('active', 'deleted')),
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now()
);

create table public.region_versions (
  id             bigserial primary key,
  region_id      bigint not null references public.regions(id) on delete cascade,
  valid_from     date not null,
  geom           jsonb not null,
  min_lat numeric, max_lat numeric, min_lng numeric, max_lng numeric,
  employee_id    bigint references public.employees(id),     -- مندوب المنطقة
  supervisor_id  bigint references public.employees(id),     -- أو مجموعة مشرف
  created_at     timestamptz not null default now(),
  created_by     uuid,
  unique (region_id, valid_from)
);

-- إسناد صريح لعميل في تداخل أو حد مشترك (B067)؛ region_id فارغ = بلا منطقة
create table public.region_assignments (
  id           bigserial primary key,
  customer_id  bigint not null references public.customers(id),
  region_id    bigint references public.regions(id),
  valid_from   date not null,
  reason       text,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  unique (customer_id, valid_from)
);

-- نقطة داخل مضلع (Ray casting)؛ الحد يعد داخلًا فيظهر الحد المشترك تداخلًا يحتاج تحديدًا
create or replace function app.in_ring(p_lat numeric, p_lng numeric, p_ring jsonb) returns boolean
language plpgsql immutable as $$
declare
  n int := jsonb_array_length(p_ring); i int; j int; yi numeric; xi numeric; yj numeric; xj numeric; v_in boolean := false;
begin
  if n < 3 then return false; end if;
  j := n - 1;
  for i in 0 .. n - 1 loop
    yi := (p_ring->i->>0)::numeric; xi := (p_ring->i->>1)::numeric;
    yj := (p_ring->j->>0)::numeric; xj := (p_ring->j->>1)::numeric;
    -- على الضلع
    if (p_lat - yi) * (xj - xi) = (p_lng - xi) * (yj - yi)
       and p_lat between least(yi, yj) and greatest(yi, yj) and p_lng between least(xi, xj) and greatest(xi, xj) then
      return true;
    end if;
    if ((yi > p_lat) <> (yj > p_lat)) and (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) then
      v_in := not v_in;
    end if;
    j := i;
  end loop;
  return v_in;
end $$;

create or replace function app.in_geom(p_lat numeric, p_lng numeric, p_geom jsonb) returns boolean
language sql immutable as $$
  select coalesce(bool_or(app.in_ring(p_lat, p_lng, g)), false) from jsonb_array_elements(p_geom) g
$$;

-- النسخة السارية لكل منطقة نشطة في تاريخ
create or replace function app.region_versions_at(p_date date)
returns setof public.region_versions language sql stable security definer set search_path = public as $$
  select distinct on (v.region_id) v.* from public.region_versions v join public.regions r on r.id = v.region_id
   where r.status = 'active' and v.valid_from <= p_date
   order by v.region_id, v.valid_from desc, v.id desc
$$;

-- منطقة العميل في تاريخ: الإسناد الصريح أولًا، ثم الاحتواء؛ أكثر من منطقة = يحتاج تحديد منطقة
create or replace function app.customer_regions(p_date date)
returns table (customer_id bigint, region_id bigint, state text, candidates bigint[])
language sql stable security definer set search_path = public, app as $$
  with v as (select * from app.region_versions_at(p_date)),
  m as (
    select c.id cid, app.loc_state(c.lat, c.lng) ls,
           coalesce(array_agg(v.region_id order by v.region_id)
                      filter (where v.region_id is not null and app.in_geom(c.lat, c.lng, v.geom)), '{}') regs
      from public.customers c
      left join v on app.loc_state(c.lat, c.lng) = 'ok'
                 and c.lat between v.min_lat and v.max_lat and c.lng between v.min_lng and v.max_lng
     group by c.id, c.lat, c.lng
  ),
  a as (
    select distinct on (x.customer_id) x.customer_id, x.region_id from public.region_assignments x
     where x.valid_from <= p_date order by x.customer_id, x.valid_from desc, x.id desc
  )
  select m.cid,
         case when a.customer_id is not null then a.region_id when cardinality(m.regs) = 1 then m.regs[1] end,
         case when a.customer_id is not null then case when a.region_id is null then 'none' else 'assigned' end
              when m.ls <> 'ok' then 'no_location'
              when cardinality(m.regs) = 0 then 'none'
              when cardinality(m.regs) = 1 then 'in'
              else 'conflict' end,
         m.regs
    from m left join a on a.customer_id = m.cid
$$;

-- منطقة عميل واحد في تاريخ (للاستخدام لكل سند دون حساب كل العملاء)
create or replace function app.customer_region_at(p_customer bigint, p_date date) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  a public.region_assignments; c public.customers; v_ids bigint[];
begin
  select * into a from public.region_assignments x where x.customer_id = p_customer and x.valid_from <= p_date
   order by x.valid_from desc, x.id desc limit 1;
  if found then return a.region_id; end if;
  select * into c from public.customers where id = p_customer;
  if app.loc_state(c.lat, c.lng) <> 'ok' then return null; end if;
  select array_agg(v.region_id) into v_ids from app.region_versions_at(p_date) v
   where c.lat between v.min_lat and v.max_lat and c.lng between v.min_lng and v.max_lng and app.in_geom(c.lat, c.lng, v.geom);
  return case when cardinality(v_ids) = 1 then v_ids[1] end;
end $$;

-- مناطق الموظف (مندوب المنطقة أو مجموعة مشرفه) في تاريخ
create or replace function app.emp_region_geoms(p_emp bigint, p_date date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(v.geom), '[]') from app.region_versions_at(p_date) v
   where v.employee_id = p_emp
      or (v.supervisor_id is not null and (v.supervisor_id = p_emp or exists (
            select 1 from public.supervisor_assignments s where s.employee_id = p_emp and s.supervisor_id = v.supervisor_id
               and daterange(s.valid_from, s.valid_to, '[]') @> p_date)))
$$;

-- موقع إصدار الفاتورة داخل مناطق مندوبها؟ null = لا منطقة مسندة أو لا موقع
create or replace function app.doc_in_region(p_emp bigint, p_date date, p_lat numeric, p_lng numeric) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when app.loc_state(p_lat, p_lng) <> 'ok' then null
              when jsonb_array_length(g) = 0 then null
              else exists (select 1 from jsonb_array_elements(g) x where app.in_geom(p_lat, p_lng, x)) end
    from (select app.emp_region_geoms(p_emp, p_date) g) q
$$;

-- الموظفون في النطاق: المسموح ∩ المختارون ∩ فريق المشرف المختار
create or replace function app.scope_emps(p_opts jsonb, p_from date, p_to date) returns bigint[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(e.id), '{}') from public.employees e
   where app.can_see_employee(e.id)
     and (coalesce(jsonb_array_length(case when jsonb_typeof(p_opts->'employees') = 'array' then p_opts->'employees' end), 0) = 0
          or e.id in (select x::bigint from jsonb_array_elements_text(p_opts->'employees') x))
     and (nullif(p_opts->>'supervisor_id', '') is null or e.id = (p_opts->>'supervisor_id')::bigint
          or exists (select 1 from public.supervisor_assignments s where s.employee_id = e.id and s.supervisor_id = (p_opts->>'supervisor_id')::bigint
                        and daterange(s.valid_from, s.valid_to, '[]') && daterange(p_from, p_to, '[]')))
$$;

create or replace function app.geom_bbox(p_geom jsonb) returns numeric[]
language sql immutable as $$
  select array[min((p->>0)::numeric), max((p->>0)::numeric), min((p->>1)::numeric), max((p->>1)::numeric)]
    from jsonb_array_elements(p_geom) g, jsonb_array_elements(g) p
$$;

create or replace function app.region_json(p_id bigint, p_date date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(r) || jsonb_build_object(
    'version', (select to_jsonb(v) || jsonb_build_object('employee', (select name from public.employees where id = v.employee_id),
                                                         'supervisor', (select name from public.employees where id = v.supervisor_id))
                  from app.region_versions_at(p_date) v where v.region_id = r.id),
    'versions', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'valid_from', v.valid_from, 'employee_id', v.employee_id,
                                                              'supervisor_id', v.supervisor_id, 'points', (select count(*) from jsonb_array_elements(v.geom) g, jsonb_array_elements(g) p))
                                           order by v.valid_from desc), '[]') from public.region_versions v where v.region_id = r.id))
    from public.regions r where r.id = p_id
$$;

-- p: {name, color, note, geom, employee_id, supervisor_id, valid_from}؛ تغير الحدود أو الإسناد ينشئ نسخة بتاريخ السريان
create or replace function public.save_region(p_id bigint, p jsonb, p_code text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint; v_before jsonb; v_cur public.region_versions; v_from date := coalesce(nullif(p->>'valid_from', '')::date, app.today());
  v_geom jsonb := p->'geom'; v_bb numeric[]; g jsonb; pt jsonb;
  v_emp bigint := nullif(p->>'employee_id', '')::bigint; v_sup bigint := nullif(p->>'supervisor_id', '')::bigint;
begin
  perform app.require_perm('P17', case when p_id is null then 'add' else 'edit' end);
  if coalesce(trim(p->>'name'), '') = '' then perform app.fail('required', 'اسم المنطقة مطلوب'); end if;
  if jsonb_typeof(v_geom) <> 'array' or jsonb_array_length(v_geom) = 0 then perform app.fail('bad_geom', 'ارسم حدود المنطقة أو استوردها'); end if;
  for g in select * from jsonb_array_elements(v_geom) loop
    if jsonb_typeof(g) <> 'array' or jsonb_array_length(g) < 3 then perform app.fail('bad_geom', 'كل مضلع يحتاج ثلاث نقاط على الأقل'); end if;
    for pt in select * from jsonb_array_elements(g) loop
      if app.is_bad_num(pt->>0) or app.is_bad_num(pt->>1) or app.loc_state((pt->>0)::numeric, (pt->>1)::numeric) <> 'ok' then
        perform app.fail('bad_geom', 'نقطة حدود غير صالحة');
      end if;
    end loop;
  end loop;
  if v_emp is not null then perform app.require_employee_scope(v_emp); end if;
  if v_sup is not null then perform app.require_employee_scope(v_sup); end if;
  perform app.guard_dates(array[v_from], p_code);
  v_bb := app.geom_bbox(v_geom);
  if p_id is null then
    insert into public.regions (name, color, note, created_by) values (trim(p->>'name'), coalesce(nullif(p->>'color', ''), '#1f5fa8'), p->>'note', auth.uid())
    returning id into v_id;
  else
    select * into v_cur from app.region_versions_at('infinity'::date) where region_id = p_id;
    if not exists (select 1 from public.regions where id = p_id and status = 'active') then perform app.fail('not_found', 'المنطقة غير موجودة'); end if;
    v_before := app.region_json(p_id, app.today());
    update public.regions set name = trim(p->>'name'), color = coalesce(nullif(p->>'color', ''), color), note = p->>'note', updated_at = now() where id = p_id;
    v_id := p_id;
  end if;
  if v_cur.id is null or v_cur.geom <> v_geom or v_cur.employee_id is distinct from v_emp or v_cur.supervisor_id is distinct from v_sup then
    if v_cur.id is not null and v_from < v_cur.valid_from then
      perform app.fail('bad_date', 'تاريخ السريان قبل آخر نسخة؛ النسخ التاريخية تبقى كما هي');
    end if;
    insert into public.region_versions (region_id, valid_from, geom, min_lat, max_lat, min_lng, max_lng, employee_id, supervisor_id, created_by)
    values (v_id, v_from, v_geom, v_bb[1], v_bb[2], v_bb[3], v_bb[4], v_emp, v_sup, auth.uid())
    on conflict (region_id, valid_from) do update set geom = excluded.geom, min_lat = excluded.min_lat, max_lat = excluded.max_lat,
       min_lng = excluded.min_lng, max_lng = excluded.max_lng, employee_id = excluded.employee_id, supervisor_id = excluded.supervisor_id,
       created_at = now(), created_by = auth.uid();
  end if;
  perform app.audit('regions', v_id::text, case when p_id is null then 'create' else 'update' end, v_before, app.region_json(v_id, v_from));
  return v_id;
end $$;

-- معاينة أثر الحدود قبل الحفظ: العملاء الداخلون والخارجون والتداخلات الجديدة
create or replace function public.preview_region(p_id bigint, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_date date := greatest(coalesce(nullif(p->>'valid_from', '')::date, app.today()), app.today());
  v_before jsonb; v_after jsonb; v_rid bigint;
begin
  perform app.require_perm('P17', 'view');
  select coalesce(jsonb_object_agg(customer_id::text, jsonb_build_object('r', region_id, 's', state)), '{}') into v_before
    from app.customer_regions(v_date) where app.can_see_customer(customer_id);
  begin
    v_rid := public.save_region(p_id, p || jsonb_build_object('valid_from', v_date), null);
    select coalesce(jsonb_object_agg(customer_id::text, jsonb_build_object('r', region_id, 's', state, 'c', candidates)), '{}') into v_after
      from app.customer_regions(v_date) where app.can_see_customer(customer_id);
    raise exception using errcode = 'P0002', message = 'preview';
  exception when sqlstate 'P0002' then null;
  end;
  return jsonb_build_object(
    'inside', (select count(*) from jsonb_each(v_after) a where (a.value->'c') @> to_jsonb(v_rid)),
    'added', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from jsonb_each(v_after) a join public.customers c on c.id = a.key::bigint
               where (a.value->'c') @> to_jsonb(v_rid) and coalesce((v_before->a.key->>'r')::bigint, -1) <> v_rid
                 and (p_id is null or not exists (select 1 from app.customer_regions(v_date) z where z.customer_id = c.id and p_id = any(z.candidates)))), '[]'),
    'removed', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from app.customer_regions(v_date) z join public.customers c on c.id = z.customer_id
               where p_id is not null and p_id = any(z.candidates) and app.can_see_customer(c.id)
                 and not ((v_after->c.id::text->'c') @> to_jsonb(p_id))), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name) order by c.customer_number)
                from jsonb_each(v_after) a join public.customers c on c.id = a.key::bigint
               where a.value->>'s' = 'conflict' and (a.value->'c') @> to_jsonb(v_rid)), '[]'));
end $$;

create or replace function public.delete_region(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_perm('P17', 'delete');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الحذف مطلوب'); end if;
  if not exists (select 1 from public.regions where id = p_id and status = 'active') then perform app.fail('not_found', 'المنطقة غير موجودة'); end if;
  perform app.audit('regions', p_id::text, 'delete', app.region_json(p_id, app.today()), null, p_reason);
  update public.regions set status = 'deleted', updated_at = now() where id = p_id;
end $$;

-- إسناد صريح لعميل (حل التداخل أو استثناء من المنطقة)
create or replace function public.assign_customer_region(p_customer bigint, p_region bigint, p_from date, p_reason text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_from date := coalesce(p_from, app.today());
begin
  perform app.require_perm('P17', 'edit');
  perform app.require_customer_scope(p_customer);
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب الإسناد مطلوب'); end if;
  insert into public.region_assignments (customer_id, region_id, valid_from, reason, created_by) values (p_customer, p_region, v_from, p_reason, auth.uid())
  on conflict (customer_id, valid_from) do update set region_id = excluded.region_id, reason = excluded.reason, created_at = now(), created_by = auth.uid();
  perform app.audit('region_assignments', p_customer::text, 'assign', null, jsonb_build_object('region_id', p_region, 'from', v_from), p_reason);
end $$;

-- قائمة المناطق في تاريخ (التاريخي) أو اليوم (الوضع الحالي)، وعدد عملائها، وما يحتاج تحديد منطقة
create or replace function public.regions_list(p_date date default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_date date := coalesce(p_date, app.today());
begin
  perform app.require_perm('P17', 'view');
  create temp table if not exists _cr (customer_id bigint, region_id bigint, state text, candidates bigint[]) on commit drop;
  truncate _cr;
  insert into _cr select * from app.customer_regions(v_date) z where app.can_see_customer(z.customer_id);
  return jsonb_build_object('date', v_date,
    'regions', coalesce((select jsonb_agg(app.region_json(r.id, v_date) || jsonb_build_object(
                  'customers', (select count(*) from _cr where _cr.region_id = r.id)) order by r.name)
                  from public.regions r where r.status = 'active'), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name,
                    'candidates', (select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name)) from public.regions g where g.id = any(_cr.candidates)))
                    order by c.customer_number) from _cr join public.customers c on c.id = _cr.customer_id where _cr.state = 'conflict'), '[]'),
    'counts', (select jsonb_build_object('in', count(*) filter (where state in ('in', 'assigned')), 'none', count(*) filter (where state = 'none'),
                      'no_location', count(*) filter (where state = 'no_location'), 'conflict', count(*) filter (where state = 'conflict')) from _cr));
end $$;

-- ---------------------------------------------------------------------
-- P16 — مواقع العملاء
-- p_opts: {search, region_id, employee_id, state: all|ok|missing|invalid, date}
-- ---------------------------------------------------------------------
create or replace function public.customer_locations(p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_date date := coalesce(nullif(o->>'date', '')::date, app.today()); s text := trim(coalesce(o->>'search', ''));
begin
  perform app.require_perm('P16', 'view');
  return coalesce((select jsonb_agg(x order by x->>'customer_number') from (
    select jsonb_build_object('id', c.id, 'customer_number', c.customer_number, 'name', c.name,
             'master_number', v.master_number, 'master_name', v.master_name, 'kind', v.kind,
             'lat', c.lat, 'lng', c.lng, 'orig_lat', c.orig_lat, 'orig_lng', c.orig_lng, 'state', app.loc_state(c.lat, c.lng),
             'updated_at', c.location_updated_at, 'region_id', z.region_id, 'region_state', z.state,
             'region', (select name from public.regions where id = z.region_id)) x
      from public.customers c
      join public.customers_v v on v.id = c.id
      join app.customer_regions(v_date) z on z.customer_id = c.id
     where app.can_see_customer(c.id)
       and (s = '' or c.customer_number = s or c.name ilike '%' || s || '%')
       and (nullif(o->>'region_id', '') is null or (o->>'region_id' = 'none' and z.region_id is null) or z.region_id::text = o->>'region_id')
       and (nullif(o->>'employee_id', '') is null or exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = (o->>'employee_id')::bigint))
       and (coalesce(o->>'state', 'all') = 'all' or app.loc_state(c.lat, c.lng) = o->>'state')
     limit 20000) q), '[]');
end $$;

-- ---------------------------------------------------------------------
-- P15 — خريطة الفواتير (MAP-002، MAP-014: الفواتير فقط؛ MAP-012: لا وقت إصدار في الإصدار الأول)
-- p_opts: {employees:[ids], supervisor_id, region_id, pay_type: all|cash|credit, loc: all|ok|missing}
-- ---------------------------------------------------------------------
create or replace function public.invoice_map(p_from date, p_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_emps bigint[];
begin
  perform app.require_perm('P15', 'view');
  if p_from is null or p_to is null or p_to < p_from then perform app.fail('bad_period', 'حدد فترة صحيحة'); end if;
  if p_to - p_from > 92 then perform app.fail('period_too_long', 'الفترة القصوى للخريطة 93 يومًا'); end if;
  v_emps := app.scope_emps(o, p_from, p_to);
  create temp table if not exists _im (j jsonb, ok boolean) on commit drop;
  truncate _im;
  insert into _im
  select jsonb_build_object('id', d.id, 'number', d.doc_number, 'date', d.doc_date, 'pay_type', d.pay_type,
           'customer_id', d.customer_id, 'customer_number', c.customer_number, 'customer', c.name, 'employee_id', d.employee_id, 'employee', e.name,
           'total', d.total, 'quantity', d.quantity, 'bonus', d.bonus, 'lat', d.lat, 'lng', d.lng, 'loc', app.loc_state(d.lat, d.lng),
           'cust_lat', c.lat, 'cust_lng', c.lng, 'in_region', app.doc_in_region(d.employee_id, d.doc_date, d.lat, d.lng)),
         app.loc_state(d.lat, d.lng) = 'ok'
    from public.docs d join public.customers c on c.id = d.customer_id join public.employees e on e.id = d.employee_id
   where d.kind = 'invoice' and d.status = 'active' and d.doc_date between p_from and p_to and d.employee_id = any(v_emps)
     and (coalesce(o->>'pay_type', 'all') = 'all' or (o->>'pay_type' = 'cash' and d.pay_type = 'فاتورة نقدي') or (o->>'pay_type' = 'credit' and d.pay_type = 'فاتورة ذمم'))
     and (nullif(o->>'region_id', '') is null or app.customer_region_at(d.customer_id, d.doc_date)::text = o->>'region_id')
     and (coalesce(o->>'loc', 'all') = 'all' or (o->>'loc' = 'ok') = (app.loc_state(d.lat, d.lng) = 'ok'))
   limit 50000;
  return jsonb_build_object('from', p_from, 'to', p_to, 'has_time', false,
    'points', coalesce((select jsonb_agg(j order by j->>'date', j->>'number') from _im where ok), '[]'),
    'missing', coalesce((select jsonb_agg(j order by j->>'date', j->>'number') from _im where not ok), '[]'),
    'employees', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'emp_number', e.emp_number) order by e.name)
                             from public.employees e where e.id in (select (j->>'employee_id')::bigint from _im)), '[]'),
    'totals', (select jsonb_build_object('count', count(*), 'total', coalesce(sum((j->>'total')::numeric), 0),
                 'quantity', coalesce(sum((j->>'quantity')::numeric), 0), 'bonus', coalesce(sum((j->>'bonus')::numeric), 0),
                 'with_location', count(*) filter (where ok), 'missing', count(*) filter (where not ok),
                 'in_region', count(*) filter (where (j->>'in_region')::boolean), 'out_region', count(*) filter (where not (j->>'in_region')::boolean))
                 from _im));
end $$;

-- ---------------------------------------------------------------------
-- P17a — مقارنة الفترات (MAP-006، MAP-011، B069)
-- ---------------------------------------------------------------------
create or replace function app.work_days_between(p_from date, p_to date) returns int
language sql stable security definer set search_path = public, app as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') g
   where extract(dow from g)::int = any(app.work_weekdays())
     and not exists (select 1 from public.holidays h where g::date between h.start_date and h.end_date)
$$;

-- عملاء النطاق: من تعامل معهم موظفو النطاق، أو عملاء المنطقة المختارة
create or replace function app.period_metrics(p_from date, p_to date, p_emps bigint[], p_region text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  create temp table if not exists _pd (id bigint, kind text, customer_id bigint, employee_id bigint, total numeric, in_region boolean) on commit drop;
  truncate _pd;
  insert into _pd
  select d.id, d.kind, d.customer_id, d.employee_id, d.total,
         case when d.kind = 'invoice' then app.doc_in_region(d.employee_id, d.doc_date, d.lat, d.lng) end
    from public.docs d
   where d.status = 'active' and d.kind in ('invoice', 'return') and d.doc_date between p_from and p_to and d.employee_id = any(p_emps)
     and (p_region is null or app.customer_region_at(d.customer_id, d.doc_date)::text = p_region);
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'days', p_to - p_from + 1, 'work_days', app.work_days_between(p_from, p_to),
    'sales', coalesce(sum(total) filter (where kind = 'invoice'), 0),
    'returns', coalesce(sum(total) filter (where kind = 'return'), 0),
    'net', coalesce(sum(case kind when 'invoice' then total else -total end), 0),
    'invoices', count(*) filter (where kind = 'invoice' and total > 0),
    'customers', count(distinct customer_id),
    'buyers', count(distinct customer_id) filter (where kind = 'invoice' and total > 0),
    'avg_invoice', case when count(*) filter (where kind = 'invoice' and total > 0) > 0
                        then sum(total) filter (where kind = 'invoice' and total > 0) / count(*) filter (where kind = 'invoice' and total > 0) end,
    'new_customers', (select count(distinct p.customer_id) from _pd p where p.kind = 'invoice' and p.total > 0
                        and not exists (select 1 from public.docs o where o.customer_id = p.customer_id and o.kind = 'invoice' and o.status = 'active'
                                          and o.total > 0 and o.doc_date < p_from)),
    'in_region', count(*) filter (where kind = 'invoice' and in_region),
    'out_region', count(*) filter (where kind = 'invoice' and in_region = false),
    'no_region', count(*) filter (where kind = 'invoice' and in_region is null))
  into v from _pd;
  -- غير المباعين: عملاء النطاق بلا شراء موجب في الفترة (MAP-011)
  v := v || jsonb_build_object('scope_customers', q.n, 'unsold', q.n - (v->>'buyers')::int)
    from (select count(*) n from public.customers c
           where app.can_see_customer(c.id)
             and (p_region is not null or exists (select 1 from public.customer_employee_links l where l.customer_id = c.id and l.employee_id = any(p_emps)))
             and (p_region is null or app.customer_region_at(c.id, p_to)::text = p_region)) q;
  v := v || jsonb_build_object('by_employee', coalesce((select jsonb_agg(jsonb_build_object('employee_id', x.employee_id, 'name', e.name,
            'sales', x.s, 'returns', x.r, 'net', x.s - x.r, 'invoices', x.n, 'buyers', x.b) order by e.name)
            from (select employee_id, coalesce(sum(total) filter (where kind = 'invoice'), 0) s, coalesce(sum(total) filter (where kind = 'return'), 0) r,
                         count(*) filter (where kind = 'invoice' and total > 0) n, count(distinct customer_id) filter (where kind = 'invoice' and total > 0) b
                    from _pd group by employee_id) x join public.employees e on e.id = x.employee_id), '[]'));
  return v;
end $$;

-- p_opts: {employees, supervisor_id, region_id}
create or replace function public.period_compare(p_a_from date, p_a_to date, p_b_from date, p_b_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_a jsonb; v_b jsonb;
begin
  perform app.require_perm('P17a', 'view');
  if p_a_to < p_a_from or p_b_to < p_b_from then perform app.fail('bad_period', 'حدد فترتين صحيحتين'); end if;
  if greatest(p_a_to - p_a_from, p_b_to - p_b_from) > 366 then perform app.fail('period_too_long', 'الفترة القصوى سنة'); end if;
  v_a := app.period_metrics(p_a_from, p_a_to, app.scope_emps(o, p_a_from, p_a_to), nullif(o->>'region_id', ''));
  v_b := app.period_metrics(p_b_from, p_b_to, app.scope_emps(o, p_b_from, p_b_to), nullif(o->>'region_id', ''));
  return jsonb_build_object('a', v_a, 'b', v_b, 'equal_length', (p_a_to - p_a_from) = (p_b_to - p_b_from));
end $$;

-- ---------------------------------------------------------------------
-- P17b — انتشار الأصناف (MAP-008، MAP-009، B070، B071)
-- p_opts: {employees, supervisor_id, region_id, search, current: bool}
-- ---------------------------------------------------------------------
create or replace function public.product_spread(p_product bigint, p_from date, p_to date, p_opts jsonb default '{}') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb := coalesce(p_opts, '{}'); v_emps bigint[]; v_rdate date; s text := trim(coalesce(o->>'search', ''));
begin
  perform app.require_perm('P17b', 'view');
  if p_product is null then perform app.fail('required', 'اختر صنفًا'); end if;
  if p_from is null or p_to is null or p_to < p_from then perform app.fail('bad_period', 'حدد فترة صحيحة'); end if;
  v_emps := app.scope_emps(o, p_from, p_to);
  -- المنطقة تتبع موقع العميل المعتمد بالنسخة السارية آخر الفترة، أو الوضع الحالي صراحة (B068)
  v_rdate := case when (o->>'current')::boolean then app.today() else p_to end;
  create temp table if not exists _ps (doc_id bigint, kind text, customer_id bigint, employee_id bigint, doc_date date, v numeric, q numeric, b numeric) on commit drop;
  truncate _ps;
  insert into _ps
  select d.id, d.kind, d.customer_id, d.employee_id, d.doc_date, sum(coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)),
         sum(coalesce(l.quantity, 0)), sum(coalesce(l.bonus, 0))
    from public.docs d join public.doc_lines l on l.doc_id = d.id
   where d.status = 'active' and d.kind in ('invoice', 'return') and l.product_id = p_product
     and d.doc_date between p_from and p_to and d.employee_id = any(v_emps)
   group by d.id;
  create temp table if not exists _pr (customer_id bigint, region_id bigint, state text) on commit drop;
  truncate _pr;
  insert into _pr select z.customer_id, z.region_id, z.state from app.customer_regions(v_rdate) z where z.customer_id in (select customer_id from _ps);
  return (
    with c as (
      select p.customer_id,
             sum(v) filter (where kind = 'invoice') val, sum(q) filter (where kind = 'invoice') qty, sum(b) filter (where kind = 'invoice') bonus,
             count(distinct doc_id) filter (where kind = 'invoice' and v > 0) inv,
             bool_or(kind = 'invoice' and v > 0) bought, bool_or(kind = 'invoice' and b > 0) got_bonus,
             sum(v) filter (where kind = 'return') rv, sum(q) filter (where kind = 'return') rq,
             min(doc_date) filter (where kind = 'invoice' and v > 0) first_d, max(doc_date) filter (where kind = 'invoice' and v > 0) last_d,
             array_agg(distinct employee_id) emps, array_agg(distinct doc_id) docs
        from _ps p group by p.customer_id
    ), r as (
      select c.*, cu.customer_number, cu.name, cv.kind ckind, cv.master_number, cu.lat, cu.lng, app.loc_state(cu.lat, cu.lng) ls,
             pr.region_id, pr.state rstate, (select name from public.regions where id = pr.region_id) region,
             case when c.bought then 'buyer' when c.got_bonus then 'bonus_only' else 'return_only' end cat
        from c join public.customers cu on cu.id = c.customer_id join public.customers_v cv on cv.id = c.customer_id
        left join _pr pr on pr.customer_id = c.customer_id
       where (nullif(o->>'region_id', '') is null or (o->>'region_id' = 'none' and pr.region_id is null) or pr.region_id::text = o->>'region_id')
         and (s = '' or cu.customer_number = s or cu.name ilike '%' || s || '%')
    )
    select jsonb_build_object('product', (select jsonb_build_object('id', id, 'code', code, 'name', name) from public.products where id = p_product),
      'from', p_from, 'to', p_to, 'region_date', v_rdate,
      'summary', jsonb_build_object(
        'buyers', count(*) filter (where cat = 'buyer'),
        'invoices', (select count(distinct doc_id) from _ps x where x.kind = 'invoice' and x.v > 0 and x.customer_id in (select customer_id from r)),
        'value', coalesce(sum(val), 0), 'quantity', coalesce(sum(qty), 0), 'bonus', coalesce(sum(bonus), 0),
        'returns_value', coalesce(sum(rv), 0), 'returns_qty', coalesce(sum(rq), 0),
        'bonus_only', count(*) filter (where cat = 'bonus_only'), 'return_only', count(*) filter (where cat = 'return_only'),
        'no_location', count(*) filter (where ls <> 'ok'), 'no_region', count(*) filter (where region_id is null)),
      'rows', coalesce(jsonb_agg(jsonb_build_object('customer_id', customer_id, 'customer_number', customer_number, 'name', name,
        'kind', ckind, 'master_number', master_number, 'lat', lat, 'lng', lng, 'loc', ls, 'region_id', region_id, 'region', region, 'region_state', rstate,
        'category', cat, 'value', coalesce(val, 0), 'quantity', coalesce(qty, 0), 'bonus', coalesce(bonus, 0), 'invoices', inv,
        'returns_value', coalesce(rv, 0), 'returns_qty', coalesce(rq, 0), 'first', first_d, 'last', last_d,
        'employees', (select jsonb_agg(name order by name) from public.employees where id = any(emps)), 'docs', to_jsonb(docs))
        order by cat, val desc nulls last, customer_number), '[]'))
    from r);
end $$;

-- ---------------------------------------------------------------------
-- الصلاحيات والقراءة
-- ---------------------------------------------------------------------
alter table public.regions            enable row level security;
alter table public.region_versions    enable row level security;
alter table public.region_assignments enable row level security;
create policy regions_read on public.regions for select to authenticated using (app.has_perm('P17') or app.has_perm('P15') or app.has_perm('P16'));
create policy region_versions_read on public.region_versions for select to authenticated using (app.has_perm('P17'));
create policy region_assignments_read on public.region_assignments for select to authenticated using (app.has_perm('P17'));

select app.apply_grants();
