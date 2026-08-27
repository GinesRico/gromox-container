#!/usr/bin/env bash
set -euo pipefail

WEB_BASE="${WEB_BASE:-https://192.168.0.161:8443/web}"
API_BASE="${API_BASE:-https://192.168.0.161:9444/api/v1}"
ADMIN_USER="${ADMIN_USER:-admin}"

# Store entryid captured from grommunio-web while editing rules for admin@arvera.es.
STORE_ENTRYID="${STORE_ENTRYID:-0000000038a1bb1005e5101aa1bb08002b2a56c20000656d736d64622e646c6c00000000000000001b55fa20aa6611cd9bc800aa002fc45a0c00000061646d696e406172766572612e6573002f6f3d6936613862643866332f6f753d45786368616e67652041646d696e6973747261746976652047726f7570202846594449424f484632335350444c54292f636e3d526563697069656e74732f636e3d303130303030303030333030303030302d61646d696e00}"

if [ -z "${ADMIN_PASS:-}" ]; then
  printf "Password admin de grommunio para %s: " "$ADMIN_USER" >&2
  stty -echo
  read -r ADMIN_PASS
  stty echo
  printf "\n" >&2
fi

LOGIN_JSON="$(curl -k -s -X POST "$API_BASE/login" \
  -d "user=${ADMIN_USER}" \
  -d "pass=${ADMIN_PASS}")"

TOKEN="$(printf "%s" "$LOGIN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["grommunioAuthJwt"])')"

REQUEST_JSON="$(python3 - "$STORE_ENTRYID" <<'PY'
import json
import sys

store_entryid = sys.argv[1]
print(json.dumps({
    "zarafa": {
        "rulesmodule": {
            "rulesmodule-probe": {
                "list": {
                    "store_entryid": store_entryid
                }
            }
        }
    }
}, ensure_ascii=False))
PY
)"

echo "===== Request rulesmodule list ====="
printf "%s\n" "$REQUEST_JSON" | python3 -m json.tool

echo
echo "===== Response ====="
curl -k -s \
  "$WEB_BASE/grommunio.php?subsystem=webapp_probe_$(date +%s)" \
  -H "Content-Type: application/json; charset=UTF-8;" \
  -H "Accept: */*" \
  -H "Origin: ${WEB_BASE%/web}" \
  -H "Referer: ${WEB_BASE}/" \
  -b "grommunioAuthJwt=${TOKEN}; domainname=arvera.es; lang=es_ES" \
  --data-raw "$REQUEST_JSON" \
  | python3 -m json.tool
