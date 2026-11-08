-- =============================================================================
-- Trade r4 — F-REP-08 «Картка товару». Звіт на RegStockBalance + RegStockCost.
--   * v_product_card_movement — рухи товару, згорнуті до «реєстратор × склад»: прихід / розхід
--     кількості (RegStockBalance) і вартості (RegStockCost); реєстратори — з v_recorder
--     (усі документи r1–r4, зокрема DocAssembly), рядки без запису у v_recorder не губляться;
--   * пакет trade_product_card: opening_qty / opening_cost (залишок на початок дня),
--     card_html — HTML картки (товар / склад або всі склади / період): початковий залишок,
--     рухи з наростаючим залишком кількості й вартості, обороти за період, кінцевий залишок,
--     посилання на документ-реєстратор (в APEX-сесії), друк (сторінка 450);
--   * меню «Склад / Продажі / Закупівлі / Головне → Звіти» — «Картка товару» (усі ролі).
-- Потребує 14 (RegStockCost), 33 (v_recorder). Скрипт повторно виконуваний.
-- =============================================================================
set define off

create or replace view v_product_card_movement as
select x.recorder_type, x.recorder_id, coalesce(r.recorder_name, x.recorder_type) recorder_name, r.page_id,
       x.warehouse_id, w.name warehouse_name, x.product_id, x.period, x.posting_seq,
       x.qty_in, x.qty_out, x.cost_in, x.cost_out
  from (select m.recorder_type, m.recorder_id, m.warehouse_id, m.product_id,
               min(m.period) period, min(m.posting_seq) posting_seq,
               sum(case when m.qty > 0 then m.qty else 0 end) qty_in,
               sum(case when m.qty < 0 then -m.qty else 0 end) qty_out,
               sum(case when m.cost_dir > 0 then m.cost else 0 end) cost_in,
               sum(case when m.cost_dir < 0 then -m.cost else 0 end) cost_out
          from (select b.recorder_type, b.recorder_id, b.warehouse_id, b.product_id, b.period,
                       b.quantity qty, 0 cost, 0 cost_dir, cast(null as number) posting_seq
                  from reg_stock_balance_movement b
                union all
                select c.recorder_type, c.recorder_id, c.warehouse_id, c.product_id, c.period,
                       0, c.cost_amount, case when c.quantity <> 0 then sign(c.quantity) else sign(c.cost_amount) end, c.posting_seq
                  from reg_stock_cost_mv c) m
         group by m.recorder_type, m.recorder_id, m.warehouse_id, m.product_id) x
  join ref_warehouse w on w.id = x.warehouse_id
  left join v_recorder r on r.recorder_type = x.recorder_type and r.recorder_id = x.recorder_id;

create or replace package trade_product_card as
  -- Залишок на початок p_at (рухи з period < p_at); p_warehouse_id null — усі склади
  function opening_qty  (p_product_id in varchar2, p_warehouse_id in varchar2, p_at in date) return number;
  function opening_cost (p_product_id in varchar2, p_warehouse_id in varchar2, p_at in date) return number;
  -- Картка товару за період [p_from; p_to] (дні включно)
  function card_html (p_product_id in varchar2, p_warehouse_id in varchar2, p_from in date, p_to in date) return clob;
end trade_product_card;
/

create or replace package body trade_product_card as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function nz (p number, f varchar2) return varchar2 is
  begin
    return case when p <> 0 then case f when 'q' then q(p) else m(p) end end;
  end;

  function opening_qty (p_product_id in varchar2, p_warehouse_id in varchar2, p_at in date) return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_stock_balance_movement
     where product_id = p_product_id and (p_warehouse_id is null or warehouse_id = p_warehouse_id) and period < p_at;
    return l;
  end opening_qty;

  function opening_cost (p_product_id in varchar2, p_warehouse_id in varchar2, p_at in date) return number is
    l number;
  begin
    select coalesce(sum(cost_amount), 0) into l from reg_stock_cost_mv
     where product_id = p_product_id and (p_warehouse_id is null or warehouse_id = p_warehouse_id) and period < p_at;
    return l;
  end opening_cost;

  -- Посилання на форму документа-реєстратора (лише в APEX-сесії)
  function doc_link (p_name varchar2, p_page number, p_id varchar2) return varchar2 is
  begin
    if p_page is null or v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => p_page, p_items => 'P' || p_page || '_ID', p_values => p_id) || '">'
           || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end doc_link;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1100px;background:#fff;padding:16px}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .tot td{font-weight:bold;background:#fafafa}
      .tx-print .small{font-size:11px;color:#333}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  function card_html (p_product_id in varchar2, p_warehouse_id in varchar2, p_from in date, p_to in date) return clob is
    l clob;
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate)) + 1;
    l_prd varchar2(500); l_unit varchar2(50); l_wh varchar2(255);
    l_q number; l_c number; l_q0 number; l_c0 number;
    l_qi number := 0; l_qo number := 0; l_ci number := 0; l_co number := 0; l_n number := 0;
    l_all boolean := p_warehouse_id is null;
    l_cols pls_integer;
  begin
    if p_product_id is null then
      return '<p>Виберіть товар.</p>';
    end if;
    select p.name || case when p.code is not null then ' (код ' || p.code || ')' end, u.short_name into l_prd, l_unit
      from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = p_product_id;
    if not l_all then
      select name into l_wh from ref_warehouse where id = p_warehouse_id;
    end if;
    l_q0 := opening_qty(p_product_id, p_warehouse_id, l_from);
    l_c0 := opening_cost(p_product_id, p_warehouse_id, l_from);
    l_q := l_q0; l_c := l_c0;
    l_cols := case when l_all then 3 else 2 end;
    l := '<div class="tx-print">' || css
      || '<h2>Картка товару</h2>'
      || '<table class="small" style="margin-bottom:8px"><tr><td>Товар: <b>' || e(l_prd) || '</b>, од. ' || e(l_unit) || '</td>'
      || '<td class="r">Склад: <b>' || e(coalesce(l_wh, 'усі склади')) || '</b></td></tr>'
      || '<tr><td>Період: з ' || to_char(l_from, 'DD.MM.YYYY') || ' по ' || to_char(l_to - 1, 'DD.MM.YYYY') || '</td>'
      || '<td class="r">Вартість — середня ковзна собівартість (RegStockCost), грн</td></tr></table>'
      || '<table class="grid"><tr><th rowspan="2" style="width:120px">Дата</th><th rowspan="2">Документ-реєстратор</th>'
      || case when l_all then '<th rowspan="2">Склад</th>' end
      || '<th colspan="2">Прихід</th><th colspan="2">Розхід</th><th colspan="2">Залишок</th></tr>'
      || '<tr><th>Кількість</th><th>Вартість</th><th>Кількість</th><th>Вартість</th><th>Кількість</th><th>Вартість</th></tr>'
      || '<tr class="tot"><td colspan="' || l_cols || '">Залишок на ' || to_char(l_from, 'DD.MM.YYYY') || '</td>'
      || '<td></td><td></td><td></td><td></td><td class="r">' || q(l_q0) || '</td><td class="r">' || m(l_c0) || '</td></tr>';
    for x in (select * from v_product_card_movement
               where product_id = p_product_id and (p_warehouse_id is null or warehouse_id = p_warehouse_id)
                 and period >= l_from and period < l_to
               order by period, posting_seq nulls last, recorder_name, warehouse_name) loop
      l_n := l_n + 1;
      l_q := l_q + x.qty_in - x.qty_out;
      l_c := l_c + x.cost_in - x.cost_out;
      l_qi := l_qi + x.qty_in; l_qo := l_qo + x.qty_out; l_ci := l_ci + x.cost_in; l_co := l_co + x.cost_out;
      l := l || '<tr><td>' || to_char(x.period, 'DD.MM.YYYY HH24:MI') || '</td><td>' || doc_link(x.recorder_name, x.page_id, x.recorder_id) || '</td>'
             || case when l_all then '<td>' || e(x.warehouse_name) || '</td>' end
             || '<td class="r">' || nz(x.qty_in, 'q') || '</td><td class="r">' || nz(x.cost_in, 'm') || '</td>'
             || '<td class="r">' || nz(x.qty_out, 'q') || '</td><td class="r">' || nz(x.cost_out, 'm') || '</td>'
             || '<td class="r">' || q(l_q) || '</td><td class="r">' || m(l_c) || '</td></tr>';
    end loop;
    if l_n = 0 then
      l := l || '<tr><td colspan="' || (l_cols + 6) || '" class="c">Рухів за період немає</td></tr>';
    end if;
    l := l || '<tr class="tot"><td colspan="' || l_cols || '">Обороти за період</td>'
           || '<td class="r">' || q(l_qi) || '</td><td class="r">' || m(l_ci) || '</td>'
           || '<td class="r">' || q(l_qo) || '</td><td class="r">' || m(l_co) || '</td><td></td><td></td></tr>'
           || '<tr class="tot"><td colspan="' || l_cols || '">Залишок на ' || to_char(l_to - 1, 'DD.MM.YYYY') || ' (кінець дня)</td>'
           || '<td></td><td></td><td></td><td></td><td class="r">' || q(l_q) || '</td><td class="r">' || m(l_c) || '</td></tr>'
           || '</table><p class="small">Рухів: ' || l_n || '. Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end card_html;

end trade_product_card;
/
show errors package body trade_product_card

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
  using (select 'ProductCard' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Картка товару', o.list_page_id = 450, o.form_page_id = null, o.auth_scheme = null
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('ProductCard', 'REPORT', 'Картка товару', (select id from sys_main_menu_section where tech_name = 'Reports'), 450, null, 150, null);
  fp('Warehouse', 'Звіти', 2, 10, 'ProductCard', 10);
  fp('Sales', 'Звіти', 2, 10, 'ProductCard', 60);
  fp('Purchases', 'Звіти', 2, 10, 'ProductCard', 50);
  fp('Main', 'Звіти', 2, 10, 'ProductCard', 50);
  commit;
end;
/
