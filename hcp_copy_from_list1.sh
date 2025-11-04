#!/bin/bash
set -euo pipefail

# ----- required -----
LIST_FILE=""; TENANT=""; DOMAIN=""; TOKEN=""
TARGET_NODE=""; SOURCES=""
# ----- optional -----
INSECURE=0; DRYRUN=0; DEBUG=0

usage(){ cat <<'EOF'
Usage:
  hcp_copy_from_list.sh \
    --list results_found.tsv \
    --tenant TENANT --domain DOMAIN \
    --token 'HCP_TOKEN' \
    --target hcp3 \
    --sources "hcp1 hcp2 hcp4" \
    [--insecure] [--dry-run] [--debug]

Input TSV header must be:  path<TAB>nodes
- path  = "namespace/relative/path.ccf"  (namespace is the first segment)
- nodes = strictly "hcpN" or "hcpN,hcpM,..." (commas only, NO SPACES)
EOF
}

# ------------- arg parse -------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_FILE="$2"; shift 2;;
    --tenant) TENANT="$2"; shift 2;;
    --domain) DOMAIN="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --target) TARGET_NODE="$2"; shift 2;;
    --sources) SOURCES="$2"; shift 2;;
    --insecure) INSECURE=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    --debug) DEBUG=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

[[ -n "$LIST_FILE" && -n "$TENANT" && -n "$DOMAIN" && -n "$TOKEN" && -n "$TARGET_NODE" && -n "$SOURCES" ]] \
  || { echo "ERROR: missing required arguments"; usage; exit 1; }
[[ -f "$LIST_FILE" ]] || { echo "ERROR: file not found: $LIST_FILE" >&2; exit 1; }

# ------------- output dirs -------------
STAMP="$(date +%Y%m%d_%H%M%S)"
OUTDIR="output/${STAMP}_copy_to_${TARGET_NODE}"
LOGDIR="${OUTDIR}/logs"; TMPDIR="${OUTDIR}/tmp"
mkdir -p "$OUTDIR" "$LOGDIR" "$TMPDIR"

LOG="${OUTDIR}/copy.log"
SCAN="${OUTDIR}/scan.log"
SUMMARY="${OUTDIR}/copy_summary.tsv"
COPIED="${OUTDIR}/copied.txt"
EXISTS="${OUTDIR}/skipped_exists.txt"
MULTI="${OUTDIR}/multi_source.txt"
TSV_TARGET_MISSING="${OUTDIR}/tsv_target_listed_but_missing.txt"
NOTINSRCSET="${OUTDIR}/not_in_sources.txt"
NOTFOUND="${OUTDIR}/not_found_on_source.txt"
FAILED="${OUTDIR}/failed.txt"
DRYLIST="${OUTDIR}/would_copy.txt"
BADFMT="${OUTDIR}/invalid_nodes_format.txt"

# init files
: >"$LOG"; : >"$SCAN"; : >"$SUMMARY"; : >"$COPIED"; : >"$EXISTS"; : >"$MULTI"
: >"$TSV_TARGET_MISSING"; : >"$NOTINSRCSET"; : >"$NOTFOUND"; : >"$FAILED"
: >"$DRYLIST"; : >"$BADFMT"

log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG" >/dev/null; }
dbg(){ (( DEBUG )) && log "DEBUG: $*"; }
scan(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" >> "$SCAN"; }

CURL_OPTS=(-sS -L); (( INSECURE )) && CURL_OPTS+=(-k)
AUTH=(-H "Authorization: HCP ${TOKEN}")

url_for(){ printf 'https://%s.%s.%s.%s/rest/%s' "$2" "$TENANT" "$1" "$DOMAIN" "$3"; }
http_code(){
  local node="$1" ns="$2" rel="$3" u code
  u="$(url_for "$node" "$ns" "$rel")"
  code="$(curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -I "${AUTH[@]}" "$u" || true)"
  scan "HEAD ${u} -> ${code}"
  echo "$code"
}
download_to_file(){
  local node="$1" ns="$2" rel="$3" outfile="$4" u
  u="$(url_for "$node" "$ns" "$rel")"
  dbg "DOWNLOAD: $u -> $outfile"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" "$u" -o "$outfile"
}
upload_from_file(){
  local node="$1" ns="$2" rel="$3" infile="$4" u
  u="$(url_for "$node" "$ns" "$rel")"
  dbg "UPLOAD: $infile -> $u"
  curl "${CURL_OPTS[@]}" -X PUT "${AUTH[@]}" \
       -H "Content-Type: application/octet-stream" \
       --data-binary @"$infile" "$u" -o /dev/null
}

strip_ns(){ echo "${1#*/}"; }
extract_ns(){ echo "${1%%/*}"; }

echo -e "path\tsource_nodes\ttarget_node\ttarget_http\tresult\tinfo" > "$SUMMARY"
ALLOWED_SRC_SET="$(echo "$SOURCES" | xargs -n1 | xargs)"

log "INPUT:   $LIST_FILE"
log "TENANT:  $TENANT"
log "DOMAIN:  $DOMAIN"
log "TARGET:  $TARGET_NODE"
log "SOURCES: $SOURCES"
(( DRYRUN )) && log "MODE:    DRY-RUN"
(( DEBUG ))  && log "MODE:    DEBUG"

# --- read TSV, skip header if present ---
{
  read -r header || true
  if [[ "$header" != $'path\tnodes' ]]; then echo "$header"; fi
  cat
} <"$LIST_FILE" | while IFS=$'\t' read -r PATH NODES || [[ -n "${PATH:-}" ]]; do
  [[ -z "${PATH:-}" ]] && continue

  NS="$(extract_ns "$PATH")"
  REL="$(strip_ns "$PATH")"

  # Strict validation
  if [[ ! "${NODES:-}" =~ ^hcp[0-9]+(,hcp[0-9]+)*$ ]]; then
    echo -e "${PATH}\t${NODES}" >> "$BADFMT"
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t-\tinvalid-nodes-format\t'${NODES}'" >> "$SUMMARY"
    dbg "INVALID NODES FORMAT: $PATH nodes='${NODES}'"
    continue
  fi

  # Always HEAD the target first
  TGT_CODE="$(http_code "$TARGET_NODE" "$NS" "$REL")"
  if [[ "$TGT_CODE" == "200" ]]; then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\texists\talready on target" >> "$SUMMARY"
    echo "$PATH" >> "$EXISTS"
    continue
  fi

  IFS=',' read -r -a NODE_ARR <<< "$NODES"
  contains_target=0
  for n in "${NODE_ARR[@]}"; do [[ "$n" == "$TARGET_NODE" ]] && contains_target=1; done
  if (( contains_target == 1 )); then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\ttsv-target-listed-but-missing\t-" >> "$SUMMARY"
    echo -e "${PATH}\t${NODES}" >> "$TSV_TARGET_MISSING"
    continue
  fi

  if ((${#NODE_ARR[@]} > 1)); then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\tmulti-source\t-" >> "$SUMMARY"
    echo -e "${PATH}\t${NODES}" >> "$MULTI"
    continue
  fi

  SRC_NODE="${NODE_ARR[0]}"
  if ! grep -qw -- "$SRC_NODE" <<<"$ALLOWED_SRC_SET"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tnot-in-sources\tallowed: ${ALLOWED_SRC_SET}" >> "$SUMMARY"
    echo -e "${PATH}\t${SRC_NODE}" >> "$NOTINSRCSET"
    continue
  fi

  SRC_CODE="$(http_code "$SRC_NODE" "$NS" "$REL")"
  if [[ "$SRC_CODE" != "200" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tnot-found-on-source\tHEAD ${SRC_CODE}" >> "$SUMMARY"
    echo -e "${PATH}\t${SRC_NODE}" >> "$NOTFOUND"
    continue
  fi

  if (( DRYRUN )); then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}" >> "$DRYLIST"
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\twould-copy\t-" >> "$SUMMARY"
    continue
  fi

  SAFE_BASENAME="$(echo -n "$REL" | tr '/ ' '__')"
  LOCAL_FILE="${TMPDIR}/${SAFE_BASENAME}"
  trap 'rm -f "$LOCAL_FILE" 2>/dev/null || true' EXIT

  if ! download_to_file "$SRC_NODE" "$NS" "$REL" "$LOCAL_FILE"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tdownload error" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; rm -f "$LOCAL_FILE" || true; continue
  fi
  if [[ ! -s "$LOCAL_FILE" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tzero-byte download" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; rm -f "$LOCAL_FILE" || true; continue
  fi
  if ! upload_from_file "$TARGET_NODE" "$NS" "$REL" "$LOCAL_FILE"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tupload error" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; rm -f "$LOCAL_FILE" || true; continue
  fi

  VERIFY="$(http_code "$TARGET_NODE" "$NS" "$REL")"
  if [[ "$VERIFY" != "200" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tpost-upload HEAD ${VERIFY}" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; rm -f "$LOCAL_FILE" || true; continue
  fi

  echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tcopied\tOK" >> "$SUMMARY"
  echo "$PATH" >> "$COPIED"
  rm -f "$LOCAL_FILE" || true
done

log "done. Output: $OUTDIR"
log "copied:                 $(wc -l < "$COPIED")"
log "skipped (exists):       $(wc -l < "$EXISTS")"
log "multi-source:           $(wc -l < "$MULTI")"
log "tsv target listed miss: $(wc -l < "$TSV_TARGET_MISSING")"
log "invalid nodes format:   $(wc -l < "$BADFMT")"
log "not in sources:         $(wc -l < "$NOTINSRCSET")"
log "not found on source:    $(wc -l < "$NOTFOUND")"
log "failed:                 $(wc -l < "$FAILED")"
(( DRYRUN )) && log "would-copy:             $(wc -l < "$DRYLIST")"