#!/usr/bin/env python3
"""Стиль теми «1C-Taxi» (Theme Roller) для Universal Theme.

Джерело: apex/theme-src/1c-taxi-custom.css — власний CSS у стилі 1С 8.3 «Такси».
Скрипт робить те саме, що Theme Roller при «Save As»:
  * стиль теми `1c-taxi` на основі Iris (themeRollerAttributes.jsonConfig.customCSS = власний CSS);
  * вихідний CSS стилю — файл теми `1c-taxi.css` = Iris.min.css + власний CSS
    (outputCssFileUrl: #THEME_DB_IMAGES#1c-taxi.css);
  * стиль стає поточним (currentThemeStyle).

Після редагування в Theme Roller («Custom CSS» → Save) APEX сам перекомпілює стиль;
щоб зберегти зміни в репозиторії — перенесіть CSS назад у 1c-taxi-custom.css і запустіть скрипт.
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "theme-src")
THEME_DIR = os.path.join(ROOT, "trade", "shared-components", "themes", "universal-theme")
THEME_APX = os.path.join(THEME_DIR, "theme.apx")
FILES_APX = os.path.join(THEME_DIR, "static-files.apx")
FILES_DIR = os.path.join(THEME_DIR, "static-files")

STYLE_ID = "1c-taxi"
STYLE_NAME = "1C-Taxi"
OUT_FILE = "1c-taxi.css"


def main():
    custom = open(os.path.join(SRC, "1c-taxi-custom.css"), encoding="utf-8").read()
    base = open(os.path.join(SRC, "Iris-26.1.min.css"), encoding="utf-8").read()

    # Custom CSS для Theme Roller: без коментарів і порожніх рядків (обмеження 32 КБ на jsonConfig)
    css = re.sub(r"/\*.*?\*/", "", custom, flags=re.S)
    css = "\n".join(l.rstrip() for l in css.splitlines() if l.strip())
    cfg = json.dumps({"classes": [], "vars": {}, "customCSS": css, "useCustomLess": "N"},
                     ensure_ascii=False, indent=4)
    assert len(cfg.encode("utf-8")) < 32767, "jsonConfig перевищує 32 КБ"

    # Файл теми = скомпільований стиль (база Iris + Custom CSS), як після Save у Theme Roller
    os.makedirs(FILES_DIR, exist_ok=True)
    with open(os.path.join(FILES_DIR, OUT_FILE), "w", encoding="utf-8") as f:
        f.write(base.rstrip() + "\n\n/* ==== Custom CSS (Theme Roller): 1C-Taxi ==== */\n" + css + "\n")
    with open(FILES_APX, "w", encoding="utf-8") as f:
        f.write(f'file "{OUT_FILE}" (\n    mimeType: text/css\n    charSet: utf-8\n)\n')

    ind = " " * 16
    cfg_block = "\n".join(ind + l for l in cfg.splitlines())
    style = (
        f"    style {STYLE_ID} (\n"
        f"        name: {STYLE_NAME}\n"
        "        css {\n"
        "            fileUrls: #APEX_FILES#libraries/oracle-fonts/oraclesans-apex#MIN#.css?v=#APEX_VERSION#\n"
        "        }\n"
        "        themeRollerAttributes {\n"
        "            readOnly: false\n"
        "            inputParameterFileUrls: #THEME_FILES#less/theme/Iris.less\n"
        f"            outputCssFileUrl: #THEME_DB_IMAGES#{OUT_FILE}\n"
        "            jsonConfig:\n"
        "                ```json\n"
        f"{cfg_block}\n"
        "                ```\n"
        "        }\n"
        "        advanced {\n"
        "            endUserCanPick: true\n"
        "        }\n"
        "    )\n"
    )

    t = open(THEME_APX, encoding="utf-8").read()
    t = re.sub(r"\n    style " + re.escape(STYLE_ID) + r" \(.*?\n    \)\n", "\n", t, flags=re.S)
    t = re.sub(r"currentThemeStyle: @\S+", f"currentThemeStyle: @{STYLE_ID}", t)
    i = t.rstrip().rfind(")")
    t = t[:i].rstrip("\n") + "\n\n" + style + ")\n"
    open(THEME_APX, "w", encoding="utf-8").write(t)
    print(f"style {STYLE_ID}: customCSS {len(css)} chars, theme file {OUT_FILE}")


if __name__ == "__main__":
    main()
