# Cluster vzdump backup jobs — imported brownfield (#30). Source of truth for
# these values at import time: `pvesh get /cluster/backup --output-format json`
# on pve (i.e. /etc/pve/jobs.cfg). This puts the backup *policy* under the
# same drift detection as the guests it protects.
#
# `comment` and the VMID `exclude` list were unmanaged live state until
# provider v0.112.0 (exclude, bpg/terraform-provider-proxmox#2983) and
# v0.115.0 (comment, #3107); both are now modelled and match jobs.cfg (#104).
# guests-weekly's selection is `all 1` + `exclude 100,102` (everything EXCEPT
# HAOS and xubuntu-ws, which have their own jobs) — keep the pair together. `prevent_destroy` stays on both: a
# recreate is still a backup-policy gap, even if it no longer loses fields.

import {
  to = proxmox_backup_job.haos_4h
  id = "haos-4h"
}

resource "proxmox_backup_job" "haos_4h" {
  id       = "haos-4h"
  schedule = "*/4:00"
  storage  = "neptune"
  enabled  = true
  comment  = "HAOS 4-hourly auto-backup"

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
    # Losing this job breaks the ~4h HAOS RPO. Deliberate removal = flip
    # this flag first.
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
  comment  = "Non-critical guests weekly auto-backup"

  # All guests except VM 100 (HAOS, 4-hourly) and VM 102 (xubuntu-ws,
  # daily). The live pairing is `all 1` + `exclude`; dropping `exclude` would
  # silently pull both into the weekly job.
  all     = true
  exclude = ["100", "102"]

  mode     = "snapshot"
  compress = "zstd"

  notes_template = "{{guestname}} (auto weekly)"
  repeat_missed  = true

  prune_backups = {
    "keep-weekly"  = "4"
    "keep-monthly" = "3"
  }

  lifecycle {
    # Losing this job leaves every non-HAOS guest without backups.
    # Deliberate removal = flip this flag first.
    prevent_destroy = true
  }
}

resource "proxmox_backup_job" "workstation_daily" {
  id       = "workstation-daily"
  schedule = "02:00"
  storage  = "neptune"
  enabled  = true
  comment  = "Primary workstation daily auto-backup"

  # VM 102 (xubuntu-ws) only: the primary persistent Claude workspace, ~24h
  # RPO instead of guests-weekly's 7 days. Guest agent on, so snapshot mode
  # freezes the filesystem rather than taking a crash-consistent copy.
  vmid = ["102"]

  mode     = "snapshot"
  compress = "zstd"

  notes_template = "{{guestname}} (auto daily)"
  repeat_missed  = true

  prune_backups = {
    "keep-daily"   = "7"
    "keep-weekly"  = "4"
    "keep-monthly" = "3"
  }

  lifecycle {
    # Losing this job drops the primary workstation back to weekly backups.
    # Deliberate removal = flip this flag first.
    prevent_destroy = true
  }
}
