# SSH public key for the dev host (xubuntu-ws), seeded into every guest this
# layer defines via cloud-init `initialization.user_account.keys`, so a guest
# that is created or rebuilt comes up already reachable from the dev host (#337).
#
# Public key only — never a private key.
#
# Guard: changing a container's `initialization` block forces replacement in
# the bpg provider, so every EXISTING guest carries
# `ignore_changes = [initialization[0].user_account]`. The key lands only in a
# newly created or rebuilt guest; no live guest is replaced to pick it up, and
# the PR plan must show 0 to destroy / 0 to replace. Existing guests keep the
# access they already have (n8n's key was added live 2026-11-19; the rest are
# reached through `pct exec`). Guests owned by claytonia (the bullpen runner
# pool) are out of scope. VMs carry no `initialization` block and are untouched.
locals {
  xubuntu_ws_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIHfTzag/D3L36ciwHOomPzdc4vQQcojEZK+9FjNTOI0 cpitzi@xubuntu-ws"
}
