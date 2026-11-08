-- F-REP-10 «Дебіторка за термінами»: дата погашення = дата реалізації + відстрочка договору,
-- FIFO-розподіл оплат на борги, інтервали прострочення, розріз організація × контрагент × договір,
-- історична дата, перенесення боргу на інший договір, прострочений борг для «Поточних справ», HTML, меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_org2 varchar2(32); l_wh varchar2(32); l_uom varchar2(32); l_sup varchar2(32); l_p varchar2(32);
  l_k varchar2(32); c1 varchar2(32); c2 varchar2(32); k30 varchar2(32); k10 varchar2(32); k30b varchar2(32);
  rc varchar2(32); s1 varchar2(32); s2 varchar2(32); s3 varchar2(32); s4 varchar2(32); s6 varchar2(32); s7 varchar2(32);
  pay varchar2(32); adj varchar2(32);
  l_n number; l_v number; l_s varchar2(4000); l_c clob;
  d0 date := trunc(sysdate);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp or (p_got is null and p_exp is null) then 'OK  ' else 'FAIL' end
                         || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
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
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function sale (p_org varchar2, p_cus varchar2, p_ctr varchar2, p_days number, p_amount number) return varchar2 is
    l varchar2(32);
  begin
    insert into doc_goods_sale (organization_id, customer_id, contract_id, warehouse_id, occurred_at)
    values (p_org, p_cus, p_ctr, l_wh, d0 - p_days + 0.5) returning id into l;
    insert into doc_goods_sale_goods (document_id, product_id, quantity, price) values (l, l_p, 1, p_amount);
    trade_ops.post_goods_sale(l);
    return l;
  end;
  -- відкритий залишок / інтервал / днів прострочення документа на дату
  function opn (p_doc varchar2, p_date date default null, p_col varchar2 default 'OPEN', p_line number default null) return varchar2 is
    l varchar2(100);
  begin
    select max(case p_col when 'BUCKET' then bucket when 'DAYS' then to_char(days_overdue)
                          when 'DUE' then to_char(due_date, 'DD.MM.YYYY') when 'CTR' then contract_id
                          when 'TERM' then to_char(term_days) else to_char(open_amount) end)
      into l from table(trade_ar_aging.open_items(coalesce(p_date, d0)))
     where recorder_id = p_doc and (p_line is null or line_number = p_line);
    return l;
  end;
  function tot (p_org varchar2, p_cp varchar2, p_bucket varchar2 default null, p_date date default null, p_ctr varchar2 default null) return number is
    l number;
  begin
    select coalesce(sum(open_amount), 0) into l from table(trade_ar_aging.open_items(coalesce(p_date, d0), p_org, p_cp))
     where (p_bucket is null or bucket = p_bucket) and (p_ctr is null or contract_id = p_ctr);
    return l;
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T17 ТОВ А ' || t, 'LEGAL', '17171717') returning id into l_org;
  insert into ref_organization (name, org_kind, edrpou) values ('T17 ТОВ Б ' || t, 'LEGAL', '17171718') returning id into l_org2;
  insert into ref_cash_desk (name, organization_id) values ('T17 Каса ' || t, l_org) returning id into l_k;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T17 склад ' || t) returning id into l_wh;
  insert into ref_product (name, unit_of_measure_id) values ('T17 Товар ' || t, l_uom) returning id into l_p;
  insert into ref_counterparty (name) values ('T17 постачальник ' || t) returning id into l_sup;
  insert into ref_counterparty (name) values ('T17 А покупець ' || t) returning id into c1;
  insert into ref_counterparty (name) values ('T17 Б покупець ' || t) returning id into c2;
  insert into ref_contract (owner_id, name, contract_number, contract_kind, payment_term_days)
  values (c1, 'T17 Договір 30', 'Д-30', 'WITH_CUSTOMER', 30) returning id into k30;
  insert into ref_contract (owner_id, name, contract_number, contract_kind, payment_term_days)
  values (c1, 'T17 Договір 10', 'Д-10', 'WITH_CUSTOMER', 10) returning id into k10;
  insert into ref_contract (owner_id, name, contract_kind, payment_term_days)
  values (c1, 'T17 Договір без номера', 'WITH_CUSTOMER', 30) returning id into k30b;
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, d0 - 130 + 0.5)
    returning id into rc;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (rc, 1, l_p, 20, 10, 0);
  trade_doc.post_goods_receipt(rc);

  -- орг. А, C1: S1 1000 (Д-30, −100 дн.), S2 500 (Д-10, −50), S3 300 (Д-30, −20), S4 200 (Д-10, −15)
  -- орг. А, C2: S6 400 без договору (−120); орг. Б, C1: S7 100 (Д-30 без номера, −5)
  s1 := sale(l_org, c1, k30, 100, 1000);
  s2 := sale(l_org, c1, k10, 50, 500);
  s3 := sale(l_org, c1, k30, 20, 300);
  s4 := sale(l_org, c1, k10, 15, 200);
  s6 := sale(l_org, c2, null, 120, 400);
  s7 := sale(l_org2, c1, k30b, 5, 100);

  -- ---------------------------------------------------------------- дата погашення
  eqs('S1: відстрочка договору 30', opn(s1, d0 - 60, 'TERM'), '30');
  eqs('S1: дата погашення = дата реалізації + 30', opn(s1, d0 - 60, 'DUE'), to_char(d0 - 70, 'DD.MM.YYYY'));
  eqs('S2: дата погашення = дата + 10', opn(s2, d0 - 45, 'DUE'), to_char(d0 - 40, 'DD.MM.YYYY'));
  eqs('S6: без договору — відстрочка 0', opn(s6, null, 'TERM'), '0');
  eqs('S6: дата погашення = дата реалізації', opn(s6, null, 'DUE'), to_char(d0 - 120, 'DD.MM.YYYY'));
  eqs('S3: договір документа', opn(s3, null, 'CTR'), k30);

  -- ---------------------------------------------------------------- до оплати: усе відкрите
  eq('Борг C1 орг. А до оплати', tot(l_org, c1), 2000);
  eqs('S1 (70 дн.) — 61–90', opn(s1, null, 'BUCKET'), 'D90');
  eqs('S1: днів прострочення 70', opn(s1, null, 'DAYS'), '70');
  eqs('S2 (40 дн.) — 31–60', opn(s2, null, 'BUCKET'), 'D60');
  eqs('S3 (строк через 10 дн.) — не настав', opn(s3, null, 'BUCKET'), 'NOT_DUE');
  eqs('S3: днів прострочення −10', opn(s3, null, 'DAYS'), '-10');
  eqs('S4 (5 дн.) — 1–30', opn(s4, null, 'BUCKET'), 'D30');
  eqs('S6 (120 дн.) — понад 90', opn(s6, null, 'BUCKET'), 'D90P');
  eqs('Межа: 0 днів — не настав', trade_ar_aging.bucket_of(0), 'NOT_DUE');
  eqs('Межа: 30 днів — 1–30', trade_ar_aging.bucket_of(30), 'D30');
  eqs('Межа: 31 день — 31–60', trade_ar_aging.bucket_of(31), 'D60');
  eqs('Межа: 90 днів — 61–90', trade_ar_aging.bucket_of(90), 'D90');
  eqs('Межа: 91 день — понад 90', trade_ar_aging.bucket_of(91), 'D90P');

  -- ---------------------------------------------------------------- оплата FIFO
  insert into doc_customer_payment (organization_id, customer_id, amount, occurred_at, payment_form, cash_desk_id)
  values (l_org, c1, 1200, d0 - 10 + 0.5, 'CASH', l_k) returning id into pay;
  trade_cust_pay.post_customer_payment(pay);
  eqs('Оплата 1200: S1 погашено повністю', opn(s1), null);
  eqs('Оплата 1200: S2 залишок 300', opn(s2), '300');
  eqs('S3 відкритий повністю', opn(s3), '300');
  eqs('S4 відкритий повністю', opn(s4), '200');
  select coalesce(sum(amount), 0) into l_v from doc_customer_payment_alloc where document_id = pay and settlement_doc_id in (s1, s2);
  eq('Розшифровка платежу узгоджена з FIFO (S1 + S2)', l_v, 1200);
  eq('Борг C1 орг. А', tot(l_org, c1), 800);
  eq('C1 орг. А: не настав', tot(l_org, c1, 'NOT_DUE'), 300);
  eq('C1 орг. А: 1–30', tot(l_org, c1, 'D30'), 200);
  eq('C1 орг. А: 31–60', tot(l_org, c1, 'D60'), 300);
  eq('C1 орг. А: 61–90', tot(l_org, c1, 'D90'), 0);
  eq('C1 орг. А: за договором Д-10', tot(l_org, c1, null, null, k10), 500);
  eq('C1 орг. А: за договором Д-30', tot(l_org, c1, null, null, k30), 300);
  eq('C1 орг. Б окремо (організація — вимір розподілу)', tot(l_org2, c1), 100);
  eq('Сума відкритих = сальдо регістру (C1, орг. А)', tot(l_org, c1),
     trade_debt_adj.debt_at(l_org, c1, 'RECEIVABLE', d0 + 1));

  -- ---------------------------------------------------------------- прострочений борг («Поточні справи»)
  eq('Прострочено орг. А (300 + 200 + 400)', trade_ar_aging.overdue_total(d0, l_org), 900);
  eq('Боржників з простроченням орг. А', trade_ar_aging.overdue_count(d0, l_org), 2);
  eq('Прострочено орг. Б — немає', trade_ar_aging.overdue_total(d0, l_org2), 0);
  eq('Орг. Б через 30 днів: S7 прострочено 5 дн.', trade_ar_aging.overdue_total(d0 + 30, l_org2), 100);

  -- ---------------------------------------------------------------- історична дата (до оплати)
  eq('На −45: борг C1 орг. А (S1 + S2)', tot(l_org, c1, null, d0 - 45), 1500);
  eqs('На −45: S1 прострочено 25 дн. — 1–30', opn(s1, d0 - 45, 'BUCKET'), 'D30');
  eqs('На −45: S2 строк не настав', opn(s2, d0 - 45, 'BUCKET'), 'NOT_DUE');
  eqs('На −45: S6 прострочено 75 дн. — 61–90', opn(s6, d0 - 45, 'BUCKET'), 'D90');
  eq('На −60: S2 ще не існує — борг C1 лише S1', tot(l_org, c1, null, d0 - 60), 1000);
  eq('На −11 (до оплати): S1 відкритий', to_number(opn(s1, d0 - 11)), 1000);
  eq('На дату до всіх продажів — порожньо', tot(l_org, null, null, d0 - 200), 0);

  -- ---------------------------------------------------------------- перенесення боргу між договорами
  -- перенесення 200 з Д-10 на Д-30 (коригування боргу): новий документ боргу на договорі-одержувачі
  insert into doc_debt_adjustment (organization_id, occurred_at, operation_kind, counterparty_id, contract_id, target_counterparty_id,
                                   target_contract_id, amount)
  values (l_org, d0 - 1 + 0.5, 'TRANSFER_RECEIVABLE', c1, k10, c1, k30, 200) returning id into adj;
  trade_debt_adj.post(adj);
  eq('Після перенесення: борг C1 орг. А не змінився', tot(l_org, c1), 800);
  eqs('Перенесення: «+»-рядок — договір-одержувач', opn(adj, null, 'CTR', 2), k30);
  eqs('Перенесення: строк від дати документа + 30 — не настав', opn(adj, null, 'BUCKET', 2), 'NOT_DUE');
  eq('Перенесення: «−»-рядок погашає найстаріший борг (S2 залишок 100)', to_number(opn(s2)), 100);
  eq('C1 орг. А за договором Д-30 (300 + 200)', tot(l_org, c1, null, null, k30), 500);
  eq('Прострочено орг. А після перенесення (100 + 200 + 400)', trade_ar_aging.overdue_total(d0, l_org), 700);

  -- ---------------------------------------------------------------- HTML
  l_c := trade_ar_aging.aging_html(d0, l_org, null, 'CONTRACT');
  has('HTML: заголовок', l_c, 'Дебіторська заборгованість за термінами на ' || to_char(d0, 'DD.MM.YYYY'));
  has('HTML: організація', l_c, 'T17 ТОВ А ' || t);
  has('HTML: контрагент C1', l_c, 'T17 А покупець ' || t);
  has('HTML: договір з номером', l_c, 'Договір № Д-10');
  has('HTML: відстрочка договору', l_c, '(відстрочка 30 дн.)');
  has('HTML: без документів у режимі договорів', l_c, 'Реалізація товарів', 0);
  has('HTML: зведення за інтервалами', l_c, 'Прострочено понад 90 днів');
  has('HTML: разом', l_c, '<td class="r">' || m(1200) || '</td>');
  has('HTML: без APEX-сесії — без посилань', l_c, '<a href=', 0);
  has('HTML: «Без договору» (C2)', l_c, 'Без договору');
  l_c := trade_ar_aging.aging_html(d0, l_org, c1, 'DOCUMENT');
  select recorder_name into l_s from v_recorder where recorder_id = s2;
  has('HTML документів: реалізація S2', l_c, l_s);
  has('HTML документів: частковий залишок S2', l_c, '(сума ' || m(500) || ', залишок ' || m(100) || ')');
  select recorder_name into l_s from v_recorder where recorder_id = s1;
  has('HTML документів: погашена S1 відсутня', l_c, l_s, 0);
  has('HTML документів: дата погашення S4', l_c, '<td class="c">' || to_char(d0 - 5, 'DD.MM.YYYY') || '</td>');
  has('HTML документів: відбір контрагента — без C2', l_c, 'T17 Б покупець', 0);
  l_c := trade_ar_aging.aging_html(d0, l_org2, null, 'CONTRACT', 'Y');
  has('HTML: лише прострочена, орг. Б — порожньо', l_c, 'Простроченої дебіторської заборгованості немає.');
  l_c := trade_ar_aging.aging_html(d0 - 200, l_org);
  has('HTML: на дату без боргів', l_c, 'Дебіторської заборгованості немає.');

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'ReceivablesAging' and list_page_id = 470 and kind = 'REPORT';
  eq('Об''єкт метаданих «Дебіторка за термінами»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'ReceivablesAging';
  eq('Панель функцій: 3 розділи', l_n, 3);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
