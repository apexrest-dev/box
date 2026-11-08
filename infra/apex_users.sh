#!/usr/bin/env bash
# Користувачі APEX і ролі Trade (повторюваний; запускати після імпорту застосунку).
# Паролі — з infra/.env. Потрібне SQLcl-підключення trade-sys.
set -euo pipefail
cd "$(dirname "$0")"
. ./.env
# Касир (F-FIN-01): користувач CASH1 створюється, якщо в .env задано CASH1_PWD
cash_sql=""
if [ -n "${CASH1_PWD:-}" ]; then
  cash_sql="u('CASH1', '${CASH1_PWD}', 'Касир'); r('CASH1', 'CASHIER');"
fi
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<SQL
set serveroutput on
alter session set current_schema = APEX_260200;
declare
  procedure u (p_name varchar2, p_pwd varchar2, p_first varchar2) is
  begin
    if apex_util.get_user_id(p_name) is null then
      apex_util.create_user(p_user_name => p_name, p_web_password => p_pwd, p_first_name => p_first,
                            p_change_password_on_first_use => 'N');
    end if;
  end;
  procedure r (p_user varchar2, p_role varchar2) is
  begin
    apex_acl.add_user_role(p_application_id => 100, p_user_name => p_user, p_role_static_id => p_role);
  exception when dup_val_on_index then null;
  end;
begin
  apex_util.set_workspace('TRADE');
  u('SALES1', '${SALES1_PWD}', 'Менеджер з продажу');
  u('BUYER1', '${BUYER1_PWD}', 'Закупівельник');
  u('STORE1', '${STORE1_PWD}', 'Комірник');
  r('DEVELOPER', 'ADMIN'); r('SALES1', 'SALES'); r('BUYER1', 'PURCHASE'); r('STORE1', 'STOREKEEPER');
  ${cash_sql}
  commit;
end;
/
exit
SQL
~/sqlcl/bin/sql -S -name trade-sys @"$tmp"
