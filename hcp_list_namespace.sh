#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# PURPOSE:
#   Fast HCP inventory by namespace: list folders, list objects per folder,
#   build full container paths, and aggregate per-node results.
#
# DESCRIPTION:
#   The script connects to one or more HCP nodes via REST API.
#   For each node it:
#     - Lists all folders (type=directory) within the namespace.
#     - For each folder, lists all objects (type=object).
#     - Builds full container paths (<folder>/<object>.ccf).
#   Finally, it aggregates all results into summary TSV files.
#
# WHAT IT DOES NOT DO:
#   - Does NOT copy, move, or delete anything in HCP.
#   - Performs only HTTP GET operations for listing.
#
# REQUIREMENTS:
#   - bash, curl, awk, sed, sort, uniq
#   - HCP REST API access and valid Authorization token
#
# USAGE EXAMPLE:
#   ./hcp_list_namespace.sh \
#       --namespace my-namespace \
#       --tenant mytenant \
#       --domain mydomain.example.net \
#       --token 'base64-encoded-hcp-token' \
#       --nodes "hcp1 hcp2 hcp3 hcp4" \
#       --out-dir ./output \
#       --batch 1000 \
#       --debug \
#       --insecure
#
# OUTPUT FILES (under ./output/<timestamp>/):
#   hcp1.txt .. hcp4.txt         - full list of containers per node
#   results_found.tsv            - TSV mapping: path <TAB> nodes (comma-separated)
#   multi_location.txt           - paths present on multiple nodes
#   scan.log                     - execution log
#   raw/                         - optional raw XML pages (only with --debug)
# ------------------------------------------------------------------------------

# ---------- defaults ----------
NAMESPACE=""
TENANT=""
DOMAIN=""
TOKEN=""
NODES=()
OUT_BASE="./output"
BATCH=1000
DEBUG=0
INSECURE=0

usage() {
  cat <<EOF
Usage:
  $0 --namespace NS --tenant TENANT --domain DOMAIN --token TOKEN \\
     --nodes "hcp1 hcp2 [hcp3 ...]" [--out-dir DIR] [--batch N] [--debug] [--insecure]

Options:
  --namespace   Namespace name (appears before tenant in the URL)
  --tenant      Tenant (2nd label in the URL)
  --domain      Domain (rest of FQDN, e.g. example.net)
  --token       HCP access token (value only, without "Authorization: HCP ")
  --nodes       Space-separated list of HCP nodes to scan (e.g. "hcp1 hcp2 hcp3 hcp4")
  --out-dir     Base output directory (default: ./output)
  --batch       Listing page size (default: 1000)
  --debug       Keep raw XML responses for audit/debug
  --insecure    Allow self-signed certificates (adds -k to curl)
EOF
}

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:-}"; shift 2 ;;
    --tenant)    TENANT="${2:-}";    shift 2 ;;
    --domain)    DOMAIN="${2:-}";    shift 2 ;;
    --token)     TOKEN="${2:-}";     shift 2 ;;
    --nodes)     read -r -a NODES <<< "${2:-}"; shift 2 ;;
    --out-dir)   OUT_BASE="${2:-}";  shift 2 ;;
    --batch)     BATCH="${2:-}";     shift 2 ;;
    --debug)     DEBUG=1;            shift 1 ;;
    --insecure)  INSECURE=1;         shift 1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------- validation ----------
[[ -n "$NAMESPACE" ]] || { echo "ERROR: --namespace required" >&2; exit 1; }
[[ -n "$TENANT"    ]] || { echo "ERROR: --tenant required"    >&2; exit 1; }
[[ -n "$DOMAIN"    ]] || { echo "ERROR: --domain required"    >&2; exit 1; }
[[ -n "$TOKEN"     ]] || { echo "ERROR: --token required"     >&2; exit 1; }
[[ ${#NODES[@]} -gt 0 ]] || { echo "ERROR: --nodes required"  >&2; exit 1; }

# ---------- layout ----------
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_BASE}/${TS}"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${OUT_DIR}" "${RAW_DIR}"

LOG="${OUT_DIR}/scan.log"
touch "$LOG"

curl_k=()
(( INSECURE )) && curl_k=(-k)

log() { printf '[%s] %s\n' "$(date +%F\ %T)" "$*" | tee -a "$LOG" >/dev/null; }

# ---------- helpers ----------
node_base_url() {
  local node="$1"
  printf 'https://%s.%s.%s.%s/rest/' "$NAMESPACE" "$TENANT" "$node" "$DOMAIN"
}

fetch_page() {
  local node="$1" rel="$2" typ="$3" marker="${4:-}"
  local url marker_arg
  url="$(node_base_url "$node")${rel}"
  marker_arg=""
  [[ -n "$marker" ]] && marker_arg="&marker=$(printf '%s' "$marker" | sed 's/ /%20/g')"
  curl "${curl_k[@]}" -sS \
    -H "Authorization: HCP ${TOKEN}" \
    "${url}?type=${typ}&format=xml&max-results=${BATCH}${marker_arg}"
}

parse_next_marker() { sed -n 's:.*<nextMarker>\([^<]*\)</nextMarker>.*:\1:p' | tr -d '\r'; }
parse_url_names()  { sed -n 's:.*<entry urlName="\([^"]*\)".*:\1:p' | tr -d '\r'; }

# ---------- main listing per node ----------
list_node() {
  local node="$1"
  local node_tag="$node"
  local folders_xml="${RAW_DIR}/${node_tag}_folders"
  local folders_lst="${OUT_DIR}/${node_tag}_folders.lst"
  local files_lst="${OUT_DIR}/${node_tag}_files.lst"
  local containers_txt="${OUT_DIR}/${node_tag}.txt"

  : > "$folders_lst"
  : > "$files_lst"
  : > "$containers_txt"

  log "[$node] Listing folders..."
  local marker="" page=1
  while :; do
    local xml
    xml="$(fetch_page "$node" "" "directory" "$marker" || true)"
    [[ -z "$xml" ]] && { log "[$node] Empty response (folders), stopping."; break; }

    (( DEBUG )) && printf '%s\n' "$xml" > "${folders_xml}_p${page}.xml"
    printf '%s\n' "$xml" | parse_url_names >> "$folders_lst"

    marker="$(printf '%s\n' "$xml" | parse_next_marker || true)"
    [[ -z "$marker" ]] && break
    ((page++))
  done

  awk 'NF>0{print}' "$folders_lst" | sort -u -o "$folders_lst"
  log "[$node] Folders: $(wc -l < "$folders_lst")"

  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local omarker="" opage=1
    while :; do
      local oxml
      oxml="$(fetch_page "$node" "${f}/" "object" "$omarker" || true)"
      [[ -z "$oxml" ]] && break
      (( DEBUG )) && printf '%s\n' "$oxml" > "${RAW_DIR}/${node}_${f//\//_}_objects_p${opage}.xml"
      printf '%s\n' "$oxml" | parse_url_names >> "$files_lst"
      omarker="$(printf '%s\n' "$oxml" | parse_next_marker || true)"
      [[ -z "$omarker" ]] && break
      ((opage++))
    done
    awk -v PFX="$f" 'NF>0 && $0 ~ /\.ccf$/ {print PFX "/" $0}' "$files_lst" >> "$containers_txt"
    : > "$files_lst"
  done < "$folders_lst"

  if [[ -f "$containers_txt" ]]; then
    sort -u -o "$containers_txt" "$containers_txt"
  fi
  log "[$node] Containers found: $(wc -l < "$containers_txt" 2>/dev/null || echo 0)"
}

# ---------- run for all nodes ----------
log "Namespace: ${NAMESPACE}, Tenant: ${TENANT}, Domain: ${DOMAIN}"
log "Nodes: ${NODES[*]}"
log "Output: ${OUT_DIR}"
(( DEBUG )) && log "Debug mode ON (raw XML pages will be saved)."

for n in "${NODES[@]}"; do
  list_node "$n"
done

# ---------- aggregation ----------
log "Aggregating per-node lists -> results_found.tsv + multi_location.txt ..."
TMP_TAGGED="$(mktemp)"
for n in "${NODES[@]}"; do
  node_file="${OUT_DIR}/${n}.txt"
  [[ -s "$node_file" ]] || continue
  awk -v NODE="$n" 'NF>0{print $0 "\t" NODE}' "$node_file"
done | sort > "$TMP_TAGGED"

RESULTS="${OUT_DIR}/results_found.tsv"
awk -F'\t' '
  { paths[$1] = (paths[$1] ? paths[$1] "," $2 : $2) }
  END { for (p in paths) print p "\t" paths[p] }
' "$TMP_TAGGED" | sort > "$RESULTS"
rm -f "$TMP_TAGGED"

awk -F'\t' 'NF==2 && $2 ~ /,/ {print $1 "\t" $2}' "$RESULTS" | sort > "${OUT_DIR}/multi_location.txt"

log "Aggregation done."
log "results_found.tsv rows: $(wc -l < "$RESULTS")"
log "multi_location.txt rows: $(wc -l < "${OUT_DIR}/multi_location.txt")"

CODES="${OUT_DIR}/results_codes.tsv"
{
  echo -e "path\tnodes"
  cat "$RESULTS"
} > "$CODES"

log "Finished."
log "Artifacts:"
for f in "${OUT_DIR}/"*.txt "${OUT_DIR}/"*.tsv "$LOG"; do
  [[ -f "$f" ]] && echo " - $f"
done