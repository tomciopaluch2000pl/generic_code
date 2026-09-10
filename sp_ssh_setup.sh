#!/bin/sh
# SP SSH setup 1.0.0 -- POSIX sh, RHEL 7.9 / AIX 7.3 design target.
# Run from a trusted, root-owned directory. No database commands are executed.
# No SSH daemon, account policy, password or existing private key is changed.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/openssh/bin:/usr/openssh/sbin
export PATH
LC_ALL=C
export LC_ALL
umask 077
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask() { printf '%s: ' "$1" >&2; IFS= read -r REPLY || fail 'Input ended'; }
# Restrict identifiers/paths used inside su and remote shell commands.
safe() { case "$1" in ''|*[!a-zA-Z0-9_./:@+-]*) fail "Unsupported characters: $1";; esac; }
help() {
cat <<'HELP'
Usage: sh sp_ssh_setup.sh source|target|test|diagnose [user]
Default user: aaodmgr1. Run as root on each host.

1. SOURCE: sh sp_ssh_setup.sh source aaodmgr1
   Creates a dedicated RSA 3072 key (prompts for key passphrase).
   Empty passphrase enables unattended use; use only if locally permitted.
   Copy ONLY the displayed ssh-rsa public-key line to the target.
2. TARGET: sh sp_ssh_setup.sh target aaodmgr1
   Enter actual source connection IP/hostname and target IP/SSH port.
   Validates default sshd config and Match rules. Appends a restricted key
   to ~/.ssh/authorized_keys only if that file is enabled. Creates backup.
   Copy the displayed TARGET HOST PUBLIC KEY line back to the source.
3. SOURCE: sh sp_ssh_setup.sh test aaodmgr1
   Pins the pasted target host key in a separate known-hosts file, tests SSH,
   optionally uploads a tiny probe to an EXISTING writable target directory,
   compares its content, and removes that probe. Prints the SCP command.
   Enter the public-key filename from step 1 when asked for Identity path,
   WITHOUT its .pub suffix (the private key path).
4. diagnose: read-only local account/config diagnostics.

The same workflow supports Linux->AIX, AIX->Linux, AIX->AIX, Linux->Linux.
Only the initiating host needs a private key. Reverse transfers may use a
pull from the initiating host, without creating reverse SSH trust.
Requires installed OpenSSH and local root access. No Python/Bash required.
This tool does NOT migrate SP or run extractdb/insertdb.

Custom AuthorizedKeysFile, AuthorizedKeysCommand-only, alternate sshd -f
configurations, shared/NFS homes, ACLs and centrally managed authentication
need local review. For alternate sshd config, diagnose it separately first.
No account unlocking or password/algorithm-policy downgrade is performed.
A locked/expired account, PAM, PowerBroker, AllowUsers, Match rules, firewall
or absent SFTP subsystem can still prevent access. Check server SSH logs.
RSA keys do not imply enabling obsolete ssh-rsa/SHA-1 signatures.

Cleanup: remove ONLY the migration key line from target authorized_keys
(identified by public-key fingerprint/comment). Do not restore an old backup
blindly: other administrators may have added keys since then. Remove the
source's dedicated key directory after the migration/access is no longer
needed. The tool prints the directory. Never copy the private key.
HELP
}
MODE=${1:-help}; U=${2:-aaodmgr1}
case "$MODE" in help|-h|--help) help; exit 0;; source|target|test|diagnose) :;; *) help; exit 1;; esac
safe "$U"; case "$U" in -*|*/*|*:*|*.*) fail 'Invalid account name';; esac
[ "$(id -u)" = 0 ] || fail 'Run as root through your authorized role'
OS=$(uname -s)
case "$OS" in
 AIX) H=$(lsuser -a home "$U" | sed 's/^[^ ]* home=//');;
 Linux) H=$(getent passwd "$U" | awk -F: 'NR==1 {print $6}');;
 *) fail "Unsupported OS: $OS";;
esac
safe "$H"; case "$H" in /*) :;; *) fail 'Home is not absolute';; esac
[ "$H" != / ] && [ -d "$H" ] || fail 'Invalid/missing home directory'
UID_EXPECTED=$(id -u "$U")
[ "$UID_EXPECTED" != 0 ] || fail 'Do not use this tool for root accounts'
printf 'Host=%s OS=%s User=%s UID=%s Home=%s\n' "$(hostname)" "$OS" "$U" "$UID_EXPECTED" "$H"
ls -ld "$H"
# File operations run as the instance owner, never as root. No recursive chown.
asuser() { su "$U" -c "$1"; }
[ "$(asuser 'id -u')" = "$UID_EXPECTED" ] || fail 'su unavailable or login shell/profile adds output; investigate locally'
D="$H/.ssh"
prepare() {
 HPERM=$(ls -ld "$H" | awk '{print $1}')
 case "$HPERM" in ?????w*|????????w*)
  printf 'Home is writable by group/others: %s\n' "$HPERM"
  ask 'Remove ONLY group/other write permissions on home? [y/N]'
  case "$REPLY" in y|Y) asuser "chmod go-w '$H'" || fail 'Home permissions require owner/admin review';;
   *) fail 'Home permissions need review before enabling SSH';; esac
  ;;
 esac
 asuser "set -eu; umask 077; [ ! -L '$D' ] || exit 1; if [ ! -d '$D' ]; then mkdir '$D'; fi; [ -O '$D' ] || exit 1; chmod 700 '$D'" || fail 'Cannot prepare owned .ssh directory (symlink refused)'
}
account_info() {
 if [ "$OS" = AIX ]; then
  lsuser -a home shell account_locked login rlogin expires "$U" || :
 else
  getent passwd "$U"
  passwd -S "$U" || :
  chage -l "$U" || :
  command -v getenforce >/dev/null 2>&1 && getenforce || :
 fi
}
sshd_config() {
 SSHD=$(command -v sshd) || fail 'sshd not found'
 ask 'Source IP as seen by target (after NAT, if any)'; SRCIP=$REPLY; safe "$SRCIP"
 ask 'Source hostname as resolved by target (use IP if no DNS)'; SRCHOST=$REPLY; safe "$SRCHOST"
 ask 'Target local IP used for this connection'; LOCALIP=$REPLY; safe "$LOCALIP"
 ask 'Target SSH port [22]'; PORT=${REPLY:-22}; portcheck
 "$SSHD" -t || fail 'Default sshd configuration does not validate'
 CFG=$("$SSHD" -T -C "user=$U,host=$SRCHOST,addr=$SRCIP,laddr=$LOCALIP,lport=$PORT") || fail 'Cannot resolve effective sshd configuration'
 printf '%s\n' "$CFG" | awk '$1 ~ /^(authorizedkeysfile|authorizedkeyscommand|pubkeyauthentication|authenticationmethods|strictmodes|allowusers|denyusers|allowgroups|denygroups|chrootdirectory|forcecommand|usepam|subsystem)$/ {print}'
}
portcheck() { case "$PORT" in ''|*[!0-9]*) fail 'Invalid port';; esac; [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail 'Invalid port'; }
case "$MODE" in
 diagnose) account_info; sshd_config; exit 0;;
 source)
 prepare
 # Atomic private directory: an existing key is never overwritten.
 KDIR="$D/sp_migration_$(date +%Y%m%d%H%M%S)_$$"
 asuser "umask 077; mkdir '$KDIR'" || fail 'Cannot create dedicated directory'
 KEY="$KDIR/id_rsa"
 asuser "ssh-keygen -t rsa -b 3072 -f '$KEY' -C 'sp-migration-$U-$(date +%Y%m%d)'" || fail 'Key generation failed'
 printf '\nPRIVATE identity path (keep on source): %s\n' "$KEY"
 printf '\nCOPY THIS PUBLIC KEY TO TARGET:\n'
 asuser "cat '$KEY.pub'; ssh-keygen -lf '$KEY.pub'"
 ;;
 target)
 account_info
 sshd_config
 printf '%s\n' "$CFG" | awk '$1=="pubkeyauthentication" && $2=="yes" {ok=1} END {exit !ok}' || fail 'Public-key authentication disabled'
 printf '%s\n' "$CFG" | awk -v h="$H" '$1=="authorizedkeysfile" {for(i=2;i<=NF;i++) if($i==".ssh/authorized_keys" || $i==h"/.ssh/authorized_keys" || $i=="%h/.ssh/authorized_keys") ok=1} END {exit !ok}' || fail 'Nonstandard AuthorizedKeysFile: no changes made; request an adapted version with diagnostic output'
 printf '\nPaste ONE public-key line from source (no private key, no options).\n'
 ask 'Public key'; PUB=$REPLY
 set -- $PUB
 [ "$#" -ge 2 ] || fail 'Incomplete public key'
 TYPE=$1; BLOB=$2
 case "$TYPE" in ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) :;; *) fail 'Unsupported public-key type';; esac
 case "$BLOB" in ''|*[!A-Za-z0-9+/=]*) fail 'Malformed public key';; esac
 prepare
 A="$D/authorized_keys"
 TMP="$D/sp_import_$(date +%Y%m%d%H%M%S)_$$"
 asuser "umask 077; mkdir '$TMP'" || fail 'Cannot create import directory'
 asuser "printf '%s\\n' '$TYPE $BLOB' > '$TMP/key'; ssh-keygen -lf '$TMP/key'" || fail 'Invalid public key'
 printf '\nKey restrictions: no agent/X11/port forwarding, no PTY; SCP remains allowed.\n'
 ask "Restrict key to source IP $SRCIP? [Y/n]"
 case "$REPLY" in n|N) OPT='no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty';;
 *) case "$SRCIP" in *[!0-9a-fA-F:.]*) fail 'Use a numeric source IP for from restriction';; esac
 OPT="from=\"$SRCIP\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty";; esac
 LINE="$OPT $TYPE $BLOB sp-migration-$(date +%Y%m%d)"
 # Retain all existing bytes and ACLs; append instead of replacing the file.
 # Refuse hardlinks/symlinks. Serialize our own invocations (other tools must
 # still not edit authorized_keys concurrently).
 asuser "set -eu
 umask 077
 mkdir '$D/sp_migration.lock' || exit 1
 trap 'rmdir $D/sp_migration.lock' 0
 [ ! -L '$A' ] || exit 1
 if [ -e '$A' ]; then
  [ -f '$A' ] && [ -O '$A' ] || exit 1
  [ \"\$(ls -ld '$A' | awk '{print \$2}')\" = 1 ] || exit 1
  if awk -v b='$BLOB' '{for(i=1;i<=NF;i++) if(\$i==b) found=1} END {exit !found}' '$A'; then
   echo 'Key already exists; existing options retained.'
   exit 0
  fi
  cp -p '$A' '$TMP/authorized_keys.before'
 else
  : > '$A'
 fi
 chmod 600 '$A'
 printf '\\n%s\\n' '$LINE' >> '$A'
 echo 'Public key appended. Backup (if file existed): $TMP/authorized_keys.before'
 " || fail 'Import failed; inspect owner, ACL, symlink/hardlink or existing lock directory'
 if [ "$OS" = Linux ] && command -v restorecon >/dev/null 2>&1; then
  restorecon "$D" "$A" || printf 'WARNING: restorecon failed; inspect SELinux labels.\n'
 fi
 printf '\nTARGET HOST PUBLIC KEYS: copy ONE line from the actual SSH daemon host key.\n'
 printf '%s\n' "$CFG" | while read -r NAME VALUE REST; do
  if [ "$NAME" = hostkey ] && [ -f "$VALUE.pub" ]; then
   printf '\nHost key: %s\n' "$VALUE.pub"; cat "$VALUE.pub"; ssh-keygen -lf "$VALUE.pub"
  fi
 done
 printf '\nUse test mode on the source. No sshd restart is required for this key append.\n'
 ;;
 test)
 ask 'Private identity path printed by source mode'; KEY=$REPLY; safe "$KEY"
 case "$KEY" in "$D"/sp_migration_*/id_rsa) :;; *) fail 'Use the dedicated migration identity';; esac
 asuser "test -f '$KEY'" || fail 'Identity unavailable'
 ask 'Target hostname or IPv4 address'; HOST=$REPLY
 case "$HOST" in ''|-*|*[!a-zA-Z0-9._-]*) fail 'Use DNS hostname or IPv4';; esac
 ask "Target user [$U]"; RU=${REPLY:-$U}; safe "$RU"
 case "$RU" in -*|*/*|*:*) fail 'Invalid remote user';; esac
 ask 'SSH port [22]'; PORT=${REPLY:-22}; portcheck
 printf 'Paste target HOST public key from its trusted root session, NOT the user key.\n'
 ask 'Host public key'; HPUB=$REPLY; set -- $HPUB
 [ "$#" -ge 2 ] || fail 'Incomplete host key'
 HT=$1; HB=$2
 case "$HT" in ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) :;; *) fail 'Unsupported host key';; esac
 case "$HB" in ''|*[!A-Za-z0-9+/=]*) fail 'Malformed host key';; esac
 TD="${KEY%/*}/test_$(date +%Y%m%d%H%M%S)_$$"
 asuser "umask 077; mkdir '$TD'; printf '%s\\n' '$HT $HB' > '$TD/host.pub'; ssh-keygen -lf '$TD/host.pub'" || fail 'Host key invalid'
 KH="$TD/known_hosts"
 if [ "$PORT" = 22 ]; then LABEL=$HOST; else LABEL="[$HOST]:$PORT"; fi
 asuser "printf '%s\\n' '$LABEL $HT $HB' > '$KH'"
 # Ignore personal config to avoid unexpected IdentityFile/ProxyCommand rules.
 # Keep host checking strict and never enable obsolete algorithms.
 OPTS="-F /dev/null -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KH -o GlobalKnownHostsFile=/dev/null -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o ConnectTimeout=15"
 printf '\nTesting as %s; enter key passphrase if configured.\n' "$U"
 asuser "ssh $OPTS -p $PORT $RU@$HOST 'id; hostname'" || fail 'SSH failed. Run the printed-style ssh command with -vvv and inspect target authentication logs. No policies changed.'
 ask 'Existing writable target directory for SCP probe (empty = skip)'; DEST=$REPLY
 if [ -n "$DEST" ]; then
  safe "$DEST"; case "$DEST" in /*) :;; *) fail 'Use an absolute target path';; esac
  PROBE="sp_ssh_probe_$(date +%Y%m%d%H%M%S)_$$"
  # Atomic remote directory prevents overwriting existing target files.
  REMOTE="$DEST/$PROBE"
  asuser "ssh $OPTS -p $PORT $RU@$HOST 'umask 077; mkdir $REMOTE'" || fail 'Target directory unavailable/not writable'
  asuser "printf '%s\\n' '$PROBE' > '$TD/probe'"
  asuser "scp $OPTS -P $PORT '$TD/probe' '$RU@$HOST:$REMOTE/probe'" || fail "SCP failed; inspect SFTP/SCP configuration. Empty probe directory may remain: $REMOTE"
  asuser "ssh $OPTS -p $PORT $RU@$HOST 'cat $REMOTE/probe' > '$TD/received'; cmp '$TD/probe' '$TD/received'" || fail "Probe mismatch; inspect $REMOTE"
  asuser "ssh $OPTS -p $PORT $RU@$HOST 'rm $REMOTE/probe && rmdir $REMOTE'" || fail 'Probe passed but remote cleanup failed'
  printf '\nSCP probe verified and remote probe removed.\n'
 fi
 printf '\nRun the following AS %s (via your PowerBroker role):\n' "$U"
 printf 'scp %s -P %s /ABSOLUTE/EXTRACT_FILE %s@%s:/ABSOLUTE/DESTINATION/\n' "$OPTS" "$PORT" "$RU" "$HOST"
 printf '\nAdd -v to scp or -vvv to ssh for diagnostics.\n'
 ;;
esac