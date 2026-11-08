-- =============================================================================
-- Trade r4 — F-NSI-09 «Організації» (кілька юросіб / ФОП). Паспорт RefOrganization (PROPOSED).
--   * довідник ref_organization, організація за замовчуванням;
--   * реквізит organization_id у шапках документів (крім «Встановлення цін»);
--   * вимір organization_id у RegCounterpartySettlement, RegSales, RegStockCost —
--     заповнюється тригером з документа-реєстратора (процедури проведення не змінюються);
--   * контроль від'ємних взаєморозрахунків у розрізі організації;
--   * копія документа зберігає організацію, документ на підставі — організацію підстави.
-- Скрипт повторно виконуваний. Представлення, меню, демо — у 25_r4_org_views_demo.sql.
-- =============================================================================

-- ---------------------------------------------------------------- RefOrganization
declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl('create sequence ref_organization_code_seq nocache');
  ddl(q'[create table ref_organization (
    id varchar2(32) default on null rawtohex(sys_guid()) not null,
    code varchar2(9) not null,
    name varchar2(255) not null,
    full_name varchar2(500),
    org_kind varchar2(10) default on null 'LEGAL' not null,
    edrpou varchar2(10),
    vat_payer varchar2(1) default on null 'N' not null,
    vat_number varchar2(12),
    iban varchar2(40),
    bank_name varchar2(255),
    address varchar2(500),
    phone varchar2(50),
    director_name varchar2(255),
    accountant_name varchar2(255),
    is_default varchar2(1) default on null 'N' not null,
    state varchar2(20) default on null 'ACTIVE' not null,
    version number(19) default on null 0 not null,
    created_at timestamp not null, created_by varchar2(255) not null,
    updated_at timestamp not null, updated_by varchar2(255) not null,
    constraint ref_organization_pk primary key (id),
    constraint ref_organization_code_uk unique (code),
    constraint ref_organization_kind_ck check (org_kind in ('LEGAL','INDIVIDUAL')),
    constraint ref_organization_vat_ck check (vat_payer in ('Y','N')),
    constraint ref_organization_def_ck check (is_default in ('Y','N')),
    constraint ref_organization_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_organization_state_ix on ref_organization (state)');
  ddl('alter table ref_organization modify (iban varchar2(40))');   -- введення з пробілами; зберігається без них
end;
/

-- Перша (основна) організація — з реквізитів sys_company_settings (до створення тригерів довідника)
declare
  n number; l_code varchar2(9);
begin
  select count(*) into n from ref_organization;
  if n = 0 then
    for t in (select trigger_name from user_triggers where trigger_name in ('REF_ORGANIZATION_BIU', 'REF_ORGANIZATION_AS')) loop
      execute immediate 'drop trigger ' || t.trigger_name;   -- створюються нижче
    end loop;
    l_code := lpad(to_char(ref_organization_code_seq.nextval), 9, '0');
    insert into ref_organization (code, name, full_name, org_kind, edrpou, iban, bank_name, address, phone, director_name, accountant_name,
                                  is_default, created_at, created_by, updated_at, updated_by)
    select l_code, coalesce(max(name), 'Моє підприємство'), max(name), 'LEGAL', max(edrpou),
           max(replace(iban, ' ')), max(bank_name), max(address), max(phone), max(director_name), max(accountant_name), 'Y',
           systimestamp, user, systimestamp, user
      from sys_company_settings;
  end if;
  commit;
end;
/

-- ---------------------------------------------------------------- organization_id у документах і регістрах
declare
  l_def varchar2(32);
  type t_list is table of varchar2(30);
  l_tabs t_list := t_list('DOC_GOODS_RECEIPT', 'DOC_SUPPLIER_PAYMENT', 'DOC_GOODS_SALE', 'DOC_CUSTOMER_PAYMENT',
                          'DOC_GOODS_TRANSFER', 'DOC_GOODS_WRITE_OFF', 'DOC_CUSTOMER_ORDER', 'DOC_SUPPLIER_ORDER',
                          'DOC_CUSTOMER_RETURN', 'DOC_SUPPLIER_RETURN', 'DOC_INVENTORY_COUNT', 'DOC_SURPLUS_POSTING',
                          'DOC_INVOICE_FOR_PAYMENT',
                          'REG_COUNTERPARTY_SETTLEMENT_MV', 'REG_SALES_TURNOVER', 'REG_STOCK_COST_MV');
  n number;
  function short (p varchar2) return varchar2 is
  begin
    return replace(replace(replace(replace(lower(p), 'counterparty_settlement', 'cp_stl'), 'invoice_for_payment', 'invoice'), 'reg_sales_turnover', 'reg_sales'), '_mv', '');
  end;
begin
  select max(id) keep (dense_rank first order by case when is_default = 'Y' then 0 else 1 end, code) into l_def
    from ref_organization where state = 'ACTIVE';
  for i in 1 .. l_tabs.count loop
    select count(*) into n from user_tab_columns where table_name = l_tabs(i) and column_name = 'ORGANIZATION_ID';
    if n = 0 then
      -- існуючі рядки отримують основну організацію без DML (тригери не спрацьовують)
      execute immediate 'alter table ' || l_tabs(i) || ' add (organization_id varchar2(32) default ''' || l_def || ''' not null)';
      execute immediate 'alter table ' || l_tabs(i) || ' modify (organization_id default null)';
      execute immediate 'alter table ' || l_tabs(i) || ' add constraint ' || short(l_tabs(i)) || '_org_fk foreign key (organization_id) references ref_organization (id)';
      execute immediate 'create index ' || short(l_tabs(i)) || '_org_ix on ' || l_tabs(i) || ' (organization_id)';
    end if;
  end loop;
end;
/

create or replace package trade_org as
  -- Організація за замовчуванням (ознака is_default, інакше перша активна за кодом)
  function default_org return varchar2;
  -- Таблиця шапки документа за типом реєстратора (null — тип без організації)
  function doc_table (p_type in varchar2) return varchar2;
  -- Організація документа
  function doc_org (p_type in varchar2, p_id in varchar2) return varchar2;
  -- Організація для руху регістру (з реєстратора; невідомий тип — за замовчуванням)
  function recorder_org (p_type in varchar2, p_id in varchar2) return varchar2;
  -- Визначення організації шапки документа в тригері
  procedure resolve_doc_org (p_org in out varchar2, p_old_org in varchar2, p_base_type in varchar2,
                             p_base_id in varchar2, p_inserting in boolean);
  -- Заборгованість контрагента в розрізі організації не може бути від'ємною
  procedure check_settlement (p_org in varchar2, p_counterparty_id in varchar2);
  -- «Скопіювати»: перенести організацію з документа-джерела
  procedure copy_org (p_type in varchar2, p_new_id in varchar2, p_src_id in varchar2);
  -- Перевірка реквізитів (тригер довідника)
  procedure check_requisites (p_kind in varchar2, p_edrpou in out varchar2, p_vat_payer in varchar2,
                              p_vat_number in out varchar2, p_iban in out varchar2);
  -- Підтримка єдиної організації за замовчуванням
  g_new_default varchar2(32);
  g_in_default  boolean := false;
end trade_org;
/

create or replace package body trade_org as

  function digits_only (p varchar2) return boolean is
  begin
    return p is not null and translate(p, 'x0123456789', 'x') is null;
  end digits_only;

  function default_org return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by case when is_default = 'Y' then 0 else 1 end, code)
      into l from ref_organization where state = 'ACTIVE';
    return l;
  end default_org;

  function doc_table (p_type in varchar2) return varchar2 is
  begin
    return case p_type
      when 'DocGoodsReceipt'      then 'DOC_GOODS_RECEIPT'
      when 'DocSupplierPayment'   then 'DOC_SUPPLIER_PAYMENT'
      when 'DocGoodsSale'         then 'DOC_GOODS_SALE'
      when 'DocCustomerPayment'   then 'DOC_CUSTOMER_PAYMENT'
      when 'DocGoodsTransfer'     then 'DOC_GOODS_TRANSFER'
      when 'DocGoodsWriteOff'     then 'DOC_GOODS_WRITE_OFF'
      when 'DocCustomerOrder'     then 'DOC_CUSTOMER_ORDER'
      when 'DocSupplierOrder'     then 'DOC_SUPPLIER_ORDER'
      when 'DocCustomerReturn'    then 'DOC_CUSTOMER_RETURN'
      when 'DocSupplierReturn'    then 'DOC_SUPPLIER_RETURN'
      when 'DocInventoryCount'    then 'DOC_INVENTORY_COUNT'
      when 'DocSurplusPosting'    then 'DOC_SURPLUS_POSTING'
      when 'DocInvoiceForPayment' then 'DOC_INVOICE_FOR_PAYMENT'
      when 'DocCashReceipt'       then 'DOC_CASH_RECEIPT'      -- r4 F-FIN-03 (db/28)
      when 'DocCashPayment'       then 'DOC_CASH_PAYMENT'
      when 'DocAssembly'          then 'DOC_ASSEMBLY'          -- r4 F-WH-10 (db/33)
      when 'DocGoodsReceiptOrder' then 'DOC_GOODS_RECEIPT_ORDER'  -- r5 F-WH-11 (db/40)
      when 'DocGoodsIssueOrder'   then 'DOC_GOODS_ISSUE_ORDER'
      when 'DocTaxInvoice'        then 'DOC_TAX_INVOICE'          -- r5 F-TAX-01 (db/42)
      when 'DocRetailReceipt'     then 'DOC_RETAIL_RECEIPT'       -- r5 F-RET-01 (db/43)
      end;
  end doc_table;

  function doc_org (p_type in varchar2, p_id in varchar2) return varchar2 is
    l_tab varchar2(30) := doc_table(p_type);
    l varchar2(32);
  begin
    if l_tab is null or p_id is null then return null; end if;
    execute immediate 'select max(organization_id) from ' || l_tab || ' where id = :i' into l using p_id;
    return l;
  end doc_org;

  function recorder_org (p_type in varchar2, p_id in varchar2) return varchar2 is
  begin
    return coalesce(doc_org(p_type, p_id), default_org);
  end recorder_org;

  procedure resolve_doc_org (p_org in out varchar2, p_old_org in varchar2, p_base_type in varchar2,
                             p_base_id in varchar2, p_inserting in boolean) is
    l varchar2(32);
  begin
    if p_base_id is not null then
      l := doc_org(p_base_type, p_base_id);   -- документ на підставі має організацію підстави
      if l is not null then p_org := l; end if;
    end if;
    if p_org is null then p_org := default_org; end if;
    if p_inserting or p_org <> nvl(p_old_org, '-') then
      trade_core.check_active_ref('REF_ORGANIZATION', p_org, 'Організація');
    end if;
  end resolve_doc_org;

  procedure check_settlement (p_org in varchar2, p_counterparty_id in varchar2) is
    l_org varchar2(255);
  begin
    for r in (select direction, sum(amount) balance
                from reg_counterparty_settlement_mv
               where organization_id = p_org and counterparty_id = p_counterparty_id and currency_code = 'UAH'
               group by direction having sum(amount) < 0) loop
      select name into l_org from ref_organization where id = p_org;
      trade_nsi.fail('SETTLEMENT_NEGATIVE_BY_ORGANIZATION',
        case r.direction when 'RECEIVABLE' then 'Операція призведе до переплати покупця'
                         else 'Операція призведе до переплати постачальнику' end
        || ' за організацією «' || l_org || '». Заборгованість після операції: '
        || to_char(r.balance, 'FM999G999G999G990D00') || ' UAH.');
    end loop;
  end check_settlement;

  procedure copy_org (p_type in varchar2, p_new_id in varchar2, p_src_id in varchar2) is
    l_tab varchar2(30) := doc_table(p_type);
    l_org varchar2(32);
  begin
    if l_tab is null then return; end if;
    l_org := doc_org(p_type, p_src_id);
    if l_org is not null then
      execute immediate 'update ' || l_tab || ' set organization_id = :o where id = :i and organization_id <> :o2'
        using l_org, p_new_id, l_org;
    end if;
  end copy_org;

  procedure check_requisites (p_kind in varchar2, p_edrpou in out varchar2, p_vat_payer in varchar2,
                              p_vat_number in out varchar2, p_iban in out varchar2) is
  begin
    p_edrpou := trim(p_edrpou);
    p_vat_number := trim(p_vat_number);
    p_iban := upper(replace(p_iban, ' '));
    if p_edrpou is not null then
      if p_kind = 'LEGAL' and not (digits_only(p_edrpou) and length(p_edrpou) = 8) then
        trade_nsi.fail('ORGANIZATION_EDRPOU', 'Код ЄДРПОУ юридичної особи — 8 цифр.');
      elsif p_kind = 'INDIVIDUAL' and not (digits_only(p_edrpou) and length(p_edrpou) = 10) then
        trade_nsi.fail('ORGANIZATION_IPN', 'РНОКПП (ІПН) фізичної особи-підприємця — 10 цифр.');
      end if;
    end if;
    if p_vat_payer = 'Y' and not (digits_only(p_vat_number) and length(p_vat_number) = 12) then
      trade_nsi.fail('ORGANIZATION_VAT_NUMBER', 'Для платника ПДВ вкажіть індивідуальний податковий номер — 12 цифр.');
    end if;
    if p_vat_payer = 'N' then
      p_vat_number := null;
    end if;
    if p_iban is not null and not (substr(p_iban, 1, 2) = 'UA' and length(p_iban) = 29 and digits_only(substr(p_iban, 3))) then
      trade_nsi.fail('ORGANIZATION_IBAN', 'IBAN має формат UA + 27 цифр.');
    end if;
  end check_requisites;

end trade_org;
/

create or replace trigger ref_organization_biu
before insert or update on ref_organization for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_ORGANIZATION_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.full_name := trim(:new.full_name);
  trade_org.check_requisites(:new.org_kind, :new.edrpou, :new.vat_payer, :new.vat_number, :new.iban);
  if :new.state <> 'ACTIVE' and :new.is_default = 'Y' then
    trade_nsi.fail('ORGANIZATION_DEFAULT_MARKED', 'Організацію за замовчуванням не можна помітити на видалення. Спочатку призначте іншу.');
  end if;
  if :new.is_default = 'Y' and not trade_org.g_in_default then
    trade_org.g_new_default := :new.id;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
-- Одна організація за замовчуванням: нова ознака знімає попередню
create or replace trigger ref_organization_as
after insert or update on ref_organization
declare
  l varchar2(32) := trade_org.g_new_default;
begin
  if l is not null and not trade_org.g_in_default then
    trade_org.g_new_default := null;
    trade_org.g_in_default := true;
    update ref_organization set is_default = 'N' where is_default = 'Y' and id <> l;
    trade_org.g_in_default := false;
  end if;
exception when others then
  trade_org.g_in_default := false;
  raise;
end;
/
create or replace trigger ref_organization_bd before delete on ref_organization
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- тригери документів
declare
  type t_doc is record (tab varchar2(30), base_col varchar2(30), base_type varchar2(30), cp_col varchar2(30));
  type t_docs is table of t_doc;
  l t_docs := t_docs(
    t_doc('DOC_GOODS_RECEIPT',       'BASE_ORDER_ID',     'DocSupplierOrder',  'SUPPLIER_ID'),
    t_doc('DOC_SUPPLIER_PAYMENT',    null,                null,                'SUPPLIER_ID'),
    t_doc('DOC_GOODS_SALE',          'BASE_ORDER_ID',     'DocCustomerOrder',  'CUSTOMER_ID'),
    t_doc('DOC_CUSTOMER_PAYMENT',    null,                null,                'CUSTOMER_ID'),
    t_doc('DOC_GOODS_TRANSFER',      null,                null,                null),
    t_doc('DOC_GOODS_WRITE_OFF',     'BASE_INVENTORY_ID', 'DocInventoryCount', null),
    t_doc('DOC_CUSTOMER_ORDER',      null,                null,                null),
    t_doc('DOC_SUPPLIER_ORDER',      null,                null,                null),
    t_doc('DOC_CUSTOMER_RETURN',     'BASE_SALE_ID',      'DocGoodsSale',      'CUSTOMER_ID'),
    t_doc('DOC_SUPPLIER_RETURN',     'BASE_RECEIPT_ID',   'DocGoodsReceipt',   'SUPPLIER_ID'),
    t_doc('DOC_INVENTORY_COUNT',     null,                null,                null),
    t_doc('DOC_SURPLUS_POSTING',     'BASE_INVENTORY_ID', 'DocInventoryCount', null),
    t_doc('DOC_INVOICE_FOR_PAYMENT', 'BASE_ORDER_ID',     'DocCustomerOrder',  null));
  t varchar2(30);
begin
  for i in 1 .. l.count loop
    t := lower(l(i).tab);
    execute immediate 'create or replace trigger ' || replace(t, 'invoice_for_payment', 'invoice') || '_org_biu'
      || ' before insert or update of organization_id' || case when l(i).base_col is not null then ', ' || lower(l(i).base_col) end
      || ' on ' || t || ' for each row'
      || ' begin trade_org.resolve_doc_org(:new.organization_id, :old.organization_id, '
      || case when l(i).base_col is null then 'null, null' else '''' || l(i).base_type || ''', :new.' || lower(l(i).base_col) end
      || ', inserting); end;';
    if l(i).cp_col is not null then
      execute immediate 'create or replace trigger ' || t || '_org_stl'
        || ' after update of status on ' || t || ' for each row when (new.status <> old.status)'
        || ' begin trade_org.check_settlement(:new.organization_id, :new.' || lower(l(i).cp_col) || '); end;';
    end if;
  end loop;
end;
/

-- ---------------------------------------------------------------- тригери регістрів: організація з реєстратора
create or replace trigger reg_cp_settlement_mv_org
before insert on reg_counterparty_settlement_mv for each row
begin
  if :new.organization_id is null then :new.organization_id := trade_org.recorder_org(:new.recorder_type, :new.recorder_id); end if;
end;
/
create or replace trigger reg_sales_turnover_org
before insert on reg_sales_turnover for each row
begin
  if :new.organization_id is null then :new.organization_id := trade_org.recorder_org(:new.recorder_type, :new.recorder_id); end if;
end;
/
create or replace trigger reg_stock_cost_mv_org
before insert on reg_stock_cost_mv for each row
begin
  if :new.organization_id is null then :new.organization_id := trade_org.recorder_org(:new.recorder_type, :new.recorder_id); end if;
end;
/

-- «Скопіювати (F9)» фіксується в журналі як COPY 'Копія <id джерела>' — переносимо організацію джерела
create or replace trigger sys_audit_log_copy_org
after insert on sys_audit_log for each row
when (new.action = 'COPY')
begin
  if :new.details like 'Копія %' then
    trade_org.copy_org(:new.object_type, :new.object_id, substr(:new.details, 7));
  end if;
end;
/
