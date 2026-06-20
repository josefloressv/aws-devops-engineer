# ssm-state-manager-self-healing

Domain: `domain-2-config-iac`
Stack name: `dop-lab-d2-ssm-state-manager-self-healing`

## Objective

Which SSM capability automatically re-applies a desired configuration when it drifts
(self-healing on a schedule), versus running only once on demand? Candidates under test:
State Manager Association (scheduled), Run Command (one-shot), Automation execution
(one-shot unless externally triggered), and Inventory (passive reporting only).

## Background — what each candidate actually does

This lab targets one specific question: of the four capabilities below, which one keeps
re-applying a desired config **on its own**, with nothing else telling it to?

- **Run Command** — a single, one-shot execution. Something calls `send-command`, the document
  runs once against the target(s), and that's it. Run Command itself has no memory of having run
  and no clock — if it ever "repeats," that's because something external called it again, not
  because Run Command scheduled itself.
- **Automation** — also one-shot per invocation, but the document is a multi-step *runbook*
  (branching, waiting on state changes, multiple actions) instead of a single script. Like Run
  Command, it has no built-in schedule — it only runs when something starts it: a person, an
  EventBridge rule, a CloudWatch alarm action, or an AWS Config auto-remediation. Whatever
  "automatic" feeling people associate with it comes from that external trigger, not from
  Automation watching anything itself.
- **Inventory** — passive metadata collection. It can be scheduled (via its own association),
  but it only *reports* facts (installed packages, OS version, instance info) into a queryable
  snapshot. It has no concept of "desired state" and never remediates — if a tracked service is
  broken, Inventory will just keep faithfully reporting that it's broken, forever.
- **State Manager Association** — the only one of the four with its own internal schedule.
  Every cycle it re-runs its target document against its targets by itself, with nothing external
  needed in between. Under the hood, each cycle *is* a Run Command invocation — the difference
  is who decides to fire it: a human/external system (Run Command, Automation) vs. the
  association's own clock (State Manager).

This scenario's `MarkerAssociation` is the State Manager candidate. The test procedure below
exercises all four against the same drift so the difference is observable directly, not just
theoretical.

One more mechanic worth knowing going in: SSM's compliance status (what you see as
"Compliant"/"Non-compliant" in the console) reflects the result of the *last completed
execution* of a document — it is not a live poll of the resource. Between scheduled cycles,
compliance can show stale/"green" even after you've broken the underlying resource, simply
because nothing has re-checked it yet.

## Resources Created

- `InstanceSecurityGroup` — outbound-only SG, no inbound rules (shell access via Session Manager).
- `Ec2Instance` — t3.small, Amazon Linux 2023, public subnet from `base/network`, instance
  profile from `base/iam-baseline`. `UserData` creates and starts a `dop-lab-marker.service`
  systemd unit (`ExecStart=/usr/bin/sleep infinity`) — this is the "desired state" being tracked.
  `Restart=always` makes systemd itself resilient to *crashes*; this lab instead tests *deliberate
  stops*, which systemd does not auto-restart on its own.
- `EnsureMarkerServiceDocument` — `AWS::SSM::Document` (Command type) that runs
  `systemctl start dop-lab-marker.service && systemctl is-active dop-lab-marker.service`.
- `MarkerAssociation` — `AWS::SSM::Association` applying that document to the instance on
  `rate(30 minutes)` (SSM's hard minimum for rate-based associations), `ApplyOnlyAtCronInterval: false`.

## Evidence Commands

Capture every command + raw output with a timestamp (`date -u`) before/after each step.

```bash
# Resolve identifiers
STACK=dop-lab-d2-ssm-state-manager-self-healing
INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
DOC_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`DocumentName`].OutputValue' --output text)
ASSOC_ID=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`AssociationId`].OutputValue' --output text)
```

1. **Confirm initial state**

   ```bash
   aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID"
   aws ssm list-associations --instance-id "$INSTANCE_ID"
   aws ssm describe-association --association-id "$ASSOC_ID"
   ```

2. **Break the desired state** (via Session Manager — no inbound SSH needed)

   ```bash
   aws ssm start-session --target "$INSTANCE_ID"
   # on the instance:
   sudo systemctl stop dop-lab-marker.service
   sudo systemctl is-active dop-lab-marker.service   # confirm inactive
   exit
   ```

3. **One-shot manual Run Command immediately after breaking it**

   ```bash
   date -u
   aws ssm send-command --instance-ids "$INSTANCE_ID" \
     --document-name "AWS-RunShellScript" \
     --parameters commands='["systemctl is-active dop-lab-marker.service"]' \
     --query 'Command.CommandId' --output text
   # then:
   aws ssm list-command-invocations --instance-id "$INSTANCE_ID" --details
   ```

   Note: SSM reports the command's overall `Status` as `Failed` whenever the script's exit
   code is non-zero (e.g. `systemctl is-active` exits 3 when inactive) — that's the script
   result, not a Run Command execution problem. It's part of the evidence: Run Command only
   reports what it found, once, on demand. It does not restart the service.

4. **Do not manually re-trigger anything.** Poll the association every 60s up to the
   30-minute schedule interval:

   ```bash
   while true; do
     date -u
     aws ssm describe-association --association-id "$ASSOC_ID" \
       --query 'AssociationDescription.{LastExecutionDate:LastExecutionDate,LastSuccessfulExecutionDate:LastSuccessfulExecutionDate,Status:Overview.Status}'
     aws ssm list-command-invocations --instance-id "$INSTANCE_ID" --details \
       --query 'CommandInvocations[].{Time:RequestedDateTime,Status:Status,DocName:DocumentName}'
     sleep 60
   done
   ```

   Then check the instance state directly (new Session Manager session):

   ```bash
   aws ssm start-session --target "$INSTANCE_ID"
   systemctl is-active dop-lab-marker.service
   systemctl status dop-lab-marker.service --no-pager
   exit
   ```

5. **Inventory — passive reporting only?**

   ```bash
   aws ssm get-inventory --filters "Key=AWS:InstanceInformation.InstanceId,Values=$INSTANCE_ID"
   ```

6. **One-shot Automation execution for comparison**

   ```bash
   aws ssm start-automation-execution \
     --document-name AWS-RestartEC2Instance \
     --parameters "InstanceId=$INSTANCE_ID" \
     --query 'AutomationExecutionId' --output text
   # then:
   aws ssm get-automation-execution --automation-execution-id <id>
   ```

   Note whether this only ran because you explicitly called `start-automation-execution` —
   it has no schedule of its own.

Do not state which capability is "the answer" in any captured output or notes — just the raw
command output and timestamps.

## Captured Evidence (Run 1 — 2026-06-20)

Raw timeline observed on stack `dop-lab-d2-ssm-state-manager-self-healing`,
instance `i-04f71d0911d9737c3`, association `fde99d99-36fe-4c72-97e3-b94f34a6122c`:

| Time (UTC) | Event | Source |
|---|---|---|
| 19:41:04 | `dop-lab-marker.service` started (UserData boot) | `journalctl` |
| 19:41:20 | Association cycle #1 — `Overview.Status: Success` | `describe-association` |
| 19:47:20 | Compliance item recorded `COMPLIANT` | `list-compliance-items` |
| 19:51:04 | Service manually stopped (Session Manager) | `journalctl` (`Stopping...Stopped`) |
| 19:51:41 | Manual Run Command `systemctl is-active` → `Failed` (inactive, exit 3) | `list-command-invocations` |
| 19:53:49–19:54:11 | Repeated manual checks, still `inactive`; compliance still showed stale `COMPLIANT` from 19:47:20 | `systemctl status`, `list-compliance-items` |
| **20:12:03** | **Association cycle #2 fires on schedule** — `LastExecutionDate`/`LastSuccessfulExecutionDate` → `20:12:03`, `Overview.Status: Success`. Same instant, `journalctl` shows `systemd[1]: Started dop-lab-marker.service`. | `describe-association`, `journalctl` |
| 20:13:03 | `systemctl is-active` → `active` | Run Command |

No `send-command`, `start-session` write action, or `start-automation-execution` was issued
between 19:54:11 and 20:12:03 — the only thing that changed state in that window was the
association's own scheduled cycle.

Steps 5 (Inventory) and 6 (Automation) from the procedure above were not yet exercised in this
run.

## Teardown

```bash
make destroy LAB=domain-2-config-iac/ssm-state-manager-self-healing
```
