-- =============================================================================
-- Trade r4 — F-REP-09 «ABC-аналіз продажів». Звіт на RegSales + RegStockCost.
--   * v_abc_sales_line — рядки продажів (RegSales) з собівартістю рядка (RegStockCost) і валовим
--     прибутком, організацією, товаром, групою номенклатури, клієнтом (повернення — від'ємні);
--   * пакет trade_abc:
--       analysis(...) — конвеєрна функція: товари або клієнти, показник REVENUE / QTY / PROFIT,
--         частка, накопичена частка, клас A/B/C за межами (типово A 80 %, B 15 %, C — решта);
--         правило класу: позиція належить класу, у межу якого потрапляє накопичена частка
--         ПЕРЕД нею (позиція, що перетинає межу, — у вищий клас; перша позиція завжди A);
--         позиції з показником ≤ 0 (збиткові, повністю повернені) — клас C, у базу частки не входять;
--       abc_html(...) — HTML звіту: параметри, зведення за класами, діаграма Парето (SVG),
--         таблиця позицій; відбір за періодом, організацією, групою номенклатури (з підгрупами);
--       to_num — розбір чисел з полів сторінки («80», «12,5», «12.5»);
--   * меню «Продажі / Закупівлі / Головне → Звіти» — «ABC-аналіз продажів» (сторінка 460).
-- Потребує 05 (RegSales), 12/14 (RegStockCost), 15 (групи), 24 (organization_id). Повторно виконуваний.
-- =============================================================================
set define off

create or replace view v_abc_sales_line as
select s.period, s.recorder_type, s.recorder_id, s.line_number, s.organization_id,
       s.product_id, p.group_id, s.counterparty_id, s.warehouse_id,
       s.quantity, s.amount revenue,
       coalesce(-cm.cost_amount, 0) cost,
       s.amount - coalesce(-cm.cost_amount, 0) gross_profit
  from reg_sales_turnover s
  join ref_product p on p.id = s.product_id
  left join reg_stock_cost_mv cm
    on cm.recorder_type = s.recorder_type and cm.recorder_id = s.recorder_id and cm.line_number = s.line_number;

create or replace package trade_abc as
  type abc_row is record (
    rn            number,
    object_id     varchar2(32),
    object_code   varchar2(50),
    object_name   varchar2(500),
    group_name    varchar2(4000),
    quantity      number,
    revenue       number,
    cost          number,
    gross_profit  number,
    value         number,
    share_pct     number,
    cum_share_pct number,
    abc_class     varchar2(1));
  type abc_tab is table of abc_row;

  -- p_dim: PRODUCT | CUSTOMER; p_measure: REVENUE | QTY | PROFIT; період [p_from; p_to] (дні включно);
  -- p_org / p_group null — без відбору; p_a / p_b — межі класів A і B у відсотках (C = 100 − A − B)
  function analysis (p_dim in varchar2, p_measure in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_group in varchar2 default null,
                     p_a in number default 80, p_b in number default 15) return abc_tab pipelined;

  function abc_html (p_dim in varchar2, p_measure in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_group in varchar2 default null,
                     p_a in number default 80, p_b in number default 15) return clob;

  -- Клас для межі: накопичена частка перед позицією → A / B / C
  function class_of (p_prev_pct in number, p_value in number, p_a in number, p_b in number) return varchar2;

  function to_num (p in varchar2, p_default in number) return number;
end trade_abc;
/

create or replace package body trade_abc as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function pc (p number) return varchar2 is begin return to_char(p, 'FM990D00'); end;
  function sv (p number) return varchar2 is   -- число для SVG (крапка, без групування)
  begin
    return to_char(round(p, 1), 'FM999999990D0', 'NLS_NUMERIC_CHARACTERS=''. ''');
  end sv;

  function to_num (p in varchar2, p_default in number) return number is
  begin
    if trim(p) is null then return p_default; end if;
    return to_number(replace(replace(trim(p), ' ', ''), ',', '.'), '999999999990D999999', 'NLS_NUMERIC_CHARACTERS=''. ''');
  exception when others then
    return p_default;
  end to_num;

  procedure check_params (p_dim varchar2, p_measure varchar2, p_a number, p_b number) is
  begin
    if p_dim not in ('PRODUCT', 'CUSTOMER') then
      trade_core.fail('Невідомий розріз ABC-аналізу: ' || p_dim || ' (товари або клієнти).');
    end if;
    if p_measure not in ('REVENUE', 'QTY', 'PROFIT') then
      trade_core.fail('Невідомий показник ABC-аналізу: ' || p_measure || ' (виручка, кількість або прибуток).');
    end if;
    if p_a is null or p_b is null or p_a <= 0 or p_b < 0 or p_a + p_b > 100 then
      trade_core.fail('Межі класів ABC некоректні: A > 0, B ≥ 0, A + B ≤ 100 %.');
    end if;
  end check_params;

  function class_of (p_prev_pct in number, p_value in number, p_a in number, p_b in number) return varchar2 is
  begin
    return case when p_value is null or p_value <= 0 then 'C'
                when p_prev_pct < p_a then 'A'
                when p_prev_pct < p_a + p_b then 'B'
                else 'C' end;
  end class_of;

  function analysis (p_dim in varchar2, p_measure in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_group in varchar2 default null,
                     p_a in number default 80, p_b in number default 15) return abc_tab pipelined is
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate)) + 1;
    r abc_row;
  begin
    check_params(p_dim, p_measure, p_a, p_b);
    for x in (
      with lines as (
        select l.*, case when p_dim = 'PRODUCT' then l.product_id else l.counterparty_id end obj_id
          from v_abc_sales_line l
         where l.period >= l_from and l.period < l_to
           and (p_org is null or l.organization_id = p_org)
           and (p_group is null or l.group_id in (select g.id from ref_product_group g
                                                  start with g.id = p_group connect by prior g.id = g.parent_id))),
      agg as (
        select obj_id, sum(quantity) quantity, sum(revenue) revenue, sum(cost) cost, sum(gross_profit) gross_profit
          from lines group by obj_id),
      v as (
        select a.*, case p_measure when 'QTY' then a.quantity when 'PROFIT' then a.gross_profit else a.revenue end val,
               coalesce(pr.code, cp.code) obj_code, coalesce(pr.name, cp.name) obj_name, gp.full_path group_name
          from agg a
          left join ref_product pr on p_dim = 'PRODUCT' and pr.id = a.obj_id
          left join v_product_group_path gp on gp.id = pr.group_id
          left join ref_counterparty cp on p_dim = 'CUSTOMER' and cp.id = a.obj_id)
      select v.*,
             sum(case when val > 0 then val else 0 end) over () total_pos,
             sum(case when val > 0 then val else 0 end) over (order by val desc, obj_name, obj_id rows unbounded preceding) cum,
             row_number() over (order by val desc, obj_name, obj_id) rn
        from v
       where val <> 0 or revenue <> 0 or quantity <> 0
       order by val desc, obj_name, obj_id) loop
      r.rn := x.rn;
      r.object_id := x.obj_id; r.object_code := x.obj_code; r.object_name := x.obj_name; r.group_name := x.group_name;
      r.quantity := x.quantity; r.revenue := x.revenue; r.cost := x.cost; r.gross_profit := x.gross_profit;
      r.value := x.val;
      if x.total_pos > 0 and x.val > 0 then
        r.share_pct := x.val * 100 / x.total_pos;
        r.cum_share_pct := x.cum * 100 / x.total_pos;
        r.abc_class := class_of((x.cum - x.val) * 100 / x.total_pos, x.val, p_a, p_b);
      else
        r.share_pct := 0;
        r.cum_share_pct := case when x.total_pos > 0 then 100 else 0 end;
        r.abc_class := 'C';
      end if;
      pipe row (r);
    end loop;
    return;
  end analysis;

  function link_card (p_name varchar2, p_id varchar2, p_from date, p_to date) return varchar2 is
  begin
    if v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => 450, p_items => 'P450_PRODUCT,P450_WH,P450_FROM,P450_TO',
                                            p_values => p_id || ',,' || to_char(p_from, 'DD.MM.YYYY') || ',' || to_char(p_to, 'DD.MM.YYYY'))
           || '">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end link_card;

  function color (p_class varchar2) return varchar2 is
  begin
    return case p_class when 'A' then '#2e7d32' when 'B' then '#f9a825' else '#c62828' end;
  end color;

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
      .tx-print .abc{display:inline-block;min-width:18px;text-align:center;color:#fff;font-weight:bold;border-radius:3px;padding:0 4px}
      .tx-print .abc-A{background:#2e7d32}.tx-print .abc-B{background:#f9a825;color:#000}.tx-print .abc-C{background:#c62828}
      .tx-print svg{width:100%;height:auto;margin:8px 0}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  -- Діаграма Парето: стовпці показника (колір класу) + лінія накопиченої частки + межі класів
  function pareto_svg (p_rows abc_tab, p_a number, p_b number, p_measure varchar2) return clob is
    c_w constant number := 1000; c_h constant number := 300;
    c_l constant number := 70; c_r constant number := 50; c_t constant number := 15; c_b constant number := 30;
    pw number := c_w - c_l - c_r; ph number := c_h - c_t - c_b;
    l clob; l_max number := 0; l_n number := p_rows.count; bw number; x number; h number; y number;
    l_pts varchar2(32767);
    function ypc (p number) return number is begin return c_t + ph * (1 - p / 100); end;
  begin
    for i in 1 .. l_n loop
      l_max := greatest(l_max, coalesce(p_rows(i).value, 0));
    end loop;
    if l_max <= 0 then
      return null;
    end if;
    bw := pw / l_n;
    l := '<svg viewBox="0 0 ' || c_w || ' ' || c_h || '" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Діаграма Парето">'
      || '<rect x="' || c_l || '" y="' || c_t || '" width="' || pw || '" height="' || ph || '" fill="none" stroke="#999"/>';
    -- осі: ліва — показник, права — накопичена частка %
    for k in 0 .. 4 loop
      y := c_t + ph * (1 - k / 4);
      l := l || '<line x1="' || c_l || '" x2="' || (c_l + pw) || '" y1="' || sv(y) || '" y2="' || sv(y) || '" stroke="#e0e0e0"/>'
             || '<text x="' || (c_l - 4) || '" y="' || sv(y + 4) || '" font-size="11" text-anchor="end">'
             || e(case when p_measure = 'QTY' then to_char(round(l_max * k / 4, 3), 'FM999G999G990D999') else m(l_max * k / 4) end) || '</text>'
             || '<text x="' || (c_l + pw + 4) || '" y="' || sv(y + 4) || '" font-size="11">' || (k * 25) || '%</text>';
    end loop;
    for i in 1 .. l_n loop
      x := c_l + (i - 1) * bw;
      h := case when p_rows(i).value > 0 then ph * p_rows(i).value / l_max else 0 end;
      l := l || '<rect x="' || sv(x + bw * 0.1) || '" y="' || sv(c_t + ph - h) || '" width="' || sv(greatest(bw * 0.8, 0.5))
             || '" height="' || sv(h) || '" fill="' || color(p_rows(i).abc_class) || '"><title>'
             || e(p_rows(i).rn || '. ' || p_rows(i).object_name || ' — ' || p_rows(i).abc_class || ', '
                  || pc(p_rows(i).share_pct) || '%, накопичено ' || pc(p_rows(i).cum_share_pct) || '%')
             || '</title></rect>';
      l_pts := l_pts || sv(x + bw / 2) || ',' || sv(ypc(p_rows(i).cum_share_pct)) || ' ';
    end loop;
    -- межі класів
    l := l || '<line x1="' || c_l || '" x2="' || (c_l + pw) || '" y1="' || sv(ypc(p_a)) || '" y2="' || sv(ypc(p_a))
           || '" stroke="#2e7d32" stroke-dasharray="6,4"/><text x="' || (c_l + 4) || '" y="' || sv(ypc(p_a) - 3)
           || '" font-size="11" fill="#2e7d32">A ≤ ' || pc(p_a) || '%</text>';
    if p_b > 0 then
      l := l || '<line x1="' || c_l || '" x2="' || (c_l + pw) || '" y1="' || sv(ypc(p_a + p_b)) || '" y2="' || sv(ypc(p_a + p_b))
             || '" stroke="#f9a825" stroke-dasharray="6,4"/><text x="' || (c_l + 4) || '" y="' || sv(ypc(p_a + p_b) - 3)
             || '" font-size="11" fill="#b07800">B ≤ ' || pc(p_a + p_b) || '%</text>';
    end if;
    l := l || '<polyline points="' || trim(l_pts) || '" fill="none" stroke="#1565c0" stroke-width="2"/>'
           || '<text x="' || c_l || '" y="' || (c_h - 8) || '" font-size="11">Позиції за спаданням показника (' || l_n || ')</text>'
           || '<text x="' || (c_l + pw) || '" y="' || (c_h - 8) || '" font-size="11" text-anchor="end" fill="#1565c0">— накопичена частка</text>'
           || '</svg>';
    return l;
  end pareto_svg;

  function abc_html (p_dim in varchar2, p_measure in varchar2, p_from in date, p_to in date,
                     p_org in varchar2 default null, p_group in varchar2 default null,
                     p_a in number default 80, p_b in number default 15) return clob is
    l clob;
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to   date := trunc(coalesce(p_to, sysdate));
    l_dim varchar2(10) := coalesce(p_dim, 'PRODUCT');
    l_ms varchar2(10) := coalesce(p_measure, 'REVENUE');
    l_rows abc_tab;
    l_org varchar2(255); l_grp varchar2(4000);
    l_ms_name varchar2(50);
    l_qty number := 0; l_rev number := 0; l_cost number := 0; l_gp number := 0; l_val number := 0; l_pos number := 0;
    l_cols pls_integer;
    function fv (p number) return varchar2 is begin return case when l_ms = 'QTY' then q(p) else m(p) end; end;
  begin
    begin
      check_params(l_dim, l_ms, p_a, p_b);
    exception when others then
      return '<div class="tx-print"><p>' || e(regexp_replace(sqlerrm, '^ORA-[0-9]+: ')) || '</p></div>';
    end;
    select * bulk collect into l_rows from table(analysis(l_dim, l_ms, l_from, l_to, p_org, p_group, p_a, p_b));
    if p_org is not null then select max(name) into l_org from ref_organization where id = p_org; end if;
    if p_group is not null then select max(full_path) into l_grp from v_product_group_path where id = p_group; end if;
    l_ms_name := case l_ms when 'QTY' then 'кількість' when 'PROFIT' then 'валовий прибуток' else 'виручка' end;
    l_cols := case when l_dim = 'PRODUCT' then 4 else 3 end;
    l := '<div class="tx-print">' || css
      || '<h2>ABC-аналіз продажів: ' || case when l_dim = 'PRODUCT' then 'товари' else 'клієнти' end || '</h2>'
      || '<table class="small" style="margin-bottom:8px"><tr><td>Період: з ' || to_char(l_from, 'DD.MM.YYYY') || ' по ' || to_char(l_to, 'DD.MM.YYYY')
      || '</td><td class="r">Показник: <b>' || l_ms_name || '</b></td></tr>'
      || '<tr><td>Організація: <b>' || e(coalesce(l_org, 'усі організації')) || '</b>; група номенклатури: <b>'
      || e(coalesce(l_grp, 'усі групи')) || '</b>' || case when l_grp is not null then ' (з підгрупами)' end || '</td>'
      || '<td class="r">Межі класів: A ' || pc(p_a) || '%, B ' || pc(p_b) || '%, C ' || pc(100 - p_a - p_b) || '%</td></tr></table>';
    if l_rows.count = 0 then
      return l || '<p class="c">Продажів за період немає.</p></div>';
    end if;
    -- зведення за класами
    l := l || '<table class="grid" style="margin-bottom:8px;width:auto"><tr><th>Клас</th><th>Позицій</th><th>% позицій</th>'
           || '<th>Показник (' || l_ms_name || ')</th><th>Частка, %</th><th>Виручка</th><th>Валовий прибуток</th></tr>';
    for c in (select abc_class, count(*) cnt, sum(value) val, sum(case when value > 0 then value else 0 end) val_pos,
                     sum(revenue) rev, sum(gross_profit) gp, sum(sum(case when value > 0 then value else 0 end)) over () total_pos,
                     sum(count(*)) over () total_cnt
                from table(l_rows) group by abc_class order by abc_class) loop
      l := l || '<tr><td class="c"><span class="abc abc-' || c.abc_class || '">' || c.abc_class || '</span></td>'
             || '<td class="r">' || c.cnt || '</td><td class="r">' || pc(c.cnt * 100 / c.total_cnt) || '</td>'
             || '<td class="r">' || fv(c.val) || '</td><td class="r">' || pc(case when c.total_pos > 0 then c.val_pos * 100 / c.total_pos else 0 end) || '</td>'
             || '<td class="r">' || m(c.rev) || '</td><td class="r">' || m(c.gp) || '</td></tr>';
    end loop;
    l := l || '</table>';
    l := l || pareto_svg(l_rows, p_a, p_b, l_ms);
    -- таблиця позицій
    l := l || '<table class="grid"><tr><th>№</th><th>' || case when l_dim = 'PRODUCT' then 'Товар' else 'Клієнт' end || '</th>'
           || case when l_dim = 'PRODUCT' then '<th>Група</th>' end
           || '<th>Код</th><th>Кількість</th><th>Виручка</th><th>Собівартість</th><th>Валовий прибуток</th>'
           || '<th>Частка, %</th><th>Накопичено, %</th><th>Клас</th></tr>';
    for i in 1 .. l_rows.count loop
      l_qty := l_qty + l_rows(i).quantity; l_rev := l_rev + l_rows(i).revenue; l_cost := l_cost + l_rows(i).cost;
      l_gp := l_gp + l_rows(i).gross_profit; l_val := l_val + l_rows(i).value;
      l := l || '<tr><td class="r">' || l_rows(i).rn || '</td><td>'
             || case when l_dim = 'PRODUCT' then link_card(l_rows(i).object_name, l_rows(i).object_id, l_from, l_to) else e(l_rows(i).object_name) end
             || '</td>' || case when l_dim = 'PRODUCT' then '<td>' || e(l_rows(i).group_name) || '</td>' end
             || '<td>' || e(l_rows(i).object_code) || '</td>'
             || '<td class="r">' || q(l_rows(i).quantity) || '</td><td class="r">' || m(l_rows(i).revenue) || '</td>'
             || '<td class="r">' || m(l_rows(i).cost) || '</td><td class="r">' || m(l_rows(i).gross_profit) || '</td>'
             || '<td class="r">' || pc(l_rows(i).share_pct) || '</td><td class="r">' || pc(l_rows(i).cum_share_pct) || '</td>'
             || '<td class="c"><span class="abc abc-' || l_rows(i).abc_class || '">' || l_rows(i).abc_class || '</span></td></tr>';
    end loop;
    l := l || '<tr class="tot"><td colspan="' || l_cols || '">Разом</td>'
           || '<td class="r">' || q(l_qty) || '</td><td class="r">' || m(l_rev) || '</td><td class="r">' || m(l_cost) || '</td>'
           || '<td class="r">' || m(l_gp) || '</td><td></td><td></td><td></td></tr></table>'
           || '<p class="small">Позицій: ' || l_rows.count || '. Клас визначається накопиченою часткою перед позицією; '
           || 'позиції з показником ≤ 0 — клас C. Собівартість — RegStockCost (середня ковзна). '
           || 'Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end abc_html;

end trade_abc;
/
show errors package body trade_abc

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
  using (select 'AbcAnalysis' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'ABC-аналіз продажів', o.list_page_id = 460, o.form_page_id = null, o.auth_scheme = null
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('AbcAnalysis', 'REPORT', 'ABC-аналіз продажів', (select id from sys_main_menu_section where tech_name = 'Reports'), 460, null, 160, null);
  fp('Sales', 'Звіти', 2, 10, 'AbcAnalysis', 70);
  fp('Purchases', 'Звіти', 2, 10, 'AbcAnalysis', 60);
  fp('Main', 'Звіти', 2, 10, 'AbcAnalysis', 60);
  commit;
end;
/
