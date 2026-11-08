-- =============================================================================
-- Trade r4 — F-NSI-09 «Організації»: представлення з виміром організації, меню, демо-дані.
-- Повторно виконуваний. Виконувати після 24_r4_organizations.sql і r3 (15, 17).
-- =============================================================================

create or replace view v_settlement_movement as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       m.counterparty_id, c.name counterparty_name,
       m.direction, case m.direction when 'PAYABLE' then 'Кредиторська' else 'Дебіторська' end direction_name,
       m.currency_code, m.amount, m.organization_id, o.name organization_name
  from reg_counterparty_settlement_mv m
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_organization o on o.id = m.organization_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

create or replace view v_settlement_balance as
select m.counterparty_id, c.code counterparty_code, c.name counterparty_name, m.direction,
       case m.direction when 'PAYABLE' then 'Кредиторська' else 'Дебіторська' end direction_name,
       m.currency_code, sum(m.amount) balance, m.organization_id, o.name organization_name
  from reg_counterparty_settlement_mv m
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_organization o on o.id = m.organization_id
 group by m.counterparty_id, c.code, c.name, m.direction, m.currency_code, m.organization_id, o.name
having sum(m.amount) <> 0;

create or replace view v_sales as
select m.id, m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id,
       c.name counterparty_name, w.name warehouse_name, p.name product_name, u.short_name unit_name,
       m.quantity, m.amount, m.organization_id, o.name organization_name
  from reg_sales_turnover m
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join ref_organization o on o.id = m.organization_id
  join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

create or replace view v_gross_profit as
select s.period, s.recorder_type, s.recorder_id, r.recorder_name, r.page_id,
       c.name customer_name, p.name product_name, u.short_name unit_name,
       s.quantity, s.amount revenue,
       coalesce(-cm.cost_amount, 0) cost,
       s.amount - coalesce(-cm.cost_amount, 0) gross_profit,
       s.organization_id, o.name organization_name
  from reg_sales_turnover s
  left join reg_stock_cost_mv cm
    on cm.recorder_type = s.recorder_type and cm.recorder_id = s.recorder_id and cm.line_number = s.line_number
  join ref_counterparty c on c.id = s.counterparty_id
  join ref_product p on p.id = s.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  join ref_organization o on o.id = s.organization_id
  join v_recorder r on r.recorder_type = s.recorder_type and r.recorder_id = s.recorder_id;

-- ---------------------------------------------------------------- меню й панель функцій
declare
  n number;
begin
  select count(*) into n from sys_metadata_object where tech_name = 'RefOrganization';
  if n = 0 then
    insert into sys_metadata_object (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order)
    select 'RefOrganization', 'CATALOG', 'Організації', id, 330, 331, 5 from sys_main_menu_section where tech_name = 'Catalogs';
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, 'Підприємство', 1, 5, o.id, 10, 'Y'
      from sys_main_menu_section s, sys_metadata_object o where s.tech_name = 'Reference' and o.tech_name = 'RefOrganization';
  end if;
  commit;
end;
/

-- ---------------------------------------------------------------- демо: дві організації
set serveroutput on
declare
  l_org1 varchar2(32); l_org2 varchar2(32); n number;
  l_wh varchar2(32); l_sup varchar2(32); l_cus varchar2(32); p1 varchar2(32); p2 varchar2(32);
  d varchar2(32);
begin
  -- Основна організація: реквізити з sys_company_settings, якщо на момент 24 вони ще не були заповнені
  select min(id) keep (dense_rank first order by code) into l_org1 from ref_organization where is_default = 'Y';
  update ref_organization o
     set (name, full_name, edrpou, iban, bank_name, address, phone, director_name, accountant_name) =
         (select s.name, 'Товариство з обмеженою відповідальністю «Трейд Демо»', s.edrpou, replace(s.iban, ' '), s.bank_name,
                 s.address, s.phone, s.director_name, s.accountant_name from sys_company_settings s where s.id = 'X')
   where o.id = l_org1 and o.name = 'Моє підприємство' and exists (select 1 from sys_company_settings);
  update ref_organization set vat_payer = 'Y', vat_number = '123456789012'
   where id = l_org1 and vat_payer = 'N' and edrpou = '12345678';

  select count(*) into n from ref_organization where edrpou = '3012345678';
  if n > 0 then
    dbms_output.put_line('Демо-організації вже створено.');
    commit;
    return;
  end if;
  insert into ref_organization (name, full_name, org_kind, edrpou, vat_payer, iban, bank_name, address, phone, director_name)
  values ('ФОП Коваленко О. М.', 'Фізична особа-підприємець Коваленко Олена Миколаївна', 'INDIVIDUAL', '3012345678', 'N',
          'UA323052990000026001234567890', 'АТ КБ «ПриватБанк»', 'м. Київ, вул. Січових Стрільців, 10',
          '+380 67 000 00 01', 'Коваленко О. М.')
  returning id into l_org2;

  -- Документи ФОП: надходження → реалізація → часткова оплата (окремі взаєморозрахунки й продажі)
  select id into l_wh  from ref_warehouse where name = 'Основний склад';
  select id into l_sup from ref_counterparty where name = 'ТОВ «Постачальник»';
  select id into l_cus from ref_counterparty where name = 'ТОВ «Покупець»';
  select id into p1 from ref_product where name = 'Тостер';
  select id into p2 from ref_product where name = 'Чайник електричний';

  insert into doc_goods_receipt (organization_id, occurred_at, supplier_id, warehouse_id, doc_comment)
  values (l_org2, sysdate - 3/24, l_sup, l_wh, 'Закупівля ФОП') returning id into d;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (d, 1, p1, 6, 900, 0);
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (d, 2, p2, 4, 420, 0);
  trade_doc.post_goods_receipt(d);

  insert into doc_supplier_payment (organization_id, occurred_at, supplier_id, amount, doc_comment)
  values (l_org2, sysdate - 2.5/24, l_sup, 5000, 'Оплата ФОП постачальнику') returning id into d;
  trade_doc.post_supplier_payment(d);

  insert into doc_goods_sale (organization_id, occurred_at, customer_id, warehouse_id, doc_comment)
  values (l_org2, sysdate - 2/24, l_cus, l_wh, 'Продаж від ФОП') returning id into d;
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (d, p1, 3, 1299);
  insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (d, p2, 2, 650);
  trade_ops.post_goods_sale(d);

  insert into doc_customer_payment (organization_id, occurred_at, customer_id, amount, doc_comment)
  values (l_org2, sysdate - 1/24, l_cus, 3000, 'Часткова оплата ФОП') returning id into d;
  trade_ops.post_customer_payment(d);
  commit;
  dbms_output.put_line('Демо: створено ФОП Коваленко О. М. і 4 проведені документи.');
end;
/
