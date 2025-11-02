#!/bin/bash
# Diagnose a single object: decide would-copy / skip-exists / no-source.
# Input path must be: <namespace>/<object-path>

set -euo pipefail

TENANT=""; DOMAIN=""; TOKEN=""
TARGET=""; NODES=""; LINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) TENANT="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --token)  TOKEN="$2";  shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --nodes)  NODES="$2";  shift 2 ;;
    --line)   LINE="$2";   shift 2 ;;
    -h|--help)
      echo "Usage: $0 --tenant T --domain D --token 'TOK' --target hcpX --nodes 'hcp1 hcp2 ...' --line 'ns/key'"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ -n "$TENANT" && -n "$DOMAIN" && -n "$TOKEN" && -n "$TARGET" && -n "$NODES" && -n "$LINE" ]] \
  || { echo "Missing args"; exit 1; }

NS="${LINE%%/*}"
KEY="${LINE#*/}"

dst_url="https://${NS}.${TENANT}.${TARGET}.${DOMAIN}/rest/${KEY}"
dst_code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: HCP ${TOKEN}" "$dst_url")

echo "LINE       : $LINE"
echo "DST check  : ${TARGET} -> HTTP $dst_code"

if [[ "$dst_code" =~ ^(200|204|206)$ ]]; then
  echo "DECISION   : SKIP (already on target)"
  exit 0
fi

found_src=""
for n in $NODES; do
  [[ "$n" == "$TARGET" ]] && continue
  src_url="https://${NS}.${TENANT}.${n}.${DOMAIN}/rest/${KEY}"
  src_code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: HCP ${TOKEN}" "$src_url")
  echo "SRC check  : ${n} -> HTTP $src_code"
  if [[ "$src_code" =~ ^(200|204|206)$ ]]; then
    found_src="$n"
    break
  fi
done

if [[ -n "$found_src" ]]; then
  echo "DECISION   : WOULD COPY from $found_src -> $TARGET"
else
  echo "DECISION   : NO SOURCE on any node"
fi
