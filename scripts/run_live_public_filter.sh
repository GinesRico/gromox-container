#!/usr/bin/env bash
set -euo pipefail

RULES_JSON="${RULES_JSON:-migration-analysis/thunderbird_filter_worker_rules.json}"
STATE_FILE="${STATE_FILE:-filter-state/live-public-filter-state.json}"
DOMAIN="${DOMAIN:-arvera.es}"
DOMAIN_ID="${DOMAIN_ID:-1}"
API_BASE_IN_CONTAINER="${API_BASE_IN_CONTAINER:-https://127.0.0.1:9443/api/v1}"
IMAP_HOST="${IMAP_HOST:-127.0.0.1}"
IMAP_PORT="${IMAP_PORT:-2143}"
ADMIN_USER="${ADMIN_USER:-admin}"
COMPOSE="${COMPOSE:-sudo docker compose}"
DRY_RUN="${DRY_RUN:-1}"
MODE="${MODE:-copy}"
SINCE_DATE="${SINCE_DATE:-2026-01-01}"
RULE_IDS="${RULE_IDS:-}"
MAILBOXES="${MAILBOXES:-}"

if [ ! -f "$RULES_JSON" ]; then
  echo "No existe RULES_JSON: $RULES_JSON" >&2
  exit 1
fi

if [ "$MODE" != "copy" ] && [ "$MODE" != "move" ]; then
  echo "MODE debe ser copy o move" >&2
  exit 1
fi

if [ -z "${ADMIN_PASS:-}" ]; then
  printf "Password admin de grommunio para %s: " "$ADMIN_USER" >&2
  stty -echo
  read -r ADMIN_PASS
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

mkdir -p "$(dirname "$STATE_FILE")"
if [ ! -f "$STATE_FILE" ]; then
  printf '{}\n' > "$STATE_FILE"
fi

$COMPOSE cp "$RULES_JSON" gromox-core:/tmp/live-public-filter-rules.json >/dev/null
$COMPOSE cp "$STATE_FILE" gromox-core:/var/tmp/live-public-filter-state.json >/dev/null
$COMPOSE exec -T -u root gromox-core bash -lc 'mkdir -p /var/tmp && chmod 1777 /var/tmp && chmod 644 /tmp/live-public-filter-rules.json && chmod 666 /var/tmp/live-public-filter-state.json' >/dev/null

$COMPOSE exec -T \
  -e DOMAIN="$DOMAIN" \
  -e DOMAIN_ID="$DOMAIN_ID" \
  -e API_BASE="$API_BASE_IN_CONTAINER" \
  -e IMAP_HOST="$IMAP_HOST" \
  -e IMAP_PORT="$IMAP_PORT" \
  -e ADMIN_USER="$ADMIN_USER" \
  -e ADMIN_PASS="$ADMIN_PASS" \
  -e COMMON_IMAP_PASS="$COMMON_IMAP_PASS" \
  -e DRY_RUN="$DRY_RUN" \
  -e MODE="$MODE" \
  -e SINCE_DATE="$SINCE_DATE" \
  -e RULE_IDS="$RULE_IDS" \
  -e MAILBOXES="$MAILBOXES" \
  gromox-core python3 - <<'PY'
import email
import imaplib
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime
from email.utils import getaddresses

RULES_PATH = "/tmp/live-public-filter-rules.json"
STATE_PATH = "/var/tmp/live-public-filter-state.json"

domain = os.environ["DOMAIN"]
domain_id = os.environ["DOMAIN_ID"]
api_base = os.environ["API_BASE"]
imap_host = os.environ["IMAP_HOST"]
imap_port = int(os.environ["IMAP_PORT"])
admin_user = os.environ["ADMIN_USER"]
admin_pass = os.environ["ADMIN_PASS"]
common_imap_pass = os.environ["COMMON_IMAP_PASS"]
dry_run = os.environ.get("DRY_RUN", "1") == "1"
mode = os.environ.get("MODE", "copy")
since_date = os.environ.get("SINCE_DATE", "2026-01-01")
rule_ids = {item.strip() for item in os.environ.get("RULE_IDS", "").split(",") if item.strip()}
mailboxes_filter = {item.strip().lower() for item in os.environ.get("MAILBOXES", "").split(",") if item.strip()}


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


rules = load_json(RULES_PATH, [])
state = load_json(STATE_PATH, {})

if rule_ids:
    rules = [rule for rule in rules if str(rule.get("id")) in rule_ids]

if mailboxes_filter:
    rules = [rule for rule in rules if rule.get("source_mailbox", "").lower() in mailboxes_filter]


def parse_conditions(condition):
    parsed = []
    for field, operator, value in re.findall(r"\(([^,]+),([^,]+),([^)]+)\)", condition or ""):
        parsed.append((field.strip().lower(), operator.strip().lower(), value.strip().lower()))
    connector = "AND" if (condition or "").strip().upper().startswith("AND ") else "OR"
    return connector, parsed


def get_header_values(msg, field):
    if field == "from":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("From", [])) if addr]
    if field == "to":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("To", [])) if addr]
    if field == "cc":
        return [addr.lower() for _, addr in getaddresses(msg.get_all("Cc", [])) if addr]
    if field == "subject":
        return [str(email.header.make_header(email.header.decode_header(msg.get("Subject", "")))).lower()]
    return []


def condition_item_matches(msg, field, operator, value):
    values = get_header_values(msg, field)
    if operator == "is":
        return any(item == value for item in values)
    if operator == "contains":
        return any(value in item for item in values)
    if operator == "ends with":
        return any(item.endswith(value) for item in values)
    if operator == "begins with":
        return any(item.startswith(value) for item in values)
    return False


def rule_matches(msg, rule):
    connector, items = parse_conditions(rule.get("condition", ""))
    if not items:
        return False
    results = [condition_item_matches(msg, *item) for item in items]
    return all(results) if connector == "AND" else any(results)


def request(method, url, token=None, csrf=None, data=None):
    headers = {}
    body = None
    if token:
        headers["Cookie"] = f"grommunioAuthJwt={token}"
    if csrf:
        headers["X-Csrf-Token"] = csrf
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    ctx = ssl._create_unverified_context()
    with urllib.request.urlopen(req, context=ctx) as resp:
        raw = resp.read()
        return json.loads(raw.decode()) if raw else None


def api_login():
    body = urllib.parse.urlencode({"user": admin_user, "pass": admin_pass}).encode()
    req = urllib.request.Request(f"{api_base}/login", data=body, method="POST")
    ctx = ssl._create_unverified_context()
    with urllib.request.urlopen(req, context=ctx) as resp:
        login = json.loads(resp.read().decode())
    return login["grommunioAuthJwt"], login["csrf"]


token = csrf = None


def load_tree():
    global token, csrf
    if token is None:
        token, csrf = api_login()
    return request("GET", f"{api_base}/domains/{domain_id}/folders/tree", token, csrf)


def find_child(parent, name):
    for child in parent.get("children", []) or []:
        if child.get("name") == name:
            return child
    return None


def ensure_public_path(public_path):
    global token, csrf
    prefix = "/IPM_SUBTREE/"
    if not public_path.startswith(prefix):
        raise RuntimeError(f"Ruta publica no valida: {public_path}")
    parts = [part for part in public_path[len(prefix):].split("/") if part]
    tree = load_tree()
    parent = tree
    built = []
    for part in parts:
        child = find_child(parent, part)
        if child is None:
            parent_id = "0" if not built else str(parent["folderid"])
            payload = {
                "displayname": part,
                "container": "IPF.Note",
                "comment": "",
                "parentID": parent_id,
                "syncToMobile": False,
            }
            created = request("POST", f"{api_base}/domains/{domain_id}/folders", token, csrf, payload)
            print(f"CREATED {'/'.join(built + [part])} -> {created['folderid']}", flush=True)
            tree = load_tree()
            parent = tree
            for existing in built:
                parent = find_child(parent, existing)
            child = find_child(parent, part)
        parent = child
        built.append(part)


def import_to_public(raw_message, public_path):
    ensure_public_path(public_path)
    with tempfile.NamedTemporaryFile("wb", suffix=".mbox", delete=False) as f:
        mbox_path = f.name
        f.write(b"From live-public-filter@example.com Sat Jan  1 00:00:00 2026\n")
        f.write(raw_message)
        f.write(b"\n")
    try:
        cmd = (
            f"gromox-mbox2mt {shlex.quote(mbox_path)} | "
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
        try:
            os.unlink(mbox_path)
        except OSError:
            pass


mailboxes = sorted({rule["source_mailbox"].lower() for rule in rules if "@" in rule.get("source_mailbox", "")})
if mailboxes_filter:
    mailboxes = [box for box in mailboxes if box in mailboxes_filter]

since_imap = datetime.fromisoformat(since_date).strftime("%d-%b-%Y")
print(f"CONFIG dry_run={dry_run} mode={mode} since={since_date} rules={len(rules)} mailboxes={','.join(mailboxes)}", flush=True)

matched_total = 0
applied_total = 0

for mailbox in mailboxes:
    mailbox_rules = [rule for rule in rules if rule.get("source_mailbox", "").lower() == mailbox]
    if not mailbox_rules:
        continue
    print(f"===== {mailbox}: {len(mailbox_rules)} reglas =====", flush=True)
    imap = imaplib.IMAP4(imap_host, imap_port)
    try:
        imap.login(mailbox, common_imap_pass)
        typ, data = imap.select("INBOX")
        if typ != "OK":
            print(f"WARN no puedo abrir INBOX de {mailbox}: {data}", flush=True)
            continue
        typ, uidvalidity_data = imap.response("UIDVALIDITY")
        uidvalidity = uidvalidity_data[0].decode() if uidvalidity_data and uidvalidity_data[0] else "unknown"
        typ, data = imap.uid("SEARCH", None, "SINCE", since_imap)
        if typ != "OK":
            print(f"WARN SEARCH fallo en {mailbox}: {data}", flush=True)
            continue
        uids = data[0].split()
        print(f"SCAN {mailbox}: {len(uids)} mensajes desde {since_date}", flush=True)
        for uid_b in uids:
            uid = uid_b.decode()
            typ, fetched = imap.uid("FETCH", uid, "(RFC822)")
            if typ != "OK" or not fetched:
                continue
            raw = None
            for item in fetched:
                if isinstance(item, tuple):
                    raw = item[1]
                    break
            if not raw:
                continue
            msg = email.message_from_bytes(raw)
            subject = str(email.header.make_header(email.header.decode_header(msg.get("Subject", ""))))
            sender = msg.get("From", "")
            for rule in mailbox_rules:
                key = f"{mailbox}:{uidvalidity}:{uid}:{rule.get('id')}"
                if state.get(key):
                    continue
                if not rule_matches(msg, rule):
                    continue
                matched_total += 1
                public_path = rule["public_folder"]
                print(f"MATCH rule={rule.get('id')} mailbox={mailbox} uid={uid} -> {public_path} | {sender} | {subject}", flush=True)
                if dry_run:
                    break
                import_to_public(raw, public_path)
                state[key] = {"mode": mode, "public_folder": public_path, "subject": subject}
                applied_total += 1
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

if not dry_run:
    try:
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2)
    except OSError as exc:
        print(f"WARN no se pudo guardar estado: {exc}", flush=True)

print(f"RESULT matched={matched_total} applied={applied_total} dry_run={dry_run}", flush=True)
PY

if [ "$DRY_RUN" != "1" ]; then
  $COMPOSE cp gromox-core:/var/tmp/live-public-filter-state.json "$STATE_FILE" >/dev/null || \
    echo "WARN: no se pudo copiar el estado a $STATE_FILE. El filtro se ha ejecutado igualmente." >&2
fi

echo "Estado guardado en: $STATE_FILE"
