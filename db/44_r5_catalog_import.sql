-- =============================================================================
-- Trade r5 — F-SRV-06 «Імпорт довідників» (APE-69), обробка DataCatalogImport
--   Завантаження одиниць виміру, груп номенклатури, номенклатури (зі штрихкодами й цінами),
--   контрагентів, штрихкодів і цін із CSV / XLSX: розбір apex_data_parser, зіставлення колонок
--   (автоматичне за заголовками + ручне), попередня перевірка (дія для кожного рядка), режими
--   «створювати й оновлювати» / «лише створювати» / «лише оновлювати», пошук існуючих за
--   кодом / артикулом / штрихкодом / ЄДРПОУ, звіт помилок; ціни — документ «Встановлення цін»
--   (проводиться автоматично, по одному на вид цін).
-- Перезапускається (таблиці створюються, якщо їх немає).
-- =============================================================================
set define off

declare
  procedure ddl (p_sql varchar2) is
  begin
    execute immediate p_sql;
  exception when others then
    if sqlcode not in (-955, -1430, -2260, -2275, -1408, -2261, -1442) then raise; end if;
  end;
begin
  ddl(q'[create table sys_import_session (
    id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
    import_kind   varchar2(20)  not null,
    import_mode   varchar2(20)  default on null 'CREATE_UPDATE' not null,
    file_name     varchar2(400),
    file_charset  varchar2(30),
    price_type_id varchar2(32),
    price_date    date,
    status        varchar2(10)  default on null 'LOADED' not null,
    total_rows    number(10)    default on null 0 not null,
    created_cnt   number(10)    default on null 0 not null,
    updated_cnt   number(10)    default on null 0 not null,
    skipped_cnt   number(10)    default on null 0 not null,
    error_cnt     number(10)    default on null 0 not null,
    price_cnt     number(10)    default on null 0 not null,
    created_at    timestamp     default on null systimestamp not null,
    created_by    varchar2(255) not null,
    checked_at    timestamp,
    applied_at    timestamp,
    applied_by    varchar2(255),
    constraint sys_import_session_pk primary key (id),
    constraint sys_import_session_kind_ck check (import_kind in ('UNIT','GROUP','PRODUCT','COUNTERPARTY','BARCODE','PRICE')),
    constraint sys_import_session_mode_ck check (import_mode in ('CREATE_UPDATE','CREATE_ONLY','UPDATE_ONLY')),
    constraint sys_import_session_status_ck check (status in ('LOADED','CHECKED','APPLIED')),
    constraint sys_import_session_pt_fk foreign key (price_type_id) references ref_price_type (id))]');
  ddl('create index sys_import_session_cr_ix on sys_import_session (created_at)');
  ddl(q'[create table sys_import_column (
    session_id  varchar2(32)  not null,
    col_no      number(3)     not null,
    header      varchar2(255),
    sample      varchar2(255),
    field_code  varchar2(30),
    constraint sys_import_column_pk primary key (session_id, col_no),
    constraint sys_import_column_ses_fk foreign key (session_id) references sys_import_session (id) on delete cascade)]');
  ddl(q'[create table sys_import_row (
    session_id  varchar2(32)   not null,
    row_no      number(10)     not null,
    row_data    clob           not null,
    row_text    varchar2(4000),
    key_text    varchar2(500),
    action      varchar2(10),
    match_by    varchar2(20),
    target_id   varchar2(32),
    message     varchar2(4000),
    result      varchar2(10),
    result_id   varchar2(32),
    constraint sys_import_row_pk primary key (session_id, row_no),
    constraint sys_import_row_json_ck check (row_data is json),
    constraint sys_import_row_action_ck check (action in ('CREATE','UPDATE','SKIP','ERROR','PRICE')),
    constraint sys_import_row_result_ck check (result in ('DONE','SKIPPED','ERROR')),
    constraint sys_import_row_ses_fk foreign key (session_id) references sys_import_session (id) on delete cascade)]');
end;
/

-- =============================================================================
-- trade_import
-- =============================================================================
create or replace package trade_import as
  c_max_rows constant pls_integer := 10000;
  c_max_cols constant pls_integer := 60;

  type t_field is record (kind varchar2(20), field_code varchar2(30), field_name varchar2(100),
                          required varchar2(1), synonyms varchar2(1000), hint varchar2(1000), ord number);
  type t_fields is table of t_field;

  function kind_name (p_kind in varchar2) return varchar2;
  function mode_name (p_mode in varchar2) return varchar2;
  function action_name (p_action in varchar2) return varchar2;
  function fields (p_kind in varchar2) return t_fields pipelined;
  function normalize_header (p_text in varchar2) return varchar2;

  -- Розбір значень файлу
  function parse_number (p_text in varchar2) return number;
  function parse_flag (p_text in varchar2) return varchar2;          -- Y / N / null (не розпізнано → 'X')

  -- Крок 1: завантаження файлу (CSV / TXT / TSV / XLSX — перший аркуш); перший рядок — заголовки.
  -- Повертає ідентифікатор сеансу імпорту; колонки зіставляються автоматично (auto_map).
  function load_file (p_kind in varchar2, p_mode in varchar2, p_file_name in varchar2, p_content in blob,
                      p_charset in varchar2 default 'AL32UTF8', p_price_type_id in varchar2 default null,
                      p_price_date in date default null) return varchar2;
  -- Те саме з тексту (для тестів і вставки з буфера)
  function load_text (p_kind in varchar2, p_mode in varchar2, p_text in clob, p_price_type_id in varchar2 default null,
                      p_price_date in date default null) return varchar2;
  procedure set_options (p_session in varchar2, p_mode in varchar2, p_price_type_id in varchar2, p_price_date in date);

  -- Крок 2: зіставлення колонок
  procedure auto_map (p_session in varchar2);
  procedure set_mapping (p_session in varchar2, p_col_no in number, p_field in varchar2);

  -- Крок 3: перевірка (попередній перегляд): дія, спосіб пошуку, повідомлення для кожного рядка
  procedure check_rows (p_session in varchar2);
  -- Крок 4: виконання (кожен рядок — окремо; помилка рядка не зупиняє інші)
  procedure apply (p_session in varchar2);

  -- UI
  function fields_html (p_kind in varchar2) return clob;
  function mapping_html (p_session in varchar2) return clob;
  function summary_html (p_session in varchar2) return clob;
  function template_csv (p_kind in varchar2) return clob;
  function errors_csv (p_session in varchar2) return clob;
  procedure download_template (p_kind in varchar2);
  procedure download_errors (p_session in varchar2);
  -- значення поля поточного рядка (внутрішнє; публічне для використання в SQL пакета)
  function val (p_field in varchar2) return varchar2;
end trade_import;
/

create or replace package body trade_import as
  type t_vals is table of varchar2(4000) index by varchar2(30);
  type t_seen is table of number index by varchar2(600);
  type t_price is record (row_no number, price_type_id varchar2(32), product_id varchar2(32), price number);
  type t_prices is table of t_price index by pls_integer;

  g_val    t_vals;
  g_sess   sys_import_session%rowtype;
  g_err    varchar2(4000);
  g_note   varchar2(4000);
  g_seen   t_seen;      -- ключі рядків файлу (дублікати)
  g_new    t_seen;      -- групи, що будуть створені попередніми рядками файлу
  g_prices t_prices;
  g_check  boolean := true;   -- true — лише перевірка, false — виконання

  -- значення, підготовлені eval_* для запису
  g_unit_id varchar2(32); g_group_id varchar2(32); g_group_new varchar2(255); g_parent_id varchar2(32);
  g_product_id varchar2(32); g_price_type_id varchar2(32); g_price number; g_kind_val varchar2(10);
  g_vat varchar2(10); g_weight number; g_flag varchar2(1); g_flag2 varchar2(1); g_qty number; g_sort number;
  g_edrpou varchar2(20); g_iban varchar2(40); g_barcode varchar2(64);

  procedure fail (p_code in varchar2, p_message in varchar2) is
  begin
    trade_nsi.fail(p_code, p_message);
  end fail;

  function kind_name (p_kind in varchar2) return varchar2 is
  begin
    return case p_kind when 'UNIT' then 'Одиниці виміру' when 'GROUP' then 'Групи номенклатури'
                       when 'PRODUCT' then 'Номенклатура' when 'COUNTERPARTY' then 'Контрагенти'
                       when 'BARCODE' then 'Штрихкоди' when 'PRICE' then 'Ціни номенклатури' end;
  end kind_name;

  function mode_name (p_mode in varchar2) return varchar2 is
  begin
    return case p_mode when 'CREATE_UPDATE' then 'Створювати нові й оновлювати існуючі'
                       when 'CREATE_ONLY' then 'Лише створювати нові' when 'UPDATE_ONLY' then 'Лише оновлювати існуючі' end;
  end mode_name;

  function action_name (p_action in varchar2) return varchar2 is
  begin
    return case p_action when 'CREATE' then 'Створення' when 'UPDATE' then 'Оновлення' when 'SKIP' then 'Пропуск'
                         when 'ERROR' then 'Помилка' when 'PRICE' then 'Ціна' end;
  end action_name;

  -- ------------------------------------------------------------------ опис полів
  function fields (p_kind in varchar2) return t_fields pipelined is
    n number := 0;
    function f (p_code varchar2, p_name varchar2, p_req varchar2, p_syn varchar2, p_hint varchar2 default null) return t_field is
      r t_field;
    begin
      n := n + 1;
      r.kind := p_kind; r.field_code := p_code; r.field_name := p_name; r.required := p_req;
      r.synonyms := p_syn; r.hint := p_hint; r.ord := n;
      return r;
    end;
  begin
    if p_kind = 'UNIT' then
      pipe row (f('CODE', 'Код', 'N', 'код|code|код одиниці', 'Пошук існуючої; порожній код нової — автоматичний.'));
      pipe row (f('NAME', 'Найменування', 'Y', 'найменування|назва|name|повне найменування|одиниця виміру'));
      pipe row (f('SHORT_NAME', 'Скорочення', 'N', 'скорочення|скорочене найменування|коротка назва|short name|од|од вим',
                  'Пошук існуючої (після коду); порожнє — перші 20 символів найменування.'));
      pipe row (f('FRACTIONAL', 'Дробова кількість', 'N', 'дробова|дробова кількість|fractional', 'Так / Ні, 1 / 0, Y / N.'));
    elsif p_kind = 'GROUP' then
      pipe row (f('CODE', 'Код', 'N', 'код|code|код групи', 'Пошук існуючої; порожній код нової — автоматичний.'));
      pipe row (f('NAME', 'Найменування', 'Y', 'найменування|назва|name|група|назва групи',
                  'Без коду існуюча група шукається за назвою серед груп того самого батька.'));
      pipe row (f('PARENT', 'Батьківська група', 'N', 'батьківська група|батьківська|батько|група батько|parent|входить до групи',
                  'Код або назва; може бути створена попереднім рядком файлу.'));
      pipe row (f('SORT_ORDER', 'Порядок', 'N', 'порядок|сортування|sort|sort order'));
    elsif p_kind = 'PRODUCT' then
      pipe row (f('CODE', 'Код', 'N', 'код|code|код товару|код номенклатури', 'Пошук існуючого №1; порожній код нового — автоматичний.'));
      pipe row (f('ARTICLE', 'Артикул', 'N', 'артикул|article|sku|арт', 'Пошук існуючого №2.'));
      pipe row (f('NAME', 'Найменування', 'Y', 'найменування|назва|name|товар|номенклатура|назва товару'));
      pipe row (f('UNIT', 'Одиниця виміру', 'N', 'одиниця виміру|одиниця|од вим|од|unit|uom',
                  'Код, скорочення або назва одиниці; для нового товару порожнє — «шт».'));
      pipe row (f('GROUP', 'Група', 'N', 'група|група номенклатури|категорія|group|category',
                  'Код або назва групи; невідома назва — буде створено групу верхнього рівня.'));
      pipe row (f('KIND', 'Вид номенклатури', 'N', 'вид|вид номенклатури|тип|kind', 'Товар / Послуга.'));
      pipe row (f('WEIGHT', 'Вага, кг', 'N', 'вага|вага кг|weight|вага нетто'));
      pipe row (f('DESCRIPTION', 'Опис', 'N', 'опис|description|коментар'));
      pipe row (f('VAT_RATE', 'Ставка ПДВ', 'N', 'ставка пдв|пдв|ставка|vat|vat rate', '20, 7, 0, «звільнено», «без ПДВ» або код ставки.'));
      pipe row (f('UKTZED', 'Код УКТ ЗЕД', 'N', 'код укт зед|укт зед|уктзед|uktzed'));
      pipe row (f('BARCODE', 'Штрихкод', 'N', 'штрихкод|штрих код|barcode|ean|ean13', 'Пошук існуючого №3; новий штрихкод додається товару.'));
      pipe row (f('PRICE', 'Ціна', 'N', 'ціна|price|роздрібна ціна|ціна продажу', 'Документ «Встановлення цін» (вид цін — у параметрах або колонці).'));
      pipe row (f('PRICE_TYPE', 'Вид цін', 'N', 'вид цін|тип цін|price type', 'Код або назва виду цін.'));
    elsif p_kind = 'COUNTERPARTY' then
      pipe row (f('CODE', 'Код', 'N', 'код|code|код контрагента', 'Пошук існуючого №1; порожній код нового — автоматичний.'));
      pipe row (f('EDRPOU', 'ЄДРПОУ / РНОКПП', 'N', 'єдрпоу|едрпоу|код єдрпоу|код за єдрпоу|edrpou|рнокпп|інн|іпн фоп',
                  'Пошук існуючого №2; 8 цифр (юрособа) або 10 (фізособа), втрачені нулі попереду доповнюються.'));
      pipe row (f('NAME', 'Найменування', 'Y', 'найменування|назва|name|контрагент|назва контрагента'));
      pipe row (f('IBAN', 'IBAN', 'N', 'iban|рахунок|розрахунковий рахунок|р р'));
      pipe row (f('VAT_PAYER', 'Платник ПДВ', 'N', 'платник пдв|пдв|vat payer', 'Так / Ні.'));
      pipe row (f('VAT_NUMBER', 'ІПН', 'N', 'іпн|індивідуальний податковий номер|ipn|vat number', '12 цифр для платника ПДВ.'));
    elsif p_kind = 'BARCODE' then
      pipe row (f('BARCODE', 'Штрихкод', 'Y', 'штрихкод|штрих код|barcode|ean|ean13', 'Існуючий штрихкод оновлюється, новий — створюється.'));
      pipe row (f('PRODUCT_CODE', 'Код товару', 'N', 'код товару|код|code|код номенклатури', 'Пошук товару №1.'));
      pipe row (f('ARTICLE', 'Артикул', 'N', 'артикул|article|sku|арт', 'Пошук товару №2.'));
      pipe row (f('PRODUCT_NAME', 'Найменування товару', 'N', 'найменування|назва|товар|номенклатура|name', 'Пошук товару №3 (однозначний збіг).'));
      pipe row (f('UNIT_QTY', 'Кількість в упаковці', 'N', 'кількість в упаковці|кількість|коефіцієнт|в упаковці|qty', 'Порожнє — 1.'));
    elsif p_kind = 'PRICE' then
      pipe row (f('PRODUCT_CODE', 'Код товару', 'N', 'код товару|код|code|код номенклатури', 'Пошук товару №1.'));
      pipe row (f('ARTICLE', 'Артикул', 'N', 'артикул|article|sku|арт', 'Пошук товару №2.'));
      pipe row (f('BARCODE', 'Штрихкод', 'N', 'штрихкод|штрих код|barcode|ean|ean13', 'Пошук товару №3.'));
      pipe row (f('PRODUCT_NAME', 'Найменування товару', 'N', 'найменування|назва|товар|номенклатура|name', 'Пошук товару №4 (однозначний збіг).'));
      pipe row (f('PRICE', 'Ціна', 'Y', 'ціна|price|роздрібна ціна|ціна продажу|нова ціна'));
      pipe row (f('PRICE_TYPE', 'Вид цін', 'N', 'вид цін|тип цін|price type', 'Код або назва; порожнє — вид цін із параметрів імпорту.'));
    end if;
    return;
  end fields;

  function normalize_header (p_text in varchar2) return varchar2 is
  begin
    return trim(regexp_replace(lower(replace(p_text, chr(160), ' ')), '[[:punct:][:space:]]+', ' '));
  end normalize_header;

  -- ------------------------------------------------------------------ розбір значень
  function parse_number (p_text in varchar2) return number is
    l varchar2(4000) := replace(replace(replace(trim(p_text), chr(160)), ' '), chr(8239));
  begin
    if l is null then return null; end if;
    l := replace(l, ',', '.');
    if length(l) - length(replace(l, '.')) > 1 then           -- 1.234.567.89 → лише остання крапка десяткова
      l := replace(substr(l, 1, instr(l, '.', -1) - 1), '.') || substr(l, instr(l, '.', -1));
    end if;
    return to_number(l default null on conversion error, '9999999999999999999D999999999', 'nls_numeric_characters=''.,''');
  end parse_number;

  function parse_flag (p_text in varchar2) return varchar2 is
    l varchar2(100) := lower(trim(p_text));
  begin
    if l is null then return null; end if;
    if l in ('y', 'yes', 'так', 't', 'true', '1', '+', 'да', 'істина') then return 'Y'; end if;
    if l in ('n', 'no', 'ні', 'f', 'false', '0', '-', 'нет', 'хиба') then return 'N'; end if;
    return 'X';
  end parse_flag;

  -- ------------------------------------------------------------------ сеанс
  procedure load_session (p_session in varchar2) is
  begin
    select * into g_sess from sys_import_session where id = p_session for update;
  exception when no_data_found then
    fail('IMPORT_SESSION_NOT_FOUND', 'Сеанс імпорту не знайдено. Завантажте файл ще раз.');
  end load_session;

  procedure check_kind (p_kind in varchar2, p_mode in varchar2) is
  begin
    if kind_name(p_kind) is null then
      fail('IMPORT_KIND', 'Виберіть, що завантажувати (довідник).');
    end if;
    if mode_name(nvl(p_mode, 'CREATE_UPDATE')) is null then
      fail('IMPORT_MODE', 'Невідомий режим імпорту.');
    end if;
  end check_kind;

  procedure set_options (p_session in varchar2, p_mode in varchar2, p_price_type_id in varchar2, p_price_date in date) is
  begin
    load_session(p_session);
    if g_sess.status = 'APPLIED' then
      fail('IMPORT_ALREADY_APPLIED', 'Імпорт уже виконано. Завантажте файл ще раз.');
    end if;
    check_kind(g_sess.import_kind, p_mode);
    if p_price_type_id is not null then
      trade_core.check_active_ref('REF_PRICE_TYPE', p_price_type_id, 'Вид цін');
    end if;
    update sys_import_session
       set import_mode = nvl(p_mode, 'CREATE_UPDATE'), price_type_id = p_price_type_id, price_date = p_price_date,
           status = 'LOADED'
     where id = p_session;
  end set_options;

  function load_file (p_kind in varchar2, p_mode in varchar2, p_file_name in varchar2, p_content in blob,
                      p_charset in varchar2 default 'AL32UTF8', p_price_type_id in varchar2 default null,
                      p_price_date in date default null) return varchar2 is
    type t_lines is table of number;
    type t_rows is table of clob;
    l_id    varchar2(32) := rawtohex(sys_guid());
    l_ext   varchar2(10) := lower(regexp_substr(p_file_name, '\.([[:alnum:]]+)$', 1, 1, null, 1));
    l_sql   varchar2(32767);
    l_lines t_lines;
    l_rows  t_rows;
    l_hdr   json_array_t;
    l_arr   json_array_t;
    l_cols  pls_integer := 0;
    l_n     pls_integer := 0;
    l_text  varchar2(4000);
    l_v     varchar2(4000);
    l_empty boolean;
    type t_names is table of varchar2(255) index by pls_integer;
    l_names t_names;
    l_samples t_names;
  begin
    check_kind(p_kind, p_mode);
    if p_content is null or dbms_lob.getlength(p_content) = 0 then
      fail('IMPORT_FILE_EMPTY', 'Виберіть файл для завантаження.');
    end if;
    if l_ext is null or l_ext not in ('csv', 'txt', 'tsv', 'xlsx') then
      fail('IMPORT_FILE_FORMAT', 'Підтримуються файли CSV, TXT, TSV (роздільник визначається автоматично) і Excel XLSX.');
    end if;
    if p_price_type_id is not null then
      trade_core.check_active_ref('REF_PRICE_TYPE', p_price_type_id, 'Вид цін');
    end if;
    l_sql := 'select line_number, json_array(';
    for i in 1 .. c_max_cols loop
      l_sql := l_sql || case when i > 1 then ', ' end || 'col' || to_char(i, 'FM000');
    end loop;
    l_sql := l_sql || ' null on null returning clob) from table(apex_data_parser.parse(p_content => :c, p_file_name => :f, '
      || 'p_file_type => :t, p_file_charset => :cs, p_max_rows => :m)) order by line_number';
    begin
      execute immediate l_sql bulk collect into l_lines, l_rows
        using p_content, case when l_ext = 'xlsx' then p_file_name else 'import.csv' end,
              case when l_ext = 'xlsx' then apex_data_parser.c_file_type_xlsx else apex_data_parser.c_file_type_csv end,
              nvl(p_charset, 'AL32UTF8'), c_max_rows + 2;
    exception when others then
      fail('IMPORT_FILE_PARSE', 'Файл не вдалося прочитати: ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
    end;
    if l_rows.count < 2 then
      fail('IMPORT_FILE_NO_ROWS', 'У файлі немає рядків даних: перший рядок — заголовки колонок, далі — дані.');
    end if;
    if l_rows.count > c_max_rows + 1 then
      fail('IMPORT_FILE_TOO_BIG', 'У файлі понад ' || c_max_rows || ' рядків — розділіть його на частини.');
    end if;
    l_hdr := json_array_t.parse(l_rows(1));
    for i in reverse 0 .. l_hdr.get_size - 1 loop
      if trim(l_hdr.get_string(i)) is not null then
        l_cols := i + 1;
        exit;
      end if;
    end loop;
    if l_cols = 0 then
      fail('IMPORT_FILE_NO_HEADER', 'Перший рядок файлу має містити заголовки колонок.');
    end if;
    insert into sys_import_session (id, import_kind, import_mode, file_name, file_charset, price_type_id, price_date, created_by)
    values (l_id, p_kind, nvl(p_mode, 'CREATE_UPDATE'), substr(p_file_name, 1, 400), nvl(p_charset, 'AL32UTF8'),
            p_price_type_id, p_price_date, trade_core.current_user_name);
    for i in 1 .. l_cols loop
      l_names(i) := nvl(substr(trim(l_hdr.get_string(i - 1)), 1, 255), 'Колонка ' || i);
      insert into sys_import_column (session_id, col_no, header) values (l_id, i, l_names(i));
    end loop;
    for r in 2 .. l_rows.count loop
      l_arr := json_array_t.parse(l_rows(r));
      l_empty := true;
      l_text := null;
      for i in 1 .. l_cols loop
        l_v := trim(l_arr.get_string(i - 1));
        if l_v is not null then
          l_empty := false;
          if not l_samples.exists(i) then l_samples(i) := l_v; end if;
          l_text := substr(l_text || case when l_text is not null then '; ' end || l_names(i) || ': ' || l_v, 1, 4000);
        end if;
      end loop;
      if not l_empty then
        l_n := l_n + 1;
        insert into sys_import_row (session_id, row_no, row_data, row_text) values (l_id, l_lines(r), l_rows(r), l_text);
      end if;
    end loop;
    if l_n = 0 then
      fail('IMPORT_FILE_NO_ROWS', 'У файлі немає рядків даних: перший рядок — заголовки колонок, далі — дані.');
    end if;
    for i in 1 .. l_cols loop
      if l_samples.exists(i) then
        update sys_import_column set sample = substr(l_samples(i), 1, 255) where session_id = l_id and col_no = i;
      end if;
    end loop;
    update sys_import_session set total_rows = l_n where id = l_id;
    auto_map(l_id);
    trade_core.audit('DataCatalogImport', l_id, 'IMPORT_LOAD', kind_name(p_kind) || ': ' || p_file_name || ', рядків ' || l_n);
    return l_id;
  end load_file;

  function load_text (p_kind in varchar2, p_mode in varchar2, p_text in clob, p_price_type_id in varchar2 default null,
                      p_price_date in date default null) return varchar2 is
    l_blob blob;
    l_dest integer := 1; l_src integer := 1; l_ctx integer := dbms_lob.default_lang_ctx; l_warn integer;
  begin
    if p_text is null or dbms_lob.getlength(p_text) = 0 then
      fail('IMPORT_FILE_EMPTY', 'Виберіть файл для завантаження.');
    end if;
    dbms_lob.createtemporary(l_blob, true);
    dbms_lob.converttoblob(l_blob, p_text, dbms_lob.lobmaxsize, l_dest, l_src, nls_charset_id('AL32UTF8'), l_ctx, l_warn);
    return load_file(p_kind, p_mode, 'import.csv', l_blob, 'AL32UTF8', p_price_type_id, p_price_date);
  end load_text;

  -- ------------------------------------------------------------------ зіставлення
  procedure auto_map (p_session in varchar2) is
    l_used t_seen;
    l_kind varchar2(20);
    l_hit  varchar2(30);
    l_h    varchar2(255);
  begin
    select import_kind into l_kind from sys_import_session where id = p_session;
    update sys_import_column set field_code = null where session_id = p_session;
    -- 1) точний збіг з назвою поля / кодом поля; 2) збіг із синонімом
    for pass in 1 .. 2 loop
      for c in (select col_no, header from sys_import_column where session_id = p_session and field_code is null order by col_no) loop
        l_h := normalize_header(c.header);
        l_hit := null;
        for f in (select * from table(trade_import.fields(l_kind)) order by ord) loop
          if not l_used.exists(f.field_code) and (
               (pass = 1 and (l_h = normalize_header(f.field_name) or l_h = lower(f.field_code)))
            or (pass = 2 and instr('|' || f.synonyms || '|', '|' || l_h || '|') > 0)) then
            l_hit := f.field_code;
            exit;
          end if;
        end loop;
        if l_hit is not null then
          l_used(l_hit) := c.col_no;
          update sys_import_column set field_code = l_hit where session_id = p_session and col_no = c.col_no;
        end if;
      end loop;
    end loop;
  end auto_map;

  procedure set_mapping (p_session in varchar2, p_col_no in number, p_field in varchar2) is
    l_ok pls_integer;
  begin
    load_session(p_session);
    if g_sess.status = 'APPLIED' then
      fail('IMPORT_ALREADY_APPLIED', 'Імпорт уже виконано. Завантажте файл ще раз.');
    end if;
    if p_field is not null then
      select count(*) into l_ok from table(trade_import.fields(g_sess.import_kind)) where field_code = p_field;
      if l_ok = 0 then
        fail('IMPORT_FIELD_UNKNOWN', 'Невідоме поле «' || p_field || '» для довідника «' || kind_name(g_sess.import_kind) || '».');
      end if;
    end if;
    update sys_import_column set field_code = p_field where session_id = p_session and col_no = p_col_no;
    update sys_import_session set status = 'LOADED' where id = p_session;
  end set_mapping;

  -- ------------------------------------------------------------------ значення рядка
  function val (p_field in varchar2) return varchar2 is
  begin
    if g_val.exists(p_field) then return g_val(p_field); end if;
    return null;
  end val;

  function has (p_field in varchar2) return boolean is
  begin
    return val(p_field) is not null;
  end has;

  procedure err (p_msg in varchar2) is
  begin
    g_err := substr(g_err || case when g_err is not null then '; ' end || p_msg, 1, 4000);
  end err;

  procedure note (p_msg in varchar2) is
  begin
    g_note := substr(g_note || case when g_note is not null then '; ' end || p_msg, 1, 4000);
  end note;

  procedure load_values (p_session in varchar2, p_data in clob) is
    l_arr json_array_t := json_array_t.parse(p_data);
  begin
    g_val.delete;
    for c in (select col_no, field_code from sys_import_column where session_id = p_session and field_code is not null) loop
      if c.col_no <= l_arr.get_size then
        g_val(c.field_code) := substr(trim(replace(l_arr.get_string(c.col_no - 1), chr(160), ' ')), 1, 4000);
      end if;
    end loop;
  end load_values;

  function num (p_field in varchar2, p_label in varchar2, p_min in number default 0) return number is
    l number;
  begin
    if not has(p_field) then return null; end if;
    l := parse_number(val(p_field));
    if l is null then
      err(p_label || ': «' || val(p_field) || '» — не число');
    elsif l < p_min then
      err(p_label || ' не може бути меншою за ' || p_min);
      l := null;
    end if;
    return l;
  end num;

  function flag (p_field in varchar2, p_label in varchar2) return varchar2 is
    l varchar2(1) := parse_flag(val(p_field));
  begin
    if l = 'X' then
      err(p_label || ': «' || val(p_field) || '» — очікується Так / Ні');
      return null;
    end if;
    return l;
  end flag;

  -- Загальні правила режиму: знайдено / не знайдено → дія
  procedure decide (p_target in varchar2, o_action out varchar2) is
  begin
    if g_err is not null then
      o_action := 'ERROR';
    elsif p_target is null and g_sess.import_mode = 'UPDATE_ONLY' then
      o_action := 'SKIP';
      note('Не знайдено — пропущено (режим «Лише оновлювати існуючі»)');
    elsif p_target is not null and g_sess.import_mode = 'CREATE_ONLY' then
      o_action := 'SKIP';
      note('Уже існує — пропущено (режим «Лише створювати нові»)');
    else
      o_action := case when p_target is null then 'CREATE' else 'UPDATE' end;
    end if;
  end decide;

  function how_name (p_how in varchar2) return varchar2 is
  begin
    return case p_how when 'CODE' then 'кодом' when 'ARTICLE' then 'артикулом' when 'BARCODE' then 'штрихкодом'
                      when 'EDRPOU' then 'ЄДРПОУ' when 'SHORT_NAME' then 'скороченням' when 'NAME' then 'найменуванням' end;
  end how_name;

  procedure pick (p_id in varchar2, p_how in varchar2, io_target in out varchar2, io_how in out varchar2, p_what in varchar2) is
  begin
    if p_id is null then return; end if;
    if io_target is null then
      io_target := p_id; io_how := p_how;
    elsif io_target <> p_id then
      err('Пошук за ' || how_name(io_how) || ' і за ' || how_name(p_how) || ' знаходить різні ' || p_what);
    end if;
  end pick;

  -- ------------------------------------------------------------------ довідники-посилання
  function find_unit (p_text in varchar2) return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by case when code = trim(p_text) then 1 when upper(short_name) = upper(trim(p_text)) then 2 else 3 end)
      into l from ref_unit_of_measure
     where state = 'ACTIVE' and (code = trim(p_text) or upper(short_name) = upper(trim(p_text)) or upper(name) = upper(trim(p_text)));
    return l;
  end find_unit;

  function find_group (p_text in varchar2, o_count out number) return varchar2 is
    l varchar2(32);
  begin
    select max(id) into l from ref_product_group where state = 'ACTIVE' and code = trim(p_text);
    o_count := case when l is null then 0 else 1 end;
    if l is null then
      select max(id), count(*) into l, o_count from ref_product_group where state = 'ACTIVE' and upper(name) = upper(trim(p_text));
    end if;
    return case when o_count = 1 then l end;
  end find_group;

  function find_price_type (p_text in varchar2) return varchar2 is
    l varchar2(32);
  begin
    select max(id) into l from ref_price_type where state = 'ACTIVE' and (code = trim(p_text) or upper(name) = upper(trim(p_text)));
    return l;
  end find_price_type;

  function find_vat (p_text in varchar2) return varchar2 is
    l   varchar2(10);
    l_t varchar2(100) := lower(replace(replace(trim(p_text), '%'), ' '));
    l_n number;
  begin
    select max(code) into l from ref_vat_rate where upper(code) = upper(trim(p_text)) or upper(name) = upper(trim(p_text));
    if l is null then
      if l_t like 'звільн%' then l := 'EXEMPT';
      elsif l_t like 'без%' or l_t = 'неплатник' then l := 'NOVAT';
      else
        l_n := parse_number(l_t);
        select max(code) into l from ref_vat_rate where rate = l_n and code like 'VAT%';
      end if;
    end if;
    return l;
  end find_vat;

  -- товар для штрихкодів і цін: код → артикул → штрихкод → найменування
  procedure find_product_ref (o_target out varchar2, o_how out varchar2) is
    l varchar2(32); l_cnt number;
  begin
    o_target := null; o_how := null;
    if has('PRODUCT_CODE') then
      select max(id) into l from ref_product where code = val('PRODUCT_CODE');
      if l is null then err('Товар з кодом «' || val('PRODUCT_CODE') || '» не знайдено'); end if;
      pick(l, 'CODE', o_target, o_how, 'товари');
    end if;
    if has('ARTICLE') then
      select max(id) into l from ref_product where state = 'ACTIVE' and upper(article) = upper(val('ARTICLE'));
      if l is null and o_target is null then err('Товар з артикулом «' || val('ARTICLE') || '» не знайдено'); end if;
      pick(l, 'ARTICLE', o_target, o_how, 'товари');
    end if;
    if has('BARCODE') and g_sess.import_kind = 'PRICE' then
      select max(product_id) into l from reg_barcode where barcode = trade_nsi.normalize_barcode(val('BARCODE'));
      if l is null and o_target is null then err('Товар зі штрихкодом «' || val('BARCODE') || '» не знайдено'); end if;
      pick(l, 'BARCODE', o_target, o_how, 'товари');
    end if;
    if o_target is null and g_err is null and has('PRODUCT_NAME') then
      select max(id), count(*) into l, l_cnt from ref_product where state = 'ACTIVE' and upper(name) = upper(val('PRODUCT_NAME'));
      if l_cnt > 1 then
        err('Найменування «' || val('PRODUCT_NAME') || '» мають ' || l_cnt || ' товари — вкажіть код або артикул');
      elsif l_cnt = 0 then
        err('Товар «' || val('PRODUCT_NAME') || '» не знайдено');
      else
        o_target := l; o_how := 'NAME';
      end if;
    end if;
    if o_target is null and g_err is null then
      err('Не вказано товар (код, артикул, штрихкод або найменування)');
    end if;
  end find_product_ref;

  -- дублікати у файлі: за знайденим об'єктом і за ключем рядка (на кроці виконання новий об'єкт уже знайдено)
  procedure dup (p_target in varchar2, p_key in varchar2, p_row in number) is
  begin
    if p_target is not null and g_seen.exists(p_target) then
      err('Повторює рядок ' || g_seen(p_target) || ' файлу');
    elsif p_key is not null and g_seen.exists(p_key) then
      err('Повторює рядок ' || g_seen(p_key) || ' файлу');
    else
      if p_target is not null then g_seen(p_target) := p_row; end if;
      if p_key is not null then g_seen(p_key) := p_row; end if;
    end if;
  end dup;

  -- ------------------------------------------------------------------ правила за видами
  procedure eval_unit (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l varchar2(32);
  begin
    o_key := coalesce(val('CODE'), val('SHORT_NAME'), val('NAME'));
    if has('CODE') then
      select max(id) into l from ref_unit_of_measure where code = val('CODE');
      pick(l, 'CODE', o_target, o_how, 'одиниці');
    end if;
    if o_target is null and has('SHORT_NAME') then
      select max(id) into l from ref_unit_of_measure where state = 'ACTIVE' and upper(short_name) = upper(val('SHORT_NAME'));
      pick(l, 'SHORT_NAME', o_target, o_how, 'одиниці');
    end if;
    if o_target is null and has('NAME') and not has('CODE') then
      select max(id) into l from ref_unit_of_measure where state = 'ACTIVE' and upper(name) = upper(val('NAME'));
      pick(l, 'NAME', o_target, o_how, 'одиниці');
    end if;
    g_flag := flag('FRACTIONAL', 'Дробова кількість');
    if o_target is null and not has('NAME') then err('Не вказано найменування'); end if;
    if has('CODE') and length(val('CODE')) > 9 then err('Код довший за 9 символів'); end if;
    if length(val('SHORT_NAME')) > 20 then err('Скорочення довше за 20 символів'); end if;
    dup(o_target, 'U:' || upper(coalesce(val('CODE'), val('SHORT_NAME'), val('NAME'))), p_row);
    decide(o_target, o_action);
  end eval_unit;

  procedure eval_group (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l varchar2(32); l_cnt number;
  begin
    o_key := coalesce(val('CODE'), val('NAME'));
    g_parent_id := null;
    if has('PARENT') then
      g_parent_id := find_group(val('PARENT'), l_cnt);
      if l_cnt > 1 then
        err('Назву батьківської групи «' || val('PARENT') || '» мають ' || l_cnt || ' групи — вкажіть код');
      elsif g_parent_id is null then
        if g_new.exists(upper(val('PARENT'))) then
          note('Батьківська група — з рядка ' || g_new(upper(val('PARENT'))) || ' файлу');
        else
          err('Батьківську групу «' || val('PARENT') || '» не знайдено');
        end if;
      end if;
    end if;
    if has('CODE') then
      select max(id) into l from ref_product_group where code = val('CODE');
      pick(l, 'CODE', o_target, o_how, 'групи');
    end if;
    if o_target is null and has('NAME') and not has('CODE') then
      select max(id) into l from ref_product_group
       where state = 'ACTIVE' and upper(name) = upper(val('NAME')) and nvl(parent_id, '#') = nvl(g_parent_id, '#');
      pick(l, 'NAME', o_target, o_how, 'групи');
    end if;
    g_sort := num('SORT_ORDER', 'Порядок');
    if o_target is null and not has('NAME') then err('Не вказано найменування'); end if;
    if has('CODE') and length(val('CODE')) > 9 then err('Код довший за 9 символів'); end if;
    if o_target is not null and o_target = g_parent_id then err('Група не може бути батьківською для себе'); end if;
    dup(o_target, 'G:' || upper(coalesce(val('CODE'), val('PARENT') || '/' || val('NAME'))), p_row);
    decide(o_target, o_action);
    if o_action = 'CREATE' then
      if has('CODE') then g_new(upper(val('CODE'))) := p_row; end if;
      if has('NAME') and not g_new.exists(upper(val('NAME'))) then g_new(upper(val('NAME'))) := p_row; end if;
    end if;
  end eval_group;

  procedure eval_product (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l varchar2(32); l_cnt number; l_k varchar2(30);
  begin
    o_key := coalesce(val('CODE'), val('ARTICLE'), val('BARCODE'), val('NAME'));
    g_unit_id := null; g_group_id := null; g_group_new := null; g_kind_val := null; g_vat := null;
    g_price_type_id := null; g_price := null; g_barcode := null;
    if has('CODE') then
      select max(id) into l from ref_product where code = val('CODE');
      pick(l, 'CODE', o_target, o_how, 'товари');
    end if;
    if has('ARTICLE') then
      select max(id) into l from ref_product where state = 'ACTIVE' and upper(article) = upper(val('ARTICLE'));
      pick(l, 'ARTICLE', o_target, o_how, 'товари');
    end if;
    if has('BARCODE') then
      g_barcode := trade_nsi.normalize_barcode(val('BARCODE'));
      select max(product_id) into l from reg_barcode where barcode = g_barcode;
      pick(l, 'BARCODE', o_target, o_how, 'товари');
    end if;
    if o_target is not null and has('CODE') and o_how <> 'CODE' then
      note('Код у файлі «' || val('CODE') || '» не змінює код знайденого товару');
    end if;
    if o_target is not null then
      select max(state) into l_k from ref_product where id = o_target;
      if l_k <> 'ACTIVE' then note('Товар помічений на видалення'); end if;
    end if;
    -- реквізити
    if has('UNIT') then
      g_unit_id := find_unit(val('UNIT'));
      if g_unit_id is null then err('Одиницю виміру «' || val('UNIT') || '» не знайдено'); end if;
    elsif o_target is null then
      g_unit_id := find_unit('шт');
      if g_unit_id is null then err('Не вказано одиницю виміру'); else note('Одиниця виміру — «шт»'); end if;
    end if;
    if has('GROUP') then
      g_group_id := find_group(val('GROUP'), l_cnt);
      if l_cnt > 1 then
        err('Назву групи «' || val('GROUP') || '» мають ' || l_cnt || ' групи — вкажіть код');
      elsif g_group_id is null then
        g_group_new := substr(val('GROUP'), 1, 255);
        if not g_new.exists('PG:' || upper(g_group_new)) then
          note('Буде створено групу «' || g_group_new || '»');
          g_new('PG:' || upper(g_group_new)) := p_row;
        end if;
      end if;
    end if;
    if has('KIND') then
      l_k := lower(val('KIND'));
      g_kind_val := case when l_k in ('товар', 'goods', 'g', 'т') then 'GOODS'
                         when l_k in ('послуга', 'service', 's', 'п', 'послуги') then 'SERVICE' end;
      if g_kind_val is null then err('Вид номенклатури «' || val('KIND') || '» — очікується Товар / Послуга'); end if;
    end if;
    g_weight := num('WEIGHT', 'Вага');
    if has('VAT_RATE') then
      g_vat := find_vat(val('VAT_RATE'));
      if g_vat is null then err('Ставку ПДВ «' || val('VAT_RATE') || '» не знайдено'); end if;
    end if;
    if has('PRICE') then
      g_price := num('PRICE', 'Ціна');
      g_price_type_id := case when has('PRICE_TYPE') then find_price_type(val('PRICE_TYPE')) else g_sess.price_type_id end;
      if g_price_type_id is null then
        err(case when has('PRICE_TYPE') then 'Вид цін «' || val('PRICE_TYPE') || '» не знайдено'
                 else 'Для цін виберіть вид цін у параметрах імпорту' end);
      end if;
    end if;
    if o_target is null and not has('NAME') then err('Не вказано найменування'); end if;
    if has('CODE') and length(val('CODE')) > 9 then err('Код довший за 9 символів'); end if;
    if length(val('ARTICLE')) > 50 then err('Артикул довший за 50 символів'); end if;
    dup(o_target, 'P:' || upper(coalesce(val('CODE'), val('ARTICLE'), g_barcode, val('NAME'))), p_row);
    decide(o_target, o_action);
  end eval_product;

  procedure eval_counterparty (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l varchar2(32); l_cnt number;
  begin
    g_edrpou := replace(val('EDRPOU'), ' ');
    if regexp_like(g_edrpou, '^[0-9]{5,7}$') then
      g_edrpou := lpad(g_edrpou, 8, '0');            -- Excel відкидає нулі попереду
    end if;
    g_iban := upper(replace(val('IBAN'), ' '));
    o_key := coalesce(val('CODE'), g_edrpou, val('NAME'));
    if has('CODE') then
      select max(id) into l from ref_counterparty where code = val('CODE');
      pick(l, 'CODE', o_target, o_how, 'контрагенти');
    end if;
    if g_edrpou is not null then
      select max(id), count(*) into l, l_cnt from ref_counterparty where state = 'ACTIVE' and edrpou = g_edrpou;
      if l_cnt > 1 then
        if o_target is null then err('Код ЄДРПОУ ' || g_edrpou || ' мають ' || l_cnt || ' контрагенти — вкажіть код'); end if;
      else
        pick(l, 'EDRPOU', o_target, o_how, 'контрагенти');
      end if;
    end if;
    g_flag := flag('VAT_PAYER', 'Платник ПДВ');
    if o_target is null and not has('NAME') then err('Не вказано найменування'); end if;
    if has('CODE') and length(val('CODE')) > 9 then err('Код довший за 9 символів'); end if;
    dup(o_target, 'C:' || upper(coalesce(val('CODE'), g_edrpou, val('NAME'))), p_row);
    decide(o_target, o_action);
  end eval_counterparty;

  procedure eval_barcode (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l_owner varchar2(32);
  begin
    g_barcode := trade_nsi.normalize_barcode(val('BARCODE'));
    o_key := g_barcode;
    if g_barcode is null then err('Не вказано штрихкод'); end if;
    find_product_ref(g_product_id, o_how);
    g_qty := num('UNIT_QTY', 'Кількість в упаковці');
    if g_qty = 0 then err('Кількість в упаковці має бути більшою за нуль'); end if;
    select max(id), max(product_id) into o_target, l_owner from reg_barcode where barcode = g_barcode;
    if o_target is not null and l_owner <> g_product_id then
      note('Штрихкод буде перенесено з іншого товару');
    end if;
    dup(null, 'B:' || g_barcode, p_row);
    decide(o_target, o_action);
  end eval_barcode;

  procedure eval_price (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
    l_cur number;
  begin
    o_key := coalesce(val('PRODUCT_CODE'), val('ARTICLE'), val('BARCODE'), val('PRODUCT_NAME'));
    find_product_ref(o_target, o_how);
    if not has('PRICE') then err('Не вказано ціну'); end if;
    g_price := num('PRICE', 'Ціна');
    g_price_type_id := case when has('PRICE_TYPE') then find_price_type(val('PRICE_TYPE')) else g_sess.price_type_id end;
    if g_price_type_id is null then
      err(case when has('PRICE_TYPE') then 'Вид цін «' || val('PRICE_TYPE') || '» не знайдено'
               else 'Виберіть вид цін у параметрах імпорту або додайте колонку «Вид цін»' end);
    end if;
    if o_target is not null and g_price_type_id is not null and g_price is not null then
      select max(price) keep (dense_rank last order by period, recorder_id) into l_cur
        from reg_product_price where product_id = o_target and price_type_id = g_price_type_id
         and period <= coalesce(g_sess.price_date, sysdate);
      if l_cur is null then
        note('Ціну встановлено вперше');
      elsif l_cur = g_price then
        note('Ціна не змінюється');
      else
        note('Поточна ціна ' || to_char(l_cur, 'FM999G999G999G990D00', 'nls_numeric_characters='', '''));
      end if;
    end if;
    dup(null, 'R:' || g_price_type_id || ':' || o_target, p_row);
    o_action := case when g_err is not null then 'ERROR' else 'PRICE' end;
  end eval_price;

  procedure eval_row (p_row in number, o_action out varchar2, o_target out varchar2, o_how out varchar2, o_key out varchar2) is
  begin
    g_err := null; g_note := null;
    case g_sess.import_kind
      when 'UNIT' then eval_unit(p_row, o_action, o_target, o_how, o_key);
      when 'GROUP' then eval_group(p_row, o_action, o_target, o_how, o_key);
      when 'PRODUCT' then eval_product(p_row, o_action, o_target, o_how, o_key);
      when 'COUNTERPARTY' then eval_counterparty(p_row, o_action, o_target, o_how, o_key);
      when 'BARCODE' then eval_barcode(p_row, o_action, o_target, o_how, o_key);
      when 'PRICE' then eval_price(p_row, o_action, o_target, o_how, o_key);
    end case;
  end eval_row;

  procedure check_mapping is
    procedure need (p_fields in varchar2, p_msg in varchar2) is
      l number;
    begin
      select count(*) into l from sys_import_column
       where session_id = g_sess.id and instr(',' || p_fields || ',', ',' || field_code || ',') > 0;
      if l = 0 then fail('IMPORT_MAPPING_REQUIRED', p_msg); end if;
    end;
  begin
    for d in (select field_code, count(*) cnt from sys_import_column
               where session_id = g_sess.id and field_code is not null group by field_code having count(*) > 1) loop
      fail('IMPORT_MAPPING_DUPLICATE', 'Поле «' || d.field_code || '» зіставлено з ' || d.cnt || ' колонками файлу — залиште одну.');
    end loop;
    case g_sess.import_kind
      when 'UNIT' then need('CODE,SHORT_NAME,NAME', 'Зіставте з колонками файлу хоча б код, скорочення або найменування.');
      when 'GROUP' then need('CODE,NAME', 'Зіставте з колонками файлу код або найменування групи.');
      when 'PRODUCT' then need('CODE,ARTICLE,BARCODE,NAME', 'Зіставте з колонками файлу код, артикул, штрихкод або найменування.');
      when 'COUNTERPARTY' then need('CODE,EDRPOU,NAME', 'Зіставте з колонками файлу код, ЄДРПОУ або найменування.');
      when 'BARCODE' then
        need('BARCODE', 'Зіставте колонку «Штрихкод».');
        need('PRODUCT_CODE,ARTICLE,PRODUCT_NAME', 'Зіставте колонку товару: код, артикул або найменування.');
      when 'PRICE' then
        need('PRICE', 'Зіставте колонку «Ціна».');
        need('PRODUCT_CODE,ARTICLE,BARCODE,PRODUCT_NAME', 'Зіставте колонку товару: код, артикул, штрихкод або найменування.');
    end case;
  end check_mapping;

  procedure reset_state is
  begin
    g_seen.delete; g_new.delete; g_prices.delete;
  end reset_state;

  procedure check_rows (p_session in varchar2) is
    l_action varchar2(10); l_target varchar2(32); l_how varchar2(20); l_key varchar2(500);
    l_pc number := 0;
  begin
    load_session(p_session);
    if g_sess.status = 'APPLIED' then
      fail('IMPORT_ALREADY_APPLIED', 'Імпорт уже виконано. Завантажте файл ще раз.');
    end if;
    check_mapping;
    reset_state;
    g_check := true;
    for r in (select row_no, row_data from sys_import_row where session_id = p_session order by row_no) loop
      load_values(p_session, r.row_data);
      eval_row(r.row_no, l_action, l_target, l_how, l_key);
      if l_action = 'PRICE' or (l_action in ('CREATE', 'UPDATE') and g_sess.import_kind = 'PRODUCT' and g_price is not null) then
        l_pc := l_pc + 1;
      end if;
      update sys_import_row
         set action = l_action, target_id = l_target, match_by = l_how, key_text = substr(l_key, 1, 500),
             message = substr(coalesce(g_err, g_note), 1, 4000), result = null, result_id = null
       where session_id = p_session and row_no = r.row_no;
    end loop;
    update sys_import_session s
       set status = 'CHECKED', checked_at = systimestamp,
           created_cnt = (select count(*) from sys_import_row where session_id = s.id and action = 'CREATE'),
           updated_cnt = (select count(*) from sys_import_row where session_id = s.id and action = 'UPDATE'),
           skipped_cnt = (select count(*) from sys_import_row where session_id = s.id and action = 'SKIP'),
           error_cnt   = (select count(*) from sys_import_row where session_id = s.id and action = 'ERROR'),
           price_cnt   = l_pc
     where id = p_session;
  end check_rows;

  -- ------------------------------------------------------------------ запис
  function ensure_group (p_name in varchar2) return varchar2 is
    l varchar2(32); l_cnt number;
  begin
    l := find_group(p_name, l_cnt);
    if l is null then
      insert into ref_product_group (name) values (p_name) returning id into l;
    end if;
    return l;
  end ensure_group;

  procedure add_barcode (p_product in varchar2) is
    l_owner varchar2(32);
  begin
    if g_barcode is null then return; end if;
    select max(product_id) into l_owner from reg_barcode where barcode = g_barcode;
    if l_owner is null then
      insert into reg_barcode (barcode, product_id, unit_quantity) values (g_barcode, p_product, 1);
    elsif l_owner <> p_product then
      fail('IMPORT_BARCODE_OWNER', 'Штрихкод ' || g_barcode || ' уже належить іншому товару.');
    end if;
  end add_barcode;

  procedure add_price (p_row in number, p_product in varchar2) is
    l pls_integer := g_prices.count + 1;
  begin
    if g_price is null or g_price_type_id is null then return; end if;
    g_prices(l).row_no := p_row; g_prices(l).product_id := p_product;
    g_prices(l).price_type_id := g_price_type_id; g_prices(l).price := g_price;
  end add_price;

  function write_row (p_row in number, p_action in varchar2, p_target in varchar2) return varchar2 is
    l_id varchar2(32) := p_target;
    l_set_parent varchar2(1) := case when has('PARENT') then 'Y' else 'N' end;
  begin
    case g_sess.import_kind
      when 'UNIT' then
        if p_action = 'CREATE' then
          insert into ref_unit_of_measure (code, name, short_name, fractional)
          values (val('CODE'), val('NAME'), coalesce(val('SHORT_NAME'), substr(val('NAME'), 1, 20)), nvl(g_flag, 'N'))
          returning id into l_id;
        else
          update ref_unit_of_measure
             set name = nvl(val('NAME'), name), short_name = nvl(val('SHORT_NAME'), short_name), fractional = nvl(g_flag, fractional)
           where id = l_id;
        end if;
      when 'GROUP' then
        if has('PARENT') and g_parent_id is null then
          declare l_cnt number; begin
            g_parent_id := find_group(val('PARENT'), l_cnt);
          end;
          if g_parent_id is null then fail('IMPORT_GROUP_PARENT', 'Батьківську групу «' || val('PARENT') || '» не знайдено.'); end if;
        end if;
        if p_action = 'CREATE' then
          insert into ref_product_group (code, name, parent_id, sort_order) values (val('CODE'), val('NAME'), g_parent_id, nvl(g_sort, 0))
          returning id into l_id;
        else
          update ref_product_group
             set name = nvl(val('NAME'), name),
                 parent_id = case when l_set_parent = 'Y' then g_parent_id else parent_id end,
                 sort_order = nvl(g_sort, sort_order)
           where id = l_id;
        end if;
      when 'PRODUCT' then
        if g_group_new is not null then
          g_group_id := ensure_group(g_group_new);
        end if;
        if p_action = 'CREATE' then
          insert into ref_product (code, name, unit_of_measure_id, group_id, product_kind, article, weight_kg, description,
                                   vat_rate_code, uktzed_code)
          values (val('CODE'), val('NAME'), g_unit_id, g_group_id, nvl(g_kind_val, 'GOODS'), val('ARTICLE'),
                  case when nvl(g_kind_val, 'GOODS') = 'GOODS' then g_weight end, substr(val('DESCRIPTION'), 1, 1000),
                  nvl(g_vat, 'VAT20'), val('UKTZED'))
          returning id into l_id;
        else
          update ref_product
             set name = nvl(val('NAME'), name), unit_of_measure_id = nvl(g_unit_id, unit_of_measure_id),
                 group_id = nvl(g_group_id, group_id), product_kind = nvl(g_kind_val, product_kind),
                 article = nvl(val('ARTICLE'), article), weight_kg = nvl(g_weight, weight_kg),
                 description = nvl(substr(val('DESCRIPTION'), 1, 1000), description),
                 vat_rate_code = nvl(g_vat, vat_rate_code), uktzed_code = nvl(val('UKTZED'), uktzed_code)
           where id = l_id;
        end if;
        add_barcode(l_id);
        add_price(p_row, l_id);
      when 'COUNTERPARTY' then
        if p_action = 'CREATE' then
          insert into ref_counterparty (code, name, edrpou, iban, vat_payer, vat_number)
          values (val('CODE'), val('NAME'), g_edrpou, g_iban, nvl(g_flag, 'N'), val('VAT_NUMBER'))
          returning id into l_id;
        else
          update ref_counterparty
             set name = nvl(val('NAME'), name), edrpou = nvl(g_edrpou, edrpou), iban = nvl(g_iban, iban),
                 vat_payer = nvl(g_flag, vat_payer), vat_number = nvl(val('VAT_NUMBER'), vat_number)
           where id = l_id;
        end if;
      when 'BARCODE' then
        if p_action = 'CREATE' then
          insert into reg_barcode (barcode, product_id, unit_quantity) values (g_barcode, g_product_id, nvl(g_qty, 1))
          returning id into l_id;
        else
          update reg_barcode set product_id = g_product_id, unit_quantity = nvl(g_qty, unit_quantity) where id = l_id;
        end if;
      when 'PRICE' then
        add_price(p_row, p_target);
    end case;
    return l_id;
  end write_row;

  function clean_error (p_msg in varchar2) return varchar2 is
  begin
    return substr(regexp_replace(regexp_substr(p_msg, '^[^' || chr(10) || ']*'), '^ORA-\d+: '), 1, 4000);
  end clean_error;

  -- ціни: документ «Встановлення цін» на кожен вид цін, проводиться
  procedure write_prices is
    l_doc varchar2(32);
    l_pt  varchar2(32);
    l_done t_seen;
  begin
    for i in 1 .. g_prices.count loop
      l_pt := g_prices(i).price_type_id;
      continue when l_done.exists(l_pt);
      l_done(l_pt) := 1;
      savepoint import_prices;
      begin
        insert into doc_price_setting (occurred_at, price_type_id, doc_comment)
        values (nvl(g_sess.price_date, sysdate), l_pt, substr('Імпорт цін з файлу ' || g_sess.file_name, 1, 1000))
        returning id into l_doc;
        for j in 1 .. g_prices.count loop
          if g_prices(j).price_type_id = l_pt then
            insert into doc_price_setting_prices (document_id, product_id, price)
            values (l_doc, g_prices(j).product_id, g_prices(j).price);
          end if;
        end loop;
        trade_ops.post_price_setting(l_doc);
        for j in 1 .. g_prices.count loop
          if g_prices(j).price_type_id = l_pt then
            update sys_import_row
               set result = 'DONE', result_id = case when g_sess.import_kind = 'PRICE' then l_doc else result_id end,
                   message = substr(message || case when message is not null then '; ' end || 'Ціну встановлено документом', 1, 4000)
             where session_id = g_sess.id and row_no = g_prices(j).row_no;
          end if;
        end loop;
      exception when others then
        declare l_m varchar2(4000) := clean_error(sqlerrm); begin
          trade_core.g_internal := false;
          rollback to import_prices;
          for j in 1 .. g_prices.count loop
            if g_prices(j).price_type_id = l_pt then
              update sys_import_row
                 set result = 'ERROR', message = substr('Ціну не встановлено: ' || l_m, 1, 4000)
               where session_id = g_sess.id and row_no = g_prices(j).row_no;
            end if;
          end loop;
        end;
      end;
    end loop;
  end write_prices;

  procedure apply (p_session in varchar2) is
    l_action varchar2(10); l_target varchar2(32); l_how varchar2(20); l_key varchar2(500); l_id varchar2(32);
    l_msg varchar2(4000);
  begin
    load_session(p_session);
    if g_sess.status = 'APPLIED' then
      fail('IMPORT_ALREADY_APPLIED', 'Імпорт уже виконано. Завантажте файл ще раз.');
    elsif g_sess.status <> 'CHECKED' then
      fail('IMPORT_NOT_CHECKED', 'Спочатку виконайте перевірку файлу («Перевірити»).');
    end if;
    check_mapping;
    reset_state;
    g_check := false;
    for r in (select row_no, row_data from sys_import_row where session_id = p_session order by row_no) loop
      load_values(p_session, r.row_data);
      savepoint import_row;
      begin
        eval_row(r.row_no, l_action, l_target, l_how, l_key);   -- повторна перевірка на момент запису
        l_msg := coalesce(g_err, g_note);
        if l_action in ('CREATE', 'UPDATE', 'PRICE') then
          l_id := write_row(r.row_no, l_action, l_target);
          update sys_import_row
             set action = l_action, target_id = l_target, match_by = l_how, key_text = substr(l_key, 1, 500),
                 message = substr(l_msg, 1, 4000), result = case when l_action = 'PRICE' then null else 'DONE' end,
                 result_id = case when l_action = 'PRICE' then null else l_id end
           where session_id = p_session and row_no = r.row_no;
        else
          update sys_import_row
             set action = l_action, target_id = l_target, match_by = l_how, key_text = substr(l_key, 1, 500),
                 message = substr(l_msg, 1, 4000), result = case when l_action = 'SKIP' then 'SKIPPED' else 'ERROR' end,
                 result_id = null
           where session_id = p_session and row_no = r.row_no;
        end if;
      exception when others then
        l_msg := clean_error(sqlerrm);
        trade_core.g_internal := false;
        rollback to import_row;
        -- рядок не записано: прибрати його ціну, якщо додана
        for i in reverse 1 .. g_prices.count loop
          if g_prices(i).row_no = r.row_no then g_prices.delete(i); end if;
        end loop;
        update sys_import_row set action = 'ERROR', result = 'ERROR', result_id = null, message = l_msg
         where session_id = p_session and row_no = r.row_no;
      end;
    end loop;
    -- ущільнити масив цін після можливих видалень
    declare
      l_tmp t_prices; k pls_integer := g_prices.first; n pls_integer := 0;
    begin
      while k is not null loop
        n := n + 1; l_tmp(n) := g_prices(k); k := g_prices.next(k);
      end loop;
      g_prices := l_tmp;
    end;
    write_prices;
    update sys_import_session s
       set status = 'APPLIED', applied_at = systimestamp, applied_by = trade_core.current_user_name,
           created_cnt = (select count(*) from sys_import_row where session_id = s.id and action = 'CREATE' and result = 'DONE'),
           updated_cnt = (select count(*) from sys_import_row where session_id = s.id and action = 'UPDATE' and result = 'DONE'),
           skipped_cnt = (select count(*) from sys_import_row where session_id = s.id and result = 'SKIPPED'),
           error_cnt   = (select count(*) from sys_import_row where session_id = s.id and result = 'ERROR'),
           price_cnt   = (select count(*) from sys_import_row where session_id = s.id and action = 'PRICE' and result = 'DONE')
     where id = p_session
     returning created_cnt, updated_cnt, skipped_cnt, error_cnt, price_cnt
          into g_sess.created_cnt, g_sess.updated_cnt, g_sess.skipped_cnt, g_sess.error_cnt, g_sess.price_cnt;
    trade_core.audit('DataCatalogImport', p_session, 'IMPORT',
      kind_name(g_sess.import_kind) || ': створено ' || g_sess.created_cnt || ', оновлено ' || g_sess.updated_cnt
      || ', цін ' || g_sess.price_cnt || ', пропущено ' || g_sess.skipped_cnt || ', помилок ' || g_sess.error_cnt);
  end apply;

  -- ------------------------------------------------------------------ UI
  function esc (p in varchar2) return varchar2 is begin return apex_escape.html(p); end;

  function fields_html (p_kind in varchar2) return clob is
    l clob;
  begin
    if kind_name(p_kind) is null then
      return '<p>Виберіть, що завантажувати.</p>';
    end if;
    l := '<p>Перший рядок файлу — заголовки колонок. Колонки зіставляються з полями автоматично за заголовками '
      || '(можна змінити на кроці «Зіставлення колонок»). Порожня клітинка під час оновлення не змінює значення.</p>'
      || '<table class="tx-table"><thead><tr><th>Поле</th><th>Обов''язкове</th><th>Заголовки, що розпізнаються</th><th>Примітка</th></tr></thead><tbody>';
    for f in (select * from table(trade_import.fields(p_kind)) order by ord) loop
      l := l || '<tr><td><b>' || esc(f.field_name) || '</b></td><td>' || case f.required when 'Y' then 'так (для нових)' else '—' end
        || '</td><td>' || esc(replace(f.synonyms, '|', ', ')) || '</td><td>' || esc(f.hint) || '</td></tr>';
    end loop;
    return l || '</tbody></table>';
  end fields_html;

  function mapping_html (p_session in varchar2) return clob is
    l clob;
    l_kind varchar2(20);
    l_status varchar2(10);
  begin
    select max(import_kind), max(status) into l_kind, l_status from sys_import_session where id = p_session;
    if l_kind is null then return null; end if;
    l := '<table class="tx-table tx-import-map"><thead><tr><th>№</th><th>Колонка файлу</th><th>Приклад значення</th>'
      || '<th>Поле довідника «' || esc(kind_name(l_kind)) || '»</th></tr></thead><tbody>';
    for c in (select col_no, header, sample, field_code from sys_import_column where session_id = p_session order by col_no) loop
      l := l || '<tr><td>' || c.col_no || '</td><td>' || esc(c.header) || '</td><td>' || esc(c.sample) || '</td><td>'
        || '<input type="hidden" name="f02" value="' || c.col_no || '">'
        || '<select name="f01" class="selectlist apex-item-select"' || case when l_status = 'APPLIED' then ' disabled' end || '>'
        || '<option value="">— не завантажувати —</option>';
      for f in (select * from table(trade_import.fields(l_kind)) order by ord) loop
        l := l || '<option value="' || f.field_code || '"' || case when f.field_code = c.field_code then ' selected' end || '>'
          || esc(f.field_name) || case when f.required = 'Y' then ' *' end || '</option>';
      end loop;
      l := l || '</select></td></tr>';
    end loop;
    return l || '</tbody></table>';
  end mapping_html;

  function summary_html (p_session in varchar2) return clob is
    l clob;
    s sys_import_session%rowtype;
    l_pt varchar2(255);
    function cell (p_label varchar2, p_val varchar2) return varchar2 is
    begin
      return '<tr><th style="text-align:left;padding-right:16px">' || p_label || '</th><td>' || p_val || '</td></tr>';
    end;
  begin
    begin
      select * into s from sys_import_session where id = p_session;
    exception when no_data_found then
      return null;
    end;
    select max(name) into l_pt from ref_price_type where id = s.price_type_id;
    l := '<table class="tx-table">'
      || cell('Довідник', esc(kind_name(s.import_kind))) || cell('Файл', esc(s.file_name))
      || cell('Режим', esc(mode_name(s.import_mode)))
      || case when s.import_kind in ('PRODUCT', 'PRICE') then
           cell('Вид цін / дата', esc(nvl(l_pt, '—')) || ' / ' || nvl(to_char(s.price_date, 'DD.MM.YYYY'), 'поточна')) end
      || cell('Рядків у файлі', s.total_rows)
      || cell('Стан', case s.status when 'LOADED' then 'Завантажено — перевірте зіставлення колонок і натисніть «Перевірити»'
                                    when 'CHECKED' then '<b>Перевірено</b> — перегляньте рядки й натисніть «Виконати імпорт»'
                                    else '<b>Імпорт виконано</b> ' || to_char(s.applied_at, 'DD.MM.YYYY HH24:MI') || ' (' || esc(s.applied_by) || ')' end);
    if s.status in ('CHECKED', 'APPLIED') then
      l := l || cell(case s.status when 'CHECKED' then 'Буде створено' else 'Створено' end, s.created_cnt)
             || cell(case s.status when 'CHECKED' then 'Буде оновлено' else 'Оновлено' end, s.updated_cnt);
      if s.import_kind = 'PRICE' or s.price_cnt > 0 then
        l := l || cell(case s.status when 'CHECKED' then 'Цін до встановлення' else 'Цін встановлено' end, s.price_cnt);
      end if;
      l := l || cell('Пропущено', s.skipped_cnt)
             || cell('Помилок', case when s.error_cnt > 0 then '<b style="color:#c00">' || s.error_cnt || '</b>' else '0' end);
    end if;
    if s.status = 'APPLIED' then
      for d in (select distinct d.id, d.doc_number, pt.name from doc_price_setting d join ref_price_type pt on pt.id = d.price_type_id
                 where d.doc_comment = substr('Імпорт цін з файлу ' || s.file_name, 1, 1000)
                   and d.created_at between s.checked_at and s.applied_at + interval '1' minute) loop
        l := l || cell('Документ цін', case when apex_util.get_session_state('APP_ID') is not null then
                   '<a href="' || apex_page.get_url(p_page => 101, p_items => 'P101_ID', p_values => d.id) || '">' end
                 || 'Встановлення цін № ' || esc(d.doc_number) || ' (' || esc(d.name) || ')'
                 || case when apex_util.get_session_state('APP_ID') is not null then '</a>' end);
      end loop;
    end if;
    return l || '</table>';
  end summary_html;

  function csv_cell (p in varchar2) return varchar2 is
  begin
    if p is null then return null; end if;
    if instr(p, ';') > 0 or instr(p, '"') > 0 or instr(p, chr(10)) > 0 then
      return '"' || replace(p, '"', '""') || '"';
    end if;
    return p;
  end csv_cell;

  function template_csv (p_kind in varchar2) return clob is
    l clob;
  begin
    for f in (select * from table(trade_import.fields(p_kind)) order by ord) loop
      l := l || case when f.ord > 1 then ';' end || csv_cell(f.field_name);
    end loop;
    return l || chr(13) || chr(10);
  end template_csv;

  function errors_csv (p_session in varchar2) return clob is
    l clob := 'Рядок;Дія;Результат;Ключ;Повідомлення;Дані рядка' || chr(13) || chr(10);
  begin
    for r in (select * from sys_import_row where session_id = p_session
                and (action in ('ERROR', 'SKIP') or result in ('ERROR', 'SKIPPED')) order by row_no) loop
      l := l || r.row_no || ';' || csv_cell(action_name(r.action)) || ';'
        || csv_cell(case r.result when 'DONE' then 'Записано' when 'SKIPPED' then 'Пропущено' when 'ERROR' then 'Помилка' end) || ';'
        || csv_cell(r.key_text) || ';' || csv_cell(r.message) || ';' || csv_cell(r.row_text) || chr(13) || chr(10);
    end loop;
    return l;
  end errors_csv;

  procedure send (p_name in varchar2, p_body in clob) is
    l_off integer := 1; l_len integer := dbms_lob.getlength(p_body);
  begin
    owa_util.mime_header('text/csv', false, 'UTF-8');
    htp.p('Content-Disposition: attachment; filename="' || p_name || '"');
    owa_util.http_header_close;
    htp.prn(unistr('\FEFF'));         -- BOM: Excel відкриває UTF-8 з кирилицею
    while l_off <= l_len loop
      htp.prn(dbms_lob.substr(p_body, 8000, l_off));
      l_off := l_off + 8000;
    end loop;
    apex_application.stop_apex_engine;
  end send;

  procedure download_template (p_kind in varchar2) is
  begin
    if kind_name(p_kind) is null then
      fail('IMPORT_KIND', 'Виберіть, що завантажувати (довідник).');
    end if;
    send('import_' || lower(p_kind) || '.csv', template_csv(p_kind));
  end download_template;

  procedure download_errors (p_session in varchar2) is
  begin
    send('import_errors.csv', errors_csv(p_session));
  end download_errors;
end trade_import;
/
show errors package body trade_import

-- ---------------------------------------------------------------- представлення для сторінки
create or replace view v_import_row as
select r.session_id, r.row_no, r.key_text, r.action, trade_import.action_name(r.action) action_name,
       case r.match_by when 'CODE' then 'Код' when 'ARTICLE' then 'Артикул' when 'BARCODE' then 'Штрихкод'
                       when 'EDRPOU' then 'ЄДРПОУ' when 'SHORT_NAME' then 'Скорочення' when 'NAME' then 'Найменування' end match_by_name,
       case r.result when 'DONE' then 'Записано' when 'SKIPPED' then 'Пропущено' when 'ERROR' then 'Помилка' end result_name,
       r.result, r.message, r.row_text, r.target_id, r.result_id,
       case when r.action = 'ERROR' or r.result = 'ERROR' then 'fa-times-circle u-danger-text'
            when r.action = 'SKIP' or r.result = 'SKIPPED' then 'fa-minus-circle'
            when r.result = 'DONE' then 'fa-check-circle u-success-text'
            when r.action = 'CREATE' then 'fa-plus-circle'
            else 'fa-pencil' end icon_class
  from sys_import_row r;

create or replace view v_import_session as
select s.id, s.created_at, s.created_by, s.import_kind, trade_import.kind_name(s.import_kind) kind_name,
       trade_import.mode_name(s.import_mode) mode_name, s.file_name, s.total_rows,
       case s.status when 'LOADED' then 'Завантажено' when 'CHECKED' then 'Перевірено' else 'Виконано' end status_name,
       s.status, s.created_cnt, s.updated_cnt, s.price_cnt, s.skipped_cnt, s.error_cnt, s.applied_at
  from sys_import_session s;

-- ---------------------------------------------------------------- меню: «НСІ та адміністрування → Сервіс»
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
  obj('DataCatalogImport', 'REPORT', 'Reports', 'Імпорт довідників', 670, null, 260, 'Роль: адміністратор');
  fp('Reference', 'Сервіс', 2, 90, 'DataCatalogImport', 20);
  commit;
end;
/
