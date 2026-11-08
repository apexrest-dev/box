-- =============================================================================
-- Trade r4 — F-FIN-05 «Коригування боргу / взаємозалік». Паспорт DocDebtAdjustment (PROPOSED).
--   * документ doc_debt_adjustment (шапковий, одна сума), види операцій:
--       OFFSET               взаємозалік дебіторки й кредиторки одного контрагента;
--       WRITE_OFF_RECEIVABLE списання безнадійної дебіторської заборгованості;
--       WRITE_OFF_PAYABLE    списання кредиторської заборгованості (строк позовної давності);
--       TRANSFER_RECEIVABLE  перенесення дебіторки на інший договір / іншого контрагента;
--       TRANSFER_PAYABLE     перенесення кредиторки на інший договір / іншого контрагента;
--   * проведення (пакет trade_debt_adj): рухи RegCounterpartySettlement з організацією документа;
--     контроль: сума заліку ≤ min(дебіторка, кредиторка) на дату документа, сума списання /
--     перенесення ≤ заборгованості відповідного напрямку; від'ємна заборгованість заборонена;
--   * друк: акт взаємозаліку / коригування (DEBT_ADJ через trade_print.document_html);
--     акт звірки взаєморозрахунків (trade_debt_adj.reconciliation_html, сторінка 420);
--   * меню «Фінанси → Взаєморозрахунки», v_recorder (+ коригування боргу).
-- Потребує 24 (trade_org), 28, 29 (v_recorder). Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено (усі реєстратори r1–r4).
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  ddl('create sequence doc_debt_adjustment_num_seq nocache');
  ddl(q'[create table doc_debt_adjustment (
    id                     varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number             varchar2(9)    not null,
    occurred_at            date           default on null sysdate not null,
    organization_id        varchar2(32)   not null,
    operation_kind         varchar2(30)   default on null 'OFFSET' not null,
    counterparty_id        varchar2(32)   not null,
    contract_id            varchar2(32),
    target_counterparty_id varchar2(32),
    target_contract_id     varchar2(32),
    currency_code          varchar2(3)    default on null 'UAH' not null,
    amount                 number(19,2)   not null,
    reason                 varchar2(500),
    doc_comment            varchar2(1000),
    status                 varchar2(10)   default on null 'DRAFT' not null,
    version                number(19)     default on null 0 not null,
    created_at             timestamp      not null,
    created_by             varchar2(255)  not null,
    updated_at             timestamp      not null,
    updated_by             varchar2(255)  not null,
    constraint doc_debt_adjustment_pk primary key (id),
    constraint doc_debt_adjustment_num_uk unique (doc_number),
    constraint doc_debt_adjustment_status_ck check (status in ('DRAFT','POSTED')),
    constraint doc_debt_adjustment_op_ck check (operation_kind in
      ('OFFSET','WRITE_OFF_RECEIVABLE','WRITE_OFF_PAYABLE','TRANSFER_RECEIVABLE','TRANSFER_PAYABLE')),
    constraint doc_debt_adjustment_amt_ck check (amount > 0),
    constraint doc_debt_adjustment_cur_ck check (currency_code = 'UAH'),
    constraint doc_debt_adjustment_org_fk foreign key (organization_id) references ref_organization (id),
    constraint doc_debt_adjustment_cp_fk foreign key (counterparty_id) references ref_counterparty (id),
    constraint doc_debt_adjustment_ctr_fk foreign key (contract_id) references ref_contract (id),
    constraint doc_debt_adjustment_tcp_fk foreign key (target_counterparty_id) references ref_counterparty (id),
    constraint doc_debt_adjustment_tctr_fk foreign key (target_contract_id) references ref_contract (id))]');
  ddl('create index doc_debt_adjustment_date_ix on doc_debt_adjustment (occurred_at)');
  ddl('create index doc_debt_adjustment_cp_ix on doc_debt_adjustment (counterparty_id)');
  ddl('create index doc_debt_adjustment_tcp_ix on doc_debt_adjustment (target_counterparty_id)');
end;
/

create or replace package trade_debt_adj as
  c_type constant varchar2(60) := 'DocDebtAdjustment';

  function operation_name (p_op in varchar2) return varchar2;

  -- Перевірка й доповнення шапки (тригер doc_debt_adjustment)
  procedure check_header (p_inserting in boolean, p_op in varchar2, p_date in date, p_org in out varchar2,
                          p_cp in varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                          p_target_cp in out varchar2, p_old_target_cp in varchar2, p_target_contract in out varchar2,
                          p_amount in number, p_reason in out varchar2);

  procedure post   (p_id in varchar2);
  procedure unpost (p_id in varchar2);
  function  copy   (p_id in varchar2) return varchar2;

  -- Заборгованість контрагента за організацією й напрямом на момент (включно); UAH
  function debt_at (p_org in varchar2, p_cp in varchar2, p_direction in varchar2, p_date in date default null) return number;
  -- Сальдо розрахунків з погляду організації: дебіторка − кредиторка (додатне — винен контрагент)
  function saldo_at (p_org in varchar2, p_cp in varchar2, p_date in date default null) return number;

  -- Друк: DEBT_ADJ — акт взаємозаліку / коригування заборгованості
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
  -- Акт звірки взаємних розрахунків організації з контрагентом за період
  function reconciliation_html (p_org in varchar2, p_cp in varchar2, p_from in date, p_to in date) return clob;
end trade_debt_adj;
/

create or replace package body trade_debt_adj as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function dt (p date) return varchar2 is begin return to_char(p, 'DD.MM.YYYY'); end;

  function operation_name (p_op in varchar2) return varchar2 is
  begin
    return case p_op
      when 'OFFSET'               then 'Взаємозалік заборгованостей'
      when 'WRITE_OFF_RECEIVABLE' then 'Списання дебіторської заборгованості'
      when 'WRITE_OFF_PAYABLE'    then 'Списання кредиторської заборгованості'
      when 'TRANSFER_RECEIVABLE'  then 'Перенесення дебіторської заборгованості'
      when 'TRANSFER_PAYABLE'     then 'Перенесення кредиторської заборгованості' end;
  end operation_name;

  function direction_of (p_op varchar2) return varchar2 is
  begin
    return case when p_op in ('WRITE_OFF_RECEIVABLE', 'TRANSFER_RECEIVABLE') then 'RECEIVABLE'
                when p_op in ('WRITE_OFF_PAYABLE', 'TRANSFER_PAYABLE') then 'PAYABLE' end;
  end direction_of;

  function kind_of_dir (p_dir varchar2) return varchar2 is
  begin
    return case p_dir when 'RECEIVABLE' then 'WITH_CUSTOMER' else 'WITH_SUPPLIER' end;
  end kind_of_dir;

  function cp_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_counterparty where id = p_id;
    return l;
  end cp_name;

  function contract_name (p_id varchar2) return varchar2 is
    l varchar2(400);
  begin
    select max(name || case when contract_number is not null then ' № ' || contract_number end) into l
      from ref_contract where id = p_id;
    return l;
  end contract_name;

  function debt_at (p_org in varchar2, p_cp in varchar2, p_direction in varchar2, p_date in date default null) return number is
    l number;
  begin
    select coalesce(sum(amount), 0) into l from reg_counterparty_settlement_mv
     where organization_id = p_org and counterparty_id = p_cp and direction = p_direction and currency_code = 'UAH'
       and (p_date is null or period <= p_date);
    return l;
  end debt_at;

  function saldo_at (p_org in varchar2, p_cp in varchar2, p_date in date default null) return number is
  begin
    return debt_at(p_org, p_cp, 'RECEIVABLE', p_date) - debt_at(p_org, p_cp, 'PAYABLE', p_date);
  end saldo_at;

  procedure check_header (p_inserting in boolean, p_op in varchar2, p_date in date, p_org in out varchar2,
                          p_cp in varchar2, p_old_cp in varchar2, p_contract in out varchar2,
                          p_target_cp in out varchar2, p_old_target_cp in varchar2, p_target_contract in out varchar2,
                          p_amount in number, p_reason in out varchar2) is
    l_dir varchar2(20) := direction_of(p_op);
  begin
    if p_op is null or operation_name(p_op) is null then
      fail('DEBT_OPERATION_KIND', 'Вкажіть вид операції коригування заборгованості.');
    end if;
    if p_org is null then
      p_org := trade_org.default_org;
    end if;
    if p_cp is null then
      fail('DEBT_COUNTERPARTY_REQUIRED', 'Вкажіть контрагента.');
    end if;
    if p_inserting or p_cp <> nvl(p_old_cp, '-') then
      trade_core.check_active_ref('REF_COUNTERPARTY', p_cp, 'Контрагент');
    end if;
    if p_amount is null or p_amount <= 0 then
      fail('DEBT_AMOUNT', 'Сума коригування має бути більшою за нуль.');
    end if;

    if p_op = 'OFFSET' then
      -- договір з покупцем (дебіторка) і договір з постачальником (кредиторка) того самого контрагента
      p_target_cp := p_cp;
      if p_inserting then
        p_contract := coalesce(p_contract, trade_nsi.resolve_default_contract(p_cp, 'WITH_CUSTOMER', p_date));
        p_target_contract := coalesce(p_target_contract, trade_nsi.resolve_default_contract(p_cp, 'WITH_SUPPLIER', p_date));
      end if;
      trade_nsi.check_contract(p_contract, p_cp, 'WITH_CUSTOMER', p_date);
      trade_nsi.check_contract(p_target_contract, p_cp, 'WITH_SUPPLIER', p_date);
    elsif p_op like 'WRITE_OFF%' then
      p_target_cp := null; p_target_contract := null;
      if p_inserting and p_contract is null then
        p_contract := trade_nsi.resolve_default_contract(p_cp, kind_of_dir(l_dir), p_date);
      end if;
      trade_nsi.check_contract(p_contract, p_cp, kind_of_dir(l_dir), p_date);
    else
      -- перенесення: одержувач за замовчуванням — той самий контрагент (інший договір)
      p_target_cp := coalesce(p_target_cp, p_cp);
      if p_target_cp <> p_cp and (p_inserting or p_target_cp <> nvl(p_old_target_cp, '-')) then
        trade_core.check_active_ref('REF_COUNTERPARTY', p_target_cp, 'Контрагент-одержувач');
      end if;
      trade_nsi.check_contract(p_contract, p_cp, kind_of_dir(l_dir), p_date);
      trade_nsi.check_contract(p_target_contract, p_target_cp, kind_of_dir(l_dir), p_date);
      if p_target_cp = p_cp and nvl(p_contract, '-') = nvl(p_target_contract, '-') then
        fail('DEBT_TRANSFER_SAME', 'Для перенесення заборгованості вкажіть інший договір або іншого контрагента-одержувача.');
      end if;
    end if;

    p_reason := trim(p_reason);
    if p_reason is null then
      p_reason := operation_name(p_op);
    end if;
  end check_header;

  -- ------------------------------------------------------------- проведення
  procedure lock_doc (p_id varchar2, o_status out varchar2) is
  begin
    select status into o_status from doc_debt_adjustment where id = p_id for update;
  exception when no_data_found then
    fail('DOCUMENT_NOT_FOUND', 'Документ не знайдено.');
  end lock_doc;

  procedure move (r doc_debt_adjustment%rowtype, p_line number, p_cp varchar2, p_dir varchar2, p_amount number) is
  begin
    insert into reg_counterparty_settlement_mv (period, recorder_type, recorder_id, line_number, counterparty_id,
                                                direction, currency_code, amount, organization_id)
    values (r.occurred_at, c_type, r.id, p_line, p_cp, p_dir, 'UAH', p_amount, r.organization_id);
  end move;

  procedure post (p_id in varchar2) is
    r doc_debt_adjustment%rowtype;
    l_status varchar2(10); l_dummy varchar2(32);
    l_rec number; l_pay number; l_debt number;
    l_dir varchar2(20);
  begin
    lock_doc(p_id, l_status);
    select * into r from doc_debt_adjustment where id = p_id;
    trade_core.check_active_ref('REF_COUNTERPARTY', r.counterparty_id, 'Контрагент');
    -- серіалізація проведень за контрагентами (як в оплатах)
    for c in (select id from ref_counterparty where id in (r.counterparty_id, r.target_counterparty_id) order by id for update) loop
      l_dummy := c.id;
    end loop;
    l_dir := direction_of(r.operation_kind);
    trade_core.g_internal := true;
    delete from reg_counterparty_settlement_mv where recorder_type = c_type and recorder_id = p_id;

    if r.operation_kind = 'OFFSET' then
      l_rec := debt_at(r.organization_id, r.counterparty_id, 'RECEIVABLE', r.occurred_at);
      l_pay := debt_at(r.organization_id, r.counterparty_id, 'PAYABLE', r.occurred_at);
      if r.amount > least(l_rec, l_pay) then
        fail('DEBT_OFFSET_EXCEEDS', 'Сума заліку ' || m(r.amount) || ' UAH перевищує меншу із заборгованостей на дату документа: '
             || 'дебіторська ' || m(l_rec) || ', кредиторська ' || m(l_pay) || ' UAH. Максимальна сума заліку — '
             || m(greatest(least(l_rec, l_pay), 0)) || ' UAH.');
      end if;
      move(r, 1, r.counterparty_id, 'RECEIVABLE', -r.amount);   -- борг покупця погашено заліком
      move(r, 2, r.counterparty_id, 'PAYABLE', -r.amount);      -- наш борг постачальнику погашено заліком
    else
      l_debt := debt_at(r.organization_id, r.counterparty_id, l_dir, r.occurred_at);
      if r.amount > l_debt then
        fail('DEBT_AMOUNT_EXCEEDS', 'Сума ' || m(r.amount) || ' UAH перевищує '
             || case l_dir when 'RECEIVABLE' then 'дебіторську' else 'кредиторську' end
             || ' заборгованість контрагента «' || cp_name(r.counterparty_id) || '» на дату документа: ' || m(l_debt) || ' UAH.');
      end if;
      move(r, 1, r.counterparty_id, l_dir, -r.amount);
      if r.operation_kind like 'TRANSFER%' then
        move(r, 2, r.target_counterparty_id, l_dir, r.amount);
      end if;
    end if;
    -- пізніші документи не повинні отримати від'ємну заборгованість
    trade_org.check_settlement(r.organization_id, r.counterparty_id);
    update doc_debt_adjustment set status = 'POSTED' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'POST', operation_name(r.operation_kind) || ', сума ' || m(r.amount) || ' UAH');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end post;

  procedure unpost (p_id in varchar2) is
    r doc_debt_adjustment%rowtype;
    l_status varchar2(10);
  begin
    lock_doc(p_id, l_status);
    if l_status <> 'POSTED' then
      fail('DOCUMENT_NOT_POSTED', 'Документ не проведено.');
    end if;
    select * into r from doc_debt_adjustment where id = p_id;
    trade_core.g_internal := true;
    delete from reg_counterparty_settlement_mv where recorder_type = c_type and recorder_id = p_id;
    -- перенесений борг одержувач міг уже погасити
    if r.target_counterparty_id is not null then
      trade_org.check_settlement(r.organization_id, r.target_counterparty_id);
    end if;
    trade_org.check_settlement(r.organization_id, r.counterparty_id);
    update doc_debt_adjustment set status = 'DRAFT' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'UNPOST');
  exception when others then
    trade_core.g_internal := false;
    raise;
  end unpost;

  function copy (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_debt_adjustment (id, occurred_at, organization_id, operation_kind, counterparty_id, contract_id,
                                     target_counterparty_id, target_contract_id, amount, reason, doc_comment)
    select l_new, sysdate, organization_id, operation_kind, counterparty_id, contract_id,
           target_counterparty_id, target_contract_id, amount, reason, doc_comment
      from doc_debt_adjustment where id = p_id;
    trade_core.audit(c_type, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy;

  -- ------------------------------------------------------------- друк
  -- Журнал друку незалежно від контексту виклику (регіон сторінки, SQL-запит)
  procedure log_print (p_type varchar2, p_id varchar2, p_details varchar2) is
    pragma autonomous_transaction;
  begin
    trade_core.audit(p_type, p_id, 'PRINT', p_details);
    commit;
  end log_print;

  function css return varchar2 is
  begin
    return '<style>
      .tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1100px;background:#fff;padding:16px;position:relative}
      .tx-print h2{font-size:17px;text-align:center;margin:10px 0 4px}.tx-print .sub{text-align:center;margin-bottom:12px}
      .tx-print table{border-collapse:collapse;width:100%}
      .tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}
      .tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}
      .tx-print .grid .tot td{font-weight:bold}
      .tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}
      .tx-print .signs{display:flex;gap:40px;margin-top:24px}.tx-print .signs>div{flex:1}
      .tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}
      @media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}.t-Body-contentInner{padding:0!important}}
      </style>';
  end css;

  function org_block (o ref_organization%rowtype) return varchar2 is
  begin
    return '<b>' || e(coalesce(o.full_name, o.name)) || '</b>'
      || case when o.edrpou is not null then '<br>Код ЄДРПОУ ' || e(o.edrpou) end
      || case when o.address is not null then '<br>' || e(o.address) end;
  end org_block;

  function cp_block (p_id varchar2) return varchar2 is
    l varchar2(4000);
  begin
    for c in (select name, edrpou from ref_counterparty where id = p_id) loop
      l := '<b>' || e(c.name) || '</b>' || case when c.edrpou is not null then '<br>Код ЄДРПОУ ' || e(c.edrpou) end;
    end loop;
    return l;
  end cp_block;

  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    l_title varchar2(200);
  begin
    if p_form <> 'DEBT_ADJ' then return null; end if;
    for r in (select * from doc_debt_adjustment where id = p_id) loop
      select * into o from ref_organization where id = r.organization_id;
      l_title := case r.operation_kind when 'OFFSET' then 'Акт взаємозаліку заборгованостей'
                 else 'Акт коригування заборгованості' end;
      l := '<div class="tx-print">' || css
        || case when r.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<h2>' || l_title || ' № ' || e(r.doc_number) || '</h2><div class="sub">від ' || dt(r.occurred_at) || '</div>'
        || '<table class="grid"><tr><th style="width:30%">Організація</th><td>' || org_block(o) || '</td></tr>'
        || '<tr><th>Контрагент</th><td>' || cp_block(r.counterparty_id) || '</td></tr>'
        || '<tr><th>Вид операції</th><td>' || e(operation_name(r.operation_kind)) || '</td></tr>';
      if r.operation_kind = 'OFFSET' then
        l := l || '<tr><th>Договір з покупцем (дебіторська заборгованість контрагента)</th><td>' || e(coalesce(contract_name(r.contract_id), 'без договору')) || '</td></tr>'
               || '<tr><th>Договір з постачальником (кредиторська заборгованість перед контрагентом)</th><td>' || e(coalesce(contract_name(r.target_contract_id), 'без договору')) || '</td></tr>';
      else
        l := l || '<tr><th>Договір</th><td>' || e(coalesce(contract_name(r.contract_id), 'без договору')) || '</td></tr>';
        if r.operation_kind like 'TRANSFER%' then
          l := l || '<tr><th>Заборгованість переноситься на</th><td>' || cp_block(r.target_counterparty_id)
                 || '<br>договір: ' || e(coalesce(contract_name(r.target_contract_id), 'без договору')) || '</td></tr>';
        end if;
      end if;
      l := l || '<tr><th>Сума, UAH</th><td><b>' || m(r.amount) || '</b> (' || e(trade_r3.amount_in_words_uk(r.amount)) || ')</td></tr>'
             || '<tr><th>Підстава</th><td>' || e(r.reason) || '</td></tr></table>';
      l := l || '<p>' || case r.operation_kind
          when 'OFFSET' then 'Сторони дійшли згоди зарахувати зустрічні однорідні вимоги на суму ' || m(r.amount)
               || ' грн. Після заліку заборгованості сторін одна перед одною зменшуються на цю суму.'
          when 'WRITE_OFF_RECEIVABLE' then 'Дебіторську заборгованість контрагента визнано безнадійною та списано на суму ' || m(r.amount) || ' грн.'
          when 'WRITE_OFF_PAYABLE' then 'Кредиторську заборгованість перед контрагентом списано на суму ' || m(r.amount) || ' грн.'
          else 'Заборгованість на суму ' || m(r.amount) || ' грн переноситься відповідно до вказаних реквізитів.' end || '</p>'
        || '<div class="signs"><div>Від організації:<br>' || e(coalesce(o.full_name, o.name))
        || '<br><br>Керівник ____________ ' || e(o.director_name) || '<br><br>Головний бухгалтер ____________ ' || e(o.accountant_name)
        || '<br><br>М. П.</div>'
        || case when r.operation_kind in ('OFFSET', 'TRANSFER_RECEIVABLE', 'TRANSFER_PAYABLE') then
             '<div>Від контрагента:<br>' || e(cp_name(r.counterparty_id)) || '<br><br>Керівник ____________<br><br>Головний бухгалтер ____________<br><br>М. П.</div>' end
        || case when r.operation_kind like 'TRANSFER%' and r.target_counterparty_id <> r.counterparty_id then
             '<div>Від нового боржника / кредитора:<br>' || e(cp_name(r.target_counterparty_id)) || '<br><br>Керівник ____________<br><br>М. П.</div>' end
        || '</div></div>';
    end loop;
    return l;
  end print_html;

  function reconciliation_html (p_org in varchar2, p_cp in varchar2, p_from in date, p_to in date) return clob is
    l clob;
    o ref_organization%rowtype;
    l_cp varchar2(255);
    l_from date := trunc(coalesce(p_from, sysdate));
    l_to date := trunc(coalesce(p_to, sysdate));
    l_open number; l_close number; l_deb number := 0; l_cred number := 0; l_d number; l_c number;

    function saldo_row (p_label varchar2, p_val number) return varchar2 is
    begin
      return '<tr class="tot"><td colspan="2">' || e(p_label) || '</td><td class="r">' || case when p_val > 0 then m(p_val) end
          || '</td><td class="r">' || case when p_val < 0 then m(-p_val) end || '</td><td colspan="2">' || e(p_label)
          || '</td><td></td><td></td></tr>';
    end saldo_row;
  begin
    if p_org is null or p_cp is null then
      return '<p>Виберіть організацію й контрагента.</p>';
    end if;
    if l_from > l_to then
      return '<p>Початок періоду пізніше за кінець.</p>';
    end if;
    select * into o from ref_organization where id = p_org;
    l_cp := cp_name(p_cp);
    l_open := saldo_at(p_org, p_cp, l_from - 1/86400);
    l_close := saldo_at(p_org, p_cp, l_to + 1 - 1/86400);
    l := '<div class="tx-print">' || css
      || '<h2>Акт звірки взаємних розрахунків</h2><div class="sub">за період з ' || dt(l_from) || ' по ' || dt(l_to)
      || '<br>між ' || e(coalesce(o.full_name, o.name)) || ' і ' || e(l_cp) || '</div>'
      || '<p>Ми, що нижче підписалися, склали цей акт про те, що стан взаємних розрахунків за даними обліку такий:</p>'
      || '<table class="grid"><tr><th colspan="4">За даними ' || e(coalesce(o.full_name, o.name)) || ', UAH</th>'
      || '<th colspan="4">За даними ' || e(l_cp) || ', UAH</th></tr>'
      || '<tr><th style="width:80px">Дата</th><th>Документ</th><th style="width:100px">Дебет</th><th style="width:100px">Кредит</th>'
      || '<th style="width:80px">Дата</th><th>Документ</th><th style="width:100px">Дебет</th><th style="width:100px">Кредит</th></tr>'
      || saldo_row('Сальдо на ' || dt(l_from), l_open);
    for x in (select m.period, m.recorder_type, m.recorder_id,
                     sum(case when m.direction = 'RECEIVABLE' and m.amount > 0 then m.amount
                              when m.direction = 'PAYABLE' and m.amount < 0 then -m.amount else 0 end) debit,
                     sum(case when m.direction = 'RECEIVABLE' and m.amount < 0 then -m.amount
                              when m.direction = 'PAYABLE' and m.amount > 0 then m.amount else 0 end) credit,
                     max(r.recorder_name) recorder_name
                from reg_counterparty_settlement_mv m
                left join v_recorder r on r.recorder_type = m.recorder_type and r.recorder_id = m.recorder_id
               where m.organization_id = p_org and m.counterparty_id = p_cp and m.currency_code = 'UAH'
                 and m.period >= l_from and m.period < l_to + 1
               group by m.period, m.recorder_type, m.recorder_id
               order by m.period, max(r.recorder_name)) loop
      -- взаємозалік дає однакові дебет і кредит одного документа — показуємо обидва
      l_d := x.debit; l_c := x.credit;
      l := l || '<tr><td>' || dt(x.period) || '</td><td>'
             || e(coalesce(case when x.recorder_name like '% __:__:__' then substr(x.recorder_name, 1, length(x.recorder_name) - 9)
                                else x.recorder_name end, x.recorder_type))
             || '</td><td class="r">' || case when l_d <> 0 then m(l_d) end || '</td><td class="r">' || case when l_c <> 0 then m(l_c) end
             || '</td><td></td><td></td><td></td><td></td></tr>';
      l_deb := l_deb + l_d; l_cred := l_cred + l_c;
    end loop;
    l := l || '<tr class="tot"><td colspan="2">Обороти за період</td><td class="r">' || m(l_deb) || '</td><td class="r">' || m(l_cred)
           || '</td><td colspan="2">Обороти за період</td><td></td><td></td></tr>'
           || saldo_row('Сальдо на ' || dt(l_to), l_close) || '</table>'
           || '<p>За даними ' || e(coalesce(o.full_name, o.name)) || ' на ' || dt(l_to) || ' '
           || case when l_close > 0 then 'заборгованість на користь ' || e(coalesce(o.full_name, o.name)) || ' становить <b>' || m(l_close)
                    || '</b> грн (' || e(trade_r3.amount_in_words_uk(l_close)) || ').'
                   when l_close < 0 then 'заборгованість на користь ' || e(l_cp) || ' становить <b>' || m(-l_close)
                    || '</b> грн (' || e(trade_r3.amount_in_words_uk(-l_close)) || ').'
                   else 'заборгованість між сторонами відсутня.' end || '</p>'
           || '<div class="signs"><div>Від ' || e(coalesce(o.full_name, o.name)) || '<br><br>Керівник ____________ ' || e(o.director_name)
           || '<br><br>Головний бухгалтер ____________ ' || e(o.accountant_name) || '<br><br>М. П.</div>'
           || '<div>Від ' || e(l_cp) || '<br><br>Керівник ____________<br><br>Головний бухгалтер ____________<br><br>М. П.</div></div></div>';
    log_print('ReconciliationAct', p_cp, 'Акт звірки ' || dt(l_from) || '–' || dt(l_to));
    return l;
  end reconciliation_html;

end trade_debt_adj;
/

-- ---------------------------------------------------------------- тригер документа
create or replace trigger doc_debt_adjustment_biud
before insert or update or delete on doc_debt_adjustment for each row
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_DEBT_ADJUSTMENT_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    if inserting or :new.organization_id <> nvl(:old.organization_id, '-') then
      if :new.organization_id is not null then
        trade_core.check_active_ref('REF_ORGANIZATION', :new.organization_id, 'Організація');
      end if;
    end if;
    :new.currency_code := 'UAH';
    trade_debt_adj.check_header(inserting, :new.operation_kind, :new.occurred_at, :new.organization_id,
      :new.counterparty_id, :old.counterparty_id, :new.contract_id,
      :new.target_counterparty_id, :old.target_counterparty_id, :new.target_contract_id,
      :new.amount, :new.reason);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/

-- ---------------------------------------------------------------- реєстратори (+ коригування боргу)
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
union all select 'DocDebtAdjustment', d.id, 'Коригування боргу ' || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 411 from doc_debt_adjustment d;

-- Список документів (сторінка 410)
create or replace view v_debt_adjustment_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name,
       d.operation_kind, trade_debt_adj.operation_name(d.operation_kind) operation_name,
       d.counterparty_id, cp.name counterparty_name, d.target_counterparty_id, tcp.name target_counterparty_name,
       d.amount, d.currency_code, d.reason, d.status, d.doc_comment
  from doc_debt_adjustment d
  join ref_organization o on o.id = d.organization_id
  join ref_counterparty cp on cp.id = d.counterparty_id
  left join ref_counterparty tcp on tcp.id = d.target_counterparty_id;

-- ---------------------------------------------------------------- меню: «Фінанси → Взаєморозрахунки»
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
  obj('DocDebtAdjustment', 'DOCUMENT', 'Documents', 'Коригування боргу', 410, 411, 170, 'Роль: каса');
  obj('ReconciliationAct', 'REPORT',   'Reports',   'Акт звірки взаєморозрахунків', 420, null, 140, null);
  fp('Finance', 'Взаєморозрахунки', 1, 9, 'DocDebtAdjustment', 10, 'Y');
  fp('Finance', 'Взаєморозрахунки', 1, 9, 'ReconciliationAct', 20);
  fp('Finance', 'Звіти', 1, 20, 'RegCounterpartySettlement', 30);
  fp('Sales', 'Звіти', 2, 10, 'ReconciliationAct', 30);
  fp('Purchases', 'Звіти', 2, 10, 'ReconciliationAct', 30);
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
