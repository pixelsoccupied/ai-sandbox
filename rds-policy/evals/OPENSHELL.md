# Run the eval in OpenShell

The Makefile creates a fresh confined sandbox, uploads the checkout, installs
the pinned dependencies, runs Promptfoo, downloads the results, and deletes the
sandbox. Vertex credentials never enter the sandbox: they stay on the gateway
as an OpenShell provider.

## Prerequisites

- OpenShell CLI and gateway version 0.0.116 or newer
- A registered gateway (`openshell gateway list`)
- Google Cloud Application Default Credentials with access to the configured
  Vertex models

From `rds-policy/evals`, copy the checked-in template and set values for your
environment:

```sh
cp .env.example .env
$EDITOR .env
```

The gateway name and project ID are runtime configuration, not repository
defaults. The scripts in `scripts/` load `.env` when present; Git ignores it.

Each step is its own small script, and `make openshell-<name>` just runs
`scripts/<name>.sh`, so CI can call either. The scripts hold nothing but
`openshell` commands: the CLI reads the gateway from `OPENSHELL_GATEWAY`, so no
command carries a `-g` flag and you can copy one out and run it by hand.

| Script | What it does |
| --- | --- |
| `provider.sh` | one-time: store your gcloud ADC on the gateway |
| `deploy.sh` | create the sandbox, upload the checkout, start the eval |
| `status.sh` | is it still running? tail of the log |
| `wait.sh` | block until it finishes, exit with the eval's code |
| `collect.sh` | download the results into `results/<sandbox>/` |
| `undeploy.sh` | delete the sandbox |
| `e2e.sh` | all of the above in order |

## One-time: register the Vertex provider

```sh
make openshell-provider
```

This stores your local gcloud ADC on the gateway as a `google-vertex-ai`
provider. A sandbox created with `--provider` sees only a placeholder token in
`GOOGLE_VERTEX_AI_TOKEN`, plus `ANTHROPIC_VERTEX_PROJECT_ID` and
`CLOUD_ML_REGION`; the sandbox proxy substitutes the real short-lived token on
requests to `aiplatform.googleapis.com`. The Makefile hands that placeholder to
both Vertex clients: Claude Code skips its own Google auth
(`CLAUDE_CODE_SKIP_VERTEX_AUTH=1`) and sends it as its bearer token, and the
judge switches from Promptfoo's `vertex:` provider, which insists on an ADC
file, to the plain HTTP provider in `graders/vertex-brokered.yaml`. No
credential file is uploaded.

## Run

```sh
make openshell-e2e
```

One-test smoke run:

```sh
make openshell-e2e PROMPTFOO_EVAL_ARGS='--filter-first-n 1'
```

`e2e.sh` names the sandbox `rds-<MMDD-HHMMSS>`, creates it, uploads the
checkout (honoring `.gitignore`, so `node_modules`, `.venv`, and `results/`
stay local), starts the install-and-eval job, polls until it exits, downloads
the results, and deletes the sandbox. If the download fails the sandbox is kept
and the command to retry is printed.

For a long run you do not want to babysit:

```sh
make openshell-deploy OPENSHELL_SANDBOX=rds-full     # create, upload, start
make openshell-status OPENSHELL_SANDBOX=rds-full     # running? tail of the log
make openshell-collect OPENSHELL_SANDBOX=rds-full    # download the results
make openshell-undeploy OPENSHELL_SANDBOX=rds-full   # delete the sandbox
```

Install and eval run as one detached job inside the sandbox, polled with short
`sandbox exec` calls, because attached exec streams are cut by the OpenShift
route's idle timeout once they go quiet for about a minute. Promptfoo runs
three tests at a time (`PROMPTFOO_CONCURRENCY`; the full suite takes about
seven minutes). If a run reports `policy_denied` with "ambiguous shared socket
ownership", rerun with `PROMPTFOO_CONCURRENCY=1`: that denial hit the judge's
ADC token refresh once at concurrency 4 and has not recurred since the
credential file left the sandbox.

## Results

Each run lands in `results/<sandbox-name>/`: `promptfoo.json`, `eval.log`,
`exit-code`, the Promptfoo SQLite state, and any `rds-merge-*` output the agent
wrote. `results/latest` points to the most recent collected run. Browse it
with:

```sh
make openshell-view
```

That sets `PROMPTFOO_CONFIG_DIR` to the downloaded state; your local Promptfoo
database is untouched.

## Policy and image

`openshell-policy.yaml` is passed on `sandbox create`. Gateways provisioned by
the team's `ooo` installer carry a global policy lock, and then the global
policy applies instead; `openshell policy get <sandbox>` shows which one is in
effect. Either way the eval needs egress to Vertex, the npm registry, PyPI, and
GitHub release assets.

The sandbox image (`quay.io/telco5gci/sandbox`) ships Python 3.13 and node but
no uv, and the project requires Python 3.14, so `setup-openshell` installs uv
and CPython under `/tmp` before `make setup`. Baking those into the image would
remove that step.
