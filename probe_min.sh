#!/bin/bash
# Tiny probe: prints decision per line: COPY / SKIP / NO-SRC, plus HTTP codes.
set -euo pipefail

FILE="${1:?usage: $0 <list-file> <target-node> <tenant> <domain> <token> [sources...]}"
TARGET="${2:?}"; TENANT="${3:?}"; DOMAIN="${4:?}"; TOKEN="${5:?}"
shift 5
SOURCES=("$@") # e.g. hcp4 hcp3 hcp2

http_code() { curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: HCP ${TOKEN}" "$1" || echo 000; }

n=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="$(echo "$raw" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  ((n++))
  ns="${line%%/*}"; key="${line#*/}"
  dst="https://${ns}.${TENANT}.${TARGET}.${DOMAIN}/rest/${key}"
  dcode=$(http_code "$dst")
  printf '[%d] DST %-4s  %s\n' "$n" "$dcode" "$dst"
  if [[ "$dcode" =~ ^(200|204|206)$ ]]; then
    echo " -> SKIP (exists on ${TARGET})"
    continue
  fi
  decided=0
  for s in "${SOURCES[@]}"; do
    [[ "$s" == "$TARGET" ]] && continue
    src="https://${ns}.${TENANT}.${s}.${DOMAIN}/rest/${key}"
    scode=$(http_code "$src")
    printf '     SRC %-4s  (%s)\n' "$scode" "$s"
    if [[ "$scode" =~ ^(200|204|206)$ ]]; then
      echo " -> COPY  from ${s} -> ${TARGET}"
      decided=1; break
    fi
  done
  [[ $decided -eq 0 ]] && echo " -> NO-SRC"
done < "$FILE"