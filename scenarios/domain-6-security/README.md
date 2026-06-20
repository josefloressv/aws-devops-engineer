# Domain 6 — Security and Compliance (17% of exam)

Priority: **high** (needs improvement on the last attempt).

Typical topics: IAM policies vs permission boundaries vs SCPs, AWS Organizations, Secrets
Manager/SSM Parameter Store rotation, KMS key policies and grants, AWS Config rules and
remediation, GuardDuty/Security Hub findings response, cross-account access patterns.

Scenarios that need an SCP require an existing AWS Organization — this is **not** provisioned
by any base stack (see `base/iam-baseline/README.md`); call it out explicitly in the
scenario's own README as a prerequisite.

Each scenario lives in its own subfolder here:
`scenarios/domain-6-security/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-6-security NAME=<scenario-slug>`.
