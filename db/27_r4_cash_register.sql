-- =============================================================================
-- Trade r4 — F-FIN-02 «Регістр грошових коштів». Паспорт RegCashBalance (PROPOSED).
--   * регістр накопичення залишків reg_cash_balance_mv: виміри організація, місце зберігання
--     (каса RefCashDesk або банківський рахунок RefBankAccount), валюта; ресурс сума (signed);
--     реквізити: вид операції, зміст;
--   * поточні підсумки reg_cash_balance_tot і місячні знімки reg_cash_balance_snap (як r3, db/22);
--     trade_regs.close_month / rebuild_totals обробляють і цей регістр;
--   * пакет trade_cash — API проведення для ПКО/ВКО, банківських виписок і оплат (APE-53/54/56/57):
--     add_movement / delete_movements / check_balances (контроль від'ємного залишку каси й рахунку
--     на кожну дату від найранішої зміненої), введення початкових залишків, залишок на дату;
--   * представлення v_cash_movement / v_cash_balance, меню «Фінанси → Звіти», сторінка 360.
-- Потребує 22_r3_totals.sql, 26_r4_cash_bank.sql. Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl(q'[create table reg_cash_balance_mv (
    id               varchar2(32)  default on null rawtohex(sys_guid()) not null,
    period           date          not null,
    recorder_type    varchar2(60)  not null,
    recorder_id      varchar2(32)  not null,
    line_number      number(10)    not null,
    organization_id  varchar2(32)  not null,
    place_kind       varchar2(12)  not null,
    cash_desk_id     varchar2(32),
    bank_account_id  varchar2(32),
    currency_code    varchar2(3)   not null,
    amount           number(19,2)  not null,
    operation_kind   varchar2(30),
    content          varchar2(255),
    constraint reg_cash_balance_mv_pk primary key (id),
    constraint reg_cash_balance_mv_uk unique (recorder_type, recorder_id, line_number),
    constraint reg_cash_balance_mv_kind_ck check (
      (place_kind = 'CASH_DESK' and cash_desk_id is not null and bank_account_id is null) or
      (place_kind = 'BANK_ACCOUNT' and bank_account_id is not null and cash_desk_id is null)),
    constraint reg_cash_balance_mv_amt_ck check (amount <> 0),
    constraint reg_cash_balance_mv_org_fk foreign key (organization_id) references ref_organization (id),
    constraint reg_cash_balance_mv_desk_fk foreign key (cash_desk_id) references ref_cash_desk (id),
    constraint reg_cash_balance_mv_bank_fk foreign key (bank_account_id) references ref_bank_account (id))]');
  ddl('create index reg_cash_balance_mv_per_ix on reg_cash_balance_mv (period)');
  ddl('create index reg_cash_balance_mv_desk_ix on reg_cash_balance_mv (cash_desk_id, period)');
  ddl('create index reg_cash_balance_mv_bank_ix on reg_cash_balance_mv (bank_account_id, period)');
  ddl('create index reg_cash_balance_mv_org_ix on reg_cash_balance_mv (organization_id)');

  -- Ключ підсумку: організація + місце зберігання + валюта (place_id = каса або рахунок)
  ddl(q'[create table reg_cash_balance_tot (
    organization_id varchar2(32) not null,
    place_kind      varchar2(12) not null,
    place_id        varchar2(32) not null,
    currency_code   varchar2(3)  not null,
    amount          number(19,2) default on null 0 not null,
    constraint reg_cash_balance_tot_pk primary key (organization_id, place_id, currency_code))]');
  ddl(q'[create table reg_cash_balance_snap (
    month_end       date         not null,
    organization_id varchar2(32) not null,
    place_kind      varchar2(12) not null,
    place_id        varchar2(32) not null,
    currency_code   varchar2(3)  not null,
    amount          number(19,2) default on null 0 not null,
    constraint reg_cash_balance_snap_pk primary key (month_end, organization_id, place_id, currency_code))]');
end;
/

create or replace package trade_cash as
  c_cash_desk    constant varchar2(12) := 'CASH_DESK';
  c_bank_account constant varchar2(12) := 'BANK_ACCOUNT';
  c_opening      constant varchar2(60) := 'CashOpeningBalance';   -- реєстратор «Введення залишку коштів»

  -- Рух регістру (лише в режимі проведення trade_core.g_internal). p_amount > 0 — надходження,
  -- < 0 — витрата. Організація й валюта беруться з каси/рахунку. Місце запам'ятовується для check_balances.
  procedure add_movement (p_recorder_type in varchar2, p_recorder_id in varchar2, p_period in date,
                          p_line_number in number, p_place_kind in varchar2, p_place_id in varchar2,
                          p_amount in number, p_operation_kind in varchar2 default null, p_content in varchar2 default null);
  -- Видалення рухів реєстратора (повторне проведення / скасування); місця запам'ятовуються
  procedure delete_movements (p_recorder_type in varchar2, p_recorder_id in varchar2);
  -- Контроль від'ємного залишку на всіх змінених місцях (CASH_BALANCE_NEGATIVE / BANK_BALANCE_NEGATIVE);
  -- викликається в кінці проведення та скасування проведення; очищає список місць
  procedure check_balances;
  -- Перевірка одного місця з дати p_from (порожньо — від початку)
  procedure check_place (p_place_id in varchar2, p_from in date default null);
  -- Введення (заміна) початкового залишку каси/рахунку; p_amount = 0 — видалити введення
  procedure set_opening_balance (p_place_kind in varchar2, p_place_id in varchar2, p_date in date, p_amount in number);

  -- Поточний залишок (підсумки) і залишок на момент (знімок + рухи)
  function balance (p_place_id in varchar2) return number;
  function balance_at (p_place_id in varchar2, p_at in date) return number;
  -- Найменування місця зберігання
  function place_name (p_place_id in varchar2) return varchar2;
  -- Чи є рухи за місцем (зміна організації / валюти заборонена)
  function has_movements (p_place_id in varchar2) return boolean;

  -- Підсумки / знімки (викликаються з trade_regs)
  procedure close_month (p_month in date);
  procedure rebuild_totals;
  procedure invalidate_snapshots (p_period in date);
end trade_cash;
/

create or replace package body trade_cash as
  type t_touched is table of date index by varchar2(32);   -- місце → найраніша змінена дата
  g_touched t_touched;

  procedure touch (p_place_id varchar2, p_period date) is
  begin
    if not g_touched.exists(p_place_id) or g_touched(p_place_id) > p_period then
      g_touched(p_place_id) := p_period;
    end if;
  end touch;

  procedure add_movement (p_recorder_type in varchar2, p_recorder_id in varchar2, p_period in date,
                          p_line_number in number, p_place_kind in varchar2, p_place_id in varchar2,
                          p_amount in number, p_operation_kind in varchar2 default null, p_content in varchar2 default null) is
  begin
    if nvl(p_amount, 0) = 0 then return; end if;   -- нульові рухи не пишуться
    if p_place_kind not in (c_cash_desk, c_bank_account) or p_place_id is null then
      trade_nsi.fail('CASH_PLACE_REQUIRED', 'Вкажіть касу або банківський рахунок.');
    end if;
    insert into reg_cash_balance_mv (period, recorder_type, recorder_id, line_number, place_kind,
                                     cash_desk_id, bank_account_id, amount, operation_kind, content)
    values (p_period, p_recorder_type, p_recorder_id, p_line_number, p_place_kind,
            case p_place_kind when c_cash_desk then p_place_id end,
            case p_place_kind when c_bank_account then p_place_id end,
            round(p_amount, 2), p_operation_kind, substr(p_content, 1, 255));
    touch(p_place_id, p_period);
  end add_movement;

  procedure delete_movements (p_recorder_type in varchar2, p_recorder_id in varchar2) is
  begin
    for r in (select coalesce(cash_desk_id, bank_account_id) place_id, min(period) period
                from reg_cash_balance_mv
               where recorder_type = p_recorder_type and recorder_id = p_recorder_id
               group by coalesce(cash_desk_id, bank_account_id)) loop
      touch(r.place_id, r.period);
    end loop;
    delete from reg_cash_balance_mv where recorder_type = p_recorder_type and recorder_id = p_recorder_id;
  end delete_movements;

  function place_name (p_place_id in varchar2) return varchar2 is
    l varchar2(400);
  begin
    select max(n) into l from (
      select 'каса «' || name || '»' n from ref_cash_desk where id = p_place_id
      union all
      select 'рахунок «' || name || '»' from ref_bank_account where id = p_place_id);
    return l;
  end place_name;

  procedure check_place (p_place_id in varchar2, p_from in date default null) is
    l_period date; l_bal number; l_cur varchar2(3); l_kind varchar2(12);
  begin
    -- залишок наростаючим підсумком на кожен момент від p_from: будь-яка точка < 0 — помилка
    select max(period) keep (dense_rank first order by period), max(bal) keep (dense_rank first order by period),
           max(currency_code), max(place_kind)
      into l_period, l_bal, l_cur, l_kind
      from (select period, currency_code, place_kind,
                   sum(sum(amount)) over (partition by currency_code order by period) bal
              from reg_cash_balance_mv
             where coalesce(cash_desk_id, bank_account_id) = p_place_id
             group by period, currency_code, place_kind)
     where bal < 0 and (p_from is null or period >= p_from);
    if l_period is not null then
      trade_nsi.fail(case l_kind when c_cash_desk then 'CASH_BALANCE_NEGATIVE' else 'BANK_BALANCE_NEGATIVE' end,
        'Недостатньо коштів: ' || place_name(p_place_id) || ' матиме від''ємний залишок '
        || to_char(l_bal, 'FM999G999G999G990D00') || ' ' || l_cur || ' на ' || to_char(l_period, 'DD.MM.YYYY HH24:MI:SS') || '.');
    end if;
  end check_place;

  procedure check_balances is
    l_place varchar2(32);
    l_list  t_touched := g_touched;
  begin
    g_touched.delete;   -- список очищається і при помилці
    l_place := l_list.first;
    while l_place is not null loop
      check_place(l_place, l_list(l_place));
      l_place := l_list.next(l_place);
    end loop;
  end check_balances;

  procedure set_opening_balance (p_place_kind in varchar2, p_place_id in varchar2, p_date in date, p_amount in number) is
    l_prev boolean := trade_core.g_internal;
  begin
    if p_place_id is null or p_place_kind not in (c_cash_desk, c_bank_account) then
      trade_nsi.fail('CASH_PLACE_REQUIRED', 'Вкажіть касу або банківський рахунок.');
    end if;
    if p_date is null then
      trade_nsi.fail('CASH_OPENING_DATE', 'Вкажіть дату початкового залишку.');
    end if;
    if p_amount is null then
      trade_nsi.fail('CASH_OPENING_AMOUNT', 'Вкажіть суму початкового залишку.');
    end if;
    if p_amount < 0 then
      trade_nsi.fail('CASH_OPENING_NEGATIVE', 'Початковий залишок не може бути від''ємним.');
    end if;
    if p_place_kind = c_cash_desk then
      trade_core.check_active_ref('REF_CASH_DESK', p_place_id, 'Каса');
    else
      trade_core.check_active_ref('REF_BANK_ACCOUNT', p_place_id, 'Банківський рахунок');
    end if;
    trade_core.g_internal := true;
    delete_movements(c_opening, p_place_id);
    add_movement(c_opening, p_place_id, trunc(p_date), 1, p_place_kind, p_place_id, p_amount,
                 'OPENING', 'Введення початкового залишку');
    check_balances;
    trade_core.g_internal := l_prev;
    trade_core.audit('RegCashBalance', p_place_id, 'OPENING_BALANCE',
                     to_char(p_amount, 'FM999999999990D00') || ' на ' || to_char(p_date, 'DD.MM.YYYY'));
  exception when others then
    trade_core.g_internal := l_prev;
    g_touched.delete;
    raise;
  end set_opening_balance;

  function balance (p_place_id in varchar2) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_cash_balance_tot where place_id = p_place_id;
    return l;
  end balance;

  function balance_at (p_place_id in varchar2, p_at in date) return number is
    l_end date; l_snap number := 0; l_mv number;
  begin
    select max(month_end) into l_end from reg_cash_balance_snap
     where place_id = p_place_id and month_end < trunc(p_at);
    if l_end is not null then
      select coalesce(sum(amount), 0) into l_snap from reg_cash_balance_snap
       where month_end = l_end and place_id = p_place_id;
    end if;
    select coalesce(sum(amount), 0) into l_mv from reg_cash_balance_mv
     where coalesce(cash_desk_id, bank_account_id) = p_place_id
       and period <= p_at and (l_end is null or period > l_end + 1 - 1/86400);
    return l_snap + l_mv;
  end balance_at;

  function has_movements (p_place_id in varchar2) return boolean is
    n number;
  begin
    select count(*) into n from reg_cash_balance_mv
     where (cash_desk_id = p_place_id or bank_account_id = p_place_id) and rownum = 1;
    return n > 0;
  end has_movements;

  procedure close_month (p_month in date) is
    l_end date := last_day(trunc(p_month));
  begin
    delete from reg_cash_balance_snap where month_end = l_end;
    insert into reg_cash_balance_snap (month_end, organization_id, place_kind, place_id, currency_code, amount)
    select l_end, organization_id, place_kind, coalesce(cash_desk_id, bank_account_id), currency_code, sum(amount)
      from reg_cash_balance_mv where period <= l_end + 1 - 1/86400
     group by organization_id, place_kind, coalesce(cash_desk_id, bank_account_id), currency_code
    having sum(amount) <> 0;
  end close_month;

  procedure rebuild_totals is
  begin
    delete from reg_cash_balance_tot;
    insert into reg_cash_balance_tot (organization_id, place_kind, place_id, currency_code, amount)
    select organization_id, place_kind, coalesce(cash_desk_id, bank_account_id), currency_code, sum(amount)
      from reg_cash_balance_mv
     group by organization_id, place_kind, coalesce(cash_desk_id, bank_account_id), currency_code;
  end rebuild_totals;

  procedure invalidate_snapshots (p_period in date) is
  begin
    delete from reg_cash_balance_snap where month_end >= last_day(trunc(p_period));
  end invalidate_snapshots;
end trade_cash;
/

-- ---------------------------------------------------------------- тригери регістру
-- Рухи пишуться лише проведенням (trade_core.g_internal)
create or replace trigger reg_cash_balance_mv_biud
before insert or update or delete on reg_cash_balance_mv
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/

-- Організація й валюта руху — з каси / рахунку
create or replace trigger reg_cash_balance_mv_bri
before insert or update on reg_cash_balance_mv for each row
declare
  l_org varchar2(32); l_cur varchar2(3);
begin
  if :new.cash_desk_id is not null then
    :new.place_kind := 'CASH_DESK';
    select organization_id, currency_code into l_org, l_cur from ref_cash_desk where id = :new.cash_desk_id;
  else
    :new.place_kind := 'BANK_ACCOUNT';
    select organization_id, currency_code into l_org, l_cur from ref_bank_account where id = :new.bank_account_id;
  end if;
  if :new.organization_id is not null and :new.organization_id <> l_org then
    trade_nsi.fail('CASH_PLACE_ORGANIZATION', 'Каса / банківський рахунок належить іншій організації.');
  end if;
  if :new.currency_code is not null and :new.currency_code <> l_cur then
    trade_nsi.fail('CASH_PLACE_CURRENCY', 'Валюта операції ' || :new.currency_code || ' не збігається з валютою каси / рахунку ' || l_cur || '.');
  end if;
  :new.organization_id := l_org;
  :new.currency_code := l_cur;
end;
/

-- Поточні підсумки й інвалідація знімків
create or replace trigger reg_cash_balance_mv_tot
after insert or update or delete on reg_cash_balance_mv for each row
begin
  if deleting or updating then
    merge into reg_cash_balance_tot t
    using (select :old.organization_id organization_id, coalesce(:old.cash_desk_id, :old.bank_account_id) place_id,
                  :old.currency_code currency_code, :old.place_kind place_kind from dual) s
       on (t.organization_id = s.organization_id and t.place_id = s.place_id and t.currency_code = s.currency_code)
     when matched then update set t.amount = t.amount - :old.amount
     when not matched then insert (organization_id, place_kind, place_id, currency_code, amount)
          values (s.organization_id, s.place_kind, s.place_id, s.currency_code, -:old.amount);
    trade_cash.invalidate_snapshots(:old.period);
  end if;
  if inserting or updating then
    merge into reg_cash_balance_tot t
    using (select :new.organization_id organization_id, coalesce(:new.cash_desk_id, :new.bank_account_id) place_id,
                  :new.currency_code currency_code, :new.place_kind place_kind from dual) s
       on (t.organization_id = s.organization_id and t.place_id = s.place_id and t.currency_code = s.currency_code)
     when matched then update set t.amount = t.amount + :new.amount
     when not matched then insert (organization_id, place_kind, place_id, currency_code, amount)
          values (s.organization_id, s.place_kind, s.place_id, s.currency_code, :new.amount);
    trade_cash.invalidate_snapshots(:new.period);
  end if;
end;
/

-- Організацію й валюту каси / рахунку з рухами змінювати не можна (ключ підсумків)
create or replace trigger ref_cash_desk_cash_bu
before update of organization_id, currency_code on ref_cash_desk for each row
when (new.organization_id <> old.organization_id or new.currency_code <> old.currency_code)
begin
  if trade_cash.has_movements(:old.id) then
    trade_nsi.fail('CASH_PLACE_HAS_MOVEMENTS', 'За касою є рухи грошових коштів — організацію й валюту змінити не можна.');
  end if;
end;
/
create or replace trigger ref_bank_account_cash_bu
before update of organization_id, currency_code on ref_bank_account for each row
when (new.organization_id <> old.organization_id or new.currency_code <> old.currency_code)
begin
  if trade_cash.has_movements(:old.id) then
    trade_nsi.fail('CASH_PLACE_HAS_MOVEMENTS', 'За рахунком є рухи грошових коштів — організацію й валюту змінити не можна.');
  end if;
end;
/

-- ---------------------------------------------------------------- представлення звіту
create or replace view v_cash_place as
select k.id place_id, 'CASH_DESK' place_kind, 'Каса' place_kind_name, k.code, k.name, k.organization_id, k.currency_code, k.state
  from ref_cash_desk k
union all
select b.id, 'BANK_ACCOUNT', 'Банківський рахунок', b.code, b.name, b.organization_id, b.currency_code, b.state
  from ref_bank_account b;

create or replace view v_cash_movement as
select m.id, m.period, m.recorder_type, m.recorder_id,
       coalesce(r.recorder_name,
                case m.recorder_type when 'CashOpeningBalance'
                     then 'Введення залишку коштів від ' || to_char(m.period, 'DD.MM.YYYY')
                     else m.recorder_type || ' ' || m.recorder_id end) recorder_name,
       coalesce(r.page_id, case when m.recorder_type = 'CashOpeningBalance'
                                then case m.place_kind when 'CASH_DESK' then 341 else 351 end end) page_id,
       m.organization_id, o.name organization_name, m.place_kind, p.place_kind_name, p.place_id, p.name place_name,
       m.currency_code, m.amount,
       case when m.amount > 0 then m.amount else 0 end incoming,
       case when m.amount < 0 then -m.amount else 0 end outgoing,
       m.operation_kind, m.content
  from reg_cash_balance_mv m
  join ref_organization o on o.id = m.organization_id
  join v_cash_place p on p.place_id = coalesce(m.cash_desk_id, m.bank_account_id)
  left join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id;

-- Поточні залишки — з підсумків
create or replace view v_cash_balance as
select t.organization_id, o.name organization_name, t.place_kind, p.place_kind_name, t.place_id, p.code place_code,
       p.name place_name, t.currency_code, t.amount balance
  from reg_cash_balance_tot t
  join ref_organization o on o.id = t.organization_id
  join v_cash_place p on p.place_id = t.place_id
 where t.amount <> 0;

-- ---------------------------------------------------------------- меню: «Фінанси → Звіти»
declare
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_tech varchar2, p_isort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_isort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_tech
       and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  end;
begin
  merge into sys_metadata_object o
  using (select 'RegCashBalance' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Залишки й обороти коштів', o.list_page_id = 360, o.auth_scheme = 'Роль: каса'
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('RegCashBalance', 'ACCUMULATION_REGISTER', 'Залишки й обороти коштів',
            (select id from sys_main_menu_section where tech_name = 'Reports'), 360, null, 120, 'Роль: каса');
  fp('Finance', 'Звіти', 1, 20, 'RegCashBalance', 10);
  commit;
end;
/

-- ---------------------------------------------------------------- підсумки й демо: початкові залишки
declare
  n number;
begin
  trade_cash.rebuild_totals;
  select count(*) into n from reg_cash_balance_mv;
  if n = 0 then
    for r in (select place_kind, place_id, case place_kind when 'CASH_DESK' then 5000 else 150000 end
                     * case currency_code when 'UAH' then 1 else 0.05 end amount
                from v_cash_place where state = 'ACTIVE') loop
      trade_cash.set_opening_balance(r.place_kind, r.place_id, trunc(add_months(sysdate, -1), 'MM'), r.amount);
    end loop;
  end if;
  trade_cash.close_month(add_months(sysdate, -1));
  commit;
end;
/
