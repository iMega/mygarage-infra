#!/usr/bin/env bash
# Creates inventory/group_vars/all/vault.yml: asks for the application
# logins and passwords and the alert URL, hashes the passwords (bcrypt),
# encrypts the result with a new random vault password and hands that
# password over (clipboard on macOS, otherwise the terminal) to be saved as
# the GitHub secret ANSIBLE_VAULT_PASSWORD (environment production) - the
# only place it is kept. vault.yml is replaced after that is confirmed.
# Neither the passwords nor the plaintext vault touch the disk; the vault
# cannot be read back, so every run replaces it as a whole.
#
#   scripts/vault.sh
#
# Needs Docker: htpasswd and ansible-vault run in a container.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly DOCKERFILE=docker/ansible.Dockerfile
readonly VAULT_FILE=inventory/group_vars/all/vault.yml
readonly SECRET=ANSIBLE_VAULT_PASSWORD
IMAGE=mygarage-ansible:$(git hash-object "$DOCKERFILE" | cut -c1-12)
readonly IMAGE

die() {
    echo "error: $*" >&2
    exit 1
}

if [[ $# -gt 0 ]]; then
    sed -n '2,13s/^# \{0,1\}//p' "$0" >&2
    exit 2
fi
[[ -t 0 ]] || die "run it in a terminal: it asks for passwords"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building $IMAGE (once)" >&2
    docker build -q -t "$IMAGE" -f "$DOCKERFILE" docker >/dev/null
fi

in_docker() {
    docker run --rm -i \
        --user "$(id -u):$(id -g)" \
        -e HOME=/tmp \
        -e ANSIBLE_VAULT_PASSWORD \
        -v "$PWD:/work" -w /work \
        "$IMAGE" "$@"
}

# --- application users --------------------------------------------------------
users=""
while :; do
    default=""
    [[ -z $users ]] && default=garage
    read -r -p "Login${default:+ [$default]}${users:+ (empty = done)}: " name
    name=${name:-$default}
    [[ -z $name ]] && break
    [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "  letters, digits, . _ - only"; continue; }

    read -r -s -p "Password for $name: " pass1 && echo
    read -r -s -p "Repeat: " pass2 && echo
    if [[ $pass1 != "$pass2" ]]; then
        echo "  passwords differ"
        continue
    fi
    if ((${#pass1} < 12)); then
        echo "  at least 12 characters"
        continue
    fi

    # Password goes through stdin, never through arguments or environment.
    hash=$(printf '%s' "$pass1" | in_docker htpasswd -niB "$name" | cut -d: -f2-)
    unset pass1 pass2
    [[ $hash == \$2y\$* ]] || die "htpasswd failed"
    users+="  - name: $name"$'\n'"    hash: \"$hash\""$'\n'
done
[[ -n $users ]] || die "at least one login is required"

# --- monitoring ---------------------------------------------------------------
echo "Alert URL receives monitoring problems as POST, e.g. https://ntfy.sh/<secret-topic>."
while :; do
    read -r -p "Alert URL (empty = journal only): " alert_url
    [[ -z $alert_url || $alert_url =~ ^https?://[^[:space:]\"\\]+$ ]] && break
    echo "  expected http(s)://… without spaces or quotes"
done

vault="---
vault_htpasswd_users:
${users}
vault_monitor_alert_url: \"${alert_url}\"
"

# --- encrypt and hand over the password ---------------------------------------
ANSIBLE_VAULT_PASSWORD=$(openssl rand -base64 32)
export ANSIBLE_VAULT_PASSWORD

clipboard=no
command -v pbcopy >/dev/null && clipboard=yes

tmp="$VAULT_FILE.new"
cleanup() {
    rm -f "$tmp"
    if [[ $clipboard == yes ]]; then pbcopy </dev/null; fi
}
trap cleanup EXIT
printf '%s' "$vault" | in_docker ansible-vault encrypt --output "$tmp" - >/dev/null

echo
echo "Save the vault password in GitHub:"
echo "  mygarage-infra → Settings → Environments → production →"
echo "  Environment secrets → $SECRET (Add secret / edit) → paste → Save."
if [[ $clipboard == yes ]]; then
    printf '%s' "$ANSIBLE_VAULT_PASSWORD" | pbcopy
    echo "The password is in the clipboard; it is cleared when this script exits."
else
    echo "Password: $ANSIBLE_VAULT_PASSWORD"
fi
while :; do
    read -r -p "Type 'saved' when done (Ctrl-C aborts, $VAULT_FILE stays unchanged): " answer
    [[ $answer == saved ]] && break
done

mv -f "$tmp" "$VAULT_FILE"
echo "$VAULT_FILE written."
echo "Commit and push it now: provision fails until the new vault.yml is in main."
