# base/iam-baseline

Reusable IAM building blocks for scenario stacks:

- `LabPermissionBoundary` — example permission boundary (denies IAM/Organizations escalation,
  allows everything else). Attach it to a role/user in a scenario to test permission-boundary
  vs SCP behavior.
- `Ec2InstanceRole` / `Ec2InstanceProfile` — trust `ec2.amazonaws.com`, `AmazonSSMManagedInstanceCore`
  only (Session Manager access, no SSH/bastion needed).
- `LambdaExecutionRole` — trust `lambda.amazonaws.com`, `AWSLambdaBasicExecutionRole`.
- `EcsTaskExecutionRole` — trust `ecs-tasks.amazonaws.com`, `AmazonECSTaskExecutionRolePolicy`.

**Out of scope on purpose:** AWS Organizations and SCPs require an existing Organization and
are not safe to assume in a base stack. Scenarios that need an SCP are modeled individually
under `scenarios/domain-6-security/` with their own README calling out the Organization
prerequisite.

## Deploy

```bash
make base-plan NAME=iam-baseline
make base-deploy NAME=iam-baseline
```

## Outputs

- `dop-lab-base-iam-baseline-PermissionBoundaryArn`
- `dop-lab-base-iam-baseline-Ec2InstanceRoleArn`
- `dop-lab-base-iam-baseline-Ec2InstanceProfileArn`
- `dop-lab-base-iam-baseline-LambdaExecutionRoleArn`
- `dop-lab-base-iam-baseline-EcsTaskExecutionRoleArn`

## Teardown

```bash
make base-destroy-all
```
