#!/usr/bin/env bash
# Delete every scenario stack tagged Project=dop-c02-lab, leaving base stacks intact.
# Usage: scripts/lab-destroy-all.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

echo "==> Finding stacks tagged Project=${PROJECT_TAG} (excluding base stacks)"
STACKS="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
  --query "Stacks[?Tags[?Key=='Project' && Value=='${PROJECT_TAG}']].StackName" \
  --output text)"

TO_DELETE=()
for stack in $STACKS; do
  case "$stack" in
    dop-lab-base-*) continue ;;
    *) TO_DELETE+=("$stack") ;;
  esac
done

if [ ${#TO_DELETE[@]} -eq 0 ]; then
  echo "==> No scenario stacks found."
  exit 0
fi

for stack in "${TO_DELETE[@]}"; do
  echo "==> Deleting $stack"
  aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$stack"
done

for stack in "${TO_DELETE[@]}"; do
  aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$stack"
  echo "==> Deleted $stack"
done

echo "==> Done. Base stacks (dop-lab-base-*) were left intact; run 'make base-destroy-all' separately."
