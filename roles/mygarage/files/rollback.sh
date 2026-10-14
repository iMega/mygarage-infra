#!/usr/bin/env bash
# Returns traffic to the previous release (or to <sha>) without rebuilding:
# the binary is still in the releases directory.
#
#   rollback.sh [sha]
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

require_root

sha=${1:-$(state_get previous_sha)}
[[ -n $sha ]] || die "no previous release recorded"
valid_sha "$sha" || die "invalid sha: $sha"
[[ -x $RELEASES_DIR/$sha/mygarage ]] || die "release $sha is not installed"

log "rolling back to $sha"
exec "$APP_DIR/bin/deploy.sh" "$sha"
