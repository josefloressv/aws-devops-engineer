#!/usr/bin/env bash
# Validate, plan, and apply a base/ template in one step. Executes the
# change set immediately unless the template provisions a non-trivial-cost
# resource type, in which case it stops after the diff for manual review
# (run `make base-deploy` to apply after reviewing).
# Usage: scripts/base-apply.sh <network|iam-baseline|logging-baseline> [Key=Value ...]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -ge 1 ] || { echo "Usage: $0 <network|iam-baseline|logging-baseline> [Key=Value ...]" >&2; exit 1; }
NAME="$1"
shift
PARAM_OVERRIDES=()
for kv in "$@"; do
  PARAM_OVERRIDES+=("ParameterKey=${kv%%=*},ParameterValue=${kv#*=}")
done

TEMPLATE_FILE="base/${NAME}/template.yaml"
[ -f "$TEMPLATE_FILE" ] || { echo "Error: $TEMPLATE_FILE not found" >&2; exit 1; }
STACK_NAME="dop-lab-base-${NAME}"

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

EXTRA_ARGS=(--tags "Key=Project,Value=${PROJECT_TAG}" "Key=Domain,Value=base" "Key=Scenario,Value=${NAME}")
if [ ${#PARAM_OVERRIDES[@]} -gt 0 ]; then
  EXTRA_ARGS+=(--parameters "${PARAM_OVERRIDES[@]}")
fi

if ! create_changeset "$STACK_NAME" "$TEMPLATE_FILE" "${EXTRA_ARGS[@]}"; then
  exit 0
fi

if [ "$COST_HIT" -eq 1 ]; then
  mkdir -p "base/${NAME}"
  echo "$CHANGESET_NAME" > "base/${NAME}/.lastchangeset"
  echo
  echo "Non-trivial-cost resource detected -- stopping for manual review instead of auto-applying."
  echo "Review the diff above, then: make base-deploy NAME=${NAME}"
  exit 0
fi

echo "==> No cost flags -- applying immediately"
execute_changeset "$STACK_NAME" "$CHANGESET_NAME"
