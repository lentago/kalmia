# ADR-0001: Ansible over more bash

**Status:** Accepted (2026-06-30; reconstructed 2026-08-13)

## Context

The `workstation-bootstrap` predecessor consisted of per-variant shell scripts
approaching ~1,000 lines each. Idempotency was entirely hand-rolled: every
"is it already installed?" check, the marker-bounded `.bashrc` block, and the
`((count++)) || true` traps were explicit guard logic spread across the scripts.
Adding a new target or toolchain required duplicating that guard logic.

The workstation toolchain — Docker, AWS/Terraform/k8s, Node/Go/Python, Starship,
Claude Code — is substantially shared across targets, with maybe 20% variation
per platform. The bash model had no good way to express "80% shared / 20%
per-platform" without copy-paste.

## Decision

Replace the bash scripts with Ansible, targeting `localhost` via a
self-provisioning `bootstrap.sh`. Idempotency becomes the module contract —
`ansible.builtin.*` and `community.general.*` modules handle "is it already
installed?" at the library level. The "80%/20%" split is expressed as a shared
role set with per-profile feature toggles and per-OS-family package-name
variables.

Every task uses FQCN (`ansible.builtin.*`, `community.general.*`). All
`command`/`shell` tasks carry explicit `creates:` guards, `stat` checks, or
`changed_when`/`failed_when` annotations. Re-running the play against a
provisioned box must be safe.

## Alternatives

**Puppet or Chef** (per fleet records — not verifiable in this repo's commit
history, recorded as rejected): agent-based CM tools; rejected because they are
heavier to bootstrap (agent + server or masterless setup), and the use case is a
single self-provisioning workstation, not a managed fleet. The overhead is not
justified.

**Nix / chezmoi** (per fleet records — recorded as noted but not taken): Nix
offers stronger reproducibility guarantees than Ansible — a derivation produces
the same closure regardless of prior state. chezmoi is purpose-built for dotfile
and home-directory management. Both were noted as valid approaches but not taken;
the tradeoff, per fleet records, was reproducibility-over-skill-transfer. The
operator context is "infrastructure operator, not a software engineer" (see
README authorship block) — a tool that is harder to read and debug without
domain knowledge trades short-term velocity for long-term operability.

**SaltStack** *(retrospective — not considered at the time)*: Similar capability
profile to Ansible; also supports agentless push and a pull/masterless mode. The
module ecosystem and community are smaller, and switching today would have no
material benefit over the existing Ansible investment. Assessed as **lateral**.

**Containerized dev environment (VS Code devcontainers / Distrobox)**
*(retrospective — not considered at the time)*: Would deliver consistent
toolchain environments per-project without touching the host machine. The use
case here is configuring the workstation itself — file manager, `.bashrc`,
system services, power management — not the project workspace inside it. A
container does not provision TLP, charge thresholds, Starship, or the system
apt baseline. Assessed as **worse** for this problem: it addresses a different
problem than the one being solved.

## Consequences

- Static CI via `ansible-lint` (syntax-check + lint) runs on every non-draft PR
  and is a required merge check.
- The bash scripts in `lentago/workstation-bootstrap` are kept during the
  transition period and superseded by this repo.
- Roles are: `common`, `languages`, `cloud_tools`, `containers`, `power`,
  `editors`, `cli_tools`, `shell`, `repos`.
- `become: false` is the play-level default; system tasks opt into `become:
  true`; user-space tasks (`nvm`, `.bashrc`, Starship, VS Code settings) run as
  the target user via `target_user` / `target_home` — never root's `$HOME`.
