#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — one-command entry point for the Ansible workstation build.
#
# Installs Ansible + the required Galaxy collections, then runs the playbook
# against localhost. This is the only bash that survives the rebuild; all the
# real provisioning logic lives in the Ansible roles.
#
#   Run from a clone:
#     WORKSTATION_PROFILE=xubuntu ./bootstrap.sh
#
#   Self-provision a fresh box (no clone needed):
#     curl -fsSL https://raw.githubusercontent.com/lentago/kalmia/main/bootstrap.sh \
#       | WORKSTATION_PROFILE=xubuntu bash
#
# Re-runnable: every role is idempotent. The profile autodetects when unset.
# ============================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/lentago/kalmia.git}"
BRANCH="${BRANCH:-main}"

extra_args=()
if [[ -n "${WORKSTATION_PROFILE:-}" ]]; then
  extra_args+=(-e "workstation_profile=${WORKSTATION_PROFILE}")
fi

have() { command -v "$1" >/dev/null 2>&1; }

install_ansible() {
  if have ansible-playbook; then
    return
  fi
  echo "[bootstrap] Installing Ansible..."
  if have apt-get; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq git software-properties-common
    sudo apt-get install -y -qq ansible
  elif have dnf; then
    sudo dnf install -y -q git ansible
  else
    echo "[bootstrap] Unsupported package manager — install Ansible manually." >&2
    exit 1
  fi
}

install_ansible

if [[ -f site.yml && -d roles ]]; then
  echo "[bootstrap] Running playbook from local checkout..."
  [[ -f requirements.yml ]] && ansible-galaxy collection install -r requirements.yml
  exec ansible-playbook -i inventory/hosts.yml site.yml "${extra_args[@]}" "$@"
else
  echo "[bootstrap] Self-provisioning via ansible-pull from ${REPO_URL} (${BRANCH})..."
  ansible-galaxy collection install community.general >/dev/null 2>&1 || true
  exec ansible-pull -U "$REPO_URL" -C "$BRANCH" -i localhost, site.yml "${extra_args[@]}" "$@"
fi
