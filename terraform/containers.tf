# pve4 LXC fleet — imported brownfield (phase 1, #23). Source of truth for
# these values at import time: `pct config <vmid>` on pve4.

locals {
  # The three claytonia (bullpen) workers are identical modulo identity.
  bullpen_runners = {
    "claude-runner"   = { vm_id = 110, ip = "192.168.139.10", mac = "BC:24:11:7A:1A:E1" }
    "claude-runner-2" = { vm_id = 111, ip = "192.168.139.11", mac = "BC:24:11:A8:C7:AF" }
    "claude-runner-3" = { vm_id = 112, ip = "192.168.139.12", mac = "BC:24:11:05:FD:71" }
  }
}

import {
  for_each = local.bullpen_runners
  to       = proxmox_virtual_environment_container.bullpen_runner[each.key]
  id       = "pve4/${each.value.vm_id}"
}

resource "proxmox_virtual_environment_container" "bullpen_runner" {
  for_each = local.bullpen_runners

  node_name     = "pve4"
  vm_id         = each.value.vm_id
  description   = "Claude Code headless runner — scheduled (cron) + triggered (inbox watcher) jobs. Code in /opt/claude-runner; inbox on NAS at /srv/jobs.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 20
  }

  # NAS claude-jobs share (queue) — bind mount, workers see /srv/jobs
  mount_point {
    volume = "/mnt/neptune-lentago/claude-jobs"
    path   = "/srv/jobs"
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = each.value.mac
  }

  initialization {
    hostname = each.key

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    # Create-only: the template these were built from. Ignored below —
    # it cannot be reconciled on imported guests.
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}

import {
  to = proxmox_virtual_environment_container.n8n
  id = "pve4/113"
}

resource "proxmox_virtual_environment_container" "n8n" {
  node_name     = "pve4"
  vm_id         = 113
  description   = "n8n workflow automation (Docker). Editor at http://192.168.139.13:5678\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
    keyctl  = true # Docker-in-LXC
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 12
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:59:AD:93"
  }

  initialization {
    hostname = "n8n"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "192.168.139.13/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    # Create-only: the template these were built from. Ignored below —
    # it cannot be reconciled on imported guests.
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}

import {
  to = proxmox_virtual_environment_container.pub
  id = "pve4/114"
}

resource "proxmox_virtual_environment_container" "pub" {
  node_name     = "pve4"
  vm_id         = 114
  description   = "Caddy webserver (pub.lan, 192.168.139.9) replacing the retired web.lan. Serves NAS /volume1/PitziLabs/web (bind-mounted to /srv/www) with directory browsing. Drop files via NAS share; room for a dynamic reverse_proxy backend later.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  # NAS web drop folder — bind mount, Caddy serves /srv/www
  mount_point {
    volume = "/mnt/neptune-lentago/web"
    path   = "/srv/www"
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:AB:8D:D2"
  }

  initialization {
    hostname = "pub"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "192.168.139.9/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    # Create-only: the template these were built from. Ignored below —
    # it cannot be reconciled on imported guests.
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}
