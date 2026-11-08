-- F-WH-24 «Оборотність запасів»: RegStockCost + RegSales — залишок на початок / кінець, середній залишок
-- (середнє денних залишків), собівартість продажів (повернення — мінус), коефіцієнт і дні оборотності;
-- розрізи товари / групи / склади / товари × склади, відбір за організацією, складом, групою (з підгрупами),
-- послуги не входять, помилки параметрів, HTML, меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); w1 varchar2(32); w2 varchar2(32); l_uom varchar2(32); l_sup varchar2(32); c1 varchar2(32);
  g1 varchar2(32); g2 varchar2(32); g3 varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); s1 varchar2(32);
  rc varchar2(32); sa varchar2(32); ret varchar2(32);
  l_n number; l_c clob;
  d0 date := trunc(sysdate);
  df date := trunc(sysdate) - 9;   -- період 10 днів

  procedure eq (p_name varchar2, p_got number, p_exp number) is
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
  procedure fails (p_name varchar2, p_code varchar2, p_dim varchar2, p_from date, p_to date) is
  begin
    for r in (select * from table(trade_turnover.analysis(p_dim, p_from, p_to))) loop
      null;
    end loop;
    dbms_output.put_line('FAIL ' || p_name || ': помилки не було');
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || sqlerrm);
  end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function val (p_dim varchar2, p_obj varchar2, p_col varchar2, p_org varchar2 default 'A', p_wh varchar2 default null,
                p_grp varchar2 default null) return number is
    l number;
  begin
    select max(case p_col when 'OQ' then open_qty when 'OC' then open_cost when 'AQ' then avg_qty when 'AC' then avg_cost
                          when 'SQ' then sold_qty when 'SC' then sales_cost when 'CQ' then close_qty when 'CC' then close_cost
                          when 'R' then turnover_ratio when 'D' then turnover_days when 'QR' then qty_ratio when 'RN' then rn end)
      into l from table(trade_turnover.analysis(p_dim, df, d0, case p_org when 'A' then l_org when 'B' then l_org2 end, p_wh, p_grp))
     where object_id = p_obj;
    return l;
  end;
  function cnt (p_dim varchar2, p_org varchar2, p_wh varchar2 default null, p_grp varchar2 default null) return number is
    l number;
  begin
    select count(*) into l from table(trade_turnover.analysis(p_dim, df, d0, p_org, p_wh, p_grp));
    return l;
  end;
  procedure receipt (p_org varchar2, p_wh varchar2, p_at date, p_prd varchar2, p_qty number, p_price number) is
  begin
    insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (p_org, l_sup, p_wh, p_at)
      returning id into rc;
    insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 1, p_prd, p_qty, p_price, 0);
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
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T26 ТОВ А ' || t, 'LEGAL', '26262626') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T26 ТОВ Б ' || t, 'LEGAL', '26262627') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T26 склад 1 ' || t) returning id into w1;
  insert into ref_warehouse (name) values ('T26 склад 2 ' || t) returning id into w2;
  insert into ref_counterparty (name) values ('T26 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T26 покупець ' || t) returning id into c1;
  insert into ref_product_group (name) values ('T26 Інструмент ' || t) returning id into g1;
  insert into ref_product_group (name, parent_id) values ('T26 Електро', g1) returning id into g2;
  insert into ref_product_group (name) values ('T26 Фарби ' || t) returning id into g3;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T26 А Пила ' || t, l_uom, g1) returning id into p1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T26 Б Дриль ' || t, l_uom, g2) returning id into p2;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T26 В Фарба ' || t, l_uom, g3) returning id into p3;
  insert into ref_product (name, unit_of_measure_id, group_id, product_kind) values ('T26 Г Доставка ' || t, l_uom, g1, 'SERVICE') returning id into s1;

  -- до періоду: орг. А — Пила 10×10 (склад 1), Фарба 5×20 (склад 1); орг. Б — Пила 2×10 (склад 1)
  receipt(l_org, w1, d0 - 15 + 0.5, p1, 10, 10);
  receipt(l_org, w1, d0 - 15 + 0.6, p3, 5, 20);
  receipt(l_org2, w1, d0 - 14 + 0.5, p1, 2, 10);
  -- перший день періоду: Дриль 20×5 (склад 2)
  receipt(l_org, w2, df + 0.5, p2, 20, 5);
  -- день d0−4: продаж Пили 4 (собів. 40); d0−2: повернення 1 (собів. 10); d0: продаж Дриля 10 (собів. 50); послуга
  sa := sale(l_org, w1, d0 - 4 + 0.5, p1, 4, 25);
  ret := trade_r3.customer_return_from_sale(sa);
  update doc_customer_return_goods set quantity = 1 where document_id = ret and product_id = p1;
  update doc_customer_return set occurred_at = d0 - 2 + 0.5 where id = ret;
  trade_r3.post_customer_return(ret);
  sa := sale(l_org, w2, d0 + 0.5, p2, 10, 9);
  sa := sale(l_org, w1, d0 - 1 + 0.5, s1, 1, 100);
  -- після періоду (не входить): продаж Пили 1
  sa := sale(l_org, w1, d0 + 1 + 0.5, p1, 1, 25);

  -- ---------------------------------------------------------------- розріз «Товари», орг. А
  eq('Пила: залишок на початок, к-сть', val('PRODUCT', p1, 'OQ'), 10);
  eq('Пила: залишок на початок, вартість', val('PRODUCT', p1, 'OC'), 100);
  -- середній: 10 − 4×5/10 + 1×3/10 = 8,3; вартість 100 − 40×0,5 + 10×0,3 = 83
  eq('Пила: середній залишок, к-сть', val('PRODUCT', p1, 'AQ'), 8.3);
  eq('Пила: середній залишок, вартість', val('PRODUCT', p1, 'AC'), 83);
  eq('Пила: продано (з поверненням)', val('PRODUCT', p1, 'SQ'), 3);
  eq('Пила: собівартість продажів', val('PRODUCT', p1, 'SC'), 30);
  eq('Пила: залишок на кінець, к-сть', val('PRODUCT', p1, 'CQ'), 7);
  eq('Пила: залишок на кінець, вартість', val('PRODUCT', p1, 'CC'), 70);
  eq('Пила: коефіцієнт = 30 / 83', val('PRODUCT', p1, 'R'), round(30 / 83, 4));
  eq('Пила: оборотність = 83 × 10 / 30 днів', val('PRODUCT', p1, 'D'), round(83 * 10 / 30, 2));
  eq('Пила: коефіцієнт за кількістю = 3 / 8,3', val('PRODUCT', p1, 'QR'), round(3 / 8.3, 4));
  -- Дриль: прихід у перший день → 20 усі 10 днів, продаж в останній день −10×1/10
  eq('Дриль: початок 0', val('PRODUCT', p2, 'OQ'), 0);
  eq('Дриль: середній залишок 19', val('PRODUCT', p2, 'AQ'), 19);
  eq('Дриль: середня вартість 95', val('PRODUCT', p2, 'AC'), 95);
  eq('Дриль: собівартість продажів 50', val('PRODUCT', p2, 'SC'), 50);
  eq('Дриль: оборотність 19 днів', val('PRODUCT', p2, 'D'), 19);
  eq('Дриль: коефіцієнт 50 / 95', val('PRODUCT', p2, 'R'), round(50 / 95, 4));
  -- Фарба: без продажів
  eq('Фарба: середній залишок 100', val('PRODUCT', p3, 'AC'), 100);
  eq('Фарба: коефіцієнт 0', val('PRODUCT', p3, 'R'), 0);
  eq('Фарба: днів немає (немає продажів)', val('PRODUCT', p3, 'D'), null);
  eq('Фарба (без продажів) — перша', val('PRODUCT', p3, 'RN'), 1);
  eq('Пила (27,67 дн.) — друга', val('PRODUCT', p1, 'RN'), 2);
  eq('Дриль (19 дн.) — третя', val('PRODUCT', p2, 'RN'), 3);
  eq('Послуга не входить', val('PRODUCT', s1, 'SQ'), null);
  eq('Рядків орг. А', cnt('PRODUCT', l_org), 3);

  -- ---------------------------------------------------------------- відбір за організацією
  eq('Орг. Б: Пила початок 2', val('PRODUCT', p1, 'OQ', 'B'), 2);
  eq('Орг. Б: без продажів — днів немає', val('PRODUCT', p1, 'D', 'B'), null);
  eq('Орг. Б: рядків 1', cnt('PRODUCT', l_org2), 1);

  -- ---------------------------------------------------------------- розрізи
  eq('Склад 1: середня вартість 83 + 100', val('WAREHOUSE', w1, 'AC'), 183);
  eq('Склад 1: собівартість продажів 30', val('WAREHOUSE', w1, 'SC'), 30);
  eq('Склад 1: оборотність 183 × 10 / 30', val('WAREHOUSE', w1, 'D'), round(183 * 10 / 30, 2));
  eq('Склад 2: оборотність 19', val('WAREHOUSE', w2, 'D'), 19);
  eq('Товар × склад: Дриль на складі 2', val('PRODUCT_WAREHOUSE', p2 || ':' || w2, 'AQ'), 19);
  eq('Товар × склад: рядків 3', cnt('PRODUCT_WAREHOUSE', l_org), 3);
  eq('Група «Інструмент» (без підгруп у розрізі): Пила', val('GROUP', g1, 'AC'), 83);
  eq('Група «Електро»: Дриль', val('GROUP', g2, 'AC'), 95);
  eq('Група «Фарби»', val('GROUP', g3, 'AC'), 100);
  eq('Розріз груп: 3 рядки', cnt('GROUP', l_org), 3);

  -- ---------------------------------------------------------------- відбори склад / група
  eq('Відбір склад 2: 1 рядок', cnt('PRODUCT', l_org, w2), 1);
  eq('Відбір склад 2: Дриль', val('PRODUCT', p2, 'AQ', 'A', w2), 19);
  eq('Відбір групи з підгрупами: 2 товари', cnt('PRODUCT', l_org, null, g1), 2);
  eq('Відбір групи «Електро»: 1 товар', cnt('PRODUCT', l_org, null, g2), 1);

  -- ---------------------------------------------------------------- допоміжні й помилки
  eq('ratio_of: середній 0 → null', trade_turnover.ratio_of(10, 0), null);
  eq('days_of: продажів 0 → null', trade_turnover.days_of(0, 100, 30), null);
  eq('days_of: 100 × 30 / 50', trade_turnover.days_of(50, 100, 30), 60);
  fails('Невідомий розріз', 'Невідомий розріз звіту оборотності', 'X', d0 - 1, d0);
  fails('По раніше З', 'Період звіту оборотності некоректний', 'PRODUCT', d0, d0 - 1);

  -- ---------------------------------------------------------------- HTML
  l_c := trade_turnover.turnover_html('PRODUCT', df, d0, l_org);
  has('HTML: заголовок', l_c, 'Оборотність запасів: товари');
  has('HTML: період 10 дн.', l_c, '(10 дн.)');
  has('HTML: організація', l_c, 'T26 ТОВ А ' || t);
  has('HTML: «немає продажів» — Фарба', l_c, 'немає продажів', 1);
  has('HTML: Пила', l_c, 'T26 А Пила ' || t);
  has('HTML: дні Пили', l_c, to_char(round(83 * 10 / 30, 2), 'FM999G999G990D0'));
  has('HTML: середній залишок разом', l_c, m(278), 2);
  has('HTML: собівартість разом', l_c, m(80), 2);
  has('HTML: без APEX-сесії — без посилань', l_c, '<a href=', 0);
  has('HTML: оборотність довша за період — червоним', l_c, 'class="r slow"', 4);
  l_c := trade_turnover.turnover_html('PRODUCT_WAREHOUSE', df, d0, l_org, w1);
  has('HTML товар × склад: заголовок', l_c, 'Оборотність запасів: товари за складами');
  has('HTML товар × склад: колонка «Склад»', l_c, '<th rowspan="2">Склад</th>');
  has('HTML товар × склад: склад у параметрах', l_c, 'Склад: <b>T26 склад 1 ' || t);
  l_c := trade_turnover.turnover_html('GROUP', df, d0, l_org, null, g1);
  has('HTML груп: заголовок', l_c, 'Оборотність запасів: групи номенклатури');
  has('HTML груп: з підгрупами', l_c, '(з підгрупами)');
  has('HTML груп: без колонки «Од.»', l_c, '<th rowspan="2">Од.</th>', 0);
  l_c := trade_turnover.turnover_html('PRODUCT', d0 + 30, d0 + 31, l_org2, w2);
  has('HTML: порожньо', l_c, 'Запасів і продажів за період немає.');
  l_c := trade_turnover.turnover_html('PRODUCT', d0, d0 - 1, l_org);
  has('HTML: помилка періоду — повідомлення', l_c, 'Період звіту оборотності некоректний');

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'InventoryTurnover' and list_page_id = 680 and kind = 'REPORT';
  eq('Об''єкт метаданих «Оборотність запасів»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'InventoryTurnover';
  eq('Панель функцій: 4 розділи', l_n, 4);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
