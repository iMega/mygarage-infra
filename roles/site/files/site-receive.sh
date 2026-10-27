#!/usr/bin/env bash
# Receives static site releases over SSH. Forced command of the site deploy
# keys, one key per environment (authorized_keys of the site user):
#
#   command="/opt/site/bin/site-receive.sh <env>",restrict <key>
#
# The client chooses only the action, the key fixes the environment:
#
#   ssh site@<host> deploy <sha> < site.tar.gz
#   ssh site@<host> rollback [<sha>]
#   ssh site@<host> status
#
# deploy unpacks the archive into a new release directory and atomically
# repoints $SITE_ROOT/<env> at it; the previous release serves until then.
# rollback repoints it at a kept release: the one before the served one, or
# the newest of <sha>.
set -euo pipefail
umask 022

# shellcheck source=/dev/null
source /etc/site-deploy.env

readonly RELEASES_DIR="$SITE_ROOT/releases"
readonly ENVS="production test"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
    logger -t site-deploy -- "$*" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    echo "usage: deploy <40-char sha> < site.tar.gz | rollback [<40-char sha>] | status" >&2
    exit 2
}

current_release() {
    basename "$(readlink "$SITE_ROOT/$site_env")"
}

# releases: kept releases of the environment, newest first.
releases() {
    find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -name "$site_env-*" -printf '%f\n' | sort -r
}

lock() {
    exec 9>"$SITE_ROOT/.$site_env.lock"
    flock -w 300 9 || die "another $site_env deploy is still running"
}

# point <release>: atomically repoints the environment at the release.
point() {
    ln -sfn "releases/$1" "$SITE_ROOT/.$site_env.tmp"
    mv -Tf "$SITE_ROOT/.$site_env.tmp" "$SITE_ROOT/$site_env"
}

# prune: keeps the newest $RELEASES_KEEP releases of the environment and the
# one it serves.
prune() {
    local current dir n=0
    current=$(current_release)
    while IFS= read -r dir; do
        n=$((n + 1))
        ((n <= RELEASES_KEEP)) && continue
        [[ $dir == "$current" ]] && continue
        rm -rf "${RELEASES_DIR:?}/$dir"
        log "$site_env: pruned $dir"
    done < <(releases)
}

deploy() {
    local sha=$1
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || usage

    lock

    local name tmp max_upload=$((MAX_UPLOAD_MB * 1024 * 1024)) max_unpacked=$((MAX_UNPACKED_MB * 1024 * 1024))
    name="$site_env-$(date -u +%Y%m%d%H%M%S)-${sha:0:12}"
    tmp="$RELEASES_DIR/.$name.tmp"
    # shellcheck disable=SC2064  # paths are fixed now
    trap "rm -rf '$tmp' '$tmp.tgz'" EXIT
    mkdir "$tmp"

    head -c $((max_upload + 1)) >"$tmp.tgz"
    (($(stat -c %s "$tmp.tgz") <= max_upload)) || die "archive is larger than ${MAX_UPLOAD_MB} MB"

    # The cut-off stream fails the pipeline, so an archive that unpacks to
    # more than the limit never fills the disk.
    gzip -dc "$tmp.tgz" | head -c $((max_unpacked + 1)) |
        tar -x -C "$tmp" --no-same-owner --no-same-permissions ||
        die "not a .tar.gz archive or it unpacks to more than ${MAX_UNPACKED_MB} MB"

    # Links could expose files outside the release to the proxy.
    local other
    other=$(find "$tmp" ! -type f ! -type d -printf '%P\n' | head -5)
    [[ -z $other ]] || die "archive may hold only files and directories, found: ${other//$'\n'/, }"
    [[ -f $tmp/index.html ]] || die "no index.html at the archive root"
    chmod -R u=rwX,go=rX "$tmp"

    mv -T "$tmp" "$RELEASES_DIR/$name"
    point "$name"
    log "$site_env: published $sha as $name"

    prune
}

rollback() {
    local sha=$1 current target
    [[ -z $sha || $sha =~ ^[0-9a-f]{40}$ ]] || usage
    lock

    current=$(current_release)
    if [[ -n $sha ]]; then
        target=$(releases | grep -m1 -e "-${sha:0:12}\$" || true)
        [[ -n $target ]] || die "release $sha is not kept on the server"
    else
        target=$(releases | awk -v c="$current" '$0 < c' | head -1)
        [[ -n $target ]] || die "no release before $current"
    fi
    [[ $target != "$current" ]] || die "$target is already served"

    point "$target"
    log "$site_env: rolled back from $current to $target"
}

status() {
    local current dir
    current=$(current_release)
    echo "$site_env: $current"
    while IFS= read -r dir; do
        if [[ $dir == "$current" ]]; then echo "* $dir"; else echo "  $dir"; fi
    done < <(releases)
}

main() {
    site_env=${1:-}
    [[ " $ENVS " == *" $site_env "* ]] || die "unknown environment: '$site_env'"

    local action arg extra
    read -r action arg extra <<<"${SSH_ORIGINAL_COMMAND:-}"
    [[ -z $extra ]] || usage

    case $action in
        deploy) deploy "$arg" ;;
        rollback) rollback "$arg" ;;
        status)
            [[ -z $arg ]] || usage
            status
            ;;
        *) usage ;;
    esac
}

main "$@"
