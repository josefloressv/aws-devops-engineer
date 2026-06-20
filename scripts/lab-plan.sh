#!/usr/bin/env bash
# Validate a scenario template and create (but not execute) its change set.
# Usage: scripts/lab-plan.sh <domain-folder>/<scenario-slug>
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

cost_flag_check "$TEMPLATE_FILE" || true

EXTRA_ARGS=(--tags "Key=Project,Value=${PROJECT_TAG}" "Key=Domain,Value=${DOMAIN_NUM}" "Key=Scenario,Value=${SCENARIO_SLUG}")
if [ -s "$PARAMS_FILE" ]; then
  EXTRA_ARGS+=(--parameters "file://${PARAMS_FILE}")
fi

if create_changeset "$STACK_NAME" "$TEMPLATE_FILE" "${EXTRA_ARGS[@]}"; then
  echo "$CHANGESET_NAME" > "${LAB_DIR}/.lastchangeset"
  echo
  echo "Review the diff above. To apply: make deploy LAB=$1"
fi
