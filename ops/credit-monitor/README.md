# credit-monitor

Monthly email report on AWS promotional credit burn rate, with a warning when the credit is
on track to expire unused.

## Why this exists

Three consecutive credits expired on this organization with **$971.02 unused** — $372.32,
$98.72, and $499.98 — because org-wide spend runs well under $1/month against $500 pools.
The failure mode here is under-utilization, not overspend, and nothing in AWS warns about
that. Budgets alert on exceeding a threshold, not on failing to reach one.

There is also **no API that returns a credit balance** — the Billing console is the only
place it appears. This stack works around that by summing Cost Explorer's `Credit` record
type from the redemption date forward, which is queryable and gives the amount consumed.

## Architecture

```
EventBridge rule (monthly)
   -> Lambda (ce:GetCostAndUsage)
      -> SNS topic
         -> email
```

Deploy to the **payer account** — `PAYER_ACCOUNT_ID` / `PAYER_PROFILE_DEFAULT` in `.env.local`
(see `.env.local.example`). Credits pool at the organization's management account, and only
that account's Cost Explorer sees org-wide data; `scripts/ops-apply.sh` refuses to run
anywhere else.

## Deploy

```bash
make ops-apply NAME=credit-monitor PARAMS="NotificationEmail=you@example.com"
```

Then **confirm the SNS subscription** — AWS sends a confirmation email, and no reports arrive
until the link is clicked.

Parameters worth overriding when a new credit is redeemed:

| Parameter | Default | Notes |
|---|---|---|
| `NotificationEmail` | *(required)* | Re-confirm the subscription if changed |
| `CreditName` | AWS Community Builders 2026 Renewal Credit | Appears in the email body |
| `CreditTotal` | `500` | Issued amount in USD |
| `CreditStart` | `2026-08-01` | Redemption date; consumption is summed from here |
| `CreditExpiry` | `2027-11-30` | Drives the projection and the days-left counter |
| `WarnThresholdPercent` | `50` | Warn below this projected utilization |
| `ScheduleExpression` | `cron(0 13 1 * ? *)` | 1st of month, 07:00 America/El_Salvador |

## Test it without waiting a month

```bash
source .env.local
aws lambda invoke --profile "$PAYER_PROFILE_DEFAULT" \
  --function-name "$(aws cloudformation describe-stacks \
    --profile "$PAYER_PROFILE_DEFAULT" \
    --stack-name dop-ops-credit-monitor \
    --query 'Stacks[0].Outputs[?OutputKey==`FunctionName`].OutputValue' --output text)" \
  /dev/stdout
```

## Sample output

```
AWS Community Builders 2026 Renewal Credit
Issued $500.00 | Redeemed 2026-08-01 | Expires 2027-11-30 (486 days left)

Used       $1.02 (0.2%)
Remaining  $498.98
Burn rate  $0.51/month

PROJECTION AT CURRENT BURN
Consumed by expiry  $8.31 (2%)
EXPIRING UNUSED     $491.69
Needed to use all   $31.24/month

TOP SERVICES
  Amazon Route 53: $1.00
  Amazon Simple Storage Service: $0.02

WARNING: on track to waste $491.69.
Leave labs standing between sessions (a NAT Gateway is ~$33/mo)
or run the RDS / EKS / Aurora scenarios.
```

## Cost

Effectively $0 — twelve Lambda invocations a year, twelve SNS emails, one EventBridge rule.
Cost Explorer's `GetCostAndUsage` API costs **$0.01 per request** (roughly $0.12/year at this
schedule). Lambda, SNS, and CloudWatch Events are all on the credit's applicable-products
list, so this bills against the credit rather than the payment method.

## Teardown

```bash
source .env.local
aws cloudformation delete-stack --profile "$PAYER_PROFILE_DEFAULT" \
  --stack-name dop-ops-credit-monitor
```
