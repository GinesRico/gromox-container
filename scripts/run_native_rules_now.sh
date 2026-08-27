#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${RULE_OWNER:=grico@arvera.es}"
: "${TARGET_MAILBOXES:=info@arvera.es}"
: "${SINCE_DATE:=2026-08-25}"
: "${DRY_RUN:=1}"
: "${MODE:=move}"
: "${IMAP_HOST:=127.0.0.1}"
: "${IMAP_PORT:=2143}"
: "${DOMAIN:=arvera.es}"
: "${COMPOSE:=sudo docker compose}"

if [ "$MODE" != "copy" ] && [ "$MODE" != "move" ]; then
  echo "MODE debe ser copy o move" >&2
  exit 1
fi

if [ -z "${RULE_OWNER_PASS:-}" ]; then
  printf "Password de %s para leer reglas nativas: " "$RULE_OWNER" >&2
  stty -echo
  read -r RULE_OWNER_PASS
  stty echo
  printf "\n" >&2
fi

if [ -z "${COMMON_IMAP_PASS:-}" ]; then
  printf "Password IMAP comun de buzones grommunio: " >&2
  stty -echo
  read -r COMMON_IMAP_PASS
  stty echo
  printf "\n" >&2
fi

$COMPOSE cp scripts/export_native_rules_for_runner.php gromox-core:/tmp/export_native_rules_for_runner.php >/dev/null

mkdir -p filter-state
NATIVE_RULES_FILE="filter-state/native-rules-runner.json"

echo "===== Exportando reglas nativas de $RULE_OWNER ====="
$COMPOSE exec -T \
  -e GROMMUNIO_USER="$RULE_OWNER" \
  -e GROMMUNIO_PASS="$RULE_OWNER_PASS" \
  gromox-core php /tmp/export_native_rules_for_runner.php > "$NATIVE_RULES_FILE"

RULE_COUNT="$(python3 -c 'import json; print(len(json.load(open("filter-state/native-rules-runner.json"))))')"
echo "Reglas nativas ejecutables: $RULE_COUNT"

$COMPOSE cp "$NATIVE_RULES_FILE" gromox-core:/tmp/native-rules-runner.json >/dev/null

$COMPOSE exec -T \
  -e RULES_PATH="/tmp/native-rules-runner.json" \
  -e TARGET_MAILBOXES="$TARGET_MAILBOXES" \
  -e SINCE_DATE="$SINCE_DATE" \
  -e DRY_RUN="$DRY_RUN" \
  -e MODE="$MODE" \
  -e IMAP_HOST="$IMAP_HOST" \
  -e IMAP_PORT="$IMAP_PORT" \
  -e DOMAIN="$DOMAIN" \
  -e COMMON_IMAP_PASS="$COMMON_IMAP_PASS" \
  gromox-core python3 - <<'PY'
import email
import imaplib
import json
import os
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime
from email.utils import getaddresses

rules_path = os.environ["RULES_PATH"]
target_mailboxes = [item.strip().lower() for item in os.environ["TARGET_MAILBOXES"].split() if item.strip()]
since_date = os.environ["SINCE_DATE"]
dry_run = os.environ.get("DRY_RUN", "1") == "1"
mode = os.environ.get("MODE", "move")
imap_host = os.environ.get("IMAP_HOST", "127.0.0.1")
imap_port = int(os.environ.get("IMAP_PORT", "2143"))
domain = os.environ["DOMAIN"]
common_imap_pass = os.environ["COMMON_IMAP_PASS"]

with open(rules_path, encoding="utf-8") as f:
    rules = json.load(f)

def decode_header(value):
    return str(email.header.make_header(email.header.decode_header(value or ""))).lower()

def header_values(msg, field):
    if field == "from":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("From", [])) if addr]
    if field == "to":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("To", [])) if addr]
    if field == "cc":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("Cc", [])) if addr]
    if field == "subject":
        return [decode_header(msg.get("Subject", ""))]
    return []

def condition_matches(msg, condition):
    values = header_values(msg, condition["field"])
    needle = condition["value"].lower()
    op = condition["operator"]
    if op == "is":
        return any(value == needle for value in values)
    if op == "contains":
        return any(needle in value for value in values)
    if op == "ends with":
        return any(value.endswith(needle) for value in values)
    if op == "begins with":
        return any(value.startswith(needle) for value in values)
    return False

def rule_matches(msg, rule):
    # Grommunio web builds these sender rules as OR conditions.
    return any(condition_matches(msg, condition) for condition in rule.get("conditions", []))

def import_to_public(raw_message, public_path):
    with tempfile.NamedTemporaryFile("wb", suffix=".mbox", delete=False) as f:
        path = f.name
        f.write(b"From native-rules-now@example.com Sat Jan  1 00:00:00 2026\n")
        f.write(raw_message)
        f.write(b"\n")
    try:
        cmd = (
            f"gromox-mbox2mt {shlex.quote(path)} | "
            f"gromox-import -u @{shlex.quote(domain)} -B {shlex.quote(public_path)} -c -v -x"
        )
        result = subprocess.run(["bash", "-lc", cmd], text=True, capture_output=True)
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            raise RuntimeError(f"Fallo importando a {public_path}")
        if result.stdout.strip():
            print(result.stdout.strip(), flush=True)
    finally:
        subprocess.run(["rm", "-f", path])

since_imap = datetime.fromisoformat(since_date).strftime("%d-%b-%Y")
print(f"CONFIG native_rules={len(rules)} target_mailboxes={','.join(target_mailboxes)} since={since_date} mode={mode} dry_run={dry_run}", flush=True)

matched = 0
applied = 0
for mailbox in target_mailboxes:
    print(f"===== {mailbox} =====", flush=True)
    imap = imaplib.IMAP4(imap_host, imap_port)
    try:
        imap.login(mailbox, common_imap_pass)
        typ, data = imap.select("INBOX")
        if typ != "OK":
            print(f"WARN no puedo abrir INBOX de {mailbox}: {data}", flush=True)
            continue
        typ, data = imap.uid("SEARCH", None, "SINCE", since_imap)
        if typ != "OK":
            print(f"WARN SEARCH fallo en {mailbox}: {data}", flush=True)
            continue
        uids = data[0].split()
        print(f"SCAN {len(uids)} mensajes", flush=True)
        for uid_b in uids:
            uid = uid_b.decode()
            typ, fetched = imap.uid("FETCH", uid, "(RFC822)")
            if typ != "OK":
                continue
            raw = next((item[1] for item in fetched if isinstance(item, tuple)), None)
            if not raw:
                continue
            msg = email.message_from_bytes(raw)
            subject = str(email.header.make_header(email.header.decode_header(msg.get("Subject", ""))))
            sender = msg.get("From", "")
            for rule in rules:
                if not rule_matches(msg, rule):
                    continue
                matched += 1
                public_path = rule["public_folder"]
                print(f"MATCH rule={rule.get('name')} target={mailbox} uid={uid} -> {public_path} | {sender} | {subject}", flush=True)
                if not dry_run:
                    import_to_public(raw, public_path)
                    applied += 1
                    if mode == "move":
                        imap.uid("STORE", uid, "+FLAGS", r"(\Deleted)")
                break
        if not dry_run and mode == "move":
            imap.expunge()
    finally:
        try:
            imap.logout()
        except Exception:
            pass

print(f"RESULT matched={matched} applied={applied} dry_run={dry_run}", flush=True)
PY
