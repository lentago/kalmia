# pve4 LXC fleet — imported brownfield (phase 1, #23). Source of truth for
# these values at import time: `pct config <vmid>` on pve4.

# The bullpen runner pool (claude-runner 1–5, VMIDs 110–112/116–117) was
# RELEASED from this layer on 2026-07-07 (#37): products own their capacity,
# so the pool's guest lifecycle now lives in lentago/claytonia `terraform/`
# (adoption: lentago/claytonia#51). kalmia keeps every other guest — including
# LXC 115 (`runner.tf`): shared CI substrate deliberately does not depend on
# claytonia's own workers.

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

  # NAS harvest landing — the lentago/music-curator Spotify harvester (an n8n
  # workflow on this box) writes dated snapshots here. Bind mount mirrors pub's
  # web mount. The unprivileged CT's uid 1000 (n8n `node` user) maps to host
  # 101000, which equals the CIFS share's forceuid (mode 0770), so the container
  # can write. See lentago/music-curator harvest/README.md.
  mount_point {
    volume = "/mnt/neptune-lentago/spotify-harvest"
    path   = "/data/harvests"
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

    # SSH key codified so the mount_point recreate (below — bpg treats a
    # mount_point add as forces-replacement) comes back reachable. The prior
    # root key was PVE-injected out-of-band and would be lost on rebuild.
    # Public key only.
    user_account {
      keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbnPjDFmbYusUw13NsD5h+NMRA/l8JAjaSZF94ohUvMQvXTY5ozTnBl5fWtd9UHof9ftE4hLdih/sSdDxRJAtq9SSCSb4OuFsEy+CFJpM6/f6mtsCjrL3TE11f5M6hiGX7423gdW0FXBLgC6klTWK023lt21S9VU0um6XIPicdsMg8udOVKSYPquPSq6XhB7ngpPjN7XdELfzSJYAwlgTaoFjw1ZvdQfMRslCXdx/AhbKBSlQKBsf/LkLZJCZACvt1+Z1vZtJr7kq7WqANEzJqrTZWDTF5NnEPU6eHDVqCh8lZZkaBY6cTNIIugwW3UMSrbw3I40OD9/qGpleyLowmf8cxX1WHY/HbVAxpmxYbWO5f4N9l6lFe6tdVwaTGtlj3jEJFM/CPZP6ygp6m9OqgaXXwSG6vFuJKz4XQvtF3hBmRs+vlzgflkF+5h/qKh+e29g/bkj82zMA8cfIdwoT9n2DdP3LHIfSFo/l9l9AANPKHFtvZq6saHIx5Dp/Pd8M= cpitzi@penguin"
      ]
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
