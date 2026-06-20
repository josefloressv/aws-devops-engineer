#!/usr/bin/env bash
# Validate, plan, and apply a scenario template in one step. Executes the
# change set immediately unless the template provisions a non-trivial-cost
# resource type, in which case it stops after the diff for manual review
# (run `make deploy` to apply after reviewing).
# Usage: scripts/lab-apply.sh <domain-folder>/<scenario-slug>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <domain-folder>/<scenario-slug>" >&2; exit 1; }
parse_lab_path "$1"

[ -f "$TEMPLATE_FILE" ] || { echo "Error: $TEMPLATE_FILE not found" >&2; exit 1; }

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

EXTRA_ARGS=(--tags "Key=Project,Value=${PROJECT_TAG}" "Key=Domain,Value=${DOMAIN_NUM}" "Key=Scenario,Value=${SCENARIO_SLUG}")
if [ -s "$PARAMS_FILE" ]; then
  EXTRA_ARGS+=(--parameters "file://${PARAMS_FILE}")
fi

if ! create_changeset "$STACK_NAME" "$TEMPLATE_FILE" "${EXTRA_ARGS[@]}"; then
  exit 0
fi

if [ "$COST_HIT" -eq 1 ]; then
  echo "$CHANGESET_NAME" > "${LAB_DIR}/.lastchangeset"
  echo
  echo "Non-trivial-cost resource detected -- stopping for manual review instead of auto-applying."
  echo "Review the diff above, then: make deploy LAB=$1"
  exit 0
fi

echo "==> No cost flags -- applying immediately"
execute_changeset "$STACK_NAME" "$CHANGESET_NAME"
