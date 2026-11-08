-- =============================================================================
-- Trade r5 — F-RET-01 «Роздрібні продажі: РМК, чек ККМ, ПРРО» (APE-68). Паспорти RefCashRegister,
-- DocRetailReceipt (PROPOSED).
--   * довідник ref_cash_register «Каси ККМ (ПРРО)»: організація, склад (не ордерний), каса для
--     готівки (UAH, тієї ж організації), банківський рахунок для оплат карткою (до еквайрингу APE-183),
--     вид цін (роздрібна), роздрібний покупець (контрагент для RegSales), ознака «Фіскальна» й
--     фіскальний номер ПРРО (10 цифр), провайдер ПРРО (STUB — імітація; CHECKBOX / DPS — резерв),
--     лічильник фіскальних чеків;
--   * документ doc_retail_receipt «Чек ККМ» (вид SALE; RETURN, base_receipt_id — резерв для чека
--     повернення APE-187; shift_id — резерв для касових змін APE-179): каса ККМ → організація, склад,
--     каса, покупець, вид цін; рядки — товар / послуга, кількість, ціна (роздрібна ціна на дату чека),
--     сума, ставка й сума ПДВ (ціни завжди включають ПДВ; організація не платник → «Без ПДВ»);
--     оплата готівкою / карткою / змішана, решта;
--   * проведення (trade_retail.post): RegStockBalance −товари, RegStockCost −середня ковзна,
--     RegSales (роздрібний покупець, сума з ПДВ), RegCashBalance: + готівка (сума − картка) у касу,
--     + картка на банківський рахунок каси ККМ (якщо вказано); контроль вільного залишку й оплати;
--     FEFO-серії (trade_series, db/38); після проведення — фіскалізація (trade_prro);
--   * ПРРО (trade_prro): заглушка без звернення до ДПС / Checkbox — фіскальний номер чека з лічильника
--     каси, посилання на перевірку чека, JSON-запит у форматі, близькому до Checkbox API (для
--     майбутньої інтеграції); фіскалізований чек не скасовується (лише чек повернення — APE-187);
--   * РМК (сторінка 660): сканування штрихкоду / артикулу («3*код» — кількість), кошик, +/−/×,
--     оплата готівкою / карткою / змішана, решта, друк чека; trade_retail.scan / pay / cart_html;
--   * друк RETAIL_RECEIPT (db/20), v_recorder (+ DocRetailReceipt), trade_org.doc_table (db/24),
--     trade_core.catalog_table (db/02), trade_series.lines_table (db/38), trade_event_log (db/37),
--     trade_r3.rebuild_stock_cost (db/14) — правки в тих скриптах; меню «Продажі → Роздрібні продажі».
-- Потребує 02, 06, 14, 20, 24, 27, 37, 38, 40, 42. Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено (усі реєстратори r1–r5).
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefCashRegister
  ddl('create sequence ref_cash_register_code_seq nocache');
  ddl(q'[create table ref_cash_register (
    id              varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code            varchar2(9)   not null,
    name            varchar2(255) not null,
    organization_id varchar2(32)  not null,
    warehouse_id    varchar2(32)  not null,
    cash_desk_id    varchar2(32)  not null,
    bank_account_id varchar2(32),
    price_type_id   varchar2(32)  not null,
    customer_id     varchar2(32)  not null,
    is_fiscal       varchar2(1)   default on null 'Y' not null,
    fiscal_number   varchar2(10),
    prro_provider   varchar2(20)  default on null 'STUB' not null,
    fiscal_seq      number(10)    default on null 0 not null,
    note            varchar2(1000),
    state           varchar2(20)  default on null 'ACTIVE' not null,
    version         number(19)    default on null 0 not null,
    created_at timestamp not null, created_by varchar2(255) not null,
    updated_at timestamp not null, updated_by varchar2(255) not null,
    constraint ref_cash_register_pk primary key (id),
    constraint ref_cash_register_code_uk unique (code),
    constraint ref_cash_register_fn_uk unique (fiscal_number),
    constraint ref_cash_register_org_fk foreign key (organization_id) references ref_organization (id),
    constraint ref_cash_register_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint ref_cash_register_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id),
    constraint ref_cash_register_bank_fk foreign key (bank_account_id) references ref_bank_account (id),
    constraint ref_cash_register_pt_fk foreign key (price_type_id) references ref_price_type (id),
    constraint ref_cash_register_cp_fk foreign key (customer_id) references ref_counterparty (id),
    constraint ref_cash_register_fiscal_ck check (is_fiscal in ('Y','N')),
    constraint ref_cash_register_prov_ck check (prro_provider in ('STUB','CHECKBOX','DPS')),
    constraint ref_cash_register_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_cash_register_org_ix on ref_cash_register (organization_id)');

  -- ---------------------------------------------------------------- DocRetailReceipt
  ddl('create sequence doc_retail_receipt_num_seq nocache');
  ddl(q'[create table doc_retail_receipt (
    id               varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number       varchar2(9)    not null,
    occurred_at      date           default on null sysdate not null,
    organization_id  varchar2(32)   not null,
    cash_register_id varchar2(32)   not null,
    warehouse_id     varchar2(32)   not null,
    cash_desk_id     varchar2(32)   not null,
    bank_account_id  varchar2(32),
    customer_id      varchar2(32)   not null,
    price_type_id    varchar2(32)   not null,
    receipt_kind     varchar2(10)   default on null 'SALE' not null,
    base_receipt_id  varchar2(32),
    shift_id         varchar2(32),
    total_amount     number(19,2)   default on null 0 not null,
    vat_amount       number(19,2)   default on null 0 not null,
    paid_cash        number(19,2),
    paid_card        number(19,2),
    change_amount    number(19,2)   default on null 0 not null,
    fiscal_status    varchar2(20)   default on null 'PENDING' not null,
    fiscal_number    varchar2(40),
    fiscal_at        date,
    fiscal_url       varchar2(500),
    fiscal_payload   clob,
    cashier_name     varchar2(255),
    doc_comment      varchar2(1000),
    status           varchar2(10)   default on null 'DRAFT' not null,
    version          number(19)     default on null 0 not null,
    created_at       timestamp      not null,
    created_by       varchar2(255)  not null,
    updated_at       timestamp      not null,
    updated_by       varchar2(255)  not null,
    constraint doc_retail_receipt_pk primary key (id),
    constraint doc_retail_receipt_num_uk unique (doc_number),
    constraint doc_retail_receipt_status_ck check (status in ('DRAFT','POSTED')),
    constraint doc_retail_receipt_kind_ck check (receipt_kind in ('SALE','RETURN')),
    constraint doc_retail_receipt_fs_ck check (fiscal_status in ('PENDING','NOT_FISCAL','FISCALIZED')),
    constraint doc_retail_receipt_pay_ck check (nvl(paid_cash, 0) >= 0 and nvl(paid_card, 0) >= 0),
    constraint doc_retail_receipt_org_fk foreign key (organization_id) references ref_organization (id),
    constraint doc_retail_receipt_reg_fk foreign key (cash_register_id) references ref_cash_register (id),
    constraint doc_retail_receipt_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint doc_retail_receipt_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id),
    constraint doc_retail_receipt_bank_fk foreign key (bank_account_id) references ref_bank_account (id),
    constraint doc_retail_receipt_cp_fk foreign key (customer_id) references ref_counterparty (id),
    constraint doc_retail_receipt_pt_fk foreign key (price_type_id) references ref_price_type (id),
    constraint doc_retail_receipt_base_fk foreign key (base_receipt_id) references doc_retail_receipt (id))]');
  ddl('create index doc_retail_receipt_date_ix on doc_retail_receipt (occurred_at)');
  ddl('create index doc_retail_receipt_reg_ix on doc_retail_receipt (cash_register_id, status)');
  ddl('create index doc_retail_receipt_base_ix on doc_retail_receipt (base_receipt_id)');
  ddl(q'[create table doc_retail_receipt_goods (
    id                varchar2(32)  default on null rawtohex(sys_guid()) not null,
    document_id       varchar2(32)  not null,
    line_number       number(10)    default on null 0 not null,
    product_id        varchar2(32)  not null,
    characteristic_id varchar2(32),
    series_id         varchar2(32),
    quantity          number(19,3)  not null,
    price             number(19,2),
    amount            number(19,2)  default on null 0 not null,
    vat_rate_code     varchar2(10),
    vat_amount        number(19,2)  default on null 0 not null,
    cost_amount       number(19,2)  default on null 0 not null,
    constraint doc_retail_receipt_goods_pk primary key (id),
    constraint doc_retail_rcpt_goods_doc_fk foreign key (document_id) references doc_retail_receipt (id) on delete cascade,
    constraint doc_retail_rcpt_goods_prd_fk foreign key (product_id) references ref_product (id),
    constraint doc_retail_rcpt_goods_chr_fk foreign key (characteristic_id) references ref_product_characteristic (id),
    constraint doc_retail_rcpt_goods_ser_fk foreign key (series_id) references ref_product_series (id),
    constraint doc_retail_rcpt_goods_vat_fk foreign key (vat_rate_code) references ref_vat_rate (code),
    constraint doc_retail_rcpt_goods_qty_ck check (quantity > 0),
    constraint doc_retail_rcpt_goods_price_ck check (price is null or price >= 0))]');
  ddl('create index doc_retail_rcpt_goods_doc_ix on doc_retail_receipt_goods (document_id, line_number)');
  ddl('create index doc_retail_rcpt_goods_prd_ix on doc_retail_receipt_goods (product_id)');
end;
/

-- =============================================================================
-- trade_prro — програмний РРО (заглушка; API для інтеграції Checkbox / ДПС)
-- =============================================================================
create or replace package trade_prro as
  -- Фіскалізація проведеного чека: фіскальна каса — номер / час / посилання / JSON-запит, інакше NOT_FISCAL
  procedure fiscalize (p_receipt_id in varchar2);
  -- JSON-запит чека (формат, близький до Checkbox API: goods / payments / суми в копійках)
  function receipt_payload (p_receipt_id in varchar2) return clob;
  function status_name (p_status in varchar2) return varchar2;
  function provider_name (p_provider in varchar2) return varchar2;
end trade_prro;
/

-- =============================================================================
-- trade_retail — каси ККМ, чек ККМ, робоче місце касира
-- =============================================================================
create or replace package trade_retail as
  c_type constant varchar2(60) := 'DocRetailReceipt';
  c_customer_name constant varchar2(100) := 'Роздрібний покупець';

  -- ---------- каси ККМ
  -- Контрагент «Роздрібний покупець» (створюється за потреби)
  function retail_customer return varchar2;
  -- Роздрібний вид цін за замовчуванням (назва «Роздрібна», інакше перший активний)
  function retail_price_type return varchar2;
  -- Каса ККМ за замовчуванням: з останнього чека користувача, інакше перша активна
  function default_register return varchar2;
  procedure check_register (p_inserting in boolean, p_id in varchar2, p_org in out varchar2, p_wh in varchar2,
                            p_desk in varchar2, p_bank in varchar2, p_pt in out varchar2, p_cp in out varchar2,
                            p_fiscal in varchar2, p_fn in out varchar2, p_provider in varchar2);

  -- ---------- чек
  procedure check_header (p_inserting in boolean, p_register in varchar2, p_old_register in varchar2,
                          p_org out varchar2, p_wh out varchar2, p_desk out varchar2, p_bank out varchar2,
                          p_cp out varchar2, p_pt out varchar2, p_kind in varchar2);
  -- Тригер рядків: перевірка, ціна (роздрібна на дату), сума, ПДВ
  procedure calc_line (p_doc_id in varchar2, p_product_id in varchar2, p_qty in number, p_check_ref in boolean,
                       p_price in out number, p_amount out number, p_vat_code out varchar2, p_vat out number);
  procedure update_totals (p_doc_id in varchar2);
  procedure post   (p_id in varchar2);
  procedure unpost (p_id in varchar2);
  function  copy   (p_id in varchar2) return varchar2;
  -- Рухи RegStockCost (проведення й trade_r3.rebuild_stock_cost)
  procedure cost_receipt (p_id in varchar2);

  -- ---------- РМК
  -- Новий чек (чернетка) на касі ККМ
  function new_receipt (p_register_id in varchar2) return varchar2;
  -- Відкрита чернетка користувача на касі (сьогодні) або null
  function open_draft (p_register_id in varchar2) return varchar2;
  -- Сканер: штрихкод / артикул / код / назва, «N*код» — кількість N; рядок того ж товару збільшується.
  -- Повертає чек (створює чернетку, якщо p_receipt_id порожній)
  function scan (p_register_id in varchar2, p_receipt_id in varchar2, p_text in varchar2) return varchar2;
  procedure add_product (p_receipt_id in varchar2, p_product_id in varchar2, p_qty in number);
  -- Сканер у формі чека (генератор: scan_call(kind, id, text))
  procedure doc_scan (p_kind in varchar2, p_receipt_id in varchar2, p_text in varchar2);
  -- Сума, введена касиром: «1 000,50» / «1000.5» → число (порожньо — null)
  function parse_amount (p_text in varchar2) return number;
  -- Зміна кількості рядка на p_delta (≤ 0 після зміни — рядок видаляється)
  procedure change_qty (p_line_id in varchar2, p_delta in number);
  procedure set_qty (p_line_id in varchar2, p_qty in number);
  procedure delete_line (p_line_id in varchar2);
  -- Видалити чернетку чека (скасування на РМК)
  procedure cancel_receipt (p_receipt_id in varchar2);
  -- Оплата й проведення: p_cash — внесено готівкою (null — без готівки), p_card — карткою
  procedure pay (p_receipt_id in varchar2, p_cash in number, p_card in number);
  -- HTML кошика й останнього чека для РМК
  function cart_html (p_receipt_id in varchar2) return clob;
  function last_html (p_receipt_id in varchar2) return clob;
  function receipt_total (p_receipt_id in varchar2) return number;

  function kind_name (p_kind in varchar2) return varchar2;
  -- Друк: RETAIL_RECEIPT — касовий чек
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
end trade_retail;
/

-- ---------------------------------------------------------------- представлення (до тіл пакетів)
create or replace view v_cash_register_list as
select r.id, r.code, r.name, r.organization_id, o.name organization_name, r.warehouse_id, w.name warehouse_name,
       r.cash_desk_id, k.name cash_desk_name, r.bank_account_id, b.name bank_account_name,
       r.price_type_id, pt.name price_type_name, r.customer_id, c.name customer_name,
       r.is_fiscal, case r.is_fiscal when 'Y' then 'Так' else 'Ні' end fiscal_name, r.fiscal_number,
       r.prro_provider, trade_prro.provider_name(r.prro_provider) provider_name, r.fiscal_seq, r.state
  from ref_cash_register r
  join ref_organization o on o.id = r.organization_id
  join ref_warehouse w on w.id = r.warehouse_id
  join ref_cash_desk k on k.id = r.cash_desk_id
  left join ref_bank_account b on b.id = r.bank_account_id
  join ref_price_type pt on pt.id = r.price_type_id
  join ref_counterparty c on c.id = r.customer_id;

create or replace view v_retail_receipt_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name, d.cash_register_id,
       r.name cash_register_name, d.warehouse_id, w.name warehouse_name, d.receipt_kind,
       trade_retail.kind_name(d.receipt_kind) kind_name, d.total_amount, d.vat_amount, d.paid_cash, d.paid_card,
       d.change_amount, d.fiscal_status, trade_prro.status_name(d.fiscal_status) fiscal_status_name, d.fiscal_number,
       d.fiscal_at, d.cashier_name, d.shift_id, d.status, d.doc_comment, d.created_by,
       (select count(*) from doc_retail_receipt_goods g where g.document_id = d.id) lines_count
  from doc_retail_receipt d
  join ref_organization o on o.id = d.organization_id
  join ref_cash_register r on r.id = d.cash_register_id
  join ref_warehouse w on w.id = d.warehouse_id;

create or replace package body trade_prro as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;

  function status_name (p_status in varchar2) return varchar2 is
  begin
    return case p_status when 'FISCALIZED' then 'Фіскалізовано' when 'NOT_FISCAL' then 'Нефіскальний'
                         when 'PENDING' then 'Не фіскалізовано' end;
  end status_name;

  function provider_name (p_provider in varchar2) return varchar2 is
  begin
    return case p_provider when 'STUB' then 'Імітація (без ДПС)' when 'CHECKBOX' then 'Checkbox'
                           when 'DPS' then 'ПРРО ДПС' end;
  end provider_name;

  function receipt_payload (p_receipt_id in varchar2) return clob is
    l clob;
  begin
    select json_object(
             'id' value d.id,
             'type' value case d.receipt_kind when 'RETURN' then 'RETURN' else 'SELL' end,
             'cashier_name' value d.cashier_name,
             'fiscal_code' value r.fiscal_number,
             'local_number' value d.doc_number,
             'goods' value (select json_arrayagg(json_object(
                                     'good' value json_object('code' value p.code, 'name' value p.name,
                                                              'price' value round(g.price * 100),
                                                              'tax' value json_array(nvl(g.vat_rate_code, 'NOVAT'))),
                                     'quantity' value round(g.quantity * 1000),
                                     'sum' value round(g.amount * 100),
                                     'vat' value round(g.vat_amount * 100)) order by g.line_number returning clob)
                              from doc_retail_receipt_goods g join ref_product p on p.id = g.product_id
                             where g.document_id = d.id) format json,
             'payments' value json_array(
                 json_object('type' value 'CASH', 'value' value round((d.total_amount - nvl(d.paid_card, 0) + d.change_amount) * 100)),
                 json_object('type' value 'CASHLESS', 'value' value round(nvl(d.paid_card, 0) * 100))),
             'total_sum' value round(d.total_amount * 100),
             'total_vat' value round(d.vat_amount * 100),
             'rest' value round(d.change_amount * 100)
             returning clob)
      into l
      from doc_retail_receipt d join ref_cash_register r on r.id = d.cash_register_id
     where d.id = p_receipt_id;
    return l;
  end receipt_payload;

  procedure fiscalize (p_receipt_id in varchar2) is
    d doc_retail_receipt%rowtype;
    r ref_cash_register%rowtype;
    l_seq number; l_fn varchar2(40); l_prev boolean := trade_core.g_internal; l_payload clob;
  begin
    select * into d from doc_retail_receipt where id = p_receipt_id for update;
    if d.status <> 'POSTED' then
      fail('PRRO_NOT_POSTED', 'Фіскалізувати можна лише проведений чек.');
    end if;
    if d.fiscal_status = 'FISCALIZED' then
      return;
    end if;
    select * into r from ref_cash_register where id = d.cash_register_id for update;
    trade_core.g_internal := true;
    if r.is_fiscal = 'N' then
      update doc_retail_receipt set fiscal_status = 'NOT_FISCAL' where id = p_receipt_id;
    else
      if r.fiscal_number is null then
        fail('PRRO_FISCAL_NUMBER_REQUIRED', 'Для фіскальної каси ККМ «' || r.name || '» не вказано фіскальний номер ПРРО.');
      end if;
      if r.prro_provider <> 'STUB' then
        -- Інтеграція з Checkbox / ПРРО ДПС — окреме завдання; тут лише імітація
        fail('PRRO_PROVIDER_NOT_SUPPORTED', 'Провайдер ПРРО «' || provider_name(r.prro_provider)
             || '» ще не підключено. Використайте режим «Імітація (без ДПС)».');
      end if;
      update ref_cash_register set fiscal_seq = fiscal_seq + 1 where id = r.id returning fiscal_seq into l_seq;
      -- Імітація фіскального номера чека: ФН ПРРО + порядковий номер (у реальному ПРРО номер присвоює ДПС)
      l_fn := r.fiscal_number || '.' || lpad(l_seq, 6, '0');
      update doc_retail_receipt
         set fiscal_status = 'FISCALIZED', fiscal_number = l_fn, fiscal_at = sysdate,
             fiscal_url = 'https://cabinet.tax.gov.ua/cashregs/check?fn=' || r.fiscal_number || '&id=' || l_fn
                          || '&date=' || to_char(d.occurred_at, 'YYYYMMDD') || '&time=' || to_char(d.occurred_at, 'HH24MISS')
                          || '&sm=' || to_char(d.total_amount, 'FM999999990D00', 'NLS_NUMERIC_CHARACTERS=''.,''')
       where id = p_receipt_id;
      l_payload := receipt_payload(p_receipt_id);
      update doc_retail_receipt set fiscal_payload = l_payload where id = p_receipt_id;
    end if;
    trade_core.g_internal := l_prev;
    trade_core.audit('DocRetailReceipt', p_receipt_id, 'FISCALIZE', nvl(l_fn, 'NOT_FISCAL'));
  exception when others then trade_core.g_internal := l_prev; raise;
  end fiscalize;

end trade_prro;
/
show errors package body trade_prro

create or replace package body trade_retail as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return rtrim(to_char(p, 'FM999G999G990D999'), '.,'); end;

  function kind_name (p_kind in varchar2) return varchar2 is
  begin
    return case p_kind when 'SALE' then 'Продаж' when 'RETURN' then 'Повернення' end;
  end kind_name;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_product where id = p_id;
    return l;
  end prd_name;

  -- =========================================================== каси ККМ
  function retail_customer return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by code) into l from ref_counterparty
     where name = c_customer_name and state = 'ACTIVE';
    if l is null then
      insert into ref_counterparty (name, vat_payer) values (c_customer_name, 'N') returning id into l;
    end if;
    return l;
  end retail_customer;

  function retail_price_type return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by case when name = 'Роздрібна' then 0 else 1 end, code) into l
      from ref_price_type where state = 'ACTIVE';
    return l;
  end retail_price_type;

  function default_register return varchar2 is
    l varchar2(32);
  begin
    select max(d.cash_register_id) keep (dense_rank last order by d.created_at) into l
      from doc_retail_receipt d join ref_cash_register r on r.id = d.cash_register_id
     where d.created_by = trade_core.current_user_name and r.state = 'ACTIVE';
    if l is null then
      select max(id) keep (dense_rank first order by code) into l from ref_cash_register where state = 'ACTIVE';
    end if;
    return l;
  end default_register;

  procedure check_register (p_inserting in boolean, p_id in varchar2, p_org in out varchar2, p_wh in varchar2,
                            p_desk in varchar2, p_bank in varchar2, p_pt in out varchar2, p_cp in out varchar2,
                            p_fiscal in varchar2, p_fn in out varchar2, p_provider in varchar2) is
    l_org varchar2(32); l_cur varchar2(3); l_n number;
  begin
    if p_desk is null then
      fail('CASH_REGISTER_DESK_REQUIRED', 'Вкажіть касу для готівкової виручки.');
    end if;
    select organization_id, currency_code into l_org, l_cur from ref_cash_desk where id = p_desk;
    p_org := coalesce(p_org, l_org);
    trade_core.check_active_ref('REF_ORGANIZATION', p_org, 'Організація');
    trade_core.check_active_ref('REF_CASH_DESK', p_desk, 'Каса');
    if l_org <> p_org then
      fail('CASH_REGISTER_DESK_ORG', 'Каса для готівки має належати організації каси ККМ.');
    end if;
    if l_cur <> 'UAH' then
      fail('CASH_REGISTER_DESK_CURRENCY', 'Каса для готівкової виручки має бути в гривні (UAH).');
    end if;
    trade_core.check_active_ref('REF_WAREHOUSE', p_wh, 'Склад');
    select count(*) into l_n from ref_warehouse where id = p_wh and use_order_scheme = 'Y';
    if l_n > 0 then
      fail('CASH_REGISTER_ORDER_WAREHOUSE', 'Склад з ордерною схемою не може бути складом каси ККМ: товар у роздрібному '
           || 'продажу видається покупцю одразу (роздрібні склади й магазини — окреме завдання).');
    end if;
    if p_bank is not null then
      select organization_id, currency_code into l_org, l_cur from ref_bank_account where id = p_bank;
      if l_org <> p_org or l_cur <> 'UAH' then
        fail('CASH_REGISTER_BANK_ACCOUNT', 'Рахунок для оплат карткою має належати організації каси ККМ і бути в UAH.');
      end if;
    end if;
    p_pt := coalesce(p_pt, retail_price_type);
    trade_core.check_active_ref('REF_PRICE_TYPE', p_pt, 'Вид цін');
    p_cp := coalesce(p_cp, retail_customer);
    trade_core.check_active_ref('REF_COUNTERPARTY', p_cp, 'Роздрібний покупець');
    p_fn := trim(p_fn);
    if p_fn is not null and (length(p_fn) <> 10 or translate(p_fn, 'x0123456789', 'x') is not null) then
      fail('CASH_REGISTER_FISCAL_NUMBER', 'Фіскальний номер ПРРО — 10 цифр.');
    end if;
    if p_fiscal = 'Y' and p_fn is null then
      fail('PRRO_FISCAL_NUMBER_REQUIRED', 'Для фіскальної каси ККМ вкажіть фіскальний номер ПРРО (10 цифр).');
    end if;
    if not p_inserting and p_id is not null then
      select count(*) into l_n from doc_retail_receipt where cash_register_id = p_id and status = 'POSTED' and organization_id <> p_org;
      if l_n > 0 then
        fail('CASH_REGISTER_HAS_RECEIPTS', 'За касою ККМ є проведені чеки іншої організації — змінити організацію не можна.');
      end if;
    end if;
  end check_register;

  -- =========================================================== чек
  procedure check_header (p_inserting in boolean, p_register in varchar2, p_old_register in varchar2,
                          p_org out varchar2, p_wh out varchar2, p_desk out varchar2, p_bank out varchar2,
                          p_cp out varchar2, p_pt out varchar2, p_kind in varchar2) is
  begin
    if p_kind = 'RETURN' then
      fail('RETAIL_RETURN_NOT_SUPPORTED', 'Чек повернення буде реалізовано окремо (повернення за чеком).');
    end if;
    if p_inserting or p_register <> p_old_register then
      trade_core.check_active_ref('REF_CASH_REGISTER', p_register, 'Каса ККМ');
    end if;
    select organization_id, warehouse_id, cash_desk_id, bank_account_id, customer_id, price_type_id
      into p_org, p_wh, p_desk, p_bank, p_cp, p_pt
      from ref_cash_register where id = p_register;
  end check_header;

  procedure calc_line (p_doc_id in varchar2, p_product_id in varchar2, p_qty in number, p_check_ref in boolean,
                       p_price in out number, p_amount out number, p_vat_code out varchar2, p_vat out number) is
    l_pt varchar2(32); l_at date; l_payer varchar2(1); l_rate varchar2(10);
  begin
    trade_lines.check_goods_r3(p_product_id, p_qty, p_check_ref, false);
    select d.price_type_id, d.occurred_at, nvl(o.vat_payer, 'N') into l_pt, l_at, l_payer
      from doc_retail_receipt d join ref_organization o on o.id = d.organization_id where d.id = p_doc_id;
    if p_price is null then
      p_price := trade_lines.get_price(l_pt, p_product_id, l_at);
    end if;
    if p_price is null then
      fail('RETAIL_PRICE_NOT_SET', 'Не встановлено роздрібну ціну товару «' || prd_name(p_product_id) || '».');
    end if;
    p_amount := round(p_qty * p_price, 2);
    if l_payer = 'Y' then
      select coalesce(max(vat_rate_code), 'VAT20') into l_rate from ref_product where id = p_product_id;
    else
      l_rate := 'NOVAT';
    end if;
    p_vat_code := l_rate;
    p_vat := trade_vat.vat_of(p_amount, l_rate, 'Y');
  end calc_line;

  procedure update_totals (p_doc_id in varchar2) is
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    update doc_retail_receipt d
       set (total_amount, vat_amount) = (select coalesce(sum(amount), 0), coalesce(sum(vat_amount), 0)
                                           from doc_retail_receipt_goods where document_id = d.id)
     where d.id = p_doc_id;
    trade_core.g_internal := l_prev;
  exception when others then trade_core.g_internal := l_prev; raise;
  end update_totals;

  procedure delete_movements (p_id varchar2) is
  begin
    delete from reg_stock_balance_movement where recorder_type = c_type and recorder_id = p_id;
    delete from reg_sales_turnover where recorder_type = c_type and recorder_id = p_id;
    trade_r3.delete_r3_movements(c_type, p_id);
    trade_cash.delete_movements(c_type, p_id);
  end delete_movements;

  procedure cost_receipt (p_id in varchar2) is
    d doc_retail_receipt%rowtype;
    l_c number;
  begin
    select * into d from doc_retail_receipt where id = p_id;
    for l in (select g.line_number, g.product_id, g.quantity from doc_retail_receipt_goods g
                join ref_product p on p.id = g.product_id
               where g.document_id = p_id and p.product_kind = 'GOODS' order by g.line_number) loop
      l_c := trade_r3.out_cost(d.warehouse_id, l.product_id, l.quantity);
      trade_r3.add_cost(c_type, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, -l.quantity, -l_c);
      update doc_retail_receipt_goods set cost_amount = l_c where document_id = p_id and line_number = l.line_number;
    end loop;
  end cost_receipt;

  procedure series_prepare (p_id varchar2) is
  begin
    execute immediate 'begin trade_series.prepare_post(:t, :i); end;' using c_type, p_id;
  exception when others then
    if sqlcode = -6550 then null; else raise; end if;   -- db/38 не встановлено
  end series_prepare;

  procedure post (p_id in varchar2) is
    d doc_retail_receipt%rowtype;
    l_dummy varchar2(32); l_cnt pls_integer; l_cash number; l_card number; l_change number;
  begin
    select * into d from doc_retail_receipt where id = p_id for update;
    select count(*) into l_cnt from doc_retail_receipt_goods where document_id = p_id;
    if l_cnt = 0 then
      fail('NO_LINES', 'Неможливо провести чек без товарів.');
    end if;
    if d.fiscal_status = 'FISCALIZED' then
      fail('RETAIL_FISCALIZED', 'Чек уже фіскалізовано — повторне проведення неможливе.');
    end if;
    trade_core.check_active_ref('REF_CASH_REGISTER', d.cash_register_id, 'Каса ККМ');
    series_prepare(p_id);
    select * into d from doc_retail_receipt where id = p_id;
    if d.total_amount <= 0 then
      fail('RETAIL_ZERO_TOTAL', 'Сума чека має бути більшою за нуль.');
    end if;
    -- Оплата: без вказаної оплати — готівкою без решти
    l_card := nvl(d.paid_card, 0);
    l_cash := case when d.paid_cash is null and l_card = 0 then d.total_amount else nvl(d.paid_cash, 0) end;
    if l_card > d.total_amount then
      fail('RETAIL_CARD_EXCEEDS_TOTAL', 'Оплата карткою (' || m(l_card) || ') перевищує суму чека (' || m(d.total_amount) || ').');
    end if;
    if l_cash + l_card < d.total_amount then
      fail('RETAIL_UNDERPAID', 'Недостатньо оплати: до сплати ' || m(d.total_amount) || ' грн, внесено '
           || m(l_cash + l_card) || ' грн, не вистачає ' || m(d.total_amount - l_cash - l_card) || ' грн.');
    end if;
    l_change := l_cash + l_card - d.total_amount;
    select id into l_dummy from ref_warehouse where id = d.warehouse_id for update;
    trade_core.g_internal := true;
    delete_movements(p_id);
    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select d.occurred_at, c_type, p_id, g.line_number, d.warehouse_id, g.product_id, -g.quantity
      from doc_retail_receipt_goods g join ref_product p on p.id = g.product_id
     where g.document_id = p_id and p.product_kind = 'GOODS';
    cost_receipt(p_id);
    insert into reg_sales_turnover (period, recorder_type, recorder_id, line_number, counterparty_id, warehouse_id, product_id, quantity, amount)
    select d.occurred_at, c_type, p_id, line_number, d.customer_id, d.warehouse_id, product_id, quantity, amount
      from doc_retail_receipt_goods where document_id = p_id;
    trade_cash.add_movement(c_type, p_id, d.occurred_at, 1, trade_cash.c_cash_desk, d.cash_desk_id,
                            d.total_amount - l_card, 'RETAIL_SALE', 'Чек ККМ № ' || d.doc_number || ' — готівка');
    if l_card > 0 then
      if d.bank_account_id is not null then
        trade_cash.add_movement(c_type, p_id, d.occurred_at, 2, trade_cash.c_bank_account, d.bank_account_id,
                                l_card, 'RETAIL_CARD', 'Чек ККМ № ' || d.doc_number || ' — оплата карткою');
      else
        trade_warn.add('RETAIL_CARD_NO_ACCOUNT', 'оплату карткою ' || m(l_card)
                       || ' грн не відображено в коштах: у касі ККМ не вказано рахунок для оплат карткою.');
      end if;
    end if;
    trade_r3.check_free_stock_doc('DOC_RETAIL_RECEIPT_GOODS', p_id, d.warehouse_id);
    trade_cash.check_balances;
    update doc_retail_receipt
       set status = 'POSTED', paid_cash = case when l_cash = 0 and d.paid_cash is null then null else l_cash end,
           paid_card = case when l_card = 0 then null else l_card end, change_amount = l_change,
           cashier_name = coalesce(cashier_name, trade_core.current_user_name)
     where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'POST');
    trade_prro.fiscalize(p_id);
  exception when others then trade_core.g_internal := false; raise;
  end post;

  procedure unpost (p_id in varchar2) is
    d doc_retail_receipt%rowtype;
  begin
    select * into d from doc_retail_receipt where id = p_id for update;
    if d.status <> 'POSTED' then
      fail('NOT_POSTED', 'Документ не проведено.');
    end if;
    if d.fiscal_status = 'FISCALIZED' then
      fail('RETAIL_FISCALIZED', 'Чек фіскалізовано (ФН ' || d.fiscal_number || ') — скасувати проведення не можна. '
           || 'Оформіть чек повернення.');
    end if;
    trade_core.g_internal := true;
    delete_movements(p_id);
    trade_cash.check_balances;
    update doc_retail_receipt_goods set cost_amount = 0 where document_id = p_id;
    update doc_retail_receipt set status = 'DRAFT', fiscal_status = 'PENDING', change_amount = 0 where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost;

  function copy (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_retail_receipt (id, occurred_at, cash_register_id, doc_comment)
    select l_new, sysdate, cash_register_id, doc_comment from doc_retail_receipt where id = p_id;
    insert into doc_retail_receipt_goods (document_id, line_number, product_id, characteristic_id, quantity)
    select l_new, line_number, product_id, characteristic_id, quantity from doc_retail_receipt_goods where document_id = p_id;
    trade_core.audit(c_type, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy;

  -- =========================================================== РМК
  function new_receipt (p_register_id in varchar2) return varchar2 is
    l varchar2(32);
  begin
    if p_register_id is null then
      fail('CASH_REGISTER_REQUIRED', 'Виберіть касу ККМ.');
    end if;
    insert into doc_retail_receipt (cash_register_id) values (p_register_id) returning id into l;
    return l;
  end new_receipt;

  function open_draft (p_register_id in varchar2) return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank last order by created_at) into l from doc_retail_receipt
     where cash_register_id = p_register_id and status = 'DRAFT' and created_by = trade_core.current_user_name
       and occurred_at >= trunc(sysdate);
    return l;
  end open_draft;

  procedure add_product (p_receipt_id in varchar2, p_product_id in varchar2, p_qty in number) is
    l_line varchar2(32); l_uc varchar2(1);
  begin
    select max(use_characteristics) into l_uc from ref_product where id = p_product_id;
    if l_uc = 'Y' then
      fail('RETAIL_CHARACTERISTIC_REQUIRED', 'Товар «' || prd_name(p_product_id)
           || '» обліковується за характеристиками — додайте його у формі чека з вибором характеристики.');
    end if;
    select max(id) into l_line from doc_retail_receipt_goods
     where document_id = p_receipt_id and product_id = p_product_id and series_id is null;
    if l_line is not null then
      update doc_retail_receipt_goods set quantity = quantity + p_qty where id = l_line;
    else
      insert into doc_retail_receipt_goods (document_id, line_number, product_id, quantity)
      values (p_receipt_id, 999999, p_product_id, p_qty);
    end if;
  end add_product;

  function scan (p_register_id in varchar2, p_receipt_id in varchar2, p_text in varchar2) return varchar2 is
    l_text varchar2(255) := trim(p_text);
    l_qty number := 1; l_prd varchar2(32); l_id varchar2(32) := p_receipt_id; l_st varchar2(10);
    l_pos pls_integer := instr(l_text, '*');
  begin
    if l_text is null then
      return l_id;
    end if;
    if l_pos > 1 then
      begin
        l_qty := to_number(replace(trim(substr(l_text, 1, l_pos - 1)), ',', '.'), '999999999D999', 'NLS_NUMERIC_CHARACTERS=''.,''');
      exception when others then
        fail('RETAIL_SCAN_QTY', 'Неправильна кількість «' || substr(l_text, 1, l_pos - 1) || '». Формат: 3*штрихкод.');
      end;
      l_text := trim(substr(l_text, l_pos + 1));
    end if;
    if l_qty <= 0 then
      fail('RETAIL_SCAN_QTY', 'Кількість має бути більшою за нуль.');
    end if;
    l_prd := trade_nsi.lookup_product(l_text);
    if l_prd is null then
      fail('BARCODE_NOT_FOUND', 'Товар зі штрихкодом/артикулом «' || l_text || '» не знайдено.');
    end if;
    if l_id is not null then
      select max(status) into l_st from doc_retail_receipt where id = l_id;
      if nvl(l_st, '-') <> 'DRAFT' then l_id := null; end if;
    end if;
    if l_id is null then
      l_id := new_receipt(p_register_id);
    end if;
    add_product(l_id, l_prd, l_qty * trade_nsi.lookup_barcode_qty(l_text));
    return l_id;
  end scan;

  procedure doc_scan (p_kind in varchar2, p_receipt_id in varchar2, p_text in varchar2) is
    l_reg varchar2(32); l varchar2(32);
  begin
    select cash_register_id into l_reg from doc_retail_receipt where id = p_receipt_id;
    l := scan(l_reg, p_receipt_id, p_text);
    if l <> p_receipt_id then
      fail('RETAIL_NOT_DRAFT', 'Чек уже проведено — товари не додаються.');
    end if;
  end doc_scan;

  function parse_amount (p_text in varchar2) return number is
    l varchar2(100) := replace(replace(replace(trim(p_text), ' ', ''), chr(160), ''), ',', '.');
  begin
    if l is null then return null; end if;
    return to_number(l, '999999999990D99', 'NLS_NUMERIC_CHARACTERS=''.,''');
  exception when value_error or invalid_number then
    fail('RETAIL_AMOUNT_INVALID', 'Неправильна сума «' || p_text || '».');
  end parse_amount;

  procedure change_qty (p_line_id in varchar2, p_delta in number) is
    l_q number;
  begin
    select max(quantity) into l_q from doc_retail_receipt_goods where id = p_line_id;
    if l_q is null then return; end if;
    set_qty(p_line_id, l_q + p_delta);
  end change_qty;

  procedure set_qty (p_line_id in varchar2, p_qty in number) is
  begin
    if p_qty is null or p_qty <= 0 then
      delete_line(p_line_id);
    else
      update doc_retail_receipt_goods set quantity = p_qty where id = p_line_id;
    end if;
  end set_qty;

  procedure delete_line (p_line_id in varchar2) is
  begin
    delete from doc_retail_receipt_goods where id = p_line_id;
  end delete_line;

  procedure cancel_receipt (p_receipt_id in varchar2) is
  begin
    if p_receipt_id is not null then
      delete from doc_retail_receipt where id = p_receipt_id and status = 'DRAFT';
    end if;
  end cancel_receipt;

  procedure pay (p_receipt_id in varchar2, p_cash in number, p_card in number) is
    l_st varchar2(10);
  begin
    if p_receipt_id is null then
      fail('NO_LINES', 'Чек порожній — відскануйте товари.');
    end if;
    select max(status) into l_st from doc_retail_receipt where id = p_receipt_id;
    if nvl(l_st, '-') <> 'DRAFT' then
      fail('RETAIL_NOT_DRAFT', 'Чек уже оплачено або видалено.');
    end if;
    if nvl(p_cash, 0) < 0 or nvl(p_card, 0) < 0 then
      fail('RETAIL_PAYMENT_NEGATIVE', 'Сума оплати не може бути від''ємною.');
    end if;
    update doc_retail_receipt set paid_cash = p_cash, paid_card = p_card where id = p_receipt_id;
    post(p_receipt_id);
  end pay;

  function receipt_total (p_receipt_id in varchar2) return number is
    l number;
  begin
    select max(total_amount) into l from doc_retail_receipt where id = p_receipt_id;
    return coalesce(l, 0);
  end receipt_total;

  function cart_html (p_receipt_id in varchar2) return clob is
    l clob; l_n pls_integer := 0;
    function btn (p_req varchar2, p_line varchar2, p_label varchar2, p_title varchar2) return varchar2 is
    begin
      return '<button type="button" class="t-Button t-Button--small t-Button--noUI tx-rmk-btn" title="' || p_title
          || '" onclick="apex.submit({request:''' || p_req || ''',set:{''P660_LINE'':''' || p_line || '''},showWait:true});">'
          || p_label || '</button>';
    end;
  begin
    l := '<style>.tx-rmk{width:100%;border-collapse:collapse;font-size:15px}.tx-rmk th,.tx-rmk td{border-bottom:1px solid #ddd;padding:6px 8px}'
      || '.tx-rmk th{text-align:left;background:#f5f5f0;font-weight:normal;font-size:12px}.tx-rmk .r{text-align:right;white-space:nowrap}'
      || '.tx-rmk .tot td{font-size:20px;font-weight:bold;border-bottom:none}.tx-rmk-btn{min-width:28px;font-weight:bold}'
      || '.tx-rmk-empty{padding:24px;text-align:center;color:#777;font-size:15px}</style>';
    for g in (select g.id, g.line_number, p.name, u.short_name, g.quantity, g.price, g.amount, g.vat_amount
                from doc_retail_receipt_goods g join ref_product p on p.id = g.product_id
                join ref_unit_of_measure u on u.id = p.unit_of_measure_id
               where g.document_id = p_receipt_id order by g.line_number) loop
      if l_n = 0 then
        l := l || '<table class="tx-rmk"><tr><th>№</th><th>Товар</th><th class="r">Кількість</th><th class="r">Ціна</th>'
               || '<th class="r">Сума</th><th class="r">у т. ч. ПДВ</th><th></th></tr>';
      end if;
      l_n := l_n + 1;
      l := l || '<tr><td>' || g.line_number || '</td><td>' || e(g.name) || '</td><td class="r">'
             || btn('LINE_DEC', g.id, '&minus;', 'Зменшити на 1') || ' ' || q(g.quantity) || ' ' || e(g.short_name) || ' '
             || btn('LINE_INC', g.id, '+', 'Збільшити на 1') || '</td><td class="r">' || m(g.price) || '</td><td class="r">'
             || m(g.amount) || '</td><td class="r">' || m(g.vat_amount) || '</td><td class="r">'
             || btn('LINE_DEL', g.id, '&times;', 'Видалити рядок') || '</td></tr>';
    end loop;
    if l_n = 0 then
      return l || '<div class="tx-rmk-empty">Чек порожній. Відскануйте штрихкод або введіть артикул / код товару '
               || '(«3*код» — кількість 3) і натисніть Enter.</div>';
    end if;
    for d in (select total_amount, vat_amount from doc_retail_receipt where id = p_receipt_id) loop
      l := l || '<tr class="tot"><td></td><td>До сплати</td><td></td><td></td><td class="r">' || m(d.total_amount)
             || '</td><td class="r" style="font-size:13px;font-weight:normal">' || m(d.vat_amount) || '</td><td></td></tr>';
    end loop;
    return l || '</table>';
  end cart_html;

  function last_html (p_receipt_id in varchar2) return clob is
    l clob;
  begin
    for d in (select * from doc_retail_receipt where id = p_receipt_id and status = 'POSTED') loop
      l := '<div style="font-size:15px;line-height:1.6">'
        || 'Чек № <b>' || e(d.doc_number) || '</b> від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS')
        || ' — сума <b>' || m(d.total_amount) || ' грн</b>'
        || case when d.paid_cash is not null then ', готівкою ' || m(d.paid_cash) end
        || case when d.paid_card is not null then ', карткою ' || m(d.paid_card) end
        || '<br><span style="font-size:24px">Решта: <b>' || m(d.change_amount) || ' грн</b></span><br>'
        || trade_prro.status_name(d.fiscal_status)
        || case when d.fiscal_number is not null then ', фіскальний номер чека <b>' || e(d.fiscal_number) || '</b>' end
        || '</div>';
    end loop;
    return l;
  end last_html;

  -- =========================================================== друк
  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    r ref_cash_register%rowtype;
    l_wh varchar2(255);
  begin
    if p_form <> 'RETAIL_RECEIPT' then return null; end if;
    for d in (select * from doc_retail_receipt where id = p_id) loop
      select * into o from ref_organization where id = d.organization_id;
      select * into r from ref_cash_register where id = d.cash_register_id;
      select name into l_wh from ref_warehouse where id = d.warehouse_id;
      l := '<div class="tx-print tx-check"><style>'
        || '.tx-check{font-family:"Courier New",monospace;font-size:13px;color:#000;width:340px;background:#fff;padding:14px;position:relative;border:1px dashed #999}'
        || '.tx-check .c{text-align:center}.tx-check .r{text-align:right;white-space:nowrap}.tx-check table{width:100%;border-collapse:collapse}'
        || '.tx-check td{padding:1px 0;vertical-align:top}.tx-check hr{border:none;border-top:1px dashed #000;margin:6px 0}'
        || '.tx-check .b{font-weight:bold}.tx-check .big td{font-size:16px;font-weight:bold}'
        || '.tx-check .wm{position:absolute;top:120px;left:0;right:0;text-align:center;font-size:44px;color:rgba(200,0,0,.15);transform:rotate(-24deg);pointer-events:none;font-weight:bold}'
        || '@media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.tx-check{border:none}}</style>'
        || case when d.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<div class="c b">' || e(coalesce(o.full_name, o.name)) || '</div>'
        || case when o.address is not null then '<div class="c">' || e(o.address) || '</div>' end
        || '<div class="c">' || e(l_wh) || '</div>'
        || case when o.vat_payer = 'Y' and o.vat_number is not null then '<div class="c">ПН ' || e(o.vat_number) || '</div>'
                when o.edrpou is not null then '<div class="c">ІД ' || e(o.edrpou) || '</div>' end
        || '<hr><div>Каса: ' || e(r.name) || '</div><div>Касир: ' || e(coalesce(d.cashier_name, d.created_by)) || '</div>'
        || '<div>Чек № ' || e(d.doc_number) || '</div><hr><table>';
      for g in (select p.name, g.quantity, g.price, g.amount, g.vat_rate_code, v.name vat_name
                  from doc_retail_receipt_goods g join ref_product p on p.id = g.product_id
                  left join ref_vat_rate v on v.code = g.vat_rate_code
                 where g.document_id = p_id order by g.line_number) loop
        l := l || '<tr><td colspan="2">' || e(g.name) || '</td></tr><tr><td>' || q(g.quantity) || ' x ' || m(g.price)
               || '</td><td class="r">' || m(g.amount) || ' ' || case when g.vat_rate_code in ('VAT20', 'VAT7', 'VAT0') then 'А' else 'Б' end
               || '</td></tr>';
      end loop;
      l := l || '</table><hr><table><tr class="big"><td>СУМА</td><td class="r">' || m(d.total_amount) || ' грн</td></tr>';
      for v in (select v.name, g.vat_rate_code, sum(g.vat_amount) vat from doc_retail_receipt_goods g
                  join ref_vat_rate v on v.code = g.vat_rate_code
                 where g.document_id = p_id group by v.name, g.vat_rate_code, v.sort_order order by v.sort_order) loop
        l := l || '<tr><td>' || case when v.vat_rate_code in ('VAT20', 'VAT7', 'VAT0') then 'ПДВ А ' || e(v.name)
                                     else 'Б ' || e(v.name) end
               || '</td><td class="r">' || m(v.vat) || '</td></tr>';
      end loop;
      l := l || case when d.paid_cash is not null then '<tr><td>ГОТІВКА</td><td class="r">' || m(d.paid_cash) || '</td></tr>' end
             || case when d.paid_card is not null then '<tr><td>КАРТКА</td><td class="r">' || m(d.paid_card) || '</td></tr>' end
             || case when d.status = 'POSTED' then '<tr><td>РЕШТА</td><td class="r">' || m(d.change_amount) || '</td></tr>' end
             || '</table><hr>'
             || '<div>' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') || '</div>'
             || case d.fiscal_status
                  when 'FISCALIZED' then '<div>ФН чека: ' || e(d.fiscal_number) || '</div><div>ФН ПРРО: ' || e(r.fiscal_number) || '</div>'
                                      || '<div class="c b">ФІСКАЛЬНИЙ ЧЕК</div>'
                                      || case when r.prro_provider = 'STUB' then '<div class="c">(тестовий режим: без передачі до ДПС)</div>' end
                                      || '<div class="c" style="font-size:10px;word-break:break-all">' || e(d.fiscal_url) || '</div>'
                  when 'NOT_FISCAL' then '<div class="c b">НЕФІСКАЛЬНИЙ ЧЕК</div>'
                  else '<div class="c">Чек не фіскалізовано</div>' end
             || '</div>';
    end loop;
    return l;
  end print_html;

end trade_retail;
/
show errors package body trade_retail

-- ---------------------------------------------------------------- тригери каси ККМ
create or replace trigger ref_cash_register_biu
before insert or update on ref_cash_register for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_CASH_REGISTER_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.fiscal_seq := 0;
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
    if not trade_core.g_internal then
      :new.fiscal_seq := :old.fiscal_seq;   -- лічильник фіскальних чеків — лише ПРРО
    end if;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.note := trim(:new.note);
  trade_retail.check_register(inserting, :new.id, :new.organization_id, :new.warehouse_id, :new.cash_desk_id,
    :new.bank_account_id, :new.price_type_id, :new.customer_id, :new.is_fiscal, :new.fiscal_number, :new.prro_provider);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_cash_register_bd before delete on ref_cash_register
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- тригери чека
create or replace trigger doc_retail_receipt_biud
before insert or update or delete on doc_retail_receipt for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_RETAIL_RECEIPT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0; :new.total_amount := 0; :new.vat_amount := 0; :new.change_amount := 0;
      :new.fiscal_status := 'PENDING'; :new.fiscal_number := null; :new.fiscal_at := null; :new.fiscal_url := null;
      :new.cashier_name := coalesce(trim(:new.cashier_name), trade_core.current_user_name);
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status; :new.total_amount := :old.total_amount; :new.vat_amount := :old.vat_amount;
        :new.change_amount := :old.change_amount; :new.fiscal_status := :old.fiscal_status;
        :new.fiscal_number := :old.fiscal_number; :new.fiscal_at := :old.fiscal_at; :new.fiscal_url := :old.fiscal_url;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    trade_retail.check_header(inserting, :new.cash_register_id, :old.cash_register_id, :new.organization_id,
      :new.warehouse_id, :new.cash_desk_id, :new.bank_account_id, :new.customer_id, :new.price_type_id, :new.receipt_kind);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_retail_receipt_ad after delete on doc_retail_receipt
begin trade_core.g_deleting_doc := false; end;
/
create or replace trigger doc_retail_receipt_goods_ct
for insert or update or delete on doc_retail_receipt_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_RETAIL_RECEIPT', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if :new.line_number is null then :new.line_number := 0; end if;
      if not trade_core.g_internal then
        :new.cost_amount := case when updating then :old.cost_amount else 0 end;   -- собівартість — лише проведенням
      end if;
      if inserting or :new.product_id <> :old.product_id then
        if updating and :new.price = :old.price then
          :new.price := null;   -- інший товар — роздрібна ціна заново
        end if;
      end if;
      trade_retail.calc_line(:new.document_id, :new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id,
                             :new.price, :new.amount, :new.vat_rate_code, :new.vat_amount);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_RETAIL_RECEIPT_GOODS', l_doc);
      trade_retail.update_totals(l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_retail_receipt_goods_ct;
/

-- ---------------------------------------------------------------- реєстратори (+ чек ККМ)
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
union all select 'DocGoodsIssueOrder', d.id, 'Видатковий ордер на товари ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 571 from doc_goods_issue_order d
union all select 'DocTaxInvoice', d.id, case d.direction when 'RECEIVED' then 'Податкова накладна отримана ' else 'Податкова накладна ' end
                 || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 621 from doc_tax_invoice d
union all select 'DocRetailReceipt', d.id, 'Чек ККМ ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 651 from doc_retail_receipt d;

-- ---------------------------------------------------------------- демо: роздрібний покупець і каса ККМ
declare
  l_org varchar2(32); l_wh varchar2(32); l_desk varchar2(32); l_bank varchar2(32); l_n number; l_cp varchar2(32);
begin
  l_cp := trade_retail.retail_customer;
  select count(*) into l_n from ref_cash_register;
  if l_n = 0 then
    select max(id) into l_org from ref_organization where name = 'ТОВ «Трейд Демо»';
    select max(id) keep (dense_rank first order by case name when 'Склад магазину' then 0 else 1 end, code) into l_wh
      from ref_warehouse where use_order_scheme = 'N' and state = 'ACTIVE';
    select max(id) keep (dense_rank first order by code) into l_desk from ref_cash_desk
     where organization_id = l_org and currency_code = 'UAH' and state = 'ACTIVE';
    select max(id) keep (dense_rank first order by case is_default when 'Y' then 0 else 1 end, code) into l_bank
      from ref_bank_account where organization_id = l_org and currency_code = 'UAH' and state = 'ACTIVE';
    if l_org is not null and l_wh is not null and l_desk is not null then
      insert into ref_cash_register (name, organization_id, warehouse_id, cash_desk_id, bank_account_id, is_fiscal, fiscal_number, note)
      values ('Каса ККМ № 1 (магазин)', l_org, l_wh, l_desk, l_bank, 'Y', '4000000001',
              'Демо: ПРРО в режимі імітації — фіскальні номери чеків формуються локально, до ДПС нічого не передається.');
    end if;
  end if;
  commit;
end;
/

-- Демо-чек (проведений і фіскалізований), якщо є залишок і роздрібна ціна
declare
  l_reg varchar2(32); l_id varchar2(32); l_n number;
begin
  select count(*) into l_n from doc_retail_receipt;
  select max(id) keep (dense_rank first order by code) into l_reg from ref_cash_register where state = 'ACTIVE';
  if l_n = 0 and l_reg is not null then
    for p in (select p.id from ref_cash_register r
                join ref_product p on p.product_kind = 'GOODS' and p.state = 'ACTIVE' and p.use_series = 'N' and p.use_characteristics = 'N'
               where r.id = l_reg
                 and trade_r3.stock_qty(r.warehouse_id, p.id) - trade_r3.reserved_qty(r.warehouse_id, p.id) >= 2
                 and trade_lines.get_price(r.price_type_id, p.id, sysdate) > 0
               order by p.code fetch first 2 rows only) loop
      if l_id is null then
        l_id := trade_retail.new_receipt(l_reg);
      end if;
      trade_retail.add_product(l_id, p.id, 1);
    end loop;
    if l_id is not null then
      trade_retail.pay(l_id, ceil(trade_retail.receipt_total(l_id) / 100) * 100, null);
    end if;
  end if;
  commit;
exception when others then
  rollback;
  dbms_output.put_line('Демо-чек не створено: ' || sqlerrm);
end;
/

-- ---------------------------------------------------------------- меню: «Продажі → Роздрібні продажі»
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
  obj('RefCashRegister',   'CATALOG',  'Catalogs',  'Каси ККМ',               640, 641, 110, null);
  obj('DocRetailReceipt',  'DOCUMENT', 'Documents', 'Чеки ККМ',               650, 651, 220, 'Роль: продажі або каса');
  obj('CashierWorkplace',  'REPORT',   'Reports',   'Робоче місце касира (РМК)', 660, null, 250, 'Роль: продажі або каса');
  fp('Sales', 'Роздрібні продажі', 1, 15, 'CashierWorkplace', 10, 'Y');
  fp('Sales', 'Роздрібні продажі', 1, 15, 'DocRetailReceipt', 20);
  fp('Sales', 'НСІ', 3, 10, 'RefCashRegister', 50);
  fp('Finance', 'Казначейство', 1, 10, 'RefCashRegister', 15);
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
