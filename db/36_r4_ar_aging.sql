-- =============================================================================
-- Trade r4 — F-REP-10 «Дебіторка за термінами» (аналіз дебіторської заборгованості за строками
-- погашення). Звіт на RegCounterpartySettlement (RECEIVABLE, UAH) + RefContract.paymentTermDays.
--   * v_receivable_item — рух дебіторки за рядками реєстратора з договором документа
--     (реалізація, повернення, оплата, ПКО/ВКО, рядок виписки, коригування боргу — для
--     перенесення на інший договір «+»-рядок належить договору-одержувачу);
--   * пакет trade_ar_aging:
--       open_items(дата, організація, контрагент) — конвеєрна функція: відкриті документи боргу на
--         кінець дня дати. Оплати (ПКО, оплати від покупців, рядки виписок, повернення, коригування)
--         розподіляються FIFO на борги — найстаріші погашаються першими: відкриті лишаються
--         найновіші документи боргу на суму сальдо (те саме FIFO-припущення, що й розшифровка
--         платежу doc_customer_payment_alloc, db/32). Розподіл — у розрізі організація × контрагент
--         (регістр не має виміру «договір»), договір береться з документа боргу;
--         дата погашення = дата документа боргу + RefContract.payment_term_days (без договору — 0 днів);
--         інтервали: NOT_DUE «не настав», D30 1–30, D60 31–60, D90 61–90, D90P > 90 днів прострочення;
--       aging_html(...) — HTML звіту за контрагентами й договорами (за потреби — з документами);
--       overdue_total / overdue_count — прострочений борг для «Поточних справ» на головній;
--   * меню «Продажі / Фінанси / Головне → Звіти» — «Дебіторка за термінами» (сторінка 470).
-- Потребує 24 (organization_id), 28, 29, 30, 32. trade_ui.current_tasks (db/16) викликає
-- trade_ar_aging динамічно. Повторно виконуваний.
-- =============================================================================
set define off

create or replace view v_receivable_item as
select m.period, m.recorder_type, m.recorder_id, m.line_number, m.organization_id, m.counterparty_id,
       m.currency_code, m.amount,
       case m.recorder_type
         when 'DocGoodsSale'       then s.contract_id
         when 'DocCustomerReturn'  then r.contract_id
         when 'DocCustomerPayment' then p.contract_id
         when 'DocCashReceipt'     then cr.contract_id
         when 'DocCashPayment'     then cp.contract_id
         when 'DocBankStatement'   then bl.contract_id
         when 'DocDebtAdjustment'  then case when m.line_number = 2 then da.target_contract_id else da.contract_id end
       end contract_id
  from reg_counterparty_settlement_mv m
  left join doc_goods_sale s        on m.recorder_type = 'DocGoodsSale'       and s.id = m.recorder_id
  left join doc_customer_return r   on m.recorder_type = 'DocCustomerReturn'  and r.id = m.recorder_id
  left join doc_customer_payment p  on m.recorder_type = 'DocCustomerPayment' and p.id = m.recorder_id
  left join doc_cash_receipt cr     on m.recorder_type = 'DocCashReceipt'     and cr.id = m.recorder_id
  left join doc_cash_payment cp     on m.recorder_type = 'DocCashPayment'     and cp.id = m.recorder_id
  left join doc_bank_statement_line bl on m.recorder_type = 'DocBankStatement' and bl.document_id = m.recorder_id
                                      and bl.line_number = m.line_number
  left join doc_debt_adjustment da  on m.recorder_type = 'DocDebtAdjustment'  and da.id = m.recorder_id
 where m.direction = 'RECEIVABLE';

create or replace package trade_ar_aging as
  type item_row is record (
    organization_id varchar2(32),
    counterparty_id varchar2(32),
    contract_id     varchar2(32),
    recorder_type   varchar2(60),
    recorder_id     varchar2(32),
    line_number     number,
    doc_date        date,
    amount          number,      -- сума боргу за документом
    open_amount     number,      -- непогашений залишок (FIFO)
    term_days       number,
    due_date        date,
    days_overdue    number,      -- ≤ 0 — строк не настав
    bucket          varchar2(10));
  type item_tab is table of item_row;

  -- Відкриті документи боргу на кінець дня p_date; p_org / p_cp null — без відбору
  function open_items (p_date in date, p_org in varchar2 default null, p_cp in varchar2 default null) return item_tab pipelined;

  -- Інтервал прострочення: NOT_DUE | D30 | D60 | D90 | D90P
  function bucket_of (p_days_overdue in number) return varchar2;

  -- Прострочений борг покупців на дату (усі організації або одна) і кількість боржників
  function overdue_total (p_date in date default sysdate, p_org in varchar2 default null) return number;
  function overdue_count (p_date in date default sysdate, p_org in varchar2 default null) return number;

  -- p_detail: CONTRACT (контрагенти й договори) | DOCUMENT (з документами боргу)
  function aging_html (p_date in date, p_org in varchar2 default null, p_cp in varchar2 default null,
                       p_detail in varchar2 default 'CONTRACT', p_overdue_only in varchar2 default 'N') return clob;
end trade_ar_aging;
/

create or replace package body trade_ar_aging as

  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function z (p number) return varchar2 is begin return case when coalesce(p, 0) = 0 then null else m(p) end; end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function bucket_of (p_days_overdue in number) return varchar2 is
  begin
    return case when p_days_overdue is null or p_days_overdue <= 0 then 'NOT_DUE'
                when p_days_overdue <= 30 then 'D30'
                when p_days_overdue <= 60 then 'D60'
                when p_days_overdue <= 90 then 'D90'
                else 'D90P' end;
  end bucket_of;

  function open_items (p_date in date, p_org in varchar2 default null, p_cp in varchar2 default null) return item_tab pipelined is
    l_day date := trunc(coalesce(p_date, sysdate));
    r item_row;
  begin
    for x in (
      with mv as (
        select i.organization_id, i.counterparty_id, i.recorder_type, i.recorder_id, i.line_number,
               i.contract_id, min(i.period) dt, sum(i.amount) amt
          from v_receivable_item i
         where i.currency_code = 'UAH' and i.period < l_day + 1
           and (p_org is null or i.organization_id = p_org)
           and (p_cp is null or i.counterparty_id = p_cp)
         group by i.organization_id, i.counterparty_id, i.recorder_type, i.recorder_id, i.line_number, i.contract_id),
      deb as (
        select mv.*,
               sum(amt) over (partition by organization_id, counterparty_id) bal,
               coalesce(sum(case when amt > 0 then amt end) over (
                 partition by organization_id, counterparty_id
                 order by case when amt > 0 then 0 else 1 end, dt desc, recorder_id desc, line_number desc
                 rows between unbounded preceding and 1 preceding), 0) newer
          from mv)
      select d.organization_id, d.counterparty_id, d.contract_id, d.recorder_type, d.recorder_id, d.line_number,
             d.dt, d.amt, least(d.amt, greatest(d.bal - d.newer, 0)) open_amt,
             coalesce(c.payment_term_days, 0) term_days
        from deb d
        left join ref_contract c on c.id = d.contract_id
       where d.amt > 0 and least(d.amt, greatest(d.bal - d.newer, 0)) > 0
       order by d.organization_id, d.counterparty_id, d.dt, d.recorder_id, d.line_number) loop
      r.organization_id := x.organization_id; r.counterparty_id := x.counterparty_id; r.contract_id := x.contract_id;
      r.recorder_type := x.recorder_type; r.recorder_id := x.recorder_id; r.line_number := x.line_number;
      r.doc_date := x.dt; r.amount := x.amt; r.open_amount := x.open_amt; r.term_days := x.term_days;
      r.due_date := trunc(x.dt) + x.term_days;
      r.days_overdue := l_day - r.due_date;
      r.bucket := bucket_of(r.days_overdue);
      pipe row (r);
    end loop;
    return;
  end open_items;

  function overdue_total (p_date in date default sysdate, p_org in varchar2 default null) return number is
    l number;
  begin
    select coalesce(sum(open_amount), 0) into l from table(open_items(p_date, p_org)) where days_overdue > 0;
    return l;
  end overdue_total;

  function overdue_count (p_date in date default sysdate, p_org in varchar2 default null) return number is
    l number;
  begin
    select count(distinct counterparty_id) into l from table(open_items(p_date, p_org)) where days_overdue > 0;
    return l;
  end overdue_count;

  function link_doc (p_name varchar2, p_page number, p_id varchar2) return varchar2 is
  begin
    if v('APP_ID') is null or p_page is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => p_page, p_items => 'P' || p_page || '_ID', p_values => p_id)
           || '">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end link_doc;

  function link_act (p_name varchar2, p_org varchar2, p_cp varchar2, p_to date) return varchar2 is
  begin
    if v('APP_ID') is null then
      return e(p_name);
    end if;
    return '<a href="' || apex_page.get_url(p_page => 420, p_items => 'P420_ORG,P420_CP,P420_FROM,P420_TO',
                                            p_values => p_org || ',' || p_cp || ',' || dt(trunc(p_to, 'Q')) || ',' || dt(p_to))
           || '" title="Акт звірки">' || e(p_name) || '</a>';
  exception when others then
    return e(p_name);
  end link_act;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1200px;background:#fff;padding:16px}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 8px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .cp td{font-weight:bold;background:#f7f7f7}
      .tx-print .ctr td:first-child{padding-left:20px}
      .tx-print .doc td{font-size:11px;color:#333}.tx-print .doc td:first-child{padding-left:36px}
      .tx-print .tot td{font-weight:bold;background:#fafafa}
      .tx-print .od{color:#c62828}
      .tx-print .small{font-size:11px;color:#333}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}.tx-print a{color:#000;text-decoration:none}}
      </style>';
  end css;

  function aging_html (p_date in date, p_org in varchar2 default null, p_cp in varchar2 default null,
                       p_detail in varchar2 default 'CONTRACT', p_overdue_only in varchar2 default 'N') return clob is
    l clob;
    l_day date := trunc(coalesce(p_date, sysdate));
    l_doc boolean := coalesce(p_detail, 'CONTRACT') = 'DOCUMENT';
    l_od boolean := coalesce(p_overdue_only, 'N') = 'Y';
    l_org varchar2(255); l_cpn varchar2(255);
    l_cp_key varchar2(70); l_ctr_key varchar2(70);
    l_rows pls_integer := 0;
    l_tot varchar2(4000);

    function cells (p_tot number, p_nd number, p_30 number, p_60 number, p_90 number, p_90p number, p_maxd number) return varchar2 is
    begin
      return '<td class="r">' || m(p_tot) || '</td><td class="r">' || z(p_nd) || '</td>'
          || '<td class="r">' || z(p_30) || '</td><td class="r">' || z(p_60) || '</td>'
          || '<td class="r">' || z(p_90) || '</td><td class="r">' || z(p_90p) || '</td>'
          || '<td class="r od">' || z(p_tot - p_nd) || '</td>'
          || '<td class="r">' || case when p_maxd > 0 then to_char(p_maxd) end || '</td>';
    end cells;
  begin
    if p_org is not null then select max(name) into l_org from ref_organization where id = p_org; end if;
    if p_cp is not null then select max(name) into l_cpn from ref_counterparty where id = p_cp; end if;
    l := '<div class="tx-print">' || css
      || '<h2>Дебіторська заборгованість за термінами на ' || dt(l_day) || '</h2>'
      || '<table class="small" style="margin-bottom:8px"><tr><td>Організація: <b>' || e(coalesce(l_org, 'усі організації'))
      || '</b>; контрагент: <b>' || e(coalesce(l_cpn, 'усі')) || '</b>'
      || case when l_od then '; лише прострочений борг' end || '</td>'
      || '<td class="r">Дата погашення = дата документа + відстрочка за договором</td></tr></table>';

    -- зведення за інтервалами
    l := l || '<table class="grid" style="margin-bottom:8px;width:auto"><tr><th>Інтервал</th><th>Сума</th><th>Частка, %</th><th>Документів</th><th>Контрагентів</th></tr>';
    for b in (
      with it as (select * from table(open_items(l_day, p_org, p_cp)) where not l_od or days_overdue > 0),
      bk as (select 1 s, 'NOT_DUE' code, 'Строк не настав' name from dual union all
             select 2, 'D30', 'Прострочено 1–30 днів' from dual union all
             select 3, 'D60', 'Прострочено 31–60 днів' from dual union all
             select 4, 'D90', 'Прострочено 61–90 днів' from dual union all
             select 5, 'D90P', 'Прострочено понад 90 днів' from dual)
      select bk.name, coalesce(sum(it.open_amount), 0) amt, count(it.recorder_id) docs, count(distinct it.counterparty_id) cps,
             sum(coalesce(sum(it.open_amount), 0)) over () total
        from bk left join it on it.bucket = bk.code
       group by bk.s, bk.name order by bk.s) loop
      l := l || '<tr><td>' || b.name || '</td><td class="r">' || m(b.amt) || '</td><td class="r">'
             || to_char(case when b.total > 0 then b.amt * 100 / b.total else 0 end, 'FM990D00') || '</td>'
             || '<td class="r">' || b.docs || '</td><td class="r">' || b.cps || '</td></tr>';
    end loop;
    l := l || '</table>';

    l := l || '<table class="grid"><tr><th rowspan="2">Контрагент / договір' || case when l_doc then ' / документ' end || '</th>'
           || case when l_doc then '<th rowspan="2">Дата погашення</th>' end
           || '<th rowspan="2">Борг</th><th rowspan="2">Строк не настав</th><th colspan="4">Прострочено, днів</th>'
           || '<th rowspan="2">Усього прострочено</th><th rowspan="2">Макс. днів прострочення</th></tr>'
           || '<tr><th>1–30</th><th>31–60</th><th>61–90</th><th>понад 90</th></tr>';
    for x in (
      with it as (
        select i.*, case when i.bucket = 'NOT_DUE' then i.open_amount else 0 end nd,
               case when i.bucket = 'D30' then i.open_amount else 0 end b30,
               case when i.bucket = 'D60' then i.open_amount else 0 end b60,
               case when i.bucket = 'D90' then i.open_amount else 0 end b90,
               case when i.bucket = 'D90P' then i.open_amount else 0 end b90p
          from table(open_items(l_day, p_org, p_cp)) i
         where not l_od or i.days_overdue > 0)
      select it.*, cp.name cp_name,
             coalesce(case when c.contract_number is not null then 'Договір № ' || c.contract_number else c.name end, 'Без договору') ctr_name,
             c.payment_term_days, rec.recorder_name, rec.page_id, o.name org_name,
             sum(open_amount) over (partition by it.counterparty_id) cp_tot,
             sum(nd) over (partition by it.counterparty_id) cp_nd, sum(b30) over (partition by it.counterparty_id) cp_30,
             sum(b60) over (partition by it.counterparty_id) cp_60, sum(b90) over (partition by it.counterparty_id) cp_90,
             sum(b90p) over (partition by it.counterparty_id) cp_90p, max(days_overdue) over (partition by it.counterparty_id) cp_maxd,
             sum(open_amount) over (partition by it.counterparty_id, it.contract_id) c_tot,
             sum(nd) over (partition by it.counterparty_id, it.contract_id) c_nd, sum(b30) over (partition by it.counterparty_id, it.contract_id) c_30,
             sum(b60) over (partition by it.counterparty_id, it.contract_id) c_60, sum(b90) over (partition by it.counterparty_id, it.contract_id) c_90,
             sum(b90p) over (partition by it.counterparty_id, it.contract_id) c_90p, max(days_overdue) over (partition by it.counterparty_id, it.contract_id) c_maxd,
             sum(open_amount) over () t_tot, sum(nd) over () t_nd, sum(b30) over () t_30, sum(b60) over () t_60,
             sum(b90) over () t_90, sum(b90p) over () t_90p, max(days_overdue) over () t_maxd,
             count(distinct it.organization_id) over (partition by it.counterparty_id) cp_orgs
        from it
        join ref_counterparty cp on cp.id = it.counterparty_id
        join ref_organization o on o.id = it.organization_id
        left join ref_contract c on c.id = it.contract_id
        left join v_recorder rec on rec.recorder_type = it.recorder_type and rec.recorder_id = it.recorder_id
       order by cp.name, it.counterparty_id, ctr_name, it.contract_id nulls last, it.doc_date, it.recorder_id, it.line_number) loop
      l_rows := l_rows + 1;
      if l_cp_key is null or l_cp_key <> x.counterparty_id then
        l_cp_key := x.counterparty_id; l_ctr_key := null;
        l := l || '<tr class="cp"><td>' || link_act(x.cp_name, case when p_org is not null then p_org
                                                                   when x.cp_orgs = 1 then x.organization_id end, x.counterparty_id, l_day)
               || '</td>' || case when l_doc then '<td></td>' end
               || cells(x.cp_tot, x.cp_nd, x.cp_30, x.cp_60, x.cp_90, x.cp_90p, x.cp_maxd) || '</tr>';
      end if;
      if l_ctr_key is null or l_ctr_key <> coalesce(x.contract_id, '-') then
        l_ctr_key := coalesce(x.contract_id, '-');
        l := l || '<tr class="ctr"><td>' || e(x.ctr_name)
               || ' <span class="small">(відстрочка ' || coalesce(x.payment_term_days, 0) || ' дн.)</span></td>'
               || case when l_doc then '<td></td>' end
               || cells(x.c_tot, x.c_nd, x.c_30, x.c_60, x.c_90, x.c_90p, x.c_maxd) || '</tr>';
      end if;
      if l_doc then
        l := l || '<tr class="doc"><td>' || link_doc(coalesce(x.recorder_name, x.recorder_type || ' ' || x.recorder_id), x.page_id, x.recorder_id)
               || case when x.open_amount < x.amount then ' <span class="small">(сума ' || m(x.amount) || ', залишок ' || m(x.open_amount) || ')</span>' end
               || case when p_org is null then ' <span class="small">— ' || e(x.org_name) || '</span>' end
               || '</td><td class="c">' || dt(x.due_date) || '</td>'
               || cells(x.open_amount, x.nd, x.b30, x.b60, x.b90, x.b90p, x.days_overdue) || '</tr>';
      end if;
      l_tot := '<tr class="tot"><td' || case when l_doc then ' colspan="2"' end || '>Разом</td>'
               || cells(x.t_tot, x.t_nd, x.t_30, x.t_60, x.t_90, x.t_90p, x.t_maxd) || '</tr>';
    end loop;
    if l_rows = 0 then
      return l || '</table><p class="c">' || case when l_od then 'Простроченої дебіторської заборгованості немає.'
                                                  else 'Дебіторської заборгованості немає.' end || '</p></div>';
    end if;
    l := l || l_tot || '</table>'
           || '<p class="small">Оплати, повернення й коригування розподілено FIFO на документи боргу (найстаріші погашаються першими) '
           || 'у розрізі організації й контрагента; дата погашення — дата документа боргу + відстрочка платежу за договором '
           || '(без договору — 0 днів). Сформовано ' || to_char(sysdate, 'DD.MM.YYYY HH24:MI') || '.</p></div>';
    return l;
  end aging_html;

end trade_ar_aging;
/
show errors package body trade_ar_aging

-- ---------------------------------------------------------------- меню: «Звіти» розділів
declare
  procedure fp (p_section varchar2, p_group varchar2, p_col number, p_gsort number, p_tech varchar2, p_isort number, p_imp varchar2 default 'N') is
  begin
    insert into sys_function_panel (section_id, group_name, column_no, group_sort, object_id, item_sort, is_important)
    select s.id, p_group, p_col, p_gsort, o.id, p_isort, p_imp
      from sys_main_menu_section s, sys_metadata_object o
     where s.tech_name = p_section and o.tech_name = p_tech
       and not exists (select 1 from sys_function_panel f where f.section_id = s.id and f.object_id = o.id);
  end;
begin
  merge into sys_metadata_object o
  using (select 'ReceivablesAging' tech_name from dual) s on (o.tech_name = s.tech_name)
  when matched then update set o.name = 'Дебіторка за термінами', o.list_page_id = 470, o.form_page_id = null, o.auth_scheme = null
  when not matched then insert (tech_name, kind, name, section_id, list_page_id, form_page_id, sort_order, auth_scheme)
    values ('ReceivablesAging', 'REPORT', 'Дебіторка за термінами', (select id from sys_main_menu_section where tech_name = 'Reports'), 470, null, 170, null);
  fp('Sales', 'Звіти', 2, 10, 'ReceivablesAging', 80);
  fp('Finance', 'Звіти', 1, 20, 'ReceivablesAging', 40);
  fp('Main', 'Звіти', 2, 10, 'ReceivablesAging', 70);
  commit;
end;
/
