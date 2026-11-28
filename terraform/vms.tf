# pve5 workstation + testbed VMs, and (last) HAOS VM 100 on pve3.
# Imported brownfield (phase 3, #28). Source of truth at import time:
# `qm config <vmid>`.
#
# Safety: every VM sets reboot_after_update = false — an imported guest must
# never be rebooted by a config write Terraform makes during reconciliation.
# Every imported VM carries prevent_destroy (#50); see README.md § Destroy guards.
#
# Power state (#38): workstations and testbeds ignore `started` — their
# momentary power is operator-/test-driven, and an apply must neither boot a
# parked workstation nor stop a testbed mid-run. HAOS and the service LXCs
# deliberately keep enforced power: re-starting those is desired state.

# --- xubuntu-ws (102): primary persistent Claude workspace, disk on `local-lvm` ---
import {
  to = proxmox_virtual_environment_vm.xubuntu_ws
  id = "pve5/102"
}

resource "proxmox_virtual_environment_vm" "xubuntu_ws" {
  node_name           = "pve5"
  vm_id               = 102
  name                = "xubuntu-ws"
  machine             = "q35"
  scsi_hardware       = "virtio-scsi-single"
  on_boot             = true
  started             = true
  reboot_after_update = false
  boot_order          = ["scsi0", "net0"]

  # qemu-guest-agent is installed in the guest; this attaches its virtio
  # channel so vzdump can freeze the filesystem and PVE can run fstrim.
  agent {
    enabled = true
  }

  # Sized as the session host for the Director and standing EMs (#286): 6 vCPU
  # on one socket, matching pve5's single-socket i5-8500T, and 16 GiB. NUMA and
  # CPU/memory hotplug are off, so a resize lands as pending config and takes
  # effect only on a PVE-side restart (`qm reboot 102`), never a guest reboot.
  #
  # x86-64-v3 (not v2-AES) so the guest sees AVX2/BMI/FMA for SIMD-accelerated
  # tools (ripgrep, zstd, numpy, ffmpeg). Every cluster node was verified
  # v3-capable on 2026-11-27, so VM 102 stays migratable (#354).
  cpu {
    cores   = 6
    sockets = 1
    type    = "x86-64-v3"
  }

  memory {
    dedicated = 16384
  }

  # Moved off `local` (pve5's root fs) to thin LVM and grown 32 -> 64 GB
  # out of band (`qm disk move` + `qm resize`); discard returns freed blocks.
  # Grown 64 -> 96 GB for #286: the single dev host holds ~20 GB of clones plus
  # the synced Claude state. The thin pool is overcommitted, so the next grow
  # needs a pool check first. The apply resizes the disk online; the guest
  # partition and ext4 filesystem are grown inside the guest (growpart +
  # resize2fs), which Terraform cannot do. ssd = true presents the thin-LVM-
  # on-NVMe disk as non-rotational in the guest (#354).
  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    file_format  = "raw"
    size         = 96
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:15:3D:2A"
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  smbios {
    uuid = "1833a71b-1912-4817-be36-b7972fe9a7f4"
  }

  # Always-on primary workspace (on_boot = true), but a running apply still
  # never touches the power button: `started` is the create-time baseline only.
  lifecycle {
    # Import-only: imported disk/state is unrebuildable by the token; guarded.
    prevent_destroy = true
    ignore_changes  = [started]
  }
}

# --- fedora-ws (104): parked, operator-started (on_boot = false; stopped,
#     last started 2026-10-25), agent on ---
#
# pve5 memory budget (measured 2026-11-27, 31.1 GiB usable, 7.6 GiB swap):
# VM 102 xubuntu-ws 16 GiB (balloon 0, ~16.1 in use) + CT 119 k3s-1 6 GiB
# (~1.3) + CT 105 grafana-stack 2 GiB (~0.2) + ~3.1 host overhead leaves
# ~11.1 GiB available. Starting fedora-ws (8 GiB) leaves ~3 GiB; a testbed
# run on top (VMs 120 + 121, 4 GiB each) exceeds physical RAM and the OOM
# killer takes VM 102's kvm first. Check headroom before resizing or adding
# any pve5 guest, and never autostart fedora-ws.
import {
  to = proxmox_virtual_environment_vm.fedora_ws
  id = "pve5/104"
}

resource "proxmox_virtual_environment_vm" "fedora_ws" {
  node_name           = "pve5"
  vm_id               = 104
  name                = "fedora-ws"
  machine             = "q35"
  scsi_hardware       = "virtio-scsi-single"
  on_boot             = true
  started             = true
  reboot_after_update = false
  boot_order          = ["scsi0", "net0"]

  agent {
    enabled = true
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "x86-64-v3"
  }

  memory {
    dedicated = 8192
  }

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 50
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:EF:FE:E1"
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  smbios {
    uuid = "c85ce4a1-b762-4a0e-a28f-255db4c07840"
  }

  # Power: operator-driven — see xubuntu_ws.
  lifecycle {
    # Import-only: imported disk/state is unrebuildable by the token; guarded.
    prevent_destroy = true
    ignore_changes  = [started]
  }
}

# --- kalmia testbeds (120 xubuntu-test, 121 fedora-xfce-test): STOPPED,
#     single socket, serial+std VGA, snapshot-reset boxes. started = false as
#     the baseline; `started` is ignored below so Terraform neither powers
#     them on nor stops one mid-test-run. ---
locals {
  testbed_vms = {
    "xubuntu-test"     = { vm_id = 120, mac = "BC:24:11:B9:93:C5", uuid = "6876cdc2-a900-4e56-a99d-5908a5488ece" }
    "fedora-xfce-test" = { vm_id = 121, mac = "BC:24:11:3B:04:29", uuid = "19e65c88-371c-4ca4-96e3-546bb64d382d" }
  }
}

import {
  for_each = local.testbed_vms
  to       = proxmox_virtual_environment_vm.testbed[each.key]
  id       = "pve5/${each.value.vm_id}"
}

resource "proxmox_virtual_environment_vm" "testbed" {
  for_each = local.testbed_vms

  node_name           = "pve5"
  vm_id               = each.value.vm_id
  name                = each.key
  machine             = "q35"
  scsi_hardware       = "virtio-scsi-single"
  on_boot             = false
  started             = false
  reboot_after_update = false
  boot_order          = ["scsi0"]

  agent {
    enabled = true
  }

  cpu {
    cores   = 2
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  # No discard: `qm rollback ... pristine` restores the snapshot's config,
  # which would strip it again on every test loop (and drift this plan).
  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 32
    iothread     = true
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac
    firewall    = true
  }

  serial_device {}

  vga {
    type = "std"
  }

  operating_system {
    type = "l26"
  }

  smbios {
    uuid = each.value.uuid
  }

  # Power cycles with the test loop (boot → provision → snapshot rollback);
  # an apply landing mid-run must never stop a testbed under test.
  lifecycle {
    # Import-only: imported disk + `pristine` snapshot are unrebuildable; guarded.
    prevent_destroy = true
    ignore_changes  = [started]
  }
}

# --- HAOS (100): MISSION-CRITICAL, pve3, USB-pinned Z-Wave/Zigbee/Matter
#     radios (passthrough does not survive migration), OVMF/EFI, SSD-emulated
#     discard disk. Imported LAST. prevent_destroy guards it; description
#     (a large HTML blob from the community-scripts installer) is ignored
#     rather than reproduced. ---
import {
  to = proxmox_virtual_environment_vm.haos
  id = "pve3/100"
}

resource "proxmox_virtual_environment_vm" "haos" {
  node_name           = "pve3"
  vm_id               = 100
  name                = "haos-17.1"
  machine             = "q35"
  bios                = "ovmf"
  scsi_hardware       = "virtio-scsi-pci"
  on_boot             = true
  started             = true
  reboot_after_update = false
  tablet_device       = false
  boot_order          = ["scsi0"]

  agent {
    enabled = true
  }

  cpu {
    cores   = 2
    sockets = 1
  }

  memory {
    dedicated = 8192
  }

  efi_disk {
    datastore_id = "local-lvm"
    type         = "4m"
  }

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 32
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "02:8B:4F:E2:7B:AF"
    firewall    = false
  }

  serial_device {}

  # Z-Wave / Zigbee / Matter USB radios — physically on pve3, the reason
  # HAOS cannot be live-migrated.
  usb {
    host = "303a:831a"
  }
  usb {
    host = "303a:4001"
  }

  operating_system {
    type = "l26"
  }

  smbios {
    uuid = "5ab9cec2-e15f-4b27-8b7d-167b5df46885"
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [description]
  }
}
