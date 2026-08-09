# ECS blue/green with CodeDeploy: linear shifting and alarm rollback

**Domain 1 — SDLC Automation**

An ALB with **two** listeners and **two** target groups, a Fargate service whose deployment
controller is `CODE_DEPLOY`, and a deployment group set to
`CodeDeployDefault.ECSLinear10PercentEvery1Minutes` with a CloudWatch alarm wired in as a
rollback trigger.

The point of the scenario is to watch, with raw output, what CodeDeploy actually does to the
load balancer during a deployment — which listener points where, when, and what a rollback
reverts.

This README records commands and raw output only. It does not label any option as correct —
compare the captures yourself. A full run was executed on 2026-08-08; raw terminal output is
in [Observed output](#observed-output--run-of-2026-08-08).

## Shape of the stack

| Resource | Why it is shaped that way |
| --- | --- |
| `DeploymentController: CODE_DEPLOY` on the service | With the default `ECS` controller the service performs its own rolling update and CodeDeploy cannot drive it at all |
| `TargetType: ip` on both target groups | `awsvpc` network mode registers ENI addresses, not instances |
| Prod listener `:80`, test listener `:8080` | The test listener is what lets the replacement task be probed before it takes production traffic |
| `LoadBalancers` on the service points at **blue only** | The template declares the starting position; CodeDeploy rewrites the listener from there |
| `AlarmConfiguration` + `AutoRollbackConfiguration` | Two separate blocks — one names the alarm, the other says which *events* roll back |
| `TerminationWaitTimeInMinutes: 5` | The original task set is kept idle after the shift completes, not deleted immediately |

The images come from ECR repository `dop-c02-lab`, tags `:blue` and `:green`. Both are
`nginx:alpine` serving a single line, `VERSION=BLUE` or `VERSION=GREEN`, so a `curl` says
unambiguously which task set answered.

## Prerequisites

`dop-lab-base-network` must exist — the ALB and the Fargate tasks both land in its two public
subnets (`AssignPublicIp: ENABLED`, so no NAT Gateway is involved).

The ECR images are seeded by [`seed-images.sh`](seed-images.sh), which builds them inside a
**CodeBuild project with `privilegedMode: true`** and deletes that project and its role on the
way out — no local Docker daemon needed. Source is the CodeCommit mirror of
[`aws-devops-sdlc-automation`](https://github.com/josefloressv/aws-devops-sdlc-automation),
so the image is built from the committed `docker/Dockerfile`.

```bash
./scenarios/domain-1-sdlc/ecs-bluegreen-codedeploy/seed-images.sh
```

The ECR repository is deliberately **not** a CloudFormation resource: it outlives this stack
so the EKS scenario can reuse the same images.

## Cost

ALB ~$0.0225/hr plus 1–2 Fargate tasks at 0.25 vCPU / 0.5 GB. Tear down as soon as the
evidence is captured — the ALB is the recurring charge.

## Deploy

```bash
make apply LAB=domain-1-sdlc/ecs-bluegreen-codedeploy
```

## Reproduce

```bash
STACK=dop-lab-d1-ecs-bluegreen-codedeploy
eval "$(aws cloudformation describe-stacks --stack-name $STACK \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text \
  | awk '{printf "P3_%s=\"%s\"\n",$1,$2}')"
```

### E3.1 — baseline

```bash
aws ecs describe-services --cluster "$P3_ClusterName" --services "$P3_ServiceName" \
  --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Controller:deploymentController.type,TaskDef:taskDefinition}' \
  --output table

aws elbv2 describe-target-health --target-group-arn "$P3_TargetGroupBlueArn" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State}' --output table
aws elbv2 describe-target-health --target-group-arn "$P3_TargetGroupGreenArn" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' --output table

curl -s "$P3_ProdUrl"
curl -s -o /dev/null -w "%{http_code}\n" "$P3_TestUrl"

aws elbv2 describe-listeners --listener-arns "$P3_ProdListenerArn" \
  --query 'Listeners[0].DefaultActions' --output json
aws elbv2 describe-listeners --listener-arns "$P3_TestListenerArn" \
  --query 'Listeners[0].DefaultActions' --output json
```

### E3.2 — register the replacement revision and start a deployment

```bash
aws ecs describe-task-definition --task-definition dop-c02-lab-task:1 \
  --query 'taskDefinition' --output json > td1.json
# strip the read-only fields, swap :blue -> :green, re-register
python3 - <<'PY'
import json, re
td = json.load(open("td1.json"))
for k in ("taskDefinitionArn","revision","status","requiresAttributes",
          "compatibilities","registeredAt","registeredBy","deregisteredAt"):
    td.pop(k, None)
c = td["containerDefinitions"][0]
c["image"] = re.sub(r":blue$", ":green", c["image"])
json.dump(td, open("td2.json","w"), indent=2)
PY
NEW_TD=$(aws ecs register-task-definition --cli-input-json file://td2.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)

# ecs/appspec.yaml in the application repo is the same document with
# TASK_DEFINITION_ARN_PLACEHOLDER where $NEW_TD goes.
cat > appspec.json <<JSON
{"version":0.0,"Resources":[{"TargetService":{"Type":"AWS::ECS::Service",
  "Properties":{"TaskDefinition":"$NEW_TD",
  "LoadBalancerInfo":{"ContainerName":"app","ContainerPort":80}}}}]}
JSON
APPSPEC=$(python3 -c 'import json,sys;print(json.dumps(open("appspec.json").read()))')

DEP_ID=$(aws deploy create-deployment \
  --application-name dop-c02-ecs-app --deployment-group-name dop-c02-ecs-dg \
  --revision "{\"revisionType\":\"AppSpecContent\",\"appSpecContent\":{\"content\":$APPSPEC}}" \
  --query 'deploymentId' --output text)

TID=$(aws deploy list-deployment-targets --deployment-id "$DEP_ID" --query 'targetIds[0]' --output text)
aws deploy get-deployment-target --deployment-id "$DEP_ID" --target-id "$TID" \
  --query 'deploymentTarget.ecsTarget.lifecycleEvents[].{Event:lifecycleEventName,Status:status}' --output table
```

Note where the lifecycle events come from: `get-deployment` never carries them. While an ECS
deployment is running it returns `deploymentOverview: null` and `instanceOverview: null`; once
it finishes, `deploymentOverview` fills in with **deployment-target** counts, not instance
counts. The per-event list is only on the target:

```bash
# InProgress
$ aws deploy get-deployment --deployment-id d-BDS7SUA1L \
    --query 'deploymentInfo.{Status:status,Overview:deploymentOverview,Instances:instanceOverview}'
{ "Status": "InProgress", "Overview": null, "Instances": null }

# after it completed
$ aws deploy get-deployment --deployment-id d-A7YW3F91L \
    --query 'deploymentInfo.deploymentOverview'
{ "Pending": 0, "InProgress": 0, "Succeeded": 1, "Failed": 0, "Skipped": 0, "Ready": 0 }
```

One target, not ten tasks.

### E3.3 — traffic during the shift

Poll production and the listener weights every 20 s until the deployment reaches a terminal
state:

```bash
while true; do
  ST=$(aws deploy get-deployment --deployment-id "$DEP_ID" --query 'deploymentInfo.status' --output text)
  B=0; G=0
  for i in $(seq 1 10); do
    R=$(curl -s --max-time 3 "$P3_ProdUrl" | grep -o 'VERSION=[A-Z]*')
    case "$R" in *BLUE) B=$((B+1));; *GREEN) G=$((G+1));; esac
  done
  W=$(aws elbv2 describe-listeners --listener-arns "$P3_ProdListenerArn" \
       --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' \
       --output text | awk -F'\t' '{n=split($1,a,"/"); printf "%s=%s ", a[2], $2}')
  echo "$ST blue=$B green=$G $W"
  case "$ST" in Succeeded|Failed|Stopped) break;; esac
  sleep 20
done
```

And, at the moment the replacement task set is healthy but before any production traffic
shifts, probe both listeners together:

```bash
for i in 1 2 3 4 5; do curl -s "$P3_ProdUrl" | grep -o 'VERSION=[A-Z]*'; done
for i in 1 2 3 4 5; do curl -s "$P3_TestUrl" | grep -o 'VERSION=[A-Z]*'; done
```

### E3.4 — forced rollback

Start a second deployment, then push the alarm into `ALARM` while it is shifting:

```bash
aws cloudwatch set-alarm-state --alarm-name dop-c02-ecs-5xx \
  --state-value ALARM --state-reason "forced for lab evidence"

aws deploy get-deployment --deployment-id "$DEP_ID2" \
  --query 'deploymentInfo.{Status:status,Error:errorInformation,Rollback:rollbackInfo}' --output json
```

### E3.5 — the deployment configs that exist (read-only)

```bash
aws deploy list-deployment-configs --query 'deploymentConfigsList' --output text | tr '\t' '\n' | sort
aws deploy get-deployment-config --deployment-config-name <name> \
  --query 'deploymentConfigInfo.{Name:deploymentConfigName,Platform:computePlatform,Traffic:trafficRoutingConfig}'
```

## Teardown

```bash
make destroy LAB=domain-1-sdlc/ecs-bluegreen-codedeploy
```

The ECR repository `dop-c02-lab` and its images are **not** in the stack and survive teardown
on purpose. Remove them only after the EKS scenario is done:

```bash
aws ecr delete-repository --repository-name dop-c02-lab --force
```

The task definition revisions registered by hand are also outside the stack:

```bash
for R in $(aws ecs list-task-definitions --family-prefix dop-c02-lab-task \
             --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$R" --query 'taskDefinition.revision'
done
```

## Observed output — run of 2026-08-08

Account ID redacted as `<ACCOUNT_ID>`.

### E3.1 — baseline

```
=== service ===
-----------------------------------------------------------------------------------------
|                                   DescribeServices                                    |
+------------+--------------------------------------------------------------------------+
|  Controller|  CODE_DEPLOY                                                             |
|  Desired   |  1                                                                       |
|  Running   |  1                                                                       |
|  Status    |  ACTIVE                                                                  |
|  TaskDef   |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:1   |
+------------+--------------------------------------------------------------------------+
=== blue TG health ===
--------------------------------------------
|           DescribeTargetHealth           |
+------+---------+-----------+-------------+
| Port | Reason  |   State   |   Target    |
+------+---------+-----------+-------------+
|  80  |  None   |  healthy  |  10.0.1.85  |
+------+---------+-----------+-------------+
=== green TG health ===
```

The green target group returns nothing at all — no targets are registered.

```
=== curl prod (:80) x5 ===
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE

=== curl test (:8080) ===
http_code=503
```

Listener default actions, both listeners, immediately after `CREATE_COMPLETE`:

```json
=== prod listener default action ===
[
    {
        "Type": "forward",
        "ForwardConfig": {
            "TargetGroups": [
                { "TargetGroupArn": ".../targetgroup/dop-la-Targe-MIF6F1XDF7I4/...", "Weight": 0 },
                { "TargetGroupArn": ".../targetgroup/dop-la-Targe-PFHSIZEJATKK/...", "Weight": 100 }
            ],
            "TargetGroupStickinessConfig": { "Enabled": false }
        }
    }
]
=== test listener default action ===
[
    {
        "Type": "forward",
        "TargetGroupArn": ".../targetgroup/dop-la-Targe-MIF6F1XDF7I4/...",
        "ForwardConfig": {
            "TargetGroups": [
                { "TargetGroupArn": ".../targetgroup/dop-la-Targe-MIF6F1XDF7I4/...", "Weight": 1 }
            ],
            "TargetGroupStickinessConfig": { "Enabled": false }
        }
    }
]
```

`PFHSIZEJATKK` is blue, `MIF6F1XDF7I4` is green throughout this document.

The template declares the prod listener as a single-target-group `forward` to blue. What
`describe-listeners` returns is a **weighted two-target-group forward**, and
`DefaultActions[0].TargetGroupArn` is gone — which is why
`--query 'DefaultActions[0].TargetGroupArn'` prints `None` for the prod listener and a real
ARN for the test listener.

### E3.2 — replacement revision and lifecycle events

```
new image: dop-c02-lab:green
registered: arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:2
deployment: d-1NNWZG91L
```

```
{ "Status": "InProgress",
  "Config": "CodeDeployDefault.ECSLinear10PercentEvery1Minutes",
  "Creator": "user",
  "Rollback": { "enabled": true, "events": ["DEPLOYMENT_FAILURE","DEPLOYMENT_STOP_ON_ALARM"] } }

=== lifecycle events from get-deployment ===
null
```

`deploymentOverview` is `null`. The lifecycle events live on the deployment **target**:

```
target id: dop-c02-lab-ecs:dop-c02-lab-svc
-----------------------------------------------------------------------------------------------------------------
|                                              GetDeploymentTarget                                              |
+-----------------------------------+------------------------+------------------------------------+-------------+
|                End                |         Event          |               Start                |   Status    |
+-----------------------------------+------------------------+------------------------------------+-------------+
|  2026-08-08T19:37:35.119000-06:00 |  BeforeInstall         |  2026-08-08T19:37:34.891000-06:00  |  Succeeded  |
|  None                             |  Install               |  2026-08-08T19:37:35.253000-06:00  |  InProgress |
|  None                             |  AfterInstall          |  None                              |  Pending    |
|  None                             |  AllowTestTraffic      |  None                              |  Pending    |
|  None                             |  AfterAllowTestTraffic |  None                              |  Pending    |
|  None                             |  BeforeAllowTraffic    |  None                              |  Pending    |
|  None                             |  AllowTraffic          |  None                              |  Pending    |
|  None                             |  AfterAllowTraffic     |  None                              |  Pending    |
+-----------------------------------+------------------------+------------------------------------+-------------+
```

Eight event names, in that order.

### E3.3a — the two listeners at the same moment

Taken while the replacement task set was healthy and registered, before any production
traffic had shifted:

```
utc=2026-08-09T01:38:42Z
--- prod :80 x5 ---
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
--- test :8080 x5 ---
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
```

### E3.3b — a complete linear shift, polled every ~23 s

Third deployment, `d-A7YW3F91L`, after the alarm was parameterised. `BLUE`/`GREEN` are the
counts out of ten `curl`s against the **prod** listener in that same second;
`PROD_LISTENER_WEIGHTS` is the default action of listener `:80` read from
`describe-listeners` at the same moment. Target group `MIF6F1XDF7I4` holds the replacement
(green) task set, `PFHSIZEJATKK` holds the original (blue).

```
ELAPSED  STATUS       BLUE  GREEN  PROD_LISTENER_WEIGHTS
3s       Created      10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
26s      InProgress   10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
49s      InProgress   10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
72s      InProgress   10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
94s      InProgress   10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
117s     InProgress   10    0      MIF6F1XDF7I4=0   PFHSIZEJATKK=100
140s     InProgress   10    0      MIF6F1XDF7I4=10  PFHSIZEJATKK=90
163s     InProgress   10    0      MIF6F1XDF7I4=10  PFHSIZEJATKK=90
186s     InProgress   9     1      MIF6F1XDF7I4=10  PFHSIZEJATKK=90
209s     InProgress   8     2      MIF6F1XDF7I4=20  PFHSIZEJATKK=80
232s     InProgress   9     1      MIF6F1XDF7I4=20  PFHSIZEJATKK=80
255s     InProgress   9     1      MIF6F1XDF7I4=30  PFHSIZEJATKK=70
278s     InProgress   9     1      MIF6F1XDF7I4=30  PFHSIZEJATKK=70
301s     InProgress   8     2      MIF6F1XDF7I4=30  PFHSIZEJATKK=70
324s     InProgress   6     4      MIF6F1XDF7I4=40  PFHSIZEJATKK=60
347s     InProgress   6     4      MIF6F1XDF7I4=40  PFHSIZEJATKK=60
370s     InProgress   7     3      MIF6F1XDF7I4=40  PFHSIZEJATKK=60
393s     InProgress   3     7      MIF6F1XDF7I4=50  PFHSIZEJATKK=50
415s     InProgress   7     3      MIF6F1XDF7I4=50  PFHSIZEJATKK=50
438s     InProgress   3     7      MIF6F1XDF7I4=60  PFHSIZEJATKK=40
462s     InProgress   4     6      MIF6F1XDF7I4=60  PFHSIZEJATKK=40
485s     InProgress   2     8      MIF6F1XDF7I4=60  PFHSIZEJATKK=40
508s     InProgress   3     7      MIF6F1XDF7I4=70  PFHSIZEJATKK=30
531s     InProgress   3     7      MIF6F1XDF7I4=70  PFHSIZEJATKK=30
554s     InProgress   2     8      MIF6F1XDF7I4=80  PFHSIZEJATKK=20
646s     InProgress   2     8      MIF6F1XDF7I4=90  PFHSIZEJATKK=10
669s     InProgress   0     10     MIF6F1XDF7I4=90  PFHSIZEJATKK=10
692s     InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
715s     InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
738s     InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
761s     InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
```

Points to read off the table rather than infer: nothing shifts for the first ~2 minutes
(`BeforeInstall` → `Install` → `AllowTestTraffic` run first, and the replacement task set has
to reach steady state); the first increment lands at 140 s and each subsequent one ~60 s
later at +10 %; response mix at a given weight is the ALB's own distribution over 10 requests,
not a guarantee (e.g. 10 % weight still returned 10/10 `BLUE` for two polls); and the weight
reaches 100/0 at 692 s while `status` is still `InProgress`.

At 761 s all eight lifecycle events were already `Succeeded`:

```
$ aws deploy get-deployment-target --deployment-id d-A7YW3F91L \
    --target-id dop-c02-lab-ecs:dop-c02-lab-svc \
    --query 'deploymentTarget.ecsTarget.lifecycleEvents[].{E:lifecycleEventName,S:status}'
+------------------------+-------------+
|            E           |      S      |
+------------------------+-------------+
|  BeforeInstall         |  Succeeded  |
|  Install               |  Succeeded  |
|  AfterInstall          |  Succeeded  |
|  AllowTestTraffic      |  Succeeded  |
|  AfterAllowTestTraffic |  Succeeded  |
|  BeforeAllowTraffic    |  Succeeded  |
|  AllowTraffic          |  Succeeded  |
|  AfterAllowTraffic     |  Succeeded  |
+------------------------+-------------+

$ aws deploy get-deployment --deployment-id d-A7YW3F91L --query 'deploymentInfo.status'
"InProgress"
```

The deployment group's blue/green configuration explains the gap between the two:

```json
{
    "terminateBlueInstancesOnDeploymentSuccess": {
        "action": "TERMINATE",
        "terminationWaitTimeInMinutes": 5
    },
    "deploymentReadyOption": {
        "actionOnTimeout": "CONTINUE_DEPLOYMENT",
        "waitTimeInMinutes": 0
    }
}
```

And what the service looks like during that window — both task sets running, both at scale
100, both `STEADY_STATE`:

```
+-------------+------------------------------+---------------+--------+----------+--------------------------------------------------------------------------+
|     Ext     |             Id               |      Sb       | Scale  | Status   |                                   Td                                     |
+-------------+------------------------------+---------------+--------+----------+--------------------------------------------------------------------------+
|  d-A7YW3F91L|  ecs-svc/5782596715501462061 |  STEADY_STATE |  100.0 |  PRIMARY |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:2   |
|  None       |  ecs-svc/2153088967709430471 |  STEADY_STATE |  100.0 |  ACTIVE  |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:1   |
+-------------+------------------------------+---------------+--------+----------+--------------------------------------------------------------------------+
```

Final record:

```json
{
    "Status": "Succeeded",
    "Config": "CodeDeployDefault.ECSLinear10PercentEvery1Minutes",
    "Creator": "user",
    "Start": "2026-08-08T19:51:20.411000-06:00",
    "Complete": "2026-08-08T20:07:36.104000-06:00"
}
```

16 minutes 16 seconds wall clock: roughly 2 min to reach the first shift, 10 min of
`10PercentEvery1Minutes`, 5 min of `terminationWaitTimeInMinutes`.

The same query once the wait expired:

```
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|     Ext     |             Id               | Scale  |  Status   |                                   Td                                     |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|  d-A7YW3F91L|  ecs-svc/5782596715501462061 |  100.0 |  PRIMARY  |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:2   |
|  None       |  ecs-svc/2153088967709430471 |  0.0   |  DRAINING |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:1   |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
```

### E3.4a — an unplanned rollback, and what caused it

The first deployment stopped by itself. It was not forced:

```
ELAPSED   STATUS                 BLUE  GREEN  PROD_LISTENER_WEIGHTS
3s        InProgress             10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
26s       InProgress             10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
48s       InProgress             10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
71s       InProgress             10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
94s       InProgress             10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
118s      Stopped                10    0      MIF6F1XDF7I4=0 PFHSIZEJATKK=100
```

```json
{
    "Status": "Stopped",
    "Error": {
        "code": "ALARM_ACTIVE",
        "message": "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <dop-c02-ecs-5xx>"
    },
    "Rollback": {
        "rollbackDeploymentId": "d-0U9J0T91L",
        "rollbackMessage": "Deployment d-1NNWZG91L terminated. Automatic rollback is triggered with a DeploymentId d-0U9J0T91L."
    }
}
```

Alarm history and the underlying metric:

```
-----------------------------------------------------------------------------------------------------------
|                                          DescribeAlarmHistory                                           |
+-----------------------------------+----------------------------------------------+----------------------+
|                At                 |                   Summary                    |        Type          |
+-----------------------------------+----------------------------------------------+----------------------+
|  2026-08-08T19:39:13.631000-06:00 |  Alarm updated from OK to ALARM              |  StateUpdate         |
|  2026-08-08T19:36:13.635000-06:00 |  Alarm updated from INSUFFICIENT_DATA to OK  |  StateUpdate         |
|  2026-08-08T19:34:58.154000-06:00 |  Alarm "dop-c02-ecs-5xx" created             |  ConfigurationUpdate |
+-----------------------------------+----------------------------------------------+----------------------+

HTTPCode_ELB_5XX_Count, Sum, period 60:
2026-08-08T19:36:00-06:00	1.0
```

That single datapoint is the `curl` from E3.1 against the **test** listener, which returned
`503` because the green target group was still empty. The metric dimension is
`LoadBalancer`, not `TargetGroup`.

The rollback deployment it spawned:

```json
{
    "Status": "Succeeded",
    "Creator": "codeDeployRollback",
    "Config": "CodeDeployDefault.ECSAllAtOnce"
}
```

Lifecycle events of the deployment that was stopped:

```
----------------------------------------
|          GetDeploymentTarget         |
+------------------------+-------------+
|          Event         |   Status    |
+------------------------+-------------+
|  BeforeInstall         |  Succeeded  |
|  Install               |  Failed     |
|  AfterInstall          |  Skipped    |
|  AllowTestTraffic      |  Skipped    |
|  AfterAllowTestTraffic |  Skipped    |
|  BeforeAllowTraffic    |  Skipped    |
|  AllowTraffic          |  Skipped    |
|  AfterAllowTraffic     |  Skipped    |
+------------------------+-------------+
```

Task sets on the service afterwards, and the listener weights:

```
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|     Ext     |             Id               | Scale  |  Status   |                                 TaskDef                                  |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|  None       |  ecs-svc/2153088967709430471 |  100.0 |  PRIMARY  |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:1   |
|  d-1NNWZG91L|  ecs-svc/7625958106979850511 |  0.0   |  DRAINING |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:2   |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+

[ { "TargetGroupArn": ".../dop-la-Targe-MIF6F1XDF7I4/...", "Weight": 0   },
  { "TargetGroupArn": ".../dop-la-Targe-PFHSIZEJATKK/...", "Weight": 100 } ]

VERSION=BLUE
VERSION=BLUE
VERSION=BLUE
```

A second deployment was started and stopped the same way, on two more 5XX at 19:45.

Once the alarm fires it does not clear itself, because `HTTPCode_ELB_5XX_Count` is only
published when it is non-zero — with `TreatMissingData: notBreaching` there is no arriving
datapoint to re-evaluate:

```
$ aws cloudwatch describe-alarms --alarm-names dop-c02-ecs-5xx --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}'
ALARM   Threshold Crossed: 1 datapoint [1.0 (09/08/26 01:36:00)] was greater than or equal to the threshold (1.0).
# still ALARM 6 minutes later, with no further datapoints
$ aws cloudwatch set-alarm-state --alarm-name dop-c02-ecs-5xx --state-value OK --state-reason "..."
OK
```

The template's alarm was therefore parameterised (`Alarm5xxThreshold: 5`,
`Alarm5xxEvaluationPeriods: 2`) so a single stray 5XX cannot stop a deployment. The
deployment group configuration was not touched.

### E3.4b — a deliberate rollback, forced mid-shift

Fourth deployment, `d-BDS7SUA1L`, reverting from `dop-c02-lab-task:2` (green) back to
`dop-c02-lab-task:1` (blue) — so this time the *new* task set lands in `PFHSIZEJATKK` and
`MIF6F1XDF7I4` is the one serving production. Nothing went wrong on its own; the alarm was
pushed into `ALARM` by hand the moment the first 10 % appeared:

```bash
aws cloudwatch set-alarm-state --alarm-name dop-c02-ecs-5xx \
  --state-value ALARM --state-reason "forced for DOP-C02 lab evidence E3.4b"
```

```
ELAPSED  STATUS       BLUE  GREEN  PROD_LISTENER_WEIGHTS              NOTE
2s       Created      0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
25s      InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
48s      InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
72s      InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
95s      InProgress   0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
118s     InProgress   0     10     MIF6F1XDF7I4=90  PFHSIZEJATKK=10   <-- set-alarm-state ALARM issued here
141s     Stopped      0     10     MIF6F1XDF7I4=100 PFHSIZEJATKK=0
```

23 seconds from forcing the alarm to `Stopped` with the weights already back at 100/0.

```json
{
    "Status": "Stopped",
    "Error": {
        "code": "ALARM_ACTIVE",
        "message": "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <dop-c02-ecs-5xx>"
    },
    "Rollback": {
        "rollbackDeploymentId": "d-GJKKPRA1L",
        "rollbackMessage": "Deployment d-BDS7SUA1L terminated. Automatic rollback is triggered with a DeploymentId d-GJKKPRA1L."
    },
    "Config": "CodeDeployDefault.ECSLinear10PercentEvery1Minutes",
    "Creator": "user"
}
```

Lifecycle events of the stopped deployment — compare with E3.4a, where the alarm was already
`ALARM` before the deployment started:

```
+------------------------+-------------+
|          Event         |   Status    |
+------------------------+-------------+
|  BeforeInstall         |  Succeeded  |
|  Install               |  Succeeded  |
|  AfterInstall          |  Succeeded  |
|  AllowTestTraffic      |  Succeeded  |
|  AfterAllowTestTraffic |  Succeeded  |
|  BeforeAllowTraffic    |  Succeeded  |
|  AllowTraffic          |  Failed     |
|  AfterAllowTraffic     |  Skipped    |
+------------------------+-------------+
```

The rollback deployment:

```json
{
    "Status": "Succeeded",
    "Creator": "codeDeployRollback",
    "Config": "CodeDeployDefault.ECSAllAtOnce",
    "Rollback": {
        "rollbackTriggeringDeploymentId": "d-BDS7SUA1L",
        "rollbackMessage": "Deployment d-GJKKPRA1L is triggered to roll back deployment d-BDS7SUA1L."
    }
}
```

Its `deploymentConfigName` is not the one on the deployment group. The relationship is
readable from either end: the stopped deployment reports `rollbackDeploymentId`, the rollback
reports `rollbackTriggeringDeploymentId`.

Listener and traffic afterwards:

```json
[
    { "TargetGroupArn": ".../dop-la-Targe-MIF6F1XDF7I4/...", "Weight": 100 },
    { "TargetGroupArn": ".../dop-la-Targe-PFHSIZEJATKK/...", "Weight": 0   }
]
```

```
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
VERSION=GREEN
```

Task sets:

```
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|     Ext     |             Id               | Scale  |  Status   |                                   Td                                     |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
|  d-A7YW3F91L|  ecs-svc/5782596715501462061 |  100.0 |  PRIMARY  |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:2   |
|  d-BDS7SUA1L|  ecs-svc/4008910740132975493 |  0.0   |  DRAINING |  arn:aws:ecs:us-east-1:<ACCOUNT_ID>:task-definition/dop-c02-lab-task:1   |
+-------------+------------------------------+--------+-----------+--------------------------------------------------------------------------+
```

The `PRIMARY` task set is still the one `d-A7YW3F91L` created — the rollback did not create a
new task set, it drained the one the stopped deployment had built and left production where it
already was.

### E3.5 — deployment configs available in the account

```
CodeDeployDefault.AllAtOnce
CodeDeployDefault.ECSAllAtOnce
CodeDeployDefault.ECSCanary10Percent15Minutes
CodeDeployDefault.ECSCanary10Percent5Minutes
CodeDeployDefault.ECSLinear10PercentEvery1Minutes
CodeDeployDefault.ECSLinear10PercentEvery3Minutes
CodeDeployDefault.HalfAtATime
CodeDeployDefault.LambdaAllAtOnce
CodeDeployDefault.LambdaCanary10Percent10Minutes
CodeDeployDefault.LambdaCanary10Percent15Minutes
CodeDeployDefault.LambdaCanary10Percent30Minutes
CodeDeployDefault.LambdaCanary10Percent5Minutes
CodeDeployDefault.LambdaLinear10PercentEvery10Minutes
CodeDeployDefault.LambdaLinear10PercentEvery1Minute
CodeDeployDefault.LambdaLinear10PercentEvery2Minutes
CodeDeployDefault.LambdaLinear10PercentEvery3Minutes
CodeDeployDefault.OneAtATime
```

```json
{ "Name": "CodeDeployDefault.ECSLinear10PercentEvery1Minutes", "Platform": "ECS",
  "Traffic": { "type": "TimeBasedLinear", "timeBasedLinear": { "linearPercentage": 10, "linearInterval": 1 } } }
{ "Name": "CodeDeployDefault.ECSCanary10Percent5Minutes", "Platform": "ECS",
  "Traffic": { "type": "TimeBasedCanary", "timeBasedCanary": { "canaryPercentage": 10, "canaryInterval": 5 } } }
{ "Name": "CodeDeployDefault.ECSAllAtOnce", "Platform": "ECS",
  "Traffic": { "type": "AllAtOnce" } }
{ "Name": "CodeDeployDefault.LambdaCanary10Percent5Minutes", "Platform": "Lambda",
  "Traffic": { "type": "TimeBasedCanary", "timeBasedCanary": { "canaryPercentage": 10, "canaryInterval": 5 } } }
```

Note which names carry an `ECS`/`Lambda` prefix and which do not.
