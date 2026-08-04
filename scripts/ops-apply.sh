#!/usr/bin/env bash
# Validate, plan, and apply an ops/ template in one step. Same auto-apply
# behaviour as base-apply.sh, but ops/ stacks are account-level tooling rather
# than lab building blocks, and they target the organization's payer account
# (PAYER_ACCOUNT_ID in .env.local) instead of the sandbox -- so this script
# requires an explicit profile and never falls back to ambient credentials.
#
# Usage: scripts/ops-apply.sh <credit-monitor> [Key=Value ...]
#        AWS_PROFILE=other-profile scripts/ops-apply.sh credit-monitor
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -ge 1 ] || { echo "Usage: $0 <credit-monitor> [Key=Value ...]" >&2; exit 1; }
NAME="$1"
shift

export AWS_PROFILE="${AWS_PROFILE:-$PAYER_PROFILE_DEFAULT}"

PARAM_OVERRIDES=()
for kv in "$@"; do
  PARAM_OVERRIDES+=("ParameterKey=${kv%%=*},ParameterValue=${kv#*=}")
done

TEMPLATE_FILE="ops/${NAME}/template.yaml"
[ -f "$TEMPLATE_FILE" ] || { echo "Error: $TEMPLATE_FILE not found" >&2; exit 1; }
STACK_NAME="dop-ops-${NAME}"

require_payer_account

echo "==> Validating $TEMPLATE_FILE"
aws cloudformation validate-template --region "$AWS_REGION" --template-body "file://${TEMPLATE_FILE}" >/dev/null

if command -v cfn-lint >/dev/null 2>&1; then
  echo "==> Running cfn-lint"
  cfn-lint "$TEMPLATE_FILE"
else
  echo "==> cfn-lint not installed, skipping"
fi

COST_HIT=0
cost_flag_check "$TEMPLATE_FILE" || COST_HIT=1

EXTRA_ARGS=(--tags "Key=Project,Value=${PROJECT_TAG}" "Key=Domain,Value=ops" "Key=Scenario,Value=${NAME}")
if [ ${#PARAM_OVERRIDES[@]} -gt 0 ]; then
  EXTRA_ARGS+=(--parameters "${PARAM_OVERRIDES[@]}")
fi

if ! create_changeset "$STACK_NAME" "$TEMPLATE_FILE" "${EXTRA_ARGS[@]}"; then
  exit 0
fi

if [ "$COST_HIT" -eq 1 ]; then
  echo "$CHANGESET_NAME" > "ops/${NAME}/.lastchangeset"
  echo
  echo "Non-trivial-cost resource detected -- stopping for manual review instead of auto-applying."
  echo "Review the diff above, then execute the saved change set manually."
  exit 0
fi

echo "==> No cost flags -- applying immediately"
execute_changeset "$STACK_NAME" "$CHANGESET_NAME"
