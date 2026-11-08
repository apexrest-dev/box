-- =============================================================================
-- Trade r3 — друковані форми документів (trade_print.document_html)
--   SALE_INVOICE   Видаткова накладна            (DocGoodsSale)
--   RECEIPT_NOTE   Прибуткова накладна           (DocGoodsReceipt)
--   CUSTOMER_ORDER Замовлення клієнта            (DocCustomerOrder)
--   SUPPLIER_ORDER Замовлення постачальнику      (DocSupplierOrder)
--   INVOICE        Рахунок на оплату             (DocInvoiceForPayment)
--   CUSTOMER_RETURN Накладна на повернення       (DocCustomerReturn)
--   SUPPLIER_RETURN Накладна на повернення постачальнику (DocSupplierReturn)
--   TRANSFER       Накладна на переміщення       (DocGoodsTransfer)
--   WRITE_OFF      Акт списання товарів          (DocGoodsWriteOff)
--   SURPLUS_ACT    Акт оприбуткування надлишків  (DocSurplusPosting)
--   COUNT_SHEET    Інвентаризаційний опис        (DocInventoryCount, без облікових даних)
--   COMPARISON     Порівняльна відомість         (DocInventoryCount)
--   PRICE_LIST     Встановлення цін (прайс)      (DocPriceSetting)
--   KO1 / KO2      Прибутковий / видатковий касовий ордер (DocCashReceipt / DocCashPayment, r4 db/28)
--   DEBT_ADJ       Акт взаємозаліку / коригування заборгованості (DocDebtAdjustment, r4 db/30)
--   PAYMENT_ORDER  Платіжна інструкція (платіжне доручення) — безготівкова оплата постачальнику (DocSupplierPayment, r4 db/31)
--   PAY_KO2        Видатковий касовий ордер — готівкова оплата постачальнику (DocSupplierPayment, r4 db/31)
--   PAY_KO1        Прибутковий касовий ордер — готівкова оплата від покупця (DocCustomerPayment, r4 db/32)
--   ASSEMBLY       Акт комплектації / розкомплектації товарів (DocAssembly, r4 db/33)
--   PAY_NOTICE     Повідомлення про надходження оплати — безготівкова оплата від покупця (DocCustomerPayment, r4 db/32)
--   RECEIPT_ORDER / ISSUE_ORDER  Прибутковий / видатковий ордер на товари (DocGoodsReceiptOrder / DocGoodsIssueOrder, r5 db/40)
--   TAX_INVOICE    Податкова накладна (DocTaxInvoice, r5 db/42); підсумок «Разом / у т. ч. ПДВ» товарних форм — trade_vat.totals_html
--   RETAIL_RECEIPT Касовий чек (DocRetailReceipt, r5 db/43)
-- Чернетки друкуються з водяним знаком «ЧЕРНЕТКА», анульовані — «АНУЛЬОВАНО».
-- Кожен друк фіксується в журналі (action PRINT).
-- =============================================================================
set define off
create or replace package trade_print as
  function invoice_html (p_id in varchar2) return clob;
  function document_html (p_form in varchar2, p_id in varchar2) return clob;
  -- Форма за замовчуванням для документа (за типом реєстратора)
  function default_form (p_id in varchar2) return varchar2;
  -- Перелік доступних форм документа: 'КОД:Назва;КОД:Назва'
  function forms_of (p_id in varchar2) return varchar2;
end trade_print;
/

create or replace package body trade_print as

  type t_rows is table of varchar2(4000);
  g_doc varchar2(32);   -- r4 (F-NSI-09): документ, що друкується (реквізити його організації)

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;

  -- Журнал друку незалежно від контексту виклику (у т.ч. із SQL-запиту)
  procedure log_print (p_type varchar2, p_id varchar2, p_form varchar2) is
    pragma autonomous_transaction;
  begin
    trade_core.audit(p_type, p_id, 'PRINT', p_form);
    commit;
  end log_print;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return rtrim(to_char(p, 'FM999G999G990D999'), '.,'); end;
  function d (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function kind_of (p_id varchar2) return varchar2 is
    l varchar2(60);
  begin
    select max(recorder_type) into l from v_recorder where recorder_id = p_id;
    if l is null then
      select max('DocInvoiceForPayment') into l from doc_invoice_for_payment where id = p_id;
    end if;
    return l;
  end kind_of;

  -- r4 F-PUR-05: форма оплати постачальнику залежить від форми оплати — trade_pay_doc (db/31, пізніше)
  -- r4 F-SAL-07: оплата від покупця — trade_cust_pay (db/32, пізніше)
  function pay_call (p_fn varchar2, p_id varchar2) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate 'begin :l := ' || case kind_of(p_id) when 'DocCustomerPayment' then 'trade_cust_pay.' else 'trade_pay_doc.' end
      || p_fn || '(:i); end;' using out l, p_id;
    return l;
  end pay_call;

  function default_form (p_id in varchar2) return varchar2 is
  begin
    if kind_of(p_id) in ('DocSupplierPayment', 'DocCustomerPayment') then
      return pay_call('default_form', p_id);
    end if;
    return case kind_of(p_id)
      when 'DocGoodsSale' then 'SALE_INVOICE' when 'DocGoodsReceipt' then 'RECEIPT_NOTE'
      when 'DocCustomerOrder' then 'CUSTOMER_ORDER' when 'DocSupplierOrder' then 'SUPPLIER_ORDER'
      when 'DocInvoiceForPayment' then 'INVOICE' when 'DocCustomerReturn' then 'CUSTOMER_RETURN'
      when 'DocSupplierReturn' then 'SUPPLIER_RETURN' when 'DocGoodsTransfer' then 'TRANSFER'
      when 'DocGoodsWriteOff' then 'WRITE_OFF' when 'DocSurplusPosting' then 'SURPLUS_ACT'
      when 'DocInventoryCount' then 'COUNT_SHEET' when 'DocPriceSetting' then 'PRICE_LIST'
      when 'DocCashReceipt' then 'KO1' when 'DocCashPayment' then 'KO2'
      when 'DocDebtAdjustment' then 'DEBT_ADJ' when 'DocAssembly' then 'ASSEMBLY'
      when 'DocGoodsReceiptOrder' then 'RECEIPT_ORDER' when 'DocGoodsIssueOrder' then 'ISSUE_ORDER'
      when 'DocTaxInvoice' then 'TAX_INVOICE' when 'DocRetailReceipt' then 'RETAIL_RECEIPT' end;
  end default_form;

  function forms_of (p_id in varchar2) return varchar2 is
  begin
    return case kind_of(p_id)
      when 'DocInventoryCount' then 'COUNT_SHEET:Інвентаризаційний опис;COMPARISON:Порівняльна відомість'
      when 'DocSupplierPayment' then pay_call('forms_of', p_id)
      when 'DocCustomerPayment' then pay_call('forms_of', p_id)
      else default_form(p_id) || ':' || case default_form(p_id)
        when 'SALE_INVOICE' then 'Видаткова накладна' when 'RECEIPT_NOTE' then 'Прибуткова накладна'
        when 'CUSTOMER_ORDER' then 'Замовлення клієнта' when 'SUPPLIER_ORDER' then 'Замовлення постачальнику'
        when 'INVOICE' then 'Рахунок на оплату' when 'CUSTOMER_RETURN' then 'Накладна на повернення'
        when 'SUPPLIER_RETURN' then 'Накладна на повернення постачальнику' when 'TRANSFER' then 'Накладна на переміщення'
        when 'WRITE_OFF' then 'Акт списання товарів' when 'SURPLUS_ACT' then 'Акт оприбуткування надлишків'
        when 'PRICE_LIST' then 'Встановлення цін'
        when 'KO1' then 'Прибутковий касовий ордер (КО-1)' when 'KO2' then 'Видатковий касовий ордер (КО-2)'
        when 'DEBT_ADJ' then 'Акт взаємозаліку / коригування боргу'
        when 'ASSEMBLY' then 'Акт комплектації / розкомплектації'
        when 'RECEIPT_ORDER' then 'Прибутковий ордер на товари' when 'ISSUE_ORDER' then 'Видатковий ордер на товари'
        when 'TAX_INVOICE' then 'Податкова накладна' when 'RETAIL_RECEIPT' then 'Касовий чек' end end;
  end forms_of;

  function company return ref_organization%rowtype is
    c ref_organization%rowtype;
    l_org varchar2(32);
  begin
    l_org := coalesce(trade_org.doc_org(kind_of(g_doc), g_doc), trade_org.default_org);
    select * into c from ref_organization where id = l_org;
    c.name := coalesce(c.full_name, c.name);
    return c;
  exception when no_data_found then
    c.name := 'Підприємство (заповніть реквізити організації)';
    return c;
  end company;

  function company_block (c ref_organization%rowtype) return varchar2 is
  begin
    return '<b>' || e(c.name) || '</b>'
      || case when c.edrpou is not null then
           case c.org_kind when 'INDIVIDUAL' then '<br>РНОКПП ' else '<br>Код ЄДРПОУ ' end || e(c.edrpou) end
      || case when c.vat_payer = 'Y' then ', ІПН ' || e(c.vat_number) end
      || case when c.iban is not null then '<br>IBAN ' || e(c.iban) || ' у ' || e(c.bank_name) end
      || case when c.address is not null then '<br>' || e(c.address) end
      || case when c.phone is not null then ', тел. ' || e(c.phone) end;
  end company_block;

  function cp_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    if p_id is null then return null; end if;
    select name into l from ref_counterparty where id = p_id;
    return l;
  end cp_name;

  function wh_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    if p_id is null then return null; end if;
    select name into l from ref_warehouse where id = p_id;
    return l;
  end wh_name;

  function contract_name (p_id varchar2) return varchar2 is
    l varchar2(400);
  begin
    if p_id is null then return null; end if;
    select name || case when contract_number is not null then ' № ' || contract_number end
                || case when contract_date is not null then ' від ' || to_char(contract_date, 'DD.MM.YYYY') end
      into l from ref_contract where id = p_id;
    return l;
  end contract_name;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:820px;background:#fff;padding:16px;position:relative}
      .tx-print h2{font-size:18px;text-align:center;margin:14px 0 10px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:bold}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .req td{padding:2px 6px;vertical-align:top}
      .tx-print .tot td{border:0;padding:2px 6px}
      .tx-print .sign{display:flex;gap:40px;margin-top:36px}.tx-print .sign div{flex:1}
      .tx-print .wm{position:absolute;top:240px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}}
      </style>';
  end css;

  -- r5 F-TAX-01: «Разом / у т. ч. ПДВ / Всього з ПДВ» — trade_vat (db/42, пізніше); без нього — «Без ПДВ»
  function vat_totals (p_total number) return varchar2 is
    l varchar2(4000);
  begin
    execute immediate 'begin :l := trade_vat.totals_html(:i, :t); end;' using out l, g_doc, p_total;
    return l;
  exception when others then
    return null;
  end vat_totals;

  function render (p_title varchar2, p_number varchar2, p_date date, p_status varchar2,
                   p_parties varchar2, p_head varchar2, p_rows t_rows, p_total number,
                   p_words boolean, p_footer varchar2, p_signs varchar2) return clob is
    l clob;
    c ref_organization%rowtype := company;
  begin
    l := '<div class="tx-print">' || css
      || case when p_status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>'
              when p_status = 'CANCELLED' then '<div class="wm">АНУЛЬОВАНО</div>' end
      || '<table class="req"><tr><td style="width:150px"><b>Підприємство:</b></td><td>' || company_block(c) || '</td></tr>'
      || p_parties || '</table>'
      || '<h2>' || e(p_title) || ' № ' || e(p_number) || ' від ' || d(p_date) || '</h2>'
      || '<table class="grid"><tr>' || p_head || '</tr>';
    for i in 1 .. p_rows.count loop
      l := l || p_rows(i);
    end loop;
    l := l || '</table>';
    if p_total is not null then
      l := l || coalesce(vat_totals(p_total),
                         '<table class="tot"><tr><td class="r"><b>Разом:</b></td><td class="r" style="width:130px"><b>' || m(p_total)
                         || '</b></td></tr><tr><td class="r">Без ПДВ</td><td></td></tr></table>');
    end if;
    if p_words then
      l := l || '<p>Всього найменувань ' || p_rows.count || ', на суму ' || m(p_total) || ' грн.<br><b>'
             || e(trade_r3.amount_in_words_uk(p_total)) || '</b></p>';
    end if;
    l := l || p_footer || '<div class="sign">' || p_signs || '</div></div>';
    return l;
  end render;

  function party (p_label varchar2, p_value varchar2) return varchar2 is
  begin
    return case when p_value is not null then '<tr><td><b>' || e(p_label) || ':</b></td><td>' || e(p_value) || '</td></tr>' end;
  end party;

  function sign (p_label varchar2, p_name varchar2 default null) return varchar2 is
  begin
    return '<div>' || e(p_label) || ': ____________________ ' || e(p_name) || '</div>';
  end sign;

  function lines (p_sql varchar2, p_id varchar2) return t_rows is
    r t_rows;
  begin
    execute immediate p_sql bulk collect into r using p_id;
    return r;
  end lines;

  -- Стандартна таблиця товарів: № | Товар | Од. | Кількість | Ціна | Сума
  function goods_sql (p_table varchar2, p_discount boolean default false) return varchar2 is
  begin
    return 'select ''<tr><td class="c">'' || g.line_number || ''</td><td>'' || replace(replace(p.name, ''<'', ''&lt;''), ''>'', ''&gt;'') || '
      || 'case when p.article is not null then '' (арт. '' || p.article || '')'' end || ''</td><td class="c">'' || u.short_name'
      || ' || ''</td><td class="r">'' || rtrim(to_char(g.quantity, ''FM999G999G990D999''), ''.,'')'
      || ' || ''</td><td class="r">'' || to_char(g.price, ''FM999G999G999G990D00'')'
      || case when p_discount then ' || ''</td><td class="r">'' || to_char(g.discount_percent, ''FM990D00'')' end
      || ' || ''</td><td class="r">'' || to_char(g.amount, ''FM999G999G999G990D00'') || ''</td></tr>'''
      || ' from ' || p_table || ' g join ref_product p on p.id = g.product_id join ref_unit_of_measure u on u.id = p.unit_of_measure_id'
      || ' where g.document_id = :d order by g.line_number';
  end goods_sql;

  function goods_head (p_discount boolean default false) return varchar2 is
  begin
    return '<th>№</th><th>Товар / послуга</th><th>Од.</th><th>Кількість</th><th>Ціна, грн</th>'
           || case when p_discount then '<th>Знижка, %</th>' end || '<th>Сума, грн</th>';
  end goods_head;

  -- Таблиця без цін: № | Товар | Од. | Кількість
  function qty_sql (p_table varchar2) return varchar2 is
  begin
    return 'select ''<tr><td class="c">'' || g.line_number || ''</td><td>'' || replace(replace(p.name, ''<'', ''&lt;''), ''>'', ''&gt;'')'
      || ' || ''</td><td class="c">'' || u.short_name || ''</td><td class="r">'' || rtrim(to_char(g.quantity, ''FM999G999G990D999''), ''.,'') || ''</td></tr>'''
      || ' from ' || p_table || ' g join ref_product p on p.id = g.product_id join ref_unit_of_measure u on u.id = p.unit_of_measure_id'
      || ' where g.document_id = :d order by g.line_number';
  end qty_sql;

  function document_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    c ref_organization%rowtype;
    l_disc number;
  begin
    g_doc := p_id;
    c := company;
    case p_form
    when 'SALE_INVOICE' then
      for x in (select * from doc_goods_sale where id = p_id) loop
        l := render('Видаткова накладна', x.doc_number, x.occurred_at, x.status,
               party('Покупець', cp_name(x.customer_id)) || party('Склад', wh_name(x.warehouse_id))
               || party('Договір', contract_name(x.contract_id)),
               goods_head, lines(goods_sql('doc_goods_sale_goods'), p_id), x.total_amount, true,
               case when x.doc_comment is not null then '<p>Примітка: ' || e(x.doc_comment) || '</p>' end,
               sign('Відвантажив', c.director_name) || sign('Отримав'));
      end loop;
    when 'RECEIPT_NOTE' then
      for x in (select * from doc_goods_receipt where id = p_id) loop
        l := render('Прибуткова накладна', x.doc_number, x.occurred_at, x.status,
               party('Постачальник', cp_name(x.supplier_id)) || party('Склад', wh_name(x.warehouse_id))
               || party('Договір', contract_name(x.contract_id)),
               goods_head, lines(goods_sql('doc_goods_receipt_goods'), p_id), x.total_amount, true, null,
               sign('Здав') || sign('Прийняв (комірник)'));
      end loop;
    when 'CUSTOMER_ORDER' then
      for x in (select * from doc_customer_order where id = p_id) loop
        select max(discount_percent) into l_disc from doc_customer_order_goods where document_id = p_id;
        l := render('Замовлення клієнта', x.doc_number, x.occurred_at, x.status,
               party('Клієнт', cp_name(x.customer_id)) || party('Договір', contract_name(x.contract_id))
               || party('Склад', wh_name(x.warehouse_id)) || party('Дата відвантаження', d(x.shipment_date)),
               goods_head(l_disc > 0), lines(goods_sql('doc_customer_order_goods', l_disc > 0), p_id), x.total_amount, true,
               case when x.closed = 'Y' then '<p><b>Замовлення закрите.</b></p>' end,
               sign('Менеджер') || sign('Клієнт'));
      end loop;
    when 'SUPPLIER_ORDER' then
      for x in (select * from doc_supplier_order where id = p_id) loop
        l := render('Замовлення постачальнику', x.doc_number, x.occurred_at, x.status,
               party('Постачальник', cp_name(x.supplier_id)) || party('Договір', contract_name(x.contract_id))
               || party('Склад доставки', wh_name(x.warehouse_id)) || party('Очікувана дата', d(x.expected_date)),
               goods_head, lines(goods_sql('doc_supplier_order_goods'), p_id), x.total_amount, true, null,
               sign('Закупівельник') || sign('Постачальник'));
      end loop;
    when 'INVOICE' then
      for x in (select * from doc_invoice_for_payment where id = p_id) loop
        l := render('Рахунок на оплату', x.doc_number, x.occurred_at, x.status,
               party('Покупець', cp_name(x.customer_id)) || party('Договір', contract_name(x.contract_id)),
               goods_head, lines(goods_sql('doc_invoice_for_payment_goods'), p_id), x.total_amount, true,
               case when x.payment_due_date is not null then '<p>Сплатити до ' || d(x.payment_due_date) || '.</p>' end
               || case when x.status = 'CANCELLED' then '<p style="color:#c00"><b>Анульовано:</b> ' || e(x.cancel_reason) || '</p>' end,
               sign('Виписав(ла)', c.accountant_name));
      end loop;
    when 'CUSTOMER_RETURN' then
      for x in (select r.*, s.doc_number base_number, s.occurred_at base_date
                  from doc_customer_return r join doc_goods_sale s on s.id = r.base_sale_id where r.id = p_id) loop
        l := render('Накладна на повернення', x.doc_number, x.occurred_at, x.status,
               party('Від покупця', cp_name(x.customer_id)) || party('Склад', wh_name(x.warehouse_id))
               || party('Підстава', 'Видаткова накладна № ' || x.base_number || ' від ' || d(x.base_date))
               || party('Причина', x.return_reason),
               goods_head, lines(goods_sql('doc_customer_return_goods'), p_id), x.total_amount, true, null,
               sign('Здав (покупець)') || sign('Прийняв (комірник)'));
      end loop;
    when 'SUPPLIER_RETURN' then
      for x in (select r.*, g.doc_number base_number, g.occurred_at base_date
                  from doc_supplier_return r join doc_goods_receipt g on g.id = r.base_receipt_id where r.id = p_id) loop
        l := render('Накладна на повернення постачальнику', x.doc_number, x.occurred_at, x.status,
               party('Постачальник', cp_name(x.supplier_id)) || party('Склад', wh_name(x.warehouse_id))
               || party('Підстава', 'Прибуткова накладна № ' || x.base_number || ' від ' || d(x.base_date))
               || party('Причина', x.return_reason),
               goods_head, lines(goods_sql('doc_supplier_return_goods'), p_id), x.total_amount, true, null,
               sign('Відвантажив') || sign('Отримав (постачальник)'));
      end loop;
    when 'TRANSFER' then
      for x in (select * from doc_goods_transfer where id = p_id) loop
        l := render('Накладна на переміщення', x.doc_number, x.occurred_at, x.status,
               party('Відправник', wh_name(x.warehouse_from_id)) || party('Отримувач', wh_name(x.warehouse_to_id)),
               '<th>№</th><th>Товар</th><th>Од.</th><th>Кількість</th>', lines(qty_sql('doc_goods_transfer_goods'), p_id),
               null, false, null, sign('Відпустив') || sign('Прийняв'));
      end loop;
    when 'WRITE_OFF' then
      for x in (select * from doc_goods_write_off where id = p_id) loop
        l := render('Акт списання товарів', x.doc_number, x.occurred_at, x.status,
               party('Склад', wh_name(x.warehouse_id)) || party('Причина', x.reason),
               '<th>№</th><th>Товар</th><th>Од.</th><th>Кількість</th>', lines(qty_sql('doc_goods_write_off_goods'), p_id),
               null, false, null, sign('Голова комісії') || sign('Член комісії') || sign('Матеріально відповідальна особа'));
      end loop;
    when 'SURPLUS_ACT' then
      for x in (select * from doc_surplus_posting where id = p_id) loop
        l := render('Акт оприбуткування надлишків', x.doc_number, x.occurred_at, x.status,
               party('Склад', wh_name(x.warehouse_id)) || party('Причина', x.reason),
               goods_head, lines(goods_sql('doc_surplus_posting_goods'), p_id), x.total_amount, true, null,
               sign('Голова комісії') || sign('Матеріально відповідальна особа'));
      end loop;
    when 'COUNT_SHEET' then
      for x in (select * from doc_inventory_count where id = p_id) loop
        l := render('Інвентаризаційний опис', x.doc_number, x.occurred_at, x.status,
               party('Склад', wh_name(x.warehouse_id)) || party('Відповідальний', x.responsible_person),
               '<th>№</th><th>Товар</th><th>Од.</th><th style="width:140px">Фактично</th>',
               lines('select ''<tr><td class="c">'' || g.line_number || ''</td><td>'' || p.name || ''</td><td class="c">'' || u.short_name'
                     || ' || ''</td><td>&nbsp;</td></tr>'' from doc_inventory_count_goods g join ref_product p on p.id = g.product_id'
                     || ' join ref_unit_of_measure u on u.id = p.unit_of_measure_id where g.document_id = :d order by g.line_number', p_id),
               null, false, '<p>Опис складено без облікових даних (сліпа інвентаризація).</p>',
               sign('Голова комісії') || sign('Члени комісії') || sign('Матеріально відповідальна особа', x.responsible_person));
      end loop;
    when 'COMPARISON' then
      for x in (select * from doc_inventory_count where id = p_id) loop
        l := render('Порівняльна відомість', x.doc_number, x.occurred_at, x.status,
               party('Склад', wh_name(x.warehouse_id)) || party('Відповідальний', x.responsible_person),
               '<th>№</th><th>Товар</th><th>Од.</th><th>За обліком</th><th>Фактично</th><th>Відхилення</th><th>Ціна</th><th>Сума відхилення</th>',
               lines('select ''<tr><td class="c">'' || g.line_number || ''</td><td>'' || p.name || ''</td><td class="c">'' || u.short_name'
                     || ' || ''</td><td class="r">'' || rtrim(to_char(g.book_quantity, ''FM999G999G990D999''), ''.,'')'
                     || ' || ''</td><td class="r">'' || rtrim(to_char(g.actual_quantity, ''FM999G999G990D999''), ''.,'')'
                     || ' || ''</td><td class="r">'' || rtrim(to_char(g.deviation, ''FM999G999G990D999''), ''.,'')'
                     || ' || ''</td><td class="r">'' || to_char(g.price, ''FM999G999G999G990D00'')'
                     || ' || ''</td><td class="r">'' || to_char(g.deviation_amount, ''FM999G999G999G990D00'') || ''</td></tr>'''
                     || ' from doc_inventory_count_goods g join ref_product p on p.id = g.product_id'
                     || ' join ref_unit_of_measure u on u.id = p.unit_of_measure_id where g.document_id = :d order by g.line_number', p_id),
               null, false,
               '<p>Надлишки: <b>' || m(x.surplus_amount) || '</b> грн; недостачі: <b>' || m(x.shortage_amount) || '</b> грн.</p>',
               sign('Голова комісії') || sign('Бухгалтер', c.accountant_name));
      end loop;
    when 'PRICE_LIST' then
      for x in (select s.*, pt.name price_type_name from doc_price_setting s join ref_price_type pt on pt.id = s.price_type_id where s.id = p_id) loop
        l := render('Встановлення цін', x.doc_number, x.occurred_at, x.status,
               party('Вид цін', x.price_type_name) || party('Діють з', d(x.occurred_at)),
               '<th>№</th><th>Товар</th><th>Од.</th><th>Ціна, грн</th>',
               lines('select ''<tr><td class="c">'' || g.line_number || ''</td><td>'' || p.name || ''</td><td class="c">'' || u.short_name'
                     || ' || ''</td><td class="r">'' || to_char(g.price, ''FM999G999G999G990D00'') || ''</td></tr>'''
                     || ' from doc_price_setting_prices g join ref_product p on p.id = g.product_id'
                     || ' join ref_unit_of_measure u on u.id = p.unit_of_measure_id where g.document_id = :d order by g.line_number', p_id),
               null, false, null, sign('Затвердив', c.director_name));
      end loop;
    when 'KO1' then
      -- r4 F-FIN-03: касові ордери — trade_cash_doc (db/28, встановлюється пізніше)
      execute immediate 'begin :l := trade_cash_doc.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'KO2' then
      execute immediate 'begin :l := trade_cash_doc.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'DEBT_ADJ' then
      -- r4 F-FIN-05: коригування боргу — trade_debt_adj (db/30, встановлюється пізніше)
      execute immediate 'begin :l := trade_debt_adj.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'PAYMENT_ORDER' then
      -- r4 F-PUR-05: оплата постачальнику — trade_pay_doc (db/31, встановлюється пізніше)
      execute immediate 'begin :l := trade_pay_doc.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'PAY_KO2' then
      execute immediate 'begin :l := trade_pay_doc.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'PAY_KO1' then
      -- r4 F-SAL-07: оплата від покупця — trade_cust_pay (db/32, встановлюється пізніше)
      execute immediate 'begin :l := trade_cust_pay.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'PAY_NOTICE' then
      execute immediate 'begin :l := trade_cust_pay.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'ASSEMBLY' then
      -- r4 F-WH-10: акт комплектації — trade_assembly (db/33, пізніше)
      execute immediate 'begin :l := trade_assembly.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'RECEIPT_ORDER' then
      -- r5 F-WH-11: складські ордери — trade_order_scheme (db/40, пізніше)
      execute immediate 'begin :l := trade_order_scheme.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'ISSUE_ORDER' then
      execute immediate 'begin :l := trade_order_scheme.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'TAX_INVOICE' then
      -- r5 F-TAX-01: податкова накладна — trade_tax (db/42, пізніше)
      execute immediate 'begin :l := trade_tax.print_html(:f, :i); end;' using out l, p_form, p_id;
    when 'RETAIL_RECEIPT' then
      -- r5 F-RET-01: касовий чек — trade_retail (db/43, пізніше)
      execute immediate 'begin :l := trade_retail.print_html(:f, :i); end;' using out l, p_form, p_id;
    else
      return '<p>Невідома друкована форма: ' || e(p_form) || '</p>';
    end case;
    if l is null then
      return '<p>Документ не знайдено.</p>';
    end if;
    log_print(kind_of(p_id), p_id, p_form);
    return l;
  end document_html;

  function invoice_html (p_id in varchar2) return clob is
  begin
    return document_html('INVOICE', p_id);
  end invoice_html;

end trade_print;
/
