-- =============================================================================

-- Trade r3 — поточні підсумки (*_tot) і місячні знімки (*_snap) регістрів залишків

-- (паспорти RegStockBalance, RegCounterpartySettlement, RegStockReserve, RegCustomerOrders,

--  RegSupplierOrders, RegStockCost). Згенеровано db/gen (див. 22_r3_totals.sql).

-- Підсумки ведуться тригерами рухів; знімки — trade_regs.close_month; зміна минулого

-- інвалідує пізніші знімки; trade_regs.rebuild_totals перебудовує все з рухів.

-- =============================================================================



create table reg_stock_balance_tot (
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  constraint reg_stock_balance_tot_pk primary key (warehouse_id, product_id)
);

create table reg_stock_balance_snap (
  month_end date not null,
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  constraint reg_stock_balance_snap_pk primary key (month_end, warehouse_id, product_id)
);

create or replace trigger reg_stock_balance_movement_tot
after insert or update or delete on reg_stock_balance_movement for each row
begin
  if deleting or updating then
    merge into reg_stock_balance_tot t using (select :old.warehouse_id warehouse_id, :old.product_id product_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity - :old.quantity
     when not matched then insert (warehouse_id, product_id, quantity) values (s.warehouse_id, s.product_id, -:old.quantity);
    trade_regs.invalidate_snapshots('stock_balance', :old.period);
  end if;
  if inserting or updating then
    merge into reg_stock_balance_tot t using (select :new.warehouse_id warehouse_id, :new.product_id product_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity + :new.quantity
     when not matched then insert (warehouse_id, product_id, quantity) values (s.warehouse_id, s.product_id, :new.quantity);
    trade_regs.invalidate_snapshots('stock_balance', :new.period);
  end if;
end;
/

create table reg_counterparty_settlement_tot (
  counterparty_id varchar2(32) not null,
  direction varchar2(12) not null,
  currency_code varchar2(3) not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_counterparty_settlement_tot_pk primary key (counterparty_id, direction, currency_code)
);

create table reg_counterparty_settlement_snap (
  month_end date not null,
  counterparty_id varchar2(32) not null,
  direction varchar2(12) not null,
  currency_code varchar2(3) not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_counterparty_settlement_snap_pk primary key (month_end, counterparty_id, direction, currency_code)
);

create or replace trigger reg_counterparty_settlement_mv_tot
after insert or update or delete on reg_counterparty_settlement_mv for each row
begin
  if deleting or updating then
    merge into reg_counterparty_settlement_tot t using (select :old.counterparty_id counterparty_id, :old.direction direction, :old.currency_code currency_code from dual) s on (t.counterparty_id = s.counterparty_id and t.direction = s.direction and t.currency_code = s.currency_code)
     when matched then update set t.amount = t.amount - :old.amount
     when not matched then insert (counterparty_id, direction, currency_code, amount) values (s.counterparty_id, s.direction, s.currency_code, -:old.amount);
    trade_regs.invalidate_snapshots('counterparty_settlement', :old.period);
  end if;
  if inserting or updating then
    merge into reg_counterparty_settlement_tot t using (select :new.counterparty_id counterparty_id, :new.direction direction, :new.currency_code currency_code from dual) s on (t.counterparty_id = s.counterparty_id and t.direction = s.direction and t.currency_code = s.currency_code)
     when matched then update set t.amount = t.amount + :new.amount
     when not matched then insert (counterparty_id, direction, currency_code, amount) values (s.counterparty_id, s.direction, s.currency_code, :new.amount);
    trade_regs.invalidate_snapshots('counterparty_settlement', :new.period);
  end if;
end;
/

create table reg_stock_reserve_tot (
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  customer_order_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  constraint reg_stock_reserve_tot_pk primary key (warehouse_id, product_id, customer_order_id)
);

create table reg_stock_reserve_snap (
  month_end date not null,
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  customer_order_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  constraint reg_stock_reserve_snap_pk primary key (month_end, warehouse_id, product_id, customer_order_id)
);

create or replace trigger reg_stock_reserve_mv_tot
after insert or update or delete on reg_stock_reserve_mv for each row
begin
  if deleting or updating then
    merge into reg_stock_reserve_tot t using (select :old.warehouse_id warehouse_id, :old.product_id product_id, :old.customer_order_id customer_order_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id and t.customer_order_id = s.customer_order_id)
     when matched then update set t.quantity = t.quantity - :old.quantity
     when not matched then insert (warehouse_id, product_id, customer_order_id, quantity) values (s.warehouse_id, s.product_id, s.customer_order_id, -:old.quantity);
    trade_regs.invalidate_snapshots('stock_reserve', :old.period);
  end if;
  if inserting or updating then
    merge into reg_stock_reserve_tot t using (select :new.warehouse_id warehouse_id, :new.product_id product_id, :new.customer_order_id customer_order_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id and t.customer_order_id = s.customer_order_id)
     when matched then update set t.quantity = t.quantity + :new.quantity
     when not matched then insert (warehouse_id, product_id, customer_order_id, quantity) values (s.warehouse_id, s.product_id, s.customer_order_id, :new.quantity);
    trade_regs.invalidate_snapshots('stock_reserve', :new.period);
  end if;
end;
/

create table reg_customer_orders_tot (
  customer_order_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_customer_orders_tot_pk primary key (customer_order_id, product_id)
);

create table reg_customer_orders_snap (
  month_end date not null,
  customer_order_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_customer_orders_snap_pk primary key (month_end, customer_order_id, product_id)
);

create or replace trigger reg_customer_orders_mv_tot
after insert or update or delete on reg_customer_orders_mv for each row
begin
  if deleting or updating then
    merge into reg_customer_orders_tot t using (select :old.customer_order_id customer_order_id, :old.product_id product_id from dual) s on (t.customer_order_id = s.customer_order_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity - :old.quantity, t.amount = t.amount - :old.amount
     when not matched then insert (customer_order_id, product_id, quantity, amount) values (s.customer_order_id, s.product_id, -:old.quantity, -:old.amount);
    trade_regs.invalidate_snapshots('customer_orders', :old.period);
  end if;
  if inserting or updating then
    merge into reg_customer_orders_tot t using (select :new.customer_order_id customer_order_id, :new.product_id product_id from dual) s on (t.customer_order_id = s.customer_order_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity + :new.quantity, t.amount = t.amount + :new.amount
     when not matched then insert (customer_order_id, product_id, quantity, amount) values (s.customer_order_id, s.product_id, :new.quantity, :new.amount);
    trade_regs.invalidate_snapshots('customer_orders', :new.period);
  end if;
end;
/

create table reg_supplier_orders_tot (
  supplier_order_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_supplier_orders_tot_pk primary key (supplier_order_id, product_id)
);

create table reg_supplier_orders_snap (
  month_end date not null,
  supplier_order_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  amount number(19,2) default on null 0 not null,
  constraint reg_supplier_orders_snap_pk primary key (month_end, supplier_order_id, product_id)
);

create or replace trigger reg_supplier_orders_mv_tot
after insert or update or delete on reg_supplier_orders_mv for each row
begin
  if deleting or updating then
    merge into reg_supplier_orders_tot t using (select :old.supplier_order_id supplier_order_id, :old.product_id product_id from dual) s on (t.supplier_order_id = s.supplier_order_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity - :old.quantity, t.amount = t.amount - :old.amount
     when not matched then insert (supplier_order_id, product_id, quantity, amount) values (s.supplier_order_id, s.product_id, -:old.quantity, -:old.amount);
    trade_regs.invalidate_snapshots('supplier_orders', :old.period);
  end if;
  if inserting or updating then
    merge into reg_supplier_orders_tot t using (select :new.supplier_order_id supplier_order_id, :new.product_id product_id from dual) s on (t.supplier_order_id = s.supplier_order_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity + :new.quantity, t.amount = t.amount + :new.amount
     when not matched then insert (supplier_order_id, product_id, quantity, amount) values (s.supplier_order_id, s.product_id, :new.quantity, :new.amount);
    trade_regs.invalidate_snapshots('supplier_orders', :new.period);
  end if;
end;
/

create table reg_stock_cost_tot (
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  cost_amount number(19,2) default on null 0 not null,
  constraint reg_stock_cost_tot_pk primary key (warehouse_id, product_id)
);

create table reg_stock_cost_snap (
  month_end date not null,
  warehouse_id varchar2(32) not null,
  product_id varchar2(32) not null,
  quantity number(19,3) default on null 0 not null,
  cost_amount number(19,2) default on null 0 not null,
  constraint reg_stock_cost_snap_pk primary key (month_end, warehouse_id, product_id)
);

create or replace trigger reg_stock_cost_mv_tot
after insert or update or delete on reg_stock_cost_mv for each row
begin
  if deleting or updating then
    merge into reg_stock_cost_tot t using (select :old.warehouse_id warehouse_id, :old.product_id product_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity - :old.quantity, t.cost_amount = t.cost_amount - :old.cost_amount
     when not matched then insert (warehouse_id, product_id, quantity, cost_amount) values (s.warehouse_id, s.product_id, -:old.quantity, -:old.cost_amount);
    trade_regs.invalidate_snapshots('stock_cost', :old.period);
  end if;
  if inserting or updating then
    merge into reg_stock_cost_tot t using (select :new.warehouse_id warehouse_id, :new.product_id product_id from dual) s on (t.warehouse_id = s.warehouse_id and t.product_id = s.product_id)
     when matched then update set t.quantity = t.quantity + :new.quantity, t.cost_amount = t.cost_amount + :new.cost_amount
     when not matched then insert (warehouse_id, product_id, quantity, cost_amount) values (s.warehouse_id, s.product_id, :new.quantity, :new.cost_amount);
    trade_regs.invalidate_snapshots('stock_cost', :new.period);
  end if;
end;
/

create or replace package trade_regs as
  -- Знімки на кінець місяця (закриття періоду)
  procedure close_month (p_month in date);
  -- Перебудова поточних підсумків з рухів (адміністратор)
  procedure rebuild_totals;
  -- Зміна минулого періоду інвалідує пізніші знімки
  procedure invalidate_snapshots (p_register in varchar2, p_period in date);
  -- Залишок товару на дату: знімок + рухи після нього
  function stock_balance_at (p_warehouse_id in varchar2, p_product_id in varchar2, p_at in date) return number;
end trade_regs;
/

create or replace package body trade_regs as

  -- r4: регістри наступних ревізій (trade_cash — RegCashBalance, db/27) — через динамічний виклик,
  -- бо пакет створюється пізніше
  procedure ext_call (p_block in varchar2, p_month in date default null) is
    n number;
  begin
    select count(*) into n from user_objects where object_name = 'TRADE_CASH' and object_type = 'PACKAGE BODY';
    if n > 0 then
      if p_month is null then execute immediate p_block; else execute immediate p_block using p_month; end if;
    end if;
  end ext_call;

  procedure close_month (p_month in date) is
    l_end date := last_day(trunc(p_month));
  begin
    delete from reg_stock_balance_snap where month_end = l_end;
    insert into reg_stock_balance_snap (month_end, warehouse_id, product_id, quantity)
    select l_end, warehouse_id, product_id, sum(quantity) quantity from reg_stock_balance_movement where period <= l_end + 1 - 1/86400 group by warehouse_id, product_id
    having sum(quantity) <> 0;
    delete from reg_counterparty_settlement_snap where month_end = l_end;
    insert into reg_counterparty_settlement_snap (month_end, counterparty_id, direction, currency_code, amount)
    select l_end, counterparty_id, direction, currency_code, sum(amount) amount from reg_counterparty_settlement_mv where period <= l_end + 1 - 1/86400 group by counterparty_id, direction, currency_code
    having sum(amount) <> 0;
    delete from reg_stock_reserve_snap where month_end = l_end;
    insert into reg_stock_reserve_snap (month_end, warehouse_id, product_id, customer_order_id, quantity)
    select l_end, warehouse_id, product_id, customer_order_id, sum(quantity) quantity from reg_stock_reserve_mv where period <= l_end + 1 - 1/86400 group by warehouse_id, product_id, customer_order_id
    having sum(quantity) <> 0;
    delete from reg_customer_orders_snap where month_end = l_end;
    insert into reg_customer_orders_snap (month_end, customer_order_id, product_id, quantity, amount)
    select l_end, customer_order_id, product_id, sum(quantity) quantity, sum(amount) amount from reg_customer_orders_mv where period <= l_end + 1 - 1/86400 group by customer_order_id, product_id
    having sum(quantity) <> 0 or sum(amount) <> 0;
    delete from reg_supplier_orders_snap where month_end = l_end;
    insert into reg_supplier_orders_snap (month_end, supplier_order_id, product_id, quantity, amount)
    select l_end, supplier_order_id, product_id, sum(quantity) quantity, sum(amount) amount from reg_supplier_orders_mv where period <= l_end + 1 - 1/86400 group by supplier_order_id, product_id
    having sum(quantity) <> 0 or sum(amount) <> 0;
    delete from reg_stock_cost_snap where month_end = l_end;
    insert into reg_stock_cost_snap (month_end, warehouse_id, product_id, quantity, cost_amount)
    select l_end, warehouse_id, product_id, sum(quantity) quantity, sum(cost_amount) cost_amount from reg_stock_cost_mv where period <= l_end + 1 - 1/86400 group by warehouse_id, product_id
    having sum(quantity) <> 0 or sum(cost_amount) <> 0;
    ext_call('begin trade_cash.close_month(:m); end;', l_end);
    trade_core.audit('Register.Snapshots', to_char(l_end, 'YYYYMMDD'), 'CLOSE_MONTH');
  end close_month;

  procedure rebuild_totals is
  begin
    delete from reg_stock_balance_tot;
    insert into reg_stock_balance_tot (warehouse_id, product_id, quantity) select warehouse_id, product_id, sum(quantity) quantity from reg_stock_balance_movement group by warehouse_id, product_id;
    delete from reg_counterparty_settlement_tot;
    insert into reg_counterparty_settlement_tot (counterparty_id, direction, currency_code, amount) select counterparty_id, direction, currency_code, sum(amount) amount from reg_counterparty_settlement_mv group by counterparty_id, direction, currency_code;
    delete from reg_stock_reserve_tot;
    insert into reg_stock_reserve_tot (warehouse_id, product_id, customer_order_id, quantity) select warehouse_id, product_id, customer_order_id, sum(quantity) quantity from reg_stock_reserve_mv group by warehouse_id, product_id, customer_order_id;
    delete from reg_customer_orders_tot;
    insert into reg_customer_orders_tot (customer_order_id, product_id, quantity, amount) select customer_order_id, product_id, sum(quantity) quantity, sum(amount) amount from reg_customer_orders_mv group by customer_order_id, product_id;
    delete from reg_supplier_orders_tot;
    insert into reg_supplier_orders_tot (supplier_order_id, product_id, quantity, amount) select supplier_order_id, product_id, sum(quantity) quantity, sum(amount) amount from reg_supplier_orders_mv group by supplier_order_id, product_id;
    delete from reg_stock_cost_tot;
    insert into reg_stock_cost_tot (warehouse_id, product_id, quantity, cost_amount) select warehouse_id, product_id, sum(quantity) quantity, sum(cost_amount) cost_amount from reg_stock_cost_mv group by warehouse_id, product_id;
    ext_call('begin trade_cash.rebuild_totals; end;');
    trade_core.audit('Register.Totals', 'ALL', 'REBUILD');
  end rebuild_totals;

  procedure invalidate_snapshots (p_register in varchar2, p_period in date) is
  begin
    case p_register
      when 'stock_balance' then delete from reg_stock_balance_snap where month_end >= last_day(trunc(p_period));
      when 'counterparty_settlement' then delete from reg_counterparty_settlement_snap where month_end >= last_day(trunc(p_period));
      when 'stock_reserve' then delete from reg_stock_reserve_snap where month_end >= last_day(trunc(p_period));
      when 'customer_orders' then delete from reg_customer_orders_snap where month_end >= last_day(trunc(p_period));
      when 'supplier_orders' then delete from reg_supplier_orders_snap where month_end >= last_day(trunc(p_period));
      when 'stock_cost' then delete from reg_stock_cost_snap where month_end >= last_day(trunc(p_period));
      else null;
    end case;
  end invalidate_snapshots;

  function stock_balance_at (p_warehouse_id in varchar2, p_product_id in varchar2, p_at in date) return number is
    l_end date; l_snap number := 0; l_mv number;
  begin
    select max(month_end) into l_end from reg_stock_balance_snap
     where warehouse_id = p_warehouse_id and product_id = p_product_id and month_end < trunc(p_at);
    if l_end is not null then
      select quantity into l_snap from reg_stock_balance_snap
       where month_end = l_end and warehouse_id = p_warehouse_id and product_id = p_product_id;
    end if;
    select coalesce(sum(quantity), 0) into l_mv from reg_stock_balance_movement
     where warehouse_id = p_warehouse_id and product_id = p_product_id
       and period <= p_at and (l_end is null or period > l_end + 1 - 1/86400);
    return l_snap + l_mv;
  end stock_balance_at;

end trade_regs;
/


-- Автопідстановка договору в реалізації й надходженні (ResolveDefaultContract)
create or replace trigger doc_goods_sale_r3_bi
before insert on doc_goods_sale for each row
begin
  if :new.contract_id is null then
    :new.contract_id := trade_nsi.resolve_default_contract(:new.customer_id, 'WITH_CUSTOMER', nvl(:new.occurred_at, sysdate));
  end if;
  if :new.price_type_id is null and :new.contract_id is not null then
    select price_type_id into :new.price_type_id from ref_contract where id = :new.contract_id;
  end if;
end;
/
create or replace trigger doc_goods_receipt_r3_bi
before insert on doc_goods_receipt for each row
begin
  if :new.contract_id is null then
    :new.contract_id := trade_nsi.resolve_default_contract(:new.supplier_id, 'WITH_SUPPLIER', nvl(:new.occurred_at, sysdate));
  end if;
end;
/

-- Початкове заповнення підсумків і знімки за минулі місяці
begin
  trade_regs.rebuild_totals;
  trade_regs.close_month(add_months(sysdate, -1));
  commit;
end;
/
