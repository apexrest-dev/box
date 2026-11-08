-- =============================================================================
-- Trade r5 — F-NSI-10 «Характеристики, серії, терміни придатності» (APE-63).
-- Паспорти RefProductCharacteristic, RefProductSeries (PROPOSED); доповнення RefProduct,
-- RegStockBalance / RegStockReserve / RegStockCost.
--   * номенклатура: ознаки use_characteristics «Використовувати характеристики»,
--     use_series «Облік серій», shelf_life_days «Термін придатності, днів» (типовий для нових серій);
--     змінювати ознаки можна лише за нульового залишку товару на всіх складах;
--   * довідники ref_product_characteristic «Характеристики номенклатури» (розмір, колір …) і
--     ref_product_series «Серії номенклатури» (номер, дата виробництва, придатний до) —
--     підпорядковані товару з відповідною ознакою;
--   * рядки документів, що рухають склад (надходження, реалізація, переміщення, списання,
--     замовлення клієнта, повернення від клієнта / постачальнику, оприбуткування, комплектація —
--     комплектуючі), отримали необов'язкові characteristic_id / series_id; повернення беруть їх
--     з рядка-підстави;
--   * виміри characteristic_id / series_id у рухах RegStockBalance, RegStockReserve, RegStockCost
--     заповнюються тригерами з рядка документа-реєстратора (рядок руху mod 1 000 000 = рядок
--     документа) — процедури проведення r1–r4 не змінювались; для товарів з ознаками в
--     RegStockBalance вимір обов'язковий, видаткові рухи контролюють залишок за ключем
--     склад × товар × характеристика × серія; підсумки *_tot, вільний залишок (резерви) і середня
--     собівартість лишаються в розрізі склад × товар (виміри в резерві й собівартості — аналітичні);
--   * FEFO: trade_series.fill_fefo — підбір серій «першим спливає — першим відвантажено» (рядок
--     ділиться на кілька серій); реалізація / переміщення / списання підбирають серії автоматично під
--     час проведення (виклик з trade_ops, db/06), реалізація пропускає прострочені серії, продаж
--     простроченої серії, вказаної вручну, — неблокувальне попередження;
--   * звіт «Товари з терміном, що спливає» (v_series_stock_balance), меню, журнал реєстрації.
-- Потребує 01–37. Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefProduct: ознаки
  ddl(q'[alter table ref_product add (use_characteristics varchar2(1) default on null 'N' not null,
                                      use_series varchar2(1) default on null 'N' not null,
                                      shelf_life_days number(5))]');
  ddl(q'[alter table ref_product add constraint ref_product_use_chr_ck check (use_characteristics in ('Y','N'))]');
  ddl(q'[alter table ref_product add constraint ref_product_use_ser_ck check (use_series in ('Y','N'))]');
  ddl(q'[alter table ref_product add constraint ref_product_shelf_ck check (shelf_life_days is null or shelf_life_days > 0)]');

  -- ---------------------------------------------------------------- RefProductCharacteristic
  ddl('create sequence ref_product_characteristic_code_seq nocache');
  ddl(q'[create table ref_product_characteristic (
    id          varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code        varchar2(9)   not null,
    name        varchar2(255) not null,
    product_id  varchar2(32)  not null,
    description varchar2(1000),
    state       varchar2(20)  default on null 'ACTIVE' not null,
    version     number(19)    default on null 0 not null,
    created_at  timestamp     not null, created_by varchar2(255) not null,
    updated_at  timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_product_characteristic_pk primary key (id),
    constraint ref_product_characteristic_code_uk unique (code),
    constraint ref_product_characteristic_name_uk unique (product_id, name),
    constraint ref_product_characteristic_prd_fk foreign key (product_id) references ref_product (id),
    constraint ref_product_characteristic_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');

  -- ---------------------------------------------------------------- RefProductSeries
  ddl('create sequence ref_product_series_code_seq nocache');
  ddl(q'[create table ref_product_series (
    id              varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code            varchar2(9)   not null,
    name            varchar2(255) not null,
    product_id      varchar2(32)  not null,
    production_date date,
    expiry_date     date,
    description     varchar2(1000),
    state           varchar2(20)  default on null 'ACTIVE' not null,
    version         number(19)    default on null 0 not null,
    created_at      timestamp     not null, created_by varchar2(255) not null,
    updated_at      timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_product_series_pk primary key (id),
    constraint ref_product_series_code_uk unique (code),
    constraint ref_product_series_name_uk unique (product_id, name),
    constraint ref_product_series_prd_fk foreign key (product_id) references ref_product (id),
    constraint ref_product_series_dates_ck check (expiry_date is null or production_date is null or expiry_date >= production_date),
    constraint ref_product_series_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_product_series_exp_ix on ref_product_series (expiry_date)');

  -- ---------------------------------------------------------------- рядки документів
  for t in (select column_value tab, rownum rn from table(sys.odcivarchar2list(
              'DOC_GOODS_RECEIPT_GOODS','DOC_GOODS_SALE_GOODS','DOC_GOODS_TRANSFER_GOODS','DOC_GOODS_WRITE_OFF_GOODS',
              'DOC_CUSTOMER_ORDER_GOODS','DOC_CUSTOMER_RETURN_GOODS','DOC_SUPPLIER_RETURN_GOODS','DOC_SURPLUS_POSTING_GOODS',
              'DOC_ASSEMBLY_GOODS',
              'REG_STOCK_BALANCE_MOVEMENT','REG_STOCK_RESERVE_MV','REG_STOCK_COST_MV'))) loop
    ddl('alter table ' || t.tab || ' add (characteristic_id varchar2(32), series_id varchar2(32))');
    ddl('alter table ' || t.tab || ' add constraint r5_dim' || t.rn || '_chr_fk foreign key (characteristic_id) references ref_product_characteristic (id)');
    ddl('alter table ' || t.tab || ' add constraint r5_dim' || t.rn || '_ser_fk foreign key (series_id) references ref_product_series (id)');
    ddl('create index r5_dim' || t.rn || '_chr_ix on ' || t.tab || ' (characteristic_id)');
    ddl('create index r5_dim' || t.rn || '_ser_ix on ' || t.tab || ' (series_id)');
  end loop;
end;
/

create or replace package trade_series as
  -- Подання серії: «<номер> (до DD.MM.YYYY)»
  function series_label (p_series_id in varchar2) return varchar2;
  function char_label   (p_char_id in varchar2) return varchar2;
  -- Стан терміну придатності на дату: EXPIRED / EXPIRING (у межах p_days) / OK / null (без терміну)
  function expiry_state (p_expiry in date, p_date in date, p_days in number) return varchar2 deterministic;
  function expiry_state_name (p_state in varchar2) return varchar2 deterministic;

  -- Тригер номенклатури: ознаки змінюються лише за нульового залишку
  procedure check_product_flags (p_inserting in boolean, p_product_id in varchar2, p_kind in varchar2,
                                 p_old_chr in varchar2, p_new_chr in out varchar2,
                                 p_old_ser in varchar2, p_new_ser in out varchar2);
  -- Тригери довідників
  procedure check_owner (p_kind in varchar2, p_inserting in boolean, p_id in varchar2,
                         p_product_id in varchar2, p_old_product_id in varchar2);
  function  default_expiry (p_product_id in varchar2, p_production_date in date) return date;
  -- Тригер рядка документа: характеристика / серія належать товару; без ознаки — очищаються
  procedure check_line (p_product_id in varchar2, p_char_id in out varchar2, p_series_id in out varchar2);

  -- Тригери рухів: виміри з рядка документа-реєстратора; p_require — обов'язковість (RegStockBalance)
  procedure movement_dims (p_type in varchar2, p_id in varchar2, p_line in number, p_product_id in varchar2,
                           p_char_id in out varchar2, p_series_id in out varchar2, p_require in boolean);
  -- Контроль залишку ключа після видаткового руху (+ попередження про прострочену серію в реалізації)
  procedure check_balance (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2,
                           p_type in varchar2, p_period in date);
  -- Залишок за ключем (без рухів документа p_excl_type/p_excl_id)
  function balance (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2,
                    p_excl_type in varchar2 default null, p_excl_id in varchar2 default null) return number;

  -- FEFO: заповнити серії рядків без серії (DocGoodsSale, DocGoodsTransfer, DocGoodsWriteOff, DocAssembly);
  -- повертає кількість заповнених частин рядків; нестача лишається рядком без серії
  function  fill_fefo (p_type in varchar2, p_id in varchar2) return number;
  procedure fill_fefo (p_type in varchar2, p_id in varchar2);
  -- Перед проведенням (з trade_ops): характеристики з замовлення-підстави, FEFO; нестача — помилка
  procedure prepare_post (p_type in varchar2, p_id in varchar2);
  -- «Скопіювати»: перенести характеристики й серії рядків (за номером рядка й товаром)
  procedure copy_dims (p_type in varchar2, p_src_id in varchar2, p_new_id in varchar2);
end trade_series;
/

create or replace package body trade_series as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function q (p number) return varchar2 is begin return rtrim(rtrim(to_char(p, 'FM999G999G990D999'), '0'), '.,'); end;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_product where id = p_id;
    return l;
  end prd_name;

  function lines_table (p_type varchar2) return varchar2 is
  begin
    return case p_type
      when 'DocGoodsReceipt'   then 'DOC_GOODS_RECEIPT_GOODS'
      when 'DocGoodsSale'      then 'DOC_GOODS_SALE_GOODS'
      when 'DocGoodsTransfer'  then 'DOC_GOODS_TRANSFER_GOODS'
      when 'DocGoodsWriteOff'  then 'DOC_GOODS_WRITE_OFF_GOODS'
      when 'DocCustomerOrder'  then 'DOC_CUSTOMER_ORDER_GOODS'
      when 'DocCustomerReturn' then 'DOC_CUSTOMER_RETURN_GOODS'
      when 'DocSupplierReturn' then 'DOC_SUPPLIER_RETURN_GOODS'
      when 'DocSurplusPosting' then 'DOC_SURPLUS_POSTING_GOODS'
      when 'DocAssembly'       then 'DOC_ASSEMBLY_GOODS'
      when 'DocRetailReceipt'  then 'DOC_RETAIL_RECEIPT_GOODS'   -- r5 F-RET-01 (db/43)
      end;
  end lines_table;

  function series_label (p_series_id in varchar2) return varchar2 is
    l varchar2(400);
  begin
    select max(name || case when expiry_date is not null then ' (до ' || to_char(expiry_date, 'DD.MM.YYYY') || ')' end)
      into l from ref_product_series where id = p_series_id;
    return l;
  end series_label;

  function char_label (p_char_id in varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_product_characteristic where id = p_char_id;
    return l;
  end char_label;

  function expiry_state (p_expiry in date, p_date in date, p_days in number) return varchar2 deterministic is
  begin
    if p_expiry is null then
      return null;
    elsif p_expiry < trunc(p_date) then
      return 'EXPIRED';
    elsif p_expiry <= trunc(p_date) + coalesce(p_days, 0) then
      return 'EXPIRING';
    end if;
    return 'OK';
  end expiry_state;

  function expiry_state_name (p_state in varchar2) return varchar2 deterministic is
  begin
    return case p_state when 'EXPIRED' then 'Прострочено' when 'EXPIRING' then 'Термін спливає' when 'OK' then 'Придатний' end;
  end expiry_state_name;

  procedure check_product_flags (p_inserting in boolean, p_product_id in varchar2, p_kind in varchar2,
                                 p_old_chr in varchar2, p_new_chr in out varchar2,
                                 p_old_ser in varchar2, p_new_ser in out varchar2) is
    l_n pls_integer;
  begin
    if p_kind = 'SERVICE' then
      p_new_chr := 'N'; p_new_ser := 'N';   -- послуги не мають складського обліку
    end if;
    if p_inserting or (p_old_chr = p_new_chr and p_old_ser = p_new_ser) then
      return;
    end if;
    select count(*) into l_n from dual
     where exists (select 1 from reg_stock_balance_movement where product_id = p_product_id
                    group by warehouse_id having sum(quantity) <> 0);
    if l_n > 0 then
      fail('SERIES_FLAGS_WITH_STOCK', 'Ознаки «Використовувати характеристики» й «Облік серій» можна змінити лише за нульового '
           || 'залишку товару на всіх складах.');
    end if;
  end check_product_flags;

  procedure check_owner (p_kind in varchar2, p_inserting in boolean, p_id in varchar2,
                         p_product_id in varchar2, p_old_product_id in varchar2) is
    l_flag varchar2(1); l_state varchar2(20); l_kind varchar2(20); l_n pls_integer;
  begin
    if not p_inserting and p_product_id = p_old_product_id then
      return;
    end if;
    select max(case p_kind when 'SERIES' then use_series else use_characteristics end), max(state), max(product_kind)
      into l_flag, l_state, l_kind from ref_product where id = p_product_id;
    if l_state is null or l_state <> 'ACTIVE' then
      fail('PRODUCT_NOT_ACTIVE', 'Товар не існує або помічений на видалення.');
    elsif l_flag <> 'Y' then
      if p_kind = 'SERIES' then
        fail('SERIES_NOT_USED', 'Для товару «' || prd_name(p_product_id) || '» не ведеться облік серій (ознака в картці номенклатури).');
      else
        fail('CHARACTERISTICS_NOT_USED', 'Для товару «' || prd_name(p_product_id)
             || '» не використовуються характеристики (ознака в картці номенклатури).');
      end if;
    end if;
    if not p_inserting then
      if p_kind = 'SERIES' then
        select count(*) into l_n from dual where exists (select 1 from reg_stock_balance_movement where series_id = p_id);
      else
        select count(*) into l_n from dual where exists (select 1 from reg_stock_balance_movement where characteristic_id = p_id);
      end if;
      if l_n > 0 then
        fail('SERIES_OWNER_CHANGE', 'Товар не можна змінити: ' || case p_kind when 'SERIES' then 'серія' else 'характеристика' end
             || ' вже використовується в рухах.');
      end if;
    end if;
  end check_owner;

  function default_expiry (p_product_id in varchar2, p_production_date in date) return date is
    l number;
  begin
    if p_production_date is null then
      return null;
    end if;
    select max(shelf_life_days) into l from ref_product where id = p_product_id;
    return case when l is not null then trunc(p_production_date) + l end;
  end default_expiry;

  procedure check_line (p_product_id in varchar2, p_char_id in out varchar2, p_series_id in out varchar2) is
    l_uc varchar2(1); l_us varchar2(1); l_prd varchar2(32); l_state varchar2(20);
  begin
    if p_char_id is null and p_series_id is null then
      return;
    end if;
    select max(use_characteristics), max(use_series) into l_uc, l_us from ref_product where id = p_product_id;
    if nvl(l_uc, 'N') = 'N' then p_char_id := null; end if;
    if nvl(l_us, 'N') = 'N' then p_series_id := null; end if;
    if p_char_id is not null then
      select max(product_id), max(state) into l_prd, l_state from ref_product_characteristic where id = p_char_id;
      if l_prd is null or l_prd <> p_product_id then
        fail('CHARACTERISTIC_OTHER_PRODUCT', 'Характеристика не належить товару «' || prd_name(p_product_id) || '».');
      elsif l_state <> 'ACTIVE' and not trade_core.g_internal then
        fail('CHARACTERISTIC_NOT_ACTIVE', 'Характеристика «' || char_label(p_char_id) || '» помічена на видалення.');
      end if;
    end if;
    if p_series_id is not null then
      select max(product_id), max(state) into l_prd, l_state from ref_product_series where id = p_series_id;
      if l_prd is null or l_prd <> p_product_id then
        fail('SERIES_OTHER_PRODUCT', 'Серія не належить товару «' || prd_name(p_product_id) || '».');
      elsif l_state <> 'ACTIVE' and not trade_core.g_internal then
        fail('SERIES_NOT_ACTIVE', 'Серія «' || series_label(p_series_id) || '» помічена на видалення.');
      end if;
    end if;
  end check_line;

  procedure movement_dims (p_type in varchar2, p_id in varchar2, p_line in number, p_product_id in varchar2,
                           p_char_id in out varchar2, p_series_id in out varchar2, p_require in boolean) is
    l_uc varchar2(1); l_us varchar2(1);
    l_ln number := mod(p_line, 1000000);
    l_tab varchar2(30);
  begin
    select max(use_characteristics), max(use_series) into l_uc, l_us from ref_product where id = p_product_id;
    if nvl(l_uc, 'N') = 'N' and nvl(l_us, 'N') = 'N' then
      p_char_id := null; p_series_id := null;
      return;
    end if;
    l_tab := lines_table(p_type);
    if p_char_id is null and p_series_id is null and l_tab is not null and l_ln > 0 then
      begin
        execute immediate 'select characteristic_id, series_id from ' || l_tab
          || ' where document_id = :d and line_number = :n and product_id = :p'
          into p_char_id, p_series_id using p_id, l_ln, p_product_id;
      exception when no_data_found or too_many_rows then null;
      end;
    end if;
    if l_uc = 'N' then p_char_id := null; end if;
    if l_us = 'N' then p_series_id := null; end if;
    if p_require then
      if l_uc = 'Y' and p_char_id is null then
        fail('CHARACTERISTIC_REQUIRED', 'Не вказано характеристику товару «' || prd_name(p_product_id) || '»'
             || case when l_ln > 0 then ' (рядок ' || l_ln || ')' end || '.');
      end if;
      if l_us = 'Y' and p_series_id is null then
        fail('SERIES_REQUIRED', 'Не вказано серію товару «' || prd_name(p_product_id) || '»'
             || case when l_ln > 0 then ' (рядок ' || l_ln || ')' end
             || '. Вкажіть серію або скористайтеся «Підібрати серії (FEFO)».');
      end if;
    end if;
  end movement_dims;

  function balance (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2,
                    p_excl_type in varchar2 default null, p_excl_id in varchar2 default null) return number is
    l number;
  begin
    select coalesce(sum(quantity), 0) into l from reg_stock_balance_movement
     where warehouse_id = p_wh and product_id = p_product_id
       and decode(characteristic_id, p_char_id, 1, 0) = 1
       and decode(series_id, p_series_id, 1, 0) = 1
       and not (p_excl_id is not null and recorder_type = p_excl_type and recorder_id = p_excl_id);
    return l;
  end balance;

  procedure check_balance (p_wh in varchar2, p_product_id in varchar2, p_char_id in varchar2, p_series_id in varchar2,
                           p_type in varchar2, p_period in date) is
    l number := balance(p_wh, p_product_id, p_char_id, p_series_id);
    l_wh varchar2(255); l_exp date;
  begin
    if l < 0 then
      select name into l_wh from ref_warehouse where id = p_wh;
      fail('INSUFFICIENT_SERIES_STOCK', 'Недостатньо залишку товару «' || prd_name(p_product_id) || '»'
           || case when p_char_id is not null then ', характеристика «' || char_label(p_char_id) || '»' end
           || case when p_series_id is not null then ', серія «' || series_label(p_series_id) || '»' end
           || ' на складі «' || l_wh || '»: не вистачає ' || q(-l) || '.');
    end if;
    if p_type = 'DocGoodsSale' and p_series_id is not null then
      select expiry_date into l_exp from ref_product_series where id = p_series_id;
      if l_exp < trunc(p_period) then
        trade_warn.add('SERIES_EXPIRED', 'продано серію «' || series_label(p_series_id) || '» товару «' || prd_name(p_product_id)
                       || '» з терміном придатності, що минув.');
      end if;
    end if;
  end check_balance;

  -- ---------------------------------------------------------------- FEFO
  procedure doc_params (p_type varchar2, p_id varchar2, o_wh out varchar2, o_date out date, o_skip_expired out varchar2,
                        o_applicable out boolean) is
    l_op varchar2(20);
  begin
    o_applicable := true; o_skip_expired := 'N';
    case p_type
      when 'DocGoodsSale' then
        select warehouse_id, occurred_at into o_wh, o_date from doc_goods_sale where id = p_id;
        o_skip_expired := 'Y';
      when 'DocGoodsTransfer' then
        select warehouse_from_id, occurred_at into o_wh, o_date from doc_goods_transfer where id = p_id;
      when 'DocGoodsWriteOff' then
        select warehouse_id, occurred_at into o_wh, o_date from doc_goods_write_off where id = p_id;
      when 'DocAssembly' then
        select warehouse_id, occurred_at, operation_kind into o_wh, o_date, l_op from doc_assembly where id = p_id;
        o_applicable := l_op = 'ASSEMBLY';   -- розкомплектація: комплектуючі надходять — серію вказують
      when 'DocRetailReceipt' then   -- r5 F-RET-01 (db/43): чек ККМ — без прострочених серій
        execute immediate 'select warehouse_id, occurred_at from doc_retail_receipt where id = :i' into o_wh, o_date using p_id;
        o_skip_expired := 'Y';
      else
        fail('FEFO_NOT_SUPPORTED', 'Підбір серій не підтримується для цього документа.');
    end case;
  end doc_params;

  function copy_cols (p_tab varchar2) return varchar2 is
    l varchar2(4000);
  begin
    select listagg(lower(column_name), ', ') within group (order by column_id) into l
      from user_tab_columns where table_name = p_tab and column_name not in ('ID', 'LINE_NUMBER', 'QUANTITY', 'SERIES_ID');
    return l;
  end copy_cols;

  function fefo (p_type varchar2, p_id varchar2, p_strict boolean) return number is
    type t_line is record (id varchar2(32), prd varchar2(32), chr varchar2(32), qty number, uc varchar2(1));
    type t_lines is table of t_line;
    ls t_lines;
    l_tab varchar2(30) := lines_table(p_type);
    l_cols varchar2(4000); l_cols_g varchar2(4000); l_cols_s varchar2(4000);
    l_wh varchar2(32); l_date date; l_skip varchar2(1); l_ok boolean;
    l_rem number; l_take number; l_used number; l_cur varchar2(32); l_new varchar2(32); l_ln number; l_first boolean;
    l_prev boolean := trade_core.g_internal;
    l_prd varchar2(32); l_chr varchar2(32);
    n number := 0;

    procedure split (p_qty number, p_series varchar2) is
      l_src varchar2(4000);
    begin
      -- одним MERGE: зсув наступних рядків + новий рядок після поточного (тригер рядків перенумеровує
      -- після кожного оператора, тому окремі UPDATE/INSERT втратили б порядок)
      execute immediate 'select line_number from ' || l_tab || ' where id = :i' into l_ln using l_cur;
      l_new := rawtohex(sys_guid());
      l_src := 'select g.id, g.line_number + 1 ln, g.quantity, g.series_id, ' || l_cols_g || ' from ' || l_tab
        || ' g where g.document_id = :d and g.line_number > :n'
        || ' union all select :nid, :n1, :q, :s, ' || l_cols_g || ' from ' || l_tab || ' g where g.id = :i';
      execute immediate 'merge into ' || l_tab || ' t using (' || l_src || ') s on (t.id = s.id)'
        || ' when matched then update set t.line_number = s.ln'
        || ' when not matched then insert (id, line_number, quantity, series_id, ' || l_cols || ')'
        || ' values (s.id, s.ln, s.quantity, s.series_id, ' || l_cols_s || ')'
        using p_id, l_ln, l_new, l_ln + 1, p_qty, p_series, l_cur;
      l_cur := l_new;
    end split;
  begin
    doc_params(p_type, p_id, l_wh, l_date, l_skip, l_ok);
    if not l_ok then
      return 0;
    end if;
    execute immediate 'select g.id, g.product_id, g.characteristic_id, g.quantity, p.use_characteristics from ' || l_tab
      || ' g join ref_product p on p.id = g.product_id where g.document_id = :d and g.series_id is null and p.use_series = ''Y'''
      || ' order by g.line_number' bulk collect into ls using p_id;
    if ls.count = 0 then
      return 0;
    end if;
    l_cols := copy_cols(l_tab);
    l_cols_g := 'g.' || replace(l_cols, ', ', ', g.');
    l_cols_s := 's.' || replace(l_cols, ', ', ', s.');
    trade_core.g_internal := true;
    for i in 1 .. ls.count loop
      if ls(i).uc = 'Y' and ls(i).chr is null then
        continue;   -- без характеристики серію не підібрати: проведення повідомить CHARACTERISTIC_REQUIRED
      end if;
      l_rem := ls(i).qty; l_first := true; l_cur := ls(i).id; l_prd := ls(i).prd; l_chr := ls(i).chr;
      for s in (select m.series_id, sum(m.quantity) qty
                  from reg_stock_balance_movement m join ref_product_series rs on rs.id = m.series_id
                 where m.warehouse_id = l_wh and m.product_id = l_prd
                   and decode(m.characteristic_id, l_chr, 1, 0) = 1
                   and not (m.recorder_type = p_type and m.recorder_id = p_id)
                   and (l_skip = 'N' or rs.expiry_date is null or rs.expiry_date >= trunc(l_date))
                 group by m.series_id, rs.expiry_date, rs.production_date, rs.name
                having sum(m.quantity) > 0
                 order by rs.expiry_date nulls last, rs.production_date nulls last, rs.name) loop
        exit when l_rem <= 0;
        execute immediate 'select coalesce(sum(quantity), 0) from ' || l_tab
          || ' where document_id = :d and product_id = :p and series_id = :s and decode(characteristic_id, :c, 1, 0) = 1'
          into l_used using p_id, l_prd, s.series_id, l_chr;
        l_take := least(l_rem, s.qty - l_used);
        if l_take > 0 then
          if l_first then
            execute immediate 'update ' || l_tab || ' set quantity = :q, series_id = :s where id = :i' using l_take, s.series_id, l_cur;
            l_first := false;
          else
            split(l_take, s.series_id);
          end if;
          l_rem := l_rem - l_take; n := n + 1;
        end if;
      end loop;
      if l_rem > 0 then
        if p_strict then
          fail('SERIES_INSUFFICIENT', 'Недостатньо залишку серій товару «' || prd_name(ls(i).prd) || '»'
               || case when ls(i).chr is not null then ', характеристика «' || char_label(ls(i).chr) || '»' end
               || case when l_skip = 'Y' then ' з непростроченим терміном придатності' end
               || ': не вистачає ' || q(l_rem) || '.');
        elsif not l_first then
          split(l_rem, null);   -- нестача — окремим рядком без серії
        end if;
      end if;
    end loop;
    trade_core.g_internal := l_prev;
    return n;
  exception when others then
    trade_core.g_internal := l_prev;
    raise;
  end fefo;

  function fill_fefo (p_type in varchar2, p_id in varchar2) return number is
    l number;
  begin
    l := fefo(p_type, p_id, false);
    trade_core.audit(p_type, p_id, 'FILL_SERIES_FEFO', 'Підібрано серій: ' || l);
    return l;
  end fill_fefo;

  procedure fill_fefo (p_type in varchar2, p_id in varchar2) is
    l number;
  begin
    l := fill_fefo(p_type, p_id);
  end fill_fefo;

  procedure prepare_post (p_type in varchar2, p_id in varchar2) is
    l_order varchar2(32); l number;
    l_prev boolean := trade_core.g_internal;
  begin
    if p_type = 'DocGoodsSale' then
      select base_order_id into l_order from doc_goods_sale where id = p_id;
      if l_order is not null then
        -- реалізація на підставі замовлення: характеристика з рядка замовлення (якщо однозначна)
        trade_core.g_internal := true;
        update doc_goods_sale_goods g
           set g.characteristic_id = (select max(o.characteristic_id) from doc_customer_order_goods o
                                       where o.document_id = l_order and o.product_id = g.product_id
                                      having count(distinct o.characteristic_id) = 1 and count(o.characteristic_id) = count(*))
         where g.document_id = p_id and g.characteristic_id is null
           and g.product_id in (select id from ref_product where use_characteristics = 'Y');
        trade_core.g_internal := l_prev;
      end if;
    end if;
    l := fefo(p_type, p_id, true);
  exception when others then
    trade_core.g_internal := l_prev;
    raise;
  end prepare_post;

  procedure copy_dims (p_type in varchar2, p_src_id in varchar2, p_new_id in varchar2) is
    l_tab varchar2(30) := lines_table(p_type);
  begin
    if l_tab is null or p_new_id is null then
      return;
    end if;
    execute immediate 'merge into ' || l_tab || ' t using (select line_number, product_id, characteristic_id, series_id from '
      || l_tab || ' where document_id = :s and (characteristic_id is not null or series_id is not null)) s'
      || ' on (t.document_id = :n and t.line_number = s.line_number and t.product_id = s.product_id)'
      || ' when matched then update set t.characteristic_id = s.characteristic_id, t.series_id = s.series_id'
      using p_src_id, p_new_id;
  end copy_dims;

end trade_series;
/
show errors package body trade_series

-- ---------------------------------------------------------------- тригери номенклатури й довідників
create or replace trigger ref_product_r5_biu
before insert or update on ref_product for each row
begin
  trade_series.check_product_flags(inserting, :new.id, :new.product_kind, :old.use_characteristics, :new.use_characteristics,
                                   :old.use_series, :new.use_series);
end;
/

create or replace trigger ref_product_characteristic_biu
before insert or update on ref_product_characteristic for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_PRODUCT_CHARACTERISTIC_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  trade_series.check_owner('CHARACTERISTIC', inserting, :new.id, :new.product_id, :old.product_id);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.description := trim(:new.description);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_product_characteristic_bd before delete on ref_product_characteristic
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

create or replace trigger ref_product_series_biu
before insert or update on ref_product_series for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_PRODUCT_SERIES_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  trade_series.check_owner('SERIES', inserting, :new.id, :new.product_id, :old.product_id);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Номер серії');
  :new.production_date := trunc(:new.production_date);
  :new.expiry_date := trunc(coalesce(:new.expiry_date, trade_series.default_expiry(:new.product_id, :new.production_date)));
  if :new.expiry_date < :new.production_date then
    trade_nsi.fail('SERIES_EXPIRY_BEFORE_PRODUCTION', 'Дата «Придатний до» не може бути раніше дати виробництва.');
  end if;
  :new.description := trim(:new.description);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_product_series_bd before delete on ref_product_series
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- тригери рядків документів
begin
  for t in (select column_value tab from table(sys.odcivarchar2list(
              'DOC_GOODS_RECEIPT_GOODS','DOC_GOODS_SALE_GOODS','DOC_GOODS_TRANSFER_GOODS','DOC_GOODS_WRITE_OFF_GOODS',
              'DOC_CUSTOMER_ORDER_GOODS','DOC_CUSTOMER_RETURN_GOODS','DOC_SUPPLIER_RETURN_GOODS','DOC_SURPLUS_POSTING_GOODS',
              'DOC_ASSEMBLY_GOODS'))) loop
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_ser' || chr(10)
      || 'before insert or update on ' || lower(t.tab) || ' for each row' || chr(10)
      || '-- r5 F-NSI-10 (db/38): характеристика / серія рядка' || chr(10)
      || 'begin' || chr(10)
      || case t.tab
           when 'DOC_CUSTOMER_RETURN_GOODS' then
             '  if inserting and :new.base_sale_line_id is not null and :new.characteristic_id is null and :new.series_id is null then' || chr(10)
             || '    select max(characteristic_id), max(series_id) into :new.characteristic_id, :new.series_id' || chr(10)
             || '      from doc_goods_sale_goods where id = :new.base_sale_line_id;' || chr(10)
             || '  end if;' || chr(10)
           when 'DOC_SUPPLIER_RETURN_GOODS' then
             '  if inserting and :new.base_receipt_line_id is not null and :new.characteristic_id is null and :new.series_id is null then' || chr(10)
             || '    select max(characteristic_id), max(series_id) into :new.characteristic_id, :new.series_id' || chr(10)
             || '      from doc_goods_receipt_goods where id = :new.base_receipt_line_id;' || chr(10)
             || '  end if;' || chr(10)
         end
      || '  trade_series.check_line(:new.product_id, :new.characteristic_id, :new.series_id);' || chr(10)
      || 'end;';
  end loop;
end;
/

-- ---------------------------------------------------------------- тригери рухів регістрів
create or replace trigger reg_stock_balance_mv_ser
for insert on reg_stock_balance_movement
compound trigger
  type t_key is record (wh varchar2(32), prd varchar2(32), chr varchar2(32), ser varchar2(32), typ varchar2(60), per date);
  type t_keys is table of t_key index by pls_integer;
  g t_keys;
  before each row is
  begin
    trade_series.movement_dims(:new.recorder_type, :new.recorder_id, :new.line_number, :new.product_id,
                               :new.characteristic_id, :new.series_id, true);
    if :new.quantity < 0 and (:new.characteristic_id is not null or :new.series_id is not null) then
      g(g.count + 1).wh := :new.warehouse_id;
      g(g.count).prd := :new.product_id; g(g.count).chr := :new.characteristic_id; g(g.count).ser := :new.series_id;
      g(g.count).typ := :new.recorder_type; g(g.count).per := :new.period;
    end if;
  end before each row;
  after statement is
  begin
    for i in 1 .. g.count loop
      trade_series.check_balance(g(i).wh, g(i).prd, g(i).chr, g(i).ser, g(i).typ, g(i).per);
    end loop;
    g.delete;
  exception when others then g.delete; raise;
  end after statement;
end reg_stock_balance_mv_ser;
/

create or replace trigger reg_stock_reserve_mv_ser
before insert on reg_stock_reserve_mv for each row
begin
  trade_series.movement_dims(:new.recorder_type, :new.recorder_id, :new.line_number, :new.product_id,
                             :new.characteristic_id, :new.series_id, false);
end;
/

create or replace trigger reg_stock_cost_mv_ser
before insert on reg_stock_cost_mv for each row
begin
  trade_series.movement_dims(:new.recorder_type, :new.recorder_id, :new.line_number, :new.product_id,
                             :new.characteristic_id, :new.series_id, false);
end;
/

-- ---------------------------------------------------------------- представлення
create or replace view v_product_characteristic_list as
select c.id, c.code, c.name, c.product_id, p.name product_name, c.description, c.state
  from ref_product_characteristic c
  join ref_product p on p.id = c.product_id;

create or replace view v_product_series_list as
select s.id, s.code, s.name, s.product_id, p.name product_name, s.production_date, s.expiry_date,
       trade_series.expiry_state_name(trade_series.expiry_state(s.expiry_date, sysdate, 30)) expiry_state_name,
       (select sum(m.quantity) from reg_stock_balance_movement m where m.series_id = s.id) quantity,
       s.description, s.state
  from ref_product_series s
  join ref_product p on p.id = s.product_id;

-- Залишки в розрізі характеристик і серій (лише товари з ознаками)
create or replace view v_series_stock_balance as
select m.warehouse_id, w.name warehouse_name, m.product_id, p.code product_code, p.name product_name, u.short_name unit_name,
       m.characteristic_id, c.name characteristic_name, m.series_id, s.name series_number,
       s.production_date, s.expiry_date, sum(m.quantity) quantity
  from reg_stock_balance_movement m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
  left join ref_product_characteristic c on c.id = m.characteristic_id
  left join ref_product_series s on s.id = m.series_id
 where m.characteristic_id is not null or m.series_id is not null
 group by m.warehouse_id, w.name, m.product_id, p.code, p.name, u.short_name, m.characteristic_id, c.name,
          m.series_id, s.name, s.production_date, s.expiry_date
having sum(m.quantity) <> 0;

-- ---------------------------------------------------------------- меню
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
  obj('RefProductCharacteristic', 'CATALOG', 'Catalogs', 'Характеристики номенклатури', 490, 491, 110, null);
  obj('RefProductSeries',         'CATALOG', 'Catalogs', 'Серії номенклатури',          500, 501, 120, null);
  obj('ExpiringGoods',            'REPORT',  'Reports',  'Товари з терміном, що спливає', 510, null, 190, null);
  fp('Reference', 'Номенклатура', 1, 10, 'RefProductCharacteristic', 16);
  fp('Reference', 'Номенклатура', 1, 10, 'RefProductSeries', 17);
  fp('Warehouse', 'НСІ', 3, 10, 'RefProductSeries', 60);
  fp('Warehouse', 'Звіти', 2, 10, 'ExpiringGoods', 40);
  fp('Sales', 'Звіти', 2, 10, 'ExpiringGoods', 70);
  fp('Main', 'Звіти', 2, 10, 'ExpiringGoods', 60);
  commit;
end;
/

-- Перекомпіляція залежних об'єктів
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
