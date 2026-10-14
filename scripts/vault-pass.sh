#!/usr/bin/env bash
# Prints the Ansible Vault password from ANSIBLE_VAULT_PASSWORD. The
# password exists only in the GitHub secret of the same name (see
# scripts/vault.sh); workflows pass it through the environment.
set -euo pipefail

if [[ -z "${ANSIBLE_VAULT_PASSWORD:-}" ]]; then
    echo "ANSIBLE_VAULT_PASSWORD is not set: the vault password exists only in GitHub" >&2
    exit 1
fi
printf '%s\n' "$ANSIBLE_VAULT_PASSWORD"
