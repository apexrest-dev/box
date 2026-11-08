#!/usr/bin/env python3
"""Генерує db/13_r3_triggers.sql — тригери шапок і рядків документів r3."""
from pathlib import Path

DOCS = [
    dict(t="doc_customer_order", kind="DocCustomerOrder", open_status="'DRAFT'",
         refs=[("customer_id", "REF_COUNTERPARTY", "Покупець"), ("warehouse_id", "REF_WAREHOUSE", "Склад")],
         opt_refs=[("price_type_id", "REF_PRICE_TYPE", "Вид цін")],
         contract=("customer_id", "WITH_CUSTOMER"), totals=["total_amount"],
         extra="""    if :new.shipment_date is not null and trunc(:new.shipment_date) < trunc(:new.occurred_at) then
      trade_nsi.fail('SHIPMENT_DATE_BEFORE_ORDER_DATE', 'Дата відвантаження не може бути раніше дати замовлення.');
    end if;
    if :new.price_type_id is null and :new.contract_id is not null then
      select price_type_id into :new.price_type_id from ref_contract where id = :new.contract_id;
    end if;""",
         lines=dict(goods_only=False, amount="round(:new.quantity * :new.price * (1 - nvl(:new.discount_percent, 0) / 100), 2)",
                    price_auto="price_type", discount=True, reserve=True)),
    dict(t="doc_supplier_order", kind="DocSupplierOrder", open_status="'DRAFT'",
         refs=[("supplier_id", "REF_COUNTERPARTY", "Постачальник"), ("warehouse_id", "REF_WAREHOUSE", "Склад")],
         opt_refs=[], contract=("supplier_id", "WITH_SUPPLIER"), totals=["total_amount"],
         extra="""    if :new.expected_date is not null and trunc(:new.expected_date) < trunc(:new.occurred_at) then
      trade_nsi.fail('EXPECTED_DATE_BEFORE_ORDER_DATE', 'Очікувана дата надходження не може бути раніше дати замовлення.');
    end if;""",
         lines=dict(goods_only=False, amount="round(:new.quantity * :new.price, 2)", price_auto="supplier")),
    dict(t="doc_customer_return", kind="DocCustomerReturn", open_status="'DRAFT'",
         refs=[("customer_id", "REF_COUNTERPARTY", "Покупець"), ("warehouse_id", "REF_WAREHOUSE", "Склад")],
         opt_refs=[], contract=("customer_id", "WITH_CUSTOMER"), totals=["total_amount"], extra="",
         lines=dict(goods_only=False, amount="round(:new.quantity * :new.price, 2)", price_auto=None)),
    dict(t="doc_supplier_return", kind="DocSupplierReturn", open_status="'DRAFT'",
         refs=[("supplier_id", "REF_COUNTERPARTY", "Постачальник"), ("warehouse_id", "REF_WAREHOUSE", "Склад")],
         opt_refs=[], contract=("supplier_id", "WITH_SUPPLIER"), totals=["total_amount"],
         extra="""    :new.return_reason := trade_core.normalize_name(:new.return_reason, 255, 'Причина повернення');""",
         lines=dict(goods_only=False, amount="round(:new.quantity * :new.price, 2)", price_auto=None)),
    dict(t="doc_inventory_count", kind="DocInventoryCount", open_status="'DRAFT'",
         refs=[("warehouse_id", "REF_WAREHOUSE", "Склад")], opt_refs=[], contract=None,
         totals=None, extra="", lines=dict(goods_only=True, inventory=True)),
    dict(t="doc_surplus_posting", kind="DocSurplusPosting", open_status="'DRAFT'",
         refs=[("warehouse_id", "REF_WAREHOUSE", "Склад")], opt_refs=[], contract=None, totals=["total_amount"],
         extra="""    :new.reason := trade_core.normalize_name(:new.reason, 255, 'Причина оприбуткування');""",
         lines=dict(goods_only=True, amount="round(:new.quantity * :new.price, 2)", price_auto=None)),
    dict(t="doc_invoice_for_payment", kind="DocInvoiceForPayment", open_status="'DRAFT'",
         refs=[("customer_id", "REF_COUNTERPARTY", "Покупець")], opt_refs=[], contract=("customer_id", "WITH_CUSTOMER"),
         totals=["total_amount"],
         extra="""    if :new.payment_due_date is null then
      select trunc(:new.occurred_at) + coalesce(max(payment_term_days), 0) into :new.payment_due_date
        from ref_contract where id = :new.contract_id;
    end if;""",
         lines=dict(goods_only=False, amount="round(:new.quantity * :new.price, 2)", price_auto=None)),
]


def header_trigger(d):
    t = d["t"]
    refs = "\n".join(
        f"    if inserting or :new.{c} <> :old.{c} then\n      trade_core.check_active_ref('{tab}', :new.{c}, '{lbl}');\n    end if;"
        for c, tab, lbl in d["refs"])
    opt = "\n".join(
        f"    if :new.{c} is not null and (inserting or :new.{c} <> nvl(:old.{c}, '-')) then\n      trade_core.check_active_ref('{tab}', :new.{c}, '{lbl}');\n    end if;"
        for c, tab, lbl in d["opt_refs"])
    contract = ""
    if d["contract"]:
        owner, kind = d["contract"]
        contract = f"""    if :new.contract_id is null and inserting then
      :new.contract_id := trade_nsi.resolve_default_contract(:new.{owner}, '{kind}', :new.occurred_at);
    end if;
    trade_nsi.check_contract(:new.contract_id, :new.{owner}, '{kind}', :new.occurred_at);"""
    keep_totals = "\n".join(f"        :new.{c} := :old.{c};" for c in (d["totals"] or []))
    if d["t"] == "doc_inventory_count":
        keep_totals = "        :new.surplus_amount := :old.surplus_amount;\n        :new.shortage_amount := :old.shortage_amount;"
    has_lines = d.get("lines") is not None
    return f"""create or replace trigger {t}_biud
before insert or update or delete on {t} for each row
begin
  if deleting then
    if :old.status <> 'DRAFT' then
      trade_nsi.fail('DOCUMENT_NOT_DRAFT', 'Видалити можна лише чернетку документа.');
    end if;
    {"trade_core.g_deleting_doc := true;" if has_lines else "null;"}
  else
    if inserting then
      :new.doc_number := coalesce(trim(:new.doc_number), trade_core.next_code('{t.upper()}_NUM_SEQ'));
      :new.status := 'DRAFT'; :new.version := 0;
      :new.created_at := systimestamp; :new.created_by := trade_core.current_user_name;
    else
      if not trade_core.g_internal then
        if :old.status <> 'DRAFT' then
          trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано) і доступний лише для читання. Скасуйте проведення для зміни.');
        end if;
        :new.status := :old.status;
{keep_totals}
      end if;
      :new.version := :old.version + 1;
    end if;
    trade_core.check_code(:new.doc_number);
{refs}
{opt}
{contract}
{d["extra"]}
    :new.updated_at := systimestamp; :new.updated_by := trade_core.current_user_name;
  end if;
end;
/
create or replace trigger {t}_ad after delete on {t}
begin trade_core.g_deleting_doc := false; end;
/
"""


def lines_trigger(d):
    t = d["t"]
    lt = t + "_goods"
    L = d["lines"]
    if L.get("inventory"):
        body = """      trade_lines.check_goods_r3(:new.product_id, nvl(:new.actual_quantity, 1), inserting or :new.product_id <> :old.product_id, true);
      if :new.actual_quantity is not null and :new.actual_quantity < 0 then
        trade_nsi.fail('ACTUAL_QUANTITY_NEGATIVE', 'Фактична кількість не може бути від''ємною.');
      end if;
      :new.deviation := case when :new.actual_quantity is null then null else :new.actual_quantity - :new.book_quantity end;
      :new.deviation_amount := case when :new.deviation is null then null else round(:new.deviation * :new.price, 2) end;"""
        totals = f"""      update {t} d
         set d.surplus_amount  = (select coalesce(sum(case when deviation_amount > 0 then deviation_amount end), 0) from {lt} where document_id = l_doc),
             d.shortage_amount = (select coalesce(sum(case when deviation_amount < 0 then -deviation_amount end), 0) from {lt} where document_id = l_doc)
       where d.id = l_doc;"""
    else:
        price = ""
        if L.get("price_auto") == "price_type":
            price = f"""      if :new.price is null then
        select price_type_id, occurred_at into l_pt, l_dt from {t} where id = l_doc;
        if l_pt is null then
          trade_nsi.fail('PRICE_TYPE_REQUIRED', 'Вкажіть ціну або вид цін у шапці документа.');
        end if;
        :new.price := trade_lines.get_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_nsi.fail('PRICE_NOT_FOUND', 'Для товару не встановлено ціну обраного виду на дату документа.');
        end if;
      end if;"""
        elif L.get("price_auto") == "supplier":
            price = f"""      if :new.price is null then
        select supplier_id, occurred_at into l_pt, l_dt from {t} where id = l_doc;
        :new.price := trade_lines.get_supplier_price(l_pt, :new.product_id, l_dt);
        if :new.price is null then
          trade_nsi.fail('PRICE_REQUIRED', 'Немає ціни постачальника для товару — вкажіть ціну вручну.');
        end if;
      end if;"""
        disc = ""
        if L.get("discount"):
            disc = """      if nvl(:new.discount_percent, 0) not between 0 and 100 then
        trade_nsi.fail('DISCOUNT_OUT_OF_RANGE', 'Знижка має бути від 0 до 100 %.');
      end if;"""
        res = ""
        if L.get("reserve"):
            res = """      :new.reserve_flag := nvl(:new.reserve_flag, 'N');
      if :new.reserve_flag = 'Y' and trade_nsi.is_service(:new.product_id) then
        trade_nsi.fail('RESERVE_SERVICE_PRODUCT', 'Послугу не можна резервувати.');
      end if;"""
        body = f"""      trade_lines.check_goods_r3(:new.product_id, :new.quantity, inserting or :new.product_id <> :old.product_id, {'true' if L['goods_only'] else 'false'});
{price}
      if :new.price is null or :new.price < 0 then
        trade_nsi.fail('PRICE_REQUIRED', 'Ціна має бути заповнена і не від''ємна.');
      end if;
{disc}
{res}
      :new.amount := {L['amount']};"""
        totals = f"""      update {t} d
         set d.total_amount = (select coalesce(sum(amount), 0) from {lt} where document_id = l_doc)
       where d.id = l_doc;"""
    return f"""create or replace trigger {lt}_ct
for insert or update or delete on {lt}
compound trigger
  type t_ids is table of varchar2(32) index by varchar2(32);
  g_docs t_ids;
  before each row is
    l_doc varchar2(32) := coalesce(:new.document_id, :old.document_id);
    l_pt  varchar2(32);
    l_dt  date;
    l_st  varchar2(10);
  begin
    if not (deleting and trade_core.g_deleting_doc) then
      select status into l_st from {t} where id = l_doc;
      if l_st <> 'DRAFT' and not trade_core.g_internal then
        trade_nsi.fail('DOCUMENT_READ_ONLY', 'Документ проведено (видано): рядки доступні лише для читання.');
      end if;
      g_docs(l_doc) := l_doc;
    end if;
    if not deleting then
{body}
    end if;
  end before each row;
  after statement is
    l_doc varchar2(32) := g_docs.first;
    l_prev boolean := trade_core.g_internal;
  begin
    trade_core.g_internal := true;
    while l_doc is not null loop
      trade_lines.renumber('{lt.upper()}', l_doc);
{totals}
      l_doc := g_docs.next(l_doc);
    end loop;
    trade_core.g_internal := l_prev; g_docs.delete;
  exception when others then trade_core.g_internal := l_prev; g_docs.delete; raise;
  end after statement;
end {lt}_ct;
/
"""


def main():
    out = ["-- Згенеровано db/gen/gen_r3_triggers.py — не редагувати вручну.", ""]
    for d in DOCS:
        out.append(header_trigger(d))
        out.append(lines_trigger(d))
    Path(__file__).resolve().parents[1].joinpath("13_r3_triggers.sql").write_text("\n".join(out), encoding="utf-8")


if __name__ == "__main__":
    main()
