# LXC 128 — kiosk-sim: a home-lab stand-in for the hosting of a private kiosk
# product (cpitzi/memory-aid). It serves one static page with Caddy and runs
# that product's content publisher on a systemd timer, so the page and the
# publisher can be exercised before any cloud hosting exists.
#
# kalmia owns only the guest's existence and shape. What runs inside it is
# provisioned by the product repo's own playbook (lab/kiosk-sim.yml there),
# not by a role here: the product is private and this repo is public, so
# nothing about its content or users belongs in this file.
#
# Disposable: no bind mounts, no keyctl, nothing in the guest that the
# product's playbook can't recreate, so it is pipeline-recreatable.

resource "proxmox_virtual_environment_container" "kiosk_sim" {
  node_name     = "pve4"
  vm_id         = 128
  description   = "kiosk-sim: lab stand-in for a private kiosk product's hosting (Caddy + publisher timer). Contents provisioned by that product's repo, cpitzi/memory-aid lab/kiosk-sim.yml.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true # systemd in an unprivileged Debian 12 guest
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  disk {
    datastore_id = "local-lvm"
    size         = 4
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # Pinned so a rebuild keeps its Firewalla device identity, quarantine
    # approval and reservation (a new MAC starts quarantined, WAN-blocked).
    mac_address = "BC:24:11:6D:41:A7"
  }

  initialization {
    hostname = "kiosk-sim"

    user_account {
      keys = [local.xubuntu_ws_ssh_public_key]
    }

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        # Inside the Firewalla DHCP pool (.10-.254), so the MAC above is
        # reserved to this address on the Firewalla (hosts2 file + redis
        # policy:mac ipAllocation, per the firewalla-dhcp-reservation
        # runbook), set 2026-11-22. Keep the two in step: change one, change
        # both. Other in-pool statics lack this today: #350.
        address = "192.168.139.48/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    # operating_system: create-only. user_account: see guest-ssh-key.tf.
    ignore_changes = [operating_system, initialization[0].user_account]
  }
}
