#!/usr/bin/env bash
# Rehearsal test for backup/mewseum-backup.sh.
# Runs the real script against a fake server folder and fake docker/rsync/drive commands,
# so nothing real is touched. Run it:   bash tests/rehearsal.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../backup/mewseum-backup.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  pass: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---- fake commands (put first on PATH) -----------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$STUBLOG"
case "$1" in
  inspect) echo true;;
  exec) args="$*"
    case "$args" in
      *"immich_postgres pg_dump"*) [ "${FAIL_IMMICH:-0}" = 1 ] && exit 1; echo "-- PostgreSQL database dump"; head -c 30000 /dev/urandom | base64;;
      *pg_dump*) echo "-- PostgreSQL database dump"; head -c 30000 /dev/urandom | base64;;
      *"maintenance:mode --on"*) echo "Maintenance mode enabled";;
      *"maintenance:mode --off"*) echo "Maintenance mode disabled";;
      *"occ status"*) echo "  - maintenance: false";;
    esac;;
esac
EOF
printf '#!/bin/bash\necho /dev/sdb1\n' > "$W/bin/findmnt"
printf '#!/bin/bash\necho "${FAKE_LABEL:-TESTDRIVE}"\n' > "$W/bin/lsblk"
printf '#!/bin/bash\nexit 0\n' > "$W/bin/mountpoint"
cat > "$W/bin/rsync" <<'EOF'
#!/bin/bash
src="${@: -2:1}"; dst="${@: -1}"
cp -rT "$src" "$dst"
EOF
# On Windows (Git Bash) the real Python needs Windows paths; elsewhere use the real python3.
if command -v cygpath >/dev/null; then
cat > "$W/bin/python3" <<'EOF'
#!/bin/bash
args=(); for a in "$@"; do if [[ $a == /* ]]; then args+=("$(cygpath -w "$a")"); else args+=("$a"); fi; done
exec python "${args[@]}"
EOF
else
  ln -s "$(command -v python3)" "$W/bin/python3"
fi
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" STUBLOG="$W/stub.log"

# ---- fake server and drive --------------------------------------------------------------------------
SRV="$W/srv"; MNT="$W/mnt"
mkdir -p "$SRV/immich/library" "$SRV/nextcloud/html" "$SRV/myapp/data" "$MNT"
echo photo > "$SRV/immich/library/a.jpg"
echo cloud > "$SRV/nextcloud/html/config.php"
echo "SECRET=1" > "$SRV/immich/.env"
python3 -c "
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute('create table t(x)'); con.execute('insert into t values (42)'); con.commit()
" "$(command -v cygpath >/dev/null && cygpath -w "$SRV/myapp/data/app.db" || echo "$SRV/myapp/data/app.db")"

cat > "$W/backup.conf" <<EOF
MNT="$MNT"
DRIVE_LABEL="TESTDRIVE"
SRV="$SRV"
IMMICH_LIB="$SRV/immich/library"
NC_HTML="$SRV/nextcloud/html"
APPS="myapp"
CONFIG_FILES="immich/.env"
EOF
export BACKUP_CONF="$W/backup.conf" BACKUP_TEST=1

run() { bash "$SCRIPT" "$@" > "$W/out.txt" 2>&1; echo $?; }

echo "1. --check changes nothing"
rc=$(run --check)
check "check exits 0" "[ $rc = 0 ]"
check "check wrote no backup folder" "[ ! -d '$MNT/Mewseum-Backup' ]"

echo "2. full run"
: > "$STUBLOG"
rc=$(run)
check "run exits 0" "[ $rc = 0 ]"
check "immich dump saved" "ls '$MNT'/Mewseum-Backup/db-dumps/immich-*.sql.gz >/dev/null 2>&1"
check "nextcloud dump saved" "ls '$MNT'/Mewseum-Backup/db-dumps/nextcloud-*.sql.gz >/dev/null 2>&1"
check "photo copied" "[ -f '$MNT/Mewseum-Backup/files/immich-library/a.jpg' ]"
check ".env copied" "[ -f '$MNT/Mewseum-Backup/files/configs/immich/.env' ]"
check "sqlite copy readable" "python3 -c \"import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute('select x from t').fetchone()[0])\" '$(command -v cygpath >/dev/null && cygpath -w "$MNT/Mewseum-Backup/files/apps/myapp/data/app.db" || echo "$MNT/Mewseum-Backup/files/apps/myapp/data/app.db")' | grep -q 42"
check "maintenance turned on once and off once" "[ \$(grep -c -- 'mode --on' '$STUBLOG') = 1 ] && [ \$(grep -c -- 'mode --off' '$STUBLOG') = 1 ]"
check "summary says finished" "grep -q 'Backup finished' '$W/out.txt'"

echo "3. wrong drive label is refused"
rc=$(FAKE_LABEL=OTHER run)
check "exits non-zero" "[ $rc != 0 ]"
check "says why" "grep -q 'Not writing to the wrong drive' '$W/out.txt'"

echo "4. no label configured is refused"
sed -i 's/^DRIVE_LABEL=.*/DRIVE_LABEL=""/' "$W/backup.conf"
rc=$(run)
check "exits non-zero" "[ $rc != 0 ]"
sed -i 's/^DRIVE_LABEL=.*/DRIVE_LABEL="TESTDRIVE"/' "$W/backup.conf"

echo "5. a failed Immich dump is reported and nothing bad is saved"
rm -f "$MNT"/Mewseum-Backup/db-dumps/*
rc=$(FAIL_IMMICH=1 run)
check "exits non-zero" "[ $rc != 0 ]"
check "no immich dump left behind" "! ls '$MNT'/Mewseum-Backup/db-dumps/immich-* >/dev/null 2>&1"
check "no .part files left" "! ls '$MNT'/Mewseum-Backup/db-dumps/*.part >/dev/null 2>&1"
check "other steps still ran" "ls '$MNT'/Mewseum-Backup/db-dumps/nextcloud-*.sql.gz >/dev/null 2>&1"

echo "6. old dumps are pruned, other files are never deleted"
touch -d '30 days ago' "$MNT/Mewseum-Backup/db-dumps/immich-2000-01-01_0000.sql.gz"
echo mine > "$MNT/Mewseum-Backup/db-dumps/my-own-notes.txt"
rc=$(run)
check "old dump removed" "[ ! -f '$MNT/Mewseum-Backup/db-dumps/immich-2000-01-01_0000.sql.gz' ]"
check "unrelated file kept" "[ -f '$MNT/Mewseum-Backup/db-dumps/my-own-notes.txt' ]"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
