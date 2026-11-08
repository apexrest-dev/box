-- Демо: потреба в закупівлі гречки → чернетка замовлення постачальнику «за потребою»
declare
  so varchar2(32); l_sup varchar2(32); l_wh varchar2(32); l_ctr varchar2(32);
begin
  select id into l_sup from ref_counterparty where name = 'ТОВ «Постачальник»';
  select id into l_wh from ref_warehouse where name = 'Основний склад';
  select id into l_ctr from ref_contract where owner_id = l_sup and contract_kind = 'WITH_SUPPLIER';
  update reg_reorder_policy set min_quantity = 100
   where warehouse_id = l_wh and product_id = (select id from ref_product where name = 'Гречка ядриця');
  insert into doc_supplier_order (occurred_at, supplier_id, contract_id, warehouse_id, expected_date, doc_comment)
  values (sysdate, l_sup, l_ctr, l_wh, trunc(sysdate + 3), 'Сформовано за потребою') returning id into so;
  trade_r3.fill_by_reorder_policy(so);
  commit;
end;
/
