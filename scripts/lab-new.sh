#!/usr/bin/env bash
# Scaffold a new scenario folder from templates/scenario-skeleton.
# Usage: scripts/lab-new.sh <domain-folder> <scenario-slug>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "scripts/lib.sh"

usage() {
  echo "Usage: $0 <domain-folder> <scenario-slug>" >&2
  echo "Example: $0 domain-6-security iam-boundary-vs-scp" >&2
  exit 1
}

[ $# -eq 2 ] || usage
DOMAIN_FOLDER="$1"
SCENARIO_SLUG="$2"

# Validates the domain folder name; exits if unknown.
ABBREV="$(domain_abbrev "$DOMAIN_FOLDER")"
STACK_NAME="dop-lab-${ABBREV}-${SCENARIO_SLUG}"

LAB_DIR="scenarios/${DOMAIN_FOLDER}/${SCENARIO_SLUG}"
if [ -d "$LAB_DIR" ]; then
  echo "Error: $LAB_DIR already exists" >&2
  exit 1
fi

mkdir -p "$LAB_DIR"

for f in template.yaml params.json README.md; do
  sed -e "s/{{SCENARIO_SLUG}}/${SCENARIO_SLUG}/g" \
      -e "s/{{STACK_NAME}}/${STACK_NAME}/g" \
      -e "s/{{DOMAIN_FOLDER}}/${DOMAIN_FOLDER}/g" \
      "templates/scenario-skeleton/$f" > "$LAB_DIR/$f"
done

echo "Created $LAB_DIR (stack name: $STACK_NAME)"
echo "Next: edit $LAB_DIR/template.yaml and $LAB_DIR/params.json, then:"
echo "  make plan LAB=${DOMAIN_FOLDER}/${SCENARIO_SLUG}"
