# minecraft-runner — minecraft-builds CI runner (LXC 124, pve4)

A self-hosted GitHub Actions runner registered to the private
`cpitzi/minecraft-builds` repo with label `minecraft` (#293). That repo builds
Minecraft worlds in code and ships Bedrock copies of them. Two workflows run
here:

- **canary**, on every PR and push to `main`: converts a small test world with
  the pinned Chunker and checks each item on its fidelity checklist on a Bedrock
  Dedicated Server.
- **release**, dispatched after a world is tagged: converts that version,
  checks it block by block against the Java save, publishes it to
  `http://pub.lan/minecraft/` and attaches it to a GitHub Release.

Both need the LAN, so this is not a hosted runner. The Bedrock server can't be
downloaded by script, and delivery is pub.lan. It is also not LXC 115, for the
same reason as pe-publish: that runner holds this repo's PVE token.

| | |
|---|---|
| Guest | LXC 124 `minecraft-runner`, pve4, 192.168.139.3, Debian 12, 4c / 10 GiB / 32 GB |
| Defined in | [`terraform/minecraft-runner.tf`](../terraform/minecraft-runner.tf) (CI apply-on-merge) |
| Provisioned by | `minecraft-runner.yml` + the `minecraft_runner` role |
| Runner | `/opt/actions-runner`, user `runner` (in `webdrop`, gid 1000), systemd service from `svc.sh` |
| Labels | `self-hosted`, `Linux`, `X64`, `minecraft` |
| Job state | `/opt/minecraft-ci`: Bedrock server (`server` → `bds-<version>`), block schema, Chunker jar, conversions, Python venv, bare clone of the world repo |

## No job guard

pe-publish has a job-started hook that refuses everything but one workflow on
`main` (#195), because bullpen agents push branches to its repo. This runner
has none. `cpitzi/minecraft-builds` is not a bullpen project, and its canary
workflow gates PRs, so running branch code is this runner's job. It serves
that one private repo.

That means any job, PR canaries included, runs as `runner` with write access to
`/srv/www/minecraft`, the pub.lan worlds page. Scoping that write to the release
job would not narrow who can publish. The only people who can push a branch to
the repo can also push `main` and dispatch the release. pub.lan is LAN-only. If
the repo ever gains a writer who shouldn't publish, such as a bullpen
registration, add a pe-publish-style guard first.

## Environment

The role writes these into `/opt/actions-runner/.env`. The repo's tools read
them, and they keep everything a job needs outside the workspace that each
checkout wipes:

| Variable | Value |
|---|---|
| `MCB_BEDROCK_HOME` | `/opt/minecraft-ci` |
| `VENV` | `/opt/minecraft-ci/venv` |
| `WORLD_GIT_DIR` | `/opt/minecraft-ci/worlds.git` |
| `MCB_WEB_DIR` | `/srv/www/minecraft` |

## Mounts

| In the container | NAS share (`/volume1/lentago/…`) | Mode |
|---|---|---|
| `/srv/www/minecraft` | `web/minecraft` | rw |
| `/srv/minecraft-ci` | `cpitzi/minecraft-ci` | ro |

`/srv/minecraft-ci` holds the Bedrock Dedicated Server zip, downloaded by hand
from minecraft.net, and `mojang-blocks.json` from `Mojang/bedrock-samples`. The
role checks both against the SHA-256 pins in its defaults before unpacking. To
upgrade the Bedrock server, stage the new zip there, bump
`minecraft_runner_bds_version` and its hash in a PR, and re-run the playbook.

Like pe-publish's, these are bind mounts of pve4's CIFS mount, attached by the
mount hook from its allowlist; see
[`terraform/README.md` § Bind mounts — the mount hook](../terraform/README.md#bind-mounts--the-mount-hook).

## Build / rebuild

1. **Allowlist:** the mounts are in `pve_host_mount_hook_allow`. Push it to pve4
   before the guest's first apply, or the hook refuses them (see
   [`docs/pve-host.md`](pve-host.md)).
2. **Guest and mounts:** merged `terraform/minecraft-runner.tf` creates the CT,
   and the apply attaches both mounts. Check from pve4:
   `pct exec 124 -- findmnt -t cifs`.
3. **Provision**, on the container, with a registration token (valid one hour)
   minted from a workstation where `gh` can administer the repo. The token goes
   over stdin, so it never appears in a command line on pve4:

   ```bash
   gh api -X POST repos/cpitzi/minecraft-builds/actions/runners/registration-token -q .token |
   ssh root@pve4 "pct exec 124 -- env LC_ALL=C.UTF-8 bash -lc '
     read -r MINECRAFT_RUNNER_TOKEN && export MINECRAFT_RUNNER_TOKEN
     apt-get update && apt-get install -y git ansible
     git clone https://github.com/lentago/kalmia /opt/kalmia 2>/dev/null || git -C /opt/kalmia pull --ff-only
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml minecraft-runner.yml'"
   ```

   Re-running on a registered runner (a role change, a new Bedrock server pin)
   needs no token: the role only asks for one while `/opt/actions-runner/.runner`
   is missing.

   ```bash
   ssh root@pve4 "pct exec 124 -- env LC_ALL=C.UTF-8 bash -lc '
     git -C /opt/kalmia pull --ff-only &&
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml minecraft-runner.yml'"
   ```

4. **Check:** the runner shows `online`
   (`gh api repos/cpitzi/minecraft-builds/actions/runners`), and a canary run
   passes.

**Firewalla:** as for pe-publish, a new MAC starts in quarantine (no internet)
until it's approved in the Firewalla app. The MAC is pinned in Terraform, so a
rebuild keeps that approval.
