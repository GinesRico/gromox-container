#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-$HOME/thunderbird-migration/Mail/Local Folders}"
SINCE_DATE="${SINCE_DATE:-2026-01-01}"
ONLY_REGEX="${ONLY_REGEX:-}"
EXCLUDE_REGEX="${EXCLUDE_REGEX:-}"
DOMAIN_ID="${DOMAIN_ID:-1}"
DOMAIN="${DOMAIN:-arvera.es}"
API_BASE="${API_BASE:-https://127.0.0.1:9444/api/v1}"
ADMIN_USER="${ADMIN_USER:-admin}"
COMPOSE="${COMPOSE:-sudo docker compose}"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "No existe SOURCE_DIR: $SOURCE_DIR" >&2
  echo "Uso: $0 ~/thunderbird-migration/Mail/Local\\ Folders" >&2
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

python3 - "$SOURCE_DIR" "$SINCE_DATE" "$API_BASE" "$DOMAIN_ID" "$ADMIN_USER" "$ADMIN_PASS" "$WORKDIR" "$ONLY_REGEX" "$EXCLUDE_REGEX" <<'PY'
import json
import mailbox
import os
import re
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

source_dir, since_date, api_base, domain_id, admin_user, admin_pass, workdir, only_regex, exclude_regex = sys.argv[1:]
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
        if not raw:
            return None
        return json.loads(raw.decode())

login_body = urllib.parse.urlencode({"user": admin_user, "pass": admin_pass}).encode()
login_req = urllib.request.Request(f"{api_base}/login", data=login_body, method="POST")
with urllib.request.urlopen(login_req, context=ctx) as resp:
    login = json.loads(resp.read().decode())
token = login["grommunioAuthJwt"]
csrf = login["csrf"]

def load_tree():
    return request("GET", f"{api_base}/domains/{domain_id}/folders/tree", token, csrf)

def norm_name(name):
    name = name.strip()
    name = re.sub(r'[\\/:"<>|?*\x00-\x1f]', "_", name)
    return name or "_sin_nombre"

def find_child(parent, name):
    for child in parent.get("children", []) or []:
        if child.get("name") == name:
            return child
    return None

def ensure_public_path(parts):
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
            child = request("POST", f"{api_base}/domains/{domain_id}/folders", token, csrf, payload)
            print(f"CREATED {'/'.join(built + [part])} -> {child['folderid']}", flush=True)
            tree = load_tree()
            parent = tree
            for existing in built:
                parent = find_child(parent, existing)
            child = find_child(parent, part)
        parent = child
        built.append(part)
    return "/IPM_SUBTREE/" + "/".join(parts)

def thunderbird_path_to_parts(path):
    rel = os.path.relpath(path, source_dir)
    bits = []
    for raw in rel.split(os.sep):
        if raw.endswith(".sbd"):
            raw = raw[:-4]
        bits.append(norm_name(raw))
    return bits

def is_mbox_file(path):
    name = os.path.basename(path)
    if name.endswith(".msf") or name.endswith(".dat"):
        return False
    if name.endswith(".sbd"):
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

def filter_mbox(src, dest):
    kept = 0
    total = 0
    mbox = mailbox.mbox(src, create=False)
    with open(dest, "wb") as out:
        for msg in mbox:
            total += 1
            dt = message_date(msg)
            if dt is None or dt < since:
                continue
            out.write(b"From thunderbird-import@example.com Sat Jan  1 00:00:00 2026\n")
            out.write(bytes(msg))
            out.write(b"\n")
            kept += 1
    return total, kept

mboxes = []
only_re = re.compile(only_regex) if only_regex else None
exclude_re = re.compile(exclude_regex) if exclude_regex else None
for root, _, files in os.walk(source_dir):
    for filename in files:
        path = os.path.join(root, filename)
        rel = os.path.relpath(path, source_dir)
        if not is_mbox_file(path):
            continue
        if only_re is not None and not only_re.search(rel):
            continue
        if exclude_re is not None and exclude_re.search(rel):
            continue
        mboxes.append(path)
mboxes.sort()

manifest = []
for src in mboxes:
    parts = thunderbird_path_to_parts(src)
    public_path = ensure_public_path(parts)
    filtered = os.path.join(workdir, f"filtered-{len(manifest)}.mbox")
    total, kept = filter_mbox(src, filtered)
    size = os.path.getsize(filtered) if kept else 0
    manifest.append({
        "src": src,
        "public_path": public_path,
        "total": total,
        "kept": kept,
        "filtered": filtered,
        "size": size,
    })
    print(f"FILTER {src} -> {public_path}: {kept}/{total}", flush=True)

with open(os.path.join(workdir, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
print(os.path.join(workdir, "manifest.json"))
PY

MANIFEST="$WORKDIR/manifest.json"
python3 - "$MANIFEST" <<'PY' | while IFS= read -r line; do
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8")):
    if item["kept"] > 0:
        print(json.dumps(item, ensure_ascii=False))
PY
  SRC="$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin)["filtered"])')"
  DEST="$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin)["public_path"])')"
  KEPT="$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kept"])')"
  echo "IMPORT $KEPT mensajes -> $DEST"
  $COMPOSE exec -T gromox-core bash -lc "cat >/tmp/thunderbird-filtered.mbox && gromox-mbox2mt /tmp/thunderbird-filtered.mbox | gromox-import -u @${DOMAIN} -B \"$DEST\" -c -v -x" < "$SRC"
done

echo "Importacion terminada."
