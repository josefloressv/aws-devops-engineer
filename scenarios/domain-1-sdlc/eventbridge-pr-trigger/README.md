# EventBridge: pull request events as a pipeline trigger

**Domain 1 — SDLC Automation**

Follow-on to
[`codepipeline-artifacts-and-reports`](../codepipeline-artifacts-and-reports/README.md),
whose pipeline this stack targets. That lab left one thing unanswered — every execution
was started by hand (`triggerType: StartPipelineExecution`). This one wires an event source
to the same pipeline and captures what changes.

Two rules, deliberately near-identical, so the difference between them is the only variable:

| Rule | `detail.event` matched | Targets |
| --- | --- | --- |
| `dop-c02-pr-trigger` | `pullRequestCreated`, `pullRequestSourceBranchUpdated` | pipeline **+** log group |
| `dop-c02-pr-trigger-closed` | `pullRequestStatusChanged` | log group only |

The log targets exist so the raw matched event body is visible. Without them a
non-matching event is indistinguishable from a delivery failure.

This README records commands and raw output only. It does not label any option as correct
— compare the captures yourself. A full run was executed on 2026-08-08; raw terminal
output is in [Observed output](#observed-output--run-of-2026-08-08).

## The lab this was supposed to be, and why it changed

The original scenario plan assumed CodeCommit would be unavailable in this account and
that pull request events would therefore be simulated with `aws events put-events`.

**That approach cannot work.** `put-events` rejects any entry whose `Source` begins with
`aws.` — the prefix is reserved for genuine service events. See
[E2.2](#e22--synthetic-events-are-rejected). CodeCommit turned out to be usable in this
account, so every event below is a real one produced by a real pull request.

## Two permission models in one rule

Worth noticing in the template, because the two targets are wired differently:

- The **pipeline** target carries a `RoleArn`. EventBridge assumes that role to call
  `codepipeline:StartPipelineExecution`.
- The **log group** target has `RoleArn: null`. Delivery is authorized by an
  `AWS::Logs::ResourcePolicy` on the log group naming `events.amazonaws.com` as principal
  — permission attached to the destination, not to the rule.

The rule's inline IAM policy sets `PolicyName`. That is a required property of
`AWS::IAM::Role.Policies` and does **not** make the role a named IAM resource — only
`RoleName` and `ManagedPolicyName` do that, and those would fail under
`scripts/lib.sh`'s `CAPABILITY_IAM`. Omitting `PolicyName` fails change-set creation with
`AWS::EarlyValidation::PropertyValidation`, which names neither the property nor the
resource.

## Cost

$0. Two EventBridge rules, two log groups with 1-day retention. EventBridge charges
nothing for AWS service events on the default bus.

## Deploy

Requires the Phase 1 stack, whose `-PipelineArn` and `-PipelineName` exports this stack
imports.

```bash
make apply LAB=domain-1-sdlc/eventbridge-pr-trigger
```

## Reproduce the events

```bash
REPO=dop-c02-sdlc
git checkout -b feature-pr-trigger && git commit --allow-empty -m "diff" && git push codecommit feature-pr-trigger

aws codecommit create-pull-request --title "trigger probe" \
  --targets repositoryName=$REPO,sourceReference=feature-pr-trigger,destinationReference=main

git commit --allow-empty -m "second" && git push codecommit feature-pr-trigger   # source branch updated
aws codecommit update-pull-request-status --pull-request-id <id> --pull-request-status CLOSED
```

---

## Observed output — run of 2026-08-08

Account ID replaced with `<ACCOUNT_ID>` throughout; this repo is public.

### E2.1 — rule and target wiring

```console
$ aws events describe-rule --name dop-c02-pr-trigger
{
    "Name": "dop-c02-pr-trigger",
    "State": "ENABLED",
    "Bus": "default",
    "Pattern": "{\"detail-type\":[\"CodeCommit Pull Request State Change\"],
                 \"resources\":[\"arn:aws:codecommit:us-east-1:<ACCOUNT_ID>:dop-c02-sdlc\"],
                 \"source\":[\"aws.codecommit\"],
                 \"detail\":{\"event\":[\"pullRequestCreated\",\"pullRequestSourceBranchUpdated\"]}}"
}

$ aws events list-targets-by-rule --rule dop-c02-pr-trigger
[
    {
        "Id": "LogMatchedEvent",
        "Arn": "arn:aws:logs:us-east-1:<ACCOUNT_ID>:log-group:/aws/events/dop-c02-pr-trigger",
        "RoleArn": null
    },
    {
        "Id": "StartPipeline",
        "Arn": "arn:aws:codepipeline:us-east-1:<ACCOUNT_ID>:dop-c02-sdlc-pipeline",
        "RoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/dop-lab-d1-eventbridge-pr--EventsInvokePipelineRole-sXYKFVPzcNpg"
    }
]
```

The contrast rule, same source and detail-type, one field different, one target:

```console
$ aws events describe-rule --name dop-c02-pr-trigger-closed
{
    "Pattern": "{\"detail-type\":[\"CodeCommit Pull Request State Change\"],
                 \"source\":[\"aws.codecommit\"],
                 \"detail\":{\"event\":[\"pullRequestStatusChanged\"]}}"
}

$ aws events list-targets-by-rule --rule dop-c02-pr-trigger-closed
[ { "Id": "LogMatchedEvent", "Arn": ".../aws/events/dop-c02-pr-trigger-closed", "RoleArn": null } ]
```

### E2.2 — synthetic events are rejected

Exactly the call the original plan specified:

```console
$ aws events put-events --entries '[{
    "Source":"aws.codecommit",
    "DetailType":"CodeCommit Pull Request State Change",
    "Detail":"{\"event\":\"pullRequestCreated\",\"repositoryNames\":[\"dop-c02-sdlc\"],\"pullRequestId\":\"1\",...}"
  }]'
{
    "FailedEntryCount": 1,
    "Entries": [
        {
            "ErrorCode": "NotAuthorizedForSourceException",
            "ErrorMessage": "Not authorized for the source."
        }
    ]
}
```

Adding the `Resources` array the rule filters on changes nothing — same rejection:

```console
$ aws events put-events --entries '[{ "Source":"aws.codecommit", ...,
    "Resources":["arn:aws:codecommit:us-east-1:<ACCOUNT_ID>:dop-c02-sdlc"], ... }]'
{ "FailedEntryCount": 1, "Entries": [ { "ErrorCode": "NotAuthorizedForSourceException" } ] }
```

The rejection is on the **`Source` field**, before pattern matching happens. `FailedEntryCount: 1`
means the entry never entered the bus. Nothing reached either rule.

### E2.2 (real) — a genuine pull request

```console
$ aws codecommit create-pull-request --title "Phase 2: real PR to fire pullRequestCreated" \
    --targets repositoryName=dop-c02-sdlc,sourceReference=feature-pr-trigger,destinationReference=main
{ "Id": "1", "Status": "OPEN" }
```

Within ~10 seconds:

```console
$ aws codepipeline list-pipeline-executions --pipeline-name dop-c02-sdlc-pipeline --max-items 3
[
    {
        "id": "13d703ae-b3e9-4a4b-b9e7-6ef799cc8755",
        "triggerType": "CloudWatchEvent",
        "triggerDetail": "arn:aws:events:us-east-1:<ACCOUNT_ID>:rule/dop-c02-pr-trigger",
        "start": "2026-08-08T19:17:18.027000-06:00"
    },
    {
        "id": "927a8a3c-093a-4353-ae98-9a06abe2470d",
        "triggerType": "StartPipelineExecution",
        "triggerDetail": "arn:aws:sts::<ACCOUNT_ID>:assumed-role/AWSReservedSSO_AdministratorAccess_.../jflores",
        "start": "2026-08-08T17:28:33.820000-06:00"
    }
]
```

`triggerType` is `CloudWatchEvent` and `triggerDetail` is the **rule ARN**. Compare with
the manual executions, where `triggerDetail` is the caller's assumed-role ARN.

The raw matched event, from the log target:

```json
{
  "version": "0",
  "id": "bf7f5f31-8efa-7871-6656-7d2e6812b7d5",
  "detail-type": "CodeCommit Pull Request State Change",
  "source": "aws.codecommit",
  "account": "<ACCOUNT_ID>",
  "time": "2026-08-09T01:17:17Z",
  "region": "us-east-1",
  "resources": ["arn:aws:codecommit:us-east-1:<ACCOUNT_ID>:dop-c02-sdlc"],
  "detail": {
    "event": "pullRequestCreated",
    "pullRequestId": "1",
    "pullRequestStatus": "Open",
    "isMerged": "False",
    "repositoryNames": ["dop-c02-sdlc"],
    "sourceReference": "refs/heads/feature-pr-trigger",
    "destinationReference": "refs/heads/main",
    "sourceCommit": "d502898c1161918d4afd75aefb10b01628489124",
    "destinationCommit": "7034b50322c8bf770d40fe9ede9c6c20462e236e",
    "author": "arn:aws:sts::<ACCOUNT_ID>:assumed-role/AWSReservedSSO_AdministratorAccess_.../jflores",
    "title": "Phase 2: real PR to fire pullRequestCreated",
    "revisionId": "f578485a8fa0ec52e00dd14144b8aafdbb76cb5852f70a9356dc58fbd1fcce05"
  }
}
```

Note `resources` is populated by the service, and `detail` carries both
`sourceCommit` and `destinationCommit`.

### E2.3 — which commit the triggered execution actually built

The PR's source branch was at `d502898c`. What the Source action fetched:

```console
$ aws codepipeline list-action-executions --pipeline-name dop-c02-sdlc-pipeline \
    --filter pipelineExecutionId=13d703ae-b3e9-4a4b-b9e7-6ef799cc8755 \
    --query 'actionExecutionDetails[?actionName==`Source`].output.outputVariables'
[
    {
        "BranchName": "main",
        "CommitId": "7034b50322c8bf770d40fe9ede9c6c20462e236e",
        "CommitMessage": "Move the unused-import comment off the import line...",
        "FullRepositoryName": "josefloressv/aws-devops-sdlc-automation",
        "ProviderType": "GitHub",
        "ConnectionArn": "arn:aws:codeconnections:us-east-1:<ACCOUNT_ID>:connection/bd7ccc21-..."
    }
]
```

| | Value |
| --- | --- |
| PR source branch commit | `d502898c` (`refs/heads/feature-pr-trigger`) |
| Commit the pipeline built | `7034b50` (`main`) |
| Repository fetched from | GitHub, via CodeConnections |
| Repository the event came from | CodeCommit `dop-c02-sdlc` |

The event that started the run and the source the run fetched are unrelated.

### E2.3 — matching vs non-matching events

Three real events, produced in order. Rule 1's log group:

```console
$ aws logs tail /aws/events/dop-c02-pr-trigger --since 20m
2026-08-09T01:17:17Z  event=pullRequestCreated               prId=1  status=Open  isMerged=False
2026-08-09T01:18:10Z  event=pullRequestSourceBranchUpdated   prId=1  status=Open  isMerged=False
-- 2 event(s) --
```

Rule 2's log group:

```console
$ aws logs tail /aws/events/dop-c02-pr-trigger-closed --since 20m
2026-08-09T01:18:44Z  event=pullRequestStatusChanged         prId=1  status=Closed  isMerged=False
-- 1 event(s) --
```

Pipeline execution count across the three events:

```
after `create-pull-request`                 3 -> 4      (+1)
after push to the PR source branch          4 -> 5      (+1)
after `update-pull-request-status CLOSED`   5 -> 5      (+0, held for 90s)
```

```console
$ # polled every 10s for 90s after closing the PR
01:18:50Z executions=5
01:19:01Z executions=5
...
01:20:17Z executions=5
```

The close event was matched and delivered — it is in rule 2's log group with a timestamp —
and the pipeline did not start. Delivery and triggering are separate facts, which is why
both rules have log targets.

### E2.4 — what the Source action watches

```console
$ aws codepipeline get-pipeline --name dop-c02-sdlc-pipeline \
    --query 'pipeline.stages[0].actions[0].configuration'
{
    "BranchName": "main",
    "ConnectionArn": "arn:aws:codeconnections:us-east-1:<ACCOUNT_ID>:connection/bd7ccc21-...",
    "DetectChanges": "true",
    "FullRepositoryId": "josefloressv/aws-devops-sdlc-automation"
}
```

There is no `PollForSourceChanges` key at all — that property belongs to the `CodeCommit`
and `S3` source providers, not to `CodeStarSourceConnection`. The Phase 1 template encodes
all three behind a `SourceProvider` parameter, so redeploying with
`SourceProvider=CodeCommit` swaps `DetectChanges` for `PollForSourceChanges` in this output.

No key in the source configuration references a pull request, a merge, or a PR id. The
only ref it names is a branch.

### E2.5 — rule metrics

```console
$ aws cloudwatch get-metric-statistics --namespace AWS/Events --metric-name TriggeredRules \
    --dimensions Name=RuleName,Value=dop-c02-pr-trigger --period 60 --statistics Sum
+-----+------------------------------+
| Sum |              T               |
+-----+------------------------------+
|  1.0|  2026-08-08T19:17:00-06:00   |
|  1.0|  2026-08-08T19:18:00-06:00   |
+-----+------------------------------+
```

| Rule | `TriggeredRules` | `Invocations` | `FailedInvocations` | Targets |
| --- | --- | --- | --- | --- |
| `dop-c02-pr-trigger` | 2 | 4 | *(no datapoint)* | 2 |
| `dop-c02-pr-trigger-closed` | 1 | 1 | *(no datapoint)* | 1 |

`TriggeredRules` counts pattern matches. `Invocations` counts target deliveries — 2 matches
across 2 targets is 4. `FailedInvocations` publishes no datapoint rather than a zero.

### E2.6 — two triggered executions, one gate

Both PR events produced an execution, and they overlapped:

```console
$ aws codepipeline get-pipeline-state --name dop-c02-sdlc-pipeline
+---------------------------------------+------------------+-------------+
|                 Exec                  |      Stage       |   Status    |
+---------------------------------------+------------------+-------------+
|  ef5ef413-75db-4183-9b02-25c18e112294 |  Source          |  Succeeded  |
|  ef5ef413-75db-4183-9b02-25c18e112294 |  Build           |  Succeeded  |
|  ef5ef413-75db-4183-9b02-25c18e112294 |  DeployDev       |  Succeeded  |
|  ef5ef413-75db-4183-9b02-25c18e112294 |  DeployStaging   |  Succeeded  |
|  ef5ef413-75db-4183-9b02-25c18e112294 |  IntegrationTest |  Succeeded  |
|  13d703ae-b3e9-4a4b-b9e7-6ef799cc8755 |  ApproveProd     |  InProgress |
+---------------------------------------+------------------+-------------+
```

The older execution (`13d703ae`, from `pullRequestCreated`) holds `ApproveProd`. The newer
one (`ef5ef413`, from `pullRequestSourceBranchUpdated`) has cleared every earlier stage and
is waiting on it. The newer execution did not supersede the older one, and both eventually
reached `Succeeded` after each approval token was answered:

```console
$ aws codepipeline list-pipeline-executions --pipeline-name dop-c02-sdlc-pipeline --max-items 3
+----------------------------------------+------------+
|  ef5ef413-75db-4183-9b02-25c18e112294  |  Succeeded |
|  13d703ae-b3e9-4a4b-b9e7-6ef799cc8755  |  Succeeded |
|  927a8a3c-093a-4353-ae98-9a06abe2470d  |  Failed    |
+----------------------------------------+------------+
```

Answering a token that has already been answered:

```console
$ aws codepipeline put-approval-result --token f7e1f9dc-... --result status=Approved
An error occurred (ApprovalAlreadyCompletedException) when calling the PutApprovalResult
operation: The approval request that you responded to is already complete or has expired.
```

## Teardown

The PR and branch created for the evidence run are not stack resources:

```bash
aws codecommit update-pull-request-status --pull-request-id 1 --pull-request-status CLOSED
git push codecommit --delete feature-pr-trigger
```

The two log groups **are** stack resources here (unlike agent-created groups elsewhere in
this repo) and are removed with the stack:

```bash
make destroy LAB=domain-1-sdlc/eventbridge-pr-trigger
```

Destroy this stack **before** `codepipeline-artifacts-and-reports` — it imports that
stack's `-PipelineArn` and `-PipelineName` exports.
