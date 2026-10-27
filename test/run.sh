#!/usr/bin/env bash
# Converges a local AlmaLinux 9 container with the production playbooks.
#
#   test/run.sh            fresh container: bootstrap + site + idempotency check
#   test/run.sh --keep     reuse the running container, run site only
#
# Needs Docker and ansible-playbook in PATH. Proxy: http://127.0.0.1:18080
# (basic auth garage/garage; test site test/testtest).
set -euo pipefail

cd "$(dirname "$0")/.."
readonly NAME=mygarage-test
readonly IMAGE=almalinux/9-init:9.6
readonly STATE=test/.state
readonly INVENTORY=test/inventory/test.yml

# Nothing in the test bench is encrypted; the variable only satisfies
# scripts/vault-pass.sh.
export ANSIBLE_VAULT_PASSWORD=${ANSIBLE_VAULT_PASSWORD:-unused}

mkdir -p "$STATE"
for key in admin deploy site-production site-test; do
    [[ -f $STATE/$key ]] || ssh-keygen -q -t ed25519 -N '' -C "mygarage-test-$key" -f "$STATE/$key"
done
[[ -f $STATE/htpasswd-hash ]] || openssl passwd -apr1 garage >"$STATE/htpasswd-hash"
[[ -f $STATE/site-test-htpasswd-hash ]] || openssl passwd -apr1 testtest >"$STATE/site-test-htpasswd-hash"

ansible-galaxy collection install -r requirements.yml -p .collections >/dev/null

if [[ ${1:-} != --keep ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" --hostname "$NAME" \
        --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -p 127.0.0.1:18080:80 "$IMAGE" >/dev/null
    until docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do
        sleep 1
    done

    ansible-playbook -i "$INVENTORY" playbooks/bootstrap.yml -e ansible_user=root
fi

ansible-playbook -i "$INVENTORY" playbooks/site.yml

echo "== idempotency"
out=$(ansible-playbook -i "$INVENTORY" playbooks/site.yml)
echo "$out" | tail -4
if ! echo "$out" | grep -qE "$NAME +: ok=[0-9]+ +changed=0 "; then
    echo "second run reported changes" >&2
    exit 1
fi
