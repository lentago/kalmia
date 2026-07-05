# LAN GitHub Actions runner (phase 2, #25) — the first guest CREATED by this
# layer rather than imported. Runs plan/apply for this repo's terraform
# workflow so merges to main can reach the LAN-only PVE API. In-guest
# bootstrap (runner agent, systemd service) is documented in README.md § CI.

resource "proxmox_virtual_environment_container" "gha_runner" {
  node_name     = "pve4"
  vm_id         = 115
  description   = "GitHub Actions self-hosted runner (LAN) — kalmia terraform plan/apply-on-merge. Agent in /opt/actions-runner, runs as user 'runner'.\n"
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
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "gha-runner"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        address = "192.168.139.15/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }
}
