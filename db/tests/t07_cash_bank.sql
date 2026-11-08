-- F-FIN-01 «Каси й банківські рахунки»: IBAN UA (формат, контрольна сума, МФО), основний рахунок, помітка. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_def varchar2(32); l_b varchar2(32); l_k varchar2(32); l_a1 varchar2(32); l_a2 varchar2(32); l_a3 varchar2(32);
  l_n number; l_s varchar2(4000); l_def_cnt number;

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
begin
  l_def := trade_org.default_org;
  select count(*) into l_def_cnt from ref_bank_account where is_default = 'Y' and organization_id = l_def and currency_code = 'UAH';
  insert into ref_organization (name, org_kind, edrpou) values ('T7 ФОП ' || t, 'INDIVIDUAL', '1234567891') returning id into l_b;

  -- ---------------------------------------------------------------- IBAN: функції
  eqs('Коректний IBAN (приклад НБУ)', trade_fin.is_valid_ua_iban('UA21 3223 1300 0002 6007 2335 6600 1'), 'Y');
  eqs('Змінена цифра → контрольна сума хибна', trade_fin.is_valid_ua_iban('UA213223130000026007233566002'), 'N');
  eqs('Переставлені цифри → хибна', trade_fin.is_valid_ua_iban('UA213223130000026007233566010'), 'N');
  eqs('Іноземний IBAN не є UA', trade_fin.is_valid_ua_iban('DE89370400440532013000'), 'N');
  eqs('Контрольна сума DE (ISO 13616)', case when trade_fin.iban_checksum_ok('DE89 3704 0044 0532 0130 00') then 'Y' else 'N' end, 'Y');
  eqs('МФО з IBAN', trade_fin.mfo_from_iban('ua21 322313 0000026007233566001'), '322313');

  -- ---------------------------------------------------------------- банківський рахунок
  fails('Рахунок без IBAN', 'BANK_ACCOUNT_IBAN_REQUIRED',
        'insert into ref_bank_account (organization_id, bank_name) values (''' || l_b || ''', ''Банк'')');
  fails('IBAN неправильного формату', 'BANK_ACCOUNT_IBAN_FORMAT',
        'insert into ref_bank_account (organization_id, iban, bank_name) values (''' || l_b || ''', ''UA2132231300000260072335660'', ''Банк'')');
  fails('IBAN з хибною контрольною сумою', 'BANK_ACCOUNT_IBAN_CHECKSUM',
        'insert into ref_bank_account (organization_id, iban, bank_name) values (''' || l_b || ''', ''UA213223130000026007233566002'', ''Банк'')');
  fails('МФО не відповідає IBAN', 'BANK_ACCOUNT_MFO',
        'insert into ref_bank_account (organization_id, iban, mfo, bank_name) values (''' || l_b || ''', ''UA213223130000026007233566001'', ''305299'', ''Банк'')');
  fails('Некоректна валюта', 'CURRENCY_CODE',
        'insert into ref_bank_account (organization_id, iban, bank_name, currency_code) values (''' || l_b || ''', ''UA213223130000026007233566001'', ''Банк'', ''U$D'')');
  fails('Рахунок без банку', 'Банк',
        'insert into ref_bank_account (organization_id, iban) values (''' || l_b || ''', ''UA213223130000026007233566001'')');

  insert into ref_bank_account (organization_id, iban, bank_name, is_default)
  values (l_b, 'ua21 3223 1300 0002 6007 2335 6600 1', 'T7 Банк', 'Y') returning id into l_a1;
  select iban || '|' || mfo || '|' || currency_code || '|' || name into l_s from ref_bank_account where id = l_a1;
  eqs('IBAN нормалізовано, МФО з IBAN, валюта UAH, автонайменування', l_s, 'UA213223130000026007233566001|322313|UAH|T7 Банк, UAH …6001');
  select count(*) into l_n from ref_bank_account where id = l_a1 and code like '0%';
  eq('Автокод рахунку', l_n, 1);
  fails('Дубль IBAN', 'IBAN_UK',
        'insert into ref_bank_account (organization_id, iban, bank_name) values (''' || l_def || ''', ''UA213223130000026007233566001'', ''Інший'')');
  eqs('Основний рахунок організації', case when trade_fin.default_bank_account(l_b) = l_a1 then 'так' else 'ні' end, 'так');

  insert into ref_bank_account (organization_id, iban, bank_name, is_default)
  values (l_b, 'UA213996220000026007233566001', 'T7 Банк 2', 'Y') returning id into l_a2;
  select count(*) into l_n from ref_bank_account where organization_id = l_b and currency_code = 'UAH' and is_default = 'Y';
  eq('Лише один основний рахунок (організація + валюта)', l_n, 1);
  eqs('Новий основний знімає ознаку з попереднього', case when trade_fin.default_bank_account(l_b) = l_a2 then 'так' else 'ні' end, 'так');

  insert into ref_bank_account (organization_id, iban, bank_name, currency_code, is_default)
  values (l_b, 'UA933003350000026000099999999', 'T7 Банк USD', 'usd', 'Y') returning id into l_a3;
  select count(*) into l_n from ref_bank_account where organization_id = l_b and is_default = 'Y';
  eq('Основні рахунки в різних валютах не конфліктують', l_n, 2);
  eqs('Основний USD-рахунок', case when trade_fin.default_bank_account(l_b, 'USD') = l_a3 then 'так' else 'ні' end, 'так');
  select count(*) into l_n from ref_bank_account where is_default = 'Y' and organization_id = l_def and currency_code = 'UAH';
  eq('Основний рахунок іншої організації не знято', l_n, l_def_cnt);

  trade_core.mark_for_deletion('REF_BANK_ACCOUNT', l_a2);
  select is_default into l_s from ref_bank_account where id = l_a2;
  eqs('Помічений рахунок перестає бути основним', l_s, 'N');
  eqs('Основний після помітки — інший активний', case when trade_fin.default_bank_account(l_b) = l_a1 then 'так' else 'ні' end, 'так');
  trade_core.restore('REF_BANK_ACCOUNT', l_a2);
  select state into l_s from ref_bank_account where id = l_a2;
  eqs('Відновлення рахунку', l_s, 'ACTIVE');
  fails('Фізичне видалення рахунку заборонене', 'Фізичне видалення',
        'delete from ref_bank_account where id = ''' || l_a2 || '''');
  fails('Зміна IBAN на хибний', 'BANK_ACCOUNT_IBAN_CHECKSUM',
        'update ref_bank_account set iban = ''UA213996220000026007233566002'' where id = ''' || l_a2 || '''');

  -- ---------------------------------------------------------------- каса
  insert into ref_cash_desk (name, responsible_name) values ('  T7 Каса ' || t || ' ', ' Т7 Касир ') returning id into l_k;
  select case when organization_id = l_def then 'так' else 'ні' end || '|' || currency_code || '|' || responsible_name into l_s
    from ref_cash_desk where id = l_k;
  eqs('Каса: організація за замовчуванням, UAH, trim', l_s, 'так|UAH|Т7 Касир');
  fails('Каса без найменування', 'Найменування',
        'insert into ref_cash_desk (name, organization_id) values (''  '', ''' || l_b || ''')');
  fails('Каса з некоректною валютою', 'CURRENCY_CODE',
        'insert into ref_cash_desk (name, organization_id, currency_code) values (''T7 X'', ''' || l_b || ''', ''U1H'')');
  update ref_cash_desk set currency_code = 'eur', organization_id = l_b where id = l_k;
  select currency_code into l_s from ref_cash_desk where id = l_k;
  eqs('Код валюти — верхній регістр', l_s, 'EUR');
  select count(*) into l_n from v_cash_desk where id = l_k and organization_id = l_b;
  eq('v_cash_desk: каса організації B', l_n, 1);
  trade_core.mark_for_deletion('REF_CASH_DESK', l_k);
  select state into l_s from ref_cash_desk where id = l_k;
  eqs('Помітка каси на видалення', l_s, 'MARKED_FOR_DELETION');
  fails('Фізичне видалення каси заборонене', 'Фізичне видалення',
        'delete from ref_cash_desk where id = ''' || l_k || '''');

  -- ---------------------------------------------------------------- помічена організація
  trade_core.mark_for_deletion('REF_ORGANIZATION', l_b);
  fails('Каса для поміченої організації', 'помічене на видалення',
        'insert into ref_cash_desk (name, organization_id) values (''T7 Y'', ''' || l_b || ''')');
  fails('Рахунок для поміченої організації', 'помічене на видалення',
        'insert into ref_bank_account (organization_id, iban, bank_name) values (''' || l_b || ''', ''UA573220010000026007233566001'', ''Б'')');

  -- ---------------------------------------------------------------- меню й права
  select count(*) into l_n from sys_main_menu_section where tech_name = 'Finance' and is_subsystem = 'Y' and is_visible = 'Y';
  eq('Розділ «Фінанси» в основному меню', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Finance' and o.tech_name in ('RefCashDesk', 'RefBankAccount') and o.auth_scheme = 'Роль: каса';
  eq('Панель «Фінанси»: каси й рахунки з правом «Роль: каса»', l_n, 2);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id in (340, 341, 350, 351)
     and p.authorization_scheme = 'Роль: каса';
  eq('Сторінки 340/341/350/351 захищені роллю', l_n, 4);
  select count(*) into l_n from apex_appl_acl_roles where application_id = 100 and role_static_id = 'CASHIER';
  eq('Роль «Касир» у застосунку', l_n, 1);
  rollback;
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
