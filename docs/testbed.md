# Testbed — clean-slate VMs for provisioning runs

Two freshly-installed, **non-customized** Proxmox VMs that exist only to be
provisioned, rolled back, and provisioned again. They are the clean targets for
the `xubuntu` and `fedora` profiles: boot a pristine box, run the play, confirm
the end state, roll back, repeat. A-fresh-box bootstrap and idempotency are
exactly what they let you exercise.

They live on the Lentago Labs homelab cluster (Proxmox node **pve5**) and are
managed by Home Claude (run from `~`); see `~/CLAUDE.md` for cluster topology.

## The two boxes

| VMID | Name | OS (as installed) | IP | Profile | Autodetect |
|---|---|---|---|---|---|
| 120 | `xubuntu-test` | Xubuntu 26.04 LTS (XFCE) | `192.168.139.16` | `xubuntu` | ✓ guest VM → `xubuntu` |
| 121 | `fedora-xfce-test` | Fedora 44 (XFCE) | `192.168.139.253` | `fedora` | ✓ Fedora → `fedora` |

Both autodetect to the correct profile via `site.yml`'s `pre_tasks`
(`ansible_distribution == 'Fedora'` → `fedora`; guest VM → `xubuntu`), so no
`-e workstation_profile=` is required — though you can pass it to be explicit.

## Access

- User **`tester`**, password **`provision1`**, full sudo (Debian `sudo` group /
  Fedora `wheel`).
- The **pve** node's root SSH key is in `tester`'s `authorized_keys`, so from
  `pve`: `ssh tester@192.168.139.16` (xubuntu) /
  `ssh tester@192.168.139.253` (fedora). Add your own key for other origins.
- `sshd` and `qemu-guest-agent` are already running on both.

## The reset loop (the whole point)

Each VM carries a cold snapshot named **`pristine`** — the clean, just-installed,
pre-customization state with install media detached. Reset to it between runs so
every test starts from an identical fresh box:

```bash
# from the laptop or any host that can reach pve
ssh pve 'ssh pve5 "qm rollback 120 pristine && qm start 120"'   # xubuntu-test
ssh pve 'ssh pve5 "qm rollback 121 pristine && qm start 121"'   # fedora-xfce-test
```

Rollback restores the powered-off pristine disk; `qm start` boots a clean box.
DHCP hands back the same IPs (`.16` / `.253`).

## Running a provisioning test

The build is self-provisioning — run it **on** the box. SSH in, then either
clone-and-run or one-shot self-provision (what a real new machine does):

```bash
# on the test VM, from a clone:
git clone https://github.com/lentago/workstation-ansible.git
cd workstation-ansible
WORKSTATION_PROFILE=xubuntu ./bootstrap.sh        # or omit — it autodetects

# …or fully fresh, no clone:
curl -fsSL https://raw.githubusercontent.com/lentago/workstation-ansible/main/bootstrap.sh \
  | WORKSTATION_PROFILE=xubuntu bash
```

`bootstrap.sh` installs Ansible (apt/dnf), pulls the Galaxy collections, and runs
`site.yml`. **A second run is the idempotency check** — it should report
`changed=0`. Then roll back to `pristine` and try the next change.

## Known caveats

The boxes are deliberately a notch newer than the profiles' nominal targets —
useful for catching drift, but expect a couple of things:

- **Xubuntu is 26.04; the `xubuntu` profile is written against 24.04.** Mostly
  version-agnostic, but the Docker CE **apt repo is keyed on the release
  codename** (`resolute`). Docker's repo lags Ubuntu releases — if there's no
  `dists/resolute` upstream yet, the `containers` role won't find packages.
  Override `docker_apt_repo_*` to a `noble` (24.04) codename for the run if it
  bites, and note it as a real finding for the 26.04 target.
- **The Fedora testbed is XFCE; the `fedora` profile comment says "Fedora KDE."**
  The toolchain is desktop-agnostic, so this doesn't change what the roles
  install — just don't be thrown by the label mismatch.
- **The pristine baseline already has `openssh-server`, `qemu-guest-agent`, and
  the `tester` user** — i.e. the profiles' `base_extra_packages` / `base_services`
  are pre-satisfied (the boxes have to be reachable). Those tasks report `ok`;
  everything else the play installs (Docker, languages, cloud tools, Starship,
  VS Code, Claude Code, …) starts absent.

## Rebuilding the testbed from scratch

If a VM is wedged beyond a snapshot rollback, Home Claude can recreate the
baseline. The artifacts live on the homelab, not in this repo:

- Remastered unattended-install ISOs on the Neptune NAS iso store
  (`/mnt/pve/neptune/template/iso/`): `xubuntu-26.04-autoinstall.iso` (Ubuntu
  autoinstall), `fedora-xfce-oemdrv.iso` (kickstart `OEMDRV` volume), plus the
  Fedora Everything netinstall ISO.
- Source configs on `pve`: `/root/vmbuild/ubuntu/{autoinstall/user-data,grub.cfg}`
  and `/root/vmbuild/fedora/oemdrv/ks.cfg`.

Ask Home Claude (run from `~`) to rebuild — it's live cluster work, not a repo PR.
