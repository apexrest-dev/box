-- F-REP-09 «ABC-аналіз продажів»: RegSales + RegStockCost, розрізи товари / клієнти, показники
-- виручка / кількість / валовий прибуток, межі класів, накопичена частка, правило межі, відбір за
-- організацією, групою номенклатури (з підгрупами), періодом; повернення, збиткові позиції, HTML, меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); l_wh varchar2(32); l_uom varchar2(32); l_sup varchar2(32);
  c1 varchar2(32); c2 varchar2(32); c3 varchar2(32);
  g1 varchar2(32); g2 varchar2(32); g3 varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32); p4 varchar2(32); s1 varchar2(32); p5 varchar2(32);
  rc varchar2(32); s_a varchar2(32); s_b varchar2(32); s_c varchar2(32); s_o varchar2(32); s_l varchar2(32); ret varchar2(32);
  l_n number; l_v number; l_s varchar2(4000); l_c clob;
  d0 date := trunc(sysdate);
  df date := trunc(sysdate) - 7;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
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
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL ' || p_name || ': помилки не було');
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || sqlerrm);
  end;
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  -- класи позицій у порядку рангу, напр. «AAABC»
  function classes (p_dim varchar2, p_ms varchar2, p_org varchar2, p_grp varchar2 default null, p_a number default 80, p_b number default 15) return varchar2 is
    l varchar2(100);
  begin
    for r in (select abc_class from table(trade_abc.analysis(p_dim, p_ms, df, d0, p_org, p_grp, p_a, p_b)) order by rn) loop
      l := l || r.abc_class;
    end loop;
    return l;
  end;
  function cls (p_dim varchar2, p_ms varchar2, p_obj varchar2, p_org varchar2 default null) return varchar2 is
    l varchar2(1);
  begin
    select max(abc_class) into l from table(trade_abc.analysis(p_dim, p_ms, df, d0, coalesce(p_org, l_org))) where object_id = p_obj;
    return l;
  end;
  function val (p_dim varchar2, p_ms varchar2, p_obj varchar2, p_org varchar2, p_col varchar2 default 'VALUE') return number is
    l number;
  begin
    select max(case p_col when 'SHARE' then round(share_pct, 2) when 'CUM' then round(cum_share_pct, 2)
                          when 'RN' then rn when 'COST' then cost when 'QTY' then quantity when 'REV' then revenue else value end)
      into l from table(trade_abc.analysis(p_dim, p_ms, df, d0, p_org)) where object_id = p_obj;
    return l;
  end;
  function sale (p_org varchar2, p_cus varchar2, p_days number) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (p_org, p_cus, l_wh, d0 - p_days + 0.5)
      returning id into l;
    return l;
  end;
  procedure line (p_doc varchar2, p_prd varchar2, p_qty number, p_price number) is
  begin
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (p_doc, p_prd, p_qty, p_price);
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T16 ТОВ А ' || t, 'LEGAL', '16161616') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T16 ТОВ Б ' || t, 'LEGAL', '16161617') returning id into l_org2;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T16 склад ' || t) returning id into l_wh;
  insert into ref_counterparty (name) values ('T16 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T16 А покупець ' || t) returning id into c1;
  insert into ref_counterparty (name) values ('T16 Б покупець ' || t) returning id into c2;
  insert into ref_counterparty (name) values ('T16 В покупець ' || t) returning id into c3;
  insert into ref_product_group (name) values ('T16 Інструмент ' || t) returning id into g1;
  insert into ref_product_group (name, parent_id) values ('T16 Електро', g1) returning id into g2;
  insert into ref_product_group (name) values ('T16 Фарби ' || t) returning id into g3;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T16 А Пила ' || t, l_uom, g1) returning id into p1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T16 Б Дриль ' || t, l_uom, g2) returning id into p2;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T16 В Гвинт ' || t, l_uom, g2) returning id into p3;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T16 Г Фарба ' || t, l_uom, g3) returning id into p4;
  insert into ref_product (name, unit_of_measure_id, group_id, product_kind) values ('T16 Д Доставка ' || t, l_uom, g1, 'SERVICE') returning id into s1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T16 Е Брак ' || t, l_uom, g3) returning id into p5;

  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, d0 - 5 + 0.5)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 1, p1, 10, 50, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 2, p2, 10, 20, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 3, p3, 10, 10, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 4, p4, 10, 5, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 5, p5, 2, 30, 0);
  trade_doc.post_goods_receipt(rc);

  -- орг. А: C1 — Пила 6×100 (собів. 300), Дриль 5×40 (100); C2 — Гвинт 4×25 (40), Фарба 2×50 (10); C3 — Доставка 1×40
  s_a := sale(l_org, c1, 2); line(s_a, p1, 6, 100); line(s_a, p2, 5, 40); trade_ops.post_goods_sale(s_a);
  s_b := sale(l_org, c2, 2); line(s_b, p3, 4, 25); line(s_b, p4, 2, 50); trade_ops.post_goods_sale(s_b);
  s_c := sale(l_org, c3, 2); line(s_c, s1, 1, 40); trade_ops.post_goods_sale(s_c);
  -- орг. Б: C1 — Пила 1×1000 (не входить у відбір орг. А)
  s_o := sale(l_org2, c1, 1); line(s_o, p1, 1, 1000); trade_ops.post_goods_sale(s_o);
  -- повернення 1 Дриля від C1 (−40 виручки, −20 собівартості)
  ret := trade_r3.customer_return_from_sale(s_a);
  delete from doc_customer_return_goods where document_id = ret and product_id = p1;
  update doc_customer_return_goods set quantity = 1 where document_id = ret and product_id = p2;
  update doc_customer_return set occurred_at = d0 - 2 + 0.75 where id = ret;
  trade_r3.post_customer_return(ret);

  -- ---------------------------------------------------------------- представлення рядків
  select count(*), sum(revenue) into l_n, l_v
    from v_abc_sales_line where organization_id = l_org and period >= df;
  eq('Рядків продажів орг. А (5 продажу + 1 повернення)', l_n, 6);
  eq('Виручка орг. А (1040 − 40)', l_v, 1000);
  select sum(cost), sum(gross_profit) into l_v, l_n from v_abc_sales_line where organization_id = l_org and period >= df;
  eq('Собівартість орг. А (300+100+40+10−20)', l_v, 430);
  eq('Валовий прибуток орг. А', l_n, 570);
  select organization_id into l_s from v_abc_sales_line where recorder_id = ret;
  eqs('Повернення — організація підстави', l_s, l_org);

  -- ---------------------------------------------------------------- товари за виручкою
  eqs('Виручка: класи товарів (A 80 / B 15)', classes('PRODUCT', 'REVENUE', l_org), 'AAABC');
  eq('Пила: виручка', val('PRODUCT', 'REVENUE', p1, l_org), 600);
  eq('Пила: частка 60 %', val('PRODUCT', 'REVENUE', p1, l_org, 'SHARE'), 60);
  eq('Дриль: виручка з урахуванням повернення', val('PRODUCT', 'REVENUE', p2, l_org), 160);
  eq('Дриль: накопичено 76 %', val('PRODUCT', 'REVENUE', p2, l_org, 'CUM'), 76);
  eq('Гвинт (перетинає межу 80 %): накопичено 86 %', val('PRODUCT', 'REVENUE', p3, l_org, 'CUM'), 86);
  eqs('Гвинт — клас A (накопичено перед ним 76 % < 80 %)', cls('PRODUCT', 'REVENUE', p3), 'A');
  eq('Гвинт і Фарба рівні — порядок за назвою: Фарба 4-та', val('PRODUCT', 'REVENUE', p4, l_org, 'RN'), 4);
  eqs('Фарба — клас B (86 %)', cls('PRODUCT', 'REVENUE', p4), 'B');
  eqs('Доставка (послуга) — клас C (96 % ≥ 95 %)', cls('PRODUCT', 'REVENUE', s1), 'C');
  eq('Доставка: собівартість послуги 0', val('PRODUCT', 'REVENUE', s1, l_org, 'COST'), 0);
  eq('Останній: накопичено 100 %', val('PRODUCT', 'REVENUE', s1, l_org, 'CUM'), 100);

  -- ---------------------------------------------------------------- інші показники
  eqs('Прибуток: класи (300, 90, 80, 60, 40)', classes('PRODUCT', 'PROFIT', l_org), 'AAABB');
  eq('Прибуток: Фарба 2-га', val('PRODUCT', 'PROFIT', p4, l_org, 'RN'), 2);
  eq('Прибуток: Дриль 100 − 20', val('PRODUCT', 'PROFIT', p2, l_org), 80);
  eq('Прибуток: Пила частка 52,63 %', val('PRODUCT', 'PROFIT', p1, l_org, 'SHARE'), 52.63);
  eqs('Кількість: класи (6, 4, 4, 2, 1)', classes('PRODUCT', 'QTY', l_org), 'AAABB');
  eq('Кількість: Дриль 5 − 1', val('PRODUCT', 'QTY', p2, l_org), 4);
  eqs('Межі A 50 / B 30', classes('PRODUCT', 'REVENUE', l_org, null, 50, 30), 'ABBCC');
  eqs('Межі A 100 / B 0 — усе A', classes('PRODUCT', 'REVENUE', l_org, null, 100, 0), 'AAAAA');

  -- ---------------------------------------------------------------- відбори
  eq('Без відбору організації: виручка Пили 600 + 1000', val('PRODUCT', 'REVENUE', p1, null), 1600);
  eq('Без відбору організації: кількість Пили', val('PRODUCT', 'REVENUE', p1, null, 'QTY'), 7);
  eqs('Відбір орг. Б: одна позиція A', classes('PRODUCT', 'REVENUE', l_org2), 'A');
  select count(*), sum(value) into l_n, l_v from table(trade_abc.analysis('PRODUCT', 'REVENUE', df, d0, l_org, g1));
  eq('Група «Інструмент» з підгрупою: позицій', l_n, 4);
  eq('Група «Інструмент»: виручка', l_v, 900);
  select count(*), round(max(share_pct), 2) into l_n, l_v from table(trade_abc.analysis('PRODUCT', 'REVENUE', df, d0, l_org, g2));
  eq('Підгрупа «Електро»: позицій', l_n, 2);
  eq('Підгрупа «Електро»: частка Дриля 160 / 260', l_v, 61.54);
  select count(*) into l_n from table(trade_abc.analysis('PRODUCT', 'REVENUE', d0 - 1, d0, l_org));
  eq('Період без продажів орг. А', l_n, 0);
  select count(*) into l_n from table(trade_abc.analysis('PRODUCT', 'REVENUE', d0 - 1, d0, null)) where object_id = p1;
  eq('Період: лише продаж орг. Б (вчора)', l_n, 1);

  -- ---------------------------------------------------------------- клієнти
  eqs('Клієнти за виручкою (760, 200, 40)', classes('CUSTOMER', 'REVENUE', l_org), 'AAC');
  eq('Клієнт C1: виручка', val('CUSTOMER', 'REVENUE', c1, l_org), 760);
  eq('Клієнт C1: прибуток 300 + 80', val('CUSTOMER', 'PROFIT', c1, l_org), 380);
  eqs('Клієнт C3 — клас C', cls('CUSTOMER', 'REVENUE', c3), 'C');
  select count(*) into l_n from table(trade_abc.analysis('CUSTOMER', 'REVENUE', df, d0, l_org, g3));
  eq('Клієнти з відбором групи «Фарби»: лише C2', l_n, 1);

  -- ---------------------------------------------------------------- збиткова позиція
  s_l := sale(l_org, c3, 1); line(s_l, p5, 1, 1); trade_ops.post_goods_sale(s_l);
  eq('Брак: прибуток 1 − 30', val('PRODUCT', 'PROFIT', p5, l_org), -29);
  eqs('Брак — клас C', cls('PRODUCT', 'PROFIT', p5), 'C');
  eq('Брак: частка 0', val('PRODUCT', 'PROFIT', p5, l_org, 'SHARE'), 0);
  eq('Брак — останній', val('PRODUCT', 'PROFIT', p5, l_org, 'RN'), 6);
  eq('Збиткова позиція не змінює базу частки (Пила 52,63 %)', val('PRODUCT', 'PROFIT', p1, l_org, 'SHARE'), 52.63);
  eqs('Прибуток з Браком: класи', classes('PRODUCT', 'PROFIT', l_org), 'AAABBC');
  trade_ops.unpost_goods_sale(s_l);

  -- ---------------------------------------------------------------- скасування повернення
  trade_r3.unpost_customer_return(ret);
  eq('Після скасування повернення: виручка Дриля', val('PRODUCT', 'REVENUE', p2, l_org), 200);
  trade_r3.post_customer_return(ret);

  -- ---------------------------------------------------------------- допоміжні функції, помилки
  eqs('class_of: перед 79,99 → A', trade_abc.class_of(79.99, 1, 80, 15), 'A');
  eqs('class_of: перед 80 → B', trade_abc.class_of(80, 1, 80, 15), 'B');
  eqs('class_of: перед 95 → C', trade_abc.class_of(95, 1, 80, 15), 'C');
  eqs('class_of: значення 0 → C', trade_abc.class_of(0, 0, 80, 15), 'C');
  eq('to_num «12,5»', trade_abc.to_num('12,5', 0), 12.5);
  eq('to_num «12.5»', trade_abc.to_num('12.5', 0), 12.5);
  eq('to_num порожньо → типове', trade_abc.to_num(null, 15), 15);
  eq('to_num «abc» → типове', trade_abc.to_num('abc', 80), 80);
  fails('Межі A + B > 100', 'ORA-20100', 'select count(*) from table(trade_abc.analysis(''PRODUCT'', ''REVENUE'', sysdate, sysdate, null, null, 90, 20))');
  fails('Межа A = 0', 'ORA-20100', 'select count(*) from table(trade_abc.analysis(''PRODUCT'', ''REVENUE'', sysdate, sysdate, null, null, 0, 15))');
  fails('Невідомий показник', 'ORA-20100', 'select count(*) from table(trade_abc.analysis(''PRODUCT'', ''MARGIN'', sysdate, sysdate))');
  fails('Невідомий розріз', 'ORA-20100', 'select count(*) from table(trade_abc.analysis(''WAREHOUSE'', ''REVENUE'', sysdate, sysdate))');

  -- ---------------------------------------------------------------- HTML
  l_c := trade_abc.abc_html('PRODUCT', 'REVENUE', df, d0, l_org, null, 80, 15);
  has('HTML: заголовок товарів', l_c, 'ABC-аналіз продажів: товари');
  has('HTML: діаграма Парето', l_c, '<svg ');
  has('HTML: 5 стовпців діаграми', l_c, '<rect x=', 6);  -- рамка + 5 стовпців
  has('HTML: лінія накопиченої частки', l_c, '<polyline ');
  has('HTML: зведення — клас A 3 позиції', l_c, '<span class="abc abc-A">A</span></td><td class="r">3</td>');
  has('HTML: позицій з класом A (зведення + 3)', l_c, '<span class="abc abc-A">A</span>', 4);
  has('HTML: разом кількість 17, виручка 1000, собів. 430', l_c,
      'Разом</td><td class="r">' || q(17) || '</td><td class="r">' || m(1000) || '</td><td class="r">' || m(430) || '</td><td class="r">' || m(570) || '</td>');
  has('HTML: організація у шапці', l_c, 'T16 ТОВ А ' || t);
  has('HTML: колонка «Група»', l_c, '<th>Група</th>');
  has('HTML: шлях групи підгрупи', l_c, 'T16 Інструмент ' || t || ' &#x2F; T16 Електро', 2);
  has('HTML: без APEX-сесії — без посилань', l_c, '<a href=', 0);
  l_c := trade_abc.abc_html('CUSTOMER', 'QTY', df, d0, l_org, g1, 80, 15);
  has('HTML клієнтів: заголовок', l_c, 'ABC-аналіз продажів: клієнти');
  has('HTML клієнтів: без колонки «Група»', l_c, '<th>Група</th>', 0);
  has('HTML клієнтів: відбір групи з підгрупами', l_c, '(з підгрупами)');
  l_c := trade_abc.abc_html('PRODUCT', 'REVENUE', d0 - 1, d0, l_org);
  has('HTML: порожній період', l_c, 'Продажів за період немає.');
  l_c := trade_abc.abc_html('PRODUCT', 'REVENUE', df, d0, l_org, null, 90, 20);
  has('HTML: некоректні межі — повідомлення', l_c, 'Межі класів ABC некоректні');

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'AbcAnalysis' and list_page_id = 460 and kind = 'REPORT';
  eq('Об''єкт метаданих «ABC-аналіз продажів»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'AbcAnalysis';
  eq('Панель функцій: 3 розділи', l_n, 3);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
