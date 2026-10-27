#!/usr/bin/env bash
# Creates inventory/group_vars/all/vault.yml: asks for the logins of the
# application and of the test site and the alert URL, hashes them (bcrypt),
# encrypts the result with a new random vault password and hands that
# password over (clipboard on macOS, otherwise the terminal), guiding through
# saving it as the GitHub secret ANSIBLE_VAULT_PASSWORD (environment
# production) - the only place it is kept. vault.yml is replaced after that
# is confirmed; the clipboard is cleared on exit.
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

# ask_users <default login> <required>: reads logins and passwords until an
# empty login into $users, a YAML list of {name, hash}. required=no accepts
# no login at all and offers no default.
ask_users() {
    local first=$1 required=$2 prompt name pass1 pass2 hash
    users=""
    while :; do
        if [[ -n $users ]]; then
            prompt="Login (empty = done): "
        elif [[ $required == yes ]]; then
            prompt="Login [$first]: "
        else
            prompt="Login (empty = none): "
        fi
        read -r -p "$prompt" name
        [[ -z $users && $required == yes ]] && name=${name:-$first}
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
    [[ -n $users || $required == no ]] || die "at least one login is required"
}

# --- application users --------------------------------------------------------
echo "Logins of the application."
ask_users garage yes
app_users=$users

# --- test site users ----------------------------------------------------------
echo "Logins of the test site test.<site domain>, separate from the application;"
echo "required once site_test_enabled is true."
ask_users test no
site_test_users=$users
if [[ -n $site_test_users ]]; then
    site_test_users=$'\n'$site_test_users
else
    site_test_users=$' []\n'
fi

# --- monitoring ---------------------------------------------------------------
echo "Alert URL receives monitoring problems as POST, e.g. https://ntfy.sh/<secret-topic>."
while :; do
    read -r -p "Alert URL (empty = journal only): " alert_url
    [[ -z $alert_url || $alert_url =~ ^https?://[^[:space:]\"\\]+$ ]] && break
    echo "  expected http(s)://… without spaces or quotes"
done

vault="---
vault_htpasswd_users:
${app_users}
vault_site_test_htpasswd_users:${site_test_users}
vault_monitor_alert_url: \"${alert_url}\"
"

# --- encrypt and hand over the password ---------------------------------------
ANSIBLE_VAULT_PASSWORD=$(openssl rand -base64 32)
export ANSIBLE_VAULT_PASSWORD

clipboard=no
command -v pbcopy >/dev/null && clipboard=yes
copied=no

tmp="$VAULT_FILE.new"
cleanup() {
    rm -f "$tmp"
    if [[ $copied == yes ]]; then pbcopy </dev/null; fi
}
trap cleanup EXIT
printf '%s' "$vault" | in_docker ansible-vault encrypt --output "$tmp" - >/dev/null

# The password reaches the clipboard only once the GitHub form is open and
# leaves it as soon as the secret is saved.
echo
echo "Step 1/2. Open the secret form in GitHub:"
echo "  mygarage-infra → Settings → Environments → production → Environment secrets"
echo "  → Add environment secret, Name: $SECRET"
echo "  (already exists → pencil icon next to $SECRET)"
read -r -p "Press Enter when the form is open (Ctrl-C aborts, $VAULT_FILE stays unchanged): " _

echo
echo "Step 2/2. Paste the password into Value and click Add secret / Update secret."
if [[ $clipboard == yes ]]; then
    printf '%s' "$ANSIBLE_VAULT_PASSWORD" | pbcopy
    copied=yes
    echo "  The password is in the clipboard."
else
    echo "  Password: $ANSIBLE_VAULT_PASSWORD"
fi
while :; do
    read -r -p "Press Enter when the secret is saved, c + Enter to copy it again: " answer
    case $answer in
        "") break ;;
        c) [[ $clipboard == yes ]] && printf '%s' "$ANSIBLE_VAULT_PASSWORD" | pbcopy ;;
    esac
done

mv -f "$tmp" "$VAULT_FILE"
echo "$VAULT_FILE written."
echo "Commit and push it now: provision fails until the new vault.yml is in main."
