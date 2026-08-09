# CodePipeline → EKS: two output artifacts, one deploy action

**Domain 1 — SDLC Automation**

A CodeBuild action that produces **two** named output artifacts, and a downstream deploy
action that consumes **three** input artifacts at once. The deploy stage reads the image URI
out of `imagedefinitions.json` and patches it into a Kubernetes manifest that arrived in a
different artifact, then `kubectl apply`s it against an existing EKS cluster.

Two things this scenario is built to show as raw output:

1. how a multi-input CodeBuild action addresses each artifact
   (`$CODEBUILD_SRC_DIR` vs `$CODEBUILD_SRC_DIR_<ArtifactName>`), and which one
   `PrimarySource` selects;
2. what actually crosses a stage boundary — a shell `export` in the build stage versus an
   `env: exported-variables` declaration versus a file written into an artifact.

The CodeBuild role reaches the cluster through an **EKS access entry**, not `aws-auth`.

## Shape of the stack

```
CodeCommit dop-c02-sdlc (main)
        │  SourceArtifact
        ▼
CodeBuild dop-c02-eks-build          (privilegedMode: true — docker build/push to ECR)
        │  buildspec: eks/buildspec-eks.yml
        │  artifacts.secondary-artifacts:
        │      ManifestArtifact  <- manifests/*
        │      ImageDefArtifact  <- imagedefinitions.json
        ▼
CodeBuild dop-c02-eks-deploy
           inputs: SourceArtifact (PrimarySource) + ManifestArtifact + ImageDefArtifact
           buildspec: eks/buildspec-eks-deploy.yml
           jq the imageUri out of ImageDefArtifact
           sed it into ManifestArtifact/deployment.yaml
           kubectl apply -> dop-c02-lab-cluster
```

The template creates three unnamed IAM roles (pipeline / build / deploy), one
`AWS::EKS::AccessEntry` binding the deploy role to `AmazonEKSClusterAdminPolicy`, the two
CodeBuild projects and the pipeline. It **creates no cluster and no ECR repository** — both
already exist and are referenced by name.

## Prerequisites

- An EKS cluster named by the `ClusterName` parameter, with authentication mode
  `API` or `API_AND_CONFIG_MAP` (access entries are rejected on `CONFIG_MAP`):

  ```bash
  aws eks describe-cluster --name dop-c02-lab-cluster \
    --query 'cluster.accessConfig.authenticationMode'
  ```

- The Phase 1 stack `dop-lab-d1-codepipeline-artifacts-and-reports`, whose
  `ArtifactBucketName` export this stack imports rather than creating a second bucket.
- An ECR repository named by `EcrRepositoryName` (created by the Phase 3 stack; it survives
  that stack's teardown).
- A CodeCommit repository named by `CodeCommitRepositoryName` containing the `eks/`
  directory from the application repo.

## Cost

The cluster is pre-existing and not created or destroyed here. CodeBuild is on-demand
`BUILD_GENERAL1_SMALL`; the two builds together run for roughly 90 seconds. The pipeline
itself is billed per active pipeline per month.

## Deploy

```bash
make apply LAB=domain-1-sdlc/eks-two-output-artifacts
```

## Reproduce

### E5.1 — how the pipeline declares the artifacts

```bash
aws codepipeline get-pipeline --name dop-c02-eks-pipeline \
  --query 'pipeline.stages[].{Stage:name,Actions:actions[].{Action:name,In:inputArtifacts[].name,Out:outputArtifacts[].name,Cfg:configuration}}'

# and what the CodeBuild project itself declares about artifacts
aws codebuild batch-get-projects --names dop-c02-eks-build \
  --query 'projects[0].{Primary:artifacts,Secondary:secondaryArtifacts,Privileged:environment.privilegedMode}'
```

### E5.2 — the deploy role's cluster access

```bash
aws eks list-access-entries --cluster-name dop-c02-lab-cluster

DEPLOY_ROLE=$(aws cloudformation describe-stacks \
  --stack-name dop-lab-d1-eks-two-output-artifacts \
  --query "Stacks[0].Outputs[?OutputKey=='DeployRoleArn'].OutputValue" --output text)

aws eks list-associated-access-policies \
  --cluster-name dop-c02-lab-cluster --principal-arn "$DEPLOY_ROLE"
```

### E5.3 — run it and read both build logs

```bash
aws codepipeline start-pipeline-execution --name dop-c02-eks-pipeline

# build stage: which files went into which secondary artifact
aws logs tail /aws/codebuild/dop-c02-eks-build --since 10m

# deploy stage: which SRC_DIR variables exist, and what the shell sees
aws logs tail /aws/codebuild/dop-c02-eks-deploy --since 10m
```

### E5.4 — what landed on the cluster

```bash
kubectl get deploy dop-c02-eks-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
kubectl get pods -l app=dop-c02-eks-app -o wide
```

## Teardown

```bash
kubectl delete deploy,svc dop-c02-eks-app --ignore-not-found

make destroy LAB=domain-1-sdlc/eks-two-output-artifacts
```

Deleting the stack removes the access entry, both CodeBuild projects and the pipeline. It
does **not** remove the Kubernetes objects (they are not CloudFormation resources), nor the
images pushed to ECR, nor the cluster.

## Observed output — run of 2026-08-08

Account IDs are shown as `<ACCOUNT_ID>` in prose; log excerpts are pasted verbatim except
for that substitution.

### E5.1 — artifact wiring

```json
[
    {
        "Stage": "Source",
        "Actions": [
            {
                "Action": "Source",
                "In": [],
                "Out": [ "SourceArtifact" ],
                "Cfg": {
                    "BranchName": "main",
                    "PollForSourceChanges": "false",
                    "RepositoryName": "dop-c02-sdlc"
                }
            }
        ]
    },
    {
        "Stage": "Build",
        "Actions": [
            {
                "Action": "BuildImageAndManifests",
                "In": [ "SourceArtifact" ],
                "Out": [ "ManifestArtifact", "ImageDefArtifact" ],
                "Cfg": { "ProjectName": "dop-c02-eks-build" }
            }
        ]
    },
    {
        "Stage": "DeployToEks",
        "Actions": [
            {
                "Action": "KubectlApply",
                "In": [ "SourceArtifact", "ManifestArtifact", "ImageDefArtifact" ],
                "Out": [],
                "Cfg": {
                    "PrimarySource": "SourceArtifact",
                    "ProjectName": "dop-c02-eks-deploy"
                }
            }
        ]
    }
]
```

What the CodeBuild project says about its own artifacts:

```json
{
    "Primary": {
        "type": "CODEPIPELINE",
        "name": "dop-c02-eks-build",
        "packaging": "NONE",
        "encryptionDisabled": false
    },
    "Secondary": null,
    "Privileged": true
}
```

The two output artifact names appear in the pipeline action and in the buildspec's
`artifacts.secondary-artifacts` keys:

```yaml
artifacts:
  secondary-artifacts:
    ManifestArtifact:
      files:
        - 'manifests/*'
      discard-paths: yes
    ImageDefArtifact:
      files:
        - 'imagedefinitions.json'
      discard-paths: yes
```

### E5.2 — access entry instead of aws-auth

```json
{
    "accessEntries": [
        "arn:aws:iam::<ACCOUNT_ID>:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_b871f7c53269d1fc",
        "arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS",
        "arn:aws:iam::<ACCOUNT_ID>:role/dop-c02-lab-cluster-node-role",
        "arn:aws:iam::<ACCOUNT_ID>:role/dop-lab-d1-eks-two-output-artifacts-DeployRole-1E7bc3XHlAbn"
    ]
}
```

```json
{
    "associatedAccessPolicies": [
        {
            "policyArn": "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy",
            "accessScope": { "type": "cluster", "namespaces": [] },
            "associatedAt": "2026-08-08T19:52:34.492000-06:00"
        }
    ],
    "clusterName": "dop-c02-lab-cluster",
    "principalArn": "arn:aws:iam::<ACCOUNT_ID>:role/dop-lab-d1-eks-two-output-artifacts-DeployRole-1E7bc3XHlAbn"
}
```

The cluster's `aws-auth` ConfigMap was never edited. Cluster `authenticationMode` is
`API_AND_CONFIG_MAP`.

### E5.3a — the build stage

```
[Container] 2026/08/09 01:54:13.400227 Running command echo "PHASE=pre_build EPOCH=$(date +%s)"
PHASE=pre_build EPOCH=1786240453
[Container] 2026/08/09 01:54:13.409198 Running command aws ecr get-login-password ... | docker login ...
Login Succeeded
[Container] 2026/08/09 01:54:22.815774 Running command export IMAGE_TAG=${CODEBUILD_RESOLVED_SOURCE_VERSION:0:7}
[Container] 2026/08/09 01:54:22.823948 Running command echo "IMAGE_TAG=$IMAGE_TAG"
IMAGE_TAG=7034b50
...
#6 naming to <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50 done
7034b50: digest: sha256:3df1d93fcabf9e78e7f9d76d148969caea8b617c8eb3b35ce532a37604e7736f size: 2196
...
[Container] 2026/08/09 01:54:27.178451 Running command export MY_IMAGE_URI=$ECR_REGISTRY/dop-c02-lab:$IMAGE_TAG
[Container] 2026/08/09 01:54:27.186030 Running command printf '[{"name":"app","imageUri":"%s"}]' "$MY_IMAGE_URI" > imagedefinitions.json
[Container] 2026/08/09 01:54:27.193818 Running command cat imagedefinitions.json
[{"name":"app","imageUri":"<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50"}]
[Container] 2026/08/09 01:54:27.202362 Running command mkdir -p manifests && cp eks/k8s/*.yaml manifests/
```

The artifact upload phase, showing each secondary artifact collected separately:

```
[Container] 2026/08/09 01:54:27.315460 Preparing to copy secondary artifacts ManifestArtifact
[Container] 2026/08/09 01:54:27.322936 Expanding manifests/*
[Container] 2026/08/09 01:54:27.326648 Found 2 file(s)
[Container] 2026/08/09 01:54:27.327442 Preparing to copy secondary artifacts ImageDefArtifact
[Container] 2026/08/09 01:54:27.334697 Expanding imagedefinitions.json
[Container] 2026/08/09 01:54:27.338262 Found 1 file(s)
[Container] 2026/08/09 01:54:27.350073 Phase complete: UPLOAD_ARTIFACTS State: SUCCEEDED
```

### E5.3b — the deploy stage: three source directories

```
[Container] 2026/08/09 01:55:15.820242 CODEBUILD_SRC_DIR=/codebuild/output/src2691/src/s3/00
[Container] 2026/08/09 01:55:15.820327 CODEBUILD_SRC_DIR_ManifestArtifact=/codebuild/output/src2691/src/s3/02
[Container] 2026/08/09 01:55:15.820389 CODEBUILD_SRC_DIR_ImageDefArtifact=/codebuild/output/src2691/src/s3/01
[Container] 2026/08/09 01:55:15.821016 YAML location is /codebuild/output/src2691/src/s3/00/eks/buildspec-eks-deploy.yml
[Container] 2026/08/09 01:55:16.061049 Moving to directory /codebuild/output/src2691/src/s3/00
```

The buildspec was read from `.../s3/00`, which is `$CODEBUILD_SRC_DIR` — the artifact named
in `PrimarySource`.

### E5.3c — what crossed the stage boundary

First two commands of the deploy stage's `install` phase, before anything else runs:

```
[Container] 2026/08/09 01:55:16.272668 Running command echo "MY_IMAGE_URI=${MY_IMAGE_URI:-<UNSET>}"
MY_IMAGE_URI=<UNSET>
[Container] 2026/08/09 01:55:16.282125 Running command echo "IMAGE_TAG=${IMAGE_TAG:-<UNSET>}"
IMAGE_TAG=<UNSET>
```

`MY_IMAGE_URI` was `export`ed in the build stage's shell. `IMAGE_TAG` was both `export`ed
and declared in the build buildspec's `env: exported-variables`:

```yaml
env:
  exported-variables:
    - IMAGE_TAG
```

Both read `<UNSET>` here. The pipeline action for `KubectlApply` sets no
`EnvironmentVariables` override; its only environment variable is `CLUSTER_NAME`, set on the
project itself.

What the same stage sees when it reads the artifacts instead:

```
[Container] 2026/08/09 01:55:36.293355 Running command ls -la "$CODEBUILD_SRC_DIR_ImageDefArtifact"
total 4
drwxr-xr-x 2 root root 35 Aug  9 01:55 .
drwxr-xr-x 5 root root 36 Aug  9 01:55 ..
-rw-r--r-- 1 root root 94 Aug  9 01:54 imagedefinitions.json
[Container] 2026/08/09 01:55:36.331434 Running command cat "$CODEBUILD_SRC_DIR_ImageDefArtifact/imagedefinitions.json"
[{"name":"app","imageUri":"<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50"}]
[Container] 2026/08/09 01:55:36.347193 Running command ls -la "$CODEBUILD_SRC_DIR_ManifestArtifact"
total 8
drwxr-xr-x 2 root root  49 Aug  9 01:55 .
drwxr-xr-x 5 root root  36 Aug  9 01:55 ..
-rw-r--r-- 1 root root 802 Aug  9 01:54 deployment.yaml
-rw-r--r-- 1 root root 249 Aug  9 01:54 service.yaml
```

`discard-paths: yes` in the build buildspec is why `deployment.yaml` sits at the root of
`ManifestArtifact` rather than under `manifests/`.

### E5.3d — the two artifacts joined

```
[Container] 2026/08/09 01:55:36.391780 Running command export IMAGE_URI=$(jq -r '.[0].imageUri' "$CODEBUILD_SRC_DIR_ImageDefArtifact/imagedefinitions.json")
[Container] 2026/08/09 01:55:36.549327 Running command echo "Resolved IMAGE_URI from imagedefinitions.json = $IMAGE_URI"
Resolved IMAGE_URI from imagedefinitions.json = <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50
[Container] 2026/08/09 01:55:36.557044 Running command sed -i "s|IMAGE_URI_PLACEHOLDER|${IMAGE_URI}|g" "$CODEBUILD_SRC_DIR_ManifestArtifact/deployment.yaml"
[Container] 2026/08/09 01:55:36.595123 Running command grep 'image:' "$CODEBUILD_SRC_DIR_ManifestArtifact/deployment.yaml"
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50
```

`deployment.yaml` is committed to the application repo with the literal string
`IMAGE_URI_PLACEHOLDER` on its `image:` line — the repo is public and carries no account ID.

### E5.3e — cluster auth and apply

```
[Container] 2026/08/09 01:55:18.472185 Running command aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_DEFAULT_REGION"
Added new context arn:aws:eks:us-east-1:<ACCOUNT_ID>:cluster/dop-c02-lab-cluster to /root/.kube/config
[Container] 2026/08/09 01:55:35.553945 Running command kubectl get nodes
NAME                            STATUS   ROLES    AGE     VERSION
ip-172-31-86-116.ec2.internal   Ready    <none>   6h34m   v1.36.2-eks-254016e
```

Two pipeline executions ran, 16 seconds apart. The first:

```
[Container] 2026/08/09 01:54:37.906801 Running command kubectl apply -f "$CODEBUILD_SRC_DIR_ManifestArtifact/deployment.yaml"
deployment.apps/dop-c02-eks-app created
[Container] 2026/08/09 01:54:38.769361 Running command kubectl apply -f "$CODEBUILD_SRC_DIR_ManifestArtifact/service.yaml"
service/dop-c02-eks-app created
deployment "dop-c02-eks-app" successfully rolled out
```

The second, from the same commit:

```
[Container] 2026/08/09 01:55:36.634223 Running command kubectl apply -f "$CODEBUILD_SRC_DIR_ManifestArtifact/deployment.yaml"
deployment.apps/dop-c02-eks-app unchanged
[Container] 2026/08/09 01:55:37.385079 Running command kubectl apply -f "$CODEBUILD_SRC_DIR_ManifestArtifact/service.yaml"
service/dop-c02-eks-app unchanged
[Container] 2026/08/09 01:55:38.258634 Running command kubectl rollout status deployment/dop-c02-eks-app --timeout=180s
deployment "dop-c02-eks-app" successfully rolled out
```

Both executions:

```
---------------------------------------------------------------------------------------------------
|                                    ListPipelineExecutions                                       |
+---------------------------------------+------------------------------------+-------------------+
|                  Id                   |               Start                |      Trigger      |
+---------------------------------------+------------------------------------+-------------------+
|  83825ab8-d48f-4a10-a316-91ccb702a519 |  2026-08-08T19:53:11.407000-06:00  |  StartPipelineExecution |
|  ccf0fce9-394f-4eec-8160-4df6287cfa4c |  2026-08-08T19:52:55.751000-06:00  |  CreatePipeline   |
+---------------------------------------+------------------------------------+-------------------+
```

Both `Succeeded`. Note the `trigger.triggerType` of the first one — the pipeline ran once at
creation time without any source change and without `StartPipelineExecution` being called.

### E5.4 — final cluster state

```
$ kubectl get deploy dop-c02-eks-app -o jsonpath='{.spec.template.spec.containers[0].image}'
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/dop-c02-lab:7034b50

$ kubectl get pods -l app=dop-c02-eks-app -o wide
NAME                             READY  STATUS   RESTARTS  AGE    IP              NODE
dop-c02-eks-app-56c48fc5-b4w9q   1/1    Running  0         3m56s  172.31.87.217   ip-172-31-86-116.ec2.internal

$ kubectl get svc dop-c02-eks-app -o wide
NAME              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE    SELECTOR
dop-c02-eks-app   ClusterIP   10.100.125.55   <none>        80/TCP    4m9s   app=dop-c02-eks-app

$ kubectl get deploy dop-c02-eks-app -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'
1
```

Revision stayed at `1` across both executions — same image tag, same pod spec.
