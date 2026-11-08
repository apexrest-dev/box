-- =============================================================================
-- Trade r5 — F-TAX-01 «ПДВ і податкові накладні» (APE-67). Паспорти RefVatRate, DocTaxInvoice,
-- RegVatLedger (PROPOSED); зміни RefProduct, RefPriceType, RefCounterparty, документів з товарами.
--   * довідник-перелік ref_vat_rate «Ставки ПДВ»: VAT20 (20 %), VAT7 (7 %), VAT0 (0 %), EXEMPT
--     (звільнено від ПДВ), NOVAT (без ПДВ — організація / постачальник не платник, не об'єкт);
--     код ставки ЄРПН (20 / 7 / 901 / 903) для податкової накладної;
--   * номенклатура: «Ставка ПДВ» (за замовчуванням 20 %) і «Код УКТ ЗЕД / ДКПП»; вид цін:
--     «Ціна включає ПДВ» (за замовчуванням так); контрагент: «Платник ПДВ» + ІПН (12 цифр);
--   * документи з цінами — реалізація, надходження, повернення від клієнта / постачальнику, рахунок
--     на оплату: у шапці «Ціни» (price_includes_vat: Y — ціна включає ПДВ, N — ПДВ зверху) і «Сума
--     ПДВ»; у рядках «Ставка ПДВ», «Сума ПДВ», «Всього». Сума рядка лишається кількість × ціна;
--     ПДВ = сума × ставка / (100 + ставка) (включає) або сума × ставка / 100 (зверху); Всього = сума
--     (включає) або сума + ПДВ (зверху). Підсумок документа total_amount = Σ «Всього» — саме він
--     рухає взаєморозрахунки й оплати (пакети проведення не змінено). Ставка рядка — з номенклатури;
--     організація не платник → NOVAT; у закупівлях постачальник не платник → NOVAT; повернення — зі
--     ставкою й режимом цін документа-підстави. Розраховують окремі тригери *_vat (follows *_ct);
--   * документ doc_tax_invoice «Податкова накладна» (видані ISSUED / отримані RECEIVED): дата
--     складання = дата першої події, контрагент, договір, підстава (реалізація / оплата / ПКО /
--     виписка; для отриманих — надходження), рядки з кодом УКТ ЗЕД, ціною й обсягом без ПДВ і ставкою;
--     стан ЄРПН (не надіслано / надіслано / зареєстровано / відхилено, номер і дата реєстрації) —
--     вручну, API для обміну M.E.Doc / Вчасно (APE-306); вид PN (РК — APE-302, поле зарезервовано);
--   * правило першої події: за ключем організація × контрагент (без договору — оплати часто без нього) накопичені відвантаження S і
--     оплати P (рухи RECEIVABLE оплат / ПКО / виписок / повернення коштів); податкове зобов'язання
--     події = max(S, P) після − max(S, P) до. Відвантаження, покрите попередньою оплатою, ПН не
--     потребує; частково покрите — ПН на непокриту частину (рядки за ставками пропорційно);
--     оплата понад відвантаження — ПН на передоплату. trade_tax.events — події з базою, виданими
--     ПН і залишком; generate — ПН за всіма подіями періоду із залишком;
--   * проведення ПН: контроль платника ПДВ, суми ≤ залишку бази першої події, реквізити отриманої;
--     рухи регістру reg_vat_mv «ПДВ: зобов'язання й кредит» за ставками (LIABILITY / CREDIT);
--     зареєстровану / надіслану ПН скасувати не можна (лише коригування — APE-302);
--   * друк «Податкова накладна», «у т. ч. ПДВ» / «ПДВ / Всього з ПДВ» у друкованих формах (db/20),
--     XML для ЄРПН (спрощена структура J1201016, без КЕП і відправлення — APE-306);
--   * реєстр ПН і зведення ПДВ (сторінка 630), меню «Фінанси → ПДВ», v_recorder (+ DocTaxInvoice).
-- Потребує 02, 06, 13, 14, 24, 32, 36, 37, 39. Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено (усі реєстратори r1–r5).
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefVatRate (перелік)
  ddl(q'[create table ref_vat_rate (
    code        varchar2(10)  not null,
    name        varchar2(100) not null,
    rate        number(5,2)   not null,
    erpn_code   varchar2(3),
    sort_order  number(3)     not null,
    constraint ref_vat_rate_pk primary key (code))]');

  execute immediate q'[merge into ref_vat_rate t
  using (select 'VAT20' code, '20 %' name, 20 rate, '20' erpn_code, 10 sort_order from dual
         union all select 'VAT7', '7 %', 7, '7', 20 from dual
         union all select 'VAT0', '0 %', 0, '901', 30 from dual
         union all select 'EXEMPT', 'Звільнено від ПДВ', 0, '903', 40 from dual
         union all select 'NOVAT', 'Без ПДВ', 0, null, 50 from dual) s
     on (t.code = s.code)
   when matched then update set t.name = s.name, t.rate = s.rate, t.erpn_code = s.erpn_code, t.sort_order = s.sort_order
   when not matched then insert (code, name, rate, erpn_code, sort_order) values (s.code, s.name, s.rate, s.erpn_code, s.sort_order)]';
  commit;

  -- ---------------------------------------------------------------- НСІ
  ddl(q'[alter table ref_product add (vat_rate_code varchar2(10) default on null 'VAT20' not null, uktzed_code varchar2(10))]');
  ddl(q'[alter table ref_product add constraint ref_product_vat_fk foreign key (vat_rate_code) references ref_vat_rate (code)]');
  ddl(q'[alter table ref_product add constraint ref_product_vat_ck check (vat_rate_code <> 'NOVAT')]');
  ddl(q'[alter table ref_price_type add (price_includes_vat varchar2(1) default on null 'Y' not null)]');
  ddl(q'[alter table ref_price_type add constraint ref_price_type_vat_ck check (price_includes_vat in ('Y','N'))]');
  ddl(q'[alter table ref_counterparty add (vat_payer varchar2(1) default on null 'N' not null, vat_number varchar2(12))]');
  ddl(q'[alter table ref_counterparty add constraint ref_counterparty_vat_ck check (vat_payer in ('Y','N'))]');

  -- ---------------------------------------------------------------- документи з цінами
  for t in (select column_value tab from table(sys.odcivarchar2list('DOC_GOODS_SALE', 'DOC_GOODS_RECEIPT', 'DOC_CUSTOMER_RETURN',
                                                                     'DOC_SUPPLIER_RETURN', 'DOC_INVOICE_FOR_PAYMENT'))) loop
    ddl('alter table ' || t.tab || ' add (price_includes_vat varchar2(1), vat_amount number(19,2) default on null 0 not null)');
    ddl('alter table ' || t.tab || ' add constraint ' || substr(t.tab, 1, 22) || '_piv_ck check (price_includes_vat in (''Y'',''N''))');
    ddl('alter table ' || t.tab || '_GOODS add (vat_rate_code varchar2(10), vat_amount number(19,2) default on null 0 not null, '
        || 'amount_with_vat number(19,2) default on null 0 not null)');
    ddl('alter table ' || t.tab || '_GOODS add constraint ' || substr(t.tab, 1, 22) || '_g_vat_fk foreign key (vat_rate_code) '
        || 'references ref_vat_rate (code)');
  end loop;

  -- ---------------------------------------------------------------- DocTaxInvoice
  ddl('create sequence doc_tax_invoice_num_seq nocache');
  ddl(q'[create table doc_tax_invoice (
    id                   varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number           varchar2(9)    not null,
    occurred_at          date           default on null sysdate not null,
    organization_id      varchar2(32)   not null,
    direction            varchar2(10)   default on null 'ISSUED' not null,
    invoice_kind         varchar2(2)    default on null 'PN' not null,
    corrected_invoice_id varchar2(32),
    counterparty_id      varchar2(32)   not null,
    contract_id          varchar2(32),
    event_kind           varchar2(10)   default on null 'MANUAL' not null,
    base_doc_type        varchar2(60),
    base_doc_id          varchar2(32),
    ext_number           varchar2(30),
    seller_vat_number    varchar2(12),
    buyer_vat_number     varchar2(12),
    not_issued_reason    varchar2(2),
    amount_without_vat   number(19,2)   default on null 0 not null,
    vat_amount           number(19,2)   default on null 0 not null,
    total_amount         number(19,2)   default on null 0 not null,
    erpn_status          varchar2(10)   default on null 'NOT_SENT' not null,
    erpn_reg_number      varchar2(30),
    erpn_reg_date        date,
    erpn_message         varchar2(1000),
    doc_comment          varchar2(1000),
    status               varchar2(10)   default on null 'DRAFT' not null,
    version              number(19)     default on null 0 not null,
    created_at           timestamp      not null,
    created_by           varchar2(255)  not null,
    updated_at           timestamp      not null,
    updated_by           varchar2(255)  not null,
    constraint doc_tax_invoice_pk primary key (id),
    constraint doc_tax_invoice_num_uk unique (doc_number),
    constraint doc_tax_invoice_st_ck check (status in ('DRAFT','POSTED')),
    constraint doc_tax_invoice_dir_ck check (direction in ('ISSUED','RECEIVED')),
    constraint doc_tax_invoice_kind_ck check (invoice_kind in ('PN','RK')),
    constraint doc_tax_invoice_ev_ck check (event_kind in ('SHIPMENT','PREPAYMENT','MANUAL')),
    constraint doc_tax_invoice_erpn_ck check (erpn_status in ('NOT_SENT','SENT','REGISTERED','REJECTED')),
    constraint doc_tax_invoice_org_fk foreign key (organization_id) references ref_organization (id),
    constraint doc_tax_invoice_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint doc_tax_invoice_ctr_fk foreign key (contract_id) references ref_contract (id),
    constraint doc_tax_invoice_corr_fk foreign key (corrected_invoice_id) references doc_tax_invoice (id))]');
  ddl('create index doc_tax_invoice_base_ix on doc_tax_invoice (base_doc_id)');
  ddl('create index doc_tax_invoice_date_ix on doc_tax_invoice (occurred_at)');
  ddl(q'[create table doc_tax_invoice_goods (
    id            varchar2(32)  default on null rawtohex(sys_guid()) not null,
    document_id   varchar2(32)  not null,
    line_number   number(10)    default on null 0 not null,
    product_id    varchar2(32),
    description   varchar2(500) not null,
    uktzed_code   varchar2(10),
    unit_name     varchar2(20),
    quantity      number(19,3)  not null,
    price         number(19,2)  not null,
    amount        number(19,2)  default on null 0 not null,
    vat_rate_code varchar2(10)  not null,
    vat_amount    number(19,2)  default on null 0 not null,
    constraint doc_tax_invoice_g_pk primary key (id),
    constraint doc_tax_invoice_g_doc_fk foreign key (document_id) references doc_tax_invoice (id) on delete cascade,
    constraint doc_tax_invoice_g_prd_fk foreign key (product_id) references ref_product (id),
    constraint doc_tax_invoice_g_vat_fk foreign key (vat_rate_code) references ref_vat_rate (code),
    constraint doc_tax_invoice_g_qty_ck check (quantity > 0))]');
  ddl('create index doc_tax_invoice_g_doc_ix on doc_tax_invoice_goods (document_id, line_number)');

  -- ---------------------------------------------------------------- RegVatLedger
  ddl(q'[create table reg_vat_mv (
    id              varchar2(32)  default on null rawtohex(sys_guid()) not null,
    period          date          not null,
    recorder_type   varchar2(60)  not null,
    recorder_id     varchar2(32)  not null,
    line_number     number(10)    not null,
    organization_id varchar2(32)  not null,
    counterparty_id varchar2(32)  not null,
    direction       varchar2(10)  not null,
    vat_rate_code   varchar2(10)  not null,
    base_amount     number(19,2)  not null,
    vat_amount      number(19,2)  not null,
    constraint reg_vat_mv_pk primary key (id),
    constraint reg_vat_mv_uk unique (recorder_type, recorder_id, line_number),
    constraint reg_vat_mv_dir_ck check (direction in ('LIABILITY','CREDIT')),
    constraint reg_vat_mv_org_fk foreign key (organization_id) references ref_organization (id),
    constraint reg_vat_mv_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint reg_vat_mv_vat_fk foreign key (vat_rate_code) references ref_vat_rate (code))]');
  ddl('create index reg_vat_mv_org_ix on reg_vat_mv (organization_id, period)');
end;
/

-- =============================================================================
-- trade_vat — ПДВ у рядках документів
-- =============================================================================
create or replace package trade_vat as
  -- Типи документів з ПДВ: DocGoodsSale, DocGoodsReceipt, DocCustomerReturn, DocSupplierReturn, DocInvoiceForPayment
  function header_table (p_type in varchar2) return varchar2;
  function rate_pct (p_code in varchar2) return number;
  function rate_name (p_code in varchar2) return varchar2;
  -- ПДВ із суми: включає (p_incl = 'Y') — сума × r / (100 + r); зверху — сума × r / 100
  function vat_of (p_amount in number, p_code in varchar2, p_incl in varchar2) return number;
  -- Ставка рядка за замовчуванням (товар, платник ПДВ організації / постачальника, рядок-підстава повернення)
  function default_rate (p_type in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_base_line_id in varchar2) return varchar2;
  -- Тригер рядків *_vat: ставка, сума ПДВ і «Всього»
  procedure calc_line (p_type in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_base_line_id in varchar2,
                       p_rate in out varchar2, p_reset in boolean, p_amount in number,
                       p_vat out number, p_total out number);
  -- Тригер рядків *_vat (після оператора): vat_amount і total_amount шапки
  procedure update_totals (p_type in varchar2, p_doc_id in varchar2);
  -- Тригер шапки *_vat: режим цін (з виду цін, документа-підстави; повернення — як у підстави)
  procedure resolve_flag (p_type in varchar2, p_inserting in boolean, p_flag in out varchar2, p_old_flag in varchar2,
                          p_base_id in varchar2, p_pt in varchar2, p_old_pt in varchar2);
  -- Перерахунок рядків (зміна режиму цін; p_reset — ставки заново за замовчуванням: зміна організації / контрагента)
  procedure recalc (p_type in varchar2, p_doc_id in varchar2, p_reset in boolean default false);
  -- «Скопіювати»: режим цін і ставки рядків з документа-джерела
  procedure copy_lines (p_type in varchar2, p_src_id in varchar2, p_dst_id in varchar2);
  -- Друк: рядки підсумку «Разом / у т. ч. ПДВ» (null — документ без ПДВ-обліку)
  function totals_html (p_doc_id in varchar2, p_total in number) return varchar2;
end trade_vat;
/

create or replace package body trade_vat as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;

  function header_table (p_type in varchar2) return varchar2 is
  begin
    return case p_type
      when 'DocGoodsSale'         then 'DOC_GOODS_SALE'
      when 'DocGoodsReceipt'      then 'DOC_GOODS_RECEIPT'
      when 'DocCustomerReturn'    then 'DOC_CUSTOMER_RETURN'
      when 'DocSupplierReturn'    then 'DOC_SUPPLIER_RETURN'
      when 'DocInvoiceForPayment' then 'DOC_INVOICE_FOR_PAYMENT' end;
  end header_table;

  function cp_column (p_type varchar2) return varchar2 is
  begin
    return case when p_type in ('DocGoodsReceipt', 'DocSupplierReturn') then 'supplier_id' else 'customer_id' end;
  end cp_column;

  function is_purchase (p_type varchar2) return boolean is
  begin
    return p_type in ('DocGoodsReceipt', 'DocSupplierReturn');
  end is_purchase;

  function rate_pct (p_code in varchar2) return number is
    l number;
  begin
    select max(rate) into l from ref_vat_rate where code = p_code;
    return coalesce(l, 0);
  end rate_pct;

  function rate_name (p_code in varchar2) return varchar2 is
    l varchar2(100);
  begin
    select max(name) into l from ref_vat_rate where code = p_code;
    return l;
  end rate_name;

  function vat_of (p_amount in number, p_code in varchar2, p_incl in varchar2) return number is
    r number := rate_pct(p_code);
  begin
    if r = 0 or p_amount is null then return 0; end if;
    return case when nvl(p_incl, 'Y') = 'Y' then round(p_amount * r / (100 + r), 2) else round(p_amount * r / 100, 2) end;
  end vat_of;

  procedure header_info (p_type varchar2, p_doc_id varchar2, o_flag out varchar2, o_org_payer out varchar2, o_cp_payer out varchar2) is
  begin
    execute immediate 'select nvl(d.price_includes_vat, ''Y''), nvl(o.vat_payer, ''N''), nvl(c.vat_payer, ''N'')'
      || ' from ' || header_table(p_type) || ' d left join ref_organization o on o.id = d.organization_id'
      || ' left join ref_counterparty c on c.id = d.' || cp_column(p_type) || ' where d.id = :i'
      into o_flag, o_org_payer, o_cp_payer using p_doc_id;
  exception when no_data_found then
    o_flag := 'Y'; o_org_payer := 'N'; o_cp_payer := 'N';
  end header_info;

  function default_rate (p_type in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_base_line_id in varchar2) return varchar2 is
    l_flag varchar2(1); l_org varchar2(1); l_cp varchar2(1); l varchar2(10);
  begin
    header_info(p_type, p_doc_id, l_flag, l_org, l_cp);
    if l_org = 'N' then
      return 'NOVAT';
    end if;
    if p_base_line_id is not null then
      if p_type = 'DocCustomerReturn' then
        select max(vat_rate_code) into l from doc_goods_sale_goods where id = p_base_line_id;
      elsif p_type = 'DocSupplierReturn' then
        select max(vat_rate_code) into l from doc_goods_receipt_goods where id = p_base_line_id;
      end if;
      if l is not null then return l; end if;
    end if;
    if is_purchase(p_type) and l_cp = 'N' then
      return 'NOVAT';
    end if;
    select max(vat_rate_code) into l from ref_product where id = p_product_id;
    return coalesce(l, 'VAT20');
  end default_rate;

  procedure calc_line (p_type in varchar2, p_doc_id in varchar2, p_product_id in varchar2, p_base_line_id in varchar2,
                       p_rate in out varchar2, p_reset in boolean, p_amount in number,
                       p_vat out number, p_total out number) is
    l_flag varchar2(1); l_org varchar2(1); l_cp varchar2(1);
  begin
    header_info(p_type, p_doc_id, l_flag, l_org, l_cp);
    if p_reset or p_rate is null then
      p_rate := default_rate(p_type, p_doc_id, p_product_id, p_base_line_id);
    end if;
    if l_org = 'N' then
      p_rate := 'NOVAT';   -- організація не платник ПДВ: ПДВ не нараховується
    end if;
    p_vat := vat_of(p_amount, p_rate, l_flag);
    p_total := case when l_flag = 'Y' then p_amount else p_amount + p_vat end;
  end calc_line;

  procedure update_totals (p_type in varchar2, p_doc_id in varchar2) is
    l_t varchar2(30) := header_table(p_type);
  begin
    execute immediate 'update ' || l_t || ' d set d.vat_amount = (select coalesce(sum(g.vat_amount), 0) from ' || l_t
      || '_goods g where g.document_id = d.id), d.total_amount = (select coalesce(sum(g.amount_with_vat), 0) from ' || l_t
      || '_goods g where g.document_id = d.id) where d.id = :i' using p_doc_id;
  end update_totals;

  function pt_flag (p_pt varchar2) return varchar2 is
    l varchar2(1);
  begin
    select max(price_includes_vat) into l from ref_price_type where id = p_pt;
    return l;
  end pt_flag;

  procedure resolve_flag (p_type in varchar2, p_inserting in boolean, p_flag in out varchar2, p_old_flag in varchar2,
                          p_base_id in varchar2, p_pt in varchar2, p_old_pt in varchar2) is
    l varchar2(1);
  begin
    if p_type in ('DocCustomerReturn', 'DocSupplierReturn') and p_base_id is not null then
      -- повернення — у режимі цін документа-підстави (сума повернення = сума боргу за підставою)
      if p_type = 'DocCustomerReturn' then
        select max(price_includes_vat) into l from doc_goods_sale where id = p_base_id;
      else
        select max(price_includes_vat) into l from doc_goods_receipt where id = p_base_id;
      end if;
      p_flag := coalesce(l, p_flag, 'Y');
      return;
    end if;
    if p_inserting then
      if p_flag is null then
        l := pt_flag(p_pt);
        if l is null and p_base_id is not null and p_type in ('DocGoodsSale', 'DocInvoiceForPayment') then
          select max(pt.price_includes_vat) into l
            from doc_customer_order o join ref_price_type pt on pt.id = o.price_type_id where o.id = p_base_id;
        end if;
        p_flag := coalesce(l, 'Y');
      end if;
    else
      if p_flag is null then
        p_flag := coalesce(p_old_flag, 'Y');
      elsif p_type = 'DocGoodsSale' and p_pt is not null and nvl(p_pt, '-') <> nvl(p_old_pt, '-')
            and p_flag = nvl(p_old_flag, 'Y') then
        p_flag := coalesce(pt_flag(p_pt), p_flag);   -- новий вид цін — його режим ПДВ
      end if;
    end if;
    if p_flag not in ('Y', 'N') then
      fail('VAT_PRICE_MODE', 'Режим цін: Y — ціна включає ПДВ, N — ПДВ зверху.');
    end if;
  end resolve_flag;

  procedure recalc (p_type in varchar2, p_doc_id in varchar2, p_reset in boolean default false) is
  begin
    execute immediate 'update ' || header_table(p_type) || '_goods set vat_rate_code = '
      || case when p_reset then 'null' else 'vat_rate_code' end || ' where document_id = :d' using p_doc_id;
  end recalc;

  procedure copy_lines (p_type in varchar2, p_src_id in varchar2, p_dst_id in varchar2) is
    l_t varchar2(30) := header_table(p_type);
  begin
    if l_t is null or p_dst_id is null then return; end if;
    execute immediate 'update ' || l_t || ' d set d.price_includes_vat = (select s.price_includes_vat from ' || l_t
      || ' s where s.id = :s) where d.id = :d' using p_src_id, p_dst_id;
    execute immediate 'merge into ' || l_t || '_goods t using (select line_number, vat_rate_code from ' || l_t
      || '_goods where document_id = :s) s on (t.document_id = :d and t.line_number = s.line_number)'
      || ' when matched then update set t.vat_rate_code = s.vat_rate_code' using p_src_id, p_dst_id;
  end copy_lines;

  function totals_html (p_doc_id in varchar2, p_total in number) return varchar2 is
    l_type varchar2(60); l_flag varchar2(1); l_vat number; l_amt number; l_taxed number;
    function row_ (p_label varchar2, p_val varchar2, p_bold boolean default false) return varchar2 is
    begin
      return '<tr><td class="r">' || case when p_bold then '<b>' end || p_label || case when p_bold then '</b>' end
        || '</td><td class="r" style="width:130px">' || case when p_bold then '<b>' end || p_val
        || case when p_bold then '</b>' end || '</td></tr>';
    end;
  begin
    for t in (select column_value typ from table(sys.odcivarchar2list('DocGoodsSale', 'DocGoodsReceipt', 'DocCustomerReturn',
                                                                      'DocSupplierReturn', 'DocInvoiceForPayment'))) loop
      begin
        execute immediate 'select nvl(d.price_includes_vat, ''Y''), d.vat_amount, (select coalesce(sum(g.amount), 0) from '
          || header_table(t.typ) || '_goods g where g.document_id = d.id), (select count(*) from ' || header_table(t.typ)
          || '_goods g where g.document_id = d.id and nvl(g.vat_rate_code, ''NOVAT'') <> ''NOVAT'') from '
          || header_table(t.typ) || ' d where d.id = :i' into l_flag, l_vat, l_amt, l_taxed using p_doc_id;
        l_type := t.typ;
        exit;
      exception when no_data_found then null;
      end;
    end loop;
    if l_type is null then
      return null;
    end if;
    if l_taxed = 0 then
      return '<table class="tot">' || row_('Разом:', m(p_total), true) || row_('Без ПДВ', null) || '</table>';
    elsif l_flag = 'Y' then
      return '<table class="tot">' || row_('Разом:', m(p_total), true) || row_('У тому числі ПДВ:', m(l_vat)) || '</table>';
    else
      return '<table class="tot">' || row_('Разом без ПДВ:', m(l_amt)) || row_('ПДВ:', m(l_vat))
        || row_('Всього з ПДВ:', m(p_total), true) || '</table>';
    end if;
  end totals_html;

end trade_vat;
/

-- ---------------------------------------------------------------- тригери шапок і рядків (follows *_ct)
begin
  for t in (select 'DOC_GOODS_SALE' tab, 'DocGoodsSale' typ, 'customer_id' cp, ':new.base_order_id' base, ':new.price_type_id' pt,
                   ':old.price_type_id' opt, 'null' bline from dual
            union all select 'DOC_GOODS_RECEIPT', 'DocGoodsReceipt', 'supplier_id', 'null', 'null', 'null', 'null' from dual
            union all select 'DOC_CUSTOMER_RETURN', 'DocCustomerReturn', 'customer_id', ':new.base_sale_id', 'null', 'null',
                             ':new.base_sale_line_id' from dual
            union all select 'DOC_SUPPLIER_RETURN', 'DocSupplierReturn', 'supplier_id', ':new.base_receipt_id', 'null', 'null',
                             ':new.base_receipt_line_id' from dual
            union all select 'DOC_INVOICE_FOR_PAYMENT', 'DocInvoiceForPayment', 'customer_id', ':new.base_order_id', 'null', 'null',
                             'null' from dual) loop
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_vat' || chr(10)
      || 'for insert or update on ' || lower(t.tab) || chr(10)
      || q'[compound trigger
  -- r5 F-TAX-01 (db/42): режим цін ПДВ і перерахунок рядків
  type t_ids is table of varchar2(1) index by varchar2(32);
  g_ids t_ids;
  before each row is
  begin
    trade_vat.resolve_flag(']' || t.typ || q'[', inserting, :new.price_includes_vat, :old.price_includes_vat, ]'
      || t.base || ', ' || t.pt || ', ' || t.opt || q'[);
  end before each row;
  after each row is
  begin
    if updating then
      if nvl(:new.organization_id, '-') <> nvl(:old.organization_id, '-') or :new.]' || t.cp || ' <> :old.' || t.cp || q'[ then
        g_ids(:new.id) := 'Y';
      elsif :new.price_includes_vat <> nvl(:old.price_includes_vat, '-') and not g_ids.exists(:new.id) then
        g_ids(:new.id) := 'N';
      end if;
    end if;
  end after each row;
  after statement is
    l varchar2(32);
    c t_ids := g_ids;
  begin
    g_ids.delete;
    l := c.first;
    while l is not null loop
      trade_vat.recalc(']' || t.typ || q'[', l, c(l) = 'Y');
      l := c.next(l);
    end loop;
  end after statement;
end;]';
    execute immediate 'create or replace trigger ' || lower(t.tab) || '_goods_vat' || chr(10)
      || 'for insert or update or delete on ' || lower(t.tab) || '_goods' || chr(10)
      || 'follows ' || lower(t.tab) || '_goods_ct' || chr(10)
      || q'[compound trigger
  -- r5 F-TAX-01 (db/42): ставка, сума ПДВ і «Всього» рядка; підсумки шапки (після *_ct)
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
  begin
    if deleting then
      if not trade_core.g_deleting_doc then
        g_docs(:old.document_id) := :old.document_id;
      end if;
    else
      trade_vat.calc_line(']' || t.typ || q'[', :new.document_id, :new.product_id, ]' || t.bline || q'[, :new.vat_rate_code,
        updating and :new.product_id <> :old.product_id and nvl(:new.vat_rate_code, '-') = nvl(:old.vat_rate_code, '-'),
        :new.amount, :new.vat_amount, :new.amount_with_vat);
      g_docs(:new.document_id) := :new.document_id;
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_vat.update_totals(']' || t.typ || q'[', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end;]';
  end loop;
end;
/

-- ---------------------------------------------------------------- контрагент: платник ПДВ
create or replace trigger ref_counterparty_vat_biu
before insert or update of vat_payer, vat_number on ref_counterparty for each row
-- r5 F-TAX-01 (db/42)
begin
  :new.vat_number := trim(:new.vat_number);
  if :new.vat_payer = 'Y' and not (length(:new.vat_number) = 12 and translate(:new.vat_number, 'x0123456789', 'x') is null) then
    trade_nsi.fail('COUNTERPARTY_VAT_NUMBER', 'Для платника ПДВ вкажіть індивідуальний податковий номер (ІПН) — 12 цифр.');
  end if;
  if :new.vat_payer = 'N' then
    :new.vat_number := null;
  end if;
end;
/

-- =============================================================================
-- trade_tax — податкові накладні, перша подія, реєстр
-- =============================================================================
create or replace package trade_tax as
  c_type constant varchar2(60) := 'DocTaxInvoice';
  c_non_payer_ipn constant varchar2(12) := '100000000000';   -- ІПН покупця-неплатника в ПН

  type ev_row is record (
    organization_id  varchar2(32),
    counterparty_id  varchar2(32),
    contract_id      varchar2(32),
    event_kind       varchar2(10),   -- SHIPMENT / PAYMENT
    doc_type         varchar2(60),
    doc_id           varchar2(32),
    event_date       date,
    event_amount     number,         -- сума події з ПДВ
    base_amount      number,         -- податкове зобов'язання за правилом першої події
    invoiced_amount  number,         -- видано ПН за подією
    remaining_amount number);        -- ще не оформлено ПН
  type ev_tab is table of ev_row;

  -- Приріст зобов'язання: max(S + s, P + p) − max(S, P), не менше 0
  function liability_increase (p_shipped in number, p_paid in number, p_ship in number, p_pay in number) return number;
  -- Події першої події (відбір за періодом / організацією / контрагентом / документом)
  function events (p_from in date default null, p_to in date default null, p_org in varchar2 default null,
                   p_cp in varchar2 default null, p_doc_id in varchar2 default null) return ev_tab pipelined;
  -- Граничний строк реєстрації в ЄРПН: складена 1–15 числа — до кінця місяця, 16–31 — до 15 числа наступного
  function erpn_deadline (p_date in date) return date;
  function status_name (p_status in varchar2) return varchar2;
  function erpn_status_name (p_status in varchar2) return varchar2;

  -- Створити ПН на підставі: реалізації / оплати від покупця / ПКО / виписки (видана), надходження (отримана)
  function create_from_base (p_type in varchar2, p_id in varchar2) return varchar2;
  -- ПН за всіма подіями періоду з неоформленим залишком; p_post = 'Y' — одразу провести; повертає кількість
  function generate (p_from in date, p_to in date, p_org in varchar2 default null, p_post in varchar2 default 'Y') return number;

  procedure post   (p_id in varchar2);
  procedure unpost (p_id in varchar2);
  function  copy   (p_id in varchar2) return varchar2;
  -- Стан у ЄРПН (вручну; API для обміну M.E.Doc / Вчасно — APE-306)
  procedure set_erpn (p_id in varchar2, p_status in varchar2, p_reg_number in varchar2 default null,
                      p_reg_date in date default null, p_message in varchar2 default null);

  -- Друк TAX_INVOICE, XML ЄРПН (спрощена J1201016), вивантаження файлу з APEX
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
  function erpn_xml (p_id in varchar2) return clob;
  procedure download_xml (p_id in varchar2);
  -- Зведення ПДВ і стан реєстрації за період (сторінка 630)
  function register_html (p_from in date, p_to in date, p_org in varchar2 default null) return clob;

  -- Тригери ПН
  procedure check_header (p_inserting in boolean, p_direction in varchar2, p_cp in varchar2, p_old_cp in varchar2,
                          p_kind in varchar2, p_corrected in varchar2);
  procedure check_line (p_product_id in varchar2, p_desc in out varchar2, p_uktzed in out varchar2, p_unit in out varchar2,
                        p_qty in number, p_price in number, p_rate in out varchar2, p_amount in out number, p_vat in out number,
                        p_check_ref in boolean, p_keep_amounts in boolean);
  procedure update_totals (p_id in varchar2);
end trade_tax;
/

-- ---------------------------------------------------------------- представлення (до тіла пакета)
-- Події для правила першої події: відвантаження (проведені реалізації, рядки зі ставкою ПДВ, з ПДВ) і оплати
-- покупця (рухи RECEIVABLE оплат від покупців, ПКО, виписок, повернення коштів покупцю — зі знаком «оплата +»)
create or replace view v_tax_event_src as
select s.organization_id, s.customer_id counterparty_id, s.contract_id, 'SHIPMENT' event_kind, 'DocGoodsSale' doc_type,
       s.id doc_id, s.occurred_at event_date, sum(g.amount_with_vat) amount
  from doc_goods_sale s join doc_goods_sale_goods g on g.document_id = s.id
 where s.status = 'POSTED' and nvl(g.vat_rate_code, 'NOVAT') <> 'NOVAT'
 group by s.organization_id, s.customer_id, s.contract_id, s.id, s.occurred_at
union all
select r.organization_id, r.counterparty_id, r.contract_id, 'PAYMENT', r.recorder_type, r.recorder_id, min(r.period), -sum(r.amount)
  from v_receivable_item r
 where r.recorder_type in ('DocCustomerPayment', 'DocCashReceipt', 'DocCashPayment', 'DocBankStatement')
 group by r.organization_id, r.counterparty_id, r.contract_id, r.recorder_type, r.recorder_id;

-- ---------------------------------------------------------------- тіло пакета
create or replace package body trade_tax as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return rtrim(to_char(p, 'FM999G999G990D999'), '.,'); end;
  function x (p varchar2) return varchar2 is begin return dbms_xmlgen.convert(p); end;
  function xn (p number) return varchar2 is begin return rtrim(rtrim(to_char(p, 'FM999999999990D000', 'NLS_NUMERIC_CHARACTERS=.,'), '0'), '.'); end;
  function xm (p number) return varchar2 is begin return to_char(p, 'FM999999999990D00', 'NLS_NUMERIC_CHARACTERS=.,'); end;

  function liability_increase (p_shipped in number, p_paid in number, p_ship in number, p_pay in number) return number is
  begin
    return greatest(greatest(nvl(p_shipped, 0) + nvl(p_ship, 0), nvl(p_paid, 0) + nvl(p_pay, 0))
                    - greatest(nvl(p_shipped, 0), nvl(p_paid, 0)), 0);
  end liability_increase;

  function invoiced_for (p_doc_id varchar2, p_cp varchar2, p_excl varchar2 default null) return number is
    l number;
  begin
    select coalesce(sum(total_amount), 0) into l from doc_tax_invoice
     where base_doc_id = p_doc_id and counterparty_id = p_cp
       and direction = 'ISSUED' and invoice_kind = 'PN' and (p_excl is null or id <> p_excl);
    return l;
  end invoiced_for;

  function events (p_from in date default null, p_to in date default null, p_org in varchar2 default null,
                   p_cp in varchar2 default null, p_doc_id in varchar2 default null) return ev_tab pipelined is
    r ev_row;
    l_s number; l_p number;
  begin
    for k in (select distinct v.organization_id, v.counterparty_id
                from v_tax_event_src v join ref_organization o on o.id = v.organization_id
               where o.vat_payer = 'Y'
                 and (p_org is null or v.organization_id = p_org)
                 and (p_cp is null or v.counterparty_id = p_cp)
                 and (p_doc_id is null or v.doc_id = p_doc_id)) loop
      l_s := 0; l_p := 0;
      for v in (select * from v_tax_event_src
                 where organization_id = k.organization_id and counterparty_id = k.counterparty_id
                 order by event_date, case event_kind when 'SHIPMENT' then 0 else 1 end, doc_id) loop
        r.base_amount := case v.event_kind when 'SHIPMENT' then liability_increase(l_s, l_p, v.amount, 0)
                                           else liability_increase(l_s, l_p, 0, v.amount) end;
        if v.event_kind = 'SHIPMENT' then l_s := l_s + v.amount; else l_p := l_p + v.amount; end if;
        if (p_from is null or v.event_date >= trunc(p_from)) and (p_to is null or v.event_date < trunc(p_to) + 1)
           and (p_doc_id is null or v.doc_id = p_doc_id) then
          r.organization_id := k.organization_id; r.counterparty_id := k.counterparty_id;
          r.contract_id := v.contract_id;
          r.event_kind := v.event_kind; r.doc_type := v.doc_type; r.doc_id := v.doc_id; r.event_date := v.event_date;
          r.event_amount := v.amount;
          r.invoiced_amount := invoiced_for(v.doc_id, k.counterparty_id);
          r.remaining_amount := greatest(r.base_amount - r.invoiced_amount, 0);
          pipe row (r);
        end if;
      end loop;
    end loop;
    return;
  end events;

  function erpn_deadline (p_date in date) return date is
  begin
    if p_date is null then return null; end if;
    return case when extract(day from p_date) <= 15 then last_day(trunc(p_date))
                else trunc(add_months(p_date, 1), 'MM') + 14 end;
  end erpn_deadline;

  function status_name (p_status in varchar2) return varchar2 is
  begin
    return case p_status when 'POSTED' then 'Проведено' else 'Чернетка' end;
  end status_name;

  function erpn_status_name (p_status in varchar2) return varchar2 is
  begin
    return case p_status when 'SENT' then 'Надіслано' when 'REGISTERED' then 'Зареєстровано' when 'REJECTED' then 'Відхилено'
                         else 'Не надіслано' end;
  end erpn_status_name;

  function doc_name (p_type varchar2, p_id varchar2) return varchar2 is
    l varchar2(400);
  begin
    select max(recorder_name) into l from v_recorder where recorder_type = p_type and recorder_id = p_id;
    return coalesce(l, p_type);
  end doc_name;

  -- ---------------------------------------------------------------- створення ПН
  function new_header (p_dir varchar2, p_org varchar2, p_cp varchar2, p_contract varchar2, p_event varchar2,
                       p_base_type varchar2, p_base_id varchar2, p_date date, p_comment varchar2) return varchar2 is
    l_id varchar2(32);
    l_reason varchar2(2);
  begin
    if p_dir = 'ISSUED' then
      select case when max(vat_payer) = 'Y' then null else '02' end into l_reason from ref_counterparty where id = p_cp;
    end if;
    insert into doc_tax_invoice (occurred_at, organization_id, direction, counterparty_id, contract_id, event_kind,
                                 base_doc_type, base_doc_id, not_issued_reason, doc_comment)
    values (p_date, p_org, p_dir, p_cp, p_contract, p_event, p_base_type, p_base_id, l_reason, p_comment)
    returning id into l_id;
    return l_id;
  end new_header;

  procedure add_line (p_id varchar2, p_line number, p_product varchar2, p_desc varchar2, p_qty number, p_price number,
                      p_amount number, p_rate varchar2, p_vat number) is
  begin
    insert into doc_tax_invoice_goods (document_id, line_number, product_id, description, quantity, price, amount, vat_rate_code, vat_amount)
    values (p_id, p_line, p_product, p_desc, p_qty, p_price, p_amount, p_rate, p_vat);
  end add_line;

  -- Рядки ПН з реалізації / надходження: повна сума — рядки документа; частина — по рядку на ставку пропорційно
  procedure fill_goods (p_id varchar2, p_lines_table varchar2, p_doc_id varchar2, p_part number, p_full number, p_title varchar2) is
    type t_cur is ref cursor;
    c t_cur;
    l_n number := 0;
    l_prd varchar2(32); l_qty number; l_total number; l_vat number; l_rate varchar2(10); l_name varchar2(255);
    l_left number := p_part; l_cnt number; l_i number := 0; l_part number; l_pv number;
  begin
    if p_part >= p_full then
      open c for 'select g.product_id, g.quantity, g.amount_with_vat, g.vat_amount, g.vat_rate_code from ' || p_lines_table
        || ' g where g.document_id = :d and nvl(g.vat_rate_code, ''NOVAT'') <> ''NOVAT'' order by g.line_number' using p_doc_id;
      loop
        fetch c into l_prd, l_qty, l_total, l_vat, l_rate;
        exit when c%notfound;
        l_n := l_n + 1;
        add_line(p_id, l_n, l_prd, null, l_qty, round((l_total - l_vat) / l_qty, 2), l_total - l_vat, l_rate, l_vat);
      end loop;
      close c;
    else
      execute immediate 'select count(distinct vat_rate_code) from ' || p_lines_table
        || ' where document_id = :d and nvl(vat_rate_code, ''NOVAT'') <> ''NOVAT''' into l_cnt using p_doc_id;
      open c for 'select g.vat_rate_code, sum(g.amount_with_vat) from ' || p_lines_table
        || ' g where g.document_id = :d and nvl(g.vat_rate_code, ''NOVAT'') <> ''NOVAT'' group by g.vat_rate_code order by 1 desc'
        using p_doc_id;
      loop
        fetch c into l_rate, l_total;
        exit when c%notfound;
        l_i := l_i + 1;
        l_part := case when l_i = l_cnt then l_left else round(l_total * p_part / p_full, 2) end;
        l_left := l_left - l_part;
        l_pv := trade_vat.vat_of(l_part, l_rate, 'Y');
        add_line(p_id, l_i, null, p_title || ' (частина, не покрита попередньою оплатою)', 1, l_part - l_pv, l_part - l_pv, l_rate, l_pv);
      end loop;
      close c;
    end if;
  end fill_goods;

  function create_for_event (r ev_row) return varchar2 is
    l_id varchar2(32);
    l_title varchar2(400) := doc_name(r.doc_type, r.doc_id);
    l_vat number;
  begin
    l_id := new_header('ISSUED', r.organization_id, r.counterparty_id, r.contract_id,
                       case r.event_kind when 'SHIPMENT' then 'SHIPMENT' else 'PREPAYMENT' end,
                       r.doc_type, r.doc_id, r.event_date, null);
    trade_core.g_internal := true;
    if r.event_kind = 'SHIPMENT' then
      fill_goods(l_id, 'doc_goods_sale_goods', r.doc_id, r.remaining_amount, r.event_amount, 'Товари за документом ' || l_title);
    else
      l_vat := trade_vat.vat_of(r.remaining_amount, 'VAT20', 'Y');
      add_line(l_id, 1, null, 'Попередня оплата за товари (' || l_title || ')', 1, r.remaining_amount - l_vat,
               r.remaining_amount - l_vat, 'VAT20', l_vat);
    end if;
    trade_core.g_internal := false;
    -- ПН на відвантаження без ставки 0 % експорт — тип причини 07 лише коли всі рядки 0 %
    update doc_tax_invoice d set d.not_issued_reason = '07'
     where d.id = l_id and d.not_issued_reason is null
       and not exists (select 1 from doc_tax_invoice_goods g where g.document_id = d.id and g.vat_rate_code <> 'VAT0');
    trade_core.audit(c_type, l_id, 'CREATE_BASED_ON', r.doc_type || ' ' || r.doc_id);
    return l_id;
  exception when others then
    trade_core.g_internal := false;
    raise;
  end create_for_event;

  procedure check_org (p_org varchar2) is
    l varchar2(1);
  begin
    select max(vat_payer) into l from ref_organization where id = p_org;
    if nvl(l, 'N') <> 'Y' then
      fail('TAX_ORG_NOT_VAT_PAYER', 'Організація не є платником ПДВ — податкові накладні не оформлюються.');
    end if;
  end check_org;

  function create_received (p_id varchar2) return varchar2 is
    l_id varchar2(32);
    l_n number;
  begin
    for d in (select r.*, c.vat_payer cp_payer from doc_goods_receipt r join ref_counterparty c on c.id = r.supplier_id
               where r.id = p_id) loop
      if d.status <> 'POSTED' then
        fail('TAX_BASE_NOT_POSTED', 'Документ-підставу не проведено.');
      end if;
      check_org(d.organization_id);
      if d.cp_payer <> 'Y' then
        fail('TAX_SUPPLIER_NOT_VAT_PAYER', 'Постачальник не є платником ПДВ — податкової накладної не буде.');
      end if;
      select count(*) into l_n from doc_tax_invoice where base_doc_id = p_id and direction = 'RECEIVED';
      if l_n > 0 then
        fail('TAX_INVOICE_EXISTS', 'Отриману податкову накладну за цим надходженням уже зареєстровано.');
      end if;
      select count(*) into l_n from doc_goods_receipt_goods where document_id = p_id and nvl(vat_rate_code, 'NOVAT') <> 'NOVAT';
      if l_n = 0 then
        fail('TAX_NO_VAT_LINES', 'У надходженні немає рядків зі ставкою ПДВ.');
      end if;
      l_id := new_header('RECEIVED', d.organization_id, d.supplier_id, d.contract_id, 'SHIPMENT', 'DocGoodsReceipt', p_id,
                         d.occurred_at, null);
      trade_core.g_internal := true;
      fill_goods(l_id, 'doc_goods_receipt_goods', p_id, d.total_amount, d.total_amount, null);
      trade_core.g_internal := false;
      trade_core.audit(c_type, l_id, 'CREATE_BASED_ON', 'DocGoodsReceipt ' || p_id);
    end loop;
    if l_id is null then
      fail('TAX_BASE_NOT_FOUND', 'Документ-підставу не знайдено.');
    end if;
    return l_id;
  exception when others then
    trade_core.g_internal := false;
    raise;
  end create_received;

  function base_status (p_type varchar2, p_id varchar2) return varchar2 is
    l varchar2(10);
  begin
    case p_type
      when 'DocGoodsSale'       then select max(status) into l from doc_goods_sale where id = p_id;
      when 'DocCustomerPayment' then select max(status) into l from doc_customer_payment where id = p_id;
      when 'DocCashReceipt'     then select max(status) into l from doc_cash_receipt where id = p_id;
      when 'DocCashPayment'     then select max(status) into l from doc_cash_payment where id = p_id;
      when 'DocBankStatement'   then select max(status) into l from doc_bank_statement where id = p_id;
      when 'DocGoodsReceipt'    then select max(status) into l from doc_goods_receipt where id = p_id;
      else l := null;
    end case;
    return l;
  end base_status;

  function base_org (p_type varchar2, p_id varchar2) return varchar2 is
    l varchar2(32);
  begin
    case p_type
      when 'DocGoodsSale'       then select max(organization_id) into l from doc_goods_sale where id = p_id;
      when 'DocCustomerPayment' then select max(organization_id) into l from doc_customer_payment where id = p_id;
      when 'DocCashReceipt'     then select max(organization_id) into l from doc_cash_receipt where id = p_id;
      when 'DocBankStatement'   then select max(organization_id) into l from doc_bank_statement where id = p_id;
      else l := null;
    end case;
    return l;
  end base_org;

  function create_from_base (p_type in varchar2, p_id in varchar2) return varchar2 is
    l_any boolean := false;
  begin
    if p_type = 'DocGoodsReceipt' then
      return create_received(p_id);
    end if;
    if p_type not in ('DocGoodsSale', 'DocCustomerPayment', 'DocCashReceipt', 'DocBankStatement') then
      fail('TAX_BASE_TYPE', 'Податкову накладну створюють на підставі реалізації, оплати від покупця, ПКО чи виписки.');
    end if;
    if nvl(base_status(p_type, p_id), '-') <> 'POSTED' then
      fail('TAX_BASE_NOT_POSTED', 'Документ-підставу не проведено.');
    end if;
    check_org(base_org(p_type, p_id));
    for r in (select * from table(events(p_doc_id => p_id)) order by remaining_amount desc) loop
      if r.base_amount > 0 then
        l_any := true;
      end if;
      if r.remaining_amount > 0 then
        return create_for_event(r);
      end if;
    end loop;
    if l_any then
      fail('TAX_INVOICE_EXISTS', 'Податкову накладну за цією подією вже оформлено на всю суму.');
    end if;
    fail('TAX_NO_LIABILITY', 'Податкове зобов''язання за документом не виникає: першою подією була '
         || case p_type when 'DocGoodsSale' then 'попередня оплата' else 'відвантаження' end
         || ' — податкову накладну оформлено (або слід оформити) на неї.');
  end create_from_base;

  function generate (p_from in date, p_to in date, p_org in varchar2 default null, p_post in varchar2 default 'Y') return number is
    l_n number := 0;
    l_id varchar2(32);
  begin
    for r in (select * from table(events(p_from, p_to, p_org)) where remaining_amount > 0 order by event_date, doc_id) loop
      l_id := create_for_event(r);
      if p_post = 'Y' then
        post(l_id);
      end if;
      l_n := l_n + 1;
    end loop;
    return l_n;
  end generate;

  -- ---------------------------------------------------------------- тригери
  procedure check_header (p_inserting in boolean, p_direction in varchar2, p_cp in varchar2, p_old_cp in varchar2,
                          p_kind in varchar2, p_corrected in varchar2) is
  begin
    if p_inserting or p_cp <> p_old_cp then
      trade_core.check_active_ref('REF_COUNTERPARTY', p_cp, 'Контрагент');
    end if;
    if p_kind = 'RK' or p_corrected is not null then
      fail('TAX_CORRECTION_NOT_SUPPORTED', 'Розрахунки коригування — окремий етап (APE-302).');
    end if;
  end check_header;

  procedure check_line (p_product_id in varchar2, p_desc in out varchar2, p_uktzed in out varchar2, p_unit in out varchar2,
                        p_qty in number, p_price in number, p_rate in out varchar2, p_amount in out number, p_vat in out number,
                        p_check_ref in boolean, p_keep_amounts in boolean) is
  begin
    if p_check_ref and p_product_id is not null then
      trade_core.check_active_ref('REF_PRODUCT', p_product_id, 'Товар');
    end if;
    if p_qty is null or p_qty <= 0 then
      fail('TAX_LINE_QTY', 'Кількість має бути більшою за нуль.');
    end if;
    if p_price is null or p_price < 0 then
      fail('TAX_LINE_PRICE', 'Ціна без ПДВ не може бути від''ємною.');
    end if;
    for p in (select p.name, p.uktzed_code, p.vat_rate_code, u.short_name
                from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = p_product_id) loop
      p_desc := coalesce(trim(p_desc), p.name);
      p_uktzed := coalesce(trim(p_uktzed), p.uktzed_code);
      p_unit := coalesce(trim(p_unit), p.short_name);
      p_rate := coalesce(p_rate, p.vat_rate_code);
    end loop;
    p_desc := trim(p_desc);
    if p_desc is null then
      fail('TAX_LINE_DESCRIPTION', 'Вкажіть товар або опис постачання.');
    end if;
    p_unit := coalesce(trim(p_unit), 'шт');
    p_rate := coalesce(p_rate, 'VAT20');
    if p_rate = 'NOVAT' then
      fail('TAX_LINE_NOVAT', 'Постачання без ПДВ (не об''єкт) до податкової накладної не включається.');
    end if;
    if not p_keep_amounts or p_amount is null then
      p_amount := round(p_qty * p_price, 2);
      p_vat := round(p_amount * trade_vat.rate_pct(p_rate) / 100, 2);
    end if;
  end check_line;

  procedure update_totals (p_id in varchar2) is
  begin
    update doc_tax_invoice d
       set (d.amount_without_vat, d.vat_amount) =
           (select coalesce(sum(amount), 0), coalesce(sum(vat_amount), 0) from doc_tax_invoice_goods where document_id = d.id),
           d.total_amount = (select coalesce(sum(amount + vat_amount), 0) from doc_tax_invoice_goods where document_id = d.id)
     where d.id = p_id;
  end update_totals;

  -- ---------------------------------------------------------------- проведення
  procedure post (p_id in varchar2) is
    l_n number; l_base number; l_inv number; l_cnt number;
    l_prev boolean := trade_core.g_internal;
  begin
    for d in (select t.*, o.vat_number org_ipn, c.vat_payer cp_payer, c.vat_number cp_ipn
                from doc_tax_invoice t join ref_organization o on o.id = t.organization_id
                join ref_counterparty c on c.id = t.counterparty_id
               where t.id = p_id for update of t.status) loop
      if d.status = 'POSTED' then
        fail('DOCUMENT_POSTED', 'Податкову накладну вже проведено.');
      end if;
      check_org(d.organization_id);
      select count(*), count(case when amount + vat_amount <= 0 then 1 end) into l_n, l_cnt
        from doc_tax_invoice_goods where document_id = p_id;
      if l_n = 0 then
        fail('TAX_INVOICE_EMPTY', 'Заповніть рядки податкової накладної.');
      end if;
      if l_cnt > 0 or d.total_amount <= 0 then
        fail('TAX_INVOICE_AMOUNT', 'Обсяг постачання рядків має бути більшим за нуль.');
      end if;
      if d.direction = 'ISSUED' and d.base_doc_id is not null then
        if nvl(base_status(d.base_doc_type, d.base_doc_id), '-') <> 'POSTED' then
          fail('TAX_BASE_NOT_POSTED', 'Документ-підставу не проведено.');
        end if;
        select coalesce(sum(base_amount), 0) into l_base
          from table(events(p_doc_id => d.base_doc_id))
         where counterparty_id = d.counterparty_id;
        l_inv := invoiced_for(d.base_doc_id, d.counterparty_id, p_id);
        if l_inv + d.total_amount > l_base + 0.01 then
          fail('TAX_INVOICE_EXCEEDS_BASE', 'Сума ПН (' || m(d.total_amount) || ') перевищує неоформлене податкове зобов''язання '
               || 'за першою подією (' || m(greatest(l_base - l_inv, 0)) || ').');
        end if;
      end if;
      if d.direction = 'RECEIVED' then
        if d.ext_number is null then
          fail('TAX_EXT_NUMBER', 'Вкажіть номер податкової накладної постачальника.');
        end if;
        if d.cp_payer <> 'Y' or d.cp_ipn is null then
          fail('TAX_COUNTERPARTY_IPN', 'Постачальник має бути платником ПДВ з ІПН (картка контрагента).');
        end if;
      end if;
      trade_core.g_internal := true;
      update doc_tax_invoice
         set status = 'POSTED',
             seller_vat_number = case d.direction when 'ISSUED' then d.org_ipn else d.cp_ipn end,
             buyer_vat_number  = case d.direction when 'ISSUED' then case when d.cp_payer = 'Y' then d.cp_ipn else c_non_payer_ipn end
                                                 else d.org_ipn end
       where id = p_id;
      delete from reg_vat_mv where recorder_type = c_type and recorder_id = p_id;
      insert into reg_vat_mv (period, recorder_type, recorder_id, line_number, organization_id, counterparty_id, direction,
                              vat_rate_code, base_amount, vat_amount)
      select d.occurred_at, c_type, p_id, row_number() over (order by r.sort_order), d.organization_id, d.counterparty_id,
             case d.direction when 'ISSUED' then 'LIABILITY' else 'CREDIT' end, g.vat_rate_code, sum(g.amount), sum(g.vat_amount)
        from doc_tax_invoice_goods g join ref_vat_rate r on r.code = g.vat_rate_code
       where g.document_id = p_id
       group by g.vat_rate_code, r.sort_order;
      trade_core.g_internal := l_prev;
      trade_core.audit(c_type, p_id, 'POST', 'Сума ' || d.total_amount || ', ПДВ ' || d.vat_amount);
      return;
    end loop;
    fail('DOCUMENT_NOT_FOUND', 'Податкову накладну не знайдено.');
  exception when others then
    trade_core.g_internal := l_prev;
    raise;
  end post;

  procedure unpost (p_id in varchar2) is
    l_prev boolean := trade_core.g_internal;
  begin
    for d in (select * from doc_tax_invoice where id = p_id for update) loop
      if d.status <> 'POSTED' then
        fail('DOCUMENT_NOT_POSTED', 'Податкову накладну не проведено.');
      end if;
      if d.erpn_status in ('SENT', 'REGISTERED') then
        fail('TAX_INVOICE_IN_ERPN', 'Податкову накладну надіслано / зареєстровано в ЄРПН — скасувати не можна, '
             || 'зміни оформлюються розрахунком коригування.');
      end if;
      trade_core.g_internal := true;
      delete from reg_vat_mv where recorder_type = c_type and recorder_id = p_id;
      update doc_tax_invoice set status = 'DRAFT', seller_vat_number = null, buyer_vat_number = null where id = p_id;
      trade_core.g_internal := l_prev;
      trade_core.audit(c_type, p_id, 'UNPOST');
    end loop;
  exception when others then
    trade_core.g_internal := l_prev;
    raise;
  end unpost;

  function copy (p_id in varchar2) return varchar2 is
    l_id varchar2(32);
  begin
    for d in (select * from doc_tax_invoice where id = p_id) loop
      insert into doc_tax_invoice (organization_id, direction, counterparty_id, contract_id, event_kind, base_doc_type, base_doc_id,
                                   not_issued_reason, doc_comment)
      values (d.organization_id, d.direction, d.counterparty_id, d.contract_id, 'MANUAL', null, null, d.not_issued_reason, d.doc_comment)
      returning id into l_id;
      insert into doc_tax_invoice_goods (document_id, line_number, product_id, description, uktzed_code, unit_name, quantity, price,
                                         vat_rate_code)
      select l_id, line_number, product_id, description, uktzed_code, unit_name, quantity, price, vat_rate_code
        from doc_tax_invoice_goods where document_id = p_id order by line_number;
      trade_core.audit(c_type, l_id, 'COPY', 'з ' || d.doc_number);
    end loop;
    return l_id;
  end copy;

  procedure set_erpn (p_id in varchar2, p_status in varchar2, p_reg_number in varchar2 default null,
                      p_reg_date in date default null, p_message in varchar2 default null) is
    l_prev boolean := trade_core.g_internal;
  begin
    for d in (select * from doc_tax_invoice where id = p_id for update) loop
      if d.status <> 'POSTED' then
        fail('TAX_ERPN_NOT_POSTED', 'Стан ЄРПН змінюється лише для проведеної податкової накладної.');
      end if;
      if p_status not in ('NOT_SENT', 'SENT', 'REGISTERED', 'REJECTED') then
        fail('TAX_ERPN_STATUS', 'Невідомий стан ЄРПН: ' || p_status);
      end if;
      if p_status = 'REGISTERED' and trim(p_reg_number) is null then
        fail('TAX_ERPN_NUMBER', 'Вкажіть реєстраційний номер ЄРПН.');
      end if;
      if d.erpn_status = 'REGISTERED' and p_status <> 'REGISTERED' then
        fail('TAX_ERPN_REGISTERED', 'Податкову накладну вже зареєстровано в ЄРПН.');
      end if;
      trade_core.g_internal := true;
      update doc_tax_invoice
         set erpn_status = p_status,
             erpn_reg_number = case when p_status = 'REGISTERED' then trim(p_reg_number) end,
             erpn_reg_date = case when p_status = 'REGISTERED' then coalesce(p_reg_date, trunc(sysdate)) end,
             erpn_message = p_message
       where id = p_id;
      trade_core.g_internal := l_prev;
      trade_core.audit(c_type, p_id, 'ERPN', erpn_status_name(p_status) || case when p_reg_number is not null then ' № ' || p_reg_number end);
    end loop;
  exception when others then
    trade_core.g_internal := l_prev;
    raise;
  end set_erpn;

  -- ---------------------------------------------------------------- друк і XML
  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    l_b20 number := 0; l_b7 number := 0; l_b0 number := 0; l_bex number := 0; l_v20 number := 0; l_v7 number := 0;
  begin
    for d in (select t.*, o.name org_name, o.full_name org_full, o.vat_number org_ipn, o.edrpou org_edrpou, o.address org_address,
                     o.director_name, c.name cp_name, c.vat_number cp_ipn, c.vat_payer cp_payer, c.edrpou cp_edrpou,
                     k.name contract_name, k.contract_number, k.contract_date
                from doc_tax_invoice t join ref_organization o on o.id = t.organization_id
                join ref_counterparty c on c.id = t.counterparty_id left join ref_contract k on k.id = t.contract_id
               where t.id = p_id) loop
      for g in (select vat_rate_code, sum(amount) a, sum(vat_amount) v from doc_tax_invoice_goods where document_id = p_id group by vat_rate_code) loop
        case g.vat_rate_code
          when 'VAT20' then l_b20 := g.a; l_v20 := g.v;
          when 'VAT7' then l_b7 := g.a; l_v7 := g.v;
          when 'VAT0' then l_b0 := g.a;
          when 'EXEMPT' then l_bex := g.a;
          else null;
        end case;
      end loop;
      l := '<div class="tx-print"><style>.tx-print{font-family:Arial,sans-serif;font-size:12px;color:#000;max-width:900px;background:#fff;padding:16px;position:relative}'
        || '.tx-print h2{font-size:17px;text-align:center;margin:10px 0}.tx-print table{border-collapse:collapse;width:100%}'
        || '.tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 5px;vertical-align:top}.tx-print .grid th{background:#f2f2f2}'
        || '.tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}.tx-print .req td{padding:2px 6px;vertical-align:top}'
        || '.tx-print .wm{position:absolute;top:240px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}'
        || '@media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}}</style>'
        || case when d.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<h2>' || case d.direction when 'RECEIVED' then 'Податкова накладна (отримана) № ' || e(d.ext_number)
                                     else 'ПОДАТКОВА НАКЛАДНА № ' || e(ltrim(d.doc_number, '0')) end
        || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY') || '</h2>'
        || case when d.not_issued_reason is not null then '<p>Не підлягає наданню отримувачу (покупцю) з причини: тип причини '
                || e(d.not_issued_reason) || case d.not_issued_reason when '02' then ' — складена на постачання неплатнику податку'
                                                                      when '07' then ' — складена на вивезені за межі митної території товари' end || '</p>' end
        || '<table class="req"><tr><td style="width:50%"><b>Продавець (постачальник):</b><br>'
        || e(case d.direction when 'ISSUED' then coalesce(d.org_full, d.org_name) else d.cp_name end)
        || '<br>ІПН: ' || e(case d.direction when 'ISSUED' then coalesce(d.seller_vat_number, d.org_ipn) else coalesce(d.seller_vat_number, d.cp_ipn) end)
        || '</td><td><b>Покупець (отримувач):</b><br>'
        || e(case d.direction when 'ISSUED' then d.cp_name else coalesce(d.org_full, d.org_name) end)
        || '<br>ІПН: ' || e(case d.direction when 'ISSUED' then coalesce(d.buyer_vat_number, case when d.cp_payer = 'Y' then d.cp_ipn else c_non_payer_ipn end)
                                              else coalesce(d.buyer_vat_number, d.org_ipn) end)
        || '</td></tr></table>'
        || case when d.contract_name is not null then '<p>Договір: ' || e(d.contract_name) || case when d.contract_number is not null
                then ' № ' || e(d.contract_number) end || case when d.contract_date is not null then ' від ' || to_char(d.contract_date, 'DD.MM.YYYY') end || '</p>' end
        || case when d.base_doc_id is not null then '<p>Підстава: ' || e(doc_name(d.base_doc_type, d.base_doc_id))
                || ' (' || case d.event_kind when 'PREPAYMENT' then 'перша подія — оплата' else 'перша подія — відвантаження' end || ')</p>' end
        || '<table class="grid"><tr><th>№</th><th>Опис (номенклатура) товарів / послуг</th><th>Код УКТ ЗЕД / ДКПП</th><th>Од.</th>'
        || '<th>Кількість</th><th>Ціна без ПДВ</th><th>Код ставки</th><th>Обсяг постачання без ПДВ</th><th>Сума ПДВ</th></tr>';
      for g in (select g.*, r.erpn_code from doc_tax_invoice_goods g join ref_vat_rate r on r.code = g.vat_rate_code
                 where g.document_id = p_id order by g.line_number) loop
        l := l || '<tr><td class="c">' || g.line_number || '</td><td>' || e(g.description) || '</td><td class="c">' || e(g.uktzed_code)
          || '</td><td class="c">' || e(g.unit_name) || '</td><td class="r">' || q(g.quantity) || '</td><td class="r">' || m(g.price)
          || '</td><td class="c">' || e(g.erpn_code) || '</td><td class="r">' || m(g.amount) || '</td><td class="r">' || m(g.vat_amount) || '</td></tr>';
      end loop;
      l := l || '</table><table class="grid" style="margin-top:8px;width:60%;margin-left:40%">'
        || '<tr><td>Загальна сума коштів з ПДВ</td><td class="r"><b>' || m(d.total_amount) || '</b></td></tr>'
        || '<tr><td>Обсяг за основною ставкою 20 %</td><td class="r">' || m(l_b20) || '</td></tr>'
        || '<tr><td>Обсяг за ставкою 7 %</td><td class="r">' || m(l_b7) || '</td></tr>'
        || '<tr><td>Обсяг за ставкою 0 %</td><td class="r">' || m(l_b0) || '</td></tr>'
        || '<tr><td>Обсяг звільнених від ПДВ операцій</td><td class="r">' || m(l_bex) || '</td></tr>'
        || '<tr><td>ПДВ за ставкою 20 %</td><td class="r">' || m(l_v20) || '</td></tr>'
        || '<tr><td>ПДВ за ставкою 7 %</td><td class="r">' || m(l_v7) || '</td></tr>'
        || '<tr><td><b>Загальна сума ПДВ</b></td><td class="r"><b>' || m(d.vat_amount) || '</b></td></tr></table>'
        || '<p>Стан у ЄРПН: <b>' || e(erpn_status_name(d.erpn_status)) || '</b>'
        || case when d.erpn_reg_number is not null then ', реєстраційний № ' || e(d.erpn_reg_number) || ' від ' || to_char(d.erpn_reg_date, 'DD.MM.YYYY') end
        || case when d.direction = 'ISSUED' then '. Зареєструвати до ' || to_char(erpn_deadline(d.occurred_at), 'DD.MM.YYYY') end || '.</p>'
        || '<div style="margin-top:30px">Складено (підписано КЕП): ____________________ ' || e(d.director_name) || '</div></div>';
    end loop;
    return l;
  end print_html;

  function erpn_xml (p_id in varchar2) return clob is
    l clob;
    l_b20 number := 0; l_b7 number := 0; l_b0 number := 0; l_bex number := 0; l_v20 number := 0; l_v7 number := 0;
    function tag (p_name varchar2, p_val varchar2, p_row number default null) return varchar2 is
    begin
      return '<' || p_name || case when p_row is not null then ' ROWNUM="' || p_row || '"' end
        || case when p_val is null then ' xsi:nil="true"/>' else '>' || x(p_val) || '</' || p_name || '>' end || chr(10);
    end;
  begin
    for d in (select t.*, o.name org_name, o.full_name org_full, o.vat_number org_ipn, o.edrpou org_edrpou, o.director_name,
                     c.name cp_name, c.vat_number cp_ipn, c.vat_payer cp_payer, c.edrpou cp_edrpou
                from doc_tax_invoice t join ref_organization o on o.id = t.organization_id
                join ref_counterparty c on c.id = t.counterparty_id where t.id = p_id) loop
      if d.direction <> 'ISSUED' then
        fail('TAX_XML_ISSUED_ONLY', 'XML для ЄРПН формується лише для виданих податкових накладних.');
      end if;
      if d.status <> 'POSTED' then
        fail('TAX_XML_NOT_POSTED', 'Проведіть податкову накладну перед вивантаженням XML.');
      end if;
      for g in (select vat_rate_code, sum(amount) a, sum(vat_amount) v from doc_tax_invoice_goods where document_id = p_id group by vat_rate_code) loop
        case g.vat_rate_code
          when 'VAT20' then l_b20 := g.a; l_v20 := g.v;
          when 'VAT7' then l_b7 := g.a; l_v7 := g.v;
          when 'VAT0' then l_b0 := g.a;
          when 'EXEMPT' then l_bex := g.a;
          else null;
        end case;
      end loop;
      l := '<?xml version="1.0" encoding="UTF-8"?>' || chr(10)
        || '<!-- Trade: податкова накладна, спрощена структура J1201016 (без КЕП; відправлення — M.E.Doc / Вчасно, APE-306) -->' || chr(10)
        || '<DECLAR xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="J1201016.xsd">' || chr(10)
        || '<DECLARHEAD>' || chr(10)
        || tag('TIN', d.org_edrpou) || tag('C_DOC', 'J12') || tag('C_DOC_SUB', '010') || tag('C_DOC_VER', '16')
        || tag('C_DOC_TYPE', '0') || tag('C_DOC_CNT', ltrim(d.doc_number, '0'))
        || tag('PERIOD_MONTH', to_char(d.occurred_at, 'FMMM')) || tag('PERIOD_TYPE', '1') || tag('PERIOD_YEAR', to_char(d.occurred_at, 'YYYY'))
        || tag('C_DOC_STAN', '1') || tag('D_FILL', to_char(d.occurred_at, 'DDMMYYYY')) || tag('SOFTWARE', 'Trade (Oracle APEX)')
        || '</DECLARHEAD>' || chr(10) || '<DECLARBODY>' || chr(10)
        || tag('HORIG1', case when d.not_issued_reason is not null then '1' end)
        || tag('HTYPR', d.not_issued_reason)
        || tag('HFILL', to_char(d.occurred_at, 'DDMMYYYY')) || tag('HNUM', ltrim(d.doc_number, '0'))
        || tag('HNAMESEL', coalesce(d.org_full, d.org_name)) || tag('HKSEL', coalesce(d.seller_vat_number, d.org_ipn)) || tag('HTINSEL', d.org_edrpou)
        || tag('HNAMEBUY', d.cp_name) || tag('HKBUY', coalesce(d.buyer_vat_number, case when d.cp_payer = 'Y' then d.cp_ipn else c_non_payer_ipn end))
        || tag('HTINBUY', case when d.cp_payer = 'Y' then d.cp_edrpou end)
        || tag('R04G11', xm(d.total_amount)) || tag('R03G11', xm(d.vat_amount)) || tag('R03G7', xm(l_v20)) || tag('R03G109', xm(l_v7))
        || tag('R01G7', xm(l_b20)) || tag('R01G109', xm(l_b7)) || tag('R01G9', xm(l_b0)) || tag('R01G10', xm(l_bex));
      for g in (select g.*, r.erpn_code from doc_tax_invoice_goods g join ref_vat_rate r on r.code = g.vat_rate_code
                 where g.document_id = p_id order by g.line_number) loop
        l := l || tag('RXXXXG3S', g.description, g.line_number) || tag('RXXXXG4', g.uktzed_code, g.line_number)
          || tag('RXXXXG4S', g.unit_name, g.line_number) || tag('RXXXXG5', xn(g.quantity), g.line_number)
          || tag('RXXXXG6', xm(g.price), g.line_number) || tag('RXXXXG008', g.erpn_code, g.line_number)
          || tag('RXXXXG010', xm(g.amount), g.line_number) || tag('RXXXXG11_10', xm(g.vat_amount), g.line_number);
      end loop;
      l := l || tag('HBOS', d.director_name) || '</DECLARBODY>' || chr(10) || '</DECLAR>' || chr(10);
    end loop;
    if l is null then
      fail('DOCUMENT_NOT_FOUND', 'Податкову накладну не знайдено.');
    end if;
    return l;
  end erpn_xml;

  procedure download_xml (p_id in varchar2) is
    l clob := erpn_xml(p_id);
    l_num varchar2(9);
    l_pos number := 1;
  begin
    select doc_number into l_num from doc_tax_invoice where id = p_id;
    trade_core.audit(c_type, p_id, 'PRINT', 'XML_ERPN');
    sys.htp.init;
    sys.owa_util.mime_header('application/xml', false, 'UTF-8');
    sys.htp.p('Content-Disposition: attachment; filename="PN_' || l_num || '.xml"');
    sys.owa_util.http_header_close;
    while l_pos <= dbms_lob.getlength(l) loop
      sys.htp.prn(dbms_lob.substr(l, 8000, l_pos));
      l_pos := l_pos + 8000;
    end loop;
    apex_application.stop_apex_engine;
  end download_xml;

  function register_html (p_from in date, p_to in date, p_org in varchar2 default null) return clob is
    l clob;
    l_lb number := 0; l_lv number := 0; l_cb number := 0; l_cv number := 0;
    l_n number; l_reg number; l_unreg number; l_over number; l_draft number; l_open number; l_open_amt number;
    l_to date := trunc(p_to) + 1;
  begin
    l := '<table class="t-Report-report" style="width:auto"><tr><th class="t-Report-colHead">Ставка</th>'
      || '<th class="t-Report-colHead">Зобов''язання: база</th><th class="t-Report-colHead">Зобов''язання: ПДВ</th>'
      || '<th class="t-Report-colHead">Кредит: база</th><th class="t-Report-colHead">Кредит: ПДВ</th></tr>';
    for r in (select v.name, v.sort_order,
                     coalesce(sum(case when m.direction = 'LIABILITY' then m.base_amount end), 0) lb,
                     coalesce(sum(case when m.direction = 'LIABILITY' then m.vat_amount end), 0) lv,
                     coalesce(sum(case when m.direction = 'CREDIT' then m.base_amount end), 0) cb,
                     coalesce(sum(case when m.direction = 'CREDIT' then m.vat_amount end), 0) cv
                from reg_vat_mv m join ref_vat_rate v on v.code = m.vat_rate_code
               where m.period >= trunc(p_from) and m.period < l_to and (p_org is null or m.organization_id = p_org)
               group by v.name, v.sort_order order by v.sort_order) loop
      l := l || '<tr><td class="t-Report-cell">' || e(r.name) || '</td><td class="t-Report-cell" style="text-align:right">' || m(r.lb)
        || '</td><td class="t-Report-cell" style="text-align:right">' || m(r.lv) || '</td><td class="t-Report-cell" style="text-align:right">'
        || m(r.cb) || '</td><td class="t-Report-cell" style="text-align:right">' || m(r.cv) || '</td></tr>';
      l_lb := l_lb + r.lb; l_lv := l_lv + r.lv; l_cb := l_cb + r.cb; l_cv := l_cv + r.cv;
    end loop;
    l := l || '<tr><td class="t-Report-cell"><b>Разом</b></td><td class="t-Report-cell" style="text-align:right"><b>' || m(l_lb)
      || '</b></td><td class="t-Report-cell" style="text-align:right"><b>' || m(l_lv) || '</b></td><td class="t-Report-cell" style="text-align:right"><b>'
      || m(l_cb) || '</b></td><td class="t-Report-cell" style="text-align:right"><b>' || m(l_cv) || '</b></td></tr></table>';
    l := l || '<p style="margin-top:8px"><b>' || case when l_lv - l_cv >= 0 then 'ПДВ до сплати: ' || m(l_lv - l_cv)
                                                     else 'ПДВ до відшкодування (від''ємне значення): ' || m(l_cv - l_lv) end || ' грн</b></p>';
    select count(case when status = 'POSTED' then 1 end),
           count(case when status = 'POSTED' and erpn_status = 'REGISTERED' then 1 end),
           count(case when status = 'POSTED' and erpn_status <> 'REGISTERED' then 1 end),
           count(case when status = 'POSTED' and erpn_status <> 'REGISTERED' and trunc(sysdate) > erpn_deadline(occurred_at) then 1 end),
           count(case when status = 'DRAFT' then 1 end)
      into l_n, l_reg, l_unreg, l_over, l_draft
      from doc_tax_invoice
     where direction = 'ISSUED' and occurred_at >= trunc(p_from) and occurred_at < l_to and (p_org is null or organization_id = p_org);
    select count(*), coalesce(sum(remaining_amount), 0) into l_open, l_open_amt
      from table(events(p_from, p_to, p_org)) where remaining_amount > 0;
    l := l || '<p>Видані ПН: проведено ' || l_n || ', зареєстровано в ЄРПН ' || l_reg || ', не зареєстровано ' || l_unreg
      || case when l_over > 0 then ' (<span style="color:#c00"><b>прострочено ' || l_over || '</b></span>)' end
      || ', чернеток ' || l_draft || '.<br>Події без податкової накладної (перша подія): ' || l_open
      || case when l_open > 0 then ' на суму <b>' || m(l_open_amt) || '</b> грн — кнопка «Створити ПН за першою подією»' end || '.</p>';
    return l;
  end register_html;

end trade_tax;
/

-- ---------------------------------------------------------------- тригери ПН і регістру
create or replace trigger doc_tax_invoice_biud
before insert or update or delete on doc_tax_invoice for each row
-- r5 F-TAX-01 (db/42)
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
    return;
  end if;
  if inserting then
    :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_TAX_INVOICE_NUM_SEQ'));
    :new.status := 'DRAFT'; :new.version := 0;
    :new.erpn_status := 'NOT_SENT'; :new.erpn_reg_number := null; :new.erpn_reg_date := null;
    :new.seller_vat_number := null; :new.buyer_vat_number := null;
    :new.amount_without_vat := 0; :new.vat_amount := 0; :new.total_amount := 0;
    :new.direction := coalesce(:new.direction, 'ISSUED');
    :new.invoice_kind := coalesce(:new.invoice_kind, 'PN');
    :new.event_kind := coalesce(:new.event_kind, 'MANUAL');
    :new.occurred_at := coalesce(:new.occurred_at, sysdate);
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    if not trade_core.g_internal then
      if :old.status = 'POSTED' then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
      end if;
      :new.status := :old.status;
      :new.erpn_status := :old.erpn_status; :new.erpn_reg_number := :old.erpn_reg_number; :new.erpn_reg_date := :old.erpn_reg_date;
      :new.amount_without_vat := :old.amount_without_vat; :new.vat_amount := :old.vat_amount; :new.total_amount := :old.total_amount;
      :new.base_doc_type := :old.base_doc_type; :new.base_doc_id := :old.base_doc_id; :new.event_kind := :old.event_kind;
    end if;
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.doc_number);
  trade_tax.check_header(inserting, :new.direction, :new.counterparty_id, :old.counterparty_id, :new.invoice_kind, :new.corrected_invoice_id);
  if :new.organization_id is null then
    :new.organization_id := trade_org.default_org;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/

create or replace trigger doc_tax_invoice_ad after delete on doc_tax_invoice
begin trade_core.g_deleting_doc := false; end;
/

create or replace trigger doc_tax_invoice_goods_ct
for insert or update or delete on doc_tax_invoice_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_TAX_INVOICE', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if :new.line_number is null or :new.line_number = 0 then :new.line_number := 1000000000; end if;
      if updating and nvl(:new.product_id, '-') <> nvl(:old.product_id, '-') then
        :new.description := case when :new.description = :old.description then null else :new.description end;
        :new.uktzed_code := case when nvl(:new.uktzed_code, '-') = nvl(:old.uktzed_code, '-') then null else :new.uktzed_code end;
        :new.unit_name := case when nvl(:new.unit_name, '-') = nvl(:old.unit_name, '-') then null else :new.unit_name end;
        :new.vat_rate_code := case when :new.vat_rate_code = :old.vat_rate_code then null else :new.vat_rate_code end;
      end if;
      trade_tax.check_line(:new.product_id, :new.description, :new.uktzed_code, :new.unit_name, :new.quantity, :new.price,
                           :new.vat_rate_code, :new.amount, :new.vat_amount,
                           inserting or nvl(:new.product_id, '-') <> nvl(:old.product_id, '-'), trade_core.g_internal);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_TAX_INVOICE_GOODS', l_doc);
      trade_tax.update_totals(l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end;
/

create or replace trigger reg_vat_mv_biud
before insert or update or delete on reg_vat_mv
begin
  if not trade_core.g_internal then
    trade_core.fail('Рухи регістру формуються лише проведенням документів.');
  end if;
end;
/

-- ---------------------------------------------------------------- реєстратори (+ податкова накладна)
create or replace view v_recorder as
select 'DocGoodsReceipt' recorder_type, d.id recorder_id,
       'Прибуткова накладна ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS') recorder_name, 51 page_id
  from doc_goods_receipt d
union all select 'DocSupplierPayment', d.id, 'Оплата постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 61 from doc_supplier_payment d
union all select 'DocPriceSetting', d.id, 'Встановлення цін ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 101 from doc_price_setting d
union all select 'DocGoodsSale', d.id, 'Реалізація товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 111 from doc_goods_sale d
union all select 'DocCustomerPayment', d.id, 'Оплата від покупця ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 121 from doc_customer_payment d
union all select 'DocGoodsTransfer', d.id, 'Переміщення товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 131 from doc_goods_transfer d
union all select 'DocGoodsWriteOff', d.id, 'Списання товарів ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 141 from doc_goods_write_off d
union all select 'DocCustomerOrder', d.id, 'Замовлення клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 261 from doc_customer_order d
union all select 'DocSupplierOrder', d.id, 'Замовлення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 271 from doc_supplier_order d
union all select 'DocCustomerReturn', d.id, 'Повернення від клієнта ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 281 from doc_customer_return d
union all select 'DocSupplierReturn', d.id, 'Повернення постачальнику ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 291 from doc_supplier_return d
union all select 'DocInventoryCount', d.id, 'Інвентаризація ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 301 from doc_inventory_count d
union all select 'DocSurplusPosting', d.id, 'Оприбуткування надлишків ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 311 from doc_surplus_posting d
union all select 'DocInvoiceForPayment', d.id, 'Рахунок на оплату ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 321 from doc_invoice_for_payment d
union all select 'DocCashReceipt', d.id, 'Прибутковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 371 from doc_cash_receipt d
union all select 'DocCashPayment', d.id, 'Видатковий касовий ордер ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 381 from doc_cash_payment d
union all select 'DocBankStatement', d.id, 'Банківська виписка ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 401 from doc_bank_statement d
union all select 'DocDebtAdjustment', d.id, 'Коригування боргу ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 411 from doc_debt_adjustment d
union all select 'DocAssembly', d.id, case d.operation_kind when 'ASSEMBLY' then 'Комплектація товарів ' else 'Розкомплектація товарів ' end
                 || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 441 from doc_assembly d
union all select 'DocGoodsReceiptOrder', d.id, 'Прибутковий ордер на товари ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 561 from doc_goods_receipt_order d
union all select 'DocGoodsIssueOrder', d.id, 'Видатковий ордер на товари ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 571 from doc_goods_issue_order d
union all select 'DocTaxInvoice', d.id, case d.direction when 'RECEIVED' then 'Податкова накладна отримана ' else 'Податкова накладна ' end
                 || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 621 from doc_tax_invoice d;

-- ---------------------------------------------------------------- представлення списків
create or replace view v_tax_invoice_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name, d.direction,
       case d.direction when 'RECEIVED' then 'Отримана' else 'Видана' end direction_name,
       d.counterparty_id, c.name counterparty_name, d.contract_id, k.name contract_name,
       d.event_kind, case d.event_kind when 'SHIPMENT' then 'Відвантаження' when 'PREPAYMENT' then 'Передоплата' else 'Вручну' end event_name,
       d.base_doc_type, d.base_doc_id, r.recorder_name base_name, r.page_id base_page,
       case when d.base_doc_id is not null and r.recorder_id is null then 'Видалено' end base_state,
       d.ext_number, d.seller_vat_number, d.buyer_vat_number, d.not_issued_reason,
       d.amount_without_vat, d.vat_amount, d.total_amount,
       d.erpn_status, trade_tax.erpn_status_name(d.erpn_status) erpn_status_name, d.erpn_reg_number, d.erpn_reg_date,
       case when d.direction = 'ISSUED' then trade_tax.erpn_deadline(d.occurred_at) end erpn_deadline,
       case when d.direction = 'ISSUED' and d.status = 'POSTED' and d.erpn_status <> 'REGISTERED'
             and trunc(sysdate) > trade_tax.erpn_deadline(d.occurred_at) then 'Так' end erpn_overdue,
       d.status, trade_tax.status_name(d.status) status_name, d.doc_comment, d.created_by
  from doc_tax_invoice d
  join ref_organization o on o.id = d.organization_id
  join ref_counterparty c on c.id = d.counterparty_id
  left join ref_contract k on k.id = d.contract_id
  left join v_recorder r on r.recorder_type = d.base_doc_type and r.recorder_id = d.base_doc_id;

create or replace view v_vat_ledger as
select m.period, m.recorder_id, t.doc_number, t.direction, case m.direction when 'LIABILITY' then 'Податкове зобов''язання' else 'Податковий кредит' end
       direction_name, m.organization_id, o.name organization_name, m.counterparty_id, c.name counterparty_name,
       m.vat_rate_code, v.name vat_rate_name, m.base_amount, m.vat_amount, t.erpn_status
  from reg_vat_mv m
  join doc_tax_invoice t on t.id = m.recorder_id
  join ref_organization o on o.id = m.organization_id
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_vat_rate v on v.code = m.vat_rate_code;

-- ---------------------------------------------------------------- міграція наявних документів
declare
  l_prev boolean := trade_core.g_internal;
begin
  trade_core.g_internal := true;
  update doc_goods_sale d set d.price_includes_vat = coalesce((select pt.price_includes_vat from ref_price_type pt where pt.id = d.price_type_id), 'Y')
   where d.price_includes_vat is null;
  update doc_goods_receipt set price_includes_vat = 'Y' where price_includes_vat is null;
  update doc_customer_return r set r.price_includes_vat = coalesce((select s.price_includes_vat from doc_goods_sale s where s.id = r.base_sale_id), 'Y')
   where r.price_includes_vat is null;
  update doc_supplier_return r set r.price_includes_vat = coalesce((select s.price_includes_vat from doc_goods_receipt s where s.id = r.base_receipt_id), 'Y')
   where r.price_includes_vat is null;
  update doc_invoice_for_payment set price_includes_vat = 'Y' where price_includes_vat is null;
  -- рядки без ставки: перерахунок (сума рядка не змінюється, режим «включає» — підсумок той самий)
  update doc_goods_sale_goods set vat_rate_code = null where vat_rate_code is null;
  update doc_goods_receipt_goods set vat_rate_code = null where vat_rate_code is null;
  update doc_customer_return_goods set vat_rate_code = null where vat_rate_code is null;
  update doc_supplier_return_goods set vat_rate_code = null where vat_rate_code is null;
  update doc_invoice_for_payment_goods set vat_rate_code = null where vat_rate_code is null;
  trade_core.g_internal := l_prev;
  commit;
exception when others then
  trade_core.g_internal := l_prev;
  rollback;
  raise;
end;
/

-- ---------------------------------------------------------------- демо: платники ПДВ серед контрагентів, ПН за першою подією
declare
  l_n number;
begin
  update ref_counterparty set vat_payer = 'Y', vat_number = lpad(to_char(mod(ora_hash(id), 1000000000)), 9, '0') || '026'
   where vat_payer = 'N' and code in (select code from (select code from ref_counterparty where state = 'ACTIVE' order by code) where rownum <= 6);
  update ref_product set uktzed_code = '2106909800' where uktzed_code is null and product_kind = 'GOODS' and rownum <= 3;
  commit;
  -- ПН за першою подією за 2 останні місяці (організації-платники ПДВ)
  select count(*) into l_n from doc_tax_invoice;
  if l_n = 0 then
    l_n := trade_tax.generate(add_months(trunc(sysdate, 'MM'), -1), sysdate, null, 'Y');
    commit;
  end if;
end;
/

-- ---------------------------------------------------------------- меню: «Фінанси → ПДВ», «Продажі», «Закупівлі»
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
  obj('DocTaxInvoice',       'DOCUMENT', 'Documents', 'Податкові накладні',      620, 621, 210, 'Роль: податковий облік');
  obj('TaxInvoiceRegister',  'REPORT',   'Reports',   'Реєстр податкових накладних', 630, null, 240, 'Роль: податковий облік');
  fp('Finance', 'ПДВ', 1, 15, 'DocTaxInvoice', 10, 'Y');
  fp('Finance', 'ПДВ', 1, 15, 'TaxInvoiceRegister', 20);
  fp('Sales', 'Розрахунки з клієнтами', 1, 20, 'DocTaxInvoice', 20);
  fp('Purchases', 'Розрахунки з постачальниками', 1, 20, 'DocTaxInvoice', 20);
  fp('Main', 'Звіти', 2, 10, 'TaxInvoiceRegister', 90);
  commit;
end;
/

-- Перекомпіляція залежних від v_recorder представлень і пакетів
begin
  for o in (select object_name, object_type from user_objects
             where status = 'INVALID' and object_type in ('VIEW', 'PACKAGE', 'PACKAGE BODY', 'TRIGGER')
             order by case object_type when 'VIEW' then 1 when 'PACKAGE' then 2 else 3 end) loop
    begin
      execute immediate 'alter ' || case o.object_type when 'PACKAGE BODY' then 'package' else lower(o.object_type) end
        || ' ' || o.object_name || ' compile' || case o.object_type when 'PACKAGE BODY' then ' body' end;
    exception when others then null;
    end;
  end loop;
end;
/
