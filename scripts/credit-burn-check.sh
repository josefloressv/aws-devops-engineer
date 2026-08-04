#!/usr/bin/env bash
# Reports how fast the active AWS promotional credit is being consumed and
# whether it is on track to expire unused.
#
# Credit *balances* are not exposed by any AWS CLI/API -- only the Billing
# console shows them. This script instead derives consumption from Cost
# Explorer's "Credit" record type, which is queryable: summing the credits
# applied since the redemption date gives the amount used, and the rest
# follows from the issued total.
#
# Must run against the payer account (credits pool at the organization's
# management account), so it needs Cost Explorer permissions there.
#
# Usage: scripts/credit-burn-check.sh
#        AWS_PROFILE=... scripts/credit-burn-check.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
source scripts/lib.sh

# Active credit: AWS Community Builders 2026 Renewal, redeemed into the
# management account. Update these three values when a new credit is redeemed
# (and refresh docs/credit-applicable-services.md at the same time).
CREDIT_NAME="AWS Community Builders 2026 Renewal Credit"
CREDIT_TOTAL=500
CREDIT_START="2026-08-01"
CREDIT_EXPIRY="2027-11-30"

export AWS_PROFILE="${AWS_PROFILE:-$PAYER_PROFILE_DEFAULT}"
PAYER_PROFILE="$AWS_PROFILE"
TODAY="$(date -u +%F)"

require_payer_account

# Cost Explorer rejects a zero-length period, so never ask for less than a day.
END="$TODAY"
if [ "$END" = "$CREDIT_START" ]; then
  END="$(date -u -v+1d -f %F "$CREDIT_START" +%F 2>/dev/null || date -u -d "$CREDIT_START + 1 day" +%F)"
fi

credit_json="$(aws ce get-cost-and-usage \
  --profile "$PAYER_PROFILE" \
  --time-period "Start=${CREDIT_START},End=${END}" \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Credit"]}}' \
  --output json)"

usage_json="$(aws ce get-cost-and-usage \
  --profile "$PAYER_PROFILE" \
  --time-period "Start=${CREDIT_START},End=${END}" \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}' \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output json)"

CREDIT_NAME="$CREDIT_NAME" CREDIT_TOTAL="$CREDIT_TOTAL" \
CREDIT_START="$CREDIT_START" CREDIT_EXPIRY="$CREDIT_EXPIRY" TODAY="$TODAY" \
python3 - "$credit_json" "$usage_json" <<'PY'
import json, os, sys
from collections import defaultdict
from datetime import date

name   = os.environ["CREDIT_NAME"]
total  = float(os.environ["CREDIT_TOTAL"])
start  = date.fromisoformat(os.environ["CREDIT_START"])
expiry = date.fromisoformat(os.environ["CREDIT_EXPIRY"])
today  = date.fromisoformat(os.environ["TODAY"])

credit_data, usage_data = json.loads(sys.argv[1]), json.loads(sys.argv[2])

# Credits are reported as negative unblended cost; flip the sign to get usage.
used = sum(abs(float(r["Total"]["UnblendedCost"]["Amount"]))
           for r in credit_data["ResultsByTime"] if r.get("Total"))
remaining = max(total - used, 0.0)

services = defaultdict(float)
for r in usage_data["ResultsByTime"]:
    for g in r.get("Groups", []):
        services[g["Keys"][0]] += float(g["Metrics"]["UnblendedCost"]["Amount"])

elapsed_days   = max((today - start).days, 1)
remaining_days = (expiry - today).days
burn_per_day   = used / elapsed_days
projected      = used + burn_per_day * max(remaining_days, 0)
wasted         = max(total - projected, 0.0)
needed_month   = remaining / max(remaining_days / 30.44, 0.01)

print(f"""
==> Credit: {name}
    Issued          ${total:,.2f}
    Redeemed        {start}   ({elapsed_days} days ago)
    Expires         {expiry}   ({remaining_days} days left)

==> Consumption (from Cost Explorer 'Credit' record type)
    Used            ${used:,.2f}   ({used / total * 100:.1f}%)
    Remaining       ${remaining:,.2f}
    Burn rate       ${burn_per_day * 30.44:,.2f} / month

==> Projection at current burn rate
    Consumed by {expiry}   ${projected:,.2f}   ({projected / total * 100:.1f}%)
    EXPIRING UNUSED             ${wasted:,.2f}
    Burn needed to use it all   ${needed_month:,.2f} / month""")

if services:
    print("\n==> What is consuming it")
    for svc, amt in sorted(services.items(), key=lambda kv: -kv[1]):
        if amt > 0:
            print(f"    {svc:<45} ${amt:,.4f}")

pct = projected / total * 100
print()
if remaining_days < 0:
    print("!! CREDIT HAS EXPIRED -- redeem a new one and update scripts/credit-burn-check.sh")
elif pct < 50:
    print(f"!! WARNING: on track to waste ${wasted:,.2f} ({100 - pct:.0f}% of the credit).")
    print(f"!! Spend must reach ~${needed_month:,.2f}/month to consume it before {expiry}.")
    print("!! Cheapest way to move the needle: leave labs standing between sessions")
    print("!! (a NAT Gateway alone is ~$33/month) and run the RDS / EKS / Aurora scenarios.")
    if remaining_days < 90:
        print(f"!! Only {remaining_days} days left -- this is the last realistic window.")
else:
    print(f"==> On track: projected {pct:.0f}% utilization by expiry.")

print("\n==> Balances shown here are derived from Cost Explorer, not the credit ledger.")
print("==> Confirm against Billing console -> Credits (no API exists for the real balance).")
PY
