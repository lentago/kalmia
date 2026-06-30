# workstation-ansible

Ansible rebuild of [`workstation-bootstrap`](https://github.com/lentago/workstation-bootstrap) —
idempotent, role-based provisioning that turns a fresh Linux box into a fully
configured cloud-infrastructure dev workstation. Same toolchain, prompt, and
workflow across four targets, expressed as Ansible roles instead of
~1,000-line bash scripts.

**Authorship:** The Ansible code and documentation in this repo are co-written
with [Claude](https://claude.ai) (Anthropic). I direct the work and review the
output; Claude writes the code. I'm an infrastructure operator, not a software
engineer — please don't read this repo as a portfolio of coding ability.

## Why Ansible

The bash scripts worked, but every "is it already installed?" guard, the
marker-bounded `.bashrc` block, and the `((count++)) || true` traps were
hand-rolled idempotency. Ansible makes idempotency the module contract, models
the "80% shared / 20% per-platform" split as roles + variables, and
self-provisions a fresh box with one command.

## Targets (profiles)

| Profile | Target | Package manager |
|---|---|---|
| `xubuntu` | Xubuntu 24.04 (Proxmox VM) | apt |
| `ubuntu_laptop` | Ubuntu Desktop LTS (bare-metal laptop) | apt |
| `crostini` | Chromebook Crostini (Debian container) | apt |
| `fedora` | Fedora KDE (Proxmox VM) | dnf |

## Quick start

Self-provision a fresh box (installs Ansible, then runs the play):

```bash
curl -fsSL https://raw.githubusercontent.com/lentago/workstation-ansible/main/bootstrap.sh \
  | WORKSTATION_PROFILE=xubuntu bash
```

Or from a clone:

```bash
git clone https://github.com/lentago/workstation-ansible.git
cd workstation-ansible
WORKSTATION_PROFILE=xubuntu ./bootstrap.sh
# …or, with Ansible already installed:
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml -e workstation_profile=xubuntu
```

The profile autodetects from host facts when unset. Run a subset with tags, e.g.
`ansible-playbook site.yml --tags cli,shell`.

## How it works

- **Self-provisioning** against `localhost` (`connection: local`).
- **Profile + facts model**: `workstation_profile` selects `profiles/<name>.yml`
  (feature toggles like `docker_daemon`, `enable_tlp`);
  `ansible_os_family` selects `vars/<family>.yml` (package-name differences such
  as `batcat`↔`bat`). The toggles exist because the split isn't purely by
  distro — Crostini is Debian but daemonless; the Ubuntu laptop is Debian but
  the lone TLP power-management target.
- **Privilege model**: user context by default; system installs escalate with
  `become: true`; user config (nvm, `.bashrc`, Starship, VS Code settings) runs
  as you.

## Roles

| Role | Installs / configures |
|---|---|
| `common` | base packages, base services, global git config |
| `languages` | Python, Node.js (nvm), Go |
| `cloud_tools` | AWS CLI v2, Granted, Terraform (tfswitch), kubectl, eksctl, Helm |
| `containers` | Docker Engine + Compose (daemon optional) |
| `power` | TLP power management, ThinkPad charge thresholds, fwupd (opt-in) |
| `editors` | VS Code (+ extensions), Claude Code |
| `cli_tools` | jq, yq, bat, fd, ripgrep, fzf, tmux, direnv, Starship, … |
| `shell` | marker-managed `.bashrc` block + Starship config |
| `repos` | GitHub CLI + clone your repos (opt-in) |

## Status

**All four profiles are runnable.** Fedora installs the shared toolchain plus
Docker + VS Code from their dnf repos; `ubuntu_laptop` adds TLP power
management, ThinkPad charge thresholds, and fwupd via the `power` role; Crostini
runs Docker CLI-only with hostname-resolution and `~/.local/bin` fixes from the
`common` role.

---

*Part of the [Lentago Labs](https://github.com/lentago) portfolio.*
