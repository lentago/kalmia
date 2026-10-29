#!/usr/bin/env bash
# Ask a PVE node's mount hook to attach one bind mount (#190). Bind mounts
# are root@pam-only, so the API token can't set them; this goes over SSH to
# the node's kalmia-mounts user, whose key can only run kalmia-mount-attach,
# and that applies the mount only if the node's allowlist carries it.
#
# Called by terraform_data local-exec during the CI apply, with HOOK_HOST,
# VMID, MP and SPEC in the environment. The apply job writes the key from
# secret PVE_MOUNT_HOOK_SSH_KEY. See README.md § Bind mounts — the mount hook.
set -euo pipefail

: "${HOOK_HOST:?}" "${VMID:?}" "${MP:?}" "${SPEC:?}"
key="${PVE_MOUNT_HOOK_SSH_KEY_FILE:-}"
if [[ ! -s $key ]]; then
  echo "mount-hook: PVE_MOUNT_HOOK_SSH_KEY_FILE is unset or empty; the CI apply job sets it from secret PVE_MOUNT_HOOK_SSH_KEY" >&2
  exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
exec ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$here/pve-known-hosts" \
  "kalmia-mounts@$HOOK_HOST" "attach $VMID $MP $SPEC"
