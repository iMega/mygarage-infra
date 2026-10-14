#!/usr/bin/env bash
# Prints the release state: active slot, release SHAs, slot health.
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

echo "active slot:   $(state_get active)"
echo "current sha:   $(state_get current_sha)"
echo "previous sha:  $(state_get previous_sha)"
echo "upstream:      $(cat "$UPSTREAM_FILE" 2>/dev/null)"
echo "mem available: $(mem_available_mb) MB"
echo

for slot in blue green; do
    port=$(port_of "$slot")
    state=$(systemctl is-active "mygarage@$slot" 2>/dev/null || true)
    ready=$(curl -fsS -m 3 "http://127.0.0.1:$port/readyz" 2>/dev/null || echo "-")
    printf '%-6s :%s  %-9s ready=%-6s release=%s\n' \
        "$slot" "$port" "$state" "$ready" "$(slot_release "$slot")"
done

echo
echo "releases:"
find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '  %TF %TH:%TM  %f\n' | sort -r
