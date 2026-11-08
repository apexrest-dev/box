-- F-FIN-06 «Валюти й курси валют»: довідник валют (ISO 4217), регістр курсів на дату (зріз останніх, кратність),
-- перерахунок у гривню й між валютами, розбір JSON НБУ, (за наявності мережі) завантаження з bank.gov.ua,
-- зовнішні ключі currency_code → ref_currency, контроль валюти кас і рахунків, гривневий еквівалент залишків коштів,
-- помітка на видалення, журнал, меню, сторінки. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  l_chf varchar2(32); l_jpy varchar2(32); l_uah varchar2(32); l_org varchar2(32); x varchar2(32);
  l_n number; l_s varchar2(4000); l_json clob;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || nvl(to_char(p_exp), 'null') || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    savepoint before_fail;
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
    rollback to before_fail;
  exception when others then
    trade_core.g_internal := false;
    rollback to before_fail;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
begin
  -- ---------------------------------------------------------------- довідник
  select count(*) into l_n from ref_currency where code in ('UAH', 'USD', 'EUR', 'PLN', 'GBP') and state = 'ACTIVE';
  eq('Початкові валюти UAH, USD, EUR, PLN, GBP', l_n, 5);
  select id into l_uah from ref_currency where code = 'UAH';
  eq('Курс UAH завжди 1', trade_currency.rate('UAH', date '2020-01-01'), 1);
  insert into ref_currency (code, numeric_code, name, symbol, load_rates) values ('chf', '756', ' Швейцарський франк ', 'Fr', 'Y')
    returning id into l_chf;
  select code || '|' || numeric_code || '|' || name || '|' || state into l_s from ref_currency where id = l_chf;
  eqs('Код у верхньому регістрі, найменування без пробілів', l_s, 'CHF|756|Швейцарський франк|ACTIVE');
  insert into ref_currency (code, numeric_code, name, load_rates) values ('JPY', '392', 'Єна', 'N') returning id into l_jpy;
  fails('Код не з 3 літер', 'CURRENCY_CODE', q'[insert into ref_currency (code, name) values ('US1', 'x')]');
  fails('Цифровий код не з цифр', 'CURRENCY_NUMERIC_CODE', q'[insert into ref_currency (code, numeric_code, name) values ('XAU', '9A', 'x')]');
  fails('Дубль коду', 'REF_CURRENCY_CODE_UK', q'[insert into ref_currency (code, name) values ('usd', 'x')]');
  fails('Без найменування', 'CURRENCY_NAME', q'[insert into ref_currency (code, name) values ('XAG', ' ')]');
  fails('Фізичне видалення', 'Фізичне видалення заборонене', 'delete from ref_currency where id = ''' || l_jpy || '''');
  update ref_currency set load_rates = 'Y' where id = l_uah;
  select load_rates into l_s from ref_currency where id = l_uah;
  eqs('UAH: ознака завантаження НБУ не вмикається', l_s, 'N');
  fails('UAH не помічається на видалення', 'CURRENCY_NATIONAL', 'begin trade_core.mark_for_deletion(''REF_CURRENCY'', ''' || l_uah || '''); end;');
  fails('Код UAH не змінюється', 'CURRENCY_NATIONAL', 'update ref_currency set code = ''UAX'' where id = ''' || l_uah || '''');

  -- ---------------------------------------------------------------- курси на дату
  trade_currency.set_rate('CHF', date '2026-01-10', 50);
  trade_currency.set_rate('CHF', to_date('20.01.2026 15:30', 'DD.MM.YYYY HH24:MI'), 52);
  eq('Курс до першого запису — немає', trade_currency.rate('CHF', date '2026-01-09'), null);
  eq('Курс на дату першого запису', trade_currency.rate('CHF', date '2026-01-10'), 50);
  eq('Курс між записами — останній попередній', trade_currency.rate('CHF', to_date('19.01.2026 23:59', 'DD.MM.YYYY HH24:MI')), 50);
  eq('Курс після другого запису (дата обрізана до дня)', trade_currency.rate('CHF', date '2026-01-25'), 52);
  eqs('Дата діючого курсу', to_char(trade_currency.rate_date('CHF', date '2026-01-15'), 'DD.MM.YYYY'), '10.01.2026');
  trade_currency.set_rate('CHF', date '2026-01-10', 50.5);
  select count(*) into l_n from reg_currency_rate where currency_code = 'CHF';
  eq('set_rate на ту саму дату — заміна, не дубль', l_n, 2);
  eq('Замінений курс', trade_currency.rate('CHF', date '2026-01-12'), 50.5);
  insert into reg_currency_rate (currency_code, rate_date, rate, multiplier) values ('jpy', date '2026-01-10', 30, 100);
  eq('Кратність 100: курс за одиницю', trade_currency.rate('JPY', date '2026-01-11'), 0.3);
  eq('Еквівалент 1000 JPY у грн', trade_currency.to_uah(1000, 'JPY', date '2026-01-11'), 300);
  eq('Еквівалент 10.01 CHF (округлення до копійки)', trade_currency.to_uah(10.01, 'CHF', date '2026-01-25'), 520.52);
  eq('Еквівалент UAH = сума', trade_currency.to_uah(123.45, 'UAH', date '2026-01-25'), 123.45);
  eq('Без курсу — null', trade_currency.to_uah(100, 'CHF', date '2025-12-31'), null);
  eq('Перерахунок 100 CHF → JPY через гривню', trade_currency.convert_amount(100, 'CHF', 'JPY', date '2026-01-25'), 17333.33);
  eq('Перерахунок у ту саму валюту', trade_currency.convert_amount(77, 'CHF', 'CHF', date '2026-01-25'), 77);
  fails('Курс UAH не вводиться', 'CURRENCY_NATIONAL', q'[insert into reg_currency_rate (currency_code, rate_date, rate) values ('UAH', date '2026-01-10', 1)]');
  fails('Курс ≤ 0', 'CURRENCY_RATE_POSITIVE', q'[insert into reg_currency_rate (currency_code, rate_date, rate) values ('CHF', date '2026-02-10', 0)]');
  fails('Кратність 0', 'CURRENCY_RATE_MULTIPLIER', q'[insert into reg_currency_rate (currency_code, rate_date, rate, multiplier) values ('CHF', date '2026-02-10', 5, 0)]');
  fails('Невідома валюта', 'CURRENCY_UNKNOWN', q'[insert into reg_currency_rate (currency_code, rate_date, rate) values ('XYZ', date '2026-02-10', 5)]');
  fails('Без дати', 'CURRENCY_RATE_DATE', q'[insert into reg_currency_rate (currency_code, rate, multiplier) values ('CHF', 5, 1)]');
  fails('Дубль валюта × дата', 'REG_CURRENCY_RATE_UK', q'[insert into reg_currency_rate (currency_code, rate_date, rate) values ('CHF', date '2026-01-10', 5)]');

  -- ---------------------------------------------------------------- JSON НБУ
  l_json := '[{"r030":756,"txt":"Швейцарський франк","rate":53.1234,"cc":"CHF","exchangedate":"03.02.2026","special":null},'
         || '{"r030":392,"txt":"Єна","rate":0.29,"cc":"JPY","exchangedate":"03.02.2026"},'
         || '{"r030":999,"txt":"Невідома","rate":1.5,"cc":"XXX","exchangedate":"03.02.2026"}]';
  eq('parse_nbu: лише валюти довідника з ознакою «Завантажувати курс НБУ»', trade_currency.parse_nbu(l_json), 1);
  select rate || '|' || source || '|' || to_char(rate_date, 'DD.MM.YYYY') into l_s from reg_currency_rate
   where currency_code = 'CHF' and rate_date = date '2026-02-03';
  eqs('Курс НБУ записано з датою exchangedate', l_s, '53.1234|NBU|03.02.2026');
  select count(*) into l_n from reg_currency_rate where currency_code = 'JPY' and rate_date = date '2026-02-03';
  eq('JPY (без ознаки НБУ) не записано', l_n, 0);
  update reg_currency_rate set rate = 53.2 where currency_code = 'CHF' and rate_date = date '2026-02-03';
  select source into l_s from reg_currency_rate where currency_code = 'CHF' and rate_date = date '2026-02-03';
  eqs('Ручна зміна курсу НБУ — джерело «Вручну»', l_s, 'MANUAL');
  eq('Повторний parse_nbu — оновлення (джерело NBU)', trade_currency.parse_nbu(l_json), 1);
  select rate || '|' || source into l_s from reg_currency_rate where currency_code = 'CHF' and rate_date = date '2026-02-03';
  eqs('Курс НБУ відновлено', l_s, '53.1234|NBU');
  fails('Період завантаження з датою «по» раніше «з»', 'NBU_PERIOD', 'declare n number; begin n := trade_currency.load_nbu_period(date ''2026-02-10'', date ''2026-02-01''); end;');
  fails('Період завантаження понад 93 дні', 'NBU_PERIOD', 'declare n number; begin n := trade_currency.load_nbu_period(date ''2026-01-01'', date ''2026-06-01''); end;');
  begin
    l_n := trade_currency.load_nbu(date '2026-11-06');
    select count(*) into l_n from reg_currency_rate where currency_code = 'USD' and rate_date = date '2026-11-06' and source = 'NBU';
    eq('Завантаження з bank.gov.ua (USD на 06.11.2026)', l_n, 1);
    select count(*) into l_n from sys_audit_log where action = 'NBU_LOAD' and object_id = '20261106';
    eq('Журнал: NBU_LOAD', sign(l_n), 1);
  exception when others then
    dbms_output.put_line('SKIP завантаження з bank.gov.ua (немає мережі?): ' || sqlerrm);
  end;

  -- ---------------------------------------------------------------- використання коду, помітка на видалення
  fails('Код використаної валюти не змінюється', 'CURRENCY_IN_USE', 'update ref_currency set code = ''CHE'' where id = ''' || l_chf || '''');
  insert into ref_currency (code, name) values ('XBA', 'Тест') returning id into x;
  update ref_currency set code = 'XBB' where id = x;
  select code into l_s from ref_currency where id = x;
  eqs('Код невикористаної валюти змінюється', l_s, 'XBB');
  select organization_id into l_org from ref_cash_desk where rownum = 1;
  insert into ref_cash_desk (name, organization_id, currency_code) values ('Каса CHF', l_org, 'chf');
  select count(*) into l_n from ref_cash_desk where name = 'Каса CHF' and currency_code = 'CHF';
  eq('Каса у валюті довідника (код нормалізовано)', l_n, 1);
  fails('Каса у валюті поза довідником', 'CURRENCY_UNKNOWN',
        'insert into ref_cash_desk (name, organization_id, currency_code) values (''Каса XYZ'', ''' || l_org || ''', ''XYZ'')');
  trade_core.mark_for_deletion('REF_CURRENCY', l_jpy);
  select state into l_s from ref_currency where id = l_jpy;
  eqs('Помітка на видалення (trade_core.catalog_table)', l_s, 'MARKED_FOR_DELETION');
  fails('Рахунок у поміченій валюті', 'CURRENCY_INACTIVE',
        'insert into ref_cash_desk (name, organization_id, currency_code) values (''Каса JPY'', ''' || l_org || ''', ''JPY'')');
  fails('check_active: помічена', 'CURRENCY_INACTIVE', 'begin trade_currency.check_active(''JPY''); end;');
  trade_core.restore('REF_CURRENCY', l_jpy);
  trade_currency.check_active('JPY');
  select state into l_s from ref_currency where id = l_jpy;
  eqs('Відновлення валюти', l_s, 'ACTIVE');
  fails('FK: рух взаєморозрахунків у валюті поза довідником', 'ORA-02291',
        q'[begin trade_core.g_internal := true; update reg_counterparty_settlement_mv set currency_code = 'QQQ' where rownum = 1; end;]');
  select count(*) into l_n from user_constraints c join user_constraints r on r.constraint_name = c.r_constraint_name
   where c.constraint_type = 'R' and r.table_name = 'REF_CURRENCY' and r.constraint_name = 'REF_CURRENCY_CODE_UK';
  eq('Зовнішні ключі currency_code → ref_currency(code)', l_n, 10);

  -- ---------------------------------------------------------------- гривневий еквівалент коштів
  select count(*), sum(case when balance_uah = round(balance * trade_currency.rate(currency_code, sysdate), 2) then 1 else 0 end)
    into l_n, l_s from v_cash_balance_uah;
  eq('v_cash_balance_uah: еквівалент = залишок × курс на сьогодні', to_number(l_s), l_n);
  select count(*) into l_n from v_cash_balance_uah where currency_code = 'UAH' and (rate <> 1 or balance_uah <> balance);
  eq('Гривневі каси: курс 1, еквівалент = залишок', l_n, 0);
  select count(*) into l_n from v_cash_balance_uah where currency_code <> 'UAH' and rate is null;
  eq('Валютні каси / рахунки мають курс на сьогодні', l_n, 0);
  select current_rate into l_n from v_currency_list where code = 'JPY';
  eq('v_currency_list: курс сьогодні (останній, за одиницю)', l_n, 0.3);

  -- ---------------------------------------------------------------- журнал, меню, сторінки, завдання
  select count(*) into l_n from user_triggers where trigger_name = 'REF_CURRENCY_EVLOG' and status = 'ENABLED';
  eq('Тригер журналу реєстрації', l_n, 1);
  select count(*) into l_n from sys_audit_log where object_type = 'REF_CURRENCY' and object_id = l_chf and action = 'CREATE';
  eq('Журнал: створення валюти', l_n, 1);
  select count(*) into l_n from sys_metadata_object
   where (tech_name = 'RefCurrency' and list_page_id = 600 and form_page_id = 601)
      or (tech_name = 'RegCurrencyRate' and list_page_id = 610);
  eq('Об''єкти меню', l_n, 2);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name in ('Finance', 'Reference') and o.tech_name in ('RefCurrency', 'RegCurrencyRate');
  eq('Панель функцій «Фінанси» і «НСІ»', l_n, 4);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (600, 601, 610);
  eq('Сторінки 600/601, 610', l_n, 3);
  select count(*) into l_n from apex_application_lovs where application_id = 100 and list_of_values_name = 'CURRENCIES'
     and lov_type = 'Dynamic';
  eq('LOV «CURRENCIES» читає довідник', l_n, 1);
  select count(*) into l_n from apex_application_page_ir_col
   where application_id = 100 and page_id = 360 and column_alias in ('BALANCE_UAH', 'CLOSING_UAH');
  eq('Сторінка 360: гривневий еквівалент', l_n, 2);
  select count(*) into l_n from user_scheduler_jobs where job_name = 'TRADE_NBU_RATES' and enabled = 'TRUE';
  eq('Щоденне завдання TRADE_NBU_RATES', l_n, 1);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
