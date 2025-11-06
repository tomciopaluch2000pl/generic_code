#!/usr/bin/env bash
# =============================================================================
# NAME:         hcp_list_containers.sh
# PURPOSE:      Enumerate all container objects (.ccf) in a namespace on
#               one or more HCP nodes by listing folders and then objects.
#
# HOW IT WORKS (high level):
#   1) For each node, list top-level "folders" under /rest/ (XML directory feed)
#      using a paginated listing (marker + max-results).
#   2) For each folder, list objects inside (paginated) and collect *.ccf names.
#   3) Build full container paths: <folder>/<file>.ccf
#   4) Write per-node lists: hcp1.txt, hcp2.txt, ...
#   5) Merge & produce:
#        - results_found.tsv  (path \t nodes)
#        - multi_location.txt (paths present on >1 node)
#        - results_codes.tsv  (HTTP codes per node for top-level calls)
#        - scan.log           (human-readable progress log)
#
# NOTES:
#   - No environment-specific names: everything is passed via CLI flags.
#   - Temporary XML files are removed unless --debug is set.
#   - Uses only curl+awk (xmllint optional; not required).
#
# USAGE EXAMPLE:
#   ./hcp_list_containers.sh \
#       --namespace my-namespace \
#       --tenant    mytenant \
#       --domain    example.net \
#       --token     'b2t...95449' \
#       --nodes     "hcp1 hcp2 hcp3 hcp4" \
#       --out-dir   output \
#       --page-size 1000 \
#       --insecure \
#       --debug
#
# REQUIRED PARAMS:
#   --namespace  HCP namespace name (DNS label)
#   --tenant     Tenant (DNS label)
#   --domain     HCP base domain (e.g., hacl.example.net)
#   --token      Value for:  -H "Authorization: HCP <TOKEN>"
#   --nodes      Space-separated node labels, e.g. "hcp1 hcp2 hcp3 hcp4"
#
# OPTIONAL:
#   --out-dir    Output root (default: ./output)
#   --page-size  max-results per request (default: 1000)
#   --insecure   Add -k to curl
#   --debug      Keep XML pages and increase logging
#
# OUTPUT (inside out-dir/<timestamp>/):
#   hcp1.txt, hcp2.txt, ...   -> one full path per line
#   results_found.tsv         -> "path<TAB>nodes" (nodes joined with comma)
#   multi_location.txt        -> subset of results_found with >1 node
#   results_codes.tsv         -> "node<TAB>http_code<TAB>info"
#   scan.log                  -> verbose activity log
# =============================================================================
set -euo pipefail

# ---------- Defaults ----------
NS=""; TENANT=""; DOMAIN=""; TOKEN=""
NODES=()
OUT_ROOT="./output"
PAGE_SIZE=1000
INSECURE=0
DEBUG=0

# ---------- Helpers ----------
log()  { printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" | tee -a "$SCAN_LOG" >/dev/null; }
err()  { printf '[%(%Y-%m-%d %H:%M:%S)T] ERROR: %s\n' -1 "$*" | tee -a "$SCAN_LOG" >/dev/null >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  $0 --namespace NS --tenant TEN --domain DOMAIN --token TOKEN --nodes "hcp1 hcp2 ..." [options]

Required:
  --namespace   Namespace DNS label (e.g., "ns123")
  --tenant      Tenant DNS label   (e.g., "acme")
  --domain      Base domain        (e.g., "hcp.example.net")
  --token       Value for curl header: Authorization: HCP <TOKEN>
  --nodes       Space-separated nodes (e.g., "hcp1 hcp2 hcp4")

Options:
  --out-dir     Output root (default: ./output)
  --page-size   max-results per request (default: 1000)
  --insecure    Use curl -k (ignore TLS issues)
  --debug       Keep raw XML pages and increase logs
  -h|--help     Show this help
EOF
}

# ---------- Arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="${2:-}"; shift 2 ;;
    --tenant)    TENANT="${2:-}"; shift 2 ;;
    --domain)    DOMAIN="${2:-}"; shift 2 ;;
    --token)     TOKEN="${2:-}"; shift 2 ;;
    --nodes)     read -r -a NODES <<<"${2:-}"; shift 2 ;;
    --out-dir)   OUT_ROOT="${2:-}"; shift 2 ;;
    --page-size) PAGE_SIZE="${2:-}"; shift 2 ;;
    --insecure)  INSECURE=1; shift ;;
    --debug)     DEBUG=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$NS"      ]] || die "--namespace is required"
[[ -n "$TENANT"  ]] || die "--tenant is required"
[[ -n "$DOMAIN"  ]] || die "--domain is required"
[[ -n "$TOKEN"   ]] || die "--token is required"
[[ ${#NODES[@]} -gt 0 ]] || die "--nodes is required (space-separated)"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_ROOT}/${TS}"
mkdir -p "$OUT_DIR"

# Files created later (declared now for shellcheck)
SCAN_LOG="${OUT_DIR}/scan.log"
RESULTS_FOUND="${OUT_DIR}/results_found.tsv"
RESULTS_CODES="${OUT_DIR}/results_codes.tsv"
MULTI_LOC="${OUT_DIR}/multi_location.txt"

# Start logs
: >"$SCAN_LOG"
: >"$RESULTS_FOUND"
: >"$RESULTS_CODES"

log "Output directory: $OUT_DIR"
log "Namespace: $NS, Tenant: $TENANT, Domain: $DOMAIN"
log "Nodes: ${NODES[*]}"
log "Page size: $PAGE_SIZE ; Insecure: $INSECURE ; Debug: $DEBUG"

# curl flags
CURL_OPTS=(-sS --fail -H "Authorization: HCP ${TOKEN}")
[[ $INSECURE -eq 1 ]] && CURL_OPTS+=(-k)

# ---------- XML parsing (awk) ----------
# Extracts folder names (urlName ending with -L) from an XML "directory" listing.
# Works with or without XML namespaces.
parse_folders() {
  # Input: XML on stdin
  # Output: one folder per line (e.g., "04f-...-L")
  awk '
    BEGIN { IGNORECASE=1 }
    /<entry/ && /type="directory"/ {
      # try to capture urlName="...-L"
      if (match($0, /urlName="([^"]+-L)"/, m)) {
        print m[1];
      }
    }
  '
}

# Extracts *.ccf object names from an XML directory listing.
parse_objects() {
  # Input: XML on stdin
  # Output: one filename per line (e.g., "0000000000410000.ccf")
  awk '
    BEGIN { IGNORECASE=1 }
    /<entry/ && /type="object"/ && /\.ccf"/ {
      if (match($0, /urlName="([^"]+\.ccf)"/, m)) {
        print m[1];
      }
    }
  '
}

# ---------- HTTP helpers ----------
# Return only the HTTP code for a HEAD/GET request
http_code_only() {
  local url="$1"
  curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}\n' "$url" || echo "000"
}

# Fetch a page (GET). On success, print body to stdout and write HTTP code to a var.
fetch_page() {
  local url="$1" ; local -n _code_ref="$2"
  local tmp=$(mktemp)
  if curl "${CURL_OPTS[@]}" -w '\n%{http_code}\n' "$url" >"$tmp" 2>>"$SCAN_LOG"; then
    _code_ref="$(tail -n1 "$tmp")"
    sed '$d' "$tmp"   # print body without the last line (code)
    rm -f "$tmp"
    return 0
  else
    _code_ref="000"
    rm -f "$tmp"
    return 1
  fi
}

# ---------- Pagination helpers ----------
# We use marker-based pagination. For folder listing:
#   /rest/?type=directory&format=xml&max-results=...&marker=<last>
# For a folder's objects:
#   /rest/<folder>/?type=directory&format=xml&max-results=...&marker=<last>
#
# If your HCP requires a different parameter name for paging, adjust MARKER_KEY.
MARKER_KEY="marker"

build_root_url() {
  local node="$1"
  printf 'https://%s.%s.%s.%s/rest/' "$NS" "$TENANT" "$node" "$DOMAIN"
}

build_dir_url() {
  local node="$1" ; local folder="$2"  # folder may be empty for top-level
  if [[ -z "$folder" ]]; then
    build_root_url "$node"
  else
    # Ensure single slash between /rest and folder
    printf '%s%s/' "$(build_root_url "$node")" "$folder"
  fi
}

build_query() {
  local marker="$1"
  if [[ -n "$marker" ]]; then
    printf '?type=directory&format=xml&max-results=%s&%s=%s' "$PAGE_SIZE" "$MARKER_KEY" "$marker"
  else
    printf '?type=directory&format=xml&max-results=%s' "$PAGE_SIZE"
  fi
}

# ---------- Main per-node scan ----------
scan_node() {
  local node="$1"
  local per_node_file="${OUT_DIR}/${node}.txt"
  : >"$per_node_file"

  log "==> [$node] Listing folders ..."
  local marker="" page=0 httpc=""
  local top_xml=""
  local folders_log="${OUT_DIR}/${node}_folders.log"
  : >"$folders_log"

  # Top-level (folders) pagination loop
  while : ; do
    page=$((page+1))
    local url="$(build_dir_url "$node" "")$(build_query "$marker")"
    [[ $DEBUG -eq 1 ]] && log "[$node] GET (folders) page=${page} : $url"

    top_xml="$(fetch_page "$url" httpc || true)"
    echo -e "${node}\t${httpc}\troot_page_${page}" >> "$RESULTS_CODES"

    if [[ "$httpc" != "200" || -z "$top_xml" ]]; then
      err "[$node] Failed folders page=${page}, HTTP=$httpc"
      break
    fi

    # Save raw page only in debug
    if [[ $DEBUG -eq 1 ]]; then
      echo "$top_xml" > "${OUT_DIR}/${node}_folders_p${page}.xml"
    fi

    # Parse folders
    mapfile -t page_folders < <(echo "$top_xml" | parse_folders)
    if [[ ${#page_folders[@]} -eq 0 ]]; then
      log "[$node] No folders parsed on page ${page}. Stopping."
      break
    fi
    printf '%s\n' "${page_folders[@]}" >> "$folders_log"

    # Decide next marker: last folder name on this page
    marker="${page_folders[-1]}"

    # If returned less than PAGE_SIZE, we reached the end
    if [[ ${#page_folders[@]} -lt $PAGE_SIZE ]]; then
      break
    fi
  done

  local total_folders
  total_folders=$(wc -l < "$folders_log" || echo 0)
  log "[$node] Folders found: $total_folders"

  # For each folder -> list objects (paginated)
  local f count=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    count=$((count+1))
    log "[$node] (${count}/${total_folders}) Folder: $f"

    local obj_marker="" obj_page=0 obj_xml=""
    while : ; do
      obj_page=$((obj_page+1))
      local url="$(build_dir_url "$node" "$f")$(build_query "$obj_marker")"
      [[ $DEBUG -eq 1 ]] && log "[$node] GET (objects) folder=$f page=${obj_page} : $url"
      obj_xml="$(fetch_page "$url" httpc || true)"
      echo -e "${node}\t${httpc}\t${f}_page_${obj_page}" >> "$RESULTS_CODES"

      if [[ "$httpc" != "200" || -z "$obj_xml" ]]; then
        err "[$node] Failed objects folder=$f page=${obj_page}, HTTP=$httpc"
        break
      fi

      [[ $DEBUG -eq 1 ]] && echo "$obj_xml" > "${OUT_DIR}/${node}_${f//\//-}_p${obj_page}.xml"

      # Parse .ccf files and append as full paths
      mapfile -t files < <(echo "$obj_xml" | parse_objects)
      if [[ ${#files[@]} -gt 0 ]]; then
        for fn in "${files[@]}"; do
          printf '%s/%s\n' "$f" "$fn" >> "$per_node_file"
        done
      fi

      # Next page decision
      if [[ ${#files[@]} -lt $PAGE_SIZE ]]; then
        break
      else
        obj_marker="${files[-1]}"
      fi
    done
  done < "$folders_log"

  # Deduplicate per node list
  if [[ -s "$per_node_file" ]]; then
    sort -u -o "$per_node_file" "$per_node_file"
    log "[$node] Containers collected: $(wc -l < "$per_node_file")"
  else
    log "[$node] No containers collected."
  fi

  # Cleanup temporary folder list unless debug
  if [[ $DEBUG -eq 0 ]]; then
    rm -f "$folders_log" "${OUT_DIR}/${node}_folders_p"*.xml "${OUT_DIR}/${node}_"*.xml 2>/dev/null || true
  fi
}

# ---------- Run for all nodes ----------
for n in "${NODES[@]}"; do
  scan_node "$n"
done

# ---------- Merge & reports ----------
log "Building merged reports ..."

# Build results_found.tsv: path \t nodes (comma-separated)
# 1) paste node name to each line of its file -> path \t node
# 2) group by path and join nodes with comma
TMP_MERGED="${OUT_DIR}/_merged.tmp"
: >"$TMP_MERGED"
for n in "${NODES[@]}"; do
  f="${OUT_DIR}/${n}.txt"
  [[ -s "$f" ]] || continue
  awk -v N="$n" '{print $0 "\t" N}' "$f" >> "$TMP_MERGED"
done

if [[ -s "$TMP_MERGED" ]]; then
  # group & join nodes
  awk -F'\t' '
    { a[$1] = (a[$1] ? a[$1] "," $2 : $2) }
    END { for (k in a) print k "\t" a[k] }
  ' "$TMP_MERGED" | sort > "$RESULTS_FOUND"
fi

# multi_location: entries where nodes column contains a comma
: >"$MULTI_LOC"
if [[ -s "$RESULTS_FOUND" ]]; then
  awk -F'\t' 'NF>=2 && $2 ~ /,/ {print $0}' "$RESULTS_FOUND" > "$MULTI_LOC"
fi

log "SUMMARY:"
for n in "${NODES[@]}"; do
  f="${OUT_DIR}/${n}.txt"
  printf "  - %-6s : %s\n" "$n" "$( [[ -s $f ]] && wc -l < "$f" || echo 0 )" | tee -a "$SCAN_LOG" >/dev/null
done
printf "  - results_found.tsv : %s rows\n" "$( [[ -s $RESULTS_FOUND ]] && wc -l < "$RESULTS_FOUND" || echo 0 )" | tee -a "$SCAN_LOG" >/dev/null
printf "  - multi_location.txt: %s rows\n" "$( [[ -s $MULTI_LOC ]] && wc -l < "$MULTI_LOC" || echo 0 )" | tee -a "$SCAN_LOG" >/dev/null
printf "  - results_codes.tsv : %s rows\n" "$( [[ -s $RESULTS_CODES ]] && wc -l < "$RESULTS_CODES" || echo 0 )" | tee -a "$SCAN_LOG" >/dev/null

log "Done."