# ADR-0005: Release runner pool to claytonia; keep LXC 115 as shared CI substrate

**Status:** Accepted (2026-07-07; reconstructed 2026-08-13)

## Context

The bullpen runner pool (claude-runner 1–5, VMIDs 110–112/116–117) provides
agent-worker capacity — headless Claude workers that take queued jobs and open
PRs across Lentago Labs repos (distinct from GitHub Actions CI: issue #37
itself draws the line, calling LXC 115 "shared CI substrate, not agent
capacity"). The pool was initially placed
under kalmia's Terraform layer because kalmia was the first repo to have a
Terraform layer and the runners live on the LAN Proxmox cluster.

As claytonia (the agent-fleet repo) grew its own `terraform/` root
(lentago/claytonia#51), two competing ownership models emerged:

- **kalmia holds the runners** — consistent with "kalmia = local infra", but
  puts capacity decisions for a product (claytonia) in a repo the product does
  not control.
- **claytonia holds the runners** — consistent with "products own their capacity";
  claytonia controls how many workers it needs and when they are scaled.

A separate consideration: LXC 115 `gha-runner` is the LAN self-hosted runner that
executes kalmia's own Terraform applies (ADR-0004). Its availability is a
prerequisite for kalmia's CI to function. That runner must not depend on
claytonia's capacity — if claytonia's pool were unavailable, kalmia could not
apply its own Terraform, including any changes needed to restore the pool.

## Decision

**Release the bullpen runner pool (VMIDs 110–112/116–117) to claytonia's
`terraform/`** (issue #37, PR #40). kalmia removes the `bullpen_runner` resources
from `containers.tf`; claytonia imports the same guests into its own state via
`terraform import`. No live guest is recreated or interrupted.

**LXC 115 `gha-runner` stays in kalmia** (PR #40): shared CI substrate must not
depend on claytonia's own workers. The statement is explicit in the PR: kalmia
keeps every other guest, including LXC 115.

**The state-surgery order is load-bearing** (documented in issue #37 and PR #40):
`terraform state rm` of all five `bullpen_runner` instances must happen **before**
this PR merges. Merging first would cause kalmia's apply to plan a destroy of five
live runners. The correct order — state rm first, then merge — means the PR's
apply is a no-op for the released guests (they become unmanaged in kalmia and are
subsequently imported by claytonia). Never reverse steps 1 and 2.

The suite boundary — **kalmia = local infra, solidago = cloud infra** — does not
cleanly accommodate non-Proxmox worker targets (which would have no home in kalmia
regardless). This is an additional argument for the move.

## Alternatives

**Keep the runner pool in kalmia and add a delegation interface** (implied
alternative — not explicitly recorded but the "products own capacity" principle
argues against it): kalmia could expose a variable or module for claytonia to
configure runner count, with kalmia still managing the Terraform resources. This
preserves centralized guest management but puts a product's capacity decisions in
an infra repo, creating an ongoing coordination requirement whenever claytonia
needs to scale. Assessed as **worse** for the ownership-clarity goal.

**Move the runner pool to a dedicated `infra-runners` repo** *(retrospective —
not considered at the time)*: A third repo, owned by no product, that manages
shared CI capacity. This is a legitimate organizational pattern for large teams.
For a two-repo lab (kalmia/claytonia), it adds a dependency repo with no net
clarity gain: someone still owns the scaling decisions, and claytonia is the
natural owner. Assessed as **lateral** — correct at scale, unnecessary here.

**Keep the pool hand-managed** *(retrospective — not considered at the time)*:
Remove the runners from Terraform entirely and manage them via the PVE UI. The
enforced-surface discipline (ADR-0003/0004) argues directly against this: once
guests are under Terraform, unmanaging them reintroduces the drift problem that
motivated the IaC adoption. Assessed as **worse**.

## Consequences

- The five bullpen runner VMIDs (110–112/116–117) are unmanaged from kalmia's
  perspective after PR #40. Their existence and shape are claytonia's concern.
- LXC 115 `gha-runner` is kalmia-owned infrastructure and kalmia-depended-upon CI
  substrate. Any plan touching it gets extra scrutiny.
- The state-surgery order is documented as a precedent: whenever guest ownership
  moves between repos in this fleet, `state rm` before the owning repo's merge,
  never after.
- Future non-Proxmox worker targets (e.g., cloud runners) have a clear home:
  claytonia, not kalmia.
