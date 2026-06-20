#!/usr/bin/env bash
# Execute the change set created by scripts/base-plan.sh and print stack outputs.
# Usage: scripts/base-deploy.sh <network|iam-baseline|logging-baseline>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <network|iam-baseline|logging-baseline>" >&2; exit 1; }
NAME="$1"
STACK_NAME="dop-lab-base-${NAME}"
CHANGESET_FILE="base/${NAME}/.lastchangeset"
[ -f "$CHANGESET_FILE" ] || { echo "Error: no pending change set. Run: make base-plan NAME=${NAME}" >&2; exit 1; }
CHANGESET_NAME="$(cat "$CHANGESET_FILE")"

execute_changeset "$STACK_NAME" "$CHANGESET_NAME"
rm -f "$CHANGESET_FILE"
