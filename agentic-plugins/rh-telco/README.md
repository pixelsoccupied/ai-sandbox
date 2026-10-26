# Red Hat Telco agentic plugin

Skills for telco partners running the OpenShift RAN and Core reference
configurations. For now that's one skill, `rds-policy-update`, which updates
your Day 2 PolicyGenerator policies when you move to a new OCP version, say
4.18 to 4.20.

**Persona**: Telco partner platform engineer (OpenShift RAN or Core)
**Marketplaces**: Claude Code, Lola

Review everything it produces before you apply it, and keep in mind that
your policy files go to whichever LLM you've configured. See the
[disclaimer](https://github.com/openshift-kni/ai-sandbox/blob/main/rds-policy/README.md#important-security-privacy-and-disclaimer).

## Getting Started

You need `podman` (or `oc`) logged in to `registry.redhat.io`, and your
policies as a Git repo or a local copy. If your Git host uses internal
certificates, add them to the trust store first.

Install in Claude Code:

```bash
claude plugin marketplace add 'RHEcosystemAppEng/agentic-catalog#rc/v1.0.0'
claude plugin install rh-telco@ecosystem-plugins
```

Or with Lola, from your project. This gets you the skill but not the
validation hook:

```bash
lola market add rh-agentic-collections https://raw.githubusercontent.com/RHEcosystemAppEng/agentic-catalog/rc/v1.0.0/marketplace/rh-agentic-collection.yml
lola install rh-telco -a claude-code
```

Then ask:

```
upgrade my policies from 4.18 to 4.20, the policy source is ./acme-ran
```

The skill first explains what changed between the two versions. When you
say go, it merges those changes into a copy of your policies, asking before
it copies anything and checking with you on each conflict. Your original
files stay untouched. The results land in
`/tmp/rds-merge-<target>-<timestamp>/`, along with a `checklist.md` showing
what happened to each CR. Review them and push them through your usual
process.

In Claude Code, a hook also runs `kustomize build` on each PolicyGenerator
file as it's written, so the agent can fix errors right away. It needs
`kustomize` and the PolicyGenerator plugin; see
[HOOKS.md](https://github.com/openshift-kni/ai-sandbox/blob/main/rds-policy/docs/HOOKS.md).

## Development

The source, design docs, and evals are in
[openshift-kni/ai-sandbox](https://github.com/openshift-kni/ai-sandbox).
To test local changes:

```bash
claude --plugin-dir /path/to/ai-sandbox/agentic-plugins/rh-telco
```
