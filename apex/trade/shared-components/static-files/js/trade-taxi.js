/* =============================================================================
   Trade — поведінка інтерфейсу у стилі «Такси»
   - панель відкритих форм (вкладки) з «Начальною сторінкою»;
   - підсвічування поточного розділу на панелі розділів;
   - відкриття рядка списку подвійним кліком / Enter, Ctrl+F — пошук;
   - гарячі клавіші форм: Ins — створити, Ctrl+Enter — провести і закрити,
     Ctrl+Shift+B — поле сканера (Enter — додати товар),
     Ctrl+S — записати, F9 — скопіювати, Esc у списку — нічого;
   - українські підписи стандартних кнопок таблиць.
   ============================================================================= */
(function ($) {
  "use strict";

  var STORE_TABS = "trade.openTabs";
  var STORE_SECTION = "trade.section";
  var MAX_TABS = 12;

  function store(key, val) {
    try {
      if (val === undefined) { return JSON.parse(sessionStorage.getItem(key)); }
      sessionStorage.setItem(key, JSON.stringify(val));
    } catch (e) { return null; }
  }

  function inDialog() {
    try { return window.self !== window.top; } catch (e) { return true; }
  }

  function pageAlias() {
    var m = location.pathname.match(/\/r\/[^/]+\/[^/]+\/([^/?]+)/);
    return m ? m[1] : String(apex.env.APP_PAGE_ID);
  }

  function formId() {
    var item = "P" + apex.env.APP_PAGE_ID + "_ID";
    var el = document.getElementById(item);
    return el ? (apex.item(item).getValue() || "") : null;
  }

  function cleanUrl() {
    // URL форми як є (з контрольною сумою аргументів); сесію підставляємо при показі
    return location.href;
  }

  function withSession(url) {
    try {
      var u = new URL(url, location.href);
      u.searchParams.set("session", apex.env.APP_SESSION);
      return u.toString();
    } catch (e) { return url; }
  }

  /* ------------------------------------------------- Панель відкритих форм */
  function renderTabs() {
    if (inDialog() || $("body").hasClass("t-PageBody--login")) { return; }
    var alias = pageAlias();
    var notForm = alias === "section";
    var tabs = store(STORE_TABS) || [];
    var home = alias === "home";
    var id = formId();
    var key = alias + ":" + (id === null ? "" : (id || "new"));
    var title = $(".tx-form-title h1").first().text() || document.title;

    if (!home && !notForm) {
      // нова форма після запису отримала ID — замінюємо вкладку «створення»
      if (id) {
        tabs = tabs.filter(function (t) { return t.key !== alias + ":new"; });
      }
      var found = tabs.filter(function (t) { return t.key === key; })[0];
      if (found) {
        found.title = title; found.url = cleanUrl();
      } else {
        tabs.push({ key: key, title: title, url: cleanUrl() });
        if (tabs.length > MAX_TABS) { tabs.shift(); }
      }
      store(STORE_TABS, tabs);
    }

    var homeUrl = apex.env.APP_URL || ("home?session=" + apex.env.APP_SESSION);
    var $bar = $('<nav class="tx-open-tabs" aria-label="Відкриті форми"></nav>');
    $bar.append(
      $('<a class="tx-open-tab" title="Початкова сторінка"></a>')
        .toggleClass("is-active", home)
        .attr("href", location.pathname.replace(/[^/]+$/, "home") + "?session=" + apex.env.APP_SESSION)
        .append('<span class="fa fa-home" aria-hidden="true"></span><span class="tx-tab-title">Початкова сторінка</span>')
    );
    tabs.forEach(function (t) {
      var $a = $('<a class="tx-open-tab"></a>').attr("href", withSession(t.url)).attr("title", t.title)
        .toggleClass("is-active", t.key === key)
        .append($('<span class="tx-tab-title"></span>').text(t.title))
        .append($('<span class="tx-tab-close" role="button" aria-label="Закрити">×</span>').attr("data-key", t.key));
      $bar.append($a);
    });
    $(".t-Body-contentInner").first().prepend($bar);

    $bar.on("click", ".tx-tab-close", function (e) {
      e.preventDefault(); e.stopPropagation();
      var k = $(this).attr("data-key");
      var list = (store(STORE_TABS) || []);
      var idx = list.findIndex(function (t) { return t.key === k; });
      list = list.filter(function (t) { return t.key !== k; });
      store(STORE_TABS, list);
      if (k === key) {
        var next = list[Math.min(idx, list.length - 1)];
        location.href = next ? withSession(next.url) : $bar.find(".tx-open-tab").first().attr("href");
      } else {
        $(this).closest(".tx-open-tab").remove();
      }
    });
  }

  /* ------------------------------------------- Поточний розділ (панель розділів) */
  function markSection() {
    var $nav = $(".t-TreeNav");
    var params = new URLSearchParams(location.search);
    var current = $nav.find(".a-TreeView-row.is-current, .a-TreeView-row.is-current--top").length;
    var $links = $nav.find("a.a-TreeView-label, .a-TreeView-label a, a");
    $links.on("click", function () { store(STORE_SECTION, $(this).text().trim()); });
    if (pageAlias() === "home") { store(STORE_SECTION, "Головне"); }
    if (!current) {
      var name = store(STORE_SECTION);
      if (name) {
        $links.filter(function () { return $(this).text().trim() === name; })
          .closest("li").addClass("tx-nav-current");
      }
    }
  }

  /* ------------------------------------------------ Заголовок форми: ← → ☆ */
  function formTitle() {
    $(document).on("click", ".tx-nav-back", function () { history.back(); });
    $(document).on("click", ".tx-nav-forward", function () { history.forward(); });
    $(document).on("click", ".tx-star", function () { $(this).toggleClass("is-on"); });
  }

  /* -------------------------------------------------------------- Списки (IR) */
  function lists() {
    $(document).on("click", ".a-IRR-table tr", function () {
      $(this).closest("table").find("tr.tx-selected").removeClass("tx-selected");
      $(this).addClass("tx-selected");
    });
    $(document).on("dblclick", ".a-IRR-table tr", function () {
      var a = $(this).find("td.a-IRR-linkCol a, td a").get(0);
      if (a) { a.click(); }
    });
  }

  /* -------------------------------------------------- Локалізація підписів */
  var DICT = {
    "Actions": "Ще",
    "Edit": "Змінити",
    "Save": "Записати",
    "Reset": "Скинути",
    "Go": "Знайти",
    "Search": "Пошук (Ctrl+F)",
    "Cancel": "Скасувати",
    "OK": "Так",
    "Show More": "Показати ще",
    "Close": "Закрити"
  };
  function translate(root) {
    $(root).find(".a-Button, .ui-button, .t-Button, button").each(function () {
      var $lab = $(this).find(".a-Button-label, .t-Button-label").first();
      var $t = $lab.length ? $lab : $(this);
      var txt = $.trim($t.text());
      if (DICT[txt] && $t.children().length === 0) { $t.text(DICT[txt]); }
    });
    $(root).find('input[placeholder="Search"], input[placeholder="Search..."], input[placeholder^="Search:"]')
      .attr("placeholder", "Пошук (Ctrl+F)");
    $(root).find(".a-GV-status, .a-GV-pageRange").addBack(".a-GV-status, .a-GV-pageRange").each(function () {
      this.textContent = this.textContent.replace(/(\d+) rows? selected/, "Вибрано рядків: $1")
        .replace("Total", "Всього");
    });
  }

  /* ----------------------------------------------------------- Гарячі клавіші */
  function clickButton(names) {
    for (var i = 0; i < names.length; i++) {
      var $b = $("button[id], .t-Button").filter(function () {
        return $(this).is(":visible") && (this.id === names[i] || $(this).attr("data-request") === names[i]
          || ($(this).attr("onclick") || "").indexOf("'" + names[i] + "'") > -1);
      }).first();
      if ($b.length) { $b.trigger("click"); return true; }
    }
    return false;
  }
  function hotkeys() {
    $(document).on("keydown", function (e) {
      var k = e.key;
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && (k === "b" || k === "B")) {
        var $scan = $("input[id$='_SCAN']:visible").first();
        if ($scan.length) { e.preventDefault(); $scan.trigger("focus").select(); }
        return;
      }
      if (k === "Enter" && $(e.target).is("input[id$='_SCAN']")) {
        e.preventDefault();
        if ($.trim($(e.target).val())) { apex.submit({ request: "SCAN", showWait: true }); }
        return;
      }
      if ((e.ctrlKey || e.metaKey) && (k === "f" || k === "F")) {
        var $s = $(".a-IRR-search-field:visible").first();
        if ($s.length) { e.preventDefault(); $s.trigger("focus").select(); }
      } else if ((e.ctrlKey || e.metaKey) && k === "Enter") {
        if (clickButton(["B_POST_CLOSE", "B_CREATE_POST_CLOSE", "POST_CLOSE", "CREATE_POST_CLOSE"])) { e.preventDefault(); }
      } else if ((e.ctrlKey || e.metaKey) && (k === "s" || k === "S")) {
        if (clickButton(["B_SAVE", "B_CREATE", "SAVE", "CREATE"])) { e.preventDefault(); }
      } else if (k === "Insert" && !$(e.target).is("input, textarea, select")) {
        if (clickButton(["B_CREATE", "CREATE"])) { e.preventDefault(); }
      } else if (k === "F9" && !$(e.target).is("input, textarea, select")) {
        if (clickButton(["B_COPY", "COPY"])) { e.preventDefault(); }
      } else if (k === "Enter" && $(e.target).closest(".a-IRR-table tr").length === 0 && $(".a-IRR-table tr.tx-selected").length
                 && !$(e.target).is("input, textarea, select, button, a")) {
        $(".a-IRR-table tr.tx-selected").first().trigger("dblclick");
      }
    });
  }

  /* Панель розділів завжди розгорнута на широкому екрані (як у «Такси») */
  function expandNav() {
    if (window.innerWidth >= 992 && $("body").hasClass("js-navCollapsed")) {
      try { apex.theme42.toggleWidgets.expandWidget("nav"); }
      catch (e) { $("#t_Button_navControl").trigger("click"); }
    }
  }

  $(function () {
    document.documentElement.classList.add("tx-taxi");
    expandNav();
    // прибрати вкладки сторінки входу, якщо потрапили раніше
    store(STORE_TABS, (store(STORE_TABS) || []).filter(function (t) {
      return t.key.indexOf("login") !== 0 && t.key.indexOf("section") !== 0 && t.title;
    }));
    renderTabs();
    markSection();
    formTitle();
    lists();
    hotkeys();
    translate(document.body);
    var obs = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.nodeType === 1) { translate(n); }
          else if (n.nodeType === 3 && n.parentNode && /rows? selected|Total/.test(n.textContent)) { translate(n.parentNode.parentNode || n.parentNode); }
        });
      });
    });
    obs.observe(document.body, { childList: true, subtree: true });
  });
})(apex.jQuery);

/* Ієрархічний довідник (F-UI-07): дерево груп ліворуч, список праворуч */
(function ($) {
  $(document).on("click", ".tx-tree-toggle", function (e) {
    e.preventDefault();
    $(this).closest("li").toggleClass("is-open");
  });
  $(document).on("click", ".tx-tree-label", function (e) {
    e.preventDefault();
    var $tree = $(this).closest(".tx-tree"), $li = $(this).closest("li");
    $tree.find("li.is-current").removeClass("is-current");
    $li.addClass("is-current");
    if ($li.hasClass("has-children")) { $li.addClass("is-open"); }
    apex.item($tree.attr("data-item")).setValue($(this).attr("data-id") || "");
  });
  $(document).on("dblclick", ".tx-tree-label", function (e) {
    e.preventDefault();
    $(this).closest("li").toggleClass("is-open");
  });
  $(document).on("change", ".tx-tree-sub input", function () {
    apex.item($(this).attr("data-item")).setValue(this.checked ? "Y" : "N");
  });
})(apex.jQuery);
