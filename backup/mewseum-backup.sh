#!/usr/bin/env bash
# mewseum-backup.sh: back up a small Docker home server to an external drive.
#
#   sudo bash backup/mewseum-backup.sh            run the backup
#   sudo bash backup/mewseum-backup.sh --check    look around and report, change nothing
#
# Settings live in backup.conf next to this script (copy backup.conf.example). See the README.
#
# What it does, in this order (databases first, files second, as the Immich docs advise):
#   Immich database, Immich photos, Nextcloud (maintenance mode on, then off),
#   compose and .env files, then each SQLite app you list, then tidying.
#
# It NEVER deletes your files from the backup. The only thing it removes is database
# dumps older than KEEP_DAYS, and only the ones this script made.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# ---- settings (anything not set in backup.conf gets these defaults) ----------------------------
: "${MNT:=/mnt/backup}"                 # where the backup drive is mounted
: "${DRIVE_LABEL:=}"                    # REQUIRED: the label of the drive's partition (a safety check)
: "${SRV:=/srv/data}"                   # where your containers keep their data
: "${DEST_NAME:=Mewseum-Backup}"        # folder created at the top of the drive
: "${KEEP_DAYS:=14}"                    # how long to keep dated database dumps

: "${ENABLE_IMMICH:=1}"
: "${IMMICH_LIB:=$SRV/immich/library}"  # Immich UPLOAD_LOCATION
: "${IMMICH_DB_C:=immich_postgres}"
: "${IMMICH_DB_USER:=postgres}"
: "${IMMICH_DB_NAME:=immich}"

: "${ENABLE_NEXTCLOUD:=1}"
: "${NC_APP_C:=nextcloud-app-1}"
: "${NC_DB_C:=nextcloud-db-1}"
: "${NC_HTML:=$SRV/nextcloud/html}"

: "${APPS:=}"                           # folders under SRV holding SQLite apps, e.g. "myapp otherapp"
: "${CONFIG_FILES:=}"                   # files under SRV to keep, e.g. "immich/.env nextcloud/docker-compose.yml"
: "${CONFIG_DIRS:=}"                    # folders under SRV copied as plain files, e.g. "docker-compose"

DEST="$MNT/$DEST_NAME"
FILES="$DEST/files"
DUMPS="$DEST/db-dumps"
LOGS="$DEST/logs"
STAMP=$(date +%Y-%m-%d_%H%M)
LOG="$LOGS/backup-$STAMP.log"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; DIM=$'\e[2m'; OFF=$'\e[0m'
RESULTS=()
NC_MAINT=0
PYTMP=""
STEP_T=""
STEP_START=0
STEP_N=0

die() { echo "${RED}STOP:${OFF} $*" >&2; exit 1; }
# say: print to the screen and (once the log exists) to the log without colour codes
say() { echo "$*"; [ -d "$LOGS" ] && echo "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG"; return 0; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

step() {
  STEP_N=$((STEP_N + 1)); STEP_T=$1; STEP_START=$(date +%s)
  say ""; say "${DIM}[$STEP_N/$TOTAL]${OFF} $1"
}
finish() {   # finish OK|WARN|FAIL "message"
  local secs=$(( $(date +%s) - STEP_START )) tag
  case $1 in OK) tag="${GRN}OK${OFF}";; WARN) tag="${YEL}WARN${OFF}";; *) tag="${RED}FAIL${OFF}";; esac
  RESULTS+=("$1|$STEP_T|$2|${secs}s")
  say "   $tag  $2 (${secs}s)"
}
code_to_status() { case $1 in 0) echo OK;; 1) echo WARN;; *) echo FAIL;; esac; }

nc_off() {
  [ "$NC_MAINT" = "1" ] || return 0
  if docker exec --user www-data "$NC_APP_C" php occ maintenance:mode --off >/dev/null 2>&1; then
    NC_MAINT=0
  else
    echo "${RED}!! Nextcloud may still be in maintenance mode. Run this to fix it:${OFF}" >&2
    echo "   docker exec --user www-data $NC_APP_C php occ maintenance:mode --off" >&2
    return 1
  fi
}
cleanup() { nc_off; [ -n "$PYTMP" ] && rm -f "$PYTMP"; }
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

# ---- checks before touching anything ------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || [ "${BACKUP_TEST:-0}" = 1 ] || die "run it with sudo:   sudo bash $0"
for c in rsync docker python3 gzip; do
  command -v "$c" >/dev/null || die "'$c' is missing. For rsync:  sudo apt install -y rsync"
done
[ -n "$DRIVE_LABEL" ] || die "set DRIVE_LABEL in backup.conf to the label of your backup drive. It is a safety check so the script never writes to the wrong disk. See backup.conf.example."
mountpoint -q "$MNT" || die "$MNT is not a mounted drive. Mount your backup drive first."
SRC_DEV=$(findmnt -no SOURCE "$MNT")
GOT_LABEL=$(lsblk -no LABEL "$SRC_DEV" 2>/dev/null | head -1)
[ "$GOT_LABEL" = "$DRIVE_LABEL" ] || die "the drive at $MNT is labeled '$GOT_LABEL', expected '$DRIVE_LABEL'. Not writing to the wrong drive."
if [ "$CHECK_ONLY" = 1 ]; then
  touch "$MNT/.write-test" 2>/dev/null && rm -f "$MNT/.write-test" || die "the drive is read-only. Remount it read-write first."
else
  mkdir -p "$FILES" "$DUMPS" "$LOGS" 2>/dev/null || die "cannot write to the drive (is it mounted read-only? remount it read-write first)."
  touch "$DEST/.write-test" 2>/dev/null && rm -f "$DEST/.write-test" || die "the drive is read-only. Remount it read-write first."
fi

read -ra APP_LIST <<< "$APPS"
sources=()
[ "$ENABLE_IMMICH" = 1 ] && sources+=("$IMMICH_LIB")
[ "$ENABLE_NEXTCLOUD" = 1 ] && sources+=("$NC_HTML")
for a in "${APP_LIST[@]}"; do sources+=("$SRV/$a"); done
need=0
for p in "${sources[@]}"; do
  sz=$(du -sb "$p" 2>/dev/null | cut -f1); need=$(( need + ${sz:-0} ))
done
free=$(df -B1 --output=avail "$MNT" | tail -1 | tr -d ' ')
[ "$free" -gt $(( need * 12 / 10 + 1073741824 )) ] || die "not enough free space on the drive: about $(numfmt --to=iec "$need") to copy, $(numfmt --to=iec "$free") free."

TOTAL=1
[ "$ENABLE_IMMICH" = 1 ] && TOTAL=$((TOTAL + 2))
[ "$ENABLE_NEXTCLOUD" = 1 ] && TOTAL=$((TOTAL + 1))
[ -n "$CONFIG_FILES$CONFIG_DIRS" ] && TOTAL=$((TOTAL + 1))
TOTAL=$((TOTAL + ${#APP_LIST[@]}))

if [ "$CHECK_ONLY" = 1 ]; then
  echo "Drive: $SRC_DEV ('$GOT_LABEL'), $(df -h --output=avail "$MNT" | tail -1 | tr -d ' ') free, writable."
  echo "About $(numfmt --to=iec "$need") to copy in $TOTAL step(s)."
  problems=0
  chk() { if running "$1"; then echo "  ${GRN}running${OFF}      container $1"; else echo "  ${RED}NOT running${OFF}  container $1"; problems=1; fi; }
  [ "$ENABLE_IMMICH" = 1 ] && chk "$IMMICH_DB_C"
  [ "$ENABLE_NEXTCLOUD" = 1 ] && { chk "$NC_APP_C"; chk "$NC_DB_C"; }
  for p in "${sources[@]}"; do
    if [ -d "$p" ]; then echo "  ${GRN}found${OFF}        $p"; else echo "  ${RED}MISSING${OFF}      $p"; problems=1; fi
  done
  if [ "$problems" = 0 ]; then echo "${GRN}Check passed. Nothing was written. Run without --check to back up.${OFF}"; else echo "${RED}Check found problems (above). Nothing was written.${OFF}"; exit 1; fi
  exit 0
fi

say "Mewseum backup, $STAMP"
say "Drive: $SRC_DEV ('$GOT_LABEL'), $(df -h --output=avail "$MNT" | tail -1 | tr -d ' ') free. Sources: about $(numfmt --to=iec "$need")."
say "Backing up into: $DEST"

# helper used to copy SQLite databases safely (a plain copy of a live database can be corrupt)
PYTMP=$(mktemp)
cat > "$PYTMP" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY

# a real, readable pg_dump file?
check_dump() {
  gzip -t "$1" 2>/dev/null || return 1
  [ "$(stat -c %s "$1")" -gt 2000 ] || return 1
  local first; first=$(zcat "$1" 2>/dev/null | head -c 4000 || true)
  [[ "$first" == *"PostgreSQL database dump"* ]]
}

RSYNC_OPTS=(-rt --no-perms --no-owner --no-group --partial --human-readable --info=progress2,stats1)
SYNC_MSG=""
sync_dir() {   # sync_dir SRC/ DST/ [extra rsync args...]   -> 0 ok, 1 warn, 2 fail
  local src=$1 dst=$2; shift 2
  mkdir -p "$dst" || { SYNC_MSG="cannot create $dst"; return 2; }
  rsync "${RSYNC_OPTS[@]}" --log-file="$LOG" "$@" "$src" "$dst"
  local rc=$?
  case $rc in
    0|24) SYNC_MSG="copied"; return 0;;
    23)   SYNC_MSG="copied, but some files could not be written (see the log)"; return 1;;
    *)    SYNC_MSG="rsync failed (code $rc)"; return 2;;
  esac
}

# ---- Immich (database BEFORE the photos, per the Immich docs) --------------------------------------
if [ "$ENABLE_IMMICH" = 1 ]; then
  step "Immich database"
  f="$DUMPS/immich-$STAMP.sql.gz"
  if ! running "$IMMICH_DB_C"; then
    finish FAIL "container $IMMICH_DB_C is not running"
  elif docker exec "$IMMICH_DB_C" pg_dump --clean --if-exists --dbname="$IMMICH_DB_NAME" --username="$IMMICH_DB_USER" | gzip > "$f.part" && check_dump "$f.part"; then
    mv "$f.part" "$f"; finish OK "$(basename "$f"), $(du -h "$f" | cut -f1)"
  else
    rm -f "$f.part"; finish FAIL "the dump failed or looks empty, nothing saved"
  fi

  step "Immich photos and videos"
  sync_dir "$IMMICH_LIB/" "$FILES/immich-library/"; rc=$?
  finish "$(code_to_status $rc)" "$SYNC_MSG ($(du -sh "$FILES/immich-library" 2>/dev/null | cut -f1) on the drive)"
fi

# ---- Nextcloud (maintenance mode on while copying, off afterwards, even if something fails) -------
if [ "$ENABLE_NEXTCLOUD" = 1 ]; then
  step "Nextcloud (maintenance mode on while copying, then off)"
  if ! running "$NC_APP_C" || ! running "$NC_DB_C"; then
    finish FAIL "the Nextcloud containers are not running"
  elif ! docker exec --user www-data "$NC_APP_C" php occ maintenance:mode --on >/dev/null 2>&1; then
    finish FAIL "could not turn maintenance mode on, so Nextcloud was skipped"
  else
    NC_MAINT=1
    worst=0; msg=""
    say "   maintenance mode is ON. Dumping the database..."
    f="$DUMPS/nextcloud-$STAMP.sql.gz"
    # the password is read inside the container, so it never appears in this script or its output
    if docker exec "$NC_DB_C" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "${POSTGRES_DB:-$POSTGRES_USER}"' | gzip > "$f.part" && check_dump "$f.part"; then
      mv "$f.part" "$f"; msg="database $(du -h "$f" | cut -f1)"
    else
      rm -f "$f.part"; worst=2; msg="DATABASE DUMP FAILED"
    fi
    say "   Copying Nextcloud files..."
    sync_dir "$NC_HTML/" "$FILES/nextcloud-html/"; rc=$?
    [ "$rc" -gt "$worst" ] && worst=$rc
    msg="$msg; files: $SYNC_MSG"
    if nc_off; then
      say "   $(docker exec --user www-data "$NC_APP_C" php occ status 2>/dev/null | grep -i maintenance | sed 's/^ *//')"
    else
      worst=2; msg="$msg; COULD NOT TURN MAINTENANCE MODE OFF"
    fi
    finish "$(code_to_status $worst)" "$msg"
  fi
fi

# ---- compose files and .env (needed to rebuild the containers after a failure) ---------------------
if [ -n "$CONFIG_FILES$CONFIG_DIRS" ]; then
  step "Compose files and settings"
  CFG="$FILES/configs"; rc=0
  for rel in $CONFIG_FILES; do
    [ -f "$SRV/$rel" ] || continue
    mkdir -p "$CFG/$(dirname "$rel")"
    cp -f "$SRV/$rel" "$CFG/$rel" 2>>"$LOG" || rc=1
  done
  for d in $CONFIG_DIRS; do
    [ -d "$SRV/$d" ] || continue
    sync_dir "$SRV/$d/" "$CFG/$d/" --exclude='__pycache__' --exclude='.git'; r=$?; [ "$r" -gt "$rc" ] && rc=$r
  done
  finish "$(code_to_status $rc)" "copied (.env files hold passwords, so keep the drive somewhere safe)"
fi

# ---- SQLite apps ----------------------------------------------------------------------------------
backup_app() {   # backup_app NAME
  local name=$1 src="$SRV/$1" dst="$FILES/apps/$1" worst=0 dbs=0 db rel
  [ -d "$src" ] || { finish FAIL "$src not found"; return; }
  sync_dir "$src/" "$dst/" --exclude='*.db*' --exclude='*.sqlite*'; worst=$?
  while IFS= read -r -d '' db; do
    rel=${db#"$src"/}
    mkdir -p "$dst/$(dirname "$rel")"
    if python3 "$PYTMP" "$db" "$dst/$rel" 2>>"$LOG"; then dbs=$((dbs+1)); else worst=2; say "   ${RED}could not copy database $rel${OFF}"; fi
  done < <(find "$src" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
  finish "$(code_to_status $worst)" "files $SYNC_MSG; $dbs database(s) copied safely"
}
for a in "${APP_LIST[@]}"; do
  step "App data: $a"; backup_app "$a"
done

# ---- tidy up and summarise --------------------------------------------------------------------------
step "Tidy old database dumps"
old=$(find "$DUMPS" -type f \( -name 'immich-*.sql.gz' -o -name 'nextcloud-*.sql.gz' \) -mtime +"$KEEP_DAYS" -print -delete | wc -l)
finish OK "removed $old dump(s) older than $KEEP_DAYS days; kept the rest"

if [ ! -f "$DEST/README.txt" ]; then
cat > "$DEST/README.txt" <<EOF
Backup made by mewseum-backup.sh

files/immich-library    Immich photos and videos (a copy of UPLOAD_LOCATION)
files/nextcloud-html    Nextcloud config, data, themes and apps
files/apps/NAME         each SQLite app: its files plus a safe copy of its database
files/configs           compose files and .env files (they can contain passwords)
db-dumps                dated Immich and Nextcloud database dumps (.sql.gz)
logs                    one log per run

Notes
- If this drive is NTFS, Linux owners and permissions were NOT saved. After copying files back
  to the server they need their ownership set again.
- Files are only ever added or updated here, never deleted, so the folder keeps growing.
- Restore steps: follow the official Immich and Nextcloud restore guides with these dumps.
EOF
fi

say ""
say "================ SUMMARY ================"
bad=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r st title m t <<< "$r"
  case $st in OK) c=$GRN;; WARN) c=$YEL;; *) c=$RED; bad=1;; esac
  say "$(printf '%s%-5s%s %-48s %s' "$c" "$st" "$OFF" "$title" "$t")"
  say "        $m"
done
say ""
say "Backup folder: $DEST"
say "Log:           $LOG"
if [ "$bad" -eq 0 ]; then say "${GRN}Backup finished.${OFF}"; else say "${RED}Backup finished WITH FAILURES. Read the lines marked FAIL above.${OFF}"; fi
exit "$bad"
