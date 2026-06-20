#!/usr/bin/env bash
# Validate a base/ template and create (but not execute) its change set.
# Usage: scripts/base-plan.sh <network|iam-baseline|logging-baseline> [Key=Value ...]
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

cost_flag_check "$TEMPLATE_FILE" || true

EXTRA_ARGS=(--tags "Key=Project,Value=${PROJECT_TAG}" "Key=Domain,Value=base" "Key=Scenario,Value=${NAME}")
if [ ${#PARAM_OVERRIDES[@]} -gt 0 ]; then
  EXTRA_ARGS+=(--parameters "${PARAM_OVERRIDES[@]}")
fi

if create_changeset "$STACK_NAME" "$TEMPLATE_FILE" "${EXTRA_ARGS[@]}"; then
  mkdir -p "base/${NAME}"
  echo "$CHANGESET_NAME" > "base/${NAME}/.lastchangeset"
  echo
  echo "Review the diff above. To apply: make base-deploy NAME=${NAME}"
fi
