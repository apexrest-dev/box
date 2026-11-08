-- =============================================================================
-- Trade — пакет trade_ui: панель функцій розділу, поточні справи, заголовки форм
-- =============================================================================
create or replace package trade_ui as
  -- HTML панелі функцій розділу (колонки груп із зеленими заголовками)
  function function_panel (p_section in varchar2) return clob;
  -- HTML блоку «Поточні справи» для начальної сторінки
  function current_tasks return clob;
  -- Заголовок форми документа: «<Вид> <номер> від <дата>» / «(створення)»
  function doc_title (p_kind_name in varchar2, p_number in varchar2, p_date in varchar2, p_status in varchar2) return varchar2;
end trade_ui;
/

create or replace package body trade_ui as

  function esc (p in varchar2) return varchar2 is
  begin
    return apex_escape.html(p);
  end esc;

  function function_panel (p_section in varchar2) return clob is
    l_html clob;
    l_col  number;
    l_grp  varchar2(100);
  begin
    l_html := '<div class="tx-fp">';
    for c in 1 .. 3 loop
      l_html := l_html || '<div class="tx-fp-col">';
      l_grp := null;
      for r in (select f.group_name, f.group_sort, f.item_sort, f.is_important, o.name, o.list_page_id
                  from sys_function_panel f
                  join sys_main_menu_section s on s.id = f.section_id
                  join sys_metadata_object o on o.id = f.object_id
                 where s.tech_name = p_section and f.column_no = c
                 order by f.group_sort, f.group_name, f.item_sort)
      loop
        if l_grp is null or l_grp <> r.group_name then
          if l_grp is not null then
            l_html := l_html || '</ul>';
          end if;
          l_html := l_html || '<h3 class="tx-fp-group">' || esc(r.group_name) || '</h3><ul class="tx-fp-list">';
          l_grp := r.group_name;
        end if;
        l_html := l_html || '<li><a class="tx-fp-link' || case r.is_important when 'Y' then ' tx-important' end
                  || '" href="' || apex_page.get_url(p_page => r.list_page_id) || '">' || esc(r.name) || '</a></li>';
      end loop;
      if l_grp is not null then
        l_html := l_html || '</ul>';
      end if;
      -- «Створити» — документи розділу (у третій колонці)
      if c = 3 then
        l_grp := null;
        for r in (select distinct o.name, o.form_page_id, min(f.item_sort) over (partition by o.id) srt
                    from sys_function_panel f
                    join sys_main_menu_section s on s.id = f.section_id
                    join sys_metadata_object o on o.id = f.object_id
                   where s.tech_name = p_section and o.kind = 'DOCUMENT'
                   order by 3, 1)
        loop
          if l_grp is null then
            l_html := l_html || '<h3 class="tx-fp-group tx-fp-create">Створити</h3><ul class="tx-fp-list">';
            l_grp := 'x';
          end if;
          l_html := l_html || '<li><a class="tx-fp-link" href="'
                    || apex_page.get_url(p_page => r.form_page_id, p_clear_cache => to_char(r.form_page_id)) || '">'
                    || esc(r.name) || '</a></li>';
        end loop;
        if l_grp is not null then
          l_html := l_html || '</ul>';
        end if;
      end if;
      l_html := l_html || '</div>';
    end loop;
    return l_html || '</div>';
  end function_panel;

  function current_tasks return clob is
    l_html clob := '<div class="tx-tasks"><h3 class="tx-fp-group">Поточні справи</h3><ul class="tx-fp-list">';
    procedure line (p_label varchar2, p_value varchar2, p_page number) is
    begin
      l_html := l_html || '<li><a class="tx-fp-link" href="' || apex_page.get_url(p_page => p_page) || '">'
                || esc(p_label) || '</a> <span class="tx-task-value">' || esc(p_value) || '</span></li>';
    end;
    function cnt (p_table varchar2) return number is
      n number;
    begin
      execute immediate 'select count(*) from ' || dbms_assert.simple_sql_name(p_table) || ' where status = ''DRAFT''' into n;
      return n;
    end;
    function bal (p_dir varchar2) return varchar2 is
      n number;
    begin
      select coalesce(sum(amount), 0) into n from reg_counterparty_settlement_mv where direction = p_dir;
      return to_char(n, 'FM999G999G999G990D00') || ' UAH';
    end;
  begin
    for r in (select o.name, o.tech_name, o.list_page_id,
                     upper(regexp_replace(o.tech_name, '([a-z])([A-Z])', '\1_\2', 1, 0, 'c')) tab
                from sys_metadata_object o
               where o.kind = 'DOCUMENT'
               order by o.list_page_id)
    loop
      if cnt(r.tab) > 0 then
        line(r.name || ' — непроведені', to_char(cnt(r.tab)), r.list_page_id);
      end if;
    end loop;
    line('Борг покупців', bal('RECEIVABLE'), 80);
    line('Борг постачальникам', bal('PAYABLE'), 80);
    return l_html || '</ul></div>';
  end current_tasks;

  function doc_title (p_kind_name in varchar2, p_number in varchar2, p_date in varchar2, p_status in varchar2) return varchar2 is
  begin
    if p_number is null then
      return p_kind_name || ' (створення)';
    end if;
    return p_kind_name || ' ' || p_number || ' від ' || p_date
           || case p_status when 'POSTED' then ' (проведено)' else '' end;
  end doc_title;

end trade_ui;
/
