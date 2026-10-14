#!/usr/bin/env bash
# Replaces the live database with a backup and restarts the active slot.
# Brief downtime is expected. The replaced database is kept next to it.
#
#   restore.sh /var/backups/mygarage/garage-YYYYmmdd-HHMMSS.db.gz
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

[[ $# -eq 1 ]] || { echo "usage: $0 <backup.db[.gz]>" >&2; exit 2; }
require_root
acquire_lock

src=$1
[[ -f $src ]] || die "backup not found: $src"

db="$DATA_DIR/garage.db"
tmp="$DATA_DIR/.garage.db.restore"
rm -f "$tmp"
if [[ $src == *.gz ]]; then
    gzip -dc "$src" >"$tmp"
else
    cp "$src" "$tmp"
fi

check=$(sqlite3 "$tmp" 'PRAGMA integrity_check;')
[[ $check == ok ]] || { rm -f "$tmp"; die "backup failed integrity check: $check"; }

active=$(state_get active)
sha=$(state_get current_sha)

log "stopping slots"
systemctl stop mygarage@blue mygarage@green

stamp=$(date +%Y%m%d-%H%M%S)
if [[ -f $db ]]; then
    sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null || true
    mv "$db" "$db.before-restore-$stamp"
    log "previous database saved as $db.before-restore-$stamp"
fi
rm -f "$db-wal" "$db-shm"
chown mygarage:mygarage "$tmp"
chmod 0640 "$tmp"
mv "$tmp" "$db"
log "database restored from $src"

if [[ -n $active && -n $sha ]]; then
    systemctl start "mygarage@$active"
    wait_ready "$(port_of "$active")" "$sha" || die "mygarage@$active did not become ready"
    log "mygarage@$active is serving the restored database"
else
    log "no release deployed: start the application with deploy.sh"
fi
