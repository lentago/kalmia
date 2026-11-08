# LXC 125 — minecraft-lan: a Bedrock Dedicated Server on the LAN (#297). Bedrock
# tablets join it as an added server (Play → Servers), so worlds reach them without
# importing .mcworld files (Android's Files app often won't hand those to the
# game). The world it serves is announced on pub.lan by the cpitzi/minecraft-builds
# publisher (minecraft/lan.json); a sync timer in the guest downloads it. In-guest
# provisioning: minecraft-lan.yml, docs/minecraft-lan.md.
#
# Its one bind mount comes from the mount hook, as for minecraft-runner; see
# README.md § Bind mounts — the mount hook.

locals {
  # Must equal its line in the node's allowlist (pve_host_mount_hook_allow).
  minecraft_lan_mounts = {
    # The staged Bedrock Dedicated Server zip, read-only: it can't be fetched by
    # script, so the role unpacks it from here (same file and pin as the runner).
    mp0 = "/mnt/neptune-lentago/cpitzi/minecraft-ci,mp=/srv/minecraft-ci,ro=1"
  }
}

resource "proxmox_virtual_environment_container" "minecraft_lan" {
  node_name = "pve4"
  vm_id     = 125
  # Still says LAN Games; clients join via Play → Servers. Updating it is an
  # in-place PVE change, deferred to #304 (apply while nobody is playing).
  description   = "minecraft-lan — Bedrock Dedicated Server for the LAN (Play → Friends → LAN Games). Serves the world pub.lan/minecraft/lan.json announces. NAS mount attached by the kalmia mount hook. Provisioned by minecraft-lan.yml (#297).\n"
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
    # A handful of players in a creative world; the server itself idles under 1 GiB.
    dedicated = 4096
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 16
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # Pinned so a rebuild keeps its Firewalla device identity (a new MAC
    # starts in Device Access Protection `learning`, WAN-blocked, and the
    # server needs the WAN for Xbox Live sign-in).
    mac_address = "BC:24:11:43:56:F5"
  }

  initialization {
    hostname = "minecraft-lan"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        # Below the Firewalla DHCP pool (.10-.254), so no reservation needed.
        address = "192.168.139.2/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    # operating_system: create-only. mount_point: attached by the mount hook.
    ignore_changes = [operating_system, mount_point]
  }
}

resource "terraform_data" "minecraft_lan_mounts" {
  for_each = local.minecraft_lan_mounts

  triggers_replace = [proxmox_virtual_environment_container.minecraft_lan.vm_id, each.key, each.value]

  provisioner "local-exec" {
    command = "${path.module}/mount-hook.sh"
    environment = {
      HOOK_HOST = "192.168.139.210" # pve4
      VMID      = proxmox_virtual_environment_container.minecraft_lan.vm_id
      MP        = each.key
      SPEC      = each.value
    }
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_container.minecraft_lan]
  }
}
