# aws-devops-engineer

Hands-on lab companion for AWS Certified DevOps Engineer - Professional (DOP-C02) exam prep.

This repo deploys real, minimal AWS infrastructure with CloudFormation to validate exam-style
questions and Pluralsight/Udemy lab scenarios **by observation** — running the CLI/console
commands a scenario calls for and capturing the raw output, not by having an assistant state
which answer is correct.

## Layout

```
base/                     reusable stacks (network, iam-baseline, logging-baseline)
scenarios/domain-N-*/     one folder per exam domain, one subfolder per scenario
templates/scenario-skeleton/  stub used by `make new`
scripts/                  shell helpers wrapping the changeset workflow + teardown
docs/                     supporting docs (e.g. the Lab Builder bridge prompt)
Makefile                  entry point for all lab lifecycle commands
```

## Conventions

See [CLAUDE.md](CLAUDE.md) for the full set of conventions (IaC tool, region, tagging, the
deploy workflow, cost guardrails). Short version: CloudFormation YAML, `us-east-1`, every
stack tagged `Project=dop-c02-lab`, change sets auto-apply unless the template provisions a
non-trivial-cost resource type, in which case it pauses for manual review.

## Quickstart

```bash
# One-time: stand up reusable base infra (network/IAM/logging)
make base-apply NAME=network
make base-apply NAME=iam-baseline
make base-apply NAME=logging-baseline

# Per scenario
make new DOMAIN=domain-6-security NAME=my-scenario-slug
# edit scenarios/domain-6-security/my-scenario-slug/template.yaml + params.json
make apply LAB=domain-6-security/my-scenario-slug
# ... run the evidence commands from the scenario's README ...
make destroy LAB=domain-6-security/my-scenario-slug

# End of a study session / before the exam
make destroy-all
make base-destroy-all
```

`make apply` / `make base-apply` plan and execute in one step. If the template trips a cost
flag (NAT Gateway, RDS, EKS, etc. — see CLAUDE.md), it stops after printing the diff instead of
auto-executing; review it, then run `make deploy` / `make base-deploy` to apply. The two-step
`make plan` → `make deploy` (and `base-plan` → `base-deploy`) targets still work if you want to
review every change manually.

## Domains

Scenario folders map 1:1 to the DOP-C02 exam domains, ordered by priority based on a prior
attempt's score breakdown:

- `domain-1-sdlc` — SDLC Automation (22%)
- `domain-2-config-iac` — Configuration Management & IaC (17%, refresh only)
- `domain-3-resilient` — Resilient Cloud Solutions (15%)
- `domain-4-monitoring` — Monitoring and Logging (15%)
- `domain-5-incident` — Incident and Event Response (14%)
- `domain-6-security` — Security and Compliance (17%)
