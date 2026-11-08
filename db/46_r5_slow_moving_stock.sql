-- =============================================================================
-- Trade r5 — F-WH-25 «Неліквіди й залежалі товари». Звіт на RegStockCost + RegSales (+ серії RegStockBalance).
--   * reg_markdown_rule «Правила уцінки неліквідів» (RegMarkdownRule, незалежний інформаційний регістр):
--     без продажу / руху від N днів → уцінка % і дія (уцінити / розпродати / списати); типові правила 90/180/365/730;
--   * пакет trade_slow_stock:
--       analysis(...) — конвеєрна функція: залишки товар × склад на дату, останнє надходження / продаж / вибуття,
--         днів без продажу (або без руху), ознака «залежалий» (≥ N днів), структура залишку за віком партій (FIFO:
--         залишок — останні надходження) у вартості, оборотність у днях за останні N днів (trade_turnover.analysis,
--         APE-116), прострочені й ті, що спливають протягом N днів, серії (APE-63), правило уцінки, рекомендація,
--         ціна обраного виду цін, рекомендована ціна, ознака «нижче собівартості»;
--       slow_html(...) — HTML звіту: підсумок (вартість, заморожений капітал, частка), структура за віком,
--         рекомендації, таблиця, перехід у картку товару (сторінка 450), друк;
--       create_price_setting(...) — документ «Встановлення цін» (DRAFT) з рекомендованими цінами уцінки;
--   * меню «Склад / Продажі / Закупівлі / Головне → Звіти» — «Неліквіди й залежалі товари» (сторінка 690),
--     «Ціноутворення» — «Правила уцінки неліквідів» (сторінка 695, адміністратор);
--   * демо: товар «Обігрівач масляний (демо неліквід)» — надходження 200 днів тому без продажів, роздрібна ціна.
-- Потребує 12/14 (RegStockCost), 15 (групи), 24 (organization_id), 35 (v_abc_sales_line), 38 (серії),
-- 45 (trade_turnover). Повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  ddl(q'[create table reg_markdown_rule (
    id               varchar2(32)  default on null rawtohex(sys_guid()) not null,
    idle_days_from   number(5)     not null,
    markdown_percent number(5,2)   default on null 0 not null,
    action           varchar2(20)  default on null 'MARKDOWN' not null,
    note             varchar2(255),
    updated_at       timestamp,
    updated_by       varchar2(255),
    constraint reg_markdown_rule_pk primary key (id),
    constraint reg_markdown_rule_days_uk unique (idle_days_from),
    constraint reg_markdown_rule_days_ck check (idle_days_from > 0),
    constraint reg_markdown_rule_pct_ck check (markdown_percent between 0 and 100),
    constraint reg_markdown_rule_act_ck check (action in ('MARKDOWN','CLEARANCE','WRITE_OFF')))]');
end;
/

create or replace trigger reg_markdown_rule_biu
before insert or update on reg_markdown_rule for each row
begin
  :new.updated_at := systimestamp;
  :new.updated_by := coalesce(sys_context('APEX$SESSION', 'APP_USER'), user);
end;
/

-- типові правила (лише якщо регістр порожній)
insert into reg_markdown_rule (idle_days_from, markdown_percent, action, note)
select d, p, a, n from (
  select 90 d, 10 p, 'MARKDOWN' a, 'Залежалий: перша уцінка' n from dual union all
  select 180, 25, 'MARKDOWN', 'Друга уцінка' from dual union all
  select 365, 50, 'CLEARANCE', 'Розпродаж за будь-яку ціну не нижче половини' from dual union all
  select 730, 100, 'WRITE_OFF', 'Списати або утилізувати' from dual)
 where not exists (select 1 from reg_markdown_rule);
commit;

create or replace package trade_slow_stock as
  type slow_row is record (
    rn                 number,
    product_id         varchar2(32),
    warehouse_id       varchar2(32),
    product_code       varchar2(50),
    product_name       varchar2(500),
    group_name         varchar2(4000),
    warehouse_name     varchar2(255),
    unit_name          varchar2(50),
    quantity           number,
    cost_amount        number,
    unit_cost          number,
    first_receipt_date date,
    last_receipt_date  date,
    last_sale_date     date,
    last_out_date      date,
    idle_days          number,       -- днів без продажу (SALE) або без руху (MOVE)
    is_slow            varchar2(1),  -- Y — idle_days ≥ порогу N
    age_d30            number,       -- вартість залишку за віком партій: ≤30, 31–90, 91–180, 181–365, >365 днів
    age_d90            number,
    age_d180           number,
    age_d365           number,
    age_over           number,
    oldest_age_days    number,
    window_sold_qty    number,       -- продано за останні N днів
    turnover_days      number,       -- оборотність у днях за останні N днів (trade_turnover)
    expired_qty        number,       -- залишок серій з минулим терміном придатності
    expiring_qty       number,       -- залишок серій, термін яких спливає протягом N днів
    nearest_expiry     date,
    rule_days          number,       -- правило уцінки (поріг днів), що застосовано
    markdown_percent   number,
    recommendation     varchar2(20), -- NONE / MONITOR / MARKDOWN / CLEARANCE / WRITE_OFF / EXPIRED / EXPIRING
    recommendation_name varchar2(100),
    price              number,
    recommended_price  number,
    below_cost         varchar2(1));
  type slow_tab is table of slow_row;

  -- Поріг «залежалий» за замовчуванням — найменший поріг правил уцінки (немає правил — 90)
  function default_days return number;
  -- Значення поля «Днів» сторінки: число або null (порожньо / не число)
  function to_days (p_text in varchar2) return number;
  function recommendation_name (p_code in varchar2) return varchar2 deterministic;
  -- Типовий вид цін (роздрібна — перший активний за кодом)
  function default_price_type return varchar2;

  -- p_date — дата залишку; p_days — поріг днів (null — default_days); p_basis SALE (без продажу; ніколи не
  -- продавався — від першого надходження) | MOVE (без будь-якого руху); p_only_slow Y — лише залежалі,
  -- прострочені або з терміном, що спливає; p_org / p_wh / p_group (з підгрупами) null — без відбору
  function analysis (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                     p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                     p_price_type in varchar2 default null, p_only_slow in varchar2 default 'Y') return slow_tab pipelined;

  function slow_html (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                      p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                      p_price_type in varchar2 default null, p_only_slow in varchar2 default 'Y') return clob;

  -- Документ «Встановлення цін» (чернетка) з рекомендованими цінами для рядків «уцінити / розпродати /
  -- спливає термін» (ціна товару — найменша рекомендована серед складів); повертає id документа
  function create_price_setting (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                                 p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                                 p_price_type in varchar2 default null) return varchar2;
end trade_slow_stock;
/

create or replace package body trade_slow_stock as

  type rule_rec is record (days number, pct number, action varchar2(20));
  type rule_tab is table of rule_rec;

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function default_days return number is
    l number;
  begin
    select min(idle_days_from) into l from reg_markdown_rule;
    return coalesce(l, 90);
  end default_days;

  function to_days (p_text in varchar2) return number is
  begin
    return to_number(trim(p_text));
  exception when value_error or invalid_number then
    return null;
  end to_days;

  function recommendation_name (p_code in varchar2) return varchar2 deterministic is
  begin
    return case p_code
             when 'NONE' then 'Не потрібно'
             when 'MONITOR' then 'Контролювати'
             when 'MARKDOWN' then 'Уцінити'
             when 'CLEARANCE' then 'Розпродати'
             when 'WRITE_OFF' then 'Списати'
             when 'EXPIRED' then 'Списати прострочене'
             when 'EXPIRING' then 'Уцінити: спливає термін'
           end;
  end recommendation_name;

  function default_price_type return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by code) into l from ref_price_type where state = 'ACTIVE';
    return l;
  end default_price_type;

  procedure check_params (p_basis varchar2, p_days number) is
  begin
    if coalesce(p_basis, 'SALE') not in ('SALE', 'MOVE') then
      trade_core.fail('Невідома ознака залежалості: ' || p_basis || ' (без продажу або без руху).');
    end if;
    if p_days is not null and p_days <= 0 then
      trade_core.fail('Кількість днів без продажу / руху має бути більшою за нуль.');
    end if;
  end check_params;

  function analysis (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                     p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                     p_price_type in varchar2 default null, p_only_slow in varchar2 default 'Y') return slow_tab pipelined is
    l_to    date := trunc(coalesce(p_date, sysdate));
    l_days  number;
    l_basis varchar2(10) := coalesce(p_basis, 'SALE');
    l_pt    varchar2(32);
    l_rules rule_tab;
    l_first rule_rec;
    r slow_row;
    l_rn number := 0;
  begin
    check_params(l_basis, p_days);
    l_days := coalesce(round(p_days), default_days);
    l_pt := coalesce(p_price_type, default_price_type);
    select idle_days_from, markdown_percent, action bulk collect into l_rules
      from reg_markdown_rule order by idle_days_from desc;
    if l_rules.count > 0 then
      l_first := l_rules(l_rules.count);
    end if;
    for x in (
      with grp as (
        select g.id from ref_product_group g where p_group is not null
         start with g.id = p_group connect by prior g.id = g.parent_id),
      mv as (
        select s.* from v_turnover_stock_mv s
         where s.period < l_to + 1
           and (p_org is null or s.organization_id = p_org)
           and (p_wh is null or s.warehouse_id = p_wh)
           and (p_group is null or s.group_id in (select id from grp))),
      bal as (
        select product_id, warehouse_id, sum(quantity) qty, sum(cost_amount) cost,
               min(case when quantity > 0 then day end) first_in,
               max(case when quantity > 0 then day end) last_in,
               max(case when quantity < 0 then day end) last_out
          from mv group by product_id, warehouse_id
        having sum(quantity) > 0),
      lay as (
        -- партії надходжень від найновішої; залишок за FIFO — останні надходження
        select m.product_id, m.warehouse_id, m.day, m.quantity,
               sum(m.quantity) over (partition by m.product_id, m.warehouse_id
                                     order by m.period desc, m.recorder_id desc, m.line_number desc
                                     rows between unbounded preceding and current row) - m.quantity cum_before
          from mv m where m.quantity > 0),
      age as (
        select b.product_id, b.warehouse_id,
               sum(case when l_to - l.day <= 30 then least(l.quantity, b.qty - l.cum_before) else 0 end) q30,
               sum(case when l_to - l.day between 31 and 90 then least(l.quantity, b.qty - l.cum_before) else 0 end) q90,
               sum(case when l_to - l.day between 91 and 180 then least(l.quantity, b.qty - l.cum_before) else 0 end) q180,
               sum(case when l_to - l.day between 181 and 365 then least(l.quantity, b.qty - l.cum_before) else 0 end) q365,
               sum(case when l_to - l.day > 365 then least(l.quantity, b.qty - l.cum_before) else 0 end) qover,
               max(l_to - l.day) oldest
          from bal b join lay l on l.product_id = b.product_id and l.warehouse_id = b.warehouse_id
         where l.cum_before < b.qty
         group by b.product_id, b.warehouse_id),
      sl as (
        select l.product_id, l.warehouse_id, max(trunc(l.period)) last_sale
          from v_abc_sales_line l
         where l.quantity > 0 and l.period < l_to + 1
           and (p_org is null or l.organization_id = p_org)
           and (p_wh is null or l.warehouse_id = p_wh)
         group by l.product_id, l.warehouse_id),
      ser as (
        select z.product_id, z.warehouse_id,
               sum(case when z.expiry_date < l_to then z.q else 0 end) expired_qty,
               sum(case when z.expiry_date >= l_to and z.expiry_date <= l_to + l_days then z.q else 0 end) expiring_qty,
               min(z.expiry_date) nearest_expiry
          from (select m.product_id, m.warehouse_id, m.series_id, s.expiry_date, sum(m.quantity) q
                  from reg_stock_balance_movement m
                  join ref_product_series s on s.id = m.series_id
                 where m.period < l_to + 1 and s.expiry_date is not null
                   and (p_wh is null or m.warehouse_id = p_wh)
                 group by m.product_id, m.warehouse_id, m.series_id, s.expiry_date
                having sum(m.quantity) > 0) z
         group by z.product_id, z.warehouse_id),
      tv as (
        select t.product_id, t.warehouse_id, t.sold_qty, t.turnover_days
          from table(trade_turnover.analysis('PRODUCT_WAREHOUSE', l_to - l_days + 1, l_to, p_org, p_wh, p_group)) t),
      v as (
        select b.*, sl.last_sale, a.q30, a.q90, a.q180, a.q365, a.qover, a.oldest,
               coalesce(ser.expired_qty, 0) expired_qty, coalesce(ser.expiring_qty, 0) expiring_qty, ser.nearest_expiry,
               coalesce(tv.sold_qty, 0) window_sold, tv.turnover_days,
               case when l_basis = 'MOVE' then l_to - greatest(b.last_in, coalesce(b.last_out, b.last_in))
                    else l_to - coalesce(sl.last_sale, b.first_in) end idle
          from bal b
          left join age a on a.product_id = b.product_id and a.warehouse_id = b.warehouse_id
          left join sl on sl.product_id = b.product_id and sl.warehouse_id = b.warehouse_id
          left join ser on ser.product_id = b.product_id and ser.warehouse_id = b.warehouse_id
          left join tv on tv.product_id = b.product_id and tv.warehouse_id = b.warehouse_id)
      select v.*, p.code product_code, p.name product_name, gp.full_path group_name, w.name warehouse_name,
             u.short_name unit_name
        from v
        join ref_product p on p.id = v.product_id
        join ref_warehouse w on w.id = v.warehouse_id
        left join ref_unit_of_measure u on u.id = p.unit_of_measure_id
        left join v_product_group_path gp on gp.id = p.group_id
       where coalesce(p_only_slow, 'Y') = 'N' or v.idle >= l_days or v.expired_qty > 0 or v.expiring_qty > 0
       order by case when v.idle >= l_days then 0 else 1 end, v.idle desc, v.cost desc, p.name, w.name) loop
      r := null;
      l_rn := l_rn + 1;
      r.rn := l_rn;
      r.product_id := x.product_id; r.warehouse_id := x.warehouse_id;
      r.product_code := x.product_code; r.product_name := x.product_name; r.group_name := x.group_name;
      r.warehouse_name := x.warehouse_name; r.unit_name := x.unit_name;
      r.quantity := x.qty; r.cost_amount := round(x.cost, 2);
      r.unit_cost := case when x.qty > 0 then round(x.cost / x.qty, 2) end;
      r.first_receipt_date := x.first_in; r.last_receipt_date := x.last_in;
      r.last_sale_date := x.last_sale; r.last_out_date := x.last_out;
      r.idle_days := x.idle;
      r.is_slow := case when x.idle >= l_days then 'Y' else 'N' end;
      -- вартість за віком: кількість партії × середня собівартість; нерозподілений залишок — до найстаршої групи
      r.age_d30 := round(coalesce(x.q30, 0) * x.cost / x.qty, 2);
      r.age_d90 := round(coalesce(x.q90, 0) * x.cost / x.qty, 2);
      r.age_d180 := round(coalesce(x.q180, 0) * x.cost / x.qty, 2);
      r.age_d365 := round(coalesce(x.q365, 0) * x.cost / x.qty, 2);
      r.age_over := r.cost_amount - r.age_d30 - r.age_d90 - r.age_d180 - r.age_d365;
      r.oldest_age_days := x.oldest;
      r.window_sold_qty := x.window_sold;
      r.turnover_days := x.turnover_days;
      r.expired_qty := x.expired_qty; r.expiring_qty := x.expiring_qty; r.nearest_expiry := x.nearest_expiry;
      -- правило уцінки
      r.recommendation := case when r.is_slow = 'Y' then 'MONITOR' else 'NONE' end;
      r.markdown_percent := 0;
      if r.is_slow = 'Y' then
        for i in 1 .. l_rules.count loop
          if x.idle >= l_rules(i).days then
            r.rule_days := l_rules(i).days; r.markdown_percent := l_rules(i).pct; r.recommendation := l_rules(i).action;
            exit;
          end if;
        end loop;
      end if;
      if x.expired_qty > 0 and r.recommendation <> 'WRITE_OFF' then
        r.recommendation := 'EXPIRED';
      elsif x.expiring_qty > 0 and r.recommendation in ('NONE', 'MONITOR') and l_first.days is not null then
        r.recommendation := 'EXPIRING';
        r.rule_days := l_first.days;
        r.markdown_percent := case when l_first.action = 'WRITE_OFF' then 0 else l_first.pct end;
      end if;
      r.recommendation_name := recommendation_name(r.recommendation);
      if l_pt is not null then
        r.price := trade_lines.get_price(l_pt, x.product_id, l_to);
      end if;
      if r.price is not null and r.recommendation in ('MARKDOWN', 'CLEARANCE', 'EXPIRING', 'EXPIRED') and r.markdown_percent > 0 then
        r.recommended_price := round(r.price * (1 - r.markdown_percent / 100), 2);
        r.below_cost := case when r.recommended_price < r.unit_cost then 'Y' else 'N' end;
      end if;
      pipe row (r);
    end loop;
    return;
  end analysis;

  function link_card (p_name varchar2, p_product varchar2, p_wh varchar2, p_to date) return varchar2 is
  begin
    if p_product is null or v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => 450, p_items => 'P450_PRODUCT,P450_WH,P450_FROM,P450_TO',
                                            p_values => p_product || ',' || p_wh || ',' || dt(add_months(p_to, -12)) || ',' || dt(p_to))
           || '">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end link_card;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1300px;background:#fff;padding:16px}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}
      .tx-print h3{font-size:14px;margin:12px 0 4px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .tot td{font-weight:bold;background:#fafafa}
      .tx-print .small{font-size:11px;color:#333}
      .tx-print .slow{color:#c62828}.tx-print .warn{color:#e65100}
      .tx-print .bar{display:inline-block;height:10px;background:#c62828;vertical-align:middle}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  function slow_html (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                      p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                      p_price_type in varchar2 default null, p_only_slow in varchar2 default 'Y') return clob is
    l clob;
    l_to date := trunc(coalesce(p_date, sysdate));
    l_days number;
    l_basis varchar2(10) := coalesce(p_basis, 'SALE');
    l_rows slow_tab;
    l_org varchar2(255); l_whn varchar2(255); l_grp varchar2(4000); l_ptn varchar2(255);
    t_cost number := 0; t_slow number := 0; t_slow_n number := 0; t_exp number := 0;
    t_a1 number := 0; t_a2 number := 0; t_a3 number := 0; t_a4 number := 0; t_a5 number := 0;
    type t_num is table of number index by varchar2(20);
    rc t_num; rs t_num;
    k varchar2(20);
    function pct (a number, b number) return varchar2 is
    begin
      return case when b > 0 then to_char(round(a / b * 100, 1), 'FM990D0') || '%' else '—' end;
    end;
    function age_row (p_name varchar2, p_val number) return varchar2 is
    begin
      return '<tr><td>' || p_name || '</td><td class="r">' || m(p_val) || '</td><td class="r">' || pct(p_val, t_cost)
          || '</td><td><span class="bar" style="width:' || case when t_cost > 0 then round(p_val / t_cost * 200) else 0 end
          || 'px"></span></td></tr>';
    end;
  begin
    begin
      check_params(l_basis, p_days);
    exception when others then
      return '<div class="tx-print"><p>' || e(regexp_replace(sqlerrm, '^ORA-[0-9]+: ')) || '</p></div>';
    end;
    l_days := coalesce(round(p_days), default_days);
    select * bulk collect into l_rows
      from table(analysis(l_to, l_days, l_basis, p_org, p_wh, p_group, p_price_type, p_only_slow));
    if p_org is not null then select max(name) into l_org from ref_organization where id = p_org; end if;
    if p_wh is not null then select max(name) into l_whn from ref_warehouse where id = p_wh; end if;
    if p_group is not null then select max(full_path) into l_grp from v_product_group_path where id = p_group; end if;
    select max(name) into l_ptn from ref_price_type where id = coalesce(p_price_type, default_price_type);
    l := '<div class="tx-print">' || css
      || '<h2>Неліквіди й залежалі товари на ' || dt(l_to) || '</h2>'
      || '<table class="small" style="margin-bottom:8px"><tr><td>Залежалий — ' || case l_basis when 'MOVE' then 'без руху' else 'без продажу' end
      || ' від <b>' || l_days || '</b> дн.' || case when coalesce(p_only_slow, 'Y') = 'Y' then '; показано лише залежалі й товари з терміном придатності, що минає' else '; усі залишки' end
      || '</td><td class="r">Склад: <b>' || e(coalesce(l_whn, 'усі склади')) || '</b></td></tr>'
      || '<tr><td>Організація: <b>' || e(coalesce(l_org, 'усі організації')) || '</b>; група номенклатури: <b>'
      || e(coalesce(l_grp, 'усі групи')) || '</b>' || case when l_grp is not null then ' (з підгрупами)' end || '</td>'
      || '<td class="r">Ціни: <b>' || e(coalesce(l_ptn, '—')) || '</b>; вартість — середня собівартість (RegStockCost), грн</td></tr></table>';
    if l_rows.count = 0 then
      return l || '<p class="c">Залежалих товарів немає.</p></div>';
    end if;
    for i in 1 .. l_rows.count loop
      t_cost := t_cost + l_rows(i).cost_amount;
      if l_rows(i).is_slow = 'Y' then t_slow := t_slow + l_rows(i).cost_amount; t_slow_n := t_slow_n + 1; end if;
      t_exp := t_exp + case when l_rows(i).expired_qty > 0 then round(l_rows(i).expired_qty * l_rows(i).unit_cost, 2) else 0 end;
      t_a1 := t_a1 + l_rows(i).age_d30; t_a2 := t_a2 + l_rows(i).age_d90; t_a3 := t_a3 + l_rows(i).age_d180;
      t_a4 := t_a4 + l_rows(i).age_d365; t_a5 := t_a5 + l_rows(i).age_over;
      k := l_rows(i).recommendation;
      rc(k) := case when rc.exists(k) then rc(k) else 0 end + 1;
      rs(k) := case when rs.exists(k) then rs(k) else 0 end + l_rows(i).cost_amount;
    end loop;
    -- підсумок
    l := l || '<table class="grid" style="margin-bottom:8px;width:auto"><tr><th>Позицій</th><th>Вартість залишку, грн</th>'
           || '<th>Залежалих позицій</th><th>Заморожений капітал, грн</th><th>Частка</th><th>Прострочено, грн</th></tr><tr>'
           || '<td class="r">' || l_rows.count || '</td><td class="r">' || m(t_cost) || '</td>'
           || '<td class="r">' || t_slow_n || '</td><td class="r slow"><b>' || m(t_slow) || '</b></td>'
           || '<td class="r">' || pct(t_slow, t_cost) || '</td><td class="r">' || m(t_exp) || '</td></tr></table>';
    -- структура за віком і рекомендації
    l := l || '<table style="width:auto"><tr><td style="vertical-align:top;padding-right:24px"><h3>Вартість за віком партій</h3>'
           || '<table class="grid" style="width:auto"><tr><th>Вік, днів</th><th>Вартість, грн</th><th>Частка</th><th></th></tr>'
           || age_row('до 30', t_a1) || age_row('31–90', t_a2) || age_row('91–180', t_a3)
           || age_row('181–365', t_a4) || age_row('понад 365', t_a5) || '</table></td>'
           || '<td style="vertical-align:top"><h3>Рекомендації</h3><table class="grid" style="width:auto">'
           || '<tr><th>Рекомендація</th><th>Позицій</th><th>Вартість, грн</th></tr>';
    for c in (select column_value code from table(sys.odcivarchar2list('WRITE_OFF', 'EXPIRED', 'CLEARANCE', 'MARKDOWN', 'EXPIRING', 'MONITOR', 'NONE'))) loop
      if rc.exists(c.code) then
        l := l || '<tr><td>' || e(recommendation_name(c.code)) || '</td><td class="r">' || rc(c.code) || '</td><td class="r">' || m(rs(c.code)) || '</td></tr>';
      end if;
    end loop;
    l := l || '</table></td></tr></table>';
    -- таблиця
    l := l || '<h3>Товари</h3><table class="grid"><tr><th>№</th><th>Товар</th><th>Склад</th><th>Од.</th><th>Залишок</th>'
           || '<th>Вартість, грн</th><th>Останнє надходження</th><th>Останній продаж</th><th>Днів ' || case l_basis when 'MOVE' then 'без руху' else 'без продажу' end || '</th>'
           || '<th>Найстаріша партія, днів</th><th>Продано за ' || l_days || ' дн.</th><th>Оборотність, днів</th>'
           || '<th>Термін придатності</th><th>Рекомендація</th><th>Уцінка, %</th><th>Ціна</th><th>Рекомендована ціна</th></tr>';
    for i in 1 .. l_rows.count loop
      l := l || '<tr><td class="r">' || l_rows(i).rn || '</td><td>'
             || link_card(l_rows(i).product_name, l_rows(i).product_id, l_rows(i).warehouse_id, l_to)
             || '<div class="small">' || e(l_rows(i).group_name) || '</div></td>'
             || '<td>' || e(l_rows(i).warehouse_name) || '</td><td>' || e(l_rows(i).unit_name) || '</td>'
             || '<td class="r">' || q(l_rows(i).quantity) || '</td><td class="r">' || m(l_rows(i).cost_amount) || '</td>'
             || '<td class="c">' || dt(l_rows(i).last_receipt_date) || '</td>'
             || '<td class="c">' || coalesce(dt(l_rows(i).last_sale_date), '<span class="small">не продавався</span>') || '</td>'
             || '<td class="r' || case when l_rows(i).is_slow = 'Y' then ' slow' end || '">' || l_rows(i).idle_days || '</td>'
             || '<td class="r">' || l_rows(i).oldest_age_days || '</td>'
             || '<td class="r">' || q(l_rows(i).window_sold_qty) || '</td>'
             || '<td class="r">' || case when l_rows(i).turnover_days is not null then to_char(l_rows(i).turnover_days, 'FM999G999G990D0')
                                         else '<span class="small">немає продажів</span>' end || '</td>'
             || '<td>' || case when l_rows(i).expired_qty > 0 then '<span class="slow">прострочено ' || q(l_rows(i).expired_qty) || '</span><br>' end
             || case when l_rows(i).expiring_qty > 0 then '<span class="warn">спливає ' || q(l_rows(i).expiring_qty) || '</span><br>' end
             || case when l_rows(i).nearest_expiry is not null then '<span class="small">найближчий до ' || dt(l_rows(i).nearest_expiry) || '</span>' end || '</td>'
             || '<td' || case when l_rows(i).recommendation in ('WRITE_OFF', 'EXPIRED') then ' class="slow"' end || '>'
             || e(l_rows(i).recommendation_name) || '</td>'
             || '<td class="r">' || case when l_rows(i).markdown_percent > 0 then rtrim(rtrim(to_char(l_rows(i).markdown_percent, 'FM990D00'), '0'), ',.') end || '</td>'
             || '<td class="r">' || m(l_rows(i).price) || '</td>'
             || '<td class="r' || case when l_rows(i).below_cost = 'Y' then ' slow' end || '">' || m(l_rows(i).recommended_price)
             || case when l_rows(i).below_cost = 'Y' then '<div class="small">нижче собівартості ' || m(l_rows(i).unit_cost) || '</div>' end
             || '</td></tr>';
    end loop;
    l := l || '<tr class="tot"><td colspan="5">Разом</td><td class="r">' || m(t_cost) || '</td><td colspan="11"></td></tr></table>'
           || '<p class="small">Днів без продажу — від останнього продажу (не продавався — від першого надходження на склад); '
           || 'без руху — від останнього надходження або вибуття. Вік партій — за FIFO (залишок складають останні надходження). '
           || 'Оборотність — за останні ' || l_days || ' дн. (звіт «Оборотність запасів»). Рекомендація — за правилами уцінки '
           || '(«Правила уцінки неліквідів»); прострочені серії — до списання. '
           || 'Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end slow_html;

  function create_price_setting (p_date in date, p_days in number default null, p_basis in varchar2 default 'SALE',
                                 p_org in varchar2 default null, p_wh in varchar2 default null, p_group in varchar2 default null,
                                 p_price_type in varchar2 default null) return varchar2 is
    l_pt varchar2(32) := coalesce(p_price_type, default_price_type);
    l_doc varchar2(32);
    l_n number := 0;
    l_comment varchar2(1000) := 'Уцінка неліквідів на ' || dt(trunc(coalesce(p_date, sysdate)))
                                || ' (звіт «Неліквіди й залежалі товари»)';
  begin
    if l_pt is null then
      trade_core.fail('Не вказано вид цін для документа уцінки.');
    end if;
    for x in (select product_id, min(recommended_price) price
                from table(analysis(p_date, p_days, p_basis, p_org, p_wh, p_group, l_pt, 'Y'))
               where recommendation in ('MARKDOWN', 'CLEARANCE', 'EXPIRING', 'EXPIRED')
                 and recommended_price is not null and recommended_price < price
               group by product_id
               order by min(product_name)) loop
      if l_doc is null then
        insert into doc_price_setting (occurred_at, price_type_id, doc_comment)
        values (sysdate, l_pt, l_comment)
        returning id into l_doc;
      end if;
      insert into doc_price_setting_prices (document_id, product_id, price) values (l_doc, x.product_id, x.price);
      l_n := l_n + 1;
    end loop;
    if l_doc is null then
      trade_core.fail('Немає товарів для уцінки: рекомендованих знижень ціни за обраним видом цін немає.');
    end if;
    trade_core.audit('DocPriceSetting', l_doc, 'CREATE_BASED_ON', 'Уцінка неліквідів: ' || l_n || ' товар(ів)');
    return l_doc;
  end create_price_setting;

end trade_slow_stock;
/
show errors package body trade_slow_stock

-- ---------------------------------------------------------------- демо: залежалий товар
declare
  l_prd varchar2(32); l_wh varchar2(32); l_sup varchar2(32); l_uom varchar2(32); l_grp varchar2(32);
  l_doc varchar2(32); l_pt varchar2(32);
begin
  select max(id) into l_prd from ref_product where name = 'Обігрівач масляний (демо неліквід)';
  if l_prd is null then
    select max(id) into l_wh from ref_warehouse where name = 'Основний склад';
    select max(id) keep (dense_rank first order by code) into l_sup from ref_counterparty where state = 'ACTIVE';
    select max(id) into l_uom from ref_unit_of_measure where short_name = 'шт';
    select max(group_id) into l_grp from ref_product where name = 'Тостер';
    l_pt := trade_slow_stock.default_price_type;
    if l_wh is null or l_sup is null or l_uom is null then
      return;
    end if;
    insert into ref_product (name, unit_of_measure_id, group_id, product_kind) values ('Обігрівач масляний (демо неліквід)', l_uom, l_grp, 'GOODS')
      returning id into l_prd;
    if l_pt is not null then
      insert into doc_price_setting (occurred_at, price_type_id, doc_comment)
      values (trunc(sysdate) - 200, l_pt, 'Демо: ціна залежалого товару') returning id into l_doc;
      insert into doc_price_setting_prices (document_id, product_id, price) values (l_doc, l_prd, 2400);
      trade_ops.post_price_setting(l_doc);
    end if;
    insert into doc_goods_receipt (supplier_id, warehouse_id, occurred_at, doc_comment)
    values (l_sup, l_wh, trunc(sysdate) - 200 + 10/24, 'Демо: товар без продажів (неліквід)') returning id into l_doc;
    insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (l_doc, 1, l_prd, 5, 1500, 0);
    trade_doc.post_goods_receipt(l_doc);
  end if;
  commit;
end;
/

-- ---------------------------------------------------------------- меню
declare
  procedure obj (p_tech varchar2, p_kind varchar2, p_section varchar2, p_name varchar2, p_list number, p_form number,
                 p_sort number, p_auth varchar2) is
  begin
    merge into sys_metadata_object o
    using (select p_tech tech_name from dual) s on (o.tech_name = s.tech_name)
    when matched then update set o.name = p_name, o.list_page_id = p_list, o.form_page_id = p_form, o.auth_scheme = p_auth
    when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
      values (p_tech, p_kind, p_name, (select id from sys_main_menu_section where tech_name = p_section), p_list, p_form, p_sort, p_auth);
  end;
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_tech varchar2, p_isort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_isort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_tech
       and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  end;
begin
  obj('SlowMovingStock',  'REPORT',               'Reports', 'Неліквіди й залежалі товари', 690, null, 280, null);
  obj('RegMarkdownRule',  'INFORMATION_REGISTER', 'Reports', 'Правила уцінки неліквідів',   695, null, 285, 'Роль: адміністратор');
  fp('Warehouse', 'Звіти', 2, 10, 'SlowMovingStock', 16);
  fp('Sales', 'Звіти', 2, 10, 'SlowMovingStock', 76);
  fp('Purchases', 'Звіти', 2, 10, 'SlowMovingStock', 66);
  fp('Main', 'Звіти', 2, 10, 'SlowMovingStock', 66);
  fp('Pricing', 'Знижки', 1, 20, 'RegMarkdownRule', 30);
  commit;
end;
/
