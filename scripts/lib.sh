#!/usr/bin/env bash
# Shared helpers for scripts/lab-*.sh and scripts/base-*.sh.
# shellcheck disable=SC2034

PROJECT_TAG="dop-c02-lab"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Resource types worth a cost warning before deploying.
COST_FLAG_PATTERN='AWS::EC2::NatGateway|AWS::RDS::|AWS::EKS::Cluster|AWS::ElastiCache::|AWS::Redshift::|AWS::OpenSearchService::|AWS::Elasticsearch::|AWS::MSK::|AWS::EC2::TransitGateway|AWS::GlobalAccelerator::|AWS::DirectConnect::'

domain_abbrev() {
  case "$1" in
    domain-1-sdlc) echo "d1" ;;
    domain-2-config-iac) echo "d2" ;;
    domain-3-resilient) echo "d3" ;;
    domain-4-monitoring) echo "d4" ;;
    domain-5-incident) echo "d5" ;;
    domain-6-security) echo "d6" ;;
    *)
      echo "Unknown domain folder: $1 (expected scenarios/domain-N-*)" >&2
      exit 1
      ;;
  esac
}

# Splits "domain-folder/scenario-slug" into globals: LAB_DIR, TEMPLATE_FILE,
# PARAMS_FILE, STACK_NAME, DOMAIN_NUM, DOMAIN_FOLDER, SCENARIO_SLUG.
parse_lab_path() {
  local lab="$1"
  DOMAIN_FOLDER="$(dirname "$lab")"
  SCENARIO_SLUG="$(basename "$lab")"
  LAB_DIR="scenarios/${DOMAIN_FOLDER}/${SCENARIO_SLUG}"
  TEMPLATE_FILE="${LAB_DIR}/template.yaml"
  PARAMS_FILE="${LAB_DIR}/params.json"
  DOMAIN_NUM="$(echo "$DOMAIN_FOLDER" | sed -E 's/^domain-([0-9]+).*/\1/')"
  local abbrev
  abbrev="$(domain_abbrev "$DOMAIN_FOLDER")"
  STACK_NAME="dop-lab-${abbrev}-${SCENARIO_SLUG}"
}

# Prints a warning and returns 1 if the template provisions a resource type
# worth a cost flag. Callers that want this to be non-fatal must guard the
# call (e.g. `cost_flag_check "$f" || true`); apply scripts use the return
# value to decide whether to pause instead of auto-executing.
cost_flag_check() {
  local template="$1"
  if grep -E -q "$COST_FLAG_PATTERN" "$template"; then
    echo "!! COST WARNING: $template provisions a non-trivial-cost resource type:" >&2
    grep -E -o "$COST_FLAG_PATTERN" "$template" | sort -u >&2
    return 1
  fi
  return 0
}

# Echoes CREATE if the stack doesn't exist yet (or is stuck in
# REVIEW_IN_PROGRESS from an abandoned first change set), else UPDATE.
# Required by `create-change-set --change-set-type`. Exits with a clear
# message if the stack is in ROLLBACK_COMPLETE, since CloudFormation refuses
# an UPDATE change set against that status -- it must be deleted first.
changeset_type_for() {
  local stack="$1"
  local status
  status="$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "")"
  if [ -z "$status" ] || [ "$status" = "REVIEW_IN_PROGRESS" ]; then
    echo "CREATE"
  elif [ "$status" = "ROLLBACK_COMPLETE" ]; then
    echo "Stack $stack is in ROLLBACK_COMPLETE (its first create failed). Delete it before retrying:" >&2
    echo "  aws cloudformation delete-stack --region $AWS_REGION --stack-name $stack" >&2
    echo "  aws cloudformation wait stack-delete-complete --region $AWS_REGION --stack-name $stack" >&2
    exit 1
  else
    echo "UPDATE"
  fi
}

# Polls describe-stacks until the stack status stops ending in _IN_PROGRESS,
# then echoes the final status.
wait_stack_settled() {
  local stack="$1"
  local status
  while true; do
    status="$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DELETE_COMPLETE")"
    case "$status" in
      *IN_PROGRESS) sleep 5 ;;
      *) echo "$status"; return 0 ;;
    esac
  done
}

# Creates a change set and waits for it to finish computing, then prints the
# diff. Sets CHANGESET_NAME as a side effect. $1=stack name, $2=template
# file, all remaining args are passed through to `create-change-set` as-is
# (--tags, --parameters, etc). Returns 1 (after deleting the empty change
# set) if the template produced no changes; exits 1 on a real failure.
create_changeset() {
  local stack="$1" template="$2"
  shift 2
  CHANGESET_NAME="cs-$(date +%s)"
  local changeset_type
  changeset_type="$(changeset_type_for "$stack")"

  echo "==> Creating $changeset_type change set $CHANGESET_NAME for stack $stack"
  aws cloudformation create-change-set \
    --region "$AWS_REGION" \
    --stack-name "$stack" \
    --change-set-name "$CHANGESET_NAME" \
    --change-set-type "$changeset_type" \
    --template-body "file://${template}" \
    --capabilities CAPABILITY_IAM \
    "$@" >/dev/null

  echo "==> Waiting for change set to finish computing..."
  if ! aws cloudformation wait change-set-create-complete --region "$AWS_REGION" --stack-name "$stack" --change-set-name "$CHANGESET_NAME"; then
    local reason
    reason="$(aws cloudformation describe-change-set --region "$AWS_REGION" --stack-name "$stack" --change-set-name "$CHANGESET_NAME" --query 'StatusReason' --output text)"
    if [[ "$reason" == *"didn't contain changes"* ]]; then
      echo "==> No changes to deploy: $reason"
      aws cloudformation delete-change-set --region "$AWS_REGION" --stack-name "$stack" --change-set-name "$CHANGESET_NAME" >/dev/null
      return 1
    fi
    echo "Change set failed: $reason" >&2
    exit 1
  fi

  echo "==> Change set diff:"
  aws cloudformation describe-change-set \
    --region "$AWS_REGION" --stack-name "$stack" --change-set-name "$CHANGESET_NAME" \
    --query 'Changes[].ResourceChange.{Action:Action,Resource:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
    --output table
}

# Executes a change set by name, waits for the stack to settle, and prints
# outputs on success. Exits 1 unless the stack lands in CREATE_COMPLETE or
# UPDATE_COMPLETE -- ROLLBACK_COMPLETE/UPDATE_ROLLBACK_COMPLETE also match a
# bare `*COMPLETE` glob, so they must be excluded explicitly or a failed
# deploy gets reported as a success.
execute_changeset() {
  local stack="$1" changeset_name="$2"
  echo "==> Executing change set $changeset_name on $stack"
  aws cloudformation execute-change-set --region "$AWS_REGION" --stack-name "$stack" --change-set-name "$changeset_name"

  echo "==> Waiting for stack to settle..."
  local status
  status="$(wait_stack_settled "$stack")"
  echo "==> Stack status: $status"

  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      echo "==> Outputs:"
      aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" --query 'Stacks[0].Outputs' --output table
      ;;
    *)
      echo "Stack did not complete successfully (status: $status), check the console/CLI events for $stack." >&2
      exit 1
      ;;
  esac
}
