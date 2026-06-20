# Domain 1 — SDLC Automation (22% of exam)

Priority: **high** (needs improvement on the last attempt).

Typical topics: CodePipeline/CodeBuild/CodeDeploy/CodeCommit, deployment strategies
(blue/green, canary, linear), CodeDeploy hooks and rollback triggers, CI/CD across accounts,
ECS/EC2/Lambda deployment automation, artifact management.

Each scenario lives in its own subfolder here:
`scenarios/domain-1-sdlc/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-1-sdlc NAME=<scenario-slug>`.
