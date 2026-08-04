# Repo conventions

This repo deploys real AWS infrastructure to validate DOP-C02 exam questions and lab
scenarios by observation. Follow these conventions for any work in this repo.

## Language

All repo content — README files, comments, script usage/output text, docs — is **English**,
regardless of the language the conversation happens in.

## IaC

- Default IaC tool: **CloudFormation (YAML)**. Do not use Terraform or CDK unless explicitly
  asked.
- Default region: `us-east-1`.
- Reusable infra (VPC, IAM baseline, logging baseline) lives under `base/` and is consumed by
  scenario stacks via `Fn::ImportValue` cross-stack exports, not nested stacks (avoids needing
  an S3 bucket to host nested templates).
- Account-level tooling that is not a lab building block lives under `ops/` and deploys to the
  **payer (management) account**, not the sandbox. Use
  `make ops-apply NAME=<name> PARAMS="Key=Value ..."`; `scripts/ops-apply.sh` pins
  `AWS_PROFILE` to the payer profile rather than using ambient credentials, and aborts if the
  caller resolves to any other account.
- This repo is public, so account IDs and profile names are **never** committed. They live in
  `.env.local` (gitignored, see `.env.local.example`) as `PAYER_ACCOUNT_ID` and
  `PAYER_PROFILE_DEFAULT`, which `scripts/lib.sh` sources. Use those variable names in docs and
  comments instead of literal IDs.
- Stack naming: scenarios = `dop-lab-<domain-abbrev>-<scenario-slug>` (e.g.
  `dop-lab-d6-iam-boundary-vs-scp`); base stacks = `dop-lab-base-<name>`; ops stacks =
  `dop-ops-<name>`.
- Every stack is created with `--tags Project=dop-c02-lab Domain=<n> Scenario=<slug>` (stack
  tags propagate to resources that support tagging — don't repeat tags per-resource unless a
  resource type requires it, e.g. `AWS::SSM::Parameter`).

## Known gotchas (learned from past scenario runs)

- `AWS::EC2::Instance.IamInstanceProfile` takes the instance profile **name**, not its ARN
  (passing the ARN fails with `Invalid IAM Instance Profile name`). `base/iam-baseline` only
  exports `Ec2InstanceProfileArn` — derive the name from it in the scenario template with
  `!Select [1, !Split ["/", !ImportValue dop-lab-base-iam-baseline-Ec2InstanceProfileArn]]`
  rather than adding a Name export to the base stack.
- `AWS::SSM::Association` rate-based `ScheduleExpression` has a hard 30-minute minimum
  (`rate(5 minutes)` etc. is rejected at deploy time with `InvalidSchedule`).
- If an `AWS::EC2::Instance` resource sits at `CREATE_IN_PROGRESS` for several minutes with no
  new stack events, suspect a transient `AccessDenied` (e.g. an SCP that changed mid-deploy) —
  the resource handler retries silently without posting intermediate events. Check with
  `aws ec2 run-instances --dry-run` using the same parameters to see the real-time permission
  result before assuming the stack is actually stuck.
- If a stack ends up in `ROLLBACK_COMPLETE`, `scripts/lab-plan.sh`/`base-plan.sh` will now stop
  and tell you to delete it first — CloudFormation refuses an `UPDATE` change set against that
  status.

## Deploy workflow — auto-apply by default, pause only for cost-flagged resources

Jose isn't cost-sensitive (AWS promotional credit, see Cost section) and wants speed over a
manual confirmation step. Default flow is `make apply LAB=...` / `make base-apply NAME=...`
(`scripts/lab-apply.sh` / `scripts/base-apply.sh`):

1. `create-change-set` to build the change set.
2. `describe-change-set` to print the diff.
3. If the template matches `COST_FLAG_PATTERN` (see Cost section below): stop here, leave the
   change set saved in `.lastchangeset`, and tell the user to review + run `make deploy` /
   `make base-deploy` manually. Do not auto-execute.
4. Otherwise: `execute-change-set` immediately, no chat confirmation needed.

The two-step `plan`/`deploy` (and `base-plan`/`base-deploy`) targets still exist for the
cost-flagged path and for anyone who wants to review before applying — use them directly when
that's preferred, but `apply`/`base-apply` is the default to reach for. Never run
`aws cloudformation deploy` directly (it doesn't support `--change-set-name`); always go
through `create-change-set` (or the wrapper scripts).

## Cost

Free-tier-first. Flag any resource type with non-trivial cost (NAT Gateway, RDS, EKS cluster,
ElastiCache, Redshift, OpenSearch/Elasticsearch, MSK, Transit Gateway, Global Accelerator,
Direct Connect) **before** creating it, even inside a change-set plan step.

Jose has a $500 **AWS Community Builders 2026 Renewal Credit**, redeemed 2026-08-01 into the
organization's management account (`PAYER_ACCOUNT_ID`) and expiring **2027-11-30**. Credit
sharing is activated for all three accounts in the org, so the credit also covers usage in the
lab and sandbox member accounts — labs deployed to any account draw from the same pool.

The credit covers nearly every service used in this repo's labs, including RDS, EKS,
ElastiCache, Redshift, OpenSearch, MSK, Global Accelerator, Direct Connect, and VPC/NAT
Gateway. **AWS Transit Gateway is the one cost-flagged type NOT covered** — if a scenario ever
needs Transit Gateway, call that out explicitly (its hourly attachment + data processing
charges will hit the actual bill, not the credit) before applying. AWS Marketplace purchases
are also uncovered — avoid Marketplace AMIs in scenario templates.

The full authoritative list of covered services is in
[`docs/credit-applicable-services.md`](docs/credit-applicable-services.md). Check it before
introducing a service this repo hasn't used before.

**Credit balances are not queryable via CLI or API** — only the Billing console's Credits page
shows them. Three prior credits (2024-2026) expired with $971.02 unused because org-wide spend
runs well under $1/month, so treat a low burn rate as the expected failure mode, not a
surprise.

## Evidence, not answers

Scenario READMEs and any generated CLI output exist to let the user infer the correct exam
answer themselves. Never state which option is correct — only produce the raw command output
that distinguishes the competing answers.

## Teardown

Every scenario must have an explicit teardown step (`make destroy LAB=...`). Base stacks are
destroyed separately (`make base-destroy-all`) and only after all scenario stacks are gone,
since scenario stacks may hold `Fn::ImportValue` references to base stack exports.
