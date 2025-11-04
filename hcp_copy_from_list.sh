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

Decision logic per row (always HEAD the target first and record its HTTP):
1) If target HEAD == 200           -> result=exists (skip).
2) Else target HEAD != 200:
   a) nodes is single (e.g., hcp1):
      - if node ∈ --sources and HEAD(source)==200 -> copy
      - else log not-in-sources / not-found-on-source
   b) nodes has multiple (e.g., hcp1,hcp2):
      - if list includes target -> tsv-target-listed-but-missing (skip)
      - else -> multi-source (skip)
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
SUMMARY="${OUTDIR}/copy_summary.tsv"
COPIED="${OUTDIR}/copied.txt"
EXISTS="${OUTDIR}/skipped_exists.txt"
MULTI="${OUTDIR}/multi_source.txt"
MULTI_WITH_TARGET="${OUTDIR}/multi_source_with_target.txt"
TSV_TARGET_MISSING="${OUTDIR}/tsv_target_listed_but_missing.txt"
NOTINSRCSET="${OUTDIR}/not_in_sources.txt"
NOTFOUND="${OUTDIR}/not_found_on_source.txt"
FAILED="${OUTDIR}/failed.txt"
DRYLIST="${OUTDIR}/would_copy.txt"
BADFMT="${OUTDIR}/invalid_nodes_format.txt"

# init files
: >"$LOG"; : >"$SUMMARY"; : >"$COPIED"; : >"$EXISTS"; : >"$MULTI"
: >"$MULTI_WITH_TARGET"; : >"$TSV_TARGET_MISSING"; : >"$NOTINSRCSET"
: >"$NOTFOUND"; : >"$FAILED"; : >"$DRYLIST"; : >"$BADFMT"

log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG" >/dev/null; }
dbg(){ (( DEBUG )) && log "DEBUG: $*"; }

CURL_OPTS=(-sS -L); (( INSECURE )) && CURL_OPTS+=(-k)
AUTH=(-H "Authorization: HCP ${TOKEN}")

# --- HTTP helpers ---
url_for(){ # node ns rel -> url
  printf 'https://%s.%s.%s.%s/rest/%s' "$2" "$TENANT" "$1" "$DOMAIN" "$3"
}
http_code(){ # node ns rel -> code
  local u; u="$(url_for "$1" "$2" "$3")"
  curl "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -I "${AUTH[@]}" "$u"
}
download_to_file(){ # node ns rel file
  local u; u="$(url_for "$1" "$2" "$3")"
  dbg "DOWNLOAD: $u -> $4"
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" "$u" -o "$4"
}
upload_from_file(){ # node ns rel file
  local u; u="$(url_for "$1" "$2" "$3")"
  dbg "UPLOAD: $4 -> $u"
  curl "${CURL_OPTS[@]}" -X PUT "${AUTH[@]}" \
       -H "Content-Type: application/octet-stream" \
       --data-binary @"$4" "$u" -o /dev/null
}

strip_ns(){ echo "${1#*/}"; }    # "ns/a/b" -> "a/b"
extract_ns(){ echo "${1%%/*}"; } # "ns/a/b" -> "ns"

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

  # Strict validation: hcpN or hcpN,hcpM,...
  if [[ ! "${NODES:-}" =~ ^hcp[0-9]+(,hcp[0-9]+)*$ ]]; then
    echo -e "${PATH}\t${NODES}" >> "$BADFMT"
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t-\tinvalid-nodes-format\t'${NODES}'" >> "$SUMMARY"
    dbg "INVALID NODES FORMAT: $PATH nodes='${NODES}'"
    continue
  fi

  # Always HEAD the target first
  TGT_CODE="$(http_code "$TARGET_NODE" "$NS" "$REL")"

  # If target already has it → exists
  if [[ "$TGT_CODE" == "200" ]]; then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\texists\talready on target" >> "$SUMMARY"
    echo "$PATH" >> "$EXISTS"
    dbg "EXISTS: $PATH on $TARGET_NODE (HTTP $TGT_CODE)"
    continue
  fi

  # Split nodes by comma (strict format guarantees no spaces)
  IFS=',' read -r -a NODE_ARR <<< "$NODES"
  NODE_COUNT="${#NODE_ARR[@]}"

  # If nodes list contains the target, but HEAD said missing → inconsistenty
  contains_target=0
  for n in "${NODE_ARR[@]}"; do [[ "$n" == "$TARGET_NODE" ]] && contains_target=1; done
  if (( contains_target == 1 )); then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\ttsv-target-listed-but-missing\t-" >> "$SUMMARY"
    echo -e "${PATH}\t${NODES}" >> "$TSV_TARGET_MISSING"
    dbg "TSV TARGET LISTED BUT HEAD!=200: $PATH nodes='${NODES}' target=$TARGET_NODE code=$TGT_CODE"
    continue
  fi

  # Multi-source (without target) → skip, report
  if (( NODE_COUNT > 1 )); then
    echo -e "${PATH}\t${NODES}\t${TARGET_NODE}\t${TGT_CODE}\tmulti-source\t-" >> "$SUMMARY"
    echo -e "${PATH}\t${NODES}" >> "$MULTI"
    dbg "MULTI-SOURCE: $PATH nodes='${NODES}'"
    continue
  fi

  # Single source node
  SRC_NODE="${NODE_ARR[0]}"

  # Must be in allowed sources
  if ! grep -qw -- "$SRC_NODE" <<<"$ALLOWED_SRC_SET"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tnot-in-sources\tallowed: ${ALLOWED_SRC_SET}" >> "$SUMMARY"
    echo -e "${PATH}\t${SRC_NODE}" >> "$NOTINSRCSET"
    dbg "NOT-IN-SOURCES: $PATH src=${SRC_NODE}"
    continue
  fi

  # Verify on source
  SRC_CODE="$(http_code "$SRC_NODE" "$NS" "$REL")"
  if [[ "$SRC_CODE" != "200" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tnot-found-on-source\tHEAD ${SRC_CODE}" >> "$SUMMARY"
    echo -e "${PATH}\t${SRC_NODE}" >> "$NOTFOUND"
    dbg "NOT-FOUND-SRC: $PATH on $SRC_NODE (HTTP $SRC_CODE)"
    continue
  fi

  # DRY RUN
  if (( DRYRUN )); then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}" >> "$DRYLIST"
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\twould-copy\t-" >> "$SUMMARY"
    dbg "WOULD-COPY: $PATH  $SRC_NODE -> $TARGET_NODE"
    continue
  fi

  # Real copy
  SAFE_BASENAME="$(echo -n "$REL" | tr '/ ' '__')"
  LOCAL_FILE="${TMPDIR}/${SAFE_BASENAME}"
  trap 'rm -f "$LOCAL_FILE" 2>/dev/null || true' EXIT

  if ! download_to_file "$SRC_NODE" "$NS" "$REL" "$LOCAL_FILE"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tdownload error" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; dbg "DOWNLOAD-ERROR: $PATH"; rm -f "$LOCAL_FILE" || true; continue
  fi
  if [[ ! -s "$LOCAL_FILE" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tzero-byte download" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; dbg "ZERO-DOWNLOAD: $PATH"; rm -f "$LOCAL_FILE" || true; continue
  fi

  if ! upload_from_file "$TARGET_NODE" "$NS" "$REL" "$LOCAL_FILE"; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tupload error" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; dbg "UPLOAD-ERROR: $PATH"; rm -f "$LOCAL_FILE" || true; continue
  fi

  # Post-verify on target
  TGT_VERIFY="$(http_code "$TARGET_NODE" "$NS" "$REL")"
  if [[ "$TGT_VERIFY" != "200" ]]; then
    echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tfailed\tpost-upload HEAD ${TGT_VERIFY}" >> "$SUMMARY"
    echo "$PATH" >> "$FAILED"; dbg "VERIFY-FAILED: $PATH on $TARGET_NODE (HTTP $TGT_VERIFY)"; rm -f "$LOCAL_FILE" || true; continue
  fi

  echo -e "${PATH}\t${SRC_NODE}\t${TARGET_NODE}\t${TGT_CODE}\tcopied\tOK" >> "$SUMMARY"
  echo "$PATH" >> "$COPIED"
  dbg "COPIED: $PATH  $SRC_NODE -> $TARGET_NODE"
  rm -f "$LOCAL_FILE" || true
done

# Footer stats
log "done. Output: $OUTDIR"
log "copied:                  $(wc -l < "$COPIED")"
log "skipped (exists):        $(wc -l < "$EXISTS")"
log "multi-source:            $(wc -l < "$MULTI")"
log "multi-source-with-target $(wc -l < "$MULTI_WITH_TARGET" 2>/dev/null || echo 0)"
log "tsv target listed missing: $(wc -l < "$TSV_TARGET_MISSING")"
log "invalid nodes format:    $(wc -l < "$BADFMT")"
log "not in sources:          $(wc -l < "$NOTINSRCSET")"
log "not found on source:     $(wc -l < "$NOTFOUND")"
log "failed:                  $(wc -l < "$FAILED")"
(( DRYRUN )) && log "would-copy:              $(wc -l < "$DRYLIST")"