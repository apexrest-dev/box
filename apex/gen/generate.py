#!/usr/bin/env python3
"""Генератор APEXlang-сторінок застосунку Trade зі специфікацій паспортів.

Запуск:  python3 apex/gen/generate.py
Пише файли у apex/trade/pages та apex/trade/shared-components.
"""
from pathlib import Path
from textwrap import indent

ROOT = Path(__file__).resolve().parents[1] / "trade"
PAGES = ROOT / "pages"
SC = ROOT / "shared-components"


def block(name, body):
    """name { ... } група властивостей."""
    return f"{name} {{\n{indent(body.rstrip(), '    ')}\n}}"


def code(lang, text):
    text = text.strip("\n")
    return f"\n    ```{lang}\n{indent(text, '    ')}\n    ```"


def comp(kind, ident, body):
    return f"{kind} {ident} (\n{indent(body.rstrip(), '    ')}\n)\n"


def narrow_labels_above(text):
    """Поля шириною 1–2 колонки з горизонтальною міткою (шаблони optional / required) не рендеряться:
    UT потребує labelColumnSpan < columnSpan («Label Column Span of 2 … only has 2 Column(s)»).
    Такі поля отримують мітку над полем (optional-above / required-above)."""
    out, narrow = [], False
    for ln in text.split("\n"):
        st = ln.strip()
        if st.startswith("pageItem "):
            narrow = False
        elif st in ("columnSpan: 1", "columnSpan: 2"):
            narrow = True
        elif narrow and st in ("template: @/optional", "template: @/required"):
            ln += "-above"
            narrow = False
        out.append(ln)
    return "\n".join(out)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.name == "pages":
        text = narrow_labels_above(text)
    path.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------------------
# Специфікації довідників (паспорти Ref*)
# ---------------------------------------------------------------------------
STATE_SQL = "case state when 'ACTIVE' then 'Активний' else 'Помічений на видалення' end state_name"

CATALOGS = [
    dict(list_page=10, form_page=11, alias="units-of-measure", table="REF_UNIT_OF_MEASURE",
         title="Одиниці виміру", item_title="Одиниця виміру",
         list_sql="select id, code, name, short_name, case fractional when 'Y' then 'Так' else 'Ні' end fractional_name, "
                  + STATE_SQL + " from ref_unit_of_measure",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("SHORT_NAME", "Скорочене найменування"),
                  ("FRACTIONAL_NAME", "Дробова кількість"), ("STATE_NAME", "Стан")],
         fields=[
             dict(col="CODE", label="Код", type="text", max=9, span=3,
                  help="Порожній код буде призначено автоматично під час запису."),
             dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
             dict(col="SHORT_NAME", label="Скорочене найменування", type="text", max=20, required=True, span=6),
             dict(col="FRACTIONAL", label="Дозволити дробову кількість", type="switch", span=6, newcol=True),
         ]),
    dict(list_page=20, form_page=21, alias="products", table="REF_PRODUCT",
         title="Товари", item_title="Товар",
         list_sql="select p.id, p.code, p.name, u.short_name unit_name, "
                  + STATE_SQL.replace("state", "p.state", 1)
                  + " from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("UNIT_NAME", "Одиниця виміру"), ("STATE_NAME", "Стан")],
         fields=[
             dict(col="CODE", label="Код", type="text", max=9, span=3,
                  help="Порожній код буде призначено автоматично під час запису."),
             dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
             dict(col="UNIT_OF_MEASURE_ID", label="Одиниця виміру", type="ref", lov="UNITS_OF_MEASURE_ACTIVE",
                  required=True, span=12),
         ]),
    dict(list_page=30, form_page=31, alias="warehouses", table="REF_WAREHOUSE",
         title="Склади", item_title="Склад",
         list_sql="select id, code, name, " + STATE_SQL + " from ref_warehouse",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("STATE_NAME", "Стан")],
         fields=[
             dict(col="CODE", label="Код", type="text", max=9, span=3,
                  help="Порожній код буде призначено автоматично під час запису."),
             dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
         ]),
    dict(list_page=40, form_page=41, alias="counterparties", table="REF_COUNTERPARTY",
         title="Контрагенти", item_title="Контрагент",
         list_sql="select id, code, name, " + STATE_SQL + " from ref_counterparty",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("STATE_NAME", "Стан")],
         fields=[
             dict(col="CODE", label="Код", type="text", max=9, span=3,
                  help="Порожній код буде призначено автоматично під час запису."),
             dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
         ]),
    dict(list_page=90, form_page=91, alias="price-types", table="REF_PRICE_TYPE",
         title="Види цін", item_title="Вид цін",
         list_sql="select id, code, name, currency_code, " + STATE_SQL + " from ref_price_type",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("CURRENCY_CODE", "Валюта"), ("STATE_NAME", "Стан")],
         fields=[
             dict(col="CODE", label="Код", type="text", max=9, span=3,
                  help="Порожній код буде призначено автоматично під час запису."),
             dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
         ]),
]


# ---------------------------------------------------------------------------
# Будівельні блоки
# ---------------------------------------------------------------------------
PAGE_AUTH = {}   # номер сторінки → схема авторизації


def page_header(num, name, alias, title, modal=False, extra=""):
    appearance = "pageMode: modalDialog\ndialogTemplate: @/modal-dialog\n" if modal else "pageTemplate: @/standard\n"
    body = f"name: {name}\nalias: {alias.upper()}\ntitle: {title}\n"
    body += block("appearance", appearance + "templateOptions: #DEFAULT#") + "\n"
    if modal:
        body += block("dialog", "width: 720\nchained: false") + "\n"
    if PAGE_AUTH.get(num):
        body += block("security", f"authorizationScheme: @{PAGE_AUTH[num]}") + "\n"
    body += extra
    return body


def title_region(text, seq=1):
    html = ('<div class="tx-form-title"><span class="tx-nav-btn tx-nav-back" title="Назад" role="button">&#8592;</span>'
            '<span class="tx-nav-btn tx-nav-forward" title="Вперед" role="button">&#8594;</span>'
            '<span class="tx-star fa fa-star-o" title="Додати в обране" role="button"></span>'
            f'<h1>{text}</h1></div>')
    b = "name: Заголовок форми\ntype: staticContent\n"
    b += block("source", "htmlCode: " + html) + "\n"
    b += block("layout", f"sequence: {seq}\nslot: body") + "\n"
    b += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    return comp("region", "form-title", b)


def ir_column(name, heading, seq, dtype="varchar2", hidden=False, extra=""):
    b = f"type: {'hidden' if hidden else 'plainText'}\n"
    b += block("source", f"dataType: {dtype}") + "\n"
    num = dtype == "number" and not hidden
    b += block("heading", f"heading: {heading}" + ("\nalignment: end" if num else "")) + "\n"
    b += block("layout", f"sequence: {seq}" + ("\ncolumnAlignment: end" if num else "")) + "\n"
    b += extra
    return comp("column", name, b)


def ir_region(ident, name, sql, columns, seq=10, link=None, extra_attrs="", parent=None, title=None, template="@/interactive-report"):
    """columns: list of (name, heading, dtype, hidden, extra)"""
    b = f"name: {name}\n"
    if title:
        b += f"title: {title}\n"
    b += "type: interactiveReport\n"
    b += block("source", "location: localDatabase\ntype: sqlQuery\nsqlQuery:" + code("sql", sql)) + "\n"
    lay = f"sequence: {seq}\n"
    lay += f"parentRegion: @{parent}\nslot: subRegions\n" if parent else "slot: body\n"
    b += block("layout", lay) + "\n"
    b += block("appearance", f"template: {template}\ntemplateOptions: #DEFAULT#") + "\n"
    if link:
        b += block("link", link) + "\n"
    else:
        b += block("link", "linkColumn: exclude") + "\n"
    b += block("pagination", "type: rowRangesXToYOfZ") + "\n"
    b += block("advanced", f"savedReportMappingIdentifier: {next_mapping_id()}") + "\n"
    b += extra_attrs
    b += "\n"
    for i, c in enumerate(columns):
        nm, hd = c[0], c[1]
        dt = c[2] if len(c) > 2 else "varchar2"
        hid = c[3] if len(c) > 3 else False
        ex = c[4] if len(c) > 4 else ""
        b += "\n" + ir_column(nm, hd, (i + 1) * 10, dt, hid, ex)
    return comp("region", ident, b)


def button(ident, name, label, seq, region, slot="next", hot=False, action=None, target=None,
           condition=None, db_action=None, confirm=None, icon=None, validations=True, auth=None):
    b = f"buttonName: {name}\nlabel: {label}\n"
    b += block("layout", f"sequence: {seq}\nregion: @{region}\nslot: {slot}") + "\n"
    ap = f"buttonTemplate: @/{'text-with-icon' if icon else 'text'}\nhot: {'true' if hot else 'false'}\ntemplateOptions: #DEFAULT#"
    if icon:
        ap += f"\nicon: {icon}"
    b += block("appearance", ap) + "\n"
    beh = ""
    if action:
        beh += f"action: {action}\n"
    if target:
        beh += f"target: {target}\n"
    if db_action:
        beh += f"databaseAction: {db_action}\n"
    if not validations:
        beh += "executeValidations: false\n"
    if confirm:
        beh += "requiresConfirmation: true\n"
    if beh:
        b += block("behavior", beh) + "\n"
    if confirm:
        b += block("confirmation", f"message: {confirm}\nstyle: warning") + "\n"
    if condition:
        b += block("serverSideCondition", condition) + "\n"
    if auth:
        b += block("security", f"authorizationScheme: @{auth}") + "\n"
    return comp("button", ident, b)


def process(ident, name, ptype, seq, body="", point=None, when_button=None, when_request_in=None, success=None, condition=None):
    b = f"name: {name}\ntype: {ptype}\n" + body
    ex = f"sequence: {seq}\n"
    if point:
        ex += f"point: {point}\n"
    b += block("execution", ex) + "\n"
    if when_button or when_request_in or condition:
        c = ""
        if when_button:
            c += f"whenButtonPressed: @{when_button}\n"
        if when_request_in:
            c += f"type: expression\nlanguage: plsql\nplsqlExpression: {request_in(when_request_in)}\n"
        if condition:
            c += condition
        b += block("serverSideCondition", c) + "\n"
    if success:
        b += block("successMessage", f"successMessage: {success}") + "\n"
    b += block("advanced", f"executionMappingIdentifier: {next_mapping_id()}") + "\n"
    return comp("process", ident, b)


def request_in(values):
    return ":REQUEST in (" + ", ".join("'" + v + "'" for v in values.split(",")) + ")"


_MAP_ID = [910000000000]


def next_mapping_id():
    _MAP_ID[0] += 1
    return _MAP_ID[0]


def branch(ident, name, seq, target, when_button=None, when_request_in=None):
    b = f"name: {name}\n"
    b += block("behavior", f"type: pageOrUrl\ntarget: {target}") + "\n"
    b += block("execution", f"sequence: {seq}\npoint: afterProcessing") + "\n"
    if when_button or when_request_in:
        c = f"whenButtonPressed: @{when_button}\n" if when_button else f"type: expression\nlanguage: plsql\nplsqlExpression: {request_in(when_request_in)}\n"
        b += block("serverSideCondition", c) + "\n"
    return comp("branch", ident, b)


def form_item(page, region, f, seq, readonly_cond=None):
    item = f"P{page}_{f['col']}"
    t = f["type"]
    typ = {"text": "textField", "switch": "switch", "ref": "popupLov", "number": "numberField", "select": "selectList",
           "date": "datePicker", "textarea": "textarea", "display": "displayOnly", "hidden": "hidden"}[t]
    b = f"type: {typ}\n"
    if t != "hidden":
        b += block("label", f"label: {f['label']}\nalignment: right") + "\n"
    lay = f"sequence: {seq}\nregion: @{region}\nslot: regionBody\n"
    if f.get("span"):
        lay += f"columnSpan: {f['span']}\n"
    if f.get("newcol"):
        lay += "startNewRow: false\n"
    if f.get("column"):
        lay += f"column: {f['column']}\n"
    b += lay and block("layout", lay) + "\n"
    if t != "hidden":
        ap = "template: @/" + ("required" if f.get("required") else "optional") + "\ntemplateOptions: #DEFAULT#\n"
        if f.get("format"):
            ap += f"formatMask: {f['format']}\n"
        b += block("appearance", ap) + "\n"
    if t in ("text", "textarea") and f.get("max"):
        b += block("validation", f"maxLength: {f['max']}" + ("\nvalueRequired: true" if f.get("required") else "")) + "\n"
    elif f.get("required"):
        b += block("validation", "valueRequired: true") + "\n"
    dtype = f.get("dtype", "varchar2")
    src = f"formRegion: @{f.get('src_region', region)}\ncolumn: {f['col']}\ndataType: {dtype}\n"
    if f.get("pk"):
        src += "primaryKey: true\n"
    if f.get("query_only"):
        src += "queryOnly: true\n"
    b += block("source", src) + "\n"
    if f.get("default"):
        b += block("default", f["default"]) + "\n"
    if t == "switch":
        b += block("settings", "useDefaults: false\nonValue: Y\nonLabel: Так\noffValue: N\noffLabel: Ні") + "\n"
    if t == "display" and f.get("lov"):
        b += block("lov", f"type: sharedComponent\nlov: @{f['lov']}\ndisplayExtraValues: true") + "\n"
        b += block("settings", "basedOn: lov\nsendOnPageSubmit: true") + "\n"
    if t == "select":
        b += block("lov", f"type: sharedComponent\nlov: @{f['lov']}\ndisplayExtraValues: true\ndisplayNullValue: {'false' if f.get('required') else 'true'}") + "\n"
    if t == "ref" and f.get("lov_sql"):
        sql = f["lov_sql"].replace("#PAGE#", str(page))
        b += block("lov", "type: sqlQuery\nsqlQuery:" + code("sql", sql) + "\ndisplayExtraValues: true\ndisplayNullValue: true") + "\n"
        if f.get("cascade"):
            parents = f["cascade"] if isinstance(f["cascade"], list) else [f["cascade"]]
            b += block("cascadingLov", "parentItems: [\n" + "".join(f"    P{page}_{c}\n" for c in parents) + "]\nparentRequired: false") + "\n"
    elif t == "ref":
        b += block("lov", f"type: sharedComponent\nlov: @{f['lov'].lower().replace('_', '-')}\ndisplayExtraValues: true\ndisplayNullValue: true") + "\n"
        b += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
    if t == "number":
        b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
    if t == "date":
        b += block("settings", "displayAs: popup\nshowTime: " + ("false" if f.get("date_only") else "true")) + "\n"
    if t == "textarea":
        b += block("settings", "resizable: true\nautoHeight: false\ncharCounter: true\ntrimSpaces: leadingAndTrailing") + "\n"
    if f.get("help"):
        b += block("help", f"helpText: {f['help']}") + "\n"
    if readonly_cond and t not in ("hidden", "display"):
        b += block("readOnly", readonly_cond) + "\n"
    return comp("pageItem", item, b)


# ---------------------------------------------------------------------------
# Сторінки довідників
# ---------------------------------------------------------------------------
def catalog_list_page(c):
    p, fp = c["list_page"], c["form_page"]
    link = (f"linkColumn: customTarget\ntarget: {{\n    page: {fp}\n    clearCache: {fp}\n    items: {{\n        P{fp}_ID: #ID#\n    }}\n}}\n"
            "linkIcon: <span class=\"fa fa-edit\" aria-hidden=\"true\" title=\"Відкрити\"></span>")
    sc = c.get("state_col", "state")
    sql = c["list_sql"].replace("select ", f"select case {sc} when 'ACTIVE' then 'fa-square tx-ico-item' else 'fa-times tx-ico-marked' end icon_class, ' ' state_icon, ", 1)
    cols = [("ID", "ID", "varchar2", True), ICON_COL, ("ICON_CLASS", "icon", "varchar2", True)] + [
        col for col in c["columns"] if col[0] != "STATE_NAME"]
    body = page_header(p, c["title"], c["alias"], c["title"])
    body += "\n" + title_region(c["title"])
    tree = c.get("tree")
    if tree:
        # Ієрархічний довідник як у 1С: дерево груп ліворуч, список вибраної групи праворуч (F-UI-07, APE-286)
        gcol = tree["group_col"]
        sql += (f" where trade_tree.in_group({gcol}, :P{p}_GROUP, nvl(:P{p}_SUB, 'Y')) = 'Y'")
        tb = "name: Групи\ntype: dynamicContent\n"
        tb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
            f"return '<div class=\"tx-tree-bar\"><label class=\"tx-tree-sub\"><input type=\"checkbox\" data-item=\"P{p}_SUB\"'\n"
            f"    || case when nvl(:P{p}_SUB, 'Y') = 'Y' then ' checked' end || '> З підгрупами</label></div>'\n"
            f"    || {tree['html_fn']}(:P{p}_GROUP, 'P{p}_GROUP');")
            + f"\npageItemsToSubmit: [\n    P{p}_GROUP\n    P{p}_SUB\n]") + "\n"
        tb += block("layout", "sequence: 5\nslot: body\ncolumnSpan: 3") + "\n"
        tb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-tree-region")
        body += "\n" + comp("region", "tree", tb)
        for it, dflt in (("GROUP", None), ("SUB", "Y")):
            hb = "type: hidden\n" + block("layout", f"sequence: {10 if it == 'GROUP' else 20}\nregion: @tree\nslot: regionBody") + "\n"
            hb += block("settings", "valueProtected: false") + "\n"
            if dflt:
                hb += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
            hb += block("sessionState", "dataType: varchar2\nstorage: session")
            body += "\n" + comp("pageItem", f"P{p}_{it}", hb)
        lr = ir_region("list", c["title"], sql, cols, link=link)
        lr = lr.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_GROUP\n            P{p}_SUB\n        ]\n        sqlQuery:", 1)
        lr = lr.replace("        sequence: 10\n        slot: body\n", "        sequence: 10\n        slot: body\n        columnSpan: 9\n        startNewRow: false\n", 1)
        assert "columnSpan: 9" in lr
        body += "\n" + lr
        for it in ("GROUP", "SUB"):
            da = f"name: Фільтр {it}\n" + block("when", f"event: change\nselectionType: items\nitems: P{p}_{it}") + "\n" + block("execution", f"sequence: {30 if it == 'GROUP' else 40}") + "\n\n"
            da += comp("action", "refresh", "name: Оновити список\naction: refresh\n" + block("affectedElements", "selectionType: region\nregion: @list") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
            body += "\n" + comp("dynamicAction", f"filter-{it.lower()}", da)
        gp = tree["group_form"]
        body += "\n" + button("create-group", "CREATE_GROUP", "Створити групу", 20, "list", slot="rightOfInteractiveReportSearchBar",
                              action="redirectThisApp", target=f"{{\n    page: {gp}\n    clearCache: {gp}\n}}", auth=tree.get("auth", "role-admin"))
        da = "name: Оновити дерево після діалогу\n" + block("when", "event: apexafterclosedialog\nselectionType: region\nregion: @list") + "\n" + block("execution", "sequence: 20") + "\n\n"
        da += comp("action", "refresh", "name: Оновити дерево\naction: refresh\n" + block("affectedElements", "selectionType: region\nregion: @tree") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
        body += "\n" + comp("dynamicAction", "refresh-tree", da)
    else:
        body += "\n" + ir_region("list", c["title"], sql, cols, link=link)
    body += "\n" + button("create", "CREATE", "Створити", 10, "list", slot="rightOfInteractiveReportSearchBar", hot=True,
                          action="redirectThisApp", target=f"{{\n    page: {fp}\n    clearCache: {fp}\n}}", auth=c.get("edit_auth", "role-admin"))
    # Оновлення списку після закриття діалогу
    body += "\n" + dialog_closed_refresh("list")
    write(PAGES / f"p{p:05d}-{c['alias']}.apx", comp("page", str(p), body))


def dialog_closed_refresh(region):
    b = "name: Оновити після закриття діалогу\n"
    b += block("when", f"event: apexafterclosedialog\nselectionType: region\nregion: @{region}") + "\n"
    b += block("execution", "sequence: 10") + "\n"
    b += "\n" + comp("action", "refresh", "name: Оновити\naction: refresh\n" + block("affectedElements", f"selectionType: region\nregion: @{region}") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    return comp("dynamicAction", "refresh-on-close", b)


def catalog_form_page(c):
    p = c["form_page"]
    reg = "form"
    body = page_header(p, c["item_title"], c["alias"] + "-item", c["item_title"], modal=True)
    if c.get("dialog_width"):
        body = body.replace("width: 720", f"width: {c['dialog_width']}", 1)
    rb = f"name: {c['item_title']}\ntype: form\n"
    rb += block("source", f"location: localDatabase\ntype: tableView\ntableName: {c['table']}") + "\n"
    rb += block("layout", "sequence: 10\nslot: contentBody") + "\n"
    rb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#") + "\n"
    rb += block("edit", "enabled: true\nallowedOperations: [\n    add\n    update\n]\nlostUpdateType: rowValues")
    body += "\n" + comp("region", reg, rb)
    bb = "name: Кнопки\ntype: staticContent\n"
    bb += block("layout", "sequence: 20\nslot: dialogFooter") + "\n"
    bb += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "buttons", bb)

    items = [dict(col="ID", type="hidden", pk=True)] + c["fields"] + [
        dict(col="STATE", label="Стан", type="display", span=6, lov="catalog-states"),
    ]
    for i, f in enumerate(items):
        body += "\n" + form_item(p, reg, f, (i + 1) * 10)
    if c.get("lines"):
        # Таблична частина довідника (напр. «Комплектуючі» специфікації набору)
        body += "\n" + lines_region(p, dict(c["lines"], slot="contentBody", seq=15,
                                            readonly=f":P{p}_STATE is not null and :P{p}_STATE <> 'ACTIVE'"))

    exists = f"type: itemIsNotNull\nitem: P{p}_ID"
    ea = c.get("edit_auth", "role-admin")
    body += "\n" + button("cancel", "CANCEL", "Скасувати", 10, "buttons", slot="close", action="definedByDynamicAction")
    body += "\n" + button("mark", "MARK", "Помітити на видалення", 20, "buttons", slot="delete",
                          condition=f"type: expression\nplsqlExpression: :P{p}_ID is not null and :P{p}_STATE = 'ACTIVE'",
                          confirm="Помітити елемент на видалення?", validations=False, auth=ea)
    body += "\n" + button("restore", "RESTORE", "Відновити", 30, "buttons", slot="delete",
                          condition=f"type: expression\nplsqlExpression: :P{p}_STATE = 'MARKED_FOR_DELETION'", validations=False, auth=ea)
    body += "\n" + button("save", "SAVE", "Записати і закрити", 40, "buttons", slot="next", hot=True,
                          condition=exists, db_action="update", auth=ea)
    body += "\n" + button("create", "CREATE", "Записати і закрити", 50, "buttons", slot="next", hot=True,
                          condition=f"type: itemIsNull\nitem: P{p}_ID", db_action="insert", auth=ea)

    # Динамічна дія закриття діалогу без запису
    da = "name: Скасувати діалог\n" + block("when", "event: click\nselectionType: button\nbutton: @cancel") + "\n"
    da += block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "cancel-dialog", "name: Закрити\naction: cancelDialog\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "cancel-dialog", da)

    body += "\n" + process("init", "Ініціалізація форми", "formInitialization", 10, f"formRegion: @{reg}\n", point="beforeHeader")
    body += "\n" + process("dml", "Записати", "formAutoRowProcessing", 10, f"formRegion: @{reg}\n",
                           point="afterSubmit", when_request_in="SAVE,CREATE", success="Елемент записано.")
    if c.get("lines"):
        body += "\n" + process("dml-lines", "Записати рядки", "interactiveGridAutoRowProcessing", 15,
                                "editableRegion: @lines\n" + block("target", "targetType: plsqlCode\ndmlPlsqlCode:" + code("plsql", lines_dml(p, c["lines"])))
                                + "\n" + block("lockRow", "lockRow: true\npreventLostUpdates: true") + "\n",
                                point="afterSubmit", when_request_in="SAVE,CREATE")
    body += "\n" + process("mark", "Помітити на видалення", "executeCode", 20,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql", f"trade_core.mark_for_deletion('{c['table']}', :P{p}_ID);")) + "\n",
                           point="afterSubmit", when_button="mark")
    body += "\n" + process("restore", "Відновити", "executeCode", 30,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql", f"trade_core.restore('{c['table']}', :P{p}_ID);")) + "\n",
                           point="afterSubmit", when_button="restore")
    body += "\n" + process("close", "Закрити діалог", "closeDialog", 40, point="afterSubmit",
                           when_request_in="SAVE,CREATE,MARK,RESTORE")
    write(PAGES / f"p{p:05d}-{c['alias']}-item.apx", comp("page", str(p), body))


# ---------------------------------------------------------------------------
# Документи (паспорти DocGoodsReceipt, DocSupplierPayment)
# ---------------------------------------------------------------------------
ICON_COL = ("STATE_ICON", "\u200b", "varchar2", False,
            block("columnFormatting", 'htmlExpression: <span class="tx-ico fa #ICON_CLASS#" aria-hidden="true"></span>') + "\n")
STATUS_SQL = "case d.status when 'POSTED' then 'Проведено' else 'Чернетка' end status_name"


def doc_list_page(p, fp, alias, title, sql, columns):
    link = (f"linkColumn: customTarget\ntarget: {{\n    page: {fp}\n    clearCache: {fp}\n    items: {{\n        P{fp}_ID: #ID#\n    }}\n}}\n"
            "linkIcon: <span class=\"fa fa-file-text-o\" aria-hidden=\"true\" title=\"Відкрити\"></span>")
    sql = sql.replace("select d.id,", "select d.id, case when d.status in ('POSTED', 'ISSUED') then 'fa-file-text-o tx-ico-posted' when d.status = 'CANCELLED' then 'fa-times tx-ico-marked' else 'fa-file-o tx-ico-draft' end icon_class, ' ' state_icon,", 1)
    cols = [("ID", "ID", "varchar2", True), ICON_COL, ("ICON_CLASS", "icon", "varchar2", True)] + [
        c for c in columns if c[0] != "STATUS_NAME"]
    body = page_header(p, title, alias, title)
    body += "\n" + title_region(title)
    body += "\n" + ir_region("list", title, sql, cols, link=link)
    body += "\n" + button("create", "CREATE", "Створити", 10, "list", slot="rightOfInteractiveReportSearchBar", hot=True,
                          action="redirectThisApp", target=f"{{\n    page: {fp}\n    clearCache: {fp}\n}}")
    write(PAGES / f"p{p:05d}-{alias}.apx", comp("page", str(p), body))


def doc_conditions(p, d=None):
    posted_value = (d or {}).get("posted_value", "POSTED")
    return {
        "new": f"type: itemIsNull\nitem: P{p}_ID",
        "draft": f"type: expression\nplsqlExpression: :P{p}_ID is not null and :P{p}_STATUS = 'DRAFT'",
        "posted": f"type: item=value\nitem: P{p}_STATUS\nvalue: {posted_value}",
        "not_draft": f"type: expression\nplsqlExpression: :P{p}_ID is not null and :P{p}_STATUS <> 'DRAFT'",
        "posted_open": f"type: expression\nplsqlExpression: :P{p}_STATUS = '{posted_value}' and nvl(:P{p}_CLOSED, 'N') = 'N'",
        "posted_closed": f"type: expression\nplsqlExpression: :P{p}_STATUS = '{posted_value}' and :P{p}_CLOSED = 'Y'",
        "exists": f"type: itemIsNotNull\nitem: P{p}_ID",
    }


def doc_buttons(p, list_page, region="actions", d=None):
    """Команди документа: Провести і закрити | Записати | Провести | Скасувати проведення | … | Скопіювати | Закрити"""
    d = d or {}
    c = doc_conditions(p, d)
    post_lbl = d.get("post_label", "Провести")
    unpost_lbl = d.get("unpost_label", "Скасувати проведення")
    b = ""
    b += button("create-post-close", "CREATE_POST_CLOSE", f"{post_lbl} і закрити", 10, region, slot="close", hot=True, condition=c["new"], db_action="insert")
    b += "\n" + button("post-close", "POST_CLOSE", f"{post_lbl} і закрити", 11, region, slot="close", hot=True, condition=c["draft"], db_action="update")
    b += "\n" + button("create", "CREATE", "Записати", 20, region, slot="close", condition=c["new"], db_action="insert")
    b += "\n" + button("save", "SAVE", "Записати", 21, region, slot="close", condition=c["draft"], db_action="update")
    b += "\n" + button("create-post", "CREATE_POST", post_lbl, 30, region, slot="close", condition=c["new"], db_action="insert")
    b += "\n" + button("post", "POST", post_lbl, 31, region, slot="close", condition=c["draft"], db_action="update")
    b += "\n" + button("unpost", "UNPOST", unpost_lbl, 40, region, slot="close", condition=c.get(d.get("unpost_when", "posted")),
                       confirm=d.get("unpost_confirm", "Скасувати проведення документа? Рухи регістрів буде видалено."), validations=False)
    for i, cmd in enumerate(d.get("commands", [])):
        b += "\n" + button(f"cmd-{cmd['name'].lower().replace('_', '-')}", cmd["name"], cmd["label"], 41 + i, region, slot="close",
                           condition=c[cmd["when"]], confirm=cmd.get("confirm"), validations=False, auth=cmd.get("auth"))
    b += "\n" + button("copy", "COPY", "Скопіювати (F9)", 50, region, slot="close", condition=c["exists"], validations=False)
    b += "\n" + button("close", "CLOSE", "Закрити", 60, region, slot="next", action="redirectThisApp",
                       target=f"{{\n    page: {list_page}\n}}")
    return b


def doc_processes(p, list_page, form_region, post_proc, unpost_proc, copy_func, lines=None, d=None):
    save_reqs = "CREATE,SAVE,POST,POST_CLOSE,CREATE_POST,CREATE_POST_CLOSE"
    post_reqs = "POST,POST_CLOSE,CREATE_POST,CREATE_POST_CLOSE"
    b = process("init", "Ініціалізація форми", "formInitialization", 10, f"formRegion: @{form_region}\n", point="beforeHeader")
    b += "\n" + process("dml", "Записати шапку", "formAutoRowProcessing", 10, f"formRegion: @{form_region}\n",
                        point="afterSubmit", when_request_in=save_reqs, success="Документ записано.")
    if lines:
        b += "\n" + process("dml-lines", "Записати рядки", "interactiveGridAutoRowProcessing", 20,
                            "editableRegion: @lines\n" + block("target", "targetType: plsqlCode\ndmlPlsqlCode:" + code("plsql", lines_dml(p, lines)))
                            + "\n" + block("lockRow", "lockRow: true\npreventLostUpdates: true") + "\n",
                            point="afterSubmit", when_request_in=save_reqs)
    post_ok = (d or {}).get("post_success", "Документ проведено.")
    b += "\n" + process("post", "Провести", "executeCode", 30,
                        block("source", "language: plsql\nplsqlCode:" + code("plsql",
                            f"trade_warn.clear;\n{post_proc}(:P{p}_ID);\n:TRADE_WARN := trade_warn.take;")) + "\n",
                        point="afterSubmit", when_request_in=post_reqs, success=post_ok + " &TRADE_WARN.")
    b += "\n" + process("unpost", "Скасувати проведення", "executeCode", 40,
                        block("source", "language: plsql\nplsqlCode:" + code("plsql", f"{unpost_proc}(:P{p}_ID);")) + "\n",
                        point="afterSubmit", when_button="unpost", success="Проведення документа скасовано.")
    copy_txt = f":P{p}_ID := {copy_func}(:P{p}_ID);"
    post_copy = []
    if (d or {}).get("series_type"):   # r5: характеристики й серії рядків переносяться в копію
        post_copy.append(f"  trade_series.copy_dims('{d['series_type']}', l_src, :P{p}_ID);\n")
    if (d or {}).get("discount_type"):   # r5 F-PRC-06: ціна до знижки й знижки рядків
        post_copy.append(f"  trade_discount.copy_lines('{d['discount_type']}', l_src, :P{p}_ID);\n")
    if (d or {}).get("vat_type"):   # r5 F-TAX-01: режим цін і ставки ПДВ рядків
        post_copy.append(f"  trade_vat.copy_lines('{d['vat_type']}', l_src, :P{p}_ID);\n")
    if post_copy:
        copy_txt = (f"declare\n  l_src varchar2(32) := :P{p}_ID;\nbegin\n  :P{p}_ID := {copy_func}(l_src);\n"
                    + "".join(post_copy) + "end;")
    b += "\n" + process("copy", "Скопіювати", "executeCode", 50,
                        block("source", "language: plsql\nplsqlCode:" + code("plsql", copy_txt)) + "\n",
                        point="afterSubmit", when_button="copy", success="Створено копію документа (чернетка).")
    for i, cmd in enumerate((d or {}).get("commands", [])):
        code_txt = cmd["plsql"].replace("#ID#", f":P{p}_ID")
        if cmd.get("target"):
            code_txt = f":P{p}_NEW_ID := {code_txt};"
        b += "\n" + process(f"cmd-{cmd['name'].lower().replace('_', '-')}", cmd["label"], "executeCode", 60 + i,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql", code_txt)) + "\n",
                            point="afterSubmit", when_request_in=cmd["name"], success=cmd.get("success"))
        if cmd.get("target"):
            tp = cmd["target"]
            b += "\n" + branch(f"to-{cmd['name'].lower().replace('_', '-')}", f"До документа: {cmd['label']}", 5 + i,
                               f"{{\n    page: {tp}\n    clearCache: {tp}\n    items: {{\n        P{tp}_ID: &P{p}_NEW_ID.\n    }}\n}}",
                               when_request_in=cmd["name"])
    if (d or {}).get("scan"):
        b += "\n" + process("scan", "Сканер штрихкодів", "executeCode", 59,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql",
                                f"{d.get('scan_call', 'trade_r3.add_by_barcode')}('{d['scan']}', :P{p}_ID, :P{p}_SCAN);\n:P{p}_SCAN := null;")) + "\n",
                            point="afterSubmit", when_request_in="SCAN")
    b += "\n" + branch("to-list", "До списку", 10, f"{{\n    page: {list_page}\n}}", when_request_in="POST_CLOSE,CREATE_POST_CLOSE")
    b += "\n" + branch("stay", "Залишитися в документі", 20,
                       f"{{\n    page: {p}\n    clearCache: {p}\n    items: {{\n        P{p}_ID: &P{p}_ID.\n    }}\n}}")
    return b


def col_value(c):
    if c["kind"] == "number":
        return f"to_number(:{c['col']}, '{c['mask']}')"
    if c["kind"] == "date":
        return f"to_date(:{c['col']}, '{c['mask']}')"
    return f":{c['col']}"


def lines_dml(p, lines):
    """PL/SQL для запису рядків табличної частини з прив'язкою до :P<page>_ID."""
    fk = lines.get("fk", "document_id")
    cols = [c for c in lines["cols"] if c["kind"] in ("ref", "number", "switch", "text", "select", "date") and not c.get("no_dml")]
    names = ", ".join(c["col"].lower() for c in cols)
    vals = ",\n            ".join(col_value(c) for c in cols)
    sets = ",\n           ".join(f"{c['col'].lower()} = {col_value(c)}" for c in cols)
    t = lines["table"].lower()
    return f"""case :APEX$ROW_STATUS
  when 'C' then
    insert into {t} ({fk}, line_number, {names})
    values (:P{p}_ID, null,
            {vals})
    returning id into :ID;
  when 'U' then
    update {t}
       set {sets}
     where id = :ID and {fk} = :P{p}_ID;
  when 'D' then
    delete from {t} where id = :ID and {fk} = :P{p}_ID;
end case;"""


def form_region(ident, title, table, seq=20, readonly_item=None, template="standard"):
    rb = f"name: {title}\ntitle: {title}\ntype: form\n"
    rb += block("source", f"location: localDatabase\ntype: tableView\ntableName: {table}") + "\n"
    rb += block("layout", f"sequence: {seq}\nslot: body") + "\n"
    rb += block("appearance", f"template: @/{template}\ntemplateOptions: #DEFAULT#") + "\n"
    if readonly_item:
        rb += block("readOnly", f"type: expression\nlanguage: plsql\nplsqlExpression: :{readonly_item} is not null and :{readonly_item} <> 'DRAFT'") + "\n"
    rb += block("edit", "enabled: true\nallowedOperations: [\n    add\n    update\n]\nlostUpdateType: rowValues")
    return comp("region", ident, rb)


def actions_region(seq=10):
    bb = "name: Команди\ntype: staticContent\n"
    bb += block("layout", f"sequence: {seq}\nslot: body") + "\n"
    bb += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
    return comp("region", "actions", bb)


def status_item(p, region, seq, same_row=True):
    b = "type: hidden\n"
    b += block("layout", f"sequence: {seq}\nregion: @{region}\nslot: regionBody") + "\n"
    b += block("source", f"formRegion: @{region}\ncolumn: STATUS\ndataType: varchar2") + "\n"
    b += block("settings", "valueProtected: true") + "\n"
    return comp("pageItem", f"P{p}_STATUS", b)


def ig_column(name, heading, seq, kind, dtype="varchar2", extra=""):
    typ = {"hidden": "hidden", "display": "displayOnly", "ref": "popupLov", "number": "numberField", "switch": "switch",
           "text": "textField", "select": "selectList", "date": "datePicker"}[kind]
    b = f"type: {typ}\n"
    src = f"type: databaseColumn\ndatabaseColumn: {name}\ndataType: {dtype}\n"
    if name == "ID":
        src += "primaryKey: true\n"
    if kind == "display" and name != "LINE_NUMBER":
        src += "queryOnly: true\n"
    if kind == "hidden" and name not in ("ID", "DOCUMENT_ID"):
        src += "queryOnly: true\n"
    b += block("source", src) + "\n"
    if kind != "hidden":
        b += block("heading", f"heading: {heading}\nalignment: {'end' if dtype == 'number' else 'start'}") + "\n"
    b += block("layout", f"sequence: {seq}" + (f"\ncolumnAlignment: end" if dtype == "number" and kind != "hidden" else "")) + "\n"
    b += extra
    return comp("column", name, b)


def lines_region(p, lines):
    cols = lines["cols"]
    fk = lines.get("fk", "document_id")
    sel = ", ".join(["id", fk, "line_number"] + [
        (c["sql"] + " " + c["col"].lower()) if c.get("sql") else c["col"].lower() for c in cols])
    gb = f"name: {lines['title']}\ntitle: {lines['title']}\ntype: interactiveGrid\n"
    gb += block("source", "location: localDatabase\ntype: sqlQuery\nsqlQuery:" + code("sql",
        f"select {sel}\n  from {lines['table'].lower()}\n where {fk} = :P{p}_ID\n order by line_number")) + "\n"
    gb += block("layout", f"sequence: {lines.get('seq', 30)}\nslot: {lines.get('slot', 'body')}") + "\n"
    gb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#\ncssClasses: tx-tabpart") + "\n"
    gb += block("readOnly", "type: expression\nlanguage: plsql\nplsqlExpression: " + lines.get(
        "readonly", f":P{p}_STATUS is not null and :P{p}_STATUS <> 'DRAFT'")) + "\n"
    ops = lines.get("ops", ["add", "update", "delete"])
    gb += block("edit", "enabled: true\nallowedOperations: [\n" + "".join(f"    {o}\n" for o in ops) + "]\nlostUpdateType: rowValues") + "\n"
    gb += block("toolbar", "show: true\ncontrols: [\n    actionsMenu\n]" + ("\naddButtonLabel: Додати рядок" if "add" in ops else "")) + "\n"
    gb += block("advanced", f"savedReportMappingIdentifier: {next_mapping_id()}") + "\n"
    disp = "\n" + comp("displayColumn", "LINE_NUMBER", "column: @LINE_NUMBER\n" + block("layout", "sequence: 10\nshow: true\nwidth: 50"))
    for i, c in enumerate([c for c in cols if c["kind"] != "hidden"]):
        disp += "\n" + comp("displayColumn", c["col"], f"column: @{c['col']}\n"
                            + block("layout", f"sequence: {(i + 2) * 10}\nshow: true\nwidth: {c.get('width', 130)}"))
    gb += "\n" + comp("savedReport", "primary", "name: Основний\nvisibility: primary\n" + block("view", "default: grid") + "\n" + disp)
    gb += "\n" + ig_column("ID", "ID", 10, "hidden")
    gb += "\n" + ig_column(fk.upper(), "Документ", 20, "hidden")
    gb += "\n" + ig_column("LINE_NUMBER", "N", 30, "display", "number")
    for i, c in enumerate(cols):
        extra = ""
        if c.get("required"):
            extra += block("validation", "valueRequired: true") + "\n"
        if c["kind"] == "ref":
            extra += block("lov", f"type: sharedComponent\nlov: @{c['lov']}\ndisplayExtraValues: true\ndisplayNullValue: true") + "\n"
            extra += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
        if c["kind"] == "select":
            extra += block("lov", f"type: sharedComponent\nlov: @{c['lov']}\ndisplayExtraValues: true\ndisplayNullValue: {'false' if c.get('required') else 'true'}") + "\n"
        if c["kind"] == "text" and c.get("max"):
            extra += block("validation", f"maxLength: {c['max']}") + "\n"
        if c.get("mask"):
            extra += block("appearance", f"formatMask: {c['mask']}") + "\n"
        if c.get("help"):
            extra += block("help", f"helpText: {c['help']}") + "\n"
        if c["kind"] == "switch":
            extra += block("settings", "useDefaults: false\nonValue: Y\nonLabel: Так\noffValue: N\noffLabel: Ні") + "\n"
            extra += block("default", "type: static\nstaticValue: N") + "\n"
        gb += "\n" + ig_column(c["col"], c["heading"], (i + 4) * 10, c["kind"], c.get("dtype", "varchar2"), extra)
    return comp("region", "lines", gb)


DATE_FIELD = dict(col="OCCURRED_AT", label="Дата", type="date", dtype="date", format="DD.MM.YYYY HH24:MI:SS", span=3,
                  newcol=True, required=True,
                  default="type: expression\nlanguage: plsql\nplsqlExpression: to_char(sysdate, 'DD.MM.YYYY HH24:MI:SS')")
NUMBER_FIELD = dict(col="DOC_NUMBER", label="Номер", type="text", max=9, span=3, help="Порожній номер буде призначено автоматично.")
Q3, Q2 = "FM999G999G999G990D000", "FM999G999G999G990D00"
PRODUCT_COL = dict(col="PRODUCT_ID", heading="Товар", kind="ref", lov="products-active", required=True, width=380)
QTY_COL = dict(col="QUANTITY", heading="Кількість", kind="number", dtype="number", mask=Q3, required=True)
DATE_LIST_COL = ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")


def money_col(name, heading):
    return (name, heading, "number", False, block("appearance", f"formatMask: {Q2}") + "\n")


def document_pages(d):
    """Сторінки документа (список + форма) зі специфікації."""
    p, lp = d["page"], d["list_page"]
    doc_list_page(lp, p, d["list_alias"], d["list_title"], d["list_sql"],
                  [("DOC_NUMBER", "Номер"), DATE_LIST_COL] + d["list_cols"] + [("STATUS_NAME", "Статус"), ("DOC_COMMENT", "Коментар")])
    body = page_header(p, d["title"], d["alias"], d["title"])
    body += "\n" + title_region(f"&P{p}_FORM_TITLE.", seq=1)
    body += "\n" + actions_region(seq=5)
    body += "\n" + form_region("header", d["title"], d["table"], readonly_item=f"P{p}_STATUS", template="blank-with-attributes")
    seq = 10
    row = [0]

    def place(span):
        """Автоматична розкладка: True — у поточному рядку."""
        same = row[0] > 0 and row[0] + span <= 12
        row[0] = (row[0] + span) if same else span
        return same

    for f in [dict(col="ID", type="hidden", pk=True), NUMBER_FIELD, DATE_FIELD] + d["fields"]:
        f = dict(f)
        if f["type"] != "hidden":
            f["newcol"] = place(f.get("span", 12))
        body += "\n" + form_item(p, "header", f, seq)
        seq += 10
    body += "\n" + status_item(p, "header", seq); seq += 10
    # Прихований заголовок форми «Вид № від дата (проведено)»
    tb = "type: hidden\n" + block("layout", f"sequence: {seq}\nregion: @header\nslot: regionBody") + "\n"
    tb += block("sessionState", "dataType: varchar2\nstorage: request")
    body += "\n" + comp("pageItem", f"P{p}_FORM_TITLE", tb); seq += 10
    # Службове поле для команд «створити на підставі»
    nb = "type: hidden\n" + block("layout", f"sequence: {seq}\nregion: @header\nslot: regionBody") + "\n"
    nb += block("sessionState", "dataType: varchar2\nstorage: request")
    body += "\n" + comp("pageItem", f"P{p}_NEW_ID", nb); seq += 10
    if d.get("scan"):
        sb = "name: Сканер\ntype: staticContent\n" + block("layout", "sequence: 25\nslot: body") + "\n"
        sb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#") + "\n"
        sb += block("serverSideCondition", doc_conditions(p, d)["draft"])
        body += "\n" + comp("region", "scan", sb)
        it = "type: textField\n" + block("label", "label: Штрихкод / артикул\nalignment: right") + "\n"
        it += block("layout", "sequence: 10\nregion: @scan\nslot: regionBody\ncolumnSpan: 5") + "\n"
        it += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nvaluePlaceholder: Відскануйте або введіть і натисніть «Додати»") + "\n"
        it += block("advanced", "customAttributes: autocomplete=\"off\"") + "\n"
        it += block("sessionState", "dataType: varchar2\nstorage: request")
        body += "\n" + comp("pageItem", f"P{p}_SCAN", it)
        body += "\n" + button("scan", "SCAN", "Додати", 20, "scan", slot="regionBody", validations=False)
        if d.get("pick_wh") is not None:
            items = {"P950_KIND": d["scan"], "P950_ID": f"&P{p}_ID.",
                     "P950_WH": f"&P{p}_{d['pick_wh']}." if d["pick_wh"] else "",
                     "P950_PT": f"&P{p}_PRICE_TYPE_ID." if d.get("pick_pt") else "",
                     "P950_SUP": f"&P{p}_SUPPLIER_ID." if d.get("pick_sup") else ""}
            tgt = "{\n    page: 950\n    clearCache: 950\n    items: {\n" + "".join(
                f"        {k}: {v}\n" for k, v in items.items() if v) + "    }\n}"
            body += "\n" + button("pick", "PICK", "Підбір", 30, "scan", slot="regionBody", action="redirectThisApp", target=tgt)
            da = "name: Після підбору\n" + block("when", "event: apexafterclosedialog\nselectionType: button\nbutton: @pick") + "\n"
            da += block("execution", "sequence: 10") + "\n\n"
            da += comp("action", "reload", "name: Перезавантажити\naction: submitPage\n" + block("settings", "requestButtonName: PICKED\nshowProcessing: true") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
            body += "\n" + comp("dynamicAction", "after-pick", da)
    for f in d.get("footer_fields", []):
        pass
    if d.get("lines"):
        body += "\n" + lines_region(p, d["lines"])
    # Додаткові регіони тільки для читання (розшифровка платежу, оплати за рахунком …)
    for i, (ident, ttl, sql, cols) in enumerate(d.get("extra_regions", [])):
        body += "\n" + ir_region(ident, ttl, sql.replace("#PAGE#", str(p)), cols, seq=45 + i, title=ttl)
    # r6 F-WH-26: «Вага й об'єм для доставки» (trade_cargo.summary_html)
    if d.get("cargo"):
        cb = "name: Вага й об'єм\ntype: dynamicContent\n"
        cb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
            f"return trade_cargo.summary_html('{d['cargo']}', :P{p}_ID);")) + "\n"
        cb += block("layout", "sequence: 38\nslot: body") + "\n"
        cb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#") + "\n"
        cb += block("serverSideCondition", doc_conditions(p, d)["exists"])
        body += "\n" + comp("region", "cargo", cb)
    # Підвал: «Всього» праворуч і «Коментар» — як у формах 1С
    fb = "name: Підвал\ntype: staticContent\n" + block("layout", "sequence: 40\nslot: body") + "\n"
    fb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "footer", fb)
    if d.get("vat"):   # r5 F-TAX-01: «Сума ПДВ» поруч із «Всього»
        body += "\n" + form_item(p, "footer", dict(col="VAT_AMOUNT", label="Сума ПДВ", type="display", dtype="number",
                                                   format=Q2, span=3, column=7, src_region="header"), seq); seq += 10
    if d.get("total"):
        body += "\n" + form_item(p, "footer", dict(col="TOTAL_AMOUNT", label="Всього", type="display", dtype="number",
                                                   format=Q2, span=3, column=10, src_region="header", newcol=bool(d.get("vat"))), seq); seq += 10
    body += "\n" + form_item(p, "footer", dict(col="DOC_COMMENT", label="Коментар", type="textarea", max=1000, span=12,
                                               src_region="header"), seq); seq += 10
    for pi in d.get("extra_items", []):
        ib = f"type: {pi.get('type', 'textField')}\n" + block("label", f"label: {pi['label']}\nalignment: right") + "\n"
        ib += block("layout", f"sequence: {seq}\nregion: @footer\nslot: regionBody\ncolumnSpan: {pi.get('span', 6)}") + "\n"
        ib += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
        ib += block("sessionState", "dataType: varchar2\nstorage: request")
        if pi.get("when"):
            ib += "\n" + block("serverSideCondition", doc_conditions(p, d)[pi["when"]])
        body += "\n" + comp("pageItem", f"P{p}_{pi['name']}", ib); seq += 10
    body += "\n" + process("form-title", "Заголовок форми", "executeCode", 20,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql",
                                f":P{p}_FORM_TITLE := trade_ui.doc_title('{d['title']}', :P{p}_DOC_NUMBER, :P{p}_OCCURRED_AT, :P{p}_STATUS);")) + "\n",
                            point="beforeHeader")
    if d.get("toggle_js"):
        body += "\n" + toggle_da(p, d["toggle_js"], d.get("toggle_item", "OPERATION_KIND"))
    body += "\n" + doc_buttons(p, lp, d=d)
    body += "\n" + doc_processes(p, lp, "header", d["post"], d["unpost"], d["copy"], lines=d.get("lines"), d=d)
    write(PAGES / f"p{p:05d}-{d['alias']}.apx", comp("page", str(p), body))


def ref_field(col, label, lov, span=6, newcol=False, required=True, help=None):
    f = dict(col=col, label=label, type="ref", lov=lov, span=span, newcol=newcol, required=required)
    if help:
        f["help"] = help
    return f


DOCUMENTS = [
    # --------------------------------------------------------------- r1
    dict(page=51, list_page=50, alias="goods-receipt", list_alias="goods-receipts", table="DOC_GOODS_RECEIPT",
         title="Прибуткова накладна", list_title="Прибуткові накладні", total=True,
         list_sql=("select d.id, d.doc_number, d.occurred_at, s.name supplier_name, w.name warehouse_name, d.total_amount, d.currency_code, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_goods_receipt d\n  join ref_counterparty s on s.id = d.supplier_id\n"
                   "  join ref_warehouse w on w.id = d.warehouse_id"),
         list_cols=[("SUPPLIER_NAME", "Постачальник"), ("WAREHOUSE_NAME", "Склад"), money_col("TOTAL_AMOUNT", "Всього"), ("CURRENCY_CODE", "Валюта")],
         fields=[ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                 ref_field("SUPPLIER_ID", "Постачальник", "COUNTERPARTIES_ACTIVE"),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=3, newcol=True)],
         lines=dict(table="DOC_GOODS_RECEIPT_GOODS", title="Товари", cols=[
             PRODUCT_COL, QTY_COL,
             dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2, required=True),
             dict(col="AMOUNT", heading="Сума", kind="display", dtype="number", mask=Q2, width=140)]),
         post="trade_doc.post_goods_receipt", unpost="trade_doc.unpost_goods_receipt", copy="trade_doc.copy_goods_receipt"),
    dict(page=61, list_page=60, alias="supplier-payment", list_alias="supplier-payments", table="DOC_SUPPLIER_PAYMENT",
         title="Оплата постачальнику", list_title="Оплати постачальникам",
         list_sql=("select d.id, d.doc_number, d.occurred_at, s.name supplier_name, d.amount, d.currency_code, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_supplier_payment d\n  join ref_counterparty s on s.id = d.supplier_id"),
         list_cols=[("SUPPLIER_NAME", "Постачальник"), money_col("AMOUNT", "Сума оплати"), ("CURRENCY_CODE", "Валюта")],
         fields=[ref_field("SUPPLIER_ID", "Постачальник", "COUNTERPARTIES_ACTIVE", newcol=True),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=3),
                 dict(col="AMOUNT", label="Сума оплати", type="number", dtype="number", format=Q2, span=3, newcol=True, required=True)],
         post="trade_doc.post_supplier_payment", unpost="trade_doc.unpost_supplier_payment", copy="trade_doc.copy_supplier_payment"),
    # --------------------------------------------------------------- r2
    dict(page=101, list_page=100, alias="price-setting", list_alias="price-settings", table="DOC_PRICE_SETTING",
         title="Встановлення цін номенклатури", list_title="Встановлення цін номенклатури",
         list_sql=("select d.id, d.doc_number, d.occurred_at, pt.name price_type_name, "
                   "(select count(*) from doc_price_setting_prices l where l.document_id = d.id) line_count, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_price_setting d\n  join ref_price_type pt on pt.id = d.price_type_id"),
         list_cols=[("PRICE_TYPE_NAME", "Вид цін"), ("LINE_COUNT", "Рядків", "number")],
         fields=[ref_field("PRICE_TYPE_ID", "Вид цін", "PRICE_TYPES_ACTIVE", newcol=True,
                           help="Ціни діють з дати документа до наступного встановлення.")],
         lines=dict(table="DOC_PRICE_SETTING_PRICES", title="Ціни", cols=[
             PRODUCT_COL, dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2, required=True)]),
         post="trade_ops.post_price_setting", unpost="trade_ops.unpost_price_setting", copy="trade_ops.copy_price_setting"),
    dict(page=111, list_page=110, alias="goods-sale", list_alias="goods-sales", table="DOC_GOODS_SALE",
         title="Реалізація товарів", list_title="Реалізація товарів", total=True,
         list_sql=("select d.id, d.doc_number, d.occurred_at, c.name customer_name, w.name warehouse_name, pt.name price_type_name, "
                   "d.total_amount, d.currency_code, " + STATUS_SQL + ", d.doc_comment\n  from doc_goods_sale d\n"
                   "  join ref_counterparty c on c.id = d.customer_id\n  join ref_warehouse w on w.id = d.warehouse_id\n"
                   "  left join ref_price_type pt on pt.id = d.price_type_id"),
         list_cols=[("CUSTOMER_NAME", "Покупець"), ("WAREHOUSE_NAME", "Склад"), ("PRICE_TYPE_NAME", "Вид цін"),
                    money_col("TOTAL_AMOUNT", "Всього"), ("CURRENCY_CODE", "Валюта")],
         fields=[ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                 ref_field("CUSTOMER_ID", "Покупець", "COUNTERPARTIES_ACTIVE"),
                 ref_field("PRICE_TYPE_ID", "Вид цін", "PRICE_TYPES_ACTIVE", span=3, newcol=True, required=False,
                           help="Порожня ціна в рядку заповнюється з регістру «Ціни номенклатури» за цим видом цін на дату документа."),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=3, newcol=True)],
         lines=dict(table="DOC_GOODS_SALE_GOODS", title="Товари", cols=[
             PRODUCT_COL, QTY_COL,
             dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2,
                  help="Залиште порожньою — ціна підставиться з виду цін."),
             dict(col="AMOUNT", heading="Сума", kind="display", dtype="number", mask=Q2, width=140)]),
         post="trade_ops.post_goods_sale", unpost="trade_ops.unpost_goods_sale", copy="trade_ops.copy_goods_sale"),
    dict(page=121, list_page=120, alias="customer-payment", list_alias="customer-payments", table="DOC_CUSTOMER_PAYMENT",
         title="Оплата від покупця", list_title="Оплати від покупців",
         list_sql=("select d.id, d.doc_number, d.occurred_at, c.name customer_name, d.amount, d.currency_code, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_customer_payment d\n  join ref_counterparty c on c.id = d.customer_id"),
         list_cols=[("CUSTOMER_NAME", "Покупець"), money_col("AMOUNT", "Сума оплати"), ("CURRENCY_CODE", "Валюта")],
         fields=[ref_field("CUSTOMER_ID", "Покупець", "COUNTERPARTIES_ACTIVE", newcol=True),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=3),
                 dict(col="AMOUNT", label="Сума оплати", type="number", dtype="number", format=Q2, span=3, newcol=True, required=True)],
         post="trade_ops.post_customer_payment", unpost="trade_ops.unpost_customer_payment", copy="trade_ops.copy_customer_payment"),
    dict(page=131, list_page=130, alias="goods-transfer", list_alias="goods-transfers", table="DOC_GOODS_TRANSFER",
         title="Переміщення товарів", list_title="Переміщення товарів",
         list_sql=("select d.id, d.doc_number, d.occurred_at, wf.name warehouse_from_name, wt.name warehouse_to_name, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_goods_transfer d\n"
                   "  join ref_warehouse wf on wf.id = d.warehouse_from_id\n  join ref_warehouse wt on wt.id = d.warehouse_to_id"),
         list_cols=[("WAREHOUSE_FROM_NAME", "Склад-відправник"), ("WAREHOUSE_TO_NAME", "Склад-отримувач")],
         fields=[ref_field("WAREHOUSE_FROM_ID", "Склад-відправник", "WAREHOUSES_ACTIVE", newcol=True),
                 ref_field("WAREHOUSE_TO_ID", "Склад-отримувач", "WAREHOUSES_ACTIVE")],
         lines=dict(table="DOC_GOODS_TRANSFER_GOODS", title="Товари", cols=[PRODUCT_COL, QTY_COL]),
         post="trade_ops.post_goods_transfer", unpost="trade_ops.unpost_goods_transfer", copy="trade_ops.copy_goods_transfer"),
    dict(page=141, list_page=140, alias="goods-write-off", list_alias="goods-write-offs", table="DOC_GOODS_WRITE_OFF",
         title="Списання товарів", list_title="Списання товарів",
         list_sql=("select d.id, d.doc_number, d.occurred_at, w.name warehouse_name, d.reason, "
                   + STATUS_SQL + ", d.doc_comment\n  from doc_goods_write_off d\n  join ref_warehouse w on w.id = d.warehouse_id"),
         list_cols=[("WAREHOUSE_NAME", "Склад"), ("REASON", "Причина")],
         fields=[ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                 dict(col="REASON", label="Причина списання", type="text", max=255, span=6, required=True)],
         lines=dict(table="DOC_GOODS_WRITE_OFF_GOODS", title="Товари", cols=[PRODUCT_COL, QTY_COL]),
         post="trade_ops.post_goods_write_off", unpost="trade_ops.unpost_goods_write_off", copy="trade_ops.copy_goods_write_off"),
]


# ---------------------------------------------------------------------------
# Регістри (Звіти): режими Залишки / Обороти / Рухи
# ---------------------------------------------------------------------------
RECORDER_LINK = block("columnFormatting", 'htmlExpression: <a href="#RECORDER_URL#">#RECORDER_NAME#</a>') + "\n"


def recorder_url_sql(alias="m"):
    return (f"apex_page.get_url(p_page => {alias}.page_id, p_items => 'P' || {alias}.page_id || '_ID', "
            f"p_values => {alias}.recorder_id) recorder_url")


def org_filter_item(p, region, seq, span=4, new_row=False):
    """r4 (F-NSI-09): відбір звіту за організацією; порожньо — усі організації."""
    b = "type: selectList\n"
    b += block("label", "label: Організація\nalignment: right") + "\n"
    b += block("layout", f"sequence: {seq}\nregion: @{region}\nslot: regionBody\ncolumnSpan: {span}"
               + ("" if new_row else "\nstartNewRow: false")) + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @organizations-all\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: Усі організації") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    return comp("pageItem", f"P{p}_ORG", b)


def org_where(p, col="m.organization_id"):
    return f"(:P{p}_ORG is null or {col} = :P{p}_ORG)"


def register_page(p, alias, title, balance_sql, balance_cols, turnover_sql, turnover_cols, movement_sql, movement_cols, org=False, extra=""):
    body = page_header(p, title, alias, title)
    body += "\n" + title_region(title, seq=0)
    if org:
        fb = "name: Відбір\ntype: staticContent\n"
        fb += block("layout", "sequence: 3\nslot: body") + "\n"
        fb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
        body += "\n" + comp("region", "filter", fb)
        body += "\n" + org_filter_item(p, "filter", 10, new_row=True)
        body += "\n" + button("apply-org", "APPLY_ORG", "Застосувати", 20, "filter", slot="regionBody", hot=True)
    # Перемикач режимів
    sel = "name: Режим\ntype: regionDisplaySelector\n"
    sel += block("layout", "sequence: 5\nslot: body") + "\n"
    sel += block("settings", "mode: viewSingleRegion\nincludeShowAll: false\nrememberSelection: bySession") + "\n"
    sel += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "mode", sel)

    def with_selector(region_text):
        return region_text.replace("    advanced {\n", "    advanced {\n        regionDisplaySelector: true\n", 1)

    body += "\n" + with_selector(ir_region("balances", "Залишки", balance_sql, balance_cols, seq=10, title="Залишки"))

    # Обороти з параметрами періоду
    tb = "name: Обороти\ntitle: Обороти\ntype: staticContent\n"
    tb += block("layout", "sequence: 20\nslot: body") + "\n"
    tb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
    tb += block("advanced", "regionDisplaySelector: true")
    body += "\n" + comp("region", "turnovers", tb)
    for i, (it, lbl, dflt) in enumerate([("FROM", "Початок періоду", "trunc(sysdate, 'MM')"),
                                          ("TO", "Кінець періоду", "trunc(sysdate)")]):
        b = "type: datePicker\n"
        b += block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {(i + 1) * 10}\nregion: @turnovers\nslot: regionBody\ncolumnSpan: 3"
                   + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: to_char({dflt}, 'DD.MM.YYYY')") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("apply", "APPLY", "Сформувати", 30, "turnovers", slot="regionBody", hot=True)
    tr = ir_region("turnover-report", "Обороти за період", turnover_sql, turnover_cols, seq=30, parent="turnovers",
                   template="@/blank-with-attributes")
    tr = tr.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_FROM\n            P{p}_TO\n" + (f"            P{p}_ORG\n" if org else "") + "        ]\n        sqlQuery:", 1)
    body += "\n" + tr

    body += "\n" + with_selector(ir_region("movements", "Рухи", movement_sql, movement_cols, seq=30, title="Рухи"))
    body += extra
    write(PAGES / f"p{p:05d}-{alias}.apx", comp("page", str(p), body))


def tabs_report_page(p, alias, title, tabs, period=False, actions=None, org=False):
    """Звіт з вкладками; tabs: (ident, title, sql, columns)."""
    body = page_header(p, title, alias, title)
    body += "\n" + title_region(title, seq=0)
    seq = 5
    if period:
        fb = "name: Період\ntype: staticContent\n"
        fb += block("layout", "sequence: 1\nslot: body") + "\n"
        fb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
        body += "\n" + comp("region", "period", fb)
        for i, (it, lbl, dflt) in enumerate([("FROM", "Початок періоду", "trunc(sysdate, 'MM')"),
                                              ("TO", "Кінець періоду", "trunc(sysdate)")]):
            b = "type: datePicker\n"
            b += block("label", f"label: {lbl}\nalignment: right") + "\n"
            b += block("layout", f"sequence: {(i + 1) * 10}\nregion: @period\nslot: regionBody\ncolumnSpan: 3"
                       + ("\nstartNewRow: false" if i else "")) + "\n"
            b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
            b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: to_char({dflt}, 'DD.MM.YYYY')") + "\n"
            b += block("sessionState", "dataType: varchar2\nstorage: session")
            body += "\n" + comp("pageItem", f"P{p}_{it}", b)
        if org:
            body += "\n" + org_filter_item(p, "period", 25)
        body += "\n" + button("apply", "APPLY", "Сформувати", 30, "period", slot="regionBody", hot=True)
        for i, a in enumerate(actions or []):
            body += "\n" + button(a["ident"], a["name"], a["label"], 40 + i, "period", slot="regionBody",
                                   confirm=a.get("confirm"), validations=False, auth=a.get("auth"))
            body += "\n" + process(a["ident"], a["label"], "executeCode", 10 + i,
                                    block("source", "language: plsql\nplsqlCode:" + code("plsql", a["plsql"])) + "\n",
                                    point="afterSubmit", when_button=a["ident"], success=a.get("success"))
    sel = "name: Режим\ntype: regionDisplaySelector\n"
    sel += block("layout", f"sequence: {seq}\nslot: body") + "\n"
    sel += block("settings", "mode: viewSingleRegion\nincludeShowAll: false\nrememberSelection: bySession") + "\n"
    sel += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "mode", sel)
    for i, (ident, ttl, sql, cols) in enumerate(tabs):
        r = ir_region(ident, ttl, sql, cols, seq=(i + 1) * 10 + 10, title=ttl)
        r = r.replace("    advanced {\n", "    advanced {\n        regionDisplaySelector: true\n", 1)
        if period:
            r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_FROM\n            P{p}_TO\n" + (f"            P{p}_ORG\n" if org else "") + "        ]\n        sqlQuery:", 1)
        body += "\n" + r
    write(PAGES / f"p{p:05d}-{alias}.apx", comp("page", str(p), body))


def r2_reports():
    q3, q2 = "FM999G999G999G990D000", "FM999G999G999G990D00"
    dt = ("PERIOD", "Діє з", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")
    tabs_report_page(150, "product-prices", "Ціни номенклатури", [
        ("current", "Діючі ціни",
         "select price_type_name, product_code, product_name, unit_name, price, period\n  from v_product_price_current",
         [("PRICE_TYPE_NAME", "Вид цін"), ("PRODUCT_CODE", "Код товару"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("PRICE", "Ціна", q2), dt]),
        ("history", "Історія",
         "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.price_type_name, m.product_name, m.unit_name, m.price\n  from v_product_price_history m",
         [dt, ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
          ("PRICE_TYPE_NAME", "Вид цін"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."), num_col("PRICE", "Ціна", q2)]),
    ])
    pf, pt = "to_date(:P160_FROM, 'DD.MM.YYYY')", "to_date(:P160_TO, 'DD.MM.YYYY') + 1"
    where = f"\n where m.period >= {pf} and m.period < {pt} and {org_where(160)}"
    tabs_report_page(160, "sales", "Продажі", [
        ("by-product", "За товарами",
         "select m.product_name, m.unit_name, sum(m.quantity) quantity, sum(m.amount) amount,\n"
         "       round(sum(m.amount) / nullif(sum(m.quantity), 0), 2) avg_price\n  from v_sales m" + where
         + "\n group by m.product_name, m.unit_name",
         [("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."), num_col("QUANTITY", "Кількість", q3),
          num_col("AMOUNT", "Сума", q2), num_col("AVG_PRICE", "Середня ціна", q2)]),
        ("by-customer", "За покупцями",
         "select m.counterparty_name, count(distinct m.recorder_id) doc_count, sum(m.amount) amount\n  from v_sales m" + where
         + "\n group by m.counterparty_name",
         [("COUNTERPARTY_NAME", "Покупець"), ("DOC_COUNT", "Документів", "number"), num_col("AMOUNT", "Сума", q2)]),
        ("records", "Записи",
         "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.organization_name, m.counterparty_name, m.warehouse_name, m.product_name, m.unit_name, m.quantity, m.amount\n  from v_sales m" + where,
         [("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
          ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
          ("ORGANIZATION_NAME", "Організація"), ("COUNTERPARTY_NAME", "Покупець"), ("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("QUANTITY", "Кількість", q3), num_col("AMOUNT", "Сума", q2)]),
    ], period=True, org=True)


def num_col(name, heading, mask):
    return (name, heading, "number", False, block("appearance", f"formatMask: {mask}") + "\n")


def registers():
    q3, q2 = "FM999G999G999G990D000", "FM999G999G999G990D00"
    period_from = "to_date(:P70_FROM, 'DD.MM.YYYY')"
    period_to = "to_date(:P70_TO, 'DD.MM.YYYY') + 1"
    register_page(
        70, "stock-balance", "Товари на складах",
        "select warehouse_name, product_code, product_name, unit_name, balance,\n"
        "       apex_page.get_url(p_page => 450, p_items => 'P450_PRODUCT,P450_WH', p_values => product_id || ',' || warehouse_id) card_url\n"
        "  from v_stock_balance",
        [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код товару"),
         ("PRODUCT_NAME", "Товар", "varchar2", False,
          block("columnFormatting", 'htmlExpression: <a href="#CARD_URL#" title="Картка товару">#PRODUCT_NAME#</a>') + "\n"),
         ("CARD_URL", "URL", "varchar2", True),
         ("UNIT_NAME", "Од."), num_col("BALANCE", "Залишок", q3)],
        f"""select w.name warehouse_name, p.name product_name, u.short_name unit_name,
       sum(case when m.period < {period_from} then m.quantity else 0 end) opening,
       sum(case when m.period >= {period_from} and m.period < {period_to} and m.quantity > 0 then m.quantity else 0 end) incoming,
       sum(case when m.period >= {period_from} and m.period < {period_to} and m.quantity < 0 then -m.quantity else 0 end) outgoing,
       sum(case when m.period < {period_to} then m.quantity else 0 end) closing
  from reg_stock_balance_movement m
  join ref_warehouse w on w.id = m.warehouse_id
  join ref_product p on p.id = m.product_id
  join ref_unit_of_measure u on u.id = p.unit_of_measure_id
 group by w.name, p.name, u.short_name""",
        [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
         num_col("OPENING", "Поч. залишок", q3), num_col("INCOMING", "Прихід", q3),
         num_col("OUTGOING", "Розхід", q3), num_col("CLOSING", "Кін. залишок", q3)],
        "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.warehouse_name, m.product_name, m.unit_name, m.quantity\n  from v_stock_movement m",
        [("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
         ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
         ("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."), num_col("QUANTITY", "Кількість", q3)])

    period_from = "to_date(:P80_FROM, 'DD.MM.YYYY')"
    period_to = "to_date(:P80_TO, 'DD.MM.YYYY') + 1"
    register_page(
        80, "settlements", "Взаєморозрахунки",
        "select organization_name, counterparty_code, counterparty_name, direction_name, currency_code, balance\n  from v_settlement_balance\n where " + org_where(80, "organization_id"),
        [("ORGANIZATION_NAME", "Організація"), ("COUNTERPARTY_CODE", "Код"), ("COUNTERPARTY_NAME", "Контрагент"), ("DIRECTION_NAME", "Заборгованість"),
         ("CURRENCY_CODE", "Валюта"), num_col("BALANCE", "Сума", q2)],
        f"""select o.name organization_name, c.name counterparty_name,
       case m.direction when 'PAYABLE' then 'Кредиторська' else 'Дебіторська' end direction_name,
       m.currency_code,
       sum(case when m.period < {period_from} then m.amount else 0 end) opening,
       sum(case when m.period >= {period_from} and m.period < {period_to} and m.amount > 0 then m.amount else 0 end) incoming,
       sum(case when m.period >= {period_from} and m.period < {period_to} and m.amount < 0 then -m.amount else 0 end) outgoing,
       sum(case when m.period < {period_to} then m.amount else 0 end) closing
  from reg_counterparty_settlement_mv m
  join ref_counterparty c on c.id = m.counterparty_id
  join ref_organization o on o.id = m.organization_id
 where {org_where(80)}
 group by o.name, c.name, m.direction, m.currency_code""",
        [("ORGANIZATION_NAME", "Організація"), ("COUNTERPARTY_NAME", "Контрагент"), ("DIRECTION_NAME", "Заборгованість"), ("CURRENCY_CODE", "Валюта"),
         num_col("OPENING", "Поч. залишок", q2), num_col("INCOMING", "Виникло", q2),
         num_col("OUTGOING", "Погашено", q2), num_col("CLOSING", "Кін. залишок", q2)],
        "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.organization_name, m.counterparty_name, m.direction_name, m.currency_code, m.amount\n  from v_settlement_movement m\n where " + org_where(80),
        [("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
         ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
         ("ORGANIZATION_NAME", "Організація"), ("COUNTERPARTY_NAME", "Контрагент"), ("DIRECTION_NAME", "Заборгованість"), ("CURRENCY_CODE", "Валюта"),
         num_col("AMOUNT", "Сума", q2)], org=True)


# ---------------------------------------------------------------------------
# Спільні списки значень
# ---------------------------------------------------------------------------
def sql_lov(ident, name, sql):
    b = f"name: {name}\n"
    b += block("source", "location: localDatabase\ntype: sqlQuery\nsqlQuery:" + code("sql", sql)) + "\n"
    b += block("columnMapping", "return: R\ndisplay: D")
    write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))


def lovs():
    sql_lov("units-of-measure-active", "UNITS_OF_MEASURE_ACTIVE",
            "select name || ' (' || short_name || ')' d, id r\n  from ref_unit_of_measure\n where state = 'ACTIVE'\n order by name")
    sql_lov("warehouses-active", "WAREHOUSES_ACTIVE",
            "select name d, id r\n  from ref_warehouse\n where state = 'ACTIVE'\n order by name")
    sql_lov("counterparties-active", "COUNTERPARTIES_ACTIVE",
            "select name d, id r\n  from ref_counterparty\n where state = 'ACTIVE'\n order by name")
    sql_lov("price-types-active", "PRICE_TYPES_ACTIVE",
            "select name d, id r\n  from ref_price_type\n where state = 'ACTIVE'\n order by name")
    sql_lov("products-active", "PRODUCTS_ACTIVE",
            "select p.name || ' (' || u.short_name || ')' d, p.id r\n  from ref_product p\n"
            "  join ref_unit_of_measure u on u.id = p.unit_of_measure_id\n where p.state = 'ACTIVE'\n order by p.name")
    b = "name: DOC_STATUSES\n" + block("source", "location: staticValues") + "\n"
    b += "\n" + comp("entry", "draft", "sequence: 1\ndisplay: Чернетка\nreturn: DRAFT")
    b += "\n" + comp("entry", "posted", "sequence: 2\ndisplay: Проведено\nreturn: POSTED")
    write(SC / "lovs" / "doc-statuses.apx", comp("lov", "doc-statuses", b))
    b = "name: CATALOG_STATES\n" + block("source", "location: staticValues") + "\n"
    b += "\n" + comp("entry", "active", "sequence: 1\ndisplay: Активний\nreturn: ACTIVE")
    b += "\n" + comp("entry", "marked", "sequence: 2\ndisplay: Помічений на видалення\nreturn: MARKED_FOR_DELETION")
    write(SC / "lovs" / "catalog-states.apx", comp("lov", "catalog-states", b))


# ===========================================================================
# r3 — НСІ, замовлення, повернення, інвентаризація, рахунки, звіти
# ===========================================================================
RECORDER_LOV = "recorders"
GOODS_COL = dict(PRODUCT_COL, lov="products-goods")
PRICE_COL = dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2, required=True)
AMOUNT_COL = dict(col="AMOUNT", heading="Сума", kind="display", dtype="number", mask=Q2, width=140)


def contract_field(owner_col, kind, span=6):
    return dict(col="CONTRACT_ID", label="Договір", type="ref", lov="CONTRACTS_" + ("CUSTOMER" if kind == "WITH_CUSTOMER" else "SUPPLIER"),
                span=span, required=False, cascade=owner_col,
                lov_sql=("select c.name || case when c.contract_number is not null then ' № ' || c.contract_number end d, c.id r\n"
                         "  from ref_contract c\n"
                         f" where c.state = 'ACTIVE' and c.contract_kind = '{kind}'\n"
                         f"   and c.owner_id = :P#PAGE#_{owner_col}\n order by c.name"),
                help="Список договорів обраного контрагента. Якщо договір один — підставляється автоматично.")


def base_field(col, label, span=6):
    return dict(col=col, label=label, type="display", lov=RECORDER_LOV, span=span)


def cmd(name, label, plsql, when, target=None, confirm=None, success=None, auth=None):
    return dict(name=name, label=label, plsql=plsql, when=when, target=target, confirm=confirm, success=success, auth=auth)


def r3_specs():
    # ---------------- довідники
    for c in CATALOGS:
        if c["table"] == "REF_PRODUCT":
            c["title"] = "Номенклатура"
            c["state_col"] = "p.state"
            c["tree"] = dict(group_col="p.group_id", html_fn="trade_tree.product_groups_html", group_form=171)
            c["list_sql"] = ("select p.id, p.code, p.article, p.name, case p.product_kind when 'SERVICE' then 'Послуга' else 'Товар' end kind_name, "
                             "g.full_path group_path, u.short_name unit_name, "
                             + STATE_SQL.replace("state", "p.state", 1)
                             + " from ref_product p join ref_unit_of_measure u on u.id = p.unit_of_measure_id"
                               " left join v_product_group_path g on g.id = p.group_id")
            c["columns"] = [("CODE", "Код"), ("ARTICLE", "Артикул"), ("NAME", "Найменування"), ("KIND_NAME", "Вид"),
                            ("GROUP_PATH", "Група"), ("UNIT_NAME", "Од."), ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="PRODUCT_KIND", label="Вид номенклатури", type="select", lov="product-kinds", required=True, span=6,
                     default="type: static\nstaticValue: GOODS"),
                dict(col="ARTICLE", label="Артикул", type="text", max=50, span=6, newcol=True),
                dict(col="GROUP_ID", label="Група", type="ref", lov="PRODUCT_GROUPS_ACTIVE", span=12),
                dict(col="WEIGHT_KG", label="Вага, кг", type="number", dtype="number", format="FM999G999G990D000", span=4),
                dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12),
            ]
    CATALOGS.append(dict(list_page=170, form_page=171, alias="product-groups", table="REF_PRODUCT_GROUP",
         title="Групи номенклатури", item_title="Група номенклатури",
         list_sql="select id, code, full_path, group_level, " + STATE_SQL + " from v_product_group_path",
         columns=[("CODE", "Код"), ("FULL_PATH", "Група"), ("GROUP_LEVEL", "Рівень"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
                 dict(col="PARENT_ID", label="Батьківська група", type="ref", lov="PRODUCT_GROUPS_ACTIVE", span=8,
                      help="Порожньо — група верхнього рівня. Глибина ієрархії — до 5 рівнів."),
                 dict(col="SORT_ORDER", label="Порядок", type="number", dtype="number", span=4, newcol=True)]))
    CATALOGS.append(dict(list_page=180, form_page=181, alias="contracts", table="REF_CONTRACT", state_col="c.state",
         title="Договори контрагентів", item_title="Договір",
         list_sql=("select c.id, c.code, o.name owner_name, c.name, c.contract_number, c.contract_date, "
                   "case c.contract_kind when 'WITH_CUSTOMER' then 'З покупцем' else 'З постачальником' end kind_name, "
                   "pt.name price_type_name, c.payment_term_days, c.credit_limit, "
                   + STATE_SQL.replace("state", "c.state", 1)
                   + " from ref_contract c join ref_counterparty o on o.id = c.owner_id left join ref_price_type pt on pt.id = c.price_type_id"),
         columns=[("CODE", "Код"), ("OWNER_NAME", "Контрагент"), ("NAME", "Найменування"), ("CONTRACT_NUMBER", "Номер"),
                  ("KIND_NAME", "Вид"), ("PRICE_TYPE_NAME", "Вид цін"), ("PAYMENT_TERM_DAYS", "Відстрочка, дн."),
                  ("CREDIT_LIMIT", "Кредитний ліміт"), ("STATE_NAME", "Стан")],
         fields=[dict(col="OWNER_ID", label="Контрагент", type="ref", lov="COUNTERPARTIES_ACTIVE", required=True, span=12),
                 dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
                 dict(col="CONTRACT_NUMBER", label="Номер договору", type="text", max=50, span=6),
                 dict(col="CONTRACT_DATE", label="Дата договору", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=6, newcol=True),
                 dict(col="CONTRACT_KIND", label="Вид договору", type="select", lov="contract-kinds", required=True, span=6,
                      default="type: static\nstaticValue: WITH_CUSTOMER"),
                 dict(col="PRICE_TYPE_ID", label="Вид цін", type="ref", lov="PRICE_TYPES_ACTIVE", span=6, newcol=True,
                      help="Лише для договорів з покупцем; підставляється в замовлення і реалізації."),
                 dict(col="PAYMENT_TERM_DAYS", label="Відстрочка, днів", type="number", dtype="number", span=6),
                 dict(col="CREDIT_LIMIT", label="Кредитний ліміт", type="number", dtype="number", format=Q2, span=6, newcol=True,
                      help="Порожньо — без ліміту. Реалізація не проводиться, якщо борг покупця перевищить ліміт."),
                 dict(col="VALID_FROM", label="Діє з", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=6),
                 dict(col="VALID_TO", label="Діє по", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=6, newcol=True)]))

    by_page = {d["page"]: d for d in DOCUMENTS}
    # ---------------- r1/r2 документи: договори, підстави, сканер, команди
    rc = by_page[51]
    rc["fields"] = rc["fields"][:2] + [contract_field("SUPPLIER_ID", "WITH_SUPPLIER"),
                                       base_field("BASE_ORDER_ID", "Замовлення-підстава")] + rc["fields"][2:]
    rc["scan"] = "RECEIPT"
    rc["commands"] = [cmd("CREATE_SUPPLIER_RETURN", "Створити повернення постачальнику",
                          "trade_r3.supplier_return_from_receipt(#ID#)", "posted", target=291)]
    sl = by_page[111]
    sl["fields"] = sl["fields"][:2] + [contract_field("CUSTOMER_ID", "WITH_CUSTOMER"),
                                       base_field("BASE_ORDER_ID", "Замовлення-підстава")] + sl["fields"][2:]
    sl["scan"] = "SALE"
    sl["commands"] = [cmd("CREATE_CUSTOMER_RETURN", "Створити повернення від клієнта",
                          "trade_r3.customer_return_from_sale(#ID#)", "posted", target=281)]
    wo = by_page[141]
    wo["fields"] = wo["fields"] + [base_field("BASE_INVENTORY_ID", "Інвентаризація-підстава", span=12)]
    wo["lines"]["cols"] = [GOODS_COL, QTY_COL]
    wo["scan"] = "WRITE_OFF"
    tr = by_page[131]
    tr["lines"]["cols"] = [GOODS_COL, QTY_COL]
    tr["scan"] = "TRANSFER"

    # ---------------- нові документи r3
    DOCUMENTS.extend([
        dict(page=261, list_page=260, alias="customer-order", list_alias="customer-orders", table="DOC_CUSTOMER_ORDER",
             title="Замовлення клієнта", list_title="Замовлення клієнтів", total=True, scan="CUSTOMER_ORDER",
             list_sql=("select d.id, d.doc_number, d.occurred_at, c.name customer_name, w.name warehouse_name, d.shipment_date, "
                       "d.total_amount, (select max(order_state) from v_customer_orders_analysis a where a.order_id = d.id) order_state, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_customer_order d\n  join ref_counterparty c on c.id = d.customer_id\n"
                       "  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("CUSTOMER_NAME", "Покупець"), ("WAREHOUSE_NAME", "Склад"),
                        ("SHIPMENT_DATE", "Відвантажити до", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                        money_col("TOTAL_AMOUNT", "Сума"), ("ORDER_STATE", "Стан виконання")],
             fields=[ref_field("CUSTOMER_ID", "Покупець", "COUNTERPARTIES_ACTIVE", newcol=True),
                     contract_field("CUSTOMER_ID", "WITH_CUSTOMER"),
                     ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     ref_field("PRICE_TYPE_ID", "Вид цін", "PRICE_TYPES_ACTIVE", span=6, required=False,
                               help="Порожня ціна в рядку заповнюється за цим видом цін."),
                     dict(col="SHIPMENT_DATE", label="Відвантажити до", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=3),
                     dict(col="CLOSED", type="hidden")],
             lines=dict(table="DOC_CUSTOMER_ORDER_GOODS", title="Товари", cols=[
                 PRODUCT_COL, QTY_COL,
                 dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2, help="Порожня — з виду цін."),
                 dict(col="DISCOUNT_PERCENT", heading="Знижка, %", kind="number", dtype="number", mask="FM990D00", width=90),
                 AMOUNT_COL,
                 dict(col="RESERVE_FLAG", heading="Резерв", kind="switch", width=80)]),
             commands=[cmd("CREATE_SALE", "Створити реалізацію", "trade_r3.sale_from_order(#ID#)", "posted_open", target=111),
                       cmd("CREATE_INVOICE", "Створити рахунок", "trade_r3.invoice_from_order(#ID#)", "posted", target=321),
                       cmd("CLOSE_ORDER", "Закрити замовлення", "trade_r3.close_customer_order(#ID#);", "posted_open",
                           confirm="Закрити замовлення? Невідвантажений залишок і резерв буде знято.", success="Замовлення закрито."),
                       cmd("REOPEN_ORDER", "Відкрити замовлення", "trade_r3.reopen_customer_order(#ID#);", "posted_closed",
                           success="Замовлення відкрито.")],
             post="trade_r3.post_customer_order", unpost="trade_r3.unpost_customer_order", copy="trade_r3.copy_customer_order"),
        dict(page=271, list_page=270, alias="supplier-order", list_alias="supplier-orders", table="DOC_SUPPLIER_ORDER",
             title="Замовлення постачальнику", list_title="Замовлення постачальникам", total=True, scan="SUPPLIER_ORDER",
             list_sql=("select d.id, d.doc_number, d.occurred_at, s.name supplier_name, w.name warehouse_name, d.expected_date, "
                       "d.total_amount, (select max(order_state) from v_supplier_orders_analysis a where a.order_id = d.id) order_state, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_supplier_order d\n  join ref_counterparty s on s.id = d.supplier_id\n"
                       "  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("SUPPLIER_NAME", "Постачальник"), ("WAREHOUSE_NAME", "Склад"),
                        ("EXPECTED_DATE", "Очікується", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                        money_col("TOTAL_AMOUNT", "Сума"), ("ORDER_STATE", "Стан виконання")],
             fields=[ref_field("SUPPLIER_ID", "Постачальник", "COUNTERPARTIES_ACTIVE", newcol=True),
                     contract_field("SUPPLIER_ID", "WITH_SUPPLIER"),
                     ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     dict(col="EXPECTED_DATE", label="Очікується", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=3),
                     dict(col="CLOSED", type="hidden")],
             lines=dict(table="DOC_SUPPLIER_ORDER_GOODS", title="Товари", cols=[
                 PRODUCT_COL, QTY_COL,
                 dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2, help="Порожня — остання ціна постачальника."),
                 AMOUNT_COL]),
             commands=[cmd("FILL_BY_REORDER", "Заповнити за потребою", "trade_r3.fill_by_reorder_policy(#ID#);", "draft",
                           success="Заповнено за параметрами забезпечення запасів."),
                       cmd("REFRESH_PRICES", "Оновити ціни постачальника", "trade_r3.refresh_supplier_prices(#ID#);", "draft",
                           success="Ціни оновлено."),
                       cmd("CREATE_RECEIPT", "Створити надходження", "trade_r3.receipt_from_order(#ID#)", "posted_open", target=51),
                       cmd("CLOSE_ORDER", "Закрити замовлення", "trade_r3.close_supplier_order(#ID#);", "posted_open",
                           confirm="Закрити замовлення? Неотриманий залишок буде знято.", success="Замовлення закрито."),
                       cmd("REOPEN_ORDER", "Відкрити замовлення", "trade_r3.reopen_supplier_order(#ID#);", "posted_closed",
                           success="Замовлення відкрито.")],
             post="trade_r3.post_supplier_order", unpost="trade_r3.unpost_supplier_order", copy="trade_r3.copy_supplier_order"),
        dict(page=281, list_page=280, alias="customer-return", list_alias="customer-returns", table="DOC_CUSTOMER_RETURN",
             title="Повернення від клієнта", list_title="Повернення від клієнтів", total=True,
             list_sql=("select d.id, d.doc_number, d.occurred_at, c.name customer_name, w.name warehouse_name, d.total_amount, d.return_reason, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_customer_return d\n  join ref_counterparty c on c.id = d.customer_id\n"
                       "  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("CUSTOMER_NAME", "Покупець"), ("WAREHOUSE_NAME", "Склад"), money_col("TOTAL_AMOUNT", "Сума"),
                        ("RETURN_REASON", "Причина")],
             fields=[base_field("BASE_SALE_ID", "Реалізація-підстава"),
                     dict(col="CUSTOMER_ID", label="Покупець", type="display", lov="counterparties-all", span=6),
                     dict(col="CONTRACT_ID", type="hidden"),
                     ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     dict(col="RETURN_REASON", label="Причина повернення", type="text", max=255, span=6)],
             lines=dict(table="DOC_CUSTOMER_RETURN_GOODS", title="Товари", ops=["update", "delete"], cols=[
                 dict(col="PRODUCT_NAME", heading="Товар", kind="display", sql="(select name from ref_product p where p.id = product_id)", width=380),
                 dict(col="QUANTITY", heading="Кількість", kind="number", dtype="number", mask=Q3, required=True),
                 dict(col="PRICE", heading="Ціна", kind="display", dtype="number", mask=Q2),
                 AMOUNT_COL]),
             post="trade_r3.post_customer_return", unpost="trade_r3.unpost_customer_return", copy="trade_r3.copy_customer_return"),
        dict(page=291, list_page=290, alias="supplier-return", list_alias="supplier-returns", table="DOC_SUPPLIER_RETURN",
             title="Повернення постачальнику", list_title="Повернення постачальникам", total=True,
             list_sql=("select d.id, d.doc_number, d.occurred_at, s.name supplier_name, w.name warehouse_name, d.total_amount, d.return_reason, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_supplier_return d\n  join ref_counterparty s on s.id = d.supplier_id\n"
                       "  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("SUPPLIER_NAME", "Постачальник"), ("WAREHOUSE_NAME", "Склад"), money_col("TOTAL_AMOUNT", "Сума"),
                        ("RETURN_REASON", "Причина")],
             fields=[base_field("BASE_RECEIPT_ID", "Надходження-підстава"),
                     dict(col="SUPPLIER_ID", label="Постачальник", type="display", lov="counterparties-all", span=6),
                     dict(col="CONTRACT_ID", type="hidden"),
                     ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     dict(col="RETURN_REASON", label="Причина повернення", type="text", max=255, span=6, required=True)],
             lines=dict(table="DOC_SUPPLIER_RETURN_GOODS", title="Товари", ops=["update", "delete"], cols=[
                 dict(col="PRODUCT_NAME", heading="Товар", kind="display", sql="(select name from ref_product p where p.id = product_id)", width=380),
                 dict(col="QUANTITY", heading="Кількість", kind="number", dtype="number", mask=Q3, required=True),
                 dict(col="PRICE", heading="Ціна", kind="display", dtype="number", mask=Q2),
                 AMOUNT_COL]),
             post="trade_r3.post_supplier_return", unpost="trade_r3.unpost_supplier_return", copy="trade_r3.copy_supplier_return"),
        dict(page=301, list_page=300, alias="inventory-count", list_alias="inventory-counts", table="DOC_INVENTORY_COUNT",
             title="Інвентаризація товарів", list_title="Інвентаризація товарів", scan="INVENTORY",
             list_sql=("select d.id, d.doc_number, d.occurred_at, w.name warehouse_name, d.responsible_person, d.surplus_amount, d.shortage_amount, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_inventory_count d\n  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("WAREHOUSE_NAME", "Склад"), ("RESPONSIBLE_PERSON", "Відповідальний"),
                        money_col("SURPLUS_AMOUNT", "Надлишки"), money_col("SHORTAGE_AMOUNT", "Недостачі")],
             fields=[ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     dict(col="RESPONSIBLE_PERSON", label="Відповідальний", type="text", max=255, span=6),
                     dict(col="SURPLUS_AMOUNT", label="Надлишки", type="display", dtype="number", format=Q2, span=3),
                     dict(col="SHORTAGE_AMOUNT", label="Недостачі", type="display", dtype="number", format=Q2, span=3)],
             lines=dict(table="DOC_INVENTORY_COUNT_GOODS", title="Товари", cols=[
                 GOODS_COL,
                 dict(col="BOOK_QUANTITY", heading="За обліком", kind="display", dtype="number", mask=Q3, no_dml=True),
                 dict(col="ACTUAL_QUANTITY", heading="Фактично", kind="number", dtype="number", mask=Q3),
                 dict(col="DEVIATION", heading="Відхилення", kind="display", dtype="number", mask=Q3),
                 dict(col="PRICE", heading="Ціна (собів.)", kind="display", dtype="number", mask=Q2),
                 dict(col="DEVIATION_AMOUNT", heading="Сума відхилення", kind="display", dtype="number", mask=Q2, width=140)]),
             commands=[cmd("FILL_BOOK", "Заповнити обліковими залишками", "trade_r3.fill_with_book_balances(#ID#);", "draft",
                           success="Заповнено обліковими залишками."),
                       cmd("CREATE_SURPLUS", "Оприбуткувати надлишки", "trade_r3.surplus_from_inventory(#ID#)", "posted", target=311),
                       cmd("CREATE_WRITE_OFF", "Списати недостачі", "trade_r3.write_off_from_inventory(#ID#)", "posted", target=141)],
             post="trade_r3.post_inventory_count", unpost="trade_r3.unpost_inventory_count", copy="trade_r3.copy_inventory_count"),
        dict(page=311, list_page=310, alias="surplus-posting", list_alias="surplus-postings", table="DOC_SURPLUS_POSTING",
             title="Оприбуткування надлишків", list_title="Оприбуткування надлишків", total=True, scan="SURPLUS",
             list_sql=("select d.id, d.doc_number, d.occurred_at, w.name warehouse_name, d.reason, d.total_amount, "
                       + STATUS_SQL + ", d.doc_comment\n  from doc_surplus_posting d\n  join ref_warehouse w on w.id = d.warehouse_id"),
             list_cols=[("WAREHOUSE_NAME", "Склад"), ("REASON", "Причина"), money_col("TOTAL_AMOUNT", "Сума")],
             fields=[ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE", newcol=True),
                     dict(col="REASON", label="Причина оприбуткування", type="text", max=255, span=6, required=True),
                     base_field("BASE_INVENTORY_ID", "Інвентаризація-підстава")],
             lines=dict(table="DOC_SURPLUS_POSTING_GOODS", title="Товари", cols=[GOODS_COL, QTY_COL, PRICE_COL, AMOUNT_COL]),
             post="trade_r3.post_surplus_posting", unpost="trade_r3.unpost_surplus_posting", copy="trade_r3.copy_surplus_posting"),
        dict(page=321, list_page=320, alias="invoice", list_alias="invoices", table="DOC_INVOICE_FOR_PAYMENT",
             title="Рахунок на оплату", list_title="Рахунки на оплату", total=True, scan="INVOICE", post_success="Рахунок видано.",
             posted_value="ISSUED", post_label="Видати", unpost_label="Повернути в чернетку", unpost_when="not_draft",
             unpost_confirm="Повернути рахунок у чернетку?",
             list_sql=("select d.id, d.doc_number, d.occurred_at, c.name customer_name, d.payment_due_date, d.total_amount, "
                       "case d.status when 'ISSUED' then 'Видано' when 'CANCELLED' then 'Анульовано' else 'Чернетка' end status_name, d.doc_comment\n"
                       "  from doc_invoice_for_payment d\n  join ref_counterparty c on c.id = d.customer_id"),
             list_cols=[("CUSTOMER_NAME", "Покупець"),
                        ("PAYMENT_DUE_DATE", "Сплатити до", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                        money_col("TOTAL_AMOUNT", "Сума"), ("STATUS_NAME", "Стан")],
             fields=[ref_field("CUSTOMER_ID", "Покупець", "COUNTERPARTIES_ACTIVE", newcol=True),
                     contract_field("CUSTOMER_ID", "WITH_CUSTOMER"),
                     dict(col="PAYMENT_DUE_DATE", label="Сплатити до", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=3),
                     base_field("BASE_ORDER_ID", "Замовлення-підстава")],
             lines=dict(table="DOC_INVOICE_FOR_PAYMENT_GOODS", title="Товари", cols=[PRODUCT_COL, QTY_COL, PRICE_COL, AMOUNT_COL]),
             extra_items=[dict(name="CANCEL_TEXT", label="Причина анулювання", span=8, when="posted")],
             commands=[cmd("PRINT", "Друк рахунку", "#ID#", "exists", target=322),
                       cmd("CANCEL_INVOICE", "Анулювати", "trade_r3.cancel_invoice(#ID#, :P321_CANCEL_TEXT);", "posted",
                           confirm="Анулювати рахунок?", success="Рахунок анульовано.")],
             post="trade_r3.issue_invoice", unpost="trade_r3.invoice_to_draft", copy="trade_r3.copy_invoice"),
    ])


PICK = {111: ("WAREHOUSE_ID", True, False), 51: ("WAREHOUSE_ID", False, True), 261: ("WAREHOUSE_ID", True, False),
        271: ("WAREHOUSE_ID", False, True), 131: ("WAREHOUSE_FROM_ID", False, False), 141: ("WAREHOUSE_ID", False, False),
        301: ("WAREHOUSE_ID", False, False), 311: ("WAREHOUSE_ID", False, False)}


def add_pick_settings():
    for d in DOCUMENTS:
        if d["page"] in PICK:
            wh, pt, sup = PICK[d["page"]]
            d["pick_wh"], d["pick_pt"], d["pick_sup"] = wh, pt, sup


def pick_page():
    """Форма підбору товарів (F-SRV-02): вільний залишок, ціна, кількість → рядки документа."""
    p = 950
    body = page_header(p, "Підбір товарів", "pick", "Підбір товарів", modal=True).replace("width: 720", "width: 1200", 1)
    for i, it in enumerate(["KIND", "ID", "WH", "PT", "SUP"]):
        ib = "type: hidden\n" + block("layout", f"sequence: {i + 1}\nregion: @goods\nslot: regionBody") + "\n"
        ib += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P950_{it}", ib)
    # Дерево груп ліворуч, як у формі підбору 1С (F-UI-07 етап 2, APE-286)
    tb = "name: Групи\ntype: dynamicContent\n"
    tb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        "return '<div class=\"tx-tree-bar\"><label class=\"tx-tree-sub\"><input type=\"checkbox\" data-item=\"P950_SUB\"'\n"
        "    || case when nvl(:P950_SUB, 'Y') = 'Y' then ' checked' end || '> З підгрупами</label></div>'\n"
        "    || trade_tree.product_groups_html(:P950_GROUP, 'P950_GROUP');")
        + "\npageItemsToSubmit: [\n    P950_GROUP\n    P950_SUB\n]") + "\n"
    tb += block("layout", "sequence: 5\nslot: contentBody\ncolumnSpan: 3") + "\n"
    tb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-tree-region")
    body += "\n" + comp("region", "tree", tb)
    for it, dflt in (("GROUP", None), ("SUB", "Y")):
        hb = "type: hidden\n" + block("layout", f"sequence: {10 if it == 'GROUP' else 20}\nregion: @tree\nslot: regionBody") + "\n"
        hb += block("settings", "valueProtected: false") + "\n"
        if dflt:
            hb += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        hb += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P950_{it}", hb)
    sql = ("select p.id product_id, p.code, p.article, p.name product_name, u.short_name unit_name, g.full_path group_path,\n"
           "       (select f.free_qty from v_free_stock f where f.warehouse_id = :P950_WH and f.product_id = p.id) free_qty,\n"
           "       coalesce(case when :P950_PT is not null then trade_lines.get_price(:P950_PT, p.id, sysdate) end,\n"
           "                case when :P950_SUP is not null then trade_lines.get_supplier_price(:P950_SUP, p.id, sysdate) end) price,\n"
           "       cast(null as number) qty\n"
           "  from ref_product p\n  join ref_unit_of_measure u on u.id = p.unit_of_measure_id\n"
           "  left join v_product_group_path g on g.id = p.group_id\n"
           " where p.state = 'ACTIVE'\n"
           "   and trade_tree.in_group(p.group_id, :P950_GROUP, nvl(:P950_SUB, 'Y')) = 'Y'\n"
           "   and (p.product_kind = 'GOODS' or :P950_KIND in ('SALE', 'RECEIPT', 'CUSTOMER_ORDER', 'SUPPLIER_ORDER', 'INVOICE'))\n"
           " order by g.full_path nulls last, p.name")
    gb = "name: Товари\ntype: interactiveGrid\n"
    gb += block("source", "location: localDatabase\ntype: sqlQuery\nsqlQuery:" + code("sql", sql)
                + "\npageItemsToSubmit: [\n    P950_WH\n    P950_PT\n    P950_SUP\n    P950_KIND\n    P950_GROUP\n    P950_SUB\n]") + "\n"
    gb += block("layout", "sequence: 10\nslot: contentBody\ncolumnSpan: 9\nstartNewRow: false") + "\n"
    gb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#") + "\n"
    gb += block("edit", "enabled: true\nallowedOperations: [\n    update\n]\nlostUpdateType: rowValues") + "\n"
    gb += block("toolbar", "show: true\ncontrols: [\n    searchField\n]") + "\n"
    gb += block("advanced", f"savedReportMappingIdentifier: {next_mapping_id()}") + "\n"
    cols = [("CODE", "Код", "display", "varchar2", 90, None), ("ARTICLE", "Артикул", "display", "varchar2", 90, None),
            ("PRODUCT_NAME", "Товар", "display", "varchar2", 260, None), ("UNIT_NAME", "Од.", "display", "varchar2", 50, None),
            ("GROUP_PATH", "Група", "display", "varchar2", 180, None),
            ("FREE_QTY", "Вільний залишок", "display", "number", 110, Q3), ("PRICE", "Ціна", "display", "number", 100, Q2),
            ("QTY", "Кількість", "number", "number", 100, Q3)]
    disp = ""
    for i, (cn, hd, k, dt, w, mk) in enumerate(cols):
        disp += "\n" + comp("displayColumn", cn, f"column: @{cn}\n" + block("layout", f"sequence: {(i + 1) * 10}\nshow: true\nwidth: {w}"))
    gb += "\n" + comp("savedReport", "primary", "name: Основний\nvisibility: primary\n" + block("view", "default: grid") + "\n" + disp)
    pk = ig_column("PRODUCT_ID", "ID", 5, "hidden").replace("    queryOnly: true\n", "    primaryKey: true\n")
    gb += "\n" + pk
    for i, (cn, hd, k, dt, w, mk) in enumerate(cols):
        extra = block("appearance", f"formatMask: {mk}") + "\n" if mk else ""
        col = ig_column(cn, hd, (i + 1) * 10, k, dt, extra)
        if cn == "QTY":
            col = col.replace("    queryOnly: true\n", "")
        gb += "\n" + col
    body += "\n" + comp("region", "goods", gb)
    bb = "name: Кнопки\ntype: staticContent\n" + block("layout", "sequence: 20\nslot: dialogFooter") + "\n"
    bb += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "buttons", bb)
    body += "\n" + button("cancel", "CANCEL", "Скасувати", 10, "buttons", slot="close", action="definedByDynamicAction")
    body += "\n" + button("add", "ADD", "Перенести в документ", 20, "buttons", slot="next", hot=True)
    da = "name: Скасувати\n" + block("when", "event: click\nselectionType: button\nbutton: @cancel") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "cancel-dialog", "name: Закрити\naction: cancelDialog\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "cancel", da)
    dml = """if :APEX$ROW_STATUS = 'U' and :QTY is not null then
  trade_r3.add_product(
    :P950_KIND, :P950_ID, :PRODUCT_ID,
    to_number(:QTY, 'FM999G999G999G990D000'),
    case :P950_KIND
      when 'RECEIPT' then trade_lines.get_supplier_price(:P950_SUP, :PRODUCT_ID, sysdate)
      when 'SURPLUS' then trade_r3.last_average_cost(:P950_WH, :PRODUCT_ID)
    end);
end if;"""
    body += "\n" + process("add-lines", "Перенести в документ", "interactiveGridAutoRowProcessing", 10,
                            "editableRegion: @goods\n" + block("target", "targetType: plsqlCode\ndmlPlsqlCode:" + code("plsql", dml)) + "\n"
                            + block("lockRow", "lockRow: false\npreventLostUpdates: false") + "\n",
                            point="afterSubmit")
    # Зміна групи: введені кількості спершу зберігаються в документ (як «кошик» підбору), потім список оновлюється
    for it in ("GROUP", "SUB"):
        da = f"name: Фільтр {it}\n" + block("when", f"event: change\nselectionType: items\nitems: P950_{it}") + "\n" + block("execution", f"sequence: {30 if it == 'GROUP' else 40}") + "\n\n"
        da += comp("action", "refresh", "name: Зберегти й оновити\naction: executeJsCode\n"
                   + block("settings", "jsCode:" + code("javascript",
                       "var r = apex.region(this.affectedElements[0].id),\n"
                       "    m = r.call('getViews', 'grid').model;\n"
                       "if (m.isChanged()) {\n"
                       "  r.widget().one('interactivegridsave', function () { r.refresh(); });\n"
                       "  r.call('getActions').invoke('save');\n"
                       "} else {\n"
                       "  r.refresh();\n"
                       "}")) + "\n"
                   + block("affectedElements", "selectionType: region\nregion: @goods") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
        body += "\n" + comp("dynamicAction", f"filter-{it.lower()}", da)
    body += "\n" + process("close", "Закрити діалог", "closeDialog", 20, point="afterSubmit", when_button="add")
    write(PAGES / "p00950-pick.apx", comp("page", str(p), body))


def add_print_commands():
    for d in DOCUMENTS:
        d.setdefault("commands", [])
        d["commands"] = [c for c in d["commands"] if c["name"] != "PRINT"]
        d["commands"].append(cmd("PRINT", "Друк", "#ID#", "exists", target=900))


def r3_lovs():
    sql_lov("product-groups-active", "PRODUCT_GROUPS_ACTIVE",
            "select full_path d, id r\n  from v_product_group_path\n where state = 'ACTIVE'\n order by full_path")
    sql_lov("products-goods", "PRODUCTS_GOODS",
            "select p.name || ' (' || u.short_name || ')' d, p.id r\n  from ref_product p\n"
            "  join ref_unit_of_measure u on u.id = p.unit_of_measure_id\n where p.state = 'ACTIVE' and p.product_kind = 'GOODS'\n order by p.name")
    sql_lov("contracts-customer", "CONTRACTS_CUSTOMER",
            "select o.name || ': ' || c.name d, c.id r\n  from ref_contract c join ref_counterparty o on o.id = c.owner_id\n"
            " where c.state = 'ACTIVE' and c.contract_kind = 'WITH_CUSTOMER'\n order by 1")
    sql_lov("contracts-supplier", "CONTRACTS_SUPPLIER",
            "select o.name || ': ' || c.name d, c.id r\n  from ref_contract c join ref_counterparty o on o.id = c.owner_id\n"
            " where c.state = 'ACTIVE' and c.contract_kind = 'WITH_SUPPLIER'\n order by 1")
    sql_lov("counterparties-all", "COUNTERPARTIES_ALL", "select name d, id r\n  from ref_counterparty\n order by name")
    sql_lov("recorders", "RECORDERS", "select recorder_name d, recorder_id r\n  from v_recorder")
    sql_lov("warehouses-all", "WAREHOUSES_ALL", "select name d, id r\n  from ref_warehouse\n order by name")
    for ident, name, entries in [
        ("product-kinds", "PRODUCT_KINDS", [("goods", "Товар", "GOODS"), ("service", "Послуга", "SERVICE")]),
        ("contract-kinds", "CONTRACT_KINDS", [("customer", "З покупцем", "WITH_CUSTOMER"), ("supplier", "З постачальником", "WITH_SUPPLIER")]),
        ("reorder-methods", "REORDER_METHODS", [("minmax", "Мін/макс", "MIN_MAX"), ("none", "Не поповнювати", "NONE")]),
    ]:
        b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
        for i, (eid, disp, ret) in enumerate(entries):
            b += "\n" + comp("entry", eid, f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
        write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))


def editable_register_page(p, alias, title, table, cols, order_by, extra_tabs=None, extra_body=""):
    """Незалежний інформаційний регістр: список-таблиця з редагуванням (типізовані зміни в тригерах)."""
    body = page_header(p, title, alias, title)
    body += "\n" + title_region(title, seq=0)
    sel = ", ".join(["id"] + [c["col"].lower() for c in cols])
    gb = f"name: {title}\ntype: interactiveGrid\n"
    gb += block("source", "location: localDatabase\ntype: sqlQuery\nsqlQuery:" + code("sql", f"select {sel}\n  from {table.lower()}\n order by {order_by}")) + "\n"
    gb += block("layout", "sequence: 10\nslot: body") + "\n"
    gb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
    gb += block("edit", "enabled: true\nallowedOperations: [\n    add\n    update\n    delete\n]\nlostUpdateType: rowValues") + "\n"
    gb += block("toolbar", "show: true\ncontrols: [\n    searchField\n    actionsMenu\n    saveButton\n]\naddButtonLabel: Додати") + "\n"
    gb += block("advanced", f"savedReportMappingIdentifier: {next_mapping_id()}" + ("\nregionDisplaySelector: true" if extra_tabs else "")) + "\n"
    disp = ""
    for i, c in enumerate(cols):
        disp += "\n" + comp("displayColumn", c["col"], f"column: @{c['col']}\n" + block("layout", f"sequence: {(i + 1) * 10}\nshow: true\nwidth: {c.get('width', 140)}"))
    gb += "\n" + comp("savedReport", "primary", "name: Основний\nvisibility: primary\n" + block("view", "default: grid") + "\n" + disp)
    gb += "\n" + ig_column("ID", "ID", 5, "hidden")
    for i, c in enumerate(cols):
        extra = ""
        if c.get("required"):
            extra += block("validation", "valueRequired: true") + "\n"
        if c["kind"] in ("ref", "select"):
            extra += block("lov", f"type: sharedComponent\nlov: @{c['lov']}\ndisplayExtraValues: true\ndisplayNullValue: true") + "\n"
            if c["kind"] == "ref":
                extra += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
        if c.get("mask"):
            extra += block("appearance", f"formatMask: {c['mask']}") + "\n"
        kind = c["kind"]
        col_txt = ig_column(c["col"], c["heading"], (i + 1) * 10, kind if kind in ("number", "ref", "date") else "display",
                            c.get("dtype", "varchar2"), extra)
        if c["kind"] == "text":
            col_txt = col_txt.replace("type: displayOnly", "type: textField", 1).replace("    queryOnly: true\n", "")
        if c["kind"] == "select":
            col_txt = col_txt.replace("type: displayOnly", "type: selectList", 1).replace("    queryOnly: true\n", "")
        gb += "\n" + col_txt
    body += "\n" + comp("region", "grid", gb)
    pb = process("dml", "Записати", "interactiveGridAutoRowProcessing", 10,
                 "editableRegion: @grid\n" + block("target", f"targetType: tableView\ntableName: {table}") + "\n"
                 + block("lockRow", "lockRow: true\npreventLostUpdates: true") + "\n", point="afterSubmit")
    body += "\n" + pb
    if extra_tabs:
        sel_r = "name: Режим\ntype: regionDisplaySelector\n" + block("layout", "sequence: 5\nslot: body") + "\n"
        sel_r += block("settings", "mode: viewSingleRegion\nincludeShowAll: false\nrememberSelection: bySession") + "\n"
        sel_r += block("appearance", "template: @/buttons-container\ntemplateOptions: #DEFAULT#")
        body += "\n" + comp("region", "mode", sel_r)
        body = body.replace(f"    name: {title}\n    type: interactiveGrid\n", f"    name: {title}\n    title: {title}\n    type: interactiveGrid\n", 1)
        for i, (ident, ttl, sql, tcols) in enumerate(extra_tabs):
            r = ir_region(ident, ttl, sql, tcols, seq=20 + i * 10, title=ttl)
            r = r.replace("    advanced {\n", "    advanced {\n        regionDisplaySelector: true\n", 1)
            body += "\n" + r
    body += extra_body
    write(PAGES / f"p{p:05d}-{alias}.apx", comp("page", str(p), body))


def print_page():
    """Універсальна сторінка друку документів (форми trade_print.document_html)."""
    p = 900
    body = page_header(p, "Друк документа", "print", "Друк")
    bar = "name: Панель друку\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)
    fi = "type: selectList\n" + block("label", "label: Форма\nalignment: right") + "\n"
    fi += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 5") + "\n"
    fi += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    fi += block("lov", "type: sqlQuery\nsqlQuery:" + code("sql",
        "select substr(column_value, instr(column_value, ':') + 1) d, substr(column_value, 1, instr(column_value, ':') - 1) r\n"
        "  from table(apex_string.split(trade_print.forms_of(:P900_ID), ';'))") + "\ndisplayNullValue: false") + "\n"
    fi += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: trade_print.default_form(:P900_ID)") + "\n"
    fi += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", "P900_FORM", fi)
    ib = "type: hidden\n" + block("layout", "sequence: 20\nregion: @bar\nslot: regionBody") + "\n"
    ib += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", "P900_ID", ib)
    body += "\n" + button("print", "PRINT", "Друк", 30, "bar", slot="regionBody", hot=True, action="definedByDynamicAction")
    pb = "name: Друкована форма\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        "return trade_print.document_html(coalesce(:P900_FORM, trade_print.default_form(:P900_ID)), :P900_ID);") + "\npageItemsToSubmit: [\n    P900_FORM\n]") + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "doc", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    da2 = "name: Змінити форму\n" + block("when", "event: change\nselectionType: items\nitems: P900_FORM") + "\n" + block("execution", "sequence: 20") + "\n\n"
    da2 += comp("action", "refresh", "name: Оновити\naction: refresh\n" + block("affectedElements", "selectionType: region\nregion: @doc") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "change-form", da2)
    write(PAGES / "p00900-print.apx", comp("page", str(p), body))


def r3_registers_and_reports():
    q3, q2 = Q3, Q2
    dt = ("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")
    editable_register_page(190, "barcodes", "Штрихкоди номенклатури", "REG_BARCODE", [
        dict(col="BARCODE", heading="Штрихкод", kind="text", required=True, width=180),
        dict(col="PRODUCT_ID", heading="Товар", kind="ref", lov="products-active", required=True, width=320),
        dict(col="UNIT_QUANTITY", heading="Кількість в упаковці", kind="number", dtype="number", mask=q3, required=True)],
        "barcode")
    editable_register_page(210, "reorder-policies", "Параметри забезпечення запасів", "REG_REORDER_POLICY", [
        dict(col="WAREHOUSE_ID", heading="Склад", kind="ref", lov="warehouses-active", required=True, width=180),
        dict(col="PRODUCT_ID", heading="Товар", kind="ref", lov="products-goods", required=True, width=280),
        dict(col="MIN_QUANTITY", heading="Мін. запас", kind="number", dtype="number", mask=q3, required=True),
        dict(col="MAX_QUANTITY", heading="Макс. запас", kind="number", dtype="number", mask=q3, required=True),
        dict(col="REORDER_METHOD", heading="Спосіб", kind="select", lov="reorder-methods", required=True),
        dict(col="PREFERRED_SUPPLIER_ID", heading="Постачальник", kind="ref", lov="counterparties-active", width=200),
        dict(col="LEAD_TIME_DAYS", heading="Термін постачання, дн.", kind="number", dtype="number")],
        "warehouse_id, product_id",
        extra_tabs=[("need", "Потреба в закупівлі",
                     "select warehouse_name, product_name, unit_name, stock_qty, reserved_qty, on_order_qty, available_qty,\n"
                     "       min_quantity, max_quantity, need_qty, supplier_name\n  from v_purchase_need",
                     [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
                      num_col("STOCK_QTY", "Залишок", q3), num_col("RESERVED_QTY", "Резерв", q3), num_col("ON_ORDER_QTY", "Замовлено", q3),
                      num_col("AVAILABLE_QTY", "Доступно", q3), num_col("MIN_QUANTITY", "Мін.", q3), num_col("MAX_QUANTITY", "Макс.", q3),
                      num_col("NEED_QTY", "Потреба", q3), ("SUPPLIER_NAME", "Постачальник")])])
    tabs_report_page(200, "supplier-prices", "Ціни постачальників", [
        ("current", "Діючі ціни", "select supplier_name, product_code, product_name, unit_name, price, period\n  from v_supplier_price_current",
         [("SUPPLIER_NAME", "Постачальник"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("PRICE", "Ціна", q2), ("PERIOD", "Діє з", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")])])
    tabs_report_page(220, "free-stock", "Резерви та вільні залишки", [
        ("free", "Вільні залишки", "select warehouse_name, product_code, product_name, unit_name, stock_qty, reserved_qty, free_qty\n  from v_free_stock",
         [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("STOCK_QTY", "Залишок", q3), num_col("RESERVED_QTY", "Резерв", q3), num_col("FREE_QTY", "Вільно", q3)]),
        ("reserves", "Резерви за замовленнями", "select order_number, customer_name, warehouse_name, product_name, unit_name, reserved_qty\n  from v_stock_reserve",
         [("ORDER_NUMBER", "Замовлення"), ("CUSTOMER_NAME", "Покупець"), ("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"),
          ("UNIT_NAME", "Од."), num_col("RESERVED_QTY", "Резерв", q3)])])
    tabs_report_page(230, "customer-orders-analysis", "Аналіз замовлень клієнтів", [
        ("analysis", "Виконання замовлень",
         "select order_number, occurred_at, shipment_date, customer_name, product_name, unit_name, ordered_qty, shipped_qty, remaining_qty, remaining_amount, order_state\n  from v_customer_orders_analysis",
         [("ORDER_NUMBER", "Замовлення"), ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
          ("SHIPMENT_DATE", "Відвантажити до", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
          ("CUSTOMER_NAME", "Покупець"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("ORDERED_QTY", "Замовлено", q3), num_col("SHIPPED_QTY", "Відвантажено", q3), num_col("REMAINING_QTY", "Залишок", q3),
          num_col("REMAINING_AMOUNT", "Сума залишку", q2), ("ORDER_STATE", "Стан")])])
    tabs_report_page(240, "supplier-orders-analysis", "Аналіз замовлень постачальникам", [
        ("analysis", "Виконання замовлень",
         "select order_number, occurred_at, expected_date, supplier_name, product_name, unit_name, ordered_qty, received_qty, remaining_qty, remaining_amount, order_state\n  from v_supplier_orders_analysis",
         [("ORDER_NUMBER", "Замовлення"), ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
          ("EXPECTED_DATE", "Очікується", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
          ("SUPPLIER_NAME", "Постачальник"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("ORDERED_QTY", "Замовлено", q3), num_col("RECEIVED_QTY", "Отримано", q3), num_col("REMAINING_QTY", "Залишок", q3),
          num_col("REMAINING_AMOUNT", "Сума залишку", q2), ("ORDER_STATE", "Стан")])])
    pf, pt = "to_date(:P250_FROM, 'DD.MM.YYYY')", "to_date(:P250_TO, 'DD.MM.YYYY') + 1"
    tabs_report_page(250, "stock-cost", "Вартість запасів і валовий прибуток", [
        ("gross", "Валовий прибуток за товарами",
         "select product_name, unit_name, sum(quantity) quantity, sum(revenue) revenue, sum(cost) cost, sum(gross_profit) gross_profit,\n"
         "       round(100 * sum(gross_profit) / nullif(sum(revenue), 0), 2) margin_pct\n  from v_gross_profit\n"
         f" where period >= {pf} and period < {pt} and {org_where(250, 'organization_id')}\n group by product_name, unit_name",
         [("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."), num_col("QUANTITY", "Кількість", q3), num_col("REVENUE", "Виручка", q2),
          num_col("COST", "Собівартість", q2), num_col("GROSS_PROFIT", "Валовий прибуток", q2), num_col("MARGIN_PCT", "Рентабельність, %", q2)]),
        ("gross-docs", "Валовий прибуток за документами",
         "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.organization_name, m.customer_name, m.product_name, m.quantity, m.revenue, m.cost, m.gross_profit\n  from v_gross_profit m\n"
         f" where m.period >= {pf} and m.period < {pt} and {org_where(250)}",
         [dt, ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
          ("ORGANIZATION_NAME", "Організація"), ("CUSTOMER_NAME", "Покупець"), ("PRODUCT_NAME", "Товар"), num_col("QUANTITY", "Кількість", q3),
          num_col("REVENUE", "Виручка", q2), num_col("COST", "Собівартість", q2), num_col("GROSS_PROFIT", "Прибуток", q2)]),
        ("cost", "Вартість запасів",
         "select warehouse_name, product_code, product_name, unit_name, quantity, cost_amount, avg_cost\n  from v_stock_cost_balance",
         [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("UNIT_NAME", "Од."),
          num_col("QUANTITY", "Кількість", q3), num_col("COST_AMOUNT", "Вартість", q2), num_col("AVG_COST", "Середня собівартість", q2)]),
        ("recalc", "Потребує перерахунку",
         "select w.name warehouse_name, p.name product_name, r.from_date, r.marked_at\n  from reg_stock_cost_recalc r\n"
         "  join ref_warehouse w on w.id = r.warehouse_id\n  join ref_product p on p.id = r.product_id",
         [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_NAME", "Товар"),
          ("FROM_DATE", "Змінено з", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
          ("MARKED_AT", "Позначено", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")])],
        period=True, org=True,
        actions=[dict(ident="rebuild-cost", name="REBUILD_COST", label="Перерахувати собівартість", auth="role-admin",
                      plsql="trade_r3.rebuild_stock_cost;", confirm="Перерахувати собівартість за всіма документами?",
                      success="Собівартість перераховано."),
                 dict(ident="close-month", name="CLOSE_MONTH", label="Закрити місяць (знімки)", auth="role-admin",
                      plsql="trade_regs.close_month(add_months(to_date(:P250_TO, 'DD.MM.YYYY'), 0));",
                      confirm="Сформувати знімки залишків на кінець місяця кінцевої дати періоду?",
                      success="Знімки залишків сформовано.")])
    print_page()


# ===========================================================================
# r4 — F-NSI-09 «Організації» (паспорт RefOrganization)
# ===========================================================================
ORG_FIELD = dict(col="ORGANIZATION_ID", label="Організація", type="select", lov="organizations-active", required=True, span=6,
                 default="type: expression\nlanguage: plsql\nplsqlExpression: trade_org.default_org",
                 help="Від імені якої організації оформлено документ. Документ на підставі отримує організацію підстави.")


def r4_specs():
    CATALOGS.append(dict(list_page=330, form_page=331, alias="organizations", table="REF_ORGANIZATION",
         title="Організації", item_title="Організація",
         list_sql=("select id, code, name, case org_kind when 'INDIVIDUAL' then 'ФОП' else 'Юридична особа' end kind_name, edrpou, "
                   "case vat_payer when 'Y' then 'Так' else 'Ні' end vat_name, iban, "
                   "case is_default when 'Y' then 'Так' end default_name, " + STATE_SQL + " from ref_organization"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("KIND_NAME", "Вид"), ("EDRPOU", "ЄДРПОУ / ІПН"),
                  ("VAT_NAME", "Платник ПДВ"), ("IBAN", "IBAN"), ("DEFAULT_NAME", "За замовчуванням"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
                 dict(col="FULL_NAME", label="Повне найменування", type="text", max=500, span=12,
                      help="Для друкованих форм; порожнє — використовується найменування."),
                 dict(col="ORG_KIND", label="Вид", type="select", lov="org-kinds", required=True, span=6,
                      default="type: static\nstaticValue: LEGAL"),
                 dict(col="EDRPOU", label="ЄДРПОУ / РНОКПП", type="text", max=10, span=6, newcol=True,
                      help="Юридична особа — код ЄДРПОУ (8 цифр), ФОП — РНОКПП (10 цифр)."),
                 dict(col="VAT_PAYER", label="Платник ПДВ", type="switch", span=6),
                 dict(col="VAT_NUMBER", label="ІПН платника ПДВ", type="text", max=12, span=6, newcol=True,
                      help="12 цифр; обов'язковий для платника ПДВ."),
                 dict(col="IBAN", label="IBAN", type="text", max=40, span=6, help="UA + 27 цифр; пробіли прибираються."),
                 dict(col="BANK_NAME", label="Банк", type="text", max=255, span=6, newcol=True),
                 dict(col="ADDRESS", label="Адреса", type="text", max=500, span=8),
                 dict(col="PHONE", label="Телефон", type="text", max=50, span=4, newcol=True),
                 dict(col="DIRECTOR_NAME", label="Керівник", type="text", max=255, span=6),
                 dict(col="ACCOUNTANT_NAME", label="Головний бухгалтер", type="text", max=255, span=6, newcol=True),
                 dict(col="IS_DEFAULT", label="За замовчуванням", type="switch", span=6,
                      help="Підставляється в нові документи. Лише одна організація може бути за замовчуванням.")]))
    # Реквізит «Організація» в усіх документах, крім «Встановлення цін»
    for d in DOCUMENTS:
        if d["table"] == "DOC_PRICE_SETTING":
            continue
        d["fields"] = [ORG_FIELD] + d["fields"]
        assert d["list_sql"].startswith("select d.id,"), d["table"]
        d["list_sql"] = d["list_sql"].replace(
            "select d.id,", "select d.id, (select o.name from ref_organization o where o.id = d.organization_id) organization_name,", 1)
        d["list_cols"] = [("ORGANIZATION_NAME", "Організація")] + d["list_cols"]


def r4_lovs():
    sql_lov("organizations-active", "ORGANIZATIONS_ACTIVE",
            "select name d, id r\n  from ref_organization\n where state = 'ACTIVE'\n order by case is_default when 'Y' then 0 else 1 end, name")
    sql_lov("organizations-all", "ORGANIZATIONS_ALL", "select name d, id r\n  from ref_organization\n order by code")
    b = "name: ORG_KINDS\n" + block("source", "location: staticValues") + "\n"
    b += "\n" + comp("entry", "legal", "sequence: 1\ndisplay: Юридична особа\nreturn: LEGAL")
    b += "\n" + comp("entry", "individual", "sequence: 2\ndisplay: Фізична особа-підприємець\nreturn: INDIVIDUAL")
    write(SC / "lovs" / "org-kinds.apx", comp("lov", "org-kinds", b))


# ===========================================================================
# r4 — F-FIN-01 «Каси й банківські рахунки» (паспорти RefCashDesk, RefBankAccount)
# ===========================================================================
CURRENCIES = [("UAH", "UAH — гривня"), ("USD", "USD — долар США"), ("EUR", "EUR — євро"), ("PLN", "PLN — злотий")]


def r4_fin_specs():
    org = dict(ORG_FIELD, span=6, help="Організація — власник каси або рахунку.")
    cur = dict(col="CURRENCY_CODE", label="Валюта", type="select", lov="currencies", required=True, span=6, newcol=True,
               default="type: static\nstaticValue: UAH")
    CATALOGS.append(dict(list_page=340, form_page=341, alias="cash-desks", table="REF_CASH_DESK",
         title="Каси", item_title="Каса", edit_auth="role-cashier",
         list_sql="select id, code, name, organization_name, currency_code, responsible_name, state from v_cash_desk",
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("ORGANIZATION_NAME", "Організація"),
                  ("CURRENCY_CODE", "Валюта"), ("RESPONSIBLE_NAME", "Відповідальний (касир)")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
                 org, cur,
                 dict(col="RESPONSIBLE_NAME", label="Відповідальний (касир)", type="text", max=255, span=12,
                      help="ПІБ матеріально відповідальної особи — підпис у касових ордерах."),
                 dict(col="NOTE", label="Коментар", type="textarea", max=1000, span=12)]))
    CATALOGS.append(dict(list_page=350, form_page=351, alias="bank-accounts", table="REF_BANK_ACCOUNT",
         title="Банківські рахунки", item_title="Банківський рахунок", edit_auth="role-cashier",
         list_sql=("select id, code, name, organization_name, iban_display, mfo, bank_name, currency_code, "
                   "case is_default when 'Y' then 'Так' end default_name, state from v_bank_account"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("ORGANIZATION_NAME", "Організація"), ("IBAN_DISPLAY", "IBAN"),
                  ("MFO", "МФО"), ("BANK_NAME", "Банк"), ("CURRENCY_CODE", "Валюта"), ("DEFAULT_NAME", "Основний")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, span=9, newcol=True,
                      help="Порожнє — «Банк, валюта …4 останні цифри IBAN»."),
                 org, cur,
                 dict(col="IBAN", label="IBAN", type="text", max=40, required=True, span=8,
                      help="UA + 27 цифр; пробіли прибираються, контрольна сума перевіряється (ISO 13616, mod 97)."),
                 dict(col="MFO", label="МФО", type="text", max=6, span=4, newcol=True,
                      help="Код банку; порожнє — береться з IBAN (позиції 5–10)."),
                 dict(col="BANK_NAME", label="Банк", type="text", max=255, required=True, span=12),
                 dict(col="IS_DEFAULT", label="Основний рахунок організації", type="switch", span=6,
                      help="Один основний рахунок на організацію й валюту: нова ознака знімає попередню."),
                 dict(col="NOTE", label="Коментар", type="textarea", max=1000, span=12)]))


def r4_fin_lovs():
    b = "name: CURRENCIES\n" + block("source", "location: staticValues") + "\n"
    for i, (r, d) in enumerate(CURRENCIES):
        b += "\n" + comp("entry", r.lower(), f"sequence: {i + 1}\ndisplay: {d}\nreturn: {r}")
    write(SC / "lovs" / "currencies.apx", comp("lov", "currencies", b))


# ===========================================================================
# r4 — F-FIN-02 «Регістр грошових коштів» (паспорт RegCashBalance)
# ===========================================================================
def r4_cash_lovs():
    sql_lov("cash-places-active", "CASH_PLACES_ACTIVE",
            "select p.place_kind_name || ': ' || p.name || ' (' || p.currency_code || ', ' || o.name || ')' d, p.place_id r\n"
            "  from v_cash_place p join ref_organization o on o.id = p.organization_id\n"
            " where p.state = 'ACTIVE'\n order by o.name, p.place_kind, p.name")


def cash_opening_region(p):
    """Вкладка «Введення залишків»: початковий залишок каси / рахунку (до появи ПКО/ВКО — єдине джерело рухів)."""
    tb = "name: Введення залишків\ntitle: Введення залишків\ntype: staticContent\n"
    tb += block("layout", "sequence: 40\nslot: body") + "\n"
    tb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
    tb += block("advanced", "regionDisplaySelector: true")
    body = "\n" + comp("region", "opening", tb)
    b = "type: selectList\n"
    b += block("label", "label: Каса / рахунок\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @opening\nslot: regionBody\ncolumnSpan: 6") + "\n"
    b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @cash-places-active\ndisplayExtraValues: false\ndisplayNullValue: true") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: request")
    body += "\n" + comp("pageItem", f"P{p}_OB_PLACE", b)
    b = "type: datePicker\n"
    b += block("label", "label: Дата залишку\nalignment: right") + "\n"
    b += block("layout", "sequence: 20\nregion: @opening\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: request")
    body += "\n" + comp("pageItem", f"P{p}_OB_DATE", b)
    b = "type: numberField\n"
    b += block("label", "label: Сума\nalignment: right") + "\n"
    b += block("layout", "sequence: 30\nregion: @opening\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#\n") + "\n"
    b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
    b += block("help", "helpText: Залишок у валюті каси / рахунку на початок дати. Повторне введення замінює попереднє; 0 — видаляє введення. "
               "Зменшення залишку перевіряється: витрати після дати не можуть зробити залишок від'ємним.") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: request")
    body += "\n" + comp("pageItem", f"P{p}_OB_AMOUNT", b)
    body += "\n" + button("set-opening", "SET_OPENING", "Записати залишок", 40, "opening", slot="regionBody", hot=True,
                           auth="role-cashier")
    plsql = (f"declare\n  l_kind varchar2(12);\nbegin\n"
             f"  select max(place_kind) into l_kind from v_cash_place where place_id = :P{p}_OB_PLACE;\n"
             f"  trade_cash.set_opening_balance(l_kind, :P{p}_OB_PLACE, to_date(:P{p}_OB_DATE, 'DD.MM.YYYY'),\n"
             f"                                 to_number(replace(translate(:P{p}_OB_AMOUNT, 'x ' || unistr('\\00A0'), 'x'), ',', '.'), '999999999999990.99'));\nend;")
    body += "\n" + process("set-opening", "Записати початковий залишок", "executeCode", 10,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                            point="afterSubmit", when_button="set-opening", success="Початковий залишок записано.")
    body += "\n" + ir_region("opening-list", "Введені залишки",
        "select m.organization_name, m.place_kind_name, m.place_name, m.currency_code, m.period, m.amount\n"
        "  from v_cash_movement m\n where m.recorder_type = 'CashOpeningBalance' and " + org_where(p),
        [("ORGANIZATION_NAME", "Організація"), ("PLACE_KIND_NAME", "Вид"), ("PLACE_NAME", "Каса / рахунок"),
         ("CURRENCY_CODE", "Валюта"), ("PERIOD", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
         num_col("AMOUNT", "Сума", "FM999G999G999G990D00")],
        seq=50, parent="opening", template="@/blank-with-attributes")
    return body


def cash_register_page():
    q2 = "FM999G999G999G990D00"
    p = 360
    pf, pt = f"to_date(:P{p}_FROM, 'DD.MM.YYYY')", f"to_date(:P{p}_TO, 'DD.MM.YYYY') + 1"
    dt = ("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n")
    register_page(
        p, "cash-balance", "Залишки й обороти коштів",
        "select organization_name, place_kind_name, place_code, place_name, currency_code, balance, rate, rate_date, balance_uah\n"
        "  from v_cash_balance_uah\n where " + org_where(p, "organization_id"),
        [("ORGANIZATION_NAME", "Організація"), ("PLACE_KIND_NAME", "Вид"), ("PLACE_CODE", "Код"), ("PLACE_NAME", "Каса / рахунок"),
         ("CURRENCY_CODE", "Валюта"), num_col("BALANCE", "Залишок", q2), num_col("RATE", "Курс НБУ", "FM999G990D0000"),
         ("RATE_DATE", "Дата курсу", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
         num_col("BALANCE_UAH", "Еквівалент, грн", q2)],
        f"""select x.*, trade_currency.rate(x.currency_code, {pt} - 1) closing_rate,
       trade_currency.to_uah(x.closing, x.currency_code, {pt} - 1) closing_uah
  from (select m.organization_name, m.place_kind_name, m.place_name, m.currency_code,
       sum(case when m.period < {pf} then m.amount else 0 end) opening,
       sum(case when m.period >= {pf} and m.period < {pt} then m.incoming else 0 end) incoming,
       sum(case when m.period >= {pf} and m.period < {pt} then m.outgoing else 0 end) outgoing,
       sum(case when m.period < {pt} then m.amount else 0 end) closing
  from v_cash_movement m
 where {org_where(p)}
 group by m.organization_name, m.place_kind_name, m.place_name, m.currency_code) x""",
        [("ORGANIZATION_NAME", "Організація"), ("PLACE_KIND_NAME", "Вид"), ("PLACE_NAME", "Каса / рахунок"), ("CURRENCY_CODE", "Валюта"),
         num_col("OPENING", "Поч. залишок", q2), num_col("INCOMING", "Надходження", q2),
         num_col("OUTGOING", "Витрата", q2), num_col("CLOSING", "Кін. залишок", q2),
         num_col("CLOSING_RATE", "Курс на кінець", "FM999G990D0000"), num_col("CLOSING_UAH", "Кін. залишок, грн", q2)],
        "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.organization_name, m.place_kind_name, m.place_name, "
        "m.currency_code, m.incoming, m.outgoing, m.content\n  from v_cash_movement m\n where " + org_where(p),
        [dt, ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
         ("ORGANIZATION_NAME", "Організація"), ("PLACE_KIND_NAME", "Вид"), ("PLACE_NAME", "Каса / рахунок"), ("CURRENCY_CODE", "Валюта"),
         num_col("INCOMING", "Надходження", q2), num_col("OUTGOING", "Витрата", q2), ("CONTENT", "Зміст")],
        org=True, extra=cash_opening_region(p))


# ===========================================================================
# r4 — F-FIN-03 «ПКО / ВКО» (паспорти DocCashReceipt, DocCashPayment)
# ===========================================================================
CASH_RECEIPT_KINDS = [("CUSTOMER_PAYMENT", "Оплата від покупця"), ("SUPPLIER_REFUND", "Повернення коштів постачальником"),
                      ("ACCOUNTABLE_RETURN", "Повернення від підзвітної особи"), ("BANK_WITHDRAWAL", "Отримання готівки в банку"),
                      ("OTHER", "Інше надходження")]
CASH_PAYMENT_KINDS = [("SUPPLIER_PAYMENT", "Оплата постачальнику"), ("CUSTOMER_REFUND", "Повернення коштів покупцю"),
                      ("ACCOUNTABLE_ISSUE", "Видача підзвітній особі"), ("ENCASHMENT", "Інкасація (здача готівки в банк)"),
                      ("OTHER", "Інша видача")]


def toggle_da(p, js, item="OPERATION_KIND"):
    """Показ/приховування полів шапки залежно від виду операції (на зміну й при завантаженні)."""
    da = "name: Вид операції\n" + block("when", f"event: change\nselectionType: items\nitems: P{p}_{item}") + "\n"
    da += block("execution", "sequence: 30") + "\n\n"
    da += comp("action", "toggle", "name: Поля за видом операції\naction: executeJsCode\n"
               + block("settings", "jsCode:" + code("javascript", js.replace("#P#", f"P{p}"))) + "\n"
               + block("execution", "sequence: 10\nfireOnInit: true"))
    return comp("dynamicAction", "operation-kind", da)


def cash_toggle_js(cp_ops, bank_ops, acc_ops):
    return ("var op = $v('#P#_OPERATION_KIND');\n"
            "function sh(i, on) { var it = apex.item(i); if (on) { it.show(); } else { it.hide(); } }\n"
            f"var cp = {cp_ops!r}.indexOf(op) >= 0;\n".replace("'", '"')
            + f"sh('#P#_COUNTERPARTY_ID', cp || op === 'OTHER');\nsh('#P#_CONTRACT_ID', cp);\n"
            + f"sh('#P#_ACCOUNTABLE_PERSON', {acc_ops!r}.indexOf(op) >= 0);\n".replace("'", '"').replace('"#P#_ACCOUNTABLE_PERSON"', "'#P#_ACCOUNTABLE_PERSON'")
            + f"sh('#P#_BANK_ACCOUNT_ID', {bank_ops!r}.indexOf(op) >= 0);\n".replace("'", '"').replace('"#P#_BANK_ACCOUNT_ID"', "'#P#_BANK_ACCOUNT_ID'"))


def r4_cash_doc_specs():
    desk_lov = ("select name || ' (' || currency_code || ')' d, id r\n  from ref_cash_desk\n"
                " where state = 'ACTIVE' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by code")
    bank_lov = ("select name d, id r\n  from ref_bank_account\n"
                " where state = 'ACTIVE' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by name")
    contract_lov = ("select c.name || case when c.contract_number is not null then ' № ' || c.contract_number end d, c.id r\n"
                    "  from ref_contract c\n where c.state = 'ACTIVE' and c.owner_id = :P#PAGE#_COUNTERPARTY_ID\n order by c.name")

    def spec(page, list_page, alias, list_alias, table, title, list_title, kinds_lov, def_op, person_label, prefix, cp_ops, bank_ops, acc_ops):
        kind = "DocCashReceipt" if prefix == "receipt" else "DocCashPayment"
        return dict(page=page, list_page=list_page, alias=alias, list_alias=list_alias, table=table,
             title=title, list_title=list_title,
             list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.operation_name, d.cash_desk_name, "
                       "d.counterparty_name, d.person_name, d.amount, d.currency_code, " + STATUS_SQL + ", d.doc_comment\n"
                       f"  from v_cash_order_list d\n where d.doc_type = '{kind}'"),
             list_cols=[("ORGANIZATION_NAME", "Організація"), ("OPERATION_NAME", "Вид операції"), ("CASH_DESK_NAME", "Каса"),
                        ("COUNTERPARTY_NAME", "Контрагент"), ("PERSON_NAME", person_label), money_col("AMOUNT", "Сума"),
                        ("CURRENCY_CODE", "Валюта")],
             fields=[dict(ORG_FIELD, help="Організація — власник каси. Документ на підставі отримує організацію підстави."),
                     dict(col="OPERATION_KIND", label="Вид операції", type="select", lov=kinds_lov, required=True, span=6, newcol=True,
                          default=f"type: static\nstaticValue: {def_op}"),
                     dict(col="CASH_DESK_ID", label="Каса", type="ref", required=True, span=6, cascade="ORGANIZATION_ID", lov_sql=desk_lov,
                          default="type: expression\nlanguage: plsql\nplsqlExpression: trade_cash_doc.default_cash_desk(trade_org.default_org)"),
                     dict(col="CURRENCY_CODE", label="Валюта", type="display", span=2),
                     dict(col="AMOUNT", label="Сума", type="number", dtype="number", format=Q2, required=True, span=4),
                     dict(col="COUNTERPARTY_ID", label="Контрагент", type="ref", lov="COUNTERPARTIES_ACTIVE", span=6, required=False,
                          help="Обов'язковий для операцій з покупцем / постачальником: ордер змінює взаєморозрахунки."),
                     dict(col="CONTRACT_ID", label="Договір", type="ref", span=6, required=False, cascade="COUNTERPARTY_ID",
                          lov_sql=contract_lov, help="Якщо в контрагента один договір потрібного виду — підставляється автоматично."),
                     dict(col="ACCOUNTABLE_PERSON", label="Підзвітна особа", type="text", max=255, span=6,
                          help="ПІБ працівника, якому видано / від якого повернено підзвітні кошти."),
                     dict(col="BANK_ACCOUNT_ID", label="Банківський рахунок", type="ref", span=6, required=False,
                          cascade="ORGANIZATION_ID", lov_sql=bank_lov,
                          help="Рахунок організації у валюті каси: інкасація зараховує на нього готівку, отримання в банку — списує."),
                     dict(col="PERSON_NAME", label=person_label, type="text", max=255, span=6,
                          help="Для друкованої форми; порожнє — контрагент / підзвітна особа / банк."),
                     dict(col="BASIS", label="Підстава", type="text", max=500, span=6,
                          help="Для друкованої форми; порожнє — вид операції й документ-підстава."),
                     dict(col="APPENDIX", label="Додаток", type="text", max=500, span=6),
                     base_field("BASE_DOC_ID", "Документ-підстава"),
                     dict(col="BASE_DOC_TYPE", type="hidden")],
             toggle_js=cash_toggle_js(cp_ops, bank_ops, acc_ops),
             post=f"trade_cash_doc.post_{prefix}", unpost=f"trade_cash_doc.unpost_{prefix}", copy=f"trade_cash_doc.copy_{prefix}")

    DOCUMENTS.extend([
        spec(371, 370, "cash-receipt", "cash-receipts", "DOC_CASH_RECEIPT", "Прибутковий касовий ордер", "Прибуткові касові ордери",
             "cash-receipt-kinds", "CUSTOMER_PAYMENT", "Прийнято від", "receipt",
             ["CUSTOMER_PAYMENT", "SUPPLIER_REFUND"], ["BANK_WITHDRAWAL"], ["ACCOUNTABLE_RETURN"]),
        spec(381, 380, "cash-payment", "cash-payments", "DOC_CASH_PAYMENT", "Видатковий касовий ордер", "Видаткові касові ордери",
             "cash-payment-kinds", "SUPPLIER_PAYMENT", "Видати", "payment",
             ["SUPPLIER_PAYMENT", "CUSTOMER_REFUND"], ["ENCASHMENT"], ["ACCOUNTABLE_ISSUE"]),
    ])
    # Введення на підставі: команди в документах-підставах (лише для ролі «Касир» / адміністратора)
    by_page = {d["page"]: d for d in DOCUMENTS}
    based = {111: ("CREATE_CASH_RECEIPT", "Створити ПКО", "trade_cash_doc.receipt_from_sale(#ID#)", "posted", 371),
             321: ("CREATE_CASH_RECEIPT", "Створити ПКО", "trade_cash_doc.receipt_from_invoice(#ID#)", "posted", 371),
             291: ("CREATE_CASH_RECEIPT", "Створити ПКО (повернення коштів)", "trade_cash_doc.receipt_from_supplier_return(#ID#)", "exists", 371),
             51: ("CREATE_CASH_PAYMENT", "Створити ВКО", "trade_cash_doc.payment_from_goods_receipt(#ID#)", "posted", 381),
             281: ("CREATE_CASH_PAYMENT", "Створити ВКО (повернення коштів)", "trade_cash_doc.payment_from_customer_return(#ID#)", "exists", 381)}
    for pg, (name, label, plsql, when, target) in based.items():
        d = by_page[pg]
        d.setdefault("commands", [])
        d["commands"] = [c for c in d["commands"] if c["name"] != name] + [cmd(name, label, plsql, when, target=target, auth="role-cashier")]


def r4_cash_doc_lovs():
    for ident, name, entries in [("cash-receipt-kinds", "CASH_RECEIPT_KINDS", CASH_RECEIPT_KINDS),
                                 ("cash-payment-kinds", "CASH_PAYMENT_KINDS", CASH_PAYMENT_KINDS)]:
        b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
        for i, (ret, disp) in enumerate(entries):
            b += "\n" + comp("entry", ret.lower().replace("_", "-"), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
        write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))
    sql_lov("cash-desks-active", "CASH_DESKS_ACTIVE",
            "select k.name || ' (' || k.currency_code || ', ' || o.name || ')' d, k.id r\n"
            "  from ref_cash_desk k join ref_organization o on o.id = k.organization_id\n"
            " where k.state = 'ACTIVE'\n order by o.name, k.code")


def cash_book_page():
    """Касова книга (КО-4): вкладні аркуші за касою й період, друк."""
    p = 390
    body = page_header(p, "Касова книга", "cash-book", "Касова книга")
    body += "\n" + title_region("Касова книга")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)
    b = "type: selectList\n" + block("label", "label: Каса\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 5") + "\n"
    b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @cash-desks-active\ndisplayExtraValues: false\ndisplayNullValue: true") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: trade_cash_doc.default_cash_desk(trade_org.default_org)") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DESK", b)
    for i, (it, lbl) in enumerate([("FROM", "З"), ("TO", "По")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {20 + i * 10}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(sysdate, 'DD.MM.YYYY')") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Касова книга\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_cash_doc.cash_book_html(:P{p}_DESK, coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate)),\n"
        f"                                     coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "book", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-cash-book.apx", comp("page", str(p), body))


def product_card_page():
    """F-REP-08 «Картка товару»: товар / склад (або всі) / період; рухи з реєстраторами, друк."""
    p = 450
    body = page_header(p, "Картка товару", "product-card", "Картка товару")
    body += "\n" + title_region("Картка товару")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)
    b = "type: popupLov\n" + block("label", "label: Товар\nalignment: right") + "\n"
    b += block("layout", f"sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 4") + "\n"
    b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @products-goods\ndisplayExtraValues: true\ndisplayNullValue: true") + "\n"
    b += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_PRODUCT", b)
    b = "type: selectList\n" + block("label", "label: Склад\nalignment: right") + "\n"
    b += block("layout", f"sequence: 15\nregion: @bar\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @warehouses-all\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: Усі склади") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_WH", b)
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {20 + i * 10}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Картка товару\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_product_card.card_html(:P{p}_PRODUCT, :P{p}_WH,\n"
        f"         coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'MM')),\n"
        f"         coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "card", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-product-card.apx", comp("page", str(p), body))


# ===========================================================================
# r4 — F-REP-09 «ABC-аналіз продажів» (RegSales + RegStockCost, trade_abc)
# ===========================================================================
def abc_lovs():
    for ident, name, entries in [("abc-dimensions", "ABC_DIMENSIONS", [("product", "Товари", "PRODUCT"), ("customer", "Клієнти", "CUSTOMER")]),
                                 ("abc-measures", "ABC_MEASURES", [("revenue", "Виручка", "REVENUE"), ("qty", "Кількість", "QTY"),
                                                                   ("profit", "Валовий прибуток", "PROFIT")])]:
        b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
        for i, (eid, disp, ret) in enumerate(entries):
            b += "\n" + comp("entry", eid, f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
        write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))


def abc_page():
    """F-REP-09: розріз (товари / клієнти), показник, період, організація, група номенклатури, межі A/B; Парето, друк."""
    p = 460
    body = page_header(p, "ABC-аналіз продажів", "abc-analysis", "ABC-аналіз продажів")
    body += "\n" + title_region("ABC-аналіз продажів")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)

    def sel(it, lbl, lov, seq, span, new_row, dflt=None, null_disp=None):
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}" + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", f"template: @/{'optional' if null_disp else 'required'}\ntemplateOptions: #DEFAULT#") + "\n"
        if dflt:
            b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        lv = f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\n"
        lv += f"displayNullValue: true\nnullDisplayValue: {null_disp}" if null_disp else "displayNullValue: false"
        b += block("lov", lv) + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        return "\n" + comp("pageItem", f"P{p}_{it}", b)

    body += sel("DIM", "Розріз", "abc-dimensions", 10, 2, True, "PRODUCT")
    body += sel("MEASURE", "Показник", "abc-measures", 12, 3, False, "REVENUE")
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {14 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + org_filter_item(p, "bar", 20, span=3, new_row=True)
    body += sel("GROUP", "Група номенклатури", "product-groups-active", 22, 4, False, null_disp="Усі групи")
    for i, (it, lbl, dflt) in enumerate([("A", "Межа A, %", "80"), ("B", "Межа B, %", "15")]):
        b = "type: numberField\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {24 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 1\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
        b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
        if it == "B":
            b += block("help", "helpText: Межі класів — частка показника наростаючим підсумком: A — до межі A, B — наступні до A + B, C — решта. "
                       "Позиція, що перетинає межу, належить вищому класу; позиції з показником ≤ 0 — клас C.") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: ABC-аналіз\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_abc.abc_html(coalesce(:P{p}_DIM, 'PRODUCT'), coalesce(:P{p}_MEASURE, 'REVENUE'),\n"
        f"         coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'MM')),\n"
        f"         coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)),\n"
        f"         :P{p}_ORG, :P{p}_GROUP, trade_abc.to_num(:P{p}_A, 80), trade_abc.to_num(:P{p}_B, 15));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "abc", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-abc-analysis.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-WH-24 «Оборотність запасів» (RegStockCost + RegSales, trade_turnover)
# ===========================================================================
def turnover_lovs():
    entries = [("product", "Товари", "PRODUCT"), ("group", "Групи номенклатури", "GROUP"),
               ("warehouse", "Склади", "WAREHOUSE"), ("product-warehouse", "Товари за складами", "PRODUCT_WAREHOUSE")]
    b = "name: TURNOVER_DIMENSIONS\n" + block("source", "location: staticValues") + "\n"
    for i, (eid, disp, ret) in enumerate(entries):
        b += "\n" + comp("entry", eid, f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / "turnover-dimensions.apx", comp("lov", "turnover-dimensions", b))


def turnover_page():
    """F-WH-24: розріз (товари / групи / склади / товари × склади), період, організація, склад, група; друк."""
    p = 680
    body = page_header(p, "Оборотність запасів", "inventory-turnover", "Оборотність запасів")
    body += "\n" + title_region("Оборотність запасів")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)

    def sel(it, lbl, lov, seq, span, new_row, dflt=None, null_disp=None):
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}" + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", f"template: @/{'optional' if null_disp else 'required'}\ntemplateOptions: #DEFAULT#") + "\n"
        if dflt:
            b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        lv = f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\n"
        lv += f"displayNullValue: true\nnullDisplayValue: {null_disp}" if null_disp else "displayNullValue: false"
        b += block("lov", lv) + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        return "\n" + comp("pageItem", f"P{p}_{it}", b)

    body += sel("DIM", "Розріз", "turnover-dimensions", 10, 3, True, "PRODUCT")
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {14 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + org_filter_item(p, "bar", 20, span=3, new_row=True)
    body += sel("WH", "Склад", "warehouses-all", 22, 3, False, null_disp="Усі склади")
    body += sel("GROUP", "Група номенклатури", "product-groups-active", 24, 4, False, null_disp="Усі групи")
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Оборотність запасів\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_turnover.turnover_html(coalesce(:P{p}_DIM, 'PRODUCT'),\n"
        f"         coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'MM')),\n"
        f"         coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)),\n"
        f"         :P{p}_ORG, :P{p}_WH, :P{p}_GROUP);")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "turnover", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-inventory-turnover.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-WH-25 «Неліквіди й залежалі товари» (trade_slow_stock, RegMarkdownRule)
# ===========================================================================
MARKDOWN_ACTIONS = [("MARKDOWN", "Уцінити"), ("CLEARANCE", "Розпродати"), ("WRITE_OFF", "Списати")]


def slow_stock_lovs():
    static_lov("slow-stock-basis", "SLOW_STOCK_BASIS", [("SALE", "Без продажу"), ("MOVE", "Без руху")])
    static_lov("slow-stock-scope", "SLOW_STOCK_SCOPE", [("Y", "Лише залежалі й з терміном, що минає"), ("N", "Усі залишки")])
    static_lov("markdown-actions", "MARKDOWN_ACTIONS", MARKDOWN_ACTIONS)


def markdown_rules_page():
    editable_register_page(695, "markdown-rules", "Правила уцінки неліквідів", "REG_MARKDOWN_RULE", [
        dict(col="IDLE_DAYS_FROM", heading="Без продажу / руху від, днів", kind="number", dtype="number", required=True, width=180),
        dict(col="MARKDOWN_PERCENT", heading="Уцінка, %", kind="number", dtype="number", mask=PCT, required=True, width=120),
        dict(col="ACTION", heading="Дія", kind="select", lov="markdown-actions", required=True, width=160),
        dict(col="NOTE", heading="Примітка", kind="text", width=320),
        dict(col="UPDATED_BY", heading="Змінив", kind="display", width=140),
    ], "idle_days_from")


def slow_stock_page():
    """F-WH-25: дата, поріг днів, ознака (без продажу / руху), організація, склад, група, вид цін, обсяг; друк; уцінка."""
    p = 690
    body = page_header(p, "Неліквіди й залежалі товари", "slow-moving-stock", "Неліквіди й залежалі товари")
    body += "\n" + title_region("Неліквіди й залежалі товари")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)

    def sel(it, lbl, lov, seq, span, new_row, dflt=None, null_disp=None, dflt_expr=None):
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}" + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", f"template: @/{'optional' if null_disp else 'required'}\ntemplateOptions: #DEFAULT#") + "\n"
        if dflt:
            b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        if dflt_expr:
            b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt_expr}") + "\n"
        lv = f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\n"
        lv += f"displayNullValue: true\nnullDisplayValue: {null_disp}" if null_disp else "displayNullValue: false"
        b += block("lov", lv) + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        return "\n" + comp("pageItem", f"P{p}_{it}", b)

    b = "type: datePicker\n" + block("label", "label: На дату\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 3") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(sysdate, 'DD.MM.YYYY')") + "\n"
    b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DATE", b)
    b = "type: numberField\n" + block("label", "label: Днів\nalignment: right") + "\n"
    b += block("layout", "sequence: 12\nregion: @bar\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(trade_slow_stock.default_days)") + "\n"
    b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
    b += block("help", "helpText: Товар залежалий, якщо без продажу (або без руху) не менше вказаної кількості днів. "
               "Порожньо — найменший поріг правил уцінки.") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DAYS", b)
    body += sel("BASIS", "Ознака", "slow-stock-basis", 14, 3, False, "SALE")
    body += sel("SCOPE", "Показати", "slow-stock-scope", 16, 3, False, "Y")
    body += "\n" + org_filter_item(p, "bar", 20, span=3, new_row=True)
    body += sel("WH", "Склад", "warehouses-all", 22, 3, False, null_disp="Усі склади")
    body += sel("GROUP", "Група номенклатури", "product-groups-active", 24, 3, False, null_disp="Усі групи")
    body += sel("PRICE_TYPE", "Вид цін", "price-types-active", 26, 3, False, dflt_expr="trade_slow_stock.default_price_type")
    for i, nm in enumerate(["NEW_ID"]):
        nb = "type: hidden\n" + block("layout", f"sequence: {30 + i}\nregion: @bar\nslot: regionBody") + "\n"
        nb += block("sessionState", "dataType: varchar2\nstorage: request")
        body += "\n" + comp("pageItem", f"P{p}_{nm}", nb)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    body += "\n" + button("markdown", "CREATE_MARKDOWN", "Створити документ уцінки", 60, "bar", slot="regionBody", auth="role-admin",
                          confirm="Створити документ «Встановлення цін» (чернетку) з рекомендованими цінами уцінки?")
    args = (f"coalesce(to_date(:P{p}_DATE, 'DD.MM.YYYY'), trunc(sysdate)),\n"
            f"         trade_slow_stock.to_days(:P{p}_DAYS),\n"
            f"         coalesce(:P{p}_BASIS, 'SALE'), :P{p}_ORG, :P{p}_WH, :P{p}_GROUP, :P{p}_PRICE_TYPE")
    body += "\n" + process("create-markdown", "Створити документ уцінки", "executeCode", 10,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql",
                               f":P{p}_NEW_ID := trade_slow_stock.create_price_setting({args});")) + "\n",
                           point="afterSubmit", when_button="markdown", success="Створено документ «Встановлення цін» (чернетка).")
    bb = "name: До документа уцінки\n"
    bb += block("behavior", f"type: pageOrUrl\ntarget: {{\n    page: 101\n    clearCache: 101\n    items: {{\n        P101_ID: &P{p}_NEW_ID.\n    }}\n}}") + "\n"
    bb += block("execution", "sequence: 5\npoint: afterProcessing") + "\n"
    bb += block("serverSideCondition", f"type: expression\nlanguage: plsql\nplsqlExpression: :REQUEST = 'CREATE_MARKDOWN' and :P{p}_NEW_ID is not null") + "\n"
    body += "\n" + comp("branch", "to-price-setting", bb)
    body += "\n" + branch("stay", "Залишитися", 20, f"{{\n    page: {p}\n}}")
    pb = "name: Неліквіди й залежалі товари\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_slow_stock.slow_html({args},\n         coalesce(:P{p}_SCOPE, 'Y'));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "slow", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-slow-moving-stock.apx", comp("page", str(p), body))


# ===========================================================================
# r4 — F-REP-10 «Дебіторка за термінами» (RegCounterpartySettlement + RefContract, trade_ar_aging)
# ===========================================================================
def aging_lovs():
    for ident, name, entries in [("aging-detail", "AGING_DETAIL", [("contract", "Контрагенти й договори", "CONTRACT"),
                                                                    ("document", "З документами боргу", "DOCUMENT")]),
                                 ("aging-filter", "AGING_FILTER", [("all", "Уся заборгованість", "N"),
                                                                   ("overdue", "Лише прострочена", "Y")])]:
        b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
        for i, (eid, disp, ret) in enumerate(entries):
            b += "\n" + comp("entry", eid, f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
        write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))


def aging_page():
    """F-REP-10: дебіторка за строками погашення на дату — організація, контрагент, деталізація, лише прострочена; друк."""
    p = 470
    body = page_header(p, "Дебіторка за термінами", "receivables-aging", "Дебіторка за термінами")
    body += "\n" + title_region("Дебіторська заборгованість за термінами")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)
    b = "type: datePicker\n" + block("label", "label: На дату\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 2") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(sysdate, 'DD.MM.YYYY')") + "\n"
    b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DATE", b)
    body += "\n" + org_filter_item(p, "bar", 12, span=3)
    b = "type: popupLov\n" + block("label", "label: Контрагент\nalignment: right") + "\n"
    b += block("layout", "sequence: 14\nregion: @bar\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @counterparties-all\ndisplayExtraValues: false\ndisplayNullValue: true") + "\n"
    b += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_CP", b)
    for it, lbl, lov, seq, span, dflt in [("DETAIL", "Деталізація", "aging-detail", 16, 2, "CONTRACT"),
                                          ("OVERDUE", "Борг", "aging-filter", 18, 2, "N")]:
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
        b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        b += block("lov", f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\ndisplayNullValue: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Дебіторка за термінами\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_ar_aging.aging_html(coalesce(to_date(:P{p}_DATE, 'DD.MM.YYYY'), trunc(sysdate)),\n"
        f"         :P{p}_ORG, :P{p}_CP, coalesce(:P{p}_DETAIL, 'CONTRACT'), coalesce(:P{p}_OVERDUE, 'N'));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "aging", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-receivables-aging.apx", comp("page", str(p), body))

# ===========================================================================
# r4 — F-FIN-04 «Банківські виписки» (паспорт DocBankStatement)
# ===========================================================================
BANK_OPERATION_KINDS = [("CUSTOMER_PAYMENT", "Надходження: оплата від покупця"),
                        ("SUPPLIER_REFUND", "Надходження: повернення коштів постачальником"),
                        ("CASH_DEPOSIT", "Надходження: внесення готівки (інкасація)"),
                        ("OTHER_IN", "Надходження: інше"),
                        ("SUPPLIER_PAYMENT", "Списання: оплата постачальнику"),
                        ("CUSTOMER_REFUND", "Списання: повернення коштів покупцю"),
                        ("CASH_WITHDRAWAL", "Списання: зняття готівки в касу"),
                        ("BANK_FEE", "Списання: банківська комісія"),
                        ("OTHER_OUT", "Списання: інше")]
BANK_SOURCE_FORMATS = [("MANUAL", "Введено вручну"), ("CSV", "Імпорт CSV"), ("1C_CLIENT_BANK", "Імпорт 1CClientBankExchange")]


def r4_bank_specs():
    # Реквізити контрагента для автопошуку у виписках
    for c in CATALOGS:
        if c["table"] == "REF_COUNTERPARTY":
            c["list_sql"] = "select id, code, name, edrpou, iban, " + STATE_SQL + " from ref_counterparty"
            c["columns"] = [("CODE", "Код"), ("NAME", "Найменування"), ("EDRPOU", "ЄДРПОУ / РНОКПП"), ("IBAN", "IBAN"), ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="EDRPOU", label="ЄДРПОУ / РНОКПП", type="text", max=10, span=4,
                     help="Код ЄДРПОУ (8 цифр) або РНОКПП (10 цифр). За ним банківська виписка знаходить контрагента."),
                dict(col="IBAN", label="IBAN", type="text", max=40, span=8, newcol=True,
                     help="Основний рахунок контрагента (UA + 27 цифр, контрольна сума). Використовується для автопошуку у виписках.")]
    bank_lov = ("select name || ' (' || currency_code || ')' d, id r\n  from ref_bank_account\n"
                " where state = 'ACTIVE' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by case is_default when 'Y' then 0 else 1 end, name")
    DOCUMENTS.append(dict(page=401, list_page=400, alias="bank-statement", list_alias="bank-statements", table="DOC_BANK_STATEMENT",
         title="Банківська виписка", list_title="Банківські виписки",
         list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.bank_account_name, d.total_in, d.total_out, "
                   "d.currency_code, d.line_count, d.unmatched_count, " + STATUS_SQL + ", d.doc_comment\n  from v_bank_statement_list d"),
         list_cols=[("ORGANIZATION_NAME", "Організація"), ("BANK_ACCOUNT_NAME", "Банківський рахунок"),
                    money_col("TOTAL_IN", "Надходження"), money_col("TOTAL_OUT", "Списання"), ("CURRENCY_CODE", "Валюта"),
                    ("LINE_COUNT", "Операцій", "number"), ("UNMATCHED_COUNT", "Без контрагента", "number")],
         fields=[dict(ORG_FIELD, help="Організація — власник рахунку."),
                 dict(col="BANK_ACCOUNT_ID", label="Банківський рахунок", type="ref", required=True, span=6, newcol=True,
                      cascade="ORGANIZATION_ID", lov_sql=bank_lov,
                      default="type: expression\nlanguage: plsql\nplsqlExpression: trade_fin.default_bank_account(trade_org.default_org)",
                      help="Рахунок організації, за яким отримано виписку. Рухи коштів — на дату виписки."),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=2),
                 dict(col="TOTAL_IN", label="Надходження", type="display", dtype="number", format=Q2, span=3),
                 dict(col="TOTAL_OUT", label="Списання", type="display", dtype="number", format=Q2, span=3),
                 dict(col="SOURCE_FORMAT", label="Джерело", type="display", lov="bank-source-formats", span=4),
                 dict(col="SOURCE_NAME", label="Файл", type="display", span=6)],
         lines=dict(table="DOC_BANK_STATEMENT_LINE", title="Операції", cols=[
             dict(col="OPERATION_KIND", heading="Вид операції", kind="select", lov="bank-operation-kinds", required=True, width=260),
             dict(col="AMOUNT", heading="Сума", kind="number", dtype="number", mask=Q2, required=True, width=120),
             dict(col="COUNTERPARTY_ID", heading="Контрагент", kind="ref", lov="counterparties-active", width=220,
                  help="Порожній — знаходиться автоматично за ЄДРПОУ / IBAN з виписки (команда «Заповнити контрагентів» шукає й за попередніми виписками)."),
             dict(col="CONTRACT_ID", heading="Договір", kind="ref", lov="contracts-active", width=200,
                  help="Порожній — договір контрагента за замовчуванням (якщо один)."),
             dict(col="PURPOSE", heading="Призначення платежу", kind="text", max=500, width=300),
             dict(col="CP_NAME", heading="Платник / одержувач (з виписки)", kind="text", max=255, width=200),
             dict(col="CP_EDRPOU", heading="ЄДРПОУ", kind="text", max=10, width=100),
             dict(col="CP_IBAN", heading="IBAN контрагента", kind="text", max=34, width=240),
             dict(col="EXT_DOC_NUMBER", heading="№ платіжки", kind="text", max=30, width=100),
             dict(col="CASH_ORDER_ID", heading="Касовий ордер", kind="ref", lov="bank-cash-orders", width=240,
                  help="Для внесення / зняття готівки: ВКО «Інкасація» або ПКО «Отримання готівки в банку». Ордер уже рухає рахунок — виписка суму не проводить повторно."),
             dict(col="PAYMENT_DOC_ID", heading="Документ оплати", kind="ref", lov="bank-payment-docs", width=240,
                  help="Безготівкова оплата постачальнику / від покупця, яку відображає рядок. Рух рахунку й погашення боргу вже записала оплата — "
                       "виписка рядок лише звіряє. Під час проведення підбирається автоматично (рахунок, контрагент, сума, ±3 дні)."),
             dict(col="MATCHED_NAME", heading="Знайдено за", kind="display", width=110,
                  sql="case matched_by when 'EDRPOU' then 'ЄДРПОУ' when 'IBAN' then 'IBAN' when 'HISTORY' then 'Історія' end")]),
         commands=[cmd("FILL_COUNTERPARTIES", "Заповнити контрагентів",
                       "declare n number; begin n := trade_bank_doc.fill_counterparties(#ID#); end;", "draft",
                       success="Контрагентів знайдено за ЄДРПОУ / IBAN (рядки без контрагента)."),
                   cmd("LINK_CASH_ORDERS", "Підібрати касові ордери",
                       "declare n number; begin n := trade_bank_doc.link_cash_orders(#ID#); end;", "draft",
                       success="Рядки внесення / зняття готівки зіставлено з проведеними касовими ордерами."),
                   cmd("LINK_PAYMENTS", "Підібрати оплати",
                       "declare n number; begin n := trade_bank_doc.link_payments(#ID#); end;", "draft",
                       success="Рядки оплат зіставлено з проведеними безготівковими документами оплати.")],
         post="trade_bank_doc.post", unpost="trade_bank_doc.unpost", copy="trade_bank_doc.copy"))


def r4_bank_lovs():
    for ident, name, entries in [("bank-operation-kinds", "BANK_OPERATION_KINDS", BANK_OPERATION_KINDS),
                                 ("bank-source-formats", "BANK_SOURCE_FORMATS", BANK_SOURCE_FORMATS)]:
        b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
        for i, (ret, disp) in enumerate(entries):
            b += "\n" + comp("entry", ret.lower().replace("_", "-"), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
        write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))
    sql_lov("contracts-active", "CONTRACTS_ACTIVE",
            "select o.name || ': ' || c.name || case when c.contract_number is not null then ' № ' || c.contract_number end d, c.id r\n"
            "  from ref_contract c join ref_counterparty o on o.id = c.owner_id\n where c.state = 'ACTIVE'\n order by 1")
    sql_lov("bank-payment-docs", "BANK_PAYMENT_DOCS",
            "select case v.doc_type when 'DocSupplierPayment' then 'Оплата постачальнику' else 'Оплата від покупця' end\n"
            "       || ' № ' || v.doc_number || ' від ' || to_char(v.occurred_at, 'DD.MM.YYYY') || ' — ' || c.name || ', '\n"
            "       || to_char(v.amount, 'FM999G999G999G990D00') || ' ' || v.currency_code\n"
            "       || case when v.status <> 'POSTED' then ' (не проведено)' end d, v.id r\n"
            "  from v_payment_doc v join ref_counterparty c on c.id = v.counterparty_id\n"
            " where v.payment_form = 'BANK'\n order by v.occurred_at desc")
    sql_lov("bank-cash-orders", "BANK_CASH_ORDERS",
            "select short_name || ' № ' || doc_number || ' від ' || to_char(occurred_at, 'DD.MM.YYYY') || ' — '\n"
            "       || to_char(amount, 'FM999G999G999G990D00') || ' ' || currency_code\n"
            "       || case when status <> 'POSTED' then ' (не проведено)' end d, id r\n"
            "  from v_cash_order\n where operation_kind in ('ENCASHMENT', 'BANK_WITHDRAWAL')\n order by occurred_at desc")


# ===========================================================================
# r4 — F-FIN-05 «Коригування боргу / взаємозалік» (паспорт DocDebtAdjustment), акт звірки
# ===========================================================================
DEBT_OPERATION_KINDS = [("OFFSET", "Взаємозалік заборгованостей"),
                        ("WRITE_OFF_RECEIVABLE", "Списання дебіторської заборгованості"),
                        ("WRITE_OFF_PAYABLE", "Списання кредиторської заборгованості"),
                        ("TRANSFER_RECEIVABLE", "Перенесення дебіторської заборгованості"),
                        ("TRANSFER_PAYABLE", "Перенесення кредиторської заборгованості")]


def r4_debt_specs():
    contract_lov = ("select c.name || case when c.contract_number is not null then ' № ' || c.contract_number end\n"
                    "       || case c.contract_kind when 'WITH_CUSTOMER' then ' (з покупцем)' else ' (з постачальником)' end d, c.id r\n"
                    "  from ref_contract c\n where c.state = 'ACTIVE' and c.owner_id = :P#PAGE#_COUNTERPARTY_ID\n order by c.name")
    target_lov = ("select c.name || case when c.contract_number is not null then ' № ' || c.contract_number end\n"
                  "       || case c.contract_kind when 'WITH_CUSTOMER' then ' (з покупцем)' else ' (з постачальником)' end d, c.id r\n"
                  "  from ref_contract c\n where c.state = 'ACTIVE'\n"
                  "   and c.owner_id = coalesce(:P#PAGE#_TARGET_COUNTERPARTY_ID, :P#PAGE#_COUNTERPARTY_ID)\n order by c.name")
    js = ("var op = $v('#P#_OPERATION_KIND');\n"
          "function sh(i, on) { var it = apex.item(i); if (on) { it.show(); } else { it.hide(); } }\n"
          "sh('#P#_TARGET_COUNTERPARTY_ID', op.indexOf('TRANSFER') === 0);\n"
          "sh('#P#_TARGET_CONTRACT_ID', op === 'OFFSET' || op.indexOf('TRANSFER') === 0);\n")
    DOCUMENTS.append(dict(page=411, list_page=410, alias="debt-adjustment", list_alias="debt-adjustments", table="DOC_DEBT_ADJUSTMENT",
         title="Коригування боргу", list_title="Коригування боргу",
         list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.operation_name, d.counterparty_name, "
                   "d.target_counterparty_name, d.amount, d.reason, " + STATUS_SQL + ", d.doc_comment\n  from v_debt_adjustment_list d"),
         list_cols=[("ORGANIZATION_NAME", "Організація"), ("OPERATION_NAME", "Вид операції"), ("COUNTERPARTY_NAME", "Контрагент"),
                    ("TARGET_COUNTERPARTY_NAME", "Новий контрагент"), money_col("AMOUNT", "Сума, UAH"), ("REASON", "Підстава")],
         fields=[dict(ORG_FIELD, help="Організація, у розрізі якої коригуються взаєморозрахунки."),
                 dict(col="OPERATION_KIND", label="Вид операції", type="select", lov="debt-operation-kinds", required=True, span=6,
                      newcol=True, default="type: static\nstaticValue: OFFSET",
                      help="Взаємозалік: зменшує і дебіторську, і кредиторську заборгованість контрагента на суму заліку "
                           "(не більше меншої з них). Списання: зменшує заборгованість одного напряму. Перенесення: "
                           "переносить заборгованість на інший договір або іншого контрагента."),
                 dict(col="COUNTERPARTY_ID", label="Контрагент", type="ref", lov="COUNTERPARTIES_ACTIVE", required=True, span=6),
                 dict(col="CONTRACT_ID", label="Договір", type="ref", span=6, required=False, cascade="COUNTERPARTY_ID",
                      lov_sql=contract_lov,
                      help="Для взаємозаліку — договір з покупцем (дебіторка); для списання й перенесення — договір, з якого списується заборгованість."),
                 dict(col="TARGET_COUNTERPARTY_ID", label="Новий контрагент", type="ref", lov="COUNTERPARTIES_ACTIVE", required=False, span=6,
                      help="Лише для перенесення: на кого переноситься заборгованість. Порожнє — той самий контрагент (перенесення між договорами)."),
                 dict(col="TARGET_CONTRACT_ID", label="Другий договір", type="ref", span=6, required=False,
                      cascade=["COUNTERPARTY_ID", "TARGET_COUNTERPARTY_ID"], lov_sql=target_lov,
                      help="Для взаємозаліку — договір з постачальником (кредиторка); для перенесення — договір-одержувач."),
                 dict(col="CURRENCY_CODE", label="Валюта", type="display", span=2),
                 dict(col="AMOUNT", label="Сума", type="number", dtype="number", format=Q2, required=True, span=4),
                 dict(col="REASON", label="Підстава", type="text", max=500, span=6,
                      help="Для друкованого акта; порожнє — вид операції.")],
         toggle_js=js,
         post="trade_debt_adj.post", unpost="trade_debt_adj.unpost", copy="trade_debt_adj.copy"))


def r4_debt_lovs():
    b = "name: DEBT_OPERATION_KINDS\n" + block("source", "location: staticValues") + "\n"
    for i, (ret, disp) in enumerate(DEBT_OPERATION_KINDS):
        b += "\n" + comp("entry", ret.lower().replace("_", "-"), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / "debt-operation-kinds.apx", comp("lov", "debt-operation-kinds", b))


def reconciliation_page():
    """Акт звірки взаєморозрахунків: організація, контрагент, період; друк."""
    p = 420
    body = page_header(p, "Акт звірки взаєморозрахунків", "reconciliation-act", "Акт звірки взаєморозрахунків")
    body += "\n" + title_region("Акт звірки взаєморозрахунків")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)
    for it, lbl, lov, seq, span, dflt, new_row in [
            ("ORG", "Організація", "organizations-active", 10, 4, "trade_org.default_org", True),
            ("CP", "Контрагент", "counterparties-active", 15, 4, None, False)]:
        b = "type: " + ("selectList" if it == "ORG" else "popupLov") + "\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}" + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", "template: @/required\ntemplateOptions: #DEFAULT#") + "\n"
        b += block("lov", f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\ndisplayNullValue: true") + "\n"
        if it == "CP":
            b += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
        if dflt:
            b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'Q'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {20 + i * 10}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Акт звірки\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_debt_adj.reconciliation_html(:P{p}_ORG, :P{p}_CP,\n"
        f"         coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'Q')),\n"
        f"         coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "act", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-reconciliation-act.apx", comp("page", str(p), body))


# ===========================================================================
# r4 — F-PUR-05 «Оплата постачальнику» (паспорт DocSupplierPayment, ревізія r4)
# ===========================================================================
PAYMENT_FORMS = [("BANK", "Безготівкова (банківський рахунок)"), ("CASH", "Готівкова (каса)")]


def r4_supplier_payment_specs():
    desk_lov = ("select name || ' (' || currency_code || ')' d, id r\n  from ref_cash_desk\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by code")
    bank_lov = ("select name d, id r\n  from ref_bank_account\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n"
                " order by case is_default when 'Y' then 0 else 1 end, name")
    order_lov = ("select 'Замовлення № ' || o.doc_number || ' від ' || to_char(o.occurred_at, 'DD.MM.YYYY') || ' — '\n"
                 "       || to_char(o.total_amount, 'FM999G999G999G990D00') || ' (сплачено '\n"
                 "       || to_char(trade_pay_doc.paid_by_order(o.id), 'FM999G999G999G990D00') || ')' d, o.id r\n"
                 "  from doc_supplier_order o\n where o.status = 'POSTED' and o.supplier_id = :P#PAGE#_SUPPLIER_ID\n"
                 "   and o.organization_id = :P#PAGE#_ORGANIZATION_ID\n order by o.occurred_at desc")
    js = ("var f = $v('#P#_PAYMENT_FORM');\n"
          "function sh(i, on) { var it = apex.item(i); if (on) { it.show(); } else { it.hide(); } }\n"
          "sh('#P#_BANK_ACCOUNT_ID', f !== 'CASH');\nsh('#P#_RECIPIENT_IBAN', f !== 'CASH');\nsh('#P#_CASH_DESK_ID', f === 'CASH');\n")
    d = next(x for x in DOCUMENTS if x["page"] == 61)
    d.update(
        list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.supplier_name, d.payment_form_name, d.source_name, "
                  "d.amount, d.currency_code, d.contract_name, d.supplier_order_number, d.statement_number, "
                  + STATUS_SQL + ", d.doc_comment\n  from v_supplier_payment_list d"),
        list_cols=[("ORGANIZATION_NAME", "Організація"), ("SUPPLIER_NAME", "Постачальник"), ("PAYMENT_FORM_NAME", "Форма оплати"),
                   ("SOURCE_NAME", "Рахунок / каса"), money_col("AMOUNT", "Сума оплати"), ("CURRENCY_CODE", "Валюта"),
                   ("CONTRACT_NAME", "Договір"), ("SUPPLIER_ORDER_NUMBER", "Замовлення"), ("STATEMENT_NUMBER", "Виписка")],
        fields=[dict(ORG_FIELD, help="Організація-платник. Документ на підставі отримує організацію підстави."),
                ref_field("SUPPLIER_ID", "Постачальник", "COUNTERPARTIES_ACTIVE", newcol=True),
                dict(col="PAYMENT_FORM", label="Форма оплати", type="select", lov="payment-forms", required=True, span=6,
                     default="type: static\nstaticValue: BANK",
                     help="Безготівкова — списання з банківського рахунку (друк: платіжна інструкція); готівкова — видача з каси (друк: КО-2). "
                          "Документ сам рухає кошти: рядок банківської виписки з цією оплатою лише звіряється."),
                dict(col="BANK_ACCOUNT_ID", label="Банківський рахунок", type="ref", span=6, required=False,
                     cascade="ORGANIZATION_ID", lov_sql=bank_lov, help="Порожній — основний гривневий рахунок організації."),
                dict(col="CASH_DESK_ID", label="Каса", type="ref", span=6, required=False, cascade="ORGANIZATION_ID", lov_sql=desk_lov,
                     help="Порожня — перша гривнева каса організації."),
                dict(col="CURRENCY_CODE", label="Валюта", type="display", span=2),
                dict(col="AMOUNT", label="Сума оплати", type="number", dtype="number", format=Q2, required=True, span=4),
                contract_field("SUPPLIER_ID", "WITH_SUPPLIER"),
                dict(col="SUPPLIER_ORDER_ID", label="Замовлення постачальнику", type="ref", span=6, required=False,
                     cascade=["SUPPLIER_ID", "ORGANIZATION_ID"], lov_sql=order_lov,
                     help="Проведене замовлення цього постачальника; договір підставляється із замовлення."),
                dict(col="RECIPIENT_IBAN", label="IBAN отримувача", type="text", max=40, span=6,
                     help="Порожній — IBAN із картки постачальника. Для друку платіжної інструкції."),
                dict(col="PURPOSE", label="Призначення платежу", type="text", max=500, span=12,
                     help="Порожнє — «Оплата за товар згідно з …» (підстава, замовлення, договір)."),
                base_field("BASE_DOC_ID", "Документ-підстава"),
                dict(col="BASE_DOC_TYPE", type="hidden")],
        toggle_js=js, toggle_item="PAYMENT_FORM",
        post="trade_pay_doc.post_supplier_payment", unpost="trade_pay_doc.unpost_supplier_payment",
        copy="trade_pay_doc.copy_supplier_payment")
    # Введення на підставі: прибуткова накладна, замовлення постачальнику
    by_page = {x["page"]: x for x in DOCUMENTS}
    for pg, plsql in {51: "trade_pay_doc.payment_from_goods_receipt(#ID#)", 271: "trade_pay_doc.payment_from_supplier_order(#ID#)"}.items():
        x = by_page[pg]
        x.setdefault("commands", [])
        x["commands"] = [c for c in x["commands"] if c["name"] != "CREATE_SUPPLIER_PAYMENT"] + [
            cmd("CREATE_SUPPLIER_PAYMENT", "Створити оплату постачальнику", plsql, "posted", target=61, auth="role-purchase-or-cashier")]


def r4_supplier_payment_lovs():
    b = "name: PAYMENT_FORMS\n" + block("source", "location: staticValues") + "\n"
    for i, (ret, disp) in enumerate(PAYMENT_FORMS):
        b += "\n" + comp("entry", ret.lower(), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / "payment-forms.apx", comp("lov", "payment-forms", b))


def r4_customer_payment_specs():
    desk_lov = ("select name || ' (' || currency_code || ')' d, id r\n  from ref_cash_desk\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by code")
    bank_lov = ("select name d, id r\n  from ref_bank_account\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n"
                " order by case is_default when 'Y' then 0 else 1 end, name")
    order_lov = ("select 'Замовлення № ' || o.doc_number || ' від ' || to_char(o.occurred_at, 'DD.MM.YYYY') || ' — '\n"
                 "       || to_char(o.total_amount, 'FM999G999G999G990D00') || ' (сплачено '\n"
                 "       || to_char(trade_cust_pay.paid_by_order(o.id), 'FM999G999G999G990D00') || ')' d, o.id r\n"
                 "  from doc_customer_order o\n where o.status = 'POSTED' and o.customer_id = :P#PAGE#_CUSTOMER_ID\n"
                 "   and o.organization_id = :P#PAGE#_ORGANIZATION_ID\n order by o.occurred_at desc")
    invoice_lov = ("select 'Рахунок № ' || i.doc_number || ' від ' || to_char(i.occurred_at, 'DD.MM.YYYY') || ' — '\n"
                   "       || to_char(i.total_amount, 'FM999G999G999G990D00') || ' (' || trade_cust_pay.payment_state_name(i.id) || ')' d, i.id r\n"
                   "  from doc_invoice_for_payment i\n where i.status = 'ISSUED' and i.customer_id = :P#PAGE#_CUSTOMER_ID\n"
                   "   and i.organization_id = :P#PAGE#_ORGANIZATION_ID\n order by i.occurred_at desc")
    js = ("var f = $v('#P#_PAYMENT_FORM');\n"
          "function sh(i, on) { var it = apex.item(i); if (on) { it.show(); } else { it.hide(); } }\n"
          "sh('#P#_BANK_ACCOUNT_ID', f !== 'CASH');\nsh('#P#_CASH_DESK_ID', f === 'CASH');\n")
    d = next(x for x in DOCUMENTS if x["page"] == 121)
    d.update(
        list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.customer_name, d.payment_form_name, d.source_name, "
                  "d.amount, d.currency_code, d.allocated_amount, d.contract_name, d.customer_order_number, d.invoice_number, "
                  "d.statement_number, " + STATUS_SQL + ", d.doc_comment\n  from v_customer_payment_list d"),
        list_cols=[("ORGANIZATION_NAME", "Організація"), ("CUSTOMER_NAME", "Покупець"), ("PAYMENT_FORM_NAME", "Форма оплати"),
                   ("SOURCE_NAME", "Рахунок / каса"), money_col("AMOUNT", "Сума оплати"), ("CURRENCY_CODE", "Валюта"),
                   money_col("ALLOCATED_AMOUNT", "Розподілено"), ("CONTRACT_NAME", "Договір"),
                   ("CUSTOMER_ORDER_NUMBER", "Замовлення"), ("INVOICE_NUMBER", "Рахунок"), ("STATEMENT_NUMBER", "Виписка")],
        fields=[dict(ORG_FIELD, help="Організація-отримувач. Документ на підставі отримує організацію підстави."),
                ref_field("CUSTOMER_ID", "Покупець", "COUNTERPARTIES_ACTIVE", newcol=True),
                dict(col="PAYMENT_FORM", label="Форма оплати", type="select", lov="payment-forms", required=True, span=6,
                     default="type: static\nstaticValue: BANK",
                     help="Безготівкова — надходження на банківський рахунок; готівкова — прийом готівки в касу (друк: КО-1). "
                          "Документ сам рухає кошти: рядок банківської виписки з цією оплатою лише звіряється."),
                dict(col="BANK_ACCOUNT_ID", label="Банківський рахунок", type="ref", span=6, required=False,
                     cascade="ORGANIZATION_ID", lov_sql=bank_lov, help="Порожній — основний гривневий рахунок організації."),
                dict(col="CASH_DESK_ID", label="Каса", type="ref", span=6, required=False, cascade="ORGANIZATION_ID", lov_sql=desk_lov,
                     help="Порожня — перша гривнева каса організації."),
                dict(col="CURRENCY_CODE", label="Валюта", type="display", span=2),
                dict(col="AMOUNT", label="Сума оплати", type="number", dtype="number", format=Q2, required=True, span=4),
                contract_field("CUSTOMER_ID", "WITH_CUSTOMER"),
                dict(col="INVOICE_ID", label="Рахунок на оплату", type="ref", span=6, required=False,
                     cascade=["CUSTOMER_ID", "ORGANIZATION_ID"], lov_sql=invoice_lov,
                     help="Виданий рахунок цього покупця: після проведення оплати рахунок отримує стан «Оплачено» / «Частково оплачено»."),
                dict(col="CUSTOMER_ORDER_ID", label="Замовлення клієнта", type="ref", span=6, required=False,
                     cascade=["CUSTOMER_ID", "ORGANIZATION_ID"], lov_sql=order_lov,
                     help="Проведене замовлення цього покупця; реалізації за ним погашаються першими."),
                dict(col="PURPOSE", label="Призначення платежу", type="text", max=500, span=12,
                     help="Порожнє — «Оплата за товар згідно з …» (підстава, рахунок, замовлення, договір)."),
                base_field("BASE_DOC_ID", "Документ-підстава"),
                dict(col="BASE_DOC_TYPE", type="hidden")],
        extra_regions=[("allocation", "Розшифровка платежу",
                        "select line_number, settlement_doc_name, settlement_doc_date, amount\n  from v_customer_payment_alloc\n"
                        " where document_id = :P#PAGE#_ID",
                        [("LINE_NUMBER", "№", "number"), ("SETTLEMENT_DOC_NAME", "Документ розрахунків"),
                         ("SETTLEMENT_DOC_DATE", "Дата боргу", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                         money_col("AMOUNT", "Сума")])],
        toggle_js=js, toggle_item="PAYMENT_FORM",
        post="trade_cust_pay.post_customer_payment", unpost="trade_cust_pay.unpost_customer_payment",
        copy="trade_cust_pay.copy_customer_payment")
    by_page = {x["page"]: x for x in DOCUMENTS}
    # Рахунок на оплату: стан оплати в списку й оплати за рахунком у формі
    inv = by_page[321]
    old = ", d.doc_comment\n  from doc_invoice_for_payment d"
    assert old in inv["list_sql"]
    inv["list_sql"] = inv["list_sql"].replace(old, ", trade_cust_pay.invoice_paid(d.id) paid_amount, "
                                              "trade_cust_pay.payment_state_name(d.id) payment_state_name" + old, 1)
    inv["list_cols"] = inv["list_cols"] + [money_col("PAID_AMOUNT", "Сплачено"), ("PAYMENT_STATE_NAME", "Оплата")]
    inv["extra_regions"] = [("invoice-payments", "Оплати за рахунком",
                             "select doc_kind, doc_number, occurred_at, payment_form_name, amount,\n"
                             "       case status when 'POSTED' then 'Проведено' else 'Чернетка' end status_name\n"
                             "  from v_invoice_payment\n where invoice_id = :P#PAGE#_ID",
                             [("DOC_KIND", "Документ"), ("DOC_NUMBER", "Номер"),
                              ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                              ("PAYMENT_FORM_NAME", "Форма оплати"), money_col("AMOUNT", "Сума"), ("STATUS_NAME", "Стан")])]
    # Введення на підставі: реалізація, рахунок на оплату, замовлення клієнта
    for pg, plsql in {111: "trade_cust_pay.payment_from_sale(#ID#)", 321: "trade_cust_pay.payment_from_invoice(#ID#)",
                      261: "trade_cust_pay.payment_from_customer_order(#ID#)"}.items():
        x = by_page[pg]
        x.setdefault("commands", [])
        x["commands"] = [c for c in x["commands"] if c["name"] != "CREATE_CUSTOMER_PAYMENT"] + [
            cmd("CREATE_CUSTOMER_PAYMENT", "Створити оплату від покупця", plsql, "posted", target=121, auth="role-sales-or-cashier")]


# ===========================================================================
# r4 — F-WH-10 «Комплектація / розкомплектація» (паспорти RefBillOfMaterials, DocAssembly)
# ===========================================================================
ASSEMBLY_OPERATION_KINDS = [("ASSEMBLY", "Комплектація"), ("DISASSEMBLY", "Розкомплектація")]


def r4_assembly_specs():
    CATALOGS.append(dict(list_page=430, form_page=431, alias="bills-of-materials", table="REF_BILL_OF_MATERIALS",
         title="Специфікації наборів", item_title="Специфікація набору", edit_auth="role-warehouse", dialog_width=960,
         list_sql=("select id, code, name, product_name, quantity, unit_name, main_name, items_count, " + STATE_SQL
                   + " from v_bill_of_materials_list"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("PRODUCT_NAME", "Набір"), ("QUANTITY", "Кількість набору"),
                  ("UNIT_NAME", "Од."), ("MAIN_NAME", "Основна"), ("ITEMS_COUNT", "Комплектуючих"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, span=9, newcol=True,
                      help="Порожнє — «Специфікація: <набір>»."),
                 dict(col="PRODUCT_ID", label="Набір", type="ref", lov="PRODUCTS_GOODS", required=True, span=6,
                      help="Товар-комплект, який збирається з комплектуючих."),
                 dict(col="QUANTITY", label="Кількість набору", type="number", dtype="number", format=Q3, required=True, span=3,
                      newcol=True, default="type: static\nstaticValue: 1",
                      help="На яку кількість наборів задано комплектуючі (зазвичай 1)."),
                 dict(col="IS_MAIN", label="Основна", type="switch", span=3, newcol=True,
                      help="Підставляється в документ комплектації. Лише одна основна специфікація набору."),
                 dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12)],
         lines=dict(table="REF_BILL_OF_MATERIALS_ITEMS", fk="bom_id", title="Комплектуючі",
                    cols=[GOODS_COL, QTY_COL,
                          dict(col="COST_SHARE", heading="Частка вартості", kind="number", dtype="number", mask="FM999G990D0000",
                               help="Вага рядка при розподілі собівартості набору під час розкомплектації. "
                                    "Порожньо в усіх рядках — розподіл за середньою собівартістю комплектуючих.")])))
    bom_lov = ("select code || ' ' || name || case is_main when 'Y' then ' (основна)' end d, id r\n"
               "  from ref_bill_of_materials\n where state = 'ACTIVE' and product_id = :P#PAGE#_KIT_PRODUCT_ID\n"
               " order by case is_main when 'Y' then 0 else 1 end, code")
    free_col = dict(col="FREE_QTY", heading="Вільний залишок", kind="display", dtype="number", mask=Q3, width=130,
                    sql="trade_assembly.line_free_qty(document_id, product_id)")
    cost_col = dict(col="COST_AMOUNT", heading="Собівартість", kind="display", dtype="number", mask=Q2, width=130)
    DOCUMENTS.append(dict(page=441, list_page=440, alias="assembly", list_alias="assemblies", table="DOC_ASSEMBLY",
         title="Комплектація товарів", list_title="Комплектація товарів",
         list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.operation_name, d.warehouse_name, d.kit_name, "
                   "d.quantity, d.kit_cost_amount, " + STATUS_SQL + ", d.doc_comment\n  from v_assembly_list d"),
         list_cols=[("ORGANIZATION_NAME", "Організація"), ("OPERATION_NAME", "Вид операції"), ("WAREHOUSE_NAME", "Склад"),
                    ("KIT_NAME", "Набір"), ("QUANTITY", "Кількість", "number", False, block("appearance", f"formatMask: {Q3}") + "\n"),
                    money_col("KIT_COST_AMOUNT", "Собівартість")],
         fields=[ORG_FIELD,
                 dict(col="OPERATION_KIND", label="Вид операції", type="select", lov="assembly-operation-kinds", required=True, span=6,
                      newcol=True, default="type: static\nstaticValue: ASSEMBLY",
                      help="Комплектація: списує комплектуючі й оприбутковує набір за сумою їх собівартості. "
                           "Розкомплектація: списує набір і оприбутковує комплектуючі."),
                 ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ACTIVE"),
                 ref_field("KIT_PRODUCT_ID", "Набір", "PRODUCTS_GOODS", newcol=True),
                 dict(col="BOM_ID", label="Специфікація", type="ref", span=6, required=False, cascade="KIT_PRODUCT_ID",
                      lov_sql=bom_lov, help="Порожнє — основна специфікація набору (підставляється під час запису)."),
                 dict(col="QUANTITY", label="Кількість наборів", type="number", dtype="number", format=Q3, required=True, span=3,
                      newcol=True, default="type: static\nstaticValue: 1"),
                 dict(col="KIT_COST_AMOUNT", label="Собівартість наборів", type="display", dtype="number", format=Q2, span=3,
                      newcol=True, query_only=True, help="Розраховується під час проведення (сума собівартості комплектуючих).")],
         lines=dict(table="DOC_ASSEMBLY_GOODS", title="Комплектуючі", cols=[GOODS_COL, QTY_COL, free_col, cost_col]),
         commands=[cmd("FILL_BY_BOM", "Заповнити за специфікацією", "trade_assembly.fill_by_bom(#ID#);", "draft",
                       confirm="Замінити комплектуючі рядками специфікації (за записаними набором, специфікацією й кількістю)?",
                       success="Комплектуючі заповнено за специфікацією.")],
         post="trade_assembly.post", unpost="trade_assembly.unpost", copy="trade_assembly.copy"))


def r4_assembly_lovs():
    b = "name: ASSEMBLY_OPERATION_KINDS\n" + block("source", "location: staticValues") + "\n"
    for i, (ret, disp) in enumerate(ASSEMBLY_OPERATION_KINDS):
        b += "\n" + comp("entry", ret.lower(), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / "assembly-operation-kinds.apx", comp("lov", "assembly-operation-kinds", b))


# ===========================================================================
# r4 — F-SRV-05 «Журнал реєстрації» (sys_audit_log, trade_event_log / v_event_log, db/37)
# ===========================================================================
EVENT_GROUPS = [("post", "Проведення", "POST"), ("unpost", "Скасування проведення", "UNPOST"),
                ("delete", "Видалення", "DELETE"), ("print", "Друк", "PRINT"),
                ("warning", "Попередження", "WARNING"), ("write", "Запис", "WRITE"), ("other", "Інші події", "OTHER")]


def event_log_lovs():
    b = "name: EVENT_LOG_EVENTS\n" + block("source", "location: staticValues") + "\n"
    for i, (eid, disp, ret) in enumerate(EVENT_GROUPS):
        b += "\n" + comp("entry", eid, f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / "event-log-events.apx", comp("lov", "event-log-events", b))
    sql_lov("event-log-users", "EVENT_LOG_USERS",
            "select distinct user_name d, user_name r\n  from sys_audit_log\n order by 1")
    sql_lov("event-log-objects", "EVENT_LOG_OBJECTS",
            "select trade_event_log.object_type_name(min(object_type)) d, trade_event_log.object_kind(object_type) r\n"
            "  from sys_audit_log\n group by trade_event_log.object_kind(object_type)\n order by 1")


def event_log_page():
    """F-SRV-05: журнал реєстрації — відбори період / користувач / об'єкт / подія, перехід до об'єкта; лише адміністратор."""
    p = 480
    body = page_header(p, "Журнал реєстрації", "event-log", "Журнал реєстрації")
    body += "\n" + title_region("Журнал реєстрації")
    bar = "name: Відбір\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "bar", bar)
    for i, (it, lbl, dflt) in enumerate([("FROM", "Початок періоду", "trunc(sysdate) - 7"), ("TO", "Кінець періоду", "trunc(sysdate)")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {(i + 1) * 10}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2"
                   + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: to_char({dflt}, 'DD.MM.YYYY')") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    for it, lbl, lov, seq, null_txt in [("USER", "Користувач", "event-log-users", 30, "Усі користувачі"),
                                        ("OBJECT", "Об'єкт", "event-log-objects", 40, "Усі об'єкти"),
                                        ("EVENT", "Подія", "event-log-events", 50, "Усі події")]:
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
        b += block("lov", f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: {null_txt}") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("apply", "APPLY", "Сформувати", 60, "bar", slot="regionBody", hot=True)
    sql = ("select cast(e.occurred_at as date) occurred_at, e.user_name, e.event_group_name, e.event_name, e.object_type_name, e.object_name,\n"
           "       case when e.link_page is not null then\n"
           "         apex_page.get_url(p_page => e.link_page, p_items => e.link_item,\n"
           "                           p_values => case when e.link_item is not null then e.object_id end) end object_url,\n"
           "       e.details, e.action, e.object_id\n"
           "  from v_event_log e\n"
           f" where e.occurred_at >= coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate) - 7)\n"
           f"   and e.occurred_at < coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)) + 1\n"
           f"   and (:P{p}_USER is null or e.user_name = :P{p}_USER)\n"
           f"   and (:P{p}_OBJECT is null or e.object_kind = :P{p}_OBJECT)\n"
           f"   and (:P{p}_EVENT is null or e.event_group = :P{p}_EVENT)\n"
           " order by e.occurred_at desc")
    obj_link = block("columnFormatting", "htmlExpression: {if OBJECT_URL/}<a href=\"#OBJECT_URL#\">#OBJECT_NAME#</a>{else/}#OBJECT_NAME#{endif/}") + "\n"
    cols = [("OCCURRED_AT", "Дата, час", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
            ("USER_NAME", "Користувач"), ("EVENT_GROUP_NAME", "Група подій"), ("EVENT_NAME", "Подія"),
            ("OBJECT_TYPE_NAME", "Метадані"), ("OBJECT_NAME", "Дані", "varchar2", False, obj_link),
            ("OBJECT_URL", "URL", "varchar2", True), ("DETAILS", "Коментар"),
            ("ACTION", "Код події", "varchar2", True), ("OBJECT_ID", "Ідентифікатор", "varchar2", True)]
    r = ir_region("log", "Журнал реєстрації", sql, cols, seq=10)
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_FROM\n            P{p}_TO\n            P{p}_USER\n"
                  f"            P{p}_OBJECT\n            P{p}_EVENT\n        ]\n        sqlQuery:", 1)
    body += "\n" + r
    write(PAGES / f"p{p:05d}-event-log.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-NSI-10 «Характеристики, серії, терміни придатності» (trade_series, db/38)
# ===========================================================================
CHAR_COL = dict(col="CHARACTERISTIC_ID", heading="Характеристика", kind="ref", lov="product-characteristics-active", width=200,
                help="Для товарів з ознакою «Використовувати характеристики» (розмір, колір …) — обов'язкова при проведенні.")
SERIES_COL = dict(col="SERIES_ID", heading="Серія", kind="ref", lov="product-series-active", width=220,
                  help="Для товарів з обліком серій. У видаткових документах порожня серія підбирається за FEFO під час проведення.")
SERIES_TYPES = {51: "DocGoodsReceipt", 111: "DocGoodsSale", 131: "DocGoodsTransfer", 141: "DocGoodsWriteOff",
                261: "DocCustomerOrder", 281: "DocCustomerReturn", 291: "DocSupplierReturn", 311: "DocSurplusPosting",
                441: "DocAssembly"}
FEFO_PAGES = (111, 131, 141, 441)


def r5_series_specs():
    for c in CATALOGS:
        if c["table"] == "REF_PRODUCT":
            c["fields"] = c["fields"] + [
                dict(col="USE_CHARACTERISTICS", label="Використовувати характеристики", type="switch", span=4,
                     help="Облік залишків у розрізі характеристик (розмір, колір …). Змінюється лише за нульового залишку."),
                dict(col="USE_SERIES", label="Облік серій", type="switch", span=4, newcol=True,
                     help="Облік залишків у розрізі серій (партій) з терміном придатності; відвантаження за FEFO. "
                          "Змінюється лише за нульового залишку."),
                dict(col="SHELF_LIFE_DAYS", label="Термін придатності, днів", type="number", dtype="number", span=4, newcol=True,
                     help="Типовий термін для нових серій: «Придатний до» = дата виробництва + термін.")]
    CATALOGS.append(dict(list_page=490, form_page=491, alias="product-characteristics", table="REF_PRODUCT_CHARACTERISTIC",
         title="Характеристики номенклатури", item_title="Характеристика номенклатури", edit_auth="role-warehouse-or-purchase",
         list_sql="select id, code, product_name, name, description, " + STATE_SQL + " from v_product_characteristic_list",
         columns=[("CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("NAME", "Характеристика"), ("DESCRIPTION", "Опис"), ("STATE_NAME", "Стан")],
         fields=[dict(col="PRODUCT_ID", label="Товар", type="ref", lov="PRODUCTS_WITH_CHARACTERISTICS", required=True, span=12,
                      help="Лише товари з ознакою «Використовувати характеристики»."),
                 dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True,
                      help="Напр. «Червона, M». Унікальне в межах товару."),
                 dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12)]))
    CATALOGS.append(dict(list_page=500, form_page=501, alias="product-series", table="REF_PRODUCT_SERIES",
         title="Серії номенклатури", item_title="Серія номенклатури", edit_auth="role-warehouse-or-purchase",
         list_sql=("select id, code, product_name, name, production_date, expiry_date, expiry_state_name, quantity, "
                   + STATE_SQL + " from v_product_series_list"),
         columns=[("CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("NAME", "Номер серії"), ("PRODUCTION_DATE", "Дата виробництва"),
                  ("EXPIRY_DATE", "Придатний до"), ("EXPIRY_STATE_NAME", "Термін (30 днів)"), ("QUANTITY", "Залишок"),
                  ("STATE_NAME", "Стан")],
         fields=[dict(col="PRODUCT_ID", label="Товар", type="ref", lov="PRODUCTS_WITH_SERIES", required=True, span=12,
                      help="Лише товари з ознакою «Облік серій»."),
                 dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Номер серії", type="text", max=255, required=True, span=9, newcol=True,
                      help="Номер партії виробника. Унікальний в межах товару."),
                 dict(col="PRODUCTION_DATE", label="Дата виробництва", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=6),
                 dict(col="EXPIRY_DATE", label="Придатний до", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=6,
                      newcol=True, help="Порожньо — дата виробництва + термін придатності з картки товару."),
                 dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12)]))
    for d in DOCUMENTS:
        p = d["page"]
        if p not in SERIES_TYPES or not d.get("lines"):
            continue
        d["series_type"] = SERIES_TYPES[p]
        cols = d["lines"]["cols"]
        pos = next((i + 1 for i, c in enumerate(cols) if c["col"] in ("PRODUCT_ID", "PRODUCT_NAME")), 1)
        if p in (281, 291):   # повернення: з рядка-підстави, лише перегляд
            new = [dict(col="CHAR_NAME", heading="Характеристика", kind="display", width=160,
                        sql="trade_series.char_label(characteristic_id)"),
                   dict(col="SERIES_NAME", heading="Серія", kind="display", width=200,
                        sql="trade_series.series_label(series_id)")]
        else:
            new = [CHAR_COL, SERIES_COL]
        d["lines"]["cols"] = cols[:pos] + new + cols[pos:]
        if p in FEFO_PAGES:
            d["commands"] = d.get("commands", []) + [
                cmd("FILL_SERIES", "Підібрати серії (FEFO)", f"trade_series.fill_fefo('{SERIES_TYPES[p]}', #ID#);", "draft",
                    success="Серії підібрано за FEFO (першим спливає — першим відвантажено). Перевірте рядки без серії.")]


def r5_series_lovs():
    sql_lov("product-characteristics-active", "PRODUCT_CHARACTERISTICS_ACTIVE",
            "select p.name || ': ' || c.name d, c.id r\n  from ref_product_characteristic c join ref_product p on p.id = c.product_id\n"
            " where c.state = 'ACTIVE'\n order by p.name, c.name")
    sql_lov("product-series-active", "PRODUCT_SERIES_ACTIVE",
            "select p.name || ': ' || s.name || case when s.expiry_date is not null then ' (до ' || to_char(s.expiry_date, 'DD.MM.YYYY') || ')' end d,\n"
            "       s.id r\n  from ref_product_series s join ref_product p on p.id = s.product_id\n"
            " where s.state = 'ACTIVE'\n order by p.name, s.expiry_date nulls last, s.name")
    for ident, name, flag in [("products-with-characteristics", "PRODUCTS_WITH_CHARACTERISTICS", "use_characteristics"),
                              ("products-with-series", "PRODUCTS_WITH_SERIES", "use_series")]:
        sql_lov(ident, name, "select p.name || ' (' || u.short_name || ')' d, p.id r\n  from ref_product p\n"
                "  join ref_unit_of_measure u on u.id = p.unit_of_measure_id\n"
                f" where p.state = 'ACTIVE' and p.{flag} = 'Y'\n order by p.name")


def expiring_goods_page():
    """F-NSI-10: «Товари з терміном, що спливає» — залишки серій зі строком придатності на дату (+ залишки характеристик)."""
    p = 510
    body = page_header(p, "Товари з терміном, що спливає", "expiring-goods", "Товари з терміном, що спливає")
    body += "\n" + title_region("Товари з терміном, що спливає")
    bar = "name: Відбір\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "bar", bar)
    b = "type: datePicker\n" + block("label", "label: На дату\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 2") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: to_char(sysdate, 'DD.MM.YYYY')") + "\n"
    b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DATE", b)
    b = "type: numberField\n" + block("label", "label: Спливає протягом, днів\nalignment: right") + "\n"
    b += block("layout", "sequence: 20\nregion: @bar\nslot: regionBody\ncolumnSpan: 2\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("default", "type: static\nstaticValue: 30") + "\n"
    b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
    b += block("help", "helpText: Серії, термін придатності яких минув або спливає протягом указаної кількості днів від дати. "
               "Порожньо — усі залишки серій і характеристик.") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_DAYS", b)
    b = "type: selectList\n" + block("label", "label: Склад\nalignment: right") + "\n"
    b += block("layout", "sequence: 30\nregion: @bar\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @warehouses-active\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: Усі склади") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_WAREHOUSE", b)
    body += "\n" + button("apply", "APPLY", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    dt = f"coalesce(to_date(:P{p}_DATE, 'DD.MM.YYYY'), trunc(sysdate))"
    days = f"case when validate_conversion(:P{p}_DAYS as number) = 1 then to_number(:P{p}_DAYS) end"
    sql = ("select v.warehouse_name, v.product_code, v.product_name, v.characteristic_name, v.series_number,\n"
           "       v.production_date, v.expiry_date, v.expiry_date - " + dt + " days_left,\n"
           "       trade_series.expiry_state_name(trade_series.expiry_state(v.expiry_date, " + dt + ", " + days + ")) expiry_state_name,\n"
           "       v.quantity, v.unit_name,\n"
           "       round(v.quantity * coalesce(trade_r3.avg_cost(v.warehouse_id, v.product_id), 0), 2) cost_amount,\n"
           "       case when v.expiry_date < " + dt + " then 'u-danger-text' when v.expiry_date is not null then 'u-warning-text' end state_css\n"
           "  from v_series_stock_balance v\n"
           " where v.quantity > 0\n"
           f"   and (:P{p}_WAREHOUSE is null or v.warehouse_id = :P{p}_WAREHOUSE)\n"
           "   and (" + days + " is null or v.expiry_date <= " + dt + " + " + days + ")\n"
           " order by v.expiry_date nulls last, v.product_name, v.warehouse_name")
    state_fmt = block("columnFormatting", 'htmlExpression: <span class="#STATE_CSS#">#EXPIRY_STATE_NAME#</span>') + "\n"
    dfmt = block("appearance", "formatMask: DD.MM.YYYY") + "\n"
    cols = [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"),
            ("CHARACTERISTIC_NAME", "Характеристика"), ("SERIES_NUMBER", "Серія"),
            ("PRODUCTION_DATE", "Дата виробництва", "date", False, dfmt), ("EXPIRY_DATE", "Придатний до", "date", False, dfmt),
            ("DAYS_LEFT", "Залишилось днів", "number"), ("EXPIRY_STATE_NAME", "Стан", "varchar2", False, state_fmt),
            ("QUANTITY", "Кількість", "number", False, block("appearance", f"formatMask: {Q3}") + "\n"), ("UNIT_NAME", "Од."),
            ("COST_AMOUNT", "Собівартість (оцінка)", "number", False, block("appearance", f"formatMask: {Q2}") + "\n"),
            ("STATE_CSS", "css", "varchar2", True)]
    r = ir_region("goods", "Залишки серій", sql, cols, seq=10)
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_DATE\n            P{p}_DAYS\n            P{p}_WAREHOUSE\n"
                  "        ]\n        sqlQuery:", 1)
    body += "\n" + r
    write(PAGES / f"p{p:05d}-expiring-goods.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-PRC-06 «Знижки й акції» (RefDiscount, RegDiscountLimit, trade_discount)
# ===========================================================================
DISCOUNT_APPLIES = [("ALL", "Замовлення й реалізація"), ("ORDER", "Замовлення клієнтів"), ("SALE", "Реалізація")]
ACL_ROLES = [("ADMIN", "Адміністратор"), ("SALES", "Менеджер з продажу"), ("PURCHASE", "Закупівельник"),
             ("STOREKEEPER", "Комірник"), ("CASHIER", "Касир")]
DISCOUNT_TYPES = {111: "DocGoodsSale", 261: "DocCustomerOrder"}
PCT = "FM990D00"


def static_lov(ident, name, entries):
    b = f"name: {name}\n" + block("source", "location: staticValues") + "\n"
    for i, (ret, disp) in enumerate(entries):
        b += "\n" + comp("entry", ret.lower().replace("_", "-"), f"sequence: {i + 1}\ndisplay: {disp}\nreturn: {ret}")
    write(SC / "lovs" / f"{ident}.apx", comp("lov", ident, b))


def r5_discount_specs():
    CATALOGS.append(dict(list_page=520, form_page=521, alias="discounts", table="REF_DISCOUNT",
         title="Знижки та акції", item_title="Знижка (акція)", dialog_width=900,
         list_sql=("select id, code, name, discount_percent, applies_to_name, period_text, validity_name, customer_name, contract_name, "
                   "group_path, product_name, min_quantity, min_doc_amount, " + STATE_SQL + " from v_discount_list"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("DISCOUNT_PERCENT", "Знижка, %"), ("APPLIES_TO_NAME", "Застосування"),
                  ("PERIOD_TEXT", "Період дії"), ("VALIDITY_NAME", "Стан дії"), ("CUSTOMER_NAME", "Покупець"),
                  ("CONTRACT_NAME", "Договір"), ("GROUP_PATH", "Група номенклатури"), ("PRODUCT_NAME", "Товар"),
                  ("MIN_QUANTITY", "Від кількості"), ("MIN_DOC_AMOUNT", "Від суми документа"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True,
                      help="Напр. «Акція: олії −5 %» або «Постійний клієнт»."),
                 dict(col="DISCOUNT_PERCENT", label="Знижка, %", type="number", dtype="number", format=PCT, required=True, span=3,
                      help="Автоматична знижка рядка. З кількох придатних умов застосовується одна — з найбільшим відсотком; "
                           "ручна знижка рядка додається до неї."),
                 dict(col="APPLIES_TO", label="Застосовується в", type="select", lov="discount-applies-to", required=True, span=3,
                      newcol=True, default="type: static\nstaticValue: ALL"),
                 dict(col="DATE_FROM", label="Діє з", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=3, newcol=True,
                      help="Період акції за датою документа. Порожньо — без обмеження."),
                 dict(col="DATE_TO", label="по", type="date", dtype="date", format="DD.MM.YYYY", date_only=True, span=3, newcol=True),
                 dict(col="CUSTOMER_ID", label="Покупець", type="ref", lov="COUNTERPARTIES_ACTIVE", span=6,
                      help="Порожньо — для всіх покупців."),
                 dict(col="CONTRACT_ID", label="Договір", type="ref", span=6, newcol=True, cascade="CUSTOMER_ID",
                      lov_sql=("select o.name || ': ' || c.name || case when c.contract_number is not null then ' № ' || c.contract_number end d, c.id r\n"
                               "  from ref_contract c join ref_counterparty o on o.id = c.owner_id\n"
                               " where c.state = 'ACTIVE' and c.contract_kind = 'WITH_CUSTOMER'\n"
                               "   and (:P#PAGE#_CUSTOMER_ID is null or c.owner_id = :P#PAGE#_CUSTOMER_ID)\n order by o.name, c.name"),
                      help="Знижка лише за документами з цим договором; покупець — власник договору."),
                 dict(col="PRODUCT_GROUP_ID", label="Група номенклатури", type="ref", lov="PRODUCT_GROUPS_ACTIVE", span=6,
                      help="Діє на товари групи та всіх її підгруп. Або група, або товар."),
                 dict(col="PRODUCT_ID", label="Товар", type="ref", lov="PRODUCTS_ACTIVE", span=6, newcol=True),
                 dict(col="MIN_QUANTITY", label="Від кількості в рядку", type="number", dtype="number", span=6),
                 dict(col="MIN_DOC_AMOUNT", label="Від суми документа, грн", type="number", dtype="number", format=Q2, span=6, newcol=True,
                      help="Сума документа за цінами до знижок."),
                 dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12)]))
    for d in DOCUMENTS:
        p = d["page"]
        if p not in DISCOUNT_TYPES:
            continue
        typ = DISCOUNT_TYPES[p]
        d["discount_type"] = typ
        cols = d["lines"]["cols"]
        manual = dict(col="MANUAL_DISCOUNT_PERCENT", heading="Ручна знижка, %", kind="number", dtype="number", mask=PCT, width=100,
                      help="Обмежена максимальною ручною знижкою вашої ролі (регістр «Обмеження ручних знижок»).")
        auto = [dict(col="AUTO_DISCOUNT_PERCENT", heading="Авт. знижка, %", kind="display", dtype="number", mask=PCT, width=90),
                dict(col="DISCOUNT_NAME", heading="Умова знижки", kind="display", width=200,
                     sql="trade_discount.rule_label(discount_id)")]
        out = []
        for c in cols:
            if p == 111 and c["col"] == "PRICE":
                out += [dict(col="BASE_PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2,
                             help="Ціна до знижки. Залиште порожньою — ціна підставиться з виду цін."),
                        manual] + auto + [
                        dict(col="DISCOUNT_PERCENT", heading="Знижка, %", kind="display", dtype="number", mask=PCT, width=80),
                        dict(col="PRICE", heading="Ціна зі знижкою", kind="display", dtype="number", mask=Q2, width=110)]
            elif p == 261 and c["col"] == "DISCOUNT_PERCENT":
                out += [manual] + auto + [
                        dict(col="DISCOUNT_PERCENT", heading="Знижка, %", kind="display", dtype="number", mask=PCT, width=80)]
            else:
                out.append(c)
        d["lines"]["cols"] = out
        d["extra_items"] = d.get("extra_items", []) + [
            dict(name="MANUAL_DISCOUNT", label="Ручна знижка на документ, %", type="numberField", span=4, when="draft")]
        d["commands"] = d.get("commands", []) + [
            cmd("CALC_DISCOUNTS", "Розрахувати знижки", f"trade_discount.calc('{typ}', #ID#);", "draft",
                success="Автоматичні знижки розраховано за умовами довідника «Знижки та акції»."),
            cmd("SET_MANUAL_DISCOUNT", "Ручна знижка на документ",
                f"trade_discount.set_manual('{typ}', #ID#, to_number(replace(:P{p}_MANUAL_DISCOUNT, ',', '.'), '990D99', 'NLS_NUMERIC_CHARACTERS=.,'));",
                "draft", success="Ручну знижку встановлено в усіх рядках документа.")]


def r5_discount_lovs():
    static_lov("discount-applies-to", "DISCOUNT_APPLIES_TO", DISCOUNT_APPLIES)
    static_lov("acl-roles-list", "ACL_ROLES_LIST", ACL_ROLES)


def discount_limits_page():
    editable_register_page(530, "discount-limits", "Обмеження ручних знижок", "REG_DISCOUNT_LIMIT", [
        dict(col="ROLE_STATIC_ID", heading="Роль", kind="select", lov="acl-roles-list", required=True, width=220),
        dict(col="MAX_MANUAL_PERCENT", heading="Макс. ручна знижка, %", kind="number", dtype="number", mask=PCT, required=True, width=160),
        dict(col="NOTE", heading="Примітка", kind="text", width=320),
        dict(col="UPDATED_BY", heading="Змінив", kind="display", width=140),
    ], "role_static_id")


def discounts_given_page():
    """F-PRC-06: «Надані знижки» — підсумки за умовами + рядки проведених реалізацій зі знижкою."""
    p = 540
    body = page_header(p, "Надані знижки", "discounts-given", "Надані знижки")
    body += "\n" + title_region("Надані знижки")
    bar = "name: Відбір\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "bar", bar)
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {10 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2" + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + org_filter_item(p, "bar", 20, span=3)
    body += "\n" + button("apply", "APPLY", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    frm = f"coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'MM'))"
    to = f"coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate))"
    sb = "name: Підсумки за умовами\ntitle: Підсумки за умовами\ntype: dynamicContent\n"
    sb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_discount.given_html({frm}, {to}, :P{p}_ORG);")) + "\n"
    sb += block("layout", "sequence: 10\nslot: body") + "\n"
    sb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "summary", sb)
    sql = ("select v.period, v.doc_number, v.document_id, v.customer_name, v.product_code, v.product_name, v.group_path,\n"
           "       v.quantity, v.base_price, v.price, v.list_amount, v.discount_percent, v.manual_discount_percent,\n"
           "       v.auto_discount_percent, v.discount_name, v.discount_amount, v.auto_discount_amount, v.amount, v.author,\n"
           "       apex_page.get_url(p_page => 111, p_items => 'P111_ID', p_values => v.document_id) doc_url\n"
           "  from v_discount_given v\n"
           f" where v.period >= {frm} and v.period < {to} + 1\n"
           f"   and (:P{p}_ORG is null or v.organization_id = :P{p}_ORG)\n"
           " order by v.period, v.doc_number, v.line_number")
    m2 = block("appearance", f"formatMask: {Q2}") + "\n"
    mp = block("appearance", f"formatMask: {PCT}") + "\n"
    cols = [DATE_LIST_COL[:3] + (False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"),
            ("DOC_NUMBER", "Реалізація", "varchar2", False, block("columnFormatting", 'htmlExpression: <a href="#DOC_URL#">#DOC_NUMBER#</a>') + "\n"),
            ("DOCUMENT_ID", "ID", "varchar2", True), ("CUSTOMER_NAME", "Покупець"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"),
            ("GROUP_PATH", "Група"), ("QUANTITY", "Кількість", "number", False, block("appearance", f"formatMask: {Q3}") + "\n"),
            ("BASE_PRICE", "Ціна до знижки", "number", False, m2), ("PRICE", "Ціна зі знижкою", "number", False, m2),
            ("LIST_AMOUNT", "Сума без знижки", "number", False, m2), ("DISCOUNT_PERCENT", "Знижка, %", "number", False, mp),
            ("MANUAL_DISCOUNT_PERCENT", "Ручна, %", "number", False, mp), ("AUTO_DISCOUNT_PERCENT", "Авт., %", "number", False, mp),
            ("DISCOUNT_NAME", "Умова знижки"), ("DISCOUNT_AMOUNT", "Сума знижки", "number", False, m2),
            ("AUTO_DISCOUNT_AMOUNT", "у т. ч. автоматична", "number", False, m2), ("AMOUNT", "Сума", "number", False, m2),
            ("AUTHOR", "Автор документа"), ("DOC_URL", "url", "varchar2", True)]
    cols[0] = ("PERIOD",) + cols[0][1:]
    r = ir_region("lines", "Рядки реалізацій зі знижкою", sql, cols, seq=20, title="Рядки реалізацій зі знижкою")
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_FROM\n            P{p}_TO\n            P{p}_ORG\n"
                  "        ]\n        sqlQuery:", 1)
    body += "\n" + r
    write(PAGES / f"p{p:05d}-discounts-given.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-WH-11 «Ордерна схема, комірки» (DocGoodsReceiptOrder, DocGoodsIssueOrder, RefStorageBin, trade_order_scheme)
# ===========================================================================
ORDER_BASIS_PAGES = {"RECEIPT": [51, 281, 311, 131, 441], "SHIPMENT": [111, 291, 141, 131, 441]}


def order_doc_spec(kind):
    rcv = kind == "RECEIPT"
    p, lp = (561, 560) if rcv else (571, 570)
    word = "до надходження" if rcv else "до відвантаження"
    basis_lov = ("select b.basis_name || ' — ' || b.state_name || ' (залишок ' || rtrim(to_char(b.remaining_qty, 'FM999G999G990D999'), '.,') || ')' d,\n"
                 "       b.basis_id r\n  from v_goods_order_basis b\n"
                 f" where b.direction = '{kind}' and b.warehouse_id = :P#PAGE#_WAREHOUSE_ID\n"
                 "   and (b.remaining_qty > 0 or b.basis_id = :P#PAGE#_BASIS_ID)\n order by b.basis_date desc")
    bin_lov = ("select b.name d, b.id r\n  from ref_storage_bin b\n"
               " where b.state = 'ACTIVE' and b.warehouse_id = :P#PAGE#_WAREHOUSE_ID\n order by b.name")
    fields = [dict(col="ORGANIZATION_ID", label="Організація", type="display", lov="organizations-all", span=6,
                   help="Організація документа-підстави (заповнюється під час запису)."),
              ref_field("WAREHOUSE_ID", "Склад", "WAREHOUSES_ORDER_SCHEME",
                        help="Лише склади з ознакою «Ордерна схема»."),
              dict(col="BIN_ID", label="Комірка розміщення", type="ref", span=6, required=False, cascade="WAREHOUSE_ID",
                   lov_sql=bin_lov, help="Підставляється в рядки без комірки під час заповнення й проведення "
                                         "(склад з адресним зберіганням)."),
              dict(col="BASIS_ID", label="Розпорядження", type="ref", span=12, required=True, cascade="WAREHOUSE_ID",
                   lov_sql=basis_lov,
                   help=f"Проведений документ менеджера з товарами {word} на складі "
                        + ("(надходження, повернення від клієнта, переміщення, комплектація …)." if rcv
                           else "(реалізація, повернення постачальнику, переміщення, списання …)."))]
    if not rcv:
        fields = [f for f in fields if f["col"] != "BIN_ID"]
    bin_col = dict(col="BIN_ID", heading="Комірка", kind="ref", lov="storage-bins-active", width=170,
                   help="Обов'язкова для складу з адресним зберіганням." + ("" if rcv else " Залишок комірки контролюється."))
    exp_col = dict(col="EXPECTED_QTY", heading="Очікується", kind="display", dtype="number", mask=Q3, width=110,
                   sql=f"trade_order_scheme.line_expected('{kind}', document_id, product_id, characteristic_id, series_id)")
    cols = [GOODS_COL, CHAR_COL, SERIES_COL, QTY_COL, bin_col, exp_col]
    if not rcv:
        cols.append(dict(col="BIN_QTY", heading="У комірці", kind="display", dtype="number", mask=Q3, width=100,
                         sql="trade_order_scheme.bin_qty(bin_id, product_id, characteristic_id, series_id, 'N')"))
    title = "Прибутковий ордер на товари" if rcv else "Видатковий ордер на товари"
    q3 = block("appearance", f"formatMask: {Q3}") + "\n"
    return dict(page=p, list_page=lp, alias="goods-receipt-order" if rcv else "goods-issue-order",
                list_alias="goods-receipt-orders" if rcv else "goods-issue-orders", table=("DOC_GOODS_RECEIPT_ORDER" if rcv else "DOC_GOODS_ISSUE_ORDER"),
                title=title, list_title="Прибуткові ордери на товари" if rcv else "Видаткові ордери на товари",
                list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.warehouse_name, d.basis_name, d.basis_state_name, "
                          "d.bin_name, d.total_qty, " + STATUS_SQL + ", d.doc_comment\n  from v_goods_order_list d\n"
                          f" where d.kind = '{kind}'"),
                list_cols=[("ORGANIZATION_NAME", "Організація"), ("WAREHOUSE_NAME", "Склад"), ("BASIS_NAME", "Розпорядження"),
                           ("BASIS_STATE_NAME", "Стан розпорядження")] + ([("BIN_NAME", "Комірка")] if rcv else [])
                          + [("TOTAL_QTY", "Кількість", "number", False, q3)],
                fields=fields, lines=dict(table=("DOC_GOODS_RECEIPT_ORDER_GOODS" if rcv else "DOC_GOODS_ISSUE_ORDER_GOODS"), title="Товари", cols=cols),
                scan=kind, scan_call="trade_order_scheme.scan",
                commands=[cmd("FILL_FROM_BASIS", "Заповнити за розпорядженням", f"trade_order_scheme.fill_from_basis('{kind}', #ID#);", "draft",
                              confirm=f"Замінити рядки товарами {word} за розпорядженням?",
                              success="Рядки заповнено за розпорядженням." + ("" if rcv else " Комірки підібрано за залишками."))],
                post="trade_order_scheme.post_" + ("receipt" if rcv else "issue"),
                unpost="trade_order_scheme.unpost_" + ("receipt" if rcv else "issue"),
                copy="trade_order_scheme.copy_" + ("receipt" if rcv else "issue"))


def r5_order_scheme_specs():
    for c in CATALOGS:
        if c["table"] == "REF_WAREHOUSE":
            c["list_sql"] = ("select id, code, name, case use_order_scheme when 'Y' then 'Так' end order_scheme_name, "
                             "case use_storage_bins when 'Y' then 'Так' end bins_name, " + STATE_SQL + " from ref_warehouse")
            c["columns"] = [("CODE", "Код"), ("NAME", "Найменування"), ("ORDER_SCHEME_NAME", "Ордерна схема"),
                            ("BINS_NAME", "Комірки"), ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="USE_ORDER_SCHEME", label="Ордерна схема", type="switch", span=6,
                     help="Документи менеджера лише оформлюють надходження / відвантаження; фактичне приймання й відпуск "
                          "товарів оформлює комірник прибутковими й видатковими ордерами. Вимикається, коли немає "
                          "незакритих розпоряджень і чернеток ордерів."),
                dict(col="USE_STORAGE_BINS", label="Адресне зберігання (комірки)", type="switch", span=6, newcol=True,
                     help="Облік товарів у комірках (стелаж-ярус-місце) — лише за ордерною схемою. "
                          "Вмикається за нульового залишку складу.")]
    CATALOGS.append(dict(list_page=550, form_page=551, alias="storage-bins", table="REF_STORAGE_BIN",
         title="Комірки складів", item_title="Комірка складу", edit_auth="role-warehouse",
         list_sql=("select id, code, warehouse_name, name, rack, tier, place, quantity, products_count, description, "
                   + STATE_SQL + " from v_storage_bin_list"),
         columns=[("CODE", "Код"), ("WAREHOUSE_NAME", "Склад"), ("NAME", "Адреса"), ("RACK", "Стелаж"), ("TIER", "Ярус"),
                  ("PLACE", "Місце"), ("QUANTITY", "Кількість товарів"), ("PRODUCTS_COUNT", "Позицій"), ("DESCRIPTION", "Опис"),
                  ("STATE_NAME", "Стан")],
         fields=[dict(col="WAREHOUSE_ID", label="Склад", type="ref", lov="WAREHOUSES_ACTIVE", required=True, span=12),
                 dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Адреса", type="text", max=100, span=9, newcol=True,
                      help="Порожньо — «стелаж-ярус-місце» (напр. A-01-03). Унікальна в межах складу."),
                 dict(col="RACK", label="Стелаж", type="text", max=20, span=4),
                 dict(col="TIER", label="Ярус", type="text", max=20, span=4, newcol=True),
                 dict(col="PLACE", label="Місце", type="text", max=20, span=4, newcol=True),
                 dict(col="DESCRIPTION", label="Опис", type="textarea", max=1000, span=12)]))
    DOCUMENTS.append(order_doc_spec("RECEIPT"))
    DOCUMENTS.append(order_doc_spec("SHIPMENT"))
    # Введення на підставі: «Створити прибутковий / видатковий ордер» у документах менеджера (роль «Комірник»)
    for d in DOCUMENTS:
        for kind, pages in ORDER_BASIS_PAGES.items():
            if d["page"] in pages:
                rcv = kind == "RECEIPT"
                d["commands"] = d.get("commands", []) + [
                    cmd("CREATE_RECEIPT_ORDER" if rcv else "CREATE_ISSUE_ORDER",
                        "Створити прибутковий ордер" if rcv else "Створити видатковий ордер",
                        f"trade_order_scheme.create_order('{kind}', #ID#)", "posted", target=561 if rcv else 571,
                        auth="role-warehouse")]


def r5_order_scheme_lovs():
    sql_lov("warehouses-order-scheme", "WAREHOUSES_ORDER_SCHEME",
            "select name d, id r\n  from ref_warehouse\n where state = 'ACTIVE' and use_order_scheme = 'Y'\n order by name")
    sql_lov("storage-bins-active", "STORAGE_BINS_ACTIVE",
            "select w.name || ': ' || b.name d, b.id r\n  from ref_storage_bin b join ref_warehouse w on w.id = b.warehouse_id\n"
            " where b.state = 'ACTIVE'\n order by w.name, b.name")


def goods_order_report_page():
    """F-WH-11: «Товари до надходження й відвантаження» — розпорядження, ключі, фактичні залишки, комірки, рухи."""
    q3 = block("appearance", f"formatMask: {Q3}") + "\n"
    dfmt = block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"
    basis_link = block("columnFormatting", 'htmlExpression: <a href="#BASIS_URL#">#BASIS_NAME#</a>') + "\n"
    basis_url = ("apex_page.get_url(p_page => b.basis_page_id, p_items => 'P' || b.basis_page_id || '_ID', "
                 "p_values => b.basis_id) basis_url")

    def basis_tab(ident, title, kind):
        return (ident, title,
                "select b.warehouse_name, b.basis_name, " + basis_url + ", b.basis_date, b.planned_qty, b.done_qty,\n"
                "       b.remaining_qty, b.state_name\n  from v_goods_order_basis b\n"
                f" where b.direction = '{kind}'\n order by b.basis_date desc",
                [("WAREHOUSE_NAME", "Склад"), ("BASIS_NAME", "Розпорядження", "varchar2", False, basis_link),
                 ("BASIS_URL", "URL", "varchar2", True), ("BASIS_DATE", "Дата", "date", False, dfmt),
                 ("PLANNED_QTY", "За документом", "number", False, q3),
                 ("DONE_QTY", "Прийнято" if kind == "RECEIPT" else "Відвантажено", "number", False, q3),
                 ("REMAINING_QTY", "Залишок", "number", False, q3), ("STATE_NAME", "Стан")])

    tabs = [basis_tab("receipts", "Очікується надходження", "RECEIPT"),
            basis_tab("shipments", "Розпорядження на відвантаження", "SHIPMENT"),
            ("by-product", "За товарами",
             "select v.direction_name, v.warehouse_name, v.product_code, v.product_name, v.characteristic_name, v.series_name,\n"
             "       v.unit_name, sum(v.planned_qty) planned_qty, sum(v.done_qty) done_qty, sum(v.remaining_qty) remaining_qty\n"
             "  from v_goods_order_balance v\n where v.remaining_qty <> 0\n"
             " group by v.direction_name, v.warehouse_name, v.product_code, v.product_name, v.characteristic_name, v.series_name, v.unit_name",
             [("DIRECTION_NAME", "Напрям"), ("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"),
              ("CHARACTERISTIC_NAME", "Характеристика"), ("SERIES_NAME", "Серія"), ("UNIT_NAME", "Од."),
              ("PLANNED_QTY", "За документами", "number", False, q3), ("DONE_QTY", "Оформлено ордерами", "number", False, q3),
              ("REMAINING_QTY", "Залишок", "number", False, q3)]),
            ("physical", "Фактичні залишки",
             "select s.warehouse_name, s.product_code, s.product_name, s.characteristic_name, s.series_name, s.unit_name,\n"
             "       s.book_qty, s.to_receive_qty, s.to_ship_qty, s.physical_qty\n  from v_order_scheme_stock s",
             [("WAREHOUSE_NAME", "Склад"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"), ("CHARACTERISTIC_NAME", "Характеристика"),
              ("SERIES_NAME", "Серія"), ("UNIT_NAME", "Од."), ("BOOK_QTY", "За обліком", "number", False, q3),
              ("TO_RECEIVE_QTY", "До надходження", "number", False, q3), ("TO_SHIP_QTY", "До відвантаження", "number", False, q3),
              ("PHYSICAL_QTY", "Фактично на складі", "number", False, q3)]),
            ("bins", "Товари в комірках",
             "select v.warehouse_name, v.bin_name, v.product_code, v.product_name, v.characteristic_name, v.series_name, v.unit_name, v.quantity\n"
             "  from v_bin_stock v\n order by v.warehouse_name, v.bin_name, v.product_name",
             [("WAREHOUSE_NAME", "Склад"), ("BIN_NAME", "Комірка"), ("PRODUCT_CODE", "Код"), ("PRODUCT_NAME", "Товар"),
              ("CHARACTERISTIC_NAME", "Характеристика"), ("SERIES_NAME", "Серія"), ("UNIT_NAME", "Од."),
              ("QUANTITY", "Кількість", "number", False, q3)]),
            ("movements", "Рухи",
             "select m.period, m.recorder_name, " + recorder_url_sql() + ",\n       m.register_name, m.direction_name, m.warehouse_name, m.bin_name,\n"
             "       m.product_name, m.characteristic_name, m.series_name, m.quantity, m.basis_name\n  from v_goods_order_movement m",
             [("PERIOD", "Період", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI:SS") + "\n"),
              ("RECORDER_NAME", "Реєстратор", "varchar2", False, RECORDER_LINK), ("RECORDER_URL", "URL", "varchar2", True),
              ("REGISTER_NAME", "Регістр"), ("DIRECTION_NAME", "Вид руху"), ("WAREHOUSE_NAME", "Склад"), ("BIN_NAME", "Комірка"),
              ("PRODUCT_NAME", "Товар"), ("CHARACTERISTIC_NAME", "Характеристика"), ("SERIES_NAME", "Серія"),
              ("QUANTITY", "Кількість", "number", False, q3), ("BASIS_NAME", "Розпорядження")])]
    tabs_report_page(580, "goods-order-scheme", "Товари до надходження й відвантаження", tabs)


def storekeeper_workplace_page():
    """F-WH-11: робоче місце комірника — завдання (незакриті розпорядження), оформлення ордера, ордери в роботі."""
    p = 590
    title = "Робоче місце комірника"
    body = page_header(p, title, "storekeeper-workplace", title)
    body += "\n" + title_region(title)
    bar = "name: Нове завдання\ntitle: Нове завдання\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "bar", bar)
    b = "type: selectList\n" + block("label", "label: Склад\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 3") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @warehouses-order-scheme\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: Усі ордерні склади") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_WH", b)
    task_sql = ("select b.direction_name || ': ' || b.basis_name || ' — ' || b.warehouse_name || ' (' || b.state_name\n"
                "       || ', залишок ' || rtrim(to_char(b.remaining_qty, 'FM999G999G990D999'), '.,') || ')' d, b.task_key r\n"
                "  from v_goods_order_basis b\n"
                f" where b.remaining_qty > 0 and (:P{p}_WH is null or b.warehouse_id = :P{p}_WH)\n order by b.basis_date")
    b = "type: popupLov\n" + block("label", "label: Розпорядження\nalignment: right") + "\n"
    b += block("layout", "sequence: 20\nregion: @bar\nslot: regionBody\ncolumnSpan: 6\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sqlQuery\nsqlQuery:" + code("sql", task_sql) + "\ndisplayExtraValues: false\ndisplayNullValue: true") + "\n"
    b += block("cascadingLov", f"parentItems: [\n    P{p}_WH\n]\nparentRequired: false") + "\n"
    b += block("settings", "displayAs: inlinePopup\ninitialFetch: auto\nmanualEntry: false") + "\n"
    b += block("help", "helpText: Документ менеджера з товарами до надходження або до відвантаження. «Оформити ордер» створює "
               "прибутковий / видатковий ордер, заповнений за розпорядженням (видатковий — з відбором по комірках).") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_TASK", b)
    for i, nm in enumerate(["NEW_ID", "NEW_KIND"]):
        nb = "type: hidden\n" + block("layout", f"sequence: {30 + i}\nregion: @bar\nslot: regionBody") + "\n"
        nb += block("sessionState", "dataType: varchar2\nstorage: request")
        body += "\n" + comp("pageItem", f"P{p}_{nm}", nb)
    body += "\n" + button("create-order", "CREATE_ORDER", "Оформити ордер", 40, "bar", slot="regionBody", hot=True, auth="role-warehouse")
    body += "\n" + button("apply", "APPLY", "Оновити", 50, "bar", slot="regionBody")
    body += "\n" + process("create-order", "Оформити ордер", "executeCode", 10,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql",
                               f":P{p}_NEW_ID := trade_order_scheme.create_task(:P{p}_TASK);\n"
                               f":P{p}_NEW_KIND := regexp_substr(:P{p}_TASK, '[^-]+', 1, 1);\n:P{p}_TASK := null;")) + "\n",
                           point="afterSubmit", when_button="create-order", success="Ордер створено за розпорядженням.")
    for seq, kind, tp in [(5, "RECEIPT", 561), (6, "SHIPMENT", 571)]:
        bb = f"name: До ордера ({kind})\n"
        bb += block("behavior", f"type: pageOrUrl\ntarget: {{\n    page: {tp}\n    clearCache: {tp}\n    items: {{\n        P{tp}_ID: &P{p}_NEW_ID.\n    }}\n}}") + "\n"
        bb += block("execution", f"sequence: {seq}\npoint: afterProcessing") + "\n"
        bb += block("serverSideCondition", f"type: expression\nlanguage: plsql\nplsqlExpression: :REQUEST = 'CREATE_ORDER' and :P{p}_NEW_KIND = '{kind}'") + "\n"
        body += "\n" + comp("branch", f"to-{kind.lower()}", bb)
    body += "\n" + branch("stay", "Залишитися", 20, f"{{\n    page: {p}\n}}")
    q3 = block("appearance", f"formatMask: {Q3}") + "\n"
    tasks_sql = ("select b.direction_name, b.warehouse_name, b.basis_name,\n"
                 "       apex_page.get_url(p_page => b.basis_page_id, p_items => 'P' || b.basis_page_id || '_ID', p_values => b.basis_id) basis_url,\n"
                 f"       apex_page.get_url(p_page => {p}, p_items => 'P{p}_TASK', p_values => b.task_key) pick_url,\n"
                 "       b.basis_date, b.planned_qty, b.done_qty, b.remaining_qty, b.state_name\n"
                 "  from v_goods_order_basis b\n"
                 f" where b.remaining_qty > 0 and (:P{p}_WH is null or b.warehouse_id = :P{p}_WH)\n order by b.basis_date")
    cols = [("DIRECTION_NAME", "Завдання"), ("WAREHOUSE_NAME", "Склад"),
            ("BASIS_NAME", "Розпорядження", "varchar2", False,
             block("columnFormatting", 'htmlExpression: <a href="#BASIS_URL#">#BASIS_NAME#</a>') + "\n"),
            ("BASIS_URL", "URL", "varchar2", True),
            ("PICK_URL", "​", "varchar2", False,
             block("columnFormatting", 'htmlExpression: <a href="#PICK_URL#" title="Вибрати завдання"><span class="fa fa-hand-pointer-o" aria-hidden="true"></span> Вибрати</a>') + "\n"),
            ("BASIS_DATE", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"),
            ("PLANNED_QTY", "За документом", "number", False, q3), ("DONE_QTY", "Оформлено", "number", False, q3),
            ("REMAINING_QTY", "Залишок", "number", False, q3), ("STATE_NAME", "Стан")]
    r = ir_region("tasks", "Завдання: незакриті розпорядження", tasks_sql, cols, seq=10, title="Завдання: незакриті розпорядження")
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_WH\n        ]\n        sqlQuery:", 1)
    body += "\n" + r
    orders_sql = ("select d.kind, case d.kind when 'RECEIPT' then 'Прибутковий ордер' else 'Видатковий ордер' end kind_name,\n"
                  "       d.doc_number, d.occurred_at, d.warehouse_name, d.basis_name, d.total_qty,\n"
                  "       apex_page.get_url(p_page => case d.kind when 'RECEIPT' then 561 else 571 end,\n"
                  "                         p_items => case d.kind when 'RECEIPT' then 'P561_ID' else 'P571_ID' end, p_values => d.id) doc_url\n"
                  "  from v_goods_order_list d\n"
                  f" where d.status = 'DRAFT' and (:P{p}_WH is null or d.warehouse_id = :P{p}_WH)\n order by d.occurred_at")
    cols = [("KIND", "kind", "varchar2", True), ("KIND_NAME", "Документ"),
            ("DOC_NUMBER", "Номер", "varchar2", False, block("columnFormatting", 'htmlExpression: <a href="#DOC_URL#">#DOC_NUMBER#</a>') + "\n"),
            ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"),
            ("WAREHOUSE_NAME", "Склад"), ("BASIS_NAME", "Розпорядження"), ("TOTAL_QTY", "Кількість", "number", False, q3),
            ("DOC_URL", "url", "varchar2", True)]
    r = ir_region("orders", "Ордери в роботі (чернетки): відкрийте ордер і скануйте товари", orders_sql, cols, seq=20,
                  title="Ордери в роботі (чернетки)")
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_WH\n        ]\n        sqlQuery:", 1)
    body += "\n" + r
    write(PAGES / f"p{p:05d}-storekeeper-workplace.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-FIN-06 «Валюти й курси валют» (RefCurrency, RegCurrencyRate, trade_currency)
# ===========================================================================
def r5_currency_specs():
    CATALOGS.append(dict(list_page=600, form_page=601, alias="currencies", table="REF_CURRENCY",
         title="Валюти", item_title="Валюта", edit_auth="role-cashier",
         list_sql=("select id, code, numeric_code, name, symbol, national_name, load_rates_name, current_rate, current_rate_date, "
                   "rates_count, " + STATE_SQL + " from v_currency_list"),
         columns=[("CODE", "Код ISO"), ("NUMERIC_CODE", "Цифровий код"), ("NAME", "Найменування"), ("SYMBOL", "Символ"),
                  ("NATIONAL_NAME", "Національна"), ("LOAD_RATES_NAME", "Курс НБУ"),
                  ("CURRENT_RATE", "Курс сьогодні", "number", False, block("appearance", "formatMask: FM999G990D0000") + "\n"),
                  ("CURRENT_RATE_DATE", "Дата курсу", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                  ("RATES_COUNT", "Записів курсу"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код ISO 4217", type="text", max=3, required=True, span=3,
                      help="3 латинські літери (UAH, USD, EUR). Код — ключ валюти в касах, рахунках і договорах; "
                           "після використання не змінюється."),
                 dict(col="NUMERIC_CODE", label="Цифровий код", type="text", max=3, span=3, newcol=True,
                      help="3 цифри ISO 4217 (980, 840, 978) — код r030 у даних НБУ."),
                 dict(col="SYMBOL", label="Символ", type="text", max=10, span=3, newcol=True),
                 dict(col="NAME", label="Найменування", type="text", max=100, required=True, span=12),
                 dict(col="LOAD_RATES", label="Завантажувати курс НБУ", type="switch", span=6,
                      help="Курс валюти щодня завантажується з bank.gov.ua (завдання TRADE_NBU_RATES) і кнопкою "
                           "«Завантажити курси НБУ» на сторінці «Курси валют». Для UAH не застосовується."),
                 dict(col="NOTE", label="Коментар", type="textarea", max=1000, span=12)]))


def r5_currency_lovs():
    # «currencies» з r4 (статичний список) тепер читає довідник «Валюти»
    sql_lov("currencies", "CURRENCIES",
            "select code || ' — ' || name d, code r\n  from ref_currency\n where state = 'ACTIVE'\n"
            " order by case code when 'UAH' then 0 else 1 end, code")
    sql_lov("currencies-foreign", "CURRENCIES_FOREIGN",
            "select code || ' — ' || name d, code r\n  from ref_currency\n where code <> 'UAH'\n order by code")


def currency_rates_page():
    """F-FIN-06: «Курси валют» — регістр відомостей (редагування) + завантаження з НБУ за період."""
    p = 610
    bar = "name: Завантаження курсів НБУ\ntitle: Завантаження курсів НБУ\ntype: staticContent\n"
    bar += block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body = "\n" + comp("region", "nbu", bar)
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(sysdate, 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {10 + i}\nregion: @nbu\nslot: regionBody\ncolumnSpan: 2" + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: request")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("load-nbu", "LOAD_NBU", "Завантажити курси НБУ", 30, "nbu", slot="regionBody", hot=True)
    plsql = (f"declare\n  l_n number;\nbegin\n"
             f"  l_n := trade_currency.load_nbu_period(coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate)),\n"
             f"                                        coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate)));\n"
             f"  apex_application.g_print_success_message := 'Завантажено курсів НБУ: ' || l_n || '.';\nend;")
    body += "\n" + process("load-nbu", "Завантажити курси НБУ", "executeCode", 20,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                            point="afterSubmit", when_button="load-nbu")
    editable_register_page(p, "currency-rates", "Курси валют", "REG_CURRENCY_RATE", [
        dict(col="CURRENCY_CODE", heading="Валюта", kind="select", lov="currencies-foreign", required=True, width=220),
        dict(col="RATE_DATE", heading="Дата", kind="date", dtype="date", mask="DD.MM.YYYY", required=True, width=120),
        dict(col="RATE", heading="Курс, грн", kind="number", dtype="number", mask="FM999G990D000000", required=True, width=130),
        dict(col="MULTIPLIER", heading="Кратність", kind="number", dtype="number", width=90),
        dict(col="SOURCE", heading="Джерело", kind="display", width=90),
        dict(col="NOTE", heading="Примітка", kind="text", width=220),
        dict(col="UPDATED_BY", heading="Змінив", kind="display", width=140),
    ], "rate_date desc, currency_code", extra_body=body)


# ===========================================================================
# r5 — F-TAX-01 «ПДВ і податкові накладні» (RefVatRate, DocTaxInvoice, RegVatLedger, trade_vat / trade_tax)
# ===========================================================================
VAT_DOC_TYPES = {51: "DocGoodsReceipt", 111: "DocGoodsSale", 281: "DocCustomerReturn", 291: "DocSupplierReturn",
                 321: "DocInvoiceForPayment"}
VAT_PRICE_MODES = [("Y", "Ціна включає ПДВ"), ("N", "ПДВ зверху ціни")]
TAX_DIRECTIONS = [("ISSUED", "Видана (податкове зобов'язання)"), ("RECEIVED", "Отримана (податковий кредит)")]
TAX_EVENT_KINDS = [("SHIPMENT", "Відвантаження"), ("PREPAYMENT", "Передоплата"), ("MANUAL", "Вручну")]
TAX_ERPN_STATUSES = [("NOT_SENT", "Не надіслано"), ("SENT", "Надіслано"), ("REGISTERED", "Зареєстровано"), ("REJECTED", "Відхилено")]
TAX_REASONS = [("02", "02 — постачання неплатнику податку"), ("07", "07 — вивезення товарів за межі митної території"),
               ("01", "01 — перевищення звичайної ціни"), ("03", "03 — у рахунок оплати праці")]
TAX_BASE_COMMANDS = {111: ("DocGoodsSale", "CREATE_TAX_INVOICE", "Створити податкову накладну"),
                     121: ("DocCustomerPayment", "CREATE_TAX_INVOICE", "Створити податкову накладну (передоплата)"),
                     371: ("DocCashReceipt", "CREATE_TAX_INVOICE", "Створити податкову накладну (передоплата)"),
                     51: ("DocGoodsReceipt", "CREATE_RECEIVED_TAX_INVOICE", "Зареєструвати отриману ПН")}


def r5_vat_specs():
    for c in CATALOGS:
        if c["table"] == "REF_PRODUCT":
            c["list_sql"] = c["list_sql"].replace(
                "select p.id,", "select p.id, (select r.name from ref_vat_rate r where r.code = p.vat_rate_code) vat_rate_name, p.uktzed_code,", 1)
            c["columns"] = [x for x in c["columns"] if x[0] != "STATE_NAME"] + [("VAT_RATE_NAME", "Ставка ПДВ"), ("UKTZED_CODE", "УКТ ЗЕД"),
                                                                              ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="VAT_RATE_CODE", label="Ставка ПДВ", type="select", lov="vat-rates-product", required=True, span=6,
                     default="type: static\nstaticValue: VAT20",
                     help="Ставка ПДВ товару за замовчуванням у документах (організація або постачальник — не платник ПДВ: «Без ПДВ»)."),
                dict(col="UKTZED_CODE", label="Код УКТ ЗЕД / ДКПП", type="text", max=10, span=6, newcol=True,
                     help="Код товару (УКТ ЗЕД) або послуги (ДКПП) для податкової накладної.")]
        elif c["table"] == "REF_PRICE_TYPE":
            c["list_sql"] = ("select id, code, name, currency_code, case price_includes_vat when 'Y' then 'Включає ПДВ' else 'ПДВ зверху' end "
                             "vat_mode_name, " + STATE_SQL + " from ref_price_type")
            c["columns"] = [("CODE", "Код"), ("NAME", "Найменування"), ("CURRENCY_CODE", "Валюта"), ("VAT_MODE_NAME", "ПДВ"),
                            ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="PRICE_INCLUDES_VAT", label="Ціна включає ПДВ", type="switch", span=6, default="type: static\nstaticValue: Y",
                     help="Режим цін нових документів за цим видом цін: ціна включає ПДВ або ПДВ нараховується зверху.")]
        elif c["table"] == "REF_COUNTERPARTY":
            c["list_sql"] = c["list_sql"].replace("select id, code, name,",
                                                  "select id, code, name, case vat_payer when 'Y' then vat_number end vat_number,", 1)
            c["columns"] = [x for x in c["columns"] if x[0] != "STATE_NAME"] + [("VAT_NUMBER", "ІПН (платник ПДВ)"), ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [
                dict(col="VAT_PAYER", label="Платник ПДВ", type="switch", span=4,
                     help="Постачання від неплатника — без ПДВ; податкова накладна неплатнику — з ІПН 100000000000 і типом причини 02."),
                dict(col="VAT_NUMBER", label="ІПН", type="text", max=12, span=8, newcol=True,
                     help="Індивідуальний податковий номер платника ПДВ — 12 цифр.")]
    for d in DOCUMENTS:
        p = d["page"]
        if p not in VAT_DOC_TYPES:
            continue
        ret = p in (281, 291)
        d["vat"] = True
        d["vat_type"] = VAT_DOC_TYPES[p]
        d["fields"] = d["fields"] + [
            dict(col="PRICE_INCLUDES_VAT", label="Ціни", type="display" if ret else "select", lov="vat-price-modes", span=3,
                 help=("Як у документа-підстави." if ret else
                       "Ціна включає ПДВ або ПДВ зверху. Порожньо — за видом цін (інакше «включає»). Зміна перераховує ПДВ рядків."))]
        cols = []
        for c in d["lines"]["cols"]:
            cols.append(c)
            if c["col"] == "AMOUNT":
                if ret:
                    cols.append(dict(col="VAT_RATE_NAME", heading="Ставка ПДВ", kind="display", width=110,
                                     sql="trade_vat.rate_name(vat_rate_code)"))
                else:
                    cols.append(dict(col="VAT_RATE_CODE", heading="Ставка ПДВ", kind="select", lov="vat-rates", width=130,
                                     help="Порожньо — ставка товару (організація / постачальник не платник — «Без ПДВ»)."))
                cols += [dict(col="VAT_AMOUNT", heading="Сума ПДВ", kind="display", dtype="number", mask=Q2, width=110),
                         dict(col="AMOUNT_WITH_VAT", heading="Всього", kind="display", dtype="number", mask=Q2, width=120)]
        d["lines"]["cols"] = cols
    # Податкова накладна
    ctr_lov = ("select o.name || ': ' || c.name || case when c.contract_number is not null then ' № ' || c.contract_number end d, c.id r\n"
               "  from ref_contract c join ref_counterparty o on o.id = c.owner_id\n"
               " where c.state = 'ACTIVE' and c.owner_id = :P#PAGE#_COUNTERPARTY_ID\n order by c.name")
    DOCUMENTS.append(dict(page=621, list_page=620, alias="tax-invoice", list_alias="tax-invoices", table="DOC_TAX_INVOICE",
        title="Податкова накладна", list_title="Податкові накладні", total=True, vat=True,
        list_sql=("select d.id, d.doc_number, d.occurred_at, d.organization_name, d.direction_name, d.counterparty_name, d.event_name, "
                  "d.base_name, d.ext_number, d.amount_without_vat, d.vat_amount, d.total_amount, d.erpn_status_name, d.erpn_reg_number, "
                  "d.erpn_deadline, d.erpn_overdue, " + STATUS_SQL + ", d.doc_comment\n  from v_tax_invoice_list d"),
        list_cols=[("ORGANIZATION_NAME", "Організація"), ("DIRECTION_NAME", "Вид"), ("COUNTERPARTY_NAME", "Контрагент"),
                   ("EVENT_NAME", "Перша подія"), ("BASE_NAME", "Підстава"), ("EXT_NUMBER", "№ постачальника"),
                   money_col("AMOUNT_WITHOUT_VAT", "Без ПДВ"), money_col("VAT_AMOUNT", "ПДВ"), money_col("TOTAL_AMOUNT", "З ПДВ"),
                   ("ERPN_STATUS_NAME", "ЄРПН"), ("ERPN_REG_NUMBER", "Реєстр. №"),
                   ("ERPN_DEADLINE", "Зареєструвати до", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
                   ("ERPN_OVERDUE", "Прострочено")],
        fields=[ORG_FIELD,
                dict(col="DIRECTION", label="Вид", type="select", lov="tax-directions", required=True, span=6, newcol=True,
                     default="type: static\nstaticValue: ISSUED"),
                ref_field("COUNTERPARTY_ID", "Контрагент", "COUNTERPARTIES_ACTIVE",
                          help="Покупець (видана ПН) або постачальник (отримана ПН)."),
                dict(col="CONTRACT_ID", label="Договір", type="ref", span=6, required=False, cascade="COUNTERPARTY_ID", lov_sql=ctr_lov),
                dict(col="EVENT_KIND", label="Перша подія", type="display", lov="tax-event-kinds", span=3),
                base_field("BASE_DOC_ID", "Підстава", span=9),
                dict(col="EXT_NUMBER", label="№ ПН постачальника", type="text", max=30, span=3,
                     help="Для отриманої ПН — порядковий номер податкової накладної постачальника (обов'язковий для проведення)."),
                dict(col="NOT_ISSUED_REASON", label="Не видається покупцю (тип причини)", type="select", lov="tax-not-issued-reasons", span=5,
                     help="Заповнюється автоматично: 02 — покупець не платник ПДВ, 07 — експорт (усі рядки 0 %)."),
                dict(col="BUYER_VAT_NUMBER", label="ІПН покупця", type="display", span=2),
                dict(col="SELLER_VAT_NUMBER", label="ІПН продавця", type="display", span=2),
                dict(col="ERPN_STATUS", label="Стан ЄРПН", type="display", lov="tax-erpn-statuses", span=3),
                dict(col="ERPN_REG_NUMBER", label="Реєстраційний № ЄРПН", type="display", span=3),
                dict(col="ERPN_REG_DATE", label="Дата реєстрації", type="display", dtype="date", format="DD.MM.YYYY", span=3),
                dict(col="AMOUNT_WITHOUT_VAT", label="Обсяг без ПДВ", type="display", dtype="number", format=Q2, span=3)],
        lines=dict(table="DOC_TAX_INVOICE_GOODS", title="Товари / послуги", cols=[
            dict(col="PRODUCT_ID", heading="Товар", kind="ref", lov="products-active", width=260,
                 help="Необов'язково: опис, код УКТ ЗЕД, одиниця й ставка підставляються з товару."),
            dict(col="DESCRIPTION", heading="Опис постачання", kind="text", max=500, width=300),
            dict(col="UKTZED_CODE", heading="УКТ ЗЕД / ДКПП", kind="text", max=10, width=110),
            dict(col="UNIT_NAME", heading="Од.", kind="text", max=20, width=60),
            QTY_COL,
            dict(col="PRICE", heading="Ціна без ПДВ", kind="number", dtype="number", mask=Q2, required=True),
            dict(col="VAT_RATE_CODE", heading="Ставка ПДВ", kind="select", lov="vat-rates-product", width=130),
            dict(col="AMOUNT", heading="Обсяг без ПДВ", kind="display", dtype="number", mask=Q2, width=130),
            dict(col="VAT_AMOUNT", heading="Сума ПДВ", kind="display", dtype="number", mask=Q2, width=110)]),
        extra_items=[dict(name="ERPN_NUMBER", label="Реєстраційний № ЄРПН", span=4, when="posted")],
        commands=[cmd("ERPN_SENT", "Надіслано в ЄРПН", "trade_tax.set_erpn(#ID#, 'SENT');", "posted",
                      success="Позначено: податкову накладну надіслано на реєстрацію."),
                  cmd("ERPN_REGISTERED", "Зареєстровано в ЄРПН", "trade_tax.set_erpn(#ID#, 'REGISTERED', :P621_ERPN_NUMBER);", "posted",
                      success="Позначено: податкову накладну зареєстровано в ЄРПН."),
                  cmd("ERPN_REJECTED", "Відхилено ЄРПН", "trade_tax.set_erpn(#ID#, 'REJECTED');", "posted",
                      confirm="Позначити реєстрацію як відхилену?", success="Позначено: реєстрацію відхилено."),
                  cmd("DOWNLOAD_XML", "Вивантажити XML (ЄРПН)", "trade_tax.download_xml(#ID#);", "posted")],
        post="trade_tax.post", unpost="trade_tax.unpost", copy="trade_tax.copy"))
    by_page = {d["page"]: d for d in DOCUMENTS}
    for pg, (typ, name, label) in TAX_BASE_COMMANDS.items():
        x = by_page[pg]
        x["commands"] = [c for c in x.get("commands", []) if c["name"] != name] + [
            cmd(name, label, f"trade_tax.create_from_base('{typ}', #ID#)", "posted", target=621, auth="role-tax")]


def r5_vat_lovs():
    sql_lov("vat-rates", "VAT_RATES", "select name d, code r\n  from ref_vat_rate\n order by sort_order")
    sql_lov("vat-rates-product", "VAT_RATES_PRODUCT",
            "select name d, code r\n  from ref_vat_rate\n where code <> 'NOVAT'\n order by sort_order")
    static_lov("vat-price-modes", "VAT_PRICE_MODES", VAT_PRICE_MODES)
    static_lov("tax-directions", "TAX_DIRECTIONS", TAX_DIRECTIONS)
    static_lov("tax-event-kinds", "TAX_EVENT_KINDS", TAX_EVENT_KINDS)
    static_lov("tax-erpn-statuses", "TAX_ERPN_STATUSES", TAX_ERPN_STATUSES)
    static_lov("tax-not-issued-reasons", "TAX_NOT_ISSUED_REASONS", TAX_REASONS)


def tax_register_page():
    """F-TAX-01: «Реєстр податкових накладних» — зведення ПДВ, ПН періоду, події першої події без ПН."""
    p = 630
    body = page_header(p, "Реєстр податкових накладних", "tax-invoice-register", "Реєстр податкових накладних")
    body += "\n" + title_region("Реєстр податкових накладних")
    bar = "name: Відбір\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "bar", bar)
    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(trunc(sysdate, 'MM'), 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {10 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 2" + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + org_filter_item(p, "bar", 20, span=3)
    body += "\n" + button("apply", "APPLY", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("generate", "GENERATE", "Створити ПН за першою подією", 50, "bar", slot="regionBody",
                          confirm="Створити й провести податкові накладні за всіма подіями періоду без ПН?")
    frm = f"coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate, 'MM'))"
    to = f"coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate))"
    plsql = (f"declare\n  l_n number;\nbegin\n  l_n := trade_tax.generate({frm}, {to}, :P{p}_ORG, 'Y');\n"
             "  apex_application.g_print_success_message := 'Створено й проведено податкових накладних: ' || l_n || '.';\nend;")
    body += "\n" + process("generate", "Створити ПН за першою подією", "executeCode", 10,
                            block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                            point="afterSubmit", when_button="generate")
    sb = "name: Зведення ПДВ\ntitle: Зведення ПДВ за період\ntype: dynamicContent\n"
    sb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_tax.register_html({frm}, {to}, :P{p}_ORG);")) + "\n"
    sb += block("layout", "sequence: 10\nslot: body") + "\n"
    sb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "summary", sb)
    items = f"        pageItemsToSubmit: [\n            P{p}_FROM\n            P{p}_TO\n            P{p}_ORG\n        ]\n        sqlQuery:"
    m2 = block("appearance", f"formatMask: {Q2}") + "\n"
    sql = ("select d.id, d.occurred_at, d.doc_number, d.organization_name, d.direction_name, d.counterparty_name,\n"
           "       case when d.direction = 'ISSUED' then d.buyer_vat_number else d.seller_vat_number end vat_number,\n"
           "       d.event_name, d.base_name, d.ext_number, d.amount_without_vat, d.vat_amount, d.total_amount, d.status_name,\n"
           "       d.erpn_status_name, d.erpn_reg_number, d.erpn_deadline, d.erpn_overdue,\n"
           "       apex_page.get_url(p_page => 621, p_items => 'P621_ID', p_values => d.id) doc_url\n"
           "  from v_tax_invoice_list d\n"
           f" where d.occurred_at >= {frm} and d.occurred_at < {to} + 1\n"
           f"   and (:P{p}_ORG is null or d.organization_id = :P{p}_ORG)\n"
           " order by d.direction, d.occurred_at, d.doc_number")
    cols = [("ID", "ID", "varchar2", True),
            ("OCCURRED_AT", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
            ("DOC_NUMBER", "Номер", "varchar2", False, block("columnFormatting", 'htmlExpression: <a href="#DOC_URL#">#DOC_NUMBER#</a>') + "\n"),
            ("ORGANIZATION_NAME", "Організація"), ("DIRECTION_NAME", "Вид"), ("COUNTERPARTY_NAME", "Контрагент"), ("VAT_NUMBER", "ІПН"),
            ("EVENT_NAME", "Перша подія"), ("BASE_NAME", "Підстава"), ("EXT_NUMBER", "№ постачальника"),
            ("AMOUNT_WITHOUT_VAT", "Без ПДВ", "number", False, m2), ("VAT_AMOUNT", "ПДВ", "number", False, m2),
            ("TOTAL_AMOUNT", "З ПДВ", "number", False, m2), ("STATUS_NAME", "Статус"), ("ERPN_STATUS_NAME", "ЄРПН"),
            ("ERPN_REG_NUMBER", "Реєстр. №"), ("ERPN_DEADLINE", "Зареєструвати до", "date", False, block("appearance", "formatMask: DD.MM.YYYY") + "\n"),
            ("ERPN_OVERDUE", "Прострочено"), ("DOC_URL", "url", "varchar2", True)]
    r = ir_region("invoices", "Податкові накладні періоду", sql, cols, seq=20, title="Податкові накладні періоду")
    body += "\n" + r.replace("        sqlQuery:", items, 1)
    sql2 = ("select e.event_date, e.doc_id, r.recorder_name doc_name, o.name organization_name, c.name counterparty_name,\n"
            "       case e.event_kind when 'SHIPMENT' then 'Відвантаження' else 'Оплата' end event_name,\n"
            "       e.event_amount, e.base_amount, e.invoiced_amount, e.remaining_amount,\n"
            "       apex_page.get_url(p_page => r.page_id, p_items => 'P' || r.page_id || '_ID', p_values => e.doc_id) doc_url\n"
            f"  from table(trade_tax.events({frm}, {to}, :P{p}_ORG)) e\n"
            "  join ref_organization o on o.id = e.organization_id\n  join ref_counterparty c on c.id = e.counterparty_id\n"
            "  left join v_recorder r on r.recorder_type = e.doc_type and r.recorder_id = e.doc_id\n"
            " where e.remaining_amount > 0\n order by e.event_date")
    cols2 = [("EVENT_DATE", "Дата", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"),
             ("DOC_ID", "ID", "varchar2", True),
             ("DOC_NAME", "Документ", "varchar2", False, block("columnFormatting", 'htmlExpression: <a href="#DOC_URL#">#DOC_NAME#</a>') + "\n"),
             ("ORGANIZATION_NAME", "Організація"), ("COUNTERPARTY_NAME", "Контрагент"), ("EVENT_NAME", "Подія"),
             ("EVENT_AMOUNT", "Сума події", "number", False, m2), ("BASE_AMOUNT", "Зобов'язання (перша подія)", "number", False, m2),
             ("INVOICED_AMOUNT", "Оформлено ПН", "number", False, m2), ("REMAINING_AMOUNT", "Без ПН", "number", False, m2),
             ("DOC_URL", "url", "varchar2", True)]
    r = ir_region("open-events", "Події без податкової накладної", sql2, cols2, seq=30, title="Події без податкової накладної")
    body += "\n" + r.replace("        sqlQuery:", items, 1)
    write(PAGES / f"p{p:05d}-tax-invoice-register.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-RET-01 «Роздрібні продажі: РМК, чек ККМ, ПРРО» (RefCashRegister, DocRetailReceipt, db/43)
# ===========================================================================
FISCAL_STATUSES = [("PENDING", "Не фіскалізовано"), ("FISCALIZED", "Фіскалізовано"), ("NOT_FISCAL", "Нефіскальний")]
PRRO_PROVIDERS = [("STUB", "Імітація (без ДПС)"), ("CHECKBOX", "Checkbox (не підключено)"), ("DPS", "ПРРО ДПС (не підключено)")]


def r5_retail_specs():
    desk_lov = ("select name d, id r\n  from ref_cash_desk\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by code")
    bank_lov = ("select name d, id r\n  from ref_bank_account\n"
                " where state = 'ACTIVE' and currency_code = 'UAH' and organization_id = :P#PAGE#_ORGANIZATION_ID\n order by name")
    CATALOGS.append(dict(list_page=640, form_page=641, alias="cash-registers", table="REF_CASH_REGISTER",
         title="Каси ККМ", item_title="Каса ККМ", edit_auth="role-cashier", dialog_width=900,
         list_sql=("select id, code, name, organization_name, warehouse_name, cash_desk_name, bank_account_name, price_type_name, "
                   "fiscal_name, fiscal_number, provider_name, fiscal_seq, " + STATE_SQL + " from v_cash_register_list"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("ORGANIZATION_NAME", "Організація"), ("WAREHOUSE_NAME", "Склад"),
                  ("CASH_DESK_NAME", "Каса (готівка)"), ("BANK_ACCOUNT_NAME", "Рахунок (картки)"), ("PRICE_TYPE_NAME", "Вид цін"),
                  ("FISCAL_NAME", "Фіскальна"), ("FISCAL_NUMBER", "ФН ПРРО"), ("PROVIDER_NAME", "ПРРО"),
                  ("FISCAL_SEQ", "Фіскальних чеків", "number"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True),
                 dict(ORG_FIELD, help="Організація — власник каси ККМ; каса й рахунок — лише цієї організації."),
                 dict(col="WAREHOUSE_ID", label="Склад", type="ref", lov="WAREHOUSES_ACTIVE", required=True, span=6, newcol=True,
                      help="Склад, з якого продається товар (без ордерної схеми)."),
                 dict(col="CASH_DESK_ID", label="Каса (готівкова виручка)", type="ref", required=True, span=6,
                      cascade="ORGANIZATION_ID", lov_sql=desk_lov,
                      help="Каса організації в UAH: чек збільшує її залишок на суму, оплачену готівкою (без решти)."),
                 dict(col="BANK_ACCOUNT_ID", label="Рахунок для оплат карткою", type="ref", required=False, span=6, newcol=True,
                      cascade="ORGANIZATION_ID", lov_sql=bank_lov,
                      help="До підключення еквайрингу оплата карткою зараховується на цей рахунок; порожньо — оплата карткою "
                           "не рухає грошові кошти (попередження при проведенні)."),
                 dict(col="PRICE_TYPE_ID", label="Вид цін", type="ref", lov="PRICE_TYPES_ACTIVE", required=True, span=6,
                      default="type: expression\nlanguage: plsql\nplsqlExpression: trade_retail.retail_price_type",
                      help="Роздрібні ціни чеків (ціни включають ПДВ)."),
                 dict(col="CUSTOMER_ID", label="Роздрібний покупець", type="ref", lov="COUNTERPARTIES_ACTIVE", required=True, span=6,
                      newcol=True, default="type: expression\nlanguage: plsql\nplsqlExpression: trade_retail.retail_customer",
                      help="Контрагент, на якого записуються роздрібні продажі (регістр «Продажі»)."),
                 dict(col="IS_FISCAL", label="Фіскальна (ПРРО)", type="switch", span=3,
                      default="type: static\nstaticValue: Y",
                      help="Чеки фіскалізуються програмним РРО. Вимкнено — нефіскальні чеки (напр. ФОП без обов'язку РРО)."),
                 dict(col="FISCAL_NUMBER", label="Фіскальний номер ПРРО", type="text", max=10, span=3, newcol=True,
                      help="10 цифр — номер, присвоєний ДПС під час реєстрації ПРРО."),
                 dict(col="PRRO_PROVIDER", label="Провайдер ПРРО", type="select", lov="prro-providers", required=True, span=3,
                      newcol=True, default="type: static\nstaticValue: STUB",
                      help="Зараз доступна лише імітація: фіскальний номер чека формується локально, до ДПС нічого не "
                           "передається. Інтеграція з Checkbox / ПРРО ДПС — окреме завдання."),
                 dict(col="FISCAL_SEQ", label="Фіскальних чеків", type="display", dtype="number", span=3, newcol=True,
                      query_only=True),
                 dict(col="NOTE", label="Коментар", type="textarea", max=1000, span=12)]))
    m2 = block("appearance", f"formatMask: {Q2}") + "\n"
    vat_name = dict(col="VAT_NAME", heading="Ставка ПДВ", kind="display", width=110, sql="trade_vat.rate_name(vat_rate_code)")
    DOCUMENTS.append(dict(page=651, list_page=650, alias="retail-receipt", list_alias="retail-receipts", table="DOC_RETAIL_RECEIPT",
         title="Чек ККМ", list_title="Чеки ККМ", total=True, vat=True, scan="RETAIL_RECEIPT", scan_call="trade_retail.doc_scan",
         series_type="DocRetailReceipt",
         list_sql=("select d.id, d.organization_name, d.doc_number, d.occurred_at, d.cash_register_name, d.kind_name, "
                   "d.total_amount, d.vat_amount, d.paid_cash, d.paid_card, d.change_amount, d.fiscal_status_name, d.fiscal_number, "
                   "d.cashier_name, " + STATUS_SQL + ", d.doc_comment\n  from v_retail_receipt_list d"),
         list_cols=[("ORGANIZATION_NAME", "Організація"), ("CASH_REGISTER_NAME", "Каса ККМ"), ("KIND_NAME", "Вид"),
                    ("TOTAL_AMOUNT", "Сума", "number", False, m2), ("VAT_AMOUNT", "ПДВ", "number", False, m2),
                    ("PAID_CASH", "Готівкою", "number", False, m2), ("PAID_CARD", "Карткою", "number", False, m2),
                    ("CHANGE_AMOUNT", "Решта", "number", False, m2), ("FISCAL_STATUS_NAME", "ПРРО"),
                    ("FISCAL_NUMBER", "Фіскальний номер"), ("CASHIER_NAME", "Касир")],
         fields=[dict(col="CASH_REGISTER_ID", label="Каса ККМ", type="ref", lov="CASH_REGISTERS_ACTIVE", required=True, span=6,
                      default="type: expression\nlanguage: plsql\nplsqlExpression: trade_retail.default_register",
                      help="Організація, склад, каса, вид цін і роздрібний покупець беруться з каси ККМ."),
                 dict(col="ORGANIZATION_ID", label="Організація", type="display", lov="organizations-all", span=6, query_only=True),
                 dict(col="WAREHOUSE_ID", label="Склад", type="display", lov="warehouses-all", span=6, query_only=True),
                 dict(col="CASH_DESK_ID", label="Каса", type="display", lov="cash-desks-active", span=6, query_only=True),
                 dict(col="PAID_CASH", label="Отримано готівкою", type="number", dtype="number", format=Q2, span=3,
                      help="Порожньо й без картки — оплата готівкою без решти."),
                 dict(col="PAID_CARD", label="Оплата карткою", type="number", dtype="number", format=Q2, span=3,
                      help="Не більше суми чека."),
                 dict(col="CHANGE_AMOUNT", label="Решта", type="display", dtype="number", format=Q2, span=3, query_only=True),
                 dict(col="CASHIER_NAME", label="Касир", type="display", span=3, query_only=True),
                 dict(col="FISCAL_STATUS", label="ПРРО", type="display", lov="fiscal-statuses", span=3, query_only=True),
                 dict(col="FISCAL_NUMBER", label="Фіскальний номер чека", type="display", span=3, query_only=True),
                 dict(col="FISCAL_AT", label="Фіскалізовано", type="display", dtype="date", format="DD.MM.YYYY HH24:MI:SS", span=3,
                      query_only=True),
                 dict(col="FISCAL_URL", label="Перевірка чека", type="display", span=3, query_only=True)],
         lines=dict(table="DOC_RETAIL_RECEIPT_GOODS", title="Товари",
                    cols=[PRODUCT_COL, CHAR_COL, SERIES_COL, QTY_COL,
                          dict(col="PRICE", heading="Ціна", kind="number", dtype="number", mask=Q2,
                               help="Порожньо — роздрібна ціна виду цін каси ККМ на дату чека (включає ПДВ)."),
                          AMOUNT_COL, vat_name,
                          dict(col="VAT_AMOUNT", heading="у т. ч. ПДВ", kind="display", dtype="number", mask=Q2, width=110),
                          dict(col="COST_AMOUNT", heading="Собівартість", kind="display", dtype="number", mask=Q2, width=120)]),
         commands=[cmd("FILL_SERIES", "Підібрати серії (FEFO)", "trade_series.fill_fefo('DocRetailReceipt', #ID#);", "draft",
                       success="Серії підібрано за FEFO (першим спливає — першим відвантажено).")],
         post_success="Чек проведено.",
         unpost_confirm="Скасувати проведення чека? Фіскалізований чек скасувати не можна — лише чеком повернення.",
         post="trade_retail.post", unpost="trade_retail.unpost", copy="trade_retail.copy"))


def r5_retail_lovs():
    static_lov("fiscal-statuses", "FISCAL_STATUSES", FISCAL_STATUSES)
    static_lov("prro-providers", "PRRO_PROVIDERS", PRRO_PROVIDERS)
    sql_lov("cash-registers-active", "CASH_REGISTERS_ACTIVE",
            "select r.name || ' (' || o.name || ')' d, r.id r\n"
            "  from ref_cash_register r join ref_organization o on o.id = r.organization_id\n"
            " where r.state = 'ACTIVE'\n order by r.code")


def cashier_workplace_page():
    """F-RET-01: робоче місце касира — каса ККМ, сканер, кошик, оплата готівкою / карткою / змішана, решта, друк чека."""
    p = 660
    title = "Робоче місце касира (РМК)"
    body = page_header(p, title, "cashier-workplace", title)
    body += "\n" + title_region(title)

    def region(ident, name, seq, template="standard", extra=""):
        b = f"name: {name}\ntitle: {name}\ntype: staticContent\n" + block("layout", f"sequence: {seq}\nslot: body") + "\n"
        b += block("appearance", f"template: @/{template}\ntemplateOptions: #DEFAULT#") + extra
        return "\n" + comp("region", ident, b)

    def hidden(name, seq, region_id, storage, protected=True):
        b = "type: hidden\n" + block("layout", f"sequence: {seq}\nregion: @{region_id}\nslot: regionBody") + "\n"
        if not protected:
            b += block("settings", "valueProtected: false") + "\n"
        b += block("sessionState", f"dataType: varchar2\nstorage: {storage}")
        return "\n" + comp("pageItem", f"P{p}_{name}", b)

    def text_item(name, label, seq, region_id, span, placeholder, new_row=True, attrs='autocomplete="off"'):
        b = "type: textField\n" + block("label", f"label: {label}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @{region_id}\nslot: regionBody\ncolumnSpan: {span}"
                   + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", f"template: @/optional-above\ntemplateOptions: #DEFAULT#\nvaluePlaceholder: {placeholder}") + "\n"
        b += block("advanced", f"customAttributes: {attrs}") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: request")
        return "\n" + comp("pageItem", f"P{p}_{name}", b)

    # --- каса ККМ
    body += region("bar", "Каса ККМ", 5)
    b = "type: selectList\n" + block("label", "label: Каса ККМ\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @bar\nslot: regionBody\ncolumnSpan: 6") + "\n"
    b += block("appearance", "template: @/optional-above\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("lov", "type: sharedComponent\nlov: @cash-registers-active\ndisplayExtraValues: false\ndisplayNullValue: true\nnullDisplayValue: — виберіть касу ККМ —") + "\n"
    b += block("default", "type: expression\nlanguage: plsql\nplsqlExpression: trade_retail.default_register") + "\n"
    b += block("help", "helpText: Каса ККМ визначає організацію, склад, касу для готівки, роздрібні ціни й ПРРО. "
               "Незавершений чек користувача на касі відкривається автоматично.") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_REGISTER", b)
    body += hidden("RECEIPT", 20, "bar", "session")
    body += hidden("LAST", 21, "bar", "session")
    body += hidden("LINE", 22, "bar", "request", protected=False)
    body += hidden("CHANGE", 23, "bar", "request")
    da = "name: Змінити касу ККМ\n" + block("when", f"event: change\nselectionType: items\nitems: P{p}_REGISTER") + "\n"
    da += block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "submit", "name: Оновити\naction: submitPage\n" + block("settings", "requestButtonName: REGISTER\nshowProcessing: true")
               + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "change-register", da)

    # --- сканер
    body += region("scan", "Товар", 10, template="standard")
    body += text_item("SCAN", "Штрихкод / артикул / код", 10, "scan", 8,
                      "Відскануйте або введіть і натисніть Enter («3*код» — кількість 3)", attrs='autocomplete="off" autofocus')
    body += "\n" + button("scan", "SCAN", "Додати (Enter)", 20, "scan", slot="regionBody", hot=True)

    # --- кошик
    cb = "name: Чек\ntitle: Чек\ntype: dynamicContent\n"
    cb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql", f"return trade_retail.cart_html(:P{p}_RECEIPT);")) + "\n"
    cb += block("layout", "sequence: 20\nslot: body") + "\n"
    cb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "cart", cb)

    # --- оплата
    body += region("pay", "Оплата", 30)
    body += text_item("CASH", "Отримано готівкою, грн", 10, "pay", 3, "порожньо — без решти", attrs='autocomplete="off" inputmode="decimal"')
    body += text_item("CARD", "Карткою, грн", 20, "pay", 3, "для змішаної оплати", new_row=False,
                      attrs='autocomplete="off" inputmode="decimal"')
    has_rcpt = f"type: itemIsNotNull\nitem: P{p}_RECEIPT"
    body += "\n" + button("pay-cash", "PAY_CASH", "Оплата готівкою", 30, "pay", slot="regionBody", hot=True, condition=has_rcpt)
    body += "\n" + button("pay-card", "PAY_CARD", "Оплата карткою", 40, "pay", slot="regionBody", condition=has_rcpt)
    body += "\n" + button("pay-mixed", "PAY_MIXED", "Змішана оплата", 50, "pay", slot="regionBody", condition=has_rcpt)
    body += "\n" + button("cancel-receipt", "CANCEL_RECEIPT", "Скасувати чек", 60, "pay", slot="regionBody", condition=has_rcpt,
                          confirm="Видалити поточний (неоплачений) чек?")

    # --- останній чек
    lb = "name: Останній чек\ntitle: Останній чек\ntype: dynamicContent\n"
    lb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_retail.last_html(:P{p}_LAST)\n"
        f"    || '<p style=\"margin-top:8px\"><a class=\"t-Button t-Button--hot\" href=\"'\n"
        f"    || apex_page.get_url(p_page => 900, p_items => 'P900_ID', p_values => :P{p}_LAST) || '\">Друк чека</a> '\n"
        f"    || '<a class=\"t-Button\" href=\"' || apex_page.get_url(p_page => 651, p_items => 'P651_ID', p_values => :P{p}_LAST)\n"
        f"    || '\">Відкрити чек</a></p>';")) + "\n"
    lb += block("layout", "sequence: 40\nslot: body") + "\n"
    lb += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
    lb += block("serverSideCondition", f"type: itemIsNotNull\nitem: P{p}_LAST")
    body += "\n" + comp("region", "last", lb)

    # --- процеси
    def proc(ident, name, seq, plsql, req, success=None, point="afterSubmit"):
        return "\n" + process(ident, name, "executeCode", seq, block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                              point=point, when_request_in=req, success=success)
    body += "\n" + process("init", "Відкрита чернетка", "executeCode", 10,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql",
                               f"if :P{p}_RECEIPT is not null then\n"
                               f"  select max(id) into :P{p}_RECEIPT from doc_retail_receipt where id = :P{p}_RECEIPT and status = 'DRAFT';\n"
                               f"end if;\n"
                               f"if :P{p}_RECEIPT is null and :P{p}_REGISTER is not null then\n"
                               f"  :P{p}_RECEIPT := trade_retail.open_draft(:P{p}_REGISTER);\nend if;")) + "\n",
                           point="beforeHeader")
    body += proc("register", "Змінити касу ККМ", 10, f":P{p}_RECEIPT := trade_retail.open_draft(:P{p}_REGISTER);\n:P{p}_LAST := null;", "REGISTER")
    body += proc("scan", "Сканер", 20,
                 f"if :P{p}_REGISTER is null then\n  trade_nsi.fail('CASH_REGISTER_REQUIRED', 'Виберіть касу ККМ.');\nend if;\n"
                 f":P{p}_RECEIPT := trade_retail.scan(:P{p}_REGISTER, :P{p}_RECEIPT, :P{p}_SCAN);\n:P{p}_SCAN := null;", "SCAN")
    body += proc("line-inc", "Збільшити кількість", 30, f"trade_retail.change_qty(:P{p}_LINE, 1);", "LINE_INC")
    body += proc("line-dec", "Зменшити кількість", 31, f"trade_retail.change_qty(:P{p}_LINE, -1);", "LINE_DEC")
    body += proc("line-del", "Видалити рядок", 32, f"trade_retail.delete_line(:P{p}_LINE);", "LINE_DEL")
    pay_tail = (f"  :P{p}_LAST := :P{p}_RECEIPT;\n  :P{p}_RECEIPT := null; :P{p}_CASH := null; :P{p}_CARD := null;\n"
                f"  select to_char(change_amount, 'FM999G999G990D00') into :P{p}_CHANGE from doc_retail_receipt where id = :P{p}_LAST;\n"
                "  :TRADE_WARN := trade_warn.take;\n")
    for seq, (req, cash, card) in enumerate([
            ("PAY_CASH", f"trade_retail.parse_amount(:P{p}_CASH)", "null"),
            ("PAY_CARD", "null", f"trade_retail.receipt_total(:P{p}_RECEIPT)"),
            ("PAY_MIXED", f"trade_retail.parse_amount(:P{p}_CASH)", f"trade_retail.parse_amount(:P{p}_CARD)")]):
        body += proc(req.lower().replace("_", "-"), f"Оплата ({req})", 40 + seq,
                     f"begin\n  trade_warn.clear;\n  trade_retail.pay(:P{p}_RECEIPT, {cash}, {card});\n" + pay_tail + "end;",
                     req, success=f"Чек оплачено. Решта: &P{p}_CHANGE. грн. &TRADE_WARN.")
    body += proc("cancel-receipt", "Скасувати чек", 50, f"trade_retail.cancel_receipt(:P{p}_RECEIPT);\n:P{p}_RECEIPT := null;",
                 "CANCEL_RECEIPT", success="Чек скасовано.")
    body += "\n" + branch("stay", "Залишитися", 10, f"{{\n    page: {p}\n}}")
    write(PAGES / f"p{p:05d}-cashier-workplace.apx", comp("page", str(p), body))


# ===========================================================================
# r5 — F-SRV-06 «Імпорт довідників» (trade_import, db/44)
# ===========================================================================
IMPORT_KINDS = [("PRODUCT", "Номенклатура (зі штрихкодами й цінами)"), ("COUNTERPARTY", "Контрагенти"),
                ("UNIT", "Одиниці виміру"), ("GROUP", "Групи номенклатури"), ("BARCODE", "Штрихкоди"),
                ("PRICE", "Ціни номенклатури (документ «Встановлення цін»)")]
IMPORT_MODES = [("CREATE_UPDATE", "Створювати нові й оновлювати існуючі"), ("CREATE_ONLY", "Лише створювати нові"),
                ("UPDATE_ONLY", "Лише оновлювати існуючі")]
IMPORT_CHARSETS = [("AL32UTF8", "UTF-8"), ("CL8MSWIN1251", "Windows-1251 (CSV з Excel)")]


def r5_import_lovs():
    static_lov("import-kinds", "IMPORT_KINDS", IMPORT_KINDS)
    static_lov("import-modes", "IMPORT_MODES", IMPORT_MODES)
    static_lov("import-charsets", "IMPORT_CHARSETS", IMPORT_CHARSETS)


def catalog_import_page():
    """F-SRV-06: майстер імпорту довідників — файл CSV/XLSX, зіставлення колонок, перевірка, виконання, звіт помилок."""
    p = 670
    title = "Імпорт довідників"
    body = page_header(p, title, "catalog-import", title)
    body += "\n" + title_region(title)
    has_sess = f"type: itemIsNotNull\nitem: P{p}_SESSION"

    def region(ident, name, seq, rtype="staticContent", source="", cond=None):
        b = f"name: {name}\ntitle: {name}\ntype: {rtype}\n" + source
        b += block("layout", f"sequence: {seq}\nslot: body") + "\n"
        b += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
        if cond:
            b += block("serverSideCondition", cond) + "\n"
        return "\n" + comp("region", ident, b)

    def html(plsql):
        return block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql", plsql)) + "\n"

    def select(name, label, lov, seq, span, new_row, null_disp=None, dflt=None, help_text=None):
        b = "type: selectList\n" + block("label", f"label: {label}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @params\nslot: regionBody\ncolumnSpan: {span}"
                   + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", "template: @/optional-above\ntemplateOptions: #DEFAULT#") + "\n"
        lv = f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\ndisplayNullValue: {'true' if null_disp else 'false'}"
        if null_disp:
            lv += f"\nnullDisplayValue: {null_disp}"
        b += block("lov", lv) + "\n"
        if dflt:
            b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        if help_text:
            b += block("help", f"helpText: {help_text}") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        return "\n" + comp("pageItem", f"P{p}_{name}", b)

    # --- крок 1: параметри й файл
    body += region("params", "1. Файл і параметри", 10)
    body += select("KIND", "Що завантажувати", "import-kinds", 10, 4, True, null_disp="— виберіть довідник —")
    body += select("MODE", "Режим", "import-modes", 20, 4, False, dflt="CREATE_UPDATE",
                   help_text="Існуючі елементи шукаються за кодом, далі — за артикулом / штрихкодом (номенклатура), "
                             "ЄДРПОУ (контрагенти), скороченням (одиниці), назвою в межах батьківської групи (групи). "
                             "Порожня клітинка під час оновлення не змінює значення.")
    body += select("CHARSET", "Кодування CSV", "import-charsets", 30, 4, False, dflt="AL32UTF8",
                   help_text="Для XLSX не має значення. CSV, збережений з Excel «CSV (роздільники — коми)», зазвичай у Windows-1251.")
    body += select("PRICE_TYPE", "Вид цін", "price-types-active", 40, 4, True, null_disp="— з колонки «Вид цін» —",
                   help_text="Для цін у файлі номенклатури та цін: створюється й проводиться документ «Встановлення цін» "
                             "(окремий на кожен вид цін).")
    b = "type: datePicker\n" + block("label", "label: Дата цін\nalignment: right") + "\n"
    b += block("layout", "sequence: 50\nregion: @params\nslot: regionBody\ncolumnSpan: 3\nstartNewRow: false") + "\n"
    b += block("appearance", "template: @/optional-above\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY\nvaluePlaceholder: поточна дата") + "\n"
    b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
    b += block("sessionState", "dataType: varchar2\nstorage: session")
    body += "\n" + comp("pageItem", f"P{p}_PRICE_DATE", b)
    b = "type: fileUpload\n" + block("label", "label: Файл (CSV, TXT, XLSX)\nalignment: right") + "\n"
    b += block("layout", "sequence: 60\nregion: @params\nslot: regionBody\ncolumnSpan: 8") + "\n"
    b += block("appearance", "template: @/optional-above\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("display", "displayAs: inlineFileBrowse") + "\n"
    b += block("storage", "type: appTempFiles\npurgeFileAt: endOfRequest\nallowMultipleFiles: false\nfileTypes: .csv,.txt,.tsv,.xlsx") + "\n"
    b += block("help", "helpText: Перший рядок — заголовки колонок, далі — дані (до 10 000 рядків). XLSX — перший аркуш. "
               "Роздільник CSV (; , табуляція) визначається автоматично.")
    body += "\n" + comp("pageItem", f"P{p}_FILE", b)
    for i, nm in enumerate(["SESSION", "STATUS"]):
        hb = "type: hidden\n" + block("layout", f"sequence: {70 + i}\nregion: @params\nslot: regionBody") + "\n"
        hb += block("settings", "valueProtected: false") + "\n"
        hb += block("sessionState", f"dataType: varchar2\nstorage: {'session' if nm == 'SESSION' else 'request'}")
        body += "\n" + comp("pageItem", f"P{p}_{nm}", hb)
    body += "\n" + button("load", "LOAD", "Завантажити й перевірити", 80, "params", slot="regionBody", hot=True, icon="fa-upload")
    body += "\n" + button("template", "TEMPLATE", "Шаблон CSV", 90, "params", slot="regionBody", icon="fa-download",
                          condition=f"type: itemIsNotNull\nitem: P{p}_KIND")
    body += "\n" + button("new", "NEW", "Новий імпорт", 100, "params", slot="regionBody", condition=has_sess)
    da = "name: Змінити довідник\n" + block("when", f"event: change\nselectionType: items\nitems: P{p}_KIND") + "\n"
    da += block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "submit", "name: Оновити\naction: submitPage\n" + block("settings", "requestButtonName: KIND\nshowProcessing: true")
               + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "change-kind", da)

    body += region("format", "Колонки файлу", 15, "dynamicContent", html(f"return trade_import.fields_html(:P{p}_KIND);"),
                   cond=f"type: expression\nplsqlExpression: :P{p}_KIND is not null and :P{p}_SESSION is null")

    # --- крок 2–3: стан, зіставлення, перевірка, виконання
    body += region("summary", "2. Стан імпорту", 20, "dynamicContent", html(f"return trade_import.summary_html(:P{p}_SESSION);"),
                   cond=has_sess)
    body += "\n" + button("apply", "APPLY", "Виконати імпорт", 10, "summary", slot="regionBody", hot=True, icon="fa-check",
                          confirm="Записати дані файлу в довідник? Рядки з помилками буде пропущено.",
                          condition=f"type: expression\nplsqlExpression: :P{p}_STATUS = 'CHECKED'")
    body += "\n" + button("errors", "ERRORS", "Звіт помилок (CSV)", 20, "summary", slot="regionBody", icon="fa-file-text-o",
                          condition=f"type: expression\nplsqlExpression: :P{p}_STATUS in ('CHECKED', 'APPLIED')")
    body += region("mapping", "3. Зіставлення колонок", 30, "dynamicContent", html(f"return trade_import.mapping_html(:P{p}_SESSION);"),
                   cond=has_sess)
    body += "\n" + button("check", "CHECK", "Перевірити", 10, "mapping", slot="regionBody", icon="fa-search",
                          condition=f"type: expression\nplsqlExpression: :P{p}_STATUS in ('LOADED', 'CHECKED')")

    icon = block("columnFormatting", "htmlExpression: <span class=\"fa #ICON_CLASS#\" aria-hidden=\"true\"></span>") + "\n"
    cols = [("ICON", "​", "varchar2", False, icon), ("ICON_CLASS", "icon", "varchar2", True),
            ("ROW_NO", "Рядок", "number"), ("ACTION_NAME", "Дія"), ("KEY_TEXT", "Ключ"), ("MATCH_BY_NAME", "Знайдено за"),
            ("RESULT_NAME", "Результат"), ("MESSAGE", "Повідомлення"), ("ROW_TEXT", "Дані рядка")]
    sql = ("select ' ' icon, icon_class, row_no, action_name, key_text, match_by_name, result_name, message, row_text\n"
           f"  from v_import_row\n where session_id = :P{p}_SESSION\n order by row_no")
    r = ir_region("rows", "4. Рядки файлу (попередній перегляд і звіт помилок)", sql, cols, seq=40,
                  title="4. Рядки файлу (попередній перегляд і звіт помилок)")
    r = r.replace("        sqlQuery:", f"        pageItemsToSubmit: [\n            P{p}_SESSION\n        ]\n        sqlQuery:", 1)
    r = r.replace("\n    link {", "\n    serverSideCondition {\n        type: itemIsNotNull\n        item: P" + str(p) + "_SESSION\n    }\n    link {", 1)
    body += "\n" + r

    link = (f"linkColumn: customTarget\ntarget: {{\n    page: {p}\n    clearCache: {p}\n    items: {{\n        P{p}_SESSION: #ID#\n    }}\n}}\n"
            "linkIcon: <span class=\"fa fa-folder-open-o\" aria-hidden=\"true\" title=\"Відкрити\"></span>")
    hcols = [("ID", "ID", "varchar2", True),
             ("CREATED_AT", "Завантажено", "date", False, block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"),
             ("CREATED_BY", "Користувач"), ("KIND_NAME", "Довідник"), ("FILE_NAME", "Файл"), ("MODE_NAME", "Режим"),
             ("STATUS_NAME", "Стан"), ("TOTAL_ROWS", "Рядків", "number"), ("CREATED_CNT", "Створено", "number"),
             ("UPDATED_CNT", "Оновлено", "number"), ("PRICE_CNT", "Цін", "number"), ("SKIPPED_CNT", "Пропущено", "number"),
             ("ERROR_CNT", "Помилок", "number")]
    hsql = ("select id, cast(created_at as date) created_at, created_by, kind_name, file_name, mode_name, status_name,\n"
            "       total_rows, created_cnt, updated_cnt, price_cnt, skipped_cnt, error_cnt\n"
            "  from v_import_session\n order by created_at desc")
    body += "\n" + ir_region("history", "Історія імпорту", hsql, hcols, seq=50, link=link, title="Історія імпорту")

    def proc(ident, name, seq, plsql, req, success=None, point="afterSubmit"):
        return "\n" + process(ident, name, "executeCode", seq, block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                              point=point, when_request_in=req, success=success)
    body += "\n" + process("init", "Параметри сеансу імпорту", "executeCode", 10,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql",
                               f"for s in (select * from sys_import_session where id = :P{p}_SESSION) loop\n"
                               f"  :P{p}_KIND := s.import_kind;\n  :P{p}_MODE := s.import_mode;\n"
                               f"  :P{p}_PRICE_TYPE := s.price_type_id;\n  :P{p}_PRICE_DATE := to_char(s.price_date, 'DD.MM.YYYY');\n"
                               f"  :P{p}_STATUS := s.status;\nend loop;\n"
                               f"if :P{p}_STATUS is null then\n  :P{p}_SESSION := null;\nend if;")) + "\n",
                           point="beforeHeader")
    body += proc("kind", "Змінити довідник", 10, f":P{p}_SESSION := null;", "KIND")
    body += proc("load", "Завантажити файл", 20,
                 "declare\n  l_blob blob;\n  l_name varchar2(400);\nbegin\n"
                 f"  select max(blob_content), max(filename) into l_blob, l_name from apex_application_temp_files where name = :P{p}_FILE;\n"
                 "  if l_blob is null then\n    trade_nsi.fail('IMPORT_FILE_EMPTY', 'Виберіть файл для завантаження.');\n  end if;\n"
                 f"  :P{p}_SESSION := trade_import.load_file(:P{p}_KIND, :P{p}_MODE, l_name, l_blob, :P{p}_CHARSET,\n"
                 f"                                       :P{p}_PRICE_TYPE, to_date(:P{p}_PRICE_DATE, 'DD.MM.YYYY'));\n"
                 "  begin\n"
                 f"    trade_import.check_rows(:P{p}_SESSION);\n"
                 "  exception when others then\n    null;   -- обов'язкові колонки не зіставлено: користувач зіставить вручну\n  end;\nend;",
                 "LOAD", success="Файл завантажено. Перевірте зіставлення колонок і рядки, потім натисніть «Виконати імпорт».")
    body += proc("check", "Зіставлення й перевірка", 30,
                 "for i in 1 .. apex_application.g_f02.count loop\n"
                 f"  trade_import.set_mapping(:P{p}_SESSION, to_number(apex_application.g_f02(i)), apex_application.g_f01(i));\nend loop;\n"
                 f"trade_import.set_options(:P{p}_SESSION, :P{p}_MODE, :P{p}_PRICE_TYPE, to_date(:P{p}_PRICE_DATE, 'DD.MM.YYYY'));\n"
                 f"trade_import.check_rows(:P{p}_SESSION);",
                 "CHECK", success="Перевірку виконано.")
    body += proc("apply", "Виконати імпорт", 40, f"trade_import.apply(:P{p}_SESSION);", "APPLY",
                 success="Імпорт виконано. Результат кожного рядка — у таблиці «Рядки файлу».")
    body += proc("template", "Шаблон CSV", 50, f"trade_import.download_template(:P{p}_KIND);", "TEMPLATE")
    body += proc("errors", "Звіт помилок", 60, f"trade_import.download_errors(:P{p}_SESSION);", "ERRORS")
    body += proc("new", "Новий імпорт", 70, f":P{p}_SESSION := null;", "NEW")
    body += "\n" + branch("stay", "Залишитися", 10, f"{{\n    page: {p}\n}}")
    write(PAGES / f"p{p:05d}-catalog-import.apx", comp("page", str(p), body))


# =============================================================================
# r7 — F-INT-04 «EDI з торговими мережами» (trade_edi, db/47): GLN, точки доставки, журнал EDI (сторінка 700)
EDI_ORDER_COMMANDS = {261: [("EDI_ORDRSP", "EDI: підтвердження ORDRSP", "trade_edi.ordrsp_from_order(#ID#)", "posted")],
                      111: [("EDI_DESADV", "EDI: відвантаження DESADV", "trade_edi.desadv_from_sale(#ID#)", "posted"),
                            ("EDI_INVOIC", "EDI: рахунок INVOIC", "trade_edi.invoic_from_sale(#ID#)", "posted")]}


def r7_edi_specs():
    gln_help = ("Глобальний номер розташування GS1 (13 цифр, остання — контрольна). За ним EDI-повідомлення мереж "
                "зіставляються з довідниками.")
    for c in CATALOGS:
        if c["table"] == "REF_COUNTERPARTY":
            c["list_sql"] = c["list_sql"].replace("select id, code, name,", "select id, code, name, gln,", 1)
            c["columns"] = [x for x in c["columns"] if x[0] != "STATE_NAME"] + [("GLN", "GLN"), ("STATE_NAME", "Стан")]
            c["fields"] = c["fields"] + [dict(col="GLN", label="GLN (EDI)", type="text", max=13, span=4, help=gln_help)]
        elif c["table"] == "REF_ORGANIZATION":
            c["fields"] = c["fields"] + [dict(col="GLN", label="GLN (EDI)", type="text", max=13, span=6,
                                              help=gln_help + " Для організації — GLN постачальника в повідомленнях мереж.")]
    CATALOGS.append(dict(list_page=710, form_page=711, alias="delivery-points", table="REF_DELIVERY_POINT",
         title="Точки доставки (GLN)", item_title="Точка доставки", edit_auth="role-sales", dialog_width=900,
         list_sql=("select id, code, name, gln, counterparty_name, counterparty_gln, address, warehouse_name, price_type_name, "
                   + STATE_SQL + " from v_delivery_point_list"),
         columns=[("CODE", "Код"), ("NAME", "Найменування"), ("GLN", "GLN"), ("COUNTERPARTY_NAME", "Контрагент (мережа)"),
                  ("COUNTERPARTY_GLN", "GLN мережі"), ("ADDRESS", "Адреса"), ("WAREHOUSE_NAME", "Склад відвантаження"),
                  ("PRICE_TYPE_NAME", "Вид цін"), ("STATE_NAME", "Стан")],
         fields=[dict(col="CODE", label="Код", type="text", max=9, span=3, help="Порожній код буде призначено автоматично."),
                 dict(col="NAME", label="Найменування", type="text", max=255, required=True, span=9, newcol=True,
                      help="Магазин або розподільчий центр мережі."),
                 dict(col="COUNTERPARTY_ID", label="Контрагент (мережа)", type="ref", lov="COUNTERPARTIES_ACTIVE", required=True, span=6),
                 dict(col="GLN", label="GLN точки доставки", type="text", max=13, required=True, span=6, newcol=True,
                      help="DELIVERYPLACE у повідомленнях ORDERS / DESADV / INVOIC / RECADV. 13 цифр з контрольною цифрою."),
                 dict(col="ADDRESS", label="Адреса", type="text", max=500, span=12),
                 dict(col="WAREHOUSE_ID", label="Склад відвантаження", type="ref", lov="WAREHOUSES_ACTIVE", required=False, span=6,
                      help="Склад нових замовлень клієнта з EDI для цієї точки. Порожньо — перший активний склад."),
                 dict(col="PRICE_TYPE_ID", label="Вид цін", type="ref", lov="PRICE_TYPES_ACTIVE", required=False, span=6, newcol=True,
                      help="Ціни замовлень з EDI. Порожньо — вид цін договору, інакше ціна з файлу мережі."),
                 dict(col="NOTE", label="Коментар", type="textarea", max=1000, span=12)]))
    dp_lov = ("select name || ' (' || gln || ')' d, id r\n  from ref_delivery_point\n"
              " where state = 'ACTIVE' and counterparty_id = :P#PAGE#_CUSTOMER_ID\n order by name")
    by_page = {d["page"]: d for d in DOCUMENTS}
    o = by_page[261]
    o["fields"] = o["fields"] + [
        dict(col="DELIVERY_POINT_ID", label="Точка доставки", type="ref", span=6, required=False, cascade="CUSTOMER_ID",
             lov_sql=dp_lov, help="Магазин / РЦ мережі (GLN) — DELIVERYPLACE у повідомленнях EDI."),
        dict(col="EXT_ORDER_NUMBER", label="№ замовлення мережі", type="text", max=35, span=3,
             help="Номер замовлення покупця (ORDERS), повертається в ORDRSP / DESADV / INVOIC."),
        dict(col="EXT_ORDER_DATE", label="Дата замовлення мережі", type="date", dtype="date", format="DD.MM.YYYY", date_only=True,
             span=3)]
    for pg, cmds in EDI_ORDER_COMMANDS.items():
        x = by_page[pg]
        names = [c[0] for c in cmds]
        x["commands"] = [c for c in x.get("commands", []) if c["name"] not in names] + [
            cmd(name, label, plsql, when, target=700, auth="role-sales") for name, label, plsql, when in cmds]



def edi_page():
    """F-INT-04: «EDI: обмін з торговими мережами» — завантаження вхідних, картка повідомлення, дії, журнал."""
    p = 700
    title = "EDI: обмін з торговими мережами"
    body = page_header(p, title, "edi-exchange", title)
    body += "\n" + title_region(title)
    has_id = f"type: itemIsNotNull\nitem: P{p}_ID"

    def region(ident, name, seq, rtype="staticContent", source="", cond=None):
        b = f"name: {name}\ntitle: {name}\ntype: {rtype}\n" + source
        b += block("layout", f"sequence: {seq}\nslot: body") + "\n"
        b += block("appearance", "template: @/standard\ntemplateOptions: #DEFAULT#") + "\n"
        if cond:
            b += block("serverSideCondition", cond) + "\n"
        return "\n" + comp("region", ident, b)

    def expr(e):
        return f"type: expression\nplsqlExpression: {e}"

    body += region("upload", "Вхідний файл (ORDERS, RECADV)", 10)
    b = "type: fileUpload\n" + block("label", "label: XML-файл від мережі / провайдера\nalignment: right") + "\n"
    b += block("layout", "sequence: 10\nregion: @upload\nslot: regionBody\ncolumnSpan: 8") + "\n"
    b += block("appearance", "template: @/optional-above\ntemplateOptions: #DEFAULT#") + "\n"
    b += block("display", "displayAs: inlineFileBrowse") + "\n"
    b += block("storage", "type: appTempFiles\npurgeFileAt: endOfRequest\nallowMultipleFiles: false\nfileTypes: .xml") + "\n"
    b += block("help", "helpText: Формат EDI-XML (структура EDIN / Вчасно.EDI): корінь ORDER (замовлення) або RECADV "
               "(повідомлення про приймання). Покупець, точка доставки й постачальник зіставляються за GLN, товари — за "
               "штрихкодом (упаковка — кількість × кратність), далі за кодом постачальника (артикул / код).")
    body += "\n" + comp("pageItem", f"P{p}_FILE", b)
    for i, nm in enumerate(["ID", "STATUS", "DIR", "TYPE", "NEW_ID"]):
        hb = "type: hidden\n" + block("layout", f"sequence: {20 + i}\nregion: @upload\nslot: regionBody") + "\n"
        hb += block("settings", "valueProtected: false") + "\n"
        hb += block("sessionState", f"dataType: varchar2\nstorage: {'session' if nm == 'ID' else 'request'}")
        body += "\n" + comp("pageItem", f"P{p}_{nm}", hb)
    body += "\n" + button("load", "LOAD", "Завантажити", 30, "upload", slot="regionBody", hot=True, icon="fa-upload")
    body += "\n" + button("sample", "SAMPLE_ORDERS", "Демо-файл ORDERS", 40, "upload", slot="regionBody", icon="fa-flask")

    body += region("message", "Повідомлення", 20, "dynamicContent",
                   block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql", f"return trade_edi.message_html(:P{p}_ID);")) + "\n",
                   cond=has_id)
    acts = [("create-order", "CREATE_ORDER", "Створити замовлення клієнта", True, "fa-plus",
             f":P{p}_DIR = 'IN' and :P{p}_TYPE = 'ORDERS' and :P{p}_STATUS = 'NEW'", None),
            ("reprocess", "REPROCESS", "Повторити зіставлення", False, "fa-refresh",
             f":P{p}_DIR = 'IN' and :P{p}_STATUS in ('NEW', 'ERROR')", None),
            ("send", "SEND", "Надіслати провайдеру", True, "fa-paper-plane",
             f":P{p}_DIR = 'OUT' and :P{p}_STATUS = 'GENERATED'", "Надіслати повідомлення через провайдера EDI?"),
            ("download", "DOWNLOAD", "Вивантажити XML", False, "fa-download", f":P{p}_ID is not null", None),
            ("sample-recadv", "SAMPLE_RECADV", "Імітувати RECADV мережі", False, "fa-flask",
             f":P{p}_DIR = 'OUT' and :P{p}_TYPE = 'DESADV' and :P{p}_STATUS in ('GENERATED', 'SENT')", None),
            ("cancel", "CANCEL", "Скасувати", False, "fa-ban", f":P{p}_STATUS in ('NEW', 'ERROR', 'GENERATED')",
             "Скасувати повідомлення? Скасоване не обробляється й не надсилається."),
            ("close", "CLOSE", "Закрити", False, None, f":P{p}_ID is not null", None)]
    for i, (ident, name, label, hot, icon, cond, confirm) in enumerate(acts):
        body += "\n" + button(ident, name, label, 10 + i * 10, "message", slot="regionBody", hot=hot, icon=icon,
                              condition=expr(cond), confirm=confirm)

    icon = block("columnFormatting", "htmlExpression: <span class=\"fa #ICON_CLASS#\" aria-hidden=\"true\"></span>") + "\n"
    link = (f"linkColumn: customTarget\ntarget: {{\n    page: {p}\n    clearCache: {p}\n    items: {{\n        P{p}_ID: #ID#\n    }}\n}}\n"
            "linkIcon: <span class=\"fa fa-folder-open-o\" aria-hidden=\"true\" title=\"Відкрити\"></span>")
    dt = block("appearance", "formatMask: DD.MM.YYYY HH24:MI") + "\n"
    d1 = block("appearance", "formatMask: DD.MM.YYYY") + "\n"
    cols = [("ID", "ID", "varchar2", True), ("ICON", "​", "varchar2", False, icon), ("ICON_CLASS", "icon", "varchar2", True),
            ("MSG_NO", "№", "number"), ("CREATED_AT", "Створено", "date", False, dt), ("DIRECTION_NAME", "Напрям"),
            ("MSG_TYPE", "Тип"), ("STATUS_NAME", "Стан"), ("DOC_NUMBER", "№ документа"), ("DOC_DATE", "Дата", "date", False, d1),
            ("ORDER_NUMBER", "№ замовлення мережі"), ("COUNTERPARTY_NAME", "Контрагент"), ("DELIVERY_POINT_NAME", "Точка доставки"),
            ("CUSTOMER_ORDER_NUMBER", "Замовлення клієнта"), ("SALE_NUMBER", "Реалізація"), ("LINE_COUNT", "Рядків", "number"),
            ("ERROR_COUNT", "Помилок", "number"), ("DIFF_COUNT", "Розбіжностей", "number"), money_col("TOTAL_AMOUNT", "Сума"),
            ("PROVIDER_CODE", "Провайдер"), ("FILE_NAME", "Файл"), ("CREATED_BY", "Користувач")]
    sql = ("select id, ' ' icon, icon_class, msg_no, created_at, direction_name, msg_type, status_name, doc_number, doc_date,\n"
           "       order_number, counterparty_name, delivery_point_name, customer_order_number, sale_number, line_count,\n"
           "       error_count, diff_count, total_amount, provider_code, file_name, created_by\n"
           "  from v_edi_message\n order by msg_no desc")
    body += "\n" + ir_region("journal", "Журнал EDI-повідомлень", sql, cols, seq=30, link=link, title="Журнал EDI-повідомлень")

    def proc(ident, name, seq, plsql, req, success=None, point="afterSubmit"):
        return "\n" + process(ident, name, "executeCode", seq, block("source", "language: plsql\nplsqlCode:" + code("plsql", plsql)) + "\n",
                              point=point, when_request_in=req, success=success)
    body += "\n" + process("init", "Стан повідомлення", "executeCode", 10,
                           block("source", "language: plsql\nplsqlCode:" + code("plsql",
                               f":P{p}_STATUS := null;\n:P{p}_DIR := null;\n:P{p}_TYPE := null;\n"
                               f"for m in (select status, direction, msg_type from sys_edi_message where id = :P{p}_ID) loop\n"
                               f"  :P{p}_STATUS := m.status;\n  :P{p}_DIR := m.direction;\n  :P{p}_TYPE := m.msg_type;\nend loop;\n"
                               f"if :P{p}_STATUS is null then\n  :P{p}_ID := null;\nend if;")) + "\n",
                           point="beforeHeader")
    body += proc("load", "Завантажити файл", 10,
                 "declare\n  l_blob blob;\n  l_name varchar2(400);\nbegin\n"
                 f"  select max(blob_content), max(filename) into l_blob, l_name from apex_application_temp_files where name = :P{p}_FILE;\n"
                 "  if l_blob is null then\n    trade_nsi.fail('EDI_FILE_EMPTY', 'Виберіть XML-файл для завантаження.');\n  end if;\n"
                 f"  :P{p}_ID := trade_edi.load_file(l_name, l_blob);\nend;",
                 "LOAD", success="Файл завантажено й зіставлено з довідниками. Перевірте стан повідомлення.")
    body += proc("sample", "Демо-файл ORDERS", 20, f":P{p}_ID := trade_edi.load_sample('ORDERS');", "SAMPLE_ORDERS",
                 success="Завантажено демо-замовлення мережі (ORDERS).")
    body += proc("create-order", "Створити замовлення клієнта", 30, f":P{p}_NEW_ID := trade_edi.create_order(:P{p}_ID);",
                 "CREATE_ORDER", success="Створено замовлення клієнта (чернетка). Перевірте й проведіть його.")
    body += proc("reprocess", "Повторити зіставлення", 40, f"trade_edi.reprocess(:P{p}_ID);", "REPROCESS",
                 success="Повідомлення зіставлено повторно.")
    body += proc("send", "Надіслати", 50, f"trade_edi.send(:P{p}_ID);", "SEND", success="Повідомлення надіслано провайдеру EDI.")
    body += proc("download", "Вивантажити XML", 60, f"trade_edi.download(:P{p}_ID);", "DOWNLOAD")
    body += proc("sample-recadv", "Імітувати RECADV", 70, f":P{p}_ID := trade_edi.load_sample('RECADV', :P{p}_ID);", "SAMPLE_RECADV",
                 success="Завантажено RECADV (імітація: нестача 1 од. першої позиції).")
    body += proc("cancel", "Скасувати", 80, f"trade_edi.cancel(:P{p}_ID);", "CANCEL", success="Повідомлення скасовано.")
    body += proc("close", "Закрити", 90, f":P{p}_ID := null;", "CLOSE")
    body += "\n" + branch("to-order", "До замовлення клієнта", 10,
                          f"{{\n    page: 261\n    clearCache: 261\n    items: {{\n        P261_ID: &P{p}_NEW_ID.\n    }}\n}}",
                          when_request_in="CREATE_ORDER")
    body += "\n" + branch("stay", "Залишитися", 20, f"{{\n    page: {p}\n}}")
    write(PAGES / f"p{p:05d}-edi-exchange.apx", comp("page", str(p), body))



# ===========================================================================
# r6 — F-WH-26 «Ваги й габарити товарів» (trade_cargo, db/48): вага, об'єм, габарити номенклатури,
# підсумок у формах документів, звіт «Вага й об'єм документів» (сторінка 720)
# ===========================================================================
CARGO_DOCS = {111: "DocGoodsSale", 261: "DocCustomerOrder", 321: "DocInvoiceForPayment", 131: "DocGoodsTransfer",
              51: "DocGoodsReceipt", 271: "DocSupplierOrder", 281: "DocCustomerReturn", 291: "DocSupplierReturn",
              571: "DocGoodsIssueOrder"}


def r6_weights_specs():
    for c in CATALOGS:
        if c["table"] == "REF_PRODUCT":
            fl = c["fields"]
            i = next(n for n, f in enumerate(fl) if f["col"] == "WEIGHT_KG")
            fl[i] = dict(fl[i], help="Вага одиниці товару (базової одиниці виміру). Для одиниць «кг», «г», «т» без значення "
                                     "береться з одиниці виміру.")
            fl[i + 1:i + 1] = [
                dict(col="VOLUME_M3", label="Об'єм, м³", type="number", dtype="number", format="FM999G990D000000", span=4,
                     newcol=True, help="Об'єм одиниці товару. Якщо задано всі три габарити, розраховується автоматично "
                                       "(Д × Ш × В / 1 000 000); для «л», «м3» без значення — з одиниці виміру."),
                dict(col="LENGTH_CM", label="Довжина, см", type="number", dtype="number", format="FM999G990D0", span=4),
                dict(col="WIDTH_CM", label="Ширина, см", type="number", dtype="number", format="FM999G990D0", span=4, newcol=True),
                dict(col="HEIGHT_CM", label="Висота, см", type="number", dtype="number", format="FM999G990D0", span=4, newcol=True)]
            marker = " from ref_product p join"
            assert c["list_sql"].count(marker) == 1
            c["list_sql"] = c["list_sql"].replace(marker, ", p.weight_kg, p.volume_m3" + marker)
            cols = [x for x in c["columns"] if x[0] != "STATE_NAME"]
            c["columns"] = cols + [("WEIGHT_KG", "Вага, кг"), ("VOLUME_M3", "Об'єм, м³")] + \
                [x for x in c["columns"] if x[0] == "STATE_NAME"]
    for d in DOCUMENTS:
        if d["page"] in CARGO_DOCS:
            d["cargo"] = CARGO_DOCS[d["page"]]


def cargo_lovs():
    static_lov("cargo-directions", "CARGO_DIRECTIONS",
               [("OUT", "Відвантаження"), ("IN", "Надходження"), ("MOVE", "Переміщення")])
    static_lov("cargo-doc-types", "CARGO_DOC_TYPES",
               [("DocGoodsSale", "Реалізація товарів"), ("DocCustomerOrder", "Замовлення клієнта"),
                ("DocGoodsIssueOrder", "Видатковий ордер на товари"), ("DocSupplierReturn", "Повернення постачальнику"),
                ("DocGoodsTransfer", "Переміщення товарів"), ("DocGoodsReceipt", "Прибуткова накладна"),
                ("DocSupplierOrder", "Замовлення постачальнику"), ("DocCustomerReturn", "Повернення від клієнта"),
                ("DocInvoiceForPayment", "Рахунок на оплату")])
    static_lov("cargo-status", "CARGO_STATUS", [("N", "Усі (з чернетками)"), ("Y", "Лише проведені")])


def cargo_page():
    """F-WH-26: вага й об'єм документів за період для планування доставки, завантаження транспорту; друк."""
    p = 720
    body = page_header(p, "Вага й об'єм документів", "cargo-weight-volume", "Вага й об'єм документів")
    body += "\n" + title_region("Вага й об'єм документів")
    bar = "name: Параметри\ntype: staticContent\n" + block("layout", "sequence: 5\nslot: body") + "\n"
    bar += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#\ncssClasses: tx-print-bar")
    body += "\n" + comp("region", "bar", bar)

    def sel(it, lbl, lov, seq, span, new_row, dflt=None, null_disp=None):
        b = "type: selectList\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {seq}\nregion: @bar\nslot: regionBody\ncolumnSpan: {span}" + ("" if new_row else "\nstartNewRow: false")) + "\n"
        b += block("appearance", f"template: @/{'optional' if null_disp else 'required'}\ntemplateOptions: #DEFAULT#") + "\n"
        if dflt:
            b += block("default", f"type: static\nstaticValue: {dflt}") + "\n"
        lv = f"type: sharedComponent\nlov: @{lov}\ndisplayExtraValues: false\n"
        lv += f"displayNullValue: true\nnullDisplayValue: {null_disp}" if null_disp else "displayNullValue: false"
        b += block("lov", lv) + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        return "\n" + comp("pageItem", f"P{p}_{it}", b)

    for i, (it, lbl, dflt) in enumerate([("FROM", "З", "to_char(sysdate, 'DD.MM.YYYY')"),
                                         ("TO", "По", "to_char(sysdate + 7, 'DD.MM.YYYY')")]):
        b = "type: datePicker\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {10 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 3" + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#\nformatMask: DD.MM.YYYY") + "\n"
        b += block("default", f"type: expression\nlanguage: plsql\nplsqlExpression: {dflt}") + "\n"
        b += block("settings", "displayAs: popup\nshowTime: false") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += sel("DIRECTION", "Напрям", "cargo-directions", 14, 3, False, null_disp="Усі напрями")
    body += sel("DOC_TYPE", "Документи", "cargo-doc-types", 16, 3, False, null_disp="Усі види")
    body += "\n" + org_filter_item(p, "bar", 20, span=3, new_row=True)
    body += sel("WH", "Склад", "warehouses-all", 22, 3, False, null_disp="Усі склади")
    body += sel("POSTED", "Статус", "cargo-status", 24, 3, False, "N")
    for i, (it, lbl, hlp) in enumerate([("CAP_KG", "Вантажопідйомність, кг", "Вантажопідйомність транспорту — % завантаження за вагою."),
                                        ("CAP_M3", "Об'єм кузова, м³", "Корисний об'єм транспорту — % завантаження за об'ємом.")]):
        b = "type: numberField\n" + block("label", f"label: {lbl}\nalignment: right") + "\n"
        b += block("layout", f"sequence: {30 + i}\nregion: @bar\nslot: regionBody\ncolumnSpan: 3" + ("\nstartNewRow: false" if i else "")) + "\n"
        b += block("appearance", "template: @/optional\ntemplateOptions: #DEFAULT#") + "\n"
        b += block("settings", "numberAlignment: end\nvirtualKeyboard: decimal") + "\n"
        b += block("help", f"helpText: {hlp}") + "\n"
        b += block("sessionState", "dataType: varchar2\nstorage: session")
        body += "\n" + comp("pageItem", f"P{p}_{it}", b)
    body += "\n" + button("show", "SHOW", "Сформувати", 40, "bar", slot="regionBody", hot=True)
    body += "\n" + button("print", "PRINT", "Друк", 50, "bar", slot="regionBody", action="definedByDynamicAction")
    pb = "name: Вага й об'єм документів\ntype: dynamicContent\n"
    pb += block("source", "language: plsql\nplsqlFunctionBody:" + code("plsql",
        f"return trade_cargo.cargo_html(\n"
        f"         coalesce(to_date(:P{p}_FROM, 'DD.MM.YYYY'), trunc(sysdate)),\n"
        f"         coalesce(to_date(:P{p}_TO, 'DD.MM.YYYY'), trunc(sysdate) + 7),\n"
        f"         :P{p}_DIRECTION, :P{p}_DOC_TYPE, :P{p}_ORG, :P{p}_WH, coalesce(:P{p}_POSTED, 'N'),\n"
        f"         trade_cargo.to_num(:P{p}_CAP_KG), trade_cargo.to_num(:P{p}_CAP_M3));")) + "\n"
    pb += block("layout", "sequence: 10\nslot: body") + "\n"
    pb += block("appearance", "template: @/blank-with-attributes\ntemplateOptions: #DEFAULT#")
    body += "\n" + comp("region", "cargo", pb)
    da = "name: Друк\n" + block("when", "event: click\nselectionType: button\nbutton: @print") + "\n" + block("execution", "sequence: 10") + "\n\n"
    da += comp("action", "print", "name: Друк\naction: executeJsCode\n" + block("settings", "jsCode: window.print();") + "\n" + block("execution", "sequence: 10\nfireOnInit: false"))
    body += "\n" + comp("dynamicAction", "print", da)
    write(PAGES / f"p{p:05d}-cargo-weight-volume.apx", comp("page", str(p), body))

def set_page_auth():
    rules = {"role-purchase": [270, 271, 290, 291, 210],
             "role-purchase-or-cashier": [60, 61],
             "role-warehouse-or-purchase": [50, 51],
             "role-sales": [110, 111, 260, 261, 280, 281, 320, 321, 700, 710, 711],   # 700–711: r7 F-INT-04
             "role-sales-or-cashier": [120, 121, 640, 641, 650, 651, 660],   # 640–660: r5 F-RET-01
             "role-warehouse": [130, 131, 140, 141, 300, 301, 310, 311, 190, 440, 441, 560, 561, 570, 571, 590],
             "role-admin": [100, 101, 480, 530, 670, 695],   # 670: r5 F-SRV-06; 695: r5 F-WH-25
             "role-cashier": [340, 341, 350, 351, 360, 370, 371, 380, 381, 390, 400, 401, 410, 411, 610],
             "role-tax": [620, 621, 630]}
    for auth, pages in rules.items():
        for pg in pages:
            PAGE_AUTH[pg] = auth


def main():
    set_page_auth()
    r3_specs()
    r4_specs()
    r4_fin_specs()
    r4_cash_doc_specs()
    r4_bank_specs()
    r4_debt_specs()
    r4_supplier_payment_specs()
    r4_customer_payment_specs()
    r4_assembly_specs()
    r5_series_specs()
    r5_discount_specs()
    r5_order_scheme_specs()
    r5_currency_specs()
    r5_vat_specs()
    r5_retail_specs()
    r7_edi_specs()
    r6_weights_specs()
    add_pick_settings()
    add_print_commands()
    lovs()
    r3_lovs()
    r4_lovs()
    r4_fin_lovs()
    r4_cash_lovs()
    r4_cash_doc_lovs()
    r4_bank_lovs()
    r4_debt_lovs()
    r4_supplier_payment_lovs()
    r4_assembly_lovs()
    abc_lovs()
    turnover_lovs()
    slow_stock_lovs()
    aging_lovs()
    event_log_lovs()
    r5_series_lovs()
    r5_discount_lovs()
    r5_order_scheme_lovs()
    r5_currency_lovs()
    r5_vat_lovs()
    r5_retail_lovs()
    r5_import_lovs()
    cargo_lovs()
    for c in CATALOGS:
        catalog_list_page(c)
        catalog_form_page(c)
    for d in DOCUMENTS:
        document_pages(d)
    registers()
    r2_reports()
    r3_registers_and_reports()
    cash_register_page()
    cash_book_page()
    reconciliation_page()
    product_card_page()
    abc_page()
    turnover_page()
    slow_stock_page()
    markdown_rules_page()
    aging_page()
    event_log_page()
    expiring_goods_page()
    discount_limits_page()
    discounts_given_page()
    goods_order_report_page()
    storekeeper_workplace_page()
    currency_rates_page()
    tax_register_page()
    cashier_workplace_page()
    catalog_import_page()
    edi_page()
    cargo_page()
    pick_page()

if __name__ == "__main__":
    main()
