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
  provider. Brownfield import in progress; roadmap, auth model, and the
  VM 100 (HAOS) handling rules live in [`terraform/README.md`](terraform/README.md)
  — read it before touching that layer.

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
| `crostini` | Chromebook Crostini (Debian) | apt |
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
  purely by distro (Crostini is Debian but daemonless; ubuntu_laptop is Debian
  but the lone TLP target).
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
- **`crostini` and `ubuntu_laptop` are runnable by design but not yet
  live-tested** — Crostini lives on the Chromebook (Docker CLI-only; the
  `common` role handles its hostname/`~/.local/bin` quirks); `ubuntu_laptop` is
  bare metal and adds TLP + ThinkPad charge thresholds + fwupd via the `power`
  role (`enable_tlp`).
- **No pending role follow-ups.** All core and platform roles are in; remote
  desktop (XRDP) was dropped as unused. Static CI can't catch runtime-only
  failures (removed plugins, host deps, idempotency) — real testbed runs do.

## Testbed

Two clean Proxmox VMs exist purely to provision against and reset:
`xubuntu-test` (`192.168.139.16`, `xubuntu` profile) and `fedora-xfce-test`
(`192.168.139.253`, `fedora` profile), each with a `pristine` snapshot so every
run starts from a fresh box. See [`docs/testbed.md`](docs/testbed.md) for access,
the rollback-reset loop, run commands, and the 26.04 / XFCE caveats. The VMs are
Home-Claude-managed on the homelab (pve5), outside this repo's CI.

## CI

- **Ansible Lint** (`.github/workflows/ansible-lint.yml`): `--syntax-check` +
  `ansible-lint` on every non-draft PR.
- **ShellCheck** (`.github/workflows/shellcheck.yml`): static analysis of
  `bootstrap.sh` via the shared workflow.
- **Claude** workflows: `@claude` responder + (manual) PR review.

## Workflow

PR workflow + auto-merge arming is fleet-wide; see `~/repos/CLAUDE.md`. Work on
the branch created for the issue. The branch ruleset gates on PR + squash-merge
(not on status checks), so Ansible Lint + ShellCheck are advisory signal.
