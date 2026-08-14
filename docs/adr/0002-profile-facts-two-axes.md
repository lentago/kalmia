# ADR-0002: Profile + facts model on two orthogonal axes

**Status:** Accepted (2026-06-30; refined 2026-08-07 with baguette split; reconstructed 2026-08-13)

## Context

Five provisioning targets are needed:

| Profile | Target | Package manager |
|---|---|---|
| `crostini` | Chromebook Crostini (legacy LXC container) | apt |
| `baguette` | Chromebook ChromeOS M147+, containerless VM | apt |
| `xubuntu` | Xubuntu 24.04 (Proxmox VM) | apt |
| `fedora` | Fedora KDE (Proxmox VM) | dnf |
| `ubuntu_laptop` | Ubuntu Desktop LTS (bare-metal laptop) | apt |

These targets differ along two independent dimensions that are not reducible to
one another:

1. **Feature toggles** — whether Docker runs a daemon (`docker_daemon`), whether
   TLP power management is active (`enable_tlp`), whether SSH is a base service.
   These are not predictable from distro alone: `crostini` is Debian but runs
   Docker CLI-only (no daemon inside an LXC container); `ubuntu_laptop` is also
   Debian but is the sole TLP target.

2. **Package names** — `batcat` vs `bat`, `fd-find` vs `fd`, etc. These are
   OS-family differences, not feature differences.

A third complication emerged in 2026-08-07 with ChromeOS M147: the containerless
Baguette environment is also hostname `penguin` — identical to the legacy Crostini
container — but is a full crosvm KVM guest with systemd, cgroups v2, and
`/dev/kvm`. Without further discrimination, autodetect would silently send a
Baguette box to the `crostini` profile, installing `docker-ce-cli` with no daemon
behind it (`docker info` returns a client and nothing else).

## Decision

**Feature toggles and package names are tracked on two separate, orthogonal axes**:

- `workstation_profile` (autodetected, or `-e workstation_profile=…`) loads
  `profiles/<name>.yml`, which sets feature toggles.
- `ansible_os_family` (a built-in Ansible fact) loads `vars/<family>.yml`, which
  sets package-name maps.

Profile autodetect uses host facts. For the Chromebook hostname collision,
autodetect discriminates on **LXC guest facts, not hostname or KVM presence**:

```yaml
'crostini' if (ansible_hostname == 'penguin' and is_lxc_guest | bool)
'baguette' if ansible_hostname == 'penguin'
```

The test is for LXC, not for KVM: Baguette reports `virtualization_role: host`
with an empty `virtualization_tech_guest` and does not look like a guest to
Ansible at all. A KVM-based test would misfire. The `| bool` filter is
load-bearing: `is_lxc_guest` renders as the string `'False'` on non-LXC hosts,
and in Jinja2 every non-empty string is truthy without the coercion.

## Alternatives

**Hostname routing alone** (recorded, rejected — demonstrated by the baguette
incident, PR #71): Before `baguette` existed, `penguin` matched `crostini`.
ChromeOS M147 made the containerless VM the default for new Linux installs, so a
new Chromebook provisioned after M147 received a `crostini` profile that installed
`docker-ce-cli` with no daemon behind it. This failure mode is what motivated the
explicit profile split and the LXC-discriminated autodetect.

**Distro-keyed-only profiles** *(retrospective — not considered at the time)*: A
single `debian.yml` profile for all Debian targets. This would force `crostini`,
`baguette`, `ubuntu_laptop`, and `xubuntu` into the same feature set. The laptop
needs TLP; the Crostini container must not run a daemon; the Baguette VM needs the
full Docker Engine. A single distro profile cannot express these differences
without in-role conditionals that recreate the per-profile split anyway. Assessed
as **worse**.

**Tag-based play split (no profile abstraction)** *(retrospective — not considered
at the time)*: Run with `--tags docker,tlp,shell` etc. to select features, with
per-host variable files for package names. This works but loses the
self-documenting "what does a baguette box get" profile concept: you must read the
tag list and the host vars to reconstruct what a given machine receives. Profiles
make the per-target contract explicit in one file. Assessed as **lateral**, with
lower readability for the operator use case.

## Consequences

- `is_lxc_guest | bool` in `site.yml` is a load-bearing guard; removing the
  `| bool` filter breaks Chromebook autodetection silently (tests pass; live run
  misfires).
- ChromeOS does not auto-upgrade existing installs, so both Chromebook profiles
  coexist permanently.
- Profile count grew from 4 to 5 with PR #71 (2026-08-07); the fifth profile was
  validated end-to-end on a Lenovo IdeaPad Flex 5i Chromebook Plus (HWID `TAEKO`,
  `brya` baseboard, i3-1315U).
- The split is not purely by distro, not purely by hostname, and not purely by
  virtualization type — any future profile routing must account for all three axes
  before adding a discriminator.
