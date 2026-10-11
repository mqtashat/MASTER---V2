-- =====================================================================
-- ماستر — 0004: الحركات والرفع الموحد
-- السندات (الفواتير والمرتجعات والتحصيلات) وبنودها وإصداراتها، ودفعات الرفع وسنداتها،
-- والمعاينة والاعتماد والتعليق والاستبعاد، وحذف الدفعة والسند، والتحرير والنقل.
-- المراجع: DATA-002..007، DATA-010، TXN-001..004، B046–B054، INV-001..011، RET-001..008،
-- COL-001..014، UPLOAD-001، QTY-002/004، MAP-015، AUTH-004، B076.
-- =====================================================================

-- ---------------------------------------------------------------------
-- أدوات
-- ---------------------------------------------------------------------

-- عدد عشري نصي موحد دون أصفار زائدة؛ اختلاف عدد المنازل النصية لا يُعد تغييرًا
create or replace function app.nnum(p text) returns text
language sql immutable as $$
  select case when p is null or trim(p) = '' then null else trim_scale(trim(p)::numeric)::text end
$$;

create or replace function app.kind_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'invoice' then 'فاتورة' when 'return' then 'مرتجع' when 'collection' then 'تحصيل' end
$$;

-- أعمدة القوالب المعتمدة: المطلوبة لقراءة السند، وكامل القالب (INV-009/010، RET-006/007، COL-001)
create or replace function app.required_columns(p_kind text) returns text[]
language sql immutable as $$
  select case when p_kind = 'collection'
    then array['القيمة', 'الدفع', 'التاريخ', 'الرقم', 'رقم العميل', 'رقم المندوب']
    else array['Bonus', 'NetPromotions', 'NetSales', 'CustomerNumber', 'ItemNumber', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber']
  end
$$;

create or replace function app.all_columns(p_kind text) returns text[]
language sql immutable as $$
  select case p_kind
    when 'invoice' then array['Longitude', 'Latitude', 'DocumentTypeID', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
                              'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID']
    when 'return' then array['Longitude', 'Latitude', 'Bonus', 'NetPromotions', 'Quantity', 'NetSales', 'Customername',
                             'CustomerNumber', 'ItemName', 'ItemNumber', 'EmployeeName', 'EmployeeNumber', 'DocumentDate', 'DocumentNumber', 'CompanyID']
    else array['القيمة', 'رقم الشيك', 'الدفع', 'التاريخ', 'الرقم', 'العميل', 'رقم العميل', 'المندوب', 'رقم المندوب']
  end
$$;

-- ---------------------------------------------------------------------
-- السندات وبنودها وإصداراتها
-- ---------------------------------------------------------------------

-- دفعات الرفع (DATA-002، P05): الحالة محفوظة لإعادة المحاولة دون تكرار ما اعتمد
create table public.upload_batches (
  id               bigserial primary key,
  kind             text not null check (kind in ('invoice', 'return', 'collection')),
  file_name        text,
  sheet_name       text,
  columns          text[] not null,               -- أعمدة الملف كما وردت (B053)
  row_count        int not null,
  status           text not null default 'open' check (status in ('open', 'closed', 'deleted')),
  uploaded_by      uuid,
  uploaded_by_name text,
  uploaded_at      timestamptz not null default now(),
  deleted_at       timestamptz,
  deleted_by       uuid,
  delete_reason    text
);
create index on public.upload_batches (kind, uploaded_at desc);

-- السند: المفتاح رقم السند + رقم العميل + تاريخ السند داخل نوع الحركة (DATA-003)
create table public.docs (
  id                   bigserial primary key,
  kind                 text not null check (kind in ('invoice', 'return', 'collection')),
  doc_number           text not null,
  customer_number      text not null,
  doc_date             date not null,
  orig_doc_number      text not null,              -- المفتاح الأصلي يبقى بعد التعديل (B048)
  orig_customer_number text not null,
  orig_doc_date        date not null,
  customer_id          bigint not null references public.customers(id),
  employee_id          bigint not null references public.employees(id),
  customer_name_src    text,                       -- الاسم كما ورد في الملف
  employee_name_src    text,
  pay_type             text check (pay_type in ('فاتورة نقدي', 'فاتورة ذمم')),   -- الفواتير فقط (INV-011)
  lat                  numeric,                    -- موقع إصدار السند، مستقل عن موقع العميل (INV-004)
  lng                  numeric,
  net_sales            numeric not null default 0,
  net_promotions       numeric not null default 0,
  total                numeric not null default 0, -- المباشر + العروض، أو مجموع أجزاء التحصيل (COL-002)
  quantity             numeric,
  bonus                numeric not null default 0,
  line_count           int not null default 0,
  pay_methods          text,                       -- التحصيلات: أنواع الدفع في السند
  cheque_numbers       text,
  status               text not null default 'active' check (status in ('active', 'deleted')),
  version              int not null default 1,
  manual_edit          boolean not null default false,   -- آخر إصدار من تعديل يدوي أو نقل (TXN-003)
  created_batch_id     bigint references public.upload_batches(id),
  last_batch_id        bigint references public.upload_batches(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  deleted_at           timestamptz,
  unique (kind, doc_number, customer_number, doc_date)
);
create index on public.docs (kind, status, doc_date);
create index on public.docs (employee_id);
create index on public.docs (customer_id);
create index on public.docs (kind, orig_doc_number, orig_customer_number, orig_doc_date);
create index on public.docs (created_batch_id);
create index on public.docs (last_batch_id);

-- بنود السند أو أجزاء التحصيل: لا هوية مستقلة للبند (B047)، والتكرار الصحيح يحفظ
create table public.doc_lines (
  id              bigserial primary key,
  doc_id          bigint not null references public.docs(id) on delete cascade,
  line_no         int not null,
  product_id      bigint references public.products(id),
  item_number     text,
  item_name_src   text,
  net_sales       numeric,
  net_promotions  numeric,
  quantity        numeric,           -- كما وردت بكسورها (QTY-004)
  bonus           numeric,
  lat             numeric,
  lng             numeric,
  amount          numeric,           -- التحصيلات: قيمة الجزء
  pay_method      text,
  cheque_no       text,
  src_row         int
);
create index on public.doc_lines (doc_id, line_no);
create index on public.doc_lines (product_id);

-- كل إصدارات السند: الأصل وكل تعديل ورفع واستعادة وحذف (TXN-003)
create table public.doc_versions (
  id           bigserial primary key,
  doc_id       bigint not null references public.docs(id) on delete cascade,
  version      int not null,
  source       text not null check (source in ('upload', 'restore', 'manual', 'transfer', 'delete', 'batch_delete', 'batch_revert')),
  batch_id     bigint references public.upload_batches(id),
  data         jsonb not null,
  status       text not null,
  manual_edit  boolean not null default false,
  at           timestamptz not null default now(),
  by_user      uuid,
  by_name      text,
  reason       text,
  unique (doc_id, version)
);

-- سندات الدفعة: تصنيف المعاينة وقرار المستخدم ونتيجته
create table public.batch_items (
  id               bigserial primary key,
  batch_id         bigint not null references public.upload_batches(id),
  seq              int not null,
  doc_number       text,
  customer_number  text,
  doc_date_raw     text,
  doc_date         date,
  employee_number  text,
  employee_id      bigint references public.employees(id),
  customer_name    text,
  rows             int[] not null,
  data             jsonb not null,                -- السند كما ورد أو بعد تصحيحه يدويًا
  norm             jsonb,                         -- السند بعد القراءة والتوحيد (ومع حفظ الأعمدة الغائبة)
  class            text not null check (class in ('new', 'unchanged', 'changed', 'manual_conflict',
                                                  'possible_match', 'deleted_before', 'pending')),
  errors           jsonb not null default '[]',
  warnings         jsonb not null default '[]',
  duplicates       jsonb not null default '[]',
  drop_duplicates  boolean not null default false,
  total            numeric,
  line_count       int,
  doc_id           bigint references public.docs(id),   -- السند المحفوظ المطابق أو الناتج
  outcome          text check (outcome in ('added', 'updated', 'restored', 'no_change', 'kept_existing', 'excluded',
                                           'removed', 'reverted')),
  prev_version     int,                           -- إصدار السند قبل هذه الدفعة
  applied_version  int,                           -- الإصدار الذي أنشأته الدفعة
  conflict_on_delete boolean not null default false,
  fixed            boolean not null default false,
  decided_at       timestamptz,
  decided_by       uuid
);
create index on public.batch_items (batch_id, seq);
create index on public.batch_items (doc_id);

-- ---------------------------------------------------------------------
-- القراءة والتحقق والتوحيد
-- ---------------------------------------------------------------------

-- p_data: {doc_number, customer_number, doc_date, [employee_number, pay_type, customer_name, employee_name], lines: [...]}
-- البند: {row, employee_number, employee_name, customer_name, pay_type, item_number, item_name, net_sales, net_promotions,
--         quantity, bonus, lat, lng} أو للتحصيل {row, employee_number, employee_name, customer_name, amount, pay_method, cheque_no}
-- يعيد {errors, warnings, duplicates, norm}
create or replace function app.validate_doc(p_kind text, p_data jsonb, p_cols text[])
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  e jsonb := '[]'; w jsonb := '[]'; v_dups jsonb := '[]';
  is_col boolean := p_kind = 'collection';
  f_num text := case when is_col then 'الرقم' else 'DocumentNumber' end;
  f_cust text := case when is_col then 'رقم العميل' else 'CustomerNumber' end;
  f_date text := case when is_col then 'التاريخ' else 'DocumentDate' end;
  f_emp text := case when is_col then 'رقم المندوب' else 'EmployeeNumber' end;
  v_lines jsonb := coalesce(p_data->'lines', '[]');
  r0 int := coalesce(nullif(v_lines->0->>'row', '')::int, 0);
  v_num text := nullif(trim(p_data->>'doc_number'), '');
  v_cust text := nullif(trim(p_data->>'customer_number'), '');
  v_date_raw text := nullif(trim(p_data->>'doc_date'), '');
  v_date date;
  v_emp text; v_emps text[];
  v_pay text; v_pays text[];
  v_has_qty boolean := 'Quantity' = any(p_cols);
  v_has_pay boolean := 'DocumentTypeID' = any(p_cols);
  v_out jsonb := '[]';
  l jsonb; nl jsonb; v_row int; v text; i int; vals text[];
  fields text[] := array['net_sales', 'net_promotions', 'quantity', 'bonus'];
  heads  text[] := array['NetSales', 'NetPromotions', 'Quantity', 'Bonus'];
  v_item text; v_lat text; v_lng text; v_pm text;
  v_unknown_items text[] := '{}';
begin
  if jsonb_array_length(v_lines) = 0 then
    e := e || app.err(r0, '—', null, 'السند بلا بنود');
  end if;

  -- الهوية والتاريخ (B050، B051)
  if v_num is null then e := e || app.err(r0, f_num, null, 'رقم السند مفقود؛ يبقى الصف ضمن أخطاء الدفعة دون تجميع'); end if;
  if v_cust is null then
    e := e || app.err(r0, f_cust, null, 'رقم العميل مفقود؛ يبقى الصف ضمن أخطاء الدفعة دون تجميع');
  elsif not exists (select 1 from public.customers where customer_number = v_cust) then
    e := e || app.err(r0, f_cust, v_cust, 'عميل غير معرّف: ' || v_cust || '؛ عرّفه في صفحة العملاء ثم أعد الفحص أو الرفع');
  end if;
  if v_date_raw is null then
    e := e || app.err(r0, f_date, null, 'تاريخ السند مفقود');
  elsif app.is_bad_date(v_date_raw) then
    e := e || app.err(r0, f_date, v_date_raw, 'تاريخ غير مقروء؛ الصيغة المعتمدة يوم/شهر/سنة');
  else
    v_date := app.to_date(v_date_raw);
  end if;

  -- الموظف: واحد للسند (DATA-010)
  if nullif(trim(p_data->>'employee_number'), '') is not null then
    v_emps := array[trim(p_data->>'employee_number')];
  else
    select coalesce(array_agg(distinct trim(x->>'employee_number')), '{}') into v_emps
      from jsonb_array_elements(v_lines) x where nullif(trim(x->>'employee_number'), '') is not null;
  end if;
  if coalesce(array_length(v_emps, 1), 0) = 0 then
    e := e || app.err(r0, f_emp, null, 'رقم الموظف مفقود؛ لا يُسند السند إلى موظف آخر تلقائيًا');
  elsif array_length(v_emps, 1) > 1 then
    e := e || app.err(r0, f_emp, array_to_string(v_emps, '، '), 'أرقام موظفين مختلفة داخل السند نفسه');
  else
    v_emp := v_emps[1];
    if not exists (select 1 from public.employees where emp_number = v_emp) then
      e := e || app.err(r0, f_emp, v_emp, 'موظف غير معرّف: ' || v_emp || '؛ عرّفه في صفحة الموظفين ثم أعد الفحص أو الرفع');
    end if;
  end if;

  -- نوع الفاتورة (INV-011): «فاتورة نقدي» أو «فاتورة ذمم» فقط
  if p_kind = 'invoice' and (v_has_pay or p_data ? 'pay_type') then
    if p_data ? 'pay_type' then
      v_pays := array[coalesce(trim(p_data->>'pay_type'), '')];
    else
      select coalesce(array_agg(distinct coalesce(trim(x->>'pay_type'), '')), '{}') into v_pays from jsonb_array_elements(v_lines) x;
    end if;
    if array_length(v_pays, 1) > 1 then
      e := e || app.err(r0, 'DocumentTypeID', array_to_string(v_pays, '، '), 'نوع الفاتورة مختلف بين صفوف السند');
    elsif coalesce(v_pays[1], '') = '' then
      e := e || app.err(r0, 'DocumentTypeID', null, 'قيمة DocumentTypeID فارغة؛ المقبول «فاتورة نقدي» أو «فاتورة ذمم»');
    elsif v_pays[1] not in ('فاتورة نقدي', 'فاتورة ذمم') then
      e := e || app.err(r0, 'DocumentTypeID', v_pays[1], 'قيمة DocumentTypeID غير مقبولة: ' || v_pays[1] || '؛ المقبول «فاتورة نقدي» أو «فاتورة ذمم»');
    else
      v_pay := v_pays[1];
    end if;
  end if;

  -- البنود
  for l in select value from jsonb_array_elements(v_lines) loop
    v_row := coalesce(nullif(l->>'row', '')::int, 0);
    if is_col then
      v := nullif(trim(l->>'amount'), '');
      if v is null then e := e || app.err(v_row, 'القيمة', null, 'القيمة مفقودة');
      elsif app.is_bad_num(v) then e := e || app.err(v_row, 'القيمة', v, 'مبلغ غير مقروء'); v := null;
      elsif v::numeric < 0 then w := w || app.err(v_row, 'القيمة', v, 'قيمة سالبة تحتاج مراجعة');
      end if;
      v_pm := nullif(trim(l->>'pay_method'), '');
      if v_pm is null then
        e := e || app.err(v_row, 'الدفع', null, 'قيمة الدفع فارغة؛ المقبول «نقدي» أو «شيك مؤجل» أو «شيك مستحق الدفع»');
      elsif v_pm not in ('نقدي', 'شيك مؤجل', 'شيك مستحق الدفع') then
        e := e || app.err(v_row, 'الدفع', v_pm, 'قيمة الدفع ' || v_pm || ' غير مقبولة؛ المقبول «نقدي» أو «شيك مؤجل» أو «شيك مستحق الدفع»');
      end if;
      nl := jsonb_build_object('row', v_row, 'amount', case when v is not null then app.nnum(v) end, 'pay_method', v_pm,
                               'cheque_no', nullif(trim(l->>'cheque_no'), ''));
    else
      v_item := nullif(trim(l->>'item_number'), '');
      if v_item is null then
        e := e || app.err(v_row, 'ItemNumber', null, 'رقم الصنف مفقود');
      elsif not exists (select 1 from public.products where code = v_item) then
        if not v_item = any(v_unknown_items) then
          e := e || app.err(v_row, 'ItemNumber', v_item, 'صنف غير معرّف: ' || v_item || '؛ عرّفه في صفحة المنتجات ثم أعد الفحص أو الرفع');
          v_unknown_items := v_unknown_items || v_item;
        end if;
      end if;
      vals := array[null, null, null, null];
      for i in 1..4 loop
        v := nullif(trim(l->>fields[i]), '');
        if fields[i] = 'quantity' and not v_has_qty then v := null; end if;
        if v is null then
          if fields[i] <> 'quantity' then e := e || app.err(v_row, heads[i], null, 'قيمة مفقودة'); end if;
        elsif app.is_bad_num(v) then
          e := e || app.err(v_row, heads[i], v, case when fields[i] in ('quantity', 'bonus') then 'كمية غير مقروءة' else 'مبلغ غير مقروء' end);
        else
          vals[i] := app.nnum(v);
          if vals[i]::numeric < 0 then
            if p_kind = 'return' then
              e := e || app.err(v_row, heads[i], v, 'قيمة سالبة في المرتجع؛ صحّحها يدويًا قبل الاعتماد دون تحويل آلي للإشارة');
            else
              w := w || app.err(v_row, heads[i], v, 'قيمة سالبة تحتاج مراجعة');
            end if;
          end if;
        end if;
      end loop;
      -- قيمة موجبة مع كمية صفر: تنبيه مراجعة دون اختراع كمية (B052)
      if vals[3] is not null and vals[3]::numeric = 0 and coalesce(vals[1]::numeric, 0) + coalesce(vals[2]::numeric, 0) > 0 then
        w := w || app.err(v_row, 'Quantity', vals[3], 'قيمة بيع موجبة مع كمية صفر؛ مراجعة دون اختراع كمية');
      end if;
      -- الموقع لا يمنع الاعتماد المالي (MAP-015)
      v_lat := nullif(trim(l->>'lat'), ''); v_lng := nullif(trim(l->>'lng'), '');
      if v_lat is not null or v_lng is not null then
        if app.is_bad_num(v_lat) or app.is_bad_num(v_lng) or v_lat is null or v_lng is null
           or v_lat::numeric not between -90 and 90 or v_lng::numeric not between -180 and 180 then
          w := w || app.err(v_row, 'Latitude/Longitude', coalesce(v_lat, '') || ', ' || coalesce(v_lng, ''),
                            'إحداثيات غير صالحة؛ لا تمنع الاعتماد المالي ويبقى السند بلا موقع');
          v_lat := null; v_lng := null;
        else
          v_lat := app.nnum(v_lat); v_lng := app.nnum(v_lng);
        end if;
      end if;
      nl := jsonb_build_object('row', v_row, 'item_number', v_item, 'item_name', nullif(trim(l->>'item_name'), ''),
                               'net_sales', vals[1], 'net_promotions', vals[2], 'quantity', vals[3], 'bonus', vals[4],
                               'lat', v_lat, 'lng', v_lng);
    end if;
    v_out := v_out || jsonb_build_array(nl);
  end loop;

  -- صفوف متطابقة في الفواتير والمرتجعات: تنبيه وقرار صريح (B047). أجزاء التحصيل المتطابقة تجمع كلها (COL-002).
  if not is_col then
    select coalesce(jsonb_agg(to_jsonb(g.rs) order by g.rs[1]), '[]') into v_dups from (
      select array_agg((x->>'row')::int order by (x->>'row')::int) rs
        from jsonb_array_elements(v_out) x group by (x - 'row')::text having count(*) > 1) g;
    for l in select value from jsonb_array_elements(v_dups) loop
      w := w || app.err((l->>0)::int, '—', (select string_agg(value, '، ') from jsonb_array_elements_text(l)),
                        'صفوف متطابقة تحتاج مراجعة: أبقِها أو استبعد التكرار من النسخة الواردة قبل الاعتماد');
    end loop;
  end if;

  return jsonb_build_object('errors', e, 'warnings', w, 'duplicates', v_dups, 'norm', jsonb_build_object(
    'doc_number', v_num, 'customer_number', v_cust, 'doc_date', v_date, 'employee_number', v_emp,
    'customer_name', coalesce(nullif(trim(p_data->>'customer_name'), ''), (select nullif(trim(x->>'customer_name'), '') from jsonb_array_elements(v_lines) x limit 1)),
    'employee_name', coalesce(nullif(trim(p_data->>'employee_name'), ''), (select nullif(trim(x->>'employee_name'), '') from jsonb_array_elements(v_lines) x limit 1)),
    'pay_type', v_pay, 'lines', v_out));
end $$;

-- مقارنة نسختين على الأعمدة الواردة فقط؛ ترتيب البنود لا يغيّر السند
create or replace function app.doc_canon(p_kind text, p_d jsonb, p_cols text[]) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'h', jsonb_build_object('doc_number', p_d->'doc_number', 'customer_number', p_d->'customer_number', 'doc_date', p_d->'doc_date',
                            'employee_number', p_d->'employee_number',
                            'pay_type', case when p_kind = 'invoice' and 'DocumentTypeID' = any(p_cols) then p_d->'pay_type' end),
    'l', coalesce((select jsonb_agg(c order by c::text) from (
      select case when p_kind = 'collection' then
               jsonb_build_object('amount', x->'amount', 'pay_method', x->'pay_method',
                                  'cheque_no', case when 'رقم الشيك' = any(p_cols) then x->'cheque_no' end)
             else
               jsonb_build_object('item_number', x->'item_number', 'net_sales', x->'net_sales', 'net_promotions', x->'net_promotions',
                                  'bonus', x->'bonus', 'quantity', case when 'Quantity' = any(p_cols) then x->'quantity' end,
                                  'lat', case when 'Latitude' = any(p_cols) then x->'lat' end,
                                  'lng', case when 'Longitude' = any(p_cols) then x->'lng' end)
             end c
        from jsonb_array_elements(p_d->'lines') x) s), '[]'))
$$;

-- نسخة ناقصة الأعمدة لا تمحو ما حُفظ من كمية أو موقع أو نوع أو رقم شيك (B053)
create or replace function app.merge_absent(p_kind text, p_new jsonb, p_old jsonb, p_cols text[]) returns jsonb
language plpgsql immutable as $$
declare
  res jsonb := p_new; v_out jsonb := '[]'; l jsonb; m jsonb; k text; n int; seen jsonb := '{}';
  keep_qty boolean := not ('Quantity' = any(p_cols));
  keep_loc boolean := not ('Longitude' = any(p_cols) and 'Latitude' = any(p_cols));
  keep_chq boolean := not ('رقم الشيك' = any(p_cols));
begin
  if p_old is null then return p_new; end if;
  if p_kind = 'invoice' and not ('DocumentTypeID' = any(p_cols)) then
    res := jsonb_set(res, '{pay_type}', coalesce(p_old->'pay_type', 'null'));
  end if;
  if not ('Customername' = any(p_cols) or 'العميل' = any(p_cols)) then
    res := jsonb_set(res, '{customer_name}', coalesce(p_old->'customer_name', 'null'));
  end if;
  if not ('EmployeeName' = any(p_cols) or 'المندوب' = any(p_cols)) then
    res := jsonb_set(res, '{employee_name}', coalesce(p_old->'employee_name', 'null'));
  end if;
  if (p_kind = 'collection' and not keep_chq) or (p_kind <> 'collection' and not keep_qty and not keep_loc) then
    return res;
  end if;
  for l in select value from jsonb_array_elements(res->'lines') loop
    k := case when p_kind = 'collection' then coalesce(l->>'amount', '') || '|' || coalesce(l->>'pay_method', '')
              else coalesce(l->>'item_number', '') end;
    n := coalesce((seen->>k)::int, 0) + 1;
    seen := seen || jsonb_build_object(k, n);
    select x into m from jsonb_array_elements(p_old->'lines') with ordinality t(x, o)
     where (case when p_kind = 'collection' then coalesce(x->>'amount', '') || '|' || coalesce(x->>'pay_method', '')
                 else coalesce(x->>'item_number', '') end) = k
     order by o offset n - 1 limit 1;
    if m is not null then
      if p_kind = 'collection' then
        l := l || jsonb_build_object('cheque_no', m->'cheque_no');
      else
        if keep_qty then l := l || jsonb_build_object('quantity', m->'quantity'); end if;
        if keep_loc then l := l || jsonb_build_object('lat', m->'lat', 'lng', m->'lng'); end if;
      end if;
    end if;
    v_out := v_out || jsonb_build_array(l);
  end loop;
  return jsonb_set(res, '{lines}', v_out);
end $$;

-- استبعاد التكرار الوارد باختيار صريح (B047): يبقى أول صف من كل مجموعة متطابقة
create or replace function app.drop_dup_lines(p_norm jsonb) returns jsonb
language sql immutable as $$
  select jsonb_set(p_norm, '{lines}', coalesce((
    select jsonb_agg(x order by o) from (
      select x, o, row_number() over (partition by (x - 'row')::text order by o) rn
        from jsonb_array_elements(p_norm->'lines') with ordinality t(x, o)) s where rn = 1), '[]'))
$$;

-- الإصدار الحالي للسند بصيغة السند الموحد
create or replace function app.doc_snapshot(p_doc bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select v.data from public.docs d join public.doc_versions v on v.doc_id = d.id and v.version = d.version where d.id = p_doc
$$;

-- كتابة إصدار جديد للسند (أو إنشاؤه) من السند الموحد، مع البنود والمجاميع والإصدار
create or replace function app.write_doc(p_doc bigint, p_kind text, p_norm jsonb, p_status text, p_batch bigint,
                                         p_source text, p_manual boolean, p_reason text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare
  v_id bigint := p_doc; v_cust bigint; v_emp bigint; v_lat numeric; v_lng numeric; v_ver int;
begin
  select id into v_cust from public.customers where customer_number = p_norm->>'customer_number';
  select id into v_emp from public.employees where emp_number = p_norm->>'employee_number';
  if v_cust is null or v_emp is null then perform app.fail('unknown_ref', 'العميل أو الموظف غير معرّف'); end if;
  select (x->>'lat')::numeric, (x->>'lng')::numeric into v_lat, v_lng
    from jsonb_array_elements(p_norm->'lines') x where x->>'lat' is not null and x->>'lng' is not null limit 1;
  if v_id is null then
    insert into public.docs (kind, doc_number, customer_number, doc_date, orig_doc_number, orig_customer_number, orig_doc_date,
                             customer_id, employee_id, customer_name_src, employee_name_src, pay_type, lat, lng, status,
                             version, manual_edit, created_batch_id, last_batch_id)
    values (p_kind, p_norm->>'doc_number', p_norm->>'customer_number', (p_norm->>'doc_date')::date,
            p_norm->>'doc_number', p_norm->>'customer_number', (p_norm->>'doc_date')::date,
            v_cust, v_emp, p_norm->>'customer_name', p_norm->>'employee_name', p_norm->>'pay_type', v_lat, v_lng, p_status,
            1, p_manual, p_batch, p_batch)
    returning id, version into v_id, v_ver;
  else
    update public.docs set doc_number = p_norm->>'doc_number', customer_number = p_norm->>'customer_number',
           doc_date = (p_norm->>'doc_date')::date, customer_id = v_cust, employee_id = v_emp,
           customer_name_src = p_norm->>'customer_name', employee_name_src = p_norm->>'employee_name',
           pay_type = p_norm->>'pay_type', lat = v_lat, lng = v_lng, status = p_status, version = version + 1,
           manual_edit = p_manual, last_batch_id = coalesce(p_batch, last_batch_id), updated_at = now(),
           deleted_at = case when p_status = 'deleted' then now() end
     where id = v_id returning version into v_ver;
  end if;
  delete from public.doc_lines where doc_id = v_id;
  insert into public.doc_lines (doc_id, line_no, product_id, item_number, item_name_src, net_sales, net_promotions, quantity, bonus,
                                lat, lng, amount, pay_method, cheque_no, src_row)
  select v_id, o, p.id, x->>'item_number', x->>'item_name', (x->>'net_sales')::numeric, (x->>'net_promotions')::numeric,
         (x->>'quantity')::numeric, (x->>'bonus')::numeric, (x->>'lat')::numeric, (x->>'lng')::numeric,
         (x->>'amount')::numeric, x->>'pay_method', x->>'cheque_no', nullif(x->>'row', '')::int
    from jsonb_array_elements(p_norm->'lines') with ordinality t(x, o)
    left join public.products p on p.code = x->>'item_number';
  update public.docs d set
    net_sales = coalesce(s.ns, 0), net_promotions = coalesce(s.np, 0),
    total = case when p_kind = 'collection' then coalesce(s.am, 0) else coalesce(s.ns, 0) + coalesce(s.np, 0) end,
    quantity = s.q, bonus = coalesce(s.b, 0), line_count = s.n, pay_methods = s.pm, cheque_numbers = s.ch
    from (select sum(net_sales) ns, sum(net_promotions) np, sum(amount) am, sum(quantity) q, sum(bonus) b, count(*) n,
                 string_agg(distinct pay_method, '، ') pm, string_agg(distinct cheque_no, '، ') ch
            from public.doc_lines where doc_id = v_id) s
   where d.id = v_id;
  insert into public.doc_versions (doc_id, version, source, batch_id, data, status, manual_edit, by_user, by_name, reason)
  values (v_id, v_ver, p_source, p_batch, p_norm, p_status, p_manual, auth.uid(),
          (select display_name from public.app_users where id = auth.uid()), p_reason);
  if p_status = 'active' then
    insert into public.customer_employee_links (customer_id, employee_id) values (v_cust, v_emp) on conflict do nothing;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- تصنيف سند الدفعة (DATA-004، DATA-005، TXN-003، B048، B053، B054)
-- ---------------------------------------------------------------------
create or replace function app.classify_item(p_item bigint) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  it public.batch_items; b public.upload_batches; d public.docs;
  v jsonb; v_norm jsonb; v_old jsonb; v_class text; v_errors jsonb; v_doc bigint;
begin
  select * into it from public.batch_items where id = p_item;
  select * into b from public.upload_batches where id = it.batch_id;
  v := app.validate_doc(b.kind, it.data, b.columns);
  v_norm := v->'norm'; v_errors := v->'errors';
  if v_norm->>'doc_number' is not null and v_norm->>'customer_number' is not null and v_norm->>'doc_date' is not null then
    select * into d from public.docs
     where kind = b.kind and doc_number = v_norm->>'doc_number' and customer_number = v_norm->>'customer_number'
       and doc_date = (v_norm->>'doc_date')::date;
    if not found then
      -- إعادة رفع الأصل بعد تعديل مفتاحه: مطابقة محتملة (B048)
      select * into d from public.docs
       where kind = b.kind and status = 'active' and orig_doc_number = v_norm->>'doc_number'
         and orig_customer_number = v_norm->>'customer_number' and orig_doc_date = (v_norm->>'doc_date')::date
       order by id limit 1;
      if found then v_class := 'possible_match'; end if;
    end if;
  end if;
  v_doc := d.id;
  if v_doc is not null and d.status = 'active' then
    v_old := app.doc_snapshot(v_doc);
    v_norm := app.merge_absent(b.kind, v_norm, v_old, b.columns);
  end if;
  -- نوع الفاتورة غائب عن ملف لسند جديد: لا يُفترض (INV-011)
  if b.kind = 'invoice' and v_norm->>'pay_type' is null and not (b.columns @> array['DocumentTypeID'])
     and (v_doc is null or d.status <> 'active') then
    v_errors := v_errors || app.err(coalesce((it.rows)[1], 0), 'DocumentTypeID', null,
                                    'عمود DocumentTypeID غير موجود في الملف ولا نوع محفوظ لهذه الفاتورة');
  end if;
  if jsonb_array_length(v_errors) > 0 then
    v_class := 'pending';
  elsif v_class = 'possible_match' then
    null;
  elsif v_doc is not null and d.status = 'deleted' then
    v_class := 'deleted_before';
  elsif v_doc is not null then
    if app.doc_canon(b.kind, v_norm, b.columns) = app.doc_canon(b.kind, v_old, b.columns) then v_class := 'unchanged';
    elsif d.manual_edit then v_class := 'manual_conflict';
    else v_class := 'changed'; end if;
  else
    v_class := 'new';
  end if;
  update public.batch_items set
    class = v_class, errors = v_errors, warnings = v->'warnings', duplicates = v->'duplicates', norm = v_norm,
    doc_number = coalesce(v_norm->>'doc_number', nullif(trim(data->>'doc_number'), '')),
    customer_number = coalesce(v_norm->>'customer_number', nullif(trim(data->>'customer_number'), '')),
    doc_date_raw = nullif(trim(data->>'doc_date'), ''), doc_date = (v_norm->>'doc_date')::date,
    employee_number = v_norm->>'employee_number',
    employee_id = (select id from public.employees where emp_number = v_norm->>'employee_number'),
    customer_name = coalesce((select name from public.customers where customer_number = v_norm->>'customer_number'), v_norm->>'customer_name'),
    total = (select sum(coalesce((x->>'net_sales')::numeric, 0) + coalesce((x->>'net_promotions')::numeric, 0) + coalesce((x->>'amount')::numeric, 0))
               from jsonb_array_elements(v_norm->'lines') x),
    line_count = jsonb_array_length(v_norm->'lines'),
    doc_id = v_doc
   where id = p_item;
  return v_class;
end $$;

-- ملخص الدفعة: أعداد السندات حسب التصنيف والقرار (DATA-005: لا تعرض الدفعة معتمدة وفيها معلق)
create or replace function app.batch_summary(p_batch bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'batch_id', p_batch,
    'rows', (select row_count from public.upload_batches where id = p_batch),
    'docs', count(*),
    'awaiting', count(*) filter (where outcome is null),
    'new', count(*) filter (where outcome is null and class = 'new'),
    'unchanged', count(*) filter (where outcome is null and class = 'unchanged'),
    'changed', count(*) filter (where outcome is null and class = 'changed'),
    'manual_conflict', count(*) filter (where outcome is null and class = 'manual_conflict'),
    'possible_match', count(*) filter (where outcome is null and class = 'possible_match'),
    'deleted_before', count(*) filter (where outcome is null and class = 'deleted_before'),
    'pending', count(*) filter (where outcome is null and class = 'pending'),
    'warnings', count(*) filter (where outcome is null and jsonb_array_length(warnings) > 0),
    'added', count(*) filter (where outcome = 'added'),
    'updated', count(*) filter (where outcome in ('updated', 'restored')),
    'no_change', count(*) filter (where outcome = 'no_change'),
    'kept_existing', count(*) filter (where outcome = 'kept_existing'),
    'excluded', count(*) filter (where outcome = 'excluded'),
    'removed', count(*) filter (where outcome = 'removed'),
    'reverted', count(*) filter (where outcome = 'reverted'),
    'conflicts', count(*) filter (where conflict_on_delete))
  from public.batch_items where batch_id = p_batch
$$;

-- ---------------------------------------------------------------------
-- الرفع: قراءة الملف إلى دفعة محفوظة بمعاينتها
-- ---------------------------------------------------------------------

-- p_rows: صفوف الملف كما قرأها التطبيق (نصوص)، مع رقم الصف في Excel
create or replace function public.upload_stage(p_kind text, p_file_name text, p_sheet text, p_columns jsonb, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_cols text[] := (select coalesce(array_agg(trim(c)), '{}') from jsonb_array_elements_text(p_columns) c);
  v_batch bigint; v_missing text[]; g record; v_seq int := 0; v_id bigint;
begin
  perform app.require_perm('P05', 'import');
  if p_kind not in ('invoice', 'return', 'collection') then perform app.fail('bad_kind', 'نوع الحركة غير معروف'); end if;
  select array_agg(c) into v_missing from unnest(app.required_columns(p_kind)) c where not c = any(v_cols);
  if v_missing is not null then
    perform app.fail('missing_columns', 'أعمدة مطلوبة غير موجودة في الملف: ' || array_to_string(v_missing, '، '));
  end if;
  if coalesce(jsonb_array_length(p_rows), 0) = 0 then perform app.fail('empty', 'الملف لا يحتوي صفوف بيانات'); end if;
  insert into public.upload_batches (kind, file_name, sheet_name, columns, row_count, uploaded_by, uploaded_by_name)
  values (p_kind, p_file_name, p_sheet, v_cols, jsonb_array_length(p_rows), auth.uid(),
          (select display_name from public.app_users where id = auth.uid()))
  returning id into v_batch;
  -- السند = تطابق العناصر الثلاثة (DATA-003)؛ الصف الناقص الهوية يبقى وحده دون تجميع (B050)
  for g in
    select k, jsonb_agg(x order by (x->>'row')::int) lines, array_agg((x->>'row')::int order by (x->>'row')::int) rws,
           min((x->>'row')::int) first_row
      from (select x, case when nullif(trim(x->>'doc_number'), '') is null or nullif(trim(x->>'customer_number'), '') is null
                             or nullif(trim(x->>'doc_date'), '') is null
                           then 'row:' || (x->>'row')
                           else trim(x->>'doc_number') || '|' || trim(x->>'customer_number') || '|' || trim(x->>'doc_date') end k
              from jsonb_array_elements(p_rows) x) s
     group by k order by first_row
  loop
    v_seq := v_seq + 1;
    insert into public.batch_items (batch_id, seq, rows, data, class)
    values (v_batch, v_seq, g.rws, jsonb_build_object('doc_number', g.lines->0->>'doc_number', 'customer_number', g.lines->0->>'customer_number',
                                                      'doc_date', g.lines->0->>'doc_date',
                                                      'lines', (select jsonb_agg(x - 'doc_number' - 'customer_number' - 'doc_date')
                                                                  from jsonb_array_elements(g.lines) x)), 'new')
    returning id into v_id;
    perform app.classify_item(v_id);
  end loop;
  perform app.audit('upload_batches', v_batch::text, 'upload', null,
                    jsonb_build_object('kind', p_kind, 'file', p_file_name, 'rows', jsonb_array_length(p_rows)));
  return app.batch_summary(v_batch);
end $$;

-- تفاصيل سند الدفعة: كامل الوارد مقابل المحفوظ (P05)
create or replace function public.upload_item_detail(p_item bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  it public.batch_items; v_kind text;
begin
  perform app.require_perm('P05', 'view');
  select * into it from public.batch_items where id = p_item;
  if not found then perform app.fail('not_found', 'السند غير موجود في الدفعة'); end if;
  if it.employee_id is not null and not app.can_see_employee(it.employee_id) then
    perform app.fail('forbidden', 'السند خارج نطاق بياناتك');
  end if;
  if it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id)) then
    perform app.fail('forbidden', 'السند المحفوظ خارج نطاق بياناتك');
  end if;
  select kind into v_kind from public.upload_batches where id = it.batch_id;
  return jsonb_build_object('item', to_jsonb(it), 'kind', v_kind,
    'existing', case when it.doc_id is not null then app.doc_snapshot(it.doc_id) end,
    'existing_status', (select status from public.docs where id = it.doc_id),
    'existing_manual', (select manual_edit from public.docs where id = it.doc_id),
    'existing_version', (select version from public.docs where id = it.doc_id));
end $$;

-- تصحيح سند معلق يدويًا ثم إعادة فحصه (DATA-005)
create or replace function public.upload_fix_item(p_item bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  it public.batch_items; v_class text; v_old jsonb;
begin
  perform app.require_perm('P05', 'approve');
  select * into it from public.batch_items where id = p_item for update;
  if not found then perform app.fail('not_found', 'السند غير موجود في الدفعة'); end if;
  if it.outcome is not null then perform app.fail('decided', 'سبق اتخاذ قرار في هذا السند'); end if;
  if (select status from public.upload_batches where id = it.batch_id) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة');
  end if;
  if it.employee_id is not null and not app.can_see_employee(it.employee_id) then
    perform app.fail('forbidden', 'السند خارج نطاق بياناتك');
  end if;
  v_old := it.data;
  update public.batch_items set data = p_data, fixed = true where id = p_item;
  v_class := app.classify_item(p_item);
  -- التصحيح لا ينقل السند إلى موظف أو سند محفوظ خارج النطاق (B072)
  select * into it from public.batch_items where id = p_item;
  if (it.employee_id is not null and not app.can_see_employee(it.employee_id))
     or (it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id))) then
    perform app.fail('forbidden', 'التصحيح يجعل السند خارج نطاق بياناتك');
  end if;
  perform app.audit('upload_batches', it.batch_id::text, 'fix_item', v_old, p_data);
  return jsonb_build_object('class', v_class, 'summary', app.batch_summary(it.batch_id));
end $$;

-- إعادة فحص السندات غير المقررة بعد تعريف رمز ناقص (DATA-010)
create or replace function public.upload_recheck(p_batch bigint) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x record;
begin
  perform app.require_perm('P05', 'import');
  for x in select id from public.batch_items where batch_id = p_batch and outcome is null order by seq loop
    perform app.classify_item(x.id);
  end loop;
  return app.batch_summary(p_batch);
end $$;

-- قرارات المعاينة. p_decisions: [{id, action, drop_duplicates}]
-- action: approve (جديد/متغير/مطابق) | use_file (اعتماد بيانات الملف بدل التعديل اليدوي أو للمطابق المحتمل)
--         | restore (استعادة صريحة لسبق حذفه) | keep (إبقاء المحفوظ) | exclude (استبعاد من الدفعة)
create or replace function public.upload_resolve(p_batch bigint, p_decisions jsonb, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  dcs jsonb; it public.batch_items; b public.upload_batches; v_class text; v_act text; v_norm jsonb;
  v_doc bigint; v_prev int; v_old_date date; v_skipped jsonb := '[]'; v_outcome text; v_ver int;
begin
  perform app.require_perm('P05', 'approve');
  select * into b from public.upload_batches where id = p_batch for update;
  if not found then perform app.fail('not_found', 'الدفعة غير موجودة'); end if;
  if b.status = 'deleted' then perform app.fail('batch_deleted', 'الدفعة محذوفة'); end if;
  for dcs in select value from jsonb_array_elements(coalesce(p_decisions, '[]')) loop
    select * into it from public.batch_items where id = (dcs->>'id')::bigint and batch_id = p_batch for update;
    if not found or it.outcome is not null then continue; end if;   -- قرار سابق: لا تكرار (إعادة المحاولة بعد الانقطاع)
    if (it.employee_id is not null and not app.can_see_employee(it.employee_id))
       or (it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id))) then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'السند خارج نطاق بياناتك'); continue;
    end if;
    v_act := dcs->>'action';
    if v_act = 'exclude' then
      update public.batch_items set outcome = 'excluded', decided_at = now(), decided_by = auth.uid() where id = it.id;
      continue;
    end if;
    -- إعادة الفحص على البيانات الحالية قبل التنفيذ (DATA-005)
    v_class := app.classify_item(it.id);
    select * into it from public.batch_items where id = it.id;
    if it.doc_id is not null and not app.can_see_employee((select employee_id from public.docs where id = it.doc_id)) then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'السند خارج نطاق بياناتك'); continue;
    end if;
    v_outcome := null; v_doc := it.doc_id; v_norm := it.norm;
    if coalesce((dcs->>'drop_duplicates')::boolean, false) and b.kind <> 'collection' then
      v_norm := app.drop_dup_lines(v_norm);
      update public.batch_items set drop_duplicates = true where id = it.id;
    end if;
    if v_class = 'pending' then
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'معلق بأخطاء تمنع الاعتماد'); continue;
    elsif v_act = 'keep' and v_class in ('manual_conflict', 'possible_match', 'deleted_before', 'changed') then
      v_outcome := 'kept_existing';
    elsif v_act = 'approve' and v_class = 'unchanged' then
      v_outcome := 'no_change';
    elsif (v_act = 'approve' and v_class in ('new', 'changed')) or (v_act = 'use_file' and v_class in ('changed', 'manual_conflict', 'possible_match'))
          or (v_act = 'restore' and v_class = 'deleted_before') then
      v_old_date := (select doc_date from public.docs where id = v_doc);
      perform app.guard_dates(array[(v_norm->>'doc_date')::date, v_old_date], p_code);
      if v_doc is not null then
        if exists (select 1 from public.docs where kind = b.kind and id <> v_doc and doc_number = v_norm->>'doc_number'
                     and customer_number = v_norm->>'customer_number' and doc_date = (v_norm->>'doc_date')::date) then
          v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'المفتاح مستخدم لسند آخر (B049)'); continue;
        end if;
        select version into v_prev from public.docs where id = v_doc for update;
      else
        v_prev := null;
      end if;
      v_doc := app.write_doc(v_doc, b.kind, v_norm, 'active', p_batch,
                             case when v_class = 'deleted_before' then 'restore' else 'upload' end, false);
      select version into v_ver from public.docs where id = v_doc;
      v_outcome := case when v_class = 'new' then 'added' when v_class = 'deleted_before' then 'restored' else 'updated' end;
      update public.batch_items set prev_version = v_prev, applied_version = v_ver, doc_id = v_doc where id = it.id;
    else
      v_skipped := v_skipped || jsonb_build_object('id', it.id, 'reason', 'القرار لا يناسب حالة السند الحالية'); continue;
    end if;
    update public.batch_items set outcome = v_outcome, decided_at = now(), decided_by = auth.uid() where id = it.id;
  end loop;
  update public.upload_batches set status = case when exists (select 1 from public.batch_items where batch_id = p_batch and outcome is null)
                                                 then 'open' else 'closed' end
   where id = p_batch;
  perform app.audit('upload_batches', p_batch::text, 'resolve', null, p_decisions);
  return app.batch_summary(p_batch) || jsonb_build_object('skipped', v_skipped);
end $$;

-- ---------------------------------------------------------------------
-- حذف الدفعة كتراجع عن أثرها (DATA-007، B054) وحذف السند (TXN-004)
-- ---------------------------------------------------------------------
create or replace function app.batch_delete_plan(p_batch bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  with x as (
    select i.*, d.version cur_version, d.total doc_total, d.doc_date cur_date,
           case
             when i.outcome = 'added' and d.version = i.applied_version then 'remove'
             when i.outcome in ('updated', 'restored') and d.version = i.applied_version then 'revert'
             when i.outcome in ('added', 'updated', 'restored') then 'conflict'
             when i.outcome is null then 'exclude'
             else 'none'
           end act
      from public.batch_items i left join public.docs d on d.id = i.doc_id
     where i.batch_id = p_batch)
  select jsonb_build_object(
    'remove', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                         'customer_number', customer_number, 'doc_date', doc_date, 'total', doc_total) order by seq)
                          from x where act = 'remove'), '[]'),
    'revert', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                         'customer_number', customer_number, 'doc_date', doc_date, 'total', doc_total,
                                         'restore_total', (select sum(coalesce((l->>'net_sales')::numeric, 0) + coalesce((l->>'net_promotions')::numeric, 0)
                                                                      + coalesce((l->>'amount')::numeric, 0))
                                                             from public.doc_versions v, jsonb_array_elements(v.data->'lines') l
                                                            where v.doc_id = x.doc_id and v.version = x.prev_version),
                                         'restore_status', (select status from public.doc_versions v where v.doc_id = x.doc_id and v.version = x.prev_version))
                                         order by seq)
                          from x where act = 'revert'), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('item_id', id, 'doc_id', doc_id, 'doc_number', doc_number,
                                            'customer_number', customer_number, 'doc_date', doc_date) order by seq)
                             from x where act = 'conflict'), '[]'),
    'exclude', (select count(*) from x where act = 'exclude'),
    'unchanged', (select count(*) from x where act = 'none'),
    'remove_total', (select coalesce(sum(doc_total), 0) from x where act = 'remove'),
    'revert_total', (select coalesce(sum(doc_total), 0) from x where act = 'revert'))
$$;

-- حذف الدفعة يمس كل سنداتها، فيلزم أن تكون كلها ضمن نطاق المستخدم (B072)
create or replace function app.require_batch_scope(p_batch bigint) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.scope_is_all() then return; end if;
  if exists (select 1 from public.batch_items i left join public.docs d on d.id = i.doc_id
              where i.batch_id = p_batch
                and ((i.employee_id is not null and not app.can_see_employee(i.employee_id))
                     or (d.id is not null and not app.can_see_employee(d.employee_id)))) then
    perform app.fail('forbidden', 'الدفعة تشمل سندات خارج نطاق بياناتك؛ يحذفها من يملك نطاقها كاملًا');
  end if;
end $$;

create or replace function public.preview_delete_batch(p_batch bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_perm('P05', 'delete');
  perform app.require_batch_scope(p_batch);
  if (select status from public.upload_batches where id = p_batch) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة مسبقًا');
  end if;
  return app.batch_delete_plan(p_batch);
end $$;

create or replace function public.delete_batch(p_batch bigint, p_reason text, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  v_plan jsonb; x jsonb; v_kind text; v_snap record; v_dates date[] := '{}';
begin
  perform app.require_perm('P05', 'delete');
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب حذف الدفعة مطلوب'); end if;
  select kind into v_kind from public.upload_batches where id = p_batch for update;
  if not found then perform app.fail('not_found', 'الدفعة غير موجودة'); end if;
  if (select status from public.upload_batches where id = p_batch) = 'deleted' then
    perform app.fail('batch_deleted', 'الدفعة محذوفة مسبقًا');
  end if;
  perform app.require_batch_scope(p_batch);
  v_plan := app.batch_delete_plan(p_batch);
  select array_agg(d.doc_date) into v_dates from public.docs d
   where d.id in (select (e->>'doc_id')::bigint from jsonb_array_elements((v_plan->'remove') || (v_plan->'revert')) e);
  v_dates := coalesce(v_dates, '{}') || coalesce((select array_agg((v.data->>'doc_date')::date) from public.doc_versions v
     join public.batch_items i on i.doc_id = v.doc_id and v.version = i.prev_version
    where i.id in (select (e->>'item_id')::bigint from jsonb_array_elements(v_plan->'revert') e)), '{}');
  perform app.guard_dates(v_dates, p_code);
  for x in select value from jsonb_array_elements(v_plan->'remove') loop
    perform app.write_doc((x->>'doc_id')::bigint, v_kind, app.doc_snapshot((x->>'doc_id')::bigint), 'deleted', null, 'batch_delete',
                          false, p_reason);
    update public.batch_items set outcome = 'removed' where id = (x->>'item_id')::bigint;
  end loop;
  for x in select value from jsonb_array_elements(v_plan->'revert') loop
    select v.data, v.status, v.manual_edit into v_snap from public.doc_versions v
      join public.batch_items i on i.doc_id = v.doc_id and v.version = i.prev_version
     where i.id = (x->>'item_id')::bigint;
    perform app.write_doc((x->>'doc_id')::bigint, v_kind, v_snap.data, v_snap.status, null, 'batch_revert', v_snap.manual_edit, p_reason);
    update public.batch_items set outcome = 'reverted' where id = (x->>'item_id')::bigint;
  end loop;
  -- المتعارض يعزل للمراجعة دون حذف أو استعادة إصدار أقدم (B054)
  update public.batch_items set conflict_on_delete = true
   where id in (select (e->>'item_id')::bigint from jsonb_array_elements(v_plan->'conflicts') e);
  update public.batch_items set outcome = 'excluded', decided_at = now(), decided_by = auth.uid()
   where batch_id = p_batch and outcome is null;
  update public.upload_batches set status = 'deleted', deleted_at = now(), deleted_by = auth.uid(), delete_reason = p_reason
   where id = p_batch;
  perform app.audit('upload_batches', p_batch::text, 'delete_batch', null, v_plan, p_reason);
  return v_plan;
end $$;

-- ---------------------------------------------------------------------
-- صفحات الحركات: التحرير الكامل والنقل والحذف (TXN-001، TXN-002، TXN-004، B049، AUTH-004)
-- ---------------------------------------------------------------------
create or replace function app.visible_doc(p_doc bigint) returns public.docs
language plpgsql stable security definer set search_path = public, app as $$
declare
  d public.docs;
begin
  select * into d from public.docs where id = p_doc;
  if not found or d.status <> 'active' then perform app.fail('not_found', 'السند غير موجود أو محذوف'); end if;
  if not app.can_see_employee(d.employee_id) then perform app.fail('forbidden', 'السند خارج نطاق بياناتك'); end if;
  return d;
end $$;

-- p_data بصيغة السند الموحد: {doc_number, customer_number, doc_date, employee_number, pay_type, lines: [...]}
create or replace function public.save_doc(p_doc bigint, p_data jsonb, p_reason text default null, p_code text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare
  d public.docs; v jsonb; v_norm jsonb; v_before jsonb; v_msg text;
begin
  perform app.require_perm('P06', 'edit');
  d := app.visible_doc(p_doc);
  v := app.validate_doc(d.kind, p_data, app.all_columns(d.kind));
  if jsonb_array_length(v->'errors') > 0 then
    select string_agg(case when (e->>'row')::int > 0 then 'البند ' || (e->>'row') || ': ' else '' end || (e->>'message'), ' — ')
      into v_msg from (select e from jsonb_array_elements(v->'errors') e limit 5) s;
    perform app.fail('invalid_doc', v_msg);
  end if;
  v_norm := v->'norm';
  if (select id from public.employees where emp_number = v_norm->>'employee_number') is distinct from d.employee_id then
    perform app.require_perm('P06', 'transfer');
    if not app.can_see_employee((select id from public.employees where emp_number = v_norm->>'employee_number')) then
      perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك');
    end if;
  end if;
  if d.kind = 'invoice' and v_norm->>'pay_type' is null then
    perform app.fail('invalid_doc', 'نوع الفاتورة مطلوب: «فاتورة نقدي» أو «فاتورة ذمم»');
  end if;
  if exists (select 1 from public.docs where kind = d.kind and id <> d.id and doc_number = v_norm->>'doc_number'
               and customer_number = v_norm->>'customer_number' and doc_date = (v_norm->>'doc_date')::date) then
    perform app.fail('key_collision', 'المفتاح المعدل (رقم السند والعميل والتاريخ) مستخدم لسند آخر؛ لا يُحفظ حتى يُحل التصادم دون دمج');
  end if;
  perform app.guard_dates(array[d.doc_date, (v_norm->>'doc_date')::date], p_code);
  v_before := app.doc_snapshot(d.id);
  if app.doc_canon(d.kind, v_norm, app.all_columns(d.kind)) = app.doc_canon(d.kind, v_before, app.all_columns(d.kind))
     and v_norm->>'customer_name' is not distinct from v_before->>'customer_name' then
    return d.id;   -- لا تغيير
  end if;
  perform app.write_doc(d.id, d.kind, v_norm, 'active', null, 'manual', true, p_reason);
  perform app.audit('docs', d.id::text, 'edit', v_before, v_norm, p_reason);
  return d.id;
end $$;

create or replace function public.preview_transfer(p_doc_ids jsonb, p_employee_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  p_ids bigint[] := (select coalesce(array_agg(x::bigint), '{}') from jsonb_array_elements_text(p_doc_ids) x);
  v_emp public.employees;
begin
  perform app.require_perm('P06', 'transfer');
  select * into v_emp from public.employees where emp_number = trim(p_employee_number);
  if not found then perform app.fail('unknown_employee', 'موظف غير معرّف: ' || coalesce(p_employee_number, '')); end if;
  if not app.can_see_employee(v_emp.id) then perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك'); end if;
  return (
    select jsonb_build_object(
      'to', jsonb_build_object('emp_number', v_emp.emp_number, 'name', v_emp.name),
      'count', count(*) filter (where d.employee_id <> v_emp.id),
      'already', count(*) filter (where d.employee_id = v_emp.id),
      'total', coalesce(sum(d.total) filter (where d.employee_id <> v_emp.id), 0)::text,
      'from', coalesce((select jsonb_agg(jsonb_build_object('emp_number', e.emp_number, 'name', e.name, 'count', g.n, 'total', g.t::text) order by e.emp_number)
                          from (select employee_id, count(*) n, sum(total) t from public.docs
                                 where id = any(p_ids) and status = 'active' and app.can_see_employee(employee_id) and employee_id <> v_emp.id
                                 group by employee_id) g join public.employees e on e.id = g.employee_id), '[]'))
      from public.docs d where d.id = any(p_ids) and d.status = 'active' and app.can_see_employee(d.employee_id));
end $$;

-- نقل سند أو مجموعة إلى موظف آخر: يتغير الإسناد كاملًا والمبالغ ثابتة (TXN-002)
create or replace function public.transfer_docs(p_doc_ids jsonb, p_employee_number text, p_reason text default null,
                                                p_code text default null)
returns int language plpgsql security definer set search_path = public, app as $$
declare
  p_ids bigint[] := (select coalesce(array_agg(x::bigint), '{}') from jsonb_array_elements_text(p_doc_ids) x);
  v_emp public.employees; d public.docs; v_snap jsonb; n int := 0;
begin
  perform app.require_perm('P06', 'transfer');
  select * into v_emp from public.employees where emp_number = trim(p_employee_number);
  if not found then perform app.fail('unknown_employee', 'موظف غير معرّف: ' || coalesce(p_employee_number, '')); end if;
  if not app.can_see_employee(v_emp.id) then perform app.fail('forbidden', 'الموظف الجديد خارج نطاق بياناتك'); end if;
  perform app.guard_dates((select array_agg(doc_date) from public.docs where id = any(p_ids) and status = 'active'), p_code);
  for d in select * from public.docs where id = any(p_ids) and status = 'active' order by id for update loop
    if not app.can_see_employee(d.employee_id) then perform app.fail('forbidden', 'سند خارج نطاق بياناتك: ' || d.doc_number); end if;
    if d.employee_id = v_emp.id then continue; end if;
    v_snap := app.doc_snapshot(d.id);
    perform app.write_doc(d.id, d.kind, v_snap || jsonb_build_object('employee_number', v_emp.emp_number, 'employee_name', v_emp.name),
                          'active', null, 'transfer', true, p_reason);
    perform app.audit('docs', d.id::text, 'transfer', jsonb_build_object('employee_number', v_snap->>'employee_number'),
                      jsonb_build_object('employee_number', v_emp.emp_number), p_reason);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.delete_doc(p_doc bigint, p_reason text, p_code text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare
  d public.docs;
begin
  if not (app.has_perm('P06', 'delete') or app.has_perm('P05', 'delete')) then
    perform app.fail('forbidden', 'لا تملك صلاحية هذا الإجراء');
  end if;
  if coalesce(trim(p_reason), '') = '' then perform app.fail('reason_required', 'سبب حذف السند مطلوب'); end if;
  d := app.visible_doc(p_doc);
  perform app.guard_dates(array[d.doc_date], p_code);
  perform app.write_doc(d.id, d.kind, app.doc_snapshot(d.id), 'deleted', null, 'delete', d.manual_edit, p_reason);
  perform app.audit('docs', d.id::text, 'delete', jsonb_build_object('doc_number', d.doc_number, 'total', d.total), null, p_reason);
end $$;

-- ---------------------------------------------------------------------
-- عروض القراءة (بصلاحيات المستخدم)
-- ---------------------------------------------------------------------
create or replace view public.docs_v with (security_invoker = true) as
select d.id, d.kind, d.doc_number, d.customer_number, d.doc_date, d.customer_id,
       coalesce(c.name, d.customer_name_src) as customer_name, d.customer_name_src,
       d.employee_id, e.emp_number as employee_number, coalesce(e.name, d.employee_name_src) as employee_name,
       d.pay_type, d.lat, d.lng, (d.lat is not null and d.lng is not null) as has_location,
       d.net_sales, d.net_promotions, d.total, d.quantity, d.bonus, d.line_count, d.pay_methods, d.cheque_numbers,
       d.manual_edit, d.version, d.created_batch_id, d.last_batch_id,
       d.orig_doc_number, d.orig_customer_number, d.orig_doc_date,
       (d.doc_number, d.customer_number, d.doc_date) is distinct from (d.orig_doc_number, d.orig_customer_number, d.orig_doc_date) as key_changed,
       d.status, d.created_at, d.updated_at
  from public.docs d
  left join public.customers c on c.id = d.customer_id
  left join public.employees e on e.id = d.employee_id
 where d.status = 'active';

-- البنود مع السعر الطبيعي التاريخي والكمية المكافئة (QTY-002، B058، B059)
create or replace view public.doc_lines_v with (security_invoker = true) as
select l.id, l.doc_id, l.line_no, l.product_id, l.item_number, coalesce(p.name, l.item_name_src) as item_name,
       l.net_sales, l.net_promotions, coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0) as line_total,
       l.quantity, l.bonus, l.lat, l.lng, l.amount, l.pay_method, l.cheque_no, l.src_row,
       pr.price as sale_price,
       case when pr.price > 0 and d.kind <> 'collection' then (coalesce(l.net_sales, 0) + coalesce(l.net_promotions, 0)) / pr.price end as equivalent_qty
  from public.doc_lines l
  join public.docs d on d.id = l.doc_id
  left join public.products p on p.id = l.product_id
  left join lateral (select app.price_at(l.product_id, 'sale', d.doc_date) as price) pr on true;

create or replace view public.upload_batches_v with (security_invoker = true) as
select b.id, b.kind, b.file_name, b.sheet_name, b.row_count, b.status, b.uploaded_by_name, b.uploaded_at,
       b.deleted_at, b.delete_reason, b.columns,
       s.docs, s.added, s.updated, s.no_change, s.kept, s.excluded, s.pending, s.awaiting, s.removed, s.reverted, s.conflicts
  from public.upload_batches b
  left join lateral (
    select count(*) docs,
           count(*) filter (where outcome = 'added') added,
           count(*) filter (where outcome in ('updated', 'restored')) updated,
           count(*) filter (where outcome = 'no_change') no_change,
           count(*) filter (where outcome = 'kept_existing') kept,
           count(*) filter (where outcome = 'excluded') excluded,
           count(*) filter (where outcome is null and class = 'pending') pending,
           count(*) filter (where outcome is null) awaiting,
           count(*) filter (where outcome = 'removed') removed,
           count(*) filter (where outcome = 'reverted') reverted,
           count(*) filter (where conflict_on_delete) conflicts
      from public.batch_items i where i.batch_id = b.id) s on true;

-- البحث في صفحة الحركات مع ملخص كامل النتائج (INV-007، RET-003، COL-005)
-- p_filters: {from, to, number, customer, employee, batch, pay_type, manual, location, pay_method, cheque}
create or replace function public.docs_search(p_kind text, p_filters jsonb, p_sort text default null, p_asc boolean default true,
                                              p_offset int default 0, p_limit int default 50)
returns jsonb language plpgsql stable set search_path = public, app as $$
declare
  f jsonb := coalesce(p_filters, '{}');
  v_where text; v_sort text; v_rows jsonb; v_sum jsonb;
begin
  v_where := format('kind = %L', p_kind);
  if nullif(f->>'from', '') is not null then v_where := v_where || format(' and doc_date >= %L::date', f->>'from'); end if;
  if nullif(f->>'to', '') is not null then v_where := v_where || format(' and doc_date <= %L::date', f->>'to'); end if;
  if nullif(trim(f->>'number'), '') is not null then v_where := v_where || format(' and doc_number like %L', trim(f->>'number') || '%'); end if;
  if nullif(trim(f->>'customer'), '') is not null then
    v_where := v_where || format(' and (customer_number = %L or customer_name ilike %L)', trim(f->>'customer'), '%' || trim(f->>'customer') || '%');
  end if;
  if nullif(trim(f->>'employee'), '') is not null then
    v_where := v_where || format(' and (employee_number = %L or employee_name ilike %L)', trim(f->>'employee'), '%' || trim(f->>'employee') || '%');
  end if;
  if nullif(f->>'batch', '') is not null then
    v_where := v_where || format(' and (created_batch_id = %s or last_batch_id = %s)', (f->>'batch')::bigint, (f->>'batch')::bigint);
  end if;
  if nullif(f->>'pay_type', '') is not null then v_where := v_where || format(' and pay_type = %L', f->>'pay_type'); end if;
  if f->>'manual' = 'yes' then v_where := v_where || ' and manual_edit'; end if;
  if f->>'manual' = 'no' then v_where := v_where || ' and not manual_edit'; end if;
  if f->>'location' = 'yes' then v_where := v_where || ' and has_location'; end if;
  if f->>'location' = 'no' then v_where := v_where || ' and not has_location'; end if;
  if nullif(f->>'pay_method', '') is not null then v_where := v_where || format(' and pay_methods like %L', '%' || (f->>'pay_method') || '%'); end if;
  if nullif(trim(f->>'cheque'), '') is not null then v_where := v_where || format(' and cheque_numbers like %L', '%' || trim(f->>'cheque') || '%'); end if;
  v_sort := case when p_sort in ('doc_number', 'doc_date', 'customer_number', 'customer_name', 'employee_name', 'net_sales',
                                 'net_promotions', 'total', 'quantity', 'bonus', 'pay_type', 'pay_methods', 'line_count')
                 then p_sort else 'doc_date' end;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]'') from (select * from public.docs_v where %s order by %I %s, id %s offset %s %s) t',
                 v_where, v_sort, case when p_asc then 'asc' else 'desc' end, case when p_asc then 'asc' else 'desc' end,
                 greatest(coalesce(p_offset, 0), 0), case when p_limit is null then '' else 'limit ' || p_limit end)
    into v_rows;
  execute format('select jsonb_build_object(''count'', count(*), ''customers'', count(distinct customer_id), ''net_sales'', coalesce(sum(net_sales), 0)::text,
                  ''net_promotions'', coalesce(sum(net_promotions), 0)::text, ''total'', coalesce(sum(total), 0)::text, ''quantity'', sum(quantity)::text,
                  ''bonus'', coalesce(sum(bonus), 0)::text) from public.docs_v where %s', v_where)
    into v_sum;
  return jsonb_build_object('rows', v_rows, 'summary', v_sum);
end $$;

-- ملخص حداثة السندات لكل نوع (UPLOAD-001): أحدث تاريخ سند معتمد وآخر عملية رفع، ضمن نطاق المشاهد
create or replace function public.upload_overview() returns jsonb
language sql stable set search_path = public as $$
  select jsonb_object_agg(k, jsonb_build_object(
    'latest_doc_date', (select max(doc_date) from public.docs where kind = k and status = 'active'),
    'last_upload_at', (select max(uploaded_at) from public.upload_batches where kind = k),
    'last_batch_id', (select id from public.upload_batches where kind = k order by uploaded_at desc, id desc limit 1),
    'open_batches', (select count(*) from public.upload_batches where kind = k and status = 'open')))
  from unnest(array['invoice', 'return', 'collection']) k
$$;

-- سجل إصدارات السند ومصدرها
create or replace function public.doc_history(p_doc bigint) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('version', v.version, 'source', v.source, 'batch_id', v.batch_id,
                  'file_name', b.file_name, 'status', v.status, 'at', v.at, 'by_name', v.by_name, 'reason', v.reason,
                  'employee_number', v.data->>'employee_number', 'doc_number', v.data->>'doc_number',
                  'customer_number', v.data->>'customer_number', 'doc_date', v.data->>'doc_date', 'data', v.data)
                  order by v.version desc), '[]')
    from public.doc_versions v left join public.upload_batches b on b.id = v.batch_id
   where v.doc_id = p_doc and exists (select 1 from public.docs d where d.id = p_doc)
$$;

-- ---------------------------------------------------------------------
-- أمان الصفوف
-- ---------------------------------------------------------------------
alter table public.upload_batches enable row level security;
alter table public.docs           enable row level security;
alter table public.doc_lines      enable row level security;
alter table public.doc_versions   enable row level security;
alter table public.batch_items    enable row level security;

create policy batches_read on public.upload_batches for select to authenticated using (app.has_perm('P05'));
create policy docs_read on public.docs for select to authenticated
  using ((app.has_perm('P06') or app.has_perm('P05')) and app.can_see_employee(employee_id));
create policy doc_lines_read on public.doc_lines for select to authenticated
  using (exists (select 1 from public.docs d where d.id = doc_id));
create policy doc_versions_read on public.doc_versions for select to authenticated
  using (exists (select 1 from public.docs d where d.id = doc_id));
create policy batch_items_read on public.batch_items for select to authenticated
  using (app.has_perm('P05') and (employee_id is null or app.can_see_employee(employee_id)));

select app.apply_grants();
