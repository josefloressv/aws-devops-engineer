# ssm-state-manager-self-healing

Domain: `domain-2-config-iac`
Stack name: `dop-lab-d2-ssm-state-manager-self-healing`

## Objective

Which SSM capability automatically re-applies a desired configuration when it drifts
(self-healing on a schedule), versus running only once on demand? Candidates under test:
State Manager Association (scheduled), Run Command (one-shot), Automation execution
(one-shot unless externally triggered), and Inventory (passive reporting only).

## Resources Created

- `InstanceSecurityGroup` — outbound-only SG, no inbound rules (shell access via Session Manager).
- `Ec2Instance` — t2.micro, Amazon Linux 2023, public subnet from `base/network`, instance
  profile from `base/iam-baseline`. `UserData` creates and starts a `dop-lab-marker.service`
  systemd unit (`ExecStart=/usr/bin/sleep infinity`) — this is the "desired state" being tracked.
- `EnsureMarkerServiceDocument` — `AWS::SSM::Document` (Command type) that runs
  `systemctl start dop-lab-marker.service && systemctl is-active dop-lab-marker.service`.
- `MarkerAssociation` — `AWS::SSM::Association` applying that document to the instance on
  `rate(5 minutes)`, `ApplyOnlyAtCronInterval: false`.

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
   aws ssm describe-association --instance-id "$INSTANCE_ID" --association-id "$ASSOC_ID"
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
   # then, with the returned command id:
   aws ssm list-command-invocations --instance-id "$INSTANCE_ID" --details
   ```

4. **Do not manually re-trigger anything.** Poll the association every 60s up to the
   5-minute schedule interval:

   ```bash
   while true; do
     date -u
     aws ssm describe-association --instance-id "$INSTANCE_ID" --association-id "$ASSOC_ID" \
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
   aws ssm get-inventory --filters Key=AWS:Application,Values=*
   ```

6. **One-shot Automation execution for comparison**

   ```bash
   aws ssm start-automation-execution \
     --document-name AWS-RestartEC2Instance \
     --parameters InstanceId="$INSTANCE_ID" \
     --query 'AutomationExecutionId' --output text
   # then:
   aws ssm get-automation-execution --automation-execution-id <id>
   ```

   Note whether this only ran because you explicitly called `start-automation-execution` —
   it has no schedule of its own.

Do not state which capability is "the answer" in any captured output or notes — just the raw
command output and timestamps.

## Teardown

```bash
make destroy LAB=domain-2-config-iac/ssm-state-manager-self-healing
```
