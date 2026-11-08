-- =============================================================================
-- Trade r3 — пакет trade_r3: проведення нових документів, доповнення r1/r2,
-- собівартість (середня ковзна), резерви й вільні залишки, введення на підставі.
-- Паспорти: configuration/objects/* (r3, PROPOSED).
-- =============================================================================

-- Нові регістри пишуться тільки проведенням
create or replace trigger reg_stock_reserve_mv_biud before insert or update or delete on reg_stock_reserve_mv
begin if not trade_core.g_internal then trade_core.fail('Рухи регістру формуються лише проведенням документів.'); end if; end;
/
create or replace trigger reg_customer_orders_mv_biud before insert or update or delete on reg_customer_orders_mv
begin if not trade_core.g_internal then trade_core.fail('Рухи регістру формуються лише проведенням документів.'); end if; end;
/
create or replace trigger reg_supplier_orders_mv_biud before insert or update or delete on reg_supplier_orders_mv
begin if not trade_core.g_internal then trade_core.fail('Рухи регістру формуються лише проведенням документів.'); end if; end;
/
create or replace trigger reg_stock_cost_mv_biud before insert or update or delete on reg_stock_cost_mv
begin if not trade_core.g_internal then trade_core.fail('Рухи регістру формуються лише проведенням документів.'); end if; end;
/

create or replace package trade_r3 as
  -- ---------- регістри
  procedure delete_r3_movements (p_type in varchar2, p_id in varchar2);
  function  stock_qty (p_warehouse_id in varchar2, p_product_id in varchar2) return number;
  function  reserved_qty (p_warehouse_id in varchar2, p_product_id in varchar2) return number;
  procedure check_free_stock (p_warehouse_id in varchar2, p_product_id in varchar2);
  procedure check_free_stock_doc (p_lines_table in varchar2, p_doc_id in varchar2, p_warehouse_id in varchar2);
  function  avg_cost (p_warehouse_id in varchar2, p_product_id in varchar2) return number;
  function  last_average_cost (p_warehouse_id in varchar2, p_product_id in varchar2) return number;

  -- ---------- доповнення проведення r1/r2 (викликаються з trade_doc / trade_ops)
  procedure hook_post_receipt   (p_id in varchar2);
  procedure hook_unpost_receipt (p_id in varchar2);
  procedure hook_post_sale      (p_id in varchar2);
  procedure hook_unpost_sale    (p_id in varchar2);
  procedure hook_post_transfer  (p_id in varchar2);
  procedure hook_post_write_off (p_id in varchar2);

  -- ---------- документи r3
  procedure post_customer_order   (p_id in varchar2);
  procedure unpost_customer_order (p_id in varchar2);
  procedure close_customer_order  (p_id in varchar2);
  procedure reopen_customer_order (p_id in varchar2);
  function  copy_customer_order   (p_id in varchar2) return varchar2;

  procedure post_supplier_order   (p_id in varchar2);
  procedure unpost_supplier_order (p_id in varchar2);
  procedure close_supplier_order  (p_id in varchar2);
  procedure reopen_supplier_order (p_id in varchar2);
  function  copy_supplier_order   (p_id in varchar2) return varchar2;
  procedure fill_by_reorder_policy (p_id in varchar2);
  procedure refresh_supplier_prices (p_id in varchar2);

  procedure post_customer_return   (p_id in varchar2);
  procedure unpost_customer_return (p_id in varchar2);
  function  copy_customer_return   (p_id in varchar2) return varchar2;

  procedure post_supplier_return   (p_id in varchar2);
  procedure unpost_supplier_return (p_id in varchar2);
  function  copy_supplier_return   (p_id in varchar2) return varchar2;

  procedure post_inventory_count   (p_id in varchar2);
  procedure unpost_inventory_count (p_id in varchar2);
  function  copy_inventory_count   (p_id in varchar2) return varchar2;
  procedure fill_with_book_balances (p_id in varchar2);

  procedure post_surplus_posting   (p_id in varchar2);
  procedure unpost_surplus_posting (p_id in varchar2);
  function  copy_surplus_posting   (p_id in varchar2) return varchar2;

  procedure issue_invoice          (p_id in varchar2);
  procedure invoice_to_draft       (p_id in varchar2);
  procedure cancel_invoice         (p_id in varchar2, p_reason in varchar2);
  function  copy_invoice           (p_id in varchar2) return varchar2;

  -- ---------- введення на підставі
  function sale_from_order          (p_order_id in varchar2) return varchar2;
  function invoice_from_order       (p_order_id in varchar2) return varchar2;
  function receipt_from_order       (p_order_id in varchar2) return varchar2;
  function customer_return_from_sale (p_sale_id in varchar2) return varchar2;
  function supplier_return_from_receipt (p_receipt_id in varchar2) return varchar2;
  function surplus_from_inventory   (p_inventory_id in varchar2) return varchar2;
  function write_off_from_inventory (p_inventory_id in varchar2) return varchar2;

  -- ---------- сканер штрихкодів і підбір
  procedure add_by_barcode (p_doc_kind in varchar2, p_doc_id in varchar2, p_text in varchar2);
  procedure add_product (p_doc_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_qty in number, p_price in number default null);

  -- ---------- друк
  function amount_in_words_uk (p_amount in number) return varchar2;

  -- ---------- перерахунок собівартості (RegStockCost, команда RebuildStockCost)
  procedure rebuild_stock_cost;

  -- ---------- API собівартості для документів пізніших ревізій (r4 F-WH-10, db/33 trade_assembly)
  -- Рух RegStockCost (зі сповіщенням про перерахунок при зміні заднім числом)
  procedure add_cost (p_type in varchar2, p_id in varchar2, p_line in number, p_period in date,
                      p_wh in varchar2, p_prd in varchar2, p_qty in number, p_cost in number);
  -- Вартість вибуття кількості за середньою ковзною (остання одиниця забирає залишок вартості)
  function  out_cost (p_wh in varchar2, p_prd in varchar2, p_qty in number) return number;
end trade_r3;
/

create or replace package body trade_r3 as

  c_receipt   constant varchar2(60) := 'DocGoodsReceipt';
  c_sale      constant varchar2(60) := 'DocGoodsSale';
  c_transfer  constant varchar2(60) := 'DocGoodsTransfer';
  c_write_off constant varchar2(60) := 'DocGoodsWriteOff';
  c_c_order   constant varchar2(60) := 'DocCustomerOrder';
  c_s_order   constant varchar2(60) := 'DocSupplierOrder';
  c_c_return  constant varchar2(60) := 'DocCustomerReturn';
  c_s_return  constant varchar2(60) := 'DocSupplierReturn';
  c_inventory constant varchar2(60) := 'DocInventoryCount';
  c_surplus   constant varchar2(60) := 'DocSurplusPosting';
  c_invoice   constant varchar2(60) := 'DocInvoiceForPayment';
  g_rebuilding boolean := false;

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select name into l from ref_product where id = p_id;
    return l;
  end prd_name;

  -- Попередження: рух складу датою до проведеної інвентаризації
  procedure warn_inventory_outdated (p_wh varchar2, p_date date) is
    l_num varchar2(9);
  begin
    if g_rebuilding then return; end if;
    select max(doc_number) keep (dense_rank last order by occurred_at) into l_num
      from doc_inventory_count where warehouse_id = p_wh and status = 'POSTED' and occurred_at >= p_date;
    if l_num is not null then
      trade_warn.add('INVENTORY_RESULT_OUTDATED', 'документ датовано раніше проведеної інвентаризації № ' || l_num
                     || ' — її результати можуть бути неактуальними.');
    end if;
  end warn_inventory_outdated;

  function qty_txt (p number) return varchar2 is
  begin return to_char(p, 'FM999G999G999G990D000'); end;
  function amt_txt (p number) return varchar2 is
  begin return to_char(p, 'FM999G999G999G990D00'); end;

  procedure lock_row (p_table varchar2, p_id varchar2) is
    l_dummy varchar2(32);
  begin
    execute immediate 'select id from ' || dbms_assert.simple_sql_name(p_table) || ' where id = :i for update'
      into l_dummy using p_id;
  end lock_row;

  procedure audit (p_type varchar2, p_id varchar2, p_action varchar2, p_details varchar2 default null) is
  begin trade_core.audit(p_type, p_id, p_action, p_details); end;

  -- =========================================================== регістри
  procedure delete_r3_movements (p_type in varchar2, p_id in varchar2) is
  begin
    delete from reg_stock_reserve_mv   where recorder_type = p_type and recorder_id = p_id;
    delete from reg_customer_orders_mv where recorder_type = p_type and recorder_id = p_id;
    delete from reg_supplier_orders_mv where recorder_type = p_type and recorder_id = p_id;
    delete from reg_stock_cost_mv      where recorder_type = p_type and recorder_id = p_id;
    delete from reg_supplier_price     where recorder_type = p_type and recorder_id = p_id;
  end delete_r3_movements;

  procedure trade_ops_delete (p_type varchar2, p_id varchar2) is
  begin
    delete from reg_stock_balance_movement     where recorder_type = p_type and recorder_id = p_id;
    delete from reg_counterparty_settlement_mv where recorder_type = p_type and recorder_id = p_id;
    delete from reg_sales_turnover             where recorder_type = p_type and recorder_id = p_id;
    delete_r3_movements(p_type, p_id);
  end trade_ops_delete;

  function stock_qty (p_warehouse_id in varchar2, p_product_id in varchar2) return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_stock_balance_tot   -- поточні підсумки
     where warehouse_id = p_warehouse_id and product_id = p_product_id;
    return l;
  end stock_qty;

  function reserved_qty (p_warehouse_id in varchar2, p_product_id in varchar2) return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_stock_reserve_tot
     where warehouse_id = p_warehouse_id and product_id = p_product_id;
    return l;
  end reserved_qty;

  procedure check_free_stock (p_warehouse_id in varchar2, p_product_id in varchar2) is
    l_stock number := stock_qty(p_warehouse_id, p_product_id);
    l_res   number := reserved_qty(p_warehouse_id, p_product_id);
    l_name  varchar2(255); l_wh varchar2(255); l_unit varchar2(20);
  begin
    if l_stock - l_res < 0 then
      select p.name, u.short_name into l_name, l_unit
        from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = p_product_id;
      select name into l_wh from ref_warehouse where id = p_warehouse_id;
      fail('INSUFFICIENT_FREE_STOCK', 'Недостатньо вільного залишку товару «' || l_name || '» на складі «' || l_wh
           || '»: залишок ' || qty_txt(l_stock) || ', у резерві ' || qty_txt(l_res)
           || ', не вистачає ' || qty_txt(l_res - l_stock) || ' ' || l_unit || '.');
    end if;
  end check_free_stock;

  procedure check_free_stock_doc (p_lines_table in varchar2, p_doc_id in varchar2, p_warehouse_id in varchar2) is
    type t_ids is table of varchar2(32);
    l_ids t_ids;
  begin
    execute immediate 'select distinct l.product_id from ' || dbms_assert.simple_sql_name(p_lines_table)
      || ' l join ref_product p on p.id = l.product_id where l.document_id = :d and p.product_kind = ''GOODS'''
      bulk collect into l_ids using p_doc_id;
    for i in 1 .. l_ids.count loop
      check_free_stock(p_warehouse_id, l_ids(i));
    end loop;
  end check_free_stock_doc;

  procedure cost_balance (p_wh varchar2, p_prd varchar2, o_qty out number, o_cost out number) is
  begin
    select coalesce(sum(quantity), 0), coalesce(sum(cost_amount), 0) into o_qty, o_cost
      from reg_stock_cost_tot where warehouse_id = p_wh and product_id = p_prd;
  end cost_balance;

  function avg_cost (p_warehouse_id in varchar2, p_product_id in varchar2) return number is
    q number; c number;
  begin
    cost_balance(p_warehouse_id, p_product_id, q, c);
    return case when q > 0 then round(c / q, 2) end;
  end avg_cost;

  function last_average_cost (p_warehouse_id in varchar2, p_product_id in varchar2) return number is
    l number;
  begin
    l := avg_cost(p_warehouse_id, p_product_id);
    if l is null then
      -- середня на момент останнього надходження з додатною кількістю
      select max(round(cost_amount / quantity, 2)) keep (dense_rank last order by period, posting_seq) into l
        from reg_stock_cost_mv where warehouse_id = p_warehouse_id and product_id = p_product_id and quantity > 0;
    end if;
    return l;
  end last_average_cost;

  procedure add_cost (p_type in varchar2, p_id in varchar2, p_line in number, p_period in date,
                      p_wh in varchar2, p_prd in varchar2, p_qty in number, p_cost in number) is
    l_later pls_integer;
  begin
    if not g_rebuilding then
      select count(*) into l_later from reg_stock_cost_mv
       where warehouse_id = p_wh and product_id = p_prd and period > p_period;
      if l_later > 0 then
        merge into reg_stock_cost_recalc t
        using (select p_wh w, p_prd p from dual) s on (t.warehouse_id = s.w and t.product_id = s.p)
         when matched then update set t.from_date = least(t.from_date, p_period), t.marked_at = systimestamp
         when not matched then insert (warehouse_id, product_id, from_date) values (p_wh, p_prd, p_period);
        trade_warn.add('COST_RECALC_REQUIRED', 'собівартість товару «' || prd_name(p_prd)
                       || '» потребує перерахунку (зміна заднім числом).');
      end if;
    end if;
    insert into reg_stock_cost_mv (period, recorder_type, recorder_id, line_number, posting_seq,
                                   warehouse_id, product_id, quantity, cost_amount)
    values (p_period, p_type, p_id, p_line, reg_stock_cost_posting_seq.nextval, p_wh, p_prd, p_qty, p_cost);
  end add_cost;

  -- Вибуття за середньою ковзною: остання одиниця забирає залишок вартості
  function out_cost (p_wh in varchar2, p_prd in varchar2, p_qty in number) return number is
    q number; c number;
  begin
    cost_balance(p_wh, p_prd, q, c);
    if q <= 0 then
      return 0;
    elsif p_qty >= q then
      return c;
    end if;
    return round(c * p_qty / q, 2);
  end out_cost;

  procedure check_settlement (p_cp varchar2, p_dir varchar2, p_code varchar2) is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_counterparty_settlement_tot
     where counterparty_id = p_cp and direction = p_dir and currency_code = 'UAH';
    if l < 0 then
      fail(p_code, case p_dir when 'RECEIVABLE' then 'Повернення перевищує заборгованість покупця на '
                                else 'Повернення перевищує заборгованість перед постачальником на ' end
                   || amt_txt(-l) || ' UAH. Спочатку скасуйте або зменште оплату.');
    end if;
  end check_settlement;

  -- Залишок замовлення (без рухів поточного реєстратора — вони вже видалені)
  procedure order_remaining (p_reg varchar2, p_order_id varchar2, p_prd varchar2, o_q out number, o_a out number) is
  begin
    if p_reg = 'C' then
      select coalesce(sum(quantity), 0), coalesce(sum(amount), 0) into o_q, o_a
        from reg_customer_orders_mv where customer_order_id = p_order_id and product_id = p_prd;
    else
      select coalesce(sum(quantity), 0), coalesce(sum(amount), 0) into o_q, o_a
        from reg_supplier_orders_mv where supplier_order_id = p_order_id and product_id = p_prd;
    end if;
  end order_remaining;

  function part_amount (p_q number, p_rq number, p_ra number) return number is
  begin
    return case when p_q >= p_rq then p_ra else round(p_q * p_ra / p_rq, 2) end;
  end part_amount;

  procedure check_base_order (p_kind varchar2, p_order_id varchar2, p_cp varchar2, p_wh varchar2) is
    l_status varchar2(10); l_closed varchar2(1); l_cp varchar2(32); l_wh varchar2(32);
  begin
    if p_kind = 'C' then
      select status, closed, customer_id, warehouse_id into l_status, l_closed, l_cp, l_wh
        from doc_customer_order where id = p_order_id for update;
    else
      select status, closed, supplier_id, warehouse_id into l_status, l_closed, l_cp, l_wh
        from doc_supplier_order where id = p_order_id for update;
    end if;
    if l_status <> 'POSTED' then
      fail('BASE_ORDER_NOT_POSTED', 'Замовлення-підстава не проведене.');
    elsif l_closed = 'Y' then
      fail('BASE_ORDER_CLOSED', 'Замовлення-підстава закрите.');
    elsif l_cp <> p_cp then
      fail(case p_kind when 'C' then 'BASE_ORDER_CUSTOMER_MISMATCH' else 'BASE_ORDER_SUPPLIER_MISMATCH' end,
           'Контрагент документа не збігається з контрагентом замовлення.');
    elsif l_wh <> p_wh then
      fail('BASE_ORDER_WAREHOUSE_MISMATCH', 'Склад документа не збігається зі складом замовлення.');
    end if;
  end check_base_order;

  procedure check_closed_base (p_kind varchar2, p_order_id varchar2) is
    l_closed varchar2(1);
  begin
    if p_order_id is null then return; end if;
    if p_kind = 'C' then
      select closed into l_closed from doc_customer_order where id = p_order_id;
    else
      select closed into l_closed from doc_supplier_order where id = p_order_id;
    end if;
    if l_closed = 'Y' then
      fail('BASE_ORDER_CLOSED', 'Замовлення-підстава закрите: спочатку відкрийте його.');
    end if;
  end check_closed_base;

  -- =========================================================== вартість запасів по документах
  procedure cost_receipt (p_id varchar2) is
    d doc_goods_receipt%rowtype;
  begin
    select * into d from doc_goods_receipt where id = p_id;
    for l in (select g.line_number, g.product_id, g.quantity, g.amount
                from doc_goods_receipt_goods g join ref_product p on p.id = g.product_id
               where g.document_id = p_id and p.product_kind = 'GOODS' order by g.line_number) loop
      add_cost(c_receipt, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, l.quantity, l.amount);
    end loop;
  end cost_receipt;

  procedure cost_sale (p_id varchar2) is
    d doc_goods_sale%rowtype;
    l_avg number; l_markup number;
  begin
    select * into d from doc_goods_sale where id = p_id;
    if not g_rebuilding then
      select max(min_markup_percent) into l_markup from sys_company_settings;
      for l in (select g.product_id, g.price, p.name from doc_goods_sale_goods g join ref_product p on p.id = g.product_id
                 where g.document_id = p_id and p.product_kind = 'GOODS' order by g.line_number) loop
        l_avg := avg_cost(d.warehouse_id, l.product_id);
        if l_avg is not null and l.price < l_avg then
          trade_warn.add('PRICE_BELOW_COST', 'ціна «' || l.name || '» (' || amt_txt(l.price)
                         || ') нижча за собівартість (' || amt_txt(l_avg) || ').');
        elsif l_avg is not null and nvl(l_markup, 0) > 0 and l.price < round(l_avg * (1 + l_markup / 100), 2) then
          trade_warn.add('PRICE_BELOW_MIN_MARKUP', 'націнка на «' || l.name || '» менша за мінімальну ' || l_markup || ' %.');
        end if;
      end loop;
    end if;
    for l in (select g.line_number, g.product_id, g.quantity
                from doc_goods_sale_goods g join ref_product p on p.id = g.product_id
               where g.document_id = p_id and p.product_kind = 'GOODS' order by g.line_number) loop
      add_cost(c_sale, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, -l.quantity,
               -out_cost(d.warehouse_id, l.product_id, l.quantity));
    end loop;
  end cost_sale;

  procedure cost_transfer (p_id varchar2) is
    d doc_goods_transfer%rowtype;
    l_c number;
  begin
    select * into d from doc_goods_transfer where id = p_id;
    for l in (select line_number, product_id, quantity from doc_goods_transfer_goods where document_id = p_id order by line_number) loop
      l_c := out_cost(d.warehouse_from_id, l.product_id, l.quantity);
      add_cost(c_transfer, p_id, l.line_number, d.occurred_at, d.warehouse_from_id, l.product_id, -l.quantity, -l_c);
      add_cost(c_transfer, p_id, 1000000 + l.line_number, d.occurred_at, d.warehouse_to_id, l.product_id, l.quantity, l_c);
    end loop;
  end cost_transfer;

  procedure cost_write_off (p_id varchar2) is
    d doc_goods_write_off%rowtype;
  begin
    select * into d from doc_goods_write_off where id = p_id;
    for l in (select line_number, product_id, quantity from doc_goods_write_off_goods where document_id = p_id order by line_number) loop
      add_cost(c_write_off, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, -l.quantity,
               -out_cost(d.warehouse_id, l.product_id, l.quantity));
    end loop;
  end cost_write_off;

  procedure cost_customer_return (p_id varchar2) is
    d doc_customer_return%rowtype;
    l_sc number; l_sq number; l_prev_c number; l_prev_q number; l_c number;
  begin
    select * into d from doc_customer_return where id = p_id;
    for l in (select r.*, s.line_number sale_line
                from doc_customer_return_goods r
                join doc_goods_sale_goods s on s.id = r.base_sale_line_id
                join ref_product p on p.id = r.product_id
               where r.document_id = p_id and p.product_kind = 'GOODS' order by r.line_number) loop
      select coalesce(-sum(cost_amount), 0), coalesce(-sum(quantity), 0) into l_sc, l_sq
        from reg_stock_cost_mv where recorder_type = c_sale and recorder_id = d.base_sale_id and line_number = l.sale_line;
      select coalesce(sum(cm.cost_amount), 0), coalesce(sum(cm.quantity), 0) into l_prev_c, l_prev_q
        from reg_stock_cost_mv cm join doc_customer_return_goods rg on rg.document_id = cm.recorder_id and rg.line_number = cm.line_number
       where cm.recorder_type = c_c_return and rg.base_sale_line_id = l.base_sale_line_id and cm.recorder_id <> p_id;
      l_c := case when l_sq <= 0 then 0
                  when l_prev_q + l.quantity >= l_sq then l_sc - l_prev_c
                  else round(l_sc * l.quantity / l_sq, 2) end;
      add_cost(c_c_return, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, l.quantity, l_c);
    end loop;
  end cost_customer_return;

  procedure cost_supplier_return (p_id varchar2) is
    d doc_supplier_return%rowtype;
  begin
    select * into d from doc_supplier_return where id = p_id;
    for l in (select r.line_number, r.product_id, r.quantity from doc_supplier_return_goods r
                join ref_product p on p.id = r.product_id
               where r.document_id = p_id and p.product_kind = 'GOODS' order by r.line_number) loop
      add_cost(c_s_return, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, -l.quantity,
               -out_cost(d.warehouse_id, l.product_id, l.quantity));
    end loop;
  end cost_supplier_return;

  procedure cost_surplus (p_id varchar2) is
    d doc_surplus_posting%rowtype;
  begin
    select * into d from doc_surplus_posting where id = p_id;
    for l in (select * from doc_surplus_posting_goods where document_id = p_id order by line_number) loop
      add_cost(c_surplus, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, l.quantity, l.amount);
    end loop;
  end cost_surplus;

  procedure rebuild_stock_cost is
    l_sql  varchar2(4000);
    l_cur  sys_refcursor;
    l_k    varchar2(1); l_id varchar2(32); l_at date; l_cr timestamp;
    l_asm  pls_integer;
    l_ret  pls_integer;
  begin
    trade_core.g_internal := true;
    g_rebuilding := true;
    delete from reg_stock_cost_mv;
    -- r4 F-WH-10: комплектація (db/33) — якщо встановлено; динамічно, бо таблиця з пізнішої ревізії
    select count(*) into l_asm from user_objects where object_name = 'TRADE_ASSEMBLY' and object_type = 'PACKAGE BODY';
    -- r5 F-RET-01: чеки ККМ (db/43)
    select count(*) into l_ret from user_objects where object_name = 'TRADE_RETAIL' and object_type = 'PACKAGE BODY';
    l_sql := 'select k, id, occurred_at, created_at from ('
      || 'select ''R'' k, id, occurred_at, created_at from doc_goods_receipt where status = ''POSTED'''
      || ' union all select ''S'', id, occurred_at, created_at from doc_goods_sale where status = ''POSTED'''
      || ' union all select ''T'', id, occurred_at, created_at from doc_goods_transfer where status = ''POSTED'''
      || ' union all select ''W'', id, occurred_at, created_at from doc_goods_write_off where status = ''POSTED'''
      || ' union all select ''C'', id, occurred_at, created_at from doc_customer_return where status = ''POSTED'''
      || ' union all select ''U'', id, occurred_at, created_at from doc_supplier_return where status = ''POSTED'''
      || ' union all select ''P'', id, occurred_at, created_at from doc_surplus_posting where status = ''POSTED'''
      || case when l_asm > 0 then ' union all select ''A'', id, occurred_at, created_at from doc_assembly where status = ''POSTED''' end
      || case when l_ret > 0 then ' union all select ''K'', id, occurred_at, created_at from doc_retail_receipt where status = ''POSTED''' end
      || ') order by occurred_at, created_at';
    open l_cur for l_sql;
    loop
      fetch l_cur into l_k, l_id, l_at, l_cr;
      exit when l_cur%notfound;
      case l_k
        when 'R' then cost_receipt(l_id);
        when 'S' then cost_sale(l_id);
        when 'T' then cost_transfer(l_id);
        when 'W' then cost_write_off(l_id);
        when 'C' then cost_customer_return(l_id);
        when 'U' then cost_supplier_return(l_id);
        when 'P' then cost_surplus(l_id);
        when 'A' then execute immediate 'begin trade_assembly.cost_assembly(:i); end;' using l_id;
        when 'K' then execute immediate 'begin trade_retail.cost_receipt(:i); end;' using l_id;
      end case;
    end loop;
    close l_cur;
    delete from reg_stock_cost_recalc;
    g_rebuilding := false;
    trade_core.g_internal := false;
    audit('Register.StockCost', 'ALL', 'REBUILD');
  exception when others then g_rebuilding := false; trade_core.g_internal := false; raise;
  end rebuild_stock_cost;

  -- =========================================================== доповнення r1/r2
  procedure hook_post_receipt (p_id in varchar2) is
    d doc_goods_receipt%rowtype;
    l_rq number; l_ra number; l_q number; l_a number;
  begin
    select * into d from doc_goods_receipt where id = p_id;
    delete_r3_movements(c_receipt, p_id);
    trade_nsi.check_contract(d.contract_id, d.supplier_id, 'WITH_SUPPLIER', d.occurred_at);
    cost_receipt(p_id);   -- вартість запасів: + сума рядка (лише товари)
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    -- Ціни постачальників: середньозважена по товару
    insert into reg_supplier_price (period, recorder_type, recorder_id, line_number, supplier_id, product_id, price)
    select d.occurred_at, c_receipt, p_id, min(line_number), d.supplier_id, product_id, round(sum(amount) / sum(quantity), 2)
      from doc_goods_receipt_goods where document_id = p_id
     group by product_id having sum(amount) > 0;
    -- Замовлення постачальнику: −min(отримано, залишок)
    if d.base_order_id is not null then
      check_base_order('S', d.base_order_id, d.supplier_id, d.warehouse_id);
      for l in (select product_id, sum(quantity) q, min(line_number) ln
                  from doc_goods_receipt_goods where document_id = p_id group by product_id) loop
        order_remaining('S', d.base_order_id, l.product_id, l_rq, l_ra);
        if l.q > l_rq then
          trade_warn.add('RECEIPT_EXCEEDS_ORDER', 'отримано «' || prd_name(l.product_id) || '» понад замовлення на '
                         || qty_txt(l.q - greatest(l_rq, 0)) || '; надлишок не зменшує замовлення.');
        end if;
        if l_rq > 0 then
          l_q := least(l.q, l_rq);
          l_a := part_amount(l_q, l_rq, l_ra);
          insert into reg_supplier_orders_mv (period, recorder_type, recorder_id, line_number, supplier_order_id, product_id, quantity, amount)
          values (d.occurred_at, c_receipt, p_id, l.ln, d.base_order_id, l.product_id, -l_q, -l_a);
        end if;
      end loop;
    end if;
  end hook_post_receipt;

  procedure hook_unpost_receipt (p_id in varchar2) is
    l_cnt pls_integer; l_ord varchar2(32);
  begin
    select count(*) into l_cnt from doc_supplier_return where base_receipt_id = p_id and status = 'POSTED';
    if l_cnt > 0 then
      fail('BASE_HAS_POSTED_RETURNS', 'Є проведені повернення постачальнику за цим надходженням — спочатку скасуйте їх.');
    end if;
    select base_order_id into l_ord from doc_goods_receipt where id = p_id;
    check_closed_base('S', l_ord);
    delete_r3_movements(c_receipt, p_id);
  end hook_unpost_receipt;

  procedure hook_post_sale (p_id in varchar2) is
    d doc_goods_sale%rowtype;
    l_rq number; l_ra number; l_left number; l_rel number; l_a number;
    l_limit number; l_debt number; l_name varchar2(255);
  begin
    select * into d from doc_goods_sale where id = p_id;
    delete_r3_movements(c_sale, p_id);
    trade_nsi.check_contract(d.contract_id, d.customer_id, 'WITH_CUSTOMER', d.occurred_at);
    if d.base_order_id is not null then
      check_base_order('C', d.base_order_id, d.customer_id, d.warehouse_id);
      for l in (select product_id, sum(quantity) q, min(line_number) ln
                  from doc_goods_sale_goods where document_id = p_id group by product_id) loop
        order_remaining('C', d.base_order_id, l.product_id, l_rq, l_ra);
        if l.q > l_rq then
          select name into l_name from ref_product where id = l.product_id;
          fail('ORDER_OVERSHIPMENT', 'Відвантаження товару «' || l_name || '» (' || qty_txt(l.q)
               || ') перевищує невідвантажений залишок замовлення (' || qty_txt(l_rq) || ').');
        end if;
        l_a := part_amount(l.q, l_rq, l_ra);
        insert into reg_customer_orders_mv (period, recorder_type, recorder_id, line_number, customer_order_id, product_id, quantity, amount)
        values (d.occurred_at, c_sale, p_id, l.ln, d.base_order_id, l.product_id, -l.q, -l_a);
        -- зняття резерву замовлення
        select coalesce(sum(quantity), 0) into l_left from reg_stock_reserve_mv
         where customer_order_id = d.base_order_id and warehouse_id = d.warehouse_id and product_id = l.product_id;
        l_rel := least(l.q, l_left);
        if l_rel > 0 then
          insert into reg_stock_reserve_mv (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, customer_order_id, quantity)
          values (d.occurred_at, c_sale, p_id, l.ln, d.warehouse_id, l.product_id, d.base_order_id, -l_rel);
        end if;
      end loop;
    end if;
    cost_sale(p_id);   -- собівартість продажу (рядок = рядок реалізації, для «Валового прибутку»)
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    -- кредитний ліміт договору
    if d.contract_id is not null then
      select credit_limit into l_limit from ref_contract where id = d.contract_id;
      if l_limit is not null then
        select coalesce(sum(amount), 0) into l_debt from reg_counterparty_settlement_mv
         where counterparty_id = d.customer_id and direction = 'RECEIVABLE' and currency_code = 'UAH';
        if l_debt > l_limit then
          fail('CREDIT_LIMIT_EXCEEDED', 'Перевищено кредитний ліміт договору: ліміт ' || amt_txt(l_limit)
               || ', борг після відвантаження ' || amt_txt(l_debt) || ', перевищення ' || amt_txt(l_debt - l_limit) || ' UAH.');
        end if;
      end if;
    end if;
  end hook_post_sale;

  procedure hook_unpost_sale (p_id in varchar2) is
    l_cnt pls_integer; l_ord varchar2(32);
  begin
    select count(*) into l_cnt from doc_customer_return where base_sale_id = p_id and status = 'POSTED';
    if l_cnt > 0 then
      fail('BASE_HAS_POSTED_RETURNS', 'Є проведені повернення від клієнта за цією реалізацією — спочатку скасуйте їх.');
    end if;
    select base_order_id into l_ord from doc_goods_sale where id = p_id;
    check_closed_base('C', l_ord);
    delete_r3_movements(c_sale, p_id);
  end hook_unpost_sale;

  procedure hook_post_transfer (p_id in varchar2) is
    d doc_goods_transfer%rowtype;
  begin
    select * into d from doc_goods_transfer where id = p_id;
    delete_r3_movements(c_transfer, p_id);
    cost_transfer(p_id);
    warn_inventory_outdated(d.warehouse_from_id, d.occurred_at);
    warn_inventory_outdated(d.warehouse_to_id, d.occurred_at);
    check_free_stock_doc('DOC_GOODS_TRANSFER_GOODS', p_id, d.warehouse_from_id);
  end hook_post_transfer;

  procedure hook_post_write_off (p_id in varchar2) is
    d doc_goods_write_off%rowtype;
  begin
    select * into d from doc_goods_write_off where id = p_id;
    delete_r3_movements(c_write_off, p_id);
    cost_write_off(p_id);
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    check_free_stock_doc('DOC_GOODS_WRITE_OFF_GOODS', p_id, d.warehouse_id);
  end hook_post_write_off;

  -- =========================================================== спільне для документів r3
  procedure require_lines (p_lines varchar2, p_id varchar2) is
    l_cnt pls_integer;
  begin
    execute immediate 'select count(*) from ' || dbms_assert.simple_sql_name(p_lines) || ' where document_id = :d' into l_cnt using p_id;
    if l_cnt = 0 then
      fail('NO_LINES', 'Неможливо провести документ без рядків у табличній частині «Товари».');
    end if;
  end require_lines;

  procedure set_status (p_table varchar2, p_id varchar2, p_status varchar2, p_type varchar2, p_action varchar2) is
  begin
    trade_core.g_internal := true;
    execute immediate 'update ' || dbms_assert.simple_sql_name(p_table) || ' set status = :s where id = :i' using p_status, p_id;
    trade_core.g_internal := false;
    audit(p_type, p_id, p_action);
  end set_status;

  function status_of (p_table varchar2, p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    execute immediate 'select status from ' || dbms_assert.simple_sql_name(p_table) || ' where id = :i for update' into l using p_id;
    return l;
  end status_of;

  -- =========================================================== Замовлення клієнта
  procedure write_customer_order (p_id varchar2) is
    d doc_customer_order%rowtype;
    k pls_integer := 0;
  begin
    select * into d from doc_customer_order where id = p_id;
    insert into reg_customer_orders_mv (period, recorder_type, recorder_id, line_number, customer_order_id, product_id, quantity, amount)
    select d.occurred_at, c_c_order, p_id, line_number, p_id, product_id, quantity, amount
      from doc_customer_order_goods where document_id = p_id;
    insert into reg_stock_reserve_mv (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, customer_order_id, quantity)
    select d.occurred_at, c_c_order, p_id, g.line_number, d.warehouse_id, g.product_id, p_id, g.quantity
      from doc_customer_order_goods g join ref_product p on p.id = g.product_id
     where g.document_id = p_id and g.reserve_flag = 'Y' and p.product_kind = 'GOODS';
    if d.closed = 'Y' then
      -- закриваючі рухи: доводять залишки замовлення й резерву до нуля
      for r in (select product_id, sum(quantity) q, sum(amount) a from reg_customer_orders_mv
                 where customer_order_id = p_id group by product_id having sum(quantity) <> 0 or sum(amount) <> 0
                 order by product_id) loop
        k := k + 1;
        insert into reg_customer_orders_mv (period, recorder_type, recorder_id, line_number, customer_order_id, product_id, quantity, amount)
        values (d.occurred_at, c_c_order, p_id, 10000 + k, p_id, r.product_id, -r.q, -r.a);
      end loop;
      k := 0;
      for r in (select warehouse_id, product_id, sum(quantity) q from reg_stock_reserve_mv
                 where customer_order_id = p_id group by warehouse_id, product_id having sum(quantity) <> 0) loop
        k := k + 1;
        insert into reg_stock_reserve_mv (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, customer_order_id, quantity)
        values (d.occurred_at, c_c_order, p_id, 10000 + k, r.warehouse_id, r.product_id, p_id, -r.q);
      end loop;
    end if;
    -- резерв лише в межах вільного залишку
    for r in (select distinct product_id from reg_stock_reserve_mv where recorder_type = c_c_order and recorder_id = p_id) loop
      if stock_qty(d.warehouse_id, r.product_id) - reserved_qty(d.warehouse_id, r.product_id) < 0 then
        declare l_name varchar2(255); begin
          select name into l_name from ref_product where id = r.product_id;
          fail('RESERVE_EXCEEDS_FREE_STOCK', 'Резерв товару «' || l_name || '» перевищує вільний залишок: вільно '
               || qty_txt(stock_qty(d.warehouse_id, r.product_id) - reserved_qty(d.warehouse_id, r.product_id) + 0) || '.');
        end;
      end if;
    end loop;
  end write_customer_order;

  procedure post_customer_order (p_id in varchar2) is
    d doc_customer_order%rowtype;
  begin
    select * into d from doc_customer_order where id = p_id for update;
    -- r5 F-PRC-06 (db/39): перерахунок автоматичних знижок перед проведенням
    begin
      execute immediate 'begin trade_discount.prepare_post(:t, :i); end;' using c_c_order, p_id;
    exception when others then
      if sqlcode <> -6550 then raise; end if;
    end;
    require_lines('DOC_CUSTOMER_ORDER_GOODS', p_id);
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    trade_core.g_internal := true;
    delete_r3_movements(c_c_order, p_id);
    write_customer_order(p_id);
    trade_core.g_internal := false;
    set_status('DOC_CUSTOMER_ORDER', p_id, 'POSTED', c_c_order, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post_customer_order;

  procedure unpost_customer_order (p_id in varchar2) is
    l_cnt pls_integer;
  begin
    if status_of('DOC_CUSTOMER_ORDER', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    select count(*) into l_cnt from doc_goods_sale where base_order_id = p_id and status = 'POSTED';
    if l_cnt > 0 then
      fail('ORDER_HAS_SHIPMENTS', 'За замовленням є проведені реалізації — спочатку скасуйте їх.');
    end if;
    trade_core.g_internal := true;
    delete_r3_movements(c_c_order, p_id);
    update doc_customer_order set closed = 'N' where id = p_id;
    trade_core.g_internal := false;
    set_status('DOC_CUSTOMER_ORDER', p_id, 'DRAFT', c_c_order, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_customer_order;

  procedure set_closed (p_table varchar2, p_id varchar2, p_closed varchar2) is
  begin
    if status_of(p_table, p_id) <> 'POSTED' then fail('NOT_POSTED', 'Закрити/відкрити можна лише проведене замовлення.'); end if;
    trade_core.g_internal := true;
    execute immediate 'update ' || p_table || ' set closed = :c where id = :i' using p_closed, p_id;
    trade_core.g_internal := false;
  exception when others then trade_core.g_internal := false; raise;
  end set_closed;

  procedure close_customer_order (p_id in varchar2) is
  begin
    set_closed('DOC_CUSTOMER_ORDER', p_id, 'Y'); post_customer_order(p_id); audit(c_c_order, p_id, 'CLOSE');
  end close_customer_order;

  procedure reopen_customer_order (p_id in varchar2) is
  begin
    set_closed('DOC_CUSTOMER_ORDER', p_id, 'N'); post_customer_order(p_id); audit(c_c_order, p_id, 'REOPEN');
  end reopen_customer_order;

  function copy_customer_order (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_customer_order (id, occurred_at, customer_id, contract_id, warehouse_id, price_type_id, doc_comment)
    select l_new, sysdate, customer_id, contract_id, warehouse_id, price_type_id, doc_comment from doc_customer_order where id = p_id;
    insert into doc_customer_order_goods (document_id, line_number, product_id, quantity, price, discount_percent, reserve_flag)
    select l_new, line_number, product_id, quantity, price, discount_percent, reserve_flag from doc_customer_order_goods where document_id = p_id;
    audit(c_c_order, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_customer_order;

  -- =========================================================== Замовлення постачальнику
  procedure post_supplier_order (p_id in varchar2) is
    d doc_supplier_order%rowtype;
    k pls_integer := 0;
  begin
    select * into d from doc_supplier_order where id = p_id for update;
    require_lines('DOC_SUPPLIER_ORDER_GOODS', p_id);
    trade_core.g_internal := true;
    delete_r3_movements(c_s_order, p_id);
    insert into reg_supplier_orders_mv (period, recorder_type, recorder_id, line_number, supplier_order_id, product_id, quantity, amount)
    select d.occurred_at, c_s_order, p_id, line_number, p_id, product_id, quantity, amount
      from doc_supplier_order_goods where document_id = p_id;
    if d.closed = 'Y' then
      for r in (select product_id, sum(quantity) q, sum(amount) a from reg_supplier_orders_mv
                 where supplier_order_id = p_id group by product_id having sum(quantity) <> 0 or sum(amount) <> 0
                 order by product_id) loop
        k := k + 1;
        insert into reg_supplier_orders_mv (period, recorder_type, recorder_id, line_number, supplier_order_id, product_id, quantity, amount)
        values (d.occurred_at, c_s_order, p_id, 10000 + k, p_id, r.product_id, -r.q, -r.a);
      end loop;
    end if;
    trade_core.g_internal := false;
    set_status('DOC_SUPPLIER_ORDER', p_id, 'POSTED', c_s_order, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post_supplier_order;

  procedure unpost_supplier_order (p_id in varchar2) is
    l_cnt pls_integer;
  begin
    if status_of('DOC_SUPPLIER_ORDER', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    select count(*) into l_cnt from doc_goods_receipt where base_order_id = p_id and status = 'POSTED';
    if l_cnt > 0 then
      fail('ORDER_HAS_RECEIPTS', 'За замовленням є проведені надходження — спочатку скасуйте їх.');
    end if;
    trade_core.g_internal := true;
    delete_r3_movements(c_s_order, p_id);
    update doc_supplier_order set closed = 'N' where id = p_id;
    trade_core.g_internal := false;
    set_status('DOC_SUPPLIER_ORDER', p_id, 'DRAFT', c_s_order, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_supplier_order;

  procedure close_supplier_order (p_id in varchar2) is
  begin
    set_closed('DOC_SUPPLIER_ORDER', p_id, 'Y'); post_supplier_order(p_id); audit(c_s_order, p_id, 'CLOSE');
  end close_supplier_order;

  procedure reopen_supplier_order (p_id in varchar2) is
  begin
    set_closed('DOC_SUPPLIER_ORDER', p_id, 'N'); post_supplier_order(p_id); audit(c_s_order, p_id, 'REOPEN');
  end reopen_supplier_order;

  function copy_supplier_order (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_supplier_order (id, occurred_at, supplier_id, contract_id, warehouse_id, doc_comment)
    select l_new, sysdate, supplier_id, contract_id, warehouse_id, doc_comment from doc_supplier_order where id = p_id;
    insert into doc_supplier_order_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, quantity, price from doc_supplier_order_goods where document_id = p_id;
    audit(c_s_order, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_supplier_order;

  procedure fill_by_reorder_policy (p_id in varchar2) is
    d doc_supplier_order%rowtype;
    l_avail number; l_need number; l_onorder number; l_price number; l_cnt pls_integer := 0;
  begin
    select * into d from doc_supplier_order where id = p_id;
    if d.status <> 'DRAFT' then fail('DOCUMENT_READ_ONLY', 'Заповнювати можна лише чернетку.'); end if;
    for r in (select rp.product_id, rp.min_quantity, rp.max_quantity, u.fractional
                from reg_reorder_policy rp
                join ref_product p on p.id = rp.product_id
                join ref_unit_of_measure u on u.id = p.unit_of_measure_id
               where rp.warehouse_id = d.warehouse_id and rp.reorder_method = 'MIN_MAX'
                 and (rp.preferred_supplier_id is null or rp.preferred_supplier_id = d.supplier_id)
                 and p.state = 'ACTIVE' and p.product_kind = 'GOODS') loop
      select coalesce(sum(m.quantity), 0) into l_onorder
        from reg_supplier_orders_mv m join doc_supplier_order o on o.id = m.supplier_order_id
       where m.product_id = r.product_id and o.warehouse_id = d.warehouse_id and o.id <> p_id;
      l_avail := stock_qty(d.warehouse_id, r.product_id) - reserved_qty(d.warehouse_id, r.product_id) + l_onorder;
      if l_avail <= r.min_quantity then
        l_need := r.max_quantity - l_avail;
        if r.fractional = 'N' then l_need := ceil(l_need); end if;
        if l_need > 0 then
          l_price := coalesce(trade_lines.get_supplier_price(d.supplier_id, r.product_id, d.occurred_at), 0);
          merge into doc_supplier_order_goods t
          using (select r.product_id product_id from dual) s
             on (t.document_id = p_id and t.product_id = s.product_id)
           when matched then update set t.quantity = l_need
           when not matched then insert (document_id, line_number, product_id, quantity, price)
                                 values (p_id, null, r.product_id, l_need, l_price);
          l_cnt := l_cnt + 1;
        end if;
      end if;
    end loop;
    if l_cnt = 0 then
      fail('NO_REORDER_NEED', 'Потреби в закупівлі за параметрами забезпечення немає.');
    end if;
  end fill_by_reorder_policy;

  procedure refresh_supplier_prices (p_id in varchar2) is
    d doc_supplier_order%rowtype;
  begin
    select * into d from doc_supplier_order where id = p_id;
    for l in (select id, product_id from doc_supplier_order_goods where document_id = p_id) loop
      update doc_supplier_order_goods
         set price = coalesce(trade_lines.get_supplier_price(d.supplier_id, l.product_id, d.occurred_at), price)
       where id = l.id;
    end loop;
  end refresh_supplier_prices;

  -- =========================================================== Повернення від клієнта
  procedure post_customer_return (p_id in varchar2) is
    d doc_customer_return%rowtype;
    l_base_status varchar2(10);
    l_sold number; l_ret number; l_name varchar2(255);
    l_sc number; l_sq number; l_prev_c number; l_prev_q number; l_c number;
  begin
    select * into d from doc_customer_return where id = p_id for update;
    select status into l_base_status from doc_goods_sale where id = d.base_sale_id for update;
    if l_base_status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Реалізація-підстава не проведена.'); end if;
    require_lines('DOC_CUSTOMER_RETURN_GOODS', p_id);
    lock_row('REF_COUNTERPARTY', d.customer_id);
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    trade_core.g_internal := true;
    trade_ops_delete(c_c_return, p_id);
    for l in (select r.*, s.line_number sale_line, s.quantity sale_qty, p.product_kind, p.name product_name
                from doc_customer_return_goods r
                join doc_goods_sale_goods s on s.id = r.base_sale_line_id
                join ref_product p on p.id = r.product_id
               where r.document_id = p_id order by r.line_number) loop
      select coalesce(sum(rg.quantity), 0) into l_ret
        from doc_customer_return_goods rg join doc_customer_return rd on rd.id = rg.document_id
       where rg.base_sale_line_id = l.base_sale_line_id and rd.status = 'POSTED' and rd.id <> p_id;
      if l.quantity > l.sale_qty - l_ret then
        fail('RETURN_EXCEEDS_SOLD', 'Повернення товару «' || l.product_name || '» (' || qty_txt(l.quantity)
             || ') перевищує доступну до повернення кількість (' || qty_txt(l.sale_qty - l_ret) || ').');
      end if;
      insert into reg_sales_turnover (period, recorder_type, recorder_id, line_number, counterparty_id, warehouse_id, product_id, quantity, amount)
      values (d.occurred_at, c_c_return, p_id, l.line_number, d.customer_id, d.warehouse_id, l.product_id, -l.quantity, -l.amount);
      if l.product_kind = 'GOODS' then
        insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
        values (d.occurred_at, c_c_return, p_id, l.line_number, d.warehouse_id, l.product_id, l.quantity);
      end if;
    end loop;
    cost_customer_return(p_id);   -- собівартість рядка продажу, пропорційно
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (d.occurred_at, c_c_return, p_id, 1, d.customer_id, 'RECEIVABLE', 'UAH', -d.total_amount);
    check_settlement(d.customer_id, 'RECEIVABLE', 'SETTLEMENT_NEGATIVE_RECEIVABLE');
    trade_core.g_internal := false;
    set_status('DOC_CUSTOMER_RETURN', p_id, 'POSTED', c_c_return, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post_customer_return;


  procedure unpost_customer_return (p_id in varchar2) is
    d doc_customer_return%rowtype;
  begin
    if status_of('DOC_CUSTOMER_RETURN', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    select * into d from doc_customer_return where id = p_id;
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    trade_core.g_internal := true;
    trade_ops_delete(c_c_return, p_id);
    check_free_stock_doc('DOC_CUSTOMER_RETURN_GOODS', p_id, d.warehouse_id);
    trade_core.g_internal := false;
    set_status('DOC_CUSTOMER_RETURN', p_id, 'DRAFT', c_c_return, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_customer_return;

  function copy_customer_return (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_customer_return (id, occurred_at, base_sale_id, customer_id, contract_id, warehouse_id, return_reason, doc_comment)
    select l_new, sysdate, base_sale_id, customer_id, contract_id, warehouse_id, return_reason, doc_comment from doc_customer_return where id = p_id;
    insert into doc_customer_return_goods (document_id, line_number, base_sale_line_id, product_id, quantity, price)
    select l_new, line_number, base_sale_line_id, product_id, quantity, price from doc_customer_return_goods where document_id = p_id;
    audit(c_c_return, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_customer_return;

  -- =========================================================== Повернення постачальнику
  procedure post_supplier_return (p_id in varchar2) is
    d doc_supplier_return%rowtype;
    l_base_status varchar2(10);
    l_ret number;
  begin
    select * into d from doc_supplier_return where id = p_id for update;
    select status into l_base_status from doc_goods_receipt where id = d.base_receipt_id for update;
    if l_base_status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Надходження-підстава не проведене.'); end if;
    require_lines('DOC_SUPPLIER_RETURN_GOODS', p_id);
    lock_row('REF_COUNTERPARTY', d.supplier_id);
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    trade_core.g_internal := true;
    trade_ops_delete(c_s_return, p_id);
    for l in (select r.*, g.quantity rcv_qty, p.product_kind, p.name product_name
                from doc_supplier_return_goods r
                join doc_goods_receipt_goods g on g.id = r.base_receipt_line_id
                join ref_product p on p.id = r.product_id
               where r.document_id = p_id order by r.line_number) loop
      select coalesce(sum(rg.quantity), 0) into l_ret
        from doc_supplier_return_goods rg join doc_supplier_return rd on rd.id = rg.document_id
       where rg.base_receipt_line_id = l.base_receipt_line_id and rd.status = 'POSTED' and rd.id <> p_id;
      if l.quantity > l.rcv_qty - l_ret then
        fail('RETURN_EXCEEDS_RECEIVED', 'Повернення товару «' || l.product_name || '» (' || qty_txt(l.quantity)
             || ') перевищує доступну до повернення кількість (' || qty_txt(l.rcv_qty - l_ret) || ').');
      end if;
      if l.product_kind = 'GOODS' then
        insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
        values (d.occurred_at, c_s_return, p_id, l.line_number, d.warehouse_id, l.product_id, -l.quantity);
      end if;
    end loop;
    cost_supplier_return(p_id);
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (d.occurred_at, c_s_return, p_id, 1, d.supplier_id, 'PAYABLE', 'UAH', -d.total_amount);
    check_settlement(d.supplier_id, 'PAYABLE', 'SETTLEMENT_NEGATIVE_PAYABLE');
    check_free_stock_doc('DOC_SUPPLIER_RETURN_GOODS', p_id, d.warehouse_id);
    trade_core.g_internal := false;
    set_status('DOC_SUPPLIER_RETURN', p_id, 'POSTED', c_s_return, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post_supplier_return;

  procedure unpost_supplier_return (p_id in varchar2) is
  begin
    if status_of('DOC_SUPPLIER_RETURN', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    trade_core.g_internal := true;
    trade_ops_delete(c_s_return, p_id);
    trade_core.g_internal := false;
    set_status('DOC_SUPPLIER_RETURN', p_id, 'DRAFT', c_s_return, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_supplier_return;

  function copy_supplier_return (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_supplier_return (id, occurred_at, base_receipt_id, supplier_id, contract_id, warehouse_id, return_reason, doc_comment)
    select l_new, sysdate, base_receipt_id, supplier_id, contract_id, warehouse_id, return_reason, doc_comment from doc_supplier_return where id = p_id;
    insert into doc_supplier_return_goods (document_id, line_number, base_receipt_line_id, product_id, quantity, price)
    select l_new, line_number, base_receipt_line_id, product_id, quantity, price from doc_supplier_return_goods where document_id = p_id;
    audit(c_s_return, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_supplier_return;

  -- =========================================================== Інвентаризація
  procedure fill_with_book_balances (p_id in varchar2) is
    d doc_inventory_count%rowtype;
  begin
    select * into d from doc_inventory_count where id = p_id;
    if d.status <> 'DRAFT' then fail('DOCUMENT_READ_ONLY', 'Заповнювати можна лише чернетку.'); end if;
    for r in (select m.product_id, sum(m.quantity) q
                from reg_stock_balance_movement m join ref_product p on p.id = m.product_id
               where m.warehouse_id = d.warehouse_id and m.period <= d.occurred_at and p.product_kind = 'GOODS'
               group by m.product_id
              union
              select product_id, 0 from doc_inventory_count_goods where document_id = p_id
               and product_id not in (select product_id from reg_stock_balance_movement where warehouse_id = d.warehouse_id))
    loop
      merge into doc_inventory_count_goods t
      using (select r.product_id product_id from dual) s
         on (t.document_id = p_id and t.product_id = s.product_id)
       when matched then update set t.book_quantity = r.q,
                                    t.price = coalesce(last_average_cost(d.warehouse_id, r.product_id), 0)
       when not matched then insert (document_id, line_number, product_id, book_quantity, actual_quantity, price)
                             values (p_id, null, r.product_id, r.q, null, coalesce(last_average_cost(d.warehouse_id, r.product_id), 0));
    end loop;
  end fill_with_book_balances;

  procedure post_inventory_count (p_id in varchar2) is
    l_cnt pls_integer;
    l_dup pls_integer;
  begin
    if status_of('DOC_INVENTORY_COUNT', p_id) <> 'DRAFT' then fail('DOCUMENT_READ_ONLY', 'Документ уже проведено.'); end if;
    require_lines('DOC_INVENTORY_COUNT_GOODS', p_id);
    select count(*) into l_cnt from doc_inventory_count_goods where document_id = p_id and actual_quantity is null;
    if l_cnt > 0 then
      fail('ACTUAL_QUANTITY_NOT_COUNTED', 'Не заповнено фактичну кількість у ' || l_cnt || ' рядках (0 — якщо товару немає).');
    end if;
    select count(*) - count(distinct product_id) into l_dup from doc_inventory_count_goods where document_id = p_id;
    if l_dup > 0 then
      fail('PRODUCT_DUPLICATE_IN_INVENTORY', 'Товар указано в інвентаризації більше одного разу.');
    end if;
    set_status('DOC_INVENTORY_COUNT', p_id, 'POSTED', c_inventory, 'POST');
  end post_inventory_count;

  procedure unpost_inventory_count (p_id in varchar2) is
    l_cnt pls_integer;
  begin
    if status_of('DOC_INVENTORY_COUNT', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    select (select count(*) from doc_surplus_posting where base_inventory_id = p_id and status = 'POSTED')
         + (select count(*) from doc_goods_write_off where base_inventory_id = p_id and status = 'POSTED')
      into l_cnt from dual;
    if l_cnt > 0 then
      fail('BASE_HAS_POSTED_DERIVED', 'За інвентаризацією проведено оприбуткування/списання — спочатку скасуйте їх.');
    end if;
    set_status('DOC_INVENTORY_COUNT', p_id, 'DRAFT', c_inventory, 'UNPOST');
  end unpost_inventory_count;

  function copy_inventory_count (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_inventory_count (id, occurred_at, warehouse_id, responsible_person, doc_comment)
    select l_new, sysdate, warehouse_id, responsible_person, doc_comment from doc_inventory_count where id = p_id;
    insert into doc_inventory_count_goods (document_id, line_number, product_id, book_quantity, actual_quantity, price)
    select l_new, line_number, product_id, 0, null, price from doc_inventory_count_goods where document_id = p_id;
    audit(c_inventory, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_inventory_count;

  -- =========================================================== Оприбуткування надлишків
  procedure post_surplus_posting (p_id in varchar2) is
    d doc_surplus_posting%rowtype;
    l_dev number; l_name varchar2(255);
  begin
    select * into d from doc_surplus_posting where id = p_id for update;
    require_lines('DOC_SURPLUS_POSTING_GOODS', p_id);
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    if d.base_inventory_id is not null then
      for r in (select product_id, sum(quantity) q from doc_surplus_posting_goods where document_id = p_id group by product_id) loop
        select coalesce(sum(case when deviation > 0 then deviation end), 0) into l_dev
          from doc_inventory_count_goods where document_id = d.base_inventory_id and product_id = r.product_id;
        select coalesce(l_dev - sum(g.quantity), l_dev) into l_dev
          from doc_surplus_posting_goods g join doc_surplus_posting s on s.id = g.document_id
         where s.base_inventory_id = d.base_inventory_id and s.status = 'POSTED' and s.id <> p_id and g.product_id = r.product_id;
        if r.q > l_dev then
          select name into l_name from ref_product where id = r.product_id;
          fail('SURPLUS_EXCEEDS_DEVIATION', 'Оприбуткування товару «' || l_name || '» перевищує надлишок за інвентаризацією ('
               || qty_txt(l_dev) || ').');
        end if;
      end loop;
    end if;
    trade_core.g_internal := true;
    trade_ops_delete(c_surplus, p_id);
    for l in (select * from doc_surplus_posting_goods where document_id = p_id order by line_number) loop
      insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
      values (d.occurred_at, c_surplus, p_id, l.line_number, d.warehouse_id, l.product_id, l.quantity);
    end loop;
    cost_surplus(p_id);
    warn_inventory_outdated(d.warehouse_id, d.occurred_at);
    for z in (select p.name from doc_surplus_posting_goods g join ref_product p on p.id = g.product_id
               where g.document_id = p_id and g.price = 0) loop
      trade_warn.add('ZERO_VALUATION', 'надлишок «' || z.name || '» оприбутковано з нульовою вартістю.');
    end loop;
    trade_core.g_internal := false;
    set_status('DOC_SURPLUS_POSTING', p_id, 'POSTED', c_surplus, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post_surplus_posting;

  procedure unpost_surplus_posting (p_id in varchar2) is
    d doc_surplus_posting%rowtype;
  begin
    if status_of('DOC_SURPLUS_POSTING', p_id) <> 'POSTED' then fail('NOT_POSTED', 'Документ не проведено.'); end if;
    select * into d from doc_surplus_posting where id = p_id;
    lock_row('REF_WAREHOUSE', d.warehouse_id);
    trade_core.g_internal := true;
    trade_ops_delete(c_surplus, p_id);
    check_free_stock_doc('DOC_SURPLUS_POSTING_GOODS', p_id, d.warehouse_id);
    trade_core.g_internal := false;
    set_status('DOC_SURPLUS_POSTING', p_id, 'DRAFT', c_surplus, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_surplus_posting;

  function copy_surplus_posting (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_surplus_posting (id, occurred_at, warehouse_id, reason, doc_comment)
    select l_new, sysdate, warehouse_id, reason, doc_comment from doc_surplus_posting where id = p_id;
    insert into doc_surplus_posting_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, quantity, price from doc_surplus_posting_goods where document_id = p_id;
    audit(c_surplus, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_surplus_posting;

  -- =========================================================== Рахунок на оплату
  procedure issue_invoice (p_id in varchar2) is
    l_total number;
  begin
    if status_of('DOC_INVOICE_FOR_PAYMENT', p_id) <> 'DRAFT' then fail('INVOICE_NOT_DRAFT', 'Видати можна лише чернетку рахунку.'); end if;
    require_lines('DOC_INVOICE_FOR_PAYMENT_GOODS', p_id);
    select total_amount into l_total from doc_invoice_for_payment where id = p_id;
    if l_total <= 0 then fail('INVOICE_TOTAL_ZERO', 'Сума рахунку має бути більшою за нуль.'); end if;
    set_status('DOC_INVOICE_FOR_PAYMENT', p_id, 'ISSUED', c_invoice, 'ISSUE');
  end issue_invoice;

  procedure invoice_to_draft (p_id in varchar2) is
  begin
    if status_of('DOC_INVOICE_FOR_PAYMENT', p_id) not in ('ISSUED', 'CANCELLED') then
      fail('INVOICE_NOT_ISSUED', 'Рахунок уже є чернеткою.');
    end if;
    trade_core.g_internal := true;
    update doc_invoice_for_payment set cancel_reason = null where id = p_id;
    trade_core.g_internal := false;
    set_status('DOC_INVOICE_FOR_PAYMENT', p_id, 'DRAFT', c_invoice, 'RETURN_TO_DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end invoice_to_draft;

  procedure cancel_invoice (p_id in varchar2, p_reason in varchar2) is
  begin
    if trim(p_reason) is null then fail('CANCEL_REASON_REQUIRED', 'Вкажіть причину анулювання рахунку.'); end if;
    if status_of('DOC_INVOICE_FOR_PAYMENT', p_id) = 'CANCELLED' then fail('INVOICE_READ_ONLY', 'Рахунок уже анульовано.'); end if;
    trade_core.g_internal := true;
    update doc_invoice_for_payment set cancel_reason = trim(p_reason) where id = p_id;
    trade_core.g_internal := false;
    set_status('DOC_INVOICE_FOR_PAYMENT', p_id, 'CANCELLED', c_invoice, 'CANCEL');
  exception when others then trade_core.g_internal := false; raise;
  end cancel_invoice;

  function copy_invoice (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_invoice_for_payment (id, occurred_at, base_order_id, customer_id, contract_id, doc_comment)
    select l_new, sysdate, base_order_id, customer_id, contract_id, doc_comment from doc_invoice_for_payment where id = p_id;
    insert into doc_invoice_for_payment_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, quantity, price from doc_invoice_for_payment_goods where document_id = p_id;
    audit(c_invoice, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_invoice;

  -- =========================================================== Введення на підставі
  function sale_from_order (p_order_id in varchar2) return varchar2 is
    o doc_customer_order%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_rq number; l_left number; l_q number; l_cnt pls_integer := 0;
  begin
    select * into o from doc_customer_order where id = p_order_id;
    if o.status <> 'POSTED' then fail('BASE_ORDER_NOT_POSTED', 'Замовлення не проведене.'); end if;
    if o.closed = 'Y' then fail('BASE_ORDER_CLOSED', 'Замовлення закрите.'); end if;
    insert into doc_goods_sale (id, occurred_at, customer_id, warehouse_id, price_type_id, contract_id, base_order_id, doc_comment)
    values (l_new, sysdate, o.customer_id, o.warehouse_id, o.price_type_id, o.contract_id, p_order_id,
            'На підставі замовлення клієнта ' || o.doc_number);
    for p in (select distinct product_id from doc_customer_order_goods where document_id = p_order_id) loop
      select coalesce(sum(quantity), 0) into l_rq from reg_customer_orders_mv
       where customer_order_id = p_order_id and product_id = p.product_id;
      l_left := l_rq;
      for g in (select * from doc_customer_order_goods where document_id = p_order_id and product_id = p.product_id order by line_number) loop
        exit when l_left <= 0;
        l_q := least(g.quantity, l_left);
        -- r5 F-PRC-06 (db/39): ціна до знижки й знижки рядка замовлення переносяться в реалізацію
        begin
          execute immediate 'begin trade_discount.sale_line_from_order(:s, :n, :g, :q); end;'
            using l_new, g.line_number, g.id, l_q;
        exception when others then
          if sqlcode = -6550 then   -- db/39 не встановлено: знижка в ціні
            insert into doc_goods_sale_goods (document_id, line_number, product_id, quantity, price)
            values (l_new, g.line_number, g.product_id, l_q, round(g.price * (1 - g.discount_percent / 100), 2));
          else
            raise;
          end if;
        end;
        l_left := l_left - l_q;
        l_cnt := l_cnt + 1;
      end loop;
    end loop;
    if l_cnt = 0 then fail('NOTHING_TO_SHIP', 'За замовленням усе вже відвантажено.'); end if;
    audit(c_sale, l_new, 'CREATE_BASED_ON', c_c_order || ' ' || p_order_id);
    return l_new;
  end sale_from_order;

  function invoice_from_order (p_order_id in varchar2) return varchar2 is
    o doc_customer_order%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    select * into o from doc_customer_order where id = p_order_id;
    if o.status <> 'POSTED' then fail('BASE_ORDER_NOT_POSTED', 'Замовлення не проведене.'); end if;
    insert into doc_invoice_for_payment (id, occurred_at, base_order_id, customer_id, contract_id, doc_comment)
    values (l_new, sysdate, p_order_id, o.customer_id, o.contract_id, 'Згідно із замовленням ' || o.doc_number);
    insert into doc_invoice_for_payment_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, quantity, round(price * (1 - discount_percent / 100), 2)
      from doc_customer_order_goods where document_id = p_order_id;
    audit(c_invoice, l_new, 'CREATE_BASED_ON', c_c_order || ' ' || p_order_id);
    return l_new;
  end invoice_from_order;

  function receipt_from_order (p_order_id in varchar2) return varchar2 is
    o doc_supplier_order%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_rq number; l_left number; l_q number; l_cnt pls_integer := 0;
  begin
    select * into o from doc_supplier_order where id = p_order_id;
    if o.status <> 'POSTED' then fail('BASE_ORDER_NOT_POSTED', 'Замовлення не проведене.'); end if;
    if o.closed = 'Y' then fail('BASE_ORDER_CLOSED', 'Замовлення закрите.'); end if;
    insert into doc_goods_receipt (id, occurred_at, supplier_id, warehouse_id, contract_id, base_order_id, doc_comment)
    values (l_new, sysdate, o.supplier_id, o.warehouse_id, o.contract_id, p_order_id,
            'На підставі замовлення постачальнику ' || o.doc_number);
    for p in (select distinct product_id from doc_supplier_order_goods where document_id = p_order_id) loop
      select coalesce(sum(quantity), 0) into l_rq from reg_supplier_orders_mv
       where supplier_order_id = p_order_id and product_id = p.product_id;
      l_left := l_rq;
      for g in (select * from doc_supplier_order_goods where document_id = p_order_id and product_id = p.product_id order by line_number) loop
        exit when l_left <= 0;
        l_q := least(g.quantity, l_left);
        insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount)
        values (l_new, g.line_number, g.product_id, l_q, g.price, 0);
        l_left := l_left - l_q;
        l_cnt := l_cnt + 1;
      end loop;
    end loop;
    if l_cnt = 0 then fail('NOTHING_TO_RECEIVE', 'За замовленням усе вже отримано.'); end if;
    audit(c_receipt, l_new, 'CREATE_BASED_ON', c_s_order || ' ' || p_order_id);
    return l_new;
  end receipt_from_order;

  function customer_return_from_sale (p_sale_id in varchar2) return varchar2 is
    s doc_goods_sale%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_cnt pls_integer := 0;
  begin
    select * into s from doc_goods_sale where id = p_sale_id;
    if s.status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Реалізація не проведена.'); end if;
    insert into doc_customer_return (id, occurred_at, base_sale_id, customer_id, contract_id, warehouse_id, return_reason)
    values (l_new, greatest(sysdate, s.occurred_at + 1/86400), p_sale_id, s.customer_id, s.contract_id, s.warehouse_id, 'Повернення від покупця');
    for g in (select g.*, g.quantity - coalesce((select sum(rg.quantity) from doc_customer_return_goods rg
                                                   join doc_customer_return rd on rd.id = rg.document_id
                                                  where rg.base_sale_line_id = g.id and rd.status = 'POSTED'), 0) left_qty
                from doc_goods_sale_goods g where g.document_id = p_sale_id order by g.line_number) loop
      if g.left_qty > 0 then
        insert into doc_customer_return_goods (document_id, line_number, base_sale_line_id, product_id, quantity, price)
        values (l_new, g.line_number, g.id, g.product_id, g.left_qty, g.price);
        l_cnt := l_cnt + 1;
      end if;
    end loop;
    if l_cnt = 0 then fail('NOTHING_TO_RETURN', 'За реалізацією все вже повернено.'); end if;
    audit(c_c_return, l_new, 'CREATE_BASED_ON', c_sale || ' ' || p_sale_id);
    return l_new;
  end customer_return_from_sale;

  function supplier_return_from_receipt (p_receipt_id in varchar2) return varchar2 is
    r doc_goods_receipt%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_cnt pls_integer := 0;
  begin
    select * into r from doc_goods_receipt where id = p_receipt_id;
    if r.status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Надходження не проведене.'); end if;
    insert into doc_supplier_return (id, occurred_at, base_receipt_id, supplier_id, contract_id, warehouse_id, return_reason)
    values (l_new, greatest(sysdate, r.occurred_at + 1/86400), p_receipt_id, r.supplier_id, r.contract_id, r.warehouse_id, 'Повернення постачальнику');
    for g in (select g.*, g.quantity - coalesce((select sum(rg.quantity) from doc_supplier_return_goods rg
                                                   join doc_supplier_return rd on rd.id = rg.document_id
                                                  where rg.base_receipt_line_id = g.id and rd.status = 'POSTED'), 0) left_qty
                from doc_goods_receipt_goods g where g.document_id = p_receipt_id order by g.line_number) loop
      if g.left_qty > 0 then
        insert into doc_supplier_return_goods (document_id, line_number, base_receipt_line_id, product_id, quantity, price)
        values (l_new, g.line_number, g.id, g.product_id, g.left_qty, g.price);
        l_cnt := l_cnt + 1;
      end if;
    end loop;
    if l_cnt = 0 then fail('NOTHING_TO_RETURN', 'За надходженням усе вже повернено.'); end if;
    audit(c_s_return, l_new, 'CREATE_BASED_ON', c_receipt || ' ' || p_receipt_id);
    return l_new;
  end supplier_return_from_receipt;

  function surplus_from_inventory (p_inventory_id in varchar2) return varchar2 is
    i doc_inventory_count%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_cnt pls_integer;
  begin
    select * into i from doc_inventory_count where id = p_inventory_id;
    if i.status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Інвентаризація не проведена.'); end if;
    select count(*) into l_cnt from doc_inventory_count_goods where document_id = p_inventory_id and deviation > 0;
    if l_cnt = 0 then fail('NOTHING_TO_POST_SURPLUS', 'Надлишків за інвентаризацією немає.'); end if;
    insert into doc_surplus_posting (id, occurred_at, base_inventory_id, warehouse_id, reason)
    values (l_new, i.occurred_at + 1/86400, p_inventory_id, i.warehouse_id, 'Надлишки за інвентаризацією № ' || i.doc_number);
    insert into doc_surplus_posting_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, deviation, price from doc_inventory_count_goods
     where document_id = p_inventory_id and deviation > 0;
    audit(c_surplus, l_new, 'CREATE_BASED_ON', c_inventory || ' ' || p_inventory_id);
    return l_new;
  end surplus_from_inventory;

  function write_off_from_inventory (p_inventory_id in varchar2) return varchar2 is
    i doc_inventory_count%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_cnt pls_integer;
  begin
    select * into i from doc_inventory_count where id = p_inventory_id;
    if i.status <> 'POSTED' then fail('BASE_NOT_POSTED', 'Інвентаризація не проведена.'); end if;
    select count(*) into l_cnt from doc_inventory_count_goods where document_id = p_inventory_id and deviation < 0;
    if l_cnt = 0 then fail('NOTHING_TO_WRITE_OFF', 'Недостач за інвентаризацією немає.'); end if;
    insert into doc_goods_write_off (id, occurred_at, warehouse_id, reason, base_inventory_id)
    values (l_new, i.occurred_at + 1/86400, i.warehouse_id, 'Недостача за інвентаризацією № ' || i.doc_number, p_inventory_id);
    insert into doc_goods_write_off_goods (document_id, line_number, product_id, quantity)
    select l_new, line_number, product_id, -deviation from doc_inventory_count_goods
     where document_id = p_inventory_id and deviation < 0;
    audit(c_write_off, l_new, 'CREATE_BASED_ON', c_inventory || ' ' || p_inventory_id);
    return l_new;
  end write_off_from_inventory;

  -- =========================================================== Сканер
  procedure add_product (p_doc_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_qty in number, p_price in number default null) is
    l_tab varchar2(60);
    l_col varchar2(30) := 'QUANTITY';
    l_cnt pls_integer;
  begin
    if p_qty is null or p_qty <= 0 then return; end if;
    l_tab := case p_doc_kind
               when 'SALE' then 'DOC_GOODS_SALE_GOODS'
               when 'RECEIPT' then 'DOC_GOODS_RECEIPT_GOODS'
               when 'CUSTOMER_ORDER' then 'DOC_CUSTOMER_ORDER_GOODS'
               when 'SUPPLIER_ORDER' then 'DOC_SUPPLIER_ORDER_GOODS'
               when 'INVENTORY' then 'DOC_INVENTORY_COUNT_GOODS'
               when 'TRANSFER' then 'DOC_GOODS_TRANSFER_GOODS'
               when 'WRITE_OFF' then 'DOC_GOODS_WRITE_OFF_GOODS'
               when 'SURPLUS' then 'DOC_SURPLUS_POSTING_GOODS'
               when 'INVOICE' then 'DOC_INVOICE_FOR_PAYMENT_GOODS' end;
    if l_tab is null then fail('BARCODE_NOT_SUPPORTED', 'Додавання товарів не підтримується для цього документа.'); end if;
    if p_doc_kind = 'INVENTORY' then l_col := 'ACTUAL_QUANTITY'; end if;
    execute immediate 'select count(*) from ' || l_tab || ' where document_id = :d and product_id = :p' into l_cnt using p_doc_id, p_product_id;
    if l_cnt > 0 then
      execute immediate 'update ' || l_tab || ' set ' || l_col || ' = nvl(' || l_col || ', 0) + :q
                          where id = (select min(id) keep (dense_rank first order by line_number) from ' || l_tab
                        || ' where document_id = :d and product_id = :p)' using p_qty, p_doc_id, p_product_id;
    elsif p_doc_kind = 'INVENTORY' then
      execute immediate 'insert into ' || l_tab || ' (document_id, product_id, book_quantity, actual_quantity, price) values (:d, :p, 0, :q, 0)'
        using p_doc_id, p_product_id, p_qty;
    elsif p_doc_kind in ('TRANSFER', 'WRITE_OFF') then
      execute immediate 'insert into ' || l_tab || ' (document_id, product_id, quantity) values (:d, :p, :q)' using p_doc_id, p_product_id, p_qty;
    elsif p_doc_kind in ('RECEIPT', 'SURPLUS', 'INVOICE') then
      execute immediate 'insert into ' || l_tab || ' (document_id, product_id, quantity, price, amount) values (:d, :p, :q, :c, 0)'
        using p_doc_id, p_product_id, p_qty, coalesce(p_price, 0);
    else
      -- ціна з виду цін / ціни постачальника (тригер рядка), якщо не передано
      execute immediate 'insert into ' || l_tab || ' (document_id, product_id, quantity, price) values (:d, :p, :q, :c)'
        using p_doc_id, p_product_id, p_qty, p_price;
    end if;
  end add_product;

  procedure add_by_barcode (p_doc_kind in varchar2, p_doc_id in varchar2, p_text in varchar2) is
    l_prd varchar2(32) := trade_nsi.lookup_product(p_text);
  begin
    if l_prd is null then
      fail('BARCODE_NOT_FOUND', 'Товар зі штрихкодом/артикулом «' || p_text || '» не знайдено.');
    end if;
    add_product(p_doc_kind, p_doc_id, l_prd, trade_nsi.lookup_barcode_qty(p_text));
  end add_by_barcode;

  -- =========================================================== Сума прописом
  function words_999 (n pls_integer, p_fem boolean) return varchar2 is
    type t_a is table of varchar2(30) index by pls_integer;
    u t_a; t t_a; h t_a; tn t_a;
    l varchar2(200); n100 pls_integer := trunc(n / 100); n10 pls_integer := mod(n, 100);
  begin
    u(1):='один'; u(2):='два'; u(3):='три'; u(4):='чотири'; u(5):='п''ять'; u(6):='шість'; u(7):='сім'; u(8):='вісім'; u(9):='дев''ять';
    tn(10):='десять'; tn(11):='одинадцять'; tn(12):='дванадцять'; tn(13):='тринадцять'; tn(14):='чотирнадцять'; tn(15):='п''ятнадцять';
    tn(16):='шістнадцять'; tn(17):='сімнадцять'; tn(18):='вісімнадцять'; tn(19):='дев''ятнадцять';
    t(2):='двадцять'; t(3):='тридцять'; t(4):='сорок'; t(5):='п''ятдесят'; t(6):='шістдесят'; t(7):='сімдесят'; t(8):='вісімдесят'; t(9):='дев''яносто';
    h(1):='сто'; h(2):='двісті'; h(3):='триста'; h(4):='чотириста'; h(5):='п''ятсот'; h(6):='шістсот'; h(7):='сімсот'; h(8):='вісімсот'; h(9):='дев''ятсот';
    if n100 > 0 then l := h(n100) || ' '; end if;
    if n10 between 10 and 19 then
      l := l || tn(n10);
    else
      if trunc(n10 / 10) > 1 then l := l || t(trunc(n10 / 10)) || ' '; end if;
      if mod(n10, 10) > 0 then
        l := l || case when p_fem and mod(n10, 10) = 1 then 'одна' when p_fem and mod(n10, 10) = 2 then 'дві' else u(mod(n10, 10)) end;
      end if;
    end if;
    return trim(l);
  end words_999;

  function plural (n pls_integer, f1 varchar2, f2 varchar2, f5 varchar2) return varchar2 is
    n10 pls_integer := mod(n, 10); n100 pls_integer := mod(n, 100);
  begin
    return case when n100 between 11 and 14 then f5 when n10 = 1 then f1 when n10 between 2 and 4 then f2 else f5 end;
  end plural;

  function amount_in_words_uk (p_amount in number) return varchar2 is
    l_uah pls_integer := trunc(abs(p_amount));
    l_kop pls_integer := round((abs(p_amount) - trunc(abs(p_amount))) * 100);
    l_mln pls_integer := trunc(l_uah / 1000000);
    l_th  pls_integer := trunc(mod(l_uah, 1000000) / 1000);
    l_r   pls_integer := mod(l_uah, 1000);
    l     varchar2(500);
  begin
    if l_mln > 0 then l := words_999(l_mln, false) || ' ' || plural(l_mln, 'мільйон', 'мільйони', 'мільйонів') || ' '; end if;
    if l_th > 0 then l := l || words_999(l_th, true) || ' ' || plural(l_th, 'тисяча', 'тисячі', 'тисяч') || ' '; end if;
    if l_r > 0 then l := l || words_999(l_r, true) || ' '; end if;
    if l_uah = 0 then l := 'нуль '; end if;
    l := l || plural(l_uah, 'гривня', 'гривні', 'гривень') || ' ' || lpad(l_kop, 2, '0') || ' '
         || plural(l_kop, 'копійка', 'копійки', 'копійок');
    return upper(substr(l, 1, 1)) || substr(l, 2);
  end amount_in_words_uk;

end trade_r3;
/
