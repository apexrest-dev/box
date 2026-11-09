-- =============================================================================
-- Trade r7 — F-INT-04 «EDI з торговими мережами» (APE-118). Паспорти EdiExchange, RefDeliveryPoint (PROPOSED).
-- Провайдеро-незалежний шар EDI без звернення до зовнішніх сервісів:
--   * GLN (13 цифр, контрольна цифра GS1): ref_organization.gln (постачальник), ref_counterparty.gln (мережа-
--     покупець), довідник ref_delivery_point «Точки доставки (GLN)» — магазин / РЦ мережі: контрагент, GLN, адреса,
--     склад відвантаження й вид цін за замовчуванням; номенклатура зіставляється за штрихкодами RegBarcode (EAN-13,
--     упаковки — кількість × unit_quantity), далі за кодом постачальника (артикул / код товару);
--   * журнал sys_edi_message (+ _line): вхідні ORDERS / RECADV, вихідні ORDRSP / DESADV / INVOIC; XML у
--     спільному форматі «EDI-XML» (структура EDIN / Вчасно.EDI: корінь ORDER / ORDRSP / DESADV / INVOICE / RECADV,
--     NUMBER, DATE, HEAD/SUPPLIER/BUYER/DELIVERYPLACE/SENDER/RECIPIENT, HEAD/POSITION…);
--   * trade_edi: load_xml / load_file (розбір і зіставлення, дублікати, помилки рядків), reprocess,
--     create_order (Замовлення клієнта з ORDERS: точка доставки, № і дата замовлення мережі, дата відвантаження,
--     ціни — за видом цін, інакше з файлу), ordrsp_from_order (підтвердження: прийнято / змінено / відхилено),
--     desadv_from_sale, invoic_from_sale (з ПДВ), RECADV — звірка прийнятої кількості з реалізацією;
--   * транспорт: вивантаження / завантаження файлу (download) і підключаємий провайдер sys_edi_provider
--     (send → процедура провайдера; STUB — імітація, FILE — ручна передача файлу); реальні EDIN / Вчасно / M.E.Doc —
--     окремі адаптери з тією самою сигнатурою (поза межами задачі);
--   * doc_customer_order: delivery_point_id, ext_order_number, ext_order_date;
--   * меню «Продажі → EDI» (сторінка 700, точки доставки 710/711), демо: GLN, 2 точки доставки, вхідне ORDERS.
-- Правки: db/02 trade_core.catalog_table (+REF_DELIVERY_POINT), db/37 install_triggers (+REF_DELIVERY_POINT).
-- Потребує 02, 12–14, 24, 37, 39, 42. Повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264, -1430) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- GLN організацій і контрагентів
  ddl('alter table ref_organization add (gln varchar2(13))');
  ddl('alter table ref_counterparty add (gln varchar2(13))');
  ddl('create unique index ref_organization_gln_ux on ref_organization (gln)');
  ddl('create unique index ref_counterparty_gln_ux on ref_counterparty (gln)');

  -- ---------------------------------------------------------------- RefDeliveryPoint
  ddl('create sequence ref_delivery_point_code_seq nocache');
  ddl(q'[create table ref_delivery_point (
    id              varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code            varchar2(9)   not null,
    name            varchar2(255) not null,
    counterparty_id varchar2(32)  not null,
    gln             varchar2(13)  not null,
    address         varchar2(500),
    warehouse_id    varchar2(32),
    price_type_id   varchar2(32),
    note            varchar2(1000),
    state           varchar2(20)  default on null 'ACTIVE' not null,
    version         number(19)    default on null 0 not null,
    created_at timestamp not null, created_by varchar2(255) not null,
    updated_at timestamp not null, updated_by varchar2(255) not null,
    constraint ref_delivery_point_pk primary key (id),
    constraint ref_delivery_point_code_uk unique (code),
    constraint ref_delivery_point_gln_uk unique (gln),
    constraint ref_delivery_point_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint ref_delivery_point_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint ref_delivery_point_pt_fk foreign key (price_type_id) references ref_price_type (id),
    constraint ref_delivery_point_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_delivery_point_cp_ix on ref_delivery_point (counterparty_id)');

  -- ---------------------------------------------------------------- замовлення клієнта: реквізити EDI
  ddl('alter table doc_customer_order add (delivery_point_id varchar2(32), ext_order_number varchar2(35), ext_order_date date)');
  ddl('alter table doc_customer_order add constraint doc_customer_order_dp_fk foreign key (delivery_point_id) references ref_delivery_point (id)');

  -- ---------------------------------------------------------------- провайдери EDI
  ddl(q'[create table sys_edi_provider (
    code           varchar2(20)  not null,
    name           varchar2(255) not null,
    send_procedure varchar2(128),
    is_default     varchar2(1)   default on null 'N' not null,
    note           varchar2(1000),
    constraint sys_edi_provider_pk primary key (code),
    constraint sys_edi_provider_def_ck check (is_default in ('Y','N')))]');

  -- ---------------------------------------------------------------- журнал повідомлень
  ddl('create sequence sys_edi_message_seq nocache');
  ddl(q'[create table sys_edi_message (
    id                varchar2(32)   default on null rawtohex(sys_guid()) not null,
    msg_no            number(10)     not null,
    direction         varchar2(3)    not null,
    msg_type          varchar2(10)   not null,
    status            varchar2(10)   default on null 'NEW' not null,
    doc_number        varchar2(35),
    doc_date          date,
    order_number      varchar2(35),
    order_date        date,
    delivery_date     date,
    desadv_number     varchar2(35),
    sender_gln        varchar2(13),
    recipient_gln     varchar2(13),
    supplier_gln      varchar2(13),
    buyer_gln         varchar2(13),
    delivery_gln      varchar2(13),
    organization_id   varchar2(32),
    counterparty_id   varchar2(32),
    delivery_point_id varchar2(32),
    customer_order_id varchar2(32),
    sale_id           varchar2(32),
    ref_message_id    varchar2(32),
    currency_code     varchar2(3),
    action_code       varchar2(3),
    line_count        number(10)     default on null 0 not null,
    error_count       number(10)     default on null 0 not null,
    diff_count        number(10)     default on null 0 not null,
    total_amount      number(19,2),
    vat_amount        number(19,2),
    comment_text      varchar2(1000),
    file_name         varchar2(400),
    payload           clob,
    error_text        varchar2(4000),
    provider_code     varchar2(20),
    ext_id            varchar2(100),
    sent_at           timestamp,
    sent_by           varchar2(255),
    processed_at      timestamp,
    processed_by      varchar2(255),
    created_at        timestamp      default on null systimestamp not null,
    created_by        varchar2(255)  not null,
    constraint sys_edi_message_pk primary key (id),
    constraint sys_edi_message_no_uk unique (msg_no),
    constraint sys_edi_message_dir_ck check (direction in ('IN','OUT')),
    constraint sys_edi_message_type_ck check (msg_type in ('ORDERS','ORDRSP','DESADV','INVOIC','RECADV')),
    constraint sys_edi_message_status_ck check (status in ('NEW','ERROR','PROCESSED','GENERATED','SENT','CANCELLED')),
    constraint sys_edi_message_org_fk foreign key (organization_id) references ref_organization (id),
    constraint sys_edi_message_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint sys_edi_message_dp_fk foreign key (delivery_point_id) references ref_delivery_point (id),
    constraint sys_edi_message_ord_fk foreign key (customer_order_id) references doc_customer_order (id),
    constraint sys_edi_message_sale_fk foreign key (sale_id) references doc_goods_sale (id),
    constraint sys_edi_message_ref_fk foreign key (ref_message_id) references sys_edi_message (id),
    constraint sys_edi_message_prov_fk foreign key (provider_code) references sys_edi_provider (code))]');
  ddl('create index sys_edi_message_cr_ix on sys_edi_message (created_at)');
  ddl('create index sys_edi_message_ord_ix on sys_edi_message (customer_order_id)');
  ddl('create index sys_edi_message_sale_ix on sys_edi_message (sale_id)');
  ddl('create index sys_edi_message_doc_ix on sys_edi_message (msg_type, counterparty_id, doc_number)');
  ddl(q'[create table sys_edi_message_line (
    id             varchar2(32)  default on null rawtohex(sys_guid()) not null,
    message_id     varchar2(32)  not null,
    line_no        number(10)    not null,
    barcode        varchar2(64),
    buyer_code     varchar2(64),
    supplier_code  varchar2(64),
    description    varchar2(500),
    quantity       number(19,3),
    unit_code      varchar2(10),
    price          number(19,4),
    price_with_vat number(19,4),
    vat_rate       number(5,2),
    accepted_qty   number(19,3),
    product_id     varchar2(32),
    unit_quantity  number(19,3)  default on null 1 not null,
    base_quantity  number(19,3),
    matched_by     varchar2(20),
    line_status    varchar2(10)  default on null 'OK' not null,
    message        varchar2(1000),
    constraint sys_edi_message_line_pk primary key (id),
    constraint sys_edi_message_line_msg_fk foreign key (message_id) references sys_edi_message (id) on delete cascade,
    constraint sys_edi_message_line_prd_fk foreign key (product_id) references ref_product (id),
    constraint sys_edi_message_line_st_ck check (line_status in ('OK','WARNING','ERROR')))]');
  ddl('create index sys_edi_message_line_msg_ix on sys_edi_message_line (message_id, line_no)');
end;
/

-- =============================================================================
create or replace package trade_edi as
  c_format constant varchar2(60) := 'EDI-XML 1.0 (структура EDIN / Вчасно.EDI)';

  -- ---------- GLN (GS1, 13 цифр)
  function gln_with_check (p12 in varchar2) return varchar2;
  function is_valid_gln   (p_gln in varchar2) return varchar2;     -- Y / N
  function normalize_gln  (p_gln in varchar2) return varchar2;
  procedure check_gln     (p_gln in varchar2, p_label in varchar2);
  procedure check_delivery_point (p_id in varchar2, p_counterparty in varchar2, p_gln in varchar2,
                                  p_warehouse in varchar2, p_price_type in varchar2);

  -- ---------- службові (публічні — використовуються в SQL пакета)
  function to_dt (p in varchar2) return date;
  function xamt  (p in number) return varchar2;

  -- ---------- довідкові назви
  function type_name      (p_type in varchar2) return varchar2;
  function status_name    (p_status in varchar2) return varchar2;
  function direction_name (p_dir in varchar2) return varchar2;
  function unit_code      (p_product_id in varchar2) return varchar2;
  function product_ean    (p_product_id in varchar2) return varchar2;
  function default_provider return varchar2;

  -- ---------- вхідні повідомлення (ORDERS, RECADV)
  function  load_xml  (p_file_name in varchar2, p_xml in clob) return varchar2;
  function  load_file (p_file_name in varchar2, p_blob in blob) return varchar2;
  procedure reprocess (p_id in varchar2);
  function  create_order (p_id in varchar2, p_post in varchar2 default 'N') return varchar2;

  -- ---------- вихідні повідомлення (ORDRSP, DESADV, INVOIC)
  function ordrsp_from_order (p_order_id in varchar2) return varchar2;
  function desadv_from_sale  (p_sale_id in varchar2) return varchar2;
  function invoic_from_sale  (p_sale_id in varchar2) return varchar2;

  -- ---------- транспорт
  procedure send      (p_id in varchar2, p_provider in varchar2 default null);
  procedure stub_send (p_id in varchar2, p_ext_id out varchar2);     -- імітація провайдера (сигнатура адаптера)
  procedure cancel    (p_id in varchar2);
  function  file_name_of (p_id in varchar2) return varchar2;
  procedure download  (p_id in varchar2);

  -- ---------- UI / демо
  function message_html (p_id in varchar2) return clob;
  function sample_orders_xml (p_number in varchar2 default null, p_delivery_gln in varchar2 default null) return clob;
  function sample_recadv_xml (p_desadv_id in varchar2, p_short in number default 0) return clob;
  function load_sample (p_kind in varchar2 default 'ORDERS', p_base_id in varchar2 default null) return varchar2;
end trade_edi;
/

create or replace package body trade_edi as

  g_dummy varchar2(1);

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;

  function esc (p varchar2) return varchar2 is
  begin
    return replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
  end esc;

  function h (p varchar2) return varchar2 is
  begin
    return replace(replace(replace(replace(replace(p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#x27;');
  end h;

  function tag (p_name varchar2, p_val varchar2) return varchar2 is
  begin
    if p_val is null then return null; end if;
    return '<' || p_name || '>' || esc(p_val) || '</' || p_name || '>';
  end tag;

  function xdate (p date) return varchar2 is begin return to_char(p, 'YYYY-MM-DD'); end;
  function xqty (p number) return varchar2 is
  begin return rtrim(rtrim(to_char(p, 'FM999999999990.000', 'NLS_NUMERIC_CHARACTERS=''.,'''), '0'), '.'); end;
  function xamt (p in number) return varchar2 is
  begin return to_char(p, 'FM999999999990.00', 'NLS_NUMERIC_CHARACTERS=''.,'''); end;
  function xprc (p number) return varchar2 is
  begin return to_char(p, 'FM999999999990.0000', 'NLS_NUMERIC_CHARACTERS=''.,'''); end;

  function qh (p number) return varchar2 is
  begin return replace(xqty(p), '.', ','); end;

  function to_num (p varchar2) return number is
    l varchar2(100) := replace(replace(trim(p), ' '), ',', '.');
  begin
    if l is null then return null; end if;
    return to_number(l, '999999999999999990.9999999999', 'NLS_NUMERIC_CHARACTERS=''.,''');
  exception when others then
    return to_number(l, '999999999999999990', 'NLS_NUMERIC_CHARACTERS=''.,''');
  end to_num;

  function to_dt (p in varchar2) return date is
    l varchar2(40) := trim(p);
  begin
    if l is null then return null; end if;
    if length(l) >= 10 and substr(l, 5, 1) = '-' then
      return to_date(substr(l, 1, 10), 'YYYY-MM-DD');
    elsif length(l) >= 10 and substr(l, 3, 1) = '.' then
      return to_date(substr(l, 1, 10), 'DD.MM.YYYY');
    elsif length(l) = 8 then
      return to_date(l, 'YYYYMMDD');
    end if;
    return to_date(l, 'YYYY-MM-DD');
  end to_dt;

  -- ================================================================ GLN
  function gln_with_check (p12 in varchar2) return varchar2 is
    l_sum pls_integer := 0;
  begin
    if p12 is null or length(p12) <> 12 or translate(p12, 'x0123456789', 'x') is not null then
      return null;
    end if;
    for i in 1 .. 12 loop
      l_sum := l_sum + to_number(substr(p12, i, 1)) * case when mod(i, 2) = 0 then 3 else 1 end;
    end loop;
    return p12 || to_char(mod(10 - mod(l_sum, 10), 10));
  end gln_with_check;

  function normalize_gln (p_gln in varchar2) return varchar2 is
  begin
    return replace(replace(trim(p_gln), ' '), '-');
  end normalize_gln;

  function is_valid_gln (p_gln in varchar2) return varchar2 is
    l varchar2(100) := normalize_gln(p_gln);
  begin
    if l is null or length(l) <> 13 or translate(l, 'x0123456789', 'x') is not null then
      return 'N';
    end if;
    return case when gln_with_check(substr(l, 1, 12)) = l then 'Y' else 'N' end;
  end is_valid_gln;

  procedure check_gln (p_gln in varchar2, p_label in varchar2) is
    l varchar2(100) := normalize_gln(p_gln);
  begin
    if l is null then return; end if;
    if length(l) <> 13 or translate(l, 'x0123456789', 'x') is not null then
      fail('GLN_FORMAT', p_label || ': GLN має містити 13 цифр.');
    end if;
    if is_valid_gln(l) = 'N' then
      fail('GLN_CHECKSUM', p_label || ': невірна контрольна цифра GLN ' || l || '.');
    end if;
  end check_gln;

  procedure check_delivery_point (p_id in varchar2, p_counterparty in varchar2, p_gln in varchar2,
                                  p_warehouse in varchar2, p_price_type in varchar2) is
    l_n number;
  begin
    if p_gln is null then
      fail('GLN_REQUIRED', 'Вкажіть GLN точки доставки.');
    end if;
    check_gln(p_gln, 'Точка доставки');
    trade_core.check_active_ref('REF_COUNTERPARTY', p_counterparty, 'Контрагент');
    if p_warehouse is not null then
      trade_core.check_active_ref('REF_WAREHOUSE', p_warehouse, 'Склад');
    end if;
    if p_price_type is not null then
      trade_core.check_active_ref('REF_PRICE_TYPE', p_price_type, 'Вид цін');
    end if;
    select count(*) into l_n from ref_organization where gln = p_gln;
    select count(*) + l_n into l_n from ref_counterparty where gln = p_gln;
    if l_n > 0 then
      fail('GLN_DUPLICATE', 'GLN ' || p_gln || ' уже вказано в організації або контрагента.');
    end if;
  end check_delivery_point;

  -- ================================================================ назви
  function type_name (p_type in varchar2) return varchar2 is
  begin
    return case p_type when 'ORDERS' then 'ORDERS — замовлення' when 'ORDRSP' then 'ORDRSP — підтвердження замовлення'
                       when 'DESADV' then 'DESADV — повідомлення про відвантаження' when 'INVOIC' then 'INVOIC — рахунок / накладна'
                       when 'RECADV' then 'RECADV — повідомлення про приймання' else p_type end;
  end type_name;

  function status_name (p_status in varchar2) return varchar2 is
  begin
    return case p_status when 'NEW' then 'Нове' when 'ERROR' then 'Помилка' when 'PROCESSED' then 'Оброблено'
                         when 'GENERATED' then 'Сформовано' when 'SENT' then 'Надіслано' when 'CANCELLED' then 'Скасовано'
                         else p_status end;
  end status_name;

  function direction_name (p_dir in varchar2) return varchar2 is
  begin
    return case p_dir when 'IN' then 'Вхідне' when 'OUT' then 'Вихідне' end;
  end direction_name;

  function unit_code (p_product_id in varchar2) return varchar2 is
    l varchar2(20);
  begin
    select lower(u.short_name) into l from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id where p.id = p_product_id;
    return case when l like 'шт%' then 'PCE' when l like 'кг%' then 'KGM' when l = 'г' then 'GRM' when l like 'л%' then 'LTR'
                when l like 'м%' and l not like 'мл%' then 'MTR' when l like 'уп%' then 'PA' when l like 'пос%' then 'E48'
                else 'PCE' end;
  exception when no_data_found then return 'PCE';
  end unit_code;

  function product_ean (p_product_id in varchar2) return varchar2 is
    l varchar2(64);
  begin
    select min(barcode) keep (dense_rank first order by case when unit_quantity = 1 then 0 else 1 end, barcode)
      into l from reg_barcode where product_id = p_product_id and length(barcode) in (8, 13, 14);
    return l;
  end product_ean;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select name into l from ref_product where id = p_id;
    return l;
  end prd_name;

  function prd_code (p_id varchar2) return varchar2 is
    l varchar2(64);
  begin
    select coalesce(article, code) into l from ref_product where id = p_id;
    return l;
  end prd_code;

  function default_provider return varchar2 is
    l varchar2(20);
  begin
    select min(code) keep (dense_rank first order by case is_default when 'Y' then 0 else 1 end, code) into l from sys_edi_provider;
    return l;
  end default_provider;

  function new_message (p_dir varchar2, p_type varchar2, p_status varchar2) return sys_edi_message%rowtype is
    m sys_edi_message%rowtype;
  begin
    m.id := rawtohex(sys_guid());
    m.msg_no := sys_edi_message_seq.nextval;
    m.direction := p_dir; m.msg_type := p_type; m.status := p_status;
    m.created_at := systimestamp; m.created_by := trade_core.current_user_name;
    return m;
  end new_message;

  -- ================================================================ вхідні: розбір і зіставлення
  procedure add_error (p_errors in out nocopy varchar2, p_text varchar2) is
  begin
    if p_errors is null then p_errors := p_text;
    elsif length(p_errors) + length(p_text) < 3900 then p_errors := p_errors || chr(10) || p_text;
    end if;
  end add_error;

  procedure parse (p_id in varchar2) is
    m sys_edi_message%rowtype;
    x xmltype;
    l_root varchar2(30);
    l_err varchar2(4000);
    l_n number;
    l_cp_dp varchar2(32);
    l_prd varchar2(32); l_uq number; l_by varchar2(20); l_st varchar2(10); l_msg varchar2(1000);
    l_lines pls_integer := 0; l_bad pls_integer := 0;
  begin
    select * into m from sys_edi_message where id = p_id for update;
    delete from sys_edi_message_line where message_id = p_id;
    m.organization_id := null; m.counterparty_id := null; m.delivery_point_id := null; m.sale_id := null; m.ref_message_id := null;
    m.error_text := null; m.diff_count := 0;
    begin
      x := xmltype(m.payload);
    exception when others then
      l_err := 'Файл не є коректним XML: ' || substr(sqlerrm, 1, 300);
      update sys_edi_message set status = 'ERROR', error_text = l_err,
             line_count = 0, error_count = 1 where id = p_id;
      return;
    end;
    l_root := upper(x.getrootelement());
    m.msg_type := case when l_root in ('ORDER', 'ORDERS') then 'ORDERS' when l_root = 'RECADV' then 'RECADV' end;
    if m.msg_type is null then
      update sys_edi_message set status = 'ERROR', line_count = 0, error_count = 1,
             error_text = 'Непідтримуваний тип вхідного повідомлення «' || l_root || '». Приймаються ORDER (ORDERS) і RECADV.'
       where id = p_id;
      return;
    end if;
    -- шапка
    select substr(trim(number_), 1, 35), to_dt(date_), substr(trim(ordernumber), 1, 35), to_dt(orderdate), to_dt(deliverydate),
           substr(trim(coalesce(desadvnumber, deliverynotenumber)), 1, 35),
           normalize_gln(sender), normalize_gln(recipient), normalize_gln(supplier), normalize_gln(buyer), normalize_gln(deliveryplace),
           upper(substr(trim(currency), 1, 3)), substr(trim(info), 1, 1000)
      into m.doc_number, m.doc_date, m.order_number, m.order_date, m.delivery_date, m.desadv_number,
           m.sender_gln, m.recipient_gln, m.supplier_gln, m.buyer_gln, m.delivery_gln, m.currency_code, m.comment_text
      from xmltable('/*' passing x columns
             number_ varchar2(100) path 'NUMBER', date_ varchar2(40) path 'DATE',
             ordernumber varchar2(100) path 'ORDERNUMBER', orderdate varchar2(40) path 'ORDERDATE',
             deliverydate varchar2(40) path 'DELIVERYDATE',
             desadvnumber varchar2(100) path 'DESADVNUMBER', deliverynotenumber varchar2(100) path 'DELIVERYNOTENUMBER',
             sender varchar2(40) path 'HEAD/SENDER', recipient varchar2(40) path 'HEAD/RECIPIENT',
             supplier varchar2(40) path 'HEAD/SUPPLIER', buyer varchar2(40) path 'HEAD/BUYER',
             deliveryplace varchar2(40) path 'HEAD/DELIVERYPLACE',
             currency varchar2(10) path 'CURRENCY', info varchar2(4000) path 'INFO');
    if m.msg_type = 'ORDERS' and m.order_number is null then
      m.order_number := m.doc_number; m.order_date := m.doc_date;
    end if;
    if m.doc_number is null then add_error(l_err, 'Не вказано номер документа (NUMBER).'); end if;
    if m.doc_date is null then add_error(l_err, 'Не вказано дату документа (DATE).'); end if;
    -- постачальник (ми): SUPPLIER, інакше RECIPIENT
    for o in (select id from ref_organization where gln = coalesce(m.supplier_gln, m.recipient_gln) and state = 'ACTIVE') loop
      m.organization_id := o.id;
    end loop;
    if m.organization_id is null then
      add_error(l_err, 'Організацію-постачальника з GLN ' || coalesce(m.supplier_gln, m.recipient_gln, '(не вказано)')
                       || ' не знайдено. Вкажіть GLN в довіднику «Організації».');
    end if;
    -- точка доставки й покупець
    if m.delivery_gln is not null then
      for d in (select id, counterparty_id from ref_delivery_point where gln = m.delivery_gln and state = 'ACTIVE') loop
        m.delivery_point_id := d.id; l_cp_dp := d.counterparty_id;
      end loop;
      if m.delivery_point_id is null then
        add_error(l_err, 'Точку доставки з GLN ' || m.delivery_gln || ' не знайдено. Додайте її в довідник «Точки доставки (GLN)».');
      end if;
    end if;
    for c in (select id from ref_counterparty where gln = coalesce(m.buyer_gln, m.sender_gln) and state = 'ACTIVE') loop
      m.counterparty_id := c.id;
    end loop;
    if m.counterparty_id is null then
      m.counterparty_id := l_cp_dp;
    elsif l_cp_dp is not null and l_cp_dp <> m.counterparty_id then
      add_error(l_err, 'Точка доставки ' || m.delivery_gln || ' належить іншому контрагенту, ніж покупець ' || m.buyer_gln || '.');
    end if;
    if m.counterparty_id is null then
      add_error(l_err, 'Покупця з GLN ' || coalesce(m.buyer_gln, m.sender_gln, '(не вказано)')
                       || ' не знайдено. Вкажіть GLN у довіднику «Контрагенти» або точку доставки.');
    end if;
    if m.msg_type = 'ORDERS' and m.delivery_point_id is null and m.delivery_gln is null then
      null;   -- точка доставки не обов'язкова: склад і вид цін — за замовчуванням
    end if;
    if m.currency_code is not null and m.currency_code <> 'UAH' then
      add_error(l_err, 'Підтримується лише валюта UAH (у файлі ' || m.currency_code || ').');
    end if;
    -- дублікати
    if m.msg_type = 'ORDERS' and m.counterparty_id is not null and m.doc_number is not null then
      select count(*) into l_n from sys_edi_message
       where msg_type = 'ORDERS' and direction = 'IN' and counterparty_id = m.counterparty_id and doc_number = m.doc_number
         and status = 'PROCESSED' and id <> p_id;
      if l_n > 0 then
        add_error(l_err, 'Замовлення мережі № ' || m.doc_number || ' уже оброблено (повторний файл).');
      end if;
    end if;
    -- RECADV: пошук відвантаження (DESADV → реалізація)
    if m.msg_type = 'RECADV' and m.counterparty_id is not null then
      for r in (select id, sale_id from sys_edi_message
                 where direction = 'OUT' and msg_type = 'DESADV' and status in ('GENERATED', 'SENT')
                   and counterparty_id = m.counterparty_id and doc_number = m.desadv_number
                 order by created_at desc fetch first 1 row only) loop
        m.ref_message_id := r.id; m.sale_id := r.sale_id;
      end loop;
      if m.sale_id is null then
        select max(id) into m.sale_id from doc_goods_sale
         where doc_number = m.desadv_number and customer_id = m.counterparty_id and status = 'POSTED';
      end if;
      if m.sale_id is null then
        add_error(l_err, 'Відвантаження (DESADV / реалізацію) № ' || coalesce(m.desadv_number, '(не вказано)')
                         || ' цього покупця не знайдено.');
      end if;
    end if;
    -- рядки
    for r in (select rownum rn, t.*
                from xmltable('//POSITION' passing x columns
                       posno varchar2(20) path 'POSITIONNUMBER', ean varchar2(100) path 'PRODUCT',
                       buyer_code varchar2(100) path 'PRODUCTIDBUYER', sup_code varchar2(100) path 'PRODUCTIDSUPPLIER',
                       descr varchar2(1000) path 'DESCRIPTION',
                       qty varchar2(40) path 'ORDEREDQUANTITY', dqty varchar2(40) path 'DELIVERQUANTITY',
                       aqty varchar2(40) path 'ACCEPTEDQUANTITY',
                       unit varchar2(20) path 'ORDERUNIT', unit2 varchar2(20) path 'UNIT',
                       price varchar2(40) path 'ORDERPRICE', price2 varchar2(40) path 'PRICE',
                       pricevat varchar2(40) path 'PRICEWITHVAT', vat varchar2(20) path 'VAT') t) loop
      l_lines := l_lines + 1;
      l_prd := null; l_uq := 1; l_by := null; l_st := 'OK'; l_msg := null;
      declare
        l_ean  varchar2(64) := trade_nsi.normalize_barcode(r.ean);
        l_qty  number; l_acc number; l_price number; l_pvat number; l_vat number; l_lno number;
      begin
        begin
          l_lno := coalesce(to_num(r.posno), r.rn);
          l_qty := to_num(case m.msg_type when 'RECADV' then coalesce(r.dqty, r.qty) else r.qty end);
          l_acc := to_num(r.aqty);
          l_price := to_num(coalesce(r.price, r.price2));
          l_pvat := to_num(r.pricevat);
          l_vat := to_num(r.vat);
        exception when others then
          l_st := 'ERROR'; l_msg := 'Некоректне число в рядку.'; l_lno := r.rn;
        end;
        if l_st = 'OK' and l_ean is not null then
          for b in (select product_id, unit_quantity from reg_barcode where barcode = l_ean) loop
            l_prd := b.product_id; l_uq := b.unit_quantity; l_by := 'BARCODE';
          end loop;
        end if;
        if l_st = 'OK' and l_prd is null and trim(r.sup_code) is not null then
          select min(id) into l_prd from ref_product where state = 'ACTIVE' and (article = trim(r.sup_code) or code = trim(r.sup_code));
          if l_prd is not null then l_by := 'SUPPLIER_CODE'; end if;
        end if;
        if l_st = 'OK' and l_prd is null then
          l_st := 'ERROR';
          l_msg := 'Товар не знайдено: штрихкод ' || coalesce(l_ean, '—') || ', код постачальника ' || coalesce(trim(r.sup_code), '—')
                   || '. Додайте штрихкод у регістр «Штрихкоди».';
        end if;
        if l_st = 'OK' and l_prd is not null then
          select count(*) into l_n from ref_product where id = l_prd and state = 'ACTIVE';
          if l_n = 0 then l_st := 'ERROR'; l_msg := 'Товар помічено на видалення.'; end if;
        end if;
        if l_st = 'OK' and m.msg_type = 'ORDERS' and (l_qty is null or l_qty <= 0) then
          l_st := 'ERROR'; l_msg := 'Кількість (ORDEREDQUANTITY) має бути більше нуля.';
        end if;
        if l_st = 'OK' and m.msg_type = 'RECADV' and l_acc is null then
          l_st := 'ERROR'; l_msg := 'Не вказано прийняту кількість (ACCEPTEDQUANTITY).';
        end if;
        if l_st = 'OK' and l_by = 'BARCODE' and l_uq <> 1 then
          l_msg := 'Штрихкод упаковки: 1 = ' || xqty(l_uq) || ' од.';
        end if;
        if l_st = 'ERROR' then l_bad := l_bad + 1; end if;
        insert into sys_edi_message_line (message_id, line_no, barcode, buyer_code, supplier_code, description, quantity, unit_code,
                                          price, price_with_vat, vat_rate, accepted_qty, product_id, unit_quantity, base_quantity,
                                          matched_by, line_status, message)
        values (p_id, l_lno, l_ean, substr(trim(r.buyer_code), 1, 64), substr(trim(r.sup_code), 1, 64), substr(trim(r.descr), 1, 500),
                l_qty, upper(substr(trim(coalesce(r.unit, r.unit2)), 1, 10)), l_price, l_pvat, l_vat, l_acc, l_prd, l_uq,
                case when m.msg_type = 'RECADV' then l_acc else l_qty end * l_uq, l_by, l_st, l_msg);
      end;
    end loop;
    if l_lines = 0 then
      add_error(l_err, 'У файлі немає рядків товарів (POSITION).');
    elsif l_bad = l_lines then
      add_error(l_err, 'Жоден рядок не зіставлено з номенклатурою.');
    end if;
    -- RECADV: розбіжності з реалізацією (за товарами, в одиницях товару)
    if m.msg_type = 'RECADV' and m.sale_id is not null then
      select count(*) into m.diff_count
        from (select product_id, sum(q_sale) q_sale, sum(q_acc) q_acc
                from (select product_id, quantity q_sale, 0 q_acc from doc_goods_sale_goods where document_id = m.sale_id
                      union all
                      select product_id, 0, base_quantity from sys_edi_message_line where message_id = p_id and product_id is not null)
               group by product_id)
       where q_sale <> q_acc;
    end if;
    update sys_edi_message
       set msg_type = m.msg_type, doc_number = m.doc_number, doc_date = m.doc_date, order_number = m.order_number,
           order_date = m.order_date, delivery_date = m.delivery_date, desadv_number = m.desadv_number,
           sender_gln = m.sender_gln, recipient_gln = m.recipient_gln, supplier_gln = m.supplier_gln, buyer_gln = m.buyer_gln,
           delivery_gln = m.delivery_gln, organization_id = m.organization_id, counterparty_id = m.counterparty_id,
           delivery_point_id = m.delivery_point_id, sale_id = m.sale_id, ref_message_id = m.ref_message_id,
           currency_code = coalesce(m.currency_code, 'UAH'), comment_text = m.comment_text,
           line_count = l_lines, error_count = l_bad + case when l_err is not null then 1 else 0 end, diff_count = m.diff_count,
           error_text = l_err,
           status = case when l_err is not null then 'ERROR' when m.msg_type = 'RECADV' then 'PROCESSED' else 'NEW' end,
           processed_at = case when l_err is null and m.msg_type = 'RECADV' then systimestamp end,
           processed_by = case when l_err is null and m.msg_type = 'RECADV' then trade_core.current_user_name end,
           total_amount = (select round(sum(quantity * coalesce(price_with_vat, price)), 2) from sys_edi_message_line where message_id = p_id)
     where id = p_id;
  end parse;

  function load_xml (p_file_name in varchar2, p_xml in clob) return varchar2 is
    m sys_edi_message%rowtype := new_message('IN', 'ORDERS', 'NEW');
  begin
    if p_xml is null or dbms_lob.getlength(p_xml) = 0 then
      fail('EDI_FILE_EMPTY', 'Файл порожній.');
    end if;
    m.file_name := substr(p_file_name, 1, 400);
    m.payload := p_xml;
    insert into sys_edi_message values m;
    parse(m.id);
    trade_core.audit('EDI', m.id, 'EDI_LOAD', m.file_name);
    return m.id;
  end load_xml;

  function load_file (p_file_name in varchar2, p_blob in blob) return varchar2 is
    l_clob clob; l_dest integer := 1; l_src integer := 1; l_ctx integer := dbms_lob.default_lang_ctx; l_warn integer;
    l_head varchar2(200); l_cs varchar2(30) := 'AL32UTF8';
  begin
    if p_blob is null or dbms_lob.getlength(p_blob) = 0 then
      fail('EDI_FILE_EMPTY', 'Виберіть файл для завантаження.');
    end if;
    if dbms_lob.getlength(p_blob) > 10 * 1024 * 1024 then
      fail('EDI_FILE_TOO_BIG', 'Файл більший за 10 МБ.');
    end if;
    l_head := lower(utl_raw.cast_to_varchar2(dbms_lob.substr(p_blob, 100, 1)));
    if instr(l_head, 'windows-1251') > 0 or instr(l_head, 'cp1251') > 0 then
      l_cs := 'CL8MSWIN1251';
    end if;
    dbms_lob.createtemporary(l_clob, true);
    dbms_lob.converttoclob(l_clob, p_blob, dbms_lob.lobmaxsize, l_dest, l_src, nls_charset_id(l_cs), l_ctx, l_warn);
    -- BOM UTF-8 і декларація кодування (CLOB уже в кодуванні БД)
    if substr(l_clob, 1, 1) = unistr('\FEFF') then
      l_clob := substr(l_clob, 2);
    end if;
    l_clob := regexp_replace(l_clob, '^\s*<\?xml[^>]*\?>', '<?xml version="1.0"?>', 1, 1);
    return load_xml(p_file_name, l_clob);
  end load_file;

  procedure reprocess (p_id in varchar2) is
    l_status varchar2(10); l_dir varchar2(3);
  begin
    select status, direction into l_status, l_dir from sys_edi_message where id = p_id;
    if l_dir <> 'IN' or l_status not in ('NEW', 'ERROR') then
      fail('EDI_NOT_REPROCESSABLE', 'Повторно зіставити можна лише вхідне повідомлення в стані «Нове» або «Помилка».');
    end if;
    parse(p_id);
    trade_core.audit('EDI', p_id, 'EDI_REPROCESS');
  end reprocess;

  function create_order (p_id in varchar2, p_post in varchar2 default 'N') return varchar2 is
    m sys_edi_message%rowtype;
    l_new varchar2(32) := rawtohex(sys_guid());
    l_wh varchar2(32); l_pt varchar2(32); l_price number; l_our number; l_cnt pls_integer := 0;
    l_dt date := sysdate; l_ship date;
  begin
    select * into m from sys_edi_message where id = p_id for update;
    if m.direction <> 'IN' or m.msg_type <> 'ORDERS' then
      fail('EDI_NOT_ORDERS', 'Замовлення клієнта створюється лише з вхідного повідомлення ORDERS.');
    end if;
    if m.status = 'PROCESSED' then
      fail('EDI_ALREADY_PROCESSED', 'Повідомлення вже оброблено: замовлення клієнта створено.');
    end if;
    if m.status <> 'NEW' then
      fail('EDI_HAS_ERRORS', 'Повідомлення містить помилки зіставлення. Виправте довідники й натисніть «Повторити зіставлення».');
    end if;
    for d in (select warehouse_id, price_type_id from ref_delivery_point where id = m.delivery_point_id) loop
      l_wh := d.warehouse_id; l_pt := d.price_type_id;
    end loop;
    if l_wh is null then
      select min(id) keep (dense_rank first order by code) into l_wh from ref_warehouse where state = 'ACTIVE';
    end if;
    if l_pt is null then
      select max(c.price_type_id) into l_pt from ref_contract c
       where c.id = trade_nsi.resolve_default_contract(m.counterparty_id, 'WITH_CUSTOMER', l_dt);
    end if;
    l_ship := case when m.delivery_date >= trunc(l_dt) then m.delivery_date end;
    insert into doc_customer_order (id, occurred_at, organization_id, customer_id, warehouse_id, price_type_id, shipment_date,
                                    delivery_point_id, ext_order_number, ext_order_date, doc_comment)
    values (l_new, l_dt, m.organization_id, m.counterparty_id, l_wh, l_pt, l_ship, m.delivery_point_id, m.doc_number, m.doc_date,
            substr('EDI ORDERS № ' || m.doc_number || ' від ' || to_char(m.doc_date, 'DD.MM.YYYY')
                   || case when m.comment_text is not null then '. ' || m.comment_text end, 1, 1000));
    for l in (select * from sys_edi_message_line where message_id = p_id and line_status <> 'ERROR' order by line_no) loop
      l_our := case when l_pt is not null then trade_lines.get_price(l_pt, l.product_id, l_dt) end;
      l_price := coalesce(l_our, round(coalesce(l.price_with_vat, l.price) / l.unit_quantity, 2));
      if l_price is null then
        update sys_edi_message_line set line_status = 'ERROR',
               message = 'Немає ціни: не задано вид цін точки доставки / договору і ціну у файлі.' where id = l.id;
        continue;
      end if;
      if l_our is not null and coalesce(l.price_with_vat, l.price) is not null
         and abs(l_our - coalesce(l.price_with_vat, l.price) / l.unit_quantity) >= 0.01 then
        update sys_edi_message_line set line_status = 'WARNING',
               message = substr(trim(message || ' Ціна мережі ' || xamt(coalesce(l.price_with_vat, l.price) / l.unit_quantity)
                                || ' ≠ ціна за видом цін ' || xamt(l_our) || '.'), 1, 1000) where id = l.id;
      end if;
      l_cnt := l_cnt + 1;
      insert into doc_customer_order_goods (document_id, line_number, product_id, quantity, price)
      values (l_new, l_cnt, l.product_id, l.base_quantity, l_price);
    end loop;
    if l_cnt = 0 then
      fail('EDI_NO_LINES', 'Немає рядків, які можна перенести в замовлення.');
    end if;
    update sys_edi_message set status = 'PROCESSED', customer_order_id = l_new, processed_at = systimestamp,
           processed_by = trade_core.current_user_name,
           error_count = (select count(*) from sys_edi_message_line where message_id = p_id and line_status = 'ERROR')
     where id = p_id;
    trade_core.audit('DocCustomerOrder', l_new, 'CREATE_BASED_ON', 'EDI ORDERS № ' || m.doc_number);
    if p_post = 'Y' then
      trade_r3.post_customer_order(l_new);
    end if;
    return l_new;
  end create_order;

  -- ================================================================ вихідні
  function head_xml (p_org varchar2, p_cp varchar2, p_dp_gln varchar2) return varchar2 is
    l_org varchar2(13); l_cp varchar2(13); l_org_code varchar2(20); l_cp_code varchar2(20);
  begin
    select gln, edrpou into l_org, l_org_code from ref_organization where id = p_org;
    select gln, edrpou into l_cp, l_cp_code from ref_counterparty where id = p_cp;
    if l_org is null then
      fail('EDI_GLN_MISSING', 'Не вказано GLN організації (довідник «Організації»).');
    end if;
    if l_cp is null and p_dp_gln is null then
      fail('EDI_GLN_MISSING', 'Не вказано GLN покупця (довідник «Контрагенти») або точку доставки.');
    end if;
    return tag('SUPPLIER', l_org) || tag('BUYER', coalesce(l_cp, p_dp_gln)) || tag('DELIVERYPLACE', p_dp_gln)
        || tag('SENDER', l_org) || tag('RECIPIENT', coalesce(l_cp, p_dp_gln))
        || tag('SUPPLIERCODE', l_org_code) || tag('BUYERCODE', l_cp_code);
  end head_xml;

  -- зберегти вихідне: перегенерувати не надіслане повідомлення того самого документа, інакше нове
  function save_out (p_type varchar2, p_order varchar2, p_sale varchar2, p_org varchar2, p_cp varchar2, p_dp varchar2,
                     p_number varchar2, p_date date, p_order_number varchar2, p_order_date date, p_delivery date,
                     p_action varchar2, p_lines number, p_total number, p_vat number, p_ref varchar2, p_xml clob) return varchar2 is
    l_id varchar2(32);
    m sys_edi_message%rowtype;
  begin
    select max(id) into l_id from sys_edi_message
     where direction = 'OUT' and msg_type = p_type and status = 'GENERATED'
       and (p_sale is not null and sale_id = p_sale or p_sale is null and customer_order_id = p_order);
    if l_id is null then
      m := new_message('OUT', p_type, 'GENERATED');
      insert into sys_edi_message values m;
      l_id := m.id;
    end if;
    update sys_edi_message
       set customer_order_id = p_order, sale_id = p_sale, organization_id = p_org, counterparty_id = p_cp, delivery_point_id = p_dp,
           doc_number = p_number, doc_date = p_date, order_number = p_order_number, order_date = p_order_date,
           delivery_date = p_delivery, action_code = p_action, line_count = p_lines, total_amount = p_total, vat_amount = p_vat,
           ref_message_id = p_ref, currency_code = 'UAH', payload = p_xml, error_text = null,
           sender_gln = (select gln from ref_organization where id = p_org),
           supplier_gln = (select gln from ref_organization where id = p_org),
           buyer_gln = (select gln from ref_counterparty where id = p_cp),
           recipient_gln = coalesce((select gln from ref_counterparty where id = p_cp), (select gln from ref_delivery_point where id = p_dp)),
           delivery_gln = (select gln from ref_delivery_point where id = p_dp),
           file_name = p_type || '_' || p_number || '_' || to_char(sysdate, 'YYYYMMDDHH24MISS') || '.xml'
     where id = l_id;
    trade_core.audit('EDI', l_id, 'EDI_GENERATE', p_type || ' № ' || p_number);
    return l_id;
  end save_out;

  function ordrsp_from_order (p_order_id in varchar2) return varchar2 is
    o doc_customer_order%rowtype;
    l clob; l_pos clob;
    l_src varchar2(32); l_dp_gln varchar2(13); l_left number; l_acc number; l_n pls_integer := 0;
    l_changed boolean := false; l_any boolean := false; l_action varchar2(3);
    l_ordered_total number := 0; l_price number;
  begin
    select * into o from doc_customer_order where id = p_order_id;
    if o.status <> 'POSTED' then
      fail('EDI_ORDER_NOT_POSTED', 'Підтвердження ORDRSP формується з проведеного замовлення клієнта.');
    end if;
    select max(id) into l_src from sys_edi_message where direction = 'IN' and msg_type = 'ORDERS' and customer_order_id = p_order_id;
    select max(gln) into l_dp_gln from ref_delivery_point where id = o.delivery_point_id;
    dbms_lob.createtemporary(l_pos, true);
    -- позиції замовлення мережі: прийнята кількість — з рядків замовлення (розподіл за товаром)
    for p in (select distinct product_id from doc_customer_order_goods where document_id = p_order_id
              union
              select distinct product_id from sys_edi_message_line where message_id = l_src and product_id is not null) loop
      select coalesce(sum(quantity), 0) into l_left from doc_customer_order_goods where document_id = p_order_id and product_id = p.product_id;
      for x in (select line_no, barcode, buyer_code, supplier_code, description, quantity, unit_code, unit_quantity, base_quantity,
                       price, 'M' src
                  from sys_edi_message_line where message_id = l_src and product_id = p.product_id and line_status <> 'ERROR'
                 order by line_no) loop
        l_acc := least(l_left, x.base_quantity);
        l_left := l_left - l_acc;
        l_n := l_n + 1;
        l_ordered_total := l_ordered_total + x.quantity;
        if l_acc <> x.base_quantity then l_changed := true; end if;
        if l_acc > 0 then l_any := true; end if;
        dbms_lob.append(l_pos, '<POSITION>' || tag('POSITIONNUMBER', x.line_no) || tag('PRODUCT', x.barcode)
          || tag('PRODUCTIDBUYER', x.buyer_code)
          || tag('PRODUCTIDSUPPLIER', coalesce(x.supplier_code, prd_code(p.product_id)))
          || tag('DESCRIPTION', coalesce(x.description, prd_name(p.product_id)))
          || tag('PRICE', xprc(x.price))
          || tag('PRODUCTTYPE', case when l_acc = 0 then '3' when l_acc <> x.base_quantity then '2' else '1' end)
          || tag('ORDRSPUNIT', coalesce(x.unit_code, unit_code(p.product_id)))
          || tag('ORDEREDQUANTITY', xqty(x.quantity)) || tag('ACCEPTEDQUANTITY', xqty(l_acc / x.unit_quantity)) || '</POSITION>');
      end loop;
      if l_left > 0 then   -- додано постачальником (немає в ORDERS)
        select max(price) into l_price from doc_customer_order_goods where document_id = p_order_id and product_id = p.product_id;
        l_n := l_n + 1; l_any := true;
        if l_src is not null then l_changed := true; end if;
        dbms_lob.append(l_pos, '<POSITION>' || tag('POSITIONNUMBER', 900 + l_n) || tag('PRODUCT', product_ean(p.product_id))
          || tag('PRODUCTIDSUPPLIER', prd_code(p.product_id))
          || tag('DESCRIPTION', prd_name(p.product_id))
          || tag('PRICE', xprc(l_price))
          || tag('PRODUCTTYPE', case when l_src is null then '1' else '2' end)
          || tag('ORDRSPUNIT', unit_code(p.product_id))
          || tag('ORDEREDQUANTITY', case when l_src is null then xqty(l_left) else '0' end)
          || tag('ACCEPTEDQUANTITY', xqty(l_left)) || '</POSITION>');
      end if;
    end loop;
    -- рядки ORDERS, не зіставлені з номенклатурою, — відхилено
    for x in (select * from sys_edi_message_line where message_id = l_src and line_status = 'ERROR' order by line_no) loop
      l_n := l_n + 1; l_changed := true;
      dbms_lob.append(l_pos, '<POSITION>' || tag('POSITIONNUMBER', x.line_no) || tag('PRODUCT', x.barcode)
        || tag('PRODUCTIDBUYER', x.buyer_code) || tag('PRODUCTIDSUPPLIER', x.supplier_code) || tag('DESCRIPTION', x.description)
        || tag('PRODUCTTYPE', '3') || tag('ORDRSPUNIT', x.unit_code)
        || tag('ORDEREDQUANTITY', xqty(x.quantity)) || tag('ACCEPTEDQUANTITY', '0') || '</POSITION>');
    end loop;
    l_action := case when not l_any then '27' when l_changed then '4' else '29' end;
    l := '<?xml version="1.0" encoding="UTF-8"?>' || chr(10) || '<ORDRSP>'
      || tag('NUMBER', o.doc_number) || tag('DATE', xdate(sysdate))
      || tag('ORDERNUMBER', coalesce(o.ext_order_number, o.doc_number)) || tag('ORDERDATE', xdate(coalesce(o.ext_order_date, o.occurred_at)))
      || tag('DELIVERYDATE', xdate(coalesce(o.shipment_date, o.occurred_at))) || tag('CURRENCY', o.currency_code)
      || tag('ACTION', l_action) || tag('TOTALAMOUNT', xamt(o.total_amount))
      || '<HEAD>' || head_xml(o.organization_id, o.customer_id, l_dp_gln);
    dbms_lob.append(l, l_pos);
    dbms_lob.append(l, '</HEAD></ORDRSP>');
    return save_out('ORDRSP', p_order_id, null, o.organization_id, o.customer_id, o.delivery_point_id, o.doc_number, sysdate,
                    coalesce(o.ext_order_number, o.doc_number), coalesce(o.ext_order_date, o.occurred_at), o.shipment_date,
                    l_action, l_n, o.total_amount, null, l_src, l);
  end ordrsp_from_order;

  function sale_xml (p_type varchar2, p_sale_id varchar2) return varchar2 is
    s doc_goods_sale%rowtype;
    o doc_customer_order%rowtype;
    l clob; l_dp varchar2(32); l_dp_gln varchar2(13); l_src varchar2(32); l_n pls_integer := 0;
    l_net number := 0; l_vat number := 0; l_gross number := 0; l_ref varchar2(32);
  begin
    select * into s from doc_goods_sale where id = p_sale_id;
    if s.status <> 'POSTED' then
      fail('EDI_SALE_NOT_POSTED', p_type || ' формується з проведеної реалізації товарів.');
    end if;
    if s.base_order_id is not null then
      select * into o from doc_customer_order where id = s.base_order_id;
      l_dp := o.delivery_point_id;
      select max(id) into l_src from sys_edi_message where direction = 'IN' and msg_type = 'ORDERS' and customer_order_id = o.id;
    end if;
    if l_dp is null then   -- єдина точка доставки покупця
      select case when count(*) = 1 then max(id) end into l_dp from ref_delivery_point
       where counterparty_id = s.customer_id and state = 'ACTIVE';
    end if;
    select max(gln) into l_dp_gln from ref_delivery_point where id = l_dp;
    if p_type = 'INVOIC' then
      select max(id) into l_ref from sys_edi_message where direction = 'OUT' and msg_type = 'DESADV' and sale_id = p_sale_id
         and status in ('GENERATED', 'SENT');
    else
      select max(id) into l_ref from sys_edi_message where direction = 'OUT' and msg_type = 'ORDRSP' and customer_order_id = o.id
         and status in ('GENERATED', 'SENT');
    end if;
    l := '<?xml version="1.0" encoding="UTF-8"?>' || chr(10)
      || case p_type when 'DESADV' then '<DESADV>' else '<INVOICE>' || tag('DOCUMENTNAME', '380') end
      || tag('NUMBER', s.doc_number) || tag('DATE', xdate(s.occurred_at)) || tag('DELIVERYDATE', xdate(s.occurred_at))
      || tag('ORDERNUMBER', coalesce(o.ext_order_number, o.doc_number)) || tag('ORDERDATE', xdate(coalesce(o.ext_order_date, o.occurred_at)))
      || tag('DELIVERYNOTENUMBER', s.doc_number) || tag('DELIVERYNOTEDATE', xdate(s.occurred_at))
      || tag('CURRENCY', s.currency_code)
      || case when p_type = 'INVOIC' then tag('PRICEINCLUDESVAT', coalesce(s.price_includes_vat, 'Y')) end
      || '<HEAD>' || head_xml(s.organization_id, s.customer_id, l_dp_gln)
      || case p_type when 'DESADV' then '<PACKINGSEQUENCE>' || tag('HIERARCHICALID', '1') end;
    for g in (select g.line_number, g.product_id, g.quantity, g.price, g.amount, g.vat_amount, g.amount_with_vat,
                     coalesce(r.rate, 0) rate, p.name, coalesce(p.article, p.code) sup_code,
                     (select min(x.buyer_code) from sys_edi_message_line x where x.message_id = l_src and x.product_id = g.product_id) buyer_code,
                     (select sum(c.quantity) from doc_customer_order_goods c where c.document_id = o.id and c.product_id = g.product_id) ordered
                from doc_goods_sale_goods g join ref_product p on p.id = g.product_id
                left join ref_vat_rate r on r.code = g.vat_rate_code
               where g.document_id = p_sale_id order by g.line_number) loop
      l_n := l_n + 1;
      l_net := l_net + (g.amount_with_vat - g.vat_amount); l_vat := l_vat + g.vat_amount; l_gross := l_gross + g.amount_with_vat;
      if p_type = 'DESADV' then
        dbms_lob.append(l, '<POSITION>' || tag('POSITIONNUMBER', l_n) || tag('PRODUCT', product_ean(g.product_id))
          || tag('PRODUCTIDBUYER', g.buyer_code) || tag('PRODUCTIDSUPPLIER', g.sup_code) || tag('DESCRIPTION', g.name)
          || tag('DELIVEREDQUANTITY', xqty(g.quantity)) || tag('DELIVEREDUNIT', unit_code(g.product_id))
          || tag('ORDEREDQUANTITY', xqty(g.ordered))
          || tag('PRICE', xprc(round((g.amount_with_vat - g.vat_amount) / g.quantity, 4)))
          || tag('PRICEWITHVAT', xprc(round(g.amount_with_vat / g.quantity, 4))) || tag('TAXRATE', xqty(g.rate)) || '</POSITION>');
      else
        dbms_lob.append(l, '<POSITION>' || tag('POSITIONNUMBER', l_n) || tag('PRODUCT', product_ean(g.product_id))
          || tag('PRODUCTIDBUYER', g.buyer_code) || tag('PRODUCTIDSUPPLIER', g.sup_code) || tag('DESCRIPTION', g.name)
          || tag('INVOICEDQUANTITY', xqty(g.quantity)) || tag('UNIT', unit_code(g.product_id))
          || tag('UNITPRICE', xprc(round((g.amount_with_vat - g.vat_amount) / g.quantity, 4)))
          || tag('TAXRATE', xqty(g.rate))
          || tag('AMOUNT', xamt(g.amount_with_vat - g.vat_amount)) || tag('TAXAMOUNT', xamt(g.vat_amount))
          || tag('AMOUNTWITHVAT', xamt(g.amount_with_vat)) || '</POSITION>');
      end if;
    end loop;
    if l_n = 0 then
      fail('EDI_NO_LINES', 'У реалізації немає товарів.');
    end if;
    dbms_lob.append(l, case p_type when 'DESADV' then '</PACKINGSEQUENCE>' end || '</HEAD>'
      || case p_type when 'INVOIC' then '<SUMMARY>' || tag('TOTALLINES', l_n) || tag('AMOUNT', xamt(l_net))
                                        || tag('TAXAMOUNT', xamt(l_vat)) || tag('AMOUNTWITHVAT', xamt(l_gross)) || '</SUMMARY>' end
      || case p_type when 'DESADV' then '</DESADV>' else '</INVOICE>' end);
    return save_out(p_type, s.base_order_id, p_sale_id, s.organization_id, s.customer_id, l_dp, s.doc_number, s.occurred_at,
                    coalesce(o.ext_order_number, o.doc_number), coalesce(o.ext_order_date, o.occurred_at), s.occurred_at,
                    null, l_n, l_gross, l_vat, l_ref, l);
  end sale_xml;

  function desadv_from_sale (p_sale_id in varchar2) return varchar2 is
  begin return sale_xml('DESADV', p_sale_id); end;

  function invoic_from_sale (p_sale_id in varchar2) return varchar2 is
  begin return sale_xml('INVOIC', p_sale_id); end;

  -- ================================================================ транспорт
  procedure stub_send (p_id in varchar2, p_ext_id out varchar2) is
    l_len number;
  begin
    -- Імітація провайдера: перевіряє XML і повертає ідентифікатор; до зовнішніх сервісів нічого не передається.
    select dbms_lob.getlength(payload) into l_len from sys_edi_message where id = p_id;
    if l_len is null or l_len = 0 then
      fail('EDI_PROVIDER_REJECTED', 'Провайдер відхилив порожнє повідомлення.');
    end if;
    p_ext_id := 'STUB-' || to_char(systimestamp, 'YYYYMMDDHH24MISSFF3') || '-' || substr(p_id, 1, 6);
  end stub_send;

  procedure send (p_id in varchar2, p_provider in varchar2 default null) is
    m sys_edi_message%rowtype;
    l_prov sys_edi_provider%rowtype;
    l_ext varchar2(100);
  begin
    select * into m from sys_edi_message where id = p_id for update;
    if m.direction <> 'OUT' then
      fail('EDI_NOT_OUTGOING', 'Надіслати можна лише вихідне повідомлення.');
    end if;
    if m.status <> 'GENERATED' then
      fail('EDI_NOT_GENERATED', 'Повідомлення вже надіслано або скасовано.');
    end if;
    begin
      select * into l_prov from sys_edi_provider where code = coalesce(p_provider, default_provider);
    exception when no_data_found then
      fail('EDI_PROVIDER_UNKNOWN', 'Провайдера EDI не налаштовано.');
    end;
    if l_prov.send_procedure is not null then
      execute immediate 'begin ' || dbms_assert.qualified_sql_name(l_prov.send_procedure) || '(:id, :ext); end;'
        using in p_id, out l_ext;
    end if;
    update sys_edi_message set status = 'SENT', provider_code = l_prov.code, ext_id = l_ext, sent_at = systimestamp,
           sent_by = trade_core.current_user_name where id = p_id;
    trade_core.audit('EDI', p_id, 'EDI_SEND', l_prov.code || case when l_ext is not null then ' ' || l_ext end);
  end send;

  procedure cancel (p_id in varchar2) is
    l_status varchar2(10);
  begin
    select status into l_status from sys_edi_message where id = p_id for update;
    if l_status not in ('NEW', 'ERROR', 'GENERATED') then
      fail('EDI_NOT_CANCELLABLE', 'Скасувати можна лише нове, помилкове або сформоване (не надіслане) повідомлення.');
    end if;
    update sys_edi_message set status = 'CANCELLED', processed_at = systimestamp, processed_by = trade_core.current_user_name
     where id = p_id;
    trade_core.audit('EDI', p_id, 'EDI_CANCEL');
  end cancel;

  function file_name_of (p_id in varchar2) return varchar2 is
    l varchar2(400);
  begin
    select coalesce(file_name, msg_type || '_' || msg_no || '.xml') into l from sys_edi_message where id = p_id;
    return l;
  end file_name_of;

  procedure download (p_id in varchar2) is
    l clob; l_pos number := 1;
  begin
    select payload into l from sys_edi_message where id = p_id;
    trade_core.audit('EDI', p_id, 'PRINT', 'EDI_XML');
    sys.htp.init;
    sys.owa_util.mime_header('application/xml', false, 'UTF-8');
    sys.htp.p('Content-Disposition: attachment; filename="' || replace(file_name_of(p_id), '"') || '"');
    sys.owa_util.http_header_close;
    while l_pos <= dbms_lob.getlength(l) loop
      sys.htp.prn(dbms_lob.substr(l, 8000, l_pos));
      l_pos := l_pos + 8000;
    end loop;
    apex_application.stop_apex_engine;
  end download;

  -- ================================================================ HTML
  function href_ (p_page number, p_item varchar2, p_id varchar2, p_text varchar2) return varchar2 is
  begin
    if p_id is null then return h(p_text); end if;
    if v('APP_ID') is null then return h(p_text); end if;
    return '<a href="' || apex_page.get_url(p_page => p_page, p_items => p_item, p_values => p_id) || '">' || h(p_text) || '</a>';
  end href_;

  function message_html (p_id in varchar2) return clob is
    l clob;
    procedure row_ (p_label varchar2, p_html varchar2) is
    begin
      if p_html is not null then
        dbms_lob.append(l, '<tr><th class="t-Report-colHead" style="text-align:left;width:220px">' || h(p_label) || '</th><td class="t-Report-cell">'
                           || p_html || '</td></tr>');
      end if;
    end;
    function gln_ (p_gln varchar2, p_name varchar2) return varchar2 is
    begin
      if p_gln is null then return null; end if;
      return h(p_gln) || case when p_name is not null then ' — ' || h(p_name) else ' <span class="u-danger-text">(не зіставлено)</span>' end;
    end;
  begin
    if p_id is null then return null; end if;
    for m in (select e.*, o.name org_name, c.name cp_name, d.name dp_name, d.address dp_address,
                     co.doc_number order_no, s.doc_number sale_no, r.msg_type ref_type, r.msg_no ref_no, pr.name provider_name
                from sys_edi_message e
                left join ref_organization o on o.id = e.organization_id
                left join ref_counterparty c on c.id = e.counterparty_id
                left join ref_delivery_point d on d.id = e.delivery_point_id
                left join doc_customer_order co on co.id = e.customer_order_id
                left join doc_goods_sale s on s.id = e.sale_id
                left join sys_edi_message r on r.id = e.ref_message_id
                left join sys_edi_provider pr on pr.code = e.provider_code
               where e.id = p_id) loop
      l := '<table class="t-Report-report" style="width:auto;margin-bottom:12px">';
      row_('Повідомлення', h('№ ' || m.msg_no || ' · ' || direction_name(m.direction) || ' · ' || type_name(m.msg_type)));
      row_('Стан', '<b>' || h(status_name(m.status)) || '</b>'
                   || case when m.error_count > 0 then ' · помилок: ' || m.error_count end
                   || case when m.msg_type = 'RECADV' then ' · розбіжностей з реалізацією: ' || m.diff_count end);
      row_('Документ', h('№ ' || m.doc_number || case when m.doc_date is not null then ' від ' || to_char(m.doc_date, 'DD.MM.YYYY') end));
      if m.order_number is not null and (m.msg_type <> 'ORDERS' or m.order_number <> m.doc_number) then
        row_('Замовлення мережі', h('№ ' || m.order_number || case when m.order_date is not null then ' від ' || to_char(m.order_date, 'DD.MM.YYYY') end));
      end if;
      row_('Дата поставки', case when m.delivery_date is not null then to_char(m.delivery_date, 'DD.MM.YYYY') end);
      row_('DESADV / накладна', h(m.desadv_number));
      row_('Постачальник (GLN)', gln_(m.supplier_gln, m.org_name));
      row_('Покупець (GLN)', gln_(coalesce(m.buyer_gln, case when m.direction = 'IN' then m.sender_gln end), m.cp_name));
      if m.buyer_gln is null and m.cp_name is not null and m.direction = 'IN' and m.sender_gln is null then
        row_('Покупець', h(m.cp_name));
      end if;
      row_('Точка доставки (GLN)', gln_(m.delivery_gln, m.dp_name || case when m.dp_address is not null then ', ' || m.dp_address end));
      row_('Замовлення клієнта', case when m.customer_order_id is not null then href_(261, 'P261_ID', m.customer_order_id, '№ ' || m.order_no) end);
      row_('Реалізація товарів', case when m.sale_id is not null then href_(111, 'P111_ID', m.sale_id, '№ ' || m.sale_no) end);
      row_('Пов''язане повідомлення', case when m.ref_message_id is not null then href_(700, 'P700_ID', m.ref_message_id, m.ref_type || ' № ' || m.ref_no) end);
      row_('Відповідь', case m.action_code when '29' then '29 — прийнято без змін' when '4' then '4 — прийнято зі змінами'
                                          when '27' then '27 — відхилено' end);
      row_('Сума', case when m.total_amount is not null then to_char(m.total_amount, 'FM999G999G999G990D00')
                        || case when m.vat_amount is not null then ' (у т. ч. ПДВ ' || to_char(m.vat_amount, 'FM999G999G999G990D00') || ')' end end);
      row_('Коментар', h(m.comment_text));
      row_('Файл', h(m.file_name));
      row_('Надіслано', case when m.sent_at is not null then to_char(m.sent_at, 'DD.MM.YYYY HH24:MI') || ' · ' || h(m.provider_name)
                             || case when m.ext_id is not null then ' · ' || h(m.ext_id) end end);
      row_('Створено', to_char(m.created_at, 'DD.MM.YYYY HH24:MI') || ' · ' || h(m.created_by));
      if m.error_text is not null then
        row_('Помилки', '<span class="u-danger-text">' || replace(h(m.error_text), chr(10), '<br>') || '</span>');
      end if;
      dbms_lob.append(l, '</table>');
      -- рядки вхідного повідомлення
      if m.direction = 'IN' and m.line_count > 0 then
        dbms_lob.append(l, '<table class="t-Report-report" style="width:auto;margin-bottom:12px"><tr>'
          || '<th class="t-Report-colHead">№</th><th class="t-Report-colHead">Штрихкод</th><th class="t-Report-colHead">Код покупця</th>'
          || '<th class="t-Report-colHead">Код постачальника</th><th class="t-Report-colHead">Опис у файлі</th>'
          || '<th class="t-Report-colHead">' || case m.msg_type when 'RECADV' then 'Поставлено' else 'Кількість' end || '</th>'
          || case m.msg_type when 'RECADV' then '<th class="t-Report-colHead">Прийнято</th>' end
          || '<th class="t-Report-colHead">Од.</th><th class="t-Report-colHead">Ціна</th><th class="t-Report-colHead">Товар</th>'
          || '<th class="t-Report-colHead">Кількість товару</th><th class="t-Report-colHead">Стан</th></tr>');
        for x in (select x.*, p.name product_name from sys_edi_message_line x left join ref_product p on p.id = x.product_id
                   where x.message_id = p_id order by x.line_no) loop
          dbms_lob.append(l, '<tr><td class="t-Report-cell">' || x.line_no || '</td><td class="t-Report-cell">' || h(x.barcode)
            || '</td><td class="t-Report-cell">' || h(x.buyer_code) || '</td><td class="t-Report-cell">' || h(x.supplier_code)
            || '</td><td class="t-Report-cell">' || h(x.description) || '</td><td class="t-Report-cell" style="text-align:right">'
            || qh(x.quantity) || '</td>'
            || case m.msg_type when 'RECADV' then '<td class="t-Report-cell" style="text-align:right">'
                    || qh(x.accepted_qty) || '</td>' end
            || '<td class="t-Report-cell">' || h(x.unit_code) || '</td><td class="t-Report-cell" style="text-align:right">'
            || to_char(coalesce(x.price_with_vat, x.price), 'FM999G999G990D00') || '</td><td class="t-Report-cell">'
            || h(x.product_name) || '</td><td class="t-Report-cell" style="text-align:right">'
            || qh(x.base_quantity) || '</td><td class="t-Report-cell">'
            || case x.line_status when 'ERROR' then '<span class="u-danger-text">Помилка</span>' when 'WARNING' then '<span class="u-warning-text">Увага</span>'
                                  else 'OK' end
            || case when x.message is not null then ': ' || h(x.message) end || '</td></tr>');
        end loop;
        dbms_lob.append(l, '</table>');
      end if;
      -- RECADV: звірка з реалізацією
      if m.msg_type = 'RECADV' and m.sale_id is not null then
        dbms_lob.append(l, '<h4>Звірка з реалізацією № ' || h(m.sale_no) || '</h4><table class="t-Report-report" style="width:auto;margin-bottom:12px"><tr>'
          || '<th class="t-Report-colHead">Товар</th><th class="t-Report-colHead">Відвантажено</th><th class="t-Report-colHead">Прийнято мережею</th>'
          || '<th class="t-Report-colHead">Різниця</th></tr>');
        for d in (select p.name, sum(q_sale) q_sale, sum(q_acc) q_acc
                    from (select product_id, quantity q_sale, 0 q_acc from doc_goods_sale_goods where document_id = m.sale_id
                          union all
                          select product_id, 0, base_quantity from sys_edi_message_line where message_id = p_id and product_id is not null) t
                    join ref_product p on p.id = t.product_id
                   group by p.name order by p.name) loop
          dbms_lob.append(l, '<tr><td class="t-Report-cell">' || h(d.name) || '</td><td class="t-Report-cell" style="text-align:right">'
            || qh(d.q_sale) || '</td><td class="t-Report-cell" style="text-align:right">'
            || qh(d.q_acc) || '</td><td class="t-Report-cell" style="text-align:right">'
            || case when d.q_acc <> d.q_sale then '<b class="u-danger-text">' || qh(d.q_acc - d.q_sale) || '</b>' else '—' end
            || '</td></tr>');
        end loop;
        dbms_lob.append(l, '</table>');
      end if;
      dbms_lob.append(l, '<details><summary>XML (' || h(c_format) || ')</summary><pre style="white-space:pre-wrap;max-height:400px;overflow:auto">'
                         || h(dbms_lob.substr(regexp_replace(dbms_lob.substr(m.payload, 30000, 1), '><', '>' || chr(10) || '<'), 30000, 1))
                         || '</pre></details>');
    end loop;
    return l;
  end message_html;

  -- ================================================================ демо / тестові файли
  function sample_orders_xml (p_number in varchar2 default null, p_delivery_gln in varchar2 default null) return clob is
    l_org varchar2(13); l_dp varchar2(13); l_cp varchar2(13);
    l clob;
  begin
    select max(gln) into l_org from ref_organization where gln is not null and state = 'ACTIVE' and is_default = 'Y';
    if l_org is null then
      select max(gln) into l_org from ref_organization where gln is not null and state = 'ACTIVE';
    end if;
    select max(d.gln), max(c.gln) into l_dp, l_cp
      from ref_delivery_point d join ref_counterparty c on c.id = d.counterparty_id
     where d.gln = coalesce(p_delivery_gln, (select min(gln) from ref_delivery_point where state = 'ACTIVE'));
    l := '<?xml version="1.0" encoding="UTF-8"?>' || chr(10) || '<ORDER>' || tag('DOCUMENTNAME', '220')
      || tag('NUMBER', coalesce(p_number, 'PO-' || to_char(sysdate, 'YYMMDDHH24MISS'))) || tag('DATE', xdate(sysdate))
      || tag('DELIVERYDATE', xdate(trunc(sysdate) + 2)) || tag('CURRENCY', 'UAH') || tag('INFO', 'Демо-замовлення мережі')
      || '<HEAD>' || tag('SUPPLIER', l_org) || tag('BUYER', l_cp) || tag('DELIVERYPLACE', l_dp) || tag('SENDER', l_cp)
      || tag('RECIPIENT', l_org)
      || '<POSITION><POSITIONNUMBER>1</POSITIONNUMBER><PRODUCT>4820001000016</PRODUCT><PRODUCTIDBUYER>100501</PRODUCTIDBUYER>'
      || '<DESCRIPTION>Цукор білий 1 кг</DESCRIPTION><ORDEREDQUANTITY>10</ORDEREDQUANTITY><ORDERUNIT>PCE</ORDERUNIT>'
      || '<ORDERPRICE>32.50</ORDERPRICE><VAT>20</VAT></POSITION>'
      || '<POSITION><POSITIONNUMBER>2</POSITIONNUMBER><PRODUCT>4820001000108</PRODUCT><PRODUCTIDBUYER>100502</PRODUCTIDBUYER>'
      || '<DESCRIPTION>Цукор білий, ящик 10 шт</DESCRIPTION><ORDEREDQUANTITY>2</ORDEREDQUANTITY><ORDERUNIT>PA</ORDERUNIT>'
      || '<ORDERPRICE>325.00</ORDERPRICE><VAT>20</VAT></POSITION>'
      || '<POSITION><POSITIONNUMBER>3</POSITIONNUMBER><PRODUCTIDBUYER>100733</PRODUCTIDBUYER><PRODUCTIDSUPPLIER>OL-001</PRODUCTIDSUPPLIER>'
      || '<DESCRIPTION>Олія соняшникова 0,9 л</DESCRIPTION><ORDEREDQUANTITY>5</ORDEREDQUANTITY><ORDERUNIT>PCE</ORDERUNIT>'
      || '<VAT>20</VAT></POSITION>'
      || '</HEAD></ORDER>';
    return l;
  end sample_orders_xml;

  function sample_recadv_xml (p_desadv_id in varchar2, p_short in number default 0) return clob is
    m sys_edi_message%rowtype;
    l clob; l_first boolean := true; x xmltype;
  begin
    select * into m from sys_edi_message where id = p_desadv_id;
    if m.msg_type <> 'DESADV' then
      fail('EDI_NOT_DESADV', 'Приклад RECADV формується з вихідного DESADV.');
    end if;
    x := xmltype(m.payload);
    l := '<?xml version="1.0" encoding="UTF-8"?>' || chr(10) || '<RECADV>' || tag('NUMBER', 'RA-' || m.doc_number)
      || tag('DATE', xdate(sysdate)) || tag('RECEPTIONDATE', xdate(sysdate)) || tag('ORDERNUMBER', m.order_number)
      || tag('DESADVNUMBER', m.doc_number)
      || '<HEAD>' || tag('SUPPLIER', m.supplier_gln) || tag('BUYER', m.buyer_gln) || tag('DELIVERYPLACE', m.delivery_gln)
      || tag('SENDER', m.buyer_gln) || tag('RECIPIENT', m.supplier_gln);
    for r in (select * from xmltable('//POSITION' passing x columns posno varchar2(20) path 'POSITIONNUMBER',
                                     ean varchar2(64) path 'PRODUCT', sup varchar2(64) path 'PRODUCTIDSUPPLIER',
                                     descr varchar2(500) path 'DESCRIPTION', qty varchar2(40) path 'DELIVEREDQUANTITY',
                                     price varchar2(40) path 'PRICE')) loop
      dbms_lob.append(l, '<POSITION>' || tag('POSITIONNUMBER', r.posno) || tag('PRODUCT', r.ean) || tag('PRODUCTIDSUPPLIER', r.sup)
        || tag('DESCRIPTION', r.descr) || tag('DELIVERQUANTITY', r.qty)
        || tag('ACCEPTEDQUANTITY', xqty(to_num(r.qty) - case when l_first then nvl(p_short, 0) else 0 end))
        || tag('PRICE', r.price) || '</POSITION>');
      l_first := false;
    end loop;
    dbms_lob.append(l, '</HEAD></RECADV>');
    return l;
  end sample_recadv_xml;

  function load_sample (p_kind in varchar2 default 'ORDERS', p_base_id in varchar2 default null) return varchar2 is
    l_id varchar2(32);
  begin
    if p_kind = 'RECADV' then
      select max(id) keep (dense_rank last order by created_at) into l_id from sys_edi_message
       where msg_type = 'DESADV' and direction = 'OUT' and status in ('GENERATED', 'SENT')
         and (p_base_id is null or id = p_base_id or sale_id = p_base_id);
      if l_id is null then
        fail('EDI_NO_DESADV', 'Немає вихідного DESADV, для якого можна сформувати приклад RECADV.');
      end if;
      return load_xml('RECADV_demo.xml', sample_recadv_xml(l_id, 1));
    end if;
    return load_xml('ORDERS_demo.xml', sample_orders_xml);
  end load_sample;

end trade_edi;
/

-- ---------------------------------------------------------------- тригери
create or replace trigger ref_delivery_point_biu
before insert or update on ref_delivery_point for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_DELIVERY_POINT_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.gln := trade_edi.normalize_gln(:new.gln);
  :new.address := trim(:new.address);
  :new.note := trim(:new.note);
  trade_edi.check_delivery_point(:new.id, :new.counterparty_id, :new.gln, :new.warehouse_id, :new.price_type_id);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_delivery_point_bd before delete on ref_delivery_point
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/
create or replace trigger ref_organization_gln_biu
before insert or update of gln on ref_organization for each row
declare
  l_n number;
begin
  :new.gln := trade_edi.normalize_gln(:new.gln);
  trade_edi.check_gln(:new.gln, 'Організація');
  if :new.gln is not null then
    select count(*) into l_n from ref_delivery_point where gln = :new.gln;
    select count(*) + l_n into l_n from ref_counterparty where gln = :new.gln;
    if l_n > 0 then
      trade_nsi.fail('GLN_DUPLICATE', 'GLN ' || :new.gln || ' уже вказано в контрагента або точки доставки.');
    end if;
  end if;
end;
/
create or replace trigger ref_counterparty_gln_biu
before insert or update of gln on ref_counterparty for each row
declare
  l_n number;
begin
  :new.gln := trade_edi.normalize_gln(:new.gln);
  trade_edi.check_gln(:new.gln, 'Контрагент');
  if :new.gln is not null then
    select count(*) into l_n from ref_delivery_point where gln = :new.gln and counterparty_id <> :new.id;
    select count(*) + l_n into l_n from ref_organization where gln = :new.gln;
    if l_n > 0 then
      trade_nsi.fail('GLN_DUPLICATE', 'GLN ' || :new.gln || ' уже вказано в організації або точки доставки іншого контрагента.');
    end if;
  end if;
end;
/
create or replace trigger doc_customer_order_edi_biu
before insert or update of delivery_point_id, customer_id, ext_order_number on doc_customer_order for each row
declare
  l_cp varchar2(32);
begin
  :new.ext_order_number := trim(:new.ext_order_number);
  if :new.delivery_point_id is not null then
    select max(counterparty_id) into l_cp from ref_delivery_point where id = :new.delivery_point_id;
    if l_cp is null or l_cp <> :new.customer_id then
      trade_nsi.fail('DELIVERY_POINT_CUSTOMER', 'Точка доставки належить іншому контрагенту.');
    end if;
    if inserting or :new.delivery_point_id <> nvl(:old.delivery_point_id, '-') then
      trade_core.check_active_ref('REF_DELIVERY_POINT', :new.delivery_point_id, 'Точка доставки');
    end if;
  end if;
end;
/

-- ---------------------------------------------------------------- представлення
create or replace view v_delivery_point_list as
select d.id, d.code, d.name, d.gln, d.address, d.counterparty_id, c.name counterparty_name, c.gln counterparty_gln,
       w.name warehouse_name, t.name price_type_name, d.note, d.state
  from ref_delivery_point d
  join ref_counterparty c on c.id = d.counterparty_id
  left join ref_warehouse w on w.id = d.warehouse_id
  left join ref_price_type t on t.id = d.price_type_id;

create or replace view v_edi_message as
select e.id, e.msg_no, e.direction, trade_edi.direction_name(e.direction) direction_name, e.msg_type,
       trade_edi.type_name(e.msg_type) type_name, e.status, trade_edi.status_name(e.status) status_name,
       e.doc_number, e.doc_date, e.order_number, e.delivery_date, e.counterparty_id, c.name counterparty_name,
       d.name delivery_point_name, e.delivery_gln, e.organization_id, o.name organization_name,
       e.customer_order_id, co.doc_number customer_order_number, e.sale_id, s.doc_number sale_number,
       e.line_count, e.error_count, e.diff_count, e.total_amount, e.file_name, e.provider_code, e.ext_id, e.sent_at,
       cast(e.created_at as date) created_at, e.created_by,
       case e.status when 'ERROR' then 'fa-exclamation-triangle u-danger-text' when 'NEW' then 'fa-envelope-o'
                     when 'PROCESSED' then 'fa-check u-success-text' when 'GENERATED' then 'fa-file-code-o'
                     when 'SENT' then 'fa-paper-plane u-success-text' else 'fa-ban' end icon_class
  from sys_edi_message e
  left join ref_counterparty c on c.id = e.counterparty_id
  left join ref_delivery_point d on d.id = e.delivery_point_id
  left join ref_organization o on o.id = e.organization_id
  left join doc_customer_order co on co.id = e.customer_order_id
  left join doc_goods_sale s on s.id = e.sale_id;

-- ---------------------------------------------------------------- провайдери, демо, меню
merge into sys_edi_provider t
using (select 'STUB' code, 'Імітація провайдера EDI (без зовнішніх викликів)' name, 'trade_edi.stub_send' send_procedure, 'Y' is_default,
              'Перевіряє повідомлення й повертає умовний ідентифікатор. Адаптер реального провайдера (EDIN, Вчасно.EDI, M.E.Doc) — '
              || 'процедура з тією самою сигнатурою (p_id in, p_ext_id out).' note from dual
       union all
       select 'FILE', 'Файловий обмін (вивантажити XML і передати вручну)', null, 'N',
              'Надсилання лише позначає повідомлення надісланим; файл вивантажується кнопкою «Вивантажити XML».' from dual) s
on (t.code = s.code)
when matched then update set t.name = s.name, t.send_procedure = s.send_procedure, t.note = s.note
when not matched then insert (code, name, send_procedure, is_default, note) values (s.code, s.name, s.send_procedure, s.is_default, s.note);
commit;

declare
  l_cp varchar2(32); l_wh varchar2(32); l_wh2 varchar2(32); l_pt varchar2(32); l_n number; l_id varchar2(32);
begin
  update ref_organization set gln = trade_edi.gln_with_check('482000100000') where code = '000000002' and gln is null;
  select max(id) into l_cp from ref_counterparty where name = 'ТОВ «Магазин Колосок»';
  if l_cp is not null then
    update ref_counterparty set gln = trade_edi.gln_with_check('482000500000') where id = l_cp and gln is null;
    select min(id) keep (dense_rank first order by code) into l_wh from ref_warehouse where state = 'ACTIVE';
    select coalesce(max(id), l_wh) into l_wh2 from ref_warehouse where code = '000000002' and state = 'ACTIVE';
    select max(id) into l_pt from ref_price_type where code = '000000002' and state = 'ACTIVE';
    merge into ref_delivery_point t
    using (select 'Колосок — магазин №1 (Київ, вул. Хрещатик, 10)' name, trade_edi.gln_with_check('482000500001') gln,
                  'м. Київ, вул. Хрещатик, 10' address, l_wh wh from dual
           union all
           select 'Колосок — РЦ Бровари', trade_edi.gln_with_check('482000500002'), 'м. Бровари, вул. Металургів, 2', l_wh2 from dual) s
    on (t.gln = s.gln)
    when not matched then insert (name, counterparty_id, gln, address, warehouse_id, price_type_id)
      values (s.name, l_cp, s.gln, s.address, s.wh, l_pt);
    select count(*) into l_n from sys_edi_message where file_name = 'ORDERS_demo.xml';
    if l_n = 0 then
      l_id := trade_edi.load_xml('ORDERS_demo.xml', trade_edi.sample_orders_xml('PO-DEMO-0001'));
    end if;
    select count(*) into l_n from sys_edi_message where file_name = 'ORDERS_demo2.xml';
    if l_n = 0 then
      -- друге демо-замовлення мережі: оброблене → проведене замовлення клієнта → ORDRSP (сформовано, не надіслано)
      l_id := trade_edi.load_xml('ORDERS_demo2.xml', trade_edi.sample_orders_xml('PO-DEMO-0002',
                                                                                 trade_edi.gln_with_check('482000500002')));
      l_id := trade_edi.create_order(l_id);
      trade_r3.post_customer_order(l_id);
      l_id := trade_edi.ordrsp_from_order(l_id);
    end if;
  end if;
  commit;
exception when others then
  rollback;
  dbms_output.put_line('Демо EDI не створено: ' || sqlerrm);
end;
/

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
  obj('RefDeliveryPoint', 'CATALOG', 'Catalogs', 'Точки доставки (GLN)', 710, 711, 120, 'Роль: продажі');
  obj('EdiExchange',      'REPORT',  'Reports',  'EDI: обмін з торговими мережами', 700, null, 280, 'Роль: продажі');
  fp('Sales', 'EDI', 2, 40, 'EdiExchange', 10, 'Y');
  fp('Sales', 'EDI', 2, 40, 'RefDeliveryPoint', 20);
  fp('Sales', 'НСІ', 3, 10, 'RefDeliveryPoint', 60);
  commit;
end;
/
