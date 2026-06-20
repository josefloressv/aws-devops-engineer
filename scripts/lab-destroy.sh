#!/usr/bin/env bash
# Delete a single scenario stack.
# Usage: scripts/lab-destroy.sh <domain-folder>/<scenario-slug>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <domain-folder>/<scenario-slug>" >&2; exit 1; }
parse_lab_path "$1"

echo "==> Deleting stack $STACK_NAME"
aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$STACK_NAME"
aws cloudformation wait stack-delete-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"
rm -f "${LAB_DIR}/.lastchangeset"
echo "==> Deleted $STACK_NAME"
