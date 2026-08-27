#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${SINCE_DATE:=2026-01-01}"
: "${MAILBOXES:=admin@arvera.es info@arvera.es grico@arvera.es castellano@arvera.es sara@arvera.es}"
: "${MODE:=move}"
: "${DRY_RUN:=1}"
: "${IMAP_PORT:=2143}"

export SINCE_DATE MAILBOXES MODE DRY_RUN IMAP_PORT

echo "===== Ejecutar filtros ahora ====="
echo "Buzones: $MAILBOXES"
echo "Desde: $SINCE_DATE"
echo "Modo: $MODE"
echo "DRY_RUN: $DRY_RUN"
echo

exec ./scripts/run_live_public_filter.sh
