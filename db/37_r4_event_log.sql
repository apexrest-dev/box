-- =============================================================================
-- Trade r4 — F-SRV-05 «Журнал реєстрації» (перегляд sys_audit_log, аналог журналу реєстрації 1С).
--   * пакет trade_event_log:
--       event_group / event_group_name / event_name — групи подій для відбору: проведення,
--         скасування проведення, видалення (помітка / відновлення / фізичне видалення), друк,
--         попередження, запис (створення / зміна / копіювання / на підставі), інші (сервісні);
--       object_kind / object_type_name / object_name — уніфікований вид об'єкта (технічне ім'я
--         sys_metadata_object: REF_WAREHOUSE → RefWarehouse, Register.Barcode → RegBarcode),
--         його назва («Документ. Прибуткові накладні») і подання конкретного об'єкта;
--       link_page / link_item — сторінка переходу з запису журналу (форма документа / довідника,
--         акт звірки за контрагентом, сторінка регістру);
--       log_write — запис подій CREATE / UPDATE / DELETE з тригерів шапок документів і довідників:
--         CREATE / UPDATE — не частіше одного разу на об'єкт у транзакції, службові зміни
--         (trade_core.g_internal: проведення, перерахунки) і зміна стану довідника (помітка на
--         видалення, яка вже пишеться як MARK_FOR_DELETION / RESTORE) не журналюються;
--   * тригери <таблиця>_evlog на шапках усіх документів і всіх довідниках (генеруються);
--   * v_event_log — журнал з назвами й посиланнями; індекс за часом події;
--   * меню «НСІ та адміністрування → Сервіс → Журнал реєстрації» (лише роль «Адміністратор»).
-- Пов'язані зміни: db/02 trade_core.catalog_table + REF_BILL_OF_MATERIALS (помітка специфікації на
-- видалення падала «Невідомий довідник»); db/29 trade_bank_doc.link_cash_orders / link_payments
-- пишуть LINK_CASH_ORDERS / LINK_PAYMENTS.
-- Потребує 01–36 (v_recorder з db/33). Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is begin execute immediate p; exception when others then if sqlcode not in (-955, -1408) then raise; end if; end;
begin
  ddl('create index sys_audit_log_time_ix on sys_audit_log (occurred_at)');
end;
/

create or replace package trade_event_log as
  -- Група події для відбору: POST, UNPOST, DELETE, PRINT, WARNING, WRITE, OTHER
  function event_group      (p_action in varchar2) return varchar2 deterministic;
  function event_group_name (p_group in varchar2) return varchar2 deterministic;
  function event_name       (p_action in varchar2) return varchar2 deterministic;

  -- Технічне ім'я виду об'єкта (як sys_metadata_object.tech_name, якщо є)
  function object_kind      (p_object_type in varchar2) return varchar2 deterministic;
  -- «Документ. Прибуткові накладні», «Довідник. Склади», «Попередження» …
  function object_type_name (p_object_type in varchar2) return varchar2;
  -- Подання об'єкта (номер і дата документа, код і назва елемента довідника …); null — немає
  function object_name      (p_object_type in varchar2, p_object_id in varchar2) return varchar2;
  -- Сторінка переходу і її елемент-ключ (null — без ключа)
  function link_page        (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2) return number;
  function link_item        (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2) return varchar2;

  -- Запис CREATE / UPDATE / DELETE з тригерів шапок документів і довідників
  procedure log_write (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2, p_details in varchar2);
  -- Скинути пам'ять «вже записано в цій транзакції» (для тестів)
  procedure reset_txn;
  -- (Пере)створити тригери журналу на документах і довідниках
  procedure install_triggers;
end trade_event_log;
/

create or replace package body trade_event_log as

  type t_seen is table of boolean index by varchar2(200);
  g_txn  varchar2(200);
  g_seen t_seen;

  function event_group (p_action in varchar2) return varchar2 deterministic is
  begin
    return case
      when p_action in ('POST', 'ISSUE') then 'POST'
      when p_action in ('UNPOST', 'RETURN_TO_DRAFT', 'CANCEL') then 'UNPOST'
      when p_action in ('DELETE', 'MARK_FOR_DELETION', 'RESTORE') then 'DELETE'
      when p_action = 'PRINT' then 'PRINT'
      when p_action = 'WARN' then 'WARNING'
      when p_action in ('CREATE', 'UPDATE', 'INSERT', 'COPY', 'CREATE_BASED_ON') then 'WRITE'
      else 'OTHER' end;
  end event_group;

  function event_group_name (p_group in varchar2) return varchar2 deterministic is
  begin
    return case p_group
      when 'POST'    then 'Проведення'
      when 'UNPOST'  then 'Скасування проведення'
      when 'DELETE'  then 'Видалення'
      when 'PRINT'   then 'Друк'
      when 'WARNING' then 'Попередження'
      when 'WRITE'   then 'Запис'
      else 'Інші події' end;
  end event_group_name;

  function event_name (p_action in varchar2) return varchar2 deterministic is
  begin
    return case p_action
      when 'POST'                then 'Проведення'
      when 'ISSUE'               then 'Видача (проведення)'
      when 'UNPOST'              then 'Скасування проведення'
      when 'RETURN_TO_DRAFT'     then 'Повернення в чернетку'
      when 'CANCEL'              then 'Анулювання'
      when 'DELETE'              then 'Видалення'
      when 'MARK_FOR_DELETION'   then 'Помітка на видалення'
      when 'RESTORE'             then 'Зняття помітки на видалення'
      when 'PRINT'               then 'Друк'
      when 'WARN'                then 'Попередження'
      when 'CREATE'              then 'Створення'
      when 'INSERT'              then 'Додавання запису'
      when 'UPDATE'              then 'Зміна'
      when 'COPY'                then 'Копіювання'
      when 'CREATE_BASED_ON'     then 'Створення на підставі'
      when 'CLOSE'               then 'Закриття'
      when 'REOPEN'              then 'Відкриття'
      when 'FILL_BY_BOM'         then 'Заповнення за специфікацією'
      when 'FILL_COUNTERPARTIES' then 'Заповнення контрагентів'
      when 'LINK_CASH_ORDERS'    then 'Прив''язка касових ордерів'
      when 'LINK_PAYMENTS'       then 'Прив''язка документів оплати'
      when 'OPENING_BALANCE'     then 'Введення початкового залишку'
      when 'REBUILD'             then 'Перерахунок'
      when 'CLOSE_MONTH'         then 'Закриття місяця (знімки)'
      else p_action end;
  end event_name;

  -- REF_UNIT_OF_MEASURE → RefUnitOfMeasure (без regexp-діапазонів: в APEX-сесії вони нечутливі до регістру)
  function camel (p varchar2) return varchar2 is
    l varchar2(200); l_up boolean := true; c varchar2(1);
  begin
    for i in 1 .. length(p) loop
      c := substr(p, i, 1);
      if c = '_' then
        l_up := true;
      else
        l := l || case when l_up then upper(c) else lower(c) end;
        l_up := false;
      end if;
    end loop;
    return l;
  end camel;

  -- DocGoodsReceipt → DOC_GOODS_RECEIPT
  function snake (p varchar2) return varchar2 is
    l varchar2(200); c varchar2(1);
  begin
    for i in 1 .. length(p) loop
      c := substr(p, i, 1);
      if i > 1 and ascii(c) between 65 and 90 then l := l || '_'; end if;
      l := l || upper(c);
    end loop;
    return l;
  end snake;

  function object_kind (p_object_type in varchar2) return varchar2 deterministic is
  begin
    return case
      when p_object_type like 'REF\_%' escape '\' then camel(p_object_type)
      when p_object_type in ('Register.Barcode', 'Register.StockCost') then 'Reg' || substr(p_object_type, 10)
      else p_object_type end;
  end object_kind;

  function meta (p_kind varchar2, o_kind out varchar2, o_list out number, o_form out number) return varchar2 is
    l varchar2(100);
  begin
    select max(name), max(kind), max(list_page_id), max(form_page_id) into l, o_kind, o_list, o_form
      from sys_metadata_object where tech_name = p_kind;
    return l;
  end meta;

  function object_type_name (p_object_type in varchar2) return varchar2 is
    l_kind varchar2(30); l_list number; l_form number; l_name varchar2(100);
  begin
    l_name := meta(object_kind(p_object_type), l_kind, l_list, l_form);
    if l_name is not null then
      return case l_kind when 'CATALOG' then 'Довідник. ' when 'DOCUMENT' then 'Документ. '
                         when 'REPORT' then 'Звіт. ' else 'Регістр. ' end || l_name;
    end if;
    return case p_object_type
      when 'Warning'            then 'Попередження'
      when 'Register.Totals'    then 'Регістри. Підсумки'
      when 'Register.Snapshots' then 'Регістри. Знімки залишків'
      else p_object_type end;
  end object_type_name;

  function object_name (p_object_type in varchar2, p_object_id in varchar2) return varchar2 is
    l varchar2(4000);
  begin
    if p_object_type like 'REF\_%' escape '\' then
      execute immediate 'select max(code || '' '' || name) from ' || dbms_assert.simple_sql_name(p_object_type) || ' where id = :i'
        into l using p_object_id;
    elsif p_object_type like 'Doc%' then
      select max(recorder_name) into l from v_recorder where recorder_type = p_object_type and recorder_id = p_object_id;
      if l is null then   -- документ видалено: подання з запису DELETE
        select max(details) into l from sys_audit_log
         where object_type = p_object_type and object_id = p_object_id and action = 'DELETE';
        l := case when l is not null then l || ' (видалено)' end;
      end if;
    elsif p_object_type = 'ReconciliationAct' then
      select max(name) into l from ref_counterparty where id = p_object_id;
    elsif p_object_type = 'RegCashBalance' then
      l := trade_cash.place_name(p_object_id);
    elsif p_object_type = 'Register.Barcode' then
      select max(b.barcode || ' — ' || p.name) into l
        from reg_barcode b join ref_product p on p.id = b.product_id where b.id = p_object_id;
    elsif p_object_type = 'Warning' then
      l := p_object_id;
    end if;
    return l;
  exception when others then
    return null;
  end object_name;

  function link_page (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2) return number is
    l_kind varchar2(30); l_list number; l_form number; l_name varchar2(100); l number;
  begin
    if p_object_type like 'Doc%' then
      select max(page_id) into l from v_recorder where recorder_type = p_object_type and recorder_id = p_object_id;
      return l;
    elsif p_object_type = 'ReconciliationAct' then
      return 420;
    end if;
    l_name := meta(object_kind(p_object_type), l_kind, l_list, l_form);
    if l_kind = 'CATALOG' then
      return case when l_form is not null and p_action <> 'DELETE' and object_name(p_object_type, p_object_id) is not null then l_form end;
    end if;
    return l_list;
  end link_page;

  function link_item (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2) return varchar2 is
    l number := link_page(p_object_type, p_object_id, p_action);
  begin
    if l is null then return null; end if;
    if p_object_type = 'ReconciliationAct' then return 'P420_CP'; end if;
    if p_object_type like 'Doc%' or p_object_type like 'REF\_%' escape '\' then return 'P' || l || '_ID'; end if;
    return null;
  end link_item;

  procedure log_write (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2, p_details in varchar2) is
    l_txn varchar2(200) := dbms_transaction.local_transaction_id(false);
    l_key varchar2(200) := substr(p_object_type || ':' || p_object_id, 1, 200);
  begin
    if p_action in ('CREATE', 'UPDATE') then
      if trade_core.g_internal and p_action = 'UPDATE' then return; end if;
      if nvl(l_txn, '-') <> nvl(g_txn, '-') then
        g_txn := l_txn; g_seen.delete;
      end if;
      if g_seen.exists(l_key) then return; end if;
      g_seen(l_key) := true;
    end if;
    trade_core.audit(p_object_type, p_object_id, p_action, substr(p_details, 1, 4000));
  end log_write;

  procedure reset_txn is
  begin
    g_txn := null; g_seen.delete;
  end reset_txn;

  procedure install_triggers is
    l_doc  boolean; l_pres_new varchar2(400); l_pres_old varchar2(400); l_type varchar2(60); l_upd varchar2(200);
  begin
    for t in (select table_name from user_tables
               where table_name in (select upper(column_value) from table(sys.odcivarchar2list(
                       'DOC_GOODS_RECEIPT','DOC_SUPPLIER_PAYMENT','DOC_PRICE_SETTING','DOC_GOODS_SALE','DOC_CUSTOMER_PAYMENT',
                       'DOC_GOODS_TRANSFER','DOC_GOODS_WRITE_OFF','DOC_CUSTOMER_ORDER','DOC_SUPPLIER_ORDER','DOC_CUSTOMER_RETURN',
                       'DOC_SUPPLIER_RETURN','DOC_INVENTORY_COUNT','DOC_SURPLUS_POSTING','DOC_INVOICE_FOR_PAYMENT','DOC_CASH_RECEIPT',
                       'DOC_CASH_PAYMENT','DOC_BANK_STATEMENT','DOC_DEBT_ADJUSTMENT','DOC_ASSEMBLY',
                       'REF_UNIT_OF_MEASURE','REF_PRODUCT','REF_WAREHOUSE','REF_COUNTERPARTY','REF_PRICE_TYPE','REF_PRODUCT_GROUP',
                       'REF_CONTRACT','REF_ORGANIZATION','REF_CASH_DESK','REF_BANK_ACCOUNT','REF_BILL_OF_MATERIALS',
                       'REF_PRODUCT_CHARACTERISTIC','REF_PRODUCT_SERIES',  -- r5 F-NSI-10 (db/38)
                       'REF_DISCOUNT',  -- r5 F-PRC-06 (db/39)
                       'DOC_GOODS_RECEIPT_ORDER','DOC_GOODS_ISSUE_ORDER','REF_STORAGE_BIN',  -- r5 F-WH-11 (db/40)
                       'REF_CURRENCY',  -- r5 F-FIN-06 (db/41)
                       'DOC_TAX_INVOICE',  -- r5 F-TAX-01 (db/42)
                       'DOC_RETAIL_RECEIPT','REF_CASH_REGISTER',  -- r5 F-RET-01 (db/43)
                       'REF_DELIVERY_POINT')))  -- r7 F-INT-04 (db/47)
               order by table_name) loop
      l_doc := t.table_name like 'DOC\_%' escape '\';
      -- документи — тип реєстратора (DocGoodsReceipt), довідники — ім'я таблиці (як MARK_FOR_DELETION у trade_core)
      l_type := case when l_doc then camel(t.table_name) else t.table_name end;
      if l_doc then
        l_pres_new := q'['№ ' || :new.doc_number || ' від ' || to_char(:new.occurred_at, 'DD.MM.YYYY HH24:MI:SS')]';
        l_pres_old := q'['№ ' || :old.doc_number || ' від ' || to_char(:old.occurred_at, 'DD.MM.YYYY HH24:MI:SS')]';
        l_upd := 'not trade_core.g_internal';
      else
        l_pres_new := q'[:new.code || ' ' || :new.name]';
        l_pres_old := q'[:old.code || ' ' || :old.name]';
        l_upd := 'not trade_core.g_internal and :old.state = :new.state';
      end if;
      execute immediate 'create or replace trigger ' || substr(lower(t.table_name), 1, 100) || '_evlog' || chr(10)
        || 'after insert or update or delete on ' || lower(t.table_name) || ' for each row' || chr(10)
        || '-- r4 F-SRV-05 (db/37): журнал реєстрації — створення / зміна / видалення' || chr(10)
        || 'begin' || chr(10)
        || '  if inserting then' || chr(10)
        || '    trade_event_log.log_write(''' || l_type || ''', :new.id, ''CREATE'', ' || l_pres_new || ');' || chr(10)
        || '  elsif deleting then' || chr(10)
        || '    trade_event_log.log_write(''' || l_type || ''', :old.id, ''DELETE'', ' || l_pres_old || ');' || chr(10)
        || '  elsif ' || l_upd || ' then' || chr(10)
        || '    trade_event_log.log_write(''' || l_type || ''', :new.id, ''UPDATE'', ' || l_pres_new || ');' || chr(10)
        || '  end if;' || chr(10)
        || 'end;';
    end loop;
  end install_triggers;

end trade_event_log;
/
show errors package body trade_event_log

begin
  trade_event_log.install_triggers;
end;
/

-- ---------------------------------------------------------------- журнал з назвами й посиланнями
create or replace view v_event_log as
select l.id, l.occurred_at, l.user_name, l.object_type,
       trade_event_log.object_kind(l.object_type) object_kind,
       trade_event_log.object_type_name(l.object_type) object_type_name,
       l.object_id,
       coalesce(r.recorder_name, trade_event_log.object_name(l.object_type, l.object_id)) object_name,
       l.action,
       trade_event_log.event_name(l.action) event_name,
       trade_event_log.event_group(l.action) event_group,
       trade_event_log.event_group_name(trade_event_log.event_group(l.action)) event_group_name,
       l.details,
       case when r.recorder_id is not null then r.page_id
            else trade_event_log.link_page(l.object_type, l.object_id, l.action) end link_page,
       case when r.recorder_id is not null then 'P' || r.page_id || '_ID'
            else trade_event_log.link_item(l.object_type, l.object_id, l.action) end link_item
  from sys_audit_log l
  left join v_recorder r on r.recorder_type = l.object_type and r.recorder_id = l.object_id;

-- ---------------------------------------------------------------- меню: «НСІ та адміністрування → Сервіс»
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
  using (select 'EventLog' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Журнал реєстрації', o.list_page_id = 480, o.form_page_id = null, o.auth_scheme = 'Роль: адміністратор'
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('EventLog', 'REPORT', 'Журнал реєстрації', (select id from sys_main_menu_section where tech_name = 'Reports'), 480, null, 180, 'Роль: адміністратор');
  fp('Reference', 'Сервіс', 2, 90, 'EventLog', 10, 'Y');
  commit;
end;
/
