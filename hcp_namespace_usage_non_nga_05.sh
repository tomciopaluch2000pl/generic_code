#!/bin/ksh
#
# hcp_namespace_usage_non_nga.sh
# Version: v0.5 AIX-safe with IP resolve
#
# Input format:
# namespace_url;ip;token

INPUT_FILE="${1:-hcp_namespaces.conf}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file not found: $INPUT_FILE"
  exit 1
fi

printf "%-70s %12s %12s %10s %12s\n" \
  "NAMESPACE" "USED_GIB" "TOTAL_GIB" "USED_%" "OBJECTS"

printf "%-70s %12s %12s %10s %12s\n" \
  "---------" "--------" "---------" "------" "-------"

while IFS=';' read ns_url ip token rest
do
  ns_url=$(echo "$ns_url" | sed 's/^[ 	]*//;s/[ 	\r]*$//')
  ip=$(echo "$ip" | sed 's/^[ 	]*//;s/[ 	\r]*$//')
  token=$(echo "$token" | sed 's/^[ 	]*//;s/[ 	\r]*$//')

  case "$ns_url" in
    ""|\#*) continue ;;
  esac

  if [ -z "$ip" ] || [ -z "$token" ]; then
    printf "%-70s %12s %12s %10s %12s\n" \
      "$ns_url" "MISSING" "MISSING" "MISSING" "-"
    continue
  fi

  xml=$(curl -sk --connect-timeout 10 --max-time 30 \
    --resolve "${ns_url}:443:${ip}" \
    -H "Authorization: HCP $token" \
    "https://${ns_url}/proc/statistics")

  namespace=$(echo "$xml" | sed -n 's/.*namespaceName="\([^"]*\)".*/\1/p' | head -1)
  used=$(echo "$xml" | sed -n 's/.*usedCapacityBytes="\([^"]*\)".*/\1/p' | head -1)
  total=$(echo "$xml" | sed -n 's/.*totalCapacityBytes="\([^"]*\)".*/\1/p' | head -1)
  objects=$(echo "$xml" | sed -n 's/.*objectCount="\([^"]*\)".*/\1/p' | head -1)

  if [ -z "$used" ] || [ -z "$total" ] || [ "$total" = "0" ]; then
    printf "%-70s %12s %12s %10s %12s\n" \
      "$ns_url" "ERROR" "ERROR" "ERROR" "-"
    continue
  fi

  if [ -z "$namespace" ]; then
    namespace="$ns_url"
  fi

  if [ -z "$objects" ]; then
    objects="0"
  fi

  awk -v ns="$namespace" \
      -v used="$used" \
      -v total="$total" \
      -v objects="$objects" '
  BEGIN {
    used_gib = used / 1024 / 1024 / 1024
    total_gib = total / 1024 / 1024 / 1024
    pct = used / total * 100

    printf "%-70s %12.0f %12.0f %9.1f%% %12s\n",
           ns, used_gib, total_gib, pct, objects
  }'

done < "$INPUT_FILE"