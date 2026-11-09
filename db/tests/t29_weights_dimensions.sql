-- F-WH-26 «Ваги й габарити товарів»: об'єм і габарити номенклатури (автооб'єм, очищення для послуг, обмеження),
-- вага / об'єм одиниці з одиниці виміру (кг, л), підсумки документів (реалізація, замовлення клієнта, переміщення,
-- рахунок), рядки без даних, summary_html, звіт cargo_html (відбори, напрям, лише проведені, % завантаження,
-- перевантаження, помилки), меню. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); w1 varchar2(32); w2 varchar2(32); c1 varchar2(32);
  u_pc varchar2(32); u_kg varchar2(32); u_l varchar2(32);
  p_box varchar2(32); p_sugar varchar2(32); p_oil varchar2(32); p_nodata varchar2(32); s1 varchar2(32);
  sa varchar2(32); sa2 varchar2(32); co varchar2(32); tr varchar2(32); inv varchar2(32);
  l_n number; l_c clob; l_v varchar2(4000);
  d0 date := trunc(sysdate) + 400;   -- окремий день, щоб не перетинатися з демо-документами

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
  procedure fails (p_name varchar2, p_sql varchar2, p_code varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL ' || p_name || ': помилки не було');
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || sqlerrm);
  end;
  function kg (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function sale (p_wh varchar2, p_at date) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, c1, p_wh, p_at)
      returning id into l;
    return l;
  end;
  procedure line (p_tab varchar2, p_doc varchar2, p_prd varchar2, p_qty number) is
  begin
    if p_tab = 'T' then
      insert into doc_goods_transfer_goods (document_id, product_id, quantity) values (p_doc, p_prd, p_qty);
    else
      execute immediate 'insert into ' || p_tab || ' (document_id, product_id, quantity, price) values (:1, :2, :3, 10)'
        using p_doc, p_prd, p_qty;
    end if;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T29 ТОВ ' || t, 'LEGAL', '29292929') returning id into l_org;
  select id into u_pc from ref_unit_of_measure where short_name = 'шт';
  select id into u_kg from ref_unit_of_measure where short_name = 'кг';
  select id into u_l from ref_unit_of_measure where short_name = 'л';
  insert into ref_warehouse (name) values ('T29 склад 1 ' || t) returning id into w1;
  insert into ref_warehouse (name) values ('T29 склад 2 ' || t) returning id into w2;
  insert into ref_counterparty (name) values ('T29 покупець ' || t) returning id into c1;

  -- ---------------------------------------------------------------- номенклатура
  insert into ref_product (name, unit_of_measure_id, weight_kg, length_cm, width_cm, height_cm)
    values ('T29 Коробка ' || t, u_pc, 2.5, 50, 40, 30) returning id into p_box;
  select volume_m3 into l_n from ref_product where id = p_box;
  eq('Об''єм з габаритів 50×40×30 см = 0,06 м³', l_n, 0.06);
  update ref_product set volume_m3 = 1 where id = p_box;
  select volume_m3 into l_n from ref_product where id = p_box;
  eq('Задані всі габарити — об''єм перераховується', l_n, 0.06);
  update ref_product set height_cm = 60 where id = p_box;
  select volume_m3 into l_n from ref_product where id = p_box;
  eq('Зміна висоти → 0,12 м³', l_n, 0.12);
  update ref_product set height_cm = null, volume_m3 = 0.1 where id = p_box;
  select volume_m3 into l_n from ref_product where id = p_box;
  eq('Неповні габарити — об''єм вручну', l_n, 0.1);
  update ref_product set height_cm = 30 where id = p_box;   -- знову 0,06
  eq('volume_of(10, 10, 10) = 0,001', trade_cargo.volume_of(10, 10, 10), 0.001);
  eq('volume_of без висоти = null', trade_cargo.volume_of(10, 10, null), null);

  insert into ref_product (name, unit_of_measure_id, volume_m3) values ('T29 Цукор ' || t, u_kg, 0.00125) returning id into p_sugar;
  insert into ref_product (name, unit_of_measure_id, weight_kg) values ('T29 Олія ' || t, u_l, 0.92) returning id into p_oil;
  insert into ref_product (name, unit_of_measure_id) values ('T29 Без даних ' || t, u_pc) returning id into p_nodata;
  insert into ref_product (name, unit_of_measure_id, product_kind, weight_kg, volume_m3, length_cm)
    values ('T29 Доставка ' || t, u_pc, 'SERVICE', 5, 1, 10) returning id into s1;
  select count(*) into l_n from ref_product where id = s1 and weight_kg is null and volume_m3 is null and length_cm is null;
  eq('Послуга: вага, об''єм і габарити очищено', l_n, 1);
  eq('Вага одиниці «кг» без значення = 1', trade_cargo.unit_weight(p_sugar), 1);
  eq('Об''єм одиниці «кг» — з картки', trade_cargo.unit_volume(p_sugar), 0.00125);
  eq('Об''єм одиниці «л» без значення = 0,001', trade_cargo.unit_volume(p_oil), 0.001);
  eq('Вага одиниці «л» — з картки', trade_cargo.unit_weight(p_oil), 0.92);
  eq('Вага «шт» без значення = null', trade_cargo.unit_weight(p_nodata), null);
  eq('Вага коробки = 2,5', trade_cargo.unit_weight(p_box), 2.5);
  eq('Послуга: вага одиниці null', trade_cargo.unit_weight(s1), null);
  fails('Від''ємна вага', 'update ref_product set weight_kg = -1 where id = ''' || p_box || '''', 'ORA-02290');
  fails('Від''ємний об''єм', 'update ref_product set length_cm = null, volume_m3 = -1 where id = ''' || p_box || '''', 'ORA-02290');
  fails('Від''ємна довжина', 'update ref_product set length_cm = -5 where id = ''' || p_box || '''', 'ORA-02290');

  -- ---------------------------------------------------------------- документи
  -- реалізація 1: коробка 4 (10 кг, 0,24 м³) + цукор 20 кг (20 кг, 0,025) + олія 10 л (9,2 кг, 0,01) + послуга
  sa := sale(w1, d0 + 0.4);
  line('doc_goods_sale_goods', sa, p_box, 4);
  line('doc_goods_sale_goods', sa, p_sugar, 20);
  line('doc_goods_sale_goods', sa, p_oil, 10);
  line('doc_goods_sale_goods', sa, s1, 1);
  eq('Реалізація: вага 39,2 кг', trade_cargo.doc_weight('DocGoodsSale', sa), 39.2);
  eq('Реалізація: об''єм 0,275 м³', trade_cargo.doc_volume('DocGoodsSale', sa), 0.275);
  eq('Реалізація: без ваги 0', trade_cargo.doc_missing('DocGoodsSale', sa), 0);
  select goods_lines into l_n from v_cargo_doc where doc_type = 'DocGoodsSale' and doc_id = sa;
  eq('Реалізація: рядків товарів 3 (послуга не рахується)', l_n, 3);
  l_c := trade_cargo.summary_html('DocGoodsSale', sa);
  has('summary: вага', l_c, 'вага <b>' || kg(39.2) || ' кг</b>');
  has('summary: рядків товарів', l_c, 'рядків товарів: 3');
  has('summary: без попередження', l_c, 'Не задано в номенклатурі', 0);
  eq('summary без документа = null', dbms_lob.getlength(trade_cargo.summary_html('DocGoodsSale', null)), null);

  -- реалізація 2: товар без даних 3 + коробка 1 (склад 2)
  sa2 := sale(w2, d0 + 0.6);
  line('doc_goods_sale_goods', sa2, p_nodata, 3);
  line('doc_goods_sale_goods', sa2, p_box, 1);
  eq('Реалізація 2: вага лише коробки 2,5', trade_cargo.doc_weight('DocGoodsSale', sa2), 2.5);
  eq('Реалізація 2: без ваги 1', trade_cargo.doc_missing('DocGoodsSale', sa2, 'WEIGHT'), 1);
  eq('Реалізація 2: без об''єму 1', trade_cargo.doc_missing('DocGoodsSale', sa2, 'VOLUME'), 1);
  l_c := trade_cargo.summary_html('DocGoodsSale', sa2);
  has('summary: попередження', l_c, 'Не задано в номенклатурі: T29 Без даних ' || t || ' (вага, об&#x27;єм)');

  -- замовлення клієнта: дата відвантаження d0 + 1 — коробка 10 (25 кг, 0,6)
  insert into doc_customer_order (organization_id, customer_id, warehouse_id, occurred_at, shipment_date)
    values (l_org, c1, w1, d0 - 3 + 0.5, d0 + 1) returning id into co;
  line('doc_customer_order_goods', co, p_box, 10);
  eq('Замовлення: вага 25', trade_cargo.doc_weight('DocCustomerOrder', co), 25);
  select count(*) into l_n from v_cargo_doc where doc_id = co and ship_date = d0 + 1 and direction = 'OUT';
  eq('Замовлення: дата відвантаження = shipment_date', l_n, 1);
  -- переміщення склад 1 → 2: цукор 50
  insert into doc_goods_transfer (organization_id, warehouse_from_id, warehouse_to_id, occurred_at)
    values (l_org, w1, w2, d0 + 0.5) returning id into tr;
  line('T', tr, p_sugar, 50);
  eq('Переміщення: вага 50', trade_cargo.doc_weight('DocGoodsTransfer', tr), 50);
  select max(direction) into l_v from v_cargo_doc where doc_id = tr;
  dbms_output.put_line(case when l_v = 'MOVE' then 'OK  ' else 'FAIL' end || ' Переміщення: напрям MOVE: ' || l_v);
  -- рахунок: олія 100
  insert into doc_invoice_for_payment (organization_id, customer_id, occurred_at) values (l_org, c1, d0 + 0.5) returning id into inv;
  line('doc_invoice_for_payment_goods', inv, p_oil, 100);
  eq('Рахунок: вага 92', trade_cargo.doc_weight('DocInvoiceForPayment', inv), 92);

  -- ---------------------------------------------------------------- звіт
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_org => l_org);
  has('Звіт: заголовок', l_c, '<h2>Вага й об''єм документів</h2>');
  has('Звіт: 4 документи (рахунок не входить)', l_c, 'Разом: документів 4');
  has('Звіт: рахунок відсутній', l_c, 'Рахунок на оплату', 0);
  -- разом: 39,2 + 2,5 + 25 + 50 = 116,7 кг
  has('Звіт: разом вага', l_c, '<td class="r">' || kg(116.7) || '</td>');
  has('Звіт: позначка без даних (рядок і разом)', l_c, 'вага: 1; об''єм: 1', 2);
  has('Звіт: попередження про неповний підсумок', l_c, 'підсумок неповний');
  has('Звіт: переміщення склад → склад', l_c, 'T29 склад 1 ' || t || ' → T29 склад 2 ' || t);
  has('Звіт: без колонки %', l_c, '% ваги', 0);
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_doc_type => 'DocInvoiceForPayment', p_org => l_org);
  has('Звіт: рахунок явним відбором', l_c, 'Разом: документів 1');
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_direction => 'OUT', p_org => l_org);
  has('Звіт: напрям OUT — 3', l_c, 'Разом: документів 3');
  l_c := trade_cargo.cargo_html(d0, d0, p_direction => 'MOVE', p_org => l_org);
  has('Звіт: напрям MOVE — 1', l_c, 'Разом: документів 1');
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_org => l_org, p_wh => w2);
  has('Звіт: склад 2 — реалізація 2 + переміщення', l_c, 'Разом: документів 2');
  l_c := trade_cargo.cargo_html(d0, d0, p_doc_type => 'DocGoodsSale', p_org => l_org);
  has('Звіт: вид — реалізації за d0', l_c, 'Разом: документів 2');
  has('Звіт: вид у параметрах', l_c, 'Документи: <b>Реалізація товарів</b>');
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_org => l_org, p_posted_only => 'Y');
  has('Звіт: лише проведені — порожньо', l_c, 'Документів з товарами за період немає.');
  -- завантаження: 100 кг / 1 м³ → разом 116,7 % і 0,275+0,06+0,6+0,0625 = 0,9975 м³
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_org => l_org, p_cap_kg => 100, p_cap_m3 => 1);
  has('Звіт: колонка % ваги', l_c, '<th>% ваги</th>');
  has('Звіт: перевантаження за вагою', l_c, '<td class="r over">' || to_char(116.7, 'FM999G990D0') || '</td>');
  has('Звіт: % об''єму разом', l_c, '<td class="r">' || to_char(99.8, 'FM999G990D0') || '</td>');
  has('Звіт: 2 рейси', l_c, 'потрібно 2 рейс(и)');
  l_c := trade_cargo.cargo_html(d0, d0 + 1, p_org => l_org, p_cap_kg => 1000);
  has('Звіт: без перевантаження', l_c, 'Перевантаження', 0);
  eq('load_percent(50, 200) = 25', trade_cargo.load_percent(50, 200), 25);
  eq('load_percent без місткості = null', trade_cargo.load_percent(50, null), null);
  eq('to_num(''1 250,5'')', trade_cargo.to_num('1 250,5'), 1250.5);
  eq('to_num(''abc'') = null', trade_cargo.to_num('abc'), null);
  l_c := trade_cargo.cargo_html(d0, d0 - 1);
  has('Звіт: помилка періоду', l_c, 'Період звіту некоректний');
  l_c := trade_cargo.cargo_html(d0, d0, p_direction => 'XX');
  has('Звіт: невідомий напрям', l_c, 'Невідомий напрям');
  l_c := trade_cargo.cargo_html(d0, d0, p_cap_kg => -1);
  has('Звіт: від''ємна місткість', l_c, 'не можуть бути від''ємними');

  -- ---------------------------------------------------------------- демо й меню
  select count(*) into l_n from ref_product where article = 'KT-100' and weight_kg = 1.2 and volume_m3 = 0.0099;
  eq('Демо: чайник 22×18×25 см = 0,0099 м³', l_n, 1);
  select count(*) into l_n from sys_metadata_object where tech_name = 'CargoWeightVolume' and list_page_id = 720 and kind = 'REPORT';
  eq('Об''єкт метаданих «Вага й об''єм документів»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'CargoWeightVolume';
  eq('Панель функцій: 3 розділи', l_n, 3);
  select count(*) into l_n from apex_application_page_regions
   where application_id = 100 and page_id in (51, 111, 131, 261, 271, 281, 291, 321, 571) and region_name = 'Вага й об''єм';
  eq('Регіон «Вага й об''єм» у 9 формах документів', l_n, 9);
  select count(*) into l_n from apex_application_pages where application_id = 100 and page_id = 720;
  eq('Сторінка 720', l_n, 1);
  select count(*) into l_n from apex_application_page_items where application_id = 100 and page_id = 21
     and item_name in ('P21_VOLUME_M3', 'P21_LENGTH_CM', 'P21_WIDTH_CM', 'P21_HEIGHT_CM');
  eq('Картка товару: 4 нові поля', l_n, 4);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
