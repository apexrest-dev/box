-- =============================================================================
-- Trade r4 — F-FIN-01 «Каси й банківські рахунки». Паспорти RefCashDesk, RefBankAccount (PROPOSED).
--   * довідники ref_cash_desk (каса організації, валюта, відповідальний) і
--     ref_bank_account (IBAN з контрольною сумою mod 97, МФО з IBAN, банк, валюта, організація-власник,
--     основний рахунок організації);
--   * пакет trade_fin (нормалізація й перевірка IBAN UA, валюти);
--   * розділ основного меню «Фінанси», панель функцій, права (роль «Касир»).
-- Потребує 24_r4_organizations.sql. trade_core.catalog_table знає нові таблиці (02_trade_core.sql).
-- Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl('create sequence ref_cash_desk_code_seq nocache');
  ddl(q'[create table ref_cash_desk (
    id varchar2(32) default on null rawtohex(sys_guid()) not null,
    code varchar2(9) not null,
    name varchar2(255) not null,
    organization_id varchar2(32) not null,
    currency_code varchar2(3) default on null 'UAH' not null,
    responsible_name varchar2(255),
    note varchar2(1000),
    state varchar2(20) default on null 'ACTIVE' not null,
    version number(19) default on null 0 not null,
    created_at timestamp not null, created_by varchar2(255) not null,
    updated_at timestamp not null, updated_by varchar2(255) not null,
    constraint ref_cash_desk_pk primary key (id),
    constraint ref_cash_desk_code_uk unique (code),
    constraint ref_cash_desk_org_fk foreign key (organization_id) references ref_organization (id),
    constraint ref_cash_desk_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_cash_desk_org_ix on ref_cash_desk (organization_id)');

  ddl('create sequence ref_bank_account_code_seq nocache');
  ddl(q'[create table ref_bank_account (
    id varchar2(32) default on null rawtohex(sys_guid()) not null,
    code varchar2(9) not null,
    name varchar2(255) not null,
    organization_id varchar2(32) not null,
    iban varchar2(40) not null,
    mfo varchar2(6) not null,
    bank_name varchar2(255) not null,
    currency_code varchar2(3) default on null 'UAH' not null,
    is_default varchar2(1) default on null 'N' not null,
    note varchar2(1000),
    state varchar2(20) default on null 'ACTIVE' not null,
    version number(19) default on null 0 not null,
    created_at timestamp not null, created_by varchar2(255) not null,
    updated_at timestamp not null, updated_by varchar2(255) not null,
    constraint ref_bank_account_pk primary key (id),
    constraint ref_bank_account_code_uk unique (code),
    constraint ref_bank_account_iban_uk unique (iban),
    constraint ref_bank_account_org_fk foreign key (organization_id) references ref_organization (id),
    constraint ref_bank_account_def_ck check (is_default in ('Y','N')),
    constraint ref_bank_account_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_bank_account_org_ix on ref_bank_account (organization_id)');
end;
/

create or replace package trade_fin as
  -- IBAN без пробілів у верхньому регістрі
  function normalize_iban (p_iban in varchar2) return varchar2;
  -- Контрольна сума IBAN за ISO 13616 (mod 97 = 1)
  function iban_checksum_ok (p_iban in varchar2) return boolean;
  -- 'Y' — коректний український IBAN (формат UA + 27 цифр і контрольна сума)
  function is_valid_ua_iban (p_iban in varchar2) return varchar2;
  -- МФО банку з українського IBAN (позиції 5–10)
  function mfo_from_iban (p_iban in varchar2) return varchar2;
  -- Перевірка IBAN: нормалізує, кидає BANK_ACCOUNT_IBAN_FORMAT / BANK_ACCOUNT_IBAN_CHECKSUM
  procedure check_iban (p_iban in out varchar2);
  -- Код валюти ISO 4217 (3 латинські літери)
  procedure check_currency (p_currency in out varchar2);
  -- Основний рахунок організації (активний, з ознакою is_default; інакше перший за кодом)
  function default_bank_account (p_organization_id in varchar2, p_currency in varchar2 default 'UAH') return varchar2;
end trade_fin;
/

create or replace package body trade_fin as
  c_letters constant varchar2(26) := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  function digits_only (p varchar2) return boolean is
  begin
    return p is not null and translate(p, 'x0123456789', 'x') is null;
  end digits_only;

  function normalize_iban (p_iban in varchar2) return varchar2 is
  begin
    return upper(replace(replace(trim(p_iban), ' '), '-'));
  end normalize_iban;

  function iban_checksum_ok (p_iban in varchar2) return boolean is
    l_s varchar2(80) := normalize_iban(p_iban);
    l_r pls_integer := 0;
    l_c varchar2(1 char);
    l_v pls_integer;
  begin
    if l_s is null or length(l_s) < 5 then return false; end if;
    l_s := substr(l_s, 5) || substr(l_s, 1, 4);
    for i in 1 .. length(l_s) loop
      l_c := substr(l_s, i, 1);
      if instr('0123456789', l_c) > 0 then
        l_r := mod(l_r * 10 + to_number(l_c), 97);
      else
        l_v := instr(c_letters, l_c);   -- без regexp: діапазони залежать від NLS_SORT
        if l_v = 0 then return false; end if;
        l_r := mod(l_r * 100 + l_v + 9, 97);   -- A = 10 … Z = 35
      end if;
    end loop;
    return l_r = 1;
  end iban_checksum_ok;

  function ua_format_ok (p varchar2) return boolean is
  begin
    return substr(p, 1, 2) = 'UA' and length(p) = 29 and digits_only(substr(p, 3));
  end ua_format_ok;

  function is_valid_ua_iban (p_iban in varchar2) return varchar2 is
    l varchar2(80) := normalize_iban(p_iban);
  begin
    return case when ua_format_ok(l) and iban_checksum_ok(l) then 'Y' else 'N' end;
  end is_valid_ua_iban;

  function mfo_from_iban (p_iban in varchar2) return varchar2 is
  begin
    return substr(normalize_iban(p_iban), 5, 6);
  end mfo_from_iban;

  procedure check_iban (p_iban in out varchar2) is
  begin
    p_iban := normalize_iban(p_iban);
    if p_iban is null then
      trade_nsi.fail('BANK_ACCOUNT_IBAN_REQUIRED', 'Поле «IBAN» обов''язкове для заповнення.');
    elsif not ua_format_ok(p_iban) then
      trade_nsi.fail('BANK_ACCOUNT_IBAN_FORMAT', 'IBAN має формат UA + 27 цифр (29 символів без пробілів).');
    elsif not iban_checksum_ok(p_iban) then
      trade_nsi.fail('BANK_ACCOUNT_IBAN_CHECKSUM', 'Неправильна контрольна сума IBAN ' || p_iban || '. Перевірте номер рахунку.');
    end if;
  end check_iban;

  procedure check_currency (p_currency in out varchar2) is
  begin
    p_currency := upper(trim(coalesce(p_currency, 'UAH')));
    if length(p_currency) <> 3 or translate(p_currency, 'x' || c_letters, 'x') is not null then
      trade_nsi.fail('CURRENCY_CODE', 'Код валюти — 3 латинські літери ISO 4217 (UAH, USD, EUR).');
    end if;
    -- r5 F-FIN-06 (db/41): валюта має бути в довіднику «Валюти» (активна); до db/41 — лише формат
    begin
      execute immediate 'begin trade_currency.check_active(:c); end;' using p_currency;
    exception when others then
      if sqlcode in (-6550, -4067) then null; else raise; end if;
    end;
  end check_currency;

  function default_bank_account (p_organization_id in varchar2, p_currency in varchar2 default 'UAH') return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by case when is_default = 'Y' then 0 else 1 end, code)
      into l from ref_bank_account
     where organization_id = p_organization_id and currency_code = coalesce(p_currency, 'UAH') and state = 'ACTIVE';
    return l;
  end default_bank_account;
end trade_fin;
/

-- ---------------------------------------------------------------- RefCashDesk
create or replace trigger ref_cash_desk_biu
before insert or update on ref_cash_desk for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_CASH_DESK_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    :new.organization_id := coalesce(:new.organization_id, trade_org.default_org);
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.responsible_name := trim(:new.responsible_name);
  trade_fin.check_currency(:new.currency_code);
  if inserting or :new.organization_id <> :old.organization_id then
    trade_core.check_active_ref('REF_ORGANIZATION', :new.organization_id, 'Організація');
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_cash_desk_bd before delete on ref_cash_desk
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- RefBankAccount
-- Компаунд-тригер: перевірки рядка + «один основний рахунок організації у валюті»
create or replace trigger ref_bank_account_cbiu
for insert or update on ref_bank_account
compound trigger
  type t_ids is table of varchar2(32);
  g_ids t_ids := t_ids();

  before each row is
  begin
    if inserting then
      :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_BANK_ACCOUNT_CODE_SEQ'));
      :new.version := 0;
      :new.state := coalesce(:new.state, 'ACTIVE');
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
      :new.organization_id := coalesce(:new.organization_id, trade_org.default_org);
    else
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.code);
    trade_fin.check_iban(:new.iban);
    if trim(:new.mfo) is not null and trim(:new.mfo) <> trade_fin.mfo_from_iban(:new.iban) then
      trade_nsi.fail('BANK_ACCOUNT_MFO', 'МФО ' || trim(:new.mfo) || ' не відповідає IBAN (у IBAN — МФО '
        || trade_fin.mfo_from_iban(:new.iban) || '). МФО можна не заповнювати — воно береться з IBAN.');
    end if;
    :new.mfo := trade_fin.mfo_from_iban(:new.iban);
    :new.bank_name := trade_core.normalize_name(:new.bank_name, 255, 'Банк');
    trade_fin.check_currency(:new.currency_code);
    -- Порожнє найменування: «<банк>, <валюта> …<4 останні цифри>», як у 1С
    if trim(:new.name) is null then
      :new.name := substr(:new.bank_name, 1, 230) || ', ' || :new.currency_code || ' …' || substr(:new.iban, -4);
    end if;
    :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
    if inserting or :new.organization_id <> :old.organization_id then
      trade_core.check_active_ref('REF_ORGANIZATION', :new.organization_id, 'Організація');
    end if;
    if :new.state <> 'ACTIVE' then
      :new.is_default := 'N';   -- помічений рахунок не може бути основним
    end if;
    if :new.is_default = 'Y' and (inserting or :old.is_default = 'N'
                                  or :new.organization_id <> :old.organization_id or :new.currency_code <> :old.currency_code) then
      g_ids.extend; g_ids(g_ids.count) := :new.id;
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end before each row;

  after statement is
  begin
    for i in 1 .. g_ids.count loop
      update ref_bank_account b set is_default = 'N'
       where b.is_default = 'Y' and b.id <> g_ids(i)
         and (b.organization_id, b.currency_code) in (select organization_id, currency_code from ref_bank_account where id = g_ids(i));
    end loop;
    g_ids.delete;
  end after statement;
end ref_bank_account_cbiu;
/
create or replace trigger ref_bank_account_bd before delete on ref_bank_account
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- представлення для списків
create or replace view v_cash_desk as
select k.id, k.code, k.name, k.organization_id, o.name organization_name, k.currency_code,
       k.responsible_name, k.note, k.state
  from ref_cash_desk k join ref_organization o on o.id = k.organization_id;

create or replace view v_bank_account as
select b.id, b.code, b.name, b.organization_id, o.name organization_name, b.iban,
       substr(b.iban, 1, 4) || ' ' || substr(b.iban, 5, 6) || ' ' || substr(b.iban, 11, 5) || ' ' || substr(b.iban, 16) iban_display,
       b.mfo, b.bank_name, b.currency_code, b.is_default, b.note, b.state
  from ref_bank_account b join ref_organization o on o.id = b.organization_id;

-- ---------------------------------------------------------------- меню: розділ «Фінанси»
declare
  n number;
  procedure obj (p_tech varchar2, p_name varchar2, p_list number, p_form number, p_sort number) is
  begin
    merge into sys_metadata_object o
    using (select p_tech tech_name from dual) s on (o.tech_name = s.tech_name)
    when matched then update set o.name = p_name, o.list_page_id = p_list, o.form_page_id = p_form, o.auth_scheme = 'Роль: каса'
    when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
      values (p_tech, 'CATALOG', p_name, (select id from sys_main_menu_section where tech_name = 'Catalogs'), p_list, p_form, p_sort, 'Роль: каса');
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
  select count(*) into n from sys_main_menu_section where tech_name = 'Finance';
  if n = 0 then
    insert into sys_main_menu_section (tech_name, name, sort_order, icon, is_subsystem, is_visible)
    values ('Finance', 'Фінанси', 145, 'fa-money', 'Y', 'Y');
  end if;
  obj('RefCashDesk',    'Каси',                 340, 341, 80);
  obj('RefBankAccount', 'Банківські рахунки',   350, 351, 90);
  fp('Finance',   'Казначейство', 1, 10, 'RefCashDesk',     10, 'Y');
  fp('Finance',   'Казначейство', 1, 10, 'RefBankAccount',  20, 'Y');
  update sys_function_panel set column_no = 1
   where section_id = (select id from sys_main_menu_section where tech_name = 'Finance') and column_no <> 1;
  -- «Організації» лишаються в «НСІ та адміністрування»: розділ «Фінанси» видно лише ролям з доступом до кас/рахунків
  delete from sys_function_panel
   where section_id = (select id from sys_main_menu_section where tech_name = 'Finance')
     and object_id = (select id from sys_metadata_object where tech_name = 'RefOrganization');
  fp('Reference', 'Підприємство', 1,  5, 'RefCashDesk',     20);
  fp('Reference', 'Підприємство', 1,  5, 'RefBankAccount',  30);
  commit;
end;
/

-- ---------------------------------------------------------------- демо: каси й рахунки двох організацій
declare
  l_org1 varchar2(32); l_org2 varchar2(32); n number;
begin
  select count(*) into n from ref_cash_desk;
  if n > 0 then return; end if;
  l_org1 := trade_org.default_org;
  select max(id) into l_org2 from ref_organization where edrpou = '3012345678';
  insert into ref_cash_desk (name, organization_id, responsible_name) values ('Основна каса', l_org1, 'Петренко І. В.');
  insert into ref_cash_desk (name, organization_id, currency_code, responsible_name) values ('Валютна каса (USD)', l_org1, 'USD', 'Петренко І. В.');
  insert into ref_bank_account (organization_id, iban, bank_name, is_default)
  values (l_org1, 'UA57 322001 00000 26007233566001', 'АТ «Універсал Банк»', 'Y');
  insert into ref_bank_account (organization_id, iban, bank_name, currency_code)
  values (l_org1, 'UA383003350000026000012345678', 'АТ «Райффайзен Банк»', 'USD');
  if l_org2 is not null then
    insert into ref_cash_desk (name, organization_id, responsible_name) values ('Каса ФОП', l_org2, 'Коваленко О. М.');
    insert into ref_bank_account (organization_id, iban, bank_name, is_default)
    values (l_org2, 'UA223052990000026001234567890', 'АТ КБ «ПриватБанк»', 'Y');
    -- IBAN демо-ФОП (25) мав неправильну контрольну суму — виправляємо на коректний
    update ref_organization set iban = 'UA223052990000026001234567890'
     where id = l_org2 and iban = 'UA323052990000026001234567890';
  end if;
  commit;
end;
/
