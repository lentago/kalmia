# Guest profiles — gap table

Every guest × attribute, comparing the **live** value (the 2026-11-28
`qm config`/`pct config` inventory in #367), the **Terraform** value
(`terraform/*.tf`, or lentago/claytonia `terraform/` for the agent workers) and
the **target** from its class profile in [`guest-profiles.md`](guest-profiles.md).

Compiled from those three sources on 2026-11-28. When a codification
PR lands, update the rows it closes.

## Reading the table

- **Live:** "unset (X)" means the key is absent from the guest's config and PVE
  uses its default X.
- **Terraform:** "default X" means the attribute isn't in the `.tf`, but the
  provider schema has a default, so the plan still shows drift. "Unset
  (computed: drift invisible)" means the provider reads whatever is live and
  the plan never shows a change: the case this table exists to surface.
- **Gap:**
  - **none:** live, Terraform and target agree, or the target is a provider
    default the plan already enforces.
  - **codify-only:** live is already right, but Terraform is silent, so drift
    is invisible. Codifying causes no behaviour change, but the first apply
    may still write the value out explicitly (for example `balloon: 8192` in
    place of an absent key). The provider may flag that write as needing a
    restart. Each child issue states what happens on a running guest.
  - **change:** live differs from the target.
  - **decision needed:** the target needs an operator decision or a value
    that isn't in the inventory (each is a question in the PR).
  - **claytonia-owned:** a gap on a claytonia guest, to be codified there.
  - A reference after the label, such as (#358), points to the issue that
    already carries the gap.

## Summary of gaps

Codification starts with #370 (profiles as `locals`, plan shows no changes).

| Guests | Gap | Attribute | Handled in |
|---|---|---|---|
| 100, 102, 104 | change | CPU flags `+md-clear;+ssbd` | #365 (PR #368) |
| 120, 121 | change | CPU model, flags, disk `discard`/`ssd`, `protection`, `tags`; codify `floating`, `hotplug` | #358 (lands with the re-taken `pristine`) |
| 120, 121 | decision needed | node placement | #366 |
| 100, 102, 104 | change | `protection` = 1, class `tags` | #371 (102, 104), #372 (100) |
| 100 | change | `startup` `order=1` | #372 |
| 100, 104 | codify-only | `floating` = `dedicated` | #372 (100), #371 (104) |
| 102 | decision needed | balloon: keep `balloon=0` or turn on the device with `floating = 16384` | #371 |
| 100, 102, 104 | codify-only | `vga`, `hotplug` | #371, #372 |
| every kalmia CT | change | class `tags` | #373, #374, #375 |
| CI runners | change | `cpuunits` = 50 | #373 |
| services, k3s nodes | codify-only | `cpuunits` = 100 | #374, #375 |
| 115, 119, 122 | codify-only | MAC pin (value needed) | #373 (115), #375 (119, 122) |
| 119, 122 | decision needed | stable addressing (DHCP today) | #376 |
| 105, 113, 115 | decision needed | verify the Firewalla reservation for an in-pool static IP | #350 (outside Terraform) |
| 118 | change | add the missing Firewalla reservation | #350 (outside Terraform) |
| CI runners, agent workers | decision needed | exclude from `guests-weekly` | #377 |
| 110 – 112, 116, 117 | claytonia-owned | `cpuunits` = 50, class `tags`; verify reservations | lentago/claytonia (list in the PR) |


## VMs

### VM 100 haos (appliance)

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| CPU model | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | none |
| CPU flags | none | unset | `+md-clear;+ssbd` | change (#365, PR #368) |
| Cores / sockets | 2 / 1 | 2 / 1 | 2 / 1 | none |
| NUMA | 0 | default `false` | off (PVE default) | none |
| Memory | 8192 | 8192 | 8192 | none |
| Balloon | unset (device on) | unset; reads as `floating = 0` | `floating = 8192` | codify-only |
| Machine | `q35` | `q35` | `q35` | none |
| BIOS | `ovmf` | `ovmf` | `ovmf` + 4m EFI disk | none |
| `scsihw` | `virtio-scsi-single` | `virtio-scsi-single` | `virtio-scsi-single` | none |
| Disk `iothread` | 1 | `true` | on | none |
| Disk `aio` | `io_uring` | default `io_uring` | `io_uring` (PVE default) | none |
| Disk `cache` | `none` | default `none` | `none` (PVE default) | none |
| Disk `discard` | `on` | `on` | `on` | none |
| Disk `ssd` | 1 | `true` | on | none |
| Disk `backup` | 1 | default `true` | on (PVE default) | none |
| Disk `replicate` | 1 | default `true` | on (PVE default) | none |
| NIC model | `virtio` | default `virtio` | `virtio` | none |
| NIC `firewall` | 0 | `false` | 0 (as live) | none |
| NIC multiqueue | none | default `0` | off (PVE default) | none |
| Guest agent | on | `enabled = true` | on | none |
| Agent `fstrim_cloned_disks` | unset (off) | default `false` | off (PVE default) | none |
| `onboot` | 1 | `true` | 1 | none |
| `startup` | unset | unset | `order=1` | change |
| `protection` | unset (0) | default `false` | 1 | change |
| `tags` | none | unset | `class-appliance;kalmia` | change |
| `vga` | unset (`std`) | unset (computed: drift invisible) | `std` (PVE default) | codify-only |
| `tablet` | 0 | `false` | off | none |
| `hotplug` | unset (`network,disk,usb`) | unset (computed: drift invisible) | `network,disk,usb` (PVE default) | codify-only |
| RNG device | none | default none | none (PVE default) | none |
| USB | `303a:831a`, `303a:4001` | both `usb { host }` | both | none |
| Serial | `serial0` | `serial_device {}` | `serial0` | none |
| Node | pve3 | pve3 | pve3 (pinned, never migrate) | none |
| Backup job | haos-4h | haos-4h | haos-4h | none |

### VM 102 xubuntu-ws (workstation)

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| CPU model | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | none |
| CPU flags | none | unset | `+md-clear;+ssbd` | change (#365, PR #368) |
| Cores / sockets | 6 / 1 | 6 / 1 | 6 / 1 | none |
| NUMA | 0 | default `false` | off (PVE default) | none |
| Memory | 16384 | 16384 | 16384 | none |
| Balloon | `0` (device off) | unset; reads as `floating = 0` | `floating = 16384` | decision needed |
| Machine | `q35` | `q35` | `q35` | none |
| BIOS | unset (SeaBIOS) | default `seabios` | SeaBIOS (PVE default) | none |
| `scsihw` | `virtio-scsi-single` | `virtio-scsi-single` | `virtio-scsi-single` | none |
| Disk `iothread` | 1 | `true` | on | none |
| Disk `aio` | `io_uring` | default `io_uring` | `io_uring` (PVE default) | none |
| Disk `cache` | `none` | default `none` | `none` (PVE default) | none |
| Disk `discard` | `on` | `on` | `on` | none |
| Disk `ssd` | 1 | `true` | on | none |
| Disk `backup` | 1 | default `true` | on (PVE default) | none |
| Disk `replicate` | 1 | default `true` | on (PVE default) | none |
| NIC model | `virtio` | default `virtio` | `virtio` | none |
| NIC `firewall` | 1 | `true` | 1 (as live) | none |
| NIC multiqueue | none | default `0` | off (PVE default) | none |
| Guest agent | on | `enabled = true` | on | none |
| Agent `fstrim_cloned_disks` | unset (off) | default `false` | off (PVE default) | none |
| `onboot` | 1 | `true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | default `false` | 1 | change |
| `tags` | none | unset | `class-workstation;kalmia` | change |
| `vga` | unset (`std`) | unset (computed: drift invisible) | `std` (PVE default) | codify-only |
| `tablet` | unset (1) | default `true` | on (PVE default) | none |
| `hotplug` | unset (`network,disk,usb`) | unset (computed: drift invisible) | `network,disk,usb` (PVE default) | codify-only |
| RNG device | none | default none | none (PVE default) | none |
| Node | pve5 | pve5 | pve5 | none |
| Backup job | workstation-daily | workstation-daily | workstation-daily | none |

### VM 104 fedora-ws (workstation, parked)

Stopped, so every change takes effect on apply.

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| CPU model | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | `Broadwell-noTSX-IBRS` | none |
| CPU flags | none | unset | `+md-clear;+ssbd` | change (#365, PR #368) |
| Cores / sockets | 4 / 1 | 4 / 1 | 4 / 1 | none |
| NUMA | 0 | default `false` | off (PVE default) | none |
| Memory | 8192 | 8192 | 8192 | none |
| Balloon | unset (device on) | unset; reads as `floating = 0` | `floating = 8192` | codify-only |
| Machine | `q35` | `q35` | `q35` | none |
| BIOS | unset (SeaBIOS) | default `seabios` | SeaBIOS (PVE default) | none |
| `scsihw` | `virtio-scsi-single` | `virtio-scsi-single` | `virtio-scsi-single` | none |
| Disk `iothread` | 1 | `true` | on | none |
| Disk `aio` | `io_uring` | default `io_uring` | `io_uring` (PVE default) | none |
| Disk `cache` | `none` | default `none` | `none` (PVE default) | none |
| Disk `discard` | `on` | `on` | `on` | none |
| Disk `ssd` | 1 | `true` | on | none |
| Disk `backup` | 1 | default `true` | on (PVE default) | none |
| Disk `replicate` | 1 | default `true` | on (PVE default) | none |
| NIC model | `virtio` | default `virtio` | `virtio` | none |
| NIC `firewall` | 1 | `true` | 1 (as live) | none |
| NIC multiqueue | none | default `0` | off (PVE default) | none |
| Guest agent | on | `enabled = true` | on | none |
| Agent `fstrim_cloned_disks` | unset (off) | default `false` | off (PVE default) | none |
| `onboot` | 0 | `false` | 0 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | default `false` | 1 | change |
| `tags` | none | unset | `class-workstation;kalmia` | change |
| `vga` | unset (`std`) | unset (computed: drift invisible) | `std` (PVE default) | codify-only |
| `tablet` | unset (1) | default `true` | on (PVE default) | none |
| `hotplug` | unset (`network,disk,usb`) | unset (computed: drift invisible) | `network,disk,usb` (PVE default) | codify-only |
| RNG device | none | default none | none (PVE default) | none |
| Node | pve5 | pve5 | pve5 | none |
| Backup job | guests-weekly | guests-weekly | guests-weekly | none |

### VM 120 xubuntu-test (testbed)

Every gap here lands with #358's re-taken `pristine`.

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| CPU model | `x86-64-v2-AES` | `x86-64-v2-AES` | `Broadwell-noTSX-IBRS` | change (#358) |
| CPU flags | none | unset | `+md-clear;+ssbd` | change (#358) |
| Cores / sockets | 2 / 1 | 2 / 1 | 2 / 1 | none |
| NUMA | 0 | default `false` | off (PVE default) | none |
| Memory | 4096 | 4096 | 4096 | none |
| Balloon | unset (device on) | unset; reads as `floating = 0` | `floating = 4096` | codify-only (#358) |
| Machine | `q35` | `q35` | `q35` | none |
| BIOS | unset (SeaBIOS) | default `seabios` | SeaBIOS (PVE default) | none |
| `scsihw` | `virtio-scsi-single` | `virtio-scsi-single` | `virtio-scsi-single` | none |
| Disk `iothread` | 1 | `true` | on | none |
| Disk `aio` | unset (`io_uring`) | default `io_uring` | `io_uring` (PVE default) | none |
| Disk `cache` | unset (`none`) | default `none` | `none` (PVE default) | none |
| Disk `discard` | unset (`ignore`) | default `ignore` | `on` | change (#358) |
| Disk `ssd` | unset (0) | default `false` | on | change (#358) |
| Disk `backup` | unset (1) | default `true` | on (PVE default) | none |
| Disk `replicate` | unset (1) | default `true` | on (PVE default) | none |
| NIC model | `virtio` | default `virtio` | `virtio` | none |
| NIC `firewall` | 1 | `true` | 1 (as live) | none |
| NIC multiqueue | none | default `0` | off (PVE default) | none |
| Guest agent | on | `enabled = true` | on | none |
| Agent `fstrim_cloned_disks` | unset (off) | default `false` | off (PVE default) | none |
| `onboot` | 0 | `false` | 0 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | default `false` | 1 | change (#358) |
| `tags` | none | unset | `class-testbed;kalmia` | change (#358) |
| `vga` | `std`, memory 16 | `type = "std"` | `std`, 16 MiB | none |
| `tablet` | unset (1) | default `true` | on (PVE default) | none |
| `hotplug` | unset (`network,disk,usb`) | unset (computed: drift invisible) | `network,disk,usb` (PVE default) | codify-only (#358) |
| RNG device | none | default none | none (PVE default) | none |
| Serial | `serial0` | `serial_device {}` | `serial0` | none |
| Node | pve5 | pve5 | pve5 today; pending #366 | decision needed (#366) |
| Backup job | guests-weekly | guests-weekly | guests-weekly | none |

### VM 121 fedora-xfce-test (testbed)

Every gap here lands with #358's re-taken `pristine`.

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| CPU model | `x86-64-v2-AES` | `x86-64-v2-AES` | `Broadwell-noTSX-IBRS` | change (#358) |
| CPU flags | none | unset | `+md-clear;+ssbd` | change (#358) |
| Cores / sockets | 2 / 1 | 2 / 1 | 2 / 1 | none |
| NUMA | 0 | default `false` | off (PVE default) | none |
| Memory | 4096 | 4096 | 4096 | none |
| Balloon | unset (device on) | unset; reads as `floating = 0` | `floating = 4096` | codify-only (#358) |
| Machine | `q35` | `q35` | `q35` | none |
| BIOS | unset (SeaBIOS) | default `seabios` | SeaBIOS (PVE default) | none |
| `scsihw` | `virtio-scsi-single` | `virtio-scsi-single` | `virtio-scsi-single` | none |
| Disk `iothread` | 1 | `true` | on | none |
| Disk `aio` | unset (`io_uring`) | default `io_uring` | `io_uring` (PVE default) | none |
| Disk `cache` | unset (`none`) | default `none` | `none` (PVE default) | none |
| Disk `discard` | unset (`ignore`) | default `ignore` | `on` | change (#358) |
| Disk `ssd` | unset (0) | default `false` | on | change (#358) |
| Disk `backup` | unset (1) | default `true` | on (PVE default) | none |
| Disk `replicate` | unset (1) | default `true` | on (PVE default) | none |
| NIC model | `virtio` | default `virtio` | `virtio` | none |
| NIC `firewall` | 1 | `true` | 1 (as live) | none |
| NIC multiqueue | none | default `0` | off (PVE default) | none |
| Guest agent | on | `enabled = true` | on | none |
| Agent `fstrim_cloned_disks` | unset (off) | default `false` | off (PVE default) | none |
| `onboot` | 0 | `false` | 0 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | default `false` | 1 | change (#358) |
| `tags` | none | unset | `class-testbed;kalmia` | change (#358) |
| `vga` | `std`, memory 16 | `type = "std"` | `std`, 16 MiB | none |
| `tablet` | unset (1) | default `true` | on (PVE default) | none |
| `hotplug` | unset (`network,disk,usb`) | unset (computed: drift invisible) | `network,disk,usb` (PVE default) | codify-only (#358) |
| RNG device | none | default none | none (PVE default) | none |
| Serial | `serial0` | `serial_device {}` | `serial0` | none |
| Node | pve5 | pve5 | pve5 today; pending #366 | decision needed (#366) |
| Backup job | guests-weekly | guests-weekly | guests-weekly | none |

## CI runner LXCs

### CT 115 gha-runner

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | change |
| Memory | 2048 | 2048 | 2048 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-ci-runner;kalmia` | change |
| Addressing | static .15, in the DHCP pool | `.15/24` | static + Firewalla reservation | decision needed (verify reservation, #350) |
| MAC | (stripped from the inventory) | unset (computed) | pinned | codify-only (value needed) |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed |

### CT 123 pe-publish

Moved here from *Service* (see the profiles doc).

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | change |
| Memory | 1024 | 1024 | 1024 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 8G | 8 | 8G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `web/wiki`, mp1 `…/search-map`, mp2 `…/search-board`, all rw | mount-hook map (`mount_point` ignored) | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-ci-runner;kalmia` | change |
| Addressing | static .5, below the pool | `.5/24` | static, below the pool | none |
| MAC | (stripped from the inventory) | `BC:24:11:50:FB:34` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed |

### CT 124 minecraft-runner

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | change |
| Memory | 10240 | 10240 | 10240 | none |
| Swap | 1024 | 1024 | 1024 | none |
| Rootfs size | 32G | 32 | 32G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `web/minecraft` rw; mp1 `minecraft-ci` `ro=1` | mount-hook map (`mount_point` ignored) | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-ci-runner;kalmia` | change |
| Addressing | static .3, below the pool | `.3/24` | static, below the pool | none |
| MAC | (stripped from the inventory) | `BC:24:11:7F:FF:0A` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed |

### CT 126 minecraft-runner-2

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | change |
| Memory | 10240 | 10240 | 10240 | none |
| Swap | 1024 | 1024 | 1024 | none |
| Rootfs size | 32G | 32 | 32G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `web/minecraft` rw; mp1 `minecraft-ci` `ro=1` | mount-hook map (`mount_point` ignored) | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-ci-runner;kalmia` | change |
| Addressing | static .23, in the DHCP pool | `.23/24` | static + Firewalla reservation | none (reserved per the `.tf` comment, unverified; #350) |
| MAC | (stripped from the inventory) | `BC:24:11:6A:2C:91` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed |

### CT 127 minecraft-runner-3

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | change |
| Memory | 10240 | 10240 | 10240 | none |
| Swap | 1024 | 1024 | 1024 | none |
| Rootfs size | 32G | 32 | 32G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `web/minecraft` rw; mp1 `minecraft-ci` `ro=1` | mount-hook map (`mount_point` ignored) | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-ci-runner;kalmia` | change |
| Addressing | static .26, in the DHCP pool | `.26/24` | static + Firewalla reservation | none (reserved per the `.tf` comment, unverified; #350) |
| MAC | (stripped from the inventory) | `BC:24:11:3D:7E:52` | pinned | none |
| Node | pve3 | pve3 | pve3 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed |

## Service LXCs

### CT 105 grafana-stack

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | unset (0) | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 2048 | 2048 | 2048 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .20, in the DHCP pool | `.20/24` | static + Firewalla reservation | decision needed (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:82:91:78` | pinned | none |
| Node | pve5 | pve5 | pve5 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 113 n8n

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | unset (0) | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 2048 | 2048 | 2048 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 12G | 12 | 12G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .13, in the DHCP pool | `.13/24` | static + Firewalla reservation | decision needed (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:59:AD:93` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 114 pub

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | unset (0) | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 1024 | 1024 | 1024 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 8G | 8 | 8G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `web` rw; mp1 `claude-jobs` `ro=1` (root@pam) | both declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .9, below the pool | `.9/24` | static, below the pool | none |
| MAC | (stripped from the inventory) | `BC:24:11:AB:8D:D2` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 118 brasenia

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 10G | 10 | 10G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .19, in the DHCP pool | `.19/24` | static + Firewalla reservation | change (Firewalla, outside Terraform; reservation confirmed missing, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:8D:F9:C8` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 125 minecraft-lan

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 16G | 16 | 16G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `minecraft-ci` `ro=1` | mount-hook map (`mount_point` ignored) | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .2, below the pool | `.2/24` | static, below the pool | none |
| MAC | (stripped from the inventory) | `BC:24:11:43:56:F5` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 128 kiosk-sim

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 1 | 1 | 1 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 512 | 512 | 512 | none |
| Swap | 256 | 256 | 256 | none |
| Rootfs size | 4G | 4 | 4G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-service;kalmia` | change |
| Addressing | static .48, in the DHCP pool | `.48/24` | static + Firewalla reservation | none (reserved 2026-11-22 per the `.tf` comment; #350) |
| MAC | (stripped from the inventory) | `BC:24:11:6D:41:A7` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

## Cluster-node LXCs

### CT 119 k3s-1

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | unset (0) | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 6144 | 6144 | 6144 | none |
| Swap | 0 | 0 | 0 | none |
| Rootfs size | 24G | 24 | 24G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-k8s-node;kalmia` | change |
| Addressing | DHCP | `dhcp` | stable address (reservation or static) | decision needed |
| MAC | (stripped from the inventory) | unset (computed) | pinned | codify-only (value needed) |
| Node | pve5 | pve5 | pve5 (≠ k3s-2's node) | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

### CT 122 k3s-2

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | `nesting=1,keyctl=1` | none |
| Cores | 4 | 4 | 4 | none |
| `cpulimit` | unset (0) | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 100 (PVE default, explicit) | codify-only |
| Memory | 6144 | 6144 | 6144 | none |
| Swap | 0 | 0 | 0 | none |
| Rootfs size | 24G | 24 | 24G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | none | none | none | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | unset (0) | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-k8s-node;kalmia` | change |
| Addressing | DHCP | `dhcp` | stable address (reservation or static) | decision needed |
| MAC | (stripped from the inventory) | unset (computed) | pinned | codify-only (value needed) |
| Node | pve4 | pve4 | pve4 (≠ k3s-1's node) | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | guests-weekly | none |

## Agent worker LXCs (claytonia)

Terraform values are from lentago/claytonia `terraform/modules/proxmox` (bpg/proxmox 0.111.1). Gaps there are claytonia's to codify; the PR for this doc lists them for filing.

### CT 110 claude-runner

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | claytonia-owned |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `claude-jobs` → `/srv/jobs` rw (root@pam) | not declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-agent-worker;claytonia` | claytonia-owned |
| Addressing | static .10, in the DHCP pool | `.10/24` | static + Firewalla reservation | claytonia-owned (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:7A:1A:E1` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| PVE pool | (not in the inventory) | `claytonia` | `claytonia` | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed (kalmia `guests-weekly`) |

### CT 111 claude-runner-2

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | claytonia-owned |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `claude-jobs` → `/srv/jobs` rw (root@pam) | not declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-agent-worker;claytonia` | claytonia-owned |
| Addressing | static .11, in the DHCP pool | `.11/24` | static + Firewalla reservation | claytonia-owned (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:A8:C7:AF` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| PVE pool | (not in the inventory) | `claytonia` | `claytonia` | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed (kalmia `guests-weekly`) |

### CT 112 claude-runner-3

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | claytonia-owned |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `claude-jobs` → `/srv/jobs` rw (root@pam) | not declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-agent-worker;claytonia` | claytonia-owned |
| Addressing | static .12, in the DHCP pool | `.12/24` | static + Firewalla reservation | claytonia-owned (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:05:FD:71` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| PVE pool | (not in the inventory) | `claytonia` | `claytonia` | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed (kalmia `guests-weekly`) |

### CT 116 claude-runner-4

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | claytonia-owned |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `claude-jobs` → `/srv/jobs` rw (root@pam) | not declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-agent-worker;claytonia` | claytonia-owned |
| Addressing | static .17, in the DHCP pool | `.17/24` | static + Firewalla reservation | claytonia-owned (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:FA:D4:3E` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| PVE pool | (not in the inventory) | `claytonia` | `claytonia` | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed (kalmia `guests-weekly`) |

### CT 117 claude-runner-5

| Attribute | Live | Terraform | Target | Gap |
|---|---|---|---|---|
| `unprivileged` | 1 | `true` | 1 | none |
| `features` | `nesting=1` | `nesting=1` | `nesting=1` | none |
| Cores | 2 | 2 | 2 | none |
| `cpulimit` | `0` | default `0` | 0 (PVE default) | none |
| `cpuunits` | unset (100) | unset (computed: drift invisible) | 50 | claytonia-owned |
| Memory | 4096 | 4096 | 4096 | none |
| Swap | 512 | 512 | 512 | none |
| Rootfs size | 20G | 20 | 20G | none |
| Rootfs mount options | none | unset | none (PVE default) | none |
| Mount points | mp0 `claude-jobs` → `/srv/jobs` rw (root@pam) | not declared; `mount_point` ignored | as live | none |
| `onboot` | 1 | `start_on_boot = true` | 1 | none |
| `startup` | unset | unset | PVE default (none) | none |
| `protection` | `0` | unset (`false`) | 0 (PVE default) | none |
| `tags` | none | unset | `class-agent-worker;claytonia` | claytonia-owned |
| Addressing | static .18, in the DHCP pool | `.18/24` | static + Firewalla reservation | claytonia-owned (verify reservation, #350) |
| MAC | (stripped from the inventory) | `BC:24:11:BE:09:18` | pinned | none |
| Node | pve4 | pve4 | pve4 | none |
| PVE pool | (not in the inventory) | `claytonia` | `claytonia` | none |
| Backup job | guests-weekly (`all`) | guests-weekly (`all = true`) | excluded (proposal) | decision needed (kalmia `guests-weekly`) |

