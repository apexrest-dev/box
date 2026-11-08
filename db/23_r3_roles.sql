-- =============================================================================
-- Trade r3 — права: схема авторизації для об'єктів основного меню (панель функцій
-- показує лише доступні користувачу посилання). Ролі й схеми — в APEX-застосунку,
-- користувачі й призначення ролей — infra/apex_users.sh.
-- =============================================================================
alter table sys_metadata_object add (auth_scheme varchar2(100));

update sys_metadata_object set auth_scheme = case
  when tech_name in ('DocGoodsSale','DocCustomerPayment','DocCustomerOrder','DocCustomerReturn','DocInvoiceForPayment') then 'Роль: продажі'
  when tech_name in ('DocSupplierPayment','DocSupplierOrder','DocSupplierReturn','RegReorderPolicy') then 'Роль: закупівлі'
  when tech_name in ('DocGoodsReceipt') then 'Роль: склад або закупівлі'
  when tech_name in ('DocGoodsTransfer','DocGoodsWriteOff','DocInventoryCount','DocSurplusPosting','RegBarcode') then 'Роль: склад'
  when tech_name in ('DocPriceSetting') then 'Роль: адміністратор'
end;
commit;
