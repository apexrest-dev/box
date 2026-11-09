-- =============================================================================
-- Trade — серверна бізнес-логіка r1
--   trade_core : контекст, коди, аудит, обробка помилок APEX
--   trade_doc  : проведення / скасування / копіювання документів
-- Уся бізнес-логіка живе на сервері (ADR-0003): UI лише викликає команди.
-- =============================================================================

create or replace package trade_core as
  -- Прапорець службового запису (проведення, перерахунок підсумків).
  g_internal boolean := false;
  -- Видалення чернетки документа (каскад рядків не перевіряє шапку)
  g_deleting_doc boolean := false;

  function current_user_name return varchar2;
  function next_code (p_seq_name in varchar2) return varchar2;
  procedure check_code (p_code in varchar2);
  function normalize_name (p_value in varchar2, p_max in pls_integer, p_label in varchar2) return varchar2;
  procedure audit (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2, p_details in varchar2 default null);
  procedure fail (p_message in varchar2);

  -- Помітка на видалення / відновлення елемента довідника
  procedure mark_for_deletion (p_table in varchar2, p_id in varchar2);
  procedure restore (p_table in varchar2, p_id in varchar2);
  procedure check_active_ref (p_table in varchar2, p_id in varchar2, p_label in varchar2);

  -- Функція обробки помилок APEX: показує українське повідомлення без ORA-префікса
  function apex_error_handler (p_error in apex_error.t_error) return apex_error.t_error_result;
end trade_core;
/

create or replace package body trade_core as

  function current_user_name return varchar2 is
  begin
    return coalesce(sys_context('APEX$SESSION', 'APP_USER'), sys_context('USERENV', 'SESSION_USER'));
  end current_user_name;

  procedure fail (p_message in varchar2) is
  begin
    raise_application_error(-20100, p_message);
  end fail;

  function next_code (p_seq_name in varchar2) return varchar2 is
    l_val number;
  begin
    execute immediate 'select ' || dbms_assert.simple_sql_name(p_seq_name) || '.nextval from dual' into l_val;
    return lpad(to_char(l_val), 9, '0');
  end next_code;

  procedure check_code (p_code in varchar2) is
  begin
    if p_code is null or length(p_code) > 9 then
      fail('Код має містити від 1 до 9 символів.');
    end if;
  end check_code;

  function normalize_name (p_value in varchar2, p_max in pls_integer, p_label in varchar2) return varchar2 is
    l_val varchar2(4000) := trim(p_value);
  begin
    if l_val is null then
      fail('Поле «' || p_label || '» обов''язкове для заповнення.');
    elsif length(l_val) > p_max then
      fail('Поле «' || p_label || '» не може бути довшим за ' || p_max || ' символів.');
    end if;
    return l_val;
  end normalize_name;

  procedure audit (p_object_type in varchar2, p_object_id in varchar2, p_action in varchar2, p_details in varchar2 default null) is
  begin
    insert into sys_audit_log (user_name, object_type, object_id, action, details)
    values (current_user_name, p_object_type, p_object_id, p_action, p_details);
  end audit;

  function catalog_table (p_table in varchar2) return varchar2 is
  begin
    if upper(p_table) not in ('REF_UNIT_OF_MEASURE','REF_PRODUCT','REF_WAREHOUSE','REF_COUNTERPARTY','REF_PRICE_TYPE','REF_PRODUCT_GROUP','REF_CONTRACT','REF_ORGANIZATION','REF_CASH_DESK','REF_BANK_ACCOUNT','REF_BILL_OF_MATERIALS','REF_PRODUCT_CHARACTERISTIC','REF_PRODUCT_SERIES','REF_DISCOUNT','REF_STORAGE_BIN','REF_CURRENCY','REF_CASH_REGISTER','REF_DELIVERY_POINT') then
      fail('Невідомий довідник ' || p_table);
    end if;
    return upper(p_table);
  end catalog_table;

  procedure set_state (p_table in varchar2, p_id in varchar2, p_state in varchar2) is
    l_tab varchar2(60) := catalog_table(p_table);
  begin
    execute immediate 'update ' || l_tab || ' set state = :s where id = :i' using p_state, p_id;
    if sql%rowcount = 0 then
      fail('Елемент не знайдено.');
    end if;
    audit(l_tab, p_id, case p_state when 'ACTIVE' then 'RESTORE' else 'MARK_FOR_DELETION' end);
  end set_state;

  procedure mark_for_deletion (p_table in varchar2, p_id in varchar2) is
  begin
    set_state(p_table, p_id, 'MARKED_FOR_DELETION');
  end mark_for_deletion;

  procedure restore (p_table in varchar2, p_id in varchar2) is
  begin
    set_state(p_table, p_id, 'ACTIVE');
  end restore;

  procedure check_active_ref (p_table in varchar2, p_id in varchar2, p_label in varchar2) is
    l_state varchar2(30);
  begin
    if p_id is null then
      fail('Поле «' || p_label || '» обов''язкове для заповнення.');
    end if;
    execute immediate 'select max(state) from ' || catalog_table(p_table) || ' where id = :i' into l_state using p_id;
    if l_state is null then
      fail('Вибране значення поля «' || p_label || '» не існує.');
    elsif l_state <> 'ACTIVE' then
      fail('Значення поля «' || p_label || '» помічене на видалення і не може бути вибране.');
    end if;
  end check_active_ref;

  function apex_error_handler (p_error in apex_error.t_error) return apex_error.t_error_result is
    l_result apex_error.t_error_result;
    l_constraint varchar2(255);
  begin
    l_result := apex_error.init_error_result(p_error => p_error);
    if p_error.ora_sqlcode between -20999 and -20000 then
      -- '[CODE] текст' → у UI лише текст (код лишається в API та журналі)
      l_result.message := regexp_replace(apex_error.get_first_ora_error_text(p_error => p_error), '^\[[A-Z0-9_]+\] ');
      l_result.additional_info := null;
    elsif p_error.ora_sqlcode in (-1, -2091, -2290, -2291, -2292) then
      l_constraint := apex_error.extract_constraint_name(p_error => p_error);
      l_result.message := case
        when l_constraint like '%CODE_UK' then 'Елемент з таким кодом уже існує.'
        when l_constraint like '%NUM_UK'  then 'Документ з таким номером уже існує.'
        when l_constraint like '%QTY_CK'  then 'Кількість має бути більшою за нуль.'
        when l_constraint like '%PRC_CK'  then 'Ціна не може бути від''ємною.'
        when l_constraint like '%AMT_CK'  then 'Сума має бути більшою за нуль.'
        when l_constraint like '%IBAN_UK' then 'Банківський рахунок з таким IBAN уже існує.'
        when p_error.ora_sqlcode = -2292 then 'Елемент використовується в інших об''єктах.'
        else l_result.message end;
      l_result.additional_info := null;
    end if;
    return l_result;
  end apex_error_handler;

end trade_core;
/

-- ---------------------------------------------------------------------------
-- Тригери довідників: код, нормалізація, версія, аудит, заборона видалення
-- ---------------------------------------------------------------------------
create or replace trigger ref_unit_of_measure_biu
before insert or update on ref_unit_of_measure for each row
begin
  if inserting then
    :new.code       := coalesce(trim(:new.code), trade_core.next_code('REF_UNIT_OF_MEASURE_CODE_SEQ'));
    :new.version    := 0;
    :new.state      := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp;
    :new.created_by := trade_core.current_user_name;
  else
    :new.version    := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name       := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.short_name := trade_core.normalize_name(:new.short_name, 20, 'Скорочене найменування');
  :new.fractional := coalesce(:new.fractional, 'N');
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

create or replace trigger ref_product_biu
before insert or update on ref_product for each row
begin
  if inserting then
    :new.code       := coalesce(trim(:new.code), trade_core.next_code('REF_PRODUCT_CODE_SEQ'));
    :new.version    := 0;
    :new.state      := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp;
    :new.created_by := trade_core.current_user_name;
  else
    :new.version    := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  if inserting or :new.unit_of_measure_id <> :old.unit_of_measure_id then
    trade_core.check_active_ref('REF_UNIT_OF_MEASURE', :new.unit_of_measure_id, 'Одиниця виміру');
  end if;
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

create or replace trigger ref_warehouse_biu
before insert or update on ref_warehouse for each row
begin
  if inserting then
    :new.code       := coalesce(trim(:new.code), trade_core.next_code('REF_WAREHOUSE_CODE_SEQ'));
    :new.version    := 0;
    :new.state      := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp;
    :new.created_by := trade_core.current_user_name;
  else
    :new.version    := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

create or replace trigger ref_counterparty_biu
before insert or update on ref_counterparty for each row
begin
  if inserting then
    :new.code       := coalesce(trim(:new.code), trade_core.next_code('REF_COUNTERPARTY_CODE_SEQ'));
    :new.version    := 0;
    :new.state      := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp;
    :new.created_by := trade_core.current_user_name;
  else
    :new.version    := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

-- Вид видалення MARK_FOR_DELETION: фізичне видалення заборонене
create or replace trigger ref_unit_of_measure_bd before delete on ref_unit_of_measure
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/
create or replace trigger ref_product_bd before delete on ref_product
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/
create or replace trigger ref_warehouse_bd before delete on ref_warehouse
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/
create or replace trigger ref_counterparty_bd before delete on ref_counterparty
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------------------
-- Тригери документів
-- ---------------------------------------------------------------------------
create or replace trigger doc_goods_receipt_biud
before insert or update or delete on doc_goods_receipt for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
    return;
  end if;
  if inserting then
    :new.doc_number    := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_GOODS_RECEIPT_NUM_SEQ'));
    :new.status        := 'DRAFT';
    :new.total_amount  := 0;
    :new.version       := 0;
    :new.currency_code := 'UAH';
    :new.occurred_at   := coalesce(:new.occurred_at, sysdate);
    :new.created_at    := systimestamp;
    :new.created_by    := trade_core.current_user_name;
  else
    if not trade_core.g_internal then
      if :old.status = 'POSTED' then
        trade_core.fail('Документ проведено: шапка і рядки доступні лише для читання. Скасуйте проведення для зміни.');
      end if;
      :new.status       := :old.status;       -- статус змінюється лише командами
      :new.total_amount := :old.total_amount; -- підсумок лише розрахунковий
    end if;
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.doc_number);
  if inserting or :new.supplier_id <> :old.supplier_id then
    trade_core.check_active_ref('REF_COUNTERPARTY', :new.supplier_id, 'Постачальник');
  end if;
  if inserting or :new.warehouse_id <> :old.warehouse_id then
    trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
  end if;
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

create or replace trigger doc_goods_receipt_ad
after delete on doc_goods_receipt
begin
  trade_core.g_deleting_doc := false;
end;
/

-- Рядки: розрахунок суми, дробність, заборона змін у проведеному документі,
-- перерахунок підсумку документа після оператора.
create or replace trigger doc_goods_receipt_goods_ct
for insert or update or delete on doc_goods_receipt_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;

  before each row is
    l_status     varchar2(10);
    l_fractional varchar2(1);
    l_doc        varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    -- каскад від видалення чернетки не перевіряє шапку
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_status from doc_goods_receipt where id = l_doc;
      if l_status = 'POSTED' and not trade_core.g_internal then
        trade_core.fail('Документ проведено: рядки доступні лише для читання. Скасуйте проведення для зміни.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if inserting or :new.product_id <> :old.product_id then
        trade_core.check_active_ref('REF_PRODUCT', :new.product_id, 'Товар');
      end if;
      if :new.quantity is null or :new.quantity <= 0 then
        trade_core.fail('Кількість має бути більшою за нуль.');
      end if;
      if :new.price is null or :new.price < 0 then
        trade_core.fail('Ціна не може бути від''ємною.');
      end if;
      select u.fractional into l_fractional
        from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id
       where p.id = :new.product_id;
      if l_fractional = 'N' and :new.quantity <> trunc(:new.quantity) then
        trade_core.fail('Одиниця виміру товару не дозволяє дробову кількість.');
      end if;
      :new.amount := round(:new.quantity * :new.price, 2);  -- HALF_UP, scale 2
    end if;
  end before each row;

  after statement is
    l_doc varchar2(32);
    l_prev boolean := trade_core.g_internal;
  begin
    l_doc := g_docs.first;
    trade_core.g_internal := true;
    while l_doc is not null loop
      -- Перенумерація рядків за порядком і перерахунок підсумку
      merge into doc_goods_receipt_goods t
      using (select id, row_number() over (order by line_number, id) rn
               from doc_goods_receipt_goods where document_id = l_doc) s
         on (t.id = s.id)
       when matched then update set t.line_number = s.rn where t.line_number <> s.rn;
      update doc_goods_receipt d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_goods_receipt_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev;
    g_docs.delete;
  exception when others then
    trade_core.g_internal := l_prev;
    g_docs.delete;
    raise;
  end after statement;
end doc_goods_receipt_goods_ct;
/

create or replace trigger doc_supplier_payment_biud
before insert or update or delete on doc_supplier_payment for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    return;
  end if;
  if inserting then
    :new.doc_number    := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_SUPPLIER_PAYMENT_NUM_SEQ'));
    :new.status        := 'DRAFT';
    :new.version       := 0;
    :new.currency_code := 'UAH';
    :new.occurred_at   := coalesce(:new.occurred_at, sysdate);
    :new.created_at    := systimestamp;
    :new.created_by    := trade_core.current_user_name;
  else
    if not trade_core.g_internal then
      if :old.status = 'POSTED' then
        trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
      end if;
      :new.status := :old.status;
    end if;
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.doc_number);
  if :new.amount is null or :new.amount <= 0 then
    trade_core.fail('Сума оплати має бути більшою за нуль.');
  end if;
  if inserting or :new.supplier_id <> :old.supplier_id then
    trade_core.check_active_ref('REF_COUNTERPARTY', :new.supplier_id, 'Постачальник');
  end if;
  :new.updated_at := systimestamp;
  :new.updated_by := trade_core.current_user_name;
end;
/

-- Рухи регістрів пишуться тільки проведенням
create or replace trigger reg_stock_balance_mv_biud
before insert or update or delete on reg_stock_balance_movement
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/
create or replace trigger reg_cp_settlement_mv_biud
before insert or update or delete on reg_counterparty_settlement_mv
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/

-- ---------------------------------------------------------------------------
-- Проведення документів
-- ---------------------------------------------------------------------------
create or replace package trade_doc as
  c_goods_receipt    constant varchar2(60) := 'DocGoodsReceipt';
  c_supplier_payment constant varchar2(60) := 'DocSupplierPayment';

  procedure post_goods_receipt   (p_id in varchar2);
  procedure unpost_goods_receipt (p_id in varchar2);
  function  copy_goods_receipt   (p_id in varchar2) return varchar2;

  procedure post_supplier_payment   (p_id in varchar2);
  procedure unpost_supplier_payment (p_id in varchar2);
  function  copy_supplier_payment   (p_id in varchar2) return varchar2;
end trade_doc;
/

create or replace package body trade_doc as

  procedure begin_internal is begin trade_core.g_internal := true; end;
  procedure end_internal   is begin trade_core.g_internal := false; end;

  -- Від'ємний залишок «Товари на складах» заборонений
  procedure check_stock (p_recorder_id in varchar2, p_warehouse_id in varchar2) is
  begin
    -- r3: вільний залишок (залишок − резерви) не може бути від'ємним
    trade_r3.check_free_stock_doc('DOC_GOODS_RECEIPT_GOODS', p_recorder_id, p_warehouse_id);
  end check_stock;

  -- Від'ємний залишок «Взаєморозрахунки» заборонений
  procedure check_settlement (p_counterparty_id in varchar2) is
    l_balance number;
  begin
    select coalesce(sum(amount), 0) into l_balance
      from reg_counterparty_settlement_mv
     where counterparty_id = p_counterparty_id and direction = 'PAYABLE' and currency_code = 'UAH';
    if l_balance < 0 then
      trade_core.fail('Операція призведе до переплати постачальнику. Заборгованість після операції: '
                      || to_char(l_balance, 'FM999G999G999G990D00') || ' UAH.');
    end if;
  end check_settlement;

  procedure delete_movements (p_type in varchar2, p_id in varchar2) is
  begin
    delete from reg_stock_balance_movement     where recorder_type = p_type and recorder_id = p_id;
    delete from reg_counterparty_settlement_mv where recorder_type = p_type and recorder_id = p_id;
    trade_r3.delete_r3_movements(p_type, p_id);
  end delete_movements;

  -- --------------------------------------------------------------- GoodsReceipt
  procedure post_goods_receipt (p_id in varchar2) is
    l_doc   doc_goods_receipt%rowtype;
    l_lines pls_integer;
    l_dummy varchar2(32);
  begin
    select * into l_doc from doc_goods_receipt where id = p_id for update;
    select count(*) into l_lines from doc_goods_receipt_goods where document_id = p_id;
    if l_lines = 0 then
      trade_core.fail('Неможливо провести документ без рядків у табличній частині «Товари».');
    end if;
    -- Серіалізація за ключами регістрів
    select id into l_dummy from ref_counterparty where id = l_doc.supplier_id for update;
    select id into l_dummy from ref_warehouse    where id = l_doc.warehouse_id for update;

    begin_internal;
    delete_movements(c_goods_receipt, p_id);   -- повторне проведення замінює набір

    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select l_doc.occurred_at, c_goods_receipt, p_id, g.line_number, l_doc.warehouse_id, g.product_id, g.quantity
      from doc_goods_receipt_goods g join ref_product p on p.id = g.product_id
     where g.document_id = p_id and p.product_kind = 'GOODS';   -- r3: послуги не рухають склад

    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (l_doc.occurred_at, c_goods_receipt, p_id, 1, l_doc.supplier_id, 'PAYABLE', l_doc.currency_code, l_doc.total_amount);
    trade_r3.hook_post_receipt(p_id);   -- r3: собівартість, ціни постачальника, замовлення

    update doc_goods_receipt set status = 'POSTED' where id = p_id;
    end_internal;
    trade_core.audit(c_goods_receipt, p_id, 'POST', 'Сума ' || l_doc.total_amount);
  exception when others then
    end_internal;
    raise;
  end post_goods_receipt;

  procedure unpost_goods_receipt (p_id in varchar2) is
    l_doc   doc_goods_receipt%rowtype;
    l_dummy varchar2(32);
  begin
    select * into l_doc from doc_goods_receipt where id = p_id for update;
    if l_doc.status <> 'POSTED' then
      trade_core.fail('Документ не проведено.');
    end if;
    select id into l_dummy from ref_counterparty where id = l_doc.supplier_id for update;
    select id into l_dummy from ref_warehouse    where id = l_doc.warehouse_id for update;

    begin_internal;
    trade_r3.hook_unpost_receipt(p_id);
    delete_movements(c_goods_receipt, p_id);
    check_stock(p_id, l_doc.warehouse_id);
    check_settlement(l_doc.supplier_id);
    update doc_goods_receipt set status = 'DRAFT' where id = p_id;
    end_internal;
    trade_core.audit(c_goods_receipt, p_id, 'UNPOST');
  exception when others then
    end_internal;
    raise;
  end unpost_goods_receipt;

  function copy_goods_receipt (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_goods_receipt (id, occurred_at, supplier_id, warehouse_id, currency_code, doc_comment)
    select l_new, sysdate, supplier_id, warehouse_id, currency_code, doc_comment
      from doc_goods_receipt where id = p_id;
    insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount)
    select l_new, line_number, product_id, quantity, price, 0
      from doc_goods_receipt_goods where document_id = p_id;
    trade_core.audit(c_goods_receipt, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_goods_receipt;

  -- ------------------------------------------------------------ SupplierPayment
  -- r4 F-PUR-05 (db/31): оплата рухає кошти (каса / рахунок) — проведення в trade_pay_doc.
  -- До встановлення db/31 (початкове розгортання, демо r1–r3) — логіка r1 нижче.
  function pay_doc_installed return boolean is
    n number;
  begin
    select count(*) into n from user_objects where object_name = 'TRADE_PAY_DOC' and object_type = 'PACKAGE BODY';
    return n > 0;
  end pay_doc_installed;

  procedure post_supplier_payment (p_id in varchar2) is
    l_doc   doc_supplier_payment%rowtype;
    l_dummy varchar2(32);
  begin
    if pay_doc_installed then
      execute immediate 'begin trade_pay_doc.post_supplier_payment(:i); end;' using p_id;
      return;
    end if;
    select * into l_doc from doc_supplier_payment where id = p_id for update;
    trade_core.check_active_ref('REF_COUNTERPARTY', l_doc.supplier_id, 'Постачальник');
    select id into l_dummy from ref_counterparty where id = l_doc.supplier_id for update;

    begin_internal;
    delete_movements(c_supplier_payment, p_id);
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (l_doc.occurred_at, c_supplier_payment, p_id, 1, l_doc.supplier_id, 'PAYABLE', l_doc.currency_code, -l_doc.amount);
    check_settlement(l_doc.supplier_id);
    update doc_supplier_payment set status = 'POSTED' where id = p_id;
    end_internal;
    trade_core.audit(c_supplier_payment, p_id, 'POST', 'Сума ' || l_doc.amount);
  exception when others then
    end_internal;
    raise;
  end post_supplier_payment;

  procedure unpost_supplier_payment (p_id in varchar2) is
    l_doc doc_supplier_payment%rowtype;
  begin
    if pay_doc_installed then
      execute immediate 'begin trade_pay_doc.unpost_supplier_payment(:i); end;' using p_id;
      return;
    end if;
    select * into l_doc from doc_supplier_payment where id = p_id for update;
    if l_doc.status <> 'POSTED' then
      trade_core.fail('Документ не проведено.');
    end if;
    begin_internal;
    delete_movements(c_supplier_payment, p_id);
    update doc_supplier_payment set status = 'DRAFT' where id = p_id;
    end_internal;
    trade_core.audit(c_supplier_payment, p_id, 'UNPOST');
  exception when others then
    end_internal;
    raise;
  end unpost_supplier_payment;

  function copy_supplier_payment (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    if pay_doc_installed then
      execute immediate 'begin :n := trade_pay_doc.copy_supplier_payment(:i); end;' using out l_new, p_id;
      return l_new;
    end if;
    insert into doc_supplier_payment (id, occurred_at, supplier_id, currency_code, amount, doc_comment)
    select l_new, sysdate, supplier_id, currency_code, amount, doc_comment
      from doc_supplier_payment where id = p_id;
    trade_core.audit(c_supplier_payment, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_supplier_payment;

end trade_doc;
/
