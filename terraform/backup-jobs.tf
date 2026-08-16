# Cluster vzdump backup jobs — imported brownfield (#30). Source of truth for
# these values at import time: `pvesh get /cluster/backup --output-format json`
# on pve (i.e. /etc/pve/jobs.cfg). This puts the backup *policy* under the
# same drift detection as the guests it protects.
#
# Provider limitation (v0.111.1): `proxmox_backup_job` tracks neither `comment`
# nor the VMID `exclude` list. Both live jobs carry a comment, and
# guests-weekly relies on `all 1` + `exclude 100` (everything EXCEPT HAOS).
# Terraform leaves those two fields unmanaged: import and in-place updates
# never touch them (the PVE update API is partial and the provider only
# deletes keys it knows), but a destroy/recreate would drop them — recreating
# guests-weekly without `exclude 100` would silently pull VM 100 into the
# weekly job on top of its 4-hourly one. Hence `prevent_destroy` on both.
# Upstream `exclude` support landed in bpg/terraform-provider-proxmox#2983
# (post-v0.111.1, unreleased); adopting it once released is tracked in #104.

import {
  to = proxmox_backup_job.haos_4h
  id = "haos-4h"
}

resource "proxmox_backup_job" "haos_4h" {
  id       = "haos-4h"
  schedule = "*/4:00"
  storage  = "neptune"
  enabled  = true

  # VM 100 (HAOS) only — the mission-critical ~4h RPO.
  vmid = ["100"]

  mode     = "snapshot"
  compress = "zstd"

  notes_template = "{{guestname}} (auto 4h)"
  repeat_missed  = true

  prune_backups = {
    "keep-last"    = "12"
    "keep-daily"   = "7"
    "keep-weekly"  = "4"
    "keep-monthly" = "3"
  }

  lifecycle {
    # Losing this job breaks the ~4h HAOS RPO, and recreation would drop the
    # unmanaged comment. Deliberate removal = flip this flag first.
    prevent_destroy = true
  }
}

import {
  to = proxmox_backup_job.guests_weekly
  id = "guests-weekly"
}

resource "proxmox_backup_job" "guests_weekly" {
  id       = "guests-weekly"
  schedule = "sun 03:00"
  storage  = "neptune"
  enabled  = true

  # All guests except VM 100 — the exclusion lives in the unmanaged
  # `exclude 100` field (see file header). Do not "fix" a plan diff here by
  # dropping `all`; the live pairing is `all 1` + `exclude 100`.
  all = true

  mode     = "snapshot"
  compress = "zstd"

  notes_template = "{{guestname}} (auto weekly)"
  repeat_missed  = true

  prune_backups = {
    "keep-weekly"  = "4"
    "keep-monthly" = "3"
  }

  lifecycle {
    # Recreation would drop the unmanaged `exclude 100` (and comment) — the
    # weekly job would silently start including HAOS. See file header.
    prevent_destroy = true
  }
}
