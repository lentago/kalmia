# `claytonia-runner` image

A versioned LXC template a bullpen worker is cut from. It replaces the hand-run
`provision/01–05` bootstrap in [claytonia](https://github.com/lentago/claytonia):
a new worker becomes `pct create` from this template + first-boot secrets +
gitops convergence, with no interactive per-box scripting.

Published as `<storage>:vztmpl/claytonia-runner-<version>.tar.zst` (default
storage `neptune`, LAN-wide).

## What the image guarantees (the contract)

**Substrate** — kalmia-authored, versioned by the image (`substrate.sh`):

- Debian 12 base + runner packages (`git jq ripgrep inotify-tools curl
  openssh-server tini cron python3 sudo less`).
- A `claude` service user (passwordless sudo) with an operator **public** SSH
  key authorized.
- **Claude Code** (native installer) at `/home/claude/.local/bin/claude`.
- The **gh CLI** (from GitHub's apt repo).
- Runner scaffold dirs and **empty secret placeholders** at `/etc/claude-runner/`.
- git bot identity + the GitHub-App credential helper wired for the `claude` user.
- A `forge-firstboot` unit that regenerates ssh host keys on first boot.

**Software** — claytonia's, installed by its own `gitops/install.sh` and enabled,
not copied here:

- `/opt/bullpen` — a claytonia checkout + `bullpen-gitops.timer` (pulls `main`,
  redeploys on drift every 5 min).
- The runner (`bin/`, the `claude-inbox`/`claude-heartbeat` pollers, cron,
  `runner.env`) force-deployed once so the image is runner-ready before its
  first poll. A booted worker converges to claytonia `main` regardless — the
  software is always-main by design; the image versions the substrate.

## What the image must never contain

- **Secrets.** The OAuth token, the GitHub-App private key + ids, and any
  Grafana push token are placeholders only (`token.env`, `gh-app.env`,
  `gh-app.pem` empty). They are injected at first boot, never baked.
- **Shared NAS runtime state.** The job queue and the project `registry.json`
  live on the NAS (`/srv/jobs`), not in the image — the build never mounts or
  writes them (claytonia `provision/04`'s registry step is deliberately not run).
- **Per-instance identity.** ssh host keys and `machine-id` are stripped at
  capture and regenerated per clone, so no two workers share host identity.

## Build

Run **as root on a PVE node** (the Proxmox API + `pct` are LAN-only). From a
kalmia checkout on the node, or by copying `forge/runner/` over:

```bash
./build.sh v1              # claytonia-runner-v1 from claytonia@main
./build.sh v1 --verify     # + instantiate and smoke-test the result
```

Tunables are environment variables (see the header of `build.sh`):
`CLAYTONIA_REF`, `BASE_TEMPLATE`, `BUILD_VMID` (throwaway, default 119),
`OUT_STORAGE`/`OUT_CACHE`, `RETAIN` (default 3). The build is idempotent-safe: it
refuses to overwrite an existing version, cleans up its throwaway container on
any exit, and writes the template atomically (`.partial` → rename) with a
`.sha256` sidecar.

What it does: creates a **privileged** throwaway LXC (so the captured rootfs has
0-based uids like a stock template — it is destroyed at the end), applies
`substrate.sh`, installs claytonia's gitops software layer, de-identifies, then
captures the rootfs to a `vztmpl` and prunes to the last `RETAIN` versions.

### Gotcha — Firewalla blocks fresh guests

A brand-new container's MAC lands in the Firewalla's Device Access Protection
`learning` state (default-block), so `apt`/installer egress fails. `build.sh`
detects this within 30s and tells you. Classify the device or force a FireMain
re-evaluation, then re-run. (Same gotcha the kalmia `terraform/README.md`
documents for new guests.)

## Consume (claytonia)

The pool's Terraform (`claytonia/terraform/`) sets the workers'
`template_file_id` — today the Debian base, switched to
`neptune:vztmpl/claytonia-runner-v1.tar.zst` once this ships (tracked as a
claytonia follow-up). New-worker scale-out then collapses to: add a map entry,
apply, attach the NAS mount + pool membership, inject secrets. First boot the
gitops loop takes over. `provision/01–05` become legacy/reference.

## Versioning

`vN` tracks the substrate (OS/Claude Code/gh/package baseline). Rebuild — a new
`vN` — when the substrate should move: a base-image bump, a new baked package, a
Claude Code pinning change. You do **not** rebuild for runner-software changes;
those ship through claytonia's gitops loop with no new image.
