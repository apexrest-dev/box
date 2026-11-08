-- =============================================================================
-- Trade r5 — F-PRC-06 «Знижки й акції» (APE-64).
-- Паспорти RefDiscount, RegDiscountLimit (PROPOSED); доповнення DocCustomerOrder, DocGoodsSale.
--   * довідник ref_discount «Знижки та акції» — умови автоматичної знижки: період дії,
--     покупець, договір, група номенклатури (з підгрупами), товар, мінімальна кількість у рядку,
--     мінімальна сума документа (до знижок), застосування (замовлення / реалізація / усі);
--     з кількох придатних умов рядок отримує одну — з найбільшим відсотком (не сумуються);
--   * рядки замовлення клієнта: discount_percent (r3, тепер — підсумкова знижка) =
--     manual_discount_percent «Ручна знижка» + auto_discount_percent «Автоматична знижка»
--     (≤ 100 %), discount_id — застосована умова; старі вставки лише з discount_percent
--     сприймаються як ручна знижка (сумісність r3);
--   * рядки реалізації: base_price «Ціна до знижки», ті самі поля знижок; price = ціна зі
--     знижкою (як і раніше — нею користуються суми, RegSales, повернення, собівартість);
--     реалізація на підставі замовлення переносить ціну й знижки рядка замовлення (раніше
--     знижка «зашивалась» у ціну);
--   * trade_discount.calc — команда «Розрахувати знижки»; під час проведення замовлення й
--     реалізації (не на підставі замовлення) автоматичні знижки перераховуються;
--     set_manual — ручна знижка на весь документ;
--   * обмеження ручної знижки за роллю — регістр reg_discount_limit (роль APEX → макс. %);
--     для користувача діє найбільше з обмежень його ролей, роль без запису не обмежує;
--     поза сеансом APEX (скрипти, інтеграції) обмеження не застосовується;
--   * звіт «Надані знижки» (v_discount_given, trade_discount.given_html).
-- Потребує 01–38. Скрипт повторно виконуваний.
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408, -2264) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefDiscount
  ddl('create sequence ref_discount_code_seq nocache');
  ddl(q'[create table ref_discount (
    id               varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code             varchar2(9)   not null,
    name             varchar2(255) not null,
    discount_percent number(5,2)   not null,
    applies_to       varchar2(10)  default on null 'ALL' not null,
    date_from        date,
    date_to          date,
    customer_id      varchar2(32),
    contract_id      varchar2(32),
    product_group_id varchar2(32),
    product_id       varchar2(32),
    min_quantity     number(19,3),
    min_doc_amount   number(19,2),
    description      varchar2(1000),
    state            varchar2(20)  default on null 'ACTIVE' not null,
    version          number(19)    default on null 0 not null,
    created_at       timestamp     not null, created_by varchar2(255) not null,
    updated_at       timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_discount_pk primary key (id),
    constraint ref_discount_code_uk unique (code),
    constraint ref_discount_pct_ck check (discount_percent > 0 and discount_percent <= 100),
    constraint ref_discount_applies_ck check (applies_to in ('ALL','ORDER','SALE')),
    constraint ref_discount_dates_ck check (date_to is null or date_from is null or date_to >= date_from),
    constraint ref_discount_qty_ck check (min_quantity is null or min_quantity > 0),
    constraint ref_discount_amt_ck check (min_doc_amount is null or min_doc_amount > 0),
    constraint ref_discount_cus_fk foreign key (customer_id) references ref_counterparty (id),
    constraint ref_discount_ctr_fk foreign key (contract_id) references ref_contract (id),
    constraint ref_discount_grp_fk foreign key (product_group_id) references ref_product_group (id),
    constraint ref_discount_prd_fk foreign key (product_id) references ref_product (id),
    constraint ref_discount_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');

  -- ---------------------------------------------------------------- RegDiscountLimit
  ddl(q'[create table reg_discount_limit (
    id                 varchar2(32)  default on null rawtohex(sys_guid()) not null,
    role_static_id     varchar2(30)  not null,
    max_manual_percent number(5,2)   not null,
    note               varchar2(255),
    updated_at         timestamp,
    updated_by         varchar2(255),
    constraint reg_discount_limit_pk primary key (id),
    constraint reg_discount_limit_role_uk unique (role_static_id),
    constraint reg_discount_limit_pct_ck check (max_manual_percent between 0 and 100))]');

  -- ---------------------------------------------------------------- рядки документів
  ddl(q'[alter table doc_customer_order_goods add (manual_discount_percent number(5,2),
                                                 auto_discount_percent number(5,2) default on null 0 not null,
                                                 discount_id varchar2(32))]');
  ddl('alter table doc_customer_order_goods add constraint doc_customer_order_goods_dsc_fk foreign key (discount_id) references ref_discount (id)');
  ddl(q'[alter table doc_goods_sale_goods add (base_price number(19,2),
                                             discount_percent number(5,2) default on null 0 not null,
                                             manual_discount_percent number(5,2),
                                             auto_discount_percent number(5,2) default on null 0 not null,
                                             discount_id varchar2(32))]');
  ddl('alter table doc_goods_sale_goods add constraint doc_goods_sale_goods_dsc_fk foreign key (discount_id) references ref_discount (id)');
  ddl('alter table doc_goods_sale_goods add constraint doc_goods_sale_goods_dsc_ck check (discount_percent between 0 and 100)');
  ddl('create index doc_customer_order_goods_dsc_ix on doc_customer_order_goods (discount_id)');
  ddl('create index doc_goods_sale_goods_dsc_ix on doc_goods_sale_goods (discount_id)');
end;
/

create or replace package trade_discount as
  -- Службові прапорці: перенесення знижок з документа-підстави / копії (без контролю обмеження)
  g_skip_limit boolean := false;
  -- Тести: ролі поточного користувача через кому (замість ролей APEX)
  g_test_roles varchar2(4000);

  -- Максимальна ручна знижка поточного користувача, %; null — без обмеження (поза сеансом APEX)
  function manual_limit return number;
  procedure check_manual (p_percent in number);
  -- Найкраща (найбільший %) придатна умова; p_scope ORDER / SALE
  function best_rule (p_scope in varchar2, p_date in date, p_customer_id in varchar2, p_contract_id in varchar2,
                      p_product_id in varchar2, p_qty in number, p_doc_amount in number, p_percent out number) return varchar2;
  function rule_label (p_discount_id in varchar2) return varchar2;
  function applies_to_name (p_code in varchar2) return varchar2 deterministic;

  -- «Розрахувати знижки»: автоматичні знижки рядків чернетки; повертає кількість рядків зі знижкою
  function  calc (p_type in varchar2, p_id in varchar2) return number;
  procedure calc (p_type in varchar2, p_id in varchar2);
  -- Перед проведенням (виклик з trade_ops / trade_r3)
  procedure prepare_post (p_type in varchar2, p_id in varchar2);
  -- Ручна знижка на весь документ (з контролем обмеження ролі)
  procedure set_manual (p_type in varchar2, p_id in varchar2, p_percent in number);
  -- Копіювання документа: ціни до знижки й знижки рядків
  procedure copy_lines (p_type in varchar2, p_src_id in varchar2, p_new_id in varchar2);
  -- Реалізація на підставі замовлення: рядок з ціною й знижками рядка замовлення (виклик з trade_r3)
  procedure sale_line_from_order (p_sale_id in varchar2, p_line_number in number, p_order_line_id in varchar2, p_qty in number);

  -- Звіт «Надані знижки»: підсумки за умовами
  function given_html (p_from in date, p_to in date, p_org in varchar2 default null) return clob;
end trade_discount;
/
show errors package trade_discount

-- ---------------------------------------------------------------- представлення
create or replace view v_discount_list as
select r.id, r.code, r.name, r.discount_percent, r.applies_to, trade_discount.applies_to_name(r.applies_to) applies_to_name,
       r.date_from, r.date_to,
       case when r.date_from is null and r.date_to is null then 'Без обмеження'
            else nvl(to_char(r.date_from, 'DD.MM.YYYY'), '…') || ' – ' || nvl(to_char(r.date_to, 'DD.MM.YYYY'), '…') end period_text,
       case when r.state <> 'ACTIVE' then 'Помічена на видалення'
            when r.date_to < trunc(sysdate) then 'Завершена'
            when r.date_from > trunc(sysdate) then 'Запланована'
            else 'Діє' end validity_name,
       r.customer_id, c.name customer_name, r.contract_id, k.name contract_name,
       r.product_group_id, g.full_path group_path, r.product_id, p.name product_name,
       r.min_quantity, r.min_doc_amount, r.description, r.state
  from ref_discount r
  left join ref_counterparty c on c.id = r.customer_id
  left join ref_contract k on k.id = r.contract_id
  left join v_product_group_path g on g.id = r.product_group_id
  left join ref_product p on p.id = r.product_id;

-- Надані знижки: рядки проведених реалізацій зі знижкою
create or replace view v_discount_given as
select d.occurred_at period, d.id document_id, d.doc_number, d.organization_id, d.customer_id, c.name customer_name,
       d.base_order_id, g.line_number, g.product_id, p.code product_code, p.name product_name, p.group_id, gp.full_path group_path,
       g.quantity, g.base_price, g.price, round(g.quantity * g.base_price, 2) list_amount, g.amount,
       round(g.quantity * g.base_price, 2) - g.amount discount_amount,
       g.discount_percent, g.manual_discount_percent, g.auto_discount_percent,
       case when g.discount_percent > 0
            then round((round(g.quantity * g.base_price, 2) - g.amount) * g.auto_discount_percent / g.discount_percent, 2)
            else 0 end auto_discount_amount,
       g.discount_id, r.name discount_name, d.created_by author
  from doc_goods_sale d
  join doc_goods_sale_goods g on g.document_id = d.id
  join ref_product p on p.id = g.product_id
  join ref_counterparty c on c.id = d.customer_id
  left join v_product_group_path gp on gp.id = p.group_id
  left join ref_discount r on r.id = g.discount_id
 where d.status = 'POSTED' and g.discount_percent > 0;

create or replace package body trade_discount as

  procedure fail (p_code varchar2, p_msg varchar2) is
  begin
    trade_nsi.fail(p_code, p_msg);
  end fail;

  function pct_txt (p number) return varchar2 is
  begin
    return rtrim(rtrim(to_char(p, 'FM990D00', 'NLS_NUMERIC_CHARACTERS=,.'), '0'), ',');
  end pct_txt;

  function manual_limit return number is
    l_user varchar2(255) := sys_context('APEX$SESSION', 'APP_USER');
    l number; l_cnt number;
  begin
    if g_test_roles is not null then
      select count(*), max(coalesce(lim.max_manual_percent, 100)) into l_cnt, l
        from (select trim(regexp_substr(g_test_roles, '[^,]+', 1, level)) r from dual
              connect by level <= regexp_count(g_test_roles, ',') + 1) x
        left join reg_discount_limit lim on lim.role_static_id = x.r;
    elsif l_user is null then
      return null;
    else
      select count(*), max(coalesce(lim.max_manual_percent, 100)) into l_cnt, l
        from apex_appl_acl_user_roles ur
        left join reg_discount_limit lim on lim.role_static_id = ur.role_static_id
       where ur.application_id = coalesce(nv('APP_ID'), 100) and ur.user_name = upper(l_user);
    end if;
    return case when l_cnt = 0 then 0 else l end;
  end manual_limit;

  procedure check_manual (p_percent in number) is
    l number;
  begin
    if nvl(p_percent, 0) <= 0 or g_skip_limit or trade_core.g_internal then
      return;
    end if;
    l := manual_limit;
    if l is not null and p_percent > l then
      fail('MANUAL_DISCOUNT_LIMIT', 'Ручна знижка ' || pct_txt(p_percent) || ' % перевищує дозволену для вашої ролі ('
           || pct_txt(l) || ' %).');
    end if;
  end check_manual;

  function best_rule (p_scope in varchar2, p_date in date, p_customer_id in varchar2, p_contract_id in varchar2,
                      p_product_id in varchar2, p_qty in number, p_doc_amount in number, p_percent out number) return varchar2 is
    l_id varchar2(32);
  begin
    select max(id) keep (dense_rank first order by discount_percent desc, code),
           max(discount_percent)
      into l_id, p_percent
      from ref_discount r
     where r.state = 'ACTIVE'
       and r.applies_to in ('ALL', p_scope)
       and (r.date_from is null or trunc(p_date) >= r.date_from)
       and (r.date_to is null or trunc(p_date) <= r.date_to)
       and (r.customer_id is null or r.customer_id = p_customer_id)
       and (r.contract_id is null or r.contract_id = p_contract_id)
       and (r.product_id is null or r.product_id = p_product_id)
       and (r.product_group_id is null
            or r.product_group_id in (select g.id from ref_product_group g
                                       start with g.id = (select p.group_id from ref_product p where p.id = p_product_id)
                                       connect by prior g.parent_id = g.id))
       and (r.min_quantity is null or p_qty >= r.min_quantity)
       and (r.min_doc_amount is null or p_doc_amount >= r.min_doc_amount);
    return l_id;
  end best_rule;

  function rule_label (p_discount_id in varchar2) return varchar2 is
    l varchar2(400); l_p number;
  begin
    if p_discount_id is null then return null; end if;
    select name, discount_percent into l, l_p from ref_discount where id = p_discount_id;
    return l || ' (' || pct_txt(l_p) || ' %)';
  exception when no_data_found then
    return null;
  end rule_label;

  function applies_to_name (p_code in varchar2) return varchar2 deterministic is
  begin
    return case p_code when 'ORDER' then 'Замовлення клієнтів' when 'SALE' then 'Реалізація' else 'Замовлення й реалізація' end;
  end applies_to_name;

  procedure check_draft (p_type varchar2, p_id varchar2) is
    l_st varchar2(10);
  begin
    if p_type = 'DocCustomerOrder' then
      select status into l_st from doc_customer_order where id = p_id;
    elsif p_type = 'DocGoodsSale' then
      select status into l_st from doc_goods_sale where id = p_id;
    else
      fail('DISCOUNT_DOC_TYPE', 'Знижки розраховуються лише в замовленні клієнта й реалізації.');
    end if;
    if l_st <> 'DRAFT' then
      fail('DOCUMENT_NOT_DRAFT', 'Знижки можна змінювати лише в чернетці документа.');
    end if;
  end check_draft;

  function calc_lines (p_type in varchar2, p_id in varchar2) return number is
    l_date date; l_cus varchar2(32); l_ctr varchar2(32); l_gross number; l_rule varchar2(32); l_pct number;
    n pls_integer := 0;
  begin
    check_draft(p_type, p_id);
    if p_type = 'DocCustomerOrder' then
      select occurred_at, customer_id, contract_id into l_date, l_cus, l_ctr from doc_customer_order where id = p_id;
      select coalesce(sum(round(quantity * price, 2)), 0) into l_gross from doc_customer_order_goods where document_id = p_id;
      for l in (select id, product_id, quantity, auto_discount_percent, discount_id
                  from doc_customer_order_goods where document_id = p_id order by line_number) loop
        l_rule := best_rule('ORDER', l_date, l_cus, l_ctr, l.product_id, l.quantity, l_gross, l_pct);
        if nvl(l_pct, 0) <> l.auto_discount_percent or nvl(l_rule, '-') <> nvl(l.discount_id, '-') then
          update doc_customer_order_goods set auto_discount_percent = nvl(l_pct, 0), discount_id = l_rule where id = l.id;
        end if;
        if l_rule is not null then n := n + 1; end if;
      end loop;
    else
      select occurred_at, customer_id, contract_id into l_date, l_cus, l_ctr from doc_goods_sale where id = p_id;
      select coalesce(sum(round(quantity * base_price, 2)), 0) into l_gross from doc_goods_sale_goods where document_id = p_id;
      for l in (select id, product_id, quantity, auto_discount_percent, discount_id
                  from doc_goods_sale_goods where document_id = p_id order by line_number) loop
        l_rule := best_rule('SALE', l_date, l_cus, l_ctr, l.product_id, l.quantity, l_gross, l_pct);
        if nvl(l_pct, 0) <> l.auto_discount_percent or nvl(l_rule, '-') <> nvl(l.discount_id, '-') then
          update doc_goods_sale_goods set auto_discount_percent = nvl(l_pct, 0), discount_id = l_rule where id = l.id;
        end if;
        if l_rule is not null then n := n + 1; end if;
      end loop;
    end if;
    return n;
  end calc_lines;

  function calc (p_type in varchar2, p_id in varchar2) return number is
    n number;
  begin
    n := calc_lines(p_type, p_id);
    trade_core.audit(p_type, p_id, 'CALC_DISCOUNTS', 'Рядків з автоматичною знижкою: ' || n);
    return n;
  end calc;

  procedure calc (p_type in varchar2, p_id in varchar2) is
    n number;
  begin
    n := calc(p_type, p_id);
  end calc;

  procedure prepare_post (p_type in varchar2, p_id in varchar2) is
    l_order varchar2(32); l_st varchar2(10); n number;
  begin
    if p_type = 'DocGoodsSale' then
      select base_order_id, status into l_order, l_st from doc_goods_sale where id = p_id;
      if l_order is not null then
        return;   -- знижки вже узгоджені в замовленні
      end if;
    elsif p_type = 'DocCustomerOrder' then
      select status into l_st from doc_customer_order where id = p_id;
    else
      return;
    end if;
    if l_st <> 'DRAFT' then
      return;   -- повторне проведення: рядки незмінні, знижки зберігаються
    end if;
    n := calc_lines(p_type, p_id);
  end prepare_post;

  procedure set_manual (p_type in varchar2, p_id in varchar2, p_percent in number) is
  begin
    check_draft(p_type, p_id);
    if p_percent is null or p_percent not between 0 and 100 then
      fail('DISCOUNT_OUT_OF_RANGE', 'Знижка має бути від 0 до 100 %.');
    end if;
    check_manual(p_percent);
    if p_type = 'DocCustomerOrder' then
      update doc_customer_order_goods set manual_discount_percent = p_percent where document_id = p_id;
    else
      update doc_goods_sale_goods set manual_discount_percent = p_percent where document_id = p_id;
    end if;
    trade_core.audit(p_type, p_id, 'SET_MANUAL_DISCOUNT', 'Ручна знижка на документ: ' || pct_txt(p_percent) || ' %');
  end set_manual;

  procedure copy_lines (p_type in varchar2, p_src_id in varchar2, p_new_id in varchar2) is
  begin
    if p_new_id is null then return; end if;
    g_skip_limit := true;
    if p_type = 'DocCustomerOrder' then
      merge into doc_customer_order_goods t
      using (select line_number, product_id, manual_discount_percent, auto_discount_percent, discount_id
               from doc_customer_order_goods where document_id = p_src_id) s
         on (t.document_id = p_new_id and t.line_number = s.line_number and t.product_id = s.product_id)
       when matched then update set t.manual_discount_percent = s.manual_discount_percent,
                                    t.auto_discount_percent = s.auto_discount_percent, t.discount_id = s.discount_id;
    elsif p_type = 'DocGoodsSale' then
      merge into doc_goods_sale_goods t
      using (select line_number, product_id, base_price, manual_discount_percent, auto_discount_percent, discount_id
               from doc_goods_sale_goods where document_id = p_src_id) s
         on (t.document_id = p_new_id and t.line_number = s.line_number and t.product_id = s.product_id)
       when matched then update set t.base_price = s.base_price, t.manual_discount_percent = s.manual_discount_percent,
                                    t.auto_discount_percent = s.auto_discount_percent, t.discount_id = s.discount_id;
    end if;
    g_skip_limit := false;
  exception when others then
    g_skip_limit := false;
    raise;
  end copy_lines;

  procedure sale_line_from_order (p_sale_id in varchar2, p_line_number in number, p_order_line_id in varchar2, p_qty in number) is
  begin
    g_skip_limit := true;
    insert into doc_goods_sale_goods (document_id, line_number, product_id, quantity, base_price, price,
                                      manual_discount_percent, auto_discount_percent, discount_id)
    select p_sale_id, p_line_number, product_id, p_qty, price, price,
           manual_discount_percent, auto_discount_percent, discount_id
      from doc_customer_order_goods where id = p_order_line_id;
    g_skip_limit := false;
  exception when others then
    g_skip_limit := false;
    raise;
  end sale_line_from_order;

  function given_html (p_from in date, p_to in date, p_org in varchar2 default null) return clob is
    l clob;
    l_list number := 0; l_disc number := 0; l_man number := 0; l_auto number := 0; l_n number := 0;
    function m (p number) return varchar2 is
    begin
      return to_char(p, 'FM999G999G999G990D00', 'NLS_NUMERIC_CHARACTERS='', ''');
    end;
    function td (p varchar2, p_cls varchar2 default null) return varchar2 is
    begin
      return '<td' || case when p_cls is not null then ' class="' || p_cls || '"' end || '>' || p || '</td>';
    end;
  begin
    l := '<table class="tx-report"><thead><tr><th>Знижка</th><th>Рядків</th><th>Сума без знижки</th>'
         || '<th>Сума знижки</th><th>у т. ч. автоматична</th><th>у т. ч. ручна</th><th>Частка, %</th></tr></thead><tbody>';
    for r in (select coalesce(discount_name, 'Лише ручна знижка') nm, count(*) cnt, sum(list_amount) list_amount,
                     sum(discount_amount) discount_amount, sum(auto_discount_amount) auto_amount,
                     sum(discount_amount - auto_discount_amount) manual_amount
                from v_discount_given
               where period >= trunc(p_from) and period < trunc(p_to) + 1
                 and (p_org is null or organization_id = p_org)
               group by coalesce(discount_name, 'Лише ручна знижка')
               order by 4 desc) loop
      l := l || '<tr>' || td(apex_escape.html(r.nm)) || td(r.cnt, 'r') || td(m(r.list_amount), 'r') || td(m(r.discount_amount), 'r')
             || td(m(r.auto_amount), 'r') || td(m(r.manual_amount), 'r')
             || td(m(case when r.list_amount > 0 then 100 * r.discount_amount / r.list_amount end), 'r') || '</tr>';
      l_n := l_n + r.cnt; l_list := l_list + r.list_amount; l_disc := l_disc + r.discount_amount;
      l_auto := l_auto + r.auto_amount; l_man := l_man + r.manual_amount;
    end loop;
    if l_n = 0 then
      l := l || '<tr><td colspan="7">За період знижок не надавалось.</td></tr>';
    end if;
    l := l || '</tbody><tfoot><tr><th>Разом</th><th class="r">' || l_n || '</th><th class="r">' || m(l_list) || '</th><th class="r">'
           || m(l_disc) || '</th><th class="r">' || m(l_auto) || '</th><th class="r">' || m(l_man) || '</th><th class="r">'
           || m(case when l_list > 0 then 100 * l_disc / l_list end) || '</th></tr></tfoot></table>';
    return l;
  end given_html;

end trade_discount;
/
show errors package body trade_discount

-- ---------------------------------------------------------------- тригери довідника й регістру
create or replace trigger ref_discount_biu
before insert or update on ref_discount for each row
declare
  l_owner varchar2(32);
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_DISCOUNT_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.description := trim(:new.description);
  :new.applies_to := coalesce(:new.applies_to, 'ALL');
  :new.date_from := trunc(:new.date_from);
  :new.date_to := trunc(:new.date_to);
  if :new.discount_percent is null or :new.discount_percent <= 0 or :new.discount_percent > 100 then
    trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Відсоток знижки має бути більше 0 і не більше 100.');
  end if;
  if :new.date_to < :new.date_from then
    trade_nsi.fail('DISCOUNT_PERIOD', 'Дата закінчення акції раніша за дату початку.');
  end if;
  if :new.contract_id is not null then
    select owner_id into l_owner from ref_contract where id = :new.contract_id;
    if :new.customer_id is null then
      :new.customer_id := l_owner;
    elsif l_owner <> :new.customer_id then
      trade_nsi.fail('DISCOUNT_CONTRACT_OWNER', 'Договір належить іншому контрагенту.');
    end if;
  end if;
  if :new.product_id is not null and :new.product_group_id is not null then
    trade_nsi.fail('DISCOUNT_PRODUCT_OR_GROUP', 'Вкажіть або товар, або групу номенклатури.');
  end if;
  if :new.state = 'ACTIVE' and (inserting or :old.state <> 'ACTIVE' or nvl(:new.customer_id, '-') <> nvl(:old.customer_id, '-')) then
    if :new.customer_id is not null then trade_core.check_active_ref('REF_COUNTERPARTY', :new.customer_id, 'Покупець'); end if;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
create or replace trigger ref_discount_bd before delete on ref_discount
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/

create or replace trigger reg_discount_limit_biu
before insert or update on reg_discount_limit for each row
begin
  :new.role_static_id := upper(trim(:new.role_static_id));
  if :new.max_manual_percent is null or :new.max_manual_percent not between 0 and 100 then
    trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Обмеження ручної знижки має бути від 0 до 100 %.');
  end if;
  :new.note := trim(:new.note);
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/

-- ---------------------------------------------------------------- рядки замовлення клієнта (db/13 + знижки r5)
create or replace trigger doc_customer_order_goods_ct
for insert or update or delete on doc_customer_order_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
    l_compat boolean := false;
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from doc_customer_order where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, false);
      if :new.price is null then
        select price_type_id, occurred_at into l_pt, l_dt from doc_customer_order where id = l_doc;
        if l_pt is null then
          trade_nsi.fail('PRICE_TYPE_REQUIRED', 'Вкажіть ціну або вид цін у шапці документа.');
        end if;
        :new.price := trade_lines.get_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_nsi.fail('PRICE_NOT_FOUND', 'Для товару не встановлено ціну обраного виду на дату документа.');
        end if;
      end if;
      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;
      -- r5 F-PRC-06: знижка = ручна + автоматична; вставка / зміна лише discount_percent — ручна (сумісність r3)
      :new.auto_discount_percent := nvl(:new.auto_discount_percent, 0);
      if inserting and :new.manual_discount_percent is null then
        :new.manual_discount_percent := greatest(nvl(:new.discount_percent, 0) - :new.auto_discount_percent, 0);
        l_compat := true;
      elsif updating and nvl(:new.manual_discount_percent, -1) = nvl(:old.manual_discount_percent, -1)
            and :new.auto_discount_percent = :old.auto_discount_percent
            and nvl(:new.discount_percent, 0) <> nvl(:old.discount_percent, 0) then
        :new.manual_discount_percent := greatest(nvl(:new.discount_percent, 0) - :new.auto_discount_percent, 0);
        l_compat := true;
      end if;
      :new.manual_discount_percent := nvl(:new.manual_discount_percent, 0);
      if :new.manual_discount_percent not between 0 and 100 or :new.auto_discount_percent not between 0 and 100 then
        trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Знижка має бути від 0 до 100 %.');
      end if;
      if not l_compat and (inserting or :new.manual_discount_percent <> nvl(:old.manual_discount_percent, 0)) then
        trade_discount.check_manual(:new.manual_discount_percent);
      end if;
      if :new.auto_discount_percent = 0 then :new.discount_id := null; end if;
      :new.discount_percent := least(100, :new.manual_discount_percent + :new.auto_discount_percent);
      :new.reserve_flag := nvl(:new.reserve_flag, 'N');
      if :new.reserve_flag = 'Y' and trade_nsi.is_service(:new.product_id) then
        trade_nsi.fail('RESERVE_SERVICE_PRODUCT', 'Послугу не можна резервувати.');
      end if;
      :new.amount := round(:new.quantity * :new.price * (1 - nvl(:new.discount_percent, 0) / 100), 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_CUSTOMER_ORDER_GOODS', l_doc);
      update doc_customer_order d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_customer_order_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_customer_order_goods_ct;
/

-- ---------------------------------------------------------------- рядки реалізації (db/06 + знижки r5)
create or replace trigger doc_goods_sale_goods_ct
for insert or update or delete on doc_goods_sale_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_compat boolean := false;
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_GOODS_SALE', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      trade_lines.check_goods(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id);
      -- r5 F-PRC-06: base_price — ціна до знижки; price — ціна зі знижкою (обчислюється).
      -- Вставка / зміна лише price (r2–r4 API) — це нова ціна до знижки.
      if inserting then
        if :new.base_price is null then :new.base_price := :new.price; end if;
      elsif nvl(:new.base_price, -1) = nvl(:old.base_price, -1) and nvl(:new.price, -1) <> nvl(:old.price, -1) then
        :new.base_price := :new.price;
      end if;
      if :new.base_price is null or (updating and :new.product_id <> :old.product_id and :new.base_price = :old.base_price) then
        -- Автопідстановка ціни з регістру «Ціни номенклатури»
        select price_type_id, occurred_at into l_pt, l_dt from doc_goods_sale where id = l_doc;
        if l_pt is null then
          trade_core.fail('Вкажіть ціну або вид цін у шапці документа.');
        end if;
        :new.base_price := trade_lines.get_price(l_pt, :new.product_id, l_dt);
        if :new.base_price is null then
          trade_core.fail('Для товару не встановлено ціну обраного виду на дату документа.');
        end if;
      end if;
      if :new.base_price < 0 then
        trade_core.fail('Ціна не може бути від''ємною.');
      end if;
      :new.auto_discount_percent := nvl(:new.auto_discount_percent, 0);
      if inserting and :new.manual_discount_percent is null then
        :new.manual_discount_percent := greatest(nvl(:new.discount_percent, 0) - :new.auto_discount_percent, 0);
        l_compat := true;
      elsif updating and nvl(:new.manual_discount_percent, -1) = nvl(:old.manual_discount_percent, -1)
            and :new.auto_discount_percent = :old.auto_discount_percent
            and nvl(:new.discount_percent, 0) <> nvl(:old.discount_percent, 0) then
        :new.manual_discount_percent := greatest(nvl(:new.discount_percent, 0) - :new.auto_discount_percent, 0);
        l_compat := true;
      end if;
      :new.manual_discount_percent := nvl(:new.manual_discount_percent, 0);
      if :new.manual_discount_percent not between 0 and 100 or :new.auto_discount_percent not between 0 and 100 then
        trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Знижка має бути від 0 до 100 %.');
      end if;
      if not l_compat and (inserting or :new.manual_discount_percent <> nvl(:old.manual_discount_percent, 0)) then
        trade_discount.check_manual(:new.manual_discount_percent);
      end if;
      if :new.auto_discount_percent = 0 then :new.discount_id := null; end if;
      :new.discount_percent := least(100, :new.manual_discount_percent + :new.auto_discount_percent);
      :new.price := round(:new.base_price * (1 - :new.discount_percent / 100), 2);
      :new.amount := round(:new.quantity * :new.price, 2);
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_GOODS_SALE_GOODS', l_doc);
      update doc_goods_sale d
         set d.total_amount = (select coalesce(sum(amount), 0) from doc_goods_sale_goods where document_id = l_doc)
       where d.id = l_doc;
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_goods_sale_goods_ct;
/

-- ---------------------------------------------------------------- міграція наявних рядків
begin
  trade_core.g_internal := true;
  update doc_customer_order_goods set manual_discount_percent = discount_percent, auto_discount_percent = 0
   where manual_discount_percent is null;
  update doc_goods_sale_goods set base_price = price, manual_discount_percent = 0, auto_discount_percent = 0, discount_percent = 0
   where base_price is null;
  trade_core.g_internal := false;
  commit;
exception when others then
  trade_core.g_internal := false;
  raise;
end;
/

-- ---------------------------------------------------------------- обмеження ролей і демо-умови
begin
  merge into reg_discount_limit l using (select 'SALES' r, 10 p, 'Менеджер з продажу — до 10 %' n from dual
                                         union all select 'ADMIN', 100, 'Адміністратор — без обмеження' from dual) s
     on (l.role_static_id = s.r)
   when not matched then insert (role_static_id, max_manual_percent, note) values (s.r, s.p, s.n);
  insert into ref_discount (name, discount_percent, applies_to, customer_id, description)
  select 'Постійний клієнт «Колосок»', 3, 'ALL', c.id, 'Демо: знижка постійному клієнту на все.'
    from ref_counterparty c
   where c.code = '000000028' and not exists (select 1 from ref_discount where name = 'Постійний клієнт «Колосок»');
  insert into ref_discount (name, discount_percent, applies_to, product_group_id, min_quantity, date_from, date_to, description)
  select 'Акція «Бакалія від 20 шт»', 5, 'ALL', g.id, 20, trunc(sysdate, 'MM'), add_months(trunc(sysdate, 'MM'), 3) - 1,
         'Демо: 5 % на бакалію (з підгрупами) при кількості в рядку від 20.'
    from ref_product_group g
   where g.code = '000000016' and not exists (select 1 from ref_discount where name = 'Акція «Бакалія від 20 шт»');
  commit;
end;
/

-- ---------------------------------------------------------------- меню
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
  obj('RefDiscount',      'CATALOG',              'Catalogs', 'Знижки та акції',          520, 521, 130, null);
  obj('RegDiscountLimit', 'INFORMATION_REGISTER', 'Reports',  'Обмеження ручних знижок',  530, null, 200, 'Роль: адміністратор');
  obj('DiscountsGiven',   'REPORT',               'Reports',  'Надані знижки',            540, null, 210, null);
  fp('Pricing', 'Знижки', 1, 20, 'RefDiscount', 10, 'Y');
  fp('Pricing', 'Знижки', 1, 20, 'RegDiscountLimit', 20);
  fp('Pricing', 'Звіти', 2, 10, 'DiscountsGiven', 30);
  fp('Sales', 'НСІ', 3, 10, 'RefDiscount', 40);
  fp('Sales', 'Звіти', 2, 10, 'DiscountsGiven', 90);
  fp('Main', 'Звіти', 2, 10, 'DiscountsGiven', 80);
  commit;
end;
/

-- Перекомпіляція залежних об'єктів
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
