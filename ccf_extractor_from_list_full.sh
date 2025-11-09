#!/usr/bin/env bash
# =============================================================================
# NAME:        ccf_extractor_from_list.sh
# PURPOSE:
#   Build a unique list of container file paths (.ccf) for many input
#   (filespace_name, ll_name) patterns AND produce object-centric reports:
#     1) objects.csv                  -> per object: filespace_name, full_object_name(HL+LL), object_id
#     2) obj_to_container_ids.csv     -> denormalized map: filespace_name, full_object_name, object_id, container_id
#     3) obj_to_container_paths.csv   -> per object aggregated: filespace_name, full_object_name, object_id,
#                                        container_ids (joined), container_paths (joined)
#
# INPUT FILE FORMAT (one per line, comma-separated):
#   <filespace_name>,<ll_name>
#   Examples:
#     /DGCEP11B/GAA,11887FAAA
#     /DGCEP11B/ZWA,1850
#
# SCOPE / MATCHING:
#   For each input line we extract the numeric prefix from ll_name
#   (drop characters after the first non-digit), e.g. "11887FAAA" -> "11887",
#   deduplicate (filespace_name, numeric_prefix) pairs, then query:
#     filespace_name='<fs>' AND ll_name LIKE '<prefix>%'
#
# LEGACY OUTPUTS (kept 1:1):
#   pairs_used.csv              - unique (filespace,ll_prefix) used
#   invalid_lines.txt           - lines skipped due to parsing issues
#   object_ids.txt              - unique OBJECT_IDs
#   objid_to_container.csv      - mapping object_id,container_id
#   container_ids.txt           - unique container IDs
#   get_ccf.sql                 - generated DB2 SQL script
#   ccf_paths.raw               - raw DB2 output
#   ccf_paths.txt               - final unique .ccf container paths
#   run_summary.txt             - high-level counts and timing
#
# NEW OUTPUTS:
#   objects.csv                 - filespace_name, full_object_name, object_id
#   obj_to_container_ids.csv    - filespace_name, full_object_name, object_id, container_id
#   obj_to_container_paths.csv  - filespace_name, full_object_name, object_id,
#                                 container_ids (joined), container_paths (joined)
#
# REQUIREMENTS:
#   - dsmadmc in PATH (admin CLI)
#   - db2 in PATH and cataloged DB name
#   - coreutils: awk, grep, sort, join, paste, cut, tr
#
# USAGE EXAMPLE:
#   ./ccf_extractor_from_list.sh \
#     --list /path/to/input.txt \
#     --server SERVER1 --user admin --pass 'secret' \
#     --db TSMDB1 --schema TSMDB1 \
#     --out-dir /tmp/ccf_batch_$(date +%Y%m%d_%H%M%S)
#
# SECURITY NOTE:
#   Passing --pass puts the password in the process list. Prefer setting
#   DSMADMC credentials via environment/secure store if possible.
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
LIST_SEP="|"  # separator for aggregated container lists

print_usage() {
  cat <<EOF
Usage:
  $0 --list <FILE> --server <SERVER> --user <ID> --pass <PASSWORD> \\
     [--db DBNAME] [--schema SCHEMA] [--out-dir DIR] [--list-sep SEP]

Required:
  --list       Path to input file with lines: <filespace_name>,<ll_name>
  --server     Server name for dsmadmc
  --user       Admin ID
  --pass       Admin password

Optional:
  --db         DB2 database name (default: ${DB_NAME})
  --schema     DB2 schema (default: ${DB_SCHEMA})
  --out-dir    Output directory (default: ${OUT_DIR})
  --list-sep   Separator for aggregated lists (default: '${LIST_SEP}')
EOF
}

# ---- Arg parsing --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)      LIST_FILE="${2:-}"; shift 2 ;;
    --server)    SERVER="${2:-}"; shift 2 ;;
    --user)      USER="${2:-}"; shift 2 ;;
    --pass)      PASS="${2:-}"; shift 2 ;;
    --db)        DB_NAME="${2:-}"; shift 2 ;;
    --schema)    DB_SCHEMA="${2:-}"; shift 2 ;;
    --out-dir)   OUT_DIR="${2:-}"; shift 2 ;;
    --list-sep)  LIST_SEP="${2:-|}"; shift 2 ;;
    -h|--help)   print_usage; exit 0 ;;
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

# New reports
OBJECTS_CSV="${OUT_DIR}/objects.csv"
OBJ2CID_DENORM="${OUT_DIR}/obj_to_container_ids.csv"
OBJ2CNP_AGG="${OUT_DIR}/obj_to_container_paths.csv"

# Internal maps
OID_LOOKUP="${OUT_DIR}/oid_lookup.tsv"
CID2PATH="${OUT_DIR}/cid_to_path.tsv"

# ---- Helpers -----------------------------------------------------------------
run_dsmadmc_csv() {
  "$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" -comma -dataonly=yes "$@"
}

extract_container_ids_from_show() {
  # Pull "Container ID: <num>" lines and print the numeric value
  grep -Eo 'Container ID:[[:space:]]*[0-9]+' | awk '{print $3}'
}

trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
ts() { date +'%Y-%m-%d %H:%M:%S'; }

join_hl_ll() {
  # $1 = HL, $2 = LL; join with a single slash
  local hl="$1" ll="$2"
  hl="${hl%\"}"; hl="${hl#\"}"
  ll="${ll%\"}"; ll="${ll#\"}"
  if [[ -z "$hl" ]]; then
    echo "$ll"
  elif [[ "${hl: -1}" == "/" || "${ll:0:1}" == "/" ]]; then
    echo "${hl}${ll}"
  else
    echo "${hl}/${ll}"
  fi
}

# ---- Step 0: Parse input list ------------------------------------------------
: > "$PAIRS_ALL"
: > "$INVALID"

# Read file safely (strip CR, skip blanks and #)
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

  fs=$(echo "$line" | cut -d',' -f1 | tr -d '\r' | trim)
  ll=$(echo "$line" | cut -d',' -f2- | tr -d '\r' | trim)

  # numeric prefix: cut everything from the first non-digit onward
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

# ---- Step 1: Query OBJECTS (filespace, HL+LL full, object_id) ----------------
: > "$OBJ_FILE"
echo 'filespace_name,full_object_name,object_id' > "$OBJECTS_CSV"

start_epoch=$(date +%s)
pairs_count=$(wc -l < "$PAIRS_USED" | tr -d ' ')
echo "$(ts) Pairs to process: $pairs_count" | tee -a "$RUN_SUM"

# For each pair, fetch detailed rows from ARCHIVES:
# We pull: filespace_name, hl_name, ll_name, object_id
while IFS=',' read -r FS_NAME LL_NUM || [[ -n "$FS_NAME" ]]; do
  [[ -z "$FS_NAME" || -z "$LL_NUM" ]] && continue
  SQL="select filespace_name,hl_name,ll_name,object_id \
from archives where filespace_name='${FS_NAME}' and ll_name like '${LL_NUM}%'"
  run_dsmadmc_csv "$SQL" \
    | tr -d '\r' \
    | awk -F',' '
      NF>=4 {
        fs=$1; hl=$2; ll=$3; oid=$4;
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",fs);
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",hl);
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",ll);
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",oid);
        gsub(/"/,"",fs); gsub(/"/,"",hl); gsub(/"/,"",ll); gsub(/"/,"",oid);
        if (oid ~ /^[0-9]+$/) {
          print fs "\t" hl "\t" ll "\t" oid;
        }
      }' \
    | while IFS=$'\t' read -r fs hl ll oid; do
        full=$(join_hl_ll "$hl" "$ll")
        printf '%s,%s,%s\n' "$fs" "$full" "$oid" >> "$OBJECTS_CSV"
        echo "$oid" >> "$OBJ_FILE"
      done
done < "$PAIRS_USED"

# Unique object IDs
if [[ -s "$OBJ_FILE" ]]; then
  sort -n -u "$OBJ_FILE" -o "$OBJ_FILE"
else
  echo "No matching objects for provided pairs." | tee -a "$RUN_SUM"
  exit 3
fi
echo "$(ts) Objects collected (unique OIDs): $(wc -l < "$OBJ_FILE")" | tee -a "$RUN_SUM"

# ---- Step 2: Map OID -> Container IDs (denormalized) -------------------------
echo "filespace_name,full_object_name,object_id,container_id" > "$OBJ2CID_DENORM"
echo "object_id,container_id" > "$MAP_FILE"

# Build OID -> (fs,full) lookup
awk -F',' 'NR>1 {print $3"\t"$1"\t"$2}' "$OBJECTS_CSV" | sort -u > "$OID_LOOKUP"

lookup_fs_full() {
  # $1 = OID; prints "fs<TAB>full"
  awk -F'\t' -v OID="$1" '($1==OID){print $2"\t"$3; exit}' "$OID_LOOKUP" || true
}

while IFS= read -r OID || [[ -n "$OID" ]]; do
  [[ -z "$OID" ]] && continue
  OUT="$("$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" \
        "show invo ${OID} listchun=yes" 2>/dev/null || true)"
  if [[ -n "$OUT" ]]; then
    echo "$OUT" | extract_container_ids_from_show \
      | while read -r CID; do
          [[ -z "$CID" ]] && continue
          echo "${OID},${CID}" >> "$MAP_FILE"
          fs_full=$(lookup_fs_full "$OID")
          if [[ -n "$fs_full" ]]; then
            fs=$(echo "$fs_full" | cut -f1)
            full=$(echo "$fs_full" | cut -f2-)
            printf '%s,%s,%s,%s\n' "$fs" "$full" "$OID" "$CID" >> "$OBJ2CID_DENORM"
          fi
        done
  fi
done < "$OBJ_FILE"

# ---- Step 3: Unique CIDs & DB2 cntrname (build CID -> PATH map) --------------
awk -F',' 'NR>1{print $2}' "$MAP_FILE" | sort -n | uniq > "$CID_FILE"
echo "$(ts) Container IDs collected: $(wc -l < "$CID_FILE")" | tee -a "$RUN_SUM"

# Select cntrid and cntrname to get an unambiguous mapping
{
  echo "connect to ${DB_NAME};"
  echo "set schema ${DB_SCHEMA};"
  while IFS= read -r CID || [[ -n "$CID" ]]; do
    [[ -z "$CID" ]] && continue
    echo "select cntrid, cntrname from sd_containers where cntrid=${CID};"
  done < "$CID_FILE"
} > "$SQL_FILE"

DB2_ERR="${OUT_DIR}/db2_error.log"
"$DB2_BIN" -txf "$SQL_FILE" > "$RAW_FILE" 2> "$DB2_ERR" || {
  echo "DB2 query failed. Check ${DB2_ERR} and ${RAW_FILE} for details." | tee -a "$RUN_SUM"
  exit 4
}

# Parse RAW_FILE: build CID -> PATH map and legacy outputs
awk -F'|' '
  NF>=2 {
    for (i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i)}
    id=$1; path=$2;
    if (id ~ /^[0-9]+$/ && length(path)>0) {
      print id "\t" path
    }
  }' "$RAW_FILE" | sort -k1,1n -u > "$CID2PATH"

# Legacy .ccf list (paths only)
cut -f2 "$CID2PATH" | sort -u > "$CCF_FILE"

# ---- Step 4: Aggregate per object (IDs & PATHS joined) -----------------------
echo "filespace_name,full_object_name,object_id,container_ids,container_paths" > "$OBJ2CNP_AGG"

# Build OID -> unique CID list
awk -F',' 'NR>1 {print $3","$4}' "$OBJ2CID_DENORM" | sort -u > "${OUT_DIR}/oid_cids.csv"
# Join CIDs to paths using CID2PATH
# Result rows: OID,CID,PATH
join -t $'\t' -1 1 -2 1 \
  <(awk -F',' '{print $2"\t"$1}' "${OUT_DIR}/oid_cids.csv" | sort -k1,1) \
  <(sort -k1,1 "$CID2PATH") \
  | awk -F'\t' '{print $2","$1","$3}' > "${OUT_DIR}/oid_cid_path.csv" || true

# Build per-OID aggregated lists (container_ids, container_paths)
awk -F',' -v SEP="$LIST_SEP" '
  {
    oid=$1; cid=$2; path=$3
    if (seen_cid[oid FS cid]++) next
    cids[oid]  = (cids[oid]  ? cids[oid]  SEP cid  : cid)
    paths[oid] = (paths[oid] ? paths[oid] SEP path : path)
  }
  END{
    for (o in cids) { print o","cids[o]","paths[o] }
  }' "${OUT_DIR}/oid_cid_path.csv" \
  | sort -n > "${OUT_DIR}/oid_lists.csv" || true
# Format: OID, CID_LIST, PATH_LIST

# Join with OBJECTS_CSV on object_id to add filespace and full object name
# OBJECTS_CSV columns: fs, full, oid
join -t',' -1 3 -2 1 \
  <(sort -t',' -k3,3 "$OBJECTS_CSV") \
  <(sort -t',' -k1,1 "${OUT_DIR}/oid_lists.csv") \
  | awk -F',' -v OFS=',' '{print $1,$2,$3,$4,$5}' >> "$OBJ2CNP_AGG" || true
# Output columns: filespace_name, full_object_name, object_id, container_ids, container_paths

# ---- Step 5: Summary ---------------------------------------------------------
end_epoch=$(date +%s)
elapsed=$(( end_epoch - start_epoch ))

{
  echo
  echo "===== SUMMARY ====="
  echo "Pairs used file:            $PAIRS_USED (count: $pairs_count)"
  echo "Invalid lines:              $INVALID ($( [ -s "$INVALID" ] && wc -l < "$INVALID" || echo 0 ))"
  echo "Objects CSV:                $OBJECTS_CSV ($(($(wc -l < "$OBJECTS_CSV")-1)) rows)"
  echo "Object IDs file:            $OBJ_FILE ($(wc -l < "$OBJ_FILE"))"
  echo "Object->Container map:      $OBJ2CID_DENORM ($(($(wc -l < "$OBJ2CID_DENORM")-1)) rows)"
  echo "Container ID list:          $CID_FILE ($(wc -l < "$CID_FILE"))"
  echo "DB2 raw output:             $RAW_FILE"
  echo "CID->Path map:              $CID2PATH ($(wc -l < "$CID2PATH"))"
  echo "Aggregated per object:      $OBJ2CNP_AGG ($(($(wc -l < "$OBJ2CNP_AGG")-1)) rows)"
  echo "Final CCF path list:        $CCF_FILE ($(wc -l < "$CCF_FILE"))"
  echo "List separator used:        '${LIST_SEP}'"
  echo "Run time (s):               $elapsed"
} | tee -a "$RUN_SUM"

echo
echo "Done. Output directory: $OUT_DIR"