# Domain 1 — SDLC Automation (22% of exam)

Priority: **high** (needs improvement on the last attempt).

Typical topics: CodePipeline/CodeBuild/CodeDeploy/CodeCommit, deployment strategies
(blue/green, canary, linear), CodeDeploy hooks and rollback triggers, CI/CD across accounts,
ECS/EC2/Lambda deployment automation, artifact management.

Each scenario lives in its own subfolder here:
`scenarios/domain-1-sdlc/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-1-sdlc NAME=<scenario-slug>`.

## Scenarios

| Scenario | What it makes observable |
| --- | --- |
| [`codepipeline-artifacts-and-reports`](codepipeline-artifacts-and-reports/README.md) | buildspec phases vs CodeBuild phases, `reports:` vs `artifacts:`, `discard-paths`, `TemplateConfiguration` per environment, where a pipeline stops when a Test stage fails |
| [`eventbridge-pr-trigger`](eventbridge-pr-trigger/README.md) | CodeCommit pull request event patterns, EventBridge → CodePipeline target wiring, matching vs non-matching events, why the triggering event and the built commit are unrelated |

Deploy order is top to bottom; teardown order is bottom to top, since
`eventbridge-pr-trigger` imports the pipeline exports from
`codepipeline-artifacts-and-reports`.

## Application source

These scenarios build pipeline infrastructure only. The application the pipelines build
lives in a separate repository,
[`aws-devops-sdlc-automation`](https://github.com/josefloressv/aws-devops-sdlc-automation),
mirrored into the CodeCommit repository `dop-c02-sdlc`.
