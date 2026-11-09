-- F-UI-07 (APE-286), етап 1: «Номенклатура» з деревом груп — trade_tree.in_group (фільтр списку
-- з підгрупами / без, «Без групи», уся номенклатура) і trade_tree.product_groups_html (корінь, вкладеність,
-- розгортання шляху до вибраної групи, поточний вузол, помічені групи, екранування), сторінка 20.
-- Усі зміни відкочуються.
set define off
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_uom varchar2(32); g1 varchar2(32); g2 varchar2(32); g3 varchar2(32); gx varchar2(32);
  p1 varchar2(32); p2 varchar2(32); p3 varchar2(32);
  l_n number; l_c clob; l_s varchar2(32767);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got);
  end;
  procedure has (p_name varchar2, p_html clob, p_text varchar2, p_times number default 1) is
    l number := 0; p number := 1;
  begin
    loop
      p := dbms_lob.instr(p_html, p_text, p);
      exit when p = 0 or p is null;
      l := l + 1; p := p + 1;
    end loop;
    dbms_output.put_line(case when l = p_times then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || l || ' × «' || p_text || '»');
  end;
  function cnt (p_filter varchar2, p_sub varchar2) return number is
    n number;
  begin
    select count(*) into n from ref_product p
     where p.id in (p1, p2, p3) and trade_tree.in_group(p.group_id, p_filter, p_sub) = 'Y';
    return n;
  end;
begin
  select id into l_uom from ref_unit_of_measure where rownum = 1;
  insert into ref_product_group (name, sort_order) values ('T30 Верхня <&> ' || t, 1) returning id into g1;
  insert into ref_product_group (name, parent_id, sort_order) values ('T30 Підгрупа', g1, 1) returning id into g2;
  insert into ref_product_group (name, parent_id, sort_order) values ('T30 Підпідгрупа', g2, 1) returning id into g3;
  insert into ref_product_group (name, sort_order) values ('T30 Інша ' || t, 2) returning id into gx;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T30 Товар у верхній', l_uom, g1) returning id into p1;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T30 Товар у підпідгрупі', l_uom, g3) returning id into p2;
  insert into ref_product (name, unit_of_measure_id, group_id) values ('T30 Товар без групи', l_uom, null) returning id into p3;

  -- ---------------------------------------------------------------- фільтр списку
  eq('Уся номенклатура (фільтр порожній)', cnt(null, 'Y'), 3);
  eq('Верхня група з підгрупами', cnt(g1, 'Y'), 2);
  eq('Верхня група без підгруп', cnt(g1, 'N'), 1);
  eq('Підгрупа з підгрупами (лише товар підпідгрупи)', cnt(g2, 'Y'), 1);
  eq('Підгрупа без підгруп — порожньо', cnt(g2, 'N'), 0);
  eq('«Без групи»', cnt(trade_tree.c_no_group, 'Y'), 1);
  eq('Інша група — порожньо', cnt(gx, 'Y'), 0);
  eqs('Порожній p_sub = з підгрупами', trade_tree.in_group(g3, g1, null), 'Y');

  -- ---------------------------------------------------------------- HTML дерева
  l_c := trade_tree.product_groups_html(null, 'P20_GROUP');
  has('Елемент сторінки у data-item', l_c, 'data-item="P20_GROUP"');
  has('Корінь «Номенклатура» поточний, коли фільтр порожній', l_c, 'is-current" data-id=""');
  has('Вузол «Без групи»', l_c, 'data-id="NONE"', 2);
  has('Назва групи екранована', l_c, 'T30 Верхня &lt;&amp;&gt; ', 2);
  has('Верхня група має дочірні (has-children)', l_c, 'has-children" data-id="' || g1 || '"');
  has('Без вибору гілка згорнута', l_c, 'is-open" data-id="' || g1 || '"', 0);
  has('Листова група — без has-children', l_c, '<li class="tx-tree-node" data-id="' || g3 || '"');
  -- вкладеність: підпідгрупа всередині <ul> підгрупи, що всередині верхньої
  l_s := dbms_lob.substr(l_c, 32767, 1);
  eqs('Порядок вкладеності g1 < g2 < g3',
      case when instr(l_s, 'data-id="' || g1) < instr(l_s, 'data-id="' || g2)
            and instr(l_s, 'data-id="' || g2) < instr(l_s, 'data-id="' || g3) then 'так' else 'ні' end, 'так');

  l_c := trade_tree.product_groups_html(g3, 'P20_GROUP');
  has('Шлях до вибраної: верхня розгорнута', l_c, 'has-children is-open" data-id="' || g1 || '"');
  has('Шлях до вибраної: підгрупа розгорнута', l_c, 'has-children is-open" data-id="' || g2 || '"');
  has('Вибрана група поточна', l_c, 'is-current" data-id="' || g3 || '"');
  has('Корінь не поточний', l_c, 'is-current" data-id=""', 0);

  l_c := trade_tree.product_groups_html(trade_tree.c_no_group, 'P20_GROUP');
  has('«Без групи» поточний', l_c, 'is-current" data-id="NONE"');

  update ref_product_group set state = 'MARKED_FOR_DELETION' where id = gx;
  l_c := trade_tree.product_groups_html(null, 'P20_GROUP');
  has('Помічена на видалення група позначена', l_c, 'is-marked" data-id="' || gx || '"');

  -- ---------------------------------------------------------------- сторінка 20
  select count(*) into l_n from apex_application_page_regions
   where application_id = 100 and page_id = 20 and source_type_code = 'NATIVE_DYNAMIC_CONTENT' and region_name = 'Групи';
  eq('Сторінка 20: область дерева «Групи»', l_n, 1);
  select count(*) into l_n from apex_application_page_items
   where application_id = 100 and page_id = 20 and item_name in ('P20_GROUP', 'P20_SUB');
  eq('Сторінка 20: елементи P20_GROUP, P20_SUB', l_n, 2);
  select count(*) into l_n from apex_application_page_buttons
   where application_id = 100 and page_id = 20 and button_name = 'CREATE_GROUP';
  eq('Сторінка 20: кнопка «Створити групу»', l_n, 1);

  -- ---------------------------------------------------------------- сторінка 950 «Підбір товарів» (етап 2)
  select count(*) into l_n from apex_application_page_regions
   where application_id = 100 and page_id = 950 and source_type_code = 'NATIVE_DYNAMIC_CONTENT' and region_name = 'Групи';
  eq('Підбір 950: область дерева «Групи»', l_n, 1);
  select count(*) into l_n from apex_application_page_items
   where application_id = 100 and page_id = 950 and item_name in ('P950_GROUP', 'P950_SUB');
  eq('Підбір 950: елементи P950_GROUP, P950_SUB', l_n, 2);
  select count(*) into l_n from apex_application_page_proc
   where application_id = 100 and page_id = 950 and process_name = 'Перенести в документ' and when_button_pressed is null;
  eq('Підбір 950: перенесення працює й при збереженні сітки (зміна групи)', l_n, 1);
  select count(*) into l_n from apex_application_page_regions
   where application_id = 100 and page_id = 950 and region_name = 'Товари'
     and dbms_lob.instr(region_source, 'trade_tree.in_group') > 0;
  eq('Підбір 950: список фільтрується деревом', l_n, 1);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
