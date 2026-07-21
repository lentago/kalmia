# pve4 LXC fleet — imported brownfield (phase 1, #23). Source of truth for
# these values at import time: `pct config <vmid>` on pve4.

# The bullpen runner pool (claude-runner 1–5, VMIDs 110–112/116–117) was
# RELEASED from this layer on 2026-07-07 (#37): products own their capacity,
# so the pool's guest lifecycle now lives in lentago/claytonia `terraform/`
# (adoption: lentago/claytonia#51). kalmia keeps every other guest — including
# LXC 115 (`runner.tf`): shared CI substrate deliberately does not depend on
# claytonia's own workers.

# CT 113 is created out-of-band by root@pam and imported here. Docker-capable
# LXCs need keyctl (and any bind mount) — both root@pam-only — so an API-token
# CI apply cannot create this container; it can only manage it post-import. It
# was rebuilt this way on 2026-07-12 after a mount-driven recreate destroyed it.
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

  # NAS bind-mount intentionally NOT declared here: Proxmox forbids bind mounts
  # via API token (root@pam only), so Terraform/CI cannot create one. Harvester
  # NAS-raw output is handled outside this resource. See music-curator harvest/.

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
  description   = "Caddy webserver (pub.lan, 192.168.139.9) replacing the retired web.lan. Serves NAS /volume1/lentago/web (bind-mounted to /srv/www) with directory browsing. Drop files via NAS share; room for a dynamic reverse_proxy backend later.\n"
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

# grafana-stack — the drosera Alloy shipper / Grafana Cloud stack (pve5).
# Note: no searchdomain in the live config, so the dns block sets servers only.
import {
  to = proxmox_virtual_environment_container.grafana_stack
  id = "pve5/105"
}

resource "proxmox_virtual_environment_container" "grafana_stack" {
  node_name     = "pve5"
  vm_id         = 105
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
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 20
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:82:91:78"
  }

  initialization {
    hostname = "grafana-stack"

    dns {
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "192.168.139.20/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    # Build template is gone from local storage; ignored after import.
    template_file_id = "local:vztmpl/ubuntu-24.04-standard_24.04-1_amd64.tar.zst"
    type             = "ubuntu"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}

# LXC 118 — lunaria, the wall-display compositor/streamer (concept:
# http://pub.lan/lunaria/LUNARIA.md). Renders http://pub.lan/brief/tv.html
# (headless chromium) into an H.264 HLS stream (mediamtx :8888) that the
# play-room Roku's sideloaded dev channel plays. Deliberately credential-free:
# pub owns the Drive leg; lunaria only reads pub.lan. No bind mounts and no
# keyctl, so the API-token CI apply can create this container from scratch.
resource "proxmox_virtual_environment_container" "lunaria" {
  node_name     = "pve4"
  vm_id         = 118
  description   = "lunaria — wall-display compositor (192.168.139.19). Renders pub.lan/brief/tv.html to HLS :8888 for the play-room Roku dev channel. Provisioned by lunaria.yml.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 10
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "lunaria"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "192.168.139.19/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    ignore_changes = [operating_system]
  }
}
