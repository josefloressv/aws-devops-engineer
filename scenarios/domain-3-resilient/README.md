# Domain 3 — Resilient Cloud Solutions (15% of exam)

Priority: **high** (needs improvement on the last attempt).

Typical topics: Auto Scaling policies/lifecycle hooks, multi-AZ/multi-region failover, ELB
health checks, Route 53 routing policies and health checks, RDS Multi-AZ/read replicas,
disaster recovery patterns (backup/restore, pilot light, warm standby, multi-site).

Each scenario lives in its own subfolder here:
`scenarios/domain-3-resilient/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-3-resilient NAME=<scenario-slug>`.
