# CLAUDE.md — workstation-ansible

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a brief
self-introduction as **Ansible Workstation Claude** — provisioning engineer for
the Ansible-based workstation build. One sentence is plenty; don't make a meal
of it.

## What this repo is

An Ansible rebuild of the `workstation-bootstrap` shell scripts: it turns a
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
  toggles (`docker_install`, `docker_daemon`, `enable_xrdp`, `enable_tlp`, …).
  `ansible_os_family` loads `vars/<family>.yml` for package-name differences
  (e.g. `batcat`↔`bat`, `fd-find`↔`fd`). The split is deliberate — it is NOT
  purely by distro (Crostini is Debian but daemonless; ubuntu_laptop is Debian
  but TLP-not-XRDP).
- **Privilege model**: the play runs `become: false`; system tasks opt into
  `become: true`, user-space tasks (nvm, `.bashrc`, Starship, VS Code settings)
  run as the user. Use `target_user` / `target_home`, never root's `$HOME`.
- **Roles**: common, languages, cloud_tools, containers, editors, cli_tools,
  shell, repos.

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

- **Debian-family profiles (`xubuntu`, `ubuntu_laptop`) are runnable now**;
  `crostini` is partial (sudo / `~/.local/bin` quirks).
- **Fedora** runs the shared toolchain plus Docker + VS Code from their dnf
  repos (`containers`/`editors` roles); the desktop layer is still pending.
- **Pending follow-ups**: the platform-specific roles — `remote_desktop`
  (XRDP + XFCE/KDE + SELinux/polkit) and `power` (TLP + ThinkPad charge
  thresholds, fwupd).

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
