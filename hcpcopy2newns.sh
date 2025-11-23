#!/usr/bin/env bash
# Purpose:
#   Copy HCP objects listed in a 2-column file (path, nodes) into a single target node.
#
#   The script:
#   - Reads a list file with two columns: "path" and "nodes".
#   - "path" contains: namespace/prefix/.../object.ext
#   - "nodes" contains: a single node ("node1") or comma-separated nodes ("node1,node2").
#   - Copies objects from allowed source nodes to one target node, without overwriting
#     any existing target objects.
#   - Optionally allows overriding the target namespace (different from the source one).
#
# Notes:
#   - The list file can use either TABs or SPACEs between the two columns.
#   - The script never overwrites objects: it always checks the target first.
#   - It supports dry-run, retry logic, and basic logging.
#
# Requirements:
#   - bash
#   - curl, awk, sed, grep
#
# Example usage:
#   hcp_copy_from_list.sh \
#     --list objects.tsv \
#     --target node3 \
#     --sources "node1 node2" \
#     --tenant mytenant \
#     --domain example.com \
#     --token 'MYTOKEN' \
#     --target-namespace my-target-namespace \
#     --retries 3 \
#     --dry-run \
#     --debug
#
#   If --target-namespace is omitted, the namespace is taken from the "path" column.

set -euo pipefail

# ---- helpers ----
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
  cat <<'EOF'
Usage:
  hcp_copy_from_list.sh --list <file> --target <node> --sources "<node ...>" \
                        --tenant <tenant> --domain <domain> --token '<token>' \
                        [--target-namespace <namespace>] \
                        [--retries N] [--dry-run] [--debug] [--insecure]

Columns expected in --list:
  path    nodes
Where:
  path  = namespace/prefix/.../object.ext   (namespace is the first segment)
  nodes = e.g. node1  OR node1,node2 (comma if multiple)  [SPACES or TAB are OK between columns]

Behavior:
  - Objects are copied only from allowed source nodes to a single target node.
  - The script NEVER overwrites existing objects on the target: it checks the target first.
  - If --target-namespace is provided, the destination object is written into that namespace.
    Otherwise, the namespace is taken from the "path" column (source namespace).

Outputs go to: output/<TIMESTAMP>_copy_to_<target>/
EOF
  exit 1
}

LIST=""
TARGET=""
SOURCES_STR=""
TENANT=""
DOMAIN=""
TOKEN=""
TARGET_NS=""        # Optional target namespace override
RETRIES=2
DEBUG=0
DRYRUN=0
CURL_INSECURE=()

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)             LIST="$2"; shift 2;;
    --target)           TARGET="$2"; shift 2;;
    --sources)          SOURCES_STR="$2"; shift 2;;
    --tenant)           TENANT="$2"; shift 2;;
    --domain)           DOMAIN="$2"; shift 2;;
    --token)            TOKEN="$2"; shift 2;;
    --target-namespace) TARGET_NS="$2"; shift 2;;
    --retries)          RETRIES="${2}"; shift 2;;
    --dry-run)          DRYRUN=1; shift;;
    --debug)            DEBUG=1; shift;;
    --insecure)         CURL_INSECURE=(-k); shift;;
    -h|--help)          usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -z "$LIST" || -z "$TARGET" || -z "$SOURCES_STR" || -z "$TENANT" || -z "$DOMAIN" || -z "$TOKEN" ]] && usage

# Normalize sources into array (split on spaces)
read -r -a SOURCES <<<"$SOURCES_STR"

TS=$(date +%Y%m%d_%H%M%S)
OUTDIR="output/${TS}_copy_to_${TARGET}"
mkdir -p "$OUTDIR"

LOG="${OUTDIR}/copy.log"
SUMMARY="${OUTDIR}/copy_summary.tsv"
WOULD="${OUTDIR}/would_copy.txt"
SKIPPED_EXISTS="${OUTDIR}/skipped_exists.txt"
FAILED="${OUTDIR}/failed.txt"
NOT_IN_SOURCES="${OUTDIR}/not_in_sources.txt"
MULTI_SRC="${OUTDIR}/multi_source.txt"
TSV_TGT_LISTED_MISSING="${OUTDIR}/tsv_target_listed_but_missing.txt"
CLEAN_IN="${OUTDIR}/clean.txt"  # for debug/trace of the parsed rows

AWK=$(command -v awk)
SED=$(command -v sed)
GREP=$(command -v grep)
CURL=$(command -v curl)

# header
{
  echo "$(_ts) Output directory: $OUTDIR"
  echo "$(_ts) Tenant/Domain: ${TENANT}.${DOMAIN}"
  echo "$(_ts) Target node: ${TARGET}"
  echo "$(_ts) Sources allowed: ${SOURCES[*]}"
  if [[ -n "$TARGET_NS" ]]; then
    echo "$(_ts) Target namespace override: ${TARGET_NS}"
  else
    echo "$(_ts) Target namespace override: (same as source namespace)"
  fi
  echo "$(_ts) Insecure curl: ${#CURL_INSECURE[@]}"
  echo "$(_ts) Retries: ${RETRIES}"
  echo "$(_ts) Dry run: ${DRYRUN}"
  echo "$(_ts) Debug: ${DEBUG}"
} | tee -a "$LOG" >/dev/null

# summary header
echo -e "path\tsource_node\ttarget_node\tresult\tinfo" > "$SUMMARY"

# curl HEAD helper -> prints HTTP status code (e.g. 200/404/403...)
head_code() {
  local url="$1"
  ${CURL} "${CURL_INSECURE[@]}" -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: HCP ${TOKEN}" "$url" || echo "000"
}

# GET to file
get_object() {
  local url="$1" out="$2"
  ${CURL} "${CURL_INSECURE[@]}" -sS -H "Authorization: HCP ${TOKEN}" \
    "$url" -o "$out"
}

# PUT from file (binary)
put_object() {
  local url="$1" file="$2"
  ${CURL} "${CURL_INSECURE[@]}" -sS -X PUT \
    -H "Authorization: HCP ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" \
    "$url" -o /dev/null
}

# ---- main loop: robust row parsing (TAB or SPACES between columns) ----
echo "$(_ts) Reading list: $LIST" | tee -a "$LOG" >/dev/null
LINE_NO=0

# We accept either TABs or SPACEs:
# - First column = first AWK field
# - Second column = last AWK field (so any middle noise is ignored)
while IFS= read -r raw; do
  LINE_NO=$((LINE_NO+1))
  # trim leading/trailing whitespace
  line=$(echo "$raw" | ${SED} 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [[ -z "$line" ]] && continue

  # header row?
  if echo "$line" | ${GREP} -qiE '^[[:space:]]*path[[:space:]]+nodes[[:space:]]*$'; then
    [[ $DEBUG -eq 1 ]] && echo "$(_ts) [DEBUG] Skip header on line $LINE_NO" | tee -a "$LOG" >/dev/null
    continue
  fi

  # pick first and last field as path / nodes (works for TABs or SPACEs)
  path=$(${AWK} '{print $1}' <<<"$line")
  nodes=$(${AWK} '{print $NF}' <<<"$line")

  # keep a cleaned echo (optional trace)
  echo -e "${path}\t${nodes}" >> "$CLEAN_IN"

  # sanity check
  if [[ -z "$path" || -z "$nodes" ]]; then
    echo -e "${path}\t-\t${TARGET}\tskipped\tinvalid_nodes_format" | tee -a "$SUMMARY" >/dev/null
    echo "$line" >> "${OUTDIR}/invalid_nodes_format.txt"
    continue
  fi

  # parse namespace + object key from path
  ns="${path%%/*}"   # first segment before '/'
  key="${path#*/}"   # everything after first '/'

  # nodes can be single 'nodeN' OR a comma list 'nodeN,nodeM'
  IFS=',' read -r -a NODE_LIST <<<"$nodes"
  # normalize (trim spaces around entries)
  for i in "${!NODE_LIST[@]}"; do
    NODE_LIST[$i]=$(echo "${NODE_LIST[$i]}" | ${SED} 's/^[[:space:]]*//; s/[[:space:]]*$//')
  done

  # Build URLs
  # SRC namespace is always taken from "ns" (from the path).
  # DST namespace:
  #   - if TARGET_NS is set, use TARGET_NS
  #   - otherwise use "ns" (source namespace)
  src_url_for() { # $1 = node
    echo "https://${ns}.${TENANT}.${1}.${DOMAIN}/rest/${key}"
  }

  dst_url_for() { # $1 = node
    local effective_ns="${TARGET_NS:-$ns}"
    echo "https://${effective_ns}.${TENANT}.${1}.${DOMAIN}/rest/${key}"
  }

  # --- decision tree ---

  # If multiple nodes are listed for this path
  if (( ${#NODE_LIST[@]} >= 2 )); then
    # If target node is listed: verify it really exists at target; if not → record mismatch.
    if printf '%s\0' "${NODE_LIST[@]}" | ${GREP} -zqx "$TARGET"; then
      tgt_url=$(dst_url_for "$TARGET")
      code=$(head_code "$tgt_url")
      if [[ "$code" == "200" ]]; then
        echo -e "${path}\t-\t${TARGET}\tskipped\ttarget_already_has_object" | tee -a "$SUMMARY" >/dev/null
        echo "$(_ts) SKIP (multi-node, target confirmed 200): $path" >> "$LOG"
        echo "$path" >> "$SKIPPED_EXISTS"
      else
        echo -e "${path}\t-\t${TARGET}\tskipped\ttsv_target_listed_but_missing" | tee -a "$SUMMARY" >/dev/null
        echo "$path" >> "$TSV_TGT_LISTED_MISSING"
        echo "$(_ts) WARN (multi-node, target listed but HEAD=${code}): $path" >> "$LOG"
      fi
    else
      # Multi-source but without target in list → manual path (do not auto-copy).
      echo -e "${path}\t-\t${TARGET}\tskipped\tmulti_source_listed" | tee -a "$SUMMARY" >/dev/null
      echo -e "${path}\t${nodes}" >> "$MULTI_SRC"
      echo "$(_ts) SKIP (multi-source): $path nodes=[${nodes}]" >> "$LOG"
    fi
    continue
  fi

  # here: exactly one node in the list
  SRC_NODE="${NODE_LIST[0]}"

  # if it's already the target → verify existence then skip
  if [[ "$SRC_NODE" == "$TARGET" ]]; then
    tgt_url=$(dst_url_for "$TARGET")
    code=$(head_code "$tgt_url")
    if [[ "$code" == "200" ]]; then
      echo -e "${path}\t${TARGET}\t${TARGET}\tskipped\ttarget_already_has_object" | tee -a "$SUMMARY" >/dev/null
      echo "$(_ts) SKIP (already at target): $path" >> "$LOG"
      echo "$path" >> "$SKIPPED_EXISTS"
    else
      echo -e "${path}\t${TARGET}\t${TARGET}\tskipped\ttsv_target_listed_but_missing" | tee -a "$SUMMARY" >/dev/null
      echo "$path" >> "$TSV_TGT_LISTED_MISSING"
      echo "$(_ts) WARN (listed target but HEAD=${code}): $path" >> "$LOG"
    fi
    continue
  fi

  # check source is in allowed sources
  allow=0
  for s in "${SOURCES[@]}"; do
    [[ "$s" == "$SRC_NODE" ]] && allow=1
  done
  if (( allow == 0 )); then
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\tskipped\tnot_in_sources_allowlist" | tee -a "$SUMMARY" >/dev/null
    echo -e "${path}\t${SRC_NODE}" >> "$NOT_IN_SOURCES"
    echo "$(_ts) SKIP (not in allowed sources): $path from ${SRC_NODE}" >> "$LOG"
    continue
  fi

  SRC_URL=$(src_url_for "$SRC_NODE")
  DST_URL=$(dst_url_for "$TARGET")

  # If destination already has it → skip (never overwrite)
  dst_code=$(head_code "$DST_URL")
  if [[ "$dst_code" == "200" ]]; then
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\tskipped\ttarget_already_has_object" | tee -a "$SUMMARY" >/dev/null
    echo "$(_ts) SKIP (target already has object, HTTP 200): $path" >> "$LOG"
    echo "$path" >> "$SKIPPED_EXISTS"
    continue
  fi

  # verify source actually has it
  src_code=$(head_code "$SRC_URL")
  if [[ "$src_code" != "200" ]]; then
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\tskipped\tsource_missing_or_forbidden(${src_code})" | tee -a "$SUMMARY" >/dev/null
    echo "$(_ts) SKIP (source !200=${src_code}): $path" >> "$LOG"
    continue
  fi

  # dry run?
  if (( DRYRUN == 1 )); then
    echo "$path" >> "$WOULD"
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\twould_copy\t-" | tee -a "$SUMMARY" >/dev/null
    [[ $DEBUG -eq 1 ]] && {
      echo "$(_ts) DRY-RUN would copy: $path  SRC=${SRC_URL}  DST=${DST_URL}" >> "$LOG"
    }
    continue
  fi

  # perform copy: GET → PUT (binary) with retries
  tmpfile="${OUTDIR}/downloaded_file.tmp"
  ok=0
  attempt=0
  while (( attempt < RETRIES )); do
    attempt=$((attempt+1))
    echo "$(_ts) Attempt ${attempt}/${RETRIES} GET $SRC_URL" >> "$LOG"
    if get_object "$SRC_URL" "$tmpfile"; then
      echo "$(_ts) PUT to $DST_URL" >> "$LOG"
      if put_object "$DST_URL" "$tmpfile"; then
        # verify
        vcode=$(head_code "$DST_URL")
        if [[ "$vcode" == "200" ]]; then
          ok=1
          break
        fi
        echo "$(_ts) VERIFY failed (HEAD=$vcode)" >> "$LOG"
      else
        echo "$(_ts) PUT failed" >> "$LOG"
      fi
    else
      echo "$(_ts) GET failed" >> "$LOG"
    fi
    sleep 1
  done
  rm -f "$tmpfile" || true

  if (( ok == 1 )); then
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\tcopied\t-" | tee -a "$SUMMARY" >/dev/null
  else
    echo -e "${path}\t${SRC_NODE}\t${TARGET}\tfailed\tcopy_or_verify_failed" | tee -a "$SUMMARY" >/dev/null
    echo "$path" >> "$FAILED"
  fi

done < "$LIST"

echo "$(_ts) Done." | tee -a "$LOG" >/dev/null