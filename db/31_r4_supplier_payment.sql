-- =============================================================================
-- Trade r4 — F-PUR-05 «Оплата постачальнику» (паспорт DocSupplierPayment, ревізія r4, PROPOSED).
--   * джерело коштів: форма оплати BANK (безготівкова, банківський рахунок організації) або CASH
--     (готівкова, каса організації); проведення рухає RegCashBalance (−сума) і
--     RegCounterpartySettlement (PAYABLE −сума) з організацією документа; контроль від'ємного
--     залишку каси / рахунку й переплати постачальнику (авансів ще немає);
--   * прив'язка до договору з постачальником (за замовчуванням — єдиний договір / договір
--     замовлення) і до замовлення постачальнику (лише проведене, той самий постачальник і
--     організація); документ-підстава — прибуткова накладна або замовлення постачальнику;
--     введення на підставі: payment_from_goods_receipt, payment_from_supplier_order;
--   * друк: PAYMENT_ORDER «Платіжна інструкція (платіжне доручення)» для форми BANK,
--     PAY_KO2 «Видатковий касовий ордер (КО-2)» для форми CASH — через trade_print.document_html;
--   * ПРАВИЛО ОДНОГО ПЛАТЕЖУ (без подвійного обліку): кожен фактичний платіж рухає кошти й
--     взаєморозрахунки рівно одним первинним документом — ВКО / ПКО, «Оплата постачальнику» /
--     «Оплата від покупця» або НЕприв'язаний рядок банківської виписки. Рядок виписки, прив'язаний
--     до оплати (payment_doc_id) чи касового ордера (cash_order_id), лише звіряє і рухів не пише.
--     Під час проведення виписки рядки «Оплата постачальнику» автоматично прив'язуються до
--     проведених безготівкових оплат (рахунок, постачальник, сума, ±3 дні; спершу — за номером
--     платіжки). Проведення оплати, яку вже відобразив НЕприв'язаний рядок проведеної виписки,
--     заборонене (PAYMENT_ALREADY_IN_STATEMENT). Оплату, прив'язану до проведеної виписки, не можна
--     скасувати, а прив'язану до будь-якої виписки — видалити.
--   * узагальнене представлення v_payment_doc (тип, форма, рахунок, контрагент, вид операції
--     виписки) — APE-57 «Оплата від покупця» додає сюди DocCustomerPayment ('CUSTOMER_PAYMENT').
-- Потребує 24 (trade_org), 26, 27 (trade_cash), 28 (trade_cash_doc), 29 (колонки payment_doc_* у
-- рядках виписки). trade_doc.*_supplier_payment (db/02) делегують сюди. Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2264, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl(q'[alter table doc_supplier_payment add (payment_form varchar2(10) default on null 'BANK' not null)]');
  ddl('alter table doc_supplier_payment add (bank_account_id varchar2(32))');
  ddl('alter table doc_supplier_payment add (cash_desk_id varchar2(32))');
  ddl('alter table doc_supplier_payment add (contract_id varchar2(32))');
  ddl('alter table doc_supplier_payment add (supplier_order_id varchar2(32))');
  ddl('alter table doc_supplier_payment add (base_doc_type varchar2(60))');
  ddl('alter table doc_supplier_payment add (base_doc_id varchar2(32))');
  ddl('alter table doc_supplier_payment add (purpose varchar2(500))');
  ddl('alter table doc_supplier_payment add (recipient_iban varchar2(34))');
  ddl(q'[alter table doc_supplier_payment add constraint doc_supplier_payment_form_ck check (payment_form in ('BANK','CASH'))]');
  ddl('alter table doc_supplier_payment add constraint doc_supplier_payment_bank_fk foreign key (bank_account_id) references ref_bank_account (id)');
  ddl('alter table doc_supplier_payment add constraint doc_supplier_payment_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id)');
  ddl('alter table doc_supplier_payment add constraint doc_supplier_payment_ctr_fk foreign key (contract_id) references ref_contract (id)');
  ddl('alter table doc_supplier_payment add constraint doc_supplier_payment_ord_fk foreign key (supplier_order_id) references doc_supplier_order (id)');
  ddl('create index doc_supplier_payment_bank_ix on doc_supplier_payment (bank_account_id, occurred_at)');
  ddl('create index doc_supplier_payment_desk_ix on doc_supplier_payment (cash_desk_id, occurred_at)');
  ddl('create index doc_supplier_payment_ord_ix on doc_supplier_payment (supplier_order_id)');
  ddl('create index doc_supplier_payment_base_ix on doc_supplier_payment (base_doc_id)');
end;
/

-- Платіжні документи з контрагентами (зв'язок із рядками виписки). APE-57: + DocCustomerPayment.
create or replace view v_payment_doc as
select 'DocSupplierPayment' doc_type, 'SUPPLIER_PAYMENT' statement_op, 'OUT' direction, d.id, d.doc_number, d.occurred_at,
       d.organization_id, d.payment_form, d.bank_account_id, d.cash_desk_id, d.supplier_id counterparty_id, d.contract_id,
       d.amount, d.currency_code, d.status
  from doc_supplier_payment d;

create or replace package trade_pay_doc as
  c_supplier constant varchar2(60) := 'DocSupplierPayment';

  -- Назва форми оплати (BANK / CASH)
  function form_name (p_form in varchar2) return varchar2;

  -- Перевірка й доповнення шапки (тригер doc_supplier_payment)
  procedure check_supplier_header (p_inserting in boolean, p_date in date, p_org in out varchar2,
                                   p_supplier in varchar2, p_old_supplier in varchar2, p_amount in number,
                                   p_form in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                                   p_desk in out varchar2, p_old_desk in varchar2, p_contract in out varchar2,
                                   p_order in out varchar2, p_base_type in out varchar2, p_base_id in varchar2,
                                   p_purpose in out varchar2, p_iban in out varchar2);

  procedure post_supplier_payment   (p_id in varchar2);
  procedure unpost_supplier_payment (p_id in varchar2);
  function  copy_supplier_payment   (p_id in varchar2) return varchar2;

  -- Введення на підставі (повертає id нової чернетки оплати)
  function payment_from_goods_receipt (p_receipt_id in varchar2) return varchar2;
  function payment_from_supplier_order (p_order_id in varchar2) return varchar2;
  -- Сплачено за замовленням постачальнику (проведені оплати з цим замовленням)
  function paid_by_order (p_order_id in varchar2) return number;

  -- Зв'язок з банківською випискою (викликається з trade_bank_doc динамічно):
  --   перевірка рядка з payment_doc_id (вид операції, рахунок, сума, контрагент; заповнює тип,
  --   порожніх контрагента й договір з оплати);
  procedure check_statement_link (p_stmt_id in varchar2, p_op in varchar2, p_amount in number,
                                  p_cp in out varchar2, p_contract in out varchar2,
                                  p_pay_type out varchar2, p_pay_id in varchar2);
  --   автозв'язок неприв'язаних рядків виписки з проведеними безготівковими оплатами; кількість;
  function link_statement (p_stmt_id in varchar2) return number;
  --   перед проведенням виписки: прив'язані оплати мають бути проведені
  procedure check_statement (p_stmt_id in varchar2);
  -- Оплата прив'язана до виписки? (скасування — проведена виписка; видалення — будь-яка)
  procedure check_payment_change (p_id in varchar2, p_deleting in boolean);

  -- Друк: PAYMENT_ORDER — платіжна інструкція, PAY_KO2 — видатковий касовий ордер (готівкова форма)
  function default_form (p_id in varchar2) return varchar2;
  function forms_of (p_id in varchar2) return varchar2;
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
end trade_pay_doc;
/

create or replace package body trade_pay_doc as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function form_name (p_form in varchar2) return varchar2 is
  begin
    return case p_form when 'BANK' then 'Безготівкова (банківський рахунок)' when 'CASH' then 'Готівкова (каса)' end;
  end form_name;

  function cp_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_counterparty where id = p_id;
    return l;
  end cp_name;

  -- ------------------------------------------------------------- шапка
  procedure base_info (p_type varchar2, p_id varchar2, o_org out varchar2, o_cp out varchar2,
                       o_contract out varchar2, o_order out varchar2, o_name out varchar2) is
  begin
    case p_type
      when 'DocGoodsReceipt' then
        select organization_id, supplier_id, contract_id, base_order_id,
               'прибутковою накладною № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_contract, o_order, o_name from doc_goods_receipt where id = p_id;
      when 'DocSupplierOrder' then
        select organization_id, supplier_id, contract_id, id,
               'замовленням № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY')
          into o_org, o_cp, o_contract, o_order, o_name from doc_supplier_order where id = p_id;
      else
        fail('PAYMENT_BASE_TYPE', 'Підставою оплати постачальнику може бути прибуткова накладна або замовлення постачальнику.');
    end case;
  exception when no_data_found then
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end base_info;

  procedure check_supplier_header (p_inserting in boolean, p_date in date, p_org in out varchar2,
                                   p_supplier in varchar2, p_old_supplier in varchar2, p_amount in number,
                                   p_form in out varchar2, p_bank in out varchar2, p_old_bank in varchar2,
                                   p_desk in out varchar2, p_old_desk in varchar2, p_contract in out varchar2,
                                   p_order in out varchar2, p_base_type in out varchar2, p_base_id in varchar2,
                                   p_purpose in out varchar2, p_iban in out varchar2) is
    l_org varchar2(32); l_cur varchar2(3);
    l_base_org varchar2(32); l_base_cp varchar2(32); l_base_ctr varchar2(32); l_base_ord varchar2(32); l_base_name varchar2(255);
    o doc_supplier_order%rowtype;
    l_ctr_name varchar2(400);
  begin
    if p_supplier is null then
      fail('PAYMENT_SUPPLIER_REQUIRED', 'Вкажіть постачальника.');
    end if;
    if p_inserting or p_supplier <> nvl(p_old_supplier, '-') then
      trade_core.check_active_ref('REF_COUNTERPARTY', p_supplier, 'Постачальник');
    end if;
    if p_amount is null or p_amount <= 0 then
      fail('PAYMENT_AMOUNT', 'Сума оплати має бути більшою за нуль.');
    end if;

    -- документ-підстава: організація, постачальник, договір і замовлення з підстави
    if p_base_id is not null then
      if p_base_type is null then
        select max(recorder_type) into p_base_type from v_recorder
         where recorder_id = p_base_id and recorder_type in ('DocGoodsReceipt', 'DocSupplierOrder');
      end if;
      base_info(p_base_type, p_base_id, l_base_org, l_base_cp, l_base_ctr, l_base_ord, l_base_name);
      if l_base_cp <> p_supplier then
        fail('PAYMENT_BASE_SUPPLIER', 'Постачальник оплати не збігається з постачальником документа-підстави.');
      end if;
      p_org := coalesce(p_org, l_base_org);
      if l_base_org <> p_org then
        fail('PAYMENT_BASE_ORGANIZATION', 'Документ-підстава оформлений від іншої організації.');
      end if;
      if p_inserting then
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
        fail('PAYMENT_BANK_REQUIRED', 'Вкажіть банківський рахунок організації, з якого сплачується постачальнику.');
      end if;
      if p_inserting or p_bank <> nvl(p_old_bank, '-') then
        trade_core.check_active_ref('REF_BANK_ACCOUNT', p_bank, 'Банківський рахунок');
      end if;
      select organization_id, currency_code into l_org, l_cur from ref_bank_account where id = p_bank;
      if l_org <> p_org then
        fail('PAYMENT_BANK_ORGANIZATION', 'Банківський рахунок належить іншій організації.');
      end if;
      -- IBAN отримувача: з довідника контрагентів, якщо не вказано
      if p_iban is null then
        select max(iban) into p_iban from ref_counterparty where id = p_supplier;
      end if;
      p_iban := trade_fin.normalize_iban(p_iban);
      if p_iban is not null then
        trade_fin.check_iban(p_iban);
      end if;
    else
      p_bank := null; p_iban := null;
      p_desk := coalesce(p_desk, trade_cash_doc.default_cash_desk(p_org, 'UAH'));
      if p_desk is null then
        fail('PAYMENT_DESK_REQUIRED', 'Вкажіть касу організації, з якої видається готівка.');
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
      fail('PAYMENT_CURRENCY', 'Розрахунки з постачальниками ведуться в UAH — виберіть гривневий рахунок / касу.');
    end if;

    -- замовлення постачальнику
    if p_order is not null then
      begin
        select * into o from doc_supplier_order where id = p_order;
      exception when no_data_found then
        fail('PAYMENT_ORDER_NOT_FOUND', 'Замовлення постачальнику не знайдено.');
      end;
      if o.supplier_id <> p_supplier then
        fail('PAYMENT_ORDER_SUPPLIER', 'Замовлення № ' || o.doc_number || ' оформлено на іншого постачальника.');
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

    -- договір з постачальником
    if p_contract is null and p_inserting then
      p_contract := trade_nsi.resolve_default_contract(p_supplier, 'WITH_SUPPLIER', p_date);
    end if;
    trade_nsi.check_contract(p_contract, p_supplier, 'WITH_SUPPLIER', p_date);

    -- призначення платежу за замовчуванням
    p_purpose := trim(p_purpose);
    if p_purpose is null then
      if p_contract is not null then
        select max(case when contract_number is not null then 'договором № ' || contract_number
                          || case when contract_date is not null then ' від ' || to_char(contract_date, 'DD.MM.YYYY') end
                        else 'договором «' || name || '»' end)
          into l_ctr_name from ref_contract where id = p_contract;
      end if;
      if l_base_name is null and p_order is not null then
        l_base_name := 'замовленням № ' || o.doc_number || ' від ' || to_char(o.occurred_at, 'DD.MM.YYYY');
      end if;
      p_purpose := substr('Оплата за товар'
        || case when l_base_name is not null or l_ctr_name is not null then ' згідно з ' end
        || l_base_name || case when l_base_name is not null and l_ctr_name is not null then ', ' end || l_ctr_name, 1, 500);
    end if;
  end check_supplier_header;

  -- ------------------------------------------------------------- проведення
  procedure delete_moves (p_id varchar2) is
  begin
    trade_cash.delete_movements(c_supplier, p_id);
    delete from reg_counterparty_settlement_mv where recorder_type = c_supplier and recorder_id = p_id;
  end delete_moves;

  procedure post_supplier_payment (p_id in varchar2) is
    d doc_supplier_payment%rowtype;
    l_dummy varchar2(32); l_num varchar2(9); l_line number;
  begin
    begin
      select * into d from doc_supplier_payment where id = p_id for update;
    exception when no_data_found then
      fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
    end;
    trade_core.check_active_ref('REF_COUNTERPARTY', d.supplier_id, 'Постачальник');
    if d.payment_form = 'BANK' then
      trade_core.check_active_ref('REF_BANK_ACCOUNT', d.bank_account_id, 'Банківський рахунок');
      -- правило одного платежу: цей платіж уже провела виписка неприв'язаним рядком?
      select max(s.doc_number) keep (dense_rank first order by abs(s.occurred_at - d.occurred_at)),
             max(l.line_number) keep (dense_rank first order by abs(s.occurred_at - d.occurred_at))
        into l_num, l_line
        from doc_bank_statement_line l join doc_bank_statement s on s.id = l.document_id
       where s.status = 'POSTED' and s.bank_account_id = d.bank_account_id
         and l.operation_kind = 'SUPPLIER_PAYMENT' and l.counterparty_id = d.supplier_id and l.amount = d.amount
         and l.payment_doc_id is null
         and s.occurred_at between trunc(d.occurred_at) - 3 and trunc(d.occurred_at) + 4;
      if l_num is not null then
        fail('PAYMENT_ALREADY_IN_STATEMENT', 'Цей платіж уже відображено рядком ' || l_line || ' проведеної банківської виписки № '
          || l_num || ' (рух рахунку й погашення боргу записала виписка). Щоб оформити оплату документом, скасуйте проведення '
          || 'виписки, проведіть оплату й проведіть виписку знову — рядок прив''яжеться до оплати автоматично.');
      end if;
    else
      trade_core.check_active_ref('REF_CASH_DESK', d.cash_desk_id, 'Каса');
    end if;
    select id into l_dummy from ref_counterparty where id = d.supplier_id for update;

    trade_core.g_internal := true;
    delete_moves(p_id);
    trade_cash.add_movement(c_supplier, p_id, d.occurred_at, 1,
                            case d.payment_form when 'BANK' then trade_cash.c_bank_account else trade_cash.c_cash_desk end,
                            coalesce(d.bank_account_id, d.cash_desk_id), -d.amount, 'SUPPLIER_PAYMENT',
                            'Оплата постачальнику № ' || d.doc_number || ' — ' || cp_name(d.supplier_id));
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id,
                                                direction, currency_code, amount, organization_id)
    values (d.occurred_at, c_supplier, p_id, 1, d.supplier_id, 'PAYABLE', 'UAH', -d.amount, d.organization_id);
    trade_cash.check_balances;
    trade_org.check_settlement(d.organization_id, d.supplier_id);
    update doc_supplier_payment set status = 'POSTED' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_supplier, p_id, 'POST', form_name(d.payment_form) || ', сума ' || m(d.amount) || ' ' || d.currency_code);
  exception when others then
    trade_core.g_internal := false;
    raise;
  end post_supplier_payment;

  procedure unpost_supplier_payment (p_id in varchar2) is
    d doc_supplier_payment%rowtype;
  begin
    begin
      select * into d from doc_supplier_payment where id = p_id for update;
    exception when no_data_found then
      fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
    end;
    if d.status <> 'POSTED' then
      fail('DOCUMENT_NOT_POSTED', 'Документ не проведено.');
    end if;
    check_payment_change(p_id, false);
    trade_core.g_internal := true;
    delete_moves(p_id);
    trade_cash.check_balances;
    trade_org.check_settlement(d.organization_id, d.supplier_id);
    update doc_supplier_payment set status = 'DRAFT' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_supplier, p_id, 'UNPOST');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end unpost_supplier_payment;

  function copy_supplier_payment (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_supplier_payment (id, occurred_at, organization_id, supplier_id, currency_code, amount, payment_form,
                                      bank_account_id, cash_desk_id, contract_id, supplier_order_id, base_doc_type, base_doc_id,
                                      purpose, recipient_iban, doc_comment)
    select l_new, sysdate, organization_id, supplier_id, currency_code, amount, payment_form, bank_account_id, cash_desk_id,
           contract_id, supplier_order_id, base_doc_type, base_doc_id, purpose, recipient_iban, doc_comment
      from doc_supplier_payment where id = p_id;
    trade_core.audit(c_supplier, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_supplier_payment;

  -- ------------------------------------------------------------- введення на підставі
  function paid_by_order (p_order_id in varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from doc_supplier_payment where supplier_order_id = p_order_id and status = 'POSTED';
    return l;
  end paid_by_order;

  function create_based (p_base_type varchar2, p_base_id varchar2, p_org varchar2, p_supplier varchar2, p_amount number) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
    l_form varchar2(10);
  begin
    if nvl(p_amount, 0) <= 0 then
      fail('PAYMENT_NOTHING_TO_PAY', 'Заборгованості перед постачальником за організацією документа немає '
        || '(або документ уже сплачено). Авансові оплати постачальникам ще не підтримуються.');
    end if;
    l_form := case when trade_fin.default_bank_account(p_org, 'UAH') is not null then 'BANK'
                   when trade_cash_doc.default_cash_desk(p_org, 'UAH') is not null then 'CASH' end;
    if l_form is null then
      fail('PAYMENT_SOURCE_NOT_FOUND', 'В організації документа немає активного гривневого банківського рахунку чи каси. '
        || 'Створіть їх у розділі «Фінанси».');
    end if;
    insert into doc_supplier_payment (id, occurred_at, organization_id, supplier_id, amount, payment_form, base_doc_type, base_doc_id)
    values (l_new, sysdate, p_org, p_supplier, p_amount, l_form, p_base_type, p_base_id);
    trade_core.audit(c_supplier, l_new, 'CREATE_BASED_ON', p_base_type || ' ' || p_base_id);
    return l_new;
  end create_based;

  function payment_from_goods_receipt (p_receipt_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_goods_receipt where id = p_receipt_id) loop
      if d.status <> 'POSTED' then fail('PAYMENT_BASE_NOT_POSTED', 'Прибуткову накладну не проведено.'); end if;
      return create_based('DocGoodsReceipt', d.id, d.organization_id, d.supplier_id,
               least(d.total_amount, trade_cash_doc.counterparty_debt(d.organization_id, d.supplier_id, 'PAYABLE')));
    end loop;
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_goods_receipt;

  function payment_from_supplier_order (p_order_id in varchar2) return varchar2 is
  begin
    for d in (select * from doc_supplier_order where id = p_order_id) loop
      if d.status <> 'POSTED' then fail('PAYMENT_BASE_NOT_POSTED', 'Замовлення постачальнику не проведено.'); end if;
      -- залишок до оплати за замовленням, але не більше поточного боргу (без авансів)
      return create_based('DocSupplierOrder', d.id, d.organization_id, d.supplier_id,
               least(d.total_amount - paid_by_order(d.id),
                     trade_cash_doc.counterparty_debt(d.organization_id, d.supplier_id, 'PAYABLE')));
    end loop;
    fail('PAYMENT_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
  end payment_from_supplier_order;

  -- ------------------------------------------------------------- зв'язок з банківською випискою
  procedure check_statement_link (p_stmt_id in varchar2, p_op in varchar2, p_amount in number,
                                  p_cp in out varchar2, p_contract in out varchar2,
                                  p_pay_type out varchar2, p_pay_id in varchar2) is
    v v_payment_doc%rowtype;
    l_bank varchar2(32);
  begin
    p_pay_type := null;
    if p_pay_id is null then return; end if;
    begin
      select * into v from v_payment_doc where id = p_pay_id;
    exception when no_data_found then
      fail('BANK_PAYMENT_NOT_FOUND', 'Документ оплати не знайдено.');
    end;
    if v.statement_op <> p_op then
      fail('BANK_PAYMENT_KIND', 'Документ оплати № ' || v.doc_number || ' не відповідає виду операції рядка виписки.');
    end if;
    if v.payment_form <> 'BANK' then
      fail('BANK_PAYMENT_FORM', 'Оплата № ' || v.doc_number || ' готівкова — у виписці зіставляються лише безготівкові оплати.');
    end if;
    select bank_account_id into l_bank from doc_bank_statement where id = p_stmt_id;
    if v.bank_account_id <> l_bank then
      fail('BANK_PAYMENT_ACCOUNT', 'Оплату № ' || v.doc_number || ' оформлено за іншим банківським рахунком.');
    end if;
    if v.amount <> p_amount then
      fail('BANK_PAYMENT_AMOUNT', 'Сума рядка ' || m(p_amount) || ' не збігається із сумою оплати № ' || v.doc_number
        || ' (' || m(v.amount) || ').');
    end if;
    if p_cp is null then
      p_cp := v.counterparty_id;
      p_contract := v.contract_id;
    elsif p_cp <> v.counterparty_id then
      fail('BANK_PAYMENT_COUNTERPARTY', 'Контрагент рядка не збігається з контрагентом оплати № ' || v.doc_number || '.');
    end if;
    -- договір рядка не впливає на рухи (їх пише оплата) — приводимо до договору оплати
    p_contract := v.contract_id;
    p_pay_type := v.doc_type;
  end check_statement_link;

  function link_statement (p_stmt_id in varchar2) return number is
    l_n number := 0; l_id varchar2(32);
    h doc_bank_statement%rowtype;
  begin
    select * into h from doc_bank_statement where id = p_stmt_id;
    for l in (select * from doc_bank_statement_line
               where document_id = p_stmt_id and payment_doc_id is null and counterparty_id is not null
                 and operation_kind in (select statement_op from v_payment_doc)
               order by line_number) loop
      select max(v.id) keep (dense_rank first order by case when v.doc_number = l.ext_doc_number then 0 else 1 end,
                                                       abs(v.occurred_at - h.occurred_at), v.doc_number)
        into l_id
        from v_payment_doc v
       where v.statement_op = l.operation_kind and v.status = 'POSTED' and v.payment_form = 'BANK'
         and v.bank_account_id = h.bank_account_id and v.counterparty_id = l.counterparty_id and v.amount = l.amount
         and v.occurred_at between trunc(h.occurred_at) - 3 and trunc(h.occurred_at) + 4
         and not exists (select 1 from doc_bank_statement_line x where x.payment_doc_id = v.id);
      if l_id is not null then
        update doc_bank_statement_line set payment_doc_id = l_id where id = l.id;
        l_n := l_n + 1;
      end if;
    end loop;
    return l_n;
  end link_statement;

  procedure check_statement (p_stmt_id in varchar2) is
  begin
    for l in (select l.line_number, v.doc_number, v.status
                from doc_bank_statement_line l join v_payment_doc v on v.id = l.payment_doc_id
               where l.document_id = p_stmt_id and v.status <> 'POSTED' order by l.line_number) loop
      fail('BANK_PAYMENT_NOT_POSTED', 'Рядок ' || l.line_number || ': документ оплати № ' || l.doc_number || ' не проведено.');
    end loop;
  end check_statement;

  procedure check_payment_change (p_id in varchar2, p_deleting in boolean) is
    l_num varchar2(9); l_line number;
  begin
    select max(s.doc_number) keep (dense_rank first order by s.doc_number), max(l.line_number) keep (dense_rank first order by s.doc_number)
      into l_num, l_line
      from doc_bank_statement_line l join doc_bank_statement s on s.id = l.document_id
     where l.payment_doc_id = p_id and (p_deleting or s.status = 'POSTED');
    if l_num is not null then
      fail('PAYMENT_LINKED_TO_STATEMENT', 'Оплату вказано в рядку ' || l_line || ' банківської виписки № ' || l_num
        || case when p_deleting then '. Спочатку приберіть її з виписки.' else ', яку проведено. Спочатку скасуйте проведення виписки.' end);
    end if;
  end check_payment_change;

  -- ------------------------------------------------------------- друк
  function default_form (p_id in varchar2) return varchar2 is
    l varchar2(10);
  begin
    select max(payment_form) into l from doc_supplier_payment where id = p_id;
    return case l when 'CASH' then 'PAY_KO2' when 'BANK' then 'PAYMENT_ORDER' end;
  end default_form;

  function forms_of (p_id in varchar2) return varchar2 is
  begin
    return case default_form(p_id)
      when 'PAYMENT_ORDER' then 'PAYMENT_ORDER:Платіжна інструкція (платіжне доручення)'
      when 'PAY_KO2' then 'PAY_KO2:Видатковий касовий ордер (КО-2)' end;
  end forms_of;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:980px;background:#fff;padding:16px;position:relative}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:4px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px;text-align:left;width:190px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .small{font-size:10px;color:#333}
      .tx-print .ln td{padding:4px 2px;vertical-align:bottom}.tx-print .ln .v{border-bottom:1px solid #000;width:100%}
      .tx-print .bank{border:1px solid #000;padding:6px 10px;width:260px;float:right;margin-top:14px;font-size:11px}
      .tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}}
      </style>';
  end css;

  function line (p_label varchar2, p_value varchar2) return varchar2 is
  begin
    return '<table class="ln"><tr><td style="white-space:nowrap">' || e(p_label) || '</td><td class="v">' || e(p_value) || '</td></tr></table>';
  end line;

  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    c ref_counterparty%rowtype;
    b ref_bank_account%rowtype;
    l_cashier varchar2(255);
  begin
    for d in (select * from doc_supplier_payment where id = p_id) loop
      select * into o from ref_organization where id = d.organization_id;
      select * into c from ref_counterparty where id = d.supplier_id;
      l := '<div class="tx-print">' || css || case when d.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end;
      if p_form = 'PAYMENT_ORDER' then
        if d.payment_form <> 'BANK' then
          return '<p>Платіжна інструкція формується лише для безготівкової оплати.</p>';
        end if;
        select * into b from ref_bank_account where id = d.bank_account_id;
        l := l || '<h2>ПЛАТІЖНА ІНСТРУКЦІЯ (платіжне доручення) № ' || e(d.doc_number) || '</h2>'
          || '<p style="text-align:center">Дата складання: ' || dt(d.occurred_at) || '</p>'
          || '<table class="grid">'
          || '<tr><th>Платник</th><td><b>' || e(coalesce(o.full_name, o.name)) || '</b></td></tr>'
          || '<tr><th>Код платника (ЄДРПОУ / РНОКПП)</th><td>' || e(o.edrpou) || '</td></tr>'
          || '<tr><th>Рахунок платника (IBAN)</th><td>' || e(b.iban) || '</td></tr>'
          || '<tr><th>Банк платника</th><td>' || e(b.bank_name) || case when b.mfo is not null then ', МФО ' || e(b.mfo) end || '</td></tr>'
          || '<tr><th>Отримувач</th><td><b>' || e(c.name) || '</b></td></tr>'
          || '<tr><th>Код отримувача (ЄДРПОУ / РНОКПП)</th><td>' || e(c.edrpou) || '</td></tr>'
          || '<tr><th>Рахунок отримувача (IBAN)</th><td>' || e(d.recipient_iban) || '</td></tr>'
          || '<tr><th>Сума</th><td class="r" style="text-align:left"><b>' || m(d.amount) || ' ' || e(d.currency_code) || '</b></td></tr>'
          || '<tr><th>Сума словами</th><td>' || e(trade_r3.amount_in_words_uk(d.amount)) || '</td></tr>'
          || '<tr><th>Призначення платежу</th><td>' || e(d.purpose) || '</td></tr>'
          || '</table>'
          || '<div class="bank">Проведено банком<br><br>«____» ______________ 20__ р.<br><br>Підпис банку ____________</div>'
          || '<div style="margin-top:18px;width:60%">М. П.' || line('Керівник', '____________ ' || o.director_name)
          || line('Головний бухгалтер', '____________ ' || o.accountant_name) || '</div><div style="clear:both"></div>';
      elsif p_form = 'PAY_KO2' then
        if d.payment_form <> 'CASH' then
          return '<p>Видатковий касовий ордер формується лише для готівкової оплати.</p>';
        end if;
        select responsible_name into l_cashier from ref_cash_desk where id = d.cash_desk_id;
        l := l || '<div class="small" style="text-align:right">Типова форма № КО-2<br>(наказ Мінфіну України від 22.01.1996 № 9)</div>'
          || '<div><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
          || case when o.edrpou is not null then '<br>Ідентифікаційний код ЄДРПОУ ' || e(o.edrpou) end || '</div>'
          || '<h2>Видатковий касовий ордер № ' || e(d.doc_number) || '<br><span style="font-weight:normal;font-size:13px">від '
          || dt(d.occurred_at) || '</span></h2>'
          || line('Видати', c.name) || line('Підстава', d.purpose)
          || line('Сума', m(d.amount) || ' ' || d.currency_code || ' (' || trade_r3.amount_in_words_uk(d.amount) || ')')
          || '<div style="margin-top:18px">' || line('Керівник', '____________ ' || o.director_name)
          || line('Головний бухгалтер', '____________ ' || o.accountant_name) || '</div>'
          || line('Одержав', trade_r3.amount_in_words_uk(d.amount))
          || line('Дата / підпис одержувача', dt(d.occurred_at) || '   ____________')
          || line('За', '____________________________ (найменування, номер, дата та місце видачі документа, що посвідчує особу)')
          || line('Видав касир', '____________ ' || l_cashier);
      else
        return '<p>Невідома друкована форма: ' || e(p_form) || '</p>';
      end if;
      l := l || '</div>';
    end loop;
    return l;
  end print_html;

end trade_pay_doc;
/

-- ---------------------------------------------------------------- тригери документа
-- Організація: з документа-підстави, інакше за замовчуванням (замість тригера db/24)
create or replace trigger doc_supplier_payment_org_biu
before insert or update of organization_id, base_doc_id on doc_supplier_payment for each row
begin
  trade_org.resolve_doc_org(:new.organization_id, :old.organization_id, :new.base_doc_type, :new.base_doc_id, inserting);
end;
/

create or replace trigger doc_supplier_payment_biud
before insert or update or delete on doc_supplier_payment for each row
follows doc_supplier_payment_org_biu
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_pay_doc.check_payment_change(:old.id, true);
    return;
  end if;
  if inserting then
    :new.doc_number    := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_SUPPLIER_PAYMENT_NUM_SEQ'));
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
  trade_pay_doc.check_supplier_header(inserting, :new.occurred_at, :new.organization_id, :new.supplier_id, :old.supplier_id,
    :new.amount, :new.payment_form, :new.bank_account_id, :old.bank_account_id, :new.cash_desk_id, :old.cash_desk_id,
    :new.contract_id, :new.supplier_order_id, :new.base_doc_type, :new.base_doc_id, :new.purpose, :new.recipient_iban);
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

-- Список оплат (сторінка 60)
create or replace view v_supplier_payment_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name, d.supplier_id, s.name supplier_name,
       d.payment_form, case d.payment_form when 'BANK' then 'Безготівкова' else 'Готівкова' end payment_form_name,
       coalesce(b.name, k.name) source_name, d.amount, d.currency_code,
       c.name || case when c.contract_number is not null then ' № ' || c.contract_number end contract_name,
       so.doc_number supplier_order_number, d.purpose,
       (select max(st.doc_number) from doc_bank_statement_line l join doc_bank_statement st on st.id = l.document_id
         where l.payment_doc_id = d.id) statement_number,
       d.status, d.doc_comment
  from doc_supplier_payment d
  join ref_organization o on o.id = d.organization_id
  join ref_counterparty s on s.id = d.supplier_id
  left join ref_bank_account b on b.id = d.bank_account_id
  left join ref_cash_desk k on k.id = d.cash_desk_id
  left join ref_contract c on c.id = d.contract_id
  left join doc_supplier_order so on so.id = d.supplier_order_id;

-- ---------------------------------------------------------------- меню: «Фінанси» + права касира
begin
  update sys_metadata_object set auth_scheme = 'Роль: закупівлі або каса' where tech_name = 'DocSupplierPayment';
  insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
  select s.id, 'Банк', 1, 7, o.id, 20, 'Y'
    from sys_main_menu_section s, sys_metadata_object o
   where s.tech_name = 'Finance' and o.tech_name = 'DocSupplierPayment'
     and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  commit;
end;
/

-- ---------------------------------------------------------------- міграція оплат r1–r3
-- Проведені раніше оплати не рухали кошти: заповнюємо джерело (основний рахунок організації,
-- інакше каса) і перепроводимо, щоб рух коштів з'явився. Невдалі — лишаються як є (вивід).
set serveroutput on
declare
  l_bank varchar2(32); l_desk varchar2(32);
begin
  for d in (select p.* from doc_supplier_payment p
             where (p.payment_form = 'BANK' and p.bank_account_id is null) or (p.payment_form = 'CASH' and p.cash_desk_id is null)
             order by p.occurred_at) loop
    begin
      savepoint mig;
      l_bank := trade_fin.default_bank_account(d.organization_id, 'UAH');
      l_desk := trade_cash_doc.default_cash_desk(d.organization_id, 'UAH');
      trade_core.g_internal := true;
      update doc_supplier_payment
         set payment_form = case when l_bank is not null then 'BANK' when l_desk is not null then 'CASH' else payment_form end
       where id = d.id;
      trade_core.g_internal := false;
      if d.status = 'POSTED' then
        trade_pay_doc.post_supplier_payment(d.id);
      end if;
    exception when others then
      trade_core.g_internal := false;
      rollback to mig;
      dbms_output.put_line('Оплату № ' || d.doc_number || ' не перенесено: ' || sqlerrm);
    end;
  end loop;
  commit;
end;
/

-- Перекомпіляція залежних об'єктів (trade_doc делегує в trade_pay_doc, trade_bank_doc — v_payment_doc)
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
