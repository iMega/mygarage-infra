#!/usr/bin/env bash
# Checks the service and the host; logs every problem to the journal with
# priority err and, when ALERT_URL is set, POSTs a summary to it (ntfy.sh
# compatible). Exits non-zero when something is wrong.
set -uo pipefail

problems=()
problem() { problems+=("$*"); }

# Before the first release there is nothing to check yet.
if [[ -s $STATE_DIR/current_sha ]]; then
    curl -fsS -m 5 -o /dev/null "$CHECK_URL/readyz" || problem "readyz failed via proxy"

    sha=$(cat "$STATE_DIR/current_sha")
    curl -fsS -m 5 "$CHECK_URL/version" 2>/dev/null | grep -q "\"sha\":\"$sha\"" ||
        problem "proxy does not serve release $sha"

    active=$(cat "$STATE_DIR/active" 2>/dev/null)
    systemctl is-active --quiet "mygarage@$active" || problem "mygarage@$active is not active"
fi

systemctl is-active --quiet openresty || problem "openresty is not active"

avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
((avail >= MEM_MIN_AVAILABLE_MB)) || problem "low memory: ${avail} MB available"

read -r swap_total swap_free < <(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { print t, f }' /proc/meminfo)
if ((swap_total > 0)); then
    swap_used=$(((swap_total - swap_free) * 100 / swap_total))
    ((swap_used <= SWAP_MAX_PERCENT)) || problem "swap ${swap_used}% used"
fi

disk=$(df -P / | awk 'NR == 2 { sub("%", "", $5); print $5 }')
((disk <= DISK_MAX_PERCENT)) || problem "disk / ${disk}% used"

if [[ -n $TLS_CERT ]]; then
    if [[ ! -r $TLS_CERT ]]; then
        problem "TLS certificate missing: $TLS_CERT"
    elif ! openssl x509 -checkend $((TLS_MIN_DAYS * 86400)) -noout -in "$TLS_CERT" >/dev/null; then
        problem "TLS certificate expires within ${TLS_MIN_DAYS} days"
    fi
fi

systemctl is-failed --quiet mygarage-backup.service && problem "last backup run failed"
# Age is checked once the first backup exists, so a fresh server stays quiet
# until the first scheduled run.
if [[ -n $(find "$BACKUP_DIR" -maxdepth 1 -name 'garage-*.db.gz' 2>/dev/null | head -1) ]]; then
    latest=$(find "$BACKUP_DIR" -maxdepth 1 -name 'garage-*.db.gz' -mmin -$((26 * 60)) | head -1)
    [[ -n $latest ]] || problem "no database backup in the last 26 hours"
fi

if ((${#problems[@]} == 0)); then
    echo "ok"
    exit 0
fi

msg="myGarage $(hostname): $(printf '%s; ' "${problems[@]}")"
logger -p user.err -t mygarage-healthcheck -- "$msg"
echo "$msg" >&2
if [[ -n ${ALERT_URL:-} ]]; then
    curl -fsS -m 10 -o /dev/null --data-raw "$msg" "$ALERT_URL" || echo "alert delivery failed" >&2
fi
exit 1
