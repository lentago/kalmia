# CLAUDE.md — kalmia

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a brief
self-introduction as **Kalmia Claude** — provisioning engineer for the Lentago
Labs workstation/VM/container provisioning system. One sentence is plenty;
don't make a meal of it.

## What this repo is

**Kalmia** (mountain laurel — the botanical codename line alongside `lentago`
and `solidago`) is the Lentago Labs provisioning system for workstations, VMs,
and containers. Renamed from `workstation-ansible` on 2026-07-04. Suite
boundary: **kalmia = local infra, solidago = cloud infra** (2026-07-04).

Two layers, split by what they own:

- **Ansible (repo root)** — what's *inside* a machine's OS: the original
  workstation provisioning described below.
- **Terraform (`terraform/`)** — Proxmox guest *existence and shape* on
  `homelab-cluster` (VMs/LXCs, resources, placement) via the `bpg/proxmox`
  provider — every guest **except the bullpen runner pool** (110–112,
  116–117), released to claytonia's `terraform/` 2026-07-07 (#37; products
  own their capacity). Roadmap, auth model, and the VM 100 (HAOS) handling
  rules live in [`terraform/README.md`](terraform/README.md) — read it
  before touching that layer.

The current form: an Ansible rebuild of the `workstation-bootstrap` shell
scripts. It turns a
fresh Linux box into a fully configured cloud-infrastructure dev workstation —
the same toolchain (Docker, AWS/Terraform/k8s, Node/Go/Python, Starship,
Claude Code, …) across four target profiles, expressed as idempotent roles
instead of ~1,000-line bash scripts. It supersedes the bash scripts in
[`lentago/workstation-bootstrap`](https://github.com/lentago/workstation-bootstrap)
(kept during the transition).

| Profile | Target | Package manager |
|---|---|---|
| `crostini` | Chromebook Crostini, legacy LXC container | apt |
| `baguette` | Chromebook ChromeOS M147+, containerless VM | apt |
| `xubuntu` | Xubuntu 24.04 (Proxmox VM) | apt |
| `fedora` | Fedora KDE (Proxmox VM) | dnf |
| `ubuntu_laptop` | Ubuntu Desktop LTS (bare-metal laptop) | apt |

## Architecture

- **Self-provisioning**: the play targets `localhost` (`connection: local`).
  `bootstrap.sh` installs Ansible and runs the play (or `ansible-pull`s the repo).
- **Profile + facts model**: `workstation_profile` (autodetected, or
  `-e workstation_profile=…`) loads `profiles/<name>.yml`, which sets feature
  toggles (`docker_install`, `docker_daemon`, `enable_tlp`, …).
  `ansible_os_family` loads `vars/<family>.yml` for package-name differences
  (e.g. `batcat`↔`bat`, `fd-find`↔`fd`). The split is deliberate — it is NOT
  purely by distro (legacy Crostini is Debian but daemonless; ubuntu_laptop is
  Debian but the lone TLP target). Nor is it purely by hostname: both Chromebook
  architectures are `penguin`, so autodetection also consults the LXC guest
  facts (`is_lxc_guest` in `site.yml`) to tell `crostini` from `baguette`.
- **Privilege model**: the play runs `become: false`; system tasks opt into
  `become: true`, user-space tasks (nvm, `.bashrc`, Starship, VS Code settings)
  run as the user. Use `target_user` / `target_home`, never root's `$HOME`.
- **Roles**: common, languages, cloud_tools, containers, power, editors,
  cli_tools, shell, repos.

## Editing guidelines

- **Idempotency is non-negotiable.** Every task must be safe to re-run — use
  `creates:`, `stat` guards, native module idempotency, and `changed_when` /
  `failed_when` on `command`/`shell`. (Killing hand-rolled idempotency is the
  whole reason we left bash.)
- **Use FQCN** (`ansible.builtin.*`, `community.general.*`) everywhere.
- **Keep the four profiles in sync.** A change to one platform's behavior should
  be reflected for the others, adapted per package manager — the same rule the
  bash repo enforced.
- **Prefer profile toggles + family vars** over hard-coding platform specifics
  inside a role.
- **No secrets in the repo.** `GH_TOKEN` only via the environment.

## Status

- **`xubuntu` and `fedora` are validated end-to-end on the testbeds**
  (Xubuntu 26.04 / Fedora 44; see [`docs/testbed.md`](docs/testbed.md)): from a
  pristine box, `bootstrap.sh` provisions clean (`failed=0`) and re-runs
  idempotently (`changed=0`), profile autodetected. Fedora pulls Docker + VS
  Code from their dnf repos (`containers`/`editors`).
- **`crostini` is validated end-to-end** on the Chromebook (Debian 13 trixie,
  2026-07-28): same bar — `failed=0` from pristine, `changed=0` on re-run.
  Docker is CLI-only (no daemon in the container) and the `common` role handles
  its hostname/`~/.local/bin` quirks. The first live run is what caught the Debian
  13 package-name breakage (`software-properties-common`, `dnsutils`) and the
  nvm `XDG_CONFIG_HOME` misplacement — none of which static CI can see.
- **`baguette` is validated end-to-end** on the Chromebook (Debian 13 trixie,
  added and validated 2026-08-06): same bar — `failed=0` from pristine
  (`ok=67`/`changed=39`), `changed=0` on re-run, profile autodetected. Docker
  Engine 29.7.2 comes up `enabled` + `active` and the daemon answers, which is
  the whole premise of splitting this profile off `crostini`. ChromeOS shipped
  the containerless VM in M143 behind `chrome://flags#containerless-crostini`,
  then made it the default for new Linux installs in M147; the Chromebook is
  now on it: `systemd-detect-virt` reports `kvm`, there is no
  `/run/systemd/container` or `/dev/.lxd-mounts`, `/sys/fs/cgroup` is
  `cgroup2fs`, and `/dev/kvm` is exposed. Ansible sees
  `virtualization_type: kvm` with an empty `virtualization_tech_guest` and
  `virtualization_role: host` — it does not look like a guest at all, which is
  why the discriminator tests for LXC rather than for KVM. Before this profile
  existed the hostname match sent the box to `crostini`, which installed
  `docker-ce-cli` with no daemon to talk to. Validated on a Lenovo IdeaPad
  Flex 5i Chromebook Plus (HWID board `TAEKO`, `brya` baseboard, i3-1315U);
  the host has 8 GB soldered LPDDR4x, of which the VM is given ~6.6 GB — the
  tightest-memory target in the fleet. Note that the box's own login MOTD says
  the containerless design became default "starting in ChromeOS version 143 and
  newer" — that wording conflates availability (M143, behind the flag) with
  default-for-new-installs (M147). M147 is the number that matters for
  profile-routing purposes; don't "correct" it to 143 off the MOTD.
- **`ubuntu_laptop` is proven idempotent on a provisioned host; a pristine
  first-run remains unproven** (#14). Run on a ThinkPad T14 Gen 2i, Ubuntu
  26.04, profile autodetected from `ansible_form_factor` (2026-08-06). This
  was a convergence, not a clean build: the ThinkPad is a daily driver
  previously provisioned by the `workstation-bootstrap` predecessor, with an
  existing, drifted `.bashrc` for the `shell` role's legacy-block migration
  path to strip. Three initial passes — `ok=42 changed=8 failed=1` (aborted
  at `editors : Install VS Code`, #73), `ok=58 changed=9 failed=0`, then
  `ok=57 changed=0 failed=0` idempotent — surfaced #73 (fixed in #74) and
  #75, neither reachable by static CI. Re-verified on the same host against
  merged `main` once #74/#78/#79 landed: a live run now reaches `ok=61
  changed=0 failed=0` in a single pass, and `--check` completes
  (`ok=60 changed=2 failed=0` — the two changes are non-destructive module
  artifacts, tracked in #80). All nine roles ran, including `power` (TLP, the
  ThinkPad charge-threshold drop-in, fwupd) — exercised for the first time on
  any profile. Still unproven: clean-build behavior (every "already present"
  branch is unexercised on this profile), whether a pristine box reaches
  `failed=0` in one pass, and the `repos` role (gated behind `clone_repos`,
  stayed `false` throughout).
- **No pending role follow-ups.** All core and platform roles are in; remote
  desktop (XRDP) was dropped as unused. Static CI can't catch runtime-only
  failures (removed plugins, host deps, idempotency) — real testbed runs do.

## Testbed

Two clean Proxmox VMs exist purely to provision against and reset:
`xubuntu-test` (`192.168.139.16`, `xubuntu` profile) and `fedora-xfce-test`
(`192.168.139.253`, `fedora` profile), each with a `pristine` snapshot so every
run starts from a fresh box. See [`docs/testbed.md`](docs/testbed.md) for access,
the rollback-reset loop, run commands, and the 26.04 / XFCE caveats. The VMs are
Home-Claude-managed in the Lentago lab (pve5), outside this repo's CI.

## CI

Four checks are merge-blocking (marked **required** below); see Workflow.

- **Ansible Lint** (`.github/workflows/ansible-lint.yml`): `--syntax-check` +
  `ansible-lint` on every non-draft PR. **required** (`ansible-lint`)
- **ShellCheck** (`.github/workflows/shellcheck.yml`): static analysis of
  `bootstrap.sh` via the shared workflow. **required**
  (`shellcheck / shellcheck`)
- **docs-check** (`.github/workflows/docs-check.yml`): relative markdown link
  resolution via the shared workflow. Deliberately not path-filtered — a
  required check whose workflow never triggers stays "Expected" forever and
  deadlocks every non-matching PR. **required** (`docs-check / docs-check`)
- **terraform** (`.github/workflows/terraform.yml`): `changes` → `validate` →
  `plan` → `apply` for the `terraform/` layer. `gate` is the aggregate job that
  always runs on PRs, so a PR touching no Terraform passes it on skipped
  dependencies. **required** (`gate`)
- **Claude** workflows: `@claude` responder + (manual) PR review. Not required.

## Workflow

PR workflow + auto-merge arming is fleet-wide; see `~/repos/CLAUDE.md`. Work on
the branch created for the issue. The branch ruleset gates on PR + squash-merge
(squash is the only permitted merge method; zero required approvals) **and on
four required status checks** — `gate`, `ansible-lint`, `shellcheck / shellcheck`,
and `docs-check / docs-check`. They are merge-blocking, not advisory: a red check
holds the PR. Branches do not have to be up to date with `main` to merge
(`strict_required_status_checks_policy` is false), so a stale-but-passing branch
still merges — which means a green PR can still break `main` if something landed
underneath it.
