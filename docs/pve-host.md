# Proxmox VE node storage safety

Every guest disk lives on its node's `local-lvm` thin pool, on a single SSD.
Guests are provisioned well past pool size on pve4 and pve5 (123% and 157% at
the 2026-10-25 audit), so a pool that fills takes every guest on that node
down with it. Three layers keep that from happening:

| Layer | Where | What |
|---|---|---|
| Autoextend | `pve-host.yml` → `pve_host` role | dmeventd grows `pve/data` by 10% at 80% full, from the VG's ~16 GiB free |
| Trim | `pve_host` role | `pve-lxc-fstrim.timer` runs `pct fstrim` on every running CT nightly at 04:30; VMs use `discard = "on"` (Terraform) plus the guest's own `fstrim.timer` |
| Alert | homelab-observability | `lvm_thin_pool_*_percent` textfile metrics and the "On-prem storage" alert rules |

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
