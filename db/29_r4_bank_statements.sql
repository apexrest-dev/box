-- =============================================================================
-- Trade r4 — F-FIN-04 «Банківські виписки». Паспорт DocBankStatement (PROPOSED).
--   * документ doc_bank_statement (виписка за банківським рахунком організації за день) і
--     таблична частина doc_bank_statement_line (операції: вид операції, контрагент, договір, сума,
--     призначення платежу, банківські реквізити контрагента з виписки, номер/дата платіжки банку);
--   * види операцій: надходження — оплата від покупця, повернення від постачальника, внесення
--     готівки (інкасація), інше; списання — оплата постачальнику, повернення покупцю, зняття
--     готівки в касу, банківська комісія, інше;
--   * проведення (пакет trade_bank_doc): RegCashBalance (рахунок, рядок = рядок виписки) через API
--     trade_cash, RegCounterpartySettlement для операцій з контрагентом (переплата заборонена);
--   * рядки «внесення / зняття готівки» прив'язуються до проведеного ВКО «Інкасація» / ПКО
--     «Отримання готівки в банку», які вже рухають і касу, і рахунок: виписка такі суми повторно
--     НЕ проводить (лише звіряє); ордер, прив'язаний до проведеної виписки, не скасовується;
--   * автопошук контрагента за ЄДРПОУ / IBAN (нові реквізити ref_counterparty.edrpou / iban) та
--     за історією попередніх виписок; API add_line — точка входу для імпорту клієнт-банку (APE-185);
--   * меню «Фінанси → Банк», v_recorder (+ виписки).
--   * r4 F-PUR-05 (db/31): рядок «Оплата постачальнику» (APE-57: «Оплата від покупця») може бути
--     прив'язаний до безготівкового документа оплати (payment_doc_type / payment_doc_id) — тоді рух
--     рахунку й погашення боргу пише оплата, рядок лише звіряє (правило одного платежу, див. db/31).
--     Перевірки й автозв'язок — у trade_pay_doc (виклик динамічний: пакет встановлюється пізніше).
-- Потребує 26, 27 (trade_cash), 28 (trade_cash_doc). Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено; повторний запуск 28 без 29 прибере з нього виписки.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -1430) then raise; end if;
  end;
begin
  -- реквізити контрагента для автопошуку в банківських виписках
  ddl('alter table ref_counterparty add (edrpou varchar2(10))');
  ddl('alter table ref_counterparty add (iban varchar2(34))');
  ddl('create index ref_counterparty_edrpou_ix on ref_counterparty (edrpou)');
  ddl('create index ref_counterparty_iban_ix on ref_counterparty (iban)');

  ddl('create sequence doc_bank_statement_num_seq nocache');
  ddl(q'[create table doc_bank_statement (
    id                 varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number         varchar2(9)    not null,
    occurred_at        date           default on null sysdate not null,
    organization_id    varchar2(32)   not null,
    bank_account_id    varchar2(32)   not null,
    currency_code      varchar2(3)    default on null 'UAH' not null,
    total_in           number(19,2)   default on null 0 not null,
    total_out          number(19,2)   default on null 0 not null,
    source_format      varchar2(20)   default on null 'MANUAL' not null,
    source_name        varchar2(255),
    doc_comment        varchar2(1000),
    status             varchar2(10)   default on null 'DRAFT' not null,
    version            number(19)     default on null 0 not null,
    created_at         timestamp      not null,
    created_by         varchar2(255)  not null,
    updated_at         timestamp      not null,
    updated_by         varchar2(255)  not null,
    constraint doc_bank_statement_pk primary key (id),
    constraint doc_bank_statement_num_uk unique (doc_number),
    constraint doc_bank_statement_status_ck check (status in ('DRAFT','POSTED')),
    constraint doc_bank_statement_src_ck check (source_format in ('MANUAL','CSV','1C_CLIENT_BANK')),
    constraint doc_bank_statement_org_fk foreign key (organization_id) references ref_organization (id),
    constraint doc_bank_statement_bank_fk foreign key (bank_account_id) references ref_bank_account (id))]');
  ddl('create index doc_bank_statement_date_ix on doc_bank_statement (occurred_at)');
  ddl('create index doc_bank_statement_bank_ix on doc_bank_statement (bank_account_id, occurred_at)');

  ddl(q'[create table doc_bank_statement_line (
    id                 varchar2(32)   default on null rawtohex(sys_guid()) not null,
    document_id        varchar2(32)   not null,
    line_number        number(10),
    operation_kind     varchar2(30)   not null,
    direction          varchar2(3)    not null,
    amount             number(19,2)   not null,
    counterparty_id    varchar2(32),
    contract_id        varchar2(32),
    purpose            varchar2(500),
    cp_name            varchar2(255),
    cp_edrpou          varchar2(10),
    cp_iban            varchar2(34),
    ext_doc_number     varchar2(30),
    ext_doc_date       date,
    cash_order_type    varchar2(60),
    cash_order_id      varchar2(32),
    matched_by         varchar2(10),
    constraint doc_bank_statement_line_pk primary key (id),
    constraint doc_bank_stmt_line_doc_fk foreign key (document_id) references doc_bank_statement (id) on delete cascade,
    constraint doc_bank_stmt_line_dir_ck check (direction in ('IN','OUT')),
    constraint doc_bank_stmt_line_op_ck check (operation_kind in ('CUSTOMER_PAYMENT','SUPPLIER_REFUND','CASH_DEPOSIT','OTHER_IN',
                                                                  'SUPPLIER_PAYMENT','CUSTOMER_REFUND','CASH_WITHDRAWAL','BANK_FEE','OTHER_OUT')),
    constraint doc_bank_stmt_line_amt_ck check (amount > 0),
    constraint doc_bank_stmt_line_match_ck check (matched_by in ('EDRPOU','IBAN','HISTORY')),
    constraint doc_bank_stmt_line_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint doc_bank_stmt_line_ctr_fk foreign key (contract_id) references ref_contract (id))]');
  ddl('create index doc_bank_stmt_line_doc_ix on doc_bank_statement_line (document_id, line_number)');
  ddl('create index doc_bank_stmt_line_cp_ix on doc_bank_statement_line (counterparty_id)');
  ddl('create index doc_bank_stmt_line_iban_ix on doc_bank_statement_line (cp_iban)');
  ddl('create index doc_bank_stmt_line_ext_ix on doc_bank_statement_line (ext_doc_number, ext_doc_date)');
  -- один касовий ордер — не більше ніж в одному рядку виписки
  ddl('create unique index doc_bank_stmt_line_cash_uk on doc_bank_statement_line (cash_order_id)');
  -- r4 F-PUR-05: прив'язка до документа оплати (одна оплата — не більше ніж в одному рядку)
  ddl('alter table doc_bank_statement_line add (payment_doc_type varchar2(60))');
  ddl('alter table doc_bank_statement_line add (payment_doc_id varchar2(32))');
  ddl('create unique index doc_bank_stmt_line_pay_uk on doc_bank_statement_line (payment_doc_id)');
end;
/

-- Реквізити контрагента: ЄДРПОУ / РНОКПП і основний IBAN (необов'язкові)
create or replace trigger ref_counterparty_req_biu
before insert or update of edrpou, iban on ref_counterparty for each row
begin
  :new.edrpou := trim(:new.edrpou);
  if :new.edrpou is not null and not (translate(:new.edrpou, 'x0123456789', 'x') is null and length(:new.edrpou) in (8, 10)) then
    trade_nsi.fail('COUNTERPARTY_EDRPOU', 'Код ЄДРПОУ — 8 цифр, РНОКПП фізичної особи — 10 цифр.');
  end if;
  if :new.iban is not null then
    trade_fin.check_iban(:new.iban);
  end if;
end;
/

create or replace package trade_bank_doc as
  c_type constant varchar2(60) := 'DocBankStatement';

  -- Назва виду операції; напрям IN / OUT; групи операцій
  function operation_name (p_op in varchar2) return varchar2;
  function direction_of (p_op in varchar2) return varchar2;
  function is_counterparty_op (p_op in varchar2) return boolean;   -- рухи взаєморозрахунків
  function is_cash_op (p_op in varchar2) return boolean;           -- внесення / зняття готівки (проводить касовий ордер)

  -- Автопошук контрагента: ЄДРПОУ → IBAN (довідник) → IBAN в попередніх виписках (p_history).
  -- o_how: EDRPOU / IBAN / HISTORY; лише однозначний активний збіг.
  function find_counterparty (p_edrpou in varchar2, p_iban in varchar2, o_how out varchar2,
                              p_history in boolean default true) return varchar2;

  -- Перевірка шапки й рядка (тригери)
  procedure check_header (p_inserting in boolean, p_org in out varchar2, p_bank in varchar2, p_old_bank in varchar2,
                          p_currency out varchar2, p_source in out varchar2);
  procedure check_line (p_doc_id in varchar2, p_inserting in boolean, p_op in out varchar2, p_direction in out varchar2,
                        p_amount in number, p_cp in out varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                        p_edrpou in out varchar2, p_iban in out varchar2, p_cash_type out varchar2, p_cash_id in varchar2,
                        p_matched in out varchar2);

  procedure post   (p_id in varchar2);
  procedure unpost (p_id in varchar2);
  function  copy   (p_id in varchar2) return varchar2;

  -- Заповнити контрагентів у рядках без контрагента (автопошук з історією); кількість знайдених
  function fill_counterparties (p_id in varchar2) return number;
  -- Прив'язати рядки внесення / зняття готівки до проведених касових ордерів (рахунок, сума, ±3 дні)
  function link_cash_orders (p_id in varchar2) return number;

  -- Рядок виписки з реквізитів банку — API імпорту клієнт-банку (APE-185, CSV / 1CClientBankExchange).
  -- Вид операції за замовчуванням: IN → оплата від покупця, OUT → оплата постачальнику.
  -- Дубль (той самий рахунок, номер і дата платіжки, сума, напрям) не додається — повертає null.
  function add_line (p_doc_id in varchar2, p_direction in varchar2, p_amount in number, p_purpose in varchar2 default null,
                     p_cp_name in varchar2 default null, p_cp_edrpou in varchar2 default null, p_cp_iban in varchar2 default null,
                     p_ext_number in varchar2 default null, p_ext_date in date default null,
                     p_operation_kind in varchar2 default null) return varchar2;

  -- Залишок рахунку на початок / кінець дня виписки
  function opening_balance (p_id in varchar2) return number;
  function closing_balance (p_id in varchar2) return number;

  -- Касовий ордер прив'язаний до виписки? (скасування / видалення ордера — тригери doc_cash_*)
  procedure check_cash_order_change (p_order_id in varchar2, p_deleting in boolean);

  -- Рядок, прив'язаний до документа оплати (тригер рядка; перевірка — trade_pay_doc, db/31)
  procedure check_payment_link (p_doc_id in varchar2, p_op in varchar2, p_amount in number,
                                p_cp in out varchar2, p_contract in out varchar2,
                                p_pay_type out varchar2, p_pay_id in varchar2);
  -- Прив'язати рядки оплат до проведених безготівкових документів оплати; кількість
  function link_payments (p_id in varchar2) return number;
end trade_bank_doc;
/

create or replace package body trade_bank_doc as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;

  -- r4 F-PUR-05: документи оплати (trade_pay_doc, db/31) — динамічно, бо пакет встановлюється пізніше
  function pay_doc_installed return boolean is
    n number;
  begin
    select count(*) into n from user_objects where object_name = 'TRADE_PAY_DOC' and object_type = 'PACKAGE BODY';
    return n > 0;
  end pay_doc_installed;

  function operation_name (p_op in varchar2) return varchar2 is
  begin
    return case p_op
      when 'CUSTOMER_PAYMENT' then 'Оплата від покупця'
      when 'SUPPLIER_REFUND'  then 'Повернення коштів постачальником'
      when 'CASH_DEPOSIT'     then 'Внесення готівки (інкасація)'
      when 'OTHER_IN'         then 'Інше надходження'
      when 'SUPPLIER_PAYMENT' then 'Оплата постачальнику'
      when 'CUSTOMER_REFUND'  then 'Повернення коштів покупцю'
      when 'CASH_WITHDRAWAL'  then 'Зняття готівки в касу'
      when 'BANK_FEE'         then 'Банківська комісія'
      when 'OTHER_OUT'        then 'Інше списання' end;
  end operation_name;

  function direction_of (p_op in varchar2) return varchar2 is
  begin
    return case when p_op in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'CASH_DEPOSIT', 'OTHER_IN') then 'IN'
                when p_op in ('SUPPLIER_PAYMENT', 'CUSTOMER_REFUND', 'CASH_WITHDRAWAL', 'BANK_FEE', 'OTHER_OUT') then 'OUT' end;
  end direction_of;

  function is_counterparty_op (p_op in varchar2) return boolean is
  begin
    return p_op in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'SUPPLIER_PAYMENT', 'CUSTOMER_REFUND');
  end is_counterparty_op;

  function is_cash_op (p_op in varchar2) return boolean is
  begin
    return p_op in ('CASH_DEPOSIT', 'CASH_WITHDRAWAL');
  end is_cash_op;

  -- Напрям і знак руху взаєморозрахунків (як у trade_cash_doc)
  procedure settlement_of (p_op varchar2, o_dir out varchar2, o_sign out number) is
  begin
    case p_op
      when 'CUSTOMER_PAYMENT' then o_dir := 'RECEIVABLE'; o_sign := -1;
      when 'CUSTOMER_REFUND'  then o_dir := 'RECEIVABLE'; o_sign := 1;
      when 'SUPPLIER_PAYMENT' then o_dir := 'PAYABLE';    o_sign := -1;
      when 'SUPPLIER_REFUND'  then o_dir := 'PAYABLE';    o_sign := 1;
      else o_dir := null; o_sign := 0;
    end case;
  end settlement_of;

  function contract_kind_of (p_op varchar2) return varchar2 is
  begin
    return case when p_op in ('CUSTOMER_PAYMENT', 'CUSTOMER_REFUND') then 'WITH_CUSTOMER'
                when p_op in ('SUPPLIER_PAYMENT', 'SUPPLIER_REFUND') then 'WITH_SUPPLIER' end;
  end contract_kind_of;

  -- Очікуваний касовий ордер для рядка готівки
  procedure cash_order_of (p_op varchar2, o_type out varchar2, o_kind out varchar2) is
  begin
    if p_op = 'CASH_DEPOSIT' then o_type := trade_cash_doc.c_payment; o_kind := 'ENCASHMENT';
    elsif p_op = 'CASH_WITHDRAWAL' then o_type := trade_cash_doc.c_receipt; o_kind := 'BANK_WITHDRAWAL';
    end if;
  end cash_order_of;

  function find_counterparty (p_edrpou in varchar2, p_iban in varchar2, o_how out varchar2,
                              p_history in boolean default true) return varchar2 is
    l_edrpou varchar2(20) := trim(p_edrpou);
    l_iban   varchar2(40) := trade_fin.normalize_iban(p_iban);
    l_n number; l_id varchar2(32);
  begin
    o_how := null;
    if l_edrpou is not null then
      select count(*), max(id) into l_n, l_id from ref_counterparty where edrpou = l_edrpou and state = 'ACTIVE';
      if l_n = 1 then o_how := 'EDRPOU'; return l_id; end if;
    end if;
    if l_iban is not null then
      select count(*), max(id) into l_n, l_id from ref_counterparty where iban = l_iban and state = 'ACTIVE';
      if l_n = 1 then o_how := 'IBAN'; return l_id; end if;
      if p_history then
        -- контрагент, вказаний для цього IBAN в останній виписці (якщо всі виписки з ним вказують одного)
        select count(distinct l.counterparty_id), max(l.counterparty_id) into l_n, l_id
          from doc_bank_statement_line l join ref_counterparty c on c.id = l.counterparty_id
         where l.cp_iban = l_iban and c.state = 'ACTIVE';
        if l_n = 1 then o_how := 'HISTORY'; return l_id; end if;
      end if;
    end if;
    return null;
  end find_counterparty;

  procedure check_header (p_inserting in boolean, p_org in out varchar2, p_bank in varchar2, p_old_bank in varchar2,
                          p_currency out varchar2, p_source in out varchar2) is
    l_org varchar2(32);
  begin
    if p_bank is null then
      fail('BANK_ACCOUNT_REQUIRED', 'Вкажіть банківський рахунок виписки.');
    end if;
    if p_inserting or p_bank <> nvl(p_old_bank, '-') then
      trade_core.check_active_ref('REF_BANK_ACCOUNT', p_bank, 'Банківський рахунок');
    end if;
    select organization_id, currency_code into l_org, p_currency from ref_bank_account where id = p_bank;
    if p_org is null then
      p_org := l_org;
    elsif p_org <> l_org then
      fail('BANK_ACCOUNT_ORGANIZATION', 'Банківський рахунок належить іншій організації. Виберіть рахунок організації виписки.');
    end if;
    p_source := coalesce(p_source, 'MANUAL');
  end check_header;

  procedure check_line (p_doc_id in varchar2, p_inserting in boolean, p_op in out varchar2, p_direction in out varchar2,
                        p_amount in number, p_cp in out varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                        p_edrpou in out varchar2, p_iban in out varchar2, p_cash_type out varchar2, p_cash_id in varchar2,
                        p_matched in out varchar2) is
    l_date date; l_bank varchar2(32); l_cur varchar2(3);
    l_how varchar2(10); l_found varchar2(32);
    l_type varchar2(60); l_kind varchar2(30);
    o v_cash_order%rowtype;
  begin
    select occurred_at, bank_account_id, currency_code into l_date, l_bank, l_cur from doc_bank_statement where id = p_doc_id;
    -- вид операції: з напряму (імпорт), інакше обов'язковий
    if p_op is null and p_direction in ('IN', 'OUT') then
      p_op := case p_direction when 'IN' then 'CUSTOMER_PAYMENT' else 'SUPPLIER_PAYMENT' end;
    end if;
    if p_op is null or operation_name(p_op) is null then
      fail('BANK_OPERATION_KIND', 'Вкажіть вид операції в рядку виписки.');
    end if;
    p_direction := direction_of(p_op);
    if p_amount is null or p_amount <= 0 then
      fail('BANK_AMOUNT', 'Сума рядка виписки має бути більшою за нуль.');
    end if;
    p_edrpou := trim(p_edrpou);
    p_iban := trade_fin.normalize_iban(p_iban);

    if is_cash_op(p_op) or p_op = 'BANK_FEE' then
      p_cp := null; p_contract := null; p_matched := null;
    else
      -- автопошук контрагента за реквізитами з виписки (без історії: тригер рядка не читає свою таблицю)
      if p_cp is null and (p_edrpou is not null or p_iban is not null) then
        l_found := find_counterparty(p_edrpou, p_iban, l_how, p_history => false);
        if l_found is not null then
          p_cp := l_found; p_matched := l_how;
        end if;
      elsif not p_inserting and p_cp is not null and p_cp <> nvl(p_old_cp, '-') and p_matched is not null
            and p_old_cp is not null then
        p_matched := null;   -- контрагента змінено вручну
      end if;
      if p_cp is null then
        p_matched := null;
      end if;
      if p_cp is not null and (p_inserting or p_cp <> nvl(p_old_cp, '-')) then
        trade_core.check_active_ref('REF_COUNTERPARTY', p_cp, 'Контрагент');
      end if;
      if is_counterparty_op(p_op) then
        if l_cur <> 'UAH' then
          fail('BANK_SETTLEMENT_CURRENCY', 'Розрахунки з контрагентами ведуться в UAH — для валютного рахунку оберіть «Інше надходження / списання».');
        end if;
        if p_cp is null then
          p_contract := null;   -- чернетка (імпорт): контрагента вкажуть перед проведенням
        else
          if p_contract is null then
            p_contract := trade_nsi.resolve_default_contract(p_cp, contract_kind_of(p_op), l_date);
          end if;
          trade_nsi.check_contract(p_contract, p_cp, contract_kind_of(p_op), l_date);
        end if;
      else
        p_contract := null;
      end if;
    end if;

    -- касовий ордер для внесення / зняття готівки
    p_cash_type := null;
    if is_cash_op(p_op) and p_cash_id is not null then
      cash_order_of(p_op, l_type, l_kind);
      begin
        select * into o from v_cash_order where id = p_cash_id;
      exception when no_data_found then
        fail('BANK_CASH_ORDER', 'Касовий ордер не знайдено.');
      end;
      if o.doc_type <> l_type or o.operation_kind <> l_kind then
        fail('BANK_CASH_ORDER_KIND', 'Для операції «' || operation_name(p_op) || '» вкажіть '
          || case l_type when trade_cash_doc.c_payment then 'ВКО «Інкасація (здача готівки в банк)»'
                                                       else 'ПКО «Отримання готівки в банку»' end || '.');
      end if;
      if o.bank_account_id <> l_bank then
        fail('BANK_CASH_ORDER_ACCOUNT', 'Касовий ордер № ' || o.doc_number || ' оформлено за іншим банківським рахунком.');
      end if;
      if o.amount <> p_amount then
        fail('BANK_CASH_ORDER_AMOUNT', 'Сума рядка ' || m(p_amount) || ' не збігається із сумою касового ордера № '
          || o.doc_number || ' (' || m(o.amount) || ').');
      end if;
      p_cash_type := o.doc_type;
    elsif not is_cash_op(p_op) and p_cash_id is not null then
      fail('BANK_CASH_ORDER_NOT_ALLOWED', 'Касовий ордер вказують лише для внесення / зняття готівки.');
    end if;
  end check_line;

  -- ------------------------------------------------------------- проведення
  procedure lock_doc (p_id varchar2, o_status out varchar2) is
  begin
    select status into o_status from doc_bank_statement where id = p_id for update;
  exception when no_data_found then
    fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
  end lock_doc;

  procedure delete_moves (p_id varchar2) is
  begin
    trade_cash.delete_movements(c_type, p_id);
    delete from reg_counterparty_settlement_mv where recorder_type = c_type and recorder_id = p_id;
  end delete_moves;

  function link_cash_orders (p_id in varchar2) return number is
    l_n number := 0; l_type varchar2(60); l_kind varchar2(30); l_order varchar2(32);
    h doc_bank_statement%rowtype;
  begin
    select * into h from doc_bank_statement where id = p_id;
    for l in (select * from doc_bank_statement_line
               where document_id = p_id and cash_order_id is null and operation_kind in ('CASH_DEPOSIT', 'CASH_WITHDRAWAL')
               order by line_number) loop
      cash_order_of(l.operation_kind, l_type, l_kind);
      select max(o.id) keep (dense_rank first order by abs(o.occurred_at - h.occurred_at), o.doc_number) into l_order
        from v_cash_order o
       where o.doc_type = l_type and o.operation_kind = l_kind and o.status = 'POSTED'
         and o.bank_account_id = h.bank_account_id and o.amount = l.amount
         and o.occurred_at between trunc(h.occurred_at) - 3 and trunc(h.occurred_at) + 4
         and not exists (select 1 from doc_bank_statement_line x where x.cash_order_id = o.id);
      if l_order is not null then
        update doc_bank_statement_line set cash_order_id = l_order where id = l.id;
        l_n := l_n + 1;
      end if;
    end loop;
    if l_n > 0 then   -- r4 F-SRV-05 (APE-62): журнал реєстрації
      trade_core.audit(c_type, p_id, 'LINK_CASH_ORDERS', 'Прив''язано касових ордерів: ' || l_n);
    end if;
    return l_n;
  end link_cash_orders;

  procedure post (p_id in varchar2) is
    h doc_bank_statement%rowtype;
    l_status varchar2(10); l_dir varchar2(20); l_sign number; l_dummy varchar2(32); l_n number;
    l_ost varchar2(10); l_cpname varchar2(255);
    type t_ids is table of varchar2(32) index by varchar2(32);
    l_cps t_ids; l_cp varchar2(32);
  begin
    lock_doc(p_id, l_status);
    trade_core.g_internal := true;
    l_n := link_cash_orders(p_id);   -- автозв'язок рядків готівки з ордерами
    l_n := link_payments(p_id);      -- автозв'язок рядків оплат з документами оплати (db/31)
    trade_core.g_internal := false;
    if pay_doc_installed then
      execute immediate 'begin trade_pay_doc.check_statement(:i); end;' using p_id;
    end if;
    select * into h from doc_bank_statement where id = p_id;
    trade_core.check_active_ref('REF_BANK_ACCOUNT', h.bank_account_id, 'Банківський рахунок');
    select count(*) into l_n from doc_bank_statement_line where document_id = p_id;
    if l_n = 0 then
      fail('BANK_NO_LINES', 'Виписка не містить жодної операції.');
    end if;
    -- перевірки рядків
    for l in (select * from doc_bank_statement_line where document_id = p_id order by line_number) loop
      if is_counterparty_op(l.operation_kind) and l.counterparty_id is null then
        fail('BANK_COUNTERPARTY_REQUIRED', 'Рядок ' || l.line_number || ': для операції «' || operation_name(l.operation_kind)
          || '» вкажіть контрагента' || case when l.cp_name is not null then ' (у виписці: ' || l.cp_name || ')' end
          || '. Скористайтеся «Заповнити контрагентів» або виберіть вручну.');
      end if;
      if l.counterparty_id is not null then
        trade_core.check_active_ref('REF_COUNTERPARTY', l.counterparty_id, 'Контрагент');
        if not l_cps.exists(l.counterparty_id) then
          select id into l_dummy from ref_counterparty where id = l.counterparty_id for update;
        end if;
        if is_counterparty_op(l.operation_kind) then
          l_cps(l.counterparty_id) := l.counterparty_id;
        end if;
      end if;
      if is_cash_op(l.operation_kind) then
        if l.cash_order_id is null then
          fail('BANK_CASH_ORDER_REQUIRED', 'Рядок ' || l.line_number || ': «' || operation_name(l.operation_kind)
            || '» проводить касовий ордер (' || case l.operation_kind when 'CASH_DEPOSIT' then 'ВКО «Інкасація»'
                                                 else 'ПКО «Отримання готівки в банку»' end
            || ' за цим рахунком і на цю суму). Оформіть і проведіть ордер, потім вкажіть його в рядку.');
        end if;
        select max(status) into l_ost from v_cash_order where id = l.cash_order_id;
        if nvl(l_ost, '-') <> 'POSTED' then
          fail('BANK_CASH_ORDER_NOT_POSTED', 'Рядок ' || l.line_number || ': касовий ордер не проведено.');
        end if;
      end if;
    end loop;

    trade_core.g_internal := true;
    delete_moves(p_id);
    for l in (select l.*, c.name cpn from doc_bank_statement_line l left join ref_counterparty c on c.id = l.counterparty_id
               where l.document_id = p_id order by l.line_number) loop
      continue when is_cash_op(l.operation_kind);   -- рух рахунку вже зробив касовий ордер
      continue when l.payment_doc_id is not null;    -- рух рахунку й погашення боргу вже зробив документ оплати
      l_cpname := coalesce(l.cpn, l.cp_name);
      trade_cash.add_movement(c_type, p_id, h.occurred_at, l.line_number, trade_cash.c_bank_account, h.bank_account_id,
                              case l.direction when 'IN' then 1 else -1 end * l.amount, l.operation_kind,
                              'Виписка № ' || h.doc_number || ': ' || operation_name(l.operation_kind)
                              || case when l_cpname is not null then ' — ' || l_cpname end);
      settlement_of(l.operation_kind, l_dir, l_sign);
      if l_dir is not null then
        insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id,
                                                    direction, currency_code, amount, organization_id)
        values (h.occurred_at, c_type, p_id, l.line_number, l.counterparty_id, l_dir, 'UAH', l_sign * l.amount, h.organization_id);
      end if;
    end loop;
    trade_cash.check_balances;
    l_cp := l_cps.first;
    while l_cp is not null loop
      trade_org.check_settlement(h.organization_id, l_cp);
      l_cp := l_cps.next(l_cp);
    end loop;
    update doc_bank_statement set status = 'POSTED' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'POST', 'Надходження ' || m(h.total_in) || ', списання ' || m(h.total_out) || ' ' || h.currency_code);
  exception when others then
    trade_core.g_internal := false;
    raise;
  end post;

  procedure unpost (p_id in varchar2) is
    h doc_bank_statement%rowtype;
    l_status varchar2(10);
  begin
    lock_doc(p_id, l_status);
    if l_status <> 'POSTED' then
      fail('DOCUMENT_NOT_POSTED', 'Документ не проведено.');
    end if;
    select * into h from doc_bank_statement where id = p_id;
    trade_core.g_internal := true;
    delete_moves(p_id);
    trade_cash.check_balances;   -- надходження вже витрачено — скасування неможливе
    for c in (select distinct counterparty_id from doc_bank_statement_line
               where document_id = p_id and counterparty_id is not null
                 and operation_kind in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'SUPPLIER_PAYMENT', 'CUSTOMER_REFUND')) loop
      trade_org.check_settlement(h.organization_id, c.counterparty_id);
    end loop;
    update doc_bank_statement set status = 'DRAFT' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'UNPOST');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end unpost;

  function copy (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_bank_statement (id, occurred_at, organization_id, bank_account_id, doc_comment)
    select l_new, sysdate, organization_id, bank_account_id, doc_comment from doc_bank_statement where id = p_id;
    -- касові ордери не копіюються (один ордер — один рядок виписки)
    insert into doc_bank_statement_line (document_id, line_number, operation_kind, direction, amount, counterparty_id, contract_id,
                                         purpose, cp_name, cp_edrpou, cp_iban, ext_doc_number, ext_doc_date, matched_by)
    select l_new, line_number, operation_kind, direction, amount, counterparty_id, contract_id,
           purpose, cp_name, cp_edrpou, cp_iban, ext_doc_number, ext_doc_date, matched_by
      from doc_bank_statement_line where document_id = p_id order by line_number;
    trade_core.audit(c_type, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy;

  function fill_counterparties (p_id in varchar2) return number is
    l_n number := 0; l_cp varchar2(32); l_how varchar2(10); l_st varchar2(10);
  begin
    select status into l_st from doc_bank_statement where id = p_id;
    if l_st <> 'DRAFT' then
      fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
    end if;
    for l in (select id, cp_edrpou, cp_iban from doc_bank_statement_line
               where document_id = p_id and counterparty_id is null
                 and operation_kind not in ('CASH_DEPOSIT', 'CASH_WITHDRAWAL', 'BANK_FEE')
                 and (cp_edrpou is not null or cp_iban is not null)) loop
      l_cp := find_counterparty(l.cp_edrpou, l.cp_iban, l_how);
      if l_cp is not null then
        update doc_bank_statement_line set counterparty_id = l_cp, matched_by = l_how where id = l.id;
        l_n := l_n + 1;
      end if;
    end loop;
    trade_core.audit(c_type, p_id, 'FILL_COUNTERPARTIES', 'Знайдено: ' || l_n);
    return l_n;
  end fill_counterparties;

  function add_line (p_doc_id in varchar2, p_direction in varchar2, p_amount in number, p_purpose in varchar2 default null,
                     p_cp_name in varchar2 default null, p_cp_edrpou in varchar2 default null, p_cp_iban in varchar2 default null,
                     p_ext_number in varchar2 default null, p_ext_date in date default null,
                     p_operation_kind in varchar2 default null) return varchar2 is
    l_id varchar2(32); l_n number; l_cp varchar2(32); l_how varchar2(10); l_bank varchar2(32);
    l_op varchar2(30) := p_operation_kind;
  begin
    if p_direction not in ('IN', 'OUT') and p_operation_kind is null then
      fail('BANK_DIRECTION', 'Напрям операції — IN (надходження) або OUT (списання).');
    end if;
    select bank_account_id into l_bank from doc_bank_statement where id = p_doc_id;
    if trim(p_ext_number) is not null then
      select count(*) into l_n
        from doc_bank_statement_line l join doc_bank_statement s on s.id = l.document_id
       where s.bank_account_id = l_bank and l.ext_doc_number = trim(p_ext_number)
         and (l.ext_doc_date = trunc(p_ext_date) or l.ext_doc_date is null and p_ext_date is null)
         and l.amount = p_amount and l.direction = coalesce(direction_of(l_op), p_direction);
      if l_n > 0 then
        return null;   -- платіж уже завантажено
      end if;
    end if;
    l_cp := find_counterparty(p_cp_edrpou, p_cp_iban, l_how);
    insert into doc_bank_statement_line (document_id, operation_kind, direction, amount, counterparty_id, purpose,
                                         cp_name, cp_edrpou, cp_iban, ext_doc_number, ext_doc_date, matched_by)
    values (p_doc_id, l_op, p_direction, p_amount, l_cp, substr(p_purpose, 1, 500),
            substr(trim(p_cp_name), 1, 255), p_cp_edrpou, p_cp_iban, trim(p_ext_number), trunc(p_ext_date), l_how)
    returning id into l_id;
    return l_id;
  end add_line;

  function opening_balance (p_id in varchar2) return number is
    l_bank varchar2(32); l_date date;
  begin
    select bank_account_id, occurred_at into l_bank, l_date from doc_bank_statement where id = p_id;
    return trade_cash.balance_at(l_bank, trunc(l_date) - 1/86400);
  end opening_balance;

  function closing_balance (p_id in varchar2) return number is
    l_bank varchar2(32); l_date date;
  begin
    select bank_account_id, occurred_at into l_bank, l_date from doc_bank_statement where id = p_id;
    return trade_cash.balance_at(l_bank, trunc(l_date) + 1 - 1/86400);
  end closing_balance;

  procedure check_payment_link (p_doc_id in varchar2, p_op in varchar2, p_amount in number,
                                p_cp in out varchar2, p_contract in out varchar2,
                                p_pay_type out varchar2, p_pay_id in varchar2) is
  begin
    p_pay_type := null;
    if p_pay_id is null then return; end if;
    if not pay_doc_installed then
      fail('BANK_PAYMENT_NOT_SUPPORTED', 'Прив''язка рядка виписки до документа оплати недоступна (не встановлено db/31).');
    end if;
    execute immediate 'begin trade_pay_doc.check_statement_link(:s, :o, :a, :c, :k, :t, :i); end;'
      using p_doc_id, p_op, p_amount, in out p_cp, in out p_contract, out p_pay_type, p_pay_id;
  end check_payment_link;

  function link_payments (p_id in varchar2) return number is
    l_n number := 0;
  begin
    if pay_doc_installed then
      execute immediate 'begin :n := trade_pay_doc.link_statement(:i); end;' using out l_n, p_id;
    end if;
    if l_n > 0 then   -- r4 F-SRV-05 (APE-62): журнал реєстрації
      trade_core.audit(c_type, p_id, 'LINK_PAYMENTS', 'Прив''язано документів оплати: ' || l_n);
    end if;
    return l_n;
  end link_payments;

  procedure check_cash_order_change (p_order_id in varchar2, p_deleting in boolean) is
    l_num varchar2(9); l_line number;
  begin
    select max(s.doc_number) keep (dense_rank first order by s.doc_number), max(l.line_number) keep (dense_rank first order by s.doc_number)
      into l_num, l_line
      from doc_bank_statement_line l join doc_bank_statement s on s.id = l.document_id
     where l.cash_order_id = p_order_id and (p_deleting or s.status = 'POSTED');
    if l_num is not null then
      fail('BANK_CASH_ORDER_LINKED', 'Касовий ордер указано в рядку ' || l_line || ' банківської виписки № ' || l_num
        || case when p_deleting then '. Спочатку приберіть його з виписки.' else ', яку проведено. Спочатку скасуйте проведення виписки.' end);
    end if;
  end check_cash_order_change;

end trade_bank_doc;
/

-- ---------------------------------------------------------------- тригери
create or replace trigger doc_bank_statement_biud
before insert or update or delete on doc_bank_statement for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_BANK_STATEMENT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0; :new.total_in := 0; :new.total_out := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_in := :old.total_in; :new.total_out := :old.total_out;
        :new.source_format := :old.source_format; :new.source_name := :old.source_name;   -- реквізити імпорту
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    trade_bank_doc.check_header(inserting, :new.organization_id, :new.bank_account_id, :old.bank_account_id,
                                :new.currency_code, :new.source_format);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_bank_statement_ad after delete on doc_bank_statement
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_bank_statement_line_ct
for insert or update or delete on doc_bank_statement_line
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_bank_statement where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено: рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if inserting then
      :new.line_number := coalesce(:new.line_number, 1e9);
    end if;
    if not deleting then
      trade_bank_doc.check_line(:new.document_id, inserting, :new.operation_kind, :new.direction, :new.amount,
                                :new.counterparty_id, :old.counterparty_id, :new.contract_id, :new.cp_edrpou, :new.cp_iban,
                                :new.cash_order_type, :new.cash_order_id, :new.matched_by);
      trade_bank_doc.check_payment_link(:new.document_id, :new.operation_kind, :new.amount, :new.counterparty_id,
                                        :new.contract_id, :new.payment_doc_type, :new.payment_doc_id);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_BANK_STATEMENT_LINE', l_doc);
      update doc_bank_statement d
         set (d.total_in, d.total_out) =
             (select coalesce(sum(case direction when 'IN' then amount end), 0),
                     coalesce(sum(case direction when 'OUT' then amount end), 0)
                from doc_bank_statement_line where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_bank_statement_line_ct;
/

-- Касовий ордер, прив'язаний до виписки: заборона скасування (проведена виписка) і видалення
create or replace trigger doc_cash_receipt_bank_bud
before update of status or delete on doc_cash_receipt for each row
begin
  if deleting or (:old.status = 'POSTED' and :new.status = 'DRAFT') then
    trade_bank_doc.check_cash_order_change(:old.id, deleting);
  end if;
end;
/
create or replace trigger doc_cash_payment_bank_bud
before update of status or delete on doc_cash_payment for each row
begin
  if deleting or (:old.status = 'POSTED' and :new.status = 'DRAFT') then
    trade_bank_doc.check_cash_order_change(:old.id, deleting);
  end if;
end;
/

-- ---------------------------------------------------------------- реєстратори (+ банківські виписки)
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
union all select 'DocBankStatement', d.id, 'Банківська виписка ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 401 from doc_bank_statement d;

-- Список виписок (сторінка 400)
create or replace view v_bank_statement_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name,
       d.bank_account_id, b.name bank_account_name, b.iban, d.currency_code, d.total_in, d.total_out,
       (select count(*) from doc_bank_statement_line l where l.document_id = d.id) line_count,
       (select count(*) from doc_bank_statement_line l
         where l.document_id = d.id and l.counterparty_id is null
           and l.operation_kind in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'SUPPLIER_PAYMENT', 'CUSTOMER_REFUND')) unmatched_count,
       d.source_format, d.source_name, d.status, d.doc_comment
  from doc_bank_statement d
  join ref_organization o on o.id = d.organization_id
  join ref_bank_account b on b.id = d.bank_account_id;

-- ---------------------------------------------------------------- меню: «Фінанси → Банк»
declare
  procedure obj (p_tech varchar2, p_kind varchar2, p_section varchar2, p_name varchar2, p_list number, p_form number, p_sort number) is
  begin
    merge into sys_metadata_object o
    using (select p_tech tech_name from dual) s on (o.tech_name = s.tech_name)
    when matched then update set o.name = p_name, o.list_page_id = p_list, o.form_page_id = p_form, o.auth_scheme = 'Роль: каса'
    when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
      values (p_tech, p_kind, p_name, (select id from sys_main_menu_section where tech_name = p_section), p_list, p_form, p_sort, 'Роль: каса');
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
  obj('DocBankStatement', 'DOCUMENT', 'Documents', 'Банківські виписки', 400, 401, 160);
  fp('Finance', 'Банк', 1, 7, 'DocBankStatement', 10, 'Y');
  commit;
end;
/

-- ---------------------------------------------------------------- демо: ЄДРПОУ контрагентів для автопошуку
begin
  update ref_counterparty set edrpou = '30123456' where name = 'ТОВ «Постачальник»' and edrpou is null;
  update ref_counterparty set edrpou = '40123457' where name = 'ТОВ «Покупець»' and edrpou is null;
  update ref_counterparty set edrpou = '2012345678' where name = 'ФОП Іваненко І. І.' and edrpou is null;
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
