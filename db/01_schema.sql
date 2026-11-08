-- =============================================================================
-- Trade (1С-подібна конфігурація) — схема даних r1
-- Джерело: configuration/objects/*/PASSPORT_UK.md
-- Виконується у схемі TRADE.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Системні таблиці: аудит, основне меню (розділи) та об'єкти меню
-- ---------------------------------------------------------------------------
create table sys_audit_log (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  occurred_at   timestamp     default systimestamp not null,
  user_name     varchar2(255) not null,
  object_type   varchar2(60)  not null,
  object_id     varchar2(32)  not null,
  action        varchar2(30)  not null,
  details       varchar2(4000),
  constraint sys_audit_log_pk primary key (id)
);
create index sys_audit_log_obj_ix on sys_audit_log (object_type, object_id);

-- Системний довідник «Основне меню» (MAIN_APPLICATION_INTERFACE_UK.md)
create table sys_main_menu_section (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  tech_name     varchar2(60)  not null,
  name          varchar2(100) not null,
  sort_order    number(5)     not null,
  is_visible    varchar2(1)   default 'Y' not null,
  constraint sys_main_menu_section_pk primary key (id),
  constraint sys_main_menu_section_uk unique (tech_name),
  constraint sys_main_menu_section_vis_ck check (is_visible in ('Y','N'))
);

-- Об'єкти конфігурації та їх належність до розділу меню (паспорт → розділ)
create table sys_metadata_object (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  tech_name     varchar2(60)  not null,
  kind          varchar2(30)  not null,
  name          varchar2(100) not null,
  section_id    varchar2(32)  not null,
  list_page_id  number(10)    not null,
  sort_order    number(5)     not null,
  constraint sys_metadata_object_pk primary key (id),
  constraint sys_metadata_object_uk unique (tech_name),
  constraint sys_metadata_object_kind_ck check (kind in ('CATALOG','DOCUMENT','ACCUMULATION_REGISTER','INFORMATION_REGISTER','REPORT')),
  constraint sys_metadata_object_sec_fk foreign key (section_id) references sys_main_menu_section (id)
);

-- ---------------------------------------------------------------------------
-- Лічильники кодів/номерів (не перевикористовуються)
-- ---------------------------------------------------------------------------
create sequence ref_unit_of_measure_code_seq nocache;
create sequence ref_product_code_seq         nocache;
create sequence ref_warehouse_code_seq       nocache;
create sequence ref_counterparty_code_seq    nocache;
create sequence doc_goods_receipt_num_seq    nocache;
create sequence doc_supplier_payment_num_seq nocache;

-- ---------------------------------------------------------------------------
-- Довідник «Одиниці виміру» RefUnitOfMeasure
-- ---------------------------------------------------------------------------
create table ref_unit_of_measure (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  code          varchar2(9)   not null,
  name          varchar2(255) not null,
  short_name    varchar2(20)  not null,
  fractional    varchar2(1)   default 'N' not null,
  state         varchar2(20)  default 'ACTIVE' not null,
  version       number(19)    default 0 not null,
  created_at    timestamp     not null,
  created_by    varchar2(255) not null,
  updated_at    timestamp     not null,
  updated_by    varchar2(255) not null,
  constraint ref_unit_of_measure_pk primary key (id),
  constraint ref_unit_of_measure_code_uk unique (code),
  constraint ref_unit_of_measure_frac_ck check (fractional in ('Y','N')),
  constraint ref_unit_of_measure_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION'))
);
create index ref_unit_of_measure_name_ix  on ref_unit_of_measure (name);
create index ref_unit_of_measure_state_ix on ref_unit_of_measure (state);

-- ---------------------------------------------------------------------------
-- Довідник «Товари» RefProduct
-- ---------------------------------------------------------------------------
create table ref_product (
  id                  varchar2(32)  default rawtohex(sys_guid()) not null,
  code                varchar2(9)   not null,
  name                varchar2(255) not null,
  unit_of_measure_id  varchar2(32)  not null,
  state               varchar2(20)  default 'ACTIVE' not null,
  version             number(19)    default 0 not null,
  created_at          timestamp     not null,
  created_by          varchar2(255) not null,
  updated_at          timestamp     not null,
  updated_by          varchar2(255) not null,
  constraint ref_product_pk primary key (id),
  constraint ref_product_code_uk unique (code),
  constraint ref_product_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_product_uom_fk foreign key (unit_of_measure_id) references ref_unit_of_measure (id)
);
create index ref_product_name_ix  on ref_product (name);
create index ref_product_state_ix on ref_product (state);
create index ref_product_uom_ix   on ref_product (unit_of_measure_id);

-- ---------------------------------------------------------------------------
-- Довідник «Склади» RefWarehouse
-- ---------------------------------------------------------------------------
create table ref_warehouse (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  code          varchar2(9)   not null,
  name          varchar2(255) not null,
  state         varchar2(20)  default 'ACTIVE' not null,
  version       number(19)    default 0 not null,
  created_at    timestamp     not null,
  created_by    varchar2(255) not null,
  updated_at    timestamp     not null,
  updated_by    varchar2(255) not null,
  constraint ref_warehouse_pk primary key (id),
  constraint ref_warehouse_code_uk unique (code),
  constraint ref_warehouse_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION'))
);
create index ref_warehouse_name_ix  on ref_warehouse (name);
create index ref_warehouse_state_ix on ref_warehouse (state);

-- ---------------------------------------------------------------------------
-- Довідник «Контрагенти» RefCounterparty
-- ---------------------------------------------------------------------------
create table ref_counterparty (
  id            varchar2(32)  default rawtohex(sys_guid()) not null,
  code          varchar2(9)   not null,
  name          varchar2(255) not null,
  state         varchar2(20)  default 'ACTIVE' not null,
  version       number(19)    default 0 not null,
  created_at    timestamp     not null,
  created_by    varchar2(255) not null,
  updated_at    timestamp     not null,
  updated_by    varchar2(255) not null,
  constraint ref_counterparty_pk primary key (id),
  constraint ref_counterparty_code_uk unique (code),
  constraint ref_counterparty_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION'))
);
create index ref_counterparty_name_ix  on ref_counterparty (name);
create index ref_counterparty_state_ix on ref_counterparty (state);

-- ---------------------------------------------------------------------------
-- Документ «Прибуткова накладна» DocGoodsReceipt
-- ---------------------------------------------------------------------------
create table doc_goods_receipt (
  id             varchar2(32)   default rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default sysdate not null,
  supplier_id    varchar2(32)   not null,
  warehouse_id   varchar2(32)   not null,
  currency_code  varchar2(3)    default 'UAH' not null,
  total_amount   number(19,2)   default 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default 'DRAFT' not null,
  version        number(19)     default 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_goods_receipt_pk primary key (id),
  constraint doc_goods_receipt_num_uk unique (doc_number),
  constraint doc_goods_receipt_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_goods_receipt_cur_ck check (currency_code = 'UAH'),
  constraint doc_goods_receipt_sup_fk foreign key (supplier_id) references ref_counterparty (id),
  constraint doc_goods_receipt_wh_fk  foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_goods_receipt_date_ix on doc_goods_receipt (occurred_at);
create index doc_goods_receipt_sup_ix  on doc_goods_receipt (supplier_id);
create index doc_goods_receipt_wh_ix   on doc_goods_receipt (warehouse_id);

create table doc_goods_receipt_goods (
  id             varchar2(32)   default rawtohex(sys_guid()) not null,
  document_id    varchar2(32)   not null,
  line_number    number(10)     not null,
  product_id     varchar2(32)   not null,
  quantity       number(19,3)   not null,
  price          number(19,2)   not null,
  amount         number(19,2)   not null,
  constraint doc_goods_receipt_goods_pk primary key (id),
  constraint doc_goods_receipt_goods_doc_fk foreign key (document_id) references doc_goods_receipt (id) on delete cascade,
  constraint doc_goods_receipt_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_goods_receipt_goods_qty_ck check (quantity > 0),
  constraint doc_goods_receipt_goods_prc_ck check (price >= 0)
);
create index doc_goods_receipt_goods_doc_ix on doc_goods_receipt_goods (document_id, line_number);
create index doc_goods_receipt_goods_prd_ix on doc_goods_receipt_goods (product_id);

-- ---------------------------------------------------------------------------
-- Документ «Оплата постачальнику» DocSupplierPayment
-- ---------------------------------------------------------------------------
create table doc_supplier_payment (
  id             varchar2(32)   default rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default sysdate not null,
  supplier_id    varchar2(32)   not null,
  currency_code  varchar2(3)    default 'UAH' not null,
  amount         number(19,2)   not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default 'DRAFT' not null,
  version        number(19)     default 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_supplier_payment_pk primary key (id),
  constraint doc_supplier_payment_num_uk unique (doc_number),
  constraint doc_supplier_payment_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_supplier_payment_cur_ck check (currency_code = 'UAH'),
  constraint doc_supplier_payment_amt_ck check (amount > 0),
  constraint doc_supplier_payment_sup_fk foreign key (supplier_id) references ref_counterparty (id)
);
create index doc_supplier_payment_date_ix on doc_supplier_payment (occurred_at);
create index doc_supplier_payment_sup_ix  on doc_supplier_payment (supplier_id);

-- ---------------------------------------------------------------------------
-- Регістр залишків «Товари на складах» RegStockBalance
-- ---------------------------------------------------------------------------
create table reg_stock_balance_movement (
  id             varchar2(32)   default rawtohex(sys_guid()) not null,
  period         date           not null,
  recorder_type  varchar2(60)   not null,
  recorder_id    varchar2(32)   not null,
  line_number    number(10)     not null,
  warehouse_id   varchar2(32)   not null,
  product_id     varchar2(32)   not null,
  quantity       number(19,3)   not null,
  constraint reg_stock_balance_mv_pk primary key (id),
  constraint reg_stock_balance_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_stock_balance_mv_wh_fk  foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_stock_balance_mv_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_stock_balance_mv_per_ix on reg_stock_balance_movement (period);
create index reg_stock_balance_mv_key_ix on reg_stock_balance_movement (warehouse_id, product_id, period);

-- ---------------------------------------------------------------------------
-- Регістр залишків «Взаєморозрахунки» RegCounterpartySettlement
-- ---------------------------------------------------------------------------
create table reg_counterparty_settlement_mv (
  id               varchar2(32)   default rawtohex(sys_guid()) not null,
  period           date           not null,
  recorder_type    varchar2(60)   not null,
  recorder_id      varchar2(32)   not null,
  line_number      number(10)     not null,
  counterparty_id  varchar2(32)   not null,
  direction        varchar2(12)   not null,
  currency_code    varchar2(3)    not null,
  amount           number(19,2)   not null,
  constraint reg_cp_settlement_mv_pk primary key (id),
  constraint reg_cp_settlement_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_cp_settlement_mv_dir_ck check (direction in ('PAYABLE','RECEIVABLE')),
  constraint reg_cp_settlement_mv_cp_fk foreign key (counterparty_id) references ref_counterparty (id)
);
create index reg_cp_settlement_mv_per_ix on reg_counterparty_settlement_mv (period);
create index reg_cp_settlement_mv_key_ix on reg_counterparty_settlement_mv (counterparty_id, direction, currency_code, period);
