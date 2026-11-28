# ADR-0007: Per-class guest profiles

**Status:** Accepted (2026-11-28)

## Context

The guests on `homelab-cluster` reached Terraform from three directions: hand
builds, community-scripts installers, and resources this layer created. Each
was imported or written as it stood (ADR-0003). Terraform pinned what each
resource happened to set, and nothing said what a guest *should* look like.

Between 2026-11-27 and 2026-11-28 that showed up as a run of one-VM fixes, each
found by accident:

- xubuntu-ws (VM 102) ran a CPU model that hid AVX2, and its disk wasn't
  marked `ssd` (#354).
- fedora-ws (VM 104) was parked but set to autostart into about 3 GiB of
  headroom (#356).
- HAOS (VM 100) ran QEMU's `kvm64`, with no AES-NI and below x86-64-v2, and an
  RTC on local time (#357).
- The models those fixes chose left out PCLMULQDQ, so AES-GCM ran 8× slower
  (#361).
- No VM passes `md-clear` or `ssbd` (#365).
- The testbeds drifted from the workstations they stand in for (#358).

All but one of these were in an attribute the resource left **unset**. CI's plan
only shows drift for attributes Terraform sets, so an unset attribute is
invisible however wrong its live value is. The exception, HAOS's `localtime`,
is worse: the provider doesn't model it at all, so no setting can surface it. The fixes were also argued guest by
guest, so the next VM or container would start from whatever its installer
chose.

## Decision

**Every guest belongs to a class, and each class has a target profile.** A
profile sets every PVE attribute listed in #367, each with a reason tied to the
class's purpose. Where the PVE default is the right answer, the profile says so
explicitly. The classes, profiles and cross-cutting policies (backups,
placement, capacity, `ignore_changes`, tags) live in
[`docs/guest-profiles.md`](../guest-profiles.md). The per-guest gaps live in
[`docs/guest-profiles-gaps.md`](../guest-profiles-gaps.md).

The seven classes:

1. interactive workstation VM;
2. appliance VM with hardware passthrough;
3. disposable test VM;
4. CI runner LXC;
5. agent worker LXC, owned by claytonia (ADR-0005);
6. service LXC;
7. cluster-node LXC.

Rules that follow:

- **Codify against the profile, not the guest.** Each kalmia-owned guest's
  Terraform sets every profile attribute, including the ones that match PVE's
  default, so the plan shows any drift. A profile is expressed once, in
  `locals` per class, and resources reference it instead of repeating
  literals. That refactor lands first, on its own, with a plan that shows no
  changes.
- **Tag the class on the guest** (`class-<name>` plus the owning repo), so the
  class shows in the PVE UI and is greppable in `/etc/pve`.
- **A new guest picks a class first.** A value that differs from its class's
  profile is a documented exception with a reason, in the resource comment and
  in the gap table.
- **The profile defines what changes, not when.** Codification PRs follow the
  standing rails. VM changes land as pending config (`reboot_after_update =
  false`) and the operator batches cold restarts, so each VM restarts once.
  Testbed changes land with a re-taken `pristine` (#358). A plan that destroys
  or replaces a stateful guest goes back to the operator.
- **claytonia's pool** gets its profile here and its codification in
  lentago/claytonia. kalmia's token can't file or change anything there.

## Alternatives

**Keep fixing guests case by case.** This costs nothing up front, and every
fix in the 2026-11 series was correct for its guest. But each started from an
accident: a benchmark, an autostart, a guest's `/proc/cpuinfo`. And each fix
had to be re-argued for the next guest (#361 repeated #354's reasoning three
times). It leaves unset attributes invisible, which was the root cause.

**One profile for all guests.** This is simpler, but the classes really do
differ on the attributes that matter:

- **BIOS:** HAOS needs OVMF; the workstations are installed BIOS-boot.
- **Power:** workstations and testbeds ignore `started`; services enforce it.
- **CPU weight:** batch classes yield.
- **Swap:** k3s nodes need 0.

A single profile would be a list of per-guest exceptions.

**A Terraform module per class.** This expresses a profile most strongly, but
moving every resource into a module address means `moved` blocks for every
guest and its mount-hook `terraform_data`, all in the same PR as a high-risk
state refactor. Class `locals` get the same single source of truth with no
state moves. A module stays open for a class whose members are truly
homogeneous (the minecraft runners), as a later, separate refactor.

**A PVE-side mechanism** (resource pools, a custom CPU model in
`cpu-models.conf`, HA groups). Pools group guests but carry no config, and the
claytonia pool already uses one for ownership. A custom CPU model is a
hand-managed cluster file outside Terraform (#361). `ha-manager` is
deliberately unused (HAOS is USB-pinned). None of these replaces a profile
written in Terraform.

## Consequences

- The gap table becomes the to-do list. Each codification child issue of #367
  closes named rows, and those rows are updated when its PR lands.
- More attributes are set explicitly, so some first applies write a value PVE
  already used implicitly (for example `floating = dedicated`, or `cpuunits =
  100`). These are textual config changes with no behaviour change. Each
  child issue says what the provider does to a running guest.
- The profiles record facts established from the provider and PVE sources that
  aren't otherwise written down:
  - bpg/proxmox reads an absent `balloon` and `balloon=0` alike.
  - A container `memory`, `network_interface` or `mount_options` change makes
    the provider reboot the CT.
  - PVE's `protection` blocks every rootfs/`mpN` update on a CT.
- `protection` diverges by guest type: on for import-only VMs, off for every
  CT, because on a CT it would block Terraform's disk updates and the mount
  hook.
- Capacity ceilings (thin-pool used %, overcommit, LXC memory caps) are
  proposals until #366's trim experiment reports. Until then pve5 takes no new
  or grown disk.
- Live state that Terraform can't model (VM `localtime`, k3s `lxc.*` keys,
  Firewalla reservations) stays listed in the profiles doc, so it is a known
  blind spot rather than a surprise.
