#!/usr/bin/env bash
# Delete all base stacks (dop-lab-base-*). Run only after `make destroy-all`,
# since scenario stacks may still hold Fn::ImportValue references to these
# exports (CloudFormation will refuse the delete if so).
# Usage: scripts/base-destroy-all.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

echo "==> Deleting base stacks (dop-lab-base-*)"
echo "==> Make sure scenario stacks are already destroyed (run 'make destroy-all' first)"
echo "==> or this will fail on exports still in use."

NAMES=()
for dir in base/*/; do
  NAMES+=("$(basename "$dir")")
done

for name in "${NAMES[@]}"; do
  stack="dop-lab-base-${name}"
  if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" >/dev/null 2>&1; then
    echo "==> Deleting $stack"
    aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$stack"
  fi
done

for name in "${NAMES[@]}"; do
  stack="dop-lab-base-${name}"
  if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" >/dev/null 2>&1; then
    aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$stack"
    echo "==> Deleted $stack"
  fi
done
