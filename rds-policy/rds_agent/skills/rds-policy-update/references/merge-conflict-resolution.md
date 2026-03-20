# Merge Conflict Resolution

## Customization Preservation

All partner customizations preserved by default. No classification as
intentional vs stale (stale workaround detection is future scope).

## Non-overlapping Changes

Reference changes fields the partner hasn't customized -- apply automatically.

Example: reference bumps `spec.channel: "4.18"` to `"4.20"`, partner hasn't
patched channel -- update automatically.

## True Conflicts

Both sides changed the same field. Flag for human review with:
- Field path
- Reference old value and new value
- Partner's current value
- Why the reference changed (from EXPLAIN output)
- User chooses: accept reference, keep partner, or provide different value

Example: reference changes `spec.deviceType: netdevice` to `vfio-pci`,
partner has `netdevice` as explicit patch -- conflict, user decides.

## CR Removal

Removing a CR from a policy does NOT remove it from clusters. Need
`complianceType: mustnothave` for actual removal. If reference includes
a removal policy, include it in the merge.

If partner has customizations on a CR being removed, flag for user --
they may still need it.

## New CRs from Reference

Only add CRs that are new and required in the target version. Do NOT
add optional or commented-out reference CRs. The reference examples
include many optional configurations -- only the partner's existing
CRs plus genuinely new required CRs belong in the output.

When adding a required new CR, place in closest-fit existing partner
policy based on:
1. Same wave grouping
2. Similar content (e.g. logging CRs go with existing logging policy)
3. If no clear fit, ask the user which policy to add it to

Preserve partner naming conventions for the policy.

## Version-Pinned Values

Partners may intentionally pin a version that differs from the current
OCP version. Common examples:
- CatalogSource image tags pinned to an older release
- Subscription channels set to a specific version
- Image references with explicit version tags

Detection: if a version-bearing field doesn't match the current (old)
OCP version, the partner likely pinned it intentionally.

Action: do NOT auto-update. Mark with `⚠ REVIEW` and present to user
with the current value and what the "expected" bump would be. Let the
user decide.

## Uncertainty Rule

When not 100% sure a change is safe, **leave the partner's value alone**
and flag it. Present:
- What the checklist says to change
- What the partner currently has
- Why you're uncertain

It is always safer to flag something and let the user decide than to
silently apply a change that might break their deployment.

## New Functionality from User

When the user requests new features (e.g. "add logging health check"),
treat as an additional merge step after reference updates. The user's
description guides what to add; reference CRs for the target version
provide the implementation.