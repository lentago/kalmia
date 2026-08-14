# Architecture decision records

This directory holds reconstructed architecture decision records (ADRs) for
the kalmia provisioning system. They were recovered on 2026-08-13 from this
repo's commit history, issue and pull-request threads, CLAUDE.md, the forge and
Terraform READMEs, and fleet-level session archives. The decisions themselves
predate this directory; the dates in each ADR header are the **original decision
dates**, not the reconstruction date. Where an alternative or claim comes
exclusively from fleet records and cannot be verified within this repo's commit
history, it is labelled accordingly.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [0001](0001-ansible-over-bash.md) | Ansible over more bash | Accepted | 2026-06-30 |
| [0002](0002-profile-facts-two-axes.md) | Profile + facts model on two orthogonal axes | Accepted | 2026-06-30 |
| [0003](0003-terraform-proxmox-guest-lifecycle.md) | Proxmox guest lifecycle under Terraform | Accepted | 2026-07-04 |
| [0004](0004-lan-apply-on-merge.md) | LAN apply-on-merge with self-hosted runner | Accepted | 2026-07-05 |
| [0005](0005-runner-pool-to-claytonia.md) | Release runner pool to claytonia | Accepted | 2026-07-07 |
| [0006](0006-image-forge-pct-capture.md) | Image forge: script + pct capture | Accepted | 2026-07-07 |
