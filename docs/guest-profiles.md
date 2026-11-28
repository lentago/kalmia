# Guest profiles — target configuration per guest class

Every guest on `homelab-cluster` belongs to one **class**, and each class has a
**target profile**: the value every PVE attribute should have on a guest of that
class, and why. [ADR-0007](adr/0007-guest-profiles.md) records the decision to
work this way. The per-guest comparison of live config, Terraform and target is
in [`guest-profiles-gaps.md`](guest-profiles-gaps.md).

Inputs (all lentago/kalmia unless noted): #367 (this work), the per-VM fixes
#354, #356, #357 and #361, the xubuntu-ws assessment on #361, #358 (testbeds),
#365 (`md-clear`/`ssbd`), #366 (pve5 NVMe and thin pool), #350 (Firewalla
reservations) and #325 (pve3 NVMe stalls). The live inventory is the
2026-11-28 `qm config`/`pct config` dump in #367.

Wherever a target is "PVE default", that is a deliberate choice: the default
fits the class's purpose. Where Terraform leaves an attribute unset and the
provider treats it as computed, drift in that attribute is invisible to the
plan. The gap table marks those rows **codify-only**.

## Classes

The classes proposed in #367 were checked against each guest's purpose
(resource comments in `terraform/*.tf`, `docs/*.md`, the linked issues). One
guest moves:

| Class | Guests | Purpose | Owner |
|---|---|---|---|
| Interactive workstation VM | 102 xubuntu-ws, 104 fedora-ws (parked) | A persistent desktop/dev host where people and Claude sessions work all day | kalmia |
| Appliance VM with hardware passthrough | 100 haos | A vendor OS image bound to physical radios on one node, mission-critical at home | kalmia |
| Disposable test VM | 120 xubuntu-test, 121 fedora-xfce-test | Reset to a `pristine` snapshot between provisioning runs ([`testbed.md`](testbed.md)) | kalmia |
| CI runner LXC | 115 gha-runner, **123 pe-publish**, 124 minecraft-runner, 126 minecraft-runner-2, 127 minecraft-runner-3 | Run GitHub Actions jobs; rebuildable from template + playbook | kalmia |
| Agent worker LXC | 110 – 112, 116, 117 (claude-runner 1 – 5) | Headless Claude workers taking queued jobs | **claytonia** (profile defined here, codified in lentago/claytonia `terraform/`) |
| Service LXC | 105 grafana-stack, 113 n8n, 114 pub, 118 brasenia, 125 minecraft-lan, 128 kiosk-sim | A long-running LAN service other things depend on | kalmia |
| Cluster-node LXC | 119 k3s-1, 122 k3s-2 | A member of the osmunda k3s cluster | kalmia |

**Change from #367:** CT 123 `pe-publish` moves from *Service* to *CI runner*.
It is a self-hosted GitHub Actions runner (label `pe-publish`,
[`pe-publish.tf`](../terraform/pe-publish.tf)) whose only job is a workflow run
on push. It serves nothing, holds no state the pipeline can't rebuild, and has
the same mount-hook shape as the minecraft runners.

Kept, with notes:

- **115 gha-runner** stays in *CI runner*, although it runs this repo's own
  Terraform apply. Its profile is the class's. The one extra fact (a
  self-replace mid-apply needs manual recovery) is already in
  [`terraform/README.md`](../terraform/README.md#destroy-guards--which-guests-carry-prevent_destroy-50).
- **128 kiosk-sim** stays in *Service*, though it is disposable. It serves a
  page on the LAN. Being disposable only changes how it is rebuilt (it
  carries no `prevent_destroy`), not its profile.
- **105 grafana-stack** stays in *Service*: it ships metrics for drosera.

## Profiles — VMs

Columns: **Target** is the value every guest of the class should have;
**Reason** ties it to the class's purpose. "Sized per guest" means the class
fixes the rule, and the gap table holds each guest's number.

### Interactive workstation VM — 102, 104

| Attribute | Target | Reason |
|---|---|---|
| CPU model | `Broadwell-noTSX-IBRS` | A superset of x86-64-v3 (AVX2/BMI/FMA for ripgrep, zstd, numpy) that adds PCLMULQDQ (8× AES-GCM) and PCID (cheaper syscalls under PTI). It starts with `enforce` on every node, so a cold start elsewhere shows the same CPU (#354, #361) |
| CPU flags | `+md-clear;+ssbd` | Lets the guest kernel mitigate MDS and Spectre v4 for its own user space, where package installs and agent sessions run all day (#365, in flight) |
| Cores / sockets | 1 socket, cores sized per guest (102: 6, 104: 4), at most the node's 6 cores | pve5 is a single-socket, non-SMT i5-8500T; one socket keeps the guest topology true to the host (#286, #356) |
| NUMA | off (PVE default) | Single-socket host; NUMA is only needed for CPU/memory hotplug, which this class doesn't use |
| Memory | sized per guest (102: 16 GiB, 104: 8 GiB), counted in full in the node budget | A workstation's working set is the whole allocation; the pve5 budget (below) assumes it is resident |
| Balloon | `floating` = `dedicated` (balloon device present, never inflated) | The same behaviour as PVE's default (no `balloon` line), but visible to Terraform, which reads "unset" and `balloon=0` alike as `floating = 0`. The device reports guest-side usage to PVE. 102's live `balloon=0` is a **decision** (gap table) |
| Machine | `q35` | PCIe topology; what both guests were installed on |
| BIOS | SeaBIOS (PVE default) | Both are installed BIOS-boot. Moving to OVMF needs an EFI disk and a bootloader change and buys a desktop nothing |
| `scsihw` | `virtio-scsi-single` | One controller per disk, which `iothread` needs |
| Disk `iothread` | on | Moves disk I/O off QEMU's main loop, so a slow write can't stall the vCPUs |
| Disk `aio` | `io_uring` (PVE default) | The fastest path on PVE 9 with `cache=none` |
| Disk `cache` | `none` (PVE default) | Bypasses the host page cache; the guest caches. Safe on thin LVM |
| Disk `discard` | on | Returns freed blocks to the overcommitted thin pool (#366) |
| Disk `ssd` | on | The guest sees its NVMe-backed disk as non-rotational, which picks the right I/O scheduler (#354) |
| Disk `backup` | on (PVE default) | The disk is the workstation's state |
| Disk `replicate` | on (PVE default) | Inert: the cluster has no replication jobs. No reason to diverge from the default |
| NIC model | `virtio` (PVE default for Linux) | Paravirtual, no emulation cost |
| NIC `firewall` | on (as live) | Keep as is. The flag only does anything if the PVE firewall is enabled for the datacenter, which the inventory doesn't show (question in the PR) |
| NIC multiqueue | off (PVE default) | Interactive SSH/git/HTTP traffic doesn't saturate one queue. Changing `queues` hot-unplugs the NIC |
| Guest agent | on | vzdump's freeze/thaw for `workstation-daily`; PVE reads IPs and can run fstrim |
| Agent `fstrim_cloned_disks` | off (PVE default) | Fires only after a clone or disk move. Routine trim is the guest's `fstrim.timer`, set in the Ansible layer (#366 ask 3) |
| `onboot` | per guest: 102 on, 104 off | 102 is the always-on primary workspace. 104 is parked; autostarting it would overcommit pve5 (#356) |
| `startup` | PVE default (no order) | Nothing on pve5 depends on a workstation's start order |
| `protection` | on | Import-only guests whose disks hold unrecoverable state. PVE's flag blocks removing the VM or its disks from the UI and CLI, as `prevent_destroy` does for Terraform. Clear it first for a deliberate `qm disk move` (§ Protection) |
| `tags` | `class-workstation`, `kalmia` | See § Class tags |
| `vga` | `std` (PVE default) | noVNC console for a desktop; no GPU passthrough |
| `tablet` | on (PVE default) | Absolute pointer in the noVNC console |
| `hotplug` | `network,disk,usb` (PVE default) | Online disk resize (used for #286). No CPU/memory hotplug: it needs NUMA and changes the topology |
| RNG device | none (PVE default) | Broadwell passes RDRAND/RDSEED, and the guest kernel's entropy pool doesn't block |
| Power | `started` ignored | Power is operator-driven in both directions (#38, #356) |

### Appliance VM with hardware passthrough — 100

| Attribute | Target | Reason |
|---|---|---|
| CPU model | `Broadwell-noTSX-IBRS` | HAOS add-ons and wheels target x86-64-v2/v3; AES-NI + PCLMULQDQ for TLS on 2 vCPUs. The same guest CPU if the radios ever move (#357, #361) |
| CPU flags | `+md-clear;+ssbd` | HAOS runs third-party add-ons (#365, in flight) |
| Cores / sockets | 1 socket, 2 cores | Home Assistant idles at well under 2 cores, and pve3's other 4 cores go to CT 127 |
| NUMA | off (PVE default) | As for workstations |
| Memory | 8 GiB | Current sizing; no evidence of pressure |
| Balloon | `floating` = `dedicated` (8192) | Codifies what is live (no `balloon` line); see the workstation row |
| Machine / BIOS | `q35` / `ovmf` with a 4m EFI disk | The HAOS image is UEFI-only |
| `scsihw` / `iothread` | `virtio-scsi-single` / on | Keeps a pve3 NVMe stall from freezing the vCPUs (#357, #325) |
| Disk `aio` / `cache` | `io_uring` / `none` (PVE defaults) | As for workstations |
| Disk `discard` | on | Thin-pool reclaim. #325 lists discards as a *suspected* stall trigger; revisit there if its evidence lands, not here |
| Disk `ssd` | on | Non-rotational to the guest |
| Disk `backup` / `replicate` | on / on (PVE defaults) | `haos-4h` backs it up; replication is inert |
| NIC | `virtio`, `firewall` off (as live), no multiqueue | Home Assistant's discovery is multicast-heavy (mDNS, SSDP, Matter). Keep the NIC off the firewall bridge, as it is today |
| Guest agent / trim | on / off | HAOS ships the agent; vzdump freezes the filesystem |
| `onboot` | on | Power is enforced desired state (`started` not ignored) |
| `startup` | `order=1` | First guest on pve3 after a node boot, ahead of CT 127. That shortens the home-automation outage, the one outage people at home notice |
| `protection` | on | Import-only, hardware-pinned |
| `tags` | `class-appliance`, `kalmia` | |
| `vga` / serial | `std` (PVE default) plus `serial0` | `serial0` is the HAOS console |
| `tablet` | off | Headless; drops an emulated USB device |
| `hotplug` | `network,disk,usb` (PVE default) | |
| USB | `303a:831a`, `303a:4001` by vendor:product | The radios; the reason VM 100 never migrates |
| RNG device | none (PVE default) | As for workstations |
| Node | pve3 only, never migrate | Restart only with a cold `qm reboot 100` on pve3, just after a `haos-4h` backup |

### Disposable test VM — 120, 121

**Every config change to this class lands with a re-taken `pristine`**
(#358): `qm rollback … pristine` restores the snapshot's config, so a change
applied alone is undone by the next test run and shows as drift.

| Attribute | Target | Reason |
|---|---|---|
| CPU model / flags | `Broadwell-noTSX-IBRS`, `+md-clear;+ssbd` | A provisioning test must see the same instruction set as the workstations it stands in for (#358) |
| Cores / sockets | 1 socket, 2 cores | A provisioning run, not a workload |
| NUMA | off (PVE default) | |
| Memory / balloon | 4 GiB, `floating` = 4096 | Codifies the live default balloon; see workstations |
| Machine / BIOS / `scsihw` | `q35` / SeaBIOS / `virtio-scsi-single` | Mirror the workstations they test |
| Disk `iothread`, `aio`, `cache` | on, `io_uring`, `none` | Mirror the workstations |
| Disk `discard` / `ssd` | on / on | Mirror the workstations. The only blocker was the rollback revert, which the re-taken `pristine` removes (#358) |
| Disk `backup` | on (PVE default; `guests-weekly`) | vzdump doesn't carry snapshots, but a stopped, rolled-back testbed's backup *is* the pristine baseline: its only off-node copy |
| Disk `replicate` | on (PVE default) | Inert |
| NIC | `virtio`, `firewall` on (as live), no multiqueue | Mirror the workstations |
| Guest agent / trim | on / off | The `pristine` image carries `qemu-guest-agent` ([`testbed.md`](testbed.md)) |
| `onboot` | off | Power belongs to the test loop |
| `startup` | PVE default | |
| `protection` | on | Disks and `pristine` snapshots are unrebuildable (`prevent_destroy`). PVE's flag doesn't block `qm rollback`. It does block `qm disk move`, so a #366 move clears it first |
| `tags` | `class-testbed`, `kalmia` | |
| `vga` / serial | `std`, 16 MiB, plus `serial0` (as live) | A serial console for headless runs, plus a display for desktop checks |
| `tablet` / `hotplug` / RNG | PVE defaults (on / `network,disk,usb` / none) | |
| Power | `started` ignored | An apply must never stop a testbed mid-run |
| Node | pve5 today; **pending #366** | #366 decides whether the testbeds and their snapshots move off pve5's 81.5%-full pool (to pve's unused `vmdata` ZFS pool or pve4) |

## Profiles — LXCs

Baseline for every LXC class unless a class says otherwise:

| Attribute | Target | Reason |
|---|---|---|
| `unprivileged` | 1 | UID-shifted, no direct host-root escape. Every guest here is unprivileged today |
| `features` | `nesting=1` only | systemd and user namespaces in an unprivileged Debian guest. Anything else (`keyctl`, `fuse`, `mknod`) is root@pam-only ([README § Rails](../terraform/README.md#rails--non-nesting-feature-flags-require-rootpam-pre-create)), which makes the guest import-only. Use it only when the workload needs it |
| `cpulimit` | 0 (PVE default, unlimited) | `cores` caps parallelism. Relative priority comes from `cpuunits`, which doesn't waste idle CPU |
| `cpuunits` | 100 (PVE default on cgroup v2), written out explicitly | Unset is computed in the provider, so drift would be invisible |
| `swap` | 512 MiB (PVE default) | Headroom for an occasional spike without OOM |
| Rootfs mount options | none (PVE default) | Trim is the nightly `pct fstrim` timer ([`pve-host.md`](pve-host.md)). It batches discards instead of issuing one per delete, and per-delete discards are the suspected stall trigger in #325 |
| Mount points | NAS bind mounts only; `ro=1` wherever the guest only reads; no volume mount points | Guest state that matters lives on the NAS. vzdump never includes bind mounts, so the `backup` flag doesn't apply. Token-created guests get them from the mount hook; import-only guests from root@pam |
| `onboot` | 1 | Every LXC is a standing service or worker |
| `startup` | PVE default (no order) | No LXC depends on another's start order. PVE starts ordered guests first, then the rest |
| `protection` | 0 (PVE default) | On a CT the flag blocks every rootfs and `mpN` update, so it would break Terraform's rootfs resizes and the mount hook (§ Protection). `prevent_destroy` guards the import-only CTs in Terraform |
| Addressing | static IP in Terraform: below the Firewalla DHCP pool (.2 – .9) if free, else in the pool with a Firewalla reservation for the pinned MAC, recorded in the `.tf` comment | Other things address these guests by IP. An in-pool static IP without a reservation can be leased away while the guest is down (#350) |
| MAC | pinned in Terraform | The Firewalla's device identity, quarantine approval and reservation follow the MAC across a rebuild ([README § Runner notes](../terraform/README.md#runner-notes-lxc-115)) |

### CI runner LXC — 115, 123, 124, 126, 127

| Attribute | Target | Reason |
|---|---|---|
| `features` | `nesting=1` | Baseline. No runner uses Docker |
| Cores | sized per workload: 2, or 4 for the Chunker runners (124, 126, 127) | Job parallelism |
| `cpuunits` | **50** | Batch work yields to services, k3s and HAOS when a node is contended: pve4 carries 16 LXCs on 6 cores, and CT 127 sits beside HAOS on pve3. An idle runner costs nothing either way |
| Memory / swap | sized to the job's peak: 10 GiB + 1 GiB swap for Chunker (`-Xmx6G` plus BDS), else 1 – 2 GiB + 512 MiB | |
| Rootfs | sized to the job workspace | |
| Mount points | hook-attached, per the guest's mount map | [README § Bind mounts](../terraform/README.md#bind-mounts--the-mount-hook) |
| `tags` | `class-ci-runner`, `kalmia` | |
| Node | pve4, with at least one minecraft runner on another node (127 on pve3) | One node down mustn't take every runner of a label |
| Backups | **decision:** exclude from `guests-weekly` | Rebuildable from template + playbook; job state lives in GitHub and on the NAS |

### Agent worker LXC — 110 – 112, 116, 117 (claytonia)

Owned by lentago/claytonia (ADR-0005). The profile is defined here, and the
PR for this doc lists the pool's gaps for filing there.

| Attribute | Target | Reason |
|---|---|---|
| `features` | `nesting=1` | Baseline |
| Cores / memory / swap / rootfs | 2 / 4 GiB / 512 MiB / 20 GiB (claytonia's module defaults) | One headless Claude session plus its tools |
| `cpuunits` | **50** | As for CI runners: batch agent work yields to pve4's services and k3s-2 |
| Mount points | `mp0` = `/mnt/neptune-lentago/claude-jobs` → `/srv/jobs`, rw, root@pam-attached | The job queue lives on the NAS |
| `tags` | `class-agent-worker`, `claytonia` | |
| Node | pve4 (claytonia's `node_name`) | |
| Backups | **decision:** exclude from `guests-weekly` (a kalmia job) | Rebuildable from the image; state is on the NAS |

### Service LXC — 105, 113, 114, 118, 125, 128

| Attribute | Target | Reason |
|---|---|---|
| `features` | `nesting=1`; plus `keyctl=1` only for Docker hosts (113) | Docker-in-LXC needs the kernel keyring |
| Cores / memory / swap / rootfs | sized per guest (gap table); swap 512 MiB, or 256 MiB on a 512 MiB guest (128) | |
| `cpuunits` | 100 (PVE default, explicit) | Services keep full weight against batch classes |
| Mount points | 114: root@pam bind mounts (import-only); 125: one hook mount, `ro=1` | |
| `tags` | `class-service`, `kalmia` | |
| Node | pve4, except 105 on pve5 | |
| Backups | `guests-weekly` | Services hold state (n8n workflows, Grafana config, worlds on 125) |

### Cluster-node LXC — 119, 122

| Attribute | Target | Reason |
|---|---|---|
| `features` | `nesting=1,keyctl=1` | containerd runs nested and its snapshotter needs the keyring ([`k3s.tf`](../terraform/k3s.tf)). This makes the nodes root@pam pre-create + import |
| Cores / memory | 4 / 6 GiB | Current sizing |
| `cpuunits` | 100 (PVE default, explicit) | |
| Swap | **0** | kubelet wants swap off |
| Rootfs | 24 GiB, no mount points | Cluster storage is in-guest |
| `tags` | `class-k8s-node`, `kalmia` | |
| Addressing | a **stable** address — **decision**: a Firewalla reservation on the DHCP lease, or a static IP | The node IP is part of a k3s node's identity, and a changed lease after a reboot breaks the join |
| MAC | pinned | Today the MAC is computed, so a rebuild gets a new one and a new lease |
| Node | anti-affinity: one node per PVE host (119 on pve5, 122 on pve4) | Losing one host mustn't take the pair down |
| Backups | `guests-weekly` | |

## Cross-cutting policies

### Backup job membership and retention

The three jobs live in [`backup-jobs.tf`](../terraform/backup-jobs.tf). All
write to `neptune`, in snapshot mode with zstd.

| Job | Schedule | Retention | Members by class |
|---|---|---|---|
| `haos-4h` | every 4 h | last 12, daily 7, weekly 4, monthly 3 | Appliance (100) |
| `workstation-daily` | 02:00 | daily 7, weekly 4, monthly 3 | Primary workstation (102) |
| `guests-weekly` | Sun 03:00 | weekly 4, monthly 3 | `all` minus `exclude`: the parked workstation (104), testbeds, services, cluster nodes, **and today also every CI runner and agent worker** |

**Proposed (decision needed):** add the CI runners (115, 123, 124, 126, 127)
and agent workers (110 – 112, 116, 117) to `guests-weekly`'s `exclude`. They
are rebuildable from a template plus a playbook (or the forge image), and keep
their state in GitHub and on the NAS. That is ten weekly dumps, of 224 GiB of
provisioned rootfs, that restore nothing a rebuild doesn't. `all` + `exclude` stays the
pairing, so a new guest is backed up by default.

### Node placement and affinity

`ha-manager` is deliberately unused, so placement is just `node_name`. Every
disk is on node-local `local-lvm`, so a move is an offline migration.

| Node | Role |
|---|---|
| pve (i7-5557U, SMT, 15.5 GiB) | No guests. Its `vmdata` ZFS pool is a candidate home for the testbeds (#366) |
| pve2 (i3-6100U, SMT, 7.6 GiB) | Quorum vote only. Never place guests |
| pve3 (i5-8500T, 31.1 GiB) | HAOS, pinned. At most one batch CT beside it (CT 127). No write-heavy guest while #325 is open |
| pve4 (i5-8500T, 31.1 GiB) | The LXC host: services, CI runners, agent workers, k3s-2 |
| pve5 (i5-8500T, 31.1 GiB) | Workstations, testbeds (pending #366), grafana-stack, k3s-1 |

Affinity rules: the k3s nodes on different hosts; the minecraft runners not all
on one host; HAOS never leaves pve3.

### Per-node capacity budget

**Memory.** The figures are from #367 (2026-11-28). VM memory counts in full:
with `floating = dedicated` nothing is reclaimed. LXC `memory` is a cgroup
cap, not a reservation.

| Node | VM memory that can run | LXC limits | Physical | In use |
|---|---|---|---|---|
| pve3 | 8 GiB (100) | 10 GiB (127) | 31.1 GiB | 6.9 GiB |
| pve4 | — | 60.5 GiB (1.95× RAM) | 31.1 GiB | 5.6 GiB |
| pve5 | 16 (102) + 8 (104) + 8 (120, 121) = 32 GiB | 8 GiB (105, 119) | 31.1 GiB | 17.4 GiB |

Proposed rules:

1. **VMs fit in RAM.** The VM memory of every guest that can run at the same
   time, plus the LXCs' in-use memory, plus 4 GiB for the host, must stay at
   or under physical RAM. On pve5 that allows 102 plus *one* of {104, the
   testbed pair}, never both. `vms.tf` already says so for 104.
2. **LXC caps ≤ 2× RAM per node** (proposal). pve4 is at 1.95×, so a new pve4
   LXC needs a move or a resize first.

**Thin pools.** Figures are from #366. **All ceilings below are proposals
pending #366's trim experiment** (`fstrim` in xubuntu-ws, then re-measure pve5
writes):

| Node | `pve/data` used | Virtual size on it | Overcommit |
|---|---|---|---|
| pve3 | 13.6 % | ~64 GiB (100: 32 + EFI, 127: 32) | pool size not in the inventory (question in the PR) |
| pve4 | 39.1 % | ~266 GiB of rootfs (16 CTs) | pool size not in the inventory (question in the PR) |
| pve5 | 81.5 % of 155.7 GiB | ~254 GiB before snapshots | ~163 % |

- **Used ceiling: 70 %**, steady state after a trim. That stays below the 80 %
  autoextend trigger ([`pve-host.md`](pve-host.md)) with a week of writes to
  spare, and keeps free space for the drive's SLC cache, which is #366's
  hypothesis for pve5's slow writes. pve5 is over it.
- **Overcommit ceiling: 150 %** of pool size, counting snapshots. pve5 is over
  it. No new or grown disk on pve5 until #366 decides where the testbeds go.

### `ignore_changes`, and why

| Attribute | On | Why |
|---|---|---|
| `started` | VMs 102, 104, 120, 121 | Power is operator- or test-loop-driven. HAOS and every LXC keep enforced power: restarting those is desired state |
| `operating_system` | every LXC | `template_file_id` is create-only and can't be reconciled on an imported guest |
| `initialization[0].user_account` | every kalmia LXC | ForceNew. The dev-host key reaches only created or rebuilt guests (#337) |
| `mount_point` | 114 and the hook-mounted CTs (123 – 127) | Bind mounts are root@pam-only; the token would get HTTP 403. The mount map and the node allowlist are the source of truth |
| `pool_id` (claytonia) | agent workers | claytonia's own choice |

Rule: add an entry only for a create-only/ForceNew field the token can't
reconcile, or for state another actor owns, and always with a comment.

Live state Terraform **cannot** see, even with every attribute set:

- VM balloon: the provider reads an absent `balloon` and `balloon=0` both as
  `floating = 0`. That is why the profiles set `floating = dedicated`.
- VM `localtime`: not in the VM resource schema (v0.115.0). It was removed
  from HAOS by hand (#357).
- LXC `host-managed=0` on `net0` (newer guests): not modelled.
- The k3s host-side `lxc.*` accommodations ([`k3s.tf`](../terraform/k3s.tf)).
- Firewalla DHCP reservations (#350).
- Bind mounts on resources with `ignore_changes = [mount_point]`.

### Protection

PVE's `protection` flag is checked in these places (qemu-server
`API2/Qemu.pm`, pve-container `LXC/Config.pm`, read 2026-11-28):

- **VM:** removing the VM, removing a drive or an unused disk, restoring a
  backup over it, and **moving its disks**. Snapshot rollback isn't checked.
- **CT:** removing the CT or a drive, and **any update of `rootfs` or an
  `mpN`** (`can't update CT … drive`).

So the two guest types get different targets:

- **VMs: on for every import-only VM** (100, 102, 104, 120, 121). It guards
  the disks against a UI or CLI removal that `prevent_destroy` can't see. A
  deliberate disk move (for example a testbed move under #366) clears the flag
  in the same change.
- **CTs: off (PVE default) for all.** The provider sends `rootfs` on every
  disk update, including a size grow, and the mount hook runs `pct set mpN`.
  Both would fail on a protected CT. `prevent_destroy` stays the guard for
  import-only CTs.

### Class tags

Each guest carries two PVE tags: its class and its owner.

| Class | Tags |
|---|---|
| Interactive workstation VM | `class-workstation`, `kalmia` |
| Appliance VM | `class-appliance`, `kalmia` |
| Disposable test VM | `class-testbed`, `kalmia` |
| CI runner LXC | `class-ci-runner`, `kalmia` |
| Agent worker LXC | `class-agent-worker`, `claytonia` |
| Service LXC | `class-service`, `kalmia` |
| Cluster-node LXC | `class-k8s-node`, `kalmia` |

The class shows in the PVE tree, and `grep -l class- /etc/pve/nodes/*/{qemu-server,lxc}/*.conf`
finds every classified guest. Tags are PVE fast-plug options: they apply live
on a running VM or CT. The provider sends them without rebooting
(bpg/proxmox v0.115.0, `vmUpdate`/`containerUpdate`).

## Apply behaviour reference (bpg/proxmox v0.115.0)

Read from the provider source (`proxmoxtf/resource/vm/vm.go`,
`proxmoxtf/resource/container/container.go`) and PVE's own hotplug code
(`qemu-server` `PVE/QemuServer.pm`, `pve-container` `PVE/LXC/Config.pm`).
Child issues cite this table.

**VMs.** Every kalmia VM sets `reboot_after_update = false`. When a change
needs a restart, the provider writes the config, emits a warning, and **never**
power-cycles the guest. On a stopped VM the change takes effect at once.

| Change | Provider | PVE, running VM |
|---|---|---|
| `tags`, `protection`, `startup`, `on_boot`, `description` | config write, no restart flagged | fast-plug: applies live |
| `memory.floating` with the balloon device's on/off state unchanged (unset → N) | flags a restart, never reboots, warns | balloon target is hot-applied. Whether PVE also queues the unchanged `memory` value as pending is **unknown**: check `qm pending` |
| `memory.floating` 0 → N (turns the balloon device on) | as above | pending until a cold restart (enabling the device isn't hotpluggable) |
| `cpu.*`, `vga`, `agent`, `boot_order`, `machine`, `bios`, `scsi_hardware`, `serial_device` | flags a restart, never reboots | pending until a cold `qm reboot` |
| Disk `discard`/`ssd`/`iothread`/`aio`/`cache` | written with the disk | pending (PVE skips these on a running disk) |
| NIC `firewall`/`bridge` | no restart | live. `model`/`queues`/`mac` hot-unplug and replug the NIC |

**LXCs.** The container resource has no `reboot_after_update`. A change
flagged as needing a restart makes the provider **reboot a running container**
at the end of the apply.

| Change | Provider | PVE, running CT |
|---|---|---|
| `tags`, `protection`, `startup`, `start_on_boot`, `description` | config write, no reboot | fast-plug: applies live |
| `cpu` (`cores`, `units`, `limit`) | config write, no reboot | live (cgroup weight/quota; cores fast-plug) |
| `memory` (`dedicated`, `swap`) | **reboots the container** | (would be live, but the provider reboots anyway) |
| `disk.size` grow | online resize, no reboot | live |
| `disk.mount_options` | **reboots the container** | |
| `network_interface`, `initialization.ip_config`/`dns`/`hostname` | **reboots the container** | |
| `features` | config write, no reboot | pending until the next restart. Also root@pam-only on update (README § Rails) |
| `mount_point`, `initialization.user_account`, `unprivileged`, `node_name`, `operating_system.template_file_id` | **replacement** (ForceNew) | |

claytonia pins bpg/proxmox 0.111.1. Its `containerUpdate` flags the same
attributes for reboot as 0.115.0 (checked in the v0.111.1 source).
