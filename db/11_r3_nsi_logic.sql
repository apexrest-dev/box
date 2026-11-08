-- =============================================================================
-- Trade r3 — логіка НСІ: trade_nsi, тригери груп, номенклатури r3, договорів,
-- штрихкодів, політики запасів. Помилки: '[CODE] повідомлення' (trade_nsi.fail).
-- =============================================================================

create or replace package trade_nsi as
  procedure fail (p_code in varchar2, p_message in varchar2);
  procedure audit_cols_ins (p_created_at out timestamp, p_created_by out varchar2);
  -- Глибина групи (корінь = 1) і перевірка циклу
  function group_depth (p_group_id in varchar2) return pls_integer;
  procedure check_group_parent (p_id in varchar2, p_parent_id in varchar2);
  -- Нормалізація й перевірка штрихкоду
  function normalize_barcode (p_barcode in varchar2) return varchar2;
  procedure check_barcode (p_barcode in varchar2, p_product_id in varchar2, p_unit_quantity in number);
  -- Пошук товару: штрихкод → артикул → код → назва
  function lookup_product (p_text in varchar2) return varchar2;
  function lookup_barcode_qty (p_barcode in varchar2) return number;
  -- Договір за замовчуванням: лише якщо рівно один чинний
  function resolve_default_contract (p_owner_id in varchar2, p_kind in varchar2, p_on_date in date) return varchar2;
  -- Перевірка договору документа
  procedure check_contract (p_contract_id in varchar2, p_owner_id in varchar2, p_kind in varchar2, p_on_date in date);
  -- Товар-послуга?
  function is_service (p_product_id in varchar2) return boolean;
end trade_nsi;
/

create or replace package body trade_nsi as

  procedure fail (p_code in varchar2, p_message in varchar2) is
  begin
    trade_core.fail('[' || p_code || '] ' || p_message);
  end fail;

  procedure audit_cols_ins (p_created_at out timestamp, p_created_by out varchar2) is
  begin
    p_created_at := systimestamp;
    p_created_by := trade_core.current_user_name;
  end audit_cols_ins;

  function group_depth (p_group_id in varchar2) return pls_integer is
    l_depth pls_integer := 0;
    l_id    varchar2(32) := p_group_id;
  begin
    while l_id is not null and l_depth < 50 loop
      l_depth := l_depth + 1;
      select parent_id into l_id from ref_product_group where id = l_id;
    end loop;
    return l_depth;
  end group_depth;

  procedure check_group_parent (p_id in varchar2, p_parent_id in varchar2) is
    l_id    varchar2(32) := p_parent_id;
    l_state varchar2(20);
    l_guard pls_integer := 0;
    l_sub   pls_integer;
  begin
    if p_parent_id is null then
      return;
    end if;
    select max(state) into l_state from ref_product_group where id = p_parent_id;
    if l_state is null then
      fail('REF_NOT_FOUND', 'Батьківську групу не знайдено.');
    elsif l_state <> 'ACTIVE' then
      fail('PRODUCT_GROUP_PARENT_NOT_ACTIVE', 'Батьківська група помічена на видалення.');
    end if;
    -- цикл: батько не може бути нащадком групи
    while l_id is not null and l_guard < 50 loop
      if l_id = p_id then
        fail('PRODUCT_GROUP_CYCLE', 'Група не може бути вкладена сама в себе або у свою підгрупу.');
      end if;
      select parent_id into l_id from ref_product_group where id = l_id;
      l_guard := l_guard + 1;
    end loop;
    -- глибина: рівень батька + 1 + висота піддерева групи ≤ 5
    select coalesce(max(level), 1) into l_sub
      from ref_product_group start with id = p_id connect by prior id = parent_id;
    if group_depth(p_parent_id) + l_sub > 5 then
      fail('PRODUCT_GROUP_MAX_DEPTH_EXCEEDED', 'Перевищено максимальну глибину ієрархії груп (5 рівнів).');
    end if;
  end check_group_parent;

  function normalize_barcode (p_barcode in varchar2) return varchar2 is
  begin
    return regexp_replace(p_barcode, '[[:space:]]', '');
  end normalize_barcode;

  procedure check_barcode (p_barcode in varchar2, p_product_id in varchar2, p_unit_quantity in number) is
    l_sum  pls_integer := 0;
    l_frac varchar2(1);
    l_kind varchar2(10);
  begin
    if p_barcode is null then
      fail('BARCODE_REQUIRED', 'Вкажіть штрихкод.');
    elsif not regexp_like(p_barcode, '^[!-~]{1,64}$') then
      fail('BARCODE_INVALID_CHARS', 'Штрихкод може містити лише друковані латинські символи (до 64).');
    end if;
    if regexp_like(p_barcode, '^[0-9]{13}$') then
      for i in 1 .. 12 loop
        l_sum := l_sum + to_number(substr(p_barcode, i, 1)) * case when mod(i, 2) = 0 then 3 else 1 end;
      end loop;
      if mod(10 - mod(l_sum, 10), 10) <> to_number(substr(p_barcode, 13, 1)) then
        fail('BARCODE_EAN13_CHECKSUM_INVALID', 'Невірна контрольна цифра штрихкоду EAN-13.');
      end if;
    end if;
    if p_unit_quantity is null or p_unit_quantity <= 0 then
      fail('BARCODE_UNIT_QUANTITY_INVALID', 'Кількість в упаковці має бути більшою за нуль.');
    end if;
    select u.fractional, p.product_kind into l_frac, l_kind
      from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = p_product_id;
    if l_frac = 'N' and p_unit_quantity <> trunc(p_unit_quantity) then
      fail('BARCODE_UNIT_QUANTITY_FRACTION_NOT_ALLOWED', 'Одиниця виміру товару не дозволяє дробову кількість в упаковці.');
    end if;
  end check_barcode;

  function lookup_product (p_text in varchar2) return varchar2 is
    l_id varchar2(32);
    l_t  varchar2(255) := trim(p_text);
  begin
    select max(product_id) into l_id from reg_barcode where barcode = normalize_barcode(l_t);
    if l_id is null then
      select max(id) into l_id from ref_product where state = 'ACTIVE' and upper(article) = upper(l_t);
    end if;
    if l_id is null then
      select max(id) into l_id from ref_product where state = 'ACTIVE' and code = l_t;
    end if;
    if l_id is null then
      select max(id) into l_id from ref_product where state = 'ACTIVE' and upper(name) = upper(l_t);
    end if;
    return l_id;
  end lookup_product;

  function lookup_barcode_qty (p_barcode in varchar2) return number is
    l_q number;
  begin
    select max(unit_quantity) into l_q from reg_barcode where barcode = normalize_barcode(p_barcode);
    return coalesce(l_q, 1);
  end lookup_barcode_qty;

  function resolve_default_contract (p_owner_id in varchar2, p_kind in varchar2, p_on_date in date) return varchar2 is
    l_cnt pls_integer;
    l_id  varchar2(32);
  begin
    select count(*), max(id) into l_cnt, l_id
      from ref_contract
     where owner_id = p_owner_id and contract_kind = p_kind and state = 'ACTIVE'
       and (valid_from is null or valid_from <= trunc(p_on_date))
       and (valid_to is null or valid_to >= trunc(p_on_date));
    return case when l_cnt = 1 then l_id end;
  end resolve_default_contract;

  procedure check_contract (p_contract_id in varchar2, p_owner_id in varchar2, p_kind in varchar2, p_on_date in date) is
    l_c ref_contract%rowtype;
  begin
    if p_contract_id is null then
      return;
    end if;
    select * into l_c from ref_contract where id = p_contract_id;
    if l_c.owner_id <> p_owner_id then
      fail('CONTRACT_OWNER_MISMATCH', 'Договір «' || l_c.name || '» належить іншому контрагенту.');
    elsif l_c.contract_kind <> p_kind then
      fail('CONTRACT_KIND_MISMATCH', 'Вид договору «' || l_c.name || '» не відповідає документу ('
           || case p_kind when 'WITH_CUSTOMER' then 'потрібен договір з покупцем' else 'потрібен договір з постачальником' end || ').');
    elsif l_c.state <> 'ACTIVE' then
      fail('CONTRACT_NOT_ACTIVE', 'Договір «' || l_c.name || '» помічений на видалення.');
    elsif (l_c.valid_from is not null and trunc(p_on_date) < l_c.valid_from)
       or (l_c.valid_to is not null and trunc(p_on_date) > l_c.valid_to) then
      fail('CONTRACT_NOT_VALID_ON_DATE', 'Договір «' || l_c.name || '» не діє на дату документа.');
    end if;
  end check_contract;

  function is_service (p_product_id in varchar2) return boolean is
    l_kind varchar2(10);
  begin
    select product_kind into l_kind from ref_product where id = p_product_id;
    return l_kind = 'SERVICE';
  end is_service;

end trade_nsi;
/

-- Повідомлення об'єктів-реєстраторів: прибирати [CODE] у UI-повідомленні, лишати в API
-- (обробник APEX показує текст без префікса коду)

-- ---------------------------------------------------------------- RefProductGroup
create or replace trigger ref_product_group_ct
for insert or update on ref_product_group
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_ids t_ids;
  before each row is
  begin
    if inserting then
      :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_PRODUCT_GROUP_CODE_SEQ'));
      :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.code);
    :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
    if inserting or nvl(:new.parent_id, '-') <> nvl(:old.parent_id, '-') then
      g_ids(:new.id) := :new.parent_id;   -- перевірка ієрархії після оператора
    end if;
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end before each row;
  after statement is
    l_id varchar2(32) := g_ids.first;
  begin
    while l_id is not null loop
      trade_nsi.check_group_parent(l_id, g_ids(l_id));
      l_id := g_ids.next(l_id);
    end loop;
    g_ids.delete;
  exception when others then g_ids.delete; raise;
  end after statement;
end ref_product_group_ct;
/
drop trigger ref_product_group_biu;
create or replace trigger ref_product_group_bd before delete on ref_product_group
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- RefProduct r3
create or replace trigger ref_product_r3_biu
before insert or update on ref_product for each row
declare
  l_used pls_integer;
  l_gstate varchar2(20);
begin
  :new.article := trim(:new.article);
  if :new.product_kind = 'SERVICE' then
    :new.weight_kg := null;
  end if;
  if :new.group_id is not null and (inserting or nvl(:old.group_id, '-') <> :new.group_id) then
    select max(state) into l_gstate from ref_product_group where id = :new.group_id;
    if l_gstate is null or l_gstate <> 'ACTIVE' then
      trade_nsi.fail('PRODUCT_GROUP_NOT_ACTIVE', 'Група номенклатури не існує або помічена на видалення.');
    end if;
  end if;
  if updating and :new.product_kind <> :old.product_kind then
    select count(*) into l_used from dual
     where exists (select 1 from reg_stock_balance_movement where product_id = :new.id)
        or exists (select 1 from doc_goods_receipt_goods where product_id = :new.id)
        or exists (select 1 from doc_goods_sale_goods where product_id = :new.id);
    if l_used > 0 then
      trade_nsi.fail('PRODUCT_KIND_CHANGE_FORBIDDEN', 'Вид номенклатури не можна змінити: товар уже використовується в документах.');
    end if;
  end if;
end;
/

-- ---------------------------------------------------------------- RefContract
create or replace trigger ref_contract_biu
before insert or update on ref_contract for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_CONTRACT_CODE_SEQ'));
    :new.version := 0;
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    trade_core.check_active_ref('REF_COUNTERPARTY', :new.owner_id, 'Контрагент');
  else
    if :new.owner_id <> :old.owner_id then
      trade_nsi.fail('CONTRACT_OWNER_IMMUTABLE', 'Власника договору не можна змінити після запису.');
    end if;
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  if :new.contract_kind = 'WITH_SUPPLIER' and (:new.credit_limit is not null or :new.price_type_id is not null) then
    trade_nsi.fail('CONTRACT_SUPPLIER_TERMS', 'Кредитний ліміт і вид цін задаються лише в договорах з покупцем.');
  end if;
  if :new.price_type_id is not null and (inserting or nvl(:old.price_type_id, '-') <> :new.price_type_id) then
    trade_core.check_active_ref('REF_PRICE_TYPE', :new.price_type_id, 'Вид цін');
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_contract_bd before delete on ref_contract
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

-- ---------------------------------------------------------------- RegBarcode
create or replace trigger reg_barcode_biu
before insert or update on reg_barcode for each row
begin
  :new.barcode := trade_nsi.normalize_barcode(:new.barcode);
  :new.unit_quantity := coalesce(:new.unit_quantity, 1);
  trade_nsi.check_barcode(:new.barcode, :new.product_id, :new.unit_quantity);
  if inserting then
    :new.version := 0;
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger reg_barcode_aiud
after insert or update or delete on reg_barcode for each row
begin
  trade_core.audit('Register.Barcode', coalesce(:new.id, :old.id),
    case when inserting then 'INSERT' when updating then 'UPDATE' else 'DELETE' end,
    '{"before":"' || :old.barcode || '","after":"' || :new.barcode || '","qty":' || coalesce(to_char(:new.unit_quantity, 'TM9', 'NLS_NUMERIC_CHARACTERS=.,'), 'null') || '}');
end;
/

-- ---------------------------------------------------------------- RegReorderPolicy
create or replace trigger reg_reorder_policy_biu
before insert or update on reg_reorder_policy for each row
declare
  l_frac varchar2(1);
begin
  if trade_nsi.is_service(:new.product_id) then
    trade_nsi.fail('REORDER_SERVICE_PRODUCT', 'Для послуг параметри забезпечення запасів не задаються.');
  end if;
  if :new.min_quantity < 0 or :new.max_quantity < 0 then
    trade_nsi.fail('REORDER_NEGATIVE_QUANTITY', 'Мінімальний і максимальний запас не можуть бути від''ємними.');
  elsif :new.min_quantity > :new.max_quantity then
    trade_nsi.fail('REORDER_MIN_GT_MAX', 'Мінімальний запас не може перевищувати максимальний.');
  end if;
  select u.fractional into l_frac from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = :new.product_id;
  if l_frac = 'N' and (:new.min_quantity <> trunc(:new.min_quantity) or :new.max_quantity <> trunc(:new.max_quantity)) then
    trade_nsi.fail('REORDER_QUANTITY_NOT_INTEGER', 'Одиниця виміру товару не дозволяє дробові значення запасу.');
  end if;
  if inserting then
    :new.version := 0;
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/

-- ---------------------------------------------------------------- RegSupplierPrice: лише проведення
create or replace trigger reg_supplier_price_biud
before insert or update or delete on reg_supplier_price
begin
  if not trade_core.g_internal then trade_core.fail('Записи регістру формуються лише проведенням документів.'); end if;
end;
/
