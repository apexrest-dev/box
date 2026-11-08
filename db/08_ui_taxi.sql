-- =============================================================================
-- Trade — інтерфейс у стилі «Такси»: розділи-підсистеми та панель функцій
-- configuration/ui/TAXI_INTERFACE_UK.md
-- =============================================================================

-- Розділи-підсистеми (панель розділів). Старі технічні розділи Catalogs/Documents/
-- Reports лишаються як «вид об'єкта» і в панелі не показуються.
alter table sys_main_menu_section add (icon varchar2(60), is_subsystem varchar2(1) default on null 'N' not null);

update sys_main_menu_section set is_visible = 'N' where tech_name in ('Catalogs', 'Documents', 'Reports', 'Settings');

insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Main',       'Головне',              100, 'fa-bars',            'Y');
insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Sales',      'Продажі',              110, 'fa-shopping-cart',   'Y');
insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Purchases',  'Закупівлі',            120, 'fa-truck',           'Y');
insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Warehouse',  'Склад',                130, 'fa-cubes',           'Y');
insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Pricing',    'Ціноутворення',        140, 'fa-tags',            'Y');
insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem) values ('Reference',  'НСІ та адміністрування', 150, 'fa-cog',           'Y');

-- Панель функцій розділу: групи посилань у колонках (1 — операції, 2 — звіти, 3 — НСІ/сервіс)
create table sys_function_panel (
  id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
  section_id    varchar2(32)  not null,
  group_name    varchar2(100) not null,
  column_no     number(1)     not null,
  group_sort    number(5)     not null,
  object_id     varchar2(32)  not null,
  item_sort     number(5)     not null,
  is_important  varchar2(1)   default on null 'N' not null,
  constraint sys_function_panel_pk primary key (id),
  constraint sys_function_panel_uk unique (section_id, group_name, object_id),
  constraint sys_function_panel_sec_fk foreign key (section_id) references sys_main_menu_section (id),
  constraint sys_function_panel_obj_fk foreign key (object_id) references sys_metadata_object (id),
  constraint sys_function_panel_col_ck check (column_no between 1 and 3)
);

-- Сторінка форми об'єкта (для команд «Створити»)
alter table sys_metadata_object add (form_page_id number(10));
update sys_metadata_object set form_page_id = list_page_id + 1 where kind in ('CATALOG', 'DOCUMENT');

declare
  procedure add (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_object varchar2, p_sort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_sort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_object;
  end;
begin
  -- Головне
  add('Main', 'Продажі',     1, 10, 'DocGoodsSale',        10, 'Y');
  add('Main', 'Продажі',     1, 10, 'DocCustomerPayment',  20);
  add('Main', 'Закупівлі',   1, 20, 'DocGoodsReceipt',     10, 'Y');
  add('Main', 'Закупівлі',   1, 20, 'DocSupplierPayment',  20);
  add('Main', 'НСІ',         1, 30, 'RefProduct',          10);
  add('Main', 'НСІ',         1, 30, 'RefCounterparty',     20);
  add('Main', 'Звіти',       2, 10, 'RegStockBalance',     10);
  add('Main', 'Звіти',       2, 10, 'RegCounterpartySettlement', 20);
  add('Main', 'Звіти',       2, 10, 'RegSales',            30);
  -- Продажі
  add('Sales', 'Продажі',                1, 10, 'DocGoodsSale',       10, 'Y');
  add('Sales', 'Розрахунки з клієнтами', 1, 20, 'DocCustomerPayment', 10);
  add('Sales', 'Звіти',                  2, 10, 'RegSales',           10);
  add('Sales', 'Звіти',                  2, 10, 'RegCounterpartySettlement', 20);
  add('Sales', 'НСІ',                    3, 10, 'RefCounterparty',    10);
  add('Sales', 'НСІ',                    3, 10, 'RefPriceType',       20);
  -- Закупівлі
  add('Purchases', 'Закупівлі',                    1, 10, 'DocGoodsReceipt',    10, 'Y');
  add('Purchases', 'Розрахунки з постачальниками', 1, 20, 'DocSupplierPayment', 10);
  add('Purchases', 'Звіти',                        2, 10, 'RegCounterpartySettlement', 10);
  add('Purchases', 'НСІ',                          3, 10, 'RefCounterparty',    10);
  -- Склад
  add('Warehouse', 'Складські операції', 1, 10, 'DocGoodsTransfer', 10, 'Y');
  add('Warehouse', 'Складські операції', 1, 10, 'DocGoodsWriteOff', 20);
  add('Warehouse', 'Звіти',              2, 10, 'RegStockBalance',  10);
  add('Warehouse', 'НСІ',                3, 10, 'RefWarehouse',     10);
  add('Warehouse', 'НСІ',                3, 10, 'RefProduct',       20);
  -- Ціноутворення
  add('Pricing', 'Ціни',  1, 10, 'DocPriceSetting', 10, 'Y');
  add('Pricing', 'Звіти', 2, 10, 'RegProductPrice', 10);
  add('Pricing', 'НСІ',   3, 10, 'RefPriceType',    10);
  -- НСІ та адміністрування
  add('Reference', 'Номенклатура', 1, 10, 'RefProduct',       10, 'Y');
  add('Reference', 'Номенклатура', 1, 10, 'RefUnitOfMeasure', 20);
  add('Reference', 'Партнери',     1, 20, 'RefCounterparty',  10, 'Y');
  add('Reference', 'Склади',       1, 30, 'RefWarehouse',     10);
  add('Reference', 'Ціни',         1, 40, 'RefPriceType',     10);
end;
/
commit;
