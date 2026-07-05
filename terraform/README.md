# Proxmox guest lifecycle — Terraform

This layer owns **guest existence and shape** on `homelab-cluster` — which
VMs/LXCs exist, their resources, placement, and hardware config — via the
[`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox) provider.
It sits between the hardware and the Ansible layer: what's *inside* the guest
OS remains the job of the playbooks in the repo root.

Suite boundary (2026-07-04): **kalmia = local infra, solidago = cloud infra.**

## Auth — the `terraform@pve` identity

The provider authenticates with a dedicated PVE user + API token, separate
from the MCP token (`root@pam!claude-mcp`). Creating it is a one-time,
operator-run step (it is an RBAC grant on shared infra — deliberately not
automated):

```bash
ssh root@pve.local

pveum user add terraform@pve --comment "kalmia terraform provider (bpg/proxmox)"

# Least-privilege variant of the provider's documented PVE 9 role: the
# identity/permission-management privileges (Permissions.Modify, User.Modify,
# Realm.*, Group.Allocate) are DROPPED — this token manages guests, not
# users/ACLs. Re-add them only if PVE users/ACLs themselves go under
# Terraform later.
pveum role add Terraform -privs "VM.Allocate, VM.Audit, VM.Backup, VM.Clone, VM.Console, VM.Migrate, VM.PowerMgmt, VM.Replicate, VM.Snapshot, VM.Snapshot.Rollback, VM.Config.CDROM, VM.Config.CPU, VM.Config.Cloudinit, VM.Config.Disk, VM.Config.HWType, VM.Config.Memory, VM.Config.Network, VM.Config.Options, VM.GuestAgent.Audit, VM.GuestAgent.FileRead, VM.GuestAgent.FileSystemMgmt, VM.GuestAgent.FileWrite, VM.GuestAgent.Unrestricted, Datastore.Allocate, Datastore.AllocateSpace, Datastore.AllocateTemplate, Datastore.Audit, Pool.Allocate, Pool.Audit, SDN.Allocate, SDN.Audit, SDN.Use, Mapping.Audit, Mapping.Modify, Mapping.Use, Sys.AccessNetwork, Sys.Audit, Sys.Console, Sys.Incoming, Sys.Modify, Sys.PowerMgmt, Sys.Syslog"

pveum aclmod / -user terraform@pve -role Terraform

# --privsep=0: the token inherits the user's role (no separate token ACL)
pveum user token add terraform@pve kalmia --privsep=0
```

The last command prints the token **once**. Export it for local runs
(nothing in this directory ever contains it):

```bash
export PROXMOX_VE_API_TOKEN='terraform@pve!kalmia=<uuid>'
```

For CI it becomes a repo Actions secret of the same name. Note: a handful of
provider operations require SSH to the node or root@pam (snippet uploads,
disk imports via `source_file.path`) — not needed for guest lifecycle; if one
ever is, wire the provider `ssh {}` block rather than widening the token.

## State

Remote state in the shared tfstate bucket (`foundry-tfstate-365184644049`,
key `kalmia/terraform.tfstate`, DynamoDB locking) — see `backend.tf`. Local
runs use the `cpitzi-iac` IAM credentials already on the workstation.

## Guest inventory (live snapshot, 2026-07-04)

| VMID | Type | Name | Node | Import phase |
|---|---|---|---|---|
| 110 | lxc | claude-runner | pve4 | 1 |
| 111 | lxc | claude-runner-2 | pve4 | 1 |
| 112 | lxc | claude-runner-3 | pve4 | 1 |
| 113 | lxc | n8n | pve4 | 1 |
| 114 | lxc | pub | pve4 | 1 |
| 105 | lxc | grafana-stack | pve5 | 3 |
| 102 | qemu | xubuntu-ws | pve5 | 3 |
| 104 | qemu | fedora-ws | pve5 | 3 |
| 120 | qemu | xubuntu-test | pve5 | 3 |
| 121 | qemu | fedora-xfce-test | pve5 | 3 |
| 100 | qemu | haos-17.1 | pve3 | 3 — **last** |

VM 100 (Home Assistant OS) is mission-critical and USB-pinned to pve3
(Z-Wave/Zigbee/Matter radios; passthrough does not survive migration). It is
imported last, gets `lifecycle { prevent_destroy = true }` from day one, and
its plans are reviewed with extra care.

## Phases

- [x] **0 — scaffolding**: provider + backend + smoke data source (#21)
- [ ] **0b — identity**: operator runs the `pveum` block above; `terraform
      plan` returns the five node names
- [ ] **1 — pve4 LXCs**: `import` blocks for 110–114, iterate to a clean
      `plan: no changes`
- [ ] **2 — apply-on-merge**: self-hosted GitHub Actions runner LXC on the
      LAN + kalmia-scoped AWS OIDC role for state; add this surface to the
      fleet "Live-state vs. code discipline" table
- [ ] **3 — remaining guests**: pve5 workstations + testbeds, then VM 100
- [ ] **Cleanup**: pin the PVE CA (drop `insecure = true`); evaluate
      provider coverage for backup jobs (`jobs.cfg`) and users/ACLs

Known provider limits (v0.111, 2026-07): PVE 9's new HA-resources API is
unsupported — fine here, `ha-manager` is deliberately unused (VM 100 pinning).
