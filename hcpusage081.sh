#!/bin/ksh
###############################################################################
#
# Script Name : hcp_namespace_usage.sh
#
# Description :
#   Collects capacity utilization statistics for HCP namespaces using the
#   HCP Namespace REST API (/proc/statistics).
#
#   The script connects directly to each namespace over HTTPS, retrieves
#   namespace statistics and generates:
#
#     - Detailed namespace utilization report
#     - Summary by Region and HCP Type
#     - Summary by HCP Node
#     - CSV report for Excel import
#
#   Hostname resolution is performed using curl --resolve, therefore
#   no /etc/hosts entries are required.
#
# Input File :
#   hcp_namespaces.conf
#
# Input Format :
#   namespace_fqdn;ip_address;authorization_token
#
# Example :
#   namespace.example.com;192.168.1.10;AUTH_TOKEN
#
# Requirements :
#   - AIX 7.x
#   - Korn Shell (ksh)
#   - curl
#   - awk
#   - sed
#
# Usage :
#   chmod 755 hcp_namespace_usage.sh
#   chmod 600 hcp_namespaces.conf
#
#   ./hcp_namespace_usage.sh
#   ./hcp_namespace_usage.sh hcp_namespaces.conf
#
# Author  :
# Team    :
# Version : v0.8.1
# Date    :
#
# Change History
# -----------------------------------------------------------------------------
# v0.1
#   - Initial implementation.
#   - Namespace capacity collection using HCP Namespace REST API.
#
# v0.2
#   - Improved compatibility with AIX.
#   - Better handling of configuration file parsing.
#
# v0.3
#   - Improved authentication token handling.
#   - Added validation of input data.
#
# v0.4
#   - XML parser updated to support attribute-based responses.
#   - Improved error handling.
#
# v0.5
#   - Added support for curl --resolve.
#   - IP address can now be provided in the configuration file.
#   - /etc/hosts entries are no longer required.
#
# v0.6
#   - Automatic extraction of Tenant and HCP Node from namespace FQDN.
#   - Automatic detection of HCP Type (NGA / STaaS).
#
# v0.7
#   - Automatic Region detection.
#   - Added summary by Region and HCP Type.
#   - Added summary by HCP Node.
#   - General code cleanup and reporting improvements.
#
# v0.8.0
#   - Added optional CSV report generation for Excel import.
#
# v0.8.1
#   - CSV report is generated automatically on every run.
#   - CSV file name includes date and timestamp to avoid overwriting reports.
#
###############################################################################

INPUT_FILE="${1:-hcp_namespaces.conf}"
RUN_TS=$(date '+%Y%m%d_%H%M%S')
CSV_FILE="hcp_namespace_usage_${RUN_TS}.csv"
TMP_FILE="/tmp/hcp_namespace_usage_summary.$$"

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: Input file not found: $INPUT_FILE"
  exit 1
fi

> "$TMP_FILE"

echo "HCP_TYPE,REGION,NAMESPACE,TENANT,HCP_NODE,USED_GIB,TOTAL_GIB,USED_PERCENT,OBJECTS,USED_BYTES,TOTAL_BYTES" > "$CSV_FILE"

printf "%-7s %-7s %-30s %-35s %-15s %12s %12s %10s %12s\n" \
  "TYPE" "REGION" "NAMESPACE" "TENANT" "HCP_NODE" \
  "USED_GIB" "TOTAL_GIB" "USED_%" "OBJECTS"

printf "%-7s %-7s %-30s %-35s %-15s %12s %12s %10s %12s\n" \
  "----" "------" "---------" "------" "--------" \
  "--------" "---------" "------" "-------"

while IFS=';' read ns_url ip token rest
do
  ns_url=$(echo "$ns_url" | sed 's/^[ 	]*//;s/[ 	\r]*$//')
  ip=$(echo "$ip" | sed 's/^[ 	]*//;s/[ 	\r]*$//')
  token=$(echo "$token" | sed 's/^[ 	]*//;s/[ 	\r]*$//')

  case "$ns_url" in
    ""|\#*) continue ;;
  esac

  namespace_from_url=$(echo "$ns_url" | awk -F'.' '{print $1}')
  tenant=$(echo "$ns_url" | awk -F'.' '{print $2}')
  hcp_node=$(echo "$ns_url" | awk -F'.' '{print $3}')

  case "$hcp_node" in
    hcp*) hcp_type="NGA" ;;
    *)    hcp_type="STaaS" ;;
  esac

  case "$ns_url" in
    *hacl*) region="EMEA" ;;
    *stm*)  region="AMER" ;;
    *sh90*) region="AMER" ;;
    *zur*)  region="CH" ;;
    *sng*)  region="APAC" ;;
    *sha*|*shanghai*|*bj*|*beijing*|*pek*) region="CHINA" ;;
    *)      region="UNKNOWN" ;;
  esac

  if [ -z "$ip" ] || [ -z "$token" ]; then
    printf "%-7s %-7s %-30s %-35s %-15s %12s %12s %10s %12s\n" \
      "$hcp_type" "$region" "$namespace_from_url" "$tenant" "$hcp_node" \
      "MISSING" "MISSING" "MISSING" "-"

    echo "$hcp_type,$region,$namespace_from_url,$tenant,$hcp_node,MISSING,MISSING,MISSING,-,," >> "$CSV_FILE"
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

  if [ -z "$namespace" ]; then
    namespace="$namespace_from_url"
  fi

  if [ -z "$used" ] || [ -z "$total" ] || [ "$total" = "0" ]; then
    printf "%-7s %-7s %-30s %-35s %-15s %12s %12s %10s %12s\n" \
      "$hcp_type" "$region" "$namespace" "$tenant" "$hcp_node" \
      "ERROR" "ERROR" "ERROR" "-"

    echo "$hcp_type,$region,$namespace,$tenant,$hcp_node,ERROR,ERROR,ERROR,-,," >> "$CSV_FILE"
    continue
  fi

  if [ -z "$objects" ]; then
    objects="0"
  fi

  echo "$hcp_type;$region;$namespace;$tenant;$hcp_node;$used;$total;$objects" >> "$TMP_FILE"

  awk -v type="$hcp_type" \
      -v region="$region" \
      -v ns="$namespace" \
      -v tenant="$tenant" \
      -v hcp="$hcp_node" \
      -v used="$used" \
      -v total="$total" \
      -v objects="$objects" \
      -v csv="$CSV_FILE" '
  BEGIN {
    used_gib = used / 1024 / 1024 / 1024
    total_gib = total / 1024 / 1024 / 1024
    pct = used / total * 100

    printf "%-7s %-7s %-30s %-35s %-15s %12.0f %12.0f %9.1f%% %12s\n",
           type, region, ns, tenant, hcp,
           used_gib, total_gib, pct, objects

    printf "%s,%s,%s,%s,%s,%.0f,%.0f,%.1f,%s,%.0f,%.0f\n",
           type, region, ns, tenant, hcp,
           used_gib, total_gib, pct, objects, used, total >> csv
  }'

done < "$INPUT_FILE"

echo
echo "SUMMARY BY REGION / TYPE"
echo "--------------------------------------------------------------------------------"

printf "%-7s %-7s %12s %14s %14s %10s\n" \
  "TYPE" "REGION" "NAMESPACES" "USED_TIB" "TOTAL_TIB" "USED_%"

printf "%-7s %-7s %12s %14s %14s %10s\n" \
  "----" "------" "----------" "--------" "---------" "------"

awk -F';' '
{
  type=$1
  region=$2
  used=$6
  total=$7
  key=type ";" region

  used_sum[key]+=used
  total_sum[key]+=total
  count[key]++

  grand_used+=used
  grand_total+=total
  grand_count++
}
END {
  for (key in used_sum) {
    split(key,a,";")
    type=a[1]
    region=a[2]

    used_tib=used_sum[key]/1024/1024/1024/1024
    total_tib=total_sum[key]/1024/1024/1024/1024
    pct=used_sum[key]/total_sum[key]*100

    printf "%-7s %-7s %12d %14.1f %14.1f %9.1f%%\n",
           type, region, count[key], used_tib, total_tib, pct
  }

  if (grand_total > 0) {
    printf "%-7s %-7s %12d %14.1f %14.1f %9.1f%%\n",
           "TOTAL", "ALL", grand_count,
           grand_used/1024/1024/1024/1024,
           grand_total/1024/1024/1024/1024,
           grand_used/grand_total*100
  }
}
' "$TMP_FILE"

echo
echo "SUMMARY BY HCP NODE"
echo "--------------------------------------------------------------------------------"

printf "%-7s %-7s %-20s %12s %14s %14s %10s\n" \
  "TYPE" "REGION" "HCP_NODE" "NAMESPACES" "USED_TIB" "TOTAL_TIB" "USED_%"

printf "%-7s %-7s %-20s %12s %14s %14s %10s\n" \
  "----" "------" "--------" "----------" "--------" "---------" "------"

awk -F';' '
{
  type=$1
  region=$2
  hcp=$5
  used=$6
  total=$7
  key=type ";" region ";" hcp

  used_sum[key]+=used
  total_sum[key]+=total
  count[key]++
}
END {
  for (key in used_sum) {
    split(key,a,";")
    type=a[1]
    region=a[2]
    hcp=a[3]

    used_tib=used_sum[key]/1024/1024/1024/1024
    total_tib=total_sum[key]/1024/1024/1024/1024
    pct=used_sum[key]/total_sum[key]*100

    printf "%-7s %-7s %-20s %12d %14.1f %14.1f %9.1f%%\n",
           type, region, hcp, count[key], used_tib, total_tib, pct
  }
}
' "$TMP_FILE"

rm -f "$TMP_FILE"

echo
echo "CSV report generated: $CSV_FILE"

exit 0