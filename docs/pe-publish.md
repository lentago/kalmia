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
| Job guard | `/usr/local/bin/pe-publish-job-guard.sh`, the job-started hook: only `publish.yml` on `main` runs (see below) |

It is deliberately not LXC 115 `gha-runner`. That runner holds this repo's
`PROXMOX_VE_API_TOKEN` and runs the kalmia and claytonia applies, so a personal
repo's workflows with write access to pub's web root don't run there.

## Job guard

The runner takes any job in the repo labelled `pe-publish`, and a branch can
edit any workflow. It can point a `pull_request` job at
`runs-on: [self-hosted, pe-publish]`, or drop `publish.yml`'s
`if: github.ref == 'refs/heads/main'` and dispatch it from itself. Bullpen
agents push branches to that repo, so the runner enforces main-only itself
(#195). The workflow's own guard is editable by the branch.

`ACTIONS_RUNNER_HOOK_JOB_STARTED` in `/opt/actions-runner/.env` points at the
root-owned `/usr/local/bin/pe-publish-job-guard.sh`. It lets a job through
only when all three are exact matches:

| Variable | Must be |
|---|---|
| `GITHUB_REPOSITORY` | `cpitzi/professional-endeavors` |
| `GITHUB_REF` | `refs/heads/main` |
| `GITHUB_WORKFLOW_REF` | `cpitzi/professional-endeavors/.github/workflows/publish.yml@refs/heads/main` |

The values come from the job's `github` context, which the server builds. The
runner starts the hook with an empty environment plus that context, so a
workflow's `env:` can't spoof them.

A refusal has to stop the job, not just fail it. The hook is the first entry
in the job's step queue. A non-zero exit only marks the job failed, and the
runner still runs every later step whose condition holds, so a branch could
add `if: always()`. So on refusal the hook:

1. writes an `::error` annotation and a `pe-publish-job-guard` journal line,
2. sends SIGTERM to its `Runner.Worker`. The worker shuts down, skips every
   remaining step (post steps included) without evaluating its condition, and
   fails the job,
3. sends SIGKILL to the worker if it hasn't been cancelled within 30 s.

In the run, a refused job fails on the **Set up runner** step with
`Refused <workflow_ref> (ref <ref>)`, and every later step is skipped. The
runner service stays up for the next job.

**Residual gap:** a job cancelled after *Set up job* finishes but before the
hook's first line runs (a window of milliseconds) still runs its
`if: always()` steps. A cancellation during *Set up job* itself ends the job
with no steps run. Closing that window means the runner can't write the share
until something outside the job approves it. That is a pull-based publish, not
a hook.

To check: `journalctl -t pe-publish-job-guard` on the container lists the
refusals, and `grep HOOK /opt/actions-runner/.env` shows the wiring.

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
