# Domain 4 — Monitoring and Logging (15% of exam)

Priority: **high** (needs improvement on the last attempt).

Typical topics: CloudWatch (metrics, alarms, composite alarms, anomaly detection, dashboards,
Logs Insights), CloudTrail, X-Ray tracing, EventBridge rules driven by monitoring signals,
centralized logging across accounts.

Each scenario lives in its own subfolder here:
`scenarios/domain-4-monitoring/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-4-monitoring NAME=<scenario-slug>`.

CloudTrail-specific scenarios create their own trail here rather than relying on
`base/logging-baseline` (which deliberately doesn't create one) — see
`base/logging-baseline/README.md` for why.
