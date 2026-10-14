#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# Shared helpers for deploy.sh, rollback.sh, status.sh and restore.sh.
# Sourced, not executed.

# shellcheck source=/dev/null
source /etc/mygarage/deploy.env

readonly RELEASES_DIR="$APP_DIR/releases"
readonly SLOTS_DIR="$APP_DIR/slots"
readonly INCOMING_DIR="$APP_DIR/incoming"
readonly LOCK_FILE=/run/lock/mygarage-deploy.lock
readonly UPSTREAM_FILE="$STATE_DIR/upstream.conf"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
    logger -t mygarage-deploy -- "$*" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || die "must run as root (use sudo)"
}

# Serialises every operation that touches slots or the upstream. Waits so
# that an Ansible-triggered restart queues behind a running deploy.
acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -w 600 9 || die "another deploy is still running"
}

valid_sha() {
    [[ $1 =~ ^[0-9a-f]{40}$ ]]
}

state_get() {
    cat "$STATE_DIR/$1" 2>/dev/null || true
}

# Writes a state file atomically.
state_set() {
    printf '%s\n' "$2" >"$STATE_DIR/.$1.tmp"
    mv -f "$STATE_DIR/.$1.tmp" "$STATE_DIR/$1"
}

port_of() {
    case $1 in
        blue) echo "$BLUE_PORT" ;;
        green) echo "$GREEN_PORT" ;;
        *) die "unknown slot: $1" ;;
    esac
}

other_slot() {
    if [[ $1 == blue ]]; then echo green; else echo blue; fi
}

# Release SHA a slot symlink points to, empty when unset.
slot_release() {
    local link="$SLOTS_DIR/$1"
    if [[ -L $link ]]; then
        basename "$(readlink "$link")"
    fi
}

mem_available_mb() {
    awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo
}

# version_is <url> <sha>: the endpoint answers /version with that SHA.
version_is() {
    curl -fsS -m 3 "$1/version" 2>/dev/null | grep -q "\"sha\":\"$2\""
}

# wait_ready <port> <sha>: polls the slot until it is ready and runs <sha>.
wait_ready() {
    local url="http://127.0.0.1:$1" deadline=$((SECONDS + READY_TIMEOUT))
    while ((SECONDS < deadline)); do
        if curl -fsS -m 3 "$url/readyz" >/dev/null 2>&1 && version_is "$url" "$2"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# set_upstream <port>: points the proxy at a slot, validates the
# configuration and reloads gracefully; old workers finish their requests.
set_upstream() {
    local tmp="$STATE_DIR/.upstream.conf.tmp"
    printf 'server 127.0.0.1:%s;\n' "$1" >"$tmp"
    cp -f "$UPSTREAM_FILE" "$STATE_DIR/upstream.conf.prev"
    mv -f "$tmp" "$UPSTREAM_FILE"

    if ! "$OPENRESTY_BIN" -t -q; then
        mv -f "$STATE_DIR/upstream.conf.prev" "$UPSTREAM_FILE"
        "$OPENRESTY_BIN" -t -q || log "WARNING: restored upstream is invalid too"
        return 1
    fi
    systemctl reload openresty
}

# restore_upstream: reverts the last set_upstream.
restore_upstream() {
    [[ -f $STATE_DIR/upstream.conf.prev ]] || return 1
    mv -f "$STATE_DIR/upstream.conf.prev" "$UPSTREAM_FILE"
    "$OPENRESTY_BIN" -t -q && systemctl reload openresty
}
