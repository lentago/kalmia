# Proxmox VE node substrate — storage safety and the mount hook

Every guest disk lives on its node's `local-lvm` thin pool, on a single SSD.
Guests are provisioned well past pool size on pve4 and pve5 (123% and 157% at
the 2026-10-25 audit), so a pool that fills takes every guest on that node
down with it. Three layers keep that from happening:

| Layer | Where | What |
|---|---|---|
| Autoextend | `pve-host.yml` → `pve_host` role | dmeventd grows `pve/data` by 10% at 80% full, from the VG's ~16 GiB free |
| Trim | `pve_host` role | `pve-lxc-fstrim.timer` runs `pct fstrim` on every running CT nightly at 04:30; VMs use `discard = "on"` (Terraform) plus the guest's own `fstrim.timer` |
| Alert | [drosera](https://github.com/lentago/drosera) | `lvm_thin_pool_*_percent` textfile metrics and the thin pool and root filesystem rules in its "On-prem availability" alert group |

## Apply

PVE nodes have no Ansible, so the play is pushed from a workstation whose
SSH key root accepts:

```bash
ansible-playbook -i pve,pve2,pve3,pve4,pve5, -u root pve-host.yml --check --diff
ansible-playbook -i pve,pve2,pve3,pve4,pve5, -u root pve-host.yml
```

## Autoextend headroom

Each node's VG has about 16 GiB unallocated. 10% of a 141 GiB pool (14 GiB)
fits that once; after one extension the VG is spent and the alert is the only
remaining guard. On pve (337 GiB pool) 10% is 34 GiB, more than the VG holds,
so autoextend there will fail. That pool is empty today.

## `local` holds no guest disks

`local` is a directory on each node's root filesystem. A VM disk there can
fill the hypervisor's `/` (xubuntu-ws did, at 32 of 68 GiB, until it moved to
`local-lvm` on 2026-10-24). Its content types exclude `images` and `rootdir`
so new disks can't land there. `storage.cfg` is cluster-wide and not managed
by Terraform; set it once from any node:

```bash
pvesm set local --content import,backup,vztmpl,snippets,iso
```

## Guest agents

All five VMs set `agent { enabled = true }` and their images carry
`qemu-guest-agent` (HAOS ships it). LXCs have no agent; PVE reaches them
directly with `pct exec`.

## Mount hook

Bind mount points are root@pam-only (PVE rejects any non-volume `mpN` from an
API token), so the token-driven Terraform pipeline cannot give a guest a NAS
bind mount on its own. The mount hook lets it, without handing CI root (#190).
On each node in `pve_host_mount_hook_nodes` (pve4 today) the `pve_host` role
installs:

| Piece | What it allows |
|---|---|
| `kalmia-mounts` user, `/var/lib/kalmia-mounts/.ssh/authorized_keys` | One key, the public half of kalmia's `PVE_MOUNT_HOOK_SSH_KEY` secret: `restrict`, accepted only `from=` LXC 115 (the apply runner), forced command |
| `/etc/sudoers.d/kalmia-mount-hook` | That user may sudo `/usr/local/sbin/kalmia-mount-attach` and nothing else |
| `/usr/local/sbin/kalmia-mount-attach` | Takes `attach <vmid> <mpN> <spec>` and runs `pct set` only when that exact triple is a line of the allowlist; a no-op if already attached |
| `/etc/kalmia/mount-hook.allow` | The allowlist, from `pve_host_mount_hook_allow` in `roles/pve_host/defaults/main.yml` |

So a leaked key can re-attach approved mounts to their approved guests and do
nothing else. It is strictly weaker than the API token CI already holds.
Every refusal is logged (`journalctl -t kalmia-mount-attach`).

**Adding a mount:** add it to `pve_host_mount_hook_allow` *and* to the
guest's mount map in `terraform/`, character for character, in one PR. Push
this play to the node **before merging**: the merge's apply calls the hook,
and a mount missing from the node's allowlist fails the apply. Pushing the
play is the root approval step. CI can never widen the allowlist itself.

```bash
ansible-playbook -i pve4, -u root pve-host.yml --check --diff
ansible-playbook -i pve4, -u root pve-host.yml
```

**Rotating the key:** `ssh-keygen -t ed25519 -N '' -C kalmia-ci-mount-hook`,
set the private half as repo secret `PVE_MOUNT_HOOK_SSH_KEY`, put the public
half in `pve_host_mount_hook_pubkey`, push the play, then shred the local
private key.
