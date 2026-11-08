-- F-WH-25 «Неліквіди й залежалі товари»: днів без продажу / руху, ознака «залежалий», вік партій (FIFO),
-- заморожений капітал, оборотність за N днів (trade_turnover), серії прострочені / що спливають, правила уцінки,
-- рекомендована ціна (нижче собівартості), відбори, документ «Встановлення цін» з уцінкою, помилки, HTML, меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); w1 varchar2(32); w2 varchar2(32); l_uom varchar2(32); l_sup varchar2(32); c1 varchar2(32);
  g1 varchar2(32); g2 varchar2(32); g3 varchar2(32); l_pt varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); p4 varchar2(32); p5 varchar2(32); p6 varchar2(32); s1 varchar2(32);
  se1 varchar2(32); se2 varchar2(32); se3 varchar2(32);
  rc varchar2(32); sa varchar2(32); l_doc varchar2(32);
  l_n number; l_c clob; l_s varchar2(4000);
  d0 date := trunc(sysdate);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure has (p_name varchar2, p_html clob, p_text varchar2, p_times number default 1) is
    l number := 0; p number := 1;
  begin
    loop
      p := dbms_lob.instr(p_html, p_text, p);
      exit when p = 0 or p is null;
      l := l + 1; p := p + 1;
    end loop;
    dbms_output.put_line(case when l = p_times then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || l || ' × «' || p_text || '»');
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_basis varchar2, p_days number) is
  begin
    for r in (select * from table(trade_slow_stock.analysis(d0, p_days, p_basis))) loop
      null;
    end loop;
    dbms_output.put_line('FAIL ' || p_name || ': помилки не було');
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || sqlerrm);
  end;
  -- значення колонки рядка товар × склад; p_org 'A' / 'B' / null
  function val (p_prd varchar2, p_col varchar2, p_wh varchar2 default null, p_basis varchar2 default 'SALE',
                p_org varchar2 default 'A', p_scope varchar2 default 'Y', p_grp varchar2 default null, p_days number default null) return number is
    l number;
  begin
    select max(case p_col when 'Q' then quantity when 'C' then cost_amount when 'UC' then unit_cost when 'I' then idle_days
                          when 'A30' then age_d30 when 'A90' then age_d90 when 'A180' then age_d180 when 'A365' then age_d365
                          when 'AO' then age_over when 'OLD' then oldest_age_days when 'WS' then window_sold_qty
                          when 'TD' then turnover_days when 'EX' then expired_qty when 'EG' then expiring_qty
                          when 'RD' then rule_days when 'MP' then markdown_percent when 'P' then price when 'RP' then recommended_price
                          when 'RN' then rn when 'CNT' then 1 end)
      into l from table(trade_slow_stock.analysis(d0, p_days, p_basis, case p_org when 'A' then l_org when 'B' then l_org2 end,
                                                  p_wh, p_grp, l_pt, p_scope))
     where product_id = p_prd and (p_wh is null or warehouse_id = p_wh);
    return l;
  end;
  function txt (p_prd varchar2, p_col varchar2, p_basis varchar2 default 'SALE', p_org varchar2 default 'A') return varchar2 is
    l varchar2(4000);
  begin
    select max(case p_col when 'R' then recommendation when 'S' then is_slow when 'B' then below_cost
                          when 'LS' then to_char(last_sale_date, 'YYYYMMDD') when 'LR' then to_char(last_receipt_date, 'YYYYMMDD') end)
      into l from table(trade_slow_stock.analysis(d0, null, p_basis, case p_org when 'A' then l_org when 'B' then l_org2 end,
                                                  null, null, l_pt, 'N'))
     where product_id = p_prd;
    return l;
  end;
  function cnt (p_org varchar2, p_wh varchar2 default null, p_grp varchar2 default null, p_scope varchar2 default 'Y') return number is
    l number;
  begin
    select count(*) into l from table(trade_slow_stock.analysis(d0, null, 'SALE', p_org, p_wh, p_grp, l_pt, p_scope));
    return l;
  end;
  procedure receipt (p_org varchar2, p_wh varchar2, p_at date, p_prd varchar2, p_qty number, p_price number, p_ser varchar2 default null) is
  begin
    insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (p_org, l_sup, p_wh, p_at)
      returning id into rc;
    insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount, series_id)
    values (rc, 1, p_prd, p_qty, p_price, 0, p_ser);
    trade_doc.post_goods_receipt(rc);
  end;
  function sale (p_org varchar2, p_wh varchar2, p_at date, p_prd varchar2, p_qty number, p_price number) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (p_org, c1, p_wh, p_at)
      returning id into l;
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l, p_prd, p_qty, p_price);
    trade_ops.post_goods_sale(l);
    return l;
  end;
  procedure price (p_prd varchar2, p_price number) is
    l varchar2(32);
  begin
    insert into doc_price_setting (occurred_at, price_type_id) values (d0 - 300, l_pt) returning id into l;
    insert into doc_price_setting_prices (document_id, product_id, price) values (l, p_prd, p_price);
    trade_ops.post_price_setting(l);
  end;
begin
  -- ---------------------------------------------------------------- правила (тестові)
  delete from reg_markdown_rule;
  insert into reg_markdown_rule (idle_days_from, markdown_percent, action) values (60, 10, 'MARKDOWN');
  insert into reg_markdown_rule (idle_days_from, markdown_percent, action) values (150, 30, 'CLEARANCE');
  insert into reg_markdown_rule (idle_days_from, markdown_percent, action) values (400, 100, 'WRITE_OFF');
  eq('Поріг за замовчуванням = найменше правило', trade_slow_stock.default_days, 60);
  select count(*) into l_n from reg_markdown_rule where updated_by is not null and updated_at is not null;
  eq('Правила: змінив / коли заповнено тригером', l_n, 3);
  begin
    insert into reg_markdown_rule (idle_days_from, markdown_percent, action) values (500, 10, 'XXX');
    eq('Правило з невідомою дією відхилено', 0, 1);
  exception when others then eq('Правило з невідомою дією відхилено', case when sqlcode = -2290 then 1 else 0 end, 1);
  end;
  begin
    insert into reg_markdown_rule (idle_days_from, markdown_percent, action) values (60, 5, 'MARKDOWN');
    eq('Дубль порогу відхилено', 0, 1);
  exception when dup_val_on_index then eq('Дубль порогу відхилено', 1, 1);
  end;
  eq('to_days: число', trade_slow_stock.to_days(' 45 '), 45);
  eq('to_days: не число → null', trade_slow_stock.to_days('abc'), null);

  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T27 ТОВ А ' || t, 'LEGAL', '27272727') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T27 ТОВ Б ' || t, 'LEGAL', '27272728') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T27 склад 1 ' || t) returning id into w1;
  insert into ref_warehouse (name) values ('T27 склад 2 ' || t) returning id into w2;
  insert into ref_counterparty (name) values ('T27 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T27 покупець ' || t) returning id into c1;
  insert into ref_price_type (name) values ('T27 роздріб ' || t) returning id into l_pt;
  insert into ref_product_group (name) values ('T27 Техніка ' || t) returning id into g1;
  insert into ref_product_group (name, parent_id) values ('T27 Обігрівачі', g1) returning id into g2;
  insert into ref_product_group (name) values ('T27 Продукти ' || t) returning id into g3;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T27 А Обігрівач ' || t, l_uom, g2) returning id into p1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T27 Б Вентилятор ' || t, l_uom, g1) returning id into p2;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T27 В Чайник ' || t, l_uom, g1) returning id into p3;
  insert into ref_product (name, unit_of_measure_id, group_id, use_series, shelf_life_days) values ('T27 Г Йогурт ' || t, l_uom, g3, 'Y', 30) returning id into p4;
  insert into ref_product (name, unit_of_measure_id, group_id, use_series) values ('T27 Д Сир ' || t, l_uom, g3, 'Y') returning id into p5;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T27 Е Плита ' || t, l_uom, g1) returning id into p6;
  insert into ref_product (name, unit_of_measure_id, group_id, product_kind) values ('T27 Ж Монтаж ' || t, l_uom, g1, 'SERVICE') returning id into s1;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('Y-1', p4, d0 - 40, d0 - 5) returning id into se1;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('Y-2', p4, d0 - 10, d0 + 20) returning id into se2;
  insert into ref_product_series (name, product_id, production_date, expiry_date) values ('C-1', p5, d0 - 10, d0 + 40) returning id into se3;
  price(p1, 1000); price(p2, 200); price(p3, 500); price(p5, 100);

  -- Обігрівач: 4 × 900 200 днів тому, не продавався → 200 днів, правило 150 (розпродаж 30%): 1000 → 700 < 900
  receipt(l_org, w1, d0 - 200 + 0.5, p1, 4, 900);
  -- Вентилятор: 10 × 100 (d0−200), продаж 4 (d0−100), 5 × 130 (d0−20): залишок 11 на 1250
  receipt(l_org, w1, d0 - 200 + 0.6, p2, 10, 100);
  sa := sale(l_org, w1, d0 - 100 + 0.5, p2, 4, 200);
  receipt(l_org, w1, d0 - 20 + 0.5, p2, 5, 130);
  -- Чайник: 10 × 300 (d0−10), продаж 2 (d0−5) — не залежалий
  receipt(l_org, w2, d0 - 10 + 0.5, p3, 10, 300);
  sa := sale(l_org, w2, d0 - 5 + 0.5, p3, 2, 500);
  -- Йогурт: серія Y-1 прострочена (3), Y-2 спливає за 20 днів (4); прихід d0−30
  receipt(l_org, w1, d0 - 30 + 0.5, p4, 3, 20, se1);
  receipt(l_org, w1, d0 - 30 + 0.6, p4, 4, 20, se2);
  -- Сир: серія C-1 спливає за 40 днів (≤ 60) → «спливає термін»; прихід d0−10
  receipt(l_org, w1, d0 - 10 + 0.5, p5, 6, 50, se3);
  -- Плита: орг. Б, 2 × 2000 (d0−500) → списати
  receipt(l_org2, w1, d0 - 500 + 0.5, p6, 2, 2000);

  -- ---------------------------------------------------------------- без продажу (SALE), орг. А
  eq('Обігрівач: залишок 4', val(p1, 'Q'), 4);
  eq('Обігрівач: вартість 3600', val(p1, 'C'), 3600);
  eq('Обігрівач: днів без продажу 200 (не продавався — від надходження)', val(p1, 'I'), 200);
  eqs('Обігрівач: останній продаж немає', txt(p1, 'LS'), null);
  eqs('Обігрівач: останнє надходження', txt(p1, 'LR'), to_char(d0 - 200, 'YYYYMMDD'));
  eqs('Обігрівач: залежалий', txt(p1, 'S'), 'Y');
  eq('Обігрівач: правило 150', val(p1, 'RD'), 150);
  eqs('Обігрівач: розпродати', txt(p1, 'R'), 'CLEARANCE');
  eq('Обігрівач: уцінка 30%', val(p1, 'MP'), 30);
  eq('Обігрівач: ціна 1000', val(p1, 'P'), 1000);
  eq('Обігрівач: рекомендована 700', val(p1, 'RP'), 700);
  eqs('Обігрівач: нижче собівартості 900', txt(p1, 'B'), 'Y');
  eq('Обігрівач: вік 181–365 — уся вартість', val(p1, 'A365'), 3600);
  eq('Обігрівач: найстаріша партія 200', val(p1, 'OLD'), 200);
  eq('Обігрівач: продано за 60 дн. 0', val(p1, 'WS'), 0);
  eq('Обігрівач: оборотність — немає продажів', val(p1, 'TD'), null);
  eq('Обігрівач — перший (найбільше днів)', val(p1, 'RN'), 1);

  eq('Вентилятор: залишок 11', val(p2, 'Q'), 11);
  eq('Вентилятор: вартість 1250', val(p2, 'C'), 1250);
  eq('Вентилятор: собівартість одиниці', val(p2, 'UC'), round(1250 / 11, 2));
  eq('Вентилятор: днів без продажу 100', val(p2, 'I'), 100);
  eqs('Вентилятор: уцінити (правило 60)', txt(p2, 'R'), 'MARKDOWN');
  eq('Вентилятор: рекомендована 180', val(p2, 'RP'), 180);
  eqs('Вентилятор: не нижче собівартості', txt(p2, 'B'), 'N');
  -- FIFO: 5 останнього приходу (20 дн.) + 6 з приходу 200 дн.
  eq('Вентилятор: вік ≤30 = 5/11 вартості', val(p2, 'A30'), round(5 * 1250 / 11, 2));
  eq('Вентилятор: вік 181–365 = 6/11 вартості', val(p2, 'A365'), 1250 - round(5 * 1250 / 11, 2));
  eq('Вентилятор: вік 31–90 = 0', val(p2, 'A90'), 0);
  eq('Вентилятор: найстаріша партія 200', val(p2, 'OLD'), 200);
  eq('Вентилятор: поріг 120 → правило 60 не досягнуто (не залежалий)', val(p2, 'CNT', p_days => 120), null);
  eq('Вентилятор: поріг 120, усі залишки — є', val(p2, 'I', p_days => 120, p_scope => 'N'), 100);

  eq('Чайник: не залежалий — не в списку', val(p3, 'CNT'), null);
  eqs('Чайник: усі залишки — не потрібно', txt(p3, 'R'), 'NONE');
  eq('Чайник: днів без продажу 5', val(p3, 'I', p_scope => 'N'), 5);
  eq('Чайник: продано за 60 дн. 2', val(p3, 'WS', p_scope => 'N'), 2);
  select max(turnover_days) into l_n
    from table(trade_turnover.analysis('PRODUCT_WAREHOUSE', d0 - 59, d0, l_org, null, null)) where product_id = p3;
  eq('Чайник: оборотність = trade_turnover за 60 дн.', val(p3, 'TD', p_scope => 'N'), l_n);
  eq('Чайник: рекомендованої ціни немає', val(p3, 'RP', p_scope => 'N'), null);

  -- серії
  eq('Йогурт: прострочено 3', val(p4, 'EX'), 3);
  eq('Йогурт: спливає 4', val(p4, 'EG'), 4);
  eqs('Йогурт: списати прострочене', txt(p4, 'R'), 'EXPIRED');
  eq('Йогурт: 30 днів — не залежалий, але у списку', val(p4, 'I'), 30);
  eq('Йогурт: ціни немає → рекомендованої немає', val(p4, 'RP'), null);
  eqs('Сир: спливає термін', txt(p5, 'R'), 'EXPIRING');
  eq('Сир: уцінка першого правила 10%', val(p5, 'MP'), 10);
  eq('Сир: рекомендована 90', val(p5, 'RP'), 90);
  eq('Сир: поріг 30 → термін (40 дн.) поза вікном', val(p5, 'EG', p_days => 30, p_scope => 'N'), 0);

  eq('Послуга не входить', val(s1, 'CNT', p_scope => 'N'), null);
  eq('Рядків орг. А (залежалі + серії)', cnt(l_org), 4);
  eq('Рядків орг. А (усі залишки)', cnt(l_org, p_scope => 'N'), 5);

  -- ---------------------------------------------------------------- без руху (MOVE)
  eq('MOVE: Обігрівач 200', val(p1, 'I', p_basis => 'MOVE'), 200);
  eq('MOVE: Вентилятор 20 (останнє надходження)', val(p2, 'I', p_basis => 'MOVE', p_scope => 'N'), 20);
  eqs('MOVE: Вентилятор не залежалий', txt(p2, 'S', 'MOVE'), 'N');
  eq('MOVE: Чайник 5 (останній продаж)', val(p3, 'I', p_basis => 'MOVE', p_scope => 'N'), 5);

  -- ---------------------------------------------------------------- відбори
  eq('Орг. Б: Плита 500 днів', val(p6, 'I', p_org => 'B'), 500);
  eqs('Орг. Б: Плита — списати (правило 400)', txt(p6, 'R', p_org => 'B'), 'WRITE_OFF');
  eq('Орг. Б: Плита — рекомендованої ціни немає', val(p6, 'RP', p_org => 'B'), null);
  eq('Орг. А: Плити немає', val(p6, 'CNT'), null);
  eq('Склад 2 орг. А: залежалих немає', cnt(l_org, w2), 0);
  eq('Склад 2 орг. А, усі: Чайник', cnt(l_org, w2, p_scope => 'N'), 1);
  eq('Група Техніка (з підгрупою Обігрівачі)', cnt(l_org, p_grp => g1), 2);
  eq('Група Обігрівачі', cnt(l_org, p_grp => g2), 1);
  eq('Група Продукти', cnt(l_org, p_grp => g3), 2);

  -- ---------------------------------------------------------------- помилки
  fails('Невідома ознака', 'Невідома ознака залежалості', 'XXX', null);
  fails('Днів ≤ 0', 'більшою за нуль', 'SALE', 0);

  -- ---------------------------------------------------------------- HTML
  l_c := trade_slow_stock.slow_html(d0, null, 'SALE', l_org, null, null, l_pt);
  has('HTML: заголовок', l_c, 'Неліквіди й залежалі товари на ' || to_char(d0, 'DD.MM.YYYY'));
  has('HTML: заморожений капітал', l_c, 'Заморожений капітал');
  -- заморожений капітал = Обігрівач 3600 + Вентилятор 1250
  has('HTML: сума заморожених 4 850,00', l_c, '<b>' || to_char(4850, 'FM999G999G999G990D00') || '</b>');
  has('HTML: Обігрівач', l_c, 'T27 А Обігрівач ' || t);
  has('HTML: розпродати', l_c, '<td>Розпродати</td>', 2);
  has('HTML: нижче собівартості', l_c, 'нижче собівартості', 1);
  has('HTML: прострочено', l_c, 'прострочено ' || to_char(3, 'FM999G999G999G990D000'));
  has('HTML: вік партій', l_c, 'Вартість за віком партій');
  has('HTML: не продавався (3 товари + примітка)', l_c, 'не продавався', 4);
  l_c := trade_slow_stock.slow_html(d0, null, 'XXX', l_org);
  has('HTML: помилка ознаки — повідомлення', l_c, 'Невідома ознака залежалості');
  l_c := trade_slow_stock.slow_html(d0, null, 'SALE', l_org, w2, null, l_pt);
  has('HTML: порожньо', l_c, 'Залежалих товарів немає.');

  -- ---------------------------------------------------------------- документ уцінки
  l_doc := trade_slow_stock.create_price_setting(d0, null, 'SALE', l_org, null, null, l_pt);
  select count(*) into l_n from doc_price_setting where id = l_doc and status = 'DRAFT' and price_type_id = l_pt;
  eq('Уцінка: документ-чернетка', l_n, 1);
  select count(*) into l_n from doc_price_setting_prices where document_id = l_doc;
  eq('Уцінка: 3 рядки (Обігрівач, Вентилятор, Сир)', l_n, 3);
  select max(price) into l_n from doc_price_setting_prices where document_id = l_doc and product_id = p1;
  eq('Уцінка: Обігрівач 700', l_n, 700);
  select max(price) into l_n from doc_price_setting_prices where document_id = l_doc and product_id = p5;
  eq('Уцінка: Сир 90', l_n, 90);
  select count(*) into l_n from sys_audit_log where object_id = l_doc and action = 'CREATE_BASED_ON';
  eq('Уцінка: запис аудиту', l_n, 1);
  trade_ops.post_price_setting(l_doc);
  eq('Після проведення: ціна Обігрівача 700', trade_lines.get_price(l_pt, p1, sysdate), 700);
  begin
    l_doc := trade_slow_stock.create_price_setting(d0, null, 'SALE', l_org, w2, null, l_pt);
    eq('Уцінка без товарів — помилка', 0, 1);
  exception when others then
    eq('Уцінка без товарів — помилка', case when instr(sqlerrm, 'Немає товарів для уцінки') > 0 then 1 else 0 end, 1);
  end;

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'SlowMovingStock' and list_page_id = 690 and kind = 'REPORT';
  eq('Об''єкт метаданих «Неліквіди й залежалі товари»', l_n, 1);
  select count(*) into l_n from sys_metadata_object where tech_name = 'RegMarkdownRule' and list_page_id = 695 and auth_scheme = 'Роль: адміністратор';
  eq('Об''єкт метаданих «Правила уцінки неліквідів»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'SlowMovingStock';
  eq('Панель функцій: 4 розділи', l_n, 4);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
