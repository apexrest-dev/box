-- =============================================================================
-- Trade r2 — ціноутворення, продажі, складські операції
-- Паспорти: configuration/objects/{RefPriceType, RegProductPrice, DocPriceSetting,
--   DocGoodsSale, DocCustomerPayment, DocGoodsTransfer, DocGoodsWriteOff, RegSales}
-- =============================================================================

create sequence ref_price_type_code_seq       nocache;
create sequence doc_price_setting_num_seq     nocache;
create sequence doc_goods_sale_num_seq        nocache;
create sequence doc_customer_payment_num_seq  nocache;
create sequence doc_goods_transfer_num_seq    nocache;
create sequence doc_goods_write_off_num_seq   nocache;

-- Довідник «Види цін» RefPriceType
create table ref_price_type (
  id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
  code          varchar2(9)   not null,
  name          varchar2(255) not null,
  currency_code varchar2(3)   default on null 'UAH' not null,
  state         varchar2(20)  default on null 'ACTIVE' not null,
  version       number(19)    default on null 0 not null,
  created_at    timestamp     not null,
  created_by    varchar2(255) not null,
  updated_at    timestamp     not null,
  updated_by    varchar2(255) not null,
  constraint ref_price_type_pk primary key (id),
  constraint ref_price_type_code_uk unique (code),
  constraint ref_price_type_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_price_type_cur_ck check (currency_code = 'UAH')
);
create index ref_price_type_name_ix on ref_price_type (name);

-- Документ «Встановлення цін номенклатури» DocPriceSetting
create table doc_price_setting (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  price_type_id  varchar2(32)   not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_price_setting_pk primary key (id),
  constraint doc_price_setting_num_uk unique (doc_number),
  constraint doc_price_setting_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_price_setting_pt_fk foreign key (price_type_id) references ref_price_type (id)
);
create index doc_price_setting_date_ix on doc_price_setting (occurred_at);

create table doc_price_setting_prices (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  price        number(19,2)  not null,
  constraint doc_price_setting_prices_pk primary key (id),
  constraint doc_price_setting_prices_doc_fk foreign key (document_id) references doc_price_setting (id) on delete cascade,
  constraint doc_price_setting_prices_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_price_setting_prices_prc_ck check (price >= 0)
);
create index doc_price_setting_prices_doc_ix on doc_price_setting_prices (document_id, line_number);

-- Періодичний регістр відомостей «Ціни номенклатури» RegProductPrice
create table reg_product_price (
  id             varchar2(32)  default on null rawtohex(sys_guid()) not null,
  period         date          not null,
  recorder_type  varchar2(60)  not null,
  recorder_id    varchar2(32)  not null,
  line_number    number(10)    not null,
  price_type_id  varchar2(32)  not null,
  product_id     varchar2(32)  not null,
  price          number(19,2)  not null,
  constraint reg_product_price_pk primary key (id),
  constraint reg_product_price_rec_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_product_price_pt_fk foreign key (price_type_id) references ref_price_type (id),
  constraint reg_product_price_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_product_price_key_ix on reg_product_price (price_type_id, product_id, period);

-- Документ «Реалізація товарів» DocGoodsSale
create table doc_goods_sale (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  customer_id    varchar2(32)   not null,
  warehouse_id   varchar2(32)   not null,
  price_type_id  varchar2(32),
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_goods_sale_pk primary key (id),
  constraint doc_goods_sale_num_uk unique (doc_number),
  constraint doc_goods_sale_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_goods_sale_cur_ck check (currency_code = 'UAH'),
  constraint doc_goods_sale_cus_fk foreign key (customer_id) references ref_counterparty (id),
  constraint doc_goods_sale_wh_fk  foreign key (warehouse_id) references ref_warehouse (id),
  constraint doc_goods_sale_pt_fk  foreign key (price_type_id) references ref_price_type (id)
);
create index doc_goods_sale_date_ix on doc_goods_sale (occurred_at);
create index doc_goods_sale_cus_ix  on doc_goods_sale (customer_id);

create table doc_goods_sale_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_goods_sale_goods_pk primary key (id),
  constraint doc_goods_sale_goods_doc_fk foreign key (document_id) references doc_goods_sale (id) on delete cascade,
  constraint doc_goods_sale_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_goods_sale_goods_qty_ck check (quantity > 0),
  constraint doc_goods_sale_goods_prc_ck check (price >= 0)
);
create index doc_goods_sale_goods_doc_ix on doc_goods_sale_goods (document_id, line_number);

-- Документ «Оплата від покупця» DocCustomerPayment
create table doc_customer_payment (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  customer_id    varchar2(32)   not null,
  currency_code  varchar2(3)    default on null 'UAH' not null,
  amount         number(19,2)   not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_customer_payment_pk primary key (id),
  constraint doc_customer_payment_num_uk unique (doc_number),
  constraint doc_customer_payment_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_customer_payment_cur_ck check (currency_code = 'UAH'),
  constraint doc_customer_payment_amt_ck check (amount > 0),
  constraint doc_customer_payment_cus_fk foreign key (customer_id) references ref_counterparty (id)
);
create index doc_customer_payment_date_ix on doc_customer_payment (occurred_at);

-- Документ «Переміщення товарів» DocGoodsTransfer
create table doc_goods_transfer (
  id                 varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number         varchar2(9)    not null,
  occurred_at        date           default on null sysdate not null,
  warehouse_from_id  varchar2(32)   not null,
  warehouse_to_id    varchar2(32)   not null,
  doc_comment        varchar2(1000),
  status             varchar2(10)   default on null 'DRAFT' not null,
  version            number(19)     default on null 0 not null,
  created_at         timestamp      not null,
  created_by         varchar2(255)  not null,
  updated_at         timestamp      not null,
  updated_by         varchar2(255)  not null,
  constraint doc_goods_transfer_pk primary key (id),
  constraint doc_goods_transfer_num_uk unique (doc_number),
  constraint doc_goods_transfer_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_goods_transfer_wh_ck check (warehouse_from_id <> warehouse_to_id),
  constraint doc_goods_transfer_from_fk foreign key (warehouse_from_id) references ref_warehouse (id),
  constraint doc_goods_transfer_to_fk   foreign key (warehouse_to_id) references ref_warehouse (id)
);
create index doc_goods_transfer_date_ix on doc_goods_transfer (occurred_at);

create table doc_goods_transfer_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  constraint doc_goods_transfer_goods_pk primary key (id),
  constraint doc_goods_transfer_goods_doc_fk foreign key (document_id) references doc_goods_transfer (id) on delete cascade,
  constraint doc_goods_transfer_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_goods_transfer_goods_qty_ck check (quantity > 0)
);
create index doc_goods_transfer_goods_doc_ix on doc_goods_transfer_goods (document_id, line_number);

-- Документ «Списання товарів» DocGoodsWriteOff
create table doc_goods_write_off (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  warehouse_id   varchar2(32)   not null,
  reason         varchar2(255)  not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_goods_write_off_pk primary key (id),
  constraint doc_goods_write_off_num_uk unique (doc_number),
  constraint doc_goods_write_off_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_goods_write_off_wh_fk foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_goods_write_off_date_ix on doc_goods_write_off (occurred_at);

create table doc_goods_write_off_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  constraint doc_goods_write_off_goods_pk primary key (id),
  constraint doc_goods_write_off_goods_doc_fk foreign key (document_id) references doc_goods_write_off (id) on delete cascade,
  constraint doc_goods_write_off_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_goods_write_off_goods_qty_ck check (quantity > 0)
);
create index doc_goods_write_off_goods_doc_ix on doc_goods_write_off_goods (document_id, line_number);

-- Регістр оборотів «Продажі» RegSales
create table reg_sales_turnover (
  id               varchar2(32)  default on null rawtohex(sys_guid()) not null,
  period           date          not null,
  recorder_type    varchar2(60)  not null,
  recorder_id      varchar2(32)  not null,
  line_number      number(10)    not null,
  counterparty_id  varchar2(32)  not null,
  warehouse_id     varchar2(32)  not null,
  product_id       varchar2(32)  not null,
  quantity         number(19,3)  not null,
  amount           number(19,2)  not null,
  constraint reg_sales_turnover_pk primary key (id),
  constraint reg_sales_turnover_rec_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_sales_turnover_cp_fk  foreign key (counterparty_id) references ref_counterparty (id),
  constraint reg_sales_turnover_wh_fk  foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_sales_turnover_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_sales_turnover_per_ix on reg_sales_turnover (period);
create index reg_sales_turnover_key_ix on reg_sales_turnover (product_id, counterparty_id, period);
