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
  # NAS-raw output is handled outside this resource. See cpitzi/music-curator
  # harvest/ (the repo left the lentago org on 2026-10-13).

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
    # Import-only: root@pam-created (keyctl); the API token cannot recreate it. Retire via #124.
    prevent_destroy = true
    ignore_changes  = [operating_system]
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

  # The claytonia job queue, read-only, for brasenia's fleet pane producer
  # (#180, brasenia#86). Attached host-side with `pct set 114 -mp1 ...,ro=1`
  # (docs/pub.md), like every bind mount: they are root@pam-only, and the
  # API token gets HTTP 403. Declared to record the live shape; ignored below.
  mount_point {
    volume    = "/mnt/neptune-lentago/claude-jobs"
    path      = "/srv/claude-jobs"
    read_only = true
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
    # Import-only: NAS bind mount is root@pam-only; the API token cannot recreate it.
    prevent_destroy = true
    # mount_point: both bind mounts are attached by root@pam with `pct set`
    # (docs/pub.md); a token-driven edit of them would fail with HTTP 403,
    # so they are never reconciled here (the claytonia workers' pattern).
    ignore_changes = [operating_system, mount_point]
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
    # Import-only: build template is gone and state is unrebuildable; guarded.
    prevent_destroy = true
    ignore_changes  = [operating_system]
  }
}

# Changing this input rebuilds LXC 118 (destroy, then create from the
# template) through the container's replace_triggered_by. Terraform fires that
# trigger only when this resource is updated or replaced, never when it is
# first created, so it landed alone (#212) and the rename changed it (#63).
resource "terraform_data" "brasenia_rebuild" {
  input = "kalmia#63: rebuilt as brasenia"
}

# LXC 118 — brasenia, the wall display's renderer and streamer (concept:
# http://pub.lan/brasenia/concept.md; runbook: docs/brasenia.md). Renders the
# viewport's panes (a sandboxed chromium, 3x scale) into a 4K HEVC HLS stream
# (:8080) that the office Roku's sideloaded dev channel plays. Credential-free:
# pub owns the Drive leg. No bind mounts and no keyctl, so the API-token CI
# apply can create this container from scratch. 4 cores / 4 GB because the 4K
# HEVC encoder alone is ~1.4 cores and ~620 MB, beside the renderer (#167, #194).
# Named lunaria until its runtime rename (#63) rebuilt it: `moved` carries the
# state across, and the trigger above turns the rename into one
# destroy-then-create of VMID 118, never two resources racing for the ID.
moved {
  from = proxmox_virtual_environment_container.lunaria
  to   = proxmox_virtual_environment_container.brasenia
}

resource "proxmox_virtual_environment_container" "brasenia" {
  node_name     = "pve4"
  vm_id         = 118
  description   = "brasenia — the wall display's renderer and streamer (192.168.139.19). Renders the viewport's panes to 4K HEVC HLS :8080 for the office Roku dev channel. Provisioned by brasenia.yml (docs/brasenia.md).\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  # nesting gives the container user namespaces, which Chromium's sandbox
  # needs before the renderer may show a site other than pub.lan (#194). The
  # token can create it: on create the provider sends nesting=1 alone, which
  # PVE allows with VM.Allocate. Changing features later is a root@pam step
  # (README "Rails": on update the provider sends every flag).
  features {
    nesting = true
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 10
  }

  network_interface {
    name        = "eth0"
    bridge      = "vmbr0"
    mac_address = "BC:24:11:8D:F9:C8" # the same device to the Firewalla across rebuilds
  }

  initialization {
    hostname = "brasenia"

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
    # Pipeline-recreatable (token-created, no keyctl/bind mount): not guarded.
    ignore_changes       = [operating_system]
    replace_triggered_by = [terraform_data.brasenia_rebuild]
  }
}
