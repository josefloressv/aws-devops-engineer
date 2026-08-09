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
| [`ecs-bluegreen-codedeploy`](ecs-bluegreen-codedeploy/README.md) | the eight ECS CodeDeploy lifecycle event names, linear traffic shifting observed live on both listeners, what an alarm-triggered rollback looks like from both ends, `deploymentOverview` vs `get-deployment-target` |
| [`sam-canary-alarm-rollback`](sam-canary-alarm-rollback/README.md) | what `AutoPublishAlias` + `DeploymentPreference` synthesize that nobody wrote, the three Lambda lifecycle events, alias `RoutingConfig` weights during a canary, alarm-forced rollback through CloudFormation |
| [`eks-two-output-artifacts`](eks-two-output-artifacts/README.md) | two named output artifacts from one CodeBuild action, `$CODEBUILD_SRC_DIR_<name>` and `PrimarySource` in a multi-input deploy action, what does and does not cross a stage boundary, EKS access entries instead of `aws-auth` |

Deploy order is top to bottom; teardown order is bottom to top.
`eventbridge-pr-trigger` and `eks-two-output-artifacts` both import exports from
`codepipeline-artifacts-and-reports`, and `eks-two-output-artifacts` uses the ECR repository
created by `ecs-bluegreen-codedeploy` (which outlives that stack's teardown).
`sam-canary-alarm-rollback` is deployed with `sam deploy`, not `make apply` — see its README.

## Teardown of the whole domain

Each scenario README has its own teardown step. Running them all leaves a few things behind,
because they are not CloudFormation resources of any scenario stack:

```bash
# 1. stacks the pipeline itself created (they are not in any scenario stack)
aws cloudformation delete-stack --stack-name dop-c02-app-staging
aws cloudformation delete-stack --stack-name dop-c02-app-dev

# 2. Kubernetes objects applied by the EKS pipeline
kubectl delete deploy,svc dop-c02-eks-app --ignore-not-found

# 3. the SAM stack (deployed outside make)
sam delete --stack-name dop-c02-sam-canary --no-prompts

# 4. task definition revisions registered by hand for the blue/green scenario
for R in $(aws ecs list-task-definitions --family-prefix dop-c02-lab-task \
             --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$R" --query 'taskDefinition.revision'
done

# 5. ECR images and the repository
aws ecr delete-repository --repository-name dop-c02-lab --force

# 6. the scenario stacks, bottom of the table upward
make destroy LAB=domain-1-sdlc/eks-two-output-artifacts
make destroy LAB=domain-1-sdlc/ecs-bluegreen-codedeploy
make destroy LAB=domain-1-sdlc/eventbridge-pr-trigger
# empty the versioned artifact bucket before this one, or the stack delete fails
make destroy LAB=domain-1-sdlc/codepipeline-artifacts-and-reports
```

The EKS cluster `dop-c02-lab-cluster` is **not** part of this domain and stays up.

## Application source

These scenarios build pipeline infrastructure only. The application the pipelines build
lives in a separate repository,
[`aws-devops-sdlc-automation`](https://github.com/josefloressv/aws-devops-sdlc-automation),
mirrored into the CodeCommit repository `dop-c02-sdlc`.
