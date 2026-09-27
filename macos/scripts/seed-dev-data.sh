#!/usr/bin/env bash
# Copies the installed app's data into a checkout's development data folder (the --data-dir
# the shared scheme passes). The scheme's Run pre-action calls it, so every Debug run starts
# from what the installed app has now, and a new worktree never starts empty. Whatever the
# previous development run changed in cascade.db and data.db is replaced; logs.db is kept.
#
# A copy, never a link: the development build writes only to its own folder. sqlite3's
# .backup reads one consistent snapshot, WAL included, even while the installed app is
# writing. A development folder still open in a running copy is left alone.
#
# Output also goes to seed-dev-data.log beside the destination, since Xcode hides a
# pre-action's output.
#
# Usage: seed-dev-data.sh [destination] [source]
set -euo pipefail

DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/dev-data}"
SOURCE="${2:-$HOME/Library/Application Support/Cascade}"
DATABASES=(cascade.db data.db)

LOG="$(dirname "$DEST")/seed-dev-data.log"
mkdir -p "$(dirname "$DEST")"
# One line per run; start over once it passes 1 MB.
[[ -f "$LOG" && $(stat -f %z "$LOG") -gt 1048576 ]] && : > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[seed-dev-data] %s %s\n' "$(date '+%F %T')" "$*"; }

if [[ ! -f "$SOURCE/cascade.db" ]]; then
  log "no installed app data at $SOURCE; keeping $DEST"
  exit 0
fi
# The app holds this lock for as long as it runs. Replacing a database under it would corrupt it.
if [[ -f "$DEST/.instance.lock" ]] && lsof -t "$DEST/.instance.lock" >/dev/null 2>&1; then
  log "$DEST is open in a running copy; keeping it"
  exit 0
fi

mkdir -p "$DEST"
# Every copy is made before any file is replaced, so a failure keeps the old pair whole.
for db in "${DATABASES[@]}"; do
  rm -f "$DEST/$db.tmp"
  [[ -f "$SOURCE/$db" ]] || continue
  # macOS's sqlite3 keeps -wal and -shm files after closing; persist_wal off stops the read
  # from leaving them in the installed app's folder. -readonly cannot be used: it fails on
  # a WAL database whose -shm file is gone, which is how the app leaves one when it quits.
  if ! sqlite3 -cmd ".timeout 5000" -cmd ".filectrl persist_wal off" "$SOURCE/$db" \
      ".backup \"$DEST/$db.tmp\"" >/dev/null; then
    for tmp in "${DATABASES[@]}"; do rm -f "$DEST/$tmp.tmp"; done
    log "could not copy $db from $SOURCE; keeping $DEST"
    exit 1
  fi
done
for db in "${DATABASES[@]}"; do
  # A -wal left beside the old file would be replayed onto the new one.
  rm -f "$DEST/$db-wal" "$DEST/$db-shm"
  # A database the installed app does not have yet goes too, so the pair always matches.
  if [[ -f "$DEST/$db.tmp" ]]; then
    mv -f "$DEST/$db.tmp" "$DEST/$db"
  else
    rm -f "$DEST/$db"
  fi
done
log "copied the installed app's data into $DEST"
