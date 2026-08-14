# ADR-0004: LAN apply-on-merge with self-hosted runner

**Status:** Accepted (2026-07-05; reconstructed 2026-08-13)

## Context

The Proxmox VE API is LAN-only: GitHub-hosted runners have no path to it. The
Terraform layer (ADR-0003) is only useful as an enforced surface if `terraform
apply` runs automatically on merge — otherwise the live cluster drifts from the
code the moment a human forgets to apply manually.

Two additional concerns shaped the design:

1. **TLS trust**: the cluster serves a self-signed cert issued by its PVE Cluster
   Manager CA. The `bpg/proxmox` provider has no CA-file argument; `insecure =
   true` was the initial workaround (PR #27), but that suppresses all TLS
   verification for the PVE endpoint.

2. **Gate-check deadlock**: a required status check backed by a path-filtered
   workflow stays "Expected" on PRs that touch no matching files, blocking those
   PRs forever. The `gate` check pattern (an always-on synthetic job) was
   established at #41 to solve this.

## Decision

**`terraform apply` runs on every merge to `main` from LXC 115 `gha-runner`**
(`runs-on: [self-hosted, lan]`) — a Debian 12 LXC on pve4, created by this same
Terraform layer (PR #27). This makes the runner itself subject to the enforced
surface it enforces.

**The workflow structure** (PR #41): PRs trigger `validate` (fmt + validate, runs
on GitHub-hosted) and `plan` (posts the diff as a PR comment, runs on LAN
runner). Pushes to `main` trigger `validate` then `apply -auto-approve`. All
`plan`/`apply` jobs run on the LAN runner because they need PVE API access.
`apply` serializes under a `terraform-apply` concurrency group to prevent race
conditions on shared Proxmox state.

**The `gate` job** (PR #41) runs unconditionally on every PR and is the single
required status check. Heavy jobs (plan, apply) declare `needs: [gate]` and can
skip on docs-only PRs without deadlocking the gate itself (skipped dependencies →
gate still reports green).

**TLS — CA pinned, `insecure = false`** (issue #31, PR #32): the cluster's PVE
root CA certificate is committed at `terraform/pve-root-ca.pem` (a trust anchor,
no private key). Both run contexts set `SSL_CERT_FILE=<pve-root-ca.pem>` and
`SSL_CERT_DIR=/etc/ssl/certs` so Go's cert pool includes both the public roots
(needed for the S3 backend) and the PVE CA. `insecure = true` is removed.

**`terraform@pve` identity stays outside Terraform** (see ADR-0003 §
Consequences): managing the credentials Terraform authenticates with inside
Terraform itself would be circular — a bad apply could lock out the runner. The
identity stays a bootstrap concern. The token's RBAC role drops all identity- and
permission-management privileges.

**AWS state access via OIDC**: the `plan`/`apply` jobs assume
`arn:aws:iam::365184644049:role/kalmia-github-actions-terraform` using `id-token:
write` — no long-lived AWS keys in secrets. The role is scoped to this repo's S3
state key and lock table only.

**Public-repo hardening**: the `plan` job refuses PRs whose head repo is not
`lentago/kalmia`; the repo's Actions approval policy requires approval for all
external contributors; fork PRs receive no secrets and no OIDC.

## Alternatives

**Exposing the PVE API to GitHub-hosted runners** *(retrospective — not
considered at the time)*: This would require either opening the LAN API to the
public internet or running a VPN gateway. Exposing the PVE API publicly widens
the attack surface on the cluster's management plane; a VPN gateway introduces a
new credential (the VPN key) and operational dependency. The self-hosted runner is
already LAN-resident, so it solves the access problem with no new network
exposure. Assessed as **worse**.

**PR + manual apply (no automation)** *(retrospective — not considered at the
time)*: Require a human to run `terraform apply` after each merge. This works for
occasional changes but breaks the enforced-surface model: the live cluster drifts
the moment a human forgets or delays an apply. The "merge IS the deploy" discipline
is load-bearing for a system where the code and the live state must stay in sync.
Assessed as **worse**.

## Consequences

- LXC 115 `gha-runner` is kalmia-managed infrastructure: it is created by the
  same Terraform layer it executes. A rebuild requires re-registration via `gh api
  repos/lentago/kalmia/actions/runners/registration-token`; the procedure is in
  `terraform/README.md`.
- The Firewalla Device Access Protection `learning` state (default-block for new
  guests) blocked the runner's first GitHub access; this gotcha is documented in
  `terraform/README.md` for future LXC additions.
- `pve-root-ca.pem` is a committed public certificate. If the PVE CA is rotated,
  both `terraform/pve-root-ca.pem` and the copy at
  `~/.config/kalmia/pve-root-ca.pem` on the workstation must be replaced.
- kalmia's `terraform/` is an **enforced surface**: a `pvesh`/UI guest mutation
  without a corresponding code change is a violation of the model; the next apply
  will attempt to reconcile it.
