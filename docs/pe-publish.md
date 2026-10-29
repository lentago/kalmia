# pe-publish — professional-endeavors publish runner (LXC 123, pve4)

A self-hosted GitHub Actions runner registered to the private
`cpitzi/professional-endeavors` repo with label `pe-publish` (#190). On every
push to that repo's `main`, its `publish.yml` workflow builds the MkDocs site
into the pub.lan web share (`http://pub.lan/wiki/`) and renews its two brasenia
wall panes, so merges reach pub.lan without anyone opening a session.

| | |
|---|---|
| Guest | LXC 123 `pe-publish`, pve4, 192.168.139.5, Debian 12, 2c / 1 GiB / 8 GB |
| Defined in | [`terraform/pe-publish.tf`](../terraform/pe-publish.tf) (CI apply-on-merge) |
| Provisioned by | `pe-publish.yml` + the `pe_publish` role |
| Runner | `/opt/actions-runner`, user `runner` (in `webdrop`, gid 1000), systemd service from `svc.sh` |
| Labels | `self-hosted`, `Linux`, `X64`, `pe-publish` |

It is deliberately not LXC 115 `gha-runner`. That runner holds this repo's
`PROXMOX_VE_API_TOKEN` and runs the kalmia and claytonia applies, so a personal
repo's workflows with write access to pub's web root don't run there.

## Mounts

| In the container | NAS share (`/volume1/lentago/…`) | Mode |
|---|---|---|
| `/srv/www/wiki` | `web/wiki` | rw |
| `/srv/www/viewport/panes/search-map` | `web/viewport/panes/search-map` | rw |
| `/srv/www/viewport/panes/search-board` | `web/viewport/panes/search-board` | rw |

They are deliberately narrow. Only those three directories are the share;
everything else under `/srv/www`, including `/srv/www/viewport` itself, is
the container's own rootfs, and anything written there never reaches pub.lan.

They are bind mounts of pve4's CIFS mount of the share, which forces every file
to uid/gid 101000 (container 1000) at mode 0770. Membership of the gid-1000
`webdrop` group is what lets `runner` write, and pub's Caddy reads through the
same group. Ownership and mode can't be changed on the share, so copy with
`rsync -rt` (or `--no-perms --no-owner --no-group`), not `-a`.

Bind mounts are root@pam-only, so Terraform doesn't set them: the CI apply
calls the pve4 mount hook, which attaches each mount only if it matches the
node's allowlist. A rebuilt container gets its mounts back with no manual step.
See [`terraform/README.md` § Bind mounts — the mount hook](../terraform/README.md#bind-mounts--the-mount-hook)
and [`docs/pve-host.md` § Mount hook](pve-host.md#mount-hook).

## Build / rebuild

1. **Guest and mounts:** merged `terraform/pe-publish.tf` creates the CT and the
   apply attaches its three mounts. Check them from pve4:
   `pct exec 123 -- findmnt -t cifs`.
2. **Provision**, on the container, with a registration token (valid one hour)
   minted from a workstation where `gh` can administer the repo. The token is
   needed only while the runner is unregistered. Later runs skip registration.

   ```bash
   TOKEN=$(gh api -X POST repos/cpitzi/professional-endeavors/actions/runners/registration-token -q .token)
   ssh root@pve4 "pct exec 123 -- env LC_ALL=C.UTF-8 PE_PUBLISH_RUNNER_TOKEN=$TOKEN bash -lc '
     apt-get update && apt-get install -y git ansible
     git clone https://github.com/lentago/kalmia /opt/kalmia 2>/dev/null || git -C /opt/kalmia pull --ff-only
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml pe-publish.yml'"
   ```

3. **Check:** the runner shows `online` under the repo's Settings → Actions →
   Runners (`gh api repos/cpitzi/professional-endeavors/actions/runners`).

A rebuild registers a new runner, and `--replace` takes over the old entry's
name. Delete any leftover offline entry from the repo's runner list.

**Firewalla:** a new MAC is put in the Firewalla's group 45 `Quarantine` (no
internet) the moment it appears, so step 2 fails until the device is approved
in the Firewalla app (device → group → remove Quarantine). The MAC is pinned
in Terraform, so a rebuild keeps that approval. See `terraform/README.md`
§ Runner notes.
