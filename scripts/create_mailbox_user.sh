#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${COMPOSE:=sudo docker compose}"
: "${DOMAIN:=arvera.es}"
: "${SHARED_MAILBOXES:=info@arvera.es admin@arvera.es}"

usage() {
  cat <<'EOF'
Uso:
  MAILBOX_EMAIL=francisco@arvera.es ./scripts/create_mailbox_user.sh

Variables:
  MAILBOX_EMAIL       Usuario con buzon propio a crear. Obligatorio.
  MAILBOX_PASSWORD    Password inicial. Si no se define, se pedira por pantalla.
  MAILBOX_DISPLAY     Nombre visible opcional.
  SHARED_MAILBOXES    Buzones compartidos a los que tendra acceso.
                      Por defecto: info@arvera.es admin@arvera.es

Notas:
  Este script crea un usuario normal con buzon propio. Si el sistema no permite
  crear mas buzones, el alta fallara y no se debe forzar desde aqui.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "${MAILBOX_EMAIL:-}" ]; then
  usage >&2
  echo >&2
  echo "ERROR: falta MAILBOX_EMAIL." >&2
  exit 1
fi

if [ -z "${MAILBOX_PASSWORD:-}" ]; then
  printf "Password inicial para %s: " "$MAILBOX_EMAIL" >&2
  stty -echo
  read -r MAILBOX_PASSWORD
  stty echo
  printf "\n" >&2
fi

echo "===== Usuario con buzon: $MAILBOX_EMAIL ====="

if $COMPOSE exec -T gromox-core grommunio-admin user show "$MAILBOX_EMAIL" >/dev/null 2>&1; then
  echo "El usuario ya existe. Ajustando privilegios."
  $COMPOSE exec -T gromox-core grommunio-admin user modify "$MAILBOX_EMAIL" \
    --status 0 \
    --pop3-imap true \
    --smtp true \
    --privWeb true \
    --privDav true \
    --privEas true
else
  echo "Creando usuario normal con buzon."
  create_cmd=(
    grommunio-admin user create "$MAILBOX_EMAIL"
    --status 0
    --pop3-imap true
    --smtp true
    --privWeb true
    --privDav true
    --privEas true
  )

  if [ -n "${MAILBOX_DISPLAY:-}" ]; then
    create_cmd+=(--property "displayname=$MAILBOX_DISPLAY")
  fi

  $COMPOSE exec -T gromox-core "${create_cmd[@]}"
fi

echo "===== Password ====="
$COMPOSE exec -T gromox-core grommunio-admin passwd "$MAILBOX_EMAIL" --password "$MAILBOX_PASSWORD"

echo "===== Permisos sobre buzones compartidos ====="
for mailbox in $SHARED_MAILBOXES; do
  echo "----- $mailbox -----"
  $COMPOSE exec -T gromox-core grommunio-admin user delegates "$mailbox" add "$MAILBOX_EMAIL" || true
  $COMPOSE exec -T gromox-core grommunio-admin user sendas "$mailbox" add "$MAILBOX_EMAIL" || true
done

echo "===== Resultado ====="
$COMPOSE exec -T gromox-core grommunio-admin user show "$MAILBOX_EMAIL" || true

echo "OK: usuario con buzon preparado."
