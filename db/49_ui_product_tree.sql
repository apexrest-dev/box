-- =============================================================================
-- F-UI-07 (APE-286), етап 1: «Номенклатура» як ієрархічний довідник 1С —
-- дерево груп ліворуч, список товарів вибраної групи праворуч (сторінка 20).
-- Пакет trade_tree: HTML дерева груп (сервер) і перевірка належності товару до групи.
-- Скрипт можна виконувати повторно.
-- =============================================================================
set define off

create or replace package trade_tree as
  -- Спеціальне значення вузла «Без групи»
  c_no_group constant varchar2(10) := 'NONE';

  -- HTML дерева груп номенклатури.
  --   p_selected — вибрана група (null — уся номенклатура, 'NONE' — без групи)
  --   p_item     — елемент сторінки, у який клік по вузлу записує id групи
  function product_groups_html (p_selected in varchar2, p_item in varchar2) return clob;

  -- 'Y', якщо товар з групою p_product_group відповідає фільтру дерева
  --   p_filter — вибраний вузол, p_sub — 'Y': разом із вкладеними групами
  function in_group (p_product_group in varchar2, p_filter in varchar2, p_sub in varchar2 default 'Y')
    return varchar2;
end trade_tree;
/

create or replace package body trade_tree as

  function esc (p in varchar2) return varchar2 is
  begin
    return apex_escape.html(p);
  end;

  function node_html (p_id in varchar2, p_name in varchar2, p_icon in varchar2, p_selected in varchar2,
                      p_has_children in boolean, p_open in boolean, p_marked in boolean default false) return varchar2 is
  begin
    return '<li class="tx-tree-node' || case when p_has_children then ' has-children' end
        || case when p_open then ' is-open' end
        || case when (p_selected is null and p_id is null) or p_selected = p_id then ' is-current' end
        || case when p_marked then ' is-marked' end || '" data-id="' || esc(p_id) || '">'
        || '<span class="tx-tree-toggle" aria-hidden="true"></span>'
        || '<a href="javascript:void(0)" class="tx-tree-label" data-id="' || esc(p_id) || '" title="' || esc(p_name) || '">'
        || '<span class="tx-tree-icon fa ' || p_icon || '" aria-hidden="true"></span>'
        || '<span class="tx-tree-text">' || esc(p_name) || '</span></a>';
  end;

  function product_groups_html (p_selected in varchar2, p_item in varchar2) return clob is
    l_html  clob;
    type t_set is table of boolean index by varchar2(32);
    l_path  t_set;   -- вибрана група та її предки — їх розгортаємо
    procedure add (s in varchar2) is
    begin
      dbms_lob.writeappend(l_html, length(s), s);
    end;
    procedure render (p_parent in varchar2) is
    begin
      for g in (
        select id, name, state,
               case when exists (select 1 from ref_product_group c where c.parent_id = g.id) then 1 else 0 end has_ch
          from ref_product_group g
         where (p_parent is null and g.parent_id is null) or g.parent_id = p_parent
         order by g.sort_order, g.name
      ) loop
        add(node_html(g.id, g.name, case when g.has_ch = 1 then 'fa-folder' else 'fa-folder-o' end, p_selected,
                      g.has_ch = 1, l_path.exists(g.id), g.state <> 'ACTIVE'));
        if g.has_ch = 1 then
          add('<ul>');
          render(g.id);
          add('</ul>');
        end if;
        add('</li>');
      end loop;
    end;
  begin
    if p_selected is not null and p_selected <> c_no_group then
      for a in (select id from ref_product_group start with id = p_selected connect by id = prior parent_id) loop
        l_path(a.id) := true;
      end loop;
    end if;
    dbms_lob.createtemporary(l_html, true);
    add('<div class="tx-tree" role="tree" data-item="' || esc(p_item) || '"><ul>');
    add(node_html(null, 'Номенклатура', 'fa-folder-open', p_selected, true, true));
    add('<ul>');
    render(null);
    add(node_html(c_no_group, 'Без групи', 'fa-folder-o', p_selected, false, false));
    add('</li></ul></li></ul></div>');
    return l_html;
  end;

  function in_group (p_product_group in varchar2, p_filter in varchar2, p_sub in varchar2 default 'Y')
    return varchar2 is
    n pls_integer;
  begin
    if p_filter is null then return 'Y'; end if;
    if p_filter = c_no_group then return case when p_product_group is null then 'Y' else 'N' end; end if;
    if p_product_group is null then return 'N'; end if;
    if p_product_group = p_filter then return 'Y'; end if;
    if nvl(p_sub, 'Y') <> 'Y' then return 'N'; end if;
    select count(*) into n
      from ref_product_group
     where id = p_filter
     start with id = p_product_group
   connect by id = prior parent_id;
    return case when n > 0 then 'Y' else 'N' end;
  end;

end trade_tree;
/
