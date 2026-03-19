# RDS Policy Agent — Evaluation Plan

## What We're Testing

Three capabilities, in order of risk:

1. **MERGE correctness** (highest risk) — wrong merges break deployments.
   Does the agent preserve partner customizations? Handle conflicts?
   Avoid adding optional CRs? Respect pinned versions?

2. **EXPLAIN accuracy** — does the agent correctly identify all reference
   changes? Miss anything? Misclassify path-only changes as content changes?

3. **Triggering & workflow** — does the skill activate on the right prompts?
   Does it ask for inputs instead of exploring? Does it run EXPLAIN before
   MERGE?

## How We're Testing

Following the [agentskills.io eval framework](https://agentskills.io/skill-creation/evaluating-skills).

### Approach

1. Define test cases in `evals/evals.json` (prompt + expected output + input files)
2. Run test cases, review outputs manually (first round — no assertions yet)
3. Add assertions based on what we observe
4. Iterate on skill, re-run in new `iteration-N/` directory
5. Compare across iterations to measure improvement

### What is Eval?

Eval (evaluation) is how you measure whether an AI agent produces correct,
consistent outputs. The general pattern:

1. Define test cases with inputs and expected outputs
2. Run the agent against each test case
3. Grade the outputs — either programmatically (assertions) or via
   human review or LLM-as-judge
4. Track results across iterations to measure improvement

This is analogous to integration testing for traditional software, but
outputs are non-deterministic so grading requires more nuance than
pass/fail assertions alone.

### How to Run

Options (in order of complexity):
- **Manual** — run each prompt in a coding agent, review output. Good
  for early iteration.
- **CLI** — use the agent's non-interactive mode for scripted runs.
  Can be looped in a bash script over `evals.json`.
- **API** — inject skill content as system prompt, send test prompts
  programmatically. Works in CI.
- **Open frameworks** — config-driven eval with built-in grading,
  comparison, and reporting.

TBD: pick an approach and implement once we have more test cases.

### Test Fixtures

- **Reference CRs**: pre-extracted from ZTP containers so evals don't
  pull containers each run
  - `evals/files/ref-4.18/`
  - `evals/files/ref-4.20/`

- **Synthetic partner policies**: minimal PolicyGenerator YAML sets
  exercising specific scenarios. NOT real partner configs.
  - `evals/files/partner-basic/` — few CRs, standard customizations
  - `evals/files/partner-pinned/` — intentionally pinned versions
  - `evals/files/partner-renamed/` — renamed CRs (fuzzy matching) [future]

## Test Cases

### Test 1: EXPLAIN — basic reference diff

**What it tests**: Can the agent identify changes between 4.18 and 4.20
without asking for partner policies?

**Prompt**: `"what changed between RDS 4.18 and 4.20?"`

**Expected output**: Structured report covering added, removed, modified
CRs with per-CR detail. Should NOT ask for partner policies.

**Key things to check** (assertions added after first run):
- Identifies ICSP → IDMS GVK replacement
- Identifies TunedPerformancePatch rename + priority change
- Does NOT list path reorganization as content changes
- Does NOT ask for partner policy source
- Saves output to file for MERGE to reference

### Test 2: MERGE — basic partner policies

**What it tests**: Given partner policies with standard customizations,
does the agent produce correct merged output?

**Prompt**: `"upgrade my policies from 4.18 to 4.20, policies are in
evals/files/partner-basic"`

**Input files**: `evals/files/partner-basic/` — two PolicyGenerator YAMLs:
- `my-common.yaml` — CatalogSource with v4.18 tag, DisconnectedICSP
  (needs GVK migration to IDMS), operator subscriptions
- `my-group-sno.yaml` — PTP with renamed CR (`acme-ptp-grandmaster`
  instead of reference `du-ptp-slave`), SRIOV with custom selector,
  PerformanceProfile with custom CPU pinning (`2-51,54-103`),
  TunedPerformancePatch with 4.18 profile name/priority

Partner uses `acme-*` naming throughout (not matching reference names).

**Key things to check**:
- Partner naming (`acme-*`) preserved throughout
- CatalogSource image tag bumped v4.18 → v4.20
- DisconnectedICSP → DisconnectedIDMS GVK migration handled
- PTP renamed CR (`acme-ptp-grandmaster`) matched via fuzzy matching
- PerformanceProfile custom CPU values preserved
- TunedPerformancePatch rename + priority change applied
- No optional/commented-out reference CRs added
- Output includes source-crs directory
- Merge checklist present and all items resolved

### Test 3: MERGE — pinned versions

**What it tests**: Does the agent detect intentionally pinned versions
and flag them instead of auto-updating?

**Prompt**: `"upgrade my policies from 4.18 to 4.20, policies are in
evals/files/partner-pinned"`

**Input files**: `evals/files/partner-pinned/my-common.yaml` — with:
- CatalogSource `redhat-operators` image tag pinned to v4.17 (not v4.18)
- Second CatalogSource `certified-operators` also pinned to v4.17
- SRIOV Subscription channel pinned to "stable" (not version-specific)
- DisconnectedICSP (same GVK migration scenario)

**Key things to check**:
- Both CatalogSources flagged with REVIEW (pinned to v4.17, not v4.18)
- SRIOV "stable" channel preserved, not overwritten with "4.20"
- the agent explains why it's flagging (value doesn't match old OCP version)
- DisconnectedICSP → IDMS migration still handled correctly

## Future Test Cases

- **MERGE — fuzzy matching**: partner with renamed SRIOV/PTP CRs
- **MERGE — real partner policies**: actual partner configs (when available)
- **MERGE — GVK replacement**: partner has customized ICSP → IDMS migration
- **VALIDATE**: dry-run against a hub (needs cluster access)
- **Full flow**: EXPLAIN → MERGE → VALIDATE end-to-end
- **Triggering**: various prompt phrasings, negative triggers

## Iteration Process

1. Run evals, review outputs manually
2. Note what went wrong — missed changes, bad merges, unnecessary questions
3. Add assertions for the failures observed
4. Update SKILL.md / references with fixes (gotchas, instructions)
5. Re-run evals in new `iteration-N/` directory
6. Compare pass rates across iterations
7. Stop when feedback is consistently empty
