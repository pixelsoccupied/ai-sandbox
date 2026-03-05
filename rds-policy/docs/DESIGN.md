# RDS Policy Agent — AI-Driven Policy Generation for Version Updates

> This document covers the problem statement and core workflow. Architecture, merge engine design, and operational details (error handling, rollback, security, observability) are covered in follow-up documents.

## 1. Context

Telco partners deploy OpenShift clusters with Day 2 configs based on a Reference Design Specification (RDS).
The upstream version of these reference configs live in [telco-reference](https://github.com/openshift-kni/telco-reference).
Users customize per environment (e.g., number of SRIOV VFs, NIC assignments, CPU pinning) and per site (IPs, VLANs, hostnames) via patches and hub templating. They will also extend the configuration with additional custom content based on their environment and requirements.
The resulting customized policies are applied to clusters through ACM.
This Proof-Of-Concept targets the RAN DU SNO profile (`telco-ran/` in telco-reference). The agent doesn't hardcode RAN DU SNO assumptions or knowledge — it works with whatever configuration (configuration CRs, Policy, or PolicyGenerator) structure it finds.

### Problem

When a partner is ready to move their solution to a new OCP version, they must build a set of policies which incorporate content from 3 distinct places:
1. The new RDS reference content (from telco-reference or ztp-site-generator)
2. Their specific modifications made in the current set of policies on top of the previous RDS version
3. Optionally, additional "new" content/features to be added to the policy set

This means merging reference changes with their existing customizations — a manual process that requires understanding what changed, why, and how it interacts with site-specific overrides. Today this is slow, error-prone, and requires deep RDS + operator knowledge.

The overall goal is **policy generation for version updates**: a partner running 4.18 needs to update to 4.20 — give them the final set of policies. The inputs are:
1. Previous and new RDS reference content (e.g. 4.18 → 4.20)
2. Partner customizations on top of the previous RDS version
3. Optionally, additional "new" content/features to be added to the policy set

### Goal

Significantly shorten the time and effort it takes a user to get from "I have a valid set of policies for 4.18" to "I have a valid set of policies for 4.20".

### Scope

Generation of a new set of Policies which are correct for the new release version and desired set of changes from the user. In this PoC the agent generates the matching Day 2 config policies for human review and approval — it doesn't perform the platform upgrade itself. The cluster is assumed to already be at the target OCP version.

Starting from an existing deployment of clusters managed by an ACM hub cluster. The hub has policies which define the desired configuration state for the clusters at the current (e.g. 4.18) release. The agent provides the following capabilities:
- Assists the user by creating a complete set of policies for the next release (e.g. 4.20) through merging new RDS reference content and existing customizations from the existing deployment
- Validates the correctness of the policies (dry-run apply to a hub in POC, compliance checking in Phase 2)

POC targets the full RAN DU SNO PolicyGenerator set:
- [acm-common-ranGen.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/acm-common-ranGen.yaml) (common — waves 1-2)
- [acm-group-du-sno-ranGen-templated.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/hub-side-templating/acm-group-du-sno-ranGen-templated.yaml) (group — wave 10)
- [acm-example-sno-site.yaml](https://github.com/openshift-kni/telco-reference/blob/main/telco-ran/configuration/argocd/example/acmpolicygenerator/acm-example-sno-site.yaml) (site — wave 100)

### Out of Scope (POC)

See section 5 for details.
- Stale workaround detection and removal
- Fleet rollout orchestration
- Cluster upgrade orchestration (platform upgrades, IBU seed images — agent handles Day 2 config policies only)
- New hardware + version update
- Fresh installs
- Dynamic live cluster/fleet state updates — the agent does static generation of policies to govern the desired state of a fleet of clusters after moving to a new version; it does not react to or update policies based on dynamic live cluster state

### Post-POC / Phase 2

- Compliance-based iteration: suggesting improvements or corrections to the policies based on compliance status retrieved from the hub where the candidate policies are applied — application of the policies requires human-in-the-loop (git PR, user applies them, etc.). This brings a different set of needs and requirements from policy generation and is covered in the VALIDATE phases below.

---

## 2. Assumptions

1. **TALM/CGU is installed** on the hub cluster
2. **PolicyGenerator format** (not older PolicyGenTemplate) is used
3. **RAN DU SNO profile** for POC (as stated in section 1)
4. **telco-reference repo** has a version branch for the target version. Agent assumes branch content is valid; branch validation is not in scope.
5. **Lab/staging environment** available for canary validation — the agent never applies policies to production clusters without explicit human approval and fleet rollout orchestration (future scope)

---

## 3. How RDS Configs Work

The agent works at the **PolicyGenerator** level — this is the layer the user maintains and interacts with. PolicyGenerator YAML is both the input and output format. Internally, the agent generates Policy CRs as an intermediate representation for merging (since that is where CR-level matching and diffing happens), then produces updated PolicyGenerator YAML as output.

When reading from a hub cluster, only Policy CRs are available (PolicyGenerator does not appear on the hub). In this mode, the agent works at the Policy CR level directly. When reading from disk or git, the agent has access to PolicyGenerator YAML and can work at that level.

Key points:

- **Reference CRs** are base templates with expected user variations in some fields. PolicyGenerator patches these with kustomize-like overlays.
- **PolicyGenerator YAML** defines policies: manifest references, patches (hardcoded or hub templates), placement, remediation. This is where user customizations live — explicit as `patches:`.
- **Hub templates** (`{{hub fromConfigMap ... hub}}`) in patches are resolved at policy evaluation time from ConfigMaps, Secrets, etc on the hub. Users provide per-cluster content in these ConfigMaps to ensure overall consistency across the fleet even when sites may have unique values for some configuration.
- The merge must handle both template systems: preserve user's hardcoded overrides of hub templates, and update reference structural changes.

**Reference source:** [openshift-kni/telco-reference](https://github.com/openshift-kni/telco-reference) with version branches (`release-4.17`, `release-4.18`, etc.). Each branch has verified reference CRs + PolicyGenerator configs for that OCP version. [quay.io/openshift-kni/ztp-site-generator is the production source for these CRs — the agent's reference source should be pluggable. POC uses the Git repo for convenience; production should use the released container manifests.]

**Input sources:** The agent can read partner policies from multiple sources:
- **Hub cluster** — reads Policy CRs directly via K8s API. In this mode the agent works at the Policy CR level (no PolicyGenerator on the hub).
- **Disk / git** — reads PolicyGenerator YAML directly. In this mode the agent can work and generate at the PolicyGenerator level.

The agent may work with policies that are managed via gitops, but it does not depend on ArgoCD infrastructure for its own operation.

---

## 4. Core Workflow

The **agent** is an AI model with access to tools (K8s API, Git, PolicyGenerator, merge engine) that reasons about the problem, decides which tools to call, and executes multi-step workflows.

### Agent Capabilities

The agent provides three distinct capabilities that are independently valuable and composed into the end-to-end update flow:

1. **EXPLAIN** — Analyze the diff between RDS reference versions and produce a structured impact summary with per-CR detail. Useful standalone for planning, independent of merging. Also useful to the agent itself for determining merge behavior — the structured output informs which CRs need matching and what kind of changes to expect.
2. **MERGE** — N-way merge: a series of ordered, incremental 2-way merges. Start with existing partner policies → merge reference updates → merge new functionality requested by the partner → etc. Each step is incremental. Matches CRs by GVK + resource identity with confidence-based matching (exact/fuzzy/none). Reuses EXPLAIN output to scope the merge. Useful standalone for generating merged configs without the full validation flow.
3. **VALIDATE** — Given NonCompliant policies on a hub, diagnose the root cause from violation messages, fix the config, and retry. Useful standalone for any compliance issue, not just version updates. Could integrate with or complement anomaly detection work.

The end-to-end update workflow (DETECT → EXPLAIN → MERGE → VALIDATE → COMPLIANT) composes all three: EXPLAIN informs MERGE, and VALIDATE is invoked to drive policies to compliance.

The agent uses its tools as needed — some steps are straightforward tool usage (fetch reference branches, run PolicyGenerator to diff reference versions, read Policy CRs from hub), others require reasoning about the results (interpret a diff, resolve a conflict, diagnose a failure). For POC, we minimize the reasoning needed by treating all user changes as intentional customizations (no classification) and escalating all true conflicts to the user.

### End-to-End Update Flow

From the user's perspective, the end-to-end flow is:

1. I provide my existing policies (from hub, disk, or git)
2. I say what version I want to go to
3. I provide a prompt describing new functionality I want to add (optional)
4. The agent builds my new policies
5. The agent verifies they will successfully apply to a hub
6. I can approve applying them to a hub
7. *(Phase 2)* I can bind them to a managed cluster, verify compliance, and iterate with the agent

The agent assists users in generating valid policies for the target RDS version, with human approval at every transition.

### Example Prompts

- *"Here is the set of 4.18 policies that I'm using right now. 4.20 is now available. Generate the equivalent set for it."*
- *"4.20 is now available. Review this hub cluster, use policies in the `ran-du` namespace. Generate the new policies."*
- *"Update my policies from 4.18 to 4.20. Use policies from this directory on disk. Also add support for the new logging health check feature."*

#### Step 1: DETECT + READINESS

Determine that an update to the policies is needed, extract the required inputs, and gather the current policy set.

Required inputs (from prompt or cluster inspection):
- **Policy source** — the agent can read the partner's current policies from multiple sources (not mutually exclusive):
  - Hub cluster: specify by namespace, label, binding criteria, or "policies bound to cluster X". On the hub, the agent works at the Policy CR level (PolicyGenerator does not appear on the hub).
  - Disk / git directory: the agent has access to PolicyGenerator YAML and can work and generate at that level.
  - When both are available, the agent uses both — e.g. PolicyGenerator from disk for structure, hub for deployed state.
- **Current version** — what RDS version and profile (e.g. DU vs Core vs Hub) the partner is running (e.g. 4.18). Phase 1: user provides this. Phase 2: the agent may derive it from the policies.
- **Target version** — what RDS version to update to (e.g. 4.20)
- **New functionality** — optional prompt describing additional features/changes to incorporate (e.g. "add logging health check", "enable workload partitioning")

Once inputs are resolved, this step:
1. Fetches both versions of the reference (e.g. `release-4.18` and `release-4.20`)
2. Validates that the target version branch exists and contains reference CRs and PolicyGenerator examples
3. Reads the partner's current policies from the specified source (hub via K8s API, or disk/git)

The outputs of this step — old reference, new reference, and partner's current configs — are the inputs to the merge. The two reference versions feed into EXPLAIN; all inputs feed into MERGE.

#### Step 2: EXPLAIN

Using the two reference versions from Step 1, summarize what changed so the user understands the impact before merging. This step is also valuable as a **standalone capability** — it only needs the two reference versions, not the partner's configs.

- Agent diffs the old and new reference configs (file-by-file and field-by-field within PolicyGenerator YAMLs and reference CRs). PolicyGenerator is used here to understand the reference structure.
- Classifies each change: new CRs added, CRs removed, CRs moved to different policies, field updates (version bumps, channel changes, structural modifications), changes in wave ordering
- Output is structured at the **individual CR level** — each changed CR includes its full GVK, resource name, change type (added/removed/modified/moved), and which specific fields changed. This level of detail is what enables MERGE to do reliable matching against the partner's CRs (including fuzzy matching when names differ). For example, if the reference has 3 different `SriovNetworkNodePolicy` resources, EXPLAIN tracks each one individually. PTP configs are a key test case here — there are multiple variants in the reference for different PTP use cases, and users may rename their versions.
- Not just raw structured data — also provides a human-readable impact summary with context and references to published RDS docs
- Serves both as a user-facing report and as the structured input to Step 3 (MERGE). By producing a precise set of changed CRs with their GVKs and field-level diffs, EXPLAIN reduces the scope of MERGE's fuzzy matching — MERGE only needs to search the partner's policies for CRs that correspond to what actually changed in the reference, not the entire reference set

*HITL: human can review before proceeding.*

Note: hypothetical example for illustration (4.18 → 4.20):

```
Reference changes: release-4.18 → release-4.20

Added CRs:
  + ClusterLogForwarder/instance (GVK: logging.openshift.io/v1)
    Adds health check for cluster-logging operator.
    Fields: spec.pipelines, spec.outputs
  + ClusterLogging/instance (GVK: logging.openshift.io/v1)
    Cleanup CR for CLO v5 resources (per reference release notes).
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

Produce updated policies that incorporate reference changes while preserving partner customizations. MERGE performs a series of ordered 2-way merges (n-way merge): start with existing partner policies → merge reference updates → merge new functionality requested by the partner. Each step is incremental. MERGE reuses the reference change classification from EXPLAIN (or invokes it if not already run).

- Reads **all** of the user's policy configs and builds an inventory of every managed CR across all policies. Partners may have more than the standard 3 files — some environments have 5-10+ policies with different names and structures than the reference.
- Correlates the partner's CRs against reference CRs — not by policy name or file structure, but by the CRs themselves. Matching has three confidence levels:
  - **Exact match** (same GVK + same resource name, e.g. `SriovNetworkNodePolicy/sriov-nnp-du`) → high confidence, include reference changes in merge plan automatically
  - **Fuzzy match** (same GVK, different name, but similar spec fields — e.g. partner has `SriovNetworkNodePolicy/my-sriov` which looks structurally like the reference's `sriov-nnp-du`) → agent reasoning needed. The agent compares spec fields and structure to assess similarity, then **asks the user to confirm** before treating it as a match. Note: fuzzy matching may be 1-to-N — one reference CR may map to multiple partner CRs (e.g. multiple `SriovNetworkNodePolicy` for different node types). A broadly recommended change from the reference may need to be replicated across all matching targets. The agent may need additional context or guidance within the reference itself to handle this correctly.
  - **No match** → custom content, left untouched

  This is where agent reasoning adds real value — examining field structure to identify renamed or restructured CRs. The agent never silently assumes a fuzzy match; low confidence always escalates to the user.
- For matched CRs, compares the partner's version against EXPLAIN's reference change set to detect overlaps and conflicts. Where reference changes don't touch customized fields, they are included in the merge plan directly. User customizations are preserved by default — the merge does not attempt to classify them as intentional vs. stale (see Future Scope). True conflicts (user and reference both modified the same field) are flagged for human review at the HITL gate.
- Produces a merge plan (add/update/remove CRs, mapped back to whichever policy file they live in). Note on CR removal semantics: removing a CR from a policy doesn't remove it from managed clusters — the policy simply stops watching it. To actually trigger removal from managed clusters, a policy with `complianceType: mustNotHave` is needed. If removal comes from the reference, the reference should include the removal policy. The agent needs to be aware of complianceType semantics when generating the merge plan.
- Merge engine writes the plan to local user files in batch (no cluster interaction).
- Identifies new hub templates that need values (templates added by the reference that weren't in the partner's previous version). This is included in the agent's output report.

*HITL: human reviews merged output via git PR or direct review. The agent does not apply without explicit user request — the user can apply manually or ask the agent to apply on their behalf. In the POC phase, the user can manually apply policies and report back errors or desired changes to the agent.*

Note: hypothetical example for illustration — applying the changes from EXPLAIN above to a partner's config. The partner's policy names and structure differ from the reference — the agent matches by CR content, not policy name.

EXPLAIN reported these reference changes (4.18 → 4.20):
```
Added:    ClusterLogForwarder/instance, ClusterLogging/instance
Modified: SriovNetworkNodePolicy/sriov-nnp-du — spec.deviceType changed
Modified: Subscription/sriov-network-operator — spec.channel 4.18 → 4.20
```

Partner's config uses different policy names and has a renamed SRIOV CR:
```
Partner's 4.18 config:                     Merged 4.20 output:

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
                                  ← added          (new reference CR)
                                                 - path: ClusterLogging.yaml
                                  ← added          (new reference CR)
```

How the agent resolved this:
- `SriovNetworkNodePolicy/my-sriov` — fuzzy matched to the reference's `sriov-nnp-du` (same GVK, similar spec). Agent asked user to confirm before merging. Partner's `pfNames` customization preserved. `deviceType` conflict flagged — both reference and partner have a value, user must decide.
- `ClusterLogForwarder/instance` and `ClusterLogging/instance` — new reference CRs, added to `my-common-policy` (agent chose the closest-fit policy based on existing logging content).
- Policy names (`my-network-policy`, `my-common-policy`) — partner's naming preserved, not overwritten with RDS reference naming convention.

#### Step 4: VALIDATE

Progressively validate merged policies — each phase catches a different class of errors. When validation fails, the agent diagnoses the root cause, proposes a fix, and the user approves before retrying.

*HITL: human must explicitly approve before any policy is applied to any cluster. Each validation retry requires human approval — the agent proposes a fix, the user reviews and approves before the next attempt. If max retries are exceeded, the agent escalates to human.*

**Phase 1: Schema validation** *(POC scope)*
- Dry-run apply to a hub (`--dry-run=server`) — catches schema violations, unknown fields, invalid references without needing a spoke cluster
- This proves the config is well-formed. It does NOT prove functional correctness.
- In the end-to-end flow, the agent automatically runs this after MERGE — no separate user action needed.

**Phase 2: Inform mode (semantic correctness)** *(post-POC)*
- With human approval, apply policies to lab hub in `inform` mode — **no changes are made to managed clusters**
- Policy controller evaluates desired state against cluster and reports compliance
- Catches: missing CRDs, unresolvable hub templates, ConfigMap references, field mismatches
- For hub templates: identifies new templates that were added by the reference and need values populated. This is surfaced in the agent's output report.
- This proves the config is semantically valid against the cluster's actual state. It does NOT prove the config will work at runtime (operators may reject it).
- Note: for compliance checking to be meaningful, the bound cluster needs to be at the target OCP version.
- There are multiple options and flows for which clusters to bind to — this needs further specification in Phase 2.
- If NonCompliant: agent proposes fix → human approves → retry from Phase 1

**Phase 3: Enforcement on lab canary (functional correctness)** *(post-POC)*
- Only proceeds if inform mode passes and **human explicitly approves**
- Create CGU (ClusterGroupUpgrade) targeting canary cluster(s) in a lab environment
- TALM (Topology Aware Lifecycle Manager) enforces on canary — catches runtime failures that inform mode can't surface: operator webhook rejections, resource conflicts, node scheduling failures
- If the canary cluster gets a bad config, it is recoverable via policy deletion or rollback — this is a lab, not production
- If failure: agent proposes fix → human approves → retry from Phase 1
- Loop until canary passes (max N retries)

#### Recovery

Recovery can be more complex than simply reverting policies. If the config adds new CRs, they need to be explicitly removed (a policy with `complianceType: mustNotHave`). The feedback from a failed attempt is valuable to the agent, but the next retry attempt needs to start from a known good system state.

#### Step 5: COMPLIANT

All policies report Compliant on the lab hub — the cluster's actual state matches the desired config for the target RDS version. Notify user. Production fleet rollout is out of scope for POC (see Future Scope).

#### ESCALATION (at any step)

Max retries exceeded → alert humans, log full context.

---

## 5. Future Scope

### Stale Workaround Detection and Removal

Partners accumulate workarounds (patches for version-specific bugs/gaps) that become stale when the fix ships in the reference. The agent would classify user additions as intentional customizations vs. stale workarounds, cross-referencing against release notes and a knowledge base of known issues and fixes. In this mode the agent is also serving as an expert advisor — there is real value here if the knowledge it has access to is sufficient to be helpful without hallucinations. We should consider what, if anything, would be captured directly in the policies to identify workarounds and provide context (e.g. a label like `workaround-id: ocpbugs-zzzzz`).

### Fleet Rollout Orchestration

After canary validation passes, batched rollout to remaining fleet via CGU (maxConcurrency from config). Per-cluster failures — note that policies drive fleet consistency, so site-specific policy fixes are suspect. The agent could identify missing or incorrect hub templating data for a site, but making a site-specific policy fix would be unusual. Site-specific issues fall more in the anomaly detection and analysis arena (e.g. one site has a non-compliant policy — what's wrong with that site?).

### AI-Driven New Cluster Onboarding

Out of scope for POC (ZTP handles this today). This is about populating hub templating ConfigMaps from hardware discovery — not creating site-specific policies (which are avoided in favor of templating). After a new cluster is provisioned and operators installed, the agent discovers hardware (SriovNetworkNodeState → NICs/VFs, node capacity → CPUs/memory) and populates the per-cluster template data. Challenges: chicken-and-egg (operators must be installed first), sensible defaults when multiple valid configs are possible, and source of network information (VLANs, IPs, subnets) is an open question — likely requires user input or integration with an external IPAM/network inventory system.

### New Hardware + Version Update

Update from 4.18 → 4.20 with different hardware. Requires both version merge AND hardware-aware config generation.

### GitOps Integration (prod)

In production, agent commits to Git → ArgoCD syncs → PolicyGenerator generates policies. PR-based approval flow optional. The agent could post merged PolicyGenerator output as a git PR (similar to how tools like renovate work) — more of a polish on the user experience than core functionality, but fits within the workflow nicely. For POC, the agent generates merged configs and can apply them to the hub if the user explicitly requests it.

---

## 6. Agent Environment

The agent runs standalone — either locally (developer workstation, CI) or in-cluster on the ACM hub. It requires: Git access (for reference configs), PolicyGenerator binary (for reference analysis in EXPLAIN), and optionally K8s API access to a hub. The agent can also read policies from disk/git if hub access is not available. The agent does not apply without explicit user request.

The agent exposes APIs (e.g. A2A protocol) so that the broader ecosystem (OpenShift Lightspeed, other tools) can integrate with it. The agent is not embedded in any specific product — it is a standalone service that others consume.
