#!/usr/bin/env bash
# Static site scenarios against the container prepared by test/run.sh.
# Uploads the way the website CI does: a .tar.gz on stdin of
# `ssh site@<host> deploy <sha>`, with the per-environment keys.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly NAME=mygarage-test
readonly STATE=test/.state
readonly WORK=$STATE/site
readonly PROXY=http://127.0.0.1:18080
readonly AUTH=test:testtest
readonly APP_AUTH=garage:garage

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
in_box() { docker exec "$NAME" bash -c "$1"; }

# page <host> [curl args]: body served for the host.
page() {
    local host=$1
    shift
    curl -fsS -H "Host: $host" "$@" "$PROXY/"
}

# ssh_site <env> <command>: runs <command> with the key of <env>, stdin
# passed through.
ssh_site() {
    docker exec -i "$NAME" ssh -i "/root/site-$1" -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error \
        site@127.0.0.1 "$2"
}

# release <dir> <text>: a site whose index.html holds <text>.
release() {
    rm -rf "$1" && mkdir -p "$1/css"
    printf '<!doctype html><p>%s</p>\n' "$2" >"$1/index.html"
    printf 'p { color: red }\n' >"$1/css/site.css"
}

sha() { printf "$1%.0s" {1..40}; }

# pack <dir>: the archive CI uploads (no macOS extended attributes).
pack() { tar --no-xattrs -czf - -C "$1" .; }

ansible_site() {
    ansible-playbook -i test/inventory/test.yml playbooks/site.yml --tags site >"$WORK/ansible.log" 2>&1 ||
        fail "ansible: $(tail -20 "$WORK/ansible.log")"
}

rm -rf "$WORK" && mkdir -p "$WORK"
# Start from a server that has never received an upload.
in_box 'rm -rf /var/www/site/production /var/www/site/test /var/www/site/releases/*-*'
ansible_site
in_box 'command -v ssh >/dev/null || dnf -q -y install openssh-clients >/dev/null'
for env in production test; do
    docker cp "$STATE/site-$env" "$NAME:/root/site-$env"
    in_box "chmod 600 /root/site-$env"
done

echo "== 1. seed release"
page site.test | grep -q 'Coming soon' || fail "production does not serve the seed"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: test.site.test' "$PROXY/")
[[ $code == 401 ]] || fail "test without credentials returned $code"
page test.site.test -u "$AUTH" | grep -q 'Coming soon' || fail "test does not serve the seed"
curl -fsS -o /dev/null -D - -u "$AUTH" -H 'Host: test.site.test' "$PROXY/" | grep -qi '^x-robots-tag: noindex' ||
    fail "test is indexable"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$APP_AUTH" -H 'Host: test.site.test' "$PROXY/")
[[ $code == 401 ]] || fail "test accepted the application login ($code)"
pass "seed on both environments, test behind its own basic auth and noindex"

echo "== 2. pull request to test"
release "$WORK/pr" "pull request"
pack "$WORK/pr" | ssh_site test "deploy $(sha a)" >/dev/null
page test.site.test -u "$AUTH" | grep -q 'pull request' || fail "test does not serve the upload"
curl -fsS -u "$AUTH" -H 'Host: test.site.test' "$PROXY/css/site.css" | grep -q red || fail "no nested file"
page site.test | grep -q 'Coming soon' || fail "test upload reached production"
[[ $(ssh_site test status | head -1) == "test: test-"*"-aaaaaaaaaaaa" ]] || fail "status: $(ssh_site test status)"
pass "test serves the pull request, production untouched"

echo "== 3. keys are pinned to their environment"
ssh_site test 'cat /etc/passwd' >/dev/null 2>&1 && fail "arbitrary command accepted"
[[ $(ssh_site test status) == test:* ]] || fail "test key reached another environment"
pass "test key runs only the receiver for test"

echo "== 4. release to production"
release "$WORK/main" "main branch"
pack "$WORK/main" | ssh_site production "deploy $(sha b)" >/dev/null
page site.test | grep -q 'main branch' || fail "production does not serve the upload"
page test.site.test -u "$AUTH" | grep -q 'pull request' || fail "production upload reached test"
pass "production serves main, test keeps the pull request"

echo "== 5. rollback without rebuild"
ssh_site production rollback </dev/null >/dev/null 2>&1 && fail "rollback past the first release accepted"
sleep 1
release "$WORK/main2" "second main"
pack "$WORK/main2" | ssh_site production "deploy $(sha 2)" >/dev/null
page site.test | grep -q 'second main' || fail "production does not serve the second release"
ssh_site production rollback </dev/null >/dev/null
page site.test | grep -q 'main branch' || fail "rollback did not restore the first release"
ssh_site production "rollback $(sha 2)" </dev/null >/dev/null
page site.test | grep -q 'second main' || fail "rollback by sha did not restore the second release"
ssh_site production "rollback $(sha 9)" </dev/null >/dev/null 2>&1 && fail "rollback to an unknown sha accepted"
pass "rollback to the previous release and by sha"

echo "== 6. bad archives are rejected, the served release stays"
reject() {
    local what=$1 out
    if out=$(ssh_site test "deploy $(sha c)" 2>&1); then
        fail "$what accepted"
    fi
    page test.site.test -u "$AUTH" | grep -q 'pull request' || fail "$what replaced the served release"
    in_box 'ls -A /var/www/site/releases' | grep -q '\.tmp' && fail "$what left a temporary directory"
    echo "   $what: ${out##*ERROR: }"
}
release "$WORK/link" "link"
ln -s /usr/local/openresty/nginx/conf/mygarage.htpasswd "$WORK/link/secret.txt"
pack "$WORK/link" | reject "symlink"
release "$WORK/noindex" "no index" && rm "$WORK/noindex/index.html"
pack "$WORK/noindex" | reject "missing index.html"
printf 'not an archive' | reject "garbage"
in_box "sed -i 's/^MAX_UNPACKED_MB=.*/MAX_UNPACKED_MB=1/' /etc/site-deploy.env"
release "$WORK/big" "big" && head -c $((2 * 1024 * 1024)) /dev/zero >"$WORK/big/zeros.bin"
pack "$WORK/big" | reject "archive unpacking over the limit"
in_box "sed -i 's/^MAX_UNPACKED_MB=.*/MAX_UNPACKED_MB=200/' /etc/site-deploy.env"
ssh_site test "deploy ../../etc" </dev/null >/dev/null 2>&1 && fail "path accepted as sha"
pass "symlink, missing index.html, garbage, oversize and bad sha rejected"

echo "== 7. old releases are pruned"
for c in d e f 1; do
    release "$WORK/pr" "pull request $c"
    pack "$WORK/pr" | ssh_site test "deploy $(sha "$c")" >/dev/null
    sleep 1
done
count=$(in_box 'find /var/www/site/releases -mindepth 1 -maxdepth 1 -name "test-*" | wc -l')
[[ $count == 3 ]] || fail "$count test releases kept"
in_box 'test -d /var/www/site/releases/seed' || fail "seed release pruned"
page test.site.test -u "$AUTH" | grep -q 'pull request 1' || fail "test does not serve the newest upload"
pass "3 test releases kept, seed kept"

echo "== 8. Ansible keeps the served releases"
ansible_site
page site.test | grep -q 'second main' || fail "Ansible reset production"
page test.site.test -u "$AUTH" | grep -q 'pull request 1' || fail "Ansible reset test"
pass "provision leaves runtime state alone"
