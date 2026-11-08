-- =============================================================================
-- Trade r5 — F-WH-11 «Ордерна схема, комірки» (APE-65). Паспорти DocGoodsReceiptOrder,
-- DocGoodsIssueOrder, RefStorageBin, RegGoodsOrderScheme, RegBinStock (PROPOSED).
--   * склад: ознаки «Ордерна схема» (use_order_scheme) і «Адресне зберігання (комірки)»
--     (use_storage_bins, лише за ордерною схемою; вмикається за нульового залишку складу);
--   * довідник ref_storage_bin «Комірки складу»: склад, стелаж-ярус-місце, адреса (порожня —
--     «стелаж-ярус-місце»), унікальна в межах складу;
--   * регістр reg_goods_order_mv «Товари до надходження / до відвантаження»: рухи документів
--     менеджера на ордерному складі (надходження, повернення, переміщення, комплектація, реалізація,
--     списання …) +кількість за підставою; складські ордери −кількість. Пишеться тригером
--     reg_stock_balance_mv_ord з рухів «Товари на складах» — пакети проведення не змінено;
--     склади без ордерної схеми працюють як раніше. Інвентаризація й документи на її підставі —
--     без ордерів (фактичний стан);
--   * документи «Прибутковий ордер на товари» (doc_goods_receipt_order) і «Видатковий ордер на
--     товари» (doc_goods_issue_order): склад, розпорядження (документ-підстава з товарами до
--     приймання / відвантаження), комірка, рядки товар × характеристика × серія × кількість ×
--     комірка; «Заповнити за розпорядженням» (видатковий — відбір по комірках з залишком),
--     сканер штрихкодів; проведення — контроль «не більше, ніж очікується», фактичного залишку
--     (облік − до надходження + до відвантаження) і залишку комірки;
--   * регістр reg_bin_stock_mv «Товари в комірках» (склади з адресним зберіганням);
--   * документ менеджера, за яким проведено ордери, не можна скасувати / перепровести;
--   * розпорядження на відвантаження — проведені видаткові документи менеджера на ордерному
--     складі; стан «До відбору» / «Відвантажено частково» / «Відвантажено» (v_goods_order_basis);
--   * меню «Склад → Ордерний склад», робоче місце комірника (сторінка 590), v_recorder (+2).
-- Потребує 02, 24, 37, 38. Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено (усі реєстратори r1–r5).
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefWarehouse: ознаки
  ddl(q'[alter table ref_warehouse add (use_order_scheme varchar2(1) default on null 'N' not null,
                                       use_storage_bins varchar2(1) default on null 'N' not null)]');
  ddl(q'[alter table ref_warehouse add constraint ref_warehouse_orders_ck check (use_order_scheme in ('Y','N'))]');
  ddl(q'[alter table ref_warehouse add constraint ref_warehouse_bins_ck check (use_storage_bins in ('Y','N'))]');
  ddl(q'[alter table ref_warehouse add constraint ref_warehouse_bins_ord_ck check (use_storage_bins = 'N' or use_order_scheme = 'Y')]');

  -- ---------------------------------------------------------------- RefStorageBin
  ddl('create sequence ref_storage_bin_code_seq nocache');
  ddl(q'[create table ref_storage_bin (
    id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code         varchar2(9)   not null,
    warehouse_id varchar2(32)  not null,
    rack         varchar2(20),
    tier         varchar2(20),
    place        varchar2(20),
    name         varchar2(100) not null,
    description  varchar2(1000),
    state        varchar2(20)  default on null 'ACTIVE' not null,
    version      number(19)    default on null 0 not null,
    created_at   timestamp     not null, created_by varchar2(255) not null,
    updated_at   timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_storage_bin_pk primary key (id),
    constraint ref_storage_bin_code_uk unique (code),
    constraint ref_storage_bin_name_uk unique (warehouse_id, name),
    constraint ref_storage_bin_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint ref_storage_bin_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');

  -- ---------------------------------------------------------------- DocGoodsReceiptOrder / DocGoodsIssueOrder
  for t in (select column_value tab from table(sys.odcivarchar2list('DOC_GOODS_RECEIPT_ORDER', 'DOC_GOODS_ISSUE_ORDER'))) loop
    ddl('create sequence ' || t.tab || '_NUM_SEQ nocache');
    ddl('create table ' || t.tab || q'[ (
      id              varchar2(32)   default on null rawtohex(sys_guid()) not null,
      doc_number      varchar2(9)    not null,
      occurred_at     date           default on null sysdate not null,
      organization_id varchar2(32)   not null,
      warehouse_id    varchar2(32)   not null,
      basis_type      varchar2(60),
      basis_id        varchar2(32),
      bin_id          varchar2(32),
      doc_comment     varchar2(1000),
      status          varchar2(10)   default on null 'DRAFT' not null,
      version         number(19)     default on null 0 not null,
      created_at      timestamp      not null,
      created_by      varchar2(255)  not null,
      updated_at      timestamp      not null,
      updated_by      varchar2(255)  not null,
      constraint ]' || t.tab || q'[_pk primary key (id),
      constraint ]' || t.tab || q'[_num_uk unique (doc_number),
      constraint ]' || t.tab || q'[_st_ck check (status in ('DRAFT','POSTED')),
      constraint ]' || t.tab || q'[_org_fk foreign key (organization_id) references ref_organization (id),
      constraint ]' || t.tab || q'[_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
      constraint ]' || t.tab || q'[_bin_fk foreign key (bin_id) references ref_storage_bin (id))]');
    ddl('create index ' || t.tab || '_basis_ix on ' || t.tab || ' (basis_id)');
    ddl('create index ' || t.tab || '_date_ix on ' || t.tab || ' (occurred_at)');
    ddl('create table ' || t.tab || q'[_GOODS (
      id                varchar2(32)  default on null rawtohex(sys_guid()) not null,
      document_id       varchar2(32)  not null,
      line_number       number(10)    default on null 0 not null,
      product_id        varchar2(32)  not null,
      characteristic_id varchar2(32),
      series_id         varchar2(32),
      quantity          number(19,3)  not null,
      bin_id            varchar2(32),
      constraint ]' || t.tab || q'[_g_pk primary key (id),
      constraint ]' || t.tab || q'[_g_doc_fk foreign key (document_id) references ]' || t.tab || q'[ (id) on delete cascade,
      constraint ]' || t.tab || q'[_g_prd_fk foreign key (product_id) references ref_product (id),
      constraint ]' || t.tab || q'[_g_chr_fk foreign key (characteristic_id) references ref_product_characteristic (id),
      constraint ]' || t.tab || q'[_g_ser_fk foreign key (series_id) references ref_product_series (id),
      constraint ]' || t.tab || q'[_g_bin_fk foreign key (bin_id) references ref_storage_bin (id),
      constraint ]' || t.tab || q'[_g_qty_ck check (quantity > 0))]');
    ddl('create index ' || t.tab || '_g_doc_ix on ' || t.tab || '_GOODS (document_id, line_number)');
  end loop;

  -- ---------------------------------------------------------------- RegGoodsOrderScheme
  ddl(q'[create table reg_goods_order_mv (
    id                varchar2(32)  default on null rawtohex(sys_guid()) not null,
    period            date          not null,
    recorder_type     varchar2(60)  not null,
    recorder_id       varchar2(32)  not null,
    line_number       number(10)    not null,
    direction         varchar2(10)  not null,
    warehouse_id      varchar2(32)  not null,
    basis_type        varchar2(60)  not null,
    basis_id          varchar2(32)  not null,
    product_id        varchar2(32)  not null,
    characteristic_id varchar2(32),
    series_id         varchar2(32),
    quantity          number(19,3)  not null,
    constraint reg_goods_order_mv_pk primary key (id),
    constraint reg_goods_order_mv_uk unique (recorder_type, recorder_id, line_number),
    constraint reg_goods_order_mv_dir_ck check (direction in ('RECEIPT','SHIPMENT')),
    constraint reg_goods_order_mv_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint reg_goods_order_mv_prd_fk foreign key (product_id) references ref_product (id))]');
  ddl('create index reg_goods_order_mv_basis_ix on reg_goods_order_mv (basis_id, direction, warehouse_id)');
  ddl('create index reg_goods_order_mv_key_ix on reg_goods_order_mv (warehouse_id, product_id)');

  -- ---------------------------------------------------------------- RegBinStock
  ddl(q'[create table reg_bin_stock_mv (
    id                varchar2(32)  default on null rawtohex(sys_guid()) not null,
    period            date          not null,
    recorder_type     varchar2(60)  not null,
    recorder_id       varchar2(32)  not null,
    line_number       number(10)    not null,
    warehouse_id      varchar2(32)  not null,
    bin_id            varchar2(32)  not null,
    product_id        varchar2(32)  not null,
    characteristic_id varchar2(32),
    series_id         varchar2(32),
    quantity          number(19,3)  not null,
    constraint reg_bin_stock_mv_pk primary key (id),
    constraint reg_bin_stock_mv_uk unique (recorder_type, recorder_id, line_number),
    constraint reg_bin_stock_mv_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint reg_bin_stock_mv_bin_fk foreign key (bin_id) references ref_storage_bin (id),
    constraint reg_bin_stock_mv_prd_fk foreign key (product_id) references ref_product (id))]');
  ddl('create index reg_bin_stock_mv_key_ix on reg_bin_stock_mv (bin_id, product_id)');
  ddl('create index reg_bin_stock_mv_wh_ix on reg_bin_stock_mv (warehouse_id, product_id)');
end;
/

-- ---------------------------------------------------------------- пакет (специфікація)
create or replace package trade_order_scheme as
  c_receipt constant varchar2(60) := 'DocGoodsReceiptOrder';
  c_issue   constant varchar2(60) := 'DocGoodsIssueOrder';
  -- Вид ордера = напрям регістру: RECEIPT (прибутковий, до надходження) / SHIPMENT (видатковий, до відвантаження)

  function order_type (p_kind in varchar2) return varchar2;
  function direction_name (p_dir in varchar2) return varchar2;
  function uses_orders (p_wh in varchar2) return varchar2;
  function uses_bins (p_wh in varchar2) return varchar2;

  -- ---------- склад і комірки
  procedure check_warehouse (p_inserting in boolean, p_id in varchar2, p_orders in out varchar2, p_old_orders in varchar2,
                             p_bins in out varchar2, p_old_bins in varchar2);
  procedure check_bin (p_inserting in boolean, p_id in varchar2, p_wh in varchar2, p_old_wh in varchar2,
                       p_rack in out varchar2, p_tier in out varchar2, p_place in out varchar2, p_name in out varchar2);
  function bin_label (p_bin_id in varchar2) return varchar2;
  -- Залишок у комірці (порожній товар — усі товари)
  function bin_qty (p_bin_id in varchar2, p_product_id in varchar2 default null, p_char_id in varchar2 default null,
                    p_series_id in varchar2 default null, p_any_dims in varchar2 default 'Y') return number;

  -- ---------- регістр «Товари до надходження / до відвантаження» (тригер reg_stock_balance_mv_ord)
  procedure stock_moved (p_type in varchar2, p_id in varchar2, p_line in number, p_period in date, p_wh in varchar2,
                         p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2, p_qty in number);
  procedure stock_unmoved (p_type in varchar2, p_id in varchar2, p_line in number, p_wh in varchar2);
  -- Очікується за підставою (порожня підстава — усі); p_excl_id — без рухів цього ордера
  function pending_qty (p_dir in varchar2, p_wh in varchar2, p_basis_id in varchar2, p_product_id in varchar2,
                        p_char_id in varchar2, p_series_id in varchar2, p_excl_id in varchar2 default null) return number;
  -- Фактичний залишок ордерного складу = облік − до надходження + до відвантаження
  function physical_qty (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2) return number;
  -- Стан розпорядження: WAITING / PARTIAL / DONE
  function basis_state (p_dir in varchar2, p_wh in varchar2, p_basis_id in varchar2) return varchar2;
  function state_name (p_dir in varchar2, p_state in varchar2) return varchar2;

  -- ---------- ордери
  procedure check_header (p_kind in varchar2, p_inserting in boolean, p_wh in varchar2, p_old_wh in varchar2,
                          p_basis_id in varchar2, p_old_basis_id in varchar2, p_basis_type in out varchar2, p_bin_id in varchar2);
  procedure check_line (p_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_char_id in out varchar2,
                        p_series_id in out varchar2, p_qty in number, p_bin_id in varchar2, p_check_ref in boolean, p_check_bin in boolean);
  procedure fill_from_basis (p_kind in varchar2, p_id in varchar2);
  -- Створити ордер за розпорядженням (порожній склад — склад з товарами до приймання / відвантаження)
  function create_order (p_kind in varchar2, p_basis_id in varchar2, p_wh in varchar2 default null) return varchar2;
  -- Робоче місце: ключ завдання 'RECEIPT-<склад>-<підстава>' (v_goods_order_basis.task_key)
  function create_task (p_key in varchar2) return varchar2;
  procedure post   (p_kind in varchar2, p_id in varchar2);
  procedure unpost (p_kind in varchar2, p_id in varchar2);
  function  copy   (p_kind in varchar2, p_id in varchar2) return varchar2;
  -- Сканер: штрихкод / артикул → рядок ордера (ключ з розпорядження)
  procedure scan (p_kind in varchar2, p_id in varchar2, p_text in varchar2);
  -- Очікувана кількість ключа рядка (без рухів самого ордера)
  function line_expected (p_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2,
                          p_char_id in varchar2, p_series_id in varchar2) return number;

  -- Друк: RECEIPT_ORDER / ISSUE_ORDER — прибутковий / видатковий ордер на товари
  function print_html (p_form in varchar2, p_id in varchar2) return clob;

  -- обгортки для сторінок (генератор викликає proc(:P_ID))
  procedure post_receipt   (p_id in varchar2);
  procedure unpost_receipt (p_id in varchar2);
  function  copy_receipt   (p_id in varchar2) return varchar2;
  procedure post_issue     (p_id in varchar2);
  procedure unpost_issue   (p_id in varchar2);
  function  copy_issue     (p_id in varchar2) return varchar2;
end trade_order_scheme;
/

-- ---------------------------------------------------------------- представлення (до тіла пакета)
create or replace view v_goods_order_header as
select 'RECEIPT' kind, 'DocGoodsReceiptOrder' doc_type, d.id, d.doc_number, d.occurred_at, d.organization_id, d.warehouse_id,
       d.basis_type, d.basis_id, d.bin_id, d.status, d.doc_comment, d.created_by
  from doc_goods_receipt_order d
union all
select 'SHIPMENT', 'DocGoodsIssueOrder', d.id, d.doc_number, d.occurred_at, d.organization_id, d.warehouse_id,
       d.basis_type, d.basis_id, d.bin_id, d.status, d.doc_comment, d.created_by
  from doc_goods_issue_order d;

create or replace view v_goods_order_line as
select 'RECEIPT' kind, g.id, g.document_id, g.line_number, g.product_id, g.characteristic_id, g.series_id, g.quantity, g.bin_id
  from doc_goods_receipt_order_goods g
union all
select 'SHIPMENT', g.id, g.document_id, g.line_number, g.product_id, g.characteristic_id, g.series_id, g.quantity, g.bin_id
  from doc_goods_issue_order_goods g;

-- ---------------------------------------------------------------- тіло пакета
create or replace package body trade_order_scheme as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function q (p number) return varchar2 is begin return rtrim(to_char(p, 'FM999G999G990D999'), '.,'); end;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_product where id = p_id;
    return l;
  end prd_name;

  function wh_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_warehouse where id = p_id;
    return l;
  end wh_name;

  function key_text (p_product_id varchar2, p_char_id varchar2, p_series_id varchar2) return varchar2 is
  begin
    return '«' || prd_name(p_product_id) || '»'
      || case when p_char_id is not null then ', характеристика «' || trade_series.char_label(p_char_id) || '»' end
      || case when p_series_id is not null then ', серія «' || trade_series.series_label(p_series_id) || '»' end;
  end key_text;

  function basis_name (p_type varchar2, p_id varchar2) return varchar2 is
    l varchar2(400);
  begin
    select max(recorder_name) into l from v_recorder where recorder_type = p_type and recorder_id = p_id;
    return coalesce(l, p_type);
  end basis_name;

  function hdr_table (p_kind varchar2) return varchar2 is
  begin
    return case p_kind when 'RECEIPT' then 'DOC_GOODS_RECEIPT_ORDER' when 'SHIPMENT' then 'DOC_GOODS_ISSUE_ORDER'
           else null end;
  end hdr_table;

  function order_type (p_kind in varchar2) return varchar2 is
  begin
    return case p_kind when 'RECEIPT' then c_receipt when 'SHIPMENT' then c_issue end;
  end order_type;

  function direction_name (p_dir in varchar2) return varchar2 is
  begin
    return case p_dir when 'RECEIPT' then 'До надходження' when 'SHIPMENT' then 'До відвантаження' end;
  end direction_name;

  function uses_orders (p_wh in varchar2) return varchar2 is
    l varchar2(1);
  begin
    select max(use_order_scheme) into l from ref_warehouse where id = p_wh;
    return nvl(l, 'N');
  end uses_orders;

  function uses_bins (p_wh in varchar2) return varchar2 is
    l varchar2(1);
  begin
    select max(use_storage_bins) into l from ref_warehouse where id = p_wh;
    return nvl(l, 'N');
  end uses_bins;

  procedure require_kind (p_kind varchar2) is
  begin
    if hdr_table(p_kind) is null then
      fail('ORDER_KIND', 'Невідомий вид складського ордера: ' || p_kind || '.');
    end if;
  end require_kind;

  -- =========================================================== склад і комірки
  procedure check_warehouse (p_inserting in boolean, p_id in varchar2, p_orders in out varchar2, p_old_orders in varchar2,
                             p_bins in out varchar2, p_old_bins in varchar2) is
    l_cnt pls_integer;
  begin
    p_orders := nvl(p_orders, 'N'); p_bins := nvl(p_bins, 'N');
    if p_bins = 'Y' and p_orders = 'N' then
      fail('STORAGE_BINS_REQUIRE_ORDERS', 'Адресне зберігання (комірки) можливе лише для складу з ордерною схемою.');
    end if;
    if p_inserting then return; end if;
    if nvl(p_old_orders, 'N') = 'Y' and p_orders = 'N' then
      select count(*) into l_cnt from (select 1 from reg_goods_order_mv where warehouse_id = p_id
                                        group by direction, basis_id, product_id, characteristic_id, series_id
                                       having sum(quantity) <> 0);
      if l_cnt = 0 then
        select count(*) into l_cnt from v_goods_order_header where warehouse_id = p_id and status = 'DRAFT';
      end if;
      if l_cnt > 0 then
        fail('ORDER_SCHEME_IN_USE', 'Ордерну схему не можна вимкнути: на складі є товари до надходження / відвантаження '
             || 'або чернетки складських ордерів. Оформіть або видаліть їх.');
      end if;
    end if;
    if nvl(p_old_bins, 'N') = 'N' and p_bins = 'Y' then
      select count(*) into l_cnt from (select 1 from reg_stock_balance_movement where warehouse_id = p_id
                                        group by product_id having sum(quantity) <> 0);
      if l_cnt > 0 then
        fail('STORAGE_BINS_STOCK_NOT_ZERO', 'Адресне зберігання вмикається лише за нульового залишку товарів на складі.');
      end if;
    elsif nvl(p_old_bins, 'N') = 'Y' and p_bins = 'N' then
      select count(*) into l_cnt from (select 1 from reg_bin_stock_mv where warehouse_id = p_id
                                        group by bin_id, product_id, characteristic_id, series_id having sum(quantity) <> 0);
      if l_cnt > 0 then
        fail('STORAGE_BINS_IN_USE', 'Адресне зберігання не можна вимкнути: у комірках є товари.');
      end if;
    end if;
  end check_warehouse;

  procedure check_bin (p_inserting in boolean, p_id in varchar2, p_wh in varchar2, p_old_wh in varchar2,
                       p_rack in out varchar2, p_tier in out varchar2, p_place in out varchar2, p_name in out varchar2) is
    l_cnt pls_integer;
  begin
    if p_inserting or p_wh <> nvl(p_old_wh, '-') then
      trade_core.check_active_ref('REF_WAREHOUSE', p_wh, 'Склад');
    end if;
    if not p_inserting and p_wh <> p_old_wh then
      select count(*) into l_cnt from reg_bin_stock_mv where bin_id = p_id;
      if l_cnt > 0 then
        fail('STORAGE_BIN_IN_USE', 'Склад комірки не можна змінити: за коміркою є рухи товарів.');
      end if;
    end if;
    p_rack := upper(trim(p_rack)); p_tier := upper(trim(p_tier)); p_place := upper(trim(p_place));
    p_name := upper(trim(p_name));
    if p_name is null then
      if p_rack is null then
        fail('STORAGE_BIN_ADDRESS', 'Вкажіть адресу комірки або стелаж (ярус, місце).');
      end if;
      p_name := p_rack || case when p_tier is not null then '-' || p_tier end || case when p_place is not null then '-' || p_place end;
    end if;
    p_name := trade_core.normalize_name(p_name, 100, 'Адреса');   -- унікальність у складі: ref_storage_bin_name_uk
  end check_bin;

  function bin_label (p_bin_id in varchar2) return varchar2 is
    l varchar2(400);
  begin
    if p_bin_id is null then return null; end if;
    select max(b.name) into l from ref_storage_bin b where b.id = p_bin_id;
    return l;
  end bin_label;

  function bin_qty (p_bin_id in varchar2, p_product_id in varchar2 default null, p_char_id in varchar2 default null,
                    p_series_id in varchar2 default null, p_any_dims in varchar2 default 'Y') return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_bin_stock_mv
     where bin_id = p_bin_id
       and (p_product_id is null or product_id = p_product_id)
       and (p_any_dims = 'Y' or (decode(characteristic_id, p_char_id, 1, 0) = 1 and decode(series_id, p_series_id, 1, 0) = 1));
    return l;
  end bin_qty;

  -- =========================================================== регістр
  procedure stock_moved (p_type in varchar2, p_id in varchar2, p_line in number, p_period in date, p_wh in varchar2,
                         p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2, p_qty in number) is
    l_inv varchar2(32);
  begin
    if p_qty = 0 or uses_orders(p_wh) = 'N' then return; end if;
    -- результати інвентаризації відображають фактичний стан — без ордерів
    if p_type = 'DocInventoryCount' then return; end if;
    if p_type = 'DocSurplusPosting' then
      select max(base_inventory_id) into l_inv from doc_surplus_posting where id = p_id;
    elsif p_type = 'DocGoodsWriteOff' then
      select max(base_inventory_id) into l_inv from doc_goods_write_off where id = p_id;
    end if;
    if l_inv is not null then return; end if;
    insert into reg_goods_order_mv (period, recorder_type, recorder_id, line_number, direction, warehouse_id,
                                    basis_type, basis_id, product_id, characteristic_id, series_id, quantity)
    values (p_period, p_type, p_id, p_line, case when p_qty > 0 then 'RECEIPT' else 'SHIPMENT' end, p_wh,
            p_type, p_id, p_product_id, p_char_id, p_series_id, abs(p_qty));
  end stock_moved;

  procedure stock_unmoved (p_type in varchar2, p_id in varchar2, p_line in number, p_wh in varchar2) is
    l_list varchar2(1000);
  begin
    delete from reg_goods_order_mv where recorder_type = p_type and recorder_id = p_id and line_number = p_line;
    if sql%rowcount > 0 then
      select listagg(case kind when 'RECEIPT' then 'прибутковий' else 'видатковий' end || ' ордер № ' || doc_number, ', ')
               within group (order by doc_number)
        into l_list
        from v_goods_order_header where basis_id = p_id and warehouse_id = p_wh and status = 'POSTED';
      if l_list is not null then
        fail('ORDER_BASIS_HAS_ORDERS', 'За документом на складі «' || wh_name(p_wh) || '» проведено складські ордери ('
             || l_list || '). Спочатку скасуйте проведення ордерів.');
      end if;
    end if;
  end stock_unmoved;

  function pending_qty (p_dir in varchar2, p_wh in varchar2, p_basis_id in varchar2, p_product_id in varchar2,
                        p_char_id in varchar2, p_series_id in varchar2, p_excl_id in varchar2 default null) return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_goods_order_mv
     where direction = p_dir and warehouse_id = p_wh and product_id = p_product_id
       and (p_basis_id is null or basis_id = p_basis_id)
       and decode(characteristic_id, p_char_id, 1, 0) = 1 and decode(series_id, p_series_id, 1, 0) = 1
       and (p_excl_id is null or recorder_id <> p_excl_id);
    return l;
  end pending_qty;

  function physical_qty (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2) return number is
  begin
    return trade_series.balance(p_wh, p_product_id, p_char_id, p_series_id)
         - pending_qty('RECEIPT', p_wh, null, p_product_id, p_char_id, p_series_id)
         + pending_qty('SHIPMENT', p_wh, null, p_product_id, p_char_id, p_series_id);
  end physical_qty;

  function basis_state (p_dir in varchar2, p_wh in varchar2, p_basis_id in varchar2) return varchar2 is
    l_rem number; l_done number;
  begin
    select coalesce(sum(case when rem > 0 then rem end), 0), coalesce(sum(done), 0) into l_rem, l_done
      from (select sum(quantity) rem, sum(case when quantity < 0 then -quantity else 0 end) done
              from reg_goods_order_mv where direction = p_dir and warehouse_id = p_wh and basis_id = p_basis_id
             group by product_id, characteristic_id, series_id);
    return case when l_rem = 0 then 'DONE' when l_done > 0 then 'PARTIAL' else 'WAITING' end;
  end basis_state;

  function state_name (p_dir in varchar2, p_state in varchar2) return varchar2 is
  begin
    return case p_dir
      when 'RECEIPT' then case p_state when 'WAITING' then 'Очікується приймання' when 'PARTIAL' then 'Прийнято частково'
                                       when 'DONE' then 'Прийнято' end
      else case p_state when 'WAITING' then 'До відбору' when 'PARTIAL' then 'Відвантажено частково'
                        when 'DONE' then 'Відвантажено' end end;
  end state_name;

  -- =========================================================== ордери: перевірки
  procedure check_header (p_kind in varchar2, p_inserting in boolean, p_wh in varchar2, p_old_wh in varchar2,
                          p_basis_id in varchar2, p_old_basis_id in varchar2, p_basis_type in out varchar2, p_bin_id in varchar2) is
    l_wh varchar2(32); l_state varchar2(20);
  begin
    if p_inserting or p_wh <> nvl(p_old_wh, '-') then
      trade_core.check_active_ref('REF_WAREHOUSE', p_wh, 'Склад');
      if uses_orders(p_wh) = 'N' then
        fail('ORDER_SCHEME_NOT_USED', 'Склад «' || wh_name(p_wh) || '» не використовує ордерну схему. '
             || 'Увімкніть ознаку «Ордерна схема» в картці складу.');
      end if;
    end if;
    if p_basis_id is null then
      fail('ORDER_BASIS_REQUIRED', 'Вкажіть розпорядження — документ-підставу з товарами '
           || case p_kind when 'RECEIPT' then 'до надходження.' else 'до відвантаження.' end);
    end if;
    if p_inserting or p_basis_id <> nvl(p_old_basis_id, '-') or p_wh <> nvl(p_old_wh, '-') or p_basis_type is null then
      select max(basis_type) into p_basis_type from reg_goods_order_mv
       where basis_id = p_basis_id and recorder_id = p_basis_id and direction = p_kind and warehouse_id = p_wh;
      if p_basis_type is null then
        fail('ORDER_BASIS_INVALID', 'Документ-підстава не містить товарів '
             || case p_kind when 'RECEIPT' then 'до надходження' else 'до відвантаження' end
             || ' на складі «' || wh_name(p_wh) || '» (документ не проведено або склад без ордерної схеми).');
      end if;
    end if;
    if p_bin_id is not null then
      select max(warehouse_id), max(state) into l_wh, l_state from ref_storage_bin where id = p_bin_id;
      if l_wh is null or l_wh <> p_wh then
        fail('STORAGE_BIN_OTHER_WAREHOUSE', 'Комірка «' || bin_label(p_bin_id) || '» не належить складу «' || wh_name(p_wh) || '».');
      elsif l_state <> 'ACTIVE' and not trade_core.g_internal then
        fail('STORAGE_BIN_NOT_ACTIVE', 'Комірка «' || bin_label(p_bin_id) || '» помічена на видалення.');
      end if;
    end if;
  end check_header;

  procedure check_line (p_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_char_id in out varchar2,
                        p_series_id in out varchar2, p_qty in number, p_bin_id in varchar2, p_check_ref in boolean, p_check_bin in boolean) is
    l_wh varchar2(32); l_bwh varchar2(32); l_state varchar2(20);
  begin
    trade_lines.check_goods_r3(p_product_id, p_qty, p_check_ref, true);
    trade_series.check_line(p_product_id, p_char_id, p_series_id);
    if p_check_bin and p_bin_id is not null then
      select max(warehouse_id) into l_wh from v_goods_order_header where kind = p_kind and id = p_doc_id;
      select max(warehouse_id), max(state) into l_bwh, l_state from ref_storage_bin where id = p_bin_id;
      if l_bwh is null or l_bwh <> l_wh then
        fail('STORAGE_BIN_OTHER_WAREHOUSE', 'Комірка «' || bin_label(p_bin_id) || '» не належить складу ордера.');
      elsif l_state <> 'ACTIVE' and not trade_core.g_internal then
        fail('STORAGE_BIN_NOT_ACTIVE', 'Комірка «' || bin_label(p_bin_id) || '» помічена на видалення.');
      end if;
    end if;
  end check_line;

  -- =========================================================== ордери: команди
  procedure lock_draft (p_kind varchar2, p_id varchar2, h out v_goods_order_header%rowtype, p_need_draft boolean default true) is
    l varchar2(32);
  begin
    require_kind(p_kind);
    execute immediate 'select id from ' || hdr_table(p_kind) || ' where id = :i for update' into l using p_id;
    select * into h from v_goods_order_header where kind = p_kind and id = p_id;
    if p_need_draft and h.status <> 'DRAFT' then
      fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
    end if;
  end lock_draft;

  procedure add_line (p_kind varchar2, p_doc_id varchar2, p_ln number, p_product_id varchar2, p_char_id varchar2,
                      p_series_id varchar2, p_qty number, p_bin_id varchar2) is
  begin
    execute immediate 'insert into ' || hdr_table(p_kind) || '_goods (document_id, line_number, product_id, characteristic_id, '
      || 'series_id, quantity, bin_id) values (:d, :n, :p, :c, :s, :q, :b)'
      using p_doc_id, p_ln, p_product_id, p_char_id, p_series_id, p_qty, p_bin_id;
  end add_line;

  procedure fill_from_basis (p_kind in varchar2, p_id in varchar2) is
    h v_goods_order_header%rowtype;
    l_ln number := 0; l_left number; l_take number;
  begin
    lock_draft(p_kind, p_id, h);
    execute immediate 'delete from ' || hdr_table(p_kind) || '_goods where document_id = :d' using p_id;
    for k in (select product_id, characteristic_id, series_id, sum(quantity) rem, min(case when quantity > 0 then line_number end) ln
                from reg_goods_order_mv
               where direction = p_kind and warehouse_id = h.warehouse_id and basis_id = h.basis_id and recorder_id <> p_id
               group by product_id, characteristic_id, series_id
              having sum(quantity) > 0
               order by 5, 1) loop
      l_left := k.rem;
      if p_kind = 'SHIPMENT' and uses_bins(h.warehouse_id) = 'Y' then
        -- відбір: комірки з залишком ключа, за адресою
        for b in (select m.bin_id, sum(m.quantity) bal from reg_bin_stock_mv m join ref_storage_bin s on s.id = m.bin_id
                   where m.warehouse_id = h.warehouse_id and m.product_id = k.product_id
                     and decode(m.characteristic_id, k.characteristic_id, 1, 0) = 1 and decode(m.series_id, k.series_id, 1, 0) = 1
                   group by m.bin_id, s.name having sum(m.quantity) > 0 order by s.name) loop
          exit when l_left <= 0;
          l_take := least(l_left, b.bal);
          l_ln := l_ln + 1;
          add_line(p_kind, p_id, l_ln, k.product_id, k.characteristic_id, k.series_id, l_take, b.bin_id);
          l_left := l_left - l_take;
        end loop;
      end if;
      if l_left > 0 then
        l_ln := l_ln + 1;
        add_line(p_kind, p_id, l_ln, k.product_id, k.characteristic_id, k.series_id, l_left,
                 case when p_kind = 'RECEIPT' then h.bin_id end);
      end if;
    end loop;
    if l_ln = 0 then
      fail('ORDER_NOTHING_PENDING', 'За розпорядженням «' || basis_name(h.basis_type, h.basis_id) || '» немає товарів '
           || case p_kind when 'RECEIPT' then 'до надходження.' else 'до відвантаження.' end);
    end if;
    trade_core.audit(order_type(p_kind), p_id, 'FILL_FROM_BASIS', h.basis_type || ' ' || h.basis_id);
  end fill_from_basis;

  function create_order (p_kind in varchar2, p_basis_id in varchar2, p_wh in varchar2 default null) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
    l_wh varchar2(32) := p_wh;
  begin
    require_kind(p_kind);
    if l_wh is null then
      select max(warehouse_id) keep (dense_rank first order by min(line_number)) into l_wh
        from reg_goods_order_mv where basis_id = p_basis_id and direction = p_kind
       group by warehouse_id having sum(quantity) > 0;
    end if;
    if l_wh is null then
      fail('ORDER_NOTHING_PENDING', 'За документом немає товарів '
           || case p_kind when 'RECEIPT' then 'до надходження' else 'до відвантаження' end
           || ' за ордерною схемою (документ не проведено, склад без ордерної схеми або ордери вже оформлено).');
    end if;
    execute immediate 'insert into ' || hdr_table(p_kind) || ' (id, occurred_at, warehouse_id, basis_id) values (:i, sysdate, :w, :b)'
      using l_new, l_wh, p_basis_id;
    fill_from_basis(p_kind, l_new);
    trade_core.audit(order_type(p_kind), l_new, 'CREATE_BASED_ON', p_basis_id);
    return l_new;
  end create_order;

  function create_task (p_key in varchar2) return varchar2 is
  begin
    if p_key is null then
      fail('ORDER_TASK_REQUIRED', 'Виберіть розпорядження зі списку завдань.');
    end if;
    return create_order(regexp_substr(p_key, '[^-]+', 1, 1), regexp_substr(p_key, '[^-]+', 1, 3), regexp_substr(p_key, '[^-]+', 1, 2));
  end create_task;

  procedure delete_movements (p_kind varchar2, p_id varchar2) is
  begin
    delete from reg_goods_order_mv where recorder_type = order_type(p_kind) and recorder_id = p_id;
    delete from reg_bin_stock_mv where recorder_type = order_type(p_kind) and recorder_id = p_id;
  end delete_movements;

  procedure check_physical (h v_goods_order_header%rowtype, p_unpost boolean) is
    l number;
  begin
    for k in (select distinct product_id, characteristic_id, series_id from v_goods_order_line
               where kind = h.kind and document_id = h.id) loop
      l := physical_qty(h.warehouse_id, k.product_id, k.characteristic_id, k.series_id);
      if l < 0 then
        fail('ORDER_PHYSICAL_STOCK', 'Товару ' || key_text(k.product_id, k.characteristic_id, k.series_id)
             || ' фактично немає на складі «' || wh_name(h.warehouse_id) || '»: не вистачає ' || q(-l)
             || case when p_unpost then ' (прийнятий товар уже відвантажено).'
                     else ' (товар ще не прийнято прибутковим ордером).' end);
      end if;
    end loop;
  end check_physical;

  procedure check_bins (h v_goods_order_header%rowtype) is
    l number;
  begin
    for k in (select distinct bin_id, product_id, characteristic_id, series_id from v_goods_order_line
               where kind = h.kind and document_id = h.id and bin_id is not null) loop
      l := bin_qty(k.bin_id, k.product_id, k.characteristic_id, k.series_id, 'N');
      if l < 0 then
        fail('BIN_STOCK_INSUFFICIENT', 'У комірці «' || bin_label(k.bin_id) || '» недостатньо товару '
             || key_text(k.product_id, k.characteristic_id, k.series_id) || ': не вистачає ' || q(-l) || '.');
      end if;
    end loop;
  end check_bins;

  procedure post (p_kind in varchar2, p_id in varchar2) is
    h v_goods_order_header%rowtype;
    l_cnt pls_integer; l_rem number; l_bins varchar2(1); l_chr varchar2(32); l_ser varchar2(32);
    l_tab varchar2(30);
  begin
    lock_draft(p_kind, p_id, h, false);
    l_tab := hdr_table(p_kind) || '_GOODS';
    select count(*) into l_cnt from v_goods_order_line where kind = p_kind and document_id = p_id;
    if l_cnt = 0 then
      fail('NO_LINES', 'Неможливо провести ордер без рядків. Скористайтеся «Заповнити за розпорядженням» або сканером.');
    end if;
    if uses_orders(h.warehouse_id) = 'N' then
      fail('ORDER_SCHEME_NOT_USED', 'Склад «' || wh_name(h.warehouse_id) || '» не використовує ордерну схему.');
    end if;
    trade_core.g_internal := true;
    -- рядки без характеристики / серії: єдиний очікуваний ключ товару за розпорядженням
    for l in (select g.id, g.product_id from v_goods_order_line g join ref_product p on p.id = g.product_id
               where g.kind = p_kind and g.document_id = p_id and g.characteristic_id is null and g.series_id is null
                 and (p.use_characteristics = 'Y' or p.use_series = 'Y')) loop
      select max(characteristic_id), max(series_id), count(*) into l_chr, l_ser, l_cnt
        from (select characteristic_id, series_id from reg_goods_order_mv
               where direction = p_kind and warehouse_id = h.warehouse_id and basis_id = h.basis_id
                 and product_id = l.product_id and recorder_id <> p_id
               group by characteristic_id, series_id having sum(quantity) > 0);
      if l_cnt = 1 then
        execute immediate 'update ' || l_tab || ' set characteristic_id = :c, series_id = :s where id = :i' using l_chr, l_ser, l.id;
      end if;
    end loop;
    l_bins := uses_bins(h.warehouse_id);
    if l_bins = 'Y' then
      if p_kind = 'RECEIPT' and h.bin_id is not null then
        execute immediate 'update ' || l_tab || ' set bin_id = :b where document_id = :d and bin_id is null' using h.bin_id, p_id;
      end if;
      for l in (select line_number, product_id from v_goods_order_line
                 where kind = p_kind and document_id = p_id and bin_id is null order by line_number) loop
        fail('ORDER_BIN_REQUIRED', 'Рядок ' || l.line_number || ': вкажіть комірку '
             || case p_kind when 'RECEIPT' then 'розміщення' else 'відбору' end || ' товару «' || prd_name(l.product_id)
             || '» (склад з адресним зберіганням).');
      end loop;
    end if;
    delete_movements(p_kind, p_id);
    insert into reg_goods_order_mv (period, recorder_type, recorder_id, line_number, direction, warehouse_id,
                                    basis_type, basis_id, product_id, characteristic_id, series_id, quantity)
    select h.occurred_at, order_type(p_kind), p_id, line_number, p_kind, h.warehouse_id, h.basis_type, h.basis_id,
           product_id, characteristic_id, series_id, -quantity
      from v_goods_order_line where kind = p_kind and document_id = p_id;
    for k in (select distinct product_id, characteristic_id, series_id from v_goods_order_line
               where kind = p_kind and document_id = p_id) loop
      l_rem := pending_qty(p_kind, h.warehouse_id, h.basis_id, k.product_id, k.characteristic_id, k.series_id);
      if l_rem < 0 then
        fail('ORDER_EXCEEDS_BASIS', 'Товар ' || key_text(k.product_id, k.characteristic_id, k.series_id)
             || ': кількість в ордері перевищує очікувану ' || case p_kind when 'RECEIPT' then 'до надходження' else 'до відвантаження' end
             || ' за розпорядженням «' || basis_name(h.basis_type, h.basis_id) || '» на ' || q(-l_rem) || '.');
      end if;
    end loop;
    if l_bins = 'Y' then
      insert into reg_bin_stock_mv (period, recorder_type, recorder_id, line_number, warehouse_id, bin_id, product_id,
                                    characteristic_id, series_id, quantity)
      select h.occurred_at, order_type(p_kind), p_id, line_number, h.warehouse_id, bin_id, product_id, characteristic_id, series_id,
             case p_kind when 'RECEIPT' then quantity else -quantity end
        from v_goods_order_line where kind = p_kind and document_id = p_id;
      if p_kind = 'SHIPMENT' then check_bins(h); end if;
    end if;
    if p_kind = 'SHIPMENT' then check_physical(h, false); end if;
    execute immediate 'update ' || hdr_table(p_kind) || ' set status = ''POSTED'' where id = :i' using p_id;
    trade_core.g_internal := false;
    trade_core.audit(order_type(p_kind), p_id, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post;

  procedure unpost (p_kind in varchar2, p_id in varchar2) is
    h v_goods_order_header%rowtype;
  begin
    lock_draft(p_kind, p_id, h, false);
    if h.status <> 'POSTED' then
      fail('NOT_POSTED', 'Документ не проведено.');
    end if;
    trade_core.g_internal := true;
    delete_movements(p_kind, p_id);
    if p_kind = 'RECEIPT' then
      check_physical(h, true);
      check_bins(h);
    end if;
    execute immediate 'update ' || hdr_table(p_kind) || ' set status = ''DRAFT'' where id = :i' using p_id;
    trade_core.g_internal := false;
    trade_core.audit(order_type(p_kind), p_id, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost;

  function copy (p_kind in varchar2, p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
    l_tab varchar2(30);
  begin
    require_kind(p_kind);
    l_tab := hdr_table(p_kind);
    execute immediate 'insert into ' || l_tab || ' (id, occurred_at, organization_id, warehouse_id, basis_id, bin_id, doc_comment) '
      || 'select :n, sysdate, organization_id, warehouse_id, basis_id, bin_id, doc_comment from ' || l_tab || ' where id = :i'
      using l_new, p_id;
    execute immediate 'insert into ' || l_tab || '_goods (document_id, line_number, product_id, characteristic_id, series_id, quantity, bin_id) '
      || 'select :n, line_number, product_id, characteristic_id, series_id, quantity, bin_id from ' || l_tab || '_goods where document_id = :i'
      using l_new, p_id;
    trade_core.audit(order_type(p_kind), l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy;

  procedure scan (p_kind in varchar2, p_id in varchar2, p_text in varchar2) is
    h v_goods_order_header%rowtype;
    l_prd varchar2(32); l_qty number; l_line varchar2(32); l_tab varchar2(30); l_ln number; l_bin varchar2(32);
  begin
    if trim(p_text) is null then return; end if;
    lock_draft(p_kind, p_id, h);
    l_tab := hdr_table(p_kind) || '_GOODS';
    l_prd := trade_nsi.lookup_product(trim(p_text));
    if l_prd is null then
      fail('BARCODE_NOT_FOUND', 'Товар зі штрихкодом/артикулом «' || trim(p_text) || '» не знайдено.');
    end if;
    l_qty := coalesce(trade_nsi.lookup_barcode_qty(trim(p_text)), 1);
    -- 1) рядок товару, де ще не набрано очікуване
    select max(g.id) keep (dense_rank first order by g.line_number) into l_line
      from v_goods_order_line g
     where g.kind = p_kind and g.document_id = p_id and g.product_id = l_prd
       and g.quantity < pending_qty(p_kind, h.warehouse_id, h.basis_id, g.product_id, g.characteristic_id, g.series_id, p_id)
           - (select coalesce(sum(o.quantity), 0) from v_goods_order_line o
               where o.kind = p_kind and o.document_id = p_id and o.id <> g.id and o.product_id = g.product_id
                 and decode(o.characteristic_id, g.characteristic_id, 1, 0) = 1 and decode(o.series_id, g.series_id, 1, 0) = 1);
    if l_line is null then
      -- 2) очікуваний ключ товару, якого ще немає в рядках
      for k in (select m.characteristic_id, m.series_id from reg_goods_order_mv m
                 where m.direction = p_kind and m.warehouse_id = h.warehouse_id and m.basis_id = h.basis_id
                   and m.product_id = l_prd and m.recorder_id <> p_id
                   and not exists (select 1 from v_goods_order_line g where g.kind = p_kind and g.document_id = p_id
                                      and g.product_id = l_prd and decode(g.characteristic_id, m.characteristic_id, 1, 0) = 1
                                      and decode(g.series_id, m.series_id, 1, 0) = 1)
                 group by m.characteristic_id, m.series_id having sum(m.quantity) > 0
                 order by min(m.line_number)) loop
        select coalesce(max(line_number), 0) + 1 into l_ln from v_goods_order_line where kind = p_kind and document_id = p_id;
        l_bin := case when p_kind = 'RECEIPT' then h.bin_id end;
        if p_kind = 'SHIPMENT' and uses_bins(h.warehouse_id) = 'Y' then
          select max(m.bin_id) keep (dense_rank first order by s.name) into l_bin
            from reg_bin_stock_mv m join ref_storage_bin s on s.id = m.bin_id
           where m.warehouse_id = h.warehouse_id and m.product_id = l_prd
             and decode(m.characteristic_id, k.characteristic_id, 1, 0) = 1 and decode(m.series_id, k.series_id, 1, 0) = 1
             and (select sum(x.quantity) from reg_bin_stock_mv x where x.bin_id = m.bin_id and x.product_id = l_prd
                    and decode(x.characteristic_id, k.characteristic_id, 1, 0) = 1 and decode(x.series_id, k.series_id, 1, 0) = 1) > 0;
        end if;
        add_line(p_kind, p_id, l_ln, l_prd, k.characteristic_id, k.series_id, l_qty, l_bin);
        return;
      end loop;
      -- 3) перший рядок товару (перевищення покаже проведення) або новий рядок
      select max(g.id) keep (dense_rank first order by g.line_number) into l_line
        from v_goods_order_line g where g.kind = p_kind and g.document_id = p_id and g.product_id = l_prd;
    end if;
    if l_line is not null then
      execute immediate 'update ' || l_tab || ' set quantity = quantity + :q where id = :i' using l_qty, l_line;
    else
      select coalesce(max(line_number), 0) + 1 into l_ln from v_goods_order_line where kind = p_kind and document_id = p_id;
      add_line(p_kind, p_id, l_ln, l_prd, null, null, l_qty, case when p_kind = 'RECEIPT' then h.bin_id end);
    end if;
  end scan;

  function line_expected (p_kind in varchar2, p_doc_id in varchar2, p_product_id in varchar2,
                          p_char_id in varchar2, p_series_id in varchar2) return number is
    l_wh varchar2(32); l_basis varchar2(32);
  begin
    select max(warehouse_id), max(basis_id) into l_wh, l_basis from v_goods_order_header where kind = p_kind and id = p_doc_id;
    if l_basis is null or p_product_id is null then return null; end if;
    return pending_qty(p_kind, l_wh, l_basis, p_product_id, p_char_id, p_series_id, p_doc_id);
  end line_expected;

  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    l_kind varchar2(10) := case p_form when 'RECEIPT_ORDER' then 'RECEIPT' when 'ISSUE_ORDER' then 'SHIPMENT' end;
    l_total number := 0;
    function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  begin
    if l_kind is null then return null; end if;
    for r in (select * from v_goods_order_header where kind = l_kind and id = p_id) loop
      select * into o from ref_organization where id = r.organization_id;
      l := '<div class="tx-print"><style>'
        || '.tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1100px;background:#fff;padding:16px;position:relative}'
        || '.tx-print h2{font-size:17px;text-align:center;margin:10px 0 4px}.tx-print .sub{text-align:center;margin-bottom:12px}'
        || '.tx-print table{border-collapse:collapse;width:100%;margin-bottom:10px}'
        || '.tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}'
        || '.tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}.tx-print .tot td{font-weight:bold}'
        || '.tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}'
        || '.tx-print .signs{display:flex;gap:40px;margin-top:24px}.tx-print .signs>div{flex:1}'
        || '.tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}'
        || '@media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}}</style>'
        || case when r.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<h2>' || case l_kind when 'RECEIPT' then 'Прибутковий' else 'Видатковий' end || ' ордер на товари № ' || e(r.doc_number)
        || '</h2><div class="sub">від ' || to_char(r.occurred_at, 'DD.MM.YYYY') || '</div>'
        || '<table class="grid"><tr><th style="width:25%">Організація</th><td><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
        || case when o.edrpou is not null then '<br>Код ЄДРПОУ ' || e(o.edrpou) end || '</td></tr>'
        || '<tr><th>Склад</th><td>' || e(wh_name(r.warehouse_id)) || '</td></tr>'
        || '<tr><th>Розпорядження</th><td>' || e(basis_name(r.basis_type, r.basis_id)) || '</td></tr>'
        || case when r.bin_id is not null then '<tr><th>Комірка розміщення</th><td>' || e(bin_label(r.bin_id)) || '</td></tr>' end
        || '</table><table class="grid"><tr><th>№</th><th>Товар</th><th>Характеристика / серія</th><th>Од.</th><th>Комірка</th>'
        || '<th>Кількість</th></tr>';
      for g in (select g.line_number, p.name, u.short_name, g.quantity, g.bin_id, g.characteristic_id, g.series_id
                  from v_goods_order_line g join ref_product p on p.id = g.product_id
                  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
                 where g.kind = l_kind and g.document_id = p_id order by g.line_number) loop
        l := l || '<tr><td class="c">' || g.line_number || '</td><td>' || e(g.name) || '</td><td>'
               || e(trim(both ' ' from trade_series.char_label(g.characteristic_id) || ' ' || trade_series.series_label(g.series_id)))
               || '</td><td class="c">' || e(g.short_name) || '</td><td class="c">' || e(bin_label(g.bin_id))
               || '</td><td class="r">' || q(g.quantity) || '</td></tr>';
        l_total := l_total + g.quantity;
      end loop;
      l := l || '<tr class="tot"><td colspan="5" class="r">Разом</td><td class="r">' || q(l_total) || '</td></tr></table>'
        || case when r.doc_comment is not null then '<p>Примітка: ' || e(r.doc_comment) || '</p>' end
        || '<div class="signs">' || case l_kind when 'RECEIPT' then '<div>Здав: ____________________</div><div>Прийняв (комірник): ____________________</div>'
                                    else '<div>Відпустив (комірник): ____________________</div><div>Отримав: ____________________</div>' end
        || '</div></div>';
    end loop;
    return l;
  end print_html;

  procedure post_receipt   (p_id in varchar2) is begin post('RECEIPT', p_id); end;
  procedure unpost_receipt (p_id in varchar2) is begin unpost('RECEIPT', p_id); end;
  function  copy_receipt   (p_id in varchar2) return varchar2 is begin return copy('RECEIPT', p_id); end;
  procedure post_issue     (p_id in varchar2) is begin post('SHIPMENT', p_id); end;
  procedure unpost_issue   (p_id in varchar2) is begin unpost('SHIPMENT', p_id); end;
  function  copy_issue     (p_id in varchar2) return varchar2 is begin return copy('SHIPMENT', p_id); end;

end trade_order_scheme;
/
show errors package body trade_order_scheme

-- ---------------------------------------------------------------- тригери складу й комірок
create or replace trigger ref_warehouse_ord_biu
before insert or update of use_order_scheme, use_storage_bins on ref_warehouse for each row
-- r5 F-WH-11 (db/40): ордерна схема й адресне зберігання
begin
  trade_order_scheme.check_warehouse(inserting, :new.id, :new.use_order_scheme, :old.use_order_scheme,
                                     :new.use_storage_bins, :old.use_storage_bins);
end;
/

create or replace trigger ref_storage_bin_biu
before insert or update on ref_storage_bin for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_STORAGE_BIN_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  trade_order_scheme.check_bin(inserting, :new.id, :new.warehouse_id, :old.warehouse_id, :new.rack, :new.tier, :new.place, :new.name);
  :new.description := trim(:new.description);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_storage_bin_bd before delete on ref_storage_bin
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- тригери ордерів
begin
  for t in (select 'DOC_GOODS_RECEIPT_ORDER' tab, 'RECEIPT' kind from dual
            union all select 'DOC_GOODS_ISSUE_ORDER', 'SHIPMENT' from dual) loop
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_biud' || chr(10)
      || 'before insert or update or delete on ' || lower(t.tab) || ' for each row' || chr(10)
      || q'[begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code(']' || t.tab || q'[_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    trade_order_scheme.check_header(']' || t.kind || q'[', inserting, :new.warehouse_id, :old.warehouse_id,
      :new.basis_id, :old.basis_id, :new.basis_type, :new.bin_id);
    trade_org.resolve_doc_org(:new.organization_id, :old.organization_id, :new.basis_type, :new.basis_id, inserting);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;]';
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_ad after delete on ' || lower(t.tab) || chr(10)
      || 'begin trade_core.g_deleting_doc := false; end;';
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_goods_ct' || chr(10)
      || 'for insert or update or delete on ' || lower(t.tab) || '_goods' || chr(10)
      || q'[compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable(']' || t.tab || q'[', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if :new.line_number is null or :new.line_number = 0 then :new.line_number := 1000000000; end if;
      if inserting or :new.product_id <> :old.product_id or :new.quantity <> :old.quantity
         or nvl(:new.characteristic_id, '-') <> nvl(:old.characteristic_id, '-') or nvl(:new.series_id, '-') <> nvl(:old.series_id, '-')
         or nvl(:new.bin_id, '-') <> nvl(:old.bin_id, '-') then
        trade_order_scheme.check_line(']' || t.kind || q'[', :new.document_id, :new.product_id, :new.characteristic_id,
          :new.series_id, :new.quantity, :new.bin_id, inserting or :new.product_id <> :old.product_id,
          inserting or nvl(:new.bin_id, '-') <> nvl(:old.bin_id, '-'));
      end if;
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber(']' || t.tab || q'[_GOODS', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end;]';
  end loop;
end;
/

-- ---------------------------------------------------------------- тригери регістрів
create or replace trigger reg_goods_order_mv_biud
before insert or update or delete on reg_goods_order_mv
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/
create or replace trigger reg_bin_stock_mv_biud
before insert or update or delete on reg_bin_stock_mv
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/
-- Рухи «Товари на складах» ордерного складу → «Товари до надходження / до відвантаження»
create or replace trigger reg_stock_balance_mv_ord
after insert or delete on reg_stock_balance_movement for each row
-- r5 F-WH-11 (db/40)
begin
  if inserting then
    trade_order_scheme.stock_moved(:new.recorder_type, :new.recorder_id, :new.line_number, :new.period, :new.warehouse_id,
                                   :new.product_id, :new.characteristic_id, :new.series_id, :new.quantity);
  else
    trade_order_scheme.stock_unmoved(:old.recorder_type, :old.recorder_id, :old.line_number, :old.warehouse_id);
  end if;
end;
/

-- ---------------------------------------------------------------- реєстратори (+ складські ордери)
create or replace view v_recorder as
select 'DocGoodsReceipt' recorder_type, d.id recorder_id,
       'Прибуткова накладна ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') recorder_name, 51 page_id
  from doc_goods_receipt d
union all select 'DocSupplierPayment', d.id, 'Оплата постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 61 from doc_supplier_payment d
union all select 'DocPriceSetting', d.id, 'Встановлення цін ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 101 from doc_price_setting d
union all select 'DocGoodsSale', d.id, 'Реалізація товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 111 from doc_goods_sale d
union all select 'DocCustomerPayment', d.id, 'Оплата від покупця ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 121 from doc_customer_payment d
union all select 'DocGoodsTransfer', d.id, 'Переміщення товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 131 from doc_goods_transfer d
union all select 'DocGoodsWriteOff', d.id, 'Списання товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 141 from doc_goods_write_off d
union all select 'DocCustomerOrder', d.id, 'Замовлення клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 261 from doc_customer_order d
union all select 'DocSupplierOrder', d.id, 'Замовлення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 271 from doc_supplier_order d
union all select 'DocCustomerReturn', d.id, 'Повернення від клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 281 from doc_customer_return d
union all select 'DocSupplierReturn', d.id, 'Повернення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 291 from doc_supplier_return d
union all select 'DocInventoryCount', d.id, 'Інвентаризація ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 301 from doc_inventory_count d
union all select 'DocSurplusPosting', d.id, 'Оприбуткування надлишків ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 311 from doc_surplus_posting d
union all select 'DocInvoiceForPayment', d.id, 'Рахунок на оплату ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 321 from doc_invoice_for_payment d
union all select 'DocCashReceipt', d.id, 'Прибутковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 371 from doc_cash_receipt d
union all select 'DocCashPayment', d.id, 'Видатковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 381 from doc_cash_payment d
union all select 'DocBankStatement', d.id, 'Банківська виписка ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 401 from doc_bank_statement d
union all select 'DocDebtAdjustment', d.id, 'Коригування боргу ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 411 from doc_debt_adjustment d
union all select 'DocAssembly', d.id, case d.operation_kind when 'ASSEMBLY' then 'Комплектація товарів ' else 'Розкомплектація товарів ' end
                 || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 441 from doc_assembly d
union all select 'DocGoodsReceiptOrder', d.id, 'Прибутковий ордер на товари ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 561 from doc_goods_receipt_order d
union all select 'DocGoodsIssueOrder', d.id, 'Видатковий ордер на товари ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 571 from doc_goods_issue_order d;

-- ---------------------------------------------------------------- представлення звітів і списків
-- Залишки «Товари до надходження / до відвантаження» за ключем
create or replace view v_goods_order_balance as
select m.direction, trade_order_scheme.direction_name(m.direction) direction_name, m.warehouse_id, w.name warehouse_name,
       m.basis_type, m.basis_id, m.product_id, p.code product_code, p.name product_name, u.short_name unit_name,
       m.characteristic_id, trade_series.char_label(m.characteristic_id) characteristic_name,
       m.series_id, trade_series.series_label(m.series_id) series_name,
       sum(case when m.quantity > 0 then m.quantity else 0 end) planned_qty,
       sum(case when m.quantity < 0 then -m.quantity else 0 end) done_qty,
       sum(m.quantity) remaining_qty
  from reg_goods_order_mv m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by m.direction, m.warehouse_id, w.name, m.basis_type, m.basis_id, m.product_id, p.code, p.name, u.short_name,
          m.characteristic_id, m.series_id;

-- Розпорядження (документи-підстави) зі станом приймання / відвантаження
create or replace view v_goods_order_basis as
select b.direction, trade_order_scheme.direction_name(b.direction) direction_name, b.warehouse_id, w.name warehouse_name,
       b.basis_type, b.basis_id, r.recorder_name basis_name, r.page_id basis_page_id, b.basis_date,
       b.planned_qty, b.done_qty, b.remaining_qty, b.lines_count,
       b.state, trade_order_scheme.state_name(b.direction, b.state) state_name,
       b.direction || '-' || b.warehouse_id || '-' || b.basis_id task_key
  from (select k.direction, k.warehouse_id, k.basis_type, k.basis_id, min(k.basis_date) basis_date,
               sum(k.planned) planned_qty, sum(k.done) done_qty, sum(greatest(k.rem, 0)) remaining_qty, count(*) lines_count,
               case when sum(greatest(k.rem, 0)) = 0 then 'DONE' when sum(k.done) > 0 then 'PARTIAL' else 'WAITING' end state
          from (select direction, warehouse_id, basis_type, basis_id,
                       min(case when quantity > 0 then period end) basis_date,
                       sum(case when quantity > 0 then quantity else 0 end) planned,
                       sum(case when quantity < 0 then -quantity else 0 end) done, sum(quantity) rem
                  from reg_goods_order_mv
                 group by direction, warehouse_id, basis_type, basis_id, product_id, characteristic_id, series_id) k
         group by k.direction, k.warehouse_id, k.basis_type, k.basis_id) b
  join ref_warehouse w on w.id = b.warehouse_id
  left join v_recorder r on r.recorder_type = b.basis_type and r.recorder_id = b.basis_id;

-- Облік / до надходження / до відвантаження / фактично на ордерних складах
create or replace view v_order_scheme_stock as
select s.warehouse_id, w.name warehouse_name, s.product_id, p.code product_code, p.name product_name, u.short_name unit_name,
       s.characteristic_id, trade_series.char_label(s.characteristic_id) characteristic_name,
       s.series_id, trade_series.series_label(s.series_id) series_name,
       s.book_qty, s.to_receive_qty, s.to_ship_qty, s.book_qty - s.to_receive_qty + s.to_ship_qty physical_qty
  from (select warehouse_id, product_id, characteristic_id, series_id,
               sum(book) book_qty, sum(rcv) to_receive_qty, sum(shp) to_ship_qty
          from (select m.warehouse_id, m.product_id, m.characteristic_id, m.series_id, m.quantity book, 0 rcv, 0 shp
                  from reg_stock_balance_movement m
                 where m.warehouse_id in (select id from ref_warehouse where use_order_scheme = 'Y')
                union all
                select o.warehouse_id, o.product_id, o.characteristic_id, o.series_id, 0,
                       case o.direction when 'RECEIPT' then o.quantity else 0 end,
                       case o.direction when 'SHIPMENT' then o.quantity else 0 end
                  from reg_goods_order_mv o)
         group by warehouse_id, product_id, characteristic_id, series_id
        having sum(book) <> 0 or sum(rcv) <> 0 or sum(shp) <> 0) s
  join ref_warehouse w on w.id = s.warehouse_id
  join ref_product p on p.id = s.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id;

-- Товари в комірках
create or replace view v_bin_stock as
select m.warehouse_id, w.name warehouse_name, m.bin_id, b.name bin_name, b.rack, b.tier, b.place,
       m.product_id, p.code product_code, p.name product_name, u.short_name unit_name,
       m.characteristic_id, trade_series.char_label(m.characteristic_id) characteristic_name,
       m.series_id, trade_series.series_label(m.series_id) series_name, sum(m.quantity) quantity
  from reg_bin_stock_mv m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_storage_bin b on b.id = m.bin_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by m.warehouse_id, w.name, m.bin_id, b.name, b.rack, b.tier, b.place, m.product_id, p.code, p.name, u.short_name,
          m.characteristic_id, m.series_id
having sum(m.quantity) <> 0;

-- Рухи обох регістрів з реєстраторами
create or replace view v_goods_order_movement as
select m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id, 'Товари до надходження / відвантаження' register_name,
       trade_order_scheme.direction_name(m.direction) direction_name, w.name warehouse_name, cast(null as varchar2(100)) bin_name,
       p.name product_name, trade_series.char_label(m.characteristic_id) characteristic_name,
       trade_series.series_label(m.series_id) series_name, m.quantity,
       (select max(x.recorder_name) from v_recorder x where x.recorder_type = m.basis_type and x.recorder_id = m.basis_id) basis_name
  from reg_goods_order_mv m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  left join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id
union all
select m.period, m.recorder_type, m.recorder_id, r.recorder_name, r.page_id, 'Товари в комірках',
       case when m.quantity > 0 then 'Розміщення' else 'Відбір' end, w.name, b.name,
       p.name, trade_series.char_label(m.characteristic_id), trade_series.series_label(m.series_id), m.quantity, null
  from reg_bin_stock_mv m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_storage_bin b on b.id = m.bin_id
  join ref_product p on p.id = m.product_id
  left join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

create or replace view v_goods_order_list as
select h.kind, h.id, h.doc_number, h.occurred_at, h.organization_id, o.name organization_name, h.warehouse_id, w.name warehouse_name,
       h.basis_type, h.basis_id, r.recorder_name basis_name, b.name bin_name, h.status, h.doc_comment,
       (select sum(g.quantity) from v_goods_order_line g where g.kind = h.kind and g.document_id = h.id) total_qty,
       trade_order_scheme.state_name(h.kind, trade_order_scheme.basis_state(h.kind, h.warehouse_id, h.basis_id)) basis_state_name
  from v_goods_order_header h
  join ref_organization o on o.id = h.organization_id
  join ref_warehouse w on w.id = h.warehouse_id
  left join ref_storage_bin b on b.id = h.bin_id
  left join v_recorder r on r.recorder_type = h.basis_type and r.recorder_id = h.basis_id;

create or replace view v_storage_bin_list as
select b.id, b.code, b.name, b.warehouse_id, w.name warehouse_name, b.rack, b.tier, b.place, b.description, b.state,
       (select sum(m.quantity) from reg_bin_stock_mv m where m.bin_id = b.id) quantity,
       (select count(*) from (select m.product_id from reg_bin_stock_mv m where m.bin_id = b.id
                               group by m.product_id, m.characteristic_id, m.series_id having sum(m.quantity) <> 0)) products_count
  from ref_storage_bin b
  join ref_warehouse w on w.id = b.warehouse_id;

-- ---------------------------------------------------------------- меню: «Склад → Ордерний склад»
declare
  procedure obj (p_tech varchar2, p_kind varchar2, p_section varchar2, p_name varchar2, p_list number, p_form number,
                 p_sort number, p_auth varchar2) is
  begin
    merge into sys_metadata_object o
    using (select p_tech tech_name from dual) s on (o.tech_name = s.tech_name)
    when matched then update set o.name = p_name, o.list_page_id = p_list, o.form_page_id = p_form, o.auth_scheme = p_auth
    when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
      values (p_tech, p_kind, p_name, (select id from sys_main_menu_section where tech_name = p_section), p_list, p_form, p_sort, p_auth);
  end;
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_tech varchar2, p_isort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_isort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_tech
       and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  end;
begin
  obj('RefStorageBin',        'CATALOG',  'Catalogs',  'Комірки складів',             550, 551, 130, null);
  obj('DocGoodsReceiptOrder', 'DOCUMENT', 'Documents', 'Прибуткові ордери на товари', 560, 561, 190, 'Роль: склад');
  obj('DocGoodsIssueOrder',   'DOCUMENT', 'Documents', 'Видаткові ордери на товари',  570, 571, 200, 'Роль: склад');
  obj('RegGoodsOrderScheme',  'ACCUMULATION_REGISTER', 'Reports', 'Товари до надходження й відвантаження', 580, null, 220, null);
  obj('StorekeeperWorkplace', 'REPORT',   'Reports',   'Робоче місце комірника',      590, null, 230, 'Роль: склад');
  fp('Warehouse', 'Ордерний склад', 1, 20, 'StorekeeperWorkplace', 10, 'Y');
  fp('Warehouse', 'Ордерний склад', 1, 20, 'DocGoodsReceiptOrder', 20);
  fp('Warehouse', 'Ордерний склад', 1, 20, 'DocGoodsIssueOrder', 30);
  fp('Warehouse', 'Ордерний склад', 1, 20, 'RegGoodsOrderScheme', 40);
  fp('Warehouse', 'НСІ', 3, 10, 'RefStorageBin', 70);
  fp('Reference', 'Склади', 1, 10, 'RefStorageBin', 15);
  commit;
end;
/

-- Перекомпіляція залежних від v_recorder представлень і пакетів
begin
  for o in (select object_name, object_type from user_objects
             where status = 'INVALID' and object_type in ('VIEW', 'PACKAGE', 'PACKAGE BODY', 'TRIGGER')
             order by case object_type when 'VIEW' then 1 when 'PACKAGE' then 2 else 3 end) loop
    begin
      execute immediate 'alter ' || case o.object_type when 'PACKAGE BODY' then 'package' else lower(o.object_type) end
        || ' ' || o.object_name || ' compile' || case o.object_type when 'PACKAGE BODY' then ' body' end;
    exception when others then null;
    end;
  end loop;
end;
/
