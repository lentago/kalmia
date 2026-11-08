# LXC 124 — minecraft-runner: self-hosted GitHub Actions runner for the personal
# cpitzi/minecraft-builds repo (label `minecraft`, #293). Its canary workflow
# converts a test world with Chunker and checks it on a Bedrock Dedicated
# Server on every PR; its release workflow converts a tagged world, checks it
# and publishes it to pub.lan (web/minecraft). Both need the LAN: the Bedrock
# server can't be downloaded by script, and delivery is pub.lan. Same reasons
# as pe-publish (LXC 123) for not using LXC 115. In-guest provisioning:
# minecraft-runner.yml, docs/minecraft-runner.md.
#
# Bind mounts come from the mount hook, as for pe-publish; see README.md
# § Bind mounts — the mount hook.

locals {
  # Each value must equal its line in the node's allowlist
  # (pve_host_mount_hook_allow) or the hook refuses it. The share is CIFS
  # forced to uid/gid 101000 (container 1000), mode 0770: the guest's runner
  # user reads and writes through the gid-1000 `webdrop` group.
  minecraft_runner_mounts = {
    # The pub.lan worlds page the release workflow publishes.
    mp0 = "/mnt/neptune-lentago/web/minecraft,mp=/srv/www/minecraft"
    # The staged Bedrock Dedicated Server zip, read-only (it can't be fetched
    # by script, so a rebuild unpacks it from here).
    mp1 = "/mnt/neptune-lentago/cpitzi/minecraft-ci,mp=/srv/minecraft-ci,ro=1"
  }
}

resource "proxmox_virtual_environment_container" "minecraft_runner" {
  node_name     = "pve4"
  vm_id         = 124
  description   = "minecraft-runner — GitHub Actions runner for cpitzi/minecraft-builds (label minecraft): Chunker conversions checked on a Bedrock Dedicated Server, releases to pub.lan/minecraft. NAS mounts attached by the kalmia mount hook. Provisioned by minecraft-runner.yml (#293).\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
  }

  cpu {
    cores = 4
  }

  memory {
    # Chunker runs with -Xmx6G; the Bedrock server and Python checks share the rest.
    dedicated = 10240
    swap      = 1024
  }

  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # Pinned so a rebuild keeps its Firewalla device identity (a new MAC
    # starts in Device Access Protection `learning`, WAN-blocked).
    mac_address = "BC:24:11:7F:FF:0A"
  }

  initialization {
    hostname = "minecraft-runner"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        # Below the Firewalla DHCP pool (.10-.254), so no reservation needed.
        address = "192.168.139.3/24"
        gateway = "192.168.139.1"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    # operating_system: create-only. mount_point: attached by the mount hook
    # (below); a token-driven edit of a bind mount gets HTTP 403.
    ignore_changes = [operating_system, mount_point]
  }
}

# One hook call per mount, re-run whenever the container is created, replaced
# or updated (the hook is a no-op for a mount already in place).
resource "terraform_data" "minecraft_runner_mounts" {
  for_each = local.minecraft_runner_mounts

  triggers_replace = [proxmox_virtual_environment_container.minecraft_runner.vm_id, each.key, each.value]

  provisioner "local-exec" {
    command = "${path.module}/mount-hook.sh"
    environment = {
      HOOK_HOST = "192.168.139.210" # pve4
      VMID      = proxmox_virtual_environment_container.minecraft_runner.vm_id
      MP        = each.key
      SPEC      = each.value
    }
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_container.minecraft_runner]
  }
}
