# EKS: retrieving stdout/stderr from an already-crashed container

**Domain 4 — Monitoring and Logging**

A pod is in `CrashLoopBackOff`. The container wrote diagnostic lines to stdout before
exiting non-zero, and that container instance is already gone. Four approaches are
commonly proposed for recovering those lines. This lab runs all four against the same
pod and records the raw output of each.

This README records commands and observations only. It does not label any approach as
correct — compare the captured output yourself. A full run was executed on 2026-08-08;
the raw terminal output of all four approaches is in
[Observed output](#observed-output--run-of-2026-08-08).

Three environment behaviours from that run are worth knowing before you read the
captures, because each one changes what a given approach can return:

- Kubelet reaps rotated container log files. Only the newest survived, and `--previous`
  failed against an already-reaped container ID before succeeding on retry.
- While a pod sits in `CrashLoopBackOff`, the current and previous container IDs are the
  same value, so `kubectl logs` and `kubectl logs --previous` return identical bytes.
- The AL2023 EKS 1.36 AMI has no `crictl` and no `docker`.

## Cost

Not free tier.

| Resource | Rate |
| --- | --- |
| EKS control plane | ~$0.10/hr (~$73/mo if left running) |
| 1 × t3.micro on-demand | ~$0.0104/hr |

Covered by the AWS Community Builders credit. The control plane bills per hour from
`CREATE_COMPLETE` regardless of whether any workload runs, so delete the stack when the
cluster is no longer being reused.

## Layout

| File | Purpose |
| --- | --- |
| `lab-eks-crashloop.yaml` | Cluster IAM role, EKS cluster, node IAM role, managed nodegroup |
| `crash-pod.yaml` | Pod that prints four lines to stdout, sleeps 2s, exits 1 |

## Deploy

This scenario uses the stack name `dop-c02-lab-eks` and cluster name
`dop-c02-lab-cluster` rather than the repo's `dop-lab-d<n>-<slug>` convention, so it
deploys with the CLI directly instead of `make apply`. The change-set workflow is
unchanged.

```sh
export AWS_PROFILE="$LAB_PROFILE" AWS_REGION=us-east-1   # lab account profile, see .env.local

aws cloudformation create-change-set \
  --stack-name dop-c02-lab-eks \
  --change-set-name cs-manual \
  --change-set-type CREATE \
  --template-body file://lab-eks-crashloop.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=VpcId,ParameterValue=<default-vpc-id> \
    "ParameterKey=SubnetIds,ParameterValue=<subnet-a>\,<subnet-b>\,<subnet-c>" \
  --tags Key=Project,Value=dop-c02-lab Key=Domain,Value=4 \
         Key=Scenario,Value=eks-crashloop-log-retrieval

aws cloudformation describe-change-set \
  --stack-name dop-c02-lab-eks --change-set-name cs-manual \
  --query 'Changes[].ResourceChange.[Action,ResourceType,LogicalResourceId]' --output table

aws cloudformation execute-change-set \
  --stack-name dop-c02-lab-eks --change-set-name cs-manual
aws cloudformation wait stack-create-complete --stack-name dop-c02-lab-eks
```

Then point kubectl at the cluster and start the pod:

```sh
aws eks update-kubeconfig --name dop-c02-lab-cluster --region us-east-1
kubectl scale deployment coredns -n kube-system --replicas=1   # free a pod slot, see notes
kubectl apply -f crash-pod.yaml
kubectl get pod crash-demo --watch    # wait for STATUS = CrashLoopBackOff
```

Reaching `CrashLoopBackOff` takes ~3.5 minutes and 4 restarts. The pod passes through
`Running` and `Error` several times first — `Error` is not the state to test against,
since the backoff timer is what guarantees the previous container is retained but not
running.

## Deployment notes

Four properties of this environment shape what the lab can do. Read them before
redeploying:

- **Kubernetes version.** The template defaults to `1.36`, the newest version EKS offered
  at the time of the run. EKS retires versions continuously, so a redeploy months from
  now may find `1.36` gone from standard support. Check the current list and override
  `KubernetesVersion` if needed:
  `aws eks describe-addon-versions --addon-name vpc-cni \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion'`.
- **`t3.micro` capacity — needs a manual step.** The EKS CNI derives `max-pods` from ENI
  limits: 2 ENIs × 2 IPv4 ⇒ **`max-pods=4`**. Measured on the running node,
  `.status.allocatable.pods` is `4` and the default kube-system set fills every slot:
  `aws-node`, `kube-proxy`, and **both** CoreDNS replicas. `crash-demo` will sit
  `Pending` indefinitely unless a slot is freed first:

  ```sh
  kubectl scale deployment coredns -n kube-system --replicas=1
  ```

  Do this *before* `kubectl apply -f crash-pod.yaml`. To reuse this cluster for anything
  else, raise `NodeInstanceType` to `t3.small` (`max-pods=11`) instead — at `t3.micro`
  there is exactly one free pod slot in the whole cluster.
- **`AmazonSSMManagedInstanceCore` on the node role.** Not needed to run Kubernetes, but
  Approach C requires a shell on the worker node, and managed nodegroups launch without
  an EC2 key pair. SSM is the only route in.
- **No `crictl` on the AMI.** The EKS-optimized AL2023 image for 1.36 carries `ctr` and
  `nerdctl` but neither `docker` nor `crictl`, so the conventional `crictl ps -a` /
  `crictl logs` recipe fails outright. This surfaced only at test time. See Approach C
  for the full tool inventory.

`Logging` is deliberately left unset on `AWS::EKS::Cluster`. Note that enabling it would
only ship *control-plane component* logs (`api`, `audit`, `authenticator`,
`controllerManager`, `scheduler`) — never container stdout/stderr, which reaches
CloudWatch only via a node-level agent such as Fluent Bit in CloudWatch Container
Insights.

## Test procedure

Confirm the pod is genuinely in `CrashLoopBackOff` (not `Error` or `Completed`) before
starting. Record the `STATUS` and `RESTARTS` values at the moment of capture.

```sh
kubectl get pod crash-demo
```

For each approach, record: the exact command, its exact output, whether the output
contained the strings `CONTAINER STARTING` and `Simulated application failure`, and
whether the CLI itself returned a non-zero exit or an error message.

### Approach A — previous container's logs via the API server

```sh
kubectl logs crash-demo --previous
```

### Approach B — pod description

```sh
kubectl describe pod crash-demo
```

Capture both the `Containers:` block and the `Events:` block.

### Approach C — direct worker node access

```sh
kubectl get nodes -o wide
kubectl get pod crash-demo -o jsonpath='{.status.containerStatuses[0].containerID}'
```

The container ID is prefixed with the runtime name; note what that prefix is. Get the
node's EC2 instance ID and open a session:

```sh
INSTANCE=$(kubectl get node -o jsonpath='{.items[0].spec.providerID}' | awk -F/ '{print $NF}')
aws ssm start-session --target "$INSTANCE"
```

SSM drops you in as `root`, so no `sudo` is needed. Try each runtime CLI and record which
ones exist on this AMI:

```sh
docker ps -a | grep crash
crictl ps -a | grep crash
ctr -n k8s.io containers ls | grep crash
nerdctl ps -a | grep crash
nerdctl logs <container-id>
```

Also record whether the exited container's log file still exists on disk:

```sh
ls -la /var/log/pods/default_crash-demo_<pod-uid>/crash-container/
cat  /var/log/pods/default_crash-demo_<pod-uid>/crash-container/*.log
```

Non-interactively the same commands run via
`aws ssm send-command --document-name AWS-RunShellScript`.

### Approach D — CloudWatch Logs

```sh
aws logs describe-log-groups --log-group-name-prefix /aws/eks
aws logs describe-log-groups --query "logGroups[?contains(logGroupName,'crash-demo')]"
```

Record the full result, including an empty result.

## Observed output — run of 2026-08-08

Cluster `dop-c02-lab-cluster`, Kubernetes 1.36, single t3.micro node running
AL2023 2023.12.20260727 with containerd 2.2.5. Node name and instance ID are redacted
below as `<node>` and `<node-instance-id>`.

Pod state at the time of capture:

```
NAME         READY   STATUS             RESTARTS      AGE
crash-demo   0/1     CrashLoopBackOff   4 (78s ago)   3m44s
```

The four strings the application itself emits are `CONTAINER STARTING`,
`ERROR: Simulated application failure`, `Stack trace line 1`, `Stack trace line 2`.

### A — `kubectl logs crash-demo --previous`

First invocation:

```
unable to retrieve container logs for containerd://12003249cfcc6b4b762459b0f691ae1a47fb8c67c30b8e24b9acb3306cf9043c
```

Re-run a few minutes later, same pod, same command:

```
CONTAINER STARTING - timestamp: Sat Aug  8 18:26:02 UTC 2026
ERROR: Simulated application failure
Stack trace line 1
Stack trace line 2
```

Exit status 0. The container ID named in the failure was an instance that kubelet had
already garbage-collected; `--previous` resolves `lastState.terminated.containerID` at
call time and fails if that instance's log file has been reaped.

Note that while the pod sits in backoff, nothing is running, so
`.status.containerStatuses[0].containerID` and `.lastState.terminated.containerID` are
the **same** value — `kubectl logs` and `kubectl logs --previous` return identical bytes
in that window.

### B — `kubectl describe pod crash-demo`

`Containers:` section:

```
Containers:
  crash-container:
    Container ID:  containerd://2343fef3e055d0fcd3fb0b8be7e7009db51efbf8bffbc4b6b678fba4f6525043
    Image:         busybox
    Command:
      sh
      -c
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
      Started:      Sat, 08 Aug 2026 12:54:27 -0600
      Finished:     Sat, 08 Aug 2026 12:54:29 -0600
    Ready:          False
    Restart Count:  11
```

`Events:` section:

```
  Type     Reason                  Age                   From               Message
  ----     ------                  ----                  ----               -------
  Warning  FailedCreatePodSandBox  35m                   kubelet            Failed to create pod sandbox: rpc error: code = Unknown desc = failed to setup network for sandbox "605216fd...": plugin type="aws-cni" name="aws-cni" failed (add): add cmd: failed to assign an IP address to container
  Normal   Scheduled               35m                   default-scheduler  Successfully assigned default/crash-demo to <node>
  Normal   Pulled                  35m                   kubelet            Successfully pulled image "busybox" in 527ms (527ms including waiting). Image size: 2236931 bytes.
  Normal   Created                 32m (x6 over 35m)     kubelet            Container created
  Normal   Started                 32m (x6 over 35m)     kubelet            Container started
  Warning  BackOff                 4m59s (x30 over 35m)  kubelet            Back-off restarting failed container crash-container in pod crash-demo_default(fe2a202d-a0ec-44a0-b178-1d7d277fea5d)
  Normal   Pulling                 3m36s (x12 over 35m)  kubelet            Pulling image "busybox"
```

Exit status 0, no error.

Read the `Args:` block carefully when scoring this one. The literal strings
`CONTAINER STARTING` and `ERROR: Simulated application failure` **do** appear in this
output — as the container's declared `Args` copied from the pod spec, echoed back by the
API server. Compare against the runtime evidence: the `Args` block reproduces the
`$(date)` substitution unexpanded, and carries no timestamp, no ordering, and no
indication of how far execution actually got. A string match alone does not distinguish
spec from captured stdout.

`FailedCreatePodSandBox` / `failed to assign an IP address to container` is an artifact
of `max-pods=4` on t3.micro, not of the crash under test.

### C — worker node direct access

Runtime as reported by the API server: `containerd://2.2.5+unknown`.
Container ID prefix on the pod: `containerd://`.

Tool inventory on the node (`AL2023_x86_64_STANDARD`, EKS 1.36):

```
PATH: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
which: no crictl in (...)
which: no docker in (...)
/usr/bin/ctr
/usr/local/bin/nerdctl

rpm: containerd-2.2.5-1.amzn2023.0.1.x86_64
socket: srw-rw---- /run/containerd/containerd.sock
/run/dockershim.sock: No such file or directory
/etc/crictl.yaml: No such file or directory
```

```
# docker ps -a | grep crash
bash: docker: command not found

# crictl ps -a | grep crash
bash: crictl: command not found

# ctr -n k8s.io containers ls | grep crash
(0 rows — ctr lists by container ID and sandbox ID, not by pod or container name)
```

`nerdctl` resolves the `k8s.io` namespace by default on this AMI; `-n k8s.io` is not
required:

```
# nerdctl ps -a | grep crash
dae6e5b56dd1  docker.io/library/busybox:latest              "sh -c echo \"CONTAIN…"  4 minutes ago   Created  k8s://default/crash-demo/crash-container
675cebf89d2a  602401143452.dkr.ecr.us-west-2.amazonaws.com/eks/pause:3.10  "/pause"  15 minutes ago  Up       k8s://default/crash-demo

# nerdctl logs dae6e5b56dd1
FATA[0000] no such container dae6e5b56dd1

# nerdctl logs 69e8ae279dc1
CONTAINER STARTING - timestamp: Sat Aug  8 18:38:55 UTC 2026
ERROR: Simulated application failure
Stack trace line 1
Stack trace line 2
```

The `no such container` failure was against the ID in `Created` state — a container
kubelet had staged for the next restart but never started, so it had no log file yet.

On-disk log files for the pod:

```
# ls -la /var/log/pods/default_crash-demo_fe2a202d-a0ec-44a0-b178-1d7d277fea5d/crash-container/
-rw-r----- 1 root root 295 Aug  8 18:33 7.log

# wc -l .../7.log
4
```

One surviving file, numbered for the current restart count; `0.log`–`6.log` had already
been reaped.

### Relationship between A and C

Captured back to back, A and C returned byte-identical content bearing the same
`18:38:55` timestamp — the same container instance. `kubectl logs` does not query
containerd: kubelet serves the API server from the file under `/var/log/pods/...`, which
is the same file the node-level CLI reads. A reaches it via API server → kubelet; C
reaches it via a shell on the node. One source, two paths — which is also why the
kubelet log-rotation reaping that broke A's first invocation bounds what C can recover.

### D — CloudWatch Logs

```
$ aws logs describe-log-groups --log-group-name-prefix /aws/eks
{
    "logGroups": []
}

$ aws logs describe-log-groups --query "logGroups[?contains(logGroupName,'crash-demo')]"
[]
```

Listing every log group in `us-east-1` on this account returned exactly one entry, an
ECS Container Insights group (name redacted) that predates this lab and belongs to an
unrelated cluster. No log group was created for the EKS cluster, the node, or the pod.

### Summary of captures

Presence of the application's own stdout strings in each approach's output:

| | Command | `CONTAINER STARTING` | `Simulated application failure` | CLI error |
| --- | --- | --- | --- | --- |
| A | `kubectl logs crash-demo --previous` | yes | yes | none on re-run; failed once against a reaped container ID |
| B | `kubectl describe pod crash-demo` | yes, in the `Args:` spec block | yes, in the `Args:` spec block | none |
| C | SSM → `nerdctl logs <id>` | yes | yes | `docker` and `crictl` not installed; `no such container` against a `Created` ID |
| D | `aws logs describe-log-groups` | no | no | none — empty result set |

## Teardown

The pod alone:

```sh
kubectl delete pod crash-demo --force
```

The whole cluster, once it is no longer being reused:

```sh
aws cloudformation delete-stack --stack-name dop-c02-lab-eks
aws cloudformation wait stack-delete-complete --stack-name dop-c02-lab-eks
aws eks list-nodegroups --cluster-name dop-c02-lab-cluster   # expect ResourceNotFoundException
aws eks list-clusters
```

CloudFormation deletes the nodegroup before the cluster on its own; the two `eks`
commands are confirmation, not sequencing.
