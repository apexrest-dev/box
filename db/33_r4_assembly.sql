-- =============================================================================
-- Trade r4 — F-WH-10 «Комплектація / розкомплектація». Паспорти RefBillOfMaterials, DocAssembly (PROPOSED).
--   * довідник ref_bill_of_materials «Специфікації наборів»: набір (товар) і кількість набору,
--     таблична частина «Комплектуючі» (товар × кількість, частка вартості для розкомплектації),
--     ознака «Основна» (одна на набір);
--   * документ doc_assembly «Комплектація товарів», вид операції ASSEMBLY (комплектація) /
--     DISASSEMBLY (розкомплектація): набір, специфікація, кількість наборів, склад,
--     таблична частина «Комплектуючі»; «Заповнити за специфікацією» (кількість × наборів /
--     кількість набору в специфікації), при проведенні без рядків — заповнюється автоматично;
--   * проведення (пакет trade_assembly): RegStockBalance −комплектуючі +набір (розкомплектація —
--     навпаки); RegStockCost: собівартість набору = Σ собівартості списаних комплектуючих
--     (середня ковзна); при розкомплектації вартість набору розподіляється на комплектуючі за
--     часткою вартості рядка специфікації (ваги рядків), інакше — за поточною середньою собівартістю × кількість,
--     інакше — за кількістю; контроль вільного залишку (залишок − резерв) списуваних товарів,
--     при скасуванні — оприбуткованих;
--   * trade_r3.rebuild_stock_cost враховує комплектацію (db/14), організація руху собівартості —
--     з документа (trade_org.doc_table, db/24), друк «Акт комплектації» (ASSEMBLY, db/20);
--   * меню «Склад → Складські операції» / «НСІ», v_recorder (+ комплектація).
-- Потребує 14 (trade_r3 add_cost/out_cost), 20, 24, 30 (v_recorder). Скрипт повторно виконуваний.
-- УВАГА: v_recorder тут перевизначено (усі реєстратори r1–r4).
-- =============================================================================
set define off

declare
  procedure ddl (p varchar2) is
  begin execute immediate p;
  exception when others then if sqlcode not in (-955, -2260, -2261, -2275, -1430, -1442, -1408) then raise; end if;
  end;
begin
  -- ---------------------------------------------------------------- RefBillOfMaterials
  ddl('create sequence ref_bill_of_materials_code_seq nocache');
  ddl(q'[create table ref_bill_of_materials (
    id          varchar2(32)  default on null rawtohex(sys_guid()) not null,
    code        varchar2(9)   not null,
    name        varchar2(255) not null,
    product_id  varchar2(32)  not null,
    quantity    number(19,3)  default on null 1 not null,
    is_main     varchar2(1)   default on null 'N' not null,
    description varchar2(1000),
    state       varchar2(20)  default on null 'ACTIVE' not null,
    version     number(19)    default on null 0 not null,
    created_at  timestamp     not null, created_by varchar2(255) not null,
    updated_at  timestamp     not null, updated_by varchar2(255) not null,
    constraint ref_bill_of_materials_pk primary key (id),
    constraint ref_bill_of_materials_code_uk unique (code),
    constraint ref_bill_of_materials_prd_fk foreign key (product_id) references ref_product (id),
    constraint ref_bill_of_materials_qty_ck check (quantity > 0),
    constraint ref_bill_of_materials_main_ck check (is_main in ('Y','N')),
    constraint ref_bill_of_materials_state_ck check (state in ('ACTIVE','MARKED_FOR_DELETION')))]');
  ddl('create index ref_bill_of_materials_prd_ix on ref_bill_of_materials (product_id)');
  ddl(q'[create table ref_bill_of_materials_items (
    id          varchar2(32)  default on null rawtohex(sys_guid()) not null,
    bom_id      varchar2(32)  not null,
    line_number number(10)    default on null 0 not null,
    product_id  varchar2(32)  not null,
    quantity    number(19,3)  not null,
    cost_share  number(9,4),
    constraint ref_bill_of_materials_items_pk primary key (id),
    constraint ref_bom_items_bom_fk foreign key (bom_id) references ref_bill_of_materials (id) on delete cascade,
    constraint ref_bom_items_prd_fk foreign key (product_id) references ref_product (id),
    constraint ref_bom_items_qty_ck check (quantity > 0),
    constraint ref_bom_items_share_ck check (cost_share is null or cost_share >= 0))]');
  ddl('create index ref_bom_items_bom_ix on ref_bill_of_materials_items (bom_id, line_number)');
  ddl('create index ref_bom_items_prd_ix on ref_bill_of_materials_items (product_id)');

  -- ---------------------------------------------------------------- DocAssembly
  ddl('create sequence doc_assembly_num_seq nocache');
  ddl(q'[create table doc_assembly (
    id               varchar2(32)   default on null rawtohex(sys_guid()) not null,
    doc_number       varchar2(9)    not null,
    occurred_at      date           default on null sysdate not null,
    organization_id  varchar2(32)   not null,
    operation_kind   varchar2(20)   default on null 'ASSEMBLY' not null,
    warehouse_id     varchar2(32)   not null,
    kit_product_id   varchar2(32)   not null,
    bom_id           varchar2(32),
    quantity         number(19,3)   default on null 1 not null,
    kit_cost_amount  number(19,2)   default on null 0 not null,
    doc_comment      varchar2(1000),
    status           varchar2(10)   default on null 'DRAFT' not null,
    version          number(19)     default on null 0 not null,
    created_at       timestamp      not null,
    created_by       varchar2(255)  not null,
    updated_at       timestamp      not null,
    updated_by       varchar2(255)  not null,
    constraint doc_assembly_pk primary key (id),
    constraint doc_assembly_num_uk unique (doc_number),
    constraint doc_assembly_status_ck check (status in ('DRAFT','POSTED')),
    constraint doc_assembly_op_ck check (operation_kind in ('ASSEMBLY','DISASSEMBLY')),
    constraint doc_assembly_qty_ck check (quantity > 0),
    constraint doc_assembly_org_fk foreign key (organization_id) references ref_organization (id),
    constraint doc_assembly_wh_fk foreign key (warehouse_id) references ref_warehouse (id),
    constraint doc_assembly_kit_fk foreign key (kit_product_id) references ref_product (id),
    constraint doc_assembly_bom_fk foreign key (bom_id) references ref_bill_of_materials (id))]');
  ddl('create index doc_assembly_date_ix on doc_assembly (occurred_at)');
  ddl('create index doc_assembly_kit_ix on doc_assembly (kit_product_id)');
  ddl('create index doc_assembly_bom_ix on doc_assembly (bom_id)');
  ddl(q'[create table doc_assembly_goods (
    id           varchar2(32)  default on null rawtohex(sys_guid()) not null,
    document_id  varchar2(32)  not null,
    line_number  number(10)    default on null 0 not null,
    product_id   varchar2(32)  not null,
    quantity     number(19,3)  not null,
    cost_amount  number(19,2)  default on null 0 not null,
    constraint doc_assembly_goods_pk primary key (id),
    constraint doc_assembly_goods_doc_fk foreign key (document_id) references doc_assembly (id) on delete cascade,
    constraint doc_assembly_goods_prd_fk foreign key (product_id) references ref_product (id),
    constraint doc_assembly_goods_qty_ck check (quantity > 0))]');
  ddl('create index doc_assembly_goods_doc_ix on doc_assembly_goods (document_id, line_number)');
  ddl('create index doc_assembly_goods_prd_ix on doc_assembly_goods (product_id)');
end;
/

create or replace package trade_assembly as
  c_type constant varchar2(60) := 'DocAssembly';
  g_main_bom varchar2(32);   -- нова основна специфікація (знімає ознаку з інших того ж набору)
  g_in_main  boolean := false;

  function operation_name (p_op in varchar2) return varchar2;

  -- ---------- специфікації наборів
  -- Основна (або єдина активна) специфікація набору
  function main_bom (p_product_id in varchar2) return varchar2;
  procedure check_bom (p_inserting in boolean, p_product_id in varchar2, p_old_product_id in varchar2, p_quantity in number);
  procedure check_bom_item (p_bom_id in varchar2, p_product_id in varchar2, p_quantity in number, p_check_ref in boolean);
  procedure renumber_bom (p_bom_id in varchar2);
  -- Орієнтовна собівартість набору за специфікацією на складі (поточні середні; null — немає даних)
  function bom_cost (p_bom_id in varchar2, p_warehouse_id in varchar2) return number;

  -- ---------- документ
  procedure check_header (p_inserting in boolean, p_op in varchar2, p_wh in varchar2, p_old_wh in varchar2,
                          p_kit in varchar2, p_old_kit in varchar2, p_bom in out varchar2, p_qty in number);
  procedure check_line (p_doc_id in varchar2, p_product_id in varchar2, p_quantity in number, p_check_ref in boolean);
  -- Заповнити комплектуючі за специфікацією (замінює рядки)
  procedure fill_by_bom (p_id in varchar2);
  procedure post   (p_id in varchar2);
  procedure unpost (p_id in varchar2);
  function  copy   (p_id in varchar2) return varchar2;
  -- Рухи RegStockCost документа (проведення й trade_r3.rebuild_stock_cost)
  procedure cost_assembly (p_id in varchar2);
  -- Вільний залишок товару рядка на складі документа (для табличної частини)
  function line_free_qty (p_doc_id in varchar2, p_product_id in varchar2) return number;
  -- Друк: ASSEMBLY — акт комплектації / розкомплектації
  function print_html (p_form in varchar2, p_id in varchar2) return clob;
end trade_assembly;
/

create or replace package body trade_assembly as

  procedure fail (p_code varchar2, p_msg varchar2) is begin trade_nsi.fail(p_code, p_msg); end;
  function e (p varchar2) return varchar2 is begin return apex_escape.html(p); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function q (p number) return varchar2 is begin return rtrim(to_char(p, 'FM999G999G990D999'), '.,'); end;

  function operation_name (p_op in varchar2) return varchar2 is
  begin
    return case p_op when 'ASSEMBLY' then 'Комплектація' when 'DISASSEMBLY' then 'Розкомплектація' end;
  end operation_name;

  function prd_name (p_id varchar2) return varchar2 is
    l varchar2(255);
  begin
    select max(name) into l from ref_product where id = p_id;
    return l;
  end prd_name;

  procedure require_goods (p_product_id varchar2, p_what varchar2) is
  begin
    if trade_nsi.is_service(p_product_id) then
      fail('PRODUCT_SERVICE_NOT_ALLOWED', '«' || prd_name(p_product_id) || '» — послуга; ' || p_what || ' може бути лише товар.');
    end if;
  end require_goods;

  -- =========================================================== специфікації
  function main_bom (p_product_id in varchar2) return varchar2 is
    l varchar2(32);
  begin
    select max(id) keep (dense_rank first order by case is_main when 'Y' then 0 else 1 end, code)
      into l from ref_bill_of_materials where product_id = p_product_id and state = 'ACTIVE';
    return l;
  end main_bom;

  procedure check_bom (p_inserting in boolean, p_product_id in varchar2, p_old_product_id in varchar2, p_quantity in number) is
  begin
    if p_product_id is null then
      fail('BOM_PRODUCT_REQUIRED', 'Вкажіть набір (товар, що комплектується).');
    end if;
    if p_inserting or p_product_id <> nvl(p_old_product_id, '-') then
      trade_core.check_active_ref('REF_PRODUCT', p_product_id, 'Набір');
      require_goods(p_product_id, 'набором');
    end if;
    trade_lines.check_goods(p_product_id, p_quantity, false);   -- кількість набору > 0, дробність одиниці
  end check_bom;

  procedure check_bom_item (p_bom_id in varchar2, p_product_id in varchar2, p_quantity in number, p_check_ref in boolean) is
    l_kit varchar2(32);
  begin
    trade_lines.check_goods_r3(p_product_id, p_quantity, p_check_ref, true);
    select product_id into l_kit from ref_bill_of_materials where id = p_bom_id;
    if l_kit = p_product_id then
      fail('BOM_KIT_IN_COMPONENTS', 'Набір «' || prd_name(l_kit) || '» не може бути власною комплектуючою.');
    end if;
  end check_bom_item;

  procedure renumber_bom (p_bom_id in varchar2) is
  begin
    merge into ref_bill_of_materials_items t
    using (select id, row_number() over (order by line_number, id) rn from ref_bill_of_materials_items where bom_id = p_bom_id) s
       on (t.id = s.id)
     when matched then update set t.line_number = s.rn where t.line_number <> s.rn;
  end renumber_bom;

  function bom_cost (p_bom_id in varchar2, p_warehouse_id in varchar2) return number is
    l number := 0; l_avg number;
  begin
    for i in (select it.product_id, it.quantity / b.quantity q
                from ref_bill_of_materials_items it join ref_bill_of_materials b on b.id = it.bom_id
               where it.bom_id = p_bom_id) loop
      l_avg := trade_r3.last_average_cost(p_warehouse_id, i.product_id);
      if l_avg is null then return null; end if;
      l := l + l_avg * i.q;
    end loop;
    return round(l, 2);
  end bom_cost;

  -- =========================================================== документ
  procedure check_header (p_inserting in boolean, p_op in varchar2, p_wh in varchar2, p_old_wh in varchar2,
                          p_kit in varchar2, p_old_kit in varchar2, p_bom in out varchar2, p_qty in number) is
    l_bom_kit varchar2(32);
  begin
    if p_op is null or operation_name(p_op) is null then
      fail('ASSEMBLY_OPERATION_KIND', 'Вкажіть вид операції: комплектація або розкомплектація.');
    end if;
    if p_inserting or p_wh <> nvl(p_old_wh, '-') then
      trade_core.check_active_ref('REF_WAREHOUSE', p_wh, 'Склад');
    end if;
    if p_kit is null then
      fail('ASSEMBLY_KIT_REQUIRED', 'Вкажіть набір.');
    end if;
    if p_inserting or p_kit <> nvl(p_old_kit, '-') then
      trade_core.check_active_ref('REF_PRODUCT', p_kit, 'Набір');
      require_goods(p_kit, 'набором');
      if not p_inserting and p_bom is not null then
        select max(product_id) into l_bom_kit from ref_bill_of_materials where id = p_bom;
        if l_bom_kit <> p_kit then p_bom := null; end if;   -- інший набір — специфікацію буде підібрано
      end if;
    end if;
    if p_bom is null then
      if p_inserting or p_kit <> nvl(p_old_kit, '-') then
        p_bom := main_bom(p_kit);   -- основна (або єдина) специфікація набору
      end if;
    else
      select max(product_id) into l_bom_kit from ref_bill_of_materials where id = p_bom;
      if l_bom_kit is null or l_bom_kit <> p_kit then
        fail('ASSEMBLY_BOM_MISMATCH', 'Специфікація не належить набору «' || prd_name(p_kit) || '».');
      end if;
    end if;
    trade_lines.check_goods(p_kit, p_qty, false);
  end check_header;

  procedure check_line (p_doc_id in varchar2, p_product_id in varchar2, p_quantity in number, p_check_ref in boolean) is
    l_kit varchar2(32);
  begin
    trade_lines.check_goods_r3(p_product_id, p_quantity, p_check_ref, true);
    select kit_product_id into l_kit from doc_assembly where id = p_doc_id;
    if l_kit = p_product_id then
      fail('ASSEMBLY_KIT_IN_COMPONENTS', 'Набір «' || prd_name(l_kit) || '» не може бути власною комплектуючою.');
    end if;
  end check_line;

  procedure fill_by_bom (p_id in varchar2) is
    d doc_assembly%rowtype;
    b ref_bill_of_materials%rowtype;
    l_cnt pls_integer;
  begin
    select * into d from doc_assembly where id = p_id for update;
    if d.status <> 'DRAFT' then
      fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
    end if;
    if d.bom_id is null then
      fail('ASSEMBLY_BOM_REQUIRED', 'Для набору «' || prd_name(d.kit_product_id) || '» немає специфікації. '
           || 'Створіть її в довіднику «Специфікації наборів» або заповніть комплектуючі вручну.');
    end if;
    select * into b from ref_bill_of_materials where id = d.bom_id;
    select count(*) into l_cnt from ref_bill_of_materials_items where bom_id = d.bom_id;
    if l_cnt = 0 then
      fail('BOM_EMPTY', 'У специфікації «' || b.name || '» немає комплектуючих.');
    end if;
    delete from doc_assembly_goods where document_id = p_id;
    for i in (select product_id, quantity from ref_bill_of_materials_items where bom_id = d.bom_id order by line_number) loop
      insert into doc_assembly_goods (document_id, line_number, product_id, quantity)
      values (p_id, null, i.product_id, round(i.quantity * d.quantity / b.quantity, 3));
    end loop;
    trade_core.audit(c_type, p_id, 'FILL_BY_BOM', b.code);
  end fill_by_bom;

  function line_free_qty (p_doc_id in varchar2, p_product_id in varchar2) return number is
    l_wh varchar2(32);
  begin
    select max(warehouse_id) into l_wh from doc_assembly where id = p_doc_id;
    if l_wh is null or p_product_id is null then return null; end if;
    return trade_r3.stock_qty(l_wh, p_product_id) - trade_r3.reserved_qty(l_wh, p_product_id);
  end line_free_qty;

  procedure delete_movements (p_id varchar2) is
  begin
    delete from reg_stock_balance_movement where recorder_type = c_type and recorder_id = p_id;
    trade_r3.delete_r3_movements(c_type, p_id);
  end delete_movements;

  -- Вартісні рухи; рядки отримують собівартість комплектуючих, шапка — собівартість набору
  procedure cost_assembly (p_id in varchar2) is
    d doc_assembly%rowtype;
    b_share_total number; l_w_total number := 0; l_left number; l_c number; l_total number := 0;
    l_cnt pls_integer; l_i pls_integer := 0;
    type t_num is table of number index by pls_integer;
    l_w t_num;
  begin
    select * into d from doc_assembly where id = p_id;
    if d.operation_kind = 'ASSEMBLY' then
      for l in (select line_number, product_id, quantity from doc_assembly_goods where document_id = p_id order by line_number) loop
        l_c := trade_r3.out_cost(d.warehouse_id, l.product_id, l.quantity);
        trade_r3.add_cost(c_type, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, -l.quantity, -l_c);
        update doc_assembly_goods set cost_amount = l_c where document_id = p_id and line_number = l.line_number;
        l_total := l_total + l_c;
      end loop;
      trade_r3.add_cost(c_type, p_id, 0, d.occurred_at, d.warehouse_id, d.kit_product_id, d.quantity, l_total);
    else
      l_total := trade_r3.out_cost(d.warehouse_id, d.kit_product_id, d.quantity);
      trade_r3.add_cost(c_type, p_id, 0, d.occurred_at, d.warehouse_id, d.kit_product_id, -d.quantity, -l_total);
      -- База розподілу: частка вартості специфікації → середня собівартість × кількість → кількість
      select count(*), sum(it.cost_share) into l_cnt, b_share_total
        from ref_bill_of_materials_items it where it.bom_id = d.bom_id and it.cost_share > 0;
      for l in (select g.line_number, g.product_id, g.quantity,
                       (select max(it.cost_share) from ref_bill_of_materials_items it
                         where it.bom_id = d.bom_id and it.product_id = g.product_id) bom_share
                  from doc_assembly_goods g where g.document_id = p_id order by g.line_number) loop
        l_i := l_i + 1;
        l_w(l_i) := case when b_share_total > 0 then nvl(l.bom_share, 0)
                         else nvl(trade_r3.last_average_cost(d.warehouse_id, l.product_id), 0) * l.quantity end;
        l_w_total := l_w_total + l_w(l_i);
      end loop;
      if l_w_total = 0 then
        l_i := 0;
        for l in (select quantity from doc_assembly_goods where document_id = p_id order by line_number) loop
          l_i := l_i + 1; l_w(l_i) := l.quantity; l_w_total := l_w_total + l.quantity;
        end loop;
      end if;
      l_left := l_total; l_i := 0;
      select count(*) into l_cnt from doc_assembly_goods where document_id = p_id;
      for l in (select line_number, product_id, quantity from doc_assembly_goods where document_id = p_id order by line_number) loop
        l_i := l_i + 1;
        l_c := case when l_i = l_cnt then l_left when l_w_total > 0 then round(l_total * l_w(l_i) / l_w_total, 2) else 0 end;
        l_left := l_left - l_c;
        trade_r3.add_cost(c_type, p_id, l.line_number, d.occurred_at, d.warehouse_id, l.product_id, l.quantity, l_c);
        update doc_assembly_goods set cost_amount = l_c where document_id = p_id and line_number = l.line_number;
      end loop;
    end if;
    update doc_assembly set kit_cost_amount = l_total where id = p_id;
  end cost_assembly;

  procedure check_lines (d doc_assembly%rowtype) is
    l_cnt pls_integer;
  begin
    select count(*) into l_cnt from doc_assembly_goods where document_id = d.id;
    if l_cnt = 0 then
      fail('NO_LINES', 'Неможливо провести документ без рядків у табличній частині «Комплектуючі».');
    end if;
    select count(*) into l_cnt from doc_assembly_goods where document_id = d.id and product_id = d.kit_product_id;
    if l_cnt > 0 then
      fail('ASSEMBLY_KIT_IN_COMPONENTS', 'Набір «' || prd_name(d.kit_product_id) || '» не може бути власною комплектуючою.');
    end if;
    for r in (select g.line_number, p.name from doc_assembly_goods g join ref_product p on p.id = g.product_id
               where g.document_id = d.id and p.product_kind <> 'GOODS' order by g.line_number) loop
      fail('PRODUCT_SERVICE_NOT_ALLOWED', 'Рядок ' || r.line_number || ': «' || r.name || '» — послуга; комплектуючими можуть бути лише товари.');
    end loop;
  end check_lines;

  procedure post (p_id in varchar2) is
    d doc_assembly%rowtype;
    l_dummy varchar2(32); l_cnt pls_integer;
  begin
    select * into d from doc_assembly where id = p_id for update;
    select count(*) into l_cnt from doc_assembly_goods where document_id = p_id;
    if l_cnt = 0 and d.bom_id is not null and d.status = 'DRAFT' then
      fill_by_bom(p_id);   -- «Провести» без рядків — комплектуючі за специфікацією
    end if;
    check_lines(d);
    select id into l_dummy from ref_warehouse where id = d.warehouse_id for update;
    trade_core.g_internal := true;
    delete_movements(p_id);
    if d.operation_kind = 'ASSEMBLY' then
      insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
      select d.occurred_at, c_type, p_id, line_number, d.warehouse_id, product_id, -quantity
        from doc_assembly_goods where document_id = p_id;
      insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
      values (d.occurred_at, c_type, p_id, 0, d.warehouse_id, d.kit_product_id, d.quantity);
      trade_r3.check_free_stock_doc('DOC_ASSEMBLY_GOODS', p_id, d.warehouse_id);
    else
      insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
      values (d.occurred_at, c_type, p_id, 0, d.warehouse_id, d.kit_product_id, -d.quantity);
      insert into reg_stock_balance_movement (period, recorder_type, recorder_id, line_number, warehouse_id, product_id, quantity)
      select d.occurred_at, c_type, p_id, line_number, d.warehouse_id, product_id, quantity
        from doc_assembly_goods where document_id = p_id;
      trade_r3.check_free_stock(d.warehouse_id, d.kit_product_id);
    end if;
    cost_assembly(p_id);
    select * into d from doc_assembly where id = p_id;
    if d.kit_cost_amount = 0 then
      trade_warn.add('ASSEMBLY_ZERO_COST', case d.operation_kind when 'ASSEMBLY'
        then 'собівартість комплектуючих нульова — набір оприбутковано з нульовою вартістю.'
        else 'собівартість набору нульова — комплектуючі оприбутковано з нульовою вартістю.' end);
    end if;
    update doc_assembly set status = 'POSTED' where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'POST');
  exception when others then trade_core.g_internal := false; raise;
  end post;

  procedure unpost (p_id in varchar2) is
    d doc_assembly%rowtype;
    l_dummy varchar2(32);
  begin
    select * into d from doc_assembly where id = p_id for update;
    if d.status <> 'POSTED' then
      fail('NOT_POSTED', 'Документ не проведено.');
    end if;
    select id into l_dummy from ref_warehouse where id = d.warehouse_id for update;
    trade_core.g_internal := true;
    delete_movements(p_id);
    -- оприбутковане документом не має бути вже спожите (продане, списане, зарезервоване)
    if d.operation_kind = 'ASSEMBLY' then
      trade_r3.check_free_stock(d.warehouse_id, d.kit_product_id);
    else
      trade_r3.check_free_stock_doc('DOC_ASSEMBLY_GOODS', p_id, d.warehouse_id);
    end if;
    update doc_assembly_goods set cost_amount = 0 where document_id = p_id;
    update doc_assembly set status = 'DRAFT', kit_cost_amount = 0 where id = p_id;
    trade_core.g_internal := false;
    trade_core.audit(c_type, p_id, 'UNPOST');
  exception when others then trade_core.g_internal := false; raise;
  end unpost;

  function copy (p_id in varchar2) return varchar2 is
    l_new varchar2(32) := rawtohex(sys_guid());
  begin
    insert into doc_assembly (id, occurred_at, organization_id, operation_kind, warehouse_id, kit_product_id, bom_id, quantity, doc_comment)
    select l_new, sysdate, organization_id, operation_kind, warehouse_id, kit_product_id, bom_id, quantity, doc_comment
      from doc_assembly where id = p_id;
    insert into doc_assembly_goods (document_id, line_number, product_id, quantity)
    select l_new, line_number, product_id, quantity from doc_assembly_goods where document_id = p_id;
    trade_core.audit(c_type, l_new, 'COPY', 'Копія ' || p_id);
    return l_new;
  end copy;

  -- =========================================================== друк
  function print_html (p_form in varchar2, p_id in varchar2) return clob is
    l clob;
    o ref_organization%rowtype;
    l_wh varchar2(255); l_bom varchar2(300); l_unit varchar2(20);
  begin
    if p_form <> 'ASSEMBLY' then return null; end if;
    for r in (select * from doc_assembly where id = p_id) loop
      select * into o from ref_organization where id = r.organization_id;
      select name into l_wh from ref_warehouse where id = r.warehouse_id;
      select max(code || ' ' || name) into l_bom from ref_bill_of_materials where id = r.bom_id;
      select u.short_name into l_unit from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id
       where p.id = r.kit_product_id;
      l := '<div class="tx-print"><style>'
        || '.tx-print{font-family:Arial,sans-serif;font-size:13px;color:#000;max-width:1100px;background:#fff;padding:16px;position:relative}'
        || '.tx-print h2{font-size:17px;text-align:center;margin:10px 0 4px}.tx-print .sub{text-align:center;margin-bottom:12px}'
        || '.tx-print table{border-collapse:collapse;width:100%;margin-bottom:10px}'
        || '.tx-print .grid th,.tx-print .grid td{border:1px solid #000;padding:3px 6px;vertical-align:top}'
        || '.tx-print .grid th{background:#f2f2f2;font-weight:normal;font-size:11px}.tx-print .tot td{font-weight:bold}'
        || '.tx-print .r{text-align:right;white-space:nowrap}.tx-print .c{text-align:center}'
        || '.tx-print .signs{display:flex;gap:40px;margin-top:24px}.tx-print .signs>div{flex:1}'
        || '.tx-print .wm{position:absolute;top:200px;left:0;right:0;text-align:center;font-size:72px;color:rgba(200,0,0,.13);transform:rotate(-24deg);pointer-events:none;font-weight:bold}'
        || '@media print{.t-Header,.t-Body-nav,.tx-open-tabs,.tx-form-title,.t-Button,.tx-print-bar{display:none!important}}</style>'
        || case when r.status = 'DRAFT' then '<div class="wm">ЧЕРНЕТКА</div>' end
        || '<h2>Акт ' || case r.operation_kind when 'ASSEMBLY' then 'комплектації' else 'розкомплектації' end
        || ' товарів № ' || e(r.doc_number) || '</h2><div class="sub">від ' || to_char(r.occurred_at, 'DD.MM.YYYY') || '</div>'
        || '<table class="grid"><tr><th style="width:25%">Організація</th><td><b>' || e(coalesce(o.full_name, o.name)) || '</b>'
        || case when o.edrpou is not null then '<br>Код ЄДРПОУ ' || e(o.edrpou) end || '</td></tr>'
        || '<tr><th>Склад</th><td>' || e(l_wh) || '</td></tr>'
        || '<tr><th>Набір</th><td><b>' || e(prd_name(r.kit_product_id)) || '</b>, ' || q(r.quantity) || ' ' || e(l_unit)
        || case when r.status = 'POSTED' then ', собівартість ' || m(r.kit_cost_amount) || ' грн' end || '</td></tr>'
        || case when l_bom is not null then '<tr><th>Специфікація</th><td>' || e(l_bom) || '</td></tr>' end
        || '</table><table class="grid"><tr><th>№</th><th>'
        || case r.operation_kind when 'ASSEMBLY' then 'Списано комплектуючих' else 'Оприбутковано комплектуючих' end
        || '</th><th>Од.</th><th>Кількість</th>' || case when r.status = 'POSTED' then '<th>Собівартість, грн</th>' end || '</tr>';
      for g in (select g.line_number, p.name, u.short_name, g.quantity, g.cost_amount
                  from doc_assembly_goods g join ref_product p on p.id = g.product_id
                  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
                 where g.document_id = p_id order by g.line_number) loop
        l := l || '<tr><td class="c">' || g.line_number || '</td><td>' || e(g.name) || '</td><td class="c">' || e(g.short_name)
               || '</td><td class="r">' || q(g.quantity) || '</td>'
               || case when r.status = 'POSTED' then '<td class="r">' || m(g.cost_amount) || '</td>' end || '</tr>';
      end loop;
      if r.status = 'POSTED' then
        l := l || '<tr class="tot"><td colspan="4" class="r">Разом</td><td class="r">' || m(r.kit_cost_amount) || '</td></tr>';
      end if;
      l := l || '</table>'
        || case when r.doc_comment is not null then '<p>Примітка: ' || e(r.doc_comment) || '</p>' end
        || '<div class="signs"><div>Здав: ____________________</div><div>Комплектувальник: ____________________</div>'
        || '<div>Комірник: ____________________</div></div></div>';
    end loop;
    return l;
  end print_html;

end trade_assembly;
/

-- ---------------------------------------------------------------- тригери специфікації
create or replace trigger ref_bill_of_materials_biu
before insert or update on ref_bill_of_materials for each row
begin
  if inserting then
    :new.code := coalesce(trim(:new.code), trade_core.next_code('REF_BILL_OF_MATERIALS_CODE_SEQ'));
    :new.version := 0;
    :new.state := coalesce(:new.state, 'ACTIVE');
    :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
  else
    :new.version := :old.version + 1;
  end if;
  trade_core.check_code(:new.code);
  trade_assembly.check_bom(inserting, :new.product_id, :old.product_id, :new.quantity);
  if trim(:new.name) is null then
    select substr('Специфікація: ' || name, 1, 255) into :new.name from ref_product where id = :new.product_id;
  end if;
  :new.name := trade_core.normalize_name(:new.name, 255, 'Найменування');
  :new.description := trim(:new.description);
  if :new.state <> 'ACTIVE' then
    :new.is_main := 'N';
  end if;
  if :new.is_main = 'Y' and not trade_assembly.g_in_main then
    trade_assembly.g_main_bom := :new.id;
  end if;
  :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
end;
/
-- Одна основна специфікація набору: нова ознака знімає попередню
create or replace trigger ref_bill_of_materials_as
after insert or update on ref_bill_of_materials
declare
  l varchar2(32) := trade_assembly.g_main_bom;
begin
  if l is not null and not trade_assembly.g_in_main then
    trade_assembly.g_main_bom := null;
    trade_assembly.g_in_main := true;
    update ref_bill_of_materials set is_main = 'N'
     where is_main = 'Y' and id <> l and product_id = (select product_id from ref_bill_of_materials where id = l);
    trade_assembly.g_in_main := false;
  end if;
exception when others then
  trade_assembly.g_in_main := false;
  raise;
end;
/
create or replace trigger ref_bill_of_materials_bd before delete on ref_bill_of_materials
begin trade_core.fail('Фізичне видалення заборонене. Використайте «Помітити на видалення».'); end;
/
create or replace trigger ref_bom_items_ct
for insert or update or delete on ref_bill_of_materials_items
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_boms t_ids;
  before each row is
  begin
    g_boms(coalesce(:new.bom_id, :old.bom_id)) := coalesce(:new.bom_id, :old.bom_id);
    if not deleting then
      trade_assembly.check_bom_item(:new.bom_id, :new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id);
      if :new.line_number is null then :new.line_number := 0; end if;
    end if;
  end before each row;
  after statement is
    l varchar2(32) := g_boms.first;
  begin
    while l is not null loop
      trade_assembly.renumber_bom(l);
      l := g_boms.next(l);
    end loop;
    g_boms.delete;
  exception when others then g_boms.delete; raise;
  end after statement;
end ref_bom_items_ct;
/

-- ---------------------------------------------------------------- тригери документа
create or replace trigger doc_assembly_org_biu
before insert or update of organization_id on doc_assembly for each row
begin trade_org.resolve_doc_org(:new.organization_id, :old.organization_id, null, null, inserting); end;
/
create or replace trigger doc_assembly_biud
before insert or update or delete on doc_assembly for each row
follows doc_assembly_org_biu
begin
  if deleting then
    if :old.status = 'POSTED' then
      trade_nsi.fail('DOCUMENT_POSTED', 'Проведений документ не можна видалити. Спочатку скасуйте проведення.');
    end if;
    trade_core.g_deleting_doc := true;
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('DOC_ASSEMBLY_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0; :new.kit_cost_amount := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status = 'POSTED' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
        :new.kit_cost_amount := :old.kit_cost_amount;
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
    trade_assembly.check_header(inserting, :new.operation_kind, :new.warehouse_id, :old.warehouse_id,
      :new.kit_product_id, :old.kit_product_id, :new.bom_id, :new.quantity);
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger doc_assembly_ad after delete on doc_assembly
begin trade_core.g_deleting_doc := false; end;
/
create or replace trigger doc_assembly_goods_ct
for insert or update or delete on doc_assembly_goods
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      trade_lines.check_editable('DOC_ASSEMBLY', l_doc);
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
      if :new.line_number is null then :new.line_number := 0; end if;
      if not trade_core.g_internal then
        :new.cost_amount := case when updating then :old.cost_amount else 0 end;   -- собівартість — лише проведенням
      end if;
      if inserting or :new.product_id <> :old.product_id or :new.quantity <> :old.quantity then
        trade_assembly.check_line(:new.document_id, :new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id);
      end if;
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('DOC_ASSEMBLY_GOODS', l_doc);
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end doc_assembly_goods_ct;
/

-- ---------------------------------------------------------------- реєстратори (+ комплектація)
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
                 || d.doc_number || ' від ' || to_char(d.occurred_at, 'DD.MM.YYYY HH24:MI:SS'), 441 from doc_assembly d;

-- Списки (сторінки 430, 440)
create or replace view v_bill_of_materials_list as
select b.id, b.code, b.name, b.product_id, p.name product_name, b.quantity, u.short_name unit_name,
       case b.is_main when 'Y' then 'Так' end main_name,
       (select count(*) from ref_bill_of_materials_items i where i.bom_id = b.id) items_count,
       b.state
  from ref_bill_of_materials b
  join ref_product p on p.id = b.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id;

create or replace view v_assembly_list as
select d.id, d.doc_number, d.occurred_at, d.organization_id, o.name organization_name,
       d.operation_kind, trade_assembly.operation_name(d.operation_kind) operation_name,
       d.warehouse_id, w.name warehouse_name, d.kit_product_id, p.name kit_name, d.quantity,
       d.kit_cost_amount, d.status, d.doc_comment
  from doc_assembly d
  join ref_organization o on o.id = d.organization_id
  join ref_warehouse w on w.id = d.warehouse_id
  join ref_product p on p.id = d.kit_product_id;

-- ---------------------------------------------------------------- меню: «Склад»
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
  obj('RefBillOfMaterials', 'CATALOG',  'Catalogs',  'Специфікації наборів', 430, 431, 100, null);
  obj('DocAssembly',        'DOCUMENT', 'Documents', 'Комплектація товарів', 440, 441, 180, 'Роль: склад');
  fp('Warehouse', 'Складські операції', 1, 10, 'DocAssembly', 50);
  fp('Warehouse', 'НСІ', 3, 10, 'RefBillOfMaterials', 50);
  fp('Reference', 'Номенклатура', 1, 10, 'RefBillOfMaterials', 40);
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
