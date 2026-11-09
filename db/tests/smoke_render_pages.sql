-- Серверний smoke-тест рендерингу сторінок застосунку 100.
-- Створює APEX-сесію від імені адміністратора (користувач з роллю ADMIN «Адміністратор», без пароля —
-- apex_session.create_session), рендерить КОЖНУ сторінку з apex_application_pages (крім глобальної 0 і входу 9999)
-- через wwv_flow.show + owa.get_page без параметрів; модальні діалоги — з dialogCs з apex_page.get_url.
-- Форми з первинним ключем P<N>_ID додатково рендеряться в режимі редагування наявного запису (P<N>_ID = max(id)
-- з таблиці форми кладеться у стан сесії) — рядок «page N <назва> /edit P<N>_ID=…».
-- Помилки шукаються в HTML (обірваний/порожній вихід, ORA-, «Label Column Span», report error, t-Alert--danger,
-- непорожній APEX_ERROR_MESSAGE) і в apex_debug_messages (рівень 1 та винятки final_exception_handler).
-- Друкує «OK   page N <назва>» / «FAIL page N <назва>: <помилка>» і підсумок.
-- Дані не змінюються: процеси рендерингу лише читають (formInitialization, заголовки), кожен запит
-- завершується rollback; сесія APEX видаляється наприкінці. (wwv_flow.show сам фіксує стан сесії APEX.)
-- Запуск: cd db/tests && sql -name trade-local @smoke_render_pages.sql < /dev/null
set serveroutput on size unlimited feedback off define off
declare
  c_app    constant number := 100;
  type t_case is record (page_id number, name varchar2(400), item varchar2(128), val varchar2(4000),
                         dialog_cs varchar2(4000));
  type t_cases is table of t_case index by pls_integer;
  l_cases  t_cases;
  c        t_case;
  l_user   varchar2(255);
  l_sess   number;
  l_pg     htp.htbuf_arr;
  l_rows   integer;
  l_html   clob;
  l_err    varchar2(4000);
  l_dbg    varchar2(4000);
  l_dbg_id number;
  l_ok     pls_integer := 0;
  l_fail   pls_integer := 0;
  l_url    varchar2(32767);
  l_id     varchar2(4000);
  l_names  owa.vc_arr;
  l_vals   owa.vc_arr;

  -- перший збіг шаблону з HTML, без тегів і зайвих пробілів
  function grab (p_pattern varchar2) return varchar2 is
  begin
    return substr(regexp_replace(regexp_replace(regexp_substr(l_html, p_pattern, 1, 1, 'n'), '<[^>]*>', ' '),
                                 '\s+', ' '), 1, 200);
  end;
  procedure add_case (p_page number, p_name varchar2, p_dialog boolean, p_item varchar2 default null,
                      p_val varchar2 default null) is
    n pls_integer := l_cases.count + 1;
  begin
    l_cases(n).page_id := p_page; l_cases(n).name := p_name;
    l_cases(n).item := p_item;    l_cases(n).val := p_val;
    -- apex_page.get_url потребує ініціалізованих глобальних APEX — рахуємо все до першого wwv_flow.show
    l_url := apex_page.get_url(p_page => p_page, p_items => p_item, p_values => p_val);
    if p_dialog then l_url := utl_url.unescape(l_url); end if;   -- діалог: URL вкладено в #action$a-dialog-open?url=
    l_cases(n).dialog_cs := regexp_substr(l_url, '[?&]dialogCs=([^&]+)', 1, 1, null, 1);
  end;
begin
  begin
    select min(user_name) into l_user from apex_appl_acl_user_roles
     where application_id = c_app and role_static_id = 'ADMIN';
  exception when no_data_found then null;
  end;
  l_user := nvl(l_user, 'DEVELOPER');
  apex_session.create_session(p_app_id => c_app, p_page_id => 1, p_username => l_user);
  l_sess := v('APP_SESSION');
  dbms_output.put_line('Сесія ' || l_sess || ', користувач ' || l_user);

  for p in (select page_id, page_name, page_mode from apex_application_pages
             where application_id = c_app and page_id not in (0, 9999) order by page_id) loop
    add_case(p.page_id, p.page_name || case when p.page_mode <> 'Normal' then ' [' || p.page_mode || ']' end,
             p.page_mode like '%Dialog%');
    -- форма з ключем P<N>_ID: ще й режим редагування наявного запису
    for f in (select r.table_name, i.item_name
                from apex_application_page_regions r
                join apex_application_page_items i
                  on i.application_id = r.application_id and i.page_id = r.page_id and i.region_id = r.region_id
                 and i.item_name = 'P' || r.page_id || '_ID'
               where r.application_id = c_app and r.page_id = p.page_id and r.source_type_code = 'NATIVE_FORM'
                 and r.table_name is not null) loop
      execute immediate 'select max(id) from ' || dbms_assert.simple_sql_name(f.table_name) into l_id;
      if l_id is not null then
        add_case(p.page_id, p.page_name || ' /edit ' || f.item_name || '=' || l_id, p.page_mode like '%Dialog%',
                 f.item_name, l_id);
      end if;
    end loop;
    -- майстер імпорту (F-SRV-06): ще й з останнім сеансом імпорту (зіставлення, стан, рядки)
    for f in (select i.item_name from apex_application_page_items i
               where i.application_id = c_app and i.page_id = p.page_id and i.item_name = 'P' || p.page_id || '_SESSION') loop
      select max(id) keep (dense_rank last order by created_at) into l_id from sys_import_session;
      if l_id is not null then
        add_case(p.page_id, p.page_name || ' /session ' || f.item_name || '=' || l_id, p.page_mode like '%Dialog%',
                 f.item_name, l_id);
      end if;
    end loop;
    -- EDI (F-INT-04): сторінка 700 з карткою останнього повідомлення кожного типу
    if p.page_id = 700 then
      for m in (select msg_type, max(id) keep (dense_rank last order by msg_no) id from sys_edi_message group by msg_type order by 1) loop
        add_case(p.page_id, p.page_name || ' /' || m.msg_type || ' P700_ID=' || m.id, false, 'P700_ID', m.id);
      end loop;
    end if;
  end loop;

  l_names(1) := 'REQUEST_METHOD';   l_vals(1) := 'GET';
  l_names(2) := 'SERVER_NAME';      l_vals(2) := 'localhost';
  l_names(3) := 'SERVER_PORT';      l_vals(3) := '8181';
  l_names(4) := 'SCRIPT_NAME';      l_vals(4) := '/ords';
  l_names(5) := 'HTTP_HOST';        l_vals(5) := 'localhost:8181';
  l_names(6) := 'SERVER_PROTOCOL';  l_vals(6) := 'HTTP/1.1';
  l_names(7) := 'REQUEST_PROTOCOL'; l_vals(7) := 'http';

  for k in 1 .. l_cases.count loop
    c := l_cases(k);
    l_err := null; l_html := null;
    if c.item is not null then
      -- режим редагування: ключ форми кладемо в стан сесії (як після переходу за посиланням зі списку)
      apex_session.attach(p_app_id => c_app, p_page_id => c.page_id, p_session_id => l_sess);
      apex_util.set_session_state(c.item, c.val);
      apex_session.detach;
    end if;
    select nvl(max(id), 0) into l_dbg_id from apex_debug_messages where session_id = l_sess;
    begin
      owa.init_cgi_env(7, l_names, l_vals);
      htp.htbuf_len := 63;   -- інакше ORA-06502 на кирилиці (63 символи × 4 байти ≤ 255)
      htp.init;
      wwv_flow.show(p_flow_id => to_char(c_app), p_flow_step_id => to_char(c.page_id), p_instance => to_char(l_sess),
                    p_debug => 'LEVEL1', p_dialog_cs => c.dialog_cs);
      l_rows := 9999999;
      owa.get_page(l_pg, l_rows);
      dbms_lob.createtemporary(l_html, true);
      for i in 1 .. l_rows loop
        if l_pg(i) is not null then dbms_lob.writeappend(l_html, length(l_pg(i)), l_pg(i)); end if;
      end loop;
    exception when others then
      l_err := 'виняток: ' || substr(sqlerrm, 1, 200);
    end;
    rollback;

    -- помилки, які APEX записав у debug (рівень 1, або виняток у final_exception_handler)
    select max(substr(regexp_replace(message, '\s+', ' '), 1, 220)) keep (dense_rank first order by id) into l_dbg
      from apex_debug_messages
     where session_id = l_sess and id > l_dbg_id
       and (message_level = 1 or (message_level = 2 and message like 'Exception%'));
    l_dbg := regexp_replace(l_dbg, '^.*?(ORA-\d+: )', '\1');
    if l_err is null and nvl(dbms_lob.getlength(l_html), 0) < 500 then
      l_err := 'порожня відповідь (' || nvl(dbms_lob.getlength(l_html), 0) || ' байт) ' || l_dbg;
    elsif l_err is null and dbms_lob.instr(l_html, '</html>') = 0 then
      l_err := 'HTML обірвано: ' || nvl(l_dbg, grab('ORA-\d+[^<]{0,150}'));
    elsif l_err is null and dbms_lob.instr(l_html, 'Label Column Span') > 0 then
      l_err := grab('[^>]{0,120}Label Column Span[^<]{0,80}');
    elsif l_err is null and regexp_instr(l_html, 'ORA-\d{5}') > 0 then
      l_err := grab('ORA-\d{5}[^<]{0,150}');
    elsif l_err is null and regexp_instr(l_html, 'report error|t-Alert--danger|a-Notification--error|t-ErrorPage') > 0 then
      l_err := 'маркер помилки: ' || grab('(report error|t-Alert--danger|a-Notification--error|t-ErrorPage).{0,200}');
    elsif l_err is null and regexp_instr(l_html, 'id="APEX_ERROR_MESSAGE"[^>]*>\s*[^<\s]') > 0 then
      l_err := 'APEX_ERROR_MESSAGE: ' || grab('id="APEX_ERROR_MESSAGE"[^>]*>.{0,300}');
    elsif l_err is null and c.item is not null and dbms_lob.instr(l_html, 'value="' || c.val || '"') = 0 then
      l_err := 'запис ' || c.val || ' не завантажено у форму';
    elsif l_err is null and l_dbg is not null then
      l_err := 'debug: ' || l_dbg;
    end if;

    if l_err is null then
      l_ok := l_ok + 1;
      dbms_output.put_line('OK   page ' || c.page_id || ' ' || c.name);
    else
      l_fail := l_fail + 1;
      dbms_output.put_line('FAIL page ' || c.page_id || ' ' || c.name || ': '
                           || replace(replace(l_err, chr(10), ' '), chr(13)));
    end if;
    if dbms_lob.istemporary(l_html) = 1 then dbms_lob.freetemporary(l_html); end if;
  end loop;

  rollback;
  apex_session.delete_session(p_session_id => l_sess);
  dbms_output.put_line('Разом: ' || l_cases.count || ' рендерів, OK ' || l_ok || ', FAIL ' || l_fail);
end;
/
rollback;
exit
