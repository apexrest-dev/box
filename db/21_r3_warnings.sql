-- =============================================================================
-- Trade r3 — неблокувальні попередження (паспорти r3) і позначки перерахунку собівартості
--   PRICE_BELOW_COST, PRICE_BELOW_MIN_MARKUP — DocGoodsSale (RegStockCost, F-PRC-05)
--   RECEIPT_EXCEEDS_ORDER — DocGoodsReceipt на підставі замовлення (RegSupplierOrders)
--   ZERO_VALUATION — DocSurplusPosting з нульовою ціною (DocSurplusPosting)
--   INVENTORY_RESULT_OUTDATED — рух складу датою до проведеної інвентаризації (DocInventoryCount)
--   COST_RECALC_REQUIRED — ретроспективна зміна вартості запасів (RegStockCost)
-- =============================================================================
create table reg_stock_cost_recalc (
  warehouse_id varchar2(32) not null,
  product_id   varchar2(32) not null,
  from_date    date not null,
  marked_at    timestamp default on null systimestamp not null,
  constraint reg_stock_cost_recalc_pk primary key (warehouse_id, product_id),
  constraint reg_stock_cost_recalc_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_stock_cost_recalc_prd_fk foreign key (product_id) references ref_product (id)
);

create or replace package trade_warn as
  procedure clear;
  procedure add (p_code in varchar2, p_message in varchar2);
  -- Текст усіх попереджень (через пробіл) і очищення списку
  function take return varchar2;
  function cnt return pls_integer;
end trade_warn;
/

create or replace package body trade_warn as
  type t_list is table of varchar2(1000);
  g t_list := t_list();

  procedure clear is begin g.delete; end;

  procedure add (p_code in varchar2, p_message in varchar2) is
  begin
    g.extend;
    g(g.count) := p_message;
    -- код лишається в журналі для аналізу
    trade_core.audit('Warning', p_code, 'WARN', substr(p_message, 1, 3900));
  end add;

  function take return varchar2 is
    l varchar2(4000);
  begin
    for i in 1 .. g.count loop
      l := substr(l || case when l is not null then ' ' end || 'Увага: ' || g(i), 1, 3900);
    end loop;
    g.delete;
    return l;
  end take;

  function cnt return pls_integer is begin return g.count; end;
end trade_warn;
/
