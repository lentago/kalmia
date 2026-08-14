# ADR-0003: Proxmox guest lifecycle under Terraform

**Status:** Accepted (2026-07-04; reconstructed 2026-08-13)

## Context

As kalmia's scope expanded beyond Ansible-on-workstations (issue #20), the
Proxmox guest layer — which VMs and LXCs exist, their resource allocation,
placement, and hardware config — was managed by hand via `pvesh` and the PVE
web UI. There was no audit trail of configuration changes, no plan-before-apply
preview, and no enforced surface.

The 2026-07-04 suite boundary decision (kalmia = local infra, solidago = cloud
infra) made kalmia the natural home for this layer: the guests run on a LAN
Proxmox cluster that solidago does not touch.

At import time, 11 live guests existed across two nodes (pve4 and pve5): service
LXCs, workstation VMs, testbed VMs, and one mission-critical VM (Home Assistant
OS, VM 100) that is USB-pinned to pve3 via Z-Wave/Zigbee/Matter radio
passthrough.

## Decision

**Guest existence and shape on `homelab-cluster` go under Terraform using the
`bpg/proxmox` provider** (`~> 0.111`, PVE 9.x compatible), with phased brownfield
import and an S3 state backend shared with the rest of the fleet.

**Import sequencing**: pve4 LXCs first (phase 1, PR #24), then pve5 workstations
and testbeds (phase 3, PR #29), then HAOS VM 100 last — the mission-critical
guest imported only after the rest of the cluster converges to a clean plan, and
given `lifecycle { prevent_destroy = true }` from day one. Phase 2 (PR #27)
inserted the apply-on-merge infrastructure between phases 1 and 3 so that phase 3
landed on an already-enforced surface.

**Power state asymmetry** (issue #38, PR #39): Terraform manages **shape, not the
power button** for pet VMs. Workstations (xubuntu-ws 102, fedora-ws 104) and
testbeds (xubuntu-test 120, fedora-xfce-test 121) get `lifecycle { ignore_changes
= [started] }` — operator- and test-driven momentary power state is not desired-
state enforcement. Service LXCs and HAOS VM 100 keep `started` enforced: a
stopped service guest is a failure to remediate, not an operator preference to
respect.

**`terraform@pve` identity is outside Terraform**: the least-privilege PVE user
and API token are created by a one-time, operator-run `pveum` block. Bringing
these credentials under Terraform management would be circular — a bad apply could
lock out the runner. Identity and ACL management stays a bootstrap concern. The
Terraform role drops the PVE 9 identity/permission-management privileges
(`Permissions.Modify`, `User.Modify`, `Realm.*`, `Group.Allocate`) — this token
manages guests, not users and ACLs.

## Alternatives

**Telmate provider** (per fleet records — recorded as rejected): The Telmate
`telmate/proxmox` provider is the older, widely-documented alternative to
`bpg/proxmox`. At the time of the decision, `bpg/proxmox` was assessed as better
maintained, more actively developed for PVE 9.x features, and with a cleaner
resource model. The Telmate provider was rejected on maintenance grounds.

**Hand-managed guests (no Terraform)** *(retrospective — not considered at the
time)*: Continuing with manual `pvesh`/UI management. The enforced-surface
discipline — "never mutate guests via pvesh/UI without codifying here in the same
session" — is the core argument against this: without Terraform, configuration
drift goes undetected and there is no plan-before-apply preview for destructive
changes. The `prevent_destroy` guard on HAOS VM 100 is a concrete example of a
safety rail that simply does not exist without IaC. Assessed as **worse**.

**Ansible `community.general.proxmox` module** *(retrospective — not considered
at the time)*: Ansible has a Proxmox module for LXC lifecycle and could have
extended kalmia's existing Ansible layer to cover guest existence. This loses the
plan/apply model: there is no "show me what will change before I commit" step with
Ansible against a live host. It also loses the state file, which is the mechanism
that lets `terraform state rm` + `import` move guest ownership cleanly between
repos (as demonstrated by the runner pool release in PR #40). Assessed as
**worse** for the guest-lifecycle use case.

## Consequences

- All 9 guests kalmia owns are under Terraform; the bullpen runner pool
  (VMIDs 110–112/116–117) was later released to claytonia's `terraform/` (#37,
  PR #40) without touching live guests.
- The phased import surfaced provider-specific gotchas: `operating_system`
  requiring `ignore_changes`, container `console` defaults written on first apply
  but not kept blockless, SMBIOS re-encoding on import, and disk `file_format`
  needing to match the datastore. These are documented in `terraform/README.md`.
- HAOS VM 100 is imported last and carries `prevent_destroy = true`. Its USB
  radio passthrough makes migration impossible; `ha-manager` is deliberately
  unused. Plans touching VM 100 get extra review.
- Kalmia's state key is `kalmia/terraform.tfstate` in the `solidago-tfstate-*`
  S3 bucket — the `solidago` prefix in the key is an artifact of the backend
  migration (#44, PR #45) and not worth churning.
