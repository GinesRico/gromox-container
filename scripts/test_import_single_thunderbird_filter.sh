#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-$HOME/thunderbird-migration/Mail/mail.gira.net}"
PUBLIC_PATH="${PUBLIC_PATH:-/IPM_SUBTREE/JUMASA}"
FROM_IS="${FROM_IS:-facturacion@jumasa.es}"
FROM_ENDS_WITH="${FROM_ENDS_WITH:-@jumasa.es}"
SINCE_DATE="${SINCE_DATE:-2026-01-01}"
DOMAIN="${DOMAIN:-arvera.es}"
DOMAIN_ID="${DOMAIN_ID:-1}"
API_BASE="${API_BASE:-https://127.0.0.1:9444/api/v1}"
ADMIN_USER="${ADMIN_USER:-admin}"
COMPOSE="${COMPOSE:-sudo docker compose}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "No existe SOURCE_DIR: $SOURCE_DIR" >&2
  exit 1
fi

if [ -z "${ADMIN_PASS:-}" ]; then
  printf "Password admin de grommunio para %s: " "$ADMIN_USER" >&2
  stty -echo
  read -r ADMIN_PASS
  stty echo
  printf "\n" >&2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

python3 - "$SOURCE_DIR" "$PUBLIC_PATH" "$FROM_IS" "$FROM_ENDS_WITH" "$SINCE_DATE" "$API_BASE" "$DOMAIN_ID" "$ADMIN_USER" "$ADMIN_PASS" "$WORKDIR" <<'PY'
import json
import mailbox
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from email.utils import getaddresses, parsedate_to_datetime

source_dir, public_path, from_is, from_ends_with, since_date, api_base, domain_id, admin_user, admin_pass, workdir = sys.argv[1:]
since = datetime.fromisoformat(since_date).replace(tzinfo=timezone.utc)
ctx = ssl._create_unverified_context()


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
    with urllib.request.urlopen(req, context=ctx) as resp:
        raw = resp.read()
        return json.loads(raw.decode()) if raw else None


login_body = urllib.parse.urlencode({"user": admin_user, "pass": admin_pass}).encode()
login_req = urllib.request.Request(f"{api_base}/login", data=login_body, method="POST")
with urllib.request.urlopen(login_req, context=ctx) as resp:
    login = json.loads(resp.read().decode())
token = login["grommunioAuthJwt"]
csrf = login["csrf"]


def load_tree():
    return request("GET", f"{api_base}/domains/{domain_id}/folders/tree", token, csrf)


def find_child(parent, name):
    for child in parent.get("children", []) or []:
        if child.get("name") == name:
            return child
    return None


def ensure_public_path(path):
    prefix = "/IPM_SUBTREE/"
    if not path.startswith(prefix):
        raise SystemExit(f"PUBLIC_PATH debe empezar por {prefix}: {path}")
    parts = [part for part in path[len(prefix):].split("/") if part]
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


def is_mbox_file(path):
    name = os.path.basename(path)
    if name.endswith(".msf") or name.endswith(".dat") or name.endswith(".sbd"):
        return False
    return os.path.isfile(path) and os.path.getsize(path) > 0


def message_date(msg):
    for header in ("Date", "Delivery-date", "Received"):
        value = msg.get(header)
        if not value:
            continue
        try:
            dt = parsedate_to_datetime(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except Exception:
            continue
    return None


def from_addresses(msg):
    return [addr.lower() for _, addr in getaddresses(msg.get_all("From", [])) if addr]


def matches(msg):
    addrs = from_addresses(msg)
    from_is_l = from_is.lower()
    from_ends_with_l = from_ends_with.lower()
    return any(addr == from_is_l or addr.endswith(from_ends_with_l) for addr in addrs)


ensure_public_path(public_path)
out_path = os.path.join(workdir, "single-filter-result.mbox")
total = 0
matched = 0
per_file = []

with open(out_path, "wb") as out:
    for root, _, files in os.walk(source_dir):
        for filename in sorted(files):
            path = os.path.join(root, filename)
            if not is_mbox_file(path):
                continue
            file_total = 0
            file_matched = 0
            try:
                mbox = mailbox.mbox(path, create=False)
                for msg in mbox:
                    total += 1
                    file_total += 1
                    dt = message_date(msg)
                    if dt is None or dt < since or not matches(msg):
                        continue
                    out.write(b"From thunderbird-filter-test@example.com Sat Jan  1 00:00:00 2026\n")
                    out.write(bytes(msg))
                    out.write(b"\n")
                    matched += 1
                    file_matched += 1
            except Exception as exc:
                print(f"WARN no se pudo leer {path}: {exc}", flush=True)
            if file_matched:
                per_file.append((path, file_matched, file_total))

print(f"SCAN total={total} matched={matched} since={since_date} source={source_dir}", flush=True)
for path, file_matched, file_total in per_file:
    print(f"MATCH {file_matched}/{file_total} {path}", flush=True)

manifest = {
    "filtered": out_path,
    "matched": matched,
    "public_path": public_path,
}
with open(os.path.join(workdir, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f)
print(os.path.join(workdir, "manifest.json"), flush=True)
PY

MANIFEST="$WORKDIR/manifest.json"
MATCHED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched"])' "$MANIFEST")"
FILTERED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["filtered"])' "$MANIFEST")"

if [ "$MATCHED" = "0" ]; then
  echo "No hay mensajes que coincidan. No importo nada."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN=1: no importo. Coincidencias: $MATCHED"
  exit 0
fi

echo "IMPORT $MATCHED mensajes -> $PUBLIC_PATH"
$COMPOSE exec -T gromox-core bash -lc "cat >/tmp/single-filter-result.mbox && gromox-mbox2mt /tmp/single-filter-result.mbox | gromox-import -u @${DOMAIN} -B \"$PUBLIC_PATH\" -c -v -x" < "$FILTERED"

echo "Prueba terminada."
