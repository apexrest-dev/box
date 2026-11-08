-- Звірка поточних підсумків із сумою рухів (має бути 0 розбіжностей)
set serveroutput on feedback off
declare
  procedure chk (p_name varchar2, p_sql varchar2) is n number;
  begin
    execute immediate p_sql into n;
    dbms_output.put_line(case when n = 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ': розбіжностей ' || n);
  end;
begin
  chk('Товари на складах', 'select count(*) from (select warehouse_id, product_id, sum(quantity) q from reg_stock_balance_movement group by warehouse_id, product_id) m full join reg_stock_balance_tot t using (warehouse_id, product_id) where nvl(m.q,0) <> nvl(t.quantity,0)');
  chk('Взаєморозрахунки', 'select count(*) from (select counterparty_id, direction, currency_code, sum(amount) a from reg_counterparty_settlement_mv group by counterparty_id, direction, currency_code) m full join reg_counterparty_settlement_tot t using (counterparty_id, direction, currency_code) where nvl(m.a,0) <> nvl(t.amount,0)');
  chk('Резерви', 'select count(*) from (select warehouse_id, product_id, customer_order_id, sum(quantity) q from reg_stock_reserve_mv group by warehouse_id, product_id, customer_order_id) m full join reg_stock_reserve_tot t using (warehouse_id, product_id, customer_order_id) where nvl(m.q,0) <> nvl(t.quantity,0)');
  chk('Вартість запасів', 'select count(*) from (select warehouse_id, product_id, sum(quantity) q, sum(cost_amount) c from reg_stock_cost_mv group by warehouse_id, product_id) m full join reg_stock_cost_tot t using (warehouse_id, product_id) where nvl(m.q,0) <> nvl(t.quantity,0) or nvl(m.c,0) <> nvl(t.cost_amount,0)');
  chk('Замовлення клієнтів', 'select count(*) from (select customer_order_id, product_id, sum(quantity) q, sum(amount) a from reg_customer_orders_mv group by customer_order_id, product_id) m full join reg_customer_orders_tot t using (customer_order_id, product_id) where nvl(m.q,0) <> nvl(t.quantity,0) or nvl(m.a,0) <> nvl(t.amount,0)');
  chk('Замовлення постачальникам', 'select count(*) from (select supplier_order_id, product_id, sum(quantity) q, sum(amount) a from reg_supplier_orders_mv group by supplier_order_id, product_id) m full join reg_supplier_orders_tot t using (supplier_order_id, product_id) where nvl(m.q,0) <> nvl(t.quantity,0) or nvl(m.a,0) <> nvl(t.amount,0)');
  chk('Грошові кошти', 'select count(*) from (select organization_id, coalesce(cash_desk_id, bank_account_id) place_id, currency_code, sum(amount) a from reg_cash_balance_mv group by organization_id, coalesce(cash_desk_id, bank_account_id), currency_code) m full join reg_cash_balance_tot t using (organization_id, place_id, currency_code) where nvl(m.a,0) <> nvl(t.amount,0)');
end;
/
