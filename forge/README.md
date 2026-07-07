# Image forge

Kalmia is the Lentago Labs provisioning system, and this is its **build side**:
versioned machine images that consumers deploy from. Where the Ansible layer
configures what's *inside* a running machine and the Terraform layer declares
which guests *exist*, the forge produces the **artifacts those guests are cut
from**.

The image is the **contract** between kalmia and a consumer. A consumer pins a
version and boots it; it never reaches into this repo's internals. That
boundary is where the fleet's agnosticism principle earns its keep — the same
recipe can target more than one substrate, and adding a target does not disturb
the ones already shipping.

## Image classes (roadmap)

| Class | First artifact | Status |
|---|---|---|
| **runner** | `claytonia-runner` — bullpen worker LXC template | **shipping** (`runner/`) |
| container | (generic OCI/LXC base) | future |
| server / VM | Proxmox VM template, later an AMI | future |
| workstation | the Ansible profiles (repo root) | existing, pre-forge |

## Design — two-layer recipe

A runner image is built in two layers, each with a single owner, so the forge
never duplicates — and therefore never drifts from — the runner software:

1. **Substrate (kalmia-authored).** The OS-level contract: base packages, the
   `claude` service user, Claude Code, the gh CLI, empty secret placeholders,
   and first-boot de-templating. It is `runner/substrate.sh`. This *is* what the
   image guarantees, so kalmia owns it; it was derived once from claytonia
   `provision/01`+`03` and is deliberately scoped to only what the runtime does
   **not** manage.

2. **Software (claytonia-owned, referenced not copied).** The runner itself —
   `bin/`, systemd units, cron, `runner.env` — is deployed by claytonia's own
   `gitops/install.sh`, which the build runs against a claytonia checkout. The
   image ships claytonia's real gitops loop, installed and enabled; the worker
   then self-updates from claytonia `main` every 5 minutes.

The consequence worth stating plainly: **the runner software is "always main" by
claytonia's gitops design.** An image can't meaningfully pin it — a booted
worker converges to `main` within one poll regardless. So an image *version*
tracks the **substrate** (OS, Claude Code, gh, package baseline), which is
exactly what an image should version. The software is a runtime concern, and it
stays claytonia's.

Never baked, on principle: secrets (the OAuth token, the GitHub App key,
Grafana credentials), and shared NAS runtime state (the job queue, the project
registry). See `runner/README.md` § What the image guarantees.

## Tooling — why `pct` capture, not Packer (yet)

The candidates were Packer, distrobuilder, mkosi, and a script-plus-`pct`
capture. The decision was **script + `pct` capture** (`runner/build.sh`), for
reasons that are specific and, we think, will age well:

- **The portable asset is the recipe, not the packager.** `substrate.sh` is a
  standalone POSIX-ish shell script and the software layer is claytonia's
  curl-able `gitops/install.sh`. A future AMI target reuses both verbatim under a
  Packer `amazon-ebs` builder's `shell` provisioner; an OCI target reuses them in
  a `Containerfile`. Only the per-target **wrapper** changes. That is the
  agnosticism test met at the layer that matters — adopting a heavier tool now
  would not make the recipe any more portable than it already is.

- **Packer has no first-class Proxmox-LXC-template builder.** Its Proxmox
  builders produce QEMU VMs; there is no clean path from Packer to a Proxmox
  `vztmpl`. Adopting Packer for the *one* target we build today would mean
  fighting it, for no portability gain the shell recipe doesn't already provide.

- **The build needs a real container.** Claude Code's native installer and the
  gh apt repo want a booted userspace, not a chroot — which a throwaway LXC
  gives directly and cheaply.

- **distrobuilder** is the purpose-built LXC image tool but is container-only
  (no AMI), and **mkosi** spans both but adds real complexity with no
  first-class vztmpl story. Neither buys more than the shell recipe already has.

When a cloud runner becomes real (gated by the off-LAN queue-transport question,
claytonia#47 — not by the image), the AMI builder is a Packer config invoking
the same `substrate.sh`. This directory is structured for that: the recipe is
target-agnostic; `build.sh` is the LXC target's wrapper, and a sibling wrapper
is where the next target lands.

## Building

See `runner/README.md` for the one-command build, the publish/retention model,
and the operational gotchas (notably the Firewalla new-guest block).
