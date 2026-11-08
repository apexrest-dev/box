# Перевірка каркаса Trade

Остання повна перевірка: **2026-11-03**.

## Середовище

- проєктна Java: Eclipse Temurin 21.0.13 LTS у `.tools/jdk-21`;
- Maven: 3.9.12;
- Docker Desktop: 4.97.0, Docker Engine 29.9.2;
- тестовий PostgreSQL: `postgres:17-alpine`, фактична версія 17.11;
- SQLite JDBC: 3.47.

JDK з `.tools` підключається лише BAT-файлами Trade. Системні `JAVA_HOME` і
`PATH` не змінюються.

## Результати

- основний Maven reactor: **BUILD SUCCESS**, 7 тестів, 0 помилок, 0 пропусків;
- конфігуратор: **BUILD SUCCESS**, 51 тест, 0 помилок, 0 пропусків;
- міграція V001 успішно застосована на чистих SQLite та PostgreSQL;
- PostgreSQL перевірений через справжній контейнер Testcontainers;
- `git diff --check` не виявив помилок пробілів;
- у версійованих та нових файлах не знайдено OpenAI-ключів за шаблонами
  `sk-*` / `sk-proj-*`.

Стандартний повторний запуск:

```powershell
.\test-all-jdk21.bat
```
