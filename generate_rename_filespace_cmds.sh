#!/bin/bash
# generate_rename_filespace_cmds.sh
#
# Reads a CSV-like file with lines:
#   node_name,filespace_name,filespace_id
#
# For each line it:
#   * detects trailing whitespace bytes (SPACE 0x20, TAB 0x09, CR 0x0D, LF 0x0A)
#     at the end of filespace_name,
#   * computes a trimmed version of the name (without those bytes),
#   * prints a report (OLD / NEW / removed HEX),
#   * optionally writes dsmadmc "rename filespace" commands into an output script.
#
# Default mode: DRY-RUN (no output script, only report).
# Execute mode: use --execute to actually generate the script with commands.
#
# Requirements:
#   * bash
#   * xxd (usually from vim-common package)
#
# Example (dry-run only):
#   ./generate_rename_filespace_cmds.sh \
#       --fs-filelist filespaces.lst
#
# Example (generate script):
#   ./generate_rename_filespace_cmds.sh \
#       --fs-filelist filespaces.lst \
#       --id <ADMIN_ID> --pwd <PASSWORD> \
#       --server <SERVER_NAME> \
#       --out-file rename_filespaces.sh \
#       --execute

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 --fs-filelist FILE [--id ID --pwd PWD --server NAME --out-file FILE --execute]

  --fs-filelist   Path to input list: node_name,filespace_name,filespace_id
  --id            Admin ID for dsmadmc (required only with --execute)
  --pwd           Admin password for dsmadmc (required only with --execute)
  --server        Server name (used for -servername, optional but recommended)
  --out-file      Output shell script with dsmadmc commands (default: rename_filespaces_<server>.sh)
  --execute       Generate the output script (otherwise DRY-RUN and no file is written)

By default (without --execute) the script only prints a report (DRY-RUN).
EOF
    exit 1
}

# Default values
FS_FILELIST=""
ADMIN_ID=""
ADMIN_PWD=""
SERVER_NAME=""
OUT_FILE=""
EXECUTE=0   # 0 = dry-run, 1 = generate script

# Parse arguments (simple long-option parser)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fs-filelist)
            FS_FILELIST="$2"; shift 2 ;;
        --id)
            ADMIN_ID="$2"; shift 2 ;;
        --pwd)
            ADMIN_PWD="$2"; shift 2 ;;
        --server)
            SERVER_NAME="$2"; shift 2 ;;
        --out-file)
            OUT_FILE="$2"; shift 2 ;;
        --execute)
            EXECUTE=1; shift ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: $1" >&2
            usage ;;
    esac
done

# Basic checks
if [[ -z "$FS_FILELIST" ]]; then
    echo "ERROR: --fs-filelist is required." >&2
    usage
fi

if [[ ! -f "$FS_FILELIST" ]]; then
    echo "ERROR: Input file not found: $FS_FILELIST" >&2
    exit 1
fi

if ! command -v xxd >/dev/null 2>&1; then
    echo "ERROR: 'xxd' command not found. Please install it (e.g. vim-common)." >&2
    exit 1
fi

if [[ $EXECUTE -eq 1 ]]; then
    # In execute mode we really need credentials
    if [[ -z "$ADMIN_ID" ]]; then
        read -r -p "Enter admin ID: " ADMIN_ID
    fi
    if [[ -z "$ADMIN_PWD" ]]; then
        read -r -s -p "Enter admin password: " ADMIN_PWD
        echo
    fi
fi

# Decide output file name
if [[ -z "$OUT_FILE" ]]; then
    if [[ -n "$SERVER_NAME" ]]; then
        OUT_FILE="rename_filespaces_${SERVER_NAME}.sh"
    else
        OUT_FILE="rename_filespaces.sh"
    fi
fi

# Prepare output script if in execute mode
if [[ $EXECUTE -eq 1 ]]; then
    echo "#!/bin/bash" >"$OUT_FILE"
    echo "# Auto-generated dsmadmc rename filespace commands" >>"$OUT_FILE"
    echo "# Review carefully before executing." >>"$OUT_FILE"
    echo >>"$OUT_FILE"
    chmod +x "$OUT_FILE"
fi

echo "### Filespace trailing whitespace analysis ###"
echo "Input file : $FS_FILELIST"
if [[ $EXECUTE -eq 1 ]]; then
    echo "Mode       : EXECUTE (commands will be written to $OUT_FILE)"
else
    echo "Mode       : DRY-RUN (no script will be written)"
fi
echo

total_rows=0
changed=0

# Helper: convert string to hex (continuous, no spaces)
to_hex() {
    # Prints lowercase hex, no newline
    printf '%s' "$1" | xxd -p | tr -d '\n'
}

# Main loop over lines
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip completely empty lines
    [[ -z "$line" ]] && continue

    total_rows=$((total_rows + 1))

    # Skip header if present
    case "$line" in
        node_name,*|NODE_NAME,*)
            continue
            ;;
    esac

    # Split into 3 fields using first and last comma, preserving whitespace
    node_name="${line%%,*}"
    rest="${line#*,}"
    filespace_name="${rest%%,*}"
    fsid="${rest##*,}"

    # Remove possible surrounding spaces from node_name and fsid (not from filespace_name!)
    node_name="${node_name#"${node_name%%[![:space:]]*}"}"
    node_name="${node_name%"${node_name##*[![:space:]]}"}"
    fsid="${fsid#"${fsid%%[![:space:]]*}"}"
    fsid="${fsid%"${fsid##*[![:space:]]}"}"

    # Convert original filespace_name to hex
    orig_hex=$(to_hex "$filespace_name")

    # If empty name, skip (should not happen, but be safe)
    if [[ -z "$orig_hex" ]]; then
        continue
    fi

    trim_hex="$orig_hex"

    # Strip trailing whitespace bytes: 20 (space), 09 (tab), 0a (LF), 0d (CR)
    while [[ ${#trim_hex} -ge 2 ]]; do
        byte="${trim_hex: -2}"
        case "$byte" in
            20|09|0a|0A|0d|0D)
                trim_hex="${trim_hex:0:${#trim_hex}-2}"
                ;;
            *)
                break
                ;;
        esac
    done

    # If no change in hex, nothing to do
    if [[ "$trim_hex" == "$orig_hex" ]]; then
        continue
    fi

    # Compute removed part (suffix)
    removed_len=$(( ${#orig_hex} - ${#trim_hex} ))
    removed_hex="${orig_hex: -$removed_len}"

    # Rebuild trimmed name from hex
    if [[ -z "$trim_hex" ]]; then
        # Name consisted only of whitespace -> do NOT touch
        echo "Row $total_rows: WARNING: filespace name is only whitespace, skipping."
        echo "  Line: $line"
        echo
        continue
    fi
    trimmed_name=$(printf '%s' "$trim_hex" | xxd -r -p)

    changed=$((changed + 1))

    echo "Row $total_rows:"
    echo "  Node       : $node_name"
    echo "  FSID       : $fsid"
    echo "  OLD name   : $(printf '%q' "$filespace_name")"
    echo "  NEW name   : $(printf '%q' "$trimmed_name")"
    echo "  RemovedHEX : $removed_hex"
    echo

    if [[ $EXECUTE -eq 1 ]]; then
        # Build base dsmadmc command
        base_cmd=(dsmadmc "-id=$ADMIN_ID" "-password=$ADMIN_PWD")
        [[ -n "$SERVER_NAME" ]] && base_cmd+=("-servername=$SERVER_NAME")

        # Single-quoted TSM command.
        # NOTE: This assumes filespace names do not contain single quotes.
        tsm_cmd="rename filespace $node_name '$filespace_name' '$trimmed_name'"

        {
            echo "# Node: $node_name, FSID (reference only): $fsid"
            echo "# Removed trailing bytes: $removed_hex"
            printf '%s ' "${base_cmd[@]}"
            echo "\"$tsm_cmd\""
            echo
        } >>"$OUT_FILE"
    fi

done < "$FS_FILELIST"

echo "### Summary ###"
echo "Total lines processed : $total_rows"
echo "Filespaces to change  : $changed"
if [[ $EXECUTE -eq 1 ]]; then
    echo "Commands written to   : $OUT_FILE"
else
    echo "No script written (dry-run). Use --execute to generate the shell script."
fi