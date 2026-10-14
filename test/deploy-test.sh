#!/usr/bin/env bash
# Release scenarios against the container prepared by test/run.sh.
# Builds the application from ../mygarage for the container architecture
# under two fake SHAs and drives deploy.sh the way CI does: upload into
# /opt/mygarage/incoming as the deploy user, then sudo deploy.sh <sha>.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly NAME=mygarage-test
readonly SRC=${MYGARAGE_SRC:-../mygarage}
readonly WORK=test/.state/releases
readonly PROXY=http://127.0.0.1:18080
readonly AUTH=garage:garage

arch=$(docker exec "$NAME" uname -m)
case $arch in
    x86_64) goarch=amd64 ;;
    aarch64) goarch=arm64 ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
esac

sha_a=$(printf 'a%.0s' {1..40})
sha_b=$(printf 'b%.0s' {1..40})
sha_bad=$(printf 'c%.0s' {1..40})

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
in_box() { docker exec "$NAME" bash -c "$1"; }
as_deploy() {
    local script=$1
    shift
    docker exec -u deploy "$NAME" sudo "/opt/mygarage/bin/$script" "$@"
}
proxy_sha() { curl -fsS -u "$AUTH" "$PROXY/version" | sed -E 's/.*"sha":"([^"]+)".*/\1/'; }

build() {
    local sha=$1 dir="$WORK/$1"
    mkdir -p "$dir"
    (cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=$goarch go build -trimpath \
        -ldflags "-s -w -X github.com/imega/mygarage/version.SHA=$sha" \
        -o "$OLDPWD/$dir/mygarage-linux-$goarch" ./cmd/main.go)
    (cd "$dir" && shasum -a 256 "mygarage-linux-$goarch" >"mygarage-linux-$goarch.sha256")
}

upload() {
    local sha=$1
    docker cp "$WORK/$sha" "$NAME:/opt/mygarage/incoming/$sha"
    in_box "chown -R deploy:deploy /opt/mygarage/incoming/$sha"
}

# Requests through the proxy in the background; prints non-200 count.
traffic_start() {
    : >"$WORK/traffic.log"
    (while :; do
        curl -s -o /dev/null -w '%{http_code}\n' -u "$AUTH" "$PROXY/healthz" >>"$WORK/traffic.log"
    done) &
    traffic_pid=$!
}
traffic_stop() {
    { kill "$traffic_pid" && wait "$traffic_pid"; } 2>/dev/null || true
    local total bad
    total=$(wc -l <"$WORK/traffic.log" | tr -d ' ')
    bad=$(grep -vc '^200$' "$WORK/traffic.log" || true)
    echo "$total $bad"
}

rm -rf "$WORK" && mkdir -p "$WORK"
build "$sha_a"
build "$sha_b"
mkdir -p "$WORK/$sha_bad"
# A binary that exits at once: passes the checksum, never becomes ready.
printf '#!/bin/sh\nexit 1\n' >"$WORK/$sha_bad/mygarage-linux-$goarch"
chmod +x "$WORK/$sha_bad/mygarage-linux-$goarch"
(cd "$WORK/$sha_bad" && shasum -a 256 "mygarage-linux-$goarch" >"mygarage-linux-$goarch.sha256")

echo "== 1. first release"
upload "$sha_a"
as_deploy deploy.sh "$sha_a"
[[ $(proxy_sha) == "$sha_a" ]] || fail "proxy does not serve A"
[[ $(in_box 'cat /var/lib/mygarage-deploy/active') == blue ]] || fail "A is not on blue"
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/")
[[ $code == 401 ]] || fail "proxy without credentials returned $code"
pass "A on blue, basic auth enforced"

echo "== 2. second release under load"
upload "$sha_b"
traffic_start
as_deploy deploy.sh "$sha_b"
read -r total bad < <(traffic_stop)
[[ $(proxy_sha) == "$sha_b" ]] || fail "proxy does not serve B"
[[ $(in_box 'cat /var/lib/mygarage-deploy/active') == green ]] || fail "B is not on green"
in_box 'systemctl is-active --quiet mygarage@blue' && fail "old slot still running"
((total > 50 && bad == 0)) || fail "requests during switch: $total total, $bad failed"
pass "B on green, $total requests during switch, $bad failed, blue stopped"

echo "== 3. rollback without rebuild"
traffic_start
as_deploy rollback.sh
read -r total bad < <(traffic_stop)
[[ $(proxy_sha) == "$sha_a" ]] || fail "rollback did not restore A"
((bad == 0)) || fail "requests during rollback: $bad of $total failed"
pass "rolled back to A on $(in_box 'cat /var/lib/mygarage-deploy/active'), $total requests, $bad failed"

echo "== 4. release that never becomes ready"
upload "$sha_bad"
sed_ready='s/^READY_TIMEOUT=.*/READY_TIMEOUT=8/'
in_box "sed -i '$sed_ready' /etc/mygarage/deploy.env"
if as_deploy deploy.sh "$sha_bad" >"$WORK/bad.log" 2>&1; then
    fail "broken release was deployed"
fi
in_box "sed -i 's/^READY_TIMEOUT=.*/READY_TIMEOUT=60/' /etc/mygarage/deploy.env"
grep -q 'did not become ready' "$WORK/bad.log" || fail "unexpected failure: $(tail -3 "$WORK/bad.log")"
[[ $(proxy_sha) == "$sha_a" ]] || fail "traffic left A after failed deploy"
[[ $(in_box 'cat /var/lib/mygarage-deploy/current_sha') == "$sha_a" ]] || fail "state changed"
# shellcheck disable=SC2016  # expanded inside the container
[[ $(in_box 'basename "$(readlink /opt/mygarage/slots/green)"') == "$sha_b" ]] ||
    fail "idle slot not restored to B"
pass "broken release rejected, A keeps serving, idle slot back on B"

echo "== 5. process crash"
active=$(in_box 'cat /var/lib/mygarage-deploy/active')
in_box "systemctl kill -s SIGKILL mygarage@$active"
for _ in $(seq 1 15); do
    sleep 1
    [[ $(proxy_sha 2>/dev/null || true) == "$sha_a" ]] && break
done
[[ $(proxy_sha) == "$sha_a" ]] || fail "service did not recover after SIGKILL"
pass "systemd restarted mygarage@$active after SIGKILL"

echo "== 6. concurrent deploys are serialised"
as_deploy deploy.sh "$sha_b" >"$WORK/c1.log" 2>&1 &
p1=$!
sleep 1
as_deploy deploy.sh "$sha_b" >"$WORK/c2.log" 2>&1 &
p2=$!
wait $p1 || fail "first concurrent deploy failed"
wait $p2 || fail "second concurrent deploy failed"
first_end=$(grep -n 'deployed bbbb' "$WORK/c1.log" | head -1)
[[ -n $first_end ]] || fail "first deploy log incomplete"
# The second run starts only after the first one finished.
[[ $(grep -c 'deploying' "$WORK/c2.log") == 1 ]] || fail "second deploy log unexpected"
[[ $(proxy_sha) == "$sha_b" ]] || fail "proxy does not serve B after concurrent deploys"
pass "second deploy waited for the lock"

echo "== 7. bad arguments"
as_deploy deploy.sh '../../etc' >/dev/null 2>&1 && fail "path accepted as sha"
as_deploy deploy.sh "$(printf 'd%.0s' {1..40})" >/dev/null 2>&1 && fail "missing release accepted"
pass "invalid and unknown SHAs rejected"

echo "== 8. backup and restore"
curl -fsS -u "$AUTH" -o /dev/null -X POST "$PROXY/work-types" -d 'category=T&name=before-backup&default_price=1'
in_box 'systemctl start mygarage-backup.service'
backup=$(in_box 'ls -1t /var/backups/mygarage/garage-*.db.gz | head -1')
[[ -n $backup ]] || fail "no backup file"
curl -fsS -u "$AUTH" -o /dev/null -X POST "$PROXY/work-types" -d 'category=T&name=after-backup&default_price=1'
in_box "/opt/mygarage/bin/restore.sh $backup" >/dev/null
names=$(in_box "sqlite3 /var/lib/mygarage/garage.db \"select group_concat(name) from work_types where category='T'\"")
[[ $names == before-backup ]] || fail "restored data: $names"
[[ $(proxy_sha) == "$sha_b" ]] || fail "service not back after restore"
pass "backup restored ($backup)"

echo "== 9. health check"
in_box 'systemctl start mygarage-healthcheck.service' || fail "healthcheck: $(in_box 'journalctl -u mygarage-healthcheck -n 5 --no-pager')"
pass "healthcheck ok"

echo "== 10. unit change from Ansible restarts through blue/green"
before=$(in_box 'cat /var/lib/mygarage-deploy/active')
traffic_start
ansible-playbook -i test/inventory/test.yml playbooks/site.yml --tags app \
    -e mygarage_memory_max=300M >"$WORK/ansible.log" 2>&1 || fail "ansible: $(tail -20 "$WORK/ansible.log")"
read -r total bad < <(traffic_stop)
after=$(in_box 'cat /var/lib/mygarage-deploy/active')
in_box 'systemctl show -p MemoryMax mygarage@'"$after" | grep -q '=314572800' || fail "new unit not applied"
[[ $before != "$after" && $(proxy_sha) == "$sha_b" ]] || fail "no blue/green restart ($before -> $after)"
((bad == 0)) || fail "requests during restart: $bad of $total failed"
ansible-playbook -i test/inventory/test.yml playbooks/site.yml --tags app >/dev/null 2>&1 || fail "ansible revert"
pass "unit change applied via $before -> $after, $total requests, $bad failed"

in_box '/opt/mygarage/bin/status.sh'
