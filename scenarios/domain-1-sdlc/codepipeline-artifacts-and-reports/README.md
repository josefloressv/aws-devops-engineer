# CodePipeline: artifacts, test reports, and what each stage actually gates

**Domain 1 — SDLC Automation**

A six-stage CodePipeline (Source → Build → DeployDev → DeployStaging → IntegrationTest →
ApproveProd) built to make five things directly observable rather than inferred:

1. The order CodeBuild runs `buildspec.yml` phases in, and how that maps onto CodeBuild's
   own phase table (which is a different list with different names).
2. What `reports:` does that `artifacts:` does not, when both point at the **same** JUnit
   XML file.
3. What `discard-paths` changes about the shape of a secondary artifact.
4. How one identical CloudFormation template body produces two different environments via
   `TemplateConfiguration`.
5. Where a pipeline stops when a Test stage fails — specifically, whether the stage after
   it ever starts.

This README records commands and raw output only. It does not label any option as correct
— compare the captures yourself. A full run was executed on 2026-08-08; raw terminal
output is in [Observed output](#observed-output--run-of-2026-08-08).

## Application source

The pipeline's source is a **separate repository**, not this one:
[`aws-devops-sdlc-automation`](https://github.com/josefloressv/aws-devops-sdlc-automation).
It holds `buildspec.yml`, the app, the tests, `infra/app-template.yaml` and
`params/{dev,staging,prod}.json`. That split is deliberate: this repo owns pipeline
infrastructure, the other owns the thing being built.

The same content is mirrored into a CodeCommit repository (`dop-c02-sdlc`) so the
`SourceProvider` parameter can be flipped without re-seeding anything.

## Source provider is a parameter, not a hardcode

The template encodes all three V1 source providers behind one parameter and two
`Conditions`:

| `SourceProvider` | Action provider | Change detection field |
| --- | --- | --- |
| `CodeStarSourceConnection` (default) | `CodeStarSourceConnection` | `DetectChanges` |
| `CodeCommit` | `CodeCommit` | `PollForSourceChanges` |
| `S3` | `S3` | `PollForSourceChanges` |

Note that the three providers do not share a change-detection property name. Deploying
with a different `SourceProvider` and diffing `get-pipeline` output is the cheapest way to
see that difference.

The CodeConnections ARN is **not committed**. It is read at deploy time from the SSM
parameter `/dop-c02-lab/github-connection-arn` via
`AWS::SSM::Parameter::Value<String>`, because this repo is public.

## Cost

Free tier for the components that stay up. CodeBuild `BUILD_GENERAL1_SMALL` on
`amazonlinux2-x86_64-standard:5.0`, one V1 pipeline, one versioned S3 artifact bucket, two
Lambda-backed app stacks behind HTTP APIs. Nothing here runs continuously.

## Deploy

```bash
# One-time: store the CodeConnections ARN the template reads at deploy time.
aws ssm put-parameter --name /dop-c02-lab/github-connection-arn \
  --type String --overwrite --value <connection-arn>

make apply LAB=domain-1-sdlc/codepipeline-artifacts-and-reports
```

The stack creates the artifact bucket, three IAM roles (pipeline, CodeBuild,
CloudFormation-deploy), CodeBuild projects `dop-c02-build` and `dop-c02-integration-test`,
and the pipeline `dop-c02-sdlc-pipeline`.

**No IAM resource in this template sets `RoleName` or `ManagedPolicyName`.**
`scripts/lib.sh` passes only `--capabilities CAPABILITY_IAM`, so a named IAM resource
would need `CAPABILITY_NAMED_IAM` and the change set would be rejected.

Inline `Policies[].PolicyName` is a different thing and is **required** — omitting it fails
change-set creation with `AWS::EarlyValidation::PropertyValidation`, which reports no
property name and no resource. Naming an inline policy does not make the role a named IAM
resource.

The CodeBuild role carries the five actions a `reports:` block needs, which are separate
from anything the build itself does:

```
codebuild:CreateReportGroup
codebuild:CreateReport
codebuild:UpdateReport
codebuild:BatchPutTestCases
codebuild:BatchPutCodeCoverages
```

## Run it

```bash
aws codepipeline start-pipeline-execution --name dop-c02-sdlc-pipeline
```

---

## Observed output — run of 2026-08-08

Account ID replaced with `<ACCOUNT_ID>` throughout; this repo is public.

### E1.0 — pipeline structure as deployed

```console
$ aws codepipeline get-pipeline --name dop-c02-sdlc-pipeline \
    --query 'pipeline.stages[].{Stage:name,Actions:actions[].{Action:name,Category:actionTypeId.category,Provider:actionTypeId.provider,In:inputArtifacts[].name,Out:outputArtifacts[].name}}'
```

| Stage | Action category | Provider | Input artifacts | Output artifacts |
| --- | --- | --- | --- | --- |
| Source | Source | CodeStarSourceConnection | — | `SourceArtifact` |
| Build | Build | CodeBuild | `SourceArtifact` | `TemplateArtifact`, `ImageDefsArtifact` |
| DeployDev | Deploy | CloudFormation | `TemplateArtifact` | — |
| DeployStaging | Deploy | CloudFormation | `TemplateArtifact` | — |
| IntegrationTest | Test | CodeBuild | `SourceArtifact` | — |
| ApproveProd | Approval | Manual | — | — |

The two Build output artifact names are not free-form — they must match the keys under
`artifacts: secondary-artifacts:` in `buildspec.yml` exactly.

### E1.1 — buildspec phases vs CodeBuild phases

The buildspec declares four phases. CodeBuild reports eleven.

```console
$ aws codebuild batch-get-builds --ids dop-c02-build:450dec9d-3fc0-4fee-b33a-f28b19035751 \
    --query 'builds[0].phases[].{Phase:phaseType,Status:phaseStatus,Secs:durationInSeconds}' --output table
-------------------------------------------
|             BatchGetBuilds              |
+-------------------+-------+-------------+
|       Phase       | Secs  |   Status    |
+-------------------+-------+-------------+
|  SUBMITTED        |  0    |  SUCCEEDED  |
|  QUEUED           |  0    |  SUCCEEDED  |
|  PROVISIONING     |  4    |  SUCCEEDED  |
|  DOWNLOAD_SOURCE  |  2    |  SUCCEEDED  |
|  INSTALL          |  20   |  SUCCEEDED  |
|  PRE_BUILD        |  1    |  SUCCEEDED  |
|  BUILD            |  0    |  SUCCEEDED  |
|  POST_BUILD       |  0    |  SUCCEEDED  |
|  UPLOAD_ARTIFACTS |  0    |  SUCCEEDED  |
|  FINALIZING       |  0    |  SUCCEEDED  |
|  COMPLETED        |  None |  None       |
+-------------------+-------+-------------+
```

Each buildspec phase echoes an epoch timestamp so the ordering is data, not documentation:

```
PHASE=install    EPOCH=1786231726  ISO=2026-08-08T23:28:46+00:00
PHASE=pre_build  EPOCH=1786231746  ISO=2026-08-08T23:29:06+00:00
PHASE=build      EPOCH=1786231748  ISO=2026-08-08T23:29:08+00:00
PHASE=post_build EPOCH=1786231748  ISO=2026-08-08T23:29:08+00:00
```

The `INSTALL` phase consumed 20 of the ~27 seconds — that is `pip install -r
requirements.txt`, not anything in `pre_build`.

Static analysis runs in `pre_build`, before any test. `app/handler.py` carries one
deliberately unused import so the tools have a real finding:

```console
[Container] Running command flake8 app/ --exit-zero --output-file=reports/flake8.txt || true
[Container] Running command bandit -r app/ -f json -o reports/bandit.json || true
[json] INFO JSON output written to file: reports/bandit.json
[Container] Running command echo "static analysis finished"
static analysis finished
[Container] Phase complete: PRE_BUILD State: SUCCEEDED
[Container] Entering phase BUILD
PHASE=build EPOCH=1786231748 ISO=2026-08-08T23:29:08+00:00
[Container] Running command pytest tests/test_handler.py --junitxml=reports/junit-unit.xml
============================= test session starts ==============================
platform linux -- Python 3.12.13, pytest-9.1.1, pluggy-1.6.0
rootdir: /codebuild/output/src12894207/src
collected 3 items
tests/test_handler.py ...                                                [100%]
- generated xml file: /codebuild/output/src12894207/src/reports/junit-unit.xml -
============================== 3 passed in 0.02s ===============================
[Container] Phase complete: BUILD State: SUCCEEDED
```

`flake8` here runs with `--exit-zero ... || true` and writes to a file, so its finding
never reaches the console and never fails the phase. `PRE_BUILD` is `SUCCEEDED`.

### E1.2 — the same JUnit XML through `reports:` and through `artifacts:`

`buildspec.yml` lists `reports/junit-unit.xml` in **both** blocks:

```yaml
reports:
  UnitTestReport:
    files: ['reports/junit-unit.xml']
    file-format: JUNITXML
artifacts:
  secondary-artifacts:
    ImageDefsArtifact:
      files: ['imagedefinitions.json', 'reports/junit-unit.xml']
      discard-paths: yes
```

What the build reports back for each:

```console
$ aws codebuild batch-get-builds --ids <build-id> --query 'builds[0].reportArns'
arn:aws:codebuild:us-east-1:<ACCOUNT_ID>:report/dop-c02-build-UnitTestReport:450dec9d-3fc0-4fee-b33a-f28b19035751

$ aws codebuild batch-get-builds --ids <build-id> \
    --query 'builds[0].secondaryArtifacts[].{Id:artifactIdentifier,Location:location}' --output table
+-------------------+--------------------------------------------------------------------+
|        Id         |                              Location                              |
+-------------------+--------------------------------------------------------------------+
|  TemplateArtifact |  arn:aws:s3:::<artifact-bucket>/dop-c02-sdlc-pipelin/TemplateAr/... |
|  ImageDefsArtifact|  arn:aws:s3:::<artifact-bucket>/dop-c02-sdlc-pipelin/ImageDefsA/... |
+-------------------+--------------------------------------------------------------------+
```

The report group parses the XML into queryable per-test-case records:

```console
$ aws codebuild batch-get-reports --report-arns <report-arn>
{
    "Type": "TEST",
    "Status": "SUCCEEDED",
    "Total": 3,
    "Counts": { "ERROR": 0, "FAILED": 0, "SKIPPED": 0, "SUCCEEDED": 3, "UNKNOWN": 0 },
    "ExportConfig": "NO_EXPORT"
}

$ aws codebuild describe-test-cases --report-arn <report-arn> --output table
+-------------------------------------+----------+-------------+
|                Name                 |  Secs    |   Status    |
+-------------------------------------+----------+-------------+
|  test_handler_returns_200           |  1000000 |  SUCCEEDED  |
|  test_handler_body_contains_env_key |  0       |  SUCCEEDED  |
|  test_force_fail_toggle             |  0       |  SUCCEEDED  |
+-------------------------------------+----------+-------------+
```

The artifact path yields the same information as an opaque blob — the bytes of the file,
downloaded and read manually:

```console
$ unzip -o ImageDefsArtifact.zip && head -c 260 junit-unit.xml
<?xml version="1.0" encoding="utf-8"?><testsuites name="pytest tests"><testsuite name="pytest"
errors="0" failures="0" skipped="0" tests="3" time="0.021"
timestamp="2026-08-08T23:29:08.757420+00:00" hostname="be932c3e9be0"><testcase
classname="tests.test_handler" name="test_handler_returns_200" time="0.001" />...
```

Note `"ExportConfig": "NO_EXPORT"` — the report group retains the parsed results without
any S3 export configured.

### E1.3 — `discard-paths` on secondary artifacts

Same build, two secondary artifacts, differing only in that flag.

```console
$ # TemplateArtifact  —  discard-paths: no
$ unzip -l TemplateArtifact.zip
./infra/app-template.yaml
./params/dev.json
./params/prod.json
./params/staging.json

$ # ImageDefsArtifact  —  discard-paths: yes
$ unzip -l ImageDefsArtifact.zip
./imagedefinitions.json
./junit-unit.xml
```

`reports/junit-unit.xml` arrived as `./junit-unit.xml`. Downstream actions address files
by path inside the artifact, so this flag decides whether
`TemplateArtifact::infra/app-template.yaml` resolves at all.

Contents of the generated `imagedefinitions.json`:

```json
[{"name":"app","imageUri":"<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:54067b0aba89e34292b6453ffe62e762778d0749"}]
```

The tag is `$CODEBUILD_RESOLVED_SOURCE_VERSION` — the full commit SHA, not `latest`.

### E1.4 — one template body, two environments

Both Deploy actions point at the *same* file in the *same* artifact and differ only in
`TemplateConfiguration`:

```console
$ aws codepipeline get-pipeline --name dop-c02-sdlc-pipeline \
    --query 'pipeline.stages[?name==`DeployDev`||name==`DeployStaging`].actions[].{...}' --output table
+---------------+----------------------+----------------+-----------------------------------------+---------------------------------------------+
|     Mode      |      StackName       |     Stage      |          TemplateConfiguration          |                TemplatePath                 |
+---------------+----------------------+----------------+-----------------------------------------+---------------------------------------------+
|  CREATE_UPDATE|  dop-c02-app-dev     |  DeployDev     |  TemplateArtifact::params/dev.json      |  TemplateArtifact::infra/app-template.yaml  |
|  CREATE_UPDATE|  dop-c02-app-staging |  DeployStaging |  TemplateArtifact::params/staging.json  |  TemplateArtifact::infra/app-template.yaml  |
+---------------+----------------------+----------------+-----------------------------------------+---------------------------------------------+
```

The deployed template bodies hash identically:

```console
$ for S in dop-c02-app-dev dop-c02-app-staging; do
    aws cloudformation get-template --stack-name $S --template-stage Original \
      --query 'TemplateBody' --output text | shasum -a 256
  done
dop-c02-app-dev      97379e2f90b5857d5a6b1a12a0f90cec4692b5a036d1ae9d2d4a7b67edffb64b
dop-c02-app-staging  97379e2f90b5857d5a6b1a12a0f90cec4692b5a036d1ae9d2d4a7b67edffb64b
```

The resulting stacks do not:

```console
$ aws cloudformation describe-stacks --stack-name dop-c02-app-dev --query 'Stacks[0].Parameters'
MemorySize   128
EnvName      dev
LogLevel     DEBUG

$ aws cloudformation describe-stacks --stack-name dop-c02-app-staging --query 'Stacks[0].Parameters'
MemorySize   256
EnvName      staging
LogLevel     INFO
```

`TemplateConfiguration` files carry tags as well as parameters, and those tags land on the
stack:

```console
$ aws cloudformation describe-stacks --stack-name dop-c02-app-dev --query 'Stacks[0].Tags'
Project  dop-c02-lab
Env      dev

$ aws cloudformation describe-stacks --stack-name dop-c02-app-staging --query 'Stacks[0].Tags'
Project  dop-c02-lab
Env      staging
```

### E1.5 — where the pipeline stops when a Test stage fails

Two executions of the same pipeline. Between them the only change was
`tests/integration/test_api.py` line 11, from `assert response.status_code == 200` to
`== 999`. **The assertion was reverted immediately after this capture.**

Green run — `405499c4-d801-40e4-99cf-e4e64e3e34e2`:

```console
$ aws codepipeline list-action-executions --pipeline-name dop-c02-sdlc-pipeline \
    --filter pipelineExecutionId=405499c4-d801-40e4-99cf-e4e64e3e34e2 --output table
+-----------------+------------------+------------------------------------+-------------+
|     Action      |      Stage       |               Start                |   Status    |
+-----------------+------------------+------------------------------------+-------------+
|  ApproveProd    |  ApproveProd     |  2026-08-08T17:09:28.548000-06:00  |  Failed     |
|  IntegrationTest|  IntegrationTest |  2026-08-08T17:08:25.344000-06:00  |  Succeeded  |
|  DeployStaging  |  DeployStaging   |  2026-08-08T17:08:21.750000-06:00  |  Succeeded  |
|  DeployDev      |  DeployDev       |  2026-08-08T17:08:19.192000-06:00  |  Succeeded  |
|  Build          |  Build           |  2026-08-08T17:07:46.715000-06:00  |  Succeeded  |
|  Source         |  Source          |  2026-08-08T17:07:43.710000-06:00  |  Succeeded  |
+-----------------+------------------+------------------------------------+-------------+
```

`ApproveProd` reached `InProgress` and produced a token
(`a3dfde77-584d-4c86-94ce-77bda70d0c04`); it shows `Failed` above because the approval was
manually **rejected** to clear the gate, not because anything upstream broke.

Red run — `927a8a3c-093a-4353-ae98-9a06abe2470d`:

```console
$ aws codepipeline list-action-executions --pipeline-name dop-c02-sdlc-pipeline \
    --filter pipelineExecutionId=927a8a3c-093a-4353-ae98-9a06abe2470d --output table
+-----------------+------------------+------------------------------------+-------------+
|     Action      |      Stage       |               Start                |   Status    |
+-----------------+------------------+------------------------------------+-------------+
|  IntegrationTest|  IntegrationTest |  2026-08-08T17:29:47.901000-06:00  |  Failed     |
|  DeployStaging  |  DeployStaging   |  2026-08-08T17:29:45.569000-06:00  |  Succeeded  |
|  DeployDev      |  DeployDev       |  2026-08-08T17:29:41.282000-06:00  |  Succeeded  |
|  Build          |  Build           |  2026-08-08T17:28:38.062000-06:00  |  Succeeded  |
|  Source         |  Source          |  2026-08-08T17:28:33.983000-06:00  |  Succeeded  |
+-----------------+------------------+------------------------------------+-------------+
```

Five rows, not six. **`ApproveProd` has no entry at all** in the red execution — the
action never started, so there is no approval token to act on.

A caution on how this is queried: `get-pipeline-state` returns the last known status of
each *stage*, which is not per-execution. Immediately after the red run it showed
`ApproveProd  Failed`, which was the leftover rejection from the green run.
`list-action-executions --filter pipelineExecutionId=...` is what distinguishes
"failed in this execution" from "never ran in this execution".

The failing build, phase by phase:

```console
$ aws codebuild batch-get-builds --ids dop-c02-integration-test:7e24680d-7df3-4a68-9c9d-3c9c2c7aa8da --output table
+-------------------+-------+-------------+
|       Phase       | Secs  |   Status    |
+-------------------+-------+-------------+
|  SUBMITTED        |  0    |  SUCCEEDED  |
|  QUEUED           |  0    |  SUCCEEDED  |
|  PROVISIONING     |  4    |  SUCCEEDED  |
|  DOWNLOAD_SOURCE  |  2    |  SUCCEEDED  |
|  INSTALL          |  13   |  SUCCEEDED  |
|  PRE_BUILD        |  0    |  SUCCEEDED  |
|  BUILD            |  9    |  FAILED     |
|  POST_BUILD       |  0    |  SUCCEEDED  |
|  UPLOAD_ARTIFACTS |  0    |  SUCCEEDED  |
|  FINALIZING       |  0    |  SUCCEEDED  |
|  COMPLETED        |  None |  None       |
+-------------------+-------+-------------+
```

`POST_BUILD`, `UPLOAD_ARTIFACTS` and `FINALIZING` all ran and succeeded **after** `BUILD`
failed. The failure context:

```json
{
    "statusCode": "COMMAND_EXECUTION_ERROR",
    "message": "Error while executing command: pytest tests/integration/ --junitxml=reports/junit-integration.xml. Reason: exit status 1"
}
```

The report group still received a report from the failed build:

```console
$ # newest report (red run)
{ "Status": "FAILED",    "Total": 1, "Passed": 0, "Failed": 1, "Created": "2026-08-08T17:30:20-06:00" }
$ # previous report (green run)
{ "Status": "SUCCEEDED", "Total": 1, "Passed": 1, "Failed": 0, "Created": "2026-08-08T17:08:55-06:00" }

$ aws codebuild describe-test-cases --report-arn <red-report-arn>
Name:    test_api_returns_200_and_env_key
Status:  FAILED
Message: |
    def test_api_returns_200_and_env_key():
            api_url = os.environ["API_URL"]
            response = requests.get(api_url, timeout=10)
    >       assert response.status_code == 999
    E       assert 200 == 999
    E        +  where 200 = <Response [200]>.status_code

    tests/integration/test_api.py:11: AssertionError
```

The integration test resolved its endpoint at run time from stack outputs rather than from
a hardcoded URL or a pipeline variable:

```yaml
- |
  export API_URL=$(aws cloudformation describe-stacks \
    --stack-name dop-c02-app-staging \
    --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
    --output text)
```

### E1.6 — change detection did not fire (unresolved)

Recorded because it is observed behaviour, not a conclusion. Every execution of this
pipeline was started by hand:

```console
$ aws codepipeline list-pipeline-executions --pipeline-name dop-c02-sdlc-pipeline --output table
+---------------------------------------+------------------------------------+---------+-------------------------+
|                  Id                   |               Start                | Status  |         Trigger         |
+---------------------------------------+------------------------------------+---------+-------------------------+
|  927a8a3c-093a-4353-ae98-9a06abe2470d |  2026-08-08T17:28:33.820000-06:00  |  Failed |  StartPipelineExecution |
|  405499c4-d801-40e4-99cf-e4e64e3e34e2 |  2026-08-08T17:07:43.511000-06:00  |  Failed |  StartPipelineExecution |
|  059b5bb2-7c95-44e1-9c8a-9ad3a6d0bc8a |  2026-08-08T16:47:39.358000-06:00  |  Failed |  CreatePipeline         |
+---------------------------------------+------------------------------------+---------+-------------------------+
```

…despite the source action carrying `DetectChanges: true` against an `AVAILABLE`
connection:

```console
$ aws codepipeline get-pipeline --name dop-c02-sdlc-pipeline --query 'pipeline.stages[0].actions[0]'
{
    "Provider": "CodeStarSourceConnection",
    "Config": {
        "BranchName": "main",
        "ConnectionArn": "arn:aws:codeconnections:us-east-1:<ACCOUNT_ID>:connection/bd7ccc21-...",
        "DetectChanges": "true",
        "FullRepositoryId": "josefloressv/aws-devops-sdlc-automation"
    }
}

$ aws codeconnections list-connections --output table
+-----------------+-----------+------------+
|      Name       | Provider  |  Status    |
+-----------------+-----------+------------+
|  dop-c02-github |  GitHub   |  AVAILABLE |
+-----------------+-----------+------------+
```

Four pushes to `main` produced no execution. What was checked and ruled out:

- The connection is `AVAILABLE`, and the Source action fetches the correct commit on every
  manual start — so authorization and repo access are working.
- `aws events list-rules` shows no CodePipeline-owned change-detection rule. For
  `CodeStarSourceConnection` sources the trigger is internal to the connection rather than
  a customer-visible EventBridge rule, so this is suggestive but not conclusive.
- The GitHub repo has no repo-level webhooks (`gh api .../hooks` returns empty). Expected
  — the AWS Connector for GitHub is an App and uses App-level delivery.
- Forcing the pipeline to re-register its trigger (toggling `DetectChanges` to `false` and
  back to `true`, bumping the pipeline to version 3) did not change the behaviour.

The pipeline was created while the connection was still `PENDING`, which is the leading
hypothesis for why the trigger never registered, but the re-registration test above does
not support it and it is left unproven here.

Phase 2 (`../eventbridge-pr-trigger/`) builds its trigger evidence on **CodeCommit + an
explicit EventBridge rule**, which does not depend on this.

## Teardown

The pipeline creates two stacks that this stack does not own. Delete those first:

```bash
aws cloudformation delete-stack --stack-name dop-c02-app-dev
aws cloudformation delete-stack --stack-name dop-c02-app-staging
aws cloudformation wait stack-delete-complete --stack-name dop-c02-app-dev
aws cloudformation wait stack-delete-complete --stack-name dop-c02-app-staging
```

The artifact bucket is versioned, so it will not delete while any object version or delete
marker remains:

```bash
BUCKET=$(aws cloudformation describe-stacks \
  --stack-name dop-lab-d1-codepipeline-artifacts-and-reports \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucketName`].OutputValue' --output text)

aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > /tmp/vers.json
aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/vers.json

aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > /tmp/marks.json
aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/marks.json
```

Report groups are not stack resources either — CodeBuild creates them on first run:

```bash
aws codebuild delete-report-group --arn <dop-c02-build-UnitTestReport-arn> --delete-reports
aws codebuild delete-report-group --arn <dop-c02-integration-test-IntegrationTestReport-arn> --delete-reports
```

Then:

```bash
make destroy LAB=domain-1-sdlc/codepipeline-artifacts-and-reports
```

Phase 2 imports this stack's pipeline exports — destroy this one **after**
`eventbridge-pr-trigger`.
