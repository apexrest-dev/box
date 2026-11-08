-- =============================================================================
-- Trade r2 — серверна логіка: тригери й пакет проведення trade_ops
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Спільні перевірки рядків табличних частин
-- ---------------------------------------------------------------------------
create or replace package trade_lines as
  -- Шапка редагована? (у POSTED — лише службовий запис)
  procedure check_editable (p_header_table in varchar2, p_doc_id in varchar2);
  -- Товар активний, кількість > 0 і відповідає дробності одиниці виміру
  procedure check_goods (p_product_id in varchar2, p_quantity in number, p_check_ref in boolean);
  -- Перенумерація рядків за порядком
  procedure renumber (p_lines_table in varchar2, p_doc_id in varchar2);
  -- Ціна з регістру «Ціни номенклатури» (зріз останніх на дату)
  function get_price (p_price_type_id in varchar2, p_product_id in varchar2, p_date in date) return number;
  -- r3: перевірка рядка з урахуванням виду номенклатури (послуги)
  procedure check_goods_r3 (p_product_id in varchar2, p_quantity in number, p_check_ref in boolean, p_goods_only in boolean);
  -- r3: ціна постачальника (зріз останніх RegSupplierPrice)
  function get_supplier_price (p_supplier_id in varchar2, p_product_id in varchar2, p_date in date) return number;
end trade_lines;
/

create or replace package body trade_lines as

  procedure check_editable (p_header_table in varchar2, p_doc_id in varchar2) is
    l_status varchar2(10);
  begin
    execute immediate 'select status from ' || dbms_assert.simple_sql_name(p_header_table) || ' where id = :i'
      into l_status using p_doc_id;
    if l_status = 'POSTED' and not trade_core.g_internal then
      trade_core.fail('Документ проведено: рядки доступні лише для читання. Скасуйте проведення для зміни.');
    end if;
  end check_editable;

  procedure check_goods (p_product_id in varchar2, p_quantity in number, p_check_ref in boolean) is
    l_fractional varchar2(1);
  begin
    if p_check_ref then
      trade_core.check_active_ref('REF_PRODUCT', p_product_id, 'Товар');
    end if;
    if p_quantity is null or p_quantity <= 0 then
      trade_core.fail('Кількість має бути більшою за нуль.');
    end if;
    select u.fractional into l_fractional
      from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id
     where p.id = p_product_id;
    if l_fractional = 'N' and p_quantity <> trunc(p_quantity) then
      trade_core.fail('Одиниця виміру товару не дозволяє дробову кількість.');
    end if;
  end check_goods;

  procedure renumber (p_lines_table in varchar2, p_doc_id in varchar2) is
    l_tab varchar2(128) := dbms_assert.simple_sql_name(p_lines_table);
  begin
    execute immediate
      'merge into ' || l_tab || ' t
       using (select id, row_number() over (order by line_number, id) rn from ' || l_tab || ' where document_id = :d) s
          on (t.id = s.id)
        when matched then update set t.line_number = s.rn where t.line_number <> s.rn' using p_doc_id;
  end renumber;

  function get_price (p_price_type_id in varchar2, p_product_id in varchar2, p_date in date) return number is
    l_price number;
  begin
    select max(price) keep (dense_rank last order by period, id)
      into l_price
      from reg_product_price
     where price_type_id = p_price_type_id
       and product_id = p_product_id
       and period <= p_date;
    return l_price;
  end get_price;

  procedure check_goods_r3 (p_product_id in varchar2, p_quantity in number, p_check_ref in boolean, p_goods_only in boolean) is
    l_kind varchar2(10);
  begin
    if p_check_ref then
      trade_core.check_active_ref('REF_PRODUCT', p_product_id, 'Товар');
    end if;
    execute immediate 'select product_kind from ref_product where id = :i' into l_kind using p_product_id;
    if l_kind = 'SERVICE' and p_goods_only then
      trade_core.fail('[PRODUCT_SERVICE_NOT_ALLOWED] Послуги не можна вказувати в цьому документі.');
    end if;
    check_goods(p_product_id, p_quantity, false);
  end check_goods_r3;

  function get_supplier_price (p_supplier_id in varchar2, p_product_id in varchar2, p_date in date) return number is
    l_price number;
  begin
    execute immediate
      'select max(price) keep (dense_rank last order by period, id) from reg_supplier_price
        where supplier_id = :s and product_id = :p and period <= :d'
      into l_price using p_supplier_id, p_product_id, p_date;
    return l_price;
  end get_supplier_price;

end trade_lines;
/

-- ---------------------------------------------------------------------------
-- Довідник «Види цін»
-- ---------------------------------------------------------------------------
create or replace trigger ref_price_type_biu
before insert or update on ref_price_type for each row
begin
  if inserting then
    :new.code       := coalesce(trim(:new.code), trade_core.next_code('REF_PRICE_TYPE_CODE_SEQ'));
    :new.version    := 0;
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
create or replace trigger ref_price_type_bd before delete on ref_price_type
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------------------
-- Шапки документів r2
-- ---------------------------------------------------------------------------
create or replace trigger doc_price_setting_biud
before insert or update or delete on doc_price_setting for each row
begin
  if deleting then
    if :old.status = 'POSTED' then trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.'); end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_PRICE_SETTING_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.'); end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.price_type_id <> :old.price_type_id then
      trade_core.check_active_ref('REF_PRICE_TYPE', :new.price_type_id, 'Вид цін');
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

create or replace trigger doc_goods_sale_biud
before insert or update or delete on doc_goods_sale for each row
begin
  if deleting then
    if :old.status = 'POSTED' then trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.'); end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_GOODS_SALE_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0; :new.total_amount := 0; :new.currency_code := 'UAH';
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.'); end if;
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
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

create or replace trigger doc_customer_payment_biud
before insert or update or delete on doc_customer_payment for each row
begin
  if deleting then
    if :old.status = 'POSTED' then trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.'); end if;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_CUSTOMER_PAYMENT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0; :new.currency_code := 'UAH';
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.'); end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if :new.amount is null or :new.amount <= 0 then trade_core.fail('Сума оплати має бути більшою за нуль.'); end if;
    if inserting or :new.customer_id <> :old.customer_id then
      trade_core.check_active_ref('REF_COUNTERPARTY', :new.customer_id, 'Покупець');
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

create or replace trigger doc_goods_transfer_biud
before insert or update or delete on doc_goods_transfer for each row
begin
  if deleting then
    if :old.status = 'POSTED' then trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.'); end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_GOODS_TRANSFER_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.'); end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if :new.warehouse_from_id = :new.warehouse_to_id then
      trade_core.fail('Склад-відправник і склад-отримувач мають відрізнятися.');
    end if;
    if inserting or :new.warehouse_from_id <> :old.warehouse_from_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_from_id, 'Склад-відправник');
    end if;
    if inserting or :new.warehouse_to_id <> :old.warehouse_to_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_to_id, 'Склад-отримувач');
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

create or replace trigger doc_goods_write_off_biud
before insert or update or delete on doc_goods_write_off for each row
begin
  if deleting then
    if :old.status = 'POSTED' then trade_core.fail('Проведений документ не можна видалити. Спочатку скасуйте проведення.'); end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_GOODS_WRITE_OFF_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then trade_core.fail('Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.'); end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    :new.reason := trade_core.normalize_name(:new.reason, 255, 'Причина списання');
    if inserting or :new.warehouse_id <> :old.warehouse_id then
      trade_core.check_active_ref('REF_WAREHOUSE', :new.warehouse_id, 'Склад');
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

-- Скидання прапорця каскадного видалення рядків
create or replace trigger doc_price_setting_ad after delete on doc_price_setting
begin trade_core.g_deleting_doc := false; end;
/
create or replace trigger doc_goods_sale_ad after delete on doc_goods_sale
begin trade_core.g_deleting_doc := false; end;
/
create or replace trigger doc_goods_transfer_ad after delete on doc_goods_transfer
begin trade_core.g_deleting_doc := false; end;
/
create or replace trigger doc_goods_write_off_ad after delete on doc_goods_write_off
begin trade_core.g_deleting_doc := false; end;
/

-- ---------------------------------------------------------------------------
-- Табличні частини r2
-- ---------------------------------------------------------------------------
create or replace trigger doc_price_setting_prices_ct
for insert or update or delete on doc_price_setting_prices
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_PRICE_SETTING', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if inserting or :new.product_id <> :old.product_id then
        trade_core.check_active_ref('REF_PRODUCT', :new.product_id, 'Товар');
      end if;
      if :new.price is null or :new.price < 0 then
        trade_core.fail('Ціна не може бути порожньою або від''ємною.');
      end if;
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_PRICE_SETTING_PRICES', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_price_setting_prices_ct;
/

create or replace trigger doc_goods_sale_goods_ct
for insert or update or delete on doc_goods_sale_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_GOODS_SALE', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id);
      if :new.price is null or (updating and :new.product_id <> :old.product_id and :new.price = :old.price) then
        -- Автопідстановка ціни з регістру «Ціни номенклатури»
        select price_type_id, occurred_at into l_pt, l_dt from doc_goods_sale where id = l_doc;
        if l_pt is null then
          trade_core.fail('Вкажіть ціну або вид цін у шапці документа.');
        end if;
        :new.price := trade_lines.get_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_core.fail('Для товару не встановлено ціну обраного виду на дату документа.');
        end if;
      end if;
      if :new.price < 0 then
        trade_core.fail('Ціна не може бути від''ємною.');
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
      trade_lines.renumber('DOC_GOODS_SALE_GOODS', l_doc);
      update doc_goods_sale d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_goods_sale_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_goods_sale_goods_ct;
/

create or replace trigger doc_goods_transfer_goods_ct
for insert or update or delete on doc_goods_transfer_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_GOODS_TRANSFER', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, true);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_GOODS_TRANSFER_GOODS', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_goods_transfer_goods_ct;
/

create or replace trigger doc_goods_write_off_goods_ct
for insert or update or delete on doc_goods_write_off_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_GOODS_WRITE_OFF', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, true);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_GOODS_WRITE_OFF_GOODS', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_goods_write_off_goods_ct;
/

-- Нові регістри пишуться тільки проведенням
create or replace trigger reg_product_price_biud
before insert or update or delete on reg_product_price
begin
  if not trade_core.g_internal then trade_core.fail('Записи регістру формуються лише проведенням документів.'); end if;
end;
/
create or replace trigger reg_sales_turnover_biud
before insert or update or delete on reg_sales_turnover
begin
  if not trade_core.g_internal then trade_core.fail('Записи регістру формуються лише проведенням документів.'); end if;
end;
/

-- ---------------------------------------------------------------------------
-- Проведення документів r2
-- ---------------------------------------------------------------------------
create or replace package trade_ops as
  c_price_setting    constant varchar2(60) := 'DocPriceSetting';
  c_goods_sale       constant varchar2(60) := 'DocGoodsSale';
  c_customer_payment constant varchar2(60) := 'DocCustomerPayment';
  c_goods_transfer   constant varchar2(60) := 'DocGoodsTransfer';
  c_goods_write_off  constant varchar2(60) := 'DocGoodsWriteOff';

  procedure post_price_setting   (p_id in varchar2);
  procedure unpost_price_setting (p_id in varchar2);
  function  copy_price_setting   (p_id in varchar2) return varchar2;

  procedure post_goods_sale   (p_id in varchar2);
  procedure unpost_goods_sale (p_id in varchar2);
  function  copy_goods_sale   (p_id in varchar2) return varchar2;

  procedure post_customer_payment   (p_id in varchar2);
  procedure unpost_customer_payment (p_id in varchar2);
  function  copy_customer_payment   (p_id in varchar2) return varchar2;

  procedure post_goods_transfer   (p_id in varchar2);
  procedure unpost_goods_transfer (p_id in varchar2);
  function  copy_goods_transfer   (p_id in varchar2) return varchar2;

  procedure post_goods_write_off   (p_id in varchar2);
  procedure unpost_goods_write_off (p_id in varchar2);
  function  copy_goods_write_off   (p_id in varchar2) return varchar2;
end trade_ops;
/

create or replace package body trade_ops as

  subtype t_ids is sys.odcivarchar2list;

  procedure delete_movements (p_type in varchar2, p_id in varchar2) is
  begin
    delete from reg_stock_balance_movement     where recorder_type = p_type and recorder_id = p_id;
    delete from reg_counterparty_settlement_mv where recorder_type = p_type and recorder_id = p_id;
    delete from reg_sales_turnover             where recorder_type = p_type and recorder_id = p_id;
    delete from reg_product_price              where recorder_type = p_type and recorder_id = p_id;
    trade_r3.delete_r3_movements(p_type, p_id);
  end delete_movements;

  procedure lock_warehouse (p_id in varchar2) is
    l_dummy varchar2(32);
  begin
    select id into l_dummy from ref_warehouse where id = p_id for update;
  end lock_warehouse;

  procedure lock_counterparty (p_id in varchar2) is
    l_dummy varchar2(32);
  begin
    select id into l_dummy from ref_counterparty where id = p_id for update;
  end lock_counterparty;

  -- Від'ємний залишок «Товари на складах» заборонений
  procedure check_stock (p_warehouse_id in varchar2, p_products in t_ids) is
  begin
    -- r3: вільний залишок (залишок − резерви); послуги не перевіряються
    for i in 1 .. p_products.count loop
      if not trade_nsi.is_service(p_products(i)) then
        trade_r3.check_free_stock(p_warehouse_id, p_products(i));
      end if;
    end loop;
  end check_stock;

  -- Від'ємний залишок «Взаєморозрахунки» заборонений
  procedure check_settlement (p_counterparty_id in varchar2, p_direction in varchar2) is
    l_balance number;
  begin
    select coalesce(sum(amount), 0) into l_balance
      from reg_counterparty_settlement_mv
     where counterparty_id = p_counterparty_id and direction = p_direction and currency_code = 'UAH';
    if l_balance < 0 then
      trade_core.fail(case p_direction
                        when 'RECEIVABLE' then 'Операція призведе до переплати покупця. Заборгованість покупця після операції: '
                        else 'Операція призведе до переплати постачальнику. Заборгованість після операції: ' end
                      || to_char(l_balance, 'FM999G999G999G990D00') || ' UAH.');
    end if;
  end check_settlement;

  function lines_products (p_lines_table in varchar2, p_doc_id in varchar2) return t_ids is
    l_ids t_ids;
  begin
    execute immediate 'select distinct product_id from ' || dbms_assert.simple_sql_name(p_lines_table)
                      || ' where document_id = :d' bulk collect into l_ids using p_doc_id;
    return l_ids;
  end lines_products;

  procedure require_lines (p_lines_table in varchar2, p_doc_id in varchar2, p_tab_name in varchar2) is
    l_cnt pls_integer;
  begin
    execute immediate 'select count(*) from ' || dbms_assert.simple_sql_name(p_lines_table)
                      || ' where document_id = :d' into l_cnt using p_doc_id;
    if l_cnt = 0 then
      trade_core.fail('Неможливо провести документ без рядків у табличній частині «' || p_tab_name || '».');
    end if;
  end require_lines;

  procedure set_status (p_table in varchar2, p_id in varchar2, p_status in varchar2) is
  begin
    execute immediate 'update ' || dbms_assert.simple_sql_name(p_table) || ' set status = :s where id = :i'
      using p_status, p_id;
  end set_status;

  procedure finish (p_table in varchar2, p_type in varchar2, p_id in varchar2, p_status in varchar2) is
  begin
    set_status(p_table, p_id, p_status);
    trade_core.g_internal := false;
    trade_core.audit(p_type, p_id, case p_status when 'POSTED' then 'POST' else 'UNPOST' end);
  end finish;

  procedure require_posted (p_table in varchar2, p_id in varchar2) is
    l_status varchar2(10);
  begin
    execute immediate 'select status from ' || dbms_assert.simple_sql_name(p_table) || ' where id = :i for update'
      into l_status using p_id;
    if l_status <> 'POSTED' then
      trade_core.fail('Документ не проведено.');
    end if;
  end require_posted;

  -- ------------------------------------------------- Встановлення цін номенклатури
  procedure post_price_setting (p_id in varchar2) is
    l_doc doc_price_setting%rowtype;
  begin
    select * into l_doc from doc_price_setting where id = p_id for update;
    require_lines('DOC_PRICE_SETTING_PRICES', p_id, 'Ціни');
    trade_core.g_internal := true;
    delete_movements(c_price_setting, p_id);
    insert into reg_product_price (period, recorder_type, recorder_id, line_number, price_type_id, product_id, price)
    select l_doc.occurred_at, c_price_setting, p_id, line_number, l_doc.price_type_id, product_id, price
      from doc_price_setting_prices where document_id = p_id;
    finish('DOC_PRICE_SETTING', c_price_setting, p_id, 'POSTED');
  exception when others then trade_core.g_internal := false; raise;
  end post_price_setting;

  procedure unpost_price_setting (p_id in varchar2) is
  begin
    require_posted('DOC_PRICE_SETTING', p_id);
    trade_core.g_internal := true;
    delete_movements(c_price_setting, p_id);
    finish('DOC_PRICE_SETTING', c_price_setting, p_id, 'DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_price_setting;

  function copy_price_setting (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_price_setting (id, occurred_at, price_type_id, doc_comment)
    select l_new, sysdate, price_type_id, doc_comment from doc_price_setting where id = p_id;
    insert into doc_price_setting_prices (document_id, line_number, product_id, price)
    select l_new, line_number, product_id, price from doc_price_setting_prices where document_id = p_id;
    trade_core.audit(c_price_setting, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_price_setting;

  -- ---------------------------------------------------------- Реалізація товарів
  -- r5 F-NSI-10 (db/38): характеристики з замовлення й підбір серій FEFO перед проведенням
  procedure series_prepare (p_type in varchar2, p_id in varchar2) is
  begin
    execute immediate 'begin trade_series.prepare_post(:t, :i); end;' using p_type, p_id;
  exception when others then
    if sqlcode = -6550 then null; else raise; end if;   -- db/38 не встановлено
  end series_prepare;

  -- r5 F-PRC-06 (db/39): перерахунок автоматичних знижок перед проведенням
  procedure discount_prepare (p_type in varchar2, p_id in varchar2) is
  begin
    execute immediate 'begin trade_discount.prepare_post(:t, :i); end;' using p_type, p_id;
  exception when others then
    if sqlcode = -6550 then null; else raise; end if;   -- db/39 не встановлено
  end discount_prepare;

  procedure post_goods_sale (p_id in varchar2) is
    l_doc doc_goods_sale%rowtype;
  begin
    select * into l_doc from doc_goods_sale where id = p_id for update;
    discount_prepare(c_goods_sale, p_id);
    series_prepare(c_goods_sale, p_id);
    require_lines('DOC_GOODS_SALE_GOODS', p_id, 'Товари');
    lock_counterparty(l_doc.customer_id);
    lock_warehouse(l_doc.warehouse_id);
    trade_core.g_internal := true;
    delete_movements(c_goods_sale, p_id);
    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select l_doc.occurred_at, c_goods_sale, p_id, g.line_number, l_doc.warehouse_id, g.product_id, -g.quantity
      from doc_goods_sale_goods g join ref_product p on p.id = g.product_id
     where g.document_id = p_id and p.product_kind = 'GOODS';   -- r3: послуги не рухають склад
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (l_doc.occurred_at, c_goods_sale, p_id, 1, l_doc.customer_id, 'RECEIVABLE', l_doc.currency_code, l_doc.total_amount);
    insert into reg_sales_turnover (period, recorder_type, recorder_id, line_number, counterparty_id, warehouse_id, product_id, quantity, amount)
    select l_doc.occurred_at, c_goods_sale, p_id, line_number, l_doc.customer_id, l_doc.warehouse_id, product_id, quantity, amount
      from doc_goods_sale_goods where document_id = p_id;
    trade_r3.hook_post_sale(p_id);   -- r3: замовлення, резерви, собівартість, кредитний ліміт
    check_stock(l_doc.warehouse_id, lines_products('DOC_GOODS_SALE_GOODS', p_id));
    finish('DOC_GOODS_SALE', c_goods_sale, p_id, 'POSTED');
  exception when others then trade_core.g_internal := false; raise;
  end post_goods_sale;

  procedure unpost_goods_sale (p_id in varchar2) is
    l_doc doc_goods_sale%rowtype;
  begin
    require_posted('DOC_GOODS_SALE', p_id);
    select * into l_doc from doc_goods_sale where id = p_id;
    lock_counterparty(l_doc.customer_id);
    trade_core.g_internal := true;
    trade_r3.hook_unpost_sale(p_id);
    delete_movements(c_goods_sale, p_id);
    check_settlement(l_doc.customer_id, 'RECEIVABLE');
    finish('DOC_GOODS_SALE', c_goods_sale, p_id, 'DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_goods_sale;

  function copy_goods_sale (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_goods_sale (id, occurred_at, customer_id, warehouse_id, price_type_id, contract_id, doc_comment)
    select l_new, sysdate, customer_id, warehouse_id, price_type_id, contract_id, doc_comment from doc_goods_sale where id = p_id;
    insert into doc_goods_sale_goods (document_id, line_number, product_id, quantity, price)
    select l_new, line_number, product_id, quantity, price from doc_goods_sale_goods where document_id = p_id;
    trade_core.audit(c_goods_sale, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_goods_sale;

  -- -------------------------------------------------------- Оплата від покупця
  -- r4 F-SAL-07 (db/32): оплата рухає кошти (каса / рахунок), розшифровка FIFO — trade_cust_pay.
  -- До встановлення db/32 (початкове розгортання, демо r2–r3) — логіка r2 нижче.
  function cust_pay_installed return boolean is
    n number;
  begin
    select count(*) into n from user_objects where object_name = 'TRADE_CUST_PAY' and object_type = 'PACKAGE BODY' and status = 'VALID';
    return n > 0;
  end cust_pay_installed;

  procedure post_customer_payment (p_id in varchar2) is
    l_doc doc_customer_payment%rowtype;
  begin
    if cust_pay_installed then
      execute immediate 'begin trade_cust_pay.post_customer_payment(:i); end;' using p_id;
      return;
    end if;
    select * into l_doc from doc_customer_payment where id = p_id for update;
    trade_core.check_active_ref('REF_COUNTERPARTY', l_doc.customer_id, 'Покупець');
    lock_counterparty(l_doc.customer_id);
    trade_core.g_internal := true;
    delete_movements(c_customer_payment, p_id);
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id, direction, currency_code, amount)
    values (l_doc.occurred_at, c_customer_payment, p_id, 1, l_doc.customer_id, 'RECEIVABLE', l_doc.currency_code, -l_doc.amount);
    check_settlement(l_doc.customer_id, 'RECEIVABLE');
    finish('DOC_CUSTOMER_PAYMENT', c_customer_payment, p_id, 'POSTED');
  exception when others then trade_core.g_internal := false; raise;
  end post_customer_payment;

  procedure unpost_customer_payment (p_id in varchar2) is
  begin
    if cust_pay_installed then
      execute immediate 'begin trade_cust_pay.unpost_customer_payment(:i); end;' using p_id;
      return;
    end if;
    require_posted('DOC_CUSTOMER_PAYMENT', p_id);
    trade_core.g_internal := true;
    delete_movements(c_customer_payment, p_id);
    finish('DOC_CUSTOMER_PAYMENT', c_customer_payment, p_id, 'DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_customer_payment;

  function copy_customer_payment (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    if cust_pay_installed then
      execute immediate 'begin :n := trade_cust_pay.copy_customer_payment(:i); end;' using out l_new, p_id;
      return l_new;
    end if;
    insert into doc_customer_payment (id, occurred_at, customer_id, amount, doc_comment)
    select l_new, sysdate, customer_id, amount, doc_comment from doc_customer_payment where id = p_id;
    trade_core.audit(c_customer_payment, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_customer_payment;

  -- ------------------------------------------------------- Переміщення товарів
  procedure post_goods_transfer (p_id in varchar2) is
    l_doc doc_goods_transfer%rowtype;
  begin
    select * into l_doc from doc_goods_transfer where id = p_id for update;
    series_prepare(c_goods_transfer, p_id);
    require_lines('DOC_GOODS_TRANSFER_GOODS', p_id, 'Товари');
    lock_warehouse(l_doc.warehouse_from_id);
    lock_warehouse(l_doc.warehouse_to_id);
    trade_core.g_internal := true;
    delete_movements(c_goods_transfer, p_id);
    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select l_doc.occurred_at, c_goods_transfer, p_id, line_number, l_doc.warehouse_from_id, product_id, -quantity
      from doc_goods_transfer_goods where document_id = p_id;
    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select l_doc.occurred_at, c_goods_transfer, p_id, 1000000 + line_number, l_doc.warehouse_to_id, product_id, quantity
      from doc_goods_transfer_goods where document_id = p_id;
    check_stock(l_doc.warehouse_from_id, lines_products('DOC_GOODS_TRANSFER_GOODS', p_id));
    trade_r3.hook_post_transfer(p_id);   -- r3: собівартість −/+
    finish('DOC_GOODS_TRANSFER', c_goods_transfer, p_id, 'POSTED');
  exception when others then trade_core.g_internal := false; raise;
  end post_goods_transfer;

  procedure unpost_goods_transfer (p_id in varchar2) is
    l_doc doc_goods_transfer%rowtype;
  begin
    require_posted('DOC_GOODS_TRANSFER', p_id);
    select * into l_doc from doc_goods_transfer where id = p_id;
    lock_warehouse(l_doc.warehouse_to_id);
    trade_core.g_internal := true;
    delete_movements(c_goods_transfer, p_id);
    check_stock(l_doc.warehouse_to_id, lines_products('DOC_GOODS_TRANSFER_GOODS', p_id));
    finish('DOC_GOODS_TRANSFER', c_goods_transfer, p_id, 'DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_goods_transfer;

  function copy_goods_transfer (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_goods_transfer (id, occurred_at, warehouse_from_id, warehouse_to_id, doc_comment)
    select l_new, sysdate, warehouse_from_id, warehouse_to_id, doc_comment from doc_goods_transfer where id = p_id;
    insert into doc_goods_transfer_goods (document_id, line_number, product_id, quantity)
    select l_new, line_number, product_id, quantity from doc_goods_transfer_goods where document_id = p_id;
    trade_core.audit(c_goods_transfer, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_goods_transfer;

  -- ---------------------------------------------------------- Списання товарів
  procedure post_goods_write_off (p_id in varchar2) is
    l_doc doc_goods_write_off%rowtype;
  begin
    select * into l_doc from doc_goods_write_off where id = p_id for update;
    series_prepare(c_goods_write_off, p_id);
    require_lines('DOC_GOODS_WRITE_OFF_GOODS', p_id, 'Товари');
    lock_warehouse(l_doc.warehouse_id);
    trade_core.g_internal := true;
    delete_movements(c_goods_write_off, p_id);
    insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
    select l_doc.occurred_at, c_goods_write_off, p_id, line_number, l_doc.warehouse_id, product_id, -quantity
      from doc_goods_write_off_goods where document_id = p_id;
    check_stock(l_doc.warehouse_id, lines_products('DOC_GOODS_WRITE_OFF_GOODS', p_id));
    trade_r3.hook_post_write_off(p_id);   -- r3: собівартість −
    finish('DOC_GOODS_WRITE_OFF', c_goods_write_off, p_id, 'POSTED');
  exception when others then trade_core.g_internal := false; raise;
  end post_goods_write_off;

  procedure unpost_goods_write_off (p_id in varchar2) is
  begin
    require_posted('DOC_GOODS_WRITE_OFF', p_id);
    trade_core.g_internal := true;
    delete_movements(c_goods_write_off, p_id);
    finish('DOC_GOODS_WRITE_OFF', c_goods_write_off, p_id, 'DRAFT');
  exception when others then trade_core.g_internal := false; raise;
  end unpost_goods_write_off;

  function copy_goods_write_off (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_goods_write_off (id, occurred_at, warehouse_id, reason, doc_comment)
    select l_new, sysdate, warehouse_id, reason, doc_comment from doc_goods_write_off where id = p_id;
    insert into doc_goods_write_off_goods (document_id, line_number, product_id, quantity)
    select l_new, line_number, product_id, quantity from doc_goods_write_off_goods where document_id = p_id;
    trade_core.audit(c_goods_write_off, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy_goods_write_off;

end trade_ops;
/
