-- =============================================================================
-- Trade r5 — F-FIN-06 «Валюти й курси валют» (APE-66). Паспорти RefCurrency, RegCurrencyRate (PROPOSED).
--   * довідник ref_currency «Валюти»: код ISO 4217 (літерний, ключ для посилань), цифровий код
--     (r030 НБУ), найменування, символ, ознака «Завантажувати курс НБУ». Національна валюта — UAH
--     (курс завжди 1, не помічається на видалення);
--   * РІШЕННЯ: наявні поля currency_code (каси, банківські рахунки, договори, види цін, касові
--     ордери, виписки, регістр коштів) лишаються літерними кодами ISO — тепер це зовнішні ключі на
--     ref_currency(code) (унікальний ключ), без міграції на id; код валюти, що вже використовується,
--     змінити не можна (CURRENCY_IN_USE);
--   * регістр відомостей reg_currency_rate «Курси валют»: валюта × дата → курс за кратність
--     (як у НБУ — грн за 1 одиницю; кратність для «дрібних» валют), джерело MANUAL / NBU;
--     курс на дату — останній запис з датою ≤ дати (зріз останніх);
--   * пакет trade_currency: rate / rate_date / to_uah / convert, set_rate, parse_nbu (JSON
--     bank.gov.ua), load_nbu (apex_web_service, HTTPS), load_nbu_period; щоденне завдання
--     TRADE_NBU_RATES (DBMS_SCHEDULER, 09:30) завантажує курси на сьогодні;
--   * гривневий еквівалент: v_cash_balance_uah (залишки кас і рахунків × курс на дату), сторінка 360;
--   * ОБМЕЖЕННЯ r5: документи й взаєморозрахунки — лише в UAH (check-обмеження r1–r4 не знято);
--     валюта договору / документа й курсові різниці — наступний етап (див. паспорт RefCurrency).
-- Потребує 02, 26, 27, 28, 29, 37. Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  ddl(q'[create table ref_currency (
    id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code          varchar2(3)   not null,
    numeric_code  varchar2(3),
    name          varchar2(100) not null,
    symbol        varchar2(10),
    load_rates    varchar2(1)   default on null 'N' not null,
    note          varchar2(1000),
    state         varchar2(20)  default on null 'ACTIVE' not null,
    version       number(19)    default on null 0 not null,
    created_at    timestamp     not null, created_by varchar2(255) not null,
    updated_at    timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_currency_pk primary key (id),
    constraint ref_currency_code_uk unique (code),
    constraint ref_currency_num_uk unique (numeric_code),
    constraint ref_currency_load_ck check (load_rates in ('Y','N')),
    constraint ref_currency_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');

  ddl(q'[create table reg_currency_rate (
    id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
    currency_code varchar2(3)   not null,
    rate_date     date          not null,
    rate          number(19,6)  not null,
    multiplier    number(10)    default on null 1 not null,
    source        varchar2(10)  default on null 'MANUAL' not null,
    note          varchar2(255),
    updated_at    timestamp,
    updated_by    varchar2(255),
    constraint reg_currency_rate_pk primary key (id),
    constraint reg_currency_rate_uk unique (currency_code, rate_date),
    constraint reg_currency_rate_cur_fk foreign key (currency_code) references ref_currency (code),
    constraint reg_currency_rate_rate_ck check (rate > 0),
    constraint reg_currency_rate_mult_ck check (multiplier > 0),
    constraint reg_currency_rate_src_ck check (source in ('MANUAL','NBU')))]');
end;
/

-- ---------------------------------------------------------------- trade_currency
create or replace package trade_currency as
  c_national constant varchar2(3) := 'UAH';
  g_loading  boolean := false;   -- set_rate: джерело задане явно
  -- Перевірка валюти: існує й активна (CURRENCY_UNKNOWN / CURRENCY_INACTIVE)
  procedure check_active (p_code in varchar2);
  -- Тригер довідника
  procedure check_currency (p_inserting in boolean, p_code in out varchar2, p_old_code in varchar2,
                            p_numeric in out varchar2, p_load in out varchar2, p_state in varchar2, p_old_state in varchar2);
  -- Чи використовується код валюти (курси, каси, рахунки, договори, види цін, документи, рухи коштів)
  function is_used (p_code in varchar2) return boolean;
  -- Курс (грн за 1 одиницю) на дату: останній запис з датою ≤ p_date; UAH = 1; немає — null
  function rate (p_code in varchar2, p_date in date default sysdate) return number;
  -- Дата курсу, що діє на дату
  function rate_date (p_code in varchar2, p_date in date default sysdate) return date;
  -- Гривневий еквівалент (округлення до копійки); немає курсу — null
  function to_uah (p_amount in number, p_code in varchar2, p_date in date default sysdate) return number;
  -- Перерахунок між валютами через гривню
  function convert_amount (p_amount in number, p_from in varchar2, p_to in varchar2, p_date in date default sysdate) return number;
  -- Курс на дату вручну / з НБУ (merge за валютою й датою)
  procedure set_rate (p_code in varchar2, p_date in date, p_rate in number, p_multiplier in number default 1,
                      p_source in varchar2 default 'MANUAL');
  -- Розбір JSON НБУ ([{"r030":840,"cc":"USD","rate":41.2,"exchangedate":"06.11.2026"}, …]):
  -- записує курси валют довідника з ознакою «Завантажувати курс НБУ»; повертає кількість курсів
  function parse_nbu (p_json in clob, p_date in date default null) return number;
  -- Завантаження з bank.gov.ua на дату (NBU_HTTP — помилка запиту)
  function load_nbu (p_date in date default trunc(sysdate)) return number;
  -- Завантаження за період (≤ 93 дні), повертає кількість курсів
  function load_nbu_period (p_from in date, p_to in date) return number;
  -- Для щоденного завдання TRADE_NBU_RATES
  procedure load_nbu_today;
end trade_currency;
/

create or replace package body trade_currency as
  c_letters constant varchar2(26) := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  c_digits  constant varchar2(10) := '0123456789';
  c_url     constant varchar2(200) := 'https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json&date=';

  procedure fail (p_code varchar2, p_msg varchar2) is
  begin
    trade_nsi.fail(p_code, p_msg);
  end fail;

  procedure check_active (p_code in varchar2) is
    l_state varchar2(20);
  begin
    select max(state) into l_state from ref_currency where code = upper(trim(p_code));
    if l_state is null then
      fail('CURRENCY_UNKNOWN', 'Валюти ' || p_code || ' немає в довіднику «Валюти».');
    elsif l_state <> 'ACTIVE' then
      fail('CURRENCY_INACTIVE', 'Валюту ' || p_code || ' помічено на видалення.');
    end if;
  end check_active;

  function is_used (p_code in varchar2) return boolean is
    l_n number;
  begin
    select count(*) into l_n from dual
     where exists (select 1 from reg_currency_rate where currency_code = p_code)
        or exists (select 1 from ref_cash_desk where currency_code = p_code)
        or exists (select 1 from ref_bank_account where currency_code = p_code)
        or exists (select 1 from ref_contract where currency_code = p_code)
        or exists (select 1 from ref_price_type where currency_code = p_code)
        or exists (select 1 from reg_cash_balance_mv where currency_code = p_code)
        or exists (select 1 from reg_counterparty_settlement_mv where currency_code = p_code);
    return l_n > 0;
  end is_used;

  procedure check_currency (p_inserting in boolean, p_code in out varchar2, p_old_code in varchar2,
                            p_numeric in out varchar2, p_load in out varchar2, p_state in varchar2, p_old_state in varchar2) is
  begin
    p_code := upper(trim(p_code));
    if p_code is null or length(p_code) <> 3 or translate(p_code, 'x' || c_letters, 'x') is not null then
      fail('CURRENCY_CODE', 'Код валюти — 3 латинські літери ISO 4217 (UAH, USD, EUR).');
    end if;
    p_numeric := trim(p_numeric);
    if p_numeric is not null then
      p_numeric := lpad(p_numeric, 3, '0');
      if length(p_numeric) <> 3 or translate(p_numeric, 'x' || c_digits, 'x') is not null then
        fail('CURRENCY_NUMERIC_CODE', 'Цифровий код валюти — 3 цифри ISO 4217 (980, 840, 978).');
      end if;
    end if;
    p_load := coalesce(p_load, 'N');
    if p_code = c_national then
      p_load := 'N';
      if p_state = 'MARKED_FOR_DELETION' then
        fail('CURRENCY_NATIONAL', 'Національну валюту (UAH) не можна помітити на видалення.');
      end if;
    end if;
    if not p_inserting and p_code <> p_old_code then
      if p_old_code = c_national then
        fail('CURRENCY_NATIONAL', 'Код національної валюти (UAH) змінювати не можна.');
      elsif is_used(p_old_code) then
        fail('CURRENCY_IN_USE', 'Код валюти ' || p_old_code || ' уже використовується (курси, каси, рахунки, договори) — змінити не можна.');
      end if;
    end if;
  end check_currency;

  function rate_date (p_code in varchar2, p_date in date default sysdate) return date is
    l_d date;
  begin
    if p_code = c_national then return trunc(p_date); end if;
    select max(rate_date) into l_d from reg_currency_rate
     where currency_code = p_code and rate_date <= trunc(coalesce(p_date, sysdate));
    return l_d;
  end rate_date;

  function rate (p_code in varchar2, p_date in date default sysdate) return number is
    l_r number;
  begin
    if p_code is null then return null; end if;
    if p_code = c_national then return 1; end if;
    select max(rate / multiplier) keep (dense_rank last order by rate_date) into l_r
      from reg_currency_rate
     where currency_code = p_code and rate_date <= trunc(coalesce(p_date, sysdate));
    return l_r;
  end rate;

  function to_uah (p_amount in number, p_code in varchar2, p_date in date default sysdate) return number is
  begin
    return round(p_amount * rate(p_code, p_date), 2);
  end to_uah;

  function convert_amount (p_amount in number, p_from in varchar2, p_to in varchar2, p_date in date default sysdate) return number is
  begin
    if p_from = p_to then return p_amount; end if;
    return round(p_amount * rate(p_from, p_date) / nullif(rate(p_to, p_date), 0), 2);
  end convert_amount;

  procedure set_rate (p_code in varchar2, p_date in date, p_rate in number, p_multiplier in number default 1,
                      p_source in varchar2 default 'MANUAL') is
  begin
    g_loading := true;
    merge into reg_currency_rate r
    using (select upper(trim(p_code)) c, trunc(p_date) d from dual) s
       on (r.currency_code = s.c and r.rate_date = s.d)
     when matched then update set r.rate = p_rate, r.multiplier = coalesce(p_multiplier, 1), r.source = p_source
     when not matched then insert (currency_code, rate_date, rate, multiplier, source)
          values (s.c, s.d, p_rate, coalesce(p_multiplier, 1), p_source);
    g_loading := false;
  exception when others then
    g_loading := false;
    raise;
  end set_rate;

  function parse_nbu (p_json in clob, p_date in date default null) return number is
    l_n number := 0;
  begin
    for r in (select j.cc, j.rate, coalesce(to_date(j.exchangedate, 'DD.MM.YYYY'), trunc(p_date)) d
                from json_table(p_json, '$[*]' columns (cc varchar2(3) path '$.cc', rate number path '$.rate',
                                                         exchangedate varchar2(10) path '$.exchangedate')) j
                join ref_currency c on c.code = upper(j.cc)
               where c.load_rates = 'Y' and c.state = 'ACTIVE' and c.code <> c_national and j.rate > 0) loop
      continue when r.d is null;
      set_rate(upper(r.cc), r.d, r.rate, 1, 'NBU');
      l_n := l_n + 1;
    end loop;
    return l_n;
  end parse_nbu;

  function load_nbu (p_date in date default trunc(sysdate)) return number is
    l_json clob;
    l_n    number;
  begin
    begin
      l_json := apex_web_service.make_rest_request(p_url => c_url || to_char(coalesce(p_date, sysdate), 'YYYYMMDD'),
                                                   p_http_method => 'GET');
    exception when others then
      fail('NBU_HTTP', 'Не вдалося отримати курси НБУ: ' || substr(sqlerrm, 1, 300));
    end;
    if apex_web_service.g_status_code <> 200 then
      fail('NBU_HTTP', 'НБУ повернув HTTP ' || apex_web_service.g_status_code || '.');
    end if;
    l_n := parse_nbu(l_json, p_date);
    trade_core.audit('REG_CURRENCY_RATE', to_char(coalesce(p_date, sysdate), 'YYYYMMDD'), 'NBU_LOAD',
                     'Завантажено курсів НБУ на ' || to_char(coalesce(p_date, sysdate), 'DD.MM.YYYY') || ': ' || l_n);
    return l_n;
  end load_nbu;

  function load_nbu_period (p_from in date, p_to in date) return number is
    l_n number := 0;
  begin
    if p_from is null or p_to is null or p_to < p_from then
      fail('NBU_PERIOD', 'Вкажіть період: дата «по» не раніше дати «з».');
    elsif trunc(p_to) - trunc(p_from) > 92 then
      fail('NBU_PERIOD', 'Період завантаження — не більше 93 днів.');
    end if;
    for i in 0 .. trunc(p_to) - trunc(p_from) loop
      l_n := l_n + load_nbu(trunc(p_from) + i);
    end loop;
    return l_n;
  end load_nbu_period;

  procedure load_nbu_today is
    l_n number;
  begin
    l_n := load_nbu(trunc(sysdate));
    commit;
  end load_nbu_today;
end trade_currency;
/

-- ---------------------------------------------------------------- тригери
create or replace trigger ref_currency_biu
before insert or update on ref_currency for each row
begin
  if inserting then
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_currency.check_currency(inserting, :new.code, :old.code, :new.numeric_code, :new.load_rates, :new.state, :old.state);
  :new.name := trim(:new.name);
  if :new.name is null then
    trade_nsi.fail('CURRENCY_NAME', 'Найменування валюти обов''язкове.');
  end if;
  :new.symbol := trim(:new.symbol);
  :new.note := trim(:new.note);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_currency_bd before delete on ref_currency
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

create or replace trigger reg_currency_rate_biu
before insert or update on reg_currency_rate for each row
declare
  l_n number;
begin
  :new.currency_code := upper(trim(:new.currency_code));
  if :new.currency_code = trade_currency.c_national then
    trade_nsi.fail('CURRENCY_NATIONAL', 'Курс національної валюти (UAH) завжди 1 — не вводиться.');
  end if;
  select count(*) into l_n from ref_currency where code = :new.currency_code;
  if l_n = 0 then
    trade_nsi.fail('CURRENCY_UNKNOWN', 'Валюти ' || :new.currency_code || ' немає в довіднику «Валюти».');
  end if;
  if :new.rate_date is null then
    trade_nsi.fail('CURRENCY_RATE_DATE', 'Вкажіть дату курсу.');
  end if;
  :new.rate_date := trunc(:new.rate_date);
  if :new.rate is null or :new.rate <= 0 then
    trade_nsi.fail('CURRENCY_RATE_POSITIVE', 'Курс валюти має бути більшим за нуль.');
  end if;
  :new.multiplier := coalesce(:new.multiplier, 1);
  if :new.multiplier <= 0 or :new.multiplier <> trunc(:new.multiplier) then
    trade_nsi.fail('CURRENCY_RATE_MULTIPLIER', 'Кратність — ціле число, більше за нуль (1, 10, 100).');
  end if;
  :new.source := coalesce(:new.source, 'MANUAL');
  -- курс, змінений вручну (не через set_rate), — джерело MANUAL
  if updating and not trade_currency.g_loading and (:new.rate <> :old.rate or :new.multiplier <> :old.multiplier) then
    :new.source := 'MANUAL';
  end if;
  :new.note := trim(:new.note);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/

-- ---------------------------------------------------------------- довідник: наповнення
declare
  procedure cur (p_code varchar2, p_num varchar2, p_name varchar2, p_sym varchar2, p_load varchar2) is
  begin
    merge into ref_currency c using (select p_code code from dual) s on (c.code = s.code)
     when not matched then insert (code, numeric_code, name, symbol, load_rates) values (p_code, p_num, p_name, p_sym, p_load);
  end;
begin
  cur('UAH', '980', 'Гривня', '₴', 'N');
  cur('USD', '840', 'Долар США', '$', 'Y');
  cur('EUR', '978', 'Євро', '€', 'Y');
  cur('PLN', '985', 'Польський злотий', 'zł', 'Y');
  cur('GBP', '826', 'Фунт стерлінгів', '£', 'Y');
  -- коди, уже вжиті в даних r1–r4 (щоб зовнішні ключі не впали)
  for r in (select distinct upper(currency_code) c from (
              select currency_code from ref_cash_desk union all select currency_code from ref_bank_account
              union all select currency_code from ref_contract union all select currency_code from ref_price_type
              union all select currency_code from reg_cash_balance_mv union all select currency_code from doc_cash_receipt
              union all select currency_code from doc_cash_payment union all select currency_code from doc_bank_statement
              union all select currency_code from reg_counterparty_settlement_mv)
             where currency_code is not null and upper(currency_code) not in (select code from ref_currency)) loop
    cur(r.c, null, r.c, null, 'N');
  end loop;
  commit;
end;
/

-- ---------------------------------------------------------------- зовнішні ключі на ref_currency(code)
declare
  procedure fk (p_tab varchar2, p_name varchar2) is
  begin
    execute immediate 'alter table ' || p_tab || ' add constraint ' || p_name
      || ' foreign key (currency_code) references ref_currency (code)';
  exception when others then if sqlcode not in (-2275, -2264) then raise; end if;
  end;
begin
  fk('ref_cash_desk',      'ref_cash_desk_cur_fk');
  fk('ref_bank_account',   'ref_bank_account_cur_fk');
  fk('ref_contract',       'ref_contract_cur_fk');
  fk('ref_price_type',     'ref_price_type_cur_fk');
  fk('doc_cash_receipt',   'doc_cash_receipt_cur_fk');
  fk('doc_cash_payment',   'doc_cash_payment_cur_fk');
  fk('doc_bank_statement', 'doc_bank_statement_cur_fk');
  fk('reg_cash_balance_mv','reg_cash_balance_mv_cur_fk');
  fk('reg_counterparty_settlement_mv', 'reg_cp_settlement_mv_cur_fk');
end;
/

-- ---------------------------------------------------------------- представлення
create or replace view v_currency_list as
select c.id, c.code, c.numeric_code, c.name, c.symbol, c.load_rates, c.note, c.state,
       case when c.code = 'UAH' then 'Так' end national_name,
       case c.load_rates when 'Y' then 'Так' end load_rates_name,
       case when c.code = 'UAH' then 1 else trade_currency.rate(c.code, sysdate) end current_rate,
       case when c.code <> 'UAH' then trade_currency.rate_date(c.code, sysdate) end current_rate_date,
       (select count(*) from reg_currency_rate r where r.currency_code = c.code) rates_count
  from ref_currency c;

create or replace view v_currency_rate as
select r.id, r.currency_code, c.name currency_name, r.rate_date, r.rate, r.multiplier, round(r.rate / r.multiplier, 6) unit_rate,
       r.source, case r.source when 'NBU' then 'НБУ' else 'Вручну' end source_name, r.note, r.updated_at, r.updated_by
  from reg_currency_rate r
  join ref_currency c on c.code = r.currency_code;

-- Залишки кас і рахунків з гривневим еквівалентом за курсом на поточну дату
create or replace view v_cash_balance_uah as
select b.organization_id, b.organization_name, b.place_kind, b.place_kind_name, b.place_id, b.place_code, b.place_name,
       b.currency_code, b.balance, trade_currency.rate(b.currency_code, sysdate) rate,
       trade_currency.rate_date(b.currency_code, sysdate) rate_date,
       trade_currency.to_uah(b.balance, b.currency_code, sysdate) balance_uah
  from v_cash_balance b;

-- ---------------------------------------------------------------- демо-курси: НБУ за 14 днів, інакше фіксовані
declare
  l_n number := 0;
begin
  select count(*) into l_n from reg_currency_rate;
  if l_n = 0 then
    begin
      l_n := trade_currency.load_nbu_period(trunc(sysdate) - 14, trunc(sysdate));
    exception when others then
      l_n := 0;
    end;
    if l_n = 0 then
      trade_currency.set_rate('USD', trunc(sysdate) - 30, 41.25);
      trade_currency.set_rate('EUR', trunc(sysdate) - 30, 47.80);
      trade_currency.set_rate('PLN', trunc(sysdate) - 30, 11.10);
      trade_currency.set_rate('GBP', trunc(sysdate) - 30, 55.40);
    end if;
    commit;
  end if;
end;
/

-- ---------------------------------------------------------------- щоденне завантаження курсів НБУ
begin
  begin dbms_scheduler.drop_job('TRADE_NBU_RATES', force => true); exception when others then null; end;
  dbms_scheduler.create_job(
    job_name        => 'TRADE_NBU_RATES',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'TRADE_CURRENCY.LOAD_NBU_TODAY',
    start_date      => systimestamp,
    repeat_interval => 'FREQ=DAILY;BYHOUR=9;BYMINUTE=30;BYSECOND=0',
    enabled         => true,
    comments        => 'Trade F-FIN-06: щоденне завантаження курсів НБУ (bank.gov.ua)');
exception when others then
  dbms_output.put_line('TRADE_NBU_RATES не створено: ' || sqlerrm);
end;
/

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
  obj('RefCurrency',     'CATALOG',              'Catalogs', 'Валюти',       600, 601, 140, null);
  obj('RegCurrencyRate', 'INFORMATION_REGISTER', 'Reports',  'Курси валют',  610, null, 240, null);
  fp('Finance', 'Казначейство', 1, 10, 'RefCurrency', 30);
  fp('Finance', 'Казначейство', 1, 10, 'RegCurrencyRate', 40);
  fp('Reference', 'Підприємство', 1, 5, 'RefCurrency', 40);
  fp('Reference', 'Підприємство', 1, 5, 'RegCurrencyRate', 50);
  commit;
end;
/

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
