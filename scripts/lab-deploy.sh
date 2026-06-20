#!/usr/bin/env bash
# Execute the change set created by scripts/lab-plan.sh and print stack outputs.
# Usage: scripts/lab-deploy.sh <domain-folder>/<scenario-slug>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

[ $# -eq 1 ] || { echo "Usage: $0 <domain-folder>/<scenario-slug>" >&2; exit 1; }
parse_lab_path "$1"

CHANGESET_FILE="${LAB_DIR}/.lastchangeset"
[ -f "$CHANGESET_FILE" ] || { echo "Error: no pending change set. Run: make plan LAB=$1" >&2; exit 1; }
CHANGESET_NAME="$(cat "$CHANGESET_FILE")"

execute_changeset "$STACK_NAME" "$CHANGESET_NAME"
rm -f "$CHANGESET_FILE"
