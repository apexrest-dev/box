-- =============================================================================
-- Trade r3 — документи (замовлення, повернення, інвентаризація, надлишки, рахунки),
-- регістри залишків r3, зміни документів r1/r2. Згенеровано за паспортами r3.
-- =============================================================================

create sequence doc_customer_order_num_seq nocache;
create table doc_customer_order (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  customer_id    varchar2(32)   not null,
  contract_id    varchar2(32),
  warehouse_id   varchar2(32)   not null,
  price_type_id  varchar2(32),
  shipment_date  date,
  closed         varchar2(1)    default on null 'N' not null,
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_customer_order_pk primary key (id),
  constraint doc_customer_order_num_uk unique (doc_number),
  constraint doc_customer_order_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_customer_order_cus_fk foreign key (customer_id) references ref_counterparty (id),
  constraint doc_customer_order_ctr_fk foreign key (contract_id) references ref_contract (id),
  constraint doc_customer_order_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint doc_customer_order_pt_fk foreign key (price_type_id) references ref_price_type (id),
  constraint doc_customer_order_closed_ck check (closed in ('Y','N'))
);
create index doc_customer_order_date_ix on doc_customer_order (occurred_at);
create table doc_customer_order_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity         number(19,3)  not null,
  price            number(19,2)  not null,
  discount_percent number(5,2)   default on null 0 not null,
  amount           number(19,2)  default on null 0 not null,
  reserve_flag     varchar2(1)   default on null 'N' not null,
  constraint doc_customer_order_goods_pk primary key (id),
  constraint doc_customer_order_goods_doc_fk foreign key (document_id) references doc_customer_order (id) on delete cascade,
  constraint doc_customer_order_goods_prd_fk foreign key (product_id) references ref_product (id)
);
create index doc_customer_order_goods_doc_ix on doc_customer_order_goods (document_id, line_number);
create index doc_customer_order_goods_prd_ix on doc_customer_order_goods (product_id);

create sequence doc_supplier_order_num_seq nocache;
create table doc_supplier_order (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  supplier_id    varchar2(32)   not null,
  contract_id    varchar2(32),
  warehouse_id   varchar2(32)   not null,
  expected_date  date,
  closed         varchar2(1)    default on null 'N' not null,
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_supplier_order_pk primary key (id),
  constraint doc_supplier_order_num_uk unique (doc_number),
  constraint doc_supplier_order_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_supplier_order_sup_fk foreign key (supplier_id) references ref_counterparty (id),
  constraint doc_supplier_order_ctr_fk foreign key (contract_id) references ref_contract (id),
  constraint doc_supplier_order_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint doc_supplier_order_closed_ck check (closed in ('Y','N'))
);
create index doc_supplier_order_date_ix on doc_supplier_order (occurred_at);
create table doc_supplier_order_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_supplier_order_goods_pk primary key (id),
  constraint doc_supplier_order_goods_doc_fk foreign key (document_id) references doc_supplier_order (id) on delete cascade,
  constraint doc_supplier_order_goods_prd_fk foreign key (product_id) references ref_product (id)
);
create index doc_supplier_order_goods_doc_ix on doc_supplier_order_goods (document_id, line_number);
create index doc_supplier_order_goods_prd_ix on doc_supplier_order_goods (product_id);

create sequence doc_customer_return_num_seq nocache;
create table doc_customer_return (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  base_sale_id   varchar2(32)   not null,
  customer_id    varchar2(32)   not null,
  contract_id    varchar2(32),
  warehouse_id   varchar2(32)   not null,
  return_reason  varchar2(255),
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_customer_return_pk primary key (id),
  constraint doc_customer_return_num_uk unique (doc_number),
  constraint doc_customer_return_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_customer_return_base_fk foreign key (base_sale_id) references doc_goods_sale (id),
  constraint doc_customer_return_cus_fk foreign key (customer_id) references ref_counterparty (id),
  constraint doc_customer_return_ctr_fk foreign key (contract_id) references ref_contract (id),
  constraint doc_customer_return_wh_fk foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_customer_return_date_ix on doc_customer_return (occurred_at);
create table doc_customer_return_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  base_sale_line_id varchar2(32) not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_customer_return_goods_pk primary key (id),
  constraint doc_customer_return_goods_doc_fk foreign key (document_id) references doc_customer_return (id) on delete cascade,
  constraint doc_customer_return_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_customer_return_goods_bl_fk foreign key (base_sale_line_id) references doc_goods_sale_goods (id)
);
create index doc_customer_return_goods_doc_ix on doc_customer_return_goods (document_id, line_number);
create index doc_customer_return_goods_prd_ix on doc_customer_return_goods (product_id);

create sequence doc_supplier_return_num_seq nocache;
create table doc_supplier_return (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  base_receipt_id varchar2(32)  not null,
  supplier_id    varchar2(32)   not null,
  contract_id    varchar2(32),
  warehouse_id   varchar2(32)   not null,
  return_reason  varchar2(255)  not null,
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_supplier_return_pk primary key (id),
  constraint doc_supplier_return_num_uk unique (doc_number),
  constraint doc_supplier_return_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_supplier_return_base_fk foreign key (base_receipt_id) references doc_goods_receipt (id),
  constraint doc_supplier_return_sup_fk foreign key (supplier_id) references ref_counterparty (id),
  constraint doc_supplier_return_ctr_fk foreign key (contract_id) references ref_contract (id),
  constraint doc_supplier_return_wh_fk foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_supplier_return_date_ix on doc_supplier_return (occurred_at);
create table doc_supplier_return_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  base_receipt_line_id varchar2(32) not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_supplier_return_goods_pk primary key (id),
  constraint doc_supplier_return_goods_doc_fk foreign key (document_id) references doc_supplier_return (id) on delete cascade,
  constraint doc_supplier_return_goods_prd_fk foreign key (product_id) references ref_product (id),
  constraint doc_supplier_return_goods_bl_fk foreign key (base_receipt_line_id) references doc_goods_receipt_goods (id)
);
create index doc_supplier_return_goods_doc_ix on doc_supplier_return_goods (document_id, line_number);
create index doc_supplier_return_goods_prd_ix on doc_supplier_return_goods (product_id);

create sequence doc_inventory_count_num_seq nocache;
create table doc_inventory_count (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  warehouse_id   varchar2(32)   not null,
  responsible_person varchar2(255),
  surplus_amount  number(19,2)  default on null 0 not null,
  shortage_amount number(19,2)  default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_inventory_count_pk primary key (id),
  constraint doc_inventory_count_num_uk unique (doc_number),
  constraint doc_inventory_count_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_inventory_count_wh_fk foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_inventory_count_date_ix on doc_inventory_count (occurred_at);
create table doc_inventory_count_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  book_quantity    number(19,3)  default on null 0 not null,
  actual_quantity  number(19,3),
  deviation        number(19,3),
  price            number(19,2)  default on null 0 not null,
  deviation_amount number(19,2),
  constraint doc_inventory_count_goods_pk primary key (id),
  constraint doc_inventory_count_goods_doc_fk foreign key (document_id) references doc_inventory_count (id) on delete cascade,
  constraint doc_inventory_count_goods_prd_fk foreign key (product_id) references ref_product (id)
);
create index doc_inventory_count_goods_doc_ix on doc_inventory_count_goods (document_id, line_number);
create index doc_inventory_count_goods_prd_ix on doc_inventory_count_goods (product_id);

create sequence doc_surplus_posting_num_seq nocache;
create table doc_surplus_posting (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  base_inventory_id varchar2(32),
  warehouse_id   varchar2(32)   not null,
  reason         varchar2(255)  not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_surplus_posting_pk primary key (id),
  constraint doc_surplus_posting_num_uk unique (doc_number),
  constraint doc_surplus_posting_status_ck check (status in ('DRAFT','POSTED')),
  constraint doc_surplus_posting_base_fk foreign key (base_inventory_id) references doc_inventory_count (id),
  constraint doc_surplus_posting_wh_fk foreign key (warehouse_id) references ref_warehouse (id)
);
create index doc_surplus_posting_date_ix on doc_surplus_posting (occurred_at);
create table doc_surplus_posting_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_surplus_posting_goods_pk primary key (id),
  constraint doc_surplus_posting_goods_doc_fk foreign key (document_id) references doc_surplus_posting (id) on delete cascade,
  constraint doc_surplus_posting_goods_prd_fk foreign key (product_id) references ref_product (id)
);
create index doc_surplus_posting_goods_doc_ix on doc_surplus_posting_goods (document_id, line_number);
create index doc_surplus_posting_goods_prd_ix on doc_surplus_posting_goods (product_id);

create sequence doc_invoice_for_payment_num_seq nocache;
create table doc_invoice_for_payment (
  id             varchar2(32)   default on null rawtohex(sys_guid()) not null,
  doc_number     varchar2(9)    not null,
  occurred_at    date           default on null sysdate not null,
  base_order_id  varchar2(32),
  customer_id    varchar2(32)   not null,
  contract_id    varchar2(32),
  payment_due_date date,
  cancel_reason  varchar2(255),
  currency_code  varchar2(3)    default on null 'UAH' not null,
  total_amount   number(19,2)   default on null 0 not null,
  doc_comment    varchar2(1000),
  status         varchar2(10)   default on null 'DRAFT' not null,
  version        number(19)     default on null 0 not null,
  created_at     timestamp      not null,
  created_by     varchar2(255)  not null,
  updated_at     timestamp      not null,
  updated_by     varchar2(255)  not null,
  constraint doc_invoice_for_payment_pk primary key (id),
  constraint doc_invoice_for_payment_num_uk unique (doc_number),
  constraint doc_invoice_for_payment_status_ck check (status in ('DRAFT','ISSUED','CANCELLED')),
  constraint doc_invoice_for_payment_base_fk foreign key (base_order_id) references doc_customer_order (id),
  constraint doc_invoice_for_payment_cus_fk foreign key (customer_id) references ref_counterparty (id),
  constraint doc_invoice_for_payment_ctr_fk foreign key (contract_id) references ref_contract (id)
);
create index doc_invoice_for_payment_date_ix on doc_invoice_for_payment (occurred_at);
create table doc_invoice_for_payment_goods (
  id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
  document_id  varchar2(32)  not null,
  line_number  number(10)    default on null 999999 not null,
  product_id   varchar2(32)  not null,
  quantity     number(19,3)  not null,
  price        number(19,2)  not null,
  amount       number(19,2)  default on null 0 not null,
  constraint doc_invoice_for_payment_goods_pk primary key (id),
  constraint doc_invoice_for_payment_goods_doc_fk foreign key (document_id) references doc_invoice_for_payment (id) on delete cascade,
  constraint doc_invoice_for_payment_goods_prd_fk foreign key (product_id) references ref_product (id)
);
create index doc_invoice_for_payment_goods_doc_ix on doc_invoice_for_payment_goods (document_id, line_number);
create index doc_invoice_for_payment_goods_prd_ix on doc_invoice_for_payment_goods (product_id);

-- Зміни документів r1/r2
alter table doc_goods_sale add (contract_id varchar2(32), base_order_id varchar2(32));
alter table doc_goods_sale add constraint doc_goods_sale_ctr_fk foreign key (contract_id) references ref_contract (id);
alter table doc_goods_sale add constraint doc_goods_sale_ord_fk foreign key (base_order_id) references doc_customer_order (id);
alter table doc_goods_receipt add (contract_id varchar2(32), base_order_id varchar2(32));
alter table doc_goods_receipt add constraint doc_goods_receipt_ctr_fk foreign key (contract_id) references ref_contract (id);
alter table doc_goods_receipt add constraint doc_goods_receipt_ord_fk foreign key (base_order_id) references doc_supplier_order (id);
alter table doc_goods_write_off add (base_inventory_id varchar2(32));
alter table doc_goods_write_off add constraint doc_goods_write_off_inv_fk foreign key (base_inventory_id) references doc_inventory_count (id);

-- Регістри залишків r3
create table reg_stock_reserve_mv (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  period date not null, recorder_type varchar2(60) not null, recorder_id varchar2(32) not null, line_number number(10) not null,
  warehouse_id varchar2(32) not null, product_id varchar2(32) not null, customer_order_id varchar2(32) not null,
  quantity number(19,3) not null,
  constraint reg_stock_reserve_mv_pk primary key (id),
  constraint reg_stock_reserve_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_stock_reserve_mv_qty_ck check (quantity <> 0),
  constraint reg_stock_reserve_mv_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_stock_reserve_mv_prd_fk foreign key (product_id) references ref_product (id),
  constraint reg_stock_reserve_mv_ord_fk foreign key (customer_order_id) references doc_customer_order (id)
);
create index reg_stock_reserve_mv_key_ix on reg_stock_reserve_mv (warehouse_id, product_id, customer_order_id);
create index reg_stock_reserve_mv_ord_ix on reg_stock_reserve_mv (customer_order_id);

create table reg_customer_orders_mv (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  period date not null, recorder_type varchar2(60) not null, recorder_id varchar2(32) not null, line_number number(10) not null,
  customer_order_id varchar2(32) not null, product_id varchar2(32) not null,
  quantity number(19,3) not null, amount number(19,2) not null,
  constraint reg_customer_orders_mv_pk primary key (id),
  constraint reg_customer_orders_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_customer_orders_mv_ord_fk foreign key (customer_order_id) references doc_customer_order (id),
  constraint reg_customer_orders_mv_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_customer_orders_mv_key_ix on reg_customer_orders_mv (customer_order_id, product_id);

create table reg_supplier_orders_mv (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  period date not null, recorder_type varchar2(60) not null, recorder_id varchar2(32) not null, line_number number(10) not null,
  supplier_order_id varchar2(32) not null, product_id varchar2(32) not null,
  quantity number(19,3) not null, amount number(19,2) not null,
  constraint reg_supplier_orders_mv_pk primary key (id),
  constraint reg_supplier_orders_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_supplier_orders_mv_ord_fk foreign key (supplier_order_id) references doc_supplier_order (id),
  constraint reg_supplier_orders_mv_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_supplier_orders_mv_key_ix on reg_supplier_orders_mv (supplier_order_id, product_id);

create sequence reg_stock_cost_posting_seq nocache;
create table reg_stock_cost_mv (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  period date not null, recorder_type varchar2(60) not null, recorder_id varchar2(32) not null, line_number number(10) not null,
  posting_seq number(19) not null,
  warehouse_id varchar2(32) not null, product_id varchar2(32) not null,
  quantity number(19,3) not null, cost_amount number(19,2) not null,
  constraint reg_stock_cost_mv_pk primary key (id),
  constraint reg_stock_cost_mv_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_stock_cost_mv_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_stock_cost_mv_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_stock_cost_mv_key_ix on reg_stock_cost_mv (warehouse_id, product_id, period, posting_seq);

-- Реквізити підприємства (друк рахунку, мінімальна націнка)
create table sys_company_settings (
  id varchar2(1) default on null 'X' not null,
  name varchar2(255) not null, edrpou varchar2(10), iban varchar2(34), bank_name varchar2(255),
  address varchar2(500), phone varchar2(50), director_name varchar2(255), accountant_name varchar2(255),
  min_markup_percent number(5,2) default on null 0 not null,
  constraint sys_company_settings_pk primary key (id),
  constraint sys_company_settings_one_ck check (id = 'X')
);
