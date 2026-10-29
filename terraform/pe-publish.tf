# LXC 123 — pe-publish: self-hosted GitHub Actions runner for the personal
# cpitzi/professional-endeavors repo (label `pe-publish`). On every push to
# its main it builds the MkDocs site into the pub.lan web share and renews two
# brasenia panes (#190). Deliberately not LXC 115: that runner holds this
# repo's PVE token and runs the kalmia and claytonia applies, so a personal
# repo's workflows with write access to pub's web root don't belong on it.
# In-guest provisioning (runner agent, packages): pe-publish.yml,
# docs/pe-publish.md.
#
# Its bind mounts are attached by the mount hook below, not by this resource:
# bind mounts are root@pam-only and the token gets HTTP 403. The hook makes
# the guest pipeline-recreatable WITH its mounts, so it is not guarded; see
# README.md § Bind mounts — the mount hook.

locals {
  # Narrowest grants that serve the job: the wiki dir and the two pane dirs
  # it renews, each writable. Each value must equal its line in the node's
  # allowlist (pve_host_mount_hook_allow) or the hook refuses it. The share is
  # CIFS forced to uid/gid 101000 (container 1000), mode 0770 — writes need
  # the gid-1000 `webdrop` group in the guest, the same group pub's Caddy
  # reads through.
  pe_publish_mounts = {
    mp0 = "/mnt/neptune-lentago/web/wiki,mp=/srv/www/wiki"
    mp1 = "/mnt/neptune-lentago/web/viewport/panes/search-map,mp=/srv/www/viewport/panes/search-map"
    mp2 = "/mnt/neptune-lentago/web/viewport/panes/search-board,mp=/srv/www/viewport/panes/search-board"
  }
}

resource "proxmox_virtual_environment_container" "pe_publish" {
  node_name     = "pve4"
  vm_id         = 123
  description   = "pe-publish — GitHub Actions runner for cpitzi/professional-endeavors (label pe-publish): builds the wiki into pub.lan/wiki and renews its brasenia panes. NAS mounts attached by the kalmia mount hook (#190). Provisioned by pe-publish.yml.\n"
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

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # Pinned so a rebuild keeps its Firewalla device identity (a new MAC
    # starts in Device Access Protection `learning`, WAN-blocked).
    mac_address = "BC:24:11:50:FB:34"
  }

  initialization {
    hostname = "pe-publish"

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    ip_config {
      ipv4 {
        # Below the Firewalla DHCP pool (.10-.254), so no reservation needed.
        address = "192.168.139.5/24"
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
resource "terraform_data" "pe_publish_mounts" {
  for_each = local.pe_publish_mounts

  triggers_replace = [proxmox_virtual_environment_container.pe_publish.vm_id, each.key, each.value]

  provisioner "local-exec" {
    command = "${path.module}/mount-hook.sh"
    environment = {
      HOOK_HOST = "192.168.139.210" # pve4
      VMID      = proxmox_virtual_environment_container.pe_publish.vm_id
      MP        = each.key
      SPEC      = each.value
    }
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_container.pe_publish]
  }
}
