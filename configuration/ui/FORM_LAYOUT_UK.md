# Скорочений опис компонування форми

## Позначення

```text
field[20]  — 20% робочої ширини панелі
field[*]   — зайняти вільний залишок
field      — ширина за вмістом
@action    — команда
|          — горизонтальне розташування
```

Відсотки колонок таблиці рахуються від робочої ширини таблиці. Відсотки полів — від робочої ширини панелі після її відступів і проміжків.

## Шаблон документа

```text
FORM documentEditor

HEADER
  @postAndClose | @save | @post | @print
  number[20] | occurredAt[20] | organization[60]
  client[50] | buyer[50]
  contract[100]
  issued | issuedAt[*]

CONTENT
  TAB goods "Товари"
    @add | @pick | @refresh
    TOOLBAR standard
    TABLE goodsLines:
      product[55] | quantity[15] | price[15] | amount[15]
    TOTAL totalAmount "Всього"

  TAB secondPart "Вкладка 2"
    ...

FOOTER
  comment[100]
```

Названий `ROW` використовується лише коли рядок має власний заголовок, видимість, права, стиль або посилання з тестів:

```text
ROW issueInfo [visibleWhen=issuanceEnabled]:
  issued | issuedAt[*]
```

Типи, назви, обов'язковість і правила полів не дублюються: вони беруться з паспорта об'єкта.

