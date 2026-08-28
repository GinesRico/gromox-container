#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${COMPOSE:=sudo docker compose}"
: "${DOMAIN:=arvera.es}"
: "${SHARED_MAILBOXES:=info@arvera.es admin@arvera.es}"
: "${GRANT_STOREOWNER:=0}"

usage() {
  cat <<'EOF'
Uso:
  OPERATOR_EMAIL=francisco@arvera.es ./scripts/create_operator_user.sh

Variables:
  OPERATOR_EMAIL       Usuario operador a crear o actualizar. Obligatorio.
  OPERATOR_PASSWORD    Password inicial. Si no se define, se pedira por pantalla.
  OPERATOR_DISPLAY     Nombre visible opcional.
  SHARED_MAILBOXES     Buzones compartidos a los que tendra acceso.
                       Por defecto: info@arvera.es admin@arvera.es
  GRANT_STOREOWNER     1 para conceder tambien permisos storeowner.
                       Por defecto: 0

Notas:
  Este script crea usuarios operadores sin buzon propio (--no-maildir). Sirve
  para permisos sobre buzones compartidos y envio como esos buzones. El acceso
  completo al webmail sin buzon propio requiere la adaptacion Arvera de Web/MAPI.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "${OPERATOR_EMAIL:-}" ]; then
  usage >&2
  echo >&2
  echo "ERROR: falta OPERATOR_EMAIL." >&2
  exit 1
fi

if [ -z "${OPERATOR_PASSWORD:-}" ]; then
  printf "Password inicial para %s: " "$OPERATOR_EMAIL" >&2
  stty -echo
  read -r OPERATOR_PASSWORD
  stty echo
  printf "\n" >&2
fi

echo "===== Usuario operador: $OPERATOR_EMAIL ====="

if $COMPOSE exec -T gromox-core grommunio-admin user show "$OPERATOR_EMAIL" >/dev/null 2>&1; then
  echo "El usuario ya existe. Ajustando privilegios de operador."
  $COMPOSE exec -T gromox-core grommunio-admin user modify "$OPERATOR_EMAIL" \
    --status 0 \
    --pop3-imap false \
    --smtp false \
    --privWeb true \
    --privDav true \
    --privEas true
else
  echo "Creando usuario sin buzon propio."
  create_cmd=(
    grommunio-admin user create "$OPERATOR_EMAIL"
    --no-maildir
    --status 0
    --pop3-imap false
    --smtp false
    --privWeb true
    --privDav true
    --privEas true
  )

  if [ -n "${OPERATOR_DISPLAY:-}" ]; then
    create_cmd+=(--property "displayname=$OPERATOR_DISPLAY")
  fi

  $COMPOSE exec -T gromox-core "${create_cmd[@]}"
fi

echo "===== Password ====="
$COMPOSE exec -T gromox-core grommunio-admin passwd "$OPERATOR_EMAIL" --password "$OPERATOR_PASSWORD"

echo "===== Permisos sobre buzones compartidos ====="
for mailbox in $SHARED_MAILBOXES; do
  echo "----- $mailbox -----"
  $COMPOSE exec -T gromox-core grommunio-admin user delegates "$mailbox" add "$OPERATOR_EMAIL" || true
  $COMPOSE exec -T gromox-core grommunio-admin user sendas "$mailbox" add "$OPERATOR_EMAIL" || true

  if [ "$GRANT_STOREOWNER" = "1" ]; then
    $COMPOSE exec -T gromox-core grommunio-admin user storeowner "$mailbox" add "$OPERATOR_EMAIL" || true
  fi
done

echo "===== Resultado ====="
$COMPOSE exec -T gromox-core grommunio-admin user show "$OPERATOR_EMAIL" || true

for mailbox in $SHARED_MAILBOXES; do
  echo "----- $mailbox delegates -----"
  $COMPOSE exec -T gromox-core grommunio-admin user delegates "$mailbox" list || true
  echo "----- $mailbox sendas -----"
  $COMPOSE exec -T gromox-core grommunio-admin user sendas "$mailbox" list || true
done

echo "OK: operador preparado. Si este usuario no tiene buzon propio, la entrada directa en Web depende de la adaptacion Arvera de webmail/MAPI."
