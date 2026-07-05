# pve5 workstation + testbed VMs, and (last) HAOS VM 100 on pve3.
# Imported brownfield (phase 3, #28). Source of truth at import time:
# `qm config <vmid>`.
#
# Safety: every VM sets reboot_after_update = false — an imported guest must
# never be rebooted by a config write Terraform makes during reconciliation.
# HAOS (100) additionally carries prevent_destroy.

# --- xubuntu-ws (102): running workstation, disk on `local` (qcow2) ---
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
  on_boot             = false
  started             = true
  reboot_after_update = false
  boot_order          = ["scsi0", "net0"]

  cpu {
    cores   = 2
    sockets = 2
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    interface    = "scsi0"
    datastore_id = "local"
    file_format  = "qcow2"
    size         = 32
    iothread     = true
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
}

# --- fedora-ws (104): running workstation, agent on, empty ide2 cdrom ---
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
  boot_order          = ["ide2", "scsi0", "net0"]

  agent {
    enabled = true
  }

  cpu {
    cores   = 2
    sockets = 2
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 8192
  }

  disk {
    interface    = "scsi0"
    datastore_id = "local-lvm"
    size         = 50
    iothread     = true
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
}

# --- kalmia testbeds (120 xubuntu-test, 121 fedora-xfce-test): STOPPED,
#     single socket, serial+std VGA, snapshot-reset boxes. started = false so
#     Terraform never powers them on. ---
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
