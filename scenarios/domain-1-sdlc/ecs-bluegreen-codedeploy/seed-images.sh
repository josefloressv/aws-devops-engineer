#!/usr/bin/env bash
# Seed the ECR repository with the :blue and :green images the blue/green
# scenario deploys.
#
# The images are built inside CodeBuild (privilegedMode) rather than locally, so
# no Docker daemon is needed on the workstation. The CodeBuild project and its
# IAM role are created here and deleted at the end -- only the ECR repository and
# the two images survive, because the EKS scenario reuses the same repository.
#
# Source is the CodeCommit mirror of the application repository, so the image is
# built from the committed docker/Dockerfile rather than from an inline copy.
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
REPO_NAME="${REPO_NAME:-dop-c02-lab}"
SOURCE_REPO="${SOURCE_REPO:-dop-c02-sdlc}"
PROJECT="dop-c02-image-seeder"
ROLE="dop-c02-image-seeder-role"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

cleanup() {
  echo "==> Cleaning up the seeder project and role"
  aws codebuild delete-project --name "$PROJECT" >/dev/null 2>&1 || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name inline >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Ensuring ECR repository $REPO_NAME exists"
aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$REPO_NAME" \
       --image-scanning-configuration scanOnPush=false \
       --tags Key=Project,Value=dop-c02-lab Key=Domain,Value=1 \
              Key=Scenario,Value=ecs-bluegreen-codedeploy \
       --query 'repository.repositoryUri' --output text

echo "==> Creating the seeder role"
aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }' >/dev/null

aws iam put-role-policy --role-name "$ROLE" --policy-name inline \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",\"Action\":\"ecr:GetAuthorizationToken\",\"Resource\":\"*\"},
      {\"Effect\":\"Allow\",
       \"Action\":[\"ecr:BatchCheckLayerAvailability\",\"ecr:CompleteLayerUpload\",\"ecr:InitiateLayerUpload\",\"ecr:PutImage\",\"ecr:UploadLayerPart\"],
       \"Resource\":\"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${REPO_NAME}\"},
      {\"Effect\":\"Allow\",\"Action\":\"codecommit:GitPull\",\"Resource\":\"arn:aws:codecommit:${REGION}:${ACCOUNT_ID}:${SOURCE_REPO}\"}
    ]
  }" >/dev/null

echo "==> Waiting for the role to propagate to CodeBuild"
sleep 12

BUILDSPEC=$(cat <<SPEC
version: 0.2
phases:
  pre_build:
    commands:
      - aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${REGISTRY}
  build:
    commands:
      - docker build --build-arg COLOR=BLUE  -t ${REGISTRY}/${REPO_NAME}:blue  docker/
      - docker build --build-arg COLOR=GREEN -t ${REGISTRY}/${REPO_NAME}:green docker/
  post_build:
    commands:
      - docker push ${REGISTRY}/${REPO_NAME}:blue
      - docker push ${REGISTRY}/${REPO_NAME}:green
SPEC
)

echo "==> Creating the seeder CodeBuild project"
aws codebuild create-project --name "$PROJECT" \
  --source "type=CODECOMMIT,location=https://git-codecommit.${REGION}.amazonaws.com/v1/repos/${SOURCE_REPO},buildspec=$BUILDSPEC" \
  --artifacts type=NO_ARTIFACTS \
  --environment "type=LINUX_CONTAINER,image=aws/codebuild/amazonlinux2-x86_64-standard:5.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true" \
  --service-role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}" \
  --query 'project.name' --output text

echo "==> Building and pushing :blue and :green"
BUILD_ID=$(aws codebuild start-build --project-name "$PROJECT" --query 'build.id' --output text)
echo "    build: $BUILD_ID"

while true; do
  STATUS=$(aws codebuild batch-get-builds --ids "$BUILD_ID" --query 'builds[0].buildStatus' --output text)
  [ "$STATUS" != "IN_PROGRESS" ] && break
  sleep 15
done
echo "==> Build finished: $STATUS"

if [ "$STATUS" != "SUCCEEDED" ]; then
  aws codebuild batch-get-builds --ids "$BUILD_ID" \
    --query 'builds[0].phases[?phaseStatus==`FAILED`].{Phase:phaseType,Contexts:contexts}' --output json
  exit 1
fi

echo "==> Images now in $REPO_NAME:"
aws ecr describe-images --repository-name "$REPO_NAME" \
  --query 'sort_by(imageDetails,&imagePushedAt)[].{Tags:imageTags,Pushed:imagePushedAt,MB:imageSizeInBytes}' \
  --output table
