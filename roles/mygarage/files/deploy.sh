#!/usr/bin/env bash
# Blue/green release of myGarage.
#
#   deploy.sh <sha>      release <sha> into the idle slot and switch traffic
#   deploy.sh --restart  redeploy the current release (applies unit/env changes)
#
# The binary comes from $APP_DIR/incoming/<sha>/ (uploaded by CI together
# with its .sha256) or from $APP_DIR/releases/<sha>/ when it was released
# before, which makes rollbacks independent of CI.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

usage() {
    echo "usage: $0 <40-char sha> | --restart" >&2
    exit 2
}

# install_release <sha>: moves an uploaded, checksum-verified binary into
# the immutable releases directory.
install_release() {
    local sha=$1 dest="$RELEASES_DIR/$1" src="$INCOMING_DIR/$1"

    if [[ -x $dest/mygarage ]]; then
        log "release $sha already installed"
        return 0
    fi
    [[ -d $src && ! -L $src ]] || die "release $sha not found in $src"

    local bin="" f
    for f in "$src"/mygarage-linux-*; do
        [[ $f == *.sha256 ]] && continue
        [[ -z $bin ]] || die "several binaries in $src"
        bin=$f
    done
    [[ -n $bin && -f $bin && ! -L $bin ]] || die "no binary in $src"
    [[ -f $bin.sha256 && ! -L $bin.sha256 ]] || die "no checksum for $bin"

    (cd "$src" && sha256sum --quiet -c "$(basename "$bin").sha256") ||
        die "checksum mismatch for $bin"

    local tmp="$RELEASES_DIR/.$sha.tmp"
    rm -rf "$tmp"
    install -d -o root -g root -m 0755 "$tmp"
    install -o root -g root -m 0755 "$bin" "$tmp/mygarage"
    install -o root -g root -m 0644 "$bin.sha256" "$tmp/mygarage.sha256"
    mv -T "$tmp" "$dest"
    rm -rf "$src"
    log "release $sha installed"
}

# point_slot <slot> <sha>: atomically repoints the slot symlink.
point_slot() {
    ln -sfn "$RELEASES_DIR/$2" "$SLOTS_DIR/.$1.tmp"
    mv -Tf "$SLOTS_DIR/.$1.tmp" "$SLOTS_DIR/$1"
}

# prune_releases: keeps the newest $RELEASES_KEEP releases plus anything a
# slot or the rollback state still references.
prune_releases() {
    local keep=() dir sha
    keep+=("$(slot_release blue)" "$(slot_release green)")
    keep+=("$(state_get current_sha)" "$(state_get previous_sha)")

    local n=0
    while IFS= read -r dir; do
        sha=$(basename "$dir")
        n=$((n + 1))
        ((n <= RELEASES_KEEP)) && continue
        [[ " ${keep[*]} " == *" $sha "* ]] && continue
        rm -rf "$dir"
        log "pruned release $sha"
    done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %p\n' |
        sort -rn | cut -d' ' -f2-)
}

# abort <slot> <switched> <previous release> <reason>: returns traffic and
# the slot symlink to where they were, so the idle slot stays usable for a
# rollback.
abort() {
    local target=$1 switched=$2 prev=$3 reason=$4
    if [[ $switched == yes ]]; then
        log "restoring previous upstream"
        restore_upstream || log "WARNING: failed to restore upstream"
    fi
    log "last log lines of mygarage@$target:"
    journalctl -u "mygarage@$target" -n 30 --no-pager 2>/dev/null || true
    systemctl stop "mygarage@$target" || true
    systemctl reset-failed "mygarage@$target" 2>/dev/null || true
    if [[ -n $prev ]]; then
        point_slot "$target" "$prev"
    else
        rm -f "$SLOTS_DIR/$target"
    fi
    die "$reason"
}

main() {
    [[ $# -eq 1 ]] || usage
    require_root
    acquire_lock

    local sha=$1
    if [[ $sha == --restart ]]; then
        sha=$(state_get current_sha)
        if [[ -z $sha ]]; then
            log "no release deployed, nothing to restart"
            exit 0
        fi
    fi
    valid_sha "$sha" || usage

    install_release "$sha"

    local active target
    active=$(state_get active)
    if [[ $active == blue || $active == green ]]; then
        target=$(other_slot "$active")
    else
        active=""
        target=blue
    fi
    local port
    port=$(port_of "$target")
    log "deploying $sha: ${active:-none} -> $target (:$port)"

    # The idle slot may still run the previous release from a rollback
    # window; stop it before measuring memory.
    systemctl stop "mygarage@$target" 2>/dev/null || true

    local avail
    avail=$(mem_available_mb)
    if ((avail < MIN_MEM_AVAILABLE_MB)); then
        die "only ${avail} MB available, need ${MIN_MEM_AVAILABLE_MB} MB: deploy stopped"
    fi

    local prev_release
    prev_release=$(slot_release "$target")
    point_slot "$target" "$sha"
    systemctl reset-failed "mygarage@$target" 2>/dev/null || true
    systemctl start "mygarage@$target"

    wait_ready "$port" "$sha" ||
        abort "$target" no "$prev_release" "mygarage@$target did not become ready in ${READY_TIMEOUT}s"
    log "mygarage@$target is ready"

    set_upstream "$port" || abort "$target" no "$prev_release" "proxy configuration rejected"
    log "traffic switched to $target"

    local ok=no
    for _ in $(seq 1 10); do
        if version_is "$CHECK_URL" "$sha"; then
            ok=yes
            break
        fi
        sleep 1
    done
    [[ $ok == yes ]] || abort "$target" yes "$prev_release" "smoke test through the proxy failed"
    log "smoke test passed"

    local current
    current=$(state_get current_sha)
    if [[ -n $current && $current != "$sha" ]]; then
        state_set previous_sha "$current"
    fi
    state_set current_sha "$sha"
    state_set active "$target"
    rm -f "$STATE_DIR/upstream.conf.prev"

    systemctl enable --quiet "mygarage@$target"
    if [[ -n $active ]]; then
        systemctl disable --quiet "mygarage@$active" || true
        log "draining mygarage@$active for ${DRAIN_SECONDS}s"
        sleep "$DRAIN_SECONDS"
        systemctl stop "mygarage@$active" || log "WARNING: failed to stop mygarage@$active"
    fi

    prune_releases
    log "deployed $sha on $target"
}

main "$@"
