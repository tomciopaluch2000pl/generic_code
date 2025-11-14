#!/usr/bin/env bash
# ----------------------------------------------------------------------
# generate_fs_macros_by_node.sh
#
# Purpose:
#   Read a CMOD→TSM mapping CSV and, for each distinct node (column 13),
#   generate three files:
#     <NODE>_rename.mac        - RENAME FILESPACE commands (old -> new)
#     <NODE>_rollback.mac      - inverse RENAME FILESPACE (new -> old)
#     <NODE>_rename_plan.csv   - plan/log for this node
#
# CSV column mapping (1-based indices):
#   2  -> OD_INSTAME_SRC   (old instance name)
#   5  -> AGID_NAME_SRC    (old AGID / old fs suffix)
#   6  -> OD_INSTAME_DST   (new instance name)
#   9  -> AGID_NAME_DST    (new AGID / new fs suffix)
#   13 -> NODE name        (TSM nodename, e.g. E1-ODCN_S_0202_01OY_6)
#
# Safety:
#   - Script first scans the CSV to collect all nodes and aborts
#     if ANY of the target files already exists:
#       <NODE>_rename.mac / <NODE>_rollback.mac / <NODE>_rename_plan.csv
#   - Duplicate triplets (node, old_fs, new_fs) are emitted only once.
#
# Usage:
#   ./generate_fs_macros_by_node.sh TSM_FILESPACEMAP_PROD_EMEA.csv
#
# Then in TSM, for a given node:
#   dsmadmc -se <SERVER> -id <USER> -pa <PASS> -noc \
#           -cmdfile=E1-ODCN_S_0202_01OY_6_rename.mac
#
# And to undo:
#   dsmadmc -se <SERVER> -id <USER> -pa <PASS> -noc \
#           -cmdfile=E1-ODCN_S_0202_01OY_6_rollback.mac
# ----------------------------------------------------------------------

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input.csv>" >&2
  exit 1
fi

input_csv=$1

if [[ ! -f "$input_csv" ]]; then
  echo "ERROR: Input CSV not found: $input_csv" >&2
  exit 1
fi

# ------------------- 1st pass: collect all node names ----------------------

echo "INFO : Scanning CSV for node names (column 13)..." >&2

mapfile -t NODES < <(
  awk -F',' '
    NR == 1 { next }                # skip header
    {
      sub(/\r$/, "", $0);           # strip Windows CR if present
      if (NF >= 13 && $13 != "") {
        node = $13;
        gsub(/^[ \t]+|[ \t]+$/, "", node);  # trim spaces
        print node;
      }
    }
  ' "$input_csv" | sort -u
)

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: No node names found in column 13 of $input_csv" >&2
  exit 1
fi

echo "INFO : Found ${#NODES[@]} distinct node(s)." >&2

# ----------------- Safety: check for existing output files -----------------

echo "INFO : Checking for existing output files per node..." >&2

for node in "${NODES[@]}"; do
  rename_mac="${node}_rename.mac"
  rollback_mac="${node}_rollback.mac"
  plan_csv="${node}_rename_plan.csv"

  for f in "$rename_mac" "$rollback_mac" "$plan_csv"; do
    if [[ -e "$f" ]]; then
      echo "ERROR: Output file already exists: $f" >&2
      echo "       Remove or rename it before rerunning this script." >&2
      exit 1
    fi
  done
done

echo "INFO : No existing output files detected. Generating macros..." >&2

# -------------------- 2nd pass: generate macros and logs -------------------

awk -F',' -v INFILE="$input_csv" '
  BEGIN {
    # Column mapping (1-based indices)
    COL_OLD_INST = 2;   # OD_INSTAME_SRC
    COL_OLD_AGID = 5;   # AGID_NAME_SRC
    COL_NEW_INST = 6;   # OD_INSTAME_DST
    COL_NEW_AGID = 9;   # AGID_NAME_DST
    COL_NODE     = 13;  # TSM node name (ODCN logon)
  }

  # Initialize files for a node only once
  function init_node_files(node,
                           rename_mac, rollback_mac, plan_csv) {

    rename_mac   = node "_rename.mac";
    rollback_mac = node "_rollback.mac";
    plan_csv     = node "_rename_plan.csv";

    if (!(node in initialized)) {
      print "* Macro generated from " INFILE " for node " node        > rename_mac;
      print "* RENAME operations"                                     >> rename_mac;
      print ""                                                        >> rename_mac;

      print "* Rollback macro for node " node                         > rollback_mac;
      print "* INVERSE operations"                                    >> rollback_mac;
      print ""                                                        >> rollback_mac;

      print "node,old_fs,new_fs,old_inst,old_agid,new_inst,new_agid"  > plan_csv;

      initialized[node] = 1;
    }
  }

  NR == 1 {
    # Skip header row
    next
  }

  {
    sub(/\r$/, "", $0);  # strip trailing CR from Windows CSV

    if (NF < COL_NODE) {
      next;
    }

    node     = $COL_NODE;
    old_inst = $COL_OLD_INST;
    old_agid = $COL_OLD_AGID;
    new_inst = $COL_NEW_INST;
    new_agid = $COL_NEW_AGID;

    # Trim whitespace around fields
    gsub(/^[ \t]+|[ \t]+$/, "", node);
    gsub(/^[ \t]+|[ \t]+$/, "", old_inst);
    gsub(/^[ \t]+|[ \t]+$/, "", old_agid);
    gsub(/^[ \t]+|[ \t]+$/, "", new_inst);
    gsub(/^[ \t]+|[ \t]+$/, "", new_agid);

    # Skip incomplete rows
    if (node == "" || old_inst == "" || old_agid == "" ||
        new_inst == "" || new_agid == "") {
      next;
    }

    old_fs = "/" old_inst "/" old_agid;
    new_fs = "/" new_inst "/" new_agid;

    # Deduplicate (node, old_fs, new_fs)
    key = node "|" old_fs "|" new_fs;
    if (seen[key]++ > 0) {
      next;
    }

    # Prepare files for this node if needed
    init_node_files(node);

    # Escape potential quotes in paths
    gsub(/"/, "\"\"", old_fs);
    gsub(/"/, "\"\"", new_fs);

    rename_mac   = node "_rename.mac";
    rollback_mac = node "_rollback.mac";
    plan_csv     = node "_rename_plan.csv";

    # Main macro: old -> new
    printf("rename filespace %s \"%s\" \"%s\"\n",
           node, old_fs, new_fs) >> rename_mac;

    # Rollback macro: new -> old
    printf("rename filespace %s \"%s\" \"%s\"\n",
           node, new_fs, old_fs) >> rollback_mac;

    # Plan log for this node
    printf("%s,%s,%s,%s,%s,%s,%s\n",
           node, old_fs, new_fs, old_inst, old_agid, new_inst, new_agid) >> plan_csv;
  }

  END {
    # Append quit to all macro files
    for (n in initialized) {
      rename_mac   = n "_rename.mac";
      rollback_mac = n "_rollback.mac";

      print ""     >> rename_mac;
      print "quit" >> rename_mac;

      print ""     >> rollback_mac;
      print "quit" >> rollback_mac;
    }
  }
' "$input_csv"

echo "INFO : Done. Generated per-node macros and logs:" >&2
for node in "${NODES[@]}"; do
  echo "  Node: $node" >&2
  echo "    ${node}_rename.mac" >&2
  echo "    ${node}_rollback.mac" >&2
  echo "    ${node}_rename_plan.csv" >&2
done