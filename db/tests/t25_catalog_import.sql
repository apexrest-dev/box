-- F-SRV-06 «Імпорт довідників» (DataCatalogImport, trade_import): розбір CSV (роздільник «;» / «,», лапки),
-- автоматичне зіставлення колонок за заголовками й ручна зміна, перевірка (дії CREATE / UPDATE / SKIP / ERROR /
-- PRICE), пошук існуючих за кодом / артикулом / штрихкодом / ЄДРПОУ (втрачені нулі), режими «лише створювати» /
-- «лише оновлювати», дублікати рядків, одиниці виміру, ієрархія груп, номенклатура зі штрихкодом і ціною
-- (документ «Встановлення цін» проведено), контрагенти, штрихкоди, ціни за видами цін, помилки рядка не зупиняють
-- інші, звіт помилок CSV, шаблон, HTML кроків, меню й права. Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(8) := substr(rawtohex(sys_guid()), 1, 6);
  nl varchar2(2) := chr(10);
  s varchar2(32); l_pt_r varchar2(32); l_pt_w varchar2(32); l_uom varchar2(32); l_p1 varchar2(32); l_p2 varchar2(32);
  l_cp varchar2(32); l_id varchar2(32); l_n number; l_s varchar2(4000); l_c clob; bc1 varchar2(13); bc2 varchar2(13);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got
      || case when p_got is null or p_got <> p_exp then ' (очікується ' || p_exp || ')' end);
  end;
  procedure ok (p_name varchar2, p_cond boolean) is
  begin
    dbms_output.put_line(case when p_cond then 'OK  ' else 'FAIL' end || ' ' || p_name);
  end;
  procedure fails (p_name varchar2, p_code varchar2, p_sql varchar2) is
  begin
    savepoint before_fail;
    execute immediate p_sql;
    dbms_output.put_line('FAIL (помилки не було): ' || p_name);
    rollback to before_fail;
  exception when others then
    rollback to before_fail;
    dbms_output.put_line(case when instr(sqlerrm, p_code) > 0 then 'OK  ' else 'FAIL' end || ' ' || p_name || ' → ' || regexp_replace(sqlerrm, '^ORA-\d+: '));
  end;
  function ean (p12 varchar2) return varchar2 is
    l number := 0;
  begin
    for i in 1 .. 12 loop
      l := l + to_number(substr(p12, i, 1)) * case when mod(i, 2) = 0 then 3 else 1 end;
    end loop;
    return p12 || mod(10 - mod(l, 10), 10);
  end;
  function act (p_row number) return varchar2 is
    l varchar2(100);
  begin
    select max(action || case when result is not null then '/' || result end) into l from sys_import_row where session_id = s and row_no = p_row;
    return l;
  end;
  function msg (p_row number) return varchar2 is
    l varchar2(4000);
  begin
    select max(message) into l from sys_import_row where session_id = s and row_no = p_row;
    return l;
  end;
  function cnt (p_action varchar2) return number is
    l number;
  begin
    select count(*) into l from sys_import_row where session_id = s and action = p_action;
    return l;
  end;
  function fld (p_col number) return varchar2 is
    l varchar2(30);
  begin
    select max(field_code) into l from sys_import_column where session_id = s and col_no = p_col;
    return l;
  end;
  function price_of (p_prd varchar2, p_pt varchar2) return number is
    l number;
  begin
    select max(price) keep (dense_rank last order by period, recorder_id) into l from reg_product_price
     where product_id = p_prd and price_type_id = p_pt;
    return l;
  end;
begin
  select id into l_pt_r from ref_price_type where name = 'Роздрібна';
  select id into l_pt_w from ref_price_type where name = 'Оптова';
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';

  -- ---------------------------------------------------------------- розбір значень
  eq('parse_number «1 234,50»', trade_import.parse_number('1 234,50'), 1234.5);
  eq('parse_number «1.234.567,89»', trade_import.parse_number('1.234.567,89'), 1234567.89);
  eq('parse_number «12.5»', trade_import.parse_number('12.5'), 12.5);
  ok('parse_number «abc» → null', trade_import.parse_number('abc') is null);
  eqs('parse_flag «Так»', trade_import.parse_flag('Так'), 'Y');
  eqs('parse_flag «0»', trade_import.parse_flag('0'), 'N');
  eqs('parse_flag «може»', trade_import.parse_flag('може'), 'X');
  eqs('normalize_header «Од. вим.»', trade_import.normalize_header(' Од. вим. '), 'од вим');
  select count(*) into l_n from table(trade_import.fields('PRODUCT'));
  eq('Полів номенклатури', l_n, 13);

  -- ---------------------------------------------------------------- контролі файлу
  fails('Порожній файл', 'IMPORT_FILE_EMPTY', q'[declare x varchar2(32); begin x := trade_import.load_text('UNIT', 'CREATE_UPDATE', null); end;]');
  fails('Лише заголовки', 'IMPORT_FILE_NO_ROWS', q'[declare x varchar2(32); begin x := trade_import.load_text('UNIT', 'CREATE_UPDATE', 'Код;Найменування'); end;]');
  fails('Невідомий довідник', 'IMPORT_KIND', q'[declare x varchar2(32); begin x := trade_import.load_text('WAREHOUSE', null, 'a;b' || chr(10) || '1;2'); end;]');
  fails('Формат PDF', 'IMPORT_FILE_FORMAT', q'[declare x varchar2(32); begin x := trade_import.load_file('UNIT', null, 'a.pdf', utl_raw.cast_to_raw('x')); end;]');

  -- ---------------------------------------------------------------- одиниці виміру
  s := trade_import.load_text('UNIT', 'CREATE_UPDATE',
         'Код;Найменування;Скорочення;Дробова' || nl || ';Метр ' || t || ';м' || t || ';так' || nl
         || ';Ящик ' || t || ';я' || t || ';ні' || nl || ';;;' || nl || '000000001;Штука;шт;не знаю');
  select total_rows into l_n from sys_import_session where id = s;
  eq('Одиниці: рядків (порожній пропущено)', l_n, 3);
  eqs('Автозіставлення: Код', fld(1), 'CODE');
  eqs('Автозіставлення: Скорочення', fld(3), 'SHORT_NAME');
  eqs('Автозіставлення: Дробова', fld(4), 'FRACTIONAL');
  fails('Імпорт без перевірки', 'IMPORT_NOT_CHECKED', 'begin trade_import.apply(''' || s || '''); end;');
  trade_import.check_rows(s);
  eqs('Метр — створення', act(2), 'CREATE');
  eqs('Штука: помилка ознаки', act(5), 'ERROR');
  ok('Штука: повідомлення', instr(msg(5), 'Так / Ні') > 0);
  trade_import.apply(s);
  select count(*) into l_n from ref_unit_of_measure where short_name in ('м' || t, 'я' || t);
  eq('Одиниці створено', l_n, 2);
  select count(*) into l_n from ref_unit_of_measure where short_name = 'м' || t and fractional = 'Y' and code is not null;
  eq('Метр: дробова, автокод', l_n, 1);
  select created_cnt * 100 + error_cnt into l_n from sys_import_session where id = s;
  eq('Підсумок: створено 2, помилок 1', l_n, 201);
  fails('Повторне виконання', 'IMPORT_ALREADY_APPLIED', 'begin trade_import.apply(''' || s || '''); end;');
  ok('Звіт помилок містить рядок 5', instr(trade_import.errors_csv(s), chr(10) || '5;') > 0);

  -- ---------------------------------------------------------------- групи (ієрархія)
  s := trade_import.load_text('GROUP', null,
         'Назва,Батьківська група' || nl || 'Імп-Електроніка ' || t || ',' || nl
         || 'Імп-Телефони ' || t || ',Імп-Електроніка ' || t || nl || 'Імп-X ' || t || ',Невідома ' || t);
  eqs('Групи: роздільник «,» і заголовок «Назва»', fld(1), 'NAME');
  trade_import.check_rows(s);
  eqs('Група 1 — створення', act(2), 'CREATE');
  eqs('Група 2 — створення (батько з рядка 2)', act(3), 'CREATE');
  ok('Група 2 — примітка', instr(msg(3), 'рядка 2') > 0);
  eqs('Група з невідомим батьком — помилка', act(4), 'ERROR');
  trade_import.apply(s);
  select count(*) into l_n from ref_product_group c join ref_product_group p on p.id = c.parent_id
   where c.name = 'Імп-Телефони ' || t and p.name = 'Імп-Електроніка ' || t;
  eq('Підгрупа в батьківській групі', l_n, 1);
  -- повторний файл: знаходить за назвою серед груп того самого батька
  s := trade_import.load_text('GROUP', null, 'Назва;Батьківська група;Порядок' || nl || 'Імп-Телефони ' || t || ';Імп-Електроніка ' || t || ';5');
  trade_import.check_rows(s);
  eqs('Група за назвою — оновлення', act(2), 'UPDATE');
  trade_import.apply(s);
  select max(sort_order) into l_n from ref_product_group where name = 'Імп-Телефони ' || t;
  eq('Порядок оновлено', l_n, 5);

  -- ---------------------------------------------------------------- номенклатура зі штрихкодом і ціною
  insert into ref_product (name, unit_of_measure_id, article) values ('Імп-існуючий ' || t, l_uom, 'EX-' || t) returning id into l_p1;
  bc1 := ean('48' || lpad(mod(to_number(t, 'XXXXXX'), 1e10), 10, '0'));
  bc2 := ean('47' || lpad(mod(to_number(t, 'XXXXXX'), 1e10), 10, '0'));
  insert into ref_product (name, unit_of_measure_id) values ('Імп-за штрихкодом ' || t, l_uom) returning id into l_id;
  insert into reg_barcode (barcode, product_id) values (bc2, l_id);
  s := trade_import.load_text('PRODUCT', 'CREATE_UPDATE',
         'Артикул,Найменування,Од.,Група,"Ціна",Штрихкод,ПДВ,Вид' || nl
         || 'NEW-' || t || ',"Товар ""Новий"" ' || t || '",кг,Імп-Нова ' || t || ',"12,50",' || bc1 || ',7,' || nl
         || 'EX-' || t || ',Імп-існуючий (нова назва) ' || t || ',,,99,,,' || nl
         || 'BAD-' || t || ',Поганий ' || t || ',ящик-невідомий,,,,,' || nl
         || 'NEW-' || t || ',Дубль ' || t || ',,,,,,' || nl
         || 'SRV-' || t || ',Послуга ' || t || ',,,abc,,звільнено,послуга' || nl
         || ',За штрихкодом ' || t || ',,,,' || bc2 || ',,',
         l_pt_r, trunc(sysdate));
  eqs('Номенклатура: «Од.» → одиниця', fld(3), 'UNIT');
  eqs('Номенклатура: «ПДВ» → ставка', fld(7), 'VAT_RATE');
  eqs('Номенклатура: «Вид» → вид номенклатури', fld(8), 'KIND');
  trade_import.check_rows(s);
  eqs('Новий товар — створення', act(2), 'CREATE');
  ok('Новий товар — примітка про нову групу', instr(msg(2), 'створено групу') > 0);
  eqs('Існуючий за артикулом — оновлення', act(3), 'UPDATE');
  eqs('Невідома одиниця — помилка', act(4), 'ERROR');
  eqs('Дубль артикулу у файлі — помилка', act(5), 'ERROR');
  ok('Дубль — повідомлення', instr(msg(5), 'рядок 2') > 0);
  eqs('Ціна «abc» — помилка', act(6), 'ERROR');
  eqs('Пошук за штрихкодом — оновлення', act(7), 'UPDATE');
  select max(match_by) into l_s from sys_import_row where session_id = s and row_no = 7;
  eqs('Спосіб пошуку — штрихкод', l_s, 'BARCODE');
  select price_cnt into l_n from sys_import_session where id = s;
  eq('Цін до встановлення', l_n, 2);
  ok('summary_html: «Перевірено»', instr(trade_import.summary_html(s), 'Перевірено') > 0);
  ok('mapping_html: списки f01', instr(trade_import.mapping_html(s), 'name="f01"') > 0);
  trade_import.apply(s);
  select max(id) into l_p2 from ref_product where article = 'NEW-' || t;
  ok('Новий товар створено', l_p2 is not null);
  select count(*) into l_n from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id
    join ref_product_group g on g.id = p.group_id
   where p.id = l_p2 and u.short_name = 'кг' and g.name = 'Імп-Нова ' || t and p.vat_rate_code = 'VAT7'
     and p.name = 'Товар "Новий" ' || t and p.product_kind = 'GOODS';
  eq('Реквізити нового товару (лапки, одиниця, група, ПДВ)', l_n, 1);
  select count(*) into l_n from reg_barcode where barcode = bc1 and product_id = l_p2;
  eq('Штрихкод нового товару', l_n, 1);
  eq('Роздрібна ціна нового товару', price_of(l_p2, l_pt_r), 12.5);
  eq('Ціна існуючого товару', price_of(l_p1, l_pt_r), 99);
  select count(*) into l_n from ref_product where id = l_p1 and name = 'Імп-існуючий (нова назва) ' || t and article = 'EX-' || t;
  eq('Існуючий товар перейменовано, артикул збережено', l_n, 1);
  select count(*) into l_n from doc_price_setting where doc_comment like 'Імпорт цін з файлу%' and status = 'POSTED'
     and id in (select recorder_id from reg_product_price where product_id = l_p2);
  eq('Документ «Встановлення цін» проведено', l_n, 1);
  select count(*) into l_n from sys_import_row where session_id = s and result = 'DONE';
  eq('Записано рядків', l_n, 3);
  ok('summary_html: документ цін', instr(trade_import.summary_html(s), 'Встановлення цін №') > 0);

  -- ---------------------------------------------------------------- режими
  s := trade_import.load_text('PRODUCT', 'UPDATE_ONLY', 'Артикул;Найменування' || nl || 'NONE-' || t || ';Нема' || nl || 'EX-' || t || ';Оновлено ' || t);
  trade_import.check_rows(s);
  eqs('Лише оновлювати: невідомий — пропуск', act(2), 'SKIP');
  eqs('Лише оновлювати: існуючий — оновлення', act(3), 'UPDATE');
  trade_import.set_options(s, 'CREATE_ONLY', null, null);
  trade_import.check_rows(s);
  eqs('Лише створювати: невідомий — створення', act(2), 'CREATE');
  eqs('Лише створювати: існуючий — пропуск', act(3), 'SKIP');
  -- ручне зіставлення
  trade_import.set_mapping(s, 2, 'DESCRIPTION');
  trade_import.check_rows(s);
  eqs('Без найменування новий — помилка', act(2), 'ERROR');
  trade_import.set_mapping(s, 2, 'ARTICLE');
  fails('Поле в двох колонках', 'IMPORT_MAPPING_DUPLICATE', 'begin trade_import.check_rows(''' || s || '''); end;');
  fails('Невідоме поле', 'IMPORT_FIELD_UNKNOWN', 'begin trade_import.set_mapping(''' || s || ''', 1, ''FOO''); end;');
  trade_import.set_mapping(s, 1, null);
  trade_import.set_mapping(s, 2, null);
  fails('Немає ключових колонок', 'IMPORT_MAPPING_REQUIRED', 'begin trade_import.check_rows(''' || s || '''); end;');

  -- ---------------------------------------------------------------- контрагенти (ЄДРПОУ з втраченим нулем)
  update ref_counterparty set edrpou = null where edrpou = '01234567';
  insert into ref_counterparty (name, edrpou) values ('Імп-контрагент ' || t, '01234567') returning id into l_cp;
  s := trade_import.load_text('COUNTERPARTY', null,
         'Код за ЄДРПОУ;Назва;Платник ПДВ;ІПН' || nl || '1234567;Імп-контрагент (ТОВ) ' || t || ';;' || nl
         || '123;Поганий ЄДРПОУ ' || t || ';;' || nl || ';Новий ' || t || ';так;123456789012');
  eqs('Контрагенти: «Код за ЄДРПОУ»', fld(1), 'EDRPOU');
  trade_import.check_rows(s);
  eqs('За ЄДРПОУ — оновлення', act(2), 'UPDATE');
  select max(match_by) into l_s from sys_import_row where session_id = s and row_no = 2;
  eqs('Спосіб пошуку — ЄДРПОУ', l_s, 'EDRPOU');
  eqs('Невірний ЄДРПОУ на перевірці — створення', act(3), 'CREATE');
  trade_import.apply(s);
  select count(*) into l_n from ref_counterparty where id = l_cp and name = 'Імп-контрагент (ТОВ) ' || t;
  eq('Контрагента перейменовано', l_n, 1);
  eqs('Невірний ЄДРПОУ — помилка запису', act(3), 'ERROR/ERROR');
  ok('Повідомлення тригера', instr(msg(3), 'ЄДРПОУ') > 0);
  select count(*) into l_n from ref_counterparty where name = 'Новий ' || t and vat_payer = 'Y' and vat_number = '123456789012';
  eq('Новий контрагент — платник ПДВ (помилка рядка не зупинила інші)', l_n, 1);

  -- ---------------------------------------------------------------- штрихкоди
  select code into l_s from ref_product where id = l_p2;
  s := trade_import.load_text('BARCODE', null,
         'Штрихкод;Код товару;Кількість в упаковці' || nl || ean('4999' || substr(bc1, 5, 8)) || ';'
         || l_s || ';6' || nl || '2000000000000;NOPE' || t || ';1');
  trade_import.check_rows(s);
  eqs('Новий штрихкод — створення', act(2), 'CREATE');
  eqs('Невідомий товар — помилка', act(3), 'ERROR');
  trade_import.apply(s);
  select count(*) into l_n from reg_barcode where product_id = l_p2 and unit_quantity = 6;
  eq('Штрихкод упаковки ×6', l_n, 1);

  -- ---------------------------------------------------------------- ціни за видами цін
  s := trade_import.load_text('PRICE', null,
         'Артикул;Ціна;Вид цін' || nl || 'NEW-' || t || ';15;' || nl || 'NEW-' || t || ';11,40;Оптова' || nl
         || 'EX-' || t || ';-1;' || nl || 'EX-' || t || ';100;Невідомий вид',
         l_pt_r, trunc(sysdate));
  trade_import.check_rows(s);
  eqs('Ціна — дія PRICE', act(2), 'PRICE');
  ok('Ціна — поточна ціна в примітці', instr(msg(2), 'Поточна ціна 12,50') > 0);
  eqs('Від''ємна ціна — помилка', act(4), 'ERROR');
  eqs('Невідомий вид цін — помилка', act(5), 'ERROR');
  trade_import.apply(s);
  eq('Нова роздрібна ціна', price_of(l_p2, l_pt_r), 15);
  eq('Оптова ціна', price_of(l_p2, l_pt_w), 11.4);
  select count(distinct result_id) into l_n from sys_import_row where session_id = s and result = 'DONE';
  eq('Два документи цін (по виду цін)', l_n, 2);
  select price_cnt * 10 + error_cnt into l_n from sys_import_session where id = s;
  eq('Підсумок: цін 2, помилок 2', l_n, 22);

  -- ---------------------------------------------------------------- UI, журнал, меню
  ok('Шаблон CSV', trade_import.template_csv('COUNTERPARTY') like 'Код;ЄДРПОУ / РНОКПП;Найменування;%');
  ok('fields_html', instr(trade_import.fields_html('PRICE'), 'Вид цін') > 0);
  select count(*) into l_n from v_import_session where id = s and status_name = 'Виконано' and kind_name = 'Ціни номенклатури';
  eq('v_import_session', l_n, 1);
  select count(*) into l_n from v_import_row where session_id = s and icon_class like 'fa-check%';
  eq('v_import_row: записані', l_n, 2);
  select count(*) into l_n from sys_audit_log where object_type = 'DataCatalogImport' and object_id = s and action in ('IMPORT_LOAD', 'IMPORT');
  eq('Журнал: завантаження й імпорт', l_n, 2);
  select count(*) into l_n from sys_metadata_object where tech_name = 'DataCatalogImport' and list_page_id = 670 and auth_scheme = 'Роль: адміністратор';
  eq('Об''єкт меню', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_main_menu_section m on m.id = f.section_id
    join sys_metadata_object o on o.id = f.object_id
   where m.tech_name = 'Reference' and f.group_name = 'Сервіс' and o.tech_name = 'DataCatalogImport';
  eq('Панель «НСІ та адміністрування → Сервіс»', l_n, 1);
  select count(*) into l_n from apex_application_pages where application_id = 100 and page_id = 670 and authorization_scheme = 'Роль: адміністратор';
  eq('Сторінка 670 — лише адміністратор', l_n, 1);
  select count(*) into l_n from apex_application_page_items where application_id = 100 and page_id = 670 and item_name = 'P670_FILE'
     and display_as_code = 'NATIVE_FILE';
  eq('Поле завантаження файлу', l_n, 1);
  rollback;
exception when others then
  dbms_output.put_line('FAIL (виняток): ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
exit
