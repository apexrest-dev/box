-- APEX передає явні NULL для незаповнених стовпців, тому значення за замовчуванням
-- задаються як DEFAULT ON NULL.
begin
  for t in (select table_name from user_tab_columns
             where column_name = 'ID' and identity_column = 'NO'
               and regexp_like(table_name, '^(REF|DOC|REG|SYS)_'))
  loop
    execute immediate 'alter table ' || t.table_name || ' modify id default on null rawtohex(sys_guid())';
  end loop;
end;
/
alter table doc_goods_receipt       modify (currency_code default on null 'UAH', total_amount default on null 0,
                                            status default on null 'DRAFT', version default on null 0, occurred_at default on null sysdate);
alter table doc_supplier_payment    modify (currency_code default on null 'UAH', status default on null 'DRAFT',
                                            version default on null 0, occurred_at default on null sysdate);
alter table doc_goods_receipt_goods modify (line_number default on null 999999, amount default on null 0);
alter table ref_unit_of_measure     modify (fractional default on null 'N', state default on null 'ACTIVE', version default on null 0);
alter table ref_product             modify (state default on null 'ACTIVE', version default on null 0);
alter table ref_warehouse           modify (state default on null 'ACTIVE', version default on null 0);
alter table ref_counterparty        modify (state default on null 'ACTIVE', version default on null 0);
