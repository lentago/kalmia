## What does this PR do?

<!-- One or two sentences describing the change. Link the related issue. -->

Closes #

## Type of change

- [ ] Bug fix
- [ ] New role / feature
- [ ] Refactor (no functional change)
- [ ] Documentation update

## Checklist

- [ ] Tasks are idempotent (safe to re-run — `creates:`, guards, native module idempotency)
- [ ] FQCN used for all modules
- [ ] Change reflected across the affected profiles (apt + dnf) where applicable
- [ ] No secrets / tokens committed
- [ ] `ansible-lint` and `ansible-playbook --syntax-check` pass locally

## Terraform (only if this PR touches `terraform/`)

- [ ] Plan reviewed for `destroy` / `replace` (`-/+`) on any guest — a ForceNew attribute change destroys the guest
- [ ] Any replaced guest is recreatable by the `terraform@pve!kalmia` API token (no bind mounts, `keyctl`/non-`nesting` features, or other `root@pam`-only settings — otherwise pre-create per [the rail in terraform/README.md](../terraform/README.md#rails--non-nesting-feature-flags-require-rootpam-pre-create))
- [ ] A recent `vzdump` backup of each replaced guest exists
- [ ] Guest recreate feasibility verified (**required** if the plan deletes a guest — the `plan` job fails without this exact checked line; leave unchecked otherwise)

## Notes for reviewer

<!-- Trade-offs, open questions, areas of uncertainty. -->
