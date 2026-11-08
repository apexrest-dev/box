-- F-REP-08 «Картка товару»: рухи товару з реєстраторами (надходження, переміщення, списання,
-- комплектація r4), прихід / розхід / наростаючий залишок кількості й вартості (RegStockCost),
-- початковий і кінцевий залишок, відбір за складом / усі склади, повнота v_recorder, меню.
-- Усі зміни відкочуються.
set serveroutput on size unlimited feedback off
declare
  t varchar2(32) := rawtohex(sys_guid());
  l_org varchar2(32); l_wh varchar2(32); l_wh2 varchar2(32); l_uom varchar2(32); l_sup varchar2(32);
  l_a varchar2(32); l_k varchar2(32); l_bom varchar2(32);
  r1 varchar2(32); r2 varchar2(32); tr varchar2(32); wo varchar2(32); asm varchar2(32);
  l_n number; l_v number; l_s varchar2(4000); l_c clob;
  d0 date := trunc(sysdate);

  procedure eq (p_name varchar2, p_got number, p_exp number) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got || ' (очікується ' || p_exp || ')');
  end;
  procedure eqs (p_name varchar2, p_got varchar2, p_exp varchar2) is
  begin
    dbms_output.put_line(case when p_got = p_exp then 'OK  ' else 'FAIL' end || ' ' || p_name || ': ' || p_got);
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
  function q (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D000'); end;
  function m (p number) return varchar2 is begin return to_char(p, 'FM999G999G999G990D00'); end;
  function bal (p_q number, p_c number) return varchar2 is
  begin
    return '<td class="r">' || q(p_q) || '</td><td class="r">' || m(p_c) || '</td></tr>';
  end;
begin
  -- ---------------------------------------------------------------- підготовка
  insert into ref_organization (name, org_kind, edrpou) values ('T15 ТОВ ' || t, 'LEGAL', '15151515') returning id into l_org;
  select id into l_uom from ref_unit_of_measure where short_name = 'шт';
  insert into ref_warehouse (name) values ('T15 склад 1 ' || t) returning id into l_wh;
  insert into ref_warehouse (name) values ('T15 склад 2 ' || t) returning id into l_wh2;
  insert into ref_product (name, unit_of_measure_id) values ('T15 Кава ' || t, l_uom) returning id into l_a;
  insert into ref_product (name, unit_of_measure_id) values ('T15 Набір ' || t, l_uom) returning id into l_k;
  insert into ref_counterparty (name) values ('T15 постачальник ' || t) returning id into l_sup;

  -- 10 × 30 (до періоду), 10 × 36 → 20 / 660, середня 33
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, d0 - 10 + 0.5)
    returning id into r1;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r1, 1, l_a, 10, 30, 0);
  trade_doc.post_goods_receipt(r1);
  insert into doc_goods_receipt (organization_id, supplier_id, warehouse_id, occurred_at) values (l_org, l_sup, l_wh, d0 - 5 + 0.5)
    returning id into r2;
  insert into doc_goods_receipt_goods (document_id, line_number, product_id, quantity, price, amount) values (r2, 1, l_a, 10, 36, 0);
  trade_doc.post_goods_receipt(r2);
  -- переміщення 5 на склад 2 (165)
  insert into doc_goods_transfer (warehouse_from_id, warehouse_to_id, occurred_at) values (l_wh, l_wh2, d0 - 4 + 0.5) returning id into tr;
  insert into doc_goods_transfer_goods (document_id, product_id, quantity) values (tr, l_a, 5);
  trade_ops.post_goods_transfer(tr);
  -- списання 2 (66)
  insert into doc_goods_write_off (warehouse_id, reason, occurred_at) values (l_wh, 'T15 псування', d0 - 3 + 0.5) returning id into wo;
  insert into doc_goods_write_off_goods (document_id, product_id, quantity) values (wo, l_a, 2);
  trade_ops.post_goods_write_off(wo);
  -- комплектація 3 наборів (1 Кава на набір): Кава −3 (99), набір +3 (99)
  insert into ref_bill_of_materials (product_id, quantity, is_main) values (l_k, 1, 'Y') returning id into l_bom;
  insert into ref_bill_of_materials_items (bom_id, product_id, quantity) values (l_bom, l_a, 1);
  insert into doc_assembly (organization_id, occurred_at, operation_kind, warehouse_id, kit_product_id, quantity)
  values (l_org, d0 - 2 + 0.5, 'ASSEMBLY', l_wh, l_k, 3) returning id into asm;
  trade_assembly.post(asm);

  -- ---------------------------------------------------------------- представлення рухів
  select count(*) into l_n from v_product_card_movement where product_id = l_a and warehouse_id = l_wh;
  eq('Рухів Кави на складі 1 (2 надходження, переміщення, списання, комплектація)', l_n, 5);
  select count(*) into l_n from v_product_card_movement where product_id = l_a;
  eq('Рухів Кави по всіх складах (переміщення — два рядки)', l_n, 6);
  select qty_out, cost_out, page_id into l_n, l_v, l_s from v_product_card_movement where recorder_id = asm and product_id = l_a;
  eq('Комплектація: розхід Кави', l_n, 3);
  eq('Комплектація: вартість розходу', l_v, 99);
  eqs('Комплектація: сторінка документа', l_s, '441');
  select qty_in, cost_in into l_n, l_v from v_product_card_movement where recorder_id = asm and product_id = l_k;
  eq('Комплектація: прихід набору', l_n, 3);
  eq('Комплектація: вартість набору', l_v, 99);
  select qty_in, cost_in into l_n, l_v from v_product_card_movement where recorder_id = tr and warehouse_id = l_wh2;
  eq('Переміщення: прихід на склад 2 з вартістю', l_n * 1000 + l_v, 5165);
  select recorder_name into l_s from v_product_card_movement where recorder_id = wo;
  eqs('Найменування реєстратора', substr(l_s, 1, 17), 'Списання товарів ');
  -- повнота: кожен реєстратор обох регістрів є у v_recorder (зі сторінкою)
  select count(*) into l_n from v_product_card_movement where page_id is null;
  eq('Рухи без документа-реєстратора у v_recorder', l_n, 0);
  select count(*) into l_n
    from (select recorder_type from reg_stock_balance_movement union select recorder_type from reg_stock_cost_mv) x
   where not exists (select 1 from v_recorder r where r.recorder_type = x.recorder_type);
  eq('Типи реєстраторів залишків / собівартості поза v_recorder', l_n, 0);

  -- ---------------------------------------------------------------- початковий залишок
  eq('Поч. залишок на склад 1 (до періоду)', trade_product_card.opening_qty(l_a, l_wh, d0 - 6), 10);
  eq('Поч. вартість на склад 1', trade_product_card.opening_cost(l_a, l_wh, d0 - 6), 300);
  eq('Поч. залишок по всіх складах після переміщення', trade_product_card.opening_qty(l_a, null, d0 - 3), 20);
  eq('Поч. вартість по всіх складах після переміщення', trade_product_card.opening_cost(l_a, null, d0 - 3), 660);

  -- ---------------------------------------------------------------- картка: склад 1
  l_c := trade_product_card.card_html(l_a, l_wh, d0 - 6, d0);
  has('Заголовок', l_c, '<h2>Картка товару</h2>');
  has('Склад у шапці', l_c, 'T15 склад 1 ' || t);
  has('Початковий залишок 10 / 300', l_c, 'Залишок на ' || to_char(d0 - 6, 'DD.MM.YYYY') || '</td><td></td><td></td><td></td><td></td>' || bal(10, 300));
  has('Надходження: прихід 10 / 360', l_c, '<td class="r">' || q(10) || '</td><td class="r">' || m(360) || '</td><td class="r"></td><td class="r"></td>');
  has('Наростаючий залишок після надходження 20 / 660', l_c, bal(20, 660));
  has('Після переміщення 15 / 495', l_c, bal(15, 495));
  has('Після списання 13 / 429', l_c, bal(13, 429));
  has('Після комплектації 10 / 330 (рядок і кінцевий залишок)', l_c, bal(10, 330), 2);
  has('Реєстратор-комплектація', l_c, 'Комплектація товарів ');
  has('Надходження до періоду не показано', l_c, '<td>' || to_char(d0 - 10 + 0.5, 'DD.MM.YYYY HH24:MI') || '</td>', 0);
  has('Без колонки «Склад» при відборі складу', l_c, '<th rowspan="2">Склад</th>', 0);
  has('Обороти: прихід 10 / 360, розхід 10 / 330', l_c,
      'Обороти за період</td><td class="r">' || q(10) || '</td><td class="r">' || m(360) || '</td><td class="r">' || q(10) || '</td><td class="r">' || m(330) || '</td>');
  has('Кількість рухів', l_c, 'Рухів: 4.');
  has('Без APEX-сесії — без посилань', l_c, '<a href=', 0);
  eq('Кінцевий залишок = залишок регістра', trade_r3.stock_qty(l_wh, l_a), 10);
  select coalesce(sum(cost_amount), 0) into l_v from reg_stock_cost_tot where warehouse_id = l_wh and product_id = l_a;
  eq('Кінцева вартість = підсумок RegStockCost', l_v, 330);

  -- ---------------------------------------------------------------- картка: усі склади
  l_c := trade_product_card.card_html(l_a, null, d0 - 6, d0);
  has('Усі склади: колонка «Склад»', l_c, '<th rowspan="2">Склад</th>');
  has('Усі склади: переміщення двома рядками', l_c, 'Переміщення товарів ', 2);
  has('Усі склади: кінцевий залишок 15 / 495', l_c, '(кінець дня)</td><td></td><td></td><td></td><td></td>' || bal(15, 495));
  has('Кількість рухів (усі склади)', l_c, 'Рухів: 5.');

  -- ---------------------------------------------------------------- порожній період, без товару
  l_c := trade_product_card.card_html(l_a, l_wh, d0 - 30, d0 - 20);
  has('Порожній період', l_c, 'Рухів за період немає');
  has('Порожній період: кінцевий залишок 0', l_c, '(кінець дня)</td><td></td><td></td><td></td><td></td>' || bal(0, 0));
  l_c := trade_product_card.card_html(null, null, d0, d0);
  has('Без товару — підказка', l_c, 'Виберіть товар.');
  -- скасування проведення прибирає рух із картки
  trade_assembly.unpost(asm);
  l_c := trade_product_card.card_html(l_a, l_wh, d0 - 6, d0);
  has('Після скасування комплектації: кінцевий залишок 13 / 429', l_c, '(кінець дня)</td><td></td><td></td><td></td><td></td>' || bal(13, 429));

  -- ---------------------------------------------------------------- меню
  select count(*) into l_n from sys_metadata_object where tech_name = 'ProductCard' and list_page_id = 450 and kind = 'REPORT';
  eq('Об''єкт метаданих «Картка товару»', l_n, 1);
  select count(*) into l_n from sys_function_panel f join sys_metadata_object o on o.id = f.object_id where o.tech_name = 'ProductCard';
  eq('Панель функцій: 4 розділи', l_n, 4);

  rollback;
exception when others then
  dbms_output.put_line('FAIL необроблена помилка: ' || sqlerrm || ' ' || dbms_utility.format_error_backtrace);
  rollback;
end;
/
