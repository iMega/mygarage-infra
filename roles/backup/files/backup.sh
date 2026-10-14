#!/usr/bin/env bash
# Local backup of the database and user files, then an application-side
# snapshot that the application uploads to Google Drive (if enabled in its
# settings). Runs as the mygarage user from mygarage-backup.service.
set -euo pipefail

log() { printf '%s\n' "$*"; }

stamp=$(date +%Y%m%d-%H%M%S)
db="$DATA_DIR/garage.db"

free_mb() {
    df -Pm "$BACKUP_DIR" | awk 'NR == 2 { print $4 }'
}

# Old backups go first: by age, then oldest-first while space is short.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'garage-*' -mtime +"$KEEP_DAYS" -delete
while (($(free_mb) < MIN_FREE_MB)); do
    oldest=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'garage-*' -printf '%T@ %p\n' |
        sort -n | head -1 | cut -d' ' -f2-)
    [[ -n $oldest ]] || { log "less than ${MIN_FREE_MB} MB free and nothing to prune"; exit 1; }
    rm -f "$oldest"
    log "pruned $oldest to free space"
done

if [[ -f $db ]]; then
    out="$BACKUP_DIR/garage-$stamp.db"
    sqlite3 "$db" ".backup '$out.tmp'"
    check=$(sqlite3 "$out.tmp" 'PRAGMA integrity_check;')
    [[ $check == ok ]] || { rm -f "$out.tmp"; log "integrity check failed: $check"; exit 1; }
    gzip -9 "$out.tmp"
    mv "$out.tmp.gz" "$out.gz"
    log "database: $out.gz"
else
    log "no database yet at $db"
fi

files=()
for f in assets access config.json; do
    [[ -e $DATA_DIR/$f ]] && files+=("$f")
done
if ((${#files[@]} > 0)); then
    tar -czf "$BACKUP_DIR/garage-files-$stamp.tar.gz" -C "$DATA_DIR" "${files[@]}"
    log "files: $BACKUP_DIR/garage-files-$stamp.tar.gz"
fi

if [[ $TRIGGER_APP == 1 ]]; then
    active=$(cat "$STATE_DIR/active" 2>/dev/null || true)
    case $active in
        blue) port=$BLUE_PORT ;;
        green) port=$GREEN_PORT ;;
        *) log "no active slot, skipping application backup"; exit 0 ;;
    esac
    code=$(curl -sS -m 300 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/backup/create")
    [[ $code == 303 ]] || { log "application backup failed: HTTP $code"; exit 1; }
    log "application backup triggered on $active"
fi
