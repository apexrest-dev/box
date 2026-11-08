-- =============================================================================
-- Trade r3 — НСІ та регістри (паспорти configuration/objects/*, статус PROPOSED)
--   RefProductGroup, RefProduct r3, RefContract, RegBarcode, RegSupplierPrice,
--   RegReorderPolicy, RegStockReserve, RegCustomerOrders, RegSupplierOrders, RegStockCost
-- Відхилення від паспортів r3: похідні таблиці *_tot/*_snap не створюються —
-- залишки обчислюються з рухів (як у r1/r2); додаються окремою ревізією продуктивності.
-- =============================================================================

-- ---------------------------------------------------------------- RefProductGroup
create sequence ref_product_group_code_seq nocache;
create table ref_product_group (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  code varchar2(9) not null, name varchar2(255) not null,
  parent_id varchar2(32), sort_order number(5) default on null 0 not null,
  state varchar2(20) default on null 'ACTIVE' not null, version number(19) default on null 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint ref_product_group_pk primary key (id),
  constraint ref_product_group_code_uk unique (code),
  constraint ref_product_group_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_product_group_sort_ck check (sort_order >= 0),
  constraint ref_product_group_self_ck check (parent_id is null or parent_id <> id),
  constraint ref_product_group_parent_fk foreign key (parent_id) references ref_product_group (id)
);
create index ref_product_group_parent_ix on ref_product_group (parent_id, sort_order, name);
create index ref_product_group_state_ix on ref_product_group (state);
create unique index ref_product_group_sib_uk on ref_product_group (
  case when state = 'ACTIVE' then nvl(parent_id, '#ROOT') end,
  case when state = 'ACTIVE' then upper(name) end);

-- ---------------------------------------------------------------- RefProduct r3
alter table ref_product add (
  group_id     varchar2(32),
  product_kind varchar2(10) default on null 'GOODS' not null,
  article      varchar2(50),
  weight_kg    number(19,3),
  description  varchar2(1000));
alter table ref_product add constraint ref_product_kind_ck check (product_kind in ('GOODS','SERVICE'));
alter table ref_product add constraint ref_product_weight_ck
  check (weight_kg is null or (weight_kg >= 0 and product_kind = 'GOODS'));
alter table ref_product add constraint ref_product_group_fk foreign key (group_id) references ref_product_group (id);
create index ref_product_group_ix on ref_product (group_id);
create unique index ref_product_article_uk on ref_product (
  case when state = 'ACTIVE' and article is not null then upper(article) end);

-- ---------------------------------------------------------------- RefContract
create sequence ref_contract_code_seq nocache;
create table ref_contract (
  id varchar2(32) default on null rawtohex(sys_guid()) not null,
  owner_id varchar2(32) not null,
  code varchar2(9) not null, name varchar2(255) not null,
  contract_number varchar2(50), contract_date date,
  contract_kind varchar2(20) default on null 'WITH_CUSTOMER' not null,
  price_type_id varchar2(32),
  payment_term_days number(3) default on null 0 not null,
  credit_limit number(19,2),
  currency_code varchar2(3) default on null 'UAH' not null,
  valid_from date, valid_to date, doc_comment varchar2(1000),
  state varchar2(20) default on null 'ACTIVE' not null, version number(19) default on null 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint ref_contract_pk primary key (id),
  constraint ref_contract_code_uk unique (code),
  constraint ref_contract_kind_ck check (contract_kind in ('WITH_CUSTOMER','WITH_SUPPLIER')),
  constraint ref_contract_term_ck check (payment_term_days between 0 and 365),
  constraint ref_contract_limit_ck check (credit_limit is null or credit_limit >= 0),
  constraint ref_contract_sup_ck check (contract_kind = 'WITH_CUSTOMER' or (credit_limit is null and price_type_id is null)),
  constraint ref_contract_cur_ck check (currency_code = 'UAH'),
  constraint ref_contract_period_ck check (valid_from is null or valid_to is null or valid_from <= valid_to),
  constraint ref_contract_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')),
  constraint ref_contract_owner_fk foreign key (owner_id) references ref_counterparty (id),
  constraint ref_contract_pt_fk foreign key (price_type_id) references ref_price_type (id)
);
create index ref_contract_owner_ix on ref_contract (owner_id, contract_kind, state);

-- ---------------------------------------------------------------- RegBarcode (незалежний)
create table reg_barcode (
  id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
  barcode       varchar2(64)  not null,
  product_id    varchar2(32)  not null,
  unit_quantity number(19,3)  default on null 1 not null,
  version       number(19)    default on null 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint reg_barcode_pk primary key (id),
  constraint reg_barcode_uk unique (barcode),
  constraint reg_barcode_qty_ck check (unit_quantity > 0),
  constraint reg_barcode_chars_ck check (regexp_like(barcode, '^[!-~]{1,64}$')),
  constraint reg_barcode_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_barcode_prd_ix on reg_barcode (product_id);

-- ---------------------------------------------------------------- RegReorderPolicy (незалежний)
create table reg_reorder_policy (
  id                    varchar2(32)  default on null rawtohex(sys_guid()) not null,
  warehouse_id          varchar2(32)  not null,
  product_id            varchar2(32)  not null,
  min_quantity          number(19,3)  not null,
  max_quantity          number(19,3)  not null,
  reorder_method        varchar2(10)  default on null 'MIN_MAX' not null,
  preferred_supplier_id varchar2(32),
  lead_time_days        number(3)     default on null 0 not null,
  version number(19) default on null 0 not null,
  created_at timestamp not null, created_by varchar2(255) not null,
  updated_at timestamp not null, updated_by varchar2(255) not null,
  constraint reg_reorder_policy_pk primary key (id),
  constraint reg_reorder_policy_uk unique (warehouse_id, product_id),
  constraint reg_reorder_policy_min_ck check (min_quantity >= 0),
  constraint reg_reorder_policy_max_ck check (max_quantity >= 0),
  constraint reg_reorder_policy_mm_ck check (min_quantity <= max_quantity),
  constraint reg_reorder_policy_method_ck check (reorder_method in ('MIN_MAX','NONE')),
  constraint reg_reorder_policy_lead_ck check (lead_time_days between 0 and 365),
  constraint reg_reorder_policy_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
  constraint reg_reorder_policy_prd_fk foreign key (product_id) references ref_product (id),
  constraint reg_reorder_policy_sup_fk foreign key (preferred_supplier_id) references ref_counterparty (id)
);

-- ---------------------------------------------------------------- RegSupplierPrice (періодичний, реєстратор)
create table reg_supplier_price (
  id             varchar2(32)  default on null rawtohex(sys_guid()) not null,
  period         date          not null,
  recorder_type  varchar2(60)  not null,
  recorder_id    varchar2(32)  not null,
  line_number    number(10)    not null,
  supplier_id    varchar2(32)  not null,
  product_id     varchar2(32)  not null,
  price          number(19,2)  not null,
  constraint reg_supplier_price_pk primary key (id),
  constraint reg_supplier_price_rec_uk unique (recorder_type, recorder_id, line_number),
  constraint reg_supplier_price_prc_ck check (price >= 0),
  constraint reg_supplier_price_sup_fk foreign key (supplier_id) references ref_counterparty (id),
  constraint reg_supplier_price_prd_fk foreign key (product_id) references ref_product (id)
);
create index reg_supplier_price_key_ix on reg_supplier_price (supplier_id, product_id, period);
