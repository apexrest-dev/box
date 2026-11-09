-- =============================================================================
-- Trade r6 — F-WH-26 «Ваги й габарити товарів» (APE-119).
--   * ref_product: об'єм одиниці (м³) і габарити довжина × ширина × висота (см); вага одиниці — weight_kg (r3).
--     Якщо задано всі три габарити, об'єм розраховується автоматично (Д × Ш × В / 1 000 000);
--     для послуг вага, об'єм і габарити очищаються (тригер ref_product_r6_biu);
--   * одиниці ваги / об'єму: для товарів з одиницею «кг» / «г» / «т» вага одиниці без значення = 1 / 0,001 / 1000 кг,
--     для «л» / «м3» об'єм одиниці без значення = 0,001 / 1 м³ (лише в розрахунку, у довіднику не записується);
--   * v_cargo_doc_line — рядки товарів документів доставки (реалізація, замовлення клієнта, рахунок на оплату,
--     переміщення, надходження, замовлення постачальнику, повернення від клієнта й постачальнику, видатковий ордер;
--     рахунок — напрям NONE: підсумок у формі, у звіті лише за явним відбором виду, щоб не дублювати замовлення);
--   * v_cargo_line — рядки з вагою й об'ємом одиниці й рядка, ознаки «немає ваги / об'єму» (послуги не враховуються);
--   * v_cargo_doc — шапки документів з підсумком ваги, об'єму, кількості місць (рядків товарів) і рядків без даних;
--   * пакет trade_cargo: unit_weight / unit_volume / volume_of, doc_weight / doc_volume / doc_missing,
--     summary_html (регіон «Вага й об'єм» у формах документів), cargo_html (звіт «Вага й об'єм документів»
--     для планування доставки: відбір період / вид / напрям / організація / склад / лише проведені,
--     вантажопідйомність і об'єм транспорту → % завантаження і перевантаження);
--   * демо: вага й габарити демо-товарів (лише там, де не задано);
--   * меню «Склад / Продажі / Закупівлі → Звіти» — «Вага й об'єм документів» (сторінка 720).
-- Потребує 10 (weight_kg), 24 (organization_id), 40 (ордери). Повторно виконуваний.
-- =============================================================================
set define off

-- ---------------------------------------------------------------- RefProduct: об'єм і габарити
declare
  procedure ddl (p varchar2) is
  begin
    execute immediate p;
  exception when others then
    if sqlcode not in (-1430, -2264, -2275) then raise; end if;   -- колонка / обмеження вже є
  end;
begin
  ddl('alter table ref_product add (volume_m3 number(19,6))');
  ddl('alter table ref_product add (length_cm number(19,1))');
  ddl('alter table ref_product add (width_cm number(19,1))');
  ddl('alter table ref_product add (height_cm number(19,1))');
  ddl('alter table ref_product add constraint ref_product_volume_ck check (volume_m3 is null or volume_m3 >= 0)');
  ddl('alter table ref_product add constraint ref_product_dims_ck check ((length_cm is null or length_cm >= 0)'
      || ' and (width_cm is null or width_cm >= 0) and (height_cm is null or height_cm >= 0))');
end;
/
comment on column ref_product.weight_kg is 'Вага одиниці товару (базової одиниці виміру), кг';
comment on column ref_product.volume_m3 is 'Об''єм одиниці товару, м³ (розраховується з габаритів, якщо задано всі три)';
comment on column ref_product.length_cm is 'Довжина одиниці (упаковки одиниці), см';
comment on column ref_product.width_cm is 'Ширина одиниці, см';
comment on column ref_product.height_cm is 'Висота одиниці, см';

create or replace trigger ref_product_r6_biu
before insert or update on ref_product for each row
begin
  if :new.product_kind = 'SERVICE' then
    :new.weight_kg := null; :new.volume_m3 := null;
    :new.length_cm := null; :new.width_cm := null; :new.height_cm := null;
  elsif :new.length_cm is not null and :new.width_cm is not null and :new.height_cm is not null then
    :new.volume_m3 := round(:new.length_cm * :new.width_cm * :new.height_cm / 1000000, 6);
  end if;
end;
/

-- ---------------------------------------------------------------- рядки товарів документів доставки
create or replace view v_cargo_doc_line as
select 'DocGoodsSale' doc_type, l.document_id doc_id, l.line_number, l.product_id, l.quantity from doc_goods_sale_goods l
union all select 'DocCustomerOrder', l.document_id, l.line_number, l.product_id, l.quantity from doc_customer_order_goods l
union all select 'DocInvoiceForPayment', l.document_id, l.line_number, l.product_id, l.quantity from doc_invoice_for_payment_goods l
union all select 'DocGoodsTransfer', l.document_id, l.line_number, l.product_id, l.quantity from doc_goods_transfer_goods l
union all select 'DocGoodsReceipt', l.document_id, l.line_number, l.product_id, l.quantity from doc_goods_receipt_goods l
union all select 'DocSupplierOrder', l.document_id, l.line_number, l.product_id, l.quantity from doc_supplier_order_goods l
union all select 'DocCustomerReturn', l.document_id, l.line_number, l.product_id, l.quantity from doc_customer_return_goods l
union all select 'DocSupplierReturn', l.document_id, l.line_number, l.product_id, l.quantity from doc_supplier_return_goods l
union all select 'DocGoodsIssueOrder', l.document_id, l.line_number, l.product_id, l.quantity from doc_goods_issue_order_goods l;

create or replace view v_cargo_product as
select p.id product_id, p.code, p.name, p.product_kind, u.short_name unit_name,
       p.weight_kg, p.volume_m3, p.length_cm, p.width_cm, p.height_cm,
       case when p.product_kind = 'SERVICE' then null
            else coalesce(p.weight_kg, case lower(u.short_name) when 'кг' then 1 when 'г' then 0.001 when 'т' then 1000 end) end unit_weight,
       case when p.product_kind = 'SERVICE' then null
            else coalesce(p.volume_m3, case lower(u.short_name) when 'л' then 0.001 when 'м3' then 1 when 'м³' then 1 end) end unit_volume
  from ref_product p
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id;

create or replace view v_cargo_line as
select l.doc_type, l.doc_id, l.line_number, l.product_id, p.code product_code, p.name product_name, p.unit_name,
       p.product_kind, l.quantity, p.unit_weight, p.unit_volume,
       case when p.product_kind = 'SERVICE' then 0 else l.quantity * p.unit_weight end line_weight,
       case when p.product_kind = 'SERVICE' then 0 else l.quantity * p.unit_volume end line_volume,
       case when p.product_kind <> 'SERVICE' and p.unit_weight is null then 1 else 0 end no_weight,
       case when p.product_kind <> 'SERVICE' and p.unit_volume is null then 1 else 0 end no_volume
  from v_cargo_doc_line l
  join v_cargo_product p on p.product_id = l.product_id;

create or replace view v_cargo_doc_head as
select 'DocGoodsSale' doc_type, d.id doc_id, 'Реалізація товарів' doc_kind, 'OUT' direction, d.doc_number, d.occurred_at,
       trunc(d.occurred_at) ship_date, d.status, d.organization_id, d.warehouse_id, cast(null as varchar2(32)) warehouse_to_id,
       d.customer_id counterparty_id, 111 page_id from doc_goods_sale d
union all select 'DocCustomerOrder', d.id, 'Замовлення клієнта', 'OUT', d.doc_number, d.occurred_at,
       coalesce(d.shipment_date, trunc(d.occurred_at)), d.status, d.organization_id, d.warehouse_id, null, d.customer_id, 261
  from doc_customer_order d
union all select 'DocInvoiceForPayment', d.id, 'Рахунок на оплату', 'NONE', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, null, null, d.customer_id, 321 from doc_invoice_for_payment d
union all select 'DocGoodsTransfer', d.id, 'Переміщення товарів', 'MOVE', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, d.warehouse_from_id, d.warehouse_to_id, null, 131 from doc_goods_transfer d
union all select 'DocGoodsReceipt', d.id, 'Прибуткова накладна', 'IN', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, d.warehouse_id, null, d.supplier_id, 51 from doc_goods_receipt d
union all select 'DocSupplierOrder', d.id, 'Замовлення постачальнику', 'IN', d.doc_number, d.occurred_at,
       coalesce(d.expected_date, trunc(d.occurred_at)), d.status, d.organization_id, d.warehouse_id, null, d.supplier_id, 271
  from doc_supplier_order d
union all select 'DocCustomerReturn', d.id, 'Повернення від клієнта', 'IN', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, d.warehouse_id, null, d.customer_id, 281 from doc_customer_return d
union all select 'DocSupplierReturn', d.id, 'Повернення постачальнику', 'OUT', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, d.warehouse_id, null, d.supplier_id, 291 from doc_supplier_return d
union all select 'DocGoodsIssueOrder', d.id, 'Видатковий ордер на товари', 'OUT', d.doc_number, d.occurred_at,
       trunc(d.occurred_at), d.status, d.organization_id, d.warehouse_id, null, null, 571 from doc_goods_issue_order d;

create or replace view v_cargo_doc as
select h.doc_type, h.doc_id, h.doc_kind, h.direction, h.doc_number, h.occurred_at, h.ship_date, h.status,
       h.organization_id, h.warehouse_id, h.warehouse_to_id, h.counterparty_id, h.page_id,
       nvl(t.goods_lines, 0) goods_lines, nvl(t.goods_qty, 0) goods_qty,
       nvl(t.weight_kg, 0) weight_kg, nvl(t.volume_m3, 0) volume_m3,
       nvl(t.no_weight, 0) no_weight_lines, nvl(t.no_volume, 0) no_volume_lines
  from v_cargo_doc_head h
  left join (select doc_type, doc_id,
                    sum(case when product_kind <> 'SERVICE' then 1 else 0 end) goods_lines,
                    sum(case when product_kind <> 'SERVICE' then quantity else 0 end) goods_qty,
                    sum(nvl(line_weight, 0)) weight_kg, sum(nvl(line_volume, 0)) volume_m3,
                    sum(no_weight) no_weight, sum(no_volume) no_volume
               from v_cargo_line group by doc_type, doc_id) t
    on t.doc_type = h.doc_type and t.doc_id = h.doc_id;

-- ---------------------------------------------------------------- пакет trade_cargo
create or replace package trade_cargo as
  -- Вага (кг) й об'єм (м³) одиниці товару з урахуванням одиниці виміру (кг / л …); послуга — null
  function unit_weight (p_product_id in varchar2) return number;
  function unit_volume (p_product_id in varchar2) return number;
  -- Об'єм за габаритами (см) → м³; null, якщо хоча б один габарит не задано
  function volume_of (p_length_cm in number, p_width_cm in number, p_height_cm in number) return number;

  -- Підсумки документа (вид з v_recorder, напр. 'DocGoodsSale')
  function doc_weight (p_doc_type in varchar2, p_doc_id in varchar2) return number;
  function doc_volume (p_doc_type in varchar2, p_doc_id in varchar2) return number;
  -- Кількість рядків товарів без ваги ('WEIGHT') або без об'єму ('VOLUME')
  function doc_missing (p_doc_type in varchar2, p_doc_id in varchar2, p_what in varchar2 default 'WEIGHT') return number;
  -- Відсоток завантаження (null, якщо місткість не задано)
  function load_percent (p_value in number, p_capacity in number) return number;
  -- Число з поля сторінки (кома або крапка, пробіли); некоректне / порожнє — null
  function to_num (p in varchar2) return number;

  -- Регіон «Вага й об'єм» у формі документа
  function summary_html (p_doc_type in varchar2, p_doc_id in varchar2) return clob;

  -- Звіт «Вага й об'єм документів»: p_direction OUT / IN / MOVE / null; p_doc_type — вид або null;
  -- p_posted_only Y/N; p_cap_kg / p_cap_m3 — вантажопідйомність і об'єм транспорту
  function cargo_html (p_from in date, p_to in date, p_direction in varchar2 default null,
                       p_doc_type in varchar2 default null, p_org in varchar2 default null,
                       p_wh in varchar2 default null, p_posted_only in varchar2 default 'N',
                       p_cap_kg in number default null, p_cap_m3 in number default null) return clob;
end trade_cargo;
/

create or replace package body trade_cargo as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function kg (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function m3 (p number) return varchar2 is begin return to_char(p, 'FM999G999G990D000'); end;
  function pc (p number) return varchar2 is begin return to_char(p, 'FM999G990D0'); end;

  function unit_weight (p_product_id in varchar2) return number is
    l number;
  begin
    select max(unit_weight) into l from v_cargo_product where product_id = p_product_id;
    return l;
  end unit_weight;

  function unit_volume (p_product_id in varchar2) return number is
    l number;
  begin
    select max(unit_volume) into l from v_cargo_product where product_id = p_product_id;
    return l;
  end unit_volume;

  function volume_of (p_length_cm in number, p_width_cm in number, p_height_cm in number) return number is
  begin
    return case when p_length_cm is not null and p_width_cm is not null and p_height_cm is not null
                then round(p_length_cm * p_width_cm * p_height_cm / 1000000, 6) end;
  end volume_of;

  function doc_weight (p_doc_type in varchar2, p_doc_id in varchar2) return number is
    l number;
  begin
    select nvl(sum(line_weight), 0) into l from v_cargo_line where doc_type = p_doc_type and doc_id = p_doc_id;
    return l;
  end doc_weight;

  function doc_volume (p_doc_type in varchar2, p_doc_id in varchar2) return number is
    l number;
  begin
    select nvl(sum(line_volume), 0) into l from v_cargo_line where doc_type = p_doc_type and doc_id = p_doc_id;
    return l;
  end doc_volume;

  function doc_missing (p_doc_type in varchar2, p_doc_id in varchar2, p_what in varchar2 default 'WEIGHT') return number is
    l number;
  begin
    select nvl(sum(case when p_what = 'VOLUME' then no_volume else no_weight end), 0) into l
      from v_cargo_line where doc_type = p_doc_type and doc_id = p_doc_id;
    return l;
  end doc_missing;

  function load_percent (p_value in number, p_capacity in number) return number is
  begin
    return case when p_capacity > 0 then round(nvl(p_value, 0) * 100 / p_capacity, 1) end;
  end load_percent;

  function to_num (p in varchar2) return number is
  begin
    return to_number(replace(replace(replace(trim(p), ' '), chr(160)), ',', '.'), '99999999999999990D999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
  exception when others then
    return null;
  end to_num;

  function product_link (p_id varchar2, p_name varchar2) return varchar2 is
  begin
    if v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => 21, p_items => 'P21_ID', p_values => p_id) || '">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end product_link;

  function summary_html (p_doc_type in varchar2, p_doc_id in varchar2) return clob is
    l clob;
    l_w number := 0; l_v number := 0; l_n number := 0; l_q number := 0; l_nw number := 0; l_nv number := 0;
    l_miss varchar2(4000);
  begin
    if p_doc_id is null then
      return null;
    end if;
    select nvl(sum(line_weight), 0), nvl(sum(line_volume), 0),
           nvl(sum(case when product_kind <> 'SERVICE' then 1 else 0 end), 0),
           nvl(sum(case when product_kind <> 'SERVICE' then quantity else 0 end), 0),
           nvl(sum(no_weight), 0), nvl(sum(no_volume), 0)
      into l_w, l_v, l_n, l_q, l_nw, l_nv
      from v_cargo_line where doc_type = p_doc_type and doc_id = p_doc_id;
    l := '<div class="tx-cargo" style="padding:6px 8px;border:1px solid #e0dccb;background:#fbfaf3;margin:6px 0">'
      || '<b>Вага й об''єм для доставки:</b> вага <b>' || kg(l_w) || ' кг</b> · об''єм <b>' || m3(l_v) || ' м³</b>'
      || ' · рядків товарів: ' || l_n || ' · кількість: ' || kg(l_q);
    if l_nw + l_nv > 0 then
      select listagg(product_name || case when no_weight = 1 and no_volume = 1 then ' (вага, об''єм)'
                                          when no_weight = 1 then ' (вага)' else ' (об''єм)' end, ', ')
                     within group (order by product_name)
        into l_miss
        from (select distinct product_name, no_weight, no_volume from v_cargo_line
               where doc_type = p_doc_type and doc_id = p_doc_id and no_weight + no_volume > 0
               fetch first 10 rows only);
      l := l || '<br><span style="color:#c62828">Не задано в номенклатурі: ' || e(l_miss)
        || ' — підсумок неповний (рядків без ваги: ' || l_nw || ', без об''єму: ' || l_nv || ').</span>';
    end if;
    return l || '</div>';
  end summary_html;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1200px;background:#fff;padding:16px}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .tot td{font-weight:bold;background:#fafafa}
      .tx-print .small{font-size:11px;color:#333}
      .tx-print .over{color:#c62828;font-weight:bold}.tx-print .miss{color:#c62828}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  function doc_link (p_page number, p_id varchar2, p_text varchar2) return varchar2 is
  begin
    if v('APP_ID') is null then
      return e(p_text);
    end if;
    return '<a href="' || apex_page.get_url(p_page => p_page, p_items => 'P' || p_page || '_ID', p_values => p_id) || '">'
           || e(p_text) || '</a>';
  exception when others then
    return e(p_text);
  end doc_link;

  function cargo_html (p_from in date, p_to in date, p_direction in varchar2 default null,
                       p_doc_type in varchar2 default null, p_org in varchar2 default null,
                       p_wh in varchar2 default null, p_posted_only in varchar2 default 'N',
                       p_cap_kg in number default null, p_cap_m3 in number default null) return clob is
    l clob;
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate));
    l_n number := 0; t_w number := 0; t_v number := 0; t_l number := 0; t_nw number := 0; t_nv number := 0;
    l_par varchar2(4000);
    l_name varchar2(255);
    function load_cell (p_val number, p_cap number) return varchar2 is
      l_p number := load_percent(p_val, p_cap);
    begin
      return case when l_p is null then '' else '<td class="r' || case when l_p > 100 then ' over' end || '">' || pc(l_p) || '</td>' end;
    end;
  begin
    if l_to < l_from then
      return '<div class="tx-print"><p>Період звіту некоректний: дата «По» раніше дати «З».</p></div>';
    end if;
    if p_direction is not null and p_direction not in ('OUT', 'IN', 'MOVE') then
      return '<div class="tx-print"><p>Невідомий напрям: ' || e(p_direction) || ' (відвантаження, надходження або переміщення).</p></div>';
    end if;
    if p_cap_kg < 0 or p_cap_m3 < 0 then
      return '<div class="tx-print"><p>Вантажопідйомність і об''єм транспорту не можуть бути від''ємними.</p></div>';
    end if;
    l_par := 'Період: <b>' || to_char(l_from, 'DD.MM.YYYY') || ' – ' || to_char(l_to, 'DD.MM.YYYY') || '</b> (дата відвантаження / надходження)';
    if p_direction is not null then
      l_par := l_par || ' · Напрям: <b>' || case p_direction when 'OUT' then 'відвантаження' when 'IN' then 'надходження' else 'переміщення' end || '</b>';
    end if;
    if p_doc_type is not null then
      select max(doc_kind) into l_name from v_cargo_doc_head where doc_type = p_doc_type and rownum = 1;
      l_par := l_par || ' · Документи: <b>' || e(coalesce(l_name, p_doc_type)) || '</b>';
    end if;
    if p_org is not null then
      select max(name) into l_name from ref_organization where id = p_org;
      l_par := l_par || ' · Організація: <b>' || e(l_name) || '</b>';
    end if;
    if p_wh is not null then
      select max(name) into l_name from ref_warehouse where id = p_wh;
      l_par := l_par || ' · Склад: <b>' || e(l_name) || '</b>';
    end if;
    if p_posted_only = 'Y' then
      l_par := l_par || ' · <b>лише проведені</b>';
    end if;
    if p_cap_kg > 0 or p_cap_m3 > 0 then
      l_par := l_par || '<br>Транспорт: вантажопідйомність <b>' || nvl(kg(p_cap_kg), '—') || ' кг</b>, об''єм <b>'
            || nvl(m3(p_cap_m3), '—') || ' м³</b>';
    end if;
    l := '<div class="tx-print">' || css || '<h2>Вага й об''єм документів</h2><p class="small">' || l_par || '</p>'
      || '<table class="grid"><tr><th>№</th><th>Дата відвантаження</th><th>Документ</th><th>Статус</th><th>Контрагент</th>'
      || '<th>Склад</th><th>Рядків товарів</th><th>Вага, кг</th><th>Об''єм, м³</th><th>Без даних</th>'
      || case when p_cap_kg > 0 then '<th>% ваги</th>' end || case when p_cap_m3 > 0 then '<th>% об''єму</th>' end || '</tr>';
    for r in (select c.*, cp.name cp_name, w.name wh_name, w2.name wh_to_name
                from v_cargo_doc c
                left join ref_counterparty cp on cp.id = c.counterparty_id
                left join ref_warehouse w on w.id = c.warehouse_id
                left join ref_warehouse w2 on w2.id = c.warehouse_to_id
               where c.ship_date between l_from and l_to
                 and (p_direction is null or c.direction = p_direction)
                 and (c.direction <> 'NONE' or c.doc_type = p_doc_type)   -- рахунок — лише явним відбором
                 and (p_doc_type is null or c.doc_type = p_doc_type)
                 and (p_org is null or c.organization_id = p_org)
                 and (p_wh is null or c.warehouse_id = p_wh or c.warehouse_to_id = p_wh)
                 and (nvl(p_posted_only, 'N') = 'N' or c.status = 'POSTED')
                 and c.goods_lines > 0
               order by c.ship_date, c.warehouse_id, c.occurred_at, c.doc_number) loop
      l_n := l_n + 1;
      t_w := t_w + r.weight_kg; t_v := t_v + r.volume_m3; t_l := t_l + r.goods_lines;
      t_nw := t_nw + r.no_weight_lines; t_nv := t_nv + r.no_volume_lines;
      l := l || '<tr><td class="c">' || l_n || '</td><td class="c">' || to_char(r.ship_date, 'DD.MM.YYYY') || '</td><td>'
        || doc_link(r.page_id, r.doc_id, r.doc_kind || ' ' || r.doc_number || ' від ' || to_char(r.occurred_at, 'DD.MM.YYYY')) || '</td>'
        || '<td>' || case r.status when 'POSTED' then 'Проведено' else 'Чернетка' end || '</td>'
        || '<td>' || e(r.cp_name) || '</td><td>' || e(r.wh_name) || case when r.wh_to_name is not null then ' → ' || e(r.wh_to_name) end || '</td>'
        || '<td class="r">' || r.goods_lines || '</td><td class="r">' || kg(r.weight_kg) || '</td><td class="r">' || m3(r.volume_m3) || '</td>'
        || '<td class="c' || case when r.no_weight_lines + r.no_volume_lines > 0 then ' miss' end || '">'
        || case when r.no_weight_lines + r.no_volume_lines > 0
                then case when r.no_weight_lines > 0 then 'вага: ' || r.no_weight_lines end
                  || case when r.no_weight_lines > 0 and r.no_volume_lines > 0 then '; ' end
                  || case when r.no_volume_lines > 0 then 'об''єм: ' || r.no_volume_lines end end || '</td>'
        || load_cell(r.weight_kg, p_cap_kg) || load_cell(r.volume_m3, p_cap_m3) || '</tr>';
    end loop;
    if l_n = 0 then
      return '<div class="tx-print">' || css || '<h2>Вага й об''єм документів</h2><p class="small">' || l_par
          || '</p><p>Документів з товарами за період немає.</p></div>';
    end if;
    l := l || '<tr class="tot"><td colspan="6">Разом: документів ' || l_n || '</td><td class="r">' || t_l || '</td><td class="r">'
      || kg(t_w) || '</td><td class="r">' || m3(t_v) || '</td><td class="c">'
      || case when t_nw + t_nv > 0 then 'вага: ' || t_nw || '; об''єм: ' || t_nv end || '</td>'
      || load_cell(t_w, p_cap_kg) || load_cell(t_v, p_cap_m3) || '</tr></table>';
    if load_percent(t_w, p_cap_kg) > 100 or load_percent(t_v, p_cap_m3) > 100 then
      l := l || '<p class="over">Перевантаження: разом документи не вміщуються в один транспорт — потрібно '
        || greatest(nvl(ceil(t_w / nullif(p_cap_kg, 0)), 1), nvl(ceil(t_v / nullif(p_cap_m3, 0)), 1)) || ' рейс(и).</p>';
    end if;
    if t_nw + t_nv > 0 then
      l := l || '<p class="miss">Частина рядків без ваги або об''єму в номенклатурі — підсумок неповний. Заповніть «Вага, кг» і '
        || 'габарити (або «Об''єм, м³») у картці товару.</p>';
    end if;
    l := l || '<p class="small">Вага й об''єм рядка = кількість × вага / об''єм одиниці товару; для одиниць «кг», «г», «т» вага, '
      || 'для «л», «м3» об''єм без значення в картці береться з одиниці виміру. Послуги не враховуються. '
      || 'Дата відвантаження — дата документа (замовлення клієнта — дата відвантаження, замовлення постачальнику — очікувана дата). '
      || 'Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end cargo_html;

end trade_cargo;
/
show errors package body trade_cargo

-- ---------------------------------------------------------------- демо: вага й габарити (лише незаповнені)
declare
  procedure dims (p_article varchar2, p_weight number, p_volume number, p_l number default null, p_w number default null, p_h number default null) is
  begin
    update ref_product
       set weight_kg = coalesce(weight_kg, p_weight),
           volume_m3 = case when length_cm is null and p_l is null then coalesce(volume_m3, p_volume) else volume_m3 end,
           length_cm = coalesce(length_cm, p_l), width_cm = coalesce(width_cm, p_w), height_cm = coalesce(height_cm, p_h)
     where article = p_article and product_kind = 'GOODS'
       and (weight_kg is null or (volume_m3 is null and length_cm is null));
  end;
begin
  dims('BK-001', null, 0.00125);          -- цукор, кг: вага з одиниці
  dims('OL-001', 0.92, null);             -- олія, л: об'єм з одиниці
  dims('KT-100', 1.2, null, 22, 18, 25);  -- чайник
  dims('BK-002', null, 0.0016);           -- борошно
  dims('BK-003', null, 0.0012);           -- рис
  dims('BK-004', null, 0.0013);           -- гречка
  dims('KT-200', 12.5, null, 48, 36, 30); -- мікрохвильова піч
  dims('KT-300', 1.8, null, 30, 20, 20);  -- тостер
  update ref_product set weight_kg = coalesce(weight_kg, 8.5), length_cm = coalesce(length_cm, 40),
         width_cm = coalesce(width_cm, 25), height_cm = coalesce(height_cm, 65)
   where name = 'Обігрівач масляний (демо неліквід)' and length_cm is null;
  commit;
end;
/

-- ---------------------------------------------------------------- меню: «Звіти» розділів
declare
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_tech varchar2, p_isort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_isort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_tech
       and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  end;
begin
  merge into sys_metadata_object o
  using (select 'CargoWeightVolume' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Вага й об''єм документів', o.list_page_id = 720, o.form_page_id = null, o.auth_scheme = null
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('CargoWeightVolume', 'REPORT', 'Вага й об''єм документів', (select id from sys_main_menu_section where tech_name = 'Reports'), 720, null, 290, null);
  fp('Warehouse', 'Звіти', 2, 10, 'CargoWeightVolume', 17);
  fp('Sales', 'Звіти', 2, 10, 'CargoWeightVolume', 77);
  fp('Purchases', 'Звіти', 2, 10, 'CargoWeightVolume', 67);
  commit;
end;
/

-- ALTER TABLE ref_product інвалідує залежні представлення й пакети
begin
  dbms_utility.compile_schema(user, false);
end;
/
