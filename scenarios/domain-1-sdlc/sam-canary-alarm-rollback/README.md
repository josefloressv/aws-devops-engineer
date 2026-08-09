# SAM canary deployment with alarm rollback

**Domain 1 — SDLC Automation**

A Lambda function with `AutoPublishAlias: live` and a `DeploymentPreference` of
`Canary10Percent5Minutes`, with a CloudWatch alarm and pre/post traffic hooks. The scenario
shows what SAM synthesises that nobody wrote, what the alias looks like mid-shift, and what a
tripped alarm does to both CodeDeploy **and** the CloudFormation stack.

This README records commands and raw output only. It does not label any option as correct —
compare the captures yourself. A full run was executed on 2026-08-08; raw terminal output is
in [Observed output](#observed-output--run-of-2026-08-08).

## Deviation from the repo layout

**This scenario has no `template.yaml` / `params.json` here and is not deployed with
`make apply`.** It is a SAM template with `Transform: AWS::Serverless-2016-10-31`, and the
whole point is the macro expansion, so it is deployed with `sam deploy` from the application
repository:

```
aws-devops-sdlc-automation/sam-canary/
  template.yaml          <- the authored template
  app.py                 <- bump VERSION to trigger a deployment
  hooks/pre_traffic.py
  hooks/post_traffic.py
```

Stack name is `dop-c02-sam-canary` (SAM-managed), not `dop-lab-d1-*`.

## Deploy

```bash
cd ~/git/aws-devops-sdlc-automation/sam-canary
sam build
sam deploy --stack-name dop-c02-sam-canary --resolve-s3 --capabilities CAPABILITY_IAM \
  --no-confirm-changeset --region us-east-1 \
  --tags Project=dop-c02-lab Domain=1 Scenario=sam-canary-alarm-rollback
```

The first deploy creates version 1 and points `live` at it. There is no traffic shift on the
first deploy — there is nothing to shift from.

## Cost

Effectively $0. Three 128 MB Lambda functions, one alarm, a few hundred invocations.

## Reproduce

### E4.1 — what SAM synthesised

```bash
aws cloudformation list-stack-resources --stack-name dop-c02-sam-canary \
  --query 'sort_by(StackResourceSummaries,&ResourceType)[].{Logical:LogicalResourceId,Type:ResourceType}' --output table

grep -E '^  [A-Za-z]+:$' ~/git/aws-devops-sdlc-automation/sam-canary/template.yaml

aws cloudformation get-template --stack-name dop-c02-sam-canary --template-stage Processed \
  --query 'TemplateBody.Resources.CanaryFunctionDeploymentGroup'
aws cloudformation get-template --stack-name dop-c02-sam-canary --template-stage Processed \
  --query 'TemplateBody.Resources.CodeDeployServiceRole.Properties'
```

### E4.2 — the shift, polled

Bump `VERSION` in `app.py`, `sam build`, `sam deploy`, and poll the alias while the deploy
blocks:

```bash
FN=$(aws cloudformation describe-stacks --stack-name dop-c02-sam-canary \
      --query 'Stacks[0].Outputs[?OutputKey==`FunctionName`].OutputValue' --output text)

while true; do
  aws lambda get-alias --function-name "$FN" --name live \
    --query '[FunctionVersion,RoutingConfig.AdditionalVersionWeights]' --output json
  for i in $(seq 1 10); do
    aws lambda invoke --function-name "${FN}:live" --payload '{}' \
      --cli-binary-format raw-in-base64-out /dev/stdout --query 'StatusCode' --output text
  done
  sleep 20
done
```

In **zsh** the braces in `"${FN}:live"` are required. `"$FN:live"` applies the `:l` history
modifier and calls a function that does not exist.

### E4.3 — the CodeDeploy record behind the SAM deploy

```bash
APP=$(aws deploy list-applications --query "applications[?contains(@,'sam-canary')]|[0]" --output text)
DG=$(aws deploy list-deployment-groups --application-name "$APP" --query 'deploymentGroups[0]' --output text)
D=$(aws deploy list-deployments --application-name "$APP" --deployment-group-name "$DG" --query 'deployments[0]' --output text)

aws deploy get-deployment --deployment-id "$D" \
  --query 'deploymentInfo.{Status:status,Config:deploymentConfigName,Creator:creator}'

TID=$(aws deploy list-deployment-targets --deployment-id "$D" --query 'targetIds[0]' --output text)
aws deploy get-deployment-target --deployment-id "$D" --target-id "$TID" \
  --query 'deploymentTarget.lambdaTarget.lifecycleEvents[].{Event:lifecycleEventName,Status:status}' --output table
aws deploy get-deployment-target --deployment-id "$D" --target-id "$TID" \
  --query 'deploymentTarget.lambdaTarget.lambdaFunctionInfo'
```

Put that lifecycle-event list next to the ECS one in
[`ecs-bluegreen-codedeploy`](../ecs-bluegreen-codedeploy/README.md#e32--replacement-revision-and-lifecycle-events).

### E4.4 — hook invocations

```bash
aws logs tail /aws/lambda/CodeDeployHook_dop-c02-sam-canary-pre --since 30m
aws logs tail /aws/lambda/CodeDeployHook_dop-c02-sam-canary-post --since 30m
```

### E4.5 — forced rollback

Bump `VERSION` again, start `sam deploy`, and trip the alarm as soon as
`AdditionalVersionWeights` becomes non-null:

```bash
ALARM=$(aws cloudformation describe-stacks --stack-name dop-c02-sam-canary \
         --query 'Stacks[0].Outputs[?OutputKey==`AlarmName`].OutputValue' --output text)
aws cloudwatch set-alarm-state --alarm-name "$ALARM" \
  --state-value ALARM --state-reason "forced for lab evidence"
```

Then read three things: the alias, the CodeDeploy deployment, and the CloudFormation stack.

## Teardown

```bash
sam delete --stack-name dop-c02-sam-canary --no-prompts --region us-east-1
```

`sam delete` also offers to remove the artifact bucket it created with `--resolve-s3`.

## Observed output — run of 2026-08-08

### E4.1 — authored vs deployed

Resources in the deployed stack:

```
-------------------------------------------------------------------------
|                          ListStackResources                           |
+----------------------------------+------------------------------------+
|              Logical             |               Type                 |
+----------------------------------+------------------------------------+
|  CanaryErrorAlarm                |  AWS::CloudWatch::Alarm            |
|  ServerlessDeploymentApplication |  AWS::CodeDeploy::Application      |
|  CanaryFunctionDeploymentGroup   |  AWS::CodeDeploy::DeploymentGroup  |
|  CanaryFunctionRole              |  AWS::IAM::Role                    |
|  CodeDeployHookPostTrafficRole   |  AWS::IAM::Role                    |
|  CodeDeployHookPreTrafficRole    |  AWS::IAM::Role                    |
|  CodeDeployServiceRole           |  AWS::IAM::Role                    |
|  CanaryFunctionAliaslive         |  AWS::Lambda::Alias                |
|  CanaryFunction                  |  AWS::Lambda::Function             |
|  CodeDeployHookPostTraffic       |  AWS::Lambda::Function             |
|  CodeDeployHookPreTraffic        |  AWS::Lambda::Function             |
|  CanaryFunctionVersion0f29531eeb |  AWS::Lambda::Version              |
+----------------------------------+------------------------------------+
```

Top-level keys actually written in `sam-canary/template.yaml`:

```
  Function:            <- Globals
  CanaryFunction:
  CanaryErrorAlarm:
  CodeDeployHookPreTraffic:
  CodeDeployHookPostTraffic:
  FunctionName:        <- Outputs
  AliasQualifiedName:
  AlarmName:
```

The synthesised deployment group:

```json
{
    "Type": "AWS::CodeDeploy::DeploymentGroup",
    "Properties": {
        "AlarmConfiguration": {
            "Enabled": true,
            "Alarms": [ { "Name": { "Ref": "CanaryErrorAlarm" } } ]
        },
        "ApplicationName": { "Ref": "ServerlessDeploymentApplication" },
        "AutoRollbackConfiguration": {
            "Enabled": true,
            "Events": [
                "DEPLOYMENT_FAILURE",
                "DEPLOYMENT_STOP_ON_ALARM",
                "DEPLOYMENT_STOP_ON_REQUEST"
            ]
        },
        "DeploymentConfigName": {
            "Fn::Sub": [ "CodeDeployDefault.Lambda${ConfigName}",
                         { "ConfigName": "Canary10Percent5Minutes" } ]
        },
        "DeploymentStyle": {
            "DeploymentType": "BLUE_GREEN",
            "DeploymentOption": "WITH_TRAFFIC_CONTROL"
        },
        "ServiceRoleArn": { "Fn::GetAtt": [ "CodeDeployServiceRole", "Arn" ] }
    }
}
```

The synthesised CodeDeploy service role:

```json
{
    "AssumeRolePolicyDocument": {
        "Version": "2012-10-17",
        "Statement": [ { "Action": ["sts:AssumeRole"], "Effect": "Allow",
                         "Principal": { "Service": ["codedeploy.amazonaws.com"] } } ]
    },
    "ManagedPolicyArns": [
        "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda"
    ]
}
```

Baseline alias, before any shift:

```json
{ "Alias": "live", "Version": "1", "Weights": null }
$ aws lambda list-versions-by-function ... --query 'Versions[].Version'
$LATEST	1
$ aws lambda invoke --function-name "${FN}:live" ...
{"statusCode": 200, "body": "{\"version\": \"v1\"}"}200
```

### E4.2 — v1 → v2 canary, polled every ~27 s

```
ELAPSED  ALIAS_VER  ADDITIONAL_VERSION_WEIGHTS                 INVOKE_RESULTS(10)
10s      ["1",null]                                            v1v1v1v1v1v1v1v1v1v1
42s      ["1",null]                                            v1v1v1v1v1v1v1v1v1v1
70s      ["1",{"2":0.1}]                                       v1v1v2v1v1v1v1v1v1v1
97s      ["1",{"2":0.1}]                                       v1v1v1v1v1v1v2v2v1v1
124s     ["1",{"2":0.1}]                                       v1v1v1v1v1v1v1v1v1v2
152s     ["1",{"2":0.1}]                                       v1v1v1v1v2v1v1v1v1v1
179s     ["1",{"2":0.1}]                                       v1v1v1v1v1v1v1v1v1v1
206s     ["1",{"2":0.1}]                                       v1v1v1v1v1v1v1v1v1v1
233s     ["1",{"2":0.1}]                                       v1v1v1v2v1v1v1v1v1v1
261s     ["1",{"2":0.1}]                                       v1v1v1v1v2v2v1v1v1v2
288s     ["1",{"2":0.1}]                                       v1v1v1v1v1v1v1v1v1v1
315s     ["1",{"2":0.1}]                                       v1v1v1v1v1v1v1v1v1v1
343s     ["2",null]                                            v2v2v2v2v2v2v2v2v2v2
370s     ["2",null]                                            v2v2v2v2v2v2v2v2v2v2
```

`FunctionVersion` stays `"1"` for the whole shift; the new version appears only inside
`AdditionalVersionWeights`. `sam deploy` returned only after 343 s.

### E4.3 — the CodeDeploy deployment behind it

```json
{
    "Status": "Succeeded",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Creator": "user",
    "Start": "2026-08-08T19:47:26.915000-06:00",
    "End": "2026-08-08T19:52:31.851000-06:00"
}
```

```
-------------------------------------
|        GetDeploymentTarget        |
+---------------------+-------------+
|        Event        |   Status    |
+---------------------+-------------+
|  BeforeAllowTraffic |  Succeeded  |
|  AllowTraffic       |  Succeeded  |
|  AfterAllowTraffic  |  Succeeded  |
+---------------------+-------------+
```

```json
{ "Function": "dop-c02-sam-canary-CanaryFunction-...",
  "Current": "1", "Target": "2", "Alias": "live", "Pct": 1.0 }
```

Three lifecycle events here; eight for the ECS deployment in the sibling scenario.

### E4.4 — hook invocations

`CodeDeployHook_dop-c02-sam-canary-pre`, both deployments:

```
01:47:29 PreTraffic hook event: {'DeploymentId': 'd-0B7YUA91L', 'LifecycleEventHookExecutionId': 'eyJlbmNyeXB0ZWREYXRhIjoi...'}
01:54:42 PreTraffic hook event: {'DeploymentId': 'd-RGSWBD91L', 'LifecycleEventHookExecutionId': 'eyJlbmNyeXB0ZWREYXRhIjoi...'}
```

`CodeDeployHook_dop-c02-sam-canary-post`, all invocations in the same window:

```
01:52:31 PostTraffic hook event: {'DeploymentId': 'd-0B7YUA91L', 'LifecycleEventHookExecutionId': 'eyJlbmNyeXB0ZWREYXRhIjoi...'}
```

The event body carries exactly two fields, and the `LifecycleEventHookExecutionId` is an
opaque encrypted blob — it is the value passed back to
`put_lifecycle_event_hook_execution_status`.

Timings against E4.3's deployment window (`19:47:26` → `19:52:31` local, i.e. `01:47:26` →
`01:52:31` UTC): PreTraffic ran ~2 s after the deployment started, PostTraffic ~0.4 s before
it completed.

### E4.5 — forced rollback on v2 → v3

```
ELAPSED  ALIAS[VER,WEIGHTS]       NOTE
0s       ["2",null]
16s      ["2",null]
32s      ["2",null]
48s      ["2",{"3":0.1}]          <-- set-alarm-state ALARM issued here
64s      ["2",null]
80s      ["2",null]
```

The deployment that was shifting:

```json
{
    "Status": "Stopped",
    "Config": "CodeDeployDefault.LambdaCanary10Percent5Minutes",
    "Error": {
        "code": "ALARM_ACTIVE",
        "message": "One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <dop-c02-sam-canary-CanaryErrorAlarm-...>"
    },
    "Rollback": {
        "rollbackDeploymentId": "d-J5KH1W91L",
        "rollbackMessage": "Deployment d-RGSWBD91L terminated. Automatic rollback is triggered with a DeploymentId d-J5KH1W91L."
    }
}
```

```
-------------------------------------          -------------------------------------
|   d-RGSWBD91L (stopped)           |          |   d-J5KH1W91L (the rollback)      |
+---------------------+-------------+          +---------------------+-------------+
|  BeforeAllowTraffic |  Succeeded  |          |  BeforeAllowTraffic |  Succeeded  |
|  AllowTraffic       |  Failed     |          |  AllowTraffic       |  Succeeded  |
|  AfterAllowTraffic  |  Skipped    |          |  AfterAllowTraffic  |  Succeeded  |
+---------------------+-------------+          +---------------------+-------------+
```

The rollback deployment reports `rollbackTriggeringDeploymentId`, the stopped one reports
`rollbackDeploymentId` — the same relationship read from either end.

Alias afterwards:

```json
{ "Version": "2", "Weights": null }
```

And the CloudFormation side of the same event:

```
UPDATE_FAILED            AWS::Lambda::Alias       CanaryFunctionAliaslive
UPDATE_ROLLBACK_IN_PROGRESS  AWS::CloudFormation::Stack  dop-c02-sam-canary
UPDATE_ROLLBACK_COMPLETE     AWS::CloudFormation::Stack  dop-c02-sam-canary
Error: Failed to create/update the stack: dop-c02-sam-canary, Waiter StackUpdateComplete failed:
Waiter encountered a terminal failure state: For expression "Stacks[].StackStatus" we matched
expected path: "UPDATE_ROLLBACK_COMPLETE" at least once
SAM_EXIT=1
```

```json
[
    {
        "Res": "CanaryFunctionAliaslive",
        "Reason": "Resource handler returned message: \"d-RGSWBD91L failed. One or more alarms have been activated according to the Amazon CloudWatch metrics you selected, and the affected deployments have been stopped. Activated alarms: <dop-c02-sam-canary-CanaryErrorAlarm-...>\" (RequestToken: ..., HandlerErrorCode: InternalFailure)"
    }
]
```

Version 3 exists as a published Lambda version; only the alias moved back.
