#!/usr/bin/env bash
# =============================================================================
# NAME:        ccf_extractor_from_list.sh
# PURPOSE:     Build a unique list of container file paths (.ccf) for many
#              (filespace, ll_name) entries provided in a text/CSV file.
#
# INPUT FILE FORMAT (one per line, comma-separated):
#   <filespace_name>,<ll_name>
#   Examples:
#     /DGCEP11B/GAA,11887FAAA
#     /DGCEP11B/ZWA,1850
#
# BEHAVIOR:
#   - For each line, extract the numeric prefix from ll_name (drop any letters
#     or other characters after the first non-digit), e.g. "11887FAAA" -> "11887".
#   - Deduplicate pairs (filespace, numeric_prefix).
#   - For each unique pair run dsmadmc query:
#       filespace_name='<filespace>' AND ll_name LIKE '<numeric_prefix>%'
#   - Collect object IDs, map to container IDs (show invo ... listchun=yes),
#     and query DB2 for physical container paths (cntrname).
#   - Produce final unique list: ccf_paths.txt
#
# OUTPUT (in --out-dir):
#   pairs_used.csv              - unique (filespace,ll_prefix) used
#   invalid_lines.txt           - lines skipped due to parsing issues
#   object_ids.txt              - aggregated object IDs
#   objid_to_container.csv      - mapping object_id,container_id
#   container_ids.txt           - unique container IDs
#   get_ccf.sql                 - generated DB2 script
#   ccf_paths.raw               - raw DB2 output
#   ccf_paths.txt               - final unique .ccf container paths
#   run_summary.txt             - high-level counts and timing
#
# REQUIREMENTS:
#   - dsmadmc in PATH (admin CLI)
#   - db2 in PATH and cataloged DB name
#
# USAGE EXAMPLE:
#   ./ccf_extractor_from_list.sh \
#     --list /path/to/input.txt \
#     --server SERVER1 --user admin --pass 'secret' \
#     --db TSMDB1 --schema TSMDB1 \
#     --out-dir /tmp/ccf_batch_$(date +%Y%m%d_%H%M%S)
#
# =============================================================================
set -euo pipefail

# ---- Defaults ----------------------------------------------------------------
OUT_DIR="/tmp/ccf_batch_$(date +%Y%m%d_%H%M%S)"
DSMADMC_BIN="${DSMADMC_BIN:-dsmadmc}"
DB2_BIN="${DB2_BIN:-db2}"
DB_NAME="TSMDB1"
DB_SCHEMA="TSMDB1"

LIST_FILE=""
SERVER=""; USER=""; PASS=""

print_usage() {
  cat <<EOF
Usage:
  $0 --list <FILE> --server <SERVER> --user <ID> --pass <PASSWORD> \\
     [--db DBNAME] [--schema SCHEMA] [--out-dir DIR]

Required:
  --list     Path to input file with lines: <filespace_name>,<ll_name>
  --server   Server name for dsmadmc
  --user     Admin ID
  --pass     Admin password

Optional:
  --db       DB2 database name (default: ${DB_NAME})
  --schema   DB2 schema (default: ${DB_SCHEMA})
  --out-dir  Output directory (default: ${OUT_DIR})
EOF
}

# ---- Arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)    LIST_FILE="${2:-}"; shift 2 ;;
    --server)  SERVER="${2:-}"; shift 2 ;;
    --user)    USER="${2:-}"; shift 2 ;;
    --pass)    PASS="${2:-}"; shift 2 ;;
    --db)      DB_NAME="${2:-}"; shift 2 ;;
    --schema)  DB_SCHEMA="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; print_usage; exit 1 ;;
  esac
done

# ---- Validation ---------------------------------------------------------------
[[ -n "${LIST_FILE}" && -f "${LIST_FILE}" ]] || { echo "ERROR: --list file missing" >&2; exit 1; }
[[ -n "$SERVER"    ]] || { echo "ERROR: --server required" >&2; exit 1; }
[[ -n "$USER"      ]] || { echo "ERROR: --user required" >&2; exit 1; }
[[ -n "$PASS"      ]] || { echo "ERROR: --pass required" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# ---- Files -------------------------------------------------------------------
PAIRS_ALL="${OUT_DIR}/pairs_all_raw.csv"
PAIRS_USED="${OUT_DIR}/pairs_used.csv"
INVALID="${OUT_DIR}/invalid_lines.txt"

OBJ_FILE="${OUT_DIR}/object_ids.txt"
MAP_FILE="${OUT_DIR}/objid_to_container.csv"
CID_FILE="${OUT_DIR}/container_ids.txt"
SQL_FILE="${OUT_DIR}/get_ccf.sql"
RAW_FILE="${OUT_DIR}/ccf_paths.raw"
CCF_FILE="${OUT_DIR}/ccf_paths.txt"
RUN_SUM="${OUT_DIR}/run_summary.txt"

# ---- Helpers -----------------------------------------------------------------
run_dsmadmc_csv() {
  "$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" \
                 -comma -dataonly=yes "$@"
}

extract_container_ids_from_show() {
  grep -Eo 'Container ID:[[:space:]]*[0-9]+' | awk '{print $3}'
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

ts() { date +'%Y-%m-%d %H:%M:%S'; }

# ---- Step 0: Parse input list ------------------------------------------------
# Build cleaned pairs (filespace, numeric_prefix)
: > "$PAIRS_ALL"
: > "$INVALID"

# Read file safely (strip CR, skip blanks and #)
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  fs=$(echo "$line" | cut -d',' -f1 | tr -d '\r' | trim)
  ll=$(echo "$line" | cut -d',' -f2- | tr -d '\r' | trim)

  # numeric prefix: cut everything from first non-digit onward
  ll_digits=$(echo "$ll" | sed -E 's/[^0-9].*$//')

  if [[ -z "$fs" || -z "$ll_digits" ]]; then
    echo "$line" >> "$INVALID"
    continue
  fi

  echo "${fs},${ll_digits}" >> "$PAIRS_ALL"
done < "$LIST_FILE"

# Unique pairs
if [[ -s "$PAIRS_ALL" ]]; then
  sort -u "$PAIRS_ALL" > "$PAIRS_USED"
else
  echo "No valid pairs found in list. See $INVALID" >&2
  exit 2
fi

# ---- Step 1: Query object IDs for each pair ----------------------------------
: > "$OBJ_FILE"

start_epoch=$(date +%s)

pairs_count=$(wc -l < "$PAIRS_USED" | tr -d ' ')
echo "$(ts) Pairs to process: $pairs_count" | tee -a "$RUN_SUM"

while IFS=',' read -r FS_NAME LL_NUM || [[ -n "$FS_NAME" ]]; do
  [[ -z "$FS_NAME" || -z "$LL_NUM" ]] && continue
  SQL="select object_id from archives where filespace_name='${FS_NAME}' and ll_name like '${LL_NUM}%'"
  run_dsmadmc_csv "$SQL" \
    | tr -d '\r' \
    | awk -F',' 'NF>=1 {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$1); gsub(/"/,"",$1); if ($1~/^[0-9]+$/) print $1;}' \
    >> "$OBJ_FILE"
done < "$PAIRS_USED"

# Unique object IDs
if [[ -s "$OBJ_FILE" ]]; then
  sort -n -u "$OBJ_FILE" -o "$OBJ_FILE"
else
  echo "No matching object IDs for provided pairs." | tee -a "$RUN_SUM"
  exit 3
fi

echo "$(ts) Object IDs collected: $(wc -l < "$OBJ_FILE")" | tee -a "$RUN_SUM"

# ---- Step 2: Map to container IDs -------------------------------------------
echo "object_id,container_id" > "$MAP_FILE"

while IFS= read -r OID || [[ -n "$OID" ]]; do
  [[ -z "$OID" ]] && continue
  OUT="$("$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" \
        "show invo ${OID} listchun=yes" 2>/dev/null || true)"
  if [[ -n "$OUT" ]]; then
    echo "$OUT" | extract_container_ids_from_show \
      | while read -r CID; do
          [[ -n "$CID" ]] && echo "${OID},${CID}" >> "$MAP_FILE"
        done
  fi
done < "$OBJ_FILE"

# Unique container IDs
awk -F',' 'NR>1{print $2}' "$MAP_FILE" | sort -n | uniq > "$CID_FILE"
echo "$(ts) Container IDs collected: $(wc -l < "$CID_FILE")" | tee -a "$RUN_SUM"

# ---- Step 3: DB2 query for cntrname ------------------------------------------
{
  echo "connect to ${DB_NAME};"
  echo "set schema ${DB_SCHEMA};"
  while IFS= read -r CID || [[ -n "$CID" ]]; do
    [[ -z "$CID" ]] && continue
    echo "select cntrname from sd_containers where cntrid=${CID};"
  done < "$CID_FILE"
} > "$SQL_FILE"

"$DB2_BIN" -txf "$SQL_FILE" > "$RAW_FILE" 2>/dev/null || {
  echo "DB2 query failed. Check ${RAW_FILE} for details." | tee -a "$RUN_SUM"
  exit 4
}

tr -d '\r' < "$RAW_FILE" \
  | awk 'NF>0 {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' \
  | sort -u > "$CCF_FILE"

# ---- Step 4: Summary ---------------------------------------------------------
end_epoch=$(date +%s)
elapsed=$(( end_epoch - start_epoch ))

{
  echo
  echo "===== SUMMARY ====="
  echo "Pairs used file:            $PAIRS_USED (count: $pairs_count)"
  echo "Invalid lines:              $INVALID ($( [ -s "$INVALID" ] && wc -l < "$INVALID" || echo 0 ))"
  echo "Object IDs file:            $OBJ_FILE ($(wc -l < "$OBJ_FILE"))"
  echo "Object->Container map:      $MAP_FILE"
  echo "Container ID list:          $CID_FILE ($(wc -l < "$CID_FILE"))"
  echo "Final CCF path list:        $CCF_FILE ($(wc -l < "$CCF_FILE"))"
  echo "Run time (s):               $elapsed"
} | tee -a "$RUN_SUM"

echo
echo "Done. Output directory: $OUT_DIR"