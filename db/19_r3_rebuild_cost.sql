-- Перерахунок собівартості після міграції r3 (документи r1/r2 не мали рухів RegStockCost)
begin trade_r3.rebuild_stock_cost; commit; end;
/
