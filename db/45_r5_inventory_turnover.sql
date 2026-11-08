-- =============================================================================
-- Trade r5 — F-WH-24 «Оборотність запасів». Звіт на RegStockCost + RegSales.
--   * v_turnover_stock_mv — рухи «Собівартість запасів» (кількість і вартість) з організацією, складом,
--     товаром, групою номенклатури (лише товари, без послуг);
--   * пакет trade_turnover:
--       analysis(...) — конвеєрна функція: розріз PRODUCT / GROUP / WAREHOUSE / PRODUCT_WAREHOUSE,
--         залишок на початок і кінець періоду, середній залишок (кількість і вартість) — середнє
--         залишків на кінець кожного дня періоду, продано (кількість) і собівартість продажів
--         (RegSales × RegStockCost, повернення від покупців — мінус), коефіцієнт оборотності =
--         собівартість продажів / середній залишок за вартістю, оборотність у днях = днів періоду /
--         коефіцієнт (= середній залишок × днів / собівартість продажів); відбір за організацією, складом,
--         групою номенклатури (з підгрупами);
--       turnover_html(...) — HTML звіту: параметри, підсумок, таблиця (найповільніші зверху), перехід у
--         картку товару (сторінка 450), друк;
--   * меню «Склад / Продажі / Закупівлі / Головне → Звіти» — «Оборотність запасів» (сторінка 680).
-- Потребує 12/14 (RegStockCost), 15 (групи), 24 (organization_id), 35 (v_abc_sales_line). Повторно виконуваний.
-- =============================================================================
set define off

create or replace view v_turnover_stock_mv as
select c.period, trunc(c.period) day, c.recorder_type, c.recorder_id, c.line_number, c.organization_id,
       c.warehouse_id, c.product_id, p.group_id, c.quantity, c.cost_amount
  from reg_stock_cost_mv c
  join ref_product p on p.id = c.product_id
 where coalesce(p.product_kind, 'GOODS') <> 'SERVICE';

create or replace package trade_turnover as
  type turnover_row is record (
    rn             number,
    object_id      varchar2(100),
    product_id     varchar2(32),
    warehouse_id   varchar2(32),
    object_code    varchar2(50),
    object_name    varchar2(500),
    group_name     varchar2(4000),
    warehouse_name varchar2(255),
    unit_name      varchar2(50),
    open_qty       number,
    open_cost      number,
    avg_qty        number,
    avg_cost       number,
    sold_qty       number,
    sales_cost     number,
    close_qty      number,
    close_cost     number,
    turnover_ratio number,   -- собівартість продажів / середній залишок (вартість); null — середній залишок 0
    turnover_days  number,   -- днів періоду / коефіцієнт; null — продажів (собівартості) немає
    qty_ratio      number);  -- продано / середній залишок (кількість)
  type turnover_tab is table of turnover_row;

  -- p_dim: PRODUCT | GROUP | WAREHOUSE | PRODUCT_WAREHOUSE; період [p_from; p_to] (дні включно);
  -- p_org / p_wh / p_group null — без відбору (група — з підгрупами)
  function analysis (p_dim in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_wh in varchar2 default null,
                     p_group in varchar2 default null) return turnover_tab pipelined;

  function turnover_html (p_dim in varchar2, p_from in date, p_to in date,
                          p_org in varchar2 default null, p_wh in varchar2 default null,
                          p_group in varchar2 default null) return clob;

  -- Коефіцієнт і дні для сум (null, якщо знаменник ≤ 0)
  function ratio_of (p_sales_cost in number, p_avg_cost in number) return number;
  function days_of (p_sales_cost in number, p_avg_cost in number, p_days in number) return number;
end trade_turnover;
/

create or replace package body trade_turnover as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function r2 (p number) return varchar2 is begin return to_char(p, 'FM999G999G990D00'); end;
  function d1 (p number) return varchar2 is begin return to_char(p, 'FM999G999G990D0'); end;

  function ratio_of (p_sales_cost in number, p_avg_cost in number) return number is
  begin
    return case when p_avg_cost > 0 then p_sales_cost / p_avg_cost end;
  end ratio_of;

  function days_of (p_sales_cost in number, p_avg_cost in number, p_days in number) return number is
  begin
    return case when p_sales_cost > 0 then greatest(p_avg_cost, 0) * p_days / p_sales_cost end;
  end days_of;

  procedure check_params (p_dim varchar2, p_from date, p_to date) is
  begin
    if p_dim not in ('PRODUCT', 'GROUP', 'WAREHOUSE', 'PRODUCT_WAREHOUSE') then
      trade_core.fail('Невідомий розріз звіту оборотності: ' || p_dim || ' (товари, групи, склади або товари × склади).');
    end if;
    if trunc(p_to) < trunc(p_from) then
      trade_core.fail('Період звіту оборотності некоректний: дата «По» раніше дати «З».');
    end if;
  end check_params;

  function analysis (p_dim in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_wh in varchar2 default null,
                     p_group in varchar2 default null) return turnover_tab pipelined is
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate));
    l_n    number;
    r turnover_row;
  begin
    check_params(p_dim, l_from, l_to);
    l_n := l_to - l_from + 1;
    for x in (
      with grp as (
        select g.id from ref_product_group g where p_group is not null
         start with g.id = p_group connect by prior g.id = g.parent_id),
      st as (
        -- середній залишок = середнє залишків на кінець кожного дня [from; to]:
        -- рух дня d входить у (to − d + 1) з n денних залишків
        select s.product_id, s.warehouse_id,
               sum(case when s.day < l_from then s.quantity else 0 end) open_qty,
               sum(case when s.day < l_from then s.cost_amount else 0 end) open_cost,
               sum(s.quantity) close_qty,
               sum(s.cost_amount) close_cost,
               sum(s.quantity * case when s.day < l_from then 1 else (l_to - s.day + 1) / l_n end) avg_qty,
               sum(s.cost_amount * case when s.day < l_from then 1 else (l_to - s.day + 1) / l_n end) avg_cost
          from v_turnover_stock_mv s
         where s.period < l_to + 1
           and (p_org is null or s.organization_id = p_org)
           and (p_wh is null or s.warehouse_id = p_wh)
           and (p_group is null or s.group_id in (select id from grp))
         group by s.product_id, s.warehouse_id),
      sl as (
        select l.product_id, l.warehouse_id, sum(l.quantity) sold_qty, sum(l.cost) sales_cost
          from v_abc_sales_line l
          join ref_product p on p.id = l.product_id
         where l.period >= l_from and l.period < l_to + 1
           and coalesce(p.product_kind, 'GOODS') <> 'SERVICE'
           and (p_org is null or l.organization_id = p_org)
           and (p_wh is null or l.warehouse_id = p_wh)
           and (p_group is null or l.group_id in (select id from grp))
         group by l.product_id, l.warehouse_id),
      base as (
        select coalesce(st.product_id, sl.product_id) product_id, coalesce(st.warehouse_id, sl.warehouse_id) warehouse_id,
               coalesce(st.open_qty, 0) open_qty, coalesce(st.open_cost, 0) open_cost,
               coalesce(st.close_qty, 0) close_qty, coalesce(st.close_cost, 0) close_cost,
               coalesce(st.avg_qty, 0) avg_qty, coalesce(st.avg_cost, 0) avg_cost,
               coalesce(sl.sold_qty, 0) sold_qty, coalesce(sl.sales_cost, 0) sales_cost
          from st full join sl on sl.product_id = st.product_id and sl.warehouse_id = st.warehouse_id),
      keyed as (
        select b.*, pr.group_id,
               case p_dim when 'PRODUCT' then b.product_id
                          when 'WAREHOUSE' then b.warehouse_id
                          when 'GROUP' then coalesce(pr.group_id, '-')
                          else b.product_id || ':' || b.warehouse_id end obj_id
          from base b join ref_product pr on pr.id = b.product_id),
      agg as (
        select obj_id, max(product_id) product_id, max(warehouse_id) warehouse_id, max(group_id) group_id,
               sum(open_qty) open_qty, sum(open_cost) open_cost, sum(close_qty) close_qty, sum(close_cost) close_cost,
               sum(avg_qty) avg_qty, sum(avg_cost) avg_cost, sum(sold_qty) sold_qty, sum(sales_cost) sales_cost
          from keyed group by obj_id),
      v as (
        select a.*,
               case when p_dim in ('PRODUCT', 'PRODUCT_WAREHOUSE') then pr.code
                    when p_dim = 'GROUP' then gr.code else w.code end obj_code,
               case when p_dim in ('PRODUCT', 'PRODUCT_WAREHOUSE') then pr.name
                    when p_dim = 'GROUP' then coalesce(gp.full_path, 'Без групи') else w.name end obj_name,
               case when p_dim <> 'WAREHOUSE' then coalesce(gp.full_path, case when p_dim = 'GROUP' then 'Без групи' end) end group_name,
               case when p_dim in ('WAREHOUSE', 'PRODUCT_WAREHOUSE') then w.name end warehouse_name,
               case when p_dim in ('PRODUCT', 'PRODUCT_WAREHOUSE') then u.short_name end unit_name
          from agg a
          join ref_product pr on pr.id = a.product_id
          left join ref_unit_of_measure u on u.id = pr.unit_of_measure_id
          left join ref_warehouse w on w.id = a.warehouse_id
          left join ref_product_group gr on p_dim = 'GROUP' and gr.id = a.group_id
          left join v_product_group_path gp on gp.id = a.group_id)
      select v.*, ratio_of(v.sales_cost, v.avg_cost) ratio, days_of(v.sales_cost, v.avg_cost, l_n) days
        from v
       where v.open_qty <> 0 or v.open_cost <> 0 or v.close_qty <> 0 or v.close_cost <> 0
          or round(v.avg_qty, 6) <> 0 or round(v.avg_cost, 6) <> 0 or v.sold_qty <> 0 or v.sales_cost <> 0
       order by case when days_of(v.sales_cost, v.avg_cost, l_n) is null and v.avg_cost > 0 then 0 else 1 end,
                days_of(v.sales_cost, v.avg_cost, l_n) desc nulls last, v.obj_name, v.warehouse_name, v.obj_id) loop
      r.rn := nvl(r.rn, 0) + 1;
      r.object_id := x.obj_id;
      r.product_id := case when p_dim in ('PRODUCT', 'PRODUCT_WAREHOUSE') then x.product_id end;
      r.warehouse_id := case when p_dim in ('WAREHOUSE', 'PRODUCT_WAREHOUSE') then x.warehouse_id end;
      r.object_code := x.obj_code; r.object_name := x.obj_name; r.group_name := x.group_name;
      r.warehouse_name := x.warehouse_name; r.unit_name := x.unit_name;
      r.open_qty := x.open_qty; r.open_cost := x.open_cost;
      r.avg_qty := round(x.avg_qty, 3); r.avg_cost := round(x.avg_cost, 2);
      r.sold_qty := x.sold_qty; r.sales_cost := x.sales_cost;
      r.close_qty := x.close_qty; r.close_cost := x.close_cost;
      r.turnover_ratio := round(x.ratio, 4);
      r.turnover_days := round(x.days, 2);
      r.qty_ratio := case when x.avg_qty > 0 then round(x.sold_qty / x.avg_qty, 4) end;
      pipe row (r);
    end loop;
    return;
  end analysis;

  function link_card (p_name varchar2, p_product varchar2, p_wh varchar2, p_from date, p_to date) return varchar2 is
  begin
    if p_product is null or v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => 450, p_items => 'P450_PRODUCT,P450_WH,P450_FROM,P450_TO',
                                            p_values => p_product || ',' || p_wh || ',' || to_char(p_from, 'DD.MM.YYYY') || ',' || to_char(p_to, 'DD.MM.YYYY'))
           || '">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end link_card;

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
      .tx-print .slow{color:#c62828}.tx-print .nosale{color:#c62828;font-style:italic}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  function turnover_html (p_dim in varchar2, p_from in date, p_to in date,
                          p_org in varchar2 default null, p_wh in varchar2 default null,
                          p_group in varchar2 default null) return clob is
    l clob;
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate));
    l_dim varchar2(20) := coalesce(p_dim, 'PRODUCT');
    l_rows turnover_tab;
    l_n number;
    l_org varchar2(255); l_whn varchar2(255); l_grp varchar2(4000);
    t_oq number := 0; t_oc number := 0; t_aq number := 0; t_ac number := 0; t_sq number := 0; t_sc number := 0;
    t_cq number := 0; t_cc number := 0;
    l_prd boolean := l_dim in ('PRODUCT', 'PRODUCT_WAREHOUSE');
    l_lead pls_integer;
    function days_cell (p_days number, p_avg number) return varchar2 is
    begin
      return case when p_days is not null then '<td class="r' || case when p_days > l_n then ' slow' end || '">' || d1(p_days) || '</td>'
                  when p_avg > 0 then '<td class="c nosale">немає продажів</td>'
                  else '<td></td>' end;
    end;
  begin
    begin
      check_params(l_dim, l_from, l_to);
    exception when others then
      return '<div class="tx-print"><p>' || e(regexp_replace(sqlerrm, '^ORA-[0-9]+: ')) || '</p></div>';
    end;
    l_n := l_to - l_from + 1;
    select * bulk collect into l_rows from table(analysis(l_dim, l_from, l_to, p_org, p_wh, p_group));
    if p_org is not null then select max(name) into l_org from ref_organization where id = p_org; end if;
    if p_wh is not null then select max(name) into l_whn from ref_warehouse where id = p_wh; end if;
    if p_group is not null then select max(full_path) into l_grp from v_product_group_path where id = p_group; end if;
    l := '<div class="tx-print">' || css
      || '<h2>Оборотність запасів: ' || case l_dim when 'PRODUCT' then 'товари' when 'GROUP' then 'групи номенклатури'
                                                    when 'WAREHOUSE' then 'склади' else 'товари за складами' end || '</h2>'
      || '<table class="small" style="margin-bottom:8px"><tr><td>Період: з ' || to_char(l_from, 'DD.MM.YYYY') || ' по ' || to_char(l_to, 'DD.MM.YYYY')
      || ' (' || l_n || ' дн.)</td><td class="r">Склад: <b>' || e(coalesce(l_whn, 'усі склади')) || '</b></td></tr>'
      || '<tr><td>Організація: <b>' || e(coalesce(l_org, 'усі організації')) || '</b>; група номенклатури: <b>'
      || e(coalesce(l_grp, 'усі групи')) || '</b>' || case when l_grp is not null then ' (з підгрупами)' end || '</td>'
      || '<td class="r">Вартість — середня ковзна собівартість (RegStockCost), грн</td></tr></table>';
    if l_rows.count = 0 then
      return l || '<p class="c">Запасів і продажів за період немає.</p></div>';
    end if;
    for i in 1 .. l_rows.count loop
      t_oq := t_oq + l_rows(i).open_qty; t_oc := t_oc + l_rows(i).open_cost;
      t_aq := t_aq + l_rows(i).avg_qty; t_ac := t_ac + l_rows(i).avg_cost;
      t_sq := t_sq + l_rows(i).sold_qty; t_sc := t_sc + l_rows(i).sales_cost;
      t_cq := t_cq + l_rows(i).close_qty; t_cc := t_cc + l_rows(i).close_cost;
    end loop;
    -- підсумок
    l := l || '<table class="grid" style="margin-bottom:8px;width:auto"><tr><th>Середній залишок, грн</th><th>Собівартість продажів, грн</th>'
           || '<th>Коефіцієнт оборотності</th><th>Оборотність, днів</th><th>Позицій</th><th>Без продажів</th></tr><tr>'
           || '<td class="r">' || m(t_ac) || '</td><td class="r">' || m(t_sc) || '</td>'
           || '<td class="r">' || r2(ratio_of(t_sc, t_ac)) || '</td>' || days_cell(days_of(t_sc, t_ac, l_n), t_ac)
           || '<td class="r">' || l_rows.count || '</td><td class="r">';
    l_lead := 0;
    for i in 1 .. l_rows.count loop
      if l_rows(i).turnover_days is null and l_rows(i).avg_cost > 0 then l_lead := l_lead + 1; end if;
    end loop;
    l := l || l_lead || '</td></tr></table>';
    -- таблиця
    l_lead := case l_dim when 'PRODUCT' then 4 when 'PRODUCT_WAREHOUSE' then 5 when 'GROUP' then 2 else 2 end;
    l := l || '<table class="grid"><tr><th rowspan="2">№</th><th rowspan="2">'
           || case l_dim when 'GROUP' then 'Група номенклатури' when 'WAREHOUSE' then 'Склад' else 'Товар' end || '</th>'
           || case when l_prd then '<th rowspan="2">Група</th>' end
           || case when l_dim = 'PRODUCT_WAREHOUSE' then '<th rowspan="2">Склад</th>' end
           || case when l_prd then '<th rowspan="2">Од.</th>' end
           || '<th colspan="2">Залишок на ' || to_char(l_from, 'DD.MM.YYYY') || '</th><th colspan="2">Середній залишок</th>'
           || '<th colspan="2">Продажі</th><th colspan="2">Залишок на ' || to_char(l_to, 'DD.MM.YYYY') || '</th>'
           || '<th rowspan="2">Коефіцієнт оборотності</th><th rowspan="2">Оборотність, днів</th></tr>'
           || '<tr><th>Кількість</th><th>Вартість</th><th>Кількість</th><th>Вартість</th>'
           || '<th>Кількість</th><th>Собівартість</th><th>Кількість</th><th>Вартість</th></tr>';
    for i in 1 .. l_rows.count loop
      l := l || '<tr><td class="r">' || l_rows(i).rn || '</td><td>'
             || case when l_prd then link_card(l_rows(i).object_name, l_rows(i).product_id, coalesce(l_rows(i).warehouse_id, p_wh), l_from, l_to)
                     else e(l_rows(i).object_name) end || '</td>'
             || case when l_prd then '<td>' || e(l_rows(i).group_name) || '</td>' end
             || case when l_dim = 'PRODUCT_WAREHOUSE' then '<td>' || e(l_rows(i).warehouse_name) || '</td>' end
             || case when l_prd then '<td>' || e(l_rows(i).unit_name) || '</td>' end
             || '<td class="r">' || q(l_rows(i).open_qty) || '</td><td class="r">' || m(l_rows(i).open_cost) || '</td>'
             || '<td class="r">' || q(l_rows(i).avg_qty) || '</td><td class="r">' || m(l_rows(i).avg_cost) || '</td>'
             || '<td class="r">' || q(l_rows(i).sold_qty) || '</td><td class="r">' || m(l_rows(i).sales_cost) || '</td>'
             || '<td class="r">' || q(l_rows(i).close_qty) || '</td><td class="r">' || m(l_rows(i).close_cost) || '</td>'
             || '<td class="r">' || r2(l_rows(i).turnover_ratio) || '</td>'
             || days_cell(l_rows(i).turnover_days, l_rows(i).avg_cost) || '</tr>';
    end loop;
    l := l || '<tr class="tot"><td colspan="' || l_lead || '">Разом</td>'
           || '<td class="r">' || q(t_oq) || '</td><td class="r">' || m(t_oc) || '</td>'
           || '<td class="r">' || q(t_aq) || '</td><td class="r">' || m(t_ac) || '</td>'
           || '<td class="r">' || q(t_sq) || '</td><td class="r">' || m(t_sc) || '</td>'
           || '<td class="r">' || q(t_cq) || '</td><td class="r">' || m(t_cc) || '</td>'
           || '<td class="r">' || r2(ratio_of(t_sc, t_ac)) || '</td>' || days_cell(days_of(t_sc, t_ac, l_n), t_ac) || '</tr></table>'
           || '<p class="small">Середній залишок — середнє залишків на кінець кожного дня періоду; собівартість продажів — '
           || 'RegSales × RegStockCost (повернення від покупців зменшують); коефіцієнт = собівартість продажів / середній залишок; '
           || 'оборотність у днях = ' || l_n || ' дн. / коефіцієнт (червоним — довше за період). '
           || 'Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end turnover_html;

end trade_turnover;
/
show errors package body trade_turnover

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
  using (select 'InventoryTurnover' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Оборотність запасів', o.list_page_id = 680, o.form_page_id = null, o.auth_scheme = null
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('InventoryTurnover', 'REPORT', 'Оборотність запасів', (select id from sys_main_menu_section where tech_name = 'Reports'), 680, null, 270, null);
  fp('Warehouse', 'Звіти', 2, 10, 'InventoryTurnover', 15);
  fp('Sales', 'Звіти', 2, 10, 'InventoryTurnover', 75);
  fp('Purchases', 'Звіти', 2, 10, 'InventoryTurnover', 65);
  fp('Main', 'Звіти', 2, 10, 'InventoryTurnover', 65);
  commit;
end;
/
