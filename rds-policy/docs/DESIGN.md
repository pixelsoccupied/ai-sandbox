# RDS Policy Agent — AI-Driven Policy Generation for Version Upgrades

> This document covers the problem statement and core workflow. Architecture, merge engine design, and operational details (error handling, rollback, security, observability) are covered in follow-up documents.

## 1. Context

Telco customers deploy OpenShift clusters with Day 2 configs based on the RDS (Reference Design Specification).
Upstream reference configs live in [telco-reference](https://github.com/openshift-kni/telco-reference), applied as ACM policies via PolicyGenerator.
Users customize per environment (e.g., number of SRIOV VFs, NIC assignments, CPU pinning) and per site (IPs, VLANs, hostnames) via patches and hub templating. They will also extend the configuration with additional custom content based on their environment and requirements.
POC targets the RAN DU SNO profile (`telco-ran/` in telco-reference). The agent doesn't hardcode RAN DU SNO assumptions or knowledge — it works with whatever configuration (configuration CRs, Policy, or PolicyGenerator) structure it finds.

**Problem:** When a partner is ready to move their solution to a new OCP version, they must build a set of policies which incorporate content from 3 distinct places:
1. The new upstream RDS reference ("upstream" throughout this doc means the RDS reference content in telco-reference or ztp-site-generator)
2. Their specific modifications made in the current set of policies
3. Their desired new content/features

This means merging upstream changes with their existing customizations — a manual process that requires understanding what changed, why, and how it interacts with site-specific overrides. Today this is slow, error-prone, and requires deep RDS + operator knowledge.

The overall goal is **policy generation for version upgrades**: a customer running 4.18 needs to update to 4.20 — give them the final set of policies. The inputs are:
1. Previous and new upstream RDS content (e.g. 4.18 → 4.20)
2. Customer customizations on top of the previous version
3. Optionally, additional content to be added to the policy set

**Goal:** Significantly shorten the time it takes a user to get from "I have a valid set of policies for 4.18" to "I have a valid set of policies for 4.20" — via 3-way merge (old upstream, new upstream, customer customizations). Validity is confirmed by driving a lab cluster to compliance.

**POC Scope:** Same hardware, just going up a version (4.18 policies to 4.20 policies). The cluster is assumed to already be upgraded to the target OCP version — the agent generates the matching Day 2 config policies for human review and approval, it doesn't perform the platform upgrade itself.

**Scope:** Starting from an existing deployment of clusters managed by an ACM hub cluster. The hub has policies which define the desired configuration state for the clusters at the current (e.g. 4.18) release. The agent provides the following capabilities:
- Assists the user by creating a complete set of policies for the next release (e.g. 4.20) through merging new RDS content and existing customizations from the existing deployment
- Verifies the syntactical correctness of the policies
- Suggests improvements or corrections to the policies based on compliance status retrieved from the hub where the candidate policies are applied — application of the policies requires human-in-the-loop (git PR, user applies them, etc.)

POC targets the full RAN DU SNO PolicyGenerator set:
- [acm-common-ranGen.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/acm-common-ranGen.yaml) (common — waves 1-2)
- [acm-group-du-sno-ranGen-templated.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/hub-side-templating/acm-group-du-sno-ranGen-templated.yaml) (group — wave 10)
- [acm-example-sno-site.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/acm-example-sno-site.yaml) (site — wave 100)

**Out of scope (POC):** See section 4 for details.
- Stale workaround detection and removal
- Fleet rollout orchestration
- Cluster upgrade orchestration (platform upgrades, IBU seed images — agent handles Day 2 config policies only)
- New hardware + version upgrade
- Fresh installs
- Integration with anomaly detection

---

## 2. How RDS Configs Work

The agent operates at whichever layer the user's config lives — **PolicyGenerator YAML + reference CRs** (the authored source) or **Policy CRs** directly. PolicyGenerator is the starting point for most users, but the agent can work at the Policy CR level when PolicyGenerator's abstraction gets in the way. Note: this is a one-way fallback — you can generate Policy CRs from PolicyGenerator, but not the reverse. Key points:

- **Reference CRs** are base templates with expected user variations in some fields. PolicyGenerator patches these with kustomize-like overlays.
- **PolicyGenerator YAML** defines policies: manifest references, patches (hardcoded or hub templates), placement, remediation. This is where user customizations live — explicit as `patches:`.
- **Hub templates** (`{{hub fromConfigMap ... hub}}`) in patches are resolved at policy evaluation time from ConfigMaps on the hub. Users may replace these with hardcoded values for their site.
- The merge must handle both template systems: preserve user's hardcoded overrides of hub templates, and update upstream structural changes.

**Upstream source:** [openshift-kni/telco-reference](https://github.com/openshift-kni/telco-reference) with version branches (`release-4.17`, `release-4.18`, etc.). Each branch has QA'd reference CRs + PolicyGenerator configs for that OCP version. [quay.io/openshift-kni/ztp-site-generator is the production source for these CRs — the agent's upstream source should be pluggable. POC uses the Git repo for convenience; production should use the released container manifests.]

The agent uses PolicyGenerator YAMLs + reference CRs from telco-reference on the **upstream side** (EXPLAIN) to diff between RDS versions. On the **customer side** (MERGE), the agent reads Policy CRs directly from the hub cluster — no dependency on the customer having PolicyGenerator YAML. No ArgoCD dependency.

---

## 3. Core Workflow

The **agent** is an AI model with access to tools (K8s API, Git, PolicyGenerator for upstream analysis, merge engine) that reasons about the problem, decides which tools to call, and executes multi-step workflows.

### Agent Capabilities

The agent provides three distinct capabilities that are independently valuable and composed into the end-to-end upgrade flow:

1. **EXPLAIN** — Analyze upstream diff between RDS versions and produce a structured impact summary with per-CR detail. Useful standalone for planning, independent of merging.
2. **MERGE** — 3-way merge of upstream changes with customer customizations. Matches CRs by GVK + resource identity with confidence-based matching (exact/fuzzy/none). Reuses EXPLAIN output to scope the merge. Useful standalone for generating merged configs without the full validation flow.
3. **VALIDATE** — Given NonCompliant policies on a hub, diagnose the root cause from violation messages, fix the config, and retry. Useful standalone for any compliance issue, not just upgrades. Could integrate with or complement anomaly detection work.

The end-to-end upgrade workflow (DETECT → EXPLAIN → MERGE → VALIDATE → COMPLIANT) composes all three: EXPLAIN informs MERGE, and VALIDATE is invoked to drive policies to compliance.

The agent uses its tools as needed — some steps are straightforward tool usage (fetch upstream branches, run PolicyGenerator to diff upstream versions, read Policy CRs from hub), others require reasoning about the results (interpret a diff, resolve a conflict, diagnose a failure). For POC, we minimize the reasoning needed by treating all user changes as intentional customizations (no classification) and escalating all true conflicts to the user.

### End-to-End Upgrade Flow

The agent assists users in getting policies from NonCompliant → Compliant against the target RDS version. A version upgrade creates the non-compliance gap (new desired state vs. old actual state). The agent helps resolve it, with human approval at every transition.

**Example prompts:**
- *"Here is the set of 4.18 policies that I'm using right now. 4.20 is now available. Generate the equivalent set for it."*
- *"4.20 is now available. Review this hub cluster. Generate the new policies."*

#### Step 1: DETECT + READINESS

Determine that an upgrade is needed, extract the required inputs, and gather the current policy set.

Required inputs (from prompt or cluster inspection):
- **Cluster** — which hub cluster to read the current Policy CRs from. The hub is the source of truth for what's deployed. The agent uses placement bindings to identify which policies apply to a given managed cluster.
- **Current version** — what RDS version and profile (e.g. DU vs Core vs Hub) the customer is running (e.g. 4.18)
- **Target version** — what RDS version to upgrade to (e.g. 4.20)

Once inputs are resolved, this step:
1. Fetches both upstream version branches from telco-reference (e.g. `release-4.18` and `release-4.20`)
2. Validates that the target version branch exists and contains reference CRs and PolicyGenerator examples
3. Reads the customer's current Policy CRs from the hub cluster via K8s API (`oc get policy -A`), filtering by placement bindings to the specified cluster. The hub is the source of truth for what's deployed.

The outputs of this step — old upstream, new upstream, and customer's current configs — are the three inputs to the 3-way merge. The two upstream versions feed into EXPLAIN; all three feed into MERGE.

#### Step 2: EXPLAIN

Using the two upstream versions from Step 1, summarize what changed so the user understands the impact before merging. This step is also valuable as a **standalone capability** — it only needs the two upstream versions, not the customer's configs.

- Agent diffs the old and new upstream reference configs from telco-reference (file-by-file and field-by-field within PolicyGenerator YAMLs and reference CRs). PolicyGenerator is used here to understand the upstream structure.
- Classifies each change: new CRs added, CRs removed, field updates (version bumps, channel changes, structural modifications)
- Output is structured at the **individual CR level** — each changed CR includes its full GVK, resource name, change type (added/removed/modified), and which specific fields changed. This level of detail is what enables MERGE to do reliable matching against the customer's CRs (including fuzzy matching when names differ). For example, if upstream has 3 different `SriovNetworkNodePolicy` resources, EXPLAIN tracks each one individually.
- Not just raw structured data — also provides a human-readable impact summary with context and references to published RDS docs
- Serves both as a user-facing report and as the structured input to Step 3 (MERGE). By producing a precise set of changed CRs with their GVKs and field-level diffs, EXPLAIN reduces the scope of MERGE's fuzzy matching — MERGE only needs to search the customer's policies for CRs that correspond to what actually changed upstream, not the entire reference set

*HITL: human can review before proceeding.*

Example output (4.18 → 4.20):

```
Upstream changes: release-4.18 → release-4.20

Added CRs:
  + ClusterLogForwarder/instance (GVK: logging.openshift.io/v1)
    Adds health check for cluster-logging operator.
    Fields: spec.pipelines, spec.outputs
  + ClusterLogging/instance (GVK: logging.openshift.io/v1)
    Cleanup CR for CLO v5 resources (per upstream release notes).
    Fields: spec.managementState, spec.collection

Modified CRs:
  SriovNetworkNodePolicy/sriov-nnp-du (GVK: sriovnetwork.openshift.io/v1)
    Fields changed: spec.deviceType (netdevice → vfio-pci)
  Subscription/sriov-network-operator (GVK: operators.coreos.com/v1alpha1)
    Fields changed: spec.channel (4.18 → 4.20)

Unchanged: 58 of 62 reference CRs.

Policy-level: name suffix convention *-4.18 → *-4.20
```

#### Step 3: MERGE

Produce updated Policy CRs that incorporate upstream changes while preserving customer customizations. MERGE works with Policy CRs read from the hub (not PolicyGenerator YAML). It reuses the upstream change classification from EXPLAIN (or invokes it if not already run).

- Reads **all** of the user's policy configs and builds an inventory of every managed CR across all policies. Customers may have more than the standard 3 files — some environments have 5-10+ policies with different names and structures than the upstream reference.
- Correlates the customer's CRs against upstream reference CRs — not by policy name or file structure, but by the CRs themselves. Matching has three confidence levels:
  - **Exact match** (same GVK + same resource name, e.g. `SriovNetworkNodePolicy/sriov-nnp-du`) → high confidence, include upstream changes in merge plan automatically
  - **Fuzzy match** (same GVK, different name, but similar spec fields — e.g. customer has `SriovNetworkNodePolicy/my-sriov` which looks structurally like upstream's `sriov-nnp-du`) → agent reasoning needed. The agent compares spec fields and structure to assess similarity, then **asks the user to confirm** before treating it as a match
  - **No match** → custom content, left untouched

  This is where agent reasoning adds real value — examining field structure to identify renamed or restructured CRs. The agent never silently assumes a fuzzy match; low confidence always escalates to the user.
- For matched CRs, compares the customer's version against EXPLAIN's upstream change set to detect overlaps and conflicts. Where upstream changes don't touch customized fields, they are included in the merge plan directly. User customizations are preserved by default — the merge does not attempt to classify them as intentional vs. stale (see Future Scope). True conflicts (user and upstream both modified the same field) are flagged for human review at the HITL gate.
- Produces a merge plan (add/update/remove CRs, mapped back to whichever policy file they live in).
- Merge engine writes the plan to local user files in batch (no cluster interaction).

*HITL: human reviews merged output via git PR or direct review. The agent does not apply without explicit user request — the user can apply manually or ask the agent to apply on their behalf.*

Example — applying the changes from EXPLAIN above to a customer's config. Note: the customer's policy names and structure differ from upstream — the agent matches by CR content, not policy name.

EXPLAIN reported these upstream changes (4.18 → 4.20):
```
Added:    ClusterLogForwarder/instance, ClusterLogging/instance
Modified: SriovNetworkNodePolicy/sriov-nnp-du — spec.deviceType changed
Modified: Subscription/sriov-network-operator — spec.channel 4.18 → 4.20
```

Customer's config uses different policy names and has a renamed SRIOV CR:
```
Customer's 4.18 config:                     Merged 4.20 output:

policies:                                    policies:
- name: my-network-policy                    - name: my-network-policy
  manifests:                                   manifests:
    - path: SriovNNPolicy.yaml                   - path: SriovNNPolicy.yaml
      patches:                                     patches:
      - metadata:                                  - metadata:
          name: my-sriov        ← fuzzy match        name: my-sriov
      - spec:                                      - spec:
          nicSelector:                                 nicSelector:
            pfNames: ["ens5f0"] ← kept                   pfNames: ["ens5f0"]
          deviceType: netdevice ← conflict!            deviceType: vfio-pci  ← flagged

- name: my-common-policy                     - name: my-common-policy
  manifests:                                   manifests:
    - path: Logging.yaml                         - path: Logging.yaml
                                                 - path: ClusterLogForwarder.yaml
                                  ← added          (new upstream CR)
                                                 - path: ClusterLogging.yaml
                                  ← added          (new upstream CR)
```

How the agent resolved this:
- `SriovNetworkNodePolicy/my-sriov` — fuzzy matched to upstream's `sriov-nnp-du` (same GVK, similar spec). Agent asked user to confirm before merging. Customer's `pfNames` customization preserved. `deviceType` conflict flagged — both upstream and customer have a value, user must decide.
- `ClusterLogForwarder/instance` and `ClusterLogging/instance` — new upstream CRs, added to `my-common-policy` (agent chose the closest-fit policy based on existing logging content).
- Policy names (`my-network-policy`, `my-common-policy`) — customer's naming preserved, not overwritten with RDS reference naming convention.

#### Step 4: VALIDATE

Progressively validate merged policies — each phase catches a different class of errors. When validation fails, the agent diagnoses the root cause, proposes a fix, and the user approves before retrying.

*HITL: human must explicitly approve before any policy is applied to any cluster. Each validation retry requires human approval — the agent proposes a fix, the user reviews and approves before the next attempt. If max retries are exceeded, the agent escalates to human.*

**Phase 1: Schema validation** *(POC scope)*
- Client-side dry run of merged Policy CRs against K8s API — catches schema violations, unknown fields, invalid references
- This proves the config is well-formed. It does NOT prove functional correctness.

**Phase 2: Inform mode (semantic correctness)** *(post-POC)*
- With human approval, apply policies to lab hub in `inform` mode — **no changes are made to managed clusters**
- Policy controller evaluates desired state against cluster and reports compliance
- Catches: missing CRDs, unresolvable hub templates, ConfigMap references, field mismatches
- This proves the config is semantically valid against the cluster's actual state. It does NOT prove the config will work at runtime (operators may reject it).
- If NonCompliant: agent proposes fix → human approves → retry from Phase 1

**Phase 3: Enforcement on lab canary (functional correctness)** *(post-POC)*
- Only proceeds if inform mode passes and **human explicitly approves**
- Create CGU (ClusterGroupUpgrade) targeting canary cluster(s) in a lab environment
- TALM (Topology Aware Lifecycle Manager) enforces on canary — catches runtime failures that inform mode can't surface: operator webhook rejections, resource conflicts, node scheduling failures
- If the canary cluster gets a bad config, it is recoverable via policy deletion or rollback — this is a lab, not production
- If failure: agent proposes fix → human approves → retry from Phase 1
- Loop until canary passes (max N retries)

#### Step 5: COMPLIANT

All policies report Compliant on the lab hub — the cluster's actual state matches the desired config for the target RDS version. Notify user. Production fleet rollout is out of scope for POC (see Future Scope).

#### ESCALATION (at any step)

Max retries exceeded → alert humans, log full context.

---

## 4. Future Scope

### Stale Workaround Detection and Removal

Customers accumulate workarounds (patches for version-specific bugs/gaps) that become stale when the fix ships upstream. The agent would classify user additions as intentional customizations vs. stale workarounds, cross-referencing against release notes and a knowledge base of known issues and fixes. This turns the 3-way merge into an N-way merge. May become a separate capability.

### Fleet Rollout Orchestration

After canary validation passes, batched rollout to remaining fleet via CGU (maxConcurrency from config). Per-cluster failures → agent attempts per-site fix.

### AI-Driven New Cluster Onboarding

Out of scope for POC (ZTP handles this today). Future: after a new cluster is provisioned and operators installed, the agent discovers hardware (SriovNetworkNodeState → NICs/VFs, node capacity → CPUs/memory) and generates site-specific reference CRs autonomously. Challenges: chicken-and-egg (operators must be installed first), sensible defaults when multiple valid configs are possible, and source of network information (VLANs, IPs, subnets) is an open question — likely requires user input or integration with an external IPAM/network inventory system.

### New Hardware + Version Upgrade

Upgrade from 4.18 → 4.20 with different hardware. Requires both version merge AND hardware-aware config generation.

### GitOps Integration (prod)

In production, agent commits to Git → ArgoCD syncs → PolicyGenerator generates policies. PR-based approval flow optional. For POC, the agent generates merged Policy CRs and can apply them to the hub if the user explicitly requests it.

---

## 5. Assumptions

1. **TALM/CGU is installed** on the hub cluster
2. **PolicyGenerator format** (not older PolicyGenTemplate) is used
3. **RAN DU SNO profile** for POC (as stated in section 1)
4. **Same hardware** across version upgrades (POC scope)
5. **telco-reference repo** has a version branch for the target version. Agent assumes branch content is valid; branch validation is not in scope.
6. **Lab/staging environment** available for canary validation — the agent never applies policies to production clusters without explicit human approval and fleet rollout orchestration (future scope)

---

## 6. Deployment Context

The agent runs standalone — either locally (developer workstation, CI) or in-cluster on the ACM hub. It requires: Git access (telco-reference), PolicyGenerator binary (for upstream analysis in EXPLAIN), and K8s API access to the hub. The agent does not apply without explicit user request.

The agent exposes APIs (e.g. A2A protocol) so that the broader ecosystem (OpenShift Lightspeed, other tools) can integrate with it. The agent is not embedded in any specific product — it is a standalone service that others consume.