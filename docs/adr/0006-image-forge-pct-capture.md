# ADR-0006: Image forge — script + pct capture

**Status:** Accepted (2026-07-07; reconstructed 2026-08-13)

## Context

The bullpen runner pool provisioning previously relied on hand-run shell scripts
(`provision/01`–`05` in the claytonia repo). Each new worker required a human to
run those scripts against a fresh LXC. This is not reproducible, not versioned,
and does not scale.

As kalmia gained a Terraform layer and the runner pool grew (PRs #34/#35 added
runners 4/5), the need for a versioned, one-command "cut a new worker from a known
baseline" artifact became clear. Issue #36 captured the requirement.

The artifact type is a Proxmox LXC template (`vztmpl`): a tarball that `pct
create` inflates into a live container. The output format is fixed by the
substrate (Proxmox), but the tooling that produces it is not.

Four tooling candidates were evaluated:

- **Packer** — the industry-standard image builder; extensive community, many
  providers.
- **distrobuilder** — Canonical's purpose-built LXC/LXD image tool.
- **mkosi** — a modern image builder that targets containers and VMs.
- **Script + `pct` capture** — a shell substrate run inside a throwaway LXC,
  captured via `pct dump` to produce the `vztmpl`.

## Decision

**Script + `pct` capture** (`forge/runner/build.sh` + `forge/runner/substrate.sh`)
for the following reasons, all specific to the current build target (PR #42,
issue #36):

**The portable asset is the recipe, not the packager.** `substrate.sh` is a
standalone POSIX-ish shell script; the software layer is claytonia's curl-able
`gitops/install.sh`. A future AMI target reuses both verbatim under a Packer
`amazon-ebs` builder's `shell` provisioner. Only the per-target wrapper changes.
Adopting a heavier tool now would not make the recipe any more portable than it
already is.

**Packer has no first-class Proxmox LXC template builder.** Its Proxmox builders
produce QEMU VMs; there is no clean path from Packer to a `vztmpl`. Adopting
Packer for today's single target would mean fighting the tool for a format it
does not natively produce.

**The build needs a real, booted container.** Claude Code's native installer and
the `gh` apt repo want a booted userspace — package postinst scripts, systemd
unit activation, the GitHub CLI apt key verification. A chroot or layer-based
build cannot satisfy this without significant workarounds. A throwaway LXC
provides it directly and cheaply.

**distrobuilder** is purpose-built for LXC images but is container-only with no
AMI story. **mkosi** spans containers and VMs but adds complexity and has no
first-class `vztmpl` output. Neither buys more than the shell recipe provides.

**Two-layer design** (documented in `forge/README.md`):

1. **Substrate (kalmia-authored)**: `substrate.sh` — OS baseline, `claude` user,
   Claude Code, `gh` CLI, empty secret placeholders, first-boot de-templating.
   This is the image's contract; kalmia owns it.

2. **Software (claytonia-owned, referenced not copied)**: the runner's `bin/`,
   systemd units, cron, `runner.env` — deployed by claytonia's own
   `gitops/install.sh`, which the build runs against a claytonia checkout. The
   runner software is "always main" by claytonia's gitops design: a booted worker
   converges to claytonia `main` within one poll regardless of when the image was
   built. An image *version* therefore tracks the substrate (OS, Claude Code, `gh`
   baseline), which is what an image should version.

**Never baked**: secrets (OAuth token, GitHub App key, Grafana credentials), shared
NAS runtime state (job queue, project registry), and per-instance identity (SSH
host keys, machine-id — stripped at capture, regenerated per clone).

## Alternatives

**Packer** (evaluated and rejected, PR #42 / `forge/README.md`): No first-class
LXC template builder; the container build needs a real booted userspace that
Packer's Proxmox builders do not provide for LXC. For a future AMI target, a
Packer config invoking the same `substrate.sh` is the planned approach.

**distrobuilder** (evaluated and rejected, PR #42 / `forge/README.md`):
Purpose-built for LXC image production, but container-only — no AMI path.
Adds a tool-specific dependency for no portability gain over the shell recipe.

**mkosi** (evaluated and rejected, PR #42 / `forge/README.md`): Spans containers
and VMs, more general-purpose than distrobuilder. Adds real complexity; no
first-class `vztmpl` story. Neither buys more than the shell recipe provides.

**Containerfile/Dockerfile + rootfs extraction** *(retrospective — not considered
at the time)*: Build the runner image as an OCI container image and extract the
rootfs for LXC import. Technically feasible, and OCI tooling is widely available.
The build-time requirement for a booted userspace (Claude Code installer, `gh` apt
repo postinst) is not met by a standard Docker build context — it would require
`RUN` steps with workarounds for absent init systems. Assessed as **lateral** for
a straightforward LXC target; potentially useful if the build chain pivots to OCI
as a primary artifact format.

**Cloud-native image builder (e.g., EC2 Image Builder)** *(retrospective — not
considered at the time)*: Appropriate for AMI production and integrates with AWS
native pipelines. Not applicable to the LXC target. When the cloud runner target
becomes real (gated on the off-LAN queue-transport question, lentago/claytonia#47),
a cloud-native builder alongside the existing `substrate.sh` is the natural path.
Assessed as **lateral** for the future AMI target; **not applicable** for the
current LXC target.

## Consequences

- `forge/runner/substrate.sh` is kalmia's contract with claytonia: what the image
  guarantees to a consumer. Changes to it require a new versioned build.
- `forge/runner/build.sh` is the LXC target's wrapper; future targets (AMI, OCI)
  add sibling wrappers that invoke the same `substrate.sh` and claytonia's
  `gitops/install.sh`.
- Two issues surfaced and were fixed during the live first build (PR #42): a fresh
  claytonia clone had no git drift so the gitops poller would no-op the initial
  deploy (rewind one commit); and `postfix` (a `cron` recommend) ships chroot
  device nodes that break unprivileged-container extraction (drop via
  `--no-install-recommends` and exclude device nodes at capture).
- The runner software is intentionally not pinned in the image. A version tag
  tracks the substrate; the software is a runtime concern that claytonia governs.
