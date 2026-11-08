-- F-PRC-06 «Знижки й акції»: довідник умов (період, покупець, договір, група з підгрупами, товар, кількість,
-- сума документа, застосування), «Розрахувати знижки» в замовленні й реалізації (найбільша з придатних),
-- ручна + автоматична знижка, сумісність r3 (discount_percent як ручна), обмеження ручної знижки за роллю,
-- ручна знижка на документ, перерахунок під час проведення, реалізація на підставі замовлення (ціна до знижки
-- й знижки переносяться), копіювання, повернення за ціною зі знижкою, звіт «Надані знижки», меню, журнал.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_wh varchar2(32); l_uom varchar2(32); l_sup varchar2(32); l_c1 varchar2(32); l_c2 varchar2(32);
  l_k1 varchar2(32); l_g0 varchar2(32); l_g1 varchar2(32); l_p1 varchar2(32); l_p2 varchar2(32);
  r_grp varchar2(32); r_cus varchar2(32); r_ctr varchar2(32); r_big varchar2(32); r_old varchar2(32);
  rc varchar2(32); o1 varchar2(32); o2 varchar2(32); s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); x varchar2(32);
  l_n number; l_s varchar2(4000); l_c clob; l_a number; l_b number;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    savepoint before_fail;
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
    rollback to before_fail;
  exception when others then
    trade_core.g_internal := false;
    trade_discount.g_skip_limit := false;
    rollback to before_fail;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  function oline (p_doc varchar2, p_prd varchar2, p_col varchar2) return number is
    l number;
  begin
    execute immediate 'select ' || p_col || ' from doc_customer_order_goods where document_id = :d and product_id = :p' into l using p_doc, p_prd;
    return l;
  end;
  function sline (p_doc varchar2, p_prd varchar2, p_col varchar2) return number is
    l number;
  begin
    execute immediate 'select ' || p_col || ' from doc_goods_sale_goods where document_id = :d and product_id = :p' into l using p_doc, p_prd;
    return l;
  end;
begin
  trade_discount.g_test_roles := null;
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T20 ТОВ ' || t, 'LEGAL', '20202020') returning id into l_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T20 склад ' || t) returning id into l_wh;
  insert into ref_product_group (name) values ('T20 Продукти ' || t) returning id into l_g0;
  insert into ref_product_group (name, parent_id) values ('T20 Крупи ' || t, l_g0) returning id into l_g1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T20 Гречка ' || t, l_uom, l_g1) returning id into l_p1;
  insert into ref_product (name, unit_of_measure_id) values ('T20 Сіль ' || t, l_uom) returning id into l_p2;
  insert into ref_counterparty (name) values ('T20 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T20 покупець 1 ' || t) returning id into l_c1;
  insert into ref_counterparty (name) values ('T20 покупець 2 ' || t) returning id into l_c2;
  insert into ref_contract (owner_id, name, contract_kind) values (l_c1, 'T20 договір ' || t, 'WITH_CUSTOMER') returning id into l_k1;
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, sysdate - 30)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (rc, l_p1, 100, 60);
  insert into doc_goods_receipt_goods (document_id, product_id, quantity, price) values (rc, l_p2, 1000, 20);
  trade_doc.post_goods_receipt(rc);

  -- ---------------------------------------------------------------- довідник умов
  insert into ref_discount (name, discount_percent, product_group_id, min_quantity) values ('T20 Група від 10', 5, l_g0, 10)
    returning id into r_grp;
  insert into ref_discount (name, discount_percent, customer_id) values ('T20 Клієнт', 3, l_c1) returning id into r_cus;
  insert into ref_discount (name, discount_percent, contract_id) values ('T20 Договір', 4, l_k1) returning id into r_ctr;
  insert into ref_discount (name, discount_percent, applies_to, min_doc_amount) values ('T20 Велика реалізація', 7, 'SALE', 10000)
    returning id into r_big;
  insert into ref_discount (name, discount_percent, customer_id, date_from, date_to) values ('T20 Минула акція', 20, l_c1, sysdate - 20, sysdate - 5)
    returning id into r_old;
  select count(*) into l_n from ref_discount where id = r_grp and code is not null and state = 'ACTIVE' and applies_to = 'ALL';
  eq('Код умови призначено, застосування «усі» за замовчуванням', l_n, 1);
  select count(*) into l_n from ref_discount where id = r_ctr and customer_id = l_c1;
  eq('Умова за договором: покупець = власник договору', l_n, 1);
  select count(*) into l_n from ref_discount where id = r_old and date_from = trunc(sysdate - 20) and date_to = trunc(sysdate - 5);
  eq('Дати акції без часу', l_n, 1);
  fails('Відсоток 0', 'DISCOUNT_OUT_OF_RANGE', 'insert into ref_discount (name, discount_percent) values (''X'', 0)');
  fails('Відсоток > 100', 'DISCOUNT_OUT_OF_RANGE', 'insert into ref_discount (name, discount_percent) values (''X'', 101)');
  fails('Кінець раніше початку', 'DISCOUNT_PERIOD',
        'insert into ref_discount (name, discount_percent, date_from, date_to) values (''X'', 1, sysdate, sysdate - 1)');
  fails('Товар і група одночасно', 'DISCOUNT_PRODUCT_OR_GROUP',
        'insert into ref_discount (name, discount_percent, product_id, product_group_id) values (''X'', 1, ''' || l_p1 || ''', ''' || l_g0 || ''')');
  fails('Договір іншого контрагента', 'DISCOUNT_CONTRACT_OWNER',
        'insert into ref_discount (name, discount_percent, customer_id, contract_id) values (''X'', 1, ''' || l_c2 || ''', ''' || l_k1 || ''')');
  fails('Фізичне видалення умови', 'видалення', 'delete from ref_discount where id = ''' || r_cus || '''');
  eqs('Подання умови', trade_discount.rule_label(r_grp), 'T20 Група від 10 (5 %)');
  select count(*) into l_n from v_discount_list where id in (r_grp, r_old) and validity_name in ('Діє', 'Завершена');
  eq('Список умов: стан дії', l_n, 2);
  select validity_name into l_s from v_discount_list where id = r_old;
  eqs('Минула акція — «Завершена»', l_s, 'Завершена');
  select count(*) into l_n from sys_audit_log where object_type = 'REF_DISCOUNT' and object_id = r_grp and action = 'CREATE';
  eq('Журнал реєстрації: створення умови', l_n, 1);

  -- ---------------------------------------------------------------- замовлення клієнта: розрахунок
  insert into doc_customer_order (customer_id, contract_id, warehouse_id, occurred_at) values (l_c1, l_k1, l_wh, sysdate - 1)
    returning id into o1;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, manual_discount_percent) values (o1, l_p1, 12, 100, 2);
  insert into doc_customer_order_goods (document_id, product_id, quantity, price) values (o1, l_p2, 2, 50);
  eq('Ручна знижка без розрахунку', oline(o1, l_p1, 'discount_percent'), 2);
  l_n := trade_discount.calc('DocCustomerOrder', o1);
  eq('Розрахувати знижки: рядків зі знижкою', l_n, 2);
  eq('Група (з підгрупами) від 10 шт — найбільша з придатних', oline(o1, l_p1, 'auto_discount_percent'), 5);
  select count(*) into l_n from doc_customer_order_goods where document_id = o1 and product_id = l_p1 and discount_id = r_grp;
  eq('Застосована умова в рядку', l_n, 1);
  eq('Знижка рядка = ручна + автоматична', oline(o1, l_p1, 'discount_percent'), 7);
  eq('Сума рядка зі знижкою', oline(o1, l_p1, 'amount'), 1116);
  eq('Договір (4 %) кращий за клієнта (3 %); «лише реалізація» і минула акція не діють', oline(o1, l_p2, 'auto_discount_percent'), 4);
  select total_amount into l_n from doc_customer_order where id = o1;
  eq('Сума документа', l_n, 1116 + 96);
  select count(*) into l_n from sys_audit_log where object_type = 'DocCustomerOrder' and object_id = o1 and action = 'CALC_DISCOUNTS';
  eq('Журнал: розрахунок знижок', l_n, 1);
  insert into doc_customer_order_goods (document_id, product_id, quantity, price, discount_percent) values (o1, l_p2, 1, 10, 10);
  select count(*) into l_n from doc_customer_order_goods
   where document_id = o1 and quantity = 1 and manual_discount_percent = 10 and auto_discount_percent = 0 and discount_percent = 10 and amount = 9;
  eq('Сумісність r3: discount_percent без ручної — ручна знижка', l_n, 1);
  delete from doc_customer_order_goods where document_id = o1 and quantity = 1;
  -- дата документа в межах минулої акції
  insert into doc_customer_order (customer_id, warehouse_id, occurred_at) values (l_c1, l_wh, sysdate - 10) returning id into o2;
  insert into doc_customer_order_goods (document_id, product_id, quantity, price) values (o2, l_p2, 1, 50);
  trade_discount.calc('DocCustomerOrder', o2);
  eq('Акція за періодом на дату документа', oline(o2, l_p2, 'auto_discount_percent'), 20);
  update doc_customer_order set occurred_at = sysdate where id = o2;
  trade_discount.calc('DocCustomerOrder', o2);
  eq('Поза періодом — знижка за договором (підставлено в замовлення автоматично)', oline(o2, l_p2, 'auto_discount_percent'), 4);

  -- ---------------------------------------------------------------- обмеження ручної знижки за роллю
  eqs('Поза сеансом APEX — без обмеження', trade_discount.manual_limit, null);
  trade_discount.g_test_roles := 'SALES';
  eq('Менеджер з продажу — 10 %', trade_discount.manual_limit, 10);
  fails('Ручна знижка понад обмеження ролі', 'MANUAL_DISCOUNT_LIMIT',
        'update doc_customer_order_goods set manual_discount_percent = 15 where document_id = ''' || o1 || ''' and product_id = ''' || l_p1 || '''');
  update doc_customer_order_goods set manual_discount_percent = 10 where document_id = o1 and product_id = l_p1;
  eq('Ручна знижка в межах обмеження', oline(o1, l_p1, 'discount_percent'), 15);
  update doc_customer_order_goods set quantity = 13 where document_id = o1 and product_id = l_p1;
  eq('Зміна кількості не перевіряє незмінну ручну знижку', oline(o1, l_p1, 'quantity'), 13);
  fails('Ручна знижка на документ понад обмеження', 'MANUAL_DISCOUNT_LIMIT',
        'begin trade_discount.set_manual(''DocCustomerOrder'', ''' || o1 || ''', 12); end;');
  trade_discount.set_manual('DocCustomerOrder', o1, 8);
  select count(*) into l_n from doc_customer_order_goods where document_id = o1 and manual_discount_percent = 8;
  eq('Ручна знижка на документ: усі рядки', l_n, 2);
  fails('Ручна знижка поза 0–100', 'DISCOUNT_OUT_OF_RANGE', 'begin trade_discount.set_manual(''DocCustomerOrder'', ''' || o1 || ''', 120); end;');
  trade_discount.g_test_roles := 'SALES,ADMIN';
  eq('Кілька ролей — найбільше обмеження', trade_discount.manual_limit, 100);
  trade_discount.g_test_roles := 'STOREKEEPER';
  eq('Роль без запису не обмежує', trade_discount.manual_limit, 100);
  update reg_discount_limit set max_manual_percent = 0 where role_static_id = 'SALES';
  trade_discount.g_test_roles := 'SALES';
  eq('Зміна обмеження в регістрі', trade_discount.manual_limit, 0);
  update reg_discount_limit set max_manual_percent = 10 where role_static_id = 'SALES';
  fails('Обмеження поза 0–100', 'DISCOUNT_OUT_OF_RANGE', 'update reg_discount_limit set max_manual_percent = 101 where role_static_id = ''SALES''');
  select count(*) into l_n from reg_discount_limit where role_static_id in ('SALES', 'ADMIN');
  eq('Обмеження ролей за замовчуванням', l_n, 2);

  -- ---------------------------------------------------------------- проведення замовлення: перерахунок
  trade_core.mark_for_deletion('REF_DISCOUNT', r_grp);
  trade_r3.post_customer_order(o1);
  eq('Проведення перераховує автоматичну знижку (умову групи помічено)', oline(o1, l_p1, 'auto_discount_percent'), 4);
  eq('Знижка рядка після проведення', oline(o1, l_p1, 'discount_percent'), 12);
  eq('Сума рядка після проведення', oline(o1, l_p1, 'amount'), 1144);
  trade_core.restore('REF_DISCOUNT', r_grp);
  fails('Розрахунок у проведеному документі', 'DOCUMENT_NOT_DRAFT', 'begin trade_discount.calc(''DocCustomerOrder'', ''' || o1 || '''); end;');

  -- ---------------------------------------------------------------- реалізація на підставі замовлення
  s1 := trade_r3.sale_from_order(o1);
  select count(*) into l_n from doc_goods_sale_goods
   where document_id = s1 and product_id = l_p1 and base_price = 100 and price = 88 and manual_discount_percent = 8
     and auto_discount_percent = 4 and discount_id = r_ctr and amount = 1144;
  eq('На підставі замовлення: ціна до знижки, знижки й умова', l_n, 1);
  trade_discount.g_test_roles := null;
  trade_ops.post_goods_sale(s1);
  eq('Реалізація за замовленням: знижки не перераховуються (група від 10 шт не застосована)', sline(s1, l_p1, 'auto_discount_percent'), 4);
  select sum(amount) into l_n from reg_sales_turnover where recorder_id = s1;
  eq('RegSales: виручка зі знижкою', l_n, 1144 + 88);
  select sum(amount) into l_n from reg_counterparty_settlement_mv where recorder_id = s1;
  eq('Борг покупця зі знижкою', l_n, 1144 + 88);

  -- ---------------------------------------------------------------- самостійна реалізація
  insert into doc_goods_sale (organization_id, customer_id, warehouse_id, occurred_at) values (l_org, l_c2, l_wh, sysdate - 0.5)
    returning id into s2;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (s2, l_p2, 300, 50);
  select count(*) into l_n from doc_goods_sale_goods where document_id = s2 and base_price = 50 and price = 50 and discount_percent = 0;
  eq('Вставка лише ціни (r2 API): ціна до знижки = ціна', l_n, 1);
  trade_ops.post_goods_sale(s2);
  eq('Проведення реалізації застосовує автоматичну знижку (сума від 10000, лише реалізація)', sline(s2, l_p2, 'auto_discount_percent'), 7);
  eq('Ціна зі знижкою', sline(s2, l_p2, 'price'), 46.5);
  select total_amount into l_n from doc_goods_sale where id = s2;
  eq('Сума реалізації зі знижкою', l_n, 13950);
  select sum(amount) into l_n from reg_sales_turnover where recorder_id = s2;
  eq('RegSales самостійної реалізації', l_n, 13950);
  trade_ops.unpost_goods_sale(s2);
  update doc_goods_sale_goods set base_price = 40 where document_id = s2;
  eq('Зміна ціни до знижки перераховує ціну', sline(s2, l_p2, 'price'), 37.2);
  update doc_goods_sale_goods set price = 50 where document_id = s2;
  eq('Зміна price (r2 API) — нова ціна до знижки', sline(s2, l_p2, 'base_price'), 50);
  trade_ops.post_goods_sale(s2);
  -- копіювання
  s3 := trade_ops.copy_goods_sale(s2);
  trade_discount.copy_lines('DocGoodsSale', s2, s3);
  select count(*) into l_n from doc_goods_sale_goods
   where document_id = s3 and base_price = 50 and auto_discount_percent = 7 and discount_id = r_big and price = 46.5;
  eq('Копія реалізації: ціна до знижки й знижки', l_n, 1);
  x := trade_r3.copy_customer_order(o1);
  trade_discount.copy_lines('DocCustomerOrder', o1, x);
  select count(*) into l_n from doc_customer_order_goods
   where document_id = x and product_id = l_p1 and manual_discount_percent = 8 and auto_discount_percent = 4 and discount_percent = 12;
  eq('Копія замовлення: ручна й автоматична знижка', l_n, 1);
  -- повернення за ціною зі знижкою
  x := trade_r3.customer_return_from_sale(s2);
  select max(price) into l_n from doc_customer_return_goods where document_id = x;
  eq('Повернення від клієнта за ціною зі знижкою', l_n, 46.5);

  -- ---------------------------------------------------------------- звіт «Надані знижки»
  select count(*), sum(discount_amount), sum(auto_discount_amount) into l_n, l_a, l_b from v_discount_given where document_id = s2;
  eq('Надані знижки: рядок реалізації', l_n, 1);
  eq('Сума знижки', l_a, 1050);
  eq('у т. ч. автоматична', l_b, 1050);
  select sum(discount_amount), sum(auto_discount_amount) into l_a, l_b from v_discount_given where document_id = s1;
  eq('Реалізація за замовленням: знижка', l_a, 156 + 12);
  eq('Реалізація за замовленням: автоматична частина', l_b, 52 + 4);
  l_c := trade_discount.given_html(sysdate - 2, sysdate, l_org);
  eq('HTML звіту: умова', sign(instr(l_c, 'T20 Велика реалізація')), 1);
  eq('HTML звіту: разом', sign(instr(l_c, to_char(1050, 'FM999G999G999G990D00', 'NLS_NUMERIC_CHARACTERS='', '''))), 1);
  l_c := trade_discount.given_html(sysdate - 400, sysdate - 300, l_org);
  eq('HTML звіту: порожній період', sign(instr(l_c, 'знижок не надавалось')), 1);

  -- ---------------------------------------------------------------- меню й сторінки
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'RefDiscount' and list_page_id = 520 and form_page_id = 521)
      or (tech_name = 'RegDiscountLimit' and list_page_id = 530 and auth_scheme = 'Роль: адміністратор')
      or (tech_name = 'DiscountsGiven' and list_page_id = 540 and kind = 'REPORT');
  eq('Об''єкти меню', l_n, 3);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (520, 521, 530, 540);
  eq('Сторінки 520/521, 530, 540', l_n, 4);
  trade_discount.g_test_roles := null;
  rollback;
exception when others then
  trade_core.g_internal := false;
  trade_discount.g_test_roles := null;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
