# base/logging-baseline

Shared, low-cost logging primitives for scenarios:

- `LogsBucket` — versioned S3 bucket, SSE-S3 encrypted, public access blocked, objects (and
  noncurrent versions) expire after 7 days.
- `CentralLogGroup` — CloudWatch Log Group `/dop-lab/central`, 7-day retention.

**Out of scope on purpose:** no CloudTrail trail here, to avoid accidentally creating a
duplicate account-wide/multi-region trail. A scenario that needs a trail creates its own under
`scenarios/domain-4-monitoring/`.

## Deploy

```bash
make base-plan NAME=logging-baseline
make base-deploy NAME=logging-baseline
```

## Outputs

- `dop-lab-base-logging-baseline-LogsBucketName` / `LogsBucketArn`
- `dop-lab-base-logging-baseline-CentralLogGroupName` / `CentralLogGroupArn`

## Teardown

```bash
make base-destroy-all
```
