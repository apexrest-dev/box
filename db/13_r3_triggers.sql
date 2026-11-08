-- Згенеровано db/gen/gen_r3_triggers.py — не редагувати вручну.

create or replace trigger doc_customer_order_biud
before insert or update or delete on doc_customer_order for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_CUSTOMER_ORDER_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.customer_id <> :old.customer_id then
      trade_core.check_active_ref('REF_COUNTERPARTY', :new.customer_id, 'Покупець');
    end if;
    if inserting or :new.warehouse_id <> :old.warehouse_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
    end if;
    if :new.price_type_id is not null and (inserting or :new.price_type_id <> nvl(:old.price_type_id, '-')) then
      trade_core.check_active_ref('REF_PRICE_TYPE', :new.price_type_id, 'Вид цін');
    end if;
    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);
    if :new.shipment_date is not null and trunc(:new.shipment_date) < trunc(:new.occurred_at) then
      trade_nsi.fail('SHIPMENT_DATE_BEFORE_ORDER_DATE', 'Дата відвантаження не може бути раніше дати замовлення.');
    end if;
    if :new.price_type_id is null and :new.contract_id is not null then
      select price_type_id into :new.price_type_id from ref_contract where id = :new.contract_id;
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_customer_order_ad after delete on doc_customer_order
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_customer_order_goods_ct
for insert or update or delete on doc_customer_order_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_customer_order where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);
      if :new.price is null then
        select price_type_id, occurred_at into l_pt, l_dt from doc_customer_order where id = l_doc;
        if l_pt is null then
          trade_nsi.fail('PRICE_TYPE_REQUIRED', 'Вкажіть ціну або вид цін у шапці документа.');
        end if;
        :new.price := trade_lines.get_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_nsi.fail('PRICE_NOT_FOUND', 'Для товару не встановлено ціну обраного виду на дату документа.');
        end if;
      end if;
      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;
      if nvl(:new.discount_percent, 0) not between 0 and 100 then
        trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Знижка має бути від 0 до 100 %.');
      end if;
      :new.reserve_flag := nvl(:new.reserve_flag, 'N');
      if :new.reserve_flag = 'Y' and trade_nsi.is_service(:new.product_id) then
        trade_nsi.fail('RESERVE_SERVICE_PRODUCT', 'Послугу не можна резервувати.');
      end if;
      :new.amount := round(:new.quantity * :new.price * (1 - nvl(:new.discount_percent, 0) / 100), 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_CUSTOMER_ORDER_GOODS', l_doc);
      update doc_customer_order d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_customer_order_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_customer_order_goods_ct;
/

create or replace trigger doc_supplier_order_biud
before insert or update or delete on doc_supplier_order for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_SUPPLIER_ORDER_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
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

    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.supplier_id, 'WITH_SUPPLIER', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.supplier_id, 'WITH_SUPPLIER', :new.occurred_at);
    if :new.expected_date is not null and trunc(:new.expected_date) < trunc(:new.occurred_at) then
      trade_nsi.fail('EXPECTED_DATE_BEFORE_ORDER_DATE', 'Очікувана дата надходження не може бути раніше дати замовлення.');
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_supplier_order_ad after delete on doc_supplier_order
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_supplier_order_goods_ct
for insert or update or delete on doc_supplier_order_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_supplier_order where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);
      if :new.price is null then
        select supplier_id, occurred_at into l_pt, l_dt from doc_supplier_order where id = l_doc;
        :new.price := trade_lines.get_supplier_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_nsi.fail('PRICE_REQUIRED', 'Немає ціни постачальника для товару — вкажіть ціну вручну.');
        end if;
      end if;
      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;


      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_SUPPLIER_ORDER_GOODS', l_doc);
      update doc_supplier_order d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_supplier_order_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_supplier_order_goods_ct;
/

create or replace trigger doc_customer_return_biud
before insert or update or delete on doc_customer_return for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_CUSTOMER_RETURN_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.customer_id <> :old.customer_id then
      trade_core.check_active_ref('REF_COUNTERPARTY', :new.customer_id, 'Покупець');
    end if;
    if inserting or :new.warehouse_id <> :old.warehouse_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
    end if;

    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);

    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_customer_return_ad after delete on doc_customer_return
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_customer_return_goods_ct
for insert or update or delete on doc_customer_return_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_customer_return where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);

      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;


      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_CUSTOMER_RETURN_GOODS', l_doc);
      update doc_customer_return d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_customer_return_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_customer_return_goods_ct;
/

create or replace trigger doc_supplier_return_biud
before insert or update or delete on doc_supplier_return for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_SUPPLIER_RETURN_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
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

    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.supplier_id, 'WITH_SUPPLIER', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.supplier_id, 'WITH_SUPPLIER', :new.occurred_at);
    :new.return_reason := trade_core.normalize_name(:new.return_reason, 255, 'Причина повернення');
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_supplier_return_ad after delete on doc_supplier_return
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_supplier_return_goods_ct
for insert or update or delete on doc_supplier_return_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_supplier_return where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);

      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;


      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_SUPPLIER_RETURN_GOODS', l_doc);
      update doc_supplier_return d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_supplier_return_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_supplier_return_goods_ct;
/

create or replace trigger doc_inventory_count_biud
before insert or update or delete on doc_inventory_count for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_INVENTORY_COUNT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.surplus_amount := :old.surplus_amount;
        :new.shortage_amount := :old.shortage_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.warehouse_id <> :old.warehouse_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
    end if;



    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_inventory_count_ad after delete on doc_inventory_count
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_inventory_count_goods_ct
for insert or update or delete on doc_inventory_count_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_inventory_count where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, nvl(:new.actual_quantity, 1), inserting or :new.product_id <> :old.product_id, true);
      if :new.actual_quantity is not null and :new.actual_quantity < 0 then
        trade_nsi.fail('ACTUAL_QUANTITY_NEGATIVE', 'Фактична кількість не може бути від''ємною.');
      end if;
      :new.deviation := case when :new.actual_quantity is null then null else :new.actual_quantity - :new.book_quantity end;
      :new.deviation_amount := case when :new.deviation is null then null else round(:new.deviation * :new.price, 2) end;
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_INVENTORY_COUNT_GOODS', l_doc);
      update doc_inventory_count d
         set d.surplus_amount  = (select coalesce(sum(case when deviation_amount > 0 then deviation_amount end), 0) from doc_inventory_count_goods where document_id = l_doc),
             d.shortage_amount = (select coalesce(sum(case when deviation_amount < 0 then -deviation_amount end), 0) from doc_inventory_count_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_inventory_count_goods_ct;
/

create or replace trigger doc_surplus_posting_biud
before insert or update or delete on doc_surplus_posting for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_SURPLUS_POSTING_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.warehouse_id <> :old.warehouse_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
    end if;


    :new.reason := trade_core.normalize_name(:new.reason, 255, 'Причина оприбуткування');
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_surplus_posting_ad after delete on doc_surplus_posting
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_surplus_posting_goods_ct
for insert or update or delete on doc_surplus_posting_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_surplus_posting where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, true);

      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;


      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_SURPLUS_POSTING_GOODS', l_doc);
      update doc_surplus_posting d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_surplus_posting_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_surplus_posting_goods_ct;
/

create or replace trigger doc_invoice_for_payment_biud
before insert or update or delete on doc_invoice_for_payment for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_INVOICE_FOR_PAYMENT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.total_amount := :old.total_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.customer_id <> :old.customer_id then
      trade_core.check_active_ref('REF_COUNTERPARTY', :new.customer_id, 'Покупець');
    end if;

    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.customer_id, 'WITH_CUSTOMER', :new.occurred_at);
    if :new.payment_due_date is null then
      select trunc(:new.occurred_at) + coalesce(max(payment_term_days), 0) into :new.payment_due_date
        from ref_contract where id = :new.contract_id;
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_invoice_for_payment_ad after delete on doc_invoice_for_payment
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_invoice_for_payment_goods_ct
for insert or update or delete on doc_invoice_for_payment_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_invoice_for_payment where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);

      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;


      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_INVOICE_FOR_PAYMENT_GOODS', l_doc);
      update doc_invoice_for_payment d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_invoice_for_payment_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_invoice_for_payment_goods_ct;
/
