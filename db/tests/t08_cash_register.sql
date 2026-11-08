-- F-FIN-02 «Регістр грошових коштів» RegCashBalance: виміри, підсумки/знімки, контроль від'ємного залишку каси
-- й рахунку, введення залишків, звіт. Проведення ПКО/ВКО (APE-53) імітується через API trade_cash. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  d0 date := trunc(add_months(sysdate, -3), 'MM');
  l_org varchar2(32); l_k varchar2(32); l_k2 varchar2(32); l_a varchar2(32);
  l_doc1 varchar2(32) := 'T8D1' || substr(t, 1, 28); l_doc2 varchar2(32) := 'T8D2' || substr(t, 1, 28);
  l_doc3 varchar2(32) := 'T8D3' || substr(t, 1, 28);
  l_n number; l_s varchar2(4000);

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
    trade_core.g_internal := false;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  -- «Проведення» тестового касового документа: замінити рухи й перевірити залишки
  procedure post (p_doc varchar2, p_kind varchar2, p_place varchar2, p_date date, p_amount number) is
  begin
    savepoint before_post;
    trade_core.g_internal := true;
    trade_cash.delete_movements('T8Doc', p_doc);
    trade_cash.add_movement('T8Doc', p_doc, p_date, 1, p_kind, p_place, p_amount, case when p_amount > 0 then 'RECEIPT' else 'PAYMENT' end, 'T8');
    trade_cash.check_balances;
    trade_core.g_internal := false;
  exception when others then
    trade_core.g_internal := false;
    rollback to before_post;
    raise;
  end;
  procedure unpost (p_doc varchar2) is
  begin
    savepoint before_unpost;
    trade_core.g_internal := true;
    trade_cash.delete_movements('T8Doc', p_doc);
    trade_cash.check_balances;
    trade_core.g_internal := false;
  exception when others then
    trade_core.g_internal := false;
    rollback to before_unpost;
    raise;
  end;
  function tot (p_place varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_tot where place_id = p_place;
    return l;
  end;
  procedure try (p_name varchar2, p_code varchar2, p_doc varchar2, p_kind varchar2, p_place varchar2, p_date date, p_amount number) is
  begin
    post(p_doc, p_kind, p_place, p_date, p_amount);
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
begin
  insert into ref_organization (name, org_kind, edrpou) values ('T8 ТОВ ' || t, 'LEGAL', '12345678') returning id into l_org;
  insert into ref_cash_desk (name, organization_id) values ('T8 Каса ' || t, l_org) returning id into l_k;
  insert into ref_cash_desk (name, organization_id, currency_code) values ('T8 Каса EUR ' || t, l_org, 'EUR') returning id into l_k2;
  insert into ref_bank_account (organization_id, iban, bank_name) values (l_org, 'UA213223130000026007233566001', 'T8 Банк') returning id into l_a;

  -- ---------------------------------------------------------------- рухи лише проведенням
  fails('Прямий запис руху заборонений', 'лише проведенням',
        'insert into reg_cash_balance_mv (period, recorder_type, recorder_id, line_number, place_kind, cash_desk_id, amount) values (sysdate, ''X'', ''X'', 1, ''CASH_DESK'', ''' || l_k || ''', 1)');

  -- ---------------------------------------------------------------- введення початкового залишку
  fails('Від''ємний початковий залишок', 'CASH_OPENING_NEGATIVE',
        'begin trade_cash.set_opening_balance(''CASH_DESK'', ''' || l_k || ''', sysdate, -1); end;');
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 500);
  trade_cash.set_opening_balance('CASH_DESK', l_k, d0, 1000);   -- повторне введення замінює
  select count(*) into l_n from reg_cash_balance_mv where recorder_type = 'CashOpeningBalance' and recorder_id = l_k;
  eq('Повторне введення залишку замінює рух', l_n, 1);
  eq('Поточний залишок каси (підсумки)', tot(l_k), 1000);
  select organization_id || '|' || currency_code || '|' || place_kind into l_s from reg_cash_balance_mv where cash_desk_id = l_k;
  eqs('Організація, валюта й вид місця — з каси', l_s, l_org || '|UAH|CASH_DESK');
  select recorder_name || '|' || page_id into l_s from v_cash_movement where place_id = l_k;
  eqs('Звіт: реєстратор введення залишку → картка каси', l_s, 'Введення залишку коштів від ' || to_char(d0, 'DD.MM.YYYY') || '|341');

  -- ---------------------------------------------------------------- проведення й контроль від'ємного залишку
  post(l_doc1, 'CASH_DESK', l_k, d0 + 5, -300);
  eq('ВКО 300: залишок 700', tot(l_k), 700);
  eq('trade_cash.balance', trade_cash.balance(l_k), 700);
  try('ВКО понад залишок каси', 'CASH_BALANCE_NEGATIVE', l_doc2, 'CASH_DESK', l_k, d0 + 6, -800);
  eq('Невдале проведення не змінює підсумки', tot(l_k), 700);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = l_doc2;
  eq('Невдале проведення не залишає рухів', l_n, 0);
  post(l_doc1, 'CASH_DESK', l_k, d0 + 5, -1000);   -- повторне проведення з новою сумою
  eq('Повторне проведення замінює набір: залишок 0', tot(l_k), 0);
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = l_doc1;
  eq('Один рух реєстратора після повторного проведення', l_n, 1);
  post(l_doc1, 'CASH_DESK', l_k, d0 + 5, -300);

  -- проміжний від'ємний залишок: надходження пізніше за витрату не рятує
  post(l_doc3, 'CASH_DESK', l_k, d0 + 20, 5000);
  eq('ПКО 5000: залишок 5700', tot(l_k), 5700);
  try('Витрата заднім числом, коли в касі ще не було грошей', 'CASH_BALANCE_NEGATIVE', l_doc2, 'CASH_DESK', l_k, d0 + 10, -2000);
  post(l_doc2, 'CASH_DESK', l_k, d0 + 25, -2000);
  eq('Та сама витрата після надходження проходить', tot(l_k), 3700);
  begin
    unpost(l_doc3);
    dbms_output.put_line('FAIL (помилки не було): скасування ПКО');
  exception when others then
    dbms_output.put_line(case when instr(sqlerrm, 'CASH_BALANCE_NEGATIVE') > 0 then 'OK  ' else 'FAIL' end
      || ' Скасування проведення ПКО, якщо гроші вже витрачено → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  eq('Після відмови скасування залишок не змінився', tot(l_k), 3700);
  unpost(l_doc2);
  unpost(l_doc3);
  eq('Скасування проведення ВКО й ПКО', tot(l_k), 700);

  -- ---------------------------------------------------------------- банківський рахунок
  try('Списання з рахунку без залишку', 'BANK_BALANCE_NEGATIVE', 'T8B1' || substr(t, 1, 28), 'BANK_ACCOUNT', l_a, d0 + 3, -1);
  post('T8B2' || substr(t, 1, 28), 'BANK_ACCOUNT', l_a, d0 + 3, 2500.555);
  eq('Надходження на рахунок (scale 2)', tot(l_a), 2500.56);
  select count(*) into l_n from reg_cash_balance_tot where place_id = l_a and place_kind = 'BANK_ACCOUNT' and organization_id = l_org;
  eq('Ключ підсумку: організація + рахунок + валюта', l_n, 1);
  fails('Рух без місця зберігання', 'CASH_PLACE_REQUIRED',
        'begin trade_core.g_internal := true; trade_cash.add_movement(''T8Doc'', ''Z'', sysdate, 1, ''CASH_DESK'', null, 10); end;');
  trade_core.g_internal := true;
  trade_cash.add_movement('T8Doc', 'ZERO', sysdate, 1, 'CASH_DESK', l_k, 0);
  trade_core.g_internal := false;
  select count(*) into l_n from reg_cash_balance_mv where recorder_id = 'ZERO';
  eq('Нульовий рух не пишеться', l_n, 0);

  -- ---------------------------------------------------------------- узгодженість виміру з довідником
  fails('Валюта руху не збігається з валютою каси', 'CASH_PLACE_CURRENCY',
        'begin trade_core.g_internal := true; insert into reg_cash_balance_mv (period, recorder_type, recorder_id, line_number, place_kind, cash_desk_id, currency_code, amount) values (sysdate, ''T8Doc'', ''C'', 1, ''CASH_DESK'', ''' || l_k2 || ''', ''UAH'', 1); end;');
  fails('Організація руху не збігається з організацією каси', 'CASH_PLACE_ORGANIZATION',
        'begin trade_core.g_internal := true; insert into reg_cash_balance_mv (period, recorder_type, recorder_id, line_number, place_kind, cash_desk_id, organization_id, amount) values (sysdate, ''T8Doc'', ''O'', 1, ''CASH_DESK'', ''' || l_k || ''', ''' || trade_org.default_org || ''', 1); end;');
  fails('Зміна валюти каси з рухами', 'CASH_PLACE_HAS_MOVEMENTS',
        'update ref_cash_desk set currency_code = ''USD'' where id = ''' || l_k || '''');
  fails('Зміна організації рахунку з рухами', 'CASH_PLACE_HAS_MOVEMENTS',
        'update ref_bank_account set organization_id = ''' || trade_org.default_org || ''' where id = ''' || l_a || '''');
  update ref_cash_desk set currency_code = 'USD' where id = l_k2;
  select currency_code into l_s from ref_cash_desk where id = l_k2;
  eqs('Валюту каси без рухів змінювати можна', l_s, 'USD');

  -- ---------------------------------------------------------------- знімки й залишок на дату
  trade_regs.close_month(d0);
  select count(*) into l_n from reg_cash_balance_snap where month_end = last_day(d0) and place_id = l_k and amount = 700;
  eq('Закриття місяця: знімок залишку каси', l_n, 1);
  eq('Залишок на дату до витрати', trade_cash.balance_at(l_k, d0 + 4), 1000);
  eq('Залишок на дату після витрати', trade_cash.balance_at(l_k, d0 + 6), 700);
  post(l_doc3, 'CASH_DESK', l_k, add_months(d0, 1) + 2, 100);
  eq('Залишок на дату через знімок + рухи', trade_cash.balance_at(l_k, add_months(d0, 1) + 3), 800);
  post(l_doc2, 'CASH_DESK', l_k, d0 + 7, 50);
  select count(*) into l_n from reg_cash_balance_snap where month_end >= last_day(d0) and place_id = l_k;
  eq('Зміна минулого періоду інвалідує знімки', l_n, 0);
  eq('Залишок на дату без знімка', trade_cash.balance_at(l_k, add_months(d0, 1) + 3), 850);

  -- ---------------------------------------------------------------- перебудова підсумків
  update reg_cash_balance_tot set amount = amount + 1 where place_id = l_k;
  trade_regs.rebuild_totals;
  select count(*) into l_n
    from (select organization_id, coalesce(cash_desk_id, bank_account_id) place_id, currency_code, sum(amount) a
            from reg_cash_balance_mv group by organization_id, coalesce(cash_desk_id, bank_account_id), currency_code) m
    full join reg_cash_balance_tot t using (organization_id, place_id, currency_code)
   where nvl(m.a, 0) <> nvl(t.amount, 0);
  eq('trade_regs.rebuild_totals перебудовує підсумки коштів', l_n, 0);
  eq('Залишок каси після перебудови', tot(l_k), 850);

  -- ---------------------------------------------------------------- звіт, меню, права
  select count(*) into l_n from v_cash_balance where place_id in (l_k, l_a) and organization_id = l_org;
  eq('v_cash_balance: каса й рахунок організації', l_n, 2);
  select sum(incoming) || '|' || sum(outgoing) into l_s from v_cash_movement where place_id = l_k;
  eqs('v_cash_movement: прихід | розхід', l_s, '1150|300');
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section s on s.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where s.tech_name = 'Finance' and o.tech_name = 'RegCashBalance' and o.auth_scheme = 'Роль: каса' and o.list_page_id = 360;
  eq('Панель «Фінанси → Звіти»: залишки й обороти коштів', l_n, 1);
  select count(*) into l_n from apex_application_pages p where p.application_id = 100 and p.page_id = 360
     and p.authorization_scheme = 'Роль: каса';
  eq('Сторінка 360 захищена роллю «каса»', l_n, 1);
  rollback;
exception when others then
  trade_core.g_internal := false;
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
