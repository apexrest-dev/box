-- =============================================================================
-- Trade r4 — F-FIN-03 «ПКО / ВКО». Паспорти DocCashReceipt, DocCashPayment (PROPOSED).
--   * документи doc_cash_receipt (прибутковий касовий ордер) і doc_cash_payment (видатковий);
--   * види операцій ПКО: оплата від покупця, повернення коштів постачальником, повернення від
--     підзвітної особи, отримання готівки в банку, інше надходження;
--     ВКО: оплата постачальнику, повернення коштів покупцю, видача підзвітній особі,
--     інкасація (здача в банк), інша видача;
--   * проведення (пакет trade_cash_doc): RegCashBalance через API trade_cash (каса, а для
--     банківських операцій — і рахунок), RegCounterpartySettlement для операцій з контрагентом
--     (переплата заборонена, як у r2-оплатах); контроль від'ємного залишку каси й рахунку;
--   * введення на підставі: реалізації, рахунку на оплату, повернення постачальнику → ПКО;
--     прибуткової накладної, повернення від клієнта → ВКО;
--   * друк: КО-1 (з квитанцією), КО-2 — через trade_print.document_html; касова книга (КО-4)
--     — trade_cash_doc.cash_book_html (сторінка 390);
--   * меню «Фінанси → Каса», v_recorder (+ ПКО/ВКО, рахунки на оплату).
-- Потребує 24 (trade_org), 26, 27 (trade_cash). Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
  function doc_ddl (p_tab varchar2, p_ops varchar2, p_def_op varchar2) return varchar2 is
  begin
    return 'create table ' || p_tab || ' (
    id                 varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number         varchar2(9)    not null,
    occurred_at        date           default on null sysdate not null,
    organization_id    varchar2(32)   not null,
    operation_kind     varchar2(30)   default on null ''' || p_def_op || ''' not null,
    cash_desk_id       varchar2(32)   not null,
    currency_code      varchar2(3)    default on null ''UAH'' not null,
    amount             number(19,2)   not null,
    counterparty_id    varchar2(32),
    contract_id        varchar2(32),
    accountable_person varchar2(255),
    bank_account_id    varchar2(32),
    person_name        varchar2(255),
    basis              varchar2(500),
    appendix           varchar2(500),
    base_doc_type      varchar2(60),
    base_doc_id        varchar2(32),
    doc_comment        varchar2(1000),
    status             varchar2(10)   default on null ''DRAFT'' not null,
    version            number(19)     default on null 0 not null,
    created_at         timestamp      not null,
    created_by         varchar2(255)  not null,
    updated_at         timestamp      not null,
    updated_by         varchar2(255)  not null,
    constraint ' || p_tab || '_pk primary key (id),
    constraint ' || p_tab || '_num_uk unique (doc_number),
    constraint ' || p_tab || '_status_ck check (status in (''DRAFT'',''POSTED'')),
    constraint ' || p_tab || '_op_ck check (operation_kind in (' || p_ops || ')),
    constraint ' || p_tab || '_amt_ck check (amount > 0),
    constraint ' || p_tab || '_org_fk foreign key (organization_id) references ref_organization (id),
    constraint ' || p_tab || '_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id),
    constraint ' || p_tab || '_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint ' || p_tab || '_ctr_fk foreign key (contract_id) references ref_contract (id),
    constraint ' || p_tab || '_bank_fk foreign key (bank_account_id) references ref_bank_account (id))';
  end;
begin
  ddl('create sequence doc_cash_receipt_num_seq nocache');
  ddl('create sequence doc_cash_payment_num_seq nocache');
  ddl(doc_ddl('doc_cash_receipt',
      q'['CUSTOMER_PAYMENT','SUPPLIER_REFUND','ACCOUNTABLE_RETURN','BANK_WITHDRAWAL','OTHER']', 'CUSTOMER_PAYMENT'));
  ddl(doc_ddl('doc_cash_payment',
      q'['SUPPLIER_PAYMENT','CUSTOMER_REFUND','ACCOUNTABLE_ISSUE','ENCASHMENT','OTHER']', 'SUPPLIER_PAYMENT'));
  for t in (select column_value tab from table(sys.odcivarchar2list('doc_cash_receipt', 'doc_cash_payment'))) loop
    ddl('create index ' || t.tab || '_date_ix on ' || t.tab || ' (occurred_at)');
    ddl('create index ' || t.tab || '_desk_ix on ' || t.tab || ' (cash_desk_id, occurred_at)');
    ddl('create index ' || t.tab || '_cp_ix on ' || t.tab || ' (counterparty_id)');
    ddl('create index ' || t.tab || '_base_ix on ' || t.tab || ' (base_doc_id)');
  end loop;
end;
/

-- Обидва види ордерів одним набором (проведення, касова книга, друк)
create or replace view v_cash_order as
select 'DocCashReceipt' doc_type, 1 sign, 'ПКО' short_name, d.id, d.doc_number, d.occurred_at, d.organization_id,
       d.operation_kind, d.cash_desk_id, d.currency_code, d.amount, d.counterparty_id, d.contract_id, d.accountable_person,
       d.bank_account_id, d.person_name, d.basis, d.appendix, d.base_doc_type, d.base_doc_id, d.doc_comment, d.status
  from doc_cash_receipt d
union all
select 'DocCashPayment', -1, 'ВКО', d.id, d.doc_number, d.occurred_at, d.organization_id,
       d.operation_kind, d.cash_desk_id, d.currency_code, d.amount, d.counterparty_id, d.contract_id, d.accountable_person,
       d.bank_account_id, d.person_name, d.basis, d.appendix, d.base_doc_type, d.base_doc_id, d.doc_comment, d.status
  from doc_cash_payment d;

create or replace package trade_cash_doc as
  c_receipt constant varchar2(60) := 'DocCashReceipt';
  c_payment constant varchar2(60) := 'DocCashPayment';

  -- Назва виду операції; групи операцій
  function operation_name (p_type in varchar2, p_op in varchar2) return varchar2;
  function is_counterparty_op (p_op in varchar2) return boolean;   -- рухи взаєморозрахунків
  function is_bank_op (p_op in varchar2) return boolean;           -- другий рух — банківський рахунок
  function is_accountable_op (p_op in varchar2) return boolean;    -- підзвітна особа

  -- Перевірка й доповнення шапки (тригери doc_cash_receipt / doc_cash_payment)
  procedure check_header (p_type in varchar2, p_inserting in boolean, p_op in varchar2, p_date in date,
                          p_org in out varchar2, p_desk in varchar2, p_old_desk in varchar2, p_currency out varchar2,
                          p_amount in number, p_cp in out varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                          p_accountable in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                          p_person in out varchar2, p_basis in out varchar2, p_base_type in out varchar2, p_base_id in varchar2);

  procedure post_receipt   (p_id in varchar2);
  procedure unpost_receipt (p_id in varchar2);
  function  copy_receipt   (p_id in varchar2) return varchar2;
  procedure post_payment   (p_id in varchar2);
  procedure unpost_payment (p_id in varchar2);
  function  copy_payment   (p_id in varchar2) return varchar2;

  -- Введення на підставі (повертає id нової чернетки ордера)
  function receipt_from_sale            (p_sale_id in varchar2) return varchar2;
  function receipt_from_invoice         (p_invoice_id in varchar2) return varchar2;
  function receipt_from_supplier_return (p_return_id in varchar2) return varchar2;
  function payment_from_goods_receipt   (p_receipt_id in varchar2) return varchar2;
  function payment_from_customer_return (p_return_id in varchar2) return varchar2;

  -- Каса організації за замовчуванням (перша активна за кодом у валюті)
  function default_cash_desk (p_org in varchar2, p_currency in varchar2 default 'UAH') return varchar2;
  -- Заборгованість контрагента в розрізі організації (RECEIVABLE / PAYABLE)
  function counterparty_debt (p_org in varchar2, p_cp in varchar2, p_direction in varchar2) return number;

  -- Друк: KO1 — прибутковий касовий ордер з квитанцією, KO2 — видатковий касовий ордер
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
  -- Касова книга (вкладні аркуші КО-4) за касою й період, аркуш на кожен день з рухами
  function cash_book_html (p_desk_id in varchar2, p_from in date, p_to in date) return clob;
end trade_cash_doc;
/

create or replace package body trade_cash_doc as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function table_of (p_type varchar2) return varchar2 is
  begin
    return case p_type when c_receipt then 'DOC_CASH_RECEIPT' when c_payment then 'DOC_CASH_PAYMENT' end;
  end table_of;

  function operation_name (p_type in varchar2, p_op in varchar2) return varchar2 is
  begin
    if p_type = c_receipt and p_op not in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'ACCOUNTABLE_RETURN', 'BANK_WITHDRAWAL', 'OTHER')
       or p_type = c_payment and p_op not in ('SUPPLIER_PAYMENT', 'CUSTOMER_REFUND', 'ACCOUNTABLE_ISSUE', 'ENCASHMENT', 'OTHER') then
      return null;   -- вид операції іншого документа
    end if;
    return case p_op
      when 'CUSTOMER_PAYMENT'   then 'Оплата від покупця'
      when 'SUPPLIER_REFUND'    then 'Повернення коштів постачальником'
      when 'ACCOUNTABLE_RETURN' then 'Повернення від підзвітної особи'
      when 'BANK_WITHDRAWAL'    then 'Отримання готівки в банку'
      when 'SUPPLIER_PAYMENT'   then 'Оплата постачальнику'
      when 'CUSTOMER_REFUND'    then 'Повернення коштів покупцю'
      when 'ACCOUNTABLE_ISSUE'  then 'Видача підзвітній особі'
      when 'ENCASHMENT'         then 'Інкасація (здача готівки в банк)'
      when 'OTHER' then case p_type when c_receipt then 'Інше надходження' else 'Інша видача' end end;
  end operation_name;

  function is_counterparty_op (p_op in varchar2) return boolean is
  begin
    return p_op in ('CUSTOMER_PAYMENT', 'SUPPLIER_REFUND', 'SUPPLIER_PAYMENT', 'CUSTOMER_REFUND');
  end is_counterparty_op;

  function is_bank_op (p_op in varchar2) return boolean is
  begin
    return p_op in ('BANK_WITHDRAWAL', 'ENCASHMENT');
  end is_bank_op;

  function is_accountable_op (p_op in varchar2) return boolean is
  begin
    return p_op in ('ACCOUNTABLE_RETURN', 'ACCOUNTABLE_ISSUE');
  end is_accountable_op;

  -- Напрям і знак руху взаєморозрахунків
  procedure settlement_of (p_op varchar2, o_dir out varchar2, o_sign out number) is
  begin
    case p_op
      when 'CUSTOMER_PAYMENT' then o_dir := 'RECEIVABLE'; o_sign := -1;   -- борг покупця зменшується
      when 'CUSTOMER_REFUND'  then o_dir := 'RECEIVABLE'; o_sign := 1;    -- повернення переплати / за поверненням товару
      when 'SUPPLIER_PAYMENT' then o_dir := 'PAYABLE';    o_sign := -1;   -- наш борг постачальнику зменшується
      when 'SUPPLIER_REFUND'  then o_dir := 'PAYABLE';    o_sign := 1;
      else o_dir := null; o_sign := 0;
    end case;
  end settlement_of;

  function contract_kind_of (p_op varchar2) return varchar2 is
  begin
    return case when p_op in ('CUSTOMER_PAYMENT', 'CUSTOMER_REFUND') then 'WITH_CUSTOMER'
                when p_op in ('SUPPLIER_PAYMENT', 'SUPPLIER_REFUND') then 'WITH_SUPPLIER' end;
  end contract_kind_of;

  function cp_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_counterparty where id = p_id;
    return l;
  end cp_name;

  function default_cash_desk (p_org in varchar2, p_currency in varchar2 default 'UAH') return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by code) into l
      from ref_cash_desk where organization_id = p_org and currency_code = p_currency and state = 'ACTIVE';
    return l;
  end default_cash_desk;

  function counterparty_debt (p_org in varchar2, p_cp in varchar2, p_direction in varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_counterparty_settlement_mv
     where organization_id = p_org and counterparty_id = p_cp and direction = p_direction and currency_code = 'UAH';
    return l;
  end counterparty_debt;

  -- Організація й контрагент документа-підстави
  procedure base_info (p_type varchar2, p_id varchar2, o_org out varchar2, o_cp out varchar2, o_name out varchar2) is
  begin
    case p_type
      when 'DocGoodsSale' then
        select organization_id, customer_id, 'видатковою накладною № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_name from doc_goods_sale where id = p_id;
      when 'DocInvoiceForPayment' then
        select organization_id, customer_id, 'рахунком на оплату № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_name from doc_invoice_for_payment where id = p_id;
      when 'DocSupplierReturn' then
        select organization_id, supplier_id, 'поверненням постачальнику № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_name from doc_supplier_return where id = p_id;
      when 'DocGoodsReceipt' then
        select organization_id, supplier_id, 'прибутковою накладною № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_name from doc_goods_receipt where id = p_id;
      when 'DocCustomerReturn' then
        select organization_id, customer_id, 'поверненням від клієнта № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_name from doc_customer_return where id = p_id;
      else
        fail('CASH_BASE_TYPE', 'Недопустимий документ-підстава касового ордера.');
    end case;
  exception when no_data_found then
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end base_info;

  function base_type_of (p_id varchar2) return varchar2 is
    l varchar2(60);
  begin
    select max(recorder_type) into l from v_recorder
     where recorder_id = p_id and recorder_type in ('DocGoodsSale', 'DocInvoiceForPayment', 'DocSupplierReturn', 'DocGoodsReceipt', 'DocCustomerReturn');
    return l;
  end base_type_of;

  procedure check_header (p_type in varchar2, p_inserting in boolean, p_op in varchar2, p_date in date,
                          p_org in out varchar2, p_desk in varchar2, p_old_desk in varchar2, p_currency out varchar2,
                          p_amount in number, p_cp in out varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                          p_accountable in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                          p_person in out varchar2, p_basis in out varchar2, p_base_type in out varchar2, p_base_id in varchar2) is
    l_desk_org varchar2(32); l_bank_org varchar2(32); l_bank_cur varchar2(3);
    l_base_org varchar2(32); l_base_cp varchar2(32); l_base_name varchar2(255);
    l_kind varchar2(20) := contract_kind_of(p_op);
  begin
    if p_op is null or operation_name(p_type, p_op) is null then
      fail('CASH_OPERATION_KIND', 'Вкажіть вид операції касового ордера.');
    end if;
    if p_desk is null then
      fail('CASH_DESK_REQUIRED', 'Вкажіть касу.');
    end if;
    if p_inserting or p_desk <> nvl(p_old_desk, '-') then
      trade_core.check_active_ref('REF_CASH_DESK', p_desk, 'Каса');
    end if;
    select organization_id, currency_code into l_desk_org, p_currency from ref_cash_desk where id = p_desk;
    if p_org is null then
      p_org := l_desk_org;
    elsif p_org <> l_desk_org then
      fail('CASH_DESK_ORGANIZATION', 'Каса належить іншій організації. Виберіть касу організації документа.');
    end if;
    if p_amount is null or p_amount <= 0 then
      fail('CASH_AMOUNT', 'Сума касового ордера має бути більшою за нуль.');
    end if;

    -- контрагент і договір
    if is_counterparty_op(p_op) then
      if p_cp is null then
        fail('CASH_COUNTERPARTY_REQUIRED', 'Для операції «' || operation_name(p_type, p_op) || '» вкажіть контрагента.');
      end if;
      if p_currency <> 'UAH' then
        fail('CASH_SETTLEMENT_CURRENCY', 'Розрахунки з контрагентами ведуться в UAH — виберіть гривневу касу.');
      end if;
      if p_contract is null and p_inserting then
        p_contract := trade_nsi.resolve_default_contract(p_cp, l_kind, p_date);
      end if;
      trade_nsi.check_contract(p_contract, p_cp, l_kind, p_date);
    elsif p_op <> 'OTHER' then
      p_cp := null;
    end if;
    if not is_counterparty_op(p_op) then
      p_contract := null;
    end if;
    if p_cp is not null and (p_inserting or p_cp <> nvl(p_old_cp, '-')) then
      trade_core.check_active_ref('REF_COUNTERPARTY', p_cp, 'Контрагент');
    end if;

    -- підзвітна особа
    p_accountable := trim(p_accountable);
    if is_accountable_op(p_op) then
      if p_accountable is null then
        fail('CASH_ACCOUNTABLE_REQUIRED', 'Вкажіть підзвітну особу (ПІБ).');
      end if;
    else
      p_accountable := null;
    end if;

    -- банківський рахунок (інкасація / отримання готівки)
    if is_bank_op(p_op) then
      if p_bank is null then
        fail('CASH_BANK_REQUIRED', 'Вкажіть банківський рахунок.');
      end if;
      if p_inserting or p_bank <> nvl(p_old_bank, '-') then
        trade_core.check_active_ref('REF_BANK_ACCOUNT', p_bank, 'Банківський рахунок');
      end if;
      select organization_id, currency_code into l_bank_org, l_bank_cur from ref_bank_account where id = p_bank;
      if l_bank_org <> p_org then
        fail('CASH_BANK_ORGANIZATION', 'Банківський рахунок належить іншій організації.');
      end if;
      if l_bank_cur <> p_currency then
        fail('CASH_BANK_CURRENCY', 'Валюта рахунку ' || l_bank_cur || ' не збігається з валютою каси ' || p_currency || '.');
      end if;
    else
      p_bank := null;
    end if;

    -- документ-підстава
    if p_base_id is not null then
      p_base_type := coalesce(p_base_type, base_type_of(p_base_id));
      base_info(p_base_type, p_base_id, l_base_org, l_base_cp, l_base_name);
      if l_base_org <> p_org then
        fail('CASH_BASE_ORGANIZATION', 'Документ-підстава оформлений від іншої організації.');
      end if;
      if is_counterparty_op(p_op) and l_base_cp <> p_cp then
        fail('CASH_BASE_COUNTERPARTY', 'Контрагент ордера не збігається з контрагентом документа-підстави.');
      end if;
    else
      p_base_type := null;
    end if;

    -- реквізити друкованої форми за замовчуванням
    p_person := trim(p_person);
    if p_person is null and p_cp is not null then
      p_person := cp_name(p_cp);
    elsif p_person is null and p_accountable is not null then
      p_person := p_accountable;
    elsif p_person is null and p_bank is not null then
      select bank_name into p_person from ref_bank_account where id = p_bank;
    end if;
    p_basis := trim(p_basis);
    if p_basis is null then
      p_basis := operation_name(p_type, p_op) || case when l_base_name is not null then ' за ' || l_base_name end;
    end if;
  end check_header;

  -- ------------------------------------------------------------- проведення
  procedure lock_doc (p_type varchar2, p_id varchar2, o_status out varchar2) is
  begin
    execute immediate 'select status from ' || table_of(p_type) || ' where id = :i for update' into o_status using p_id;
  exception when no_data_found then
    fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
  end lock_doc;

  procedure delete_moves (p_type varchar2, p_id varchar2) is
  begin
    trade_cash.delete_movements(p_type, p_id);
    delete from reg_counterparty_settlement_mv where recorder_type = p_type and recorder_id = p_id;
  end delete_moves;

  procedure set_status (p_type varchar2, p_id varchar2, p_status varchar2) is
  begin
    execute immediate 'update ' || table_of(p_type) || ' set status = :s where id = :i' using p_status, p_id;
  end set_status;

  procedure post_doc (p_type varchar2, p_id varchar2) is
    r v_cash_order%rowtype;
    l_status varchar2(10); l_dir varchar2(20); l_sign number; l_dummy varchar2(32);
    l_content varchar2(255);
  begin
    lock_doc(p_type, p_id, l_status);
    select * into r from v_cash_order where id = p_id and doc_type = p_type;
    trade_core.check_active_ref('REF_CASH_DESK', r.cash_desk_id, 'Каса');
    if r.counterparty_id is not null then
      trade_core.check_active_ref('REF_COUNTERPARTY', r.counterparty_id, 'Контрагент');
      select id into l_dummy from ref_counterparty where id = r.counterparty_id for update;
    end if;
    if r.bank_account_id is not null then
      trade_core.check_active_ref('REF_BANK_ACCOUNT', r.bank_account_id, 'Банківський рахунок');
    end if;
    l_content := substr(r.short_name || ' № ' || r.doc_number || ': ' || operation_name(p_type, r.operation_kind)
                        || case when r.person_name is not null then ' — ' || r.person_name end, 1, 255);
    trade_core.g_internal := true;
    delete_moves(p_type, p_id);
    -- каса: ПКО +, ВКО −
    trade_cash.add_movement(p_type, p_id, r.occurred_at, 1, trade_cash.c_cash_desk, r.cash_desk_id,
                            r.sign * r.amount, r.operation_kind, l_content);
    -- банківський рахунок: інкасація +, отримання готівки −
    if is_bank_op(r.operation_kind) then
      trade_cash.add_movement(p_type, p_id, r.occurred_at, 2, trade_cash.c_bank_account, r.bank_account_id,
                              -r.sign * r.amount, r.operation_kind, l_content);
    end if;
    -- взаєморозрахунки
    settlement_of(r.operation_kind, l_dir, l_sign);
    if l_dir is not null then
      insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id,
                                                  direction, currency_code, amount, organization_id)
      values (r.occurred_at, p_type, p_id, 1, r.counterparty_id, l_dir, 'UAH', l_sign * r.amount, r.organization_id);
    end if;
    trade_cash.check_balances;
    if l_dir is not null then
      trade_org.check_settlement(r.organization_id, r.counterparty_id);
    end if;
    set_status(p_type, p_id, 'POSTED');
    trade_core.g_internal := false;
    trade_core.audit(p_type, p_id, 'POST', operation_name(p_type, r.operation_kind) || ', сума ' || m(r.amount) || ' ' || r.currency_code);
  exception when others then
    trade_core.g_internal := false;
    raise;
  end post_doc;

  procedure unpost_doc (p_type varchar2, p_id varchar2) is
    r v_cash_order%rowtype;
    l_status varchar2(10);
  begin
    lock_doc(p_type, p_id, l_status);
    if l_status <> 'POSTED' then
      fail('DOCUMENT_NOT_POSTED', 'Документ не проведено.');
    end if;
    select * into r from v_cash_order where id = p_id and doc_type = p_type;
    trade_core.g_internal := true;
    delete_moves(p_type, p_id);
    trade_cash.check_balances;   -- скасування ПКО неможливе, якщо гроші вже витрачено
    if is_counterparty_op(r.operation_kind) then
      trade_org.check_settlement(r.organization_id, r.counterparty_id);
    end if;
    set_status(p_type, p_id, 'DRAFT');
    trade_core.g_internal := false;
    trade_core.audit(p_type, p_id, 'UNPOST');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end unpost_doc;

  function copy_doc (p_type varchar2, p_id varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    execute immediate 'insert into ' || table_of(p_type) || ' (id, occurred_at, organization_id, operation_kind, cash_desk_id, amount,
        counterparty_id, contract_id, accountable_person, bank_account_id, person_name, basis, appendix, base_doc_type, base_doc_id, doc_comment)
      select :n, sysdate, organization_id, operation_kind, cash_desk_id, amount, counterparty_id, contract_id, accountable_person,
             bank_account_id, person_name, basis, appendix, base_doc_type, base_doc_id, doc_comment
        from ' || table_of(p_type) || ' where id = :i' using l_new, p_id;
    trade_core.audit(p_type, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_doc;

  procedure post_receipt   (p_id in varchar2) is begin post_doc(c_receipt, p_id); end;
  procedure unpost_receipt (p_id in varchar2) is begin unpost_doc(c_receipt, p_id); end;
  function  copy_receipt   (p_id in varchar2) return varchar2 is begin return copy_doc(c_receipt, p_id); end;
  procedure post_payment   (p_id in varchar2) is begin post_doc(c_payment, p_id); end;
  procedure unpost_payment (p_id in varchar2) is begin unpost_doc(c_payment, p_id); end;
  function  copy_payment   (p_id in varchar2) return varchar2 is begin return copy_doc(c_payment, p_id); end;

  -- ------------------------------------------------------------- введення на підставі
  function create_based (p_type varchar2, p_op varchar2, p_base_type varchar2, p_base_id varchar2,
                         p_org varchar2, p_cp varchar2, p_contract varchar2, p_amount number) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
    l_desk varchar2(32) := default_cash_desk(p_org, 'UAH');
  begin
    if l_desk is null then
      fail('CASH_DESK_NOT_FOUND', 'В організації документа немає активної гривневої каси. Створіть касу в розділі «Фінанси».');
    end if;
    if nvl(p_amount, 0) <= 0 then
      fail('CASH_NOTHING_TO_PAY', 'Сума документа-підстави нульова — касовий ордер не потрібен.');
    end if;
    execute immediate 'insert into ' || table_of(p_type) || ' (id, occurred_at, organization_id, operation_kind, cash_desk_id, amount,
        counterparty_id, contract_id, base_doc_type, base_doc_id) values (:n, sysdate, :o, :k, :d, :a, :c, :t, :bt, :bi)'
      using l_new, p_org, p_op, l_desk, p_amount, p_cp, p_contract, p_base_type, p_base_id;
    trade_core.audit(p_type, l_new, 'CREATE_BASED_ON', p_base_type || ' ' || p_base_id);
    return l_new;
  end create_based;

  -- Сума до оплати: не більше поточного боргу (якщо борг є), інакше — сума документа
  function to_pay (p_total number, p_debt number) return number is
  begin
    return case when p_debt > 0 then least(p_total, p_debt) else p_total end;
  end to_pay;

  function receipt_from_sale (p_sale_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_goods_sale where id = p_sale_id) loop
      if d.status <> 'POSTED' then fail('CASH_BASE_NOT_POSTED', 'Реалізацію не проведено.'); end if;
      return create_based(c_receipt, 'CUSTOMER_PAYMENT', 'DocGoodsSale', d.id, d.organization_id, d.customer_id, d.contract_id,
                          to_pay(d.total_amount, counterparty_debt(d.organization_id, d.customer_id, 'RECEIVABLE')));
    end loop;
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end receipt_from_sale;

  function receipt_from_invoice (p_invoice_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_invoice_for_payment where id = p_invoice_id) loop
      if d.status <> 'ISSUED' then fail('CASH_BASE_NOT_POSTED', 'Рахунок на оплату не видано (або анульовано).'); end if;
      -- оплата за рахунком може бути авансовою (до відвантаження): сума — повна сума рахунку
      return create_based(c_receipt, 'CUSTOMER_PAYMENT', 'DocInvoiceForPayment', d.id, d.organization_id, d.customer_id,
                          d.contract_id, d.total_amount);
    end loop;
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end receipt_from_invoice;

  function receipt_from_supplier_return (p_return_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_supplier_return where id = p_return_id) loop
      return create_based(c_receipt, 'SUPPLIER_REFUND', 'DocSupplierReturn', d.id, d.organization_id, d.supplier_id,
                          d.contract_id, d.total_amount);
    end loop;
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end receipt_from_supplier_return;

  function payment_from_goods_receipt (p_receipt_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_goods_receipt where id = p_receipt_id) loop
      if d.status <> 'POSTED' then fail('CASH_BASE_NOT_POSTED', 'Прибуткову накладну не проведено.'); end if;
      return create_based(c_payment, 'SUPPLIER_PAYMENT', 'DocGoodsReceipt', d.id, d.organization_id, d.supplier_id, d.contract_id,
                          to_pay(d.total_amount, counterparty_debt(d.organization_id, d.supplier_id, 'PAYABLE')));
    end loop;
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_goods_receipt;

  function payment_from_customer_return (p_return_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_customer_return where id = p_return_id) loop
      return create_based(c_payment, 'CUSTOMER_REFUND', 'DocCustomerReturn', d.id, d.organization_id, d.customer_id,
                          d.contract_id, d.total_amount);
    end loop;
    fail('CASH_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_customer_return;

  -- ------------------------------------------------------------- друк
  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:980px;background:#fff;padding:16px;position:relative}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}.tx-print h3{font-size:14px;text-align:center;margin:8px 0}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .ln td{padding:4px 2px;vertical-align:bottom}.tx-print .ln .v{border-bottom:1px solid #000;width:100%}
      .tx-print .small{font-size:10px;color:#333}.tx-print .ko{display:flex;gap:0}
      .tx-print .ko .main{flex:3;padding-right:14px}.tx-print .ko .slip{flex:2;border-left:1px dashed #000;padding-left:14px}
      .tx-print .sheet{page-break-after:always;margin-bottom:28px}
      .tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}}
      </style>';
  end css;

  function line (p_label varchar2, p_value varchar2) return varchar2 is
  begin
    return '<table class="ln"><tr><td style="white-space:nowrap">' || e(p_label) || '</td><td class="v">' || e(p_value) || '</td></tr></table>';
  end line;

  function words (p_amount number, p_currency varchar2) return varchar2 is
  begin
    return case when p_currency = 'UAH' then trade_r3.amount_in_words_uk(p_amount)
                else m(p_amount) || ' ' || p_currency end;
  end words;

  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    l_cashier varchar2(255); l_desk varchar2(255);
    l_title varchar2(100);
  begin
    for r in (select * from v_cash_order where id = p_id
                and doc_type = case p_form when 'KO1' then c_receipt when 'KO2' then c_payment end) loop
      select * into o from ref_organization where id = r.organization_id;
      select responsible_name, name into l_cashier, l_desk from ref_cash_desk where id = r.cash_desk_id;
      l_title := case r.doc_type when c_receipt then 'Прибутковий касовий ордер' else 'Видатковий касовий ордер' end;
      l := '<div class="tx-print">' || css
        || case when r.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<div class="ko"><div class="main">'
        || '<div class="small" style="text-align:right">Типова форма № ' || case r.doc_type when c_receipt then 'КО-1' else 'КО-2' end
        || '<br>(наказ Мінфіну України від 22.01.1996 № 9)</div>'
        || '<div><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
        || case when o.edrpou is not null then '<br>Ідентифікаційний код ЄДРПОУ ' || e(o.edrpou) end || '</div>'
        || '<h2>' || l_title || ' № ' || e(r.doc_number) || '<br><span style="font-weight:normal;font-size:13px">від '
        || dt(r.occurred_at) || '</span></h2>'
        || '<table class="grid"><tr><th>Кореспондуючий рахунок, субрахунок</th><th>Код аналітичного рахунку</th>'
        || '<th>Сума, ' || e(r.currency_code) || '</th><th>Код цільового призначення</th></tr>'
        || '<tr><td>&nbsp;</td><td>&nbsp;</td><td class="r"><b>' || m(r.amount) || '</b></td><td>&nbsp;</td></tr></table>'
        || line(case r.doc_type when c_receipt then 'Прийнято від' else 'Видати' end, r.person_name)
        || line('Підстава', r.basis)
        || line('Сума', words(r.amount, r.currency_code))
        || line('Додаток', r.appendix);
      if r.doc_type = c_receipt then
        l := l || '<div style="margin-top:22px">' || line('Головний бухгалтер', '____________ ' || o.accountant_name)
               || line('Одержав касир', '____________ ' || l_cashier) || '</div></div>'
          -- квитанція (відривна частина)
          || '<div class="slip"><div><b>' || e(coalesce(o.full_name, o.name)) || '</b></div>'
          || '<h3>Квитанція до прибуткового касового ордера № ' || e(r.doc_number) || '<br>від ' || dt(r.occurred_at) || '</h3>'
          || line('Прийнято від', r.person_name) || line('Підстава', r.basis)
          || line('Сума', m(r.amount) || ' ' || r.currency_code) || line('', words(r.amount, r.currency_code))
          || '<p>М. П.</p>' || line('Головний бухгалтер', '____________ ' || o.accountant_name)
          || line('Касир', '____________ ' || l_cashier) || '</div></div>';
      else
        l := l || '<div style="margin-top:18px">' || line('Керівник', '____________ ' || o.director_name)
               || line('Головний бухгалтер', '____________ ' || o.accountant_name) || '</div>'
               || line('Одержав', words(r.amount, r.currency_code))
               || line('Дата / підпис одержувача', dt(r.occurred_at) || '   ____________')
               || line('За', '____________________________ (найменування, номер, дата та місце видачі документа, що посвідчує особу)')
               || line('Видав касир', '____________ ' || l_cashier) || '</div></div>';
      end if;
      l := l || '</div>';
    end loop;
    return l;
  end print_html;

  function cash_book_html (p_desk_id in varchar2, p_from in date, p_to in date) return clob is
    l clob;
    l_desk ref_cash_desk%rowtype;
    o ref_organization%rowtype;
    l_open number; l_in number; l_out number; l_rc number; l_pc number; l_any boolean := false;
  begin
    if p_desk_id is null then
      return '<p>Виберіть касу.</p>';
    end if;
    select * into l_desk from ref_cash_desk where id = p_desk_id;
    select * into o from ref_organization where id = l_desk.organization_id;
    l := '<div class="tx-print">' || css;
    for d in (select trunc(period) day, dense_rank() over (order by trunc(period)) sheet_no
                from reg_cash_balance_mv where cash_desk_id = p_desk_id
               group by trunc(period) order by 1) loop
      continue when d.day < trunc(p_from) or d.day > trunc(p_to);
      l_any := true;
      select coalesce(sum(amount), 0) into l_open from reg_cash_balance_mv
       where cash_desk_id = p_desk_id and period < d.day;
      l := l || '<div class="sheet"><div><b>' || e(coalesce(o.full_name, o.name)) || '</b>, ' || e(l_desk.name)
             || ' (' || e(l_desk.currency_code) || ')<span style="float:right">Аркуш ' || d.sheet_no || '</span></div>'
             || '<h3>Вкладний аркуш касової книги — каса за ' || dt(d.day) || '</h3>'
             || '<table class="grid"><tr><th style="width:110px">Номер документа</th><th>Від кого отримано чи кому видано</th>'
             || '<th style="width:110px">Номер кореспондуючого рахунку, субрахунку</th><th style="width:120px">Надходження</th>'
             || '<th style="width:120px">Видаток</th></tr>'
             || '<tr><td></td><td><b>Залишок на початок дня</b></td><td></td><td class="r"><b>' || m(l_open) || '</b></td><td class="r">x</td></tr>';
      l_in := 0; l_out := 0; l_rc := 0; l_pc := 0;
      for x in (select m.period, m.amount, m.recorder_type, c.short_name, c.doc_number, c.person_name, c.basis, m.content
                  from reg_cash_balance_mv m
                  left join v_cash_order c on c.doc_type = m.recorder_type and c.id = m.recorder_id
                 where m.cash_desk_id = p_desk_id and m.period >= d.day and m.period < d.day + 1
                 order by m.period, c.doc_number) loop
        l := l || '<tr><td>' || e(case when x.doc_number is not null then x.short_name || ' № ' || x.doc_number end)
               || '</td><td>' || e(coalesce(x.person_name || case when x.basis is not null then ' — ' || x.basis end, x.content))
               || '</td><td></td><td class="r">' || case when x.amount > 0 then m(x.amount) end
               || '</td><td class="r">' || case when x.amount < 0 then m(-x.amount) end || '</td></tr>';
        if x.amount > 0 then l_in := l_in + x.amount; else l_out := l_out - x.amount; end if;
        if x.recorder_type = c_receipt then l_rc := l_rc + 1; elsif x.recorder_type = c_payment then l_pc := l_pc + 1; end if;
      end loop;
      l := l || '<tr><td></td><td><b>Разом за день</b></td><td></td><td class="r"><b>' || m(l_in) || '</b></td><td class="r"><b>'
             || m(l_out) || '</b></td></tr>'
             || '<tr><td></td><td><b>Залишок на кінець дня</b></td><td></td><td class="r"><b>' || m(l_open + l_in - l_out)
             || '</b></td><td class="r">x</td></tr></table>'
             || line('Касир', '____________ ' || l_desk.responsible_name)
             || '<p>Записи в касовій книзі перевірив і документи в кількості ' || l_rc || ' прибуткових та ' || l_pc
             || ' видаткових одержав.</p>' || line('Бухгалтер', '____________ ' || o.accountant_name) || '</div>';
    end loop;
    if not l_any then
      l := l || '<p>За вибраний період рухів каси немає.</p>';
    end if;
    return l || '</div>';
  end cash_book_html;

end trade_cash_doc;
/

-- ---------------------------------------------------------------- тригери документів
declare
  procedure trg (p_tab varchar2, p_type varchar2) is
  begin
    execute immediate replace(replace(q'[
create or replace trigger #T#_biud
before insert or update or delete on #T# for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('#T#_NUM_SEQ'));
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
    trade_cash_doc.check_header('#K#', inserting, :new.operation_kind, :new.occurred_at,
      :new.organization_id, :new.cash_desk_id, :old.cash_desk_id, :new.currency_code,
      :new.amount, :new.counterparty_id, :old.counterparty_id, :new.contract_id,
      :new.accountable_person, :new.bank_account_id, :old.bank_account_id,
      :new.person_name, :new.basis, :new.base_doc_type, :new.base_doc_id);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;]', '#T#', p_tab), '#K#', p_type);
  end;
begin
  trg('doc_cash_receipt', 'DocCashReceipt');
  trg('doc_cash_payment', 'DocCashPayment');
end;
/

-- ---------------------------------------------------------------- реєстратори (+ ПКО/ВКО, рахунки на оплату)
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
union all select 'DocCashPayment', d.id, 'Видатковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 381 from doc_cash_payment d;

-- Список ордерів (сторінки 370/380)
create or replace view v_cash_order_list as
select c.doc_type, c.id, c.doc_number, c.occurred_at, c.organization_id, o.name organization_name,
       c.operation_kind, trade_cash_doc.operation_name(c.doc_type, c.operation_kind) operation_name,
       c.cash_desk_id, k.name cash_desk_name, c.currency_code, c.amount, c.counterparty_id, cp.name counterparty_name,
       c.person_name, c.basis, c.status, c.doc_comment
  from v_cash_order c
  join ref_organization o on o.id = c.organization_id
  join ref_cash_desk k on k.id = c.cash_desk_id
  left join ref_counterparty cp on cp.id = c.counterparty_id;

-- ---------------------------------------------------------------- меню: «Фінанси → Каса»
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
  obj('DocCashReceipt', 'DOCUMENT', 'Documents', 'Прибуткові касові ордери', 370, 371, 140);
  obj('DocCashPayment', 'DOCUMENT', 'Documents', 'Видаткові касові ордери',  380, 381, 150);
  obj('CashBook',       'REPORT',   'Reports',   'Касова книга',             390, null, 130);
  fp('Finance', 'Каса', 1, 5, 'DocCashReceipt', 10, 'Y');
  fp('Finance', 'Каса', 1, 5, 'DocCashPayment', 20, 'Y');
  fp('Finance', 'Звіти', 1, 20, 'CashBook', 20);
  commit;
end;
/

-- ---------------------------------------------------------------- демо: видача під звіт і повернення залишку
declare
  n number; l_desk varchar2(32); d varchar2(32);
begin
  select count(*) into n from v_cash_order;
  if n > 0 then return; end if;
  l_desk := trade_cash_doc.default_cash_desk(trade_org.default_org, 'UAH');
  if l_desk is null or trade_cash.balance(l_desk) < 1000 then return; end if;
  insert into doc_cash_payment (occurred_at, operation_kind, cash_desk_id, amount, accountable_person, basis)
  values (trunc(sysdate) - 2 + 10/24, 'ACCOUNTABLE_ISSUE', l_desk, 1000, 'Іваненко Петро Сергійович', 'На господарські потреби')
  returning id into d;
  trade_cash_doc.post_payment(d);
  insert into doc_cash_receipt (occurred_at, operation_kind, cash_desk_id, amount, accountable_person, basis)
  values (trunc(sysdate) - 1 + 15/24, 'ACCOUNTABLE_RETURN', l_desk, 150, 'Іваненко Петро Сергійович', 'Повернення невикористаного залишку підзвітної суми')
  returning id into d;
  trade_cash_doc.post_receipt(d);
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
