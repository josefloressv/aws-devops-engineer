# EKS: container stdout in CloudWatch, and what survives the pod

**Domain 4 — Monitoring and Logging**

Follow-on to
[`eks-crashloop-log-retrieval`](../eks-crashloop-log-retrieval/README.md). That lab ran
four approaches for recovering a crashed container's stdout against a cluster created
with **no log forwarding**, and Approach D (`aws logs describe-log-groups`) returned an
empty set.

This lab adds the forwarding path — the `amazon-cloudwatch-observability` EKS add-on,
which runs Fluent Bit as a node-level DaemonSet — and re-runs the same four approaches
against the same pod. It then deletes the pod and runs all four again.

The two READMEs are meant to be read as a pair. The first lab's "no logging configured"
state is the control condition, which is why the forwarding path lives in a **separate**
CloudFormation stack rather than being folded into the cluster template.

This README records commands and observations only. It does not label any approach as
correct — compare the captured output yourself. A full run was executed on 2026-08-08;
raw terminal output is in [Observed output](#observed-output--run-of-2026-08-08).

## What the run showed, in one line each

Three results are worth knowing before reading the captures, because two of them
contradict reasonable expectations:

- With the pod deleted, Approaches A, B and C all return "not found" while D still
  returns the lines. See [Phase 2](#phase-2--after-kubectl-delete-pod).
- **Deleting the forwarding stack does not revert Approach D to empty.** The log group
  and every event in it survive, because Fluent Bit creates the log group at runtime —
  it is not a resource in the stack, so CloudFormation never owned it and has nothing to
  delete. See [Phase 3](#phase-3--after-deleting-the-forwarding-stack).
- Only restarts that happened *after* the agent was installed appear in CloudWatch. The
  pod had 7 restarts; 2 are in the log group. Fluent Bit forwards from the moment it
  starts tailing, and does not backfill files written before it existed.

## Cost

Not free tier. This lab adds one genuinely new cost line on top of the cluster the first
lab already created.

| Resource | Rate |
| --- | --- |
| EKS control plane (already running from lab 1) | ~$0.10/hr |
| 1 × t3.small on-demand (raised from t3.micro, see below) | ~$0.021/hr |
| CloudWatch Logs ingestion | $0.50/GB ingested |
| CloudWatch Logs storage | $0.03/GB-month |
| **Container Insights custom metrics** | **$0.30/metric/month** |

The Container Insights metric stream is the line to watch. The CloudWatch agent publishes
a large set of custom metrics per node, per pod and per container, and custom metrics bill
per metric per month regardless of how little data each one carries — on an idle
single-node lab cluster this can outweigh both the logs and the node. It is the reason
this lab's stack is meant to be short-lived: install it, capture, delete it.

Covered by the AWS Community Builders credit (see the repo `CLAUDE.md`); no Transit
Gateway or Marketplace resources are involved.

Fluent Bit creates its log groups with retention **Never expire**. The stack ships a
`LogRetentionDays` parameter, but note that it is *not* applied by the stack — see
[`SetLogRetentionCommand`](#log-retention) for why and how to apply it.

## Layout

| File | Purpose |
| --- | --- |
| `lab-eks-logging.yaml` | CloudWatch Observability add-on + node-role IAM policy |

The pod under test is the first lab's
[`crash-pod.yaml`](../eks-crashloop-log-retrieval/crash-pod.yaml), used **unmodified** —
keeping it byte-identical is what makes the before/after comparison valid.

## Prerequisite: node capacity

The add-on installs three pods (`cloudwatch-agent` DaemonSet, `fluent-bit` DaemonSet, and
the `amazon-cloudwatch-observability-controller-manager` Deployment). The first lab ran on
a `t3.micro`, where `max-pods=4` was fully consumed by `aws-node`, `kube-proxy`, one
CoreDNS replica and `crash-demo` — nothing else can schedule there.

Raise the cluster stack's node type first:

```sh
aws cloudformation create-change-set \
  --stack-name dop-c02-lab-eks --change-set-name cs-t3small --change-set-type UPDATE \
  --template-body file://../eks-crashloop-log-retrieval/lab-eks-crashloop.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=NodeInstanceType,ParameterValue=t3.small \
               ParameterKey=ClusterName,UsePreviousValue=true \
               ParameterKey=KubernetesVersion,UsePreviousValue=true \
               ParameterKey=VpcId,UsePreviousValue=true \
               ParameterKey=SubnetIds,UsePreviousValue=true \
               ParameterKey=NodegroupSize,UsePreviousValue=true
```

`t3.small` gives `max-pods=11`. Replacing the nodegroup takes ~5 minutes and destroys the
running `crash-demo` container, so re-apply the pod afterwards:

```sh
kubectl apply -f ../eks-crashloop-log-retrieval/crash-pod.yaml
```

### Gotcha found doing this: a named nodegroup cannot be replaced

Changing `InstanceTypes` **replaces** an `AWS::EKS::Nodegroup`, and CloudFormation
replaces create-first/delete-second. The first lab's template pinned
`NodegroupName: !Sub "${ClusterName}-ng"`, so the create leg tried to build a second
nodegroup with a name that was still taken, and the update rolled back:

```
Nodegroup  UPDATE_FAILED  Resource handler returned message: "NodeGroup already exists
with name dop-c02-lab-cluster-ng and cluster name dop-c02-lab-cluster
(Service: Eks, Status Code: 409 ...)" (HandlerErrorCode: AlreadyExists)
```

The rollback was clean — the original nodegroup and its node kept running. The fix, now
committed to the first lab's template, is to **omit** `NodegroupName` so CloudFormation
auto-generates it; an auto-named replacement cannot collide with its predecessor. This
applies to any replacement cause (AMI type, subnets), not just instance type.

## Deploy

```sh
export AWS_PROFILE="$LAB_PROFILE" AWS_REGION=us-east-1   # lab account profile, see .env.local

aws cloudformation create-change-set \
  --stack-name dop-c02-lab-eks-logging \
  --change-set-name cs-create \
  --change-set-type CREATE \
  --template-body file://lab-eks-logging.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags Key=Project,Value=dop-c02-lab Key=Domain,Value=4 \
         Key=Scenario,Value=eks-pod-logs-to-cloudwatch

aws cloudformation describe-change-set \
  --stack-name dop-c02-lab-eks-logging --change-set-name cs-create \
  --query 'Changes[].ResourceChange.[Action,ResourceType,LogicalResourceId]' --output table

aws cloudformation execute-change-set \
  --stack-name dop-c02-lab-eks-logging --change-set-name cs-create
aws cloudformation wait stack-create-complete --stack-name dop-c02-lab-eks-logging
```

The change set contains exactly two resources:

```
|  Add   |  AWS::IAM::ManagedPolicy  |  CloudWatchAgentPolicy         |
|  Add   |  AWS::EKS::Addon          |  CloudWatchObservabilityAddon  |
```

Confirm the add-on's pods are up, then give Fluent Bit ~2 minutes to ship:

```sh
kubectl get pods -n amazon-cloudwatch
```

### Why the IAM policy is shaped the way it is

Fluent Bit and the CloudWatch agent run as DaemonSets with no IRSA or Pod Identity
association, so they authenticate as the **EC2 instance role of the node**. That role is
owned by the *cluster* stack, and `ManagedPolicyArns` cannot be appended to a role from a
second stack. So this stack does not attach AWS's `CloudWatchAgentServerPolicy`; it
creates a customer managed policy that attaches *itself* to the imported role through the
policy's own `Roles` property.

The cluster stack exports the role ARN but not its name, so the name is derived from the
ARN:

```yaml
Roles:
  - !Select
    - 1
    - !Split
      - "/"
      - Fn::ImportValue: !Sub "${EksStackName}-NodeRoleArn"
```

`DependsOn: CloudWatchAgentPolicy` on the add-on matters: it attaches the permissions
before the agents start. In this run all three pods reached `Running` with **0 restarts**,
i.e. they never hit an `AccessDenied` startup loop.

### Log retention

`LogRetentionDays` exists but is deliberately **not** wired to a `AWS::Logs::LogGroup`
resource. Declaring the log groups in this stack would make them stack-owned, which would
(a) change the very thing [Phase 3](#phase-3--after-deleting-the-forwarding-stack)
measures, and (b) make a later re-deploy fail with "already exists" if they were retained.
The parameter instead renders a copy-paste command as a stack output:

```sh
aws cloudformation describe-stacks --stack-name dop-c02-lab-eks-logging \
  --query 'Stacks[0].Outputs[?OutputKey==`SetLogRetentionCommand`].OutputValue' --output text
```

which produces, for `LogRetentionDays=1`:

```sh
for g in application dataplane host performance; do aws logs put-retention-policy \
  --log-group-name /aws/containerinsights/dop-c02-lab-cluster/$g --retention-in-days 1; done
```

## Test procedure

For each command record: the exact command, its exact output, whether the output contained
`CONTAINER STARTING` and `Simulated application failure`, and whether the CLI errored.

### Phase 1 — pod alive, forwarding on

Re-run the first lab's Approaches A, B and C unchanged, then D:

```sh
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights
aws logs describe-log-streams \
  --log-group-name /aws/containerinsights/dop-c02-lab-cluster/application \
  --order-by LastEventTime --descending
aws logs filter-log-events \
  --log-group-name /aws/containerinsights/dop-c02-lab-cluster/application \
  --filter-pattern '"Simulated application failure"'
```

For Approach C, note that this AMI has **no `docker` and no `crictl`** — use
`nerdctl ps -a` / `nerdctl logs`, which default to the `k8s.io` namespace.

Pass `--max-items` to `filter-log-events`. Without it the CLI's auto-pagination applies
`--query` per page, so `--query 'length(events)'` prints one number per page
(`0 0 0 1 0`) rather than a total.

### Phase 2 — the retention test

```sh
kubectl delete pod crash-demo --force
```

Then immediately re-run all four. Capture the current and previous container IDs
**before** deleting, since Approach C needs them afterwards:

```sh
kubectl get pod crash-demo -o jsonpath='{.status.containerStatuses[0].containerID}'
kubectl get pod crash-demo -o jsonpath='{.status.containerStatuses[0].lastState.terminated.containerID}'
kubectl get pod crash-demo -o jsonpath='{.metadata.uid}'
```

### Phase 3 — revert

```sh
aws cloudformation delete-stack --stack-name dop-c02-lab-eks-logging
aws cloudformation wait stack-delete-complete --stack-name dop-c02-lab-eks-logging
```

Then re-check the add-on, the node role's attached policies, and the log group.

## Observed output — run of 2026-08-08

Cluster `dop-c02-lab-cluster`, Kubernetes 1.36, single **t3.small** node, add-on
`amazon-cloudwatch-observability` **v6.4.0-eksbuild.1** (the default build for 1.36 in
this account on the run date). Node name, instance ID and pod IPs are redacted below as
`<node>`, `<node-instance-id>` and `<pod-ip>`.

### Before installing the add-on

Same result as the first lab, re-confirmed on the new node:

```
$ aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights
{
    "logGroups": []
}
$ aws logs describe-log-groups --log-group-name-prefix /aws/eks
{
    "logGroups": []
}
```

Listing every log group in `us-east-1` returned exactly one entry, an unrelated ECS
Container Insights group (redacted) predating this lab.

### Add-on pods

```
$ kubectl get pods -n amazon-cloudwatch
NAME                                                              READY   STATUS    RESTARTS   AGE
amazon-cloudwatch-observability-controller-manager-7fdc4b6gtx8h   1/1     Running   0          41s
cloudwatch-agent-hj4mp                                            1/1     Running   0          35s
fluent-bit-7h7rx                                                  1/1     Running   0          41s
```

Log groups appeared within ~2 minutes. `performance` showed up slightly later than the
other three:

```
$ aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights
/aws/containerinsights/dop-c02-lab-cluster/application
/aws/containerinsights/dop-c02-lab-cluster/dataplane
/aws/containerinsights/dop-c02-lab-cluster/host
/aws/containerinsights/dop-c02-lab-cluster/performance
```

All four were created with `retentionInDays: None` (never expire).

### Phase 1 — pod alive

Pod state at capture:

```
NAME         READY   STATUS             RESTARTS      AGE
crash-demo   0/1     CrashLoopBackOff   6 (96s ago)   7m27s
```

**A — `kubectl logs crash-demo --previous`** — exit 0:

```
CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
ERROR: Simulated application failure
Stack trace line 1
Stack trace line 2
```

**B — `kubectl describe pod crash-demo`** — exit 0:

```
Containers:
  crash-container:
    Container ID:  containerd://0baf950a1433...
    Image:         busybox
    Args:
      echo "CONTAINER STARTING - timestamp: $(date)"
      echo "ERROR: Simulated application failure"
      echo "Stack trace line 1"
      echo "Stack trace line 2"
      sleep 2
      exit 1
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      Sat, 08 Aug 2026 13:32:23 -0600
      Finished:     Sat, 08 Aug 2026 13:32:25 -0600
    Restart Count:  6
```

As in the first lab, the application's strings appear here as the container's declared
`Args` copied from the pod spec — with `$(date)` unexpanded — not as captured stdout.

**C — worker node via SSM** — exit 0:

```
# nerdctl ps -a | grep crash
0baf950a1433  docker.io/library/busybox:latest  "sh -c echo \"CONTAIN…"  About a minute ago  Created  k8s://default/crash-demo/crash-container
1431fa1b9613  .../eks/pause:3.10                "/pause"                 7 minutes ago       Up       k8s://default/crash-demo

# nerdctl logs 0baf950a1433
CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
ERROR: Simulated application failure
Stack trace line 1
Stack trace line 2

# ls -la /var/log/pods/default_crash-demo_<pod-uid>/crash-container/
-rw-r----- 1 root root 295 Aug  8 19:32 6.log

# cat /var/log/pods/default_crash-demo_<pod-uid>/crash-container/6.log
2026-08-08T19:32:23.415901069Z stdout F CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
2026-08-08T19:32:23.415926866Z stdout F ERROR: Simulated application failure
2026-08-08T19:32:23.415930873Z stdout F Stack trace line 1
2026-08-08T19:32:23.41593362Z  stdout F Stack trace line 2

# which docker crictl
which: no docker in (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin)
which: no crictl in (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin)
```

**D — CloudWatch Logs** — exit 0. A stream now exists for the pod, named after the node
and the on-disk container log file:

```
$ aws logs describe-log-streams --log-group-name .../application \
    --order-by LastEventTime --descending
<node>-application.var.log.containers.crash-demo_default_crash-container-0baf950a1433....log
<node>-application.var.log.containers.cloudwatch-agent-hj4mp_amazon-cloudwatch_otc-container-....log
<node>-application.var.log.containers.fluent-bit-7h7rx_amazon-cloudwatch_fluent-bit-....log
<node>-application.var.log.containers.amazon-cloudwatch-observability-controller-manager-...log
```

```
$ aws logs filter-log-events --log-group-name .../application \
    --filter-pattern '"Simulated application failure"' --max-items 100
{
    "events": [
        {
            "logStreamName": "<node>-application.var.log.containers.crash-demo_default_crash-container-0baf950a1433....log",
            "timestamp": 1786217543415,
            "message": "{\"time\":\"2026-08-08T19:32:23.415926866Z\",\"stream\":\"stdout\",\"_p\":\"F\",\"log\":\"ERROR: Simulated application failure\",\"kubernetes\":{\"pod_name\":\"crash-demo\",\"namespace_name\":\"default\",\"pod_id\":\"<pod-uid>\",\"host\":\"<node>\",\"pod_ip\":\"<pod-ip>\",\"container_name\":\"crash-container\",\"docker_id\":\"0baf950a1433...\",\"container_image\":\"docker.io/library/busybox:latest\"}}",
            "ingestionTime": 1786217552524
        }
    ],
    "searchedLogStreams": []
}
```

Fluent Bit wraps each line in JSON and attaches Kubernetes metadata; the raw stdout line
is the `log` field. Decoded, the group held these `CONTAINER STARTING` events:

```
CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
CONTAINER STARTING - timestamp: Sat Aug  8 19:37:36 UTC 2026
```

Two events against a restart count of 7 — the five restarts that happened before the
add-on was installed are not in CloudWatch. Every restart *after* the agent started was
captured, including one whose container writes 4 lines and exits within ~2s.

### Phase 2 — after `kubectl delete pod`

```
$ kubectl delete pod crash-demo --force
Warning: Immediate deletion does not wait for confirmation that the running resource has been terminated.
pod "crash-demo" force deleted from default namespace
```

**A** — exit 1:

```
error: error from server (NotFound): pods "crash-demo" not found in namespace "default"
```

**B** — exit 1:

```
Error from server (NotFound): pods "crash-demo" not found
```

**C** — exit 0, but both container IDs captured before the delete are gone, and the
pod's log directory is now empty:

```
# nerdctl ps -a | grep crash
1431fa1b9613  .../eks/pause:3.10  "/pause"  12 minutes ago  Created  k8s://default/crash-demo

# nerdctl logs 0baf950a1433        # the previous container
time="2026-08-08T19:39:11Z" level=fatal msg="no such container 0baf950a1433"

# nerdctl logs bc5b73b70bae        # the current container
time="2026-08-08T19:39:11Z" level=fatal msg="no such container bc5b73b70bae"

# ls -la /var/log/pods/default_crash-demo_<pod-uid>/crash-container/
total 0
drwxr-xr-x. 2 root root 6 Aug  8 19:38 .

# ls -la /var/log/containers/ | grep crash
NO_CRASH_FILES
```

**D** — exit 0, unchanged from Phase 1:

```
events: 2
   CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
   CONTAINER STARTING - timestamp: Sat Aug  8 19:37:36 UTC 2026
```

Both pod streams were still listed, including the final container instance that the node
no longer has any trace of:

```
$ aws logs describe-log-streams --log-group-name .../application \
    --query 'logStreams[?contains(logStreamName,`crash-demo`)]'
<node>-application.var.log.containers.crash-demo_default_crash-container-bc5b73b70bae....log
<node>-application.var.log.containers.crash-demo_default_crash-container-0baf950a1433....log
```

### Phase 3 — after deleting the forwarding stack

```
$ aws cloudformation delete-stack --stack-name dop-c02-lab-eks-logging
$ aws cloudformation wait stack-delete-complete --stack-name dop-c02-lab-eks-logging
$ aws cloudformation describe-stacks --stack-name dop-c02-lab-eks-logging
An error occurred (ValidationError): Stack with id dop-c02-lab-eks-logging does not exist
```

The forwarding path is gone — add-on removed, its pods gone, IAM policy detached from the
node role:

```
$ aws eks list-addons --cluster-name dop-c02-lab-cluster
{ "addons": [] }

$ kubectl get pods -n amazon-cloudwatch
No resources found in amazon-cloudwatch namespace.

$ aws iam list-attached-role-policies --role-name dop-c02-lab-cluster-node-role
[ "AmazonSSMManagedInstanceCore", "AmazonEKS_CNI_Policy",
  "AmazonEC2ContainerRegistryReadOnly", "AmazonEKSWorkerNodePolicy" ]
```

The log groups and their contents did **not** go with it:

```
$ aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights
/aws/containerinsights/dop-c02-lab-cluster/application   retention 1
/aws/containerinsights/dop-c02-lab-cluster/dataplane     retention 1
/aws/containerinsights/dop-c02-lab-cluster/host          retention 1
/aws/containerinsights/dop-c02-lab-cluster/performance   retention 1

$ aws logs filter-log-events --log-group-name .../application \
    --filter-pattern '"CONTAINER STARTING"' --max-items 100
events: 2
   CONTAINER STARTING - timestamp: Sat Aug  8 19:32:23 UTC 2026
   CONTAINER STARTING - timestamp: Sat Aug  8 19:37:36 UTC 2026
```

The `retention 1` values are the ones applied manually by `SetLogRetentionCommand`; they
survived too. Deleting the stack stops *new* logs being forwarded, but does not remove
what was already delivered. Returning Approach D to a genuinely empty result requires
deleting the log groups explicitly:

```sh
for g in application dataplane host performance; do
  aws logs delete-log-group --log-group-name /aws/containerinsights/dop-c02-lab-cluster/$g
done
```

## Before / after

Presence of the application's own stdout strings in each approach's output. "Before" is
the first lab ([`eks-crashloop-log-retrieval`](../eks-crashloop-log-retrieval/README.md));
"after" is this lab with the add-on installed.

| | Command | Before (no forwarding) | After, pod alive | After, pod deleted |
| --- | --- | --- | --- | --- |
| A | `kubectl logs crash-demo --previous` | both strings, exit 0 (failed once against a reaped container ID) | both strings, exit 0 | `NotFound`, exit 1 |
| B | `kubectl describe pod crash-demo` | both strings, in the `Args:` spec block | both strings, in the `Args:` spec block | `NotFound`, exit 1 |
| C | SSM → `nerdctl logs <id>` | both strings, exit 0 (`docker`/`crictl` absent) | both strings, exit 0 | `no such container`; pod log dir empty |
| D | `aws logs filter-log-events` | no log group at all — empty result set | both strings, exit 0 | both strings, exit 0 |

And across the stack lifecycle:

| State | Approach D result |
| --- | --- |
| Cluster only (lab 1) | no `/aws/containerinsights` log groups exist |
| Forwarding stack deployed, pod running | log group holds every restart since the agent started |
| Pod force-deleted | unchanged — same events still queryable |
| Forwarding stack deleted | unchanged — groups, events and retention all persist |
| Log groups explicitly deleted | back to the lab 1 state |

## Teardown

Default: remove only the forwarding stack, leaving the cluster up for further labs.

```sh
aws cloudformation delete-stack --stack-name dop-c02-lab-eks-logging
aws cloudformation wait stack-delete-complete --stack-name dop-c02-lab-eks-logging
```

The log groups are **not** removed by that, and they continue to bill for storage until
their retention expires. Delete them explicitly when done:

```sh
for g in application dataplane host performance; do
  aws logs delete-log-group --log-group-name /aws/containerinsights/dop-c02-lab-cluster/$g
done
```

The cluster itself is torn down from the first lab:

```sh
aws cloudformation delete-stack --stack-name dop-c02-lab-eks
```
