#!/bin/ksh
#
# hcp_namespace_usage_non_nga.sh
# Version: v0.2 AIX-safe
#
# Input file format:
# namespace_url;token
#
# Example:
# ns1.tenant.hcp.example.net;b2tnYWRtaW46xxxx
# ns2.tenant.hcp.example.net;b2tnYWRtaW46yyyy

INPUT_FILE="${1:-hcp_namespaces.conf}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file not found: $INPUT_FILE"
  exit 1
fi

printf "%-60s %12s %12s %10s %12s\n" \
  "NAMESPACE" "USED_GIB" "TOTAL_GIB" "USED_%" "OBJECTS"

printf "%-60s %12s %12s %10s %12s\n" \
  "---------" "--------" "---------" "------" "-------"

while IFS=';' read ns_url token rest
do
  ns_url=$(echo "$ns_url" | sed 's/^[ 	]*//;s/[ 	\r]*$//')
  token=$(echo "$token" | sed 's/^[ 	]*//;s/[ 	\r]*$//')

  case "$ns_url" in
    ""|\#*) continue ;;
  esac

  if [ -z "$token" ]; then
    printf "%-60s %12s %12s %10s %12s\n" \
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

  if [ -z "$used" ] || [ -z "$total" ] || [ "$total" = "0" ]; then
    printf "%-60s %12s %12s %10s %12s\n" \
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

    printf "%-60s %12.0f %12.0f %9.1f%% %12s\n",
           ns, used_gib, total_gib, pct, objects
  }'

done < "$INPUT_FILE"