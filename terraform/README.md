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

## CI / apply-on-merge

The [`terraform` workflow](../.github/workflows/terraform.yml) runs on every
PR and push touching `terraform/**`:

- **PR** → `validate` (fmt + validate, GitHub-hosted) and `plan` (posts the
  diff as a PR comment).
- **push to `main`** → `validate` then **`apply -auto-approve`** — merging a
  guest change deploys it; this directory is a fleet **enforced surface**
  (live-state vs. code discipline applies: never mutate guests via `pvesh`/UI
  without codifying here in the same session).

`plan` and `apply` run on the **LAN self-hosted runner** — LXC 115
`gha-runner` on pve4 (`runs-on: [self-hosted, lan]`) — because the PVE API is
LAN-only. CI reaches AWS (S3 state) via GitHub OIDC assuming
`arn:aws:iam::365184644049:role/kalmia-github-actions-terraform` (this state
key + the lock table only), and reaches PVE via the `PROXMOX_VE_API_TOKEN`
repo secret. The `apply` job serializes under a `terraform-apply` concurrency
group.

### Runner notes (LXC 115)

- Agent in `/opt/actions-runner`, runs as user `runner`, systemd service
  installed via `svc.sh`; registered repo-scoped with label `lan`.
- Re-register after a rebuild: `gh api -X POST
  repos/lentago/kalmia/actions/runners/registration-token -q .token`, then
  `config.sh --unattended --url https://github.com/lentago/kalmia --token …
  --name gha-runner --labels lan`.
- **Public-repo hardening**: workflow approval is required for **all**
  external contributors (repo Actions setting); secrets are not exposed to
  fork-PR runs; the OIDC role trusts only `repo:lentago/kalmia:*` subs.
- **Firewalla gotcha**: a brand-new guest lands in Device Access Protection
  `learning` state (default-block + isolation — WAN IPv4 RST'd) until it's
  classified. If a fresh guest can't reach the internet, check
  `policy:mac:<MAC>` / `host:mac:<MAC>` on the Firewalla and see the fleet
  memory; FireMain restart forces re-evaluation.

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
| 115 | lxc | gha-runner | pve4 | n/a — created BY this layer (phase 2) |

VM 100 (Home Assistant OS) is mission-critical and USB-pinned to pve3
(Z-Wave/Zigbee/Matter radios; passthrough does not survive migration). It is
imported last, gets `lifecycle { prevent_destroy = true }` from day one, and
its plans are reviewed with extra care.

## Phases

- [x] **0 — scaffolding**: provider + backend + smoke data source (#21)
- [x] **0b — identity**: operator runs the `pveum` block above; `terraform
      plan` returns the five node names (done 2026-07-04)
- [x] **1 — pve4 LXCs**: `import` blocks for 110–114, imported to a clean
      `plan: no changes` (#23)
- [ ] **2 — apply-on-merge**: self-hosted GitHub Actions runner LXC on the
      LAN + kalmia-scoped AWS OIDC role for state; add this surface to the
      fleet "Live-state vs. code discipline" table
- [ ] **3 — remaining guests**: pve5 workstations + testbeds, then VM 100
- [ ] **Cleanup**: pin the PVE CA (drop `insecure = true`); evaluate
      provider coverage for backup jobs (`jobs.cfg`) and users/ACLs

Known provider limits (v0.111, 2026-07): PVE 9's new HA-resources API is
unsupported — fine here, `ha-manager` is deliberately unused (VM 100 pinning).

## Import gotchas (learned in phase 1)

- `operating_system.template_file_id` is required but create-only and cannot
  be reconciled on imported guests → set it to the real template and add
  `lifecycle { ignore_changes = [operating_system] }`.
- The first apply after a container import writes the provider's `console`
  defaults (`cmode: tty`, `console: 1`, `tty: 2`) explicitly into the live
  config. The values equal PVE's implicit defaults — no behavior change, no
  restart — but the config text changes. Do **not** then add an explicit
  `console {}` block to match: the provider keeps state blockless, so an
  explicit block plans as a perpetual add. Omit it.
- Read the full plan before declaring a diff benign — the whole diff, not a
  grep of it.
