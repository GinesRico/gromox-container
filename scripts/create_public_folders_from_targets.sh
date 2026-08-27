#!/usr/bin/env bash
set -euo pipefail

TARGETS_CSV="${1:-migration-analysis/thunderbird_filter_targets.csv}"
DOMAIN_ID="${DOMAIN_ID:-1}"
API_BASE="${API_BASE:-https://127.0.0.1:9444/api/v1}"
ADMIN_USER="${ADMIN_USER:-admin}"

if [ ! -f "$TARGETS_CSV" ]; then
  echo "No existe TARGETS_CSV: $TARGETS_CSV" >&2
  exit 1
fi

if [ -z "${ADMIN_PASS:-}" ]; then
  printf "Password admin de grommunio para %s: " "$ADMIN_USER" >&2
  stty -echo
  read -r ADMIN_PASS
  stty echo
  printf "\n" >&2
fi

python3 - "$TARGETS_CSV" "$API_BASE" "$DOMAIN_ID" "$ADMIN_USER" "$ADMIN_PASS" <<'PY'
import csv
import json
import ssl
import sys
import urllib.parse
import urllib.request

targets_csv, api_base, domain_id, admin_user, admin_pass = sys.argv[1:]
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


def ensure_path(public_path):
    prefix = "/IPM_SUBTREE/"
    if not public_path.startswith(prefix):
        return
    parts = [part for part in public_path[len(prefix):].split("/") if part]
    if not parts:
        return

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
        else:
            print(f"EXISTS  {'/'.join(built + [part])}", flush=True)
        parent = child
        built.append(part)


with open(targets_csv, newline="", encoding="utf-8-sig") as f:
    rows = list(csv.DictReader(f))

paths = sorted({row["public_folder"].strip() for row in rows if row.get("public_folder", "").strip()})
for path in paths:
    ensure_path(path)

print(f"OK: {len(paths)} rutas verificadas.")
PY
