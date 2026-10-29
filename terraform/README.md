# Proxmox guest lifecycle — Terraform

This layer owns **guest existence and shape** on `homelab-cluster` — which
VMs/LXCs exist, their resources, placement, and hardware config — via the
[`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox) provider.
It sits between the hardware and the Ansible layer: what's *inside* the guest
OS remains the job of the playbooks in the repo root.

One carve-out (2026-07-07, #37): the **bullpen runner pool** (claude-runner
1–5, VMIDs 110–112/116–117) is owned by
[claytonia](https://github.com/lentago/claytonia)'s `terraform/` — products
own their capacity. kalmia keeps every other guest, including LXC 115
`gha-runner` (shared CI substrate must not depend on claytonia's workers).

Since #30 the layer also owns the cluster's two vzdump **backup jobs**
([`backup-jobs.tf`](backup-jobs.tf)) — the backup *policy* sits under the
same drift detection as the guests it protects. Read that file's header
before touching them: `guests-weekly` depends on its `exclude = ["100"]`.

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

A second, much narrower secret, `PVE_MOUNT_HOOK_SSH_KEY`, lets the apply attach
allowlisted bind mounts, which the token can't. See § Bind mounts — the mount
hook.

### TLS — trusting the PVE CA (why `insecure = false`)

The cluster serves a self-signed cert issued by its PVE Cluster Manager CA.
The provider has no CA-file argument, so instead of `insecure = true` both run
contexts trust that CA out of band via Go's cert-pool env vars:

- `SSL_CERT_DIR=/etc/ssl/certs` — keeps the system roots (needed for the AWS
  S3 state backend).
- `SSL_CERT_FILE=<pve-root-ca.pem>` — adds the Proxmox root CA. Go loads certs
  from both, so the pool ends up with public roots **and** the PVE CA.

The public CA cert is committed at [`pve-root-ca.pem`](pve-root-ca.pem) (a
trust anchor, no private key). The node cert's SANs already include the IP
endpoint (`192.168.139.8`) plus `pve`/`pve.local`, so no endpoint change is
needed. CI sets both env vars in the workflow; locally they live in
`~/.config/kalmia/proxmox.env` alongside the token (pointing at a copy at
`~/.config/kalmia/pve-root-ca.pem`). If the CA is ever rotated, replace both
copies.

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

### ForceNew guard (#53)

A ForceNew attribute change makes the provider destroy and recreate a guest
(this is how CT 113 was lost on 2026-07-12), and the recreate can fail
post-merge if it needs `root@pam`-only settings (see Rails below). Two layers:

- **PR template** — the Terraform checklist asks the author to review the plan
  for destroy/replace, confirm the guest is recreatable by `terraform@pve!kalmia`
  (no bind mounts / `keyctl` / other `root@pam`-only settings, else pre-create),
  and confirm a recent `vzdump` exists.
- **`plan` job guard** — after `terraform plan -out=tfplan`, the workflow parses
  `terraform show -json tfplan` (python3; no `jq` dependency) and lists every
  `proxmox_virtual_environment_container` / `_vm` whose actions include
  `delete` (destroy or replace) in the PR plan comment. The job **fails unless
  the PR body contains the exact line** `- [x] Guest recreate feasibility verified`,
  which blocks the `gate`. The body is read live from the API, so after ticking
  the box just re-run the `plan` job (`edited` isn't a trigger, and a re-run
  replays the original event payload — hence the live read).
  No labels are used (they're IaC-managed in `lentago/.github`). The Dependabot
  skip on `plan` is unchanged.

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
- **Firewalla quarantine** (since 2026-10-22): New Device Quarantine also puts
  every brand-new MAC in group 45 `Quarantine`, whose rule blocks internet
  (LAN still works; outbound TCP is refused). First hit on a real guest:
  CT 123 on 2026-10-29, within seconds of its create. `redis-cli hget
  policy:mac:<MAC> tags` on the Firewalla shows `["45"]`. The owner approves
  the device in the Firewalla app (device → group → remove Quarantine) before
  any in-guest provisioning. Pin `mac_address` so a rebuild keeps the approval.

## State

Remote state in the shared tfstate bucket (`solidago-tfstate-365184644049`,
key `kalmia/terraform.tfstate`, DynamoDB locking) — see `backend.tf`. Local
runs use the `cpitzi-iac` IAM credentials already on the workstation.

## Guest inventory (live snapshot, 2026-07-04)

| VMID | Type | Name | Node | Import phase |
|---|---|---|---|---|
| 113 | lxc | n8n | pve4 | 1 |
| 114 | lxc | pub | pve4 | 1 |
| 105 | lxc | grafana-stack | pve5 | 3 |
| 102 | qemu | xubuntu-ws | pve5 | 3 |
| 104 | qemu | fedora-ws | pve5 | 3 |
| 120 | qemu | xubuntu-test | pve5 | 3 |
| 121 | qemu | fedora-xfce-test | pve5 | 3 |
| 100 | qemu | haos-17.1 | pve3 | 3 — **last** |
| 115 | lxc | gha-runner | pve4 | n/a — created BY this layer (phase 2) |
| 123 | lxc | pe-publish | pve4 | n/a — created BY this layer (#190) |

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
- [x] **2 — apply-on-merge**: LAN self-hosted runner (LXC 115) + kalmia AWS
      OIDC role + `terraform` workflow; added to the fleet enforced-surfaces
      table (#27)
- [x] **3 — remaining guests**: pve5 LXC 105 + VMs 102/104/120/121, then
      VM 100 (HAOS) last — all imported to a clean `plan: no changes`, guests
      verified running/stopped as before, HAOS not rebooted (#28)
- [x] **Cleanup**: pinned the PVE CA — `insecure = false`, trust via
      `SSL_CERT_FILE`/`SSL_CERT_DIR` (see § TLS). Provider coverage evaluated:
      `proxmox_virtual_environment_backup_job` exists → backup jobs
      (`jobs.cfg`) are a worthwhile future phase (#30). Users/ACLs are also
      supported, but the `terraform@pve` identity is deliberately **not**
      brought under Terraform — managing the credentials TF authenticates with
      is circular and a bad apply could lock out the runner; it stays a
      bootstrap concern.
- [x] **4 — backup jobs**: the two cluster vzdump jobs (`haos-4h`,
      `guests-weekly`) imported to a clean `plan: no changes` (#30). Their
      `comment` and the weekly job's `exclude 100` were live-only until
      provider v0.115.0; both are now in config (#104), with
      `prevent_destroy` kept. See the [`backup-jobs.tf`](backup-jobs.tf)
      header before touching these jobs.

**All 9 guests kalmia owns are under Terraform.** The bullpen runner pool
(110–112, 116–117 — grown to five workers in #34/#35) was released to
claytonia's `terraform/` on 2026-07-07 (#37; adoption
lentago/claytonia#51), with the state moved via `terraform state rm` +
import — no guest was touched.

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

## Destroy guards — which guests carry `prevent_destroy` (#50)

The bpg provider treats some edits (e.g. adding a `mount_point`) as ForceNew,
and an API-token apply cannot recreate guests that need `root@pam`-only
features (`keyctl`, or bind mounts the mount hook doesn't attach). The 2026-07-12 CT 113 destruction was exactly
that. `prevent_destroy = true` turns a destroy into a hard plan-time failure.
Rule: guard every guest the token pipeline cannot rebuild; leave
pipeline-recreatable guests unguarded so ordinary replacements still work.

| Guest | Resource | Guarded | Class / why |
|---|---|---|---|
| n8n CT 113 | `container.n8n` | yes | Import-only: `keyctl`, root@pam-created. Stays guarded until its two-step retirement (#124) |
| pub CT 114 | `container.pub` | yes | Import-only: NAS bind mount is root@pam-only |
| grafana-stack CT 105 | `container.grafana_stack` | yes | Import-only: build template gone, live state unrebuildable |
| xubuntu-ws VM 102, fedora-ws VM 104 | `vm.xubuntu_ws`, `vm.fedora_ws` | yes | Import-only: workstation disks hold unrecoverable state |
| testbeds VM 120, 121 | `vm.testbed` | yes | Import-only: disks and `pristine` snapshots can't be rebuilt by the pipeline |
| k3s CT 119, 122 | `container.k3s` | yes | `keyctl` ⇒ root@pam pre-create + import (see Rails below), so effectively import-only |
| HAOS VM 100 | `vm.haos` | yes | Hardware-pinned USB radios (since #28) |
| backup jobs | `backup-jobs.tf` | yes | Pre-existing |
| brasenia CT 118 | `container.brasenia` | no | Pipeline-recreatable: token-created (nesting alone is allowed on create), no keyctl/bind mount; `terraform_data.brasenia_rebuild` forces a rebuild ([`containers.tf`](containers.tf); create-path evidence on [#63](https://github.com/lentago/kalmia/issues/63#issuecomment-6509707205)) |
| gha-runner CT 115 | `container.gha_runner` | no | Pipeline-recreatable: token-created, no keyctl/bind mount. Note it runs this pipeline, so a self-replace mid-apply would need manual recovery |
| pe-publish CT 123 | `container.pe_publish` | no | Pipeline-recreatable: token-created, bind mounts re-attached by the mount hook (§ below) |

Intentionally replacing a guarded guest means removing the guard in a
dedicated PR first (and, for import-only guests, pre-creating as root@pam).

## Bind mounts — the mount hook

PVE lets only root@pam set a bind mount point (`mount point type bind is only
allowed for root@pam`; directory mappings cover VM virtiofs, not containers),
so a `mount_point` block on a token-created guest fails the apply with HTTP 403.
Imported guests (pub CT 114, the claytonia workers) keep theirs from a manual
`pct set` and ignore `mount_point`; rebuilt, they would come back without it.

The mount hook (#190) closes that for any mount on its allowlist:

1. The guest resource declares **no** `mount_point` and carries `mount_point`
   in `ignore_changes`. Its mounts live in a locals map,
   `mpN => "<host path>,mp=<ct path>[,ro=1]"` (PVE's canonical form, as
   `pct config` prints it).
2. A `terraform_data` per mount runs [`mount-hook.sh`](mount-hook.sh) via
   `local-exec`, with `replace_triggered_by` on the guest: whenever the guest is
   created, replaced or updated, each mount is re-requested (a no-op when it's
   already attached).
3. `mount-hook.sh` SSHes to the node as `kalmia-mounts` with the key the apply
   job writes from secret `PVE_MOUNT_HOOK_SSH_KEY`, pinning the node's host
   key from [`pve-known-hosts`](pve-known-hosts). That user can only run
   `kalmia-mount-attach`, which applies the mount only if the exact
   `<vmid> <mpN> <spec>` is in the node's root-owned allowlist.

The allowlist is the root-side approval. It lives in `roles/pve_host` and
reaches the node only when an operator pushes `pve-host.yml`, so CI can
re-attach approved mounts but never choose a host path. **Push the play before
merging** a PR that adds a mount, or the merge's apply fails at the hook. Plan
never runs provisioners, so PR plans neither need nor see the key. Host side,
security envelope and key rotation: [`docs/pve-host.md` § Mount hook](../docs/pve-host.md#mount-hook).

Worked example: `pe-publish.tf` (CT 123, three NAS mounts).

## Rails — non-`nesting` feature flags require root@pam pre-create

PVE enforces a privilege boundary on LXC feature flags: the `terraform@pve`
token may create containers, but **only `root@pam` may set features other than
`nesting`**. Applying a new container carrying `keyctl`, `fuse`, `mknod`, etc.
from CI fails with HTTP 403 even though `terraform plan` returns a clean diff.

> **Reviewer warning:** a plan that shows a feature-flagged container as
> `create` will pass the CI plan job and fail the CI apply job — **the 403
> lands post-merge**. Any new LXC resource with a non-`nesting` feature flag is
> a pre-create gate: the operator must stand up the container before the PR is
> merged.

**Changing features on an existing container hits the same 403, even for
`nesting` alone** (found 2026-10-29, #194, LXC 118). On update the provider
(0.115) sends every flag (`fuse=0,keyctl=0,mknod=0,nesting=1`), so it can
clear a flag. PVE's `check_ct_modify_config_perm` lets the token add features
to a featureless container only when the request is exactly `nesting`, and it
counts any other key as a privileged change, even one set to 0. So set the
feature live first, as root@pam, then merge; the plan then has no change for
that container:

```bash
ssh root@pve4.local 'pct set 118 --features nesting=1 && pct reboot 118'
```

The k3s pool (`#121`, VMIDs 119/122) was the module's first attempted create
with `keyctl = true`; it surfaced this constraint. Every earlier feature-flagged
guest (n8n, VMID 113: `nesting + keyctl`) predates the module and was adopted
via import, which masked it. The recipe below resolved it.

### Pre-create + import (k3s pool — worked example)

**1. Create both containers on their target nodes as root@pam:**

```bash
# k3s-1 — pve5, VMID 119
ssh root@pve5.local
pct create 119 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname k3s-1 --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores 4 --memory 6144 --swap 0 \
  --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --nameserver 192.168.139.1 --searchdomain local \
  --ostype debian --onboot 1
pct start 119

# k3s-2 — pve4, VMID 122
ssh root@pve4.local
pct create 122 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname k3s-2 --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores 4 --memory 6144 --swap 0 \
  --rootfs local-lvm:24 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --nameserver 192.168.139.1 --searchdomain local \
  --ostype debian --onboot 1
pct start 122
```

**2. Import both containers into state** (run from `terraform/` with credentials
set):

```bash
terraform import 'proxmox_virtual_environment_container.k3s["k3s-1"]' pve5/119
terraform import 'proxmox_virtual_environment_container.k3s["k3s-2"]' pve4/122
```

**3. Verify plan, then push and merge.** The CI apply reconciles without 403 —
the containers already exist, so no create is attempted.

### Post-import normalization

The first CI apply after import writes provider defaults for `client_timeout_*`
fields and the `console` block (`cmode: tty`, `console: 1`, `tty: 2`) into the
live config. Both equal PVE's implicit defaults — no behavior change, no restart
— and settle to a clean plan on the following apply. Same pattern as the phase-1
LXC imports; see § Import gotchas.

### Forward: encoding as `import {}` blocks

The `import {}` block approach (used in `lentago/.github`'s settings module)
would let the `.tf` itself carry the import and remove the separate operator
step. Not implemented — record here if a third feature-flagged container
prompts the investment.

## VM import notes (learned in phase 3)

- **`reboot_after_update = false` on every imported VM.** The first apply
  after import reconciles computed defaults; this flag guarantees such a
  write can never reboot a running guest. Verified: HAOS stayed up through
  its import.
- **First apply re-encodes SMBIOS.** Declaring `smbios { uuid = … }` makes
  the provider rewrite `smbios1` with a `base64=1` prefix (the UUID is
  unchanged; only the string encoding changes). Cosmetic, no reboot,
  converges to a clean plan. Keeping the `smbios` block is still correct —
  it pins the UUID so the VM is never seen as needing recreation.
- **Match live power state, don't fight it.** Set `started` to each guest's
  actual state (`false` for the stopped snapshot-reset testbeds) or Terraform
  will try to power them on.
- **Disk `file_format` must match the datastore.** `qcow2` for the file/dir
  store (`local`), `raw` for LVM-thin (`local-lvm`). A mismatch reads as a
  disk change.
- **HAOS specifics that must be reproduced or it plans a recreate:**
  `bios = "ovmf"` + `efi_disk {}`, `scsi_hardware = "virtio-scsi-pci"`, both
  `usb { host = … }` radios, and the disk `discard`/`ssd` flags. Its verbose
  installer `description` is `ignore_changes`d rather than reproduced.
