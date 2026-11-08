-- =============================================================================
-- Trade r3 — друк: рахунок на оплату (DocInvoiceForPayment), заголовки форм
-- =============================================================================
create or replace package trade_print as
  function invoice_html (p_id in varchar2) return clob;
end trade_print;
/

create or replace package body trade_print as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;

  function invoice_html (p_id in varchar2) return clob is
    l clob;
    c sys_company_settings%rowtype;
    d doc_invoice_for_payment%rowtype;
    l_cus varchar2(255);
    n pls_integer := 0;
  begin
    select * into d from doc_invoice_for_payment where id = p_id;
    begin
      select * into c from sys_company_settings where id = 'X';
    exception when no_data_found then
      c.name := 'Підприємство (заповніть реквізити)';
    end;
    select name into l_cus from ref_counterparty where id = d.customer_id;
    l := '<div class="tx-print"><style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:800px;background:#fff;padding:16px}
      .tx-print h2{font-size:18px;text-align:center;margin:16px 0}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px}
      .tx-print .grid th{background:#f2f2f2}
      .tx-print .r{text-align:right}.tx-print .req td{padding:2px 6px;vertical-align:top}
      .tx-print .tot td{border:0;padding:2px 6px}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button{display:none!important}}
      </style>'
      || '<table class="req"><tr><td style="width:130px"><b>Постачальник:</b></td><td><b>' || e(c.name) || '</b><br>'
      || case when c.edrpou is not null then 'Код ЄДРПОУ ' || e(c.edrpou) || '<br>' end
      || case when c.iban is not null then 'IBAN ' || e(c.iban) || ' у ' || e(c.bank_name) || '<br>' end
      || e(c.address) || case when c.phone is not null then ', тел. ' || e(c.phone) end || '</td></tr>'
      || '<tr><td><b>Покупець:</b></td><td>' || e(l_cus) || '</td></tr></table>'
      || '<h2>Рахунок на оплату № ' || e(d.doc_number) || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY') || '</h2>'
      || '<table class="grid"><tr><th>№</th><th>Товар / послуга</th><th>Од.</th><th>Кількість</th><th>Ціна, грн</th><th>Сума, грн</th></tr>';
    for r in (select g.line_number, p.name, u.short_name, g.quantity, g.price, g.amount
                from doc_invoice_for_payment_goods g
                join ref_product p on p.id = g.product_id
                join ref_unit_of_measure u on u.id = p.unit_of_measure_id
               where g.document_id = p_id order by g.line_number) loop
      n := n + 1;
      l := l || '<tr><td class="r">' || r.line_number || '</td><td>' || e(r.name) || '</td><td>' || e(r.short_name)
             || '</td><td class="r">' || rtrim(to_char(r.quantity, 'FM999G999G990D999'), '.,') || '</td><td class="r">' || m(r.price)
             || '</td><td class="r">' || m(r.amount) || '</td></tr>';
    end loop;
    l := l || '</table><table class="tot"><tr><td class="r"><b>Разом:</b></td><td class="r" style="width:120px"><b>' || m(d.total_amount)
           || '</b></td></tr><tr><td class="r">Без ПДВ</td><td></td></tr></table>'
           || '<p>Всього найменувань ' || n || ', на суму ' || m(d.total_amount) || ' грн.<br><b>'
           || e(trade_r3.amount_in_words_uk(d.total_amount)) || '</b></p>'
           || case when d.payment_due_date is not null then '<p>Сплатити до ' || to_char(d.payment_due_date, 'DD.MM.YYYY') || '.</p>' end
           || case when d.status = 'CANCELLED' then '<p style="color:#c00"><b>АНУЛЬОВАНО:</b> ' || e(d.cancel_reason) || '</p>' end
           || '<p style="margin-top:32px">Виписав(ла): ____________________ ' || e(c.accountant_name) || '</p></div>';
    return l;
  end invoice_html;

end trade_print;
/

create or replace package body trade_ui as
  function esc (p in varchar2) return varchar2 is begin return apex_escape.html(p); end esc;
  function function_panel (p_section in varchar2) return clob is
    l_html clob; l_grp varchar2(100);
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
                   and (o.auth_scheme is null or apex_authorization.is_authorized(o.auth_scheme))
                 order by f.group_sort, f.group_name, f.item_sort) loop
        if l_grp is null or l_grp <> r.group_name then
          if l_grp is not null then l_html := l_html || '</ul>'; end if;
          l_html := l_html || '<h3 class="tx-fp-group">' || esc(r.group_name) || '</h3><ul class="tx-fp-list">';
          l_grp := r.group_name;
        end if;
        l_html := l_html || '<li><a class="tx-fp-link' || case r.is_important when 'Y' then ' tx-important' end
                  || '" href="' || apex_page.get_url(p_page => r.list_page_id) || '">' || esc(r.name) || '</a></li>';
      end loop;
      if l_grp is not null then l_html := l_html || '</ul>'; end if;
      if c = 3 then
        l_grp := null;
        for r in (select o.name, o.form_page_id, min(f.item_sort) srt
                    from sys_function_panel f
                    join sys_main_menu_section s on s.id = f.section_id
                    join sys_metadata_object o on o.id = f.object_id
                   where s.tech_name = p_section and o.kind = 'DOCUMENT'
                     and (o.auth_scheme is null or apex_authorization.is_authorized(o.auth_scheme))
                   group by o.name, o.form_page_id order by 3, 1) loop
          if l_grp is null then
            l_html := l_html || '<h3 class="tx-fp-group tx-fp-create">Створити</h3><ul class="tx-fp-list">';
            l_grp := 'x';
          end if;
          l_html := l_html || '<li><a class="tx-fp-link" href="'
                    || apex_page.get_url(p_page => r.form_page_id, p_clear_cache => to_char(r.form_page_id)) || '">'
                    || esc(r.name) || '</a></li>';
        end loop;
        if l_grp is not null then l_html := l_html || '</ul>'; end if;
      end if;
      l_html := l_html || '</div>';
    end loop;
    return l_html || '</div>';
  end function_panel;

  -- DocGoodsSale → DOC_GOODS_SALE (без regexp: діапазони [a-z] залежать від NLS_SORT сесії)
  function snake (p in varchar2) return varchar2 is
    l varchar2(200);
    c varchar2(1);
  begin
    for i in 1 .. length(p) loop
      c := substr(p, i, 1);
      if i > 1 and ascii(c) between 65 and 90 then l := l || '_'; end if;
      l := l || c;
    end loop;
    return upper(l);
  end snake;

  function current_tasks return clob is
    l_html clob := '<div class="tx-tasks"><h3 class="tx-fp-group">Поточні справи</h3><ul class="tx-fp-list">';
    n number;
    procedure line (p_label varchar2, p_value varchar2, p_page number) is
    begin
      l_html := l_html || '<li><a class="tx-fp-link" href="' || apex_page.get_url(p_page => p_page) || '">'
                || esc(p_label) || '</a> <span class="tx-task-value">' || esc(p_value) || '</span></li>';
    end;
  begin
    for r in (select o.name, o.list_page_id, o.tech_name
                from sys_metadata_object o where o.kind = 'DOCUMENT' order by o.list_page_id) loop
      execute immediate 'select count(*) from ' || dbms_assert.simple_sql_name(snake(r.tech_name)) || ' where status = ''DRAFT''' into n;
      if n > 0 then line(r.name || ' — чернетки', to_char(n), r.list_page_id); end if;
    end loop;
    select count(distinct order_id) into n from v_customer_orders_analysis where order_state = 'До виконання';
    if n > 0 then line('Замовлення клієнтів до виконання', to_char(n), 230); end if;
    select count(*) into n from v_purchase_need where need_qty > 0;
    if n > 0 then line('Потрібно закупити (позицій)', to_char(n), 210); end if;
    select coalesce(sum(amount), 0) into n from reg_counterparty_settlement_mv where direction = 'RECEIVABLE';
    line('Борг покупців', to_char(n, 'FM999G999G999G990D00') || ' UAH', 80);
    -- r4 F-REP-10: прострочений борг покупців (trade_ar_aging, db/36 — виклик динамічний)
    begin
      execute immediate 'begin :n := trade_ar_aging.overdue_total(sysdate); end;' using out n;
      if n > 0 then line('Прострочений борг покупців', to_char(n, 'FM999G999G999G990D00') || ' UAH', 470); end if;
    exception when others then null;
    end;
    select coalesce(sum(amount), 0) into n from reg_counterparty_settlement_mv where direction = 'PAYABLE';
    line('Борг постачальникам', to_char(n, 'FM999G999G999G990D00') || ' UAH', 80);
    return l_html || '</ul></div>';
  end current_tasks;

  function doc_title (p_kind_name in varchar2, p_number in varchar2, p_date in varchar2, p_status in varchar2) return varchar2 is
  begin
    if p_number is null then
      return p_kind_name || ' (створення)';
    end if;
    return p_kind_name || ' ' || p_number || ' від ' || p_date
           || case p_status when 'POSTED' then ' (проведено)' when 'ISSUED' then ' (видано)' when 'CANCELLED' then ' (анульовано)' end;
  end doc_title;
end trade_ui;
/
