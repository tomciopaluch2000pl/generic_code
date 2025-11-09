#!/usr/bin/env bash
# =============================================================================
# NAME:        ccf_extractor_from_list.sh
# PURPOSE:
#   Build a unique list of container file paths (.ccf) for many input
#   (filespace_name, ll_name) patterns AND produce object-centric reports:
#     1) objects.csv                  -> filespace_name, full_object_name(HL+LL), object_id
#     2) obj_to_container_ids.csv     -> filespace_name, full_object_name, object_id, container_id (deduped)
#     3) obj_to_container_paths.csv   -> filespace_name, full_object_name, object_id, container_id, container_path
#
# INPUT FILE FORMAT (one per line, comma-separated):
#   <filespace_name>,<ll_name>
#
# LEGACY OUTPUTS (kept 1:1):
#   pairs_used.csv, invalid_lines.txt, object_ids.txt, objid_to_container.csv,
#   container_ids.txt, get_ccf.sql, ccf_paths.raw, ccf_paths.txt, run_summary.txt
#
# REQUIREMENTS:
#   - dsmadmc in PATH (admin CLI)
#   - db2 in PATH and cataloged DB name
#   - coreutils: awk, grep, sort, cut, tr
#
# SECURITY NOTE:
#   Passing --pass exposes the password in process list. Prefer env/secure store.
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
LIST_SEP="|"  # (kept for compatibility; not used in flat Step 4)

print_usage() {
  cat <<EOF
Usage:
  $0 --list <FILE> --server <SERVER> --user <ID> --pass <PASSWORD> \\
     [--db DBNAME] [--schema SCHEMA] [--out-dir DIR] [--list-sep SEP]
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
    --list-sep)  LIST_SEP="${2:-|}"; shift 2 ;; # kept for compatibility
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

OBJECTS_CSV="${OUT_DIR}/objects.csv"
OBJ2CID_DENORM="${OUT_DIR}/obj_to_container_ids.csv"
OBJ2CNP_AGG="${OUT_DIR}/obj_to_container_paths.csv"
CID2PATH="${OUT_DIR}/cid_to_path.tsv"
OID_LOOKUP="${OUT_DIR}/oid_lookup.tsv"

# ---- Helpers -----------------------------------------------------------------
run_dsmadmc_csv() {
  "$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" -comma -dataonly=yes "$@"
}
extract_container_ids_from_show() {
  grep -Eo 'Container ID:[[:space:]]*[0-9]+' | awk '{print $3}'
}
trim() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
ts() { date +'%Y-%m-%d %H:%M:%S'; }
join_hl_ll() {
  local hl="$1" ll="$2"
  hl="${hl%\"}"; hl="${hl#\"}"; ll="${ll%\"}"; ll="${ll#\"}"
  if [[ -z "$hl" ]]; then echo "$ll"
  elif [[ "${hl: -1}" == "/" || "${ll:0:1}" == "/" ]]; then echo "${hl}${ll}"
  else echo "${hl}/${ll}"; fi
}

# ---- Step 0: Parse input list ------------------------------------------------
: > "$PAIRS_ALL"; : > "$INVALID"
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  fs=$(echo "$line" | cut -d',' -f1 | tr -d '\r' | trim)
  ll=$(echo "$line" | cut -d',' -f2- | tr -d '\r' | trim)
  ll_digits=$(echo "$ll" | sed -E 's/[^0-9].*$//')
  if [[ -z "$fs" || -z "$ll_digits" ]]; then echo "$line" >> "$INVALID"; continue; fi
  echo "${fs},${ll_digits}" >> "$PAIRS_ALL"
done < "$LIST_FILE"

if [[ -s "$PAIRS_ALL" ]]; then sort -u "$PAIRS_ALL" > "$PAIRS_USED"
else echo "No valid pairs found in list. See $INVALID" >&2; exit 2; fi

# ---- Step 1: Query OBJECTS ---------------------------------------------------
: > "$OBJ_FILE"
echo 'filespace_name,full_object_name,object_id' > "$OBJECTS_CSV"
start_epoch=$(date +%s)
pairs_count=$(wc -l < "$PAIRS_USED" | tr -d ' ')
echo "$(ts) Pairs to process: $pairs_count" | tee -a "$RUN_SUM"

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
        if (oid ~ /^[0-9]+$/) print fs "\t" hl "\t" ll "\t" oid;
      }' \
    | while IFS=$'\t' read -r fs hl ll oid; do
        full=$(join_hl_ll "$hl" "$ll")
        printf '%s,%s,%s\n' "$fs" "$full" "$oid" >> "$OBJECTS_CSV"
        echo "$oid" >> "$OBJ_FILE"
      done
done < "$PAIRS_USED"

if [[ -s "$OBJ_FILE" ]]; then sort -n -u "$OBJ_FILE" -o "$OBJ_FILE"
else echo "No matching objects for provided pairs." | tee -a "$RUN_SUM"; exit 3; fi
echo "$(ts) Objects collected (unique OIDs): $(wc -l < "$OBJ_FILE")" | tee -a "$RUN_SUM"

# Build OID lookup: OID -> FS, FULL
awk -F',' 'NR>1 {print $3"\t"$1"\t"$2}' "$OBJECTS_CSV" | sort -u > "$OID_LOOKUP"

# ---- Step 2: Map OID -> Container IDs (dedup) --------------------------------
echo "filespace_name,full_object_name,object_id,container_id" > "$OBJ2CID_DENORM"
echo "object_id,container_id" > "$MAP_FILE"

while IFS= read -r OID || [[ -n "$OID" ]]; do
  [[ -z "$OID" ]] && continue
  OUT="$("$DSMADMC_BIN" -se="$SERVER" -id="$USER" -password="$PASS" \
        "show invo ${OID} listchun=yes" 2>/dev/null || true)"
  [[ -z "$OUT" ]] && continue
  # Deduplicate container IDs per OID on the fly
  echo "$OUT" | extract_container_ids_from_show | awk -v O="$OID" 'NF{print O","$1}' \
    | sort -t',' -u \
    | while IFS=',' read -r o cid; do
        echo "${o},${cid}" >> "$MAP_FILE"
        fs_full=$(awk -F'\t' -v x="$o" '($1==x){print $2"\t"$3; exit}' "$OID_LOOKUP")
        if [[ -n "$fs_full" ]]; then
          fs=$(echo "$fs_full" | cut -f1)
          full=$(echo "$fs_full" | cut -f2-)
          printf '%s,%s,%s,%s\n' "$fs" "$full" "$o" "$cid" >> "$OBJ2CID_DENORM"
        fi
      done
done < "$OBJ_FILE"

# Final dedupe (safety)
if [[ -s "$MAP_FILE" ]]; then
  { echo "object_id,container_id"; tail -n +2 "$MAP_FILE" | sort -t',' -u; } > "${MAP_FILE}.tmp" && mv "${MAP_FILE}.tmp" "$MAP_FILE"
fi
if [[ -s "$OBJ2CID_DENORM" ]]; then
  { echo "filespace_name,full_object_name,object_id,container_id"; tail -n +2 "$OBJ2CID_DENORM" | sort -t',' -u; } > "${OBJ2CID_DENORM}.tmp" && mv "${OBJ2CID_DENORM}.tmp" "$OBJ2CID_DENORM"
fi

# ---- Step 3: CID list & DB2 cntrname (robust parsing) ------------------------
awk -F',' 'NR>1{print $2}' "$MAP_FILE" | sort -n | uniq > "$CID_FILE"
echo "$(ts) Container IDs collected: $(wc -l < "$CID_FILE")" | tee -a "$RUN_SUM"

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

# Parse DB2 rows regardless of delimiter (treat as whitespace-separated):
# expected: "<id> <path-with-possible-spaces>"
awk '
  NF>=2 {
    id=$1; $1="";
    path=substr($0,2);
    gsub(/^[[:space:]]+|[[:space:]]+$/,"",path);
    if (id ~ /^[0-9]+$/ && length(path)>0) print id "\t" path
  }' "$RAW_FILE" | sort -k1,1n -u > "$CID2PATH"

# Legacy: pure path list
cut -f2 "$CID2PATH" | sort -u > "$CCF_FILE"

# ---- Step 4: Per-object, per-container with PATH (one row per container) ----
# Output columns: filespace_name, full_object_name, object_id, container_id, container_path
echo "filespace_name,full_object_name,object_id,container_id,container_path" > "$OBJ2CNP_AGG"

# Load CID->PATH map and enrich OBJ2CID_DENORM (dedup already applied above)
awk -v FS=',' -v OFS=',' -v MAP="$CID2PATH" '
  BEGIN{
    while ((getline < MAP) > 0) {
      # MAP lines: CID \t PATH
      split($0, a, "\t")
      if (a[1] ~ /^[0-9]+$/) cid2path[a[1]] = a[2]
    }
  }
  FNR==1 {next}  # skip header of obj_to_container_ids.csv
  {
    fs=$1; full=$2; oid=$3; cid=$4
    path = (cid in cid2path ? cid2path[cid] : "")
    key = fs OFS full OFS oid OFS cid OFS path
    if (!(key in seen)) { seen[key]=1; print fs, full, oid, cid, path }
  }
' "$OBJ2CID_DENORM" \
| sort -t',' -k1,1 -k2,2 -k3,3n -k4,4n >> "$OBJ2CNP_AGG"

# ---- Step 5: Summary ---------------------------------------------------------
end_epoch=$(date +%s); elapsed=$(( end_epoch - start_epoch ))
{
  echo
  echo "===== SUMMARY ====="
  echo "Pairs used file:            $PAIRS_USED (count: $pairs_count)"
  echo "Invalid lines:              $INVALID ($( [ -s "$INVALID" ] && wc -l < "$INVALID" || echo 0 ))"
  echo "Objects CSV:                $OBJECTS_CSV ($(($(wc -l < "$OBJECTS_CSV")-1)) rows)"
  echo "Object IDs file:            $OBJ_FILE ($(wc -l < "$OBJ_FILE"))"
  echo "Object->Container map:      $OBJ2CID_DENORM ($(($(wc -l < "$OBJ2CID_DENORM")-1)) rows, deduped)"
  echo "Container ID list:          $CID_FILE ($(wc -l < "$CID_FILE"))"
  echo "DB2 raw output:             $RAW_FILE"
  echo "CID->Path map:              $CID2PATH ($(wc -l < "$CID2PATH"))"
  echo "Per-object per-container:   $OBJ2CNP_AGG ($(($(wc -l < "$OBJ2CNP_AGG")-1)) rows)"
  echo "Final CCF path list:        $CCF_FILE ($(wc -l < "$CCF_FILE"))"
  echo "Run time (s):               $elapsed"
} | tee -a "$RUN_SUM"

echo
echo "Done. Output directory: $OUT_DIR"