-- =============================================================================
-- Trade r4 — F-SAL-07 «Оплата від покупця» (паспорт DocCustomerPayment, ревізія r4, PROPOSED).
-- Дзеркало F-PUR-05 (db/31, «Оплата постачальнику»):
--   * джерело коштів: форма оплати BANK (надходження на банківський рахунок організації) або CASH
--     (прийом готівки в касу організації); проведення рухає RegCashBalance (+сума) і
--     RegCounterpartySettlement (RECEIVABLE −сума) з організацією документа; переплата покупця
--     (аванс) заборонена — авансів ще немає;
--   * прив'язка до договору з покупцем, замовлення клієнта (проведене) і рахунку на оплату (виданий);
--     документ-підстава — реалізація, рахунок на оплату або замовлення клієнта; введення на підставі:
--     payment_from_sale, payment_from_invoice, payment_from_customer_order;
--   * стан оплати рахунку: «Не оплачено» / «Частково оплачено» / «Оплачено» — сума проведених оплат
--     від покупця з цим рахунком і проведених ПКО на підставі рахунку (invoice_paid / payment_state);
--   * розшифровка платежу (doc_customer_payment_alloc): під час проведення сума розподіляється на
--     документи боргу (реалізації тощо) FIFO за датою боргу; спершу — документ-підстава і реалізації
--     замовлення оплати. Відкритий залишок документів визначається FIFO-припущенням від сальдо
--     дебіторки на дату оплати (найстаріші борги вважаються погашеними першими), тому враховуються й
--     ПКО, рядки виписок, коригування. Нерозподілений залишок (борг виник пізніше дати оплати) — допустимий;
--   * ПРАВИЛО ОДНОГО ПЛАТЕЖУ (db/31): безготівкова оплата від покупця й рядок виписки «Оплата від
--     покупця» — один платіж; прив'язаний рядок (payment_doc_id) лише звіряє, автозв'язок під час
--     проведення виписки, PAYMENT_ALREADY_IN_STATEMENT, PAYMENT_LINKED_TO_STATEMENT (trade_pay_doc —
--     загальні процедури за v_payment_doc);
--   * друк: PAY_NOTICE «Повідомлення про надходження оплати» (BANK), PAY_KO1 «Прибутковий касовий
--     ордер (КО-1)» (CASH) — через trade_print.document_html.
-- Потребує 24, 26, 27, 28, 29, 31. trade_ops.*_customer_payment (db/06) делегують сюди.
-- Скрипт повторно виконуваний. Після повторного виконання db/31 (v_payment_doc) — виконати знову.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2264, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl(q'[alter table doc_customer_payment add (payment_form varchar2(10) default on null 'BANK' not null)]');
  ddl('alter table doc_customer_payment add (bank_account_id varchar2(32))');
  ddl('alter table doc_customer_payment add (cash_desk_id varchar2(32))');
  ddl('alter table doc_customer_payment add (contract_id varchar2(32))');
  ddl('alter table doc_customer_payment add (customer_order_id varchar2(32))');
  ddl('alter table doc_customer_payment add (invoice_id varchar2(32))');
  ddl('alter table doc_customer_payment add (base_doc_type varchar2(60))');
  ddl('alter table doc_customer_payment add (base_doc_id varchar2(32))');
  ddl('alter table doc_customer_payment add (purpose varchar2(500))');
  ddl(q'[alter table doc_customer_payment add constraint doc_customer_payment_form_ck check (payment_form in ('BANK','CASH'))]');
  ddl('alter table doc_customer_payment add constraint doc_customer_payment_bank_fk foreign key (bank_account_id) references ref_bank_account (id)');
  ddl('alter table doc_customer_payment add constraint doc_customer_payment_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id)');
  ddl('alter table doc_customer_payment add constraint doc_customer_payment_ctr_fk foreign key (contract_id) references ref_contract (id)');
  ddl('alter table doc_customer_payment add constraint doc_customer_payment_ord_fk foreign key (customer_order_id) references doc_customer_order (id)');
  ddl('alter table doc_customer_payment add constraint doc_customer_payment_inv_fk foreign key (invoice_id) references doc_invoice_for_payment (id)');
  ddl('create index doc_customer_payment_bank_ix on doc_customer_payment (bank_account_id, occurred_at)');
  ddl('create index doc_customer_payment_desk_ix on doc_customer_payment (cash_desk_id, occurred_at)');
  ddl('create index doc_customer_payment_ord_ix on doc_customer_payment (customer_order_id)');
  ddl('create index doc_customer_payment_inv_ix on doc_customer_payment (invoice_id)');
  ddl('create index doc_customer_payment_base_ix on doc_customer_payment (base_doc_id)');
  -- Розшифровка платежу (заповнюється проведенням, FIFO)
  ddl(q'[create table doc_customer_payment_alloc (
    id                  varchar2(32)  default on null rawtohex(sys_guid()) not null,
    document_id         varchar2(32)  not null,
    line_number         number(10)    not null,
    settlement_doc_type varchar2(60)  not null,
    settlement_doc_id   varchar2(32)  not null,
    settlement_doc_date date          not null,
    amount              number(19,2)  not null,
    constraint doc_customer_payment_alloc_pk primary key (id),
    constraint doc_customer_payment_alloc_uk unique (document_id, line_number),
    constraint doc_customer_payment_alloc_amt_ck check (amount > 0),
    constraint doc_customer_payment_alloc_doc_fk foreign key (document_id) references doc_customer_payment (id) on delete cascade)]');
  ddl('create index doc_customer_payment_alloc_set_ix on doc_customer_payment_alloc (settlement_doc_id)');
end;
/

-- Платіжні документи з контрагентами (зв'язок із рядками виписки): оплати постачальникам і від покупців
create or replace view v_payment_doc as
select 'DocSupplierPayment' doc_type, 'SUPPLIER_PAYMENT' statement_op, 'OUT' direction, d.id, d.doc_number, d.occurred_at,
       d.organization_id, d.payment_form, d.bank_account_id, d.cash_desk_id, d.supplier_id counterparty_id, d.contract_id,
       d.amount, d.currency_code, d.status
  from doc_supplier_payment d
union all
select 'DocCustomerPayment', 'CUSTOMER_PAYMENT', 'IN', d.id, d.doc_number, d.occurred_at,
       d.organization_id, d.payment_form, d.bank_account_id, d.cash_desk_id, d.customer_id, d.contract_id,
       d.amount, d.currency_code, d.status
  from doc_customer_payment d;

create or replace package trade_cust_pay as
  c_customer constant varchar2(60) := 'DocCustomerPayment';

  -- Перевірка й доповнення шапки (тригер doc_customer_payment)
  procedure check_customer_header (p_inserting in boolean, p_date in date, p_org in out varchar2,
                                   p_customer in varchar2, p_old_customer in varchar2, p_amount in number,
                                   p_form in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                                   p_desk in out varchar2, p_old_desk in varchar2, p_contract in out varchar2,
                                   p_order in out varchar2, p_invoice in out varchar2,
                                   p_base_type in out varchar2, p_base_id in varchar2, p_purpose in out varchar2);

  procedure post_customer_payment   (p_id in varchar2);
  procedure unpost_customer_payment (p_id in varchar2);
  function  copy_customer_payment   (p_id in varchar2) return varchar2;

  -- Розшифровка платежу FIFO (викликається проведенням; повертає нерозподілений залишок)
  function allocate (p_id in varchar2) return number;

  -- Введення на підставі (повертає id нової чернетки оплати)
  function payment_from_sale           (p_sale_id in varchar2) return varchar2;
  function payment_from_invoice        (p_invoice_id in varchar2) return varchar2;
  function payment_from_customer_order (p_order_id in varchar2) return varchar2;

  -- Сплачено за замовленням клієнта / рахунком (проведені оплати від покупця; для рахунку — і ПКО)
  function paid_by_order (p_order_id in varchar2) return number;
  function invoice_paid  (p_invoice_id in varchar2) return number;
  -- Стан оплати рахунку: NOT_PAID / PARTIAL / PAID (null — чернетка чи анульований рахунок)
  function payment_state      (p_invoice_id in varchar2) return varchar2;
  function payment_state_name (p_invoice_id in varchar2) return varchar2;

  -- Друк: PAY_NOTICE — повідомлення про надходження (BANK), PAY_KO1 — прибутковий касовий ордер (CASH)
  function default_form (p_id in varchar2) return varchar2;
  function forms_of (p_id in varchar2) return varchar2;
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
end trade_cust_pay;
/

create or replace package body trade_cust_pay as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function cp_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_counterparty where id = p_id;
    return l;
  end cp_name;

  -- ------------------------------------------------------------- шапка
  procedure base_info (p_type varchar2, p_id varchar2, o_org out varchar2, o_cp out varchar2, o_contract out varchar2,
                       o_order out varchar2, o_invoice out varchar2, o_name out varchar2) is
  begin
    case p_type
      when 'DocGoodsSale' then
        select organization_id, customer_id, contract_id, base_order_id, null,
               'видатковою накладною № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_contract, o_order, o_invoice, o_name from doc_goods_sale where id = p_id;
      when 'DocInvoiceForPayment' then
        select organization_id, customer_id, contract_id, base_order_id, id,
               'рахунком на оплату № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_contract, o_order, o_invoice, o_name from doc_invoice_for_payment where id = p_id;
      when 'DocCustomerOrder' then
        select organization_id, customer_id, contract_id, id, null,
               'замовленням № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_contract, o_order, o_invoice, o_name from doc_customer_order where id = p_id;
      else
        fail('PAYMENT_BASE_TYPE', 'Підставою оплати від покупця може бути реалізація, рахунок на оплату або замовлення клієнта.');
    end case;
  exception when no_data_found then
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end base_info;

  procedure check_customer_header (p_inserting in boolean, p_date in date, p_org in out varchar2,
                                   p_customer in varchar2, p_old_customer in varchar2, p_amount in number,
                                   p_form in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                                   p_desk in out varchar2, p_old_desk in varchar2, p_contract in out varchar2,
                                   p_order in out varchar2, p_invoice in out varchar2,
                                   p_base_type in out varchar2, p_base_id in varchar2, p_purpose in out varchar2) is
    l_org varchar2(32); l_cur varchar2(3);
    l_base_org varchar2(32); l_base_cp varchar2(32); l_base_ctr varchar2(32); l_base_ord varchar2(32);
    l_base_inv varchar2(32); l_base_name varchar2(255);
    o doc_customer_order%rowtype;
    i doc_invoice_for_payment%rowtype;
    l_ctr_name varchar2(400);
  begin
    if p_customer is null then
      fail('PAYMENT_CUSTOMER_REQUIRED', 'Вкажіть покупця.');
    end if;
    if p_inserting or p_customer <> nvl(p_old_customer, '-') then
      trade_core.check_active_ref('REF_COUNTERPARTY', p_customer, 'Покупець');
    end if;
    if p_amount is null or p_amount <= 0 then
      fail('PAYMENT_AMOUNT', 'Сума оплати має бути більшою за нуль.');
    end if;

    -- документ-підстава: організація, покупець, договір, замовлення й рахунок з підстави
    if p_base_id is not null then
      if p_base_type is null then
        select max(recorder_type) into p_base_type from v_recorder
         where recorder_id = p_base_id and recorder_type in ('DocGoodsSale', 'DocInvoiceForPayment', 'DocCustomerOrder');
      end if;
      base_info(p_base_type, p_base_id, l_base_org, l_base_cp, l_base_ctr, l_base_ord, l_base_inv, l_base_name);
      if l_base_cp <> p_customer then
        fail('PAYMENT_BASE_CUSTOMER', 'Покупець оплати не збігається з покупцем документа-підстави.');
      end if;
      p_org := coalesce(p_org, l_base_org);
      if l_base_org <> p_org then
        fail('PAYMENT_BASE_ORGANIZATION', 'Документ-підстава оформлений від іншої організації.');
      end if;
      if p_inserting then
        p_invoice := coalesce(p_invoice, l_base_inv);
        p_order := coalesce(p_order, l_base_ord);
        p_contract := coalesce(p_contract, l_base_ctr);
      end if;
    else
      p_base_type := null;
    end if;

    -- джерело коштів
    p_form := coalesce(p_form, 'BANK');
    if p_form not in ('BANK', 'CASH') then
      fail('PAYMENT_FORM', 'Форма оплати — безготівкова (BANK) або готівкова (CASH).');
    end if;
    if p_org is null then
      if p_form = 'BANK' then
        select max(organization_id) into p_org from ref_bank_account where id = p_bank;
      else
        select max(organization_id) into p_org from ref_cash_desk where id = p_desk;
      end if;
      p_org := coalesce(p_org, trade_org.default_org);
    end if;
    if p_form = 'BANK' then
      p_desk := null;
      p_bank := coalesce(p_bank, trade_fin.default_bank_account(p_org, 'UAH'));
      if p_bank is null then
        fail('PAYMENT_BANK_REQUIRED', 'Вкажіть банківський рахунок організації, на який надходить оплата.');
      end if;
      if p_inserting or p_bank <> nvl(p_old_bank, '-') then
        trade_core.check_active_ref('REF_BANK_ACCOUNT', p_bank, 'Банківський рахунок');
      end if;
      select organization_id, currency_code into l_org, l_cur from ref_bank_account where id = p_bank;
      if l_org <> p_org then
        fail('PAYMENT_BANK_ORGANIZATION', 'Банківський рахунок належить іншій організації.');
      end if;
    else
      p_bank := null;
      p_desk := coalesce(p_desk, trade_cash_doc.default_cash_desk(p_org, 'UAH'));
      if p_desk is null then
        fail('PAYMENT_DESK_REQUIRED', 'Вкажіть касу організації, до якої приймається готівка.');
      end if;
      if p_inserting or p_desk <> nvl(p_old_desk, '-') then
        trade_core.check_active_ref('REF_CASH_DESK', p_desk, 'Каса');
      end if;
      select organization_id, currency_code into l_org, l_cur from ref_cash_desk where id = p_desk;
      if l_org <> p_org then
        fail('PAYMENT_DESK_ORGANIZATION', 'Каса належить іншій організації.');
      end if;
    end if;
    if l_cur <> 'UAH' then
      fail('PAYMENT_CURRENCY', 'Розрахунки з покупцями ведуться в UAH — виберіть гривневий рахунок / касу.');
    end if;

    -- рахунок на оплату (виданий, той самий покупець і організація)
    if p_invoice is not null then
      begin
        select * into i from doc_invoice_for_payment where id = p_invoice;
      exception when no_data_found then
        fail('PAYMENT_INVOICE_NOT_FOUND', 'Рахунок на оплату не знайдено.');
      end;
      if i.customer_id <> p_customer then
        fail('PAYMENT_INVOICE_CUSTOMER', 'Рахунок № ' || i.doc_number || ' виставлено іншому покупцю.');
      end if;
      if i.organization_id <> p_org then
        fail('PAYMENT_INVOICE_ORGANIZATION', 'Рахунок № ' || i.doc_number || ' виставлено від іншої організації.');
      end if;
      if i.status <> 'ISSUED' then
        fail('PAYMENT_INVOICE_NOT_ISSUED', 'Рахунок № ' || i.doc_number || ' не видано (чернетка або анульований).');
      end if;
      if p_inserting then
        p_order := coalesce(p_order, i.base_order_id);
        p_contract := coalesce(p_contract, i.contract_id);
      end if;
    end if;

    -- замовлення клієнта (проведене, той самий покупець і організація)
    if p_order is not null then
      begin
        select * into o from doc_customer_order where id = p_order;
      exception when no_data_found then
        fail('PAYMENT_ORDER_NOT_FOUND', 'Замовлення клієнта не знайдено.');
      end;
      if o.customer_id <> p_customer then
        fail('PAYMENT_ORDER_CUSTOMER', 'Замовлення № ' || o.doc_number || ' оформлено на іншого покупця.');
      end if;
      if o.organization_id <> p_org then
        fail('PAYMENT_ORDER_ORGANIZATION', 'Замовлення № ' || o.doc_number || ' оформлено від іншої організації.');
      end if;
      if o.status <> 'POSTED' then
        fail('PAYMENT_ORDER_NOT_POSTED', 'Замовлення № ' || o.doc_number || ' не проведено.');
      end if;
      if p_contract is null and p_inserting then
        p_contract := o.contract_id;
      end if;
    end if;

    -- договір з покупцем
    if p_contract is null and p_inserting then
      p_contract := trade_nsi.resolve_default_contract(p_customer, 'WITH_CUSTOMER', p_date);
    end if;
    trade_nsi.check_contract(p_contract, p_customer, 'WITH_CUSTOMER', p_date);

    -- призначення платежу за замовчуванням
    p_purpose := trim(p_purpose);
    if p_purpose is null then
      if p_contract is not null then
        select max(case when contract_number is not null then 'договором № ' || contract_number
                          || case when contract_date is not null then ' від ' || to_char(contract_date, 'DD.MM.YYYY') end
                        else 'договором «' || name || '»' end)
          into l_ctr_name from ref_contract where id = p_contract;
      end if;
      if l_base_name is null and p_invoice is not null then
        l_base_name := 'рахунком на оплату № ' || i.doc_number || ' від ' || to_char(i.occurred_at, 'DD.MM.YYYY');
      elsif l_base_name is null and p_order is not null then
        l_base_name := 'замовленням № ' || o.doc_number || ' від ' || to_char(o.occurred_at, 'DD.MM.YYYY');
      end if;
      p_purpose := substr('Оплата за товар'
        || case when l_base_name is not null or l_ctr_name is not null then ' згідно з ' end
        || l_base_name || case when l_base_name is not null and l_ctr_name is not null then ', ' end || l_ctr_name, 1, 500);
    end if;
  end check_customer_header;

  -- ------------------------------------------------------------- розшифровка платежу (FIFO)
  function allocate (p_id in varchar2) return number is
    d doc_customer_payment%rowtype;
    l_left number; l_amt number; n number := 0;
  begin
    select * into d from doc_customer_payment where id = p_id;
    delete from doc_customer_payment_alloc where document_id = p_id;
    l_left := d.amount;
    for r in (
      with mv as (
        select recorder_type, recorder_id, min(period) dt, sum(amount) amt
          from reg_counterparty_settlement_mv
         where organization_id = d.organization_id and counterparty_id = d.customer_id
           and direction = 'RECEIVABLE' and currency_code = 'UAH' and period <= d.occurred_at
           and not (recorder_type = c_customer and recorder_id = p_id)
         group by recorder_type, recorder_id),
      tot as (select coalesce(sum(amt), 0) dbt from mv),
      deb as (
        select mv.*, tot.dbt,
               coalesce(sum(mv.amt) over (order by mv.dt desc, mv.recorder_id desc rows between unbounded preceding and 1 preceding), 0) newer
          from mv cross join tot where mv.amt > 0),
      opn as (select recorder_type, recorder_id, dt, least(amt, greatest(dbt - newer, 0)) open_amt from deb)
      select o.recorder_type, o.recorder_id, o.dt, o.open_amt,
             case when o.recorder_id = d.base_doc_id then 0
                  when d.customer_order_id is not null and o.recorder_type = 'DocGoodsSale'
                       and exists (select 1 from doc_goods_sale s where s.id = o.recorder_id and s.base_order_id = d.customer_order_id) then 1
                  else 2 end prio
        from opn o
       where o.open_amt > 0
       order by prio, o.dt, o.recorder_id) loop
      exit when l_left <= 0;
      l_amt := least(l_left, r.open_amt);
      n := n + 1;
      insert into doc_customer_payment_alloc (document_id, line_number, settlement_doc_type, settlement_doc_id, settlement_doc_date, amount)
      values (p_id, n, r.recorder_type, r.recorder_id, r.dt, l_amt);
      l_left := l_left - l_amt;
    end loop;
    return l_left;
  end allocate;

  -- ------------------------------------------------------------- проведення
  procedure delete_moves (p_id varchar2) is
  begin
    trade_cash.delete_movements(c_customer, p_id);
    delete from reg_counterparty_settlement_mv where recorder_type = c_customer and recorder_id = p_id;
    delete from doc_customer_payment_alloc where document_id = p_id;
  end delete_moves;

  procedure post_customer_payment (p_id in varchar2) is
    d doc_customer_payment%rowtype;
    l_dummy varchar2(32); l_num varchar2(9); l_line number; l_left number;
  begin
    begin
      select * into d from doc_customer_payment where id = p_id for update;
    exception when no_data_found then
      fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
    end;
    trade_core.check_active_ref('REF_COUNTERPARTY', d.customer_id, 'Покупець');
    if d.payment_form = 'BANK' then
      trade_core.check_active_ref('REF_BANK_ACCOUNT', d.bank_account_id, 'Банківський рахунок');
      -- правило одного платежу: це надходження вже провела виписка неприв'язаним рядком?
      select max(s.doc_number) keep (dense_rank first order by abs(s.occurred_at - d.occurred_at)),
             max(l.line_number) keep (dense_rank first order by abs(s.occurred_at - d.occurred_at))
        into l_num, l_line
        from doc_bank_statement_line l join doc_bank_statement s on s.id = l.document_id
       where s.status = 'POSTED' and s.bank_account_id = d.bank_account_id
         and l.operation_kind = 'CUSTOMER_PAYMENT' and l.counterparty_id = d.customer_id and l.amount = d.amount
         and l.payment_doc_id is null
         and s.occurred_at between trunc(d.occurred_at) - 3 and trunc(d.occurred_at) + 4;
      if l_num is not null then
        fail('PAYMENT_ALREADY_IN_STATEMENT', 'Це надходження вже відображено рядком ' || l_line || ' проведеної банківської виписки № '
          || l_num || ' (рух рахунку й погашення боргу записала виписка). Щоб оформити оплату документом, скасуйте проведення '
          || 'виписки, проведіть оплату й проведіть виписку знову — рядок прив''яжеться до оплати автоматично.');
      end if;
    else
      trade_core.check_active_ref('REF_CASH_DESK', d.cash_desk_id, 'Каса');
    end if;
    select id into l_dummy from ref_counterparty where id = d.customer_id for update;

    trade_core.g_internal := true;
    delete_moves(p_id);
    l_left := allocate(p_id);
    trade_cash.add_movement(c_customer, p_id, d.occurred_at, 1,
                            case d.payment_form when 'BANK' then trade_cash.c_bank_account else trade_cash.c_cash_desk end,
                            coalesce(d.bank_account_id, d.cash_desk_id), d.amount, 'CUSTOMER_PAYMENT',
                            'Оплата від покупця № ' || d.doc_number || ' — ' || cp_name(d.customer_id));
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id,
                                                direction, currency_code, amount, organization_id)
    values (d.occurred_at, c_customer, p_id, 1, d.customer_id, 'RECEIVABLE', 'UAH', -d.amount, d.organization_id);
    trade_cash.check_balances;
    trade_org.check_settlement(d.organization_id, d.customer_id);
    update doc_customer_payment set status = 'POSTED' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_customer, p_id, 'POST', case d.payment_form when 'BANK' then 'Безготівкова' else 'Готівкова' end
      || ', сума ' || m(d.amount) || ' ' || d.currency_code || case when l_left > 0 then ', не розподілено ' || m(l_left) end);
  exception when others then
    trade_core.g_internal := false;
    raise;
  end post_customer_payment;

  procedure unpost_customer_payment (p_id in varchar2) is
    d doc_customer_payment%rowtype;
  begin
    begin
      select * into d from doc_customer_payment where id = p_id for update;
    exception when no_data_found then
      fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
    end;
    if d.status <> 'POSTED' then
      fail('DOCUMENT_NOT_POSTED', 'Документ не проведено.');
    end if;
    trade_pay_doc.check_payment_change(p_id, false);
    trade_core.g_internal := true;
    delete_moves(p_id);
    trade_cash.check_balances;
    trade_org.check_settlement(d.organization_id, d.customer_id);
    update doc_customer_payment set status = 'DRAFT' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_customer, p_id, 'UNPOST');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end unpost_customer_payment;

  function copy_customer_payment (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_customer_payment (id, occurred_at, organization_id, customer_id, currency_code, amount, payment_form,
                                      bank_account_id, cash_desk_id, contract_id, customer_order_id, invoice_id,
                                      base_doc_type, base_doc_id, purpose, doc_comment)
    select l_new, sysdate, organization_id, customer_id, currency_code, amount, payment_form, bank_account_id, cash_desk_id,
           contract_id, customer_order_id,
           (select i.id from doc_invoice_for_payment i where i.id = p.invoice_id and i.status = 'ISSUED'),
           base_doc_type, base_doc_id, purpose, doc_comment
      from doc_customer_payment p where id = p_id;
    trade_core.audit(c_customer, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_customer_payment;

  -- ------------------------------------------------------------- сплачено / стан оплати рахунку
  function paid_by_order (p_order_id in varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from doc_customer_payment where customer_order_id = p_order_id and status = 'POSTED';
    return l;
  end paid_by_order;

  function invoice_paid (p_invoice_id in varchar2) return number is
    l1 number; l2 number;
  begin
    select coalesce(sum(amount), 0) into l1 from doc_customer_payment where invoice_id = p_invoice_id and status = 'POSTED';
    select coalesce(sum(amount), 0) into l2 from doc_cash_receipt
     where base_doc_type = 'DocInvoiceForPayment' and base_doc_id = p_invoice_id and status = 'POSTED';
    return l1 + l2;
  end invoice_paid;

  function payment_state (p_invoice_id in varchar2) return varchar2 is
    l_total number; l_status varchar2(10); l_paid number;
  begin
    select max(total_amount), max(status) into l_total, l_status from doc_invoice_for_payment where id = p_invoice_id;
    if l_status is null or l_status <> 'ISSUED' then
      return null;
    end if;
    l_paid := invoice_paid(p_invoice_id);
    return case when l_paid <= 0 then 'NOT_PAID' when l_paid < l_total then 'PARTIAL' else 'PAID' end;
  end payment_state;

  function payment_state_name (p_invoice_id in varchar2) return varchar2 is
  begin
    return case payment_state(p_invoice_id)
      when 'NOT_PAID' then 'Не оплачено' when 'PARTIAL' then 'Частково оплачено' when 'PAID' then 'Оплачено' end;
  end payment_state_name;

  -- ------------------------------------------------------------- введення на підставі
  function create_based (p_base_type varchar2, p_base_id varchar2, p_org varchar2, p_customer varchar2, p_amount number) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
    l_form varchar2(10);
  begin
    if nvl(p_amount, 0) <= 0 then
      fail('PAYMENT_NOTHING_TO_PAY', 'Заборгованості покупця за організацією документа немає '
        || '(або документ уже сплачено). Авансові оплати від покупців ще не підтримуються.');
    end if;
    l_form := case when trade_fin.default_bank_account(p_org, 'UAH') is not null then 'BANK'
                   when trade_cash_doc.default_cash_desk(p_org, 'UAH') is not null then 'CASH' end;
    if l_form is null then
      fail('PAYMENT_SOURCE_NOT_FOUND', 'В організації документа немає активного гривневого банківського рахунку чи каси. '
        || 'Створіть їх у розділі «Фінанси».');
    end if;
    insert into doc_customer_payment (id, occurred_at, organization_id, customer_id, amount, payment_form, base_doc_type, base_doc_id)
    values (l_new, sysdate, p_org, p_customer, p_amount, l_form, p_base_type, p_base_id);
    trade_core.audit(c_customer, l_new, 'CREATE_BASED_ON', p_base_type || ' ' || p_base_id);
    return l_new;
  end create_based;

  function debt (p_org varchar2, p_cp varchar2) return number is
  begin
    return trade_cash_doc.counterparty_debt(p_org, p_cp, 'RECEIVABLE');
  end debt;

  function payment_from_sale (p_sale_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_goods_sale where id = p_sale_id) loop
      if d.status <> 'POSTED' then fail('PAYMENT_BASE_NOT_POSTED', 'Реалізацію не проведено.'); end if;
      return create_based('DocGoodsSale', d.id, d.organization_id, d.customer_id,
                          least(d.total_amount, debt(d.organization_id, d.customer_id)));
    end loop;
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_sale;

  function payment_from_invoice (p_invoice_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_invoice_for_payment where id = p_invoice_id) loop
      if d.status <> 'ISSUED' then fail('PAYMENT_BASE_NOT_POSTED', 'Рахунок на оплату не видано (або анульовано).'); end if;
      -- залишок до оплати за рахунком, але не більше поточного боргу (без авансів)
      return create_based('DocInvoiceForPayment', d.id, d.organization_id, d.customer_id,
                          least(d.total_amount - invoice_paid(d.id), debt(d.organization_id, d.customer_id)));
    end loop;
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_invoice;

  function payment_from_customer_order (p_order_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_customer_order where id = p_order_id) loop
      if d.status <> 'POSTED' then fail('PAYMENT_BASE_NOT_POSTED', 'Замовлення клієнта не проведено.'); end if;
      return create_based('DocCustomerOrder', d.id, d.organization_id, d.customer_id,
                          least(d.total_amount - paid_by_order(d.id), debt(d.organization_id, d.customer_id)));
    end loop;
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_customer_order;

  -- ------------------------------------------------------------- друк
  function default_form (p_id in varchar2) return varchar2 is
    l varchar2(10);
  begin
    select max(payment_form) into l from doc_customer_payment where id = p_id;
    return case l when 'CASH' then 'PAY_KO1' when 'BANK' then 'PAY_NOTICE' end;
  end default_form;

  function forms_of (p_id in varchar2) return varchar2 is
  begin
    return case default_form(p_id)
      when 'PAY_NOTICE' then 'PAY_NOTICE:Повідомлення про надходження оплати'
      when 'PAY_KO1' then 'PAY_KO1:Прибутковий касовий ордер (КО-1)' end;
  end forms_of;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:980px;background:#fff;padding:16px;position:relative}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}.tx-print h3{font-size:14px;text-align:center;margin:8px 0}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:4px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px;text-align:left}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .small{font-size:10px;color:#333}
      .tx-print .ln td{padding:4px 2px;vertical-align:bottom}.tx-print .ln .v{border-bottom:1px solid #000;width:100%}
      .tx-print .ko{display:flex;gap:0}.tx-print .ko .main{flex:3;padding-right:14px}
      .tx-print .ko .slip{flex:2;border-left:1px dashed #000;padding-left:14px}
      .tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}}
      </style>';
  end css;

  function line (p_label varchar2, p_value varchar2) return varchar2 is
  begin
    return '<table class="ln"><tr><td style="white-space:nowrap">' || e(p_label) || '</td><td class="v">' || e(p_value) || '</td></tr></table>';
  end line;

  -- Розшифровка платежу (таблиця для друку)
  function alloc_html (p_id varchar2, p_amount number) return varchar2 is
    l varchar2(32767); l_sum number := 0;
  begin
    for a in (select a.line_number, a.amount, a.settlement_doc_date, coalesce(r.recorder_name, a.settlement_doc_type) doc_name
                from doc_customer_payment_alloc a
                left join v_recorder r on r.recorder_type = a.settlement_doc_type and r.recorder_id = a.settlement_doc_id
               where a.document_id = p_id order by a.line_number) loop
      l := l || '<tr><td class="r">' || a.line_number || '</td><td>' || e(regexp_replace(a.doc_name, ' \d\d:\d\d:\d\d$'))
             || '</td><td class="r">' || m(a.amount) || '</td></tr>';
      l_sum := l_sum + a.amount;
    end loop;
    if l is null then
      return null;
    end if;
    return '<h3>Розшифровка платежу</h3><table class="grid"><tr><th style="width:40px">№</th><th>Документ розрахунків</th>'
      || '<th style="width:140px">Сума, UAH</th></tr>' || l
      || case when p_amount > l_sum then '<tr><td></td><td>Не розподілено</td><td class="r">' || m(p_amount - l_sum) || '</td></tr>' end
      || '</table>';
  end alloc_html;

  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    c ref_counterparty%rowtype;
    b ref_bank_account%rowtype;
    l_cashier varchar2(255);
  begin
    for d in (select * from doc_customer_payment where id = p_id) loop
      select * into o from ref_organization where id = d.organization_id;
      select * into c from ref_counterparty where id = d.customer_id;
      l := '<div class="tx-print">' || css || case when d.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end;
      if p_form = 'PAY_NOTICE' then
        if d.payment_form <> 'BANK' then
          return '<p>Повідомлення про надходження формується лише для безготівкової оплати.</p>';
        end if;
        select * into b from ref_bank_account where id = d.bank_account_id;
        l := l || '<div><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
          || case when o.edrpou is not null then '<br>Код ЄДРПОУ ' || e(o.edrpou) end || '</div>'
          || '<h2>ПОВІДОМЛЕННЯ ПРО НАДХОДЖЕННЯ ОПЛАТИ № ' || e(d.doc_number) || '</h2>'
          || '<p style="text-align:center">від ' || dt(d.occurred_at) || '</p>'
          || '<table class="grid">'
          || '<tr><th style="width:220px">Платник</th><td><b>' || e(c.name) || '</b></td></tr>'
          || '<tr><th>Код платника (ЄДРПОУ / РНОКПП)</th><td>' || e(c.edrpou) || '</td></tr>'
          || '<tr><th>Рахунок платника (IBAN)</th><td>' || e(c.iban) || '</td></tr>'
          || '<tr><th>Отримувач</th><td><b>' || e(coalesce(o.full_name, o.name)) || '</b></td></tr>'
          || '<tr><th>Рахунок отримувача (IBAN)</th><td>' || e(b.iban) || '</td></tr>'
          || '<tr><th>Банк отримувача</th><td>' || e(b.bank_name) || case when b.mfo is not null then ', МФО ' || e(b.mfo) end || '</td></tr>'
          || '<tr><th>Сума</th><td><b>' || m(d.amount) || ' ' || e(d.currency_code) || '</b></td></tr>'
          || '<tr><th>Сума словами</th><td>' || e(trade_r3.amount_in_words_uk(d.amount)) || '</td></tr>'
          || '<tr><th>Призначення платежу</th><td>' || e(d.purpose) || '</td></tr>'
          || '</table>' || alloc_html(d.id, d.amount)
          || '<div style="margin-top:18px;width:60%">' || line('Головний бухгалтер', '____________ ' || o.accountant_name) || '</div>';
      elsif p_form = 'PAY_KO1' then
        if d.payment_form <> 'CASH' then
          return '<p>Прибутковий касовий ордер формується лише для готівкової оплати.</p>';
        end if;
        select responsible_name into l_cashier from ref_cash_desk where id = d.cash_desk_id;
        l := l || '<div class="ko"><div class="main">'
          || '<div class="small" style="text-align:right">Типова форма № КО-1<br>(наказ Мінфіну України від 22.01.1996 № 9)</div>'
          || '<div><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
          || case when o.edrpou is not null then '<br>Ідентифікаційний код ЄДРПОУ ' || e(o.edrpou) end || '</div>'
          || '<h2>Прибутковий касовий ордер № ' || e(d.doc_number) || '<br><span style="font-weight:normal;font-size:13px">від '
          || dt(d.occurred_at) || '</span></h2>'
          || line('Прийнято від', c.name) || line('Підстава', d.purpose)
          || line('Сума', m(d.amount) || ' ' || d.currency_code || ' (' || trade_r3.amount_in_words_uk(d.amount) || ')')
          || '<div style="margin-top:22px">' || line('Головний бухгалтер', '____________ ' || o.accountant_name)
          || line('Одержав касир', '____________ ' || l_cashier) || '</div></div>'
          || '<div class="slip"><div><b>' || e(coalesce(o.full_name, o.name)) || '</b></div>'
          || '<h3>Квитанція до прибуткового касового ордера № ' || e(d.doc_number) || '<br>від ' || dt(d.occurred_at) || '</h3>'
          || line('Прийнято від', c.name) || line('Підстава', d.purpose)
          || line('Сума', m(d.amount) || ' ' || d.currency_code) || line('', trade_r3.amount_in_words_uk(d.amount))
          || '<p>М. П.</p>' || line('Головний бухгалтер', '____________ ' || o.accountant_name)
          || line('Касир', '____________ ' || l_cashier) || '</div></div>';
      else
        return '<p>Невідома друкована форма: ' || e(p_form) || '</p>';
      end if;
      l := l || '</div>';
    end loop;
    return l;
  end print_html;

end trade_cust_pay;
/

-- ---------------------------------------------------------------- тригери документа
-- Організація: з документа-підстави, інакше за замовчуванням (замість тригера db/24)
create or replace trigger doc_customer_payment_org_biu
before insert or update of organization_id, base_doc_id on doc_customer_payment for each row
begin
  trade_org.resolve_doc_org(:new.organization_id, :old.organization_id, :new.base_doc_type, :new.base_doc_id, inserting);
end;
/

create or replace trigger doc_customer_payment_biud
before insert or update or delete on doc_customer_payment for each row
follows doc_customer_payment_org_biu
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_pay_doc.check_payment_change(:old.id, true);
    return;
  end if;
  if inserting then
    :new.doc_number    := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_CUSTOMER_PAYMENT_NUM_SEQ'));
    :new.status        := 'DRAFT';
    :new.version       := 0;
    :new.occurred_at   := coalesce(:new.occurred_at, sysdate);
    :new.created_at    := systimestamp;
    :new.created_by    := trade_core.current_user_name;
  else
    if not trade_core.g_internal then
      if :old.status = 'POSTED' then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
      end if;
      :new.status := :old.status;
    end if;
    :new.version := :old.version + 1;
  end if;
  :new.currency_code := 'UAH';
  trade_core.check_code(:new.doc_number);
  if trade_core.g_internal and updating and :new.status <> :old.status then
    null;   -- зміна статусу проведенням: шапку не перевіряємо повторно (рахунок міг бути анульований після оплати)
  else
    trade_cust_pay.check_customer_header(inserting, :new.occurred_at, :new.organization_id, :new.customer_id, :old.customer_id,
      :new.amount, :new.payment_form, :new.bank_account_id, :old.bank_account_id, :new.cash_desk_id, :old.cash_desk_id,
      :new.contract_id, :new.customer_order_id, :new.invoice_id, :new.base_doc_type, :new.base_doc_id, :new.purpose);
  end if;
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

-- Список оплат від покупців (сторінка 120)
create or replace view v_customer_payment_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name, d.customer_id, c.name customer_name,
       d.payment_form, case d.payment_form when 'BANK' then 'Безготівкова' else 'Готівкова' end payment_form_name,
       coalesce(b.name, k.name) source_name, d.amount, d.currency_code,
       ct.name || case when ct.contract_number is not null then ' № ' || ct.contract_number end contract_name,
       co.doc_number customer_order_number, i.doc_number invoice_number, d.purpose,
       (select sum(a.amount) from doc_customer_payment_alloc a where a.document_id = d.id) allocated_amount,
       (select max(st.doc_number) from doc_bank_statement_line l join doc_bank_statement st on st.id = l.document_id
         where l.payment_doc_id = d.id) statement_number,
       d.status, d.doc_comment
  from doc_customer_payment d
  join ref_organization o on o.id = d.organization_id
  join ref_counterparty c on c.id = d.customer_id
  left join ref_bank_account b on b.id = d.bank_account_id
  left join ref_cash_desk k on k.id = d.cash_desk_id
  left join ref_contract ct on ct.id = d.contract_id
  left join doc_customer_order co on co.id = d.customer_order_id
  left join doc_invoice_for_payment i on i.id = d.invoice_id;

-- Розшифровка платежу (регіон форми 121)
create or replace view v_customer_payment_alloc as
select a.document_id, a.line_number, a.settlement_doc_type, a.settlement_doc_id, a.settlement_doc_date,
       coalesce(regexp_replace(r.recorder_name, ' \d\d:\d\d:\d\d$'), a.settlement_doc_type) settlement_doc_name, a.amount
  from doc_customer_payment_alloc a
  left join v_recorder r on r.recorder_type = a.settlement_doc_type and r.recorder_id = a.settlement_doc_id;

-- Оплати за рахунком на оплату (регіон форми 321): оплати від покупця з рахунком і ПКО на підставі рахунку
create or replace view v_invoice_payment as
select d.invoice_id, 'DocCustomerPayment' doc_type, d.id, 'Оплата від покупця' doc_kind, d.doc_number, d.occurred_at,
       case d.payment_form when 'BANK' then 'Безготівкова' else 'Готівкова' end payment_form_name, d.amount, d.status
  from doc_customer_payment d where d.invoice_id is not null
union all
select r.base_doc_id, 'DocCashReceipt', r.id, 'Прибутковий касовий ордер', r.doc_number, r.occurred_at, 'Готівкова', r.amount, r.status
  from doc_cash_receipt r where r.base_doc_type = 'DocInvoiceForPayment';

-- ---------------------------------------------------------------- меню: «Фінанси» + права касира
begin
  update sys_metadata_object set auth_scheme = 'Роль: продажі або каса' where tech_name = 'DocCustomerPayment';
  insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
  select s.id, 'Банк', 1, 7, o.id, 15, 'Y'
    from sys_main_menu_section s, sys_metadata_object o
   where s.tech_name = 'Finance' and o.tech_name = 'DocCustomerPayment'
     and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  commit;
end;
/

-- ---------------------------------------------------------------- міграція оплат r2–r3
-- Проведені раніше оплати не рухали кошти й не мали розшифровки: заповнюємо джерело (основний рахунок
-- організації, інакше каса) і перепроводимо в порядку дат. Невдалі — лишаються як є (вивід).
set serveroutput on
declare
  l_bank varchar2(32); l_desk varchar2(32);
begin
  for d in (select p.* from doc_customer_payment p
             where (p.payment_form = 'BANK' and p.bank_account_id is null) or (p.payment_form = 'CASH' and p.cash_desk_id is null)
             order by p.occurred_at) loop
    begin
      savepoint mig;
      l_bank := trade_fin.default_bank_account(d.organization_id, 'UAH');
      l_desk := trade_cash_doc.default_cash_desk(d.organization_id, 'UAH');
      trade_core.g_internal := true;
      update doc_customer_payment
         set payment_form = case when l_bank is not null then 'BANK' when l_desk is not null then 'CASH' else payment_form end
       where id = d.id;
      trade_core.g_internal := false;
      if d.status = 'POSTED' then
        trade_cust_pay.post_customer_payment(d.id);
      end if;
    exception when others then
      trade_core.g_internal := false;
      rollback to mig;
      dbms_output.put_line('Оплату від покупця № ' || d.doc_number || ' не перенесено: ' || sqlerrm);
    end;
  end loop;
  commit;
end;
/

-- Перекомпіляція залежних об'єктів (trade_ops делегує в trade_cust_pay, trade_bank_doc / trade_pay_doc — v_payment_doc)
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
