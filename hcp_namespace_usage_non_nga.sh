#!/bin/bash

INPUT_FILE="${1:-hcp_namespaces.conf}"

printf "%-45s %12s %12s %10s %12s\n" \
  "NAMESPACE" "USED_GIB" "TOTAL_GIB" "USED_%" "OBJECTS"

printf "%-45s %12s %12s %10s %12s\n" \
  "---------" "--------" "---------" "------" "-------"

while IFS=';' read -r ns_url token; do

  # skip empty lines and comments
  [[ -z "$ns_url" ]] && continue
  [[ "$ns_url" =~ ^[[:space:]]*# ]] && continue

  # remove spaces around fields
  ns_url=$(echo "$ns_url" | xargs)
  token=$(echo "$token" | xargs)

  if [[ -z "$ns_url" || -z "$token" ]]; then
    printf "%-45s %12s %12s %10s %12s\n" \
      "$ns_url" "MISSING" "MISSING" "MISSING" "-"
    continue
  fi

  xml=$(curl -sk --connect-timeout 10 --max-time 30 \
    -H "Authorization: HCP $token" \
    "https://${ns_url}/proc/statistics")

  namespace=$(echo "$xml" | awk -F'[<>]' '/<namespace>/ {print $3; exit}')
  used=$(echo "$xml" | awk -F'[<>]' '/<usedCapacityBytes>/ {print $3; exit}')
  total=$(echo "$xml" | awk -F'[<>]' '/<totalCapacityBytes>/ {print $3; exit}')
  objects=$(echo "$xml" | awk -F'[<>]' '/<objectCount>/ {print $3; exit}')

  if [[ -z "$used" || -z "$total" || "$total" == "0" ]]; then
    printf "%-45s %12s %12s %10s %12s\n" \
      "$ns_url" "ERROR" "ERROR" "ERROR" "-"
    continue
  fi

  [[ -z "$namespace" ]] && namespace="$ns_url"
  [[ -z "$objects" ]] && objects="0"

  awk -v ns="$namespace" \
      -v used="$used" \
      -v total="$total" \
      -v objects="$objects" '
  BEGIN {
    used_gib = used / 1024 / 1024 / 1024
    total_gib = total / 1024 / 1024 / 1024
    pct = used / total * 100

    printf "%-45s %12.0f %12.0f %9.1f%% %12s\n",
           ns, used_gib, total_gib, pct, objects
  }'

done < "$INPUT_FILE"