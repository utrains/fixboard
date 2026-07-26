#!/usr/bin/env bash
#
# setup-platform.sh — automates Ridgeline Cloud's "FixBoard Platform Setup"
# guide (Doc1): EKS cluster + every AWS-managed service the app needs
# before deployment. Covers Doc1 Phases 1-6, in order. Does NOT touch
# anything FixBoard-specific (namespace, secrets, deployments) — that's
# Doc2's job, run manually or via a separate script once this one's
# Phase 7 checklist is green.
#
# This script is the "run it quickly" path. Read Doc1 first — it explains
# *why* each step exists. This script just re-runs the *what*.
set -euo pipefail
shopt -s inherit_errexit

ERR_TRAP='echo; echo "==> FAILED at line ${LINENO}. Aborting — nothing past this point ran." >&2'
trap "$ERR_TRAP" ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configurable values — all overridable via environment variables. Defaults
# match Doc1 exactly.
# ---------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-ridgeline-fixboard}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_VERSION="${EKS_VERSION:-1.31}"
NODEGROUP_NAME="${NODEGROUP_NAME:-fixboard-workers}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODES="${NODES:-2}"
NODES_MIN="${NODES_MIN:-2}"
NODES_MAX="${NODES_MAX:-4}"

BACKEND_ECR_REPO="${BACKEND_ECR_REPO:-fixboard-backend}"
FRONTEND_ECR_REPO="${FRONTEND_ECR_REPO:-fixboard-frontend}"

ALB_POLICY_NAME="${ALB_POLICY_NAME:-AWSLoadBalancerControllerIAMPolicy}"
ALB_IAM_POLICY_URL="${ALB_IAM_POLICY_URL:-https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.0/docs/install/iam_policy.json}"
ALB_SA_NAME="${ALB_SA_NAME:-aws-load-balancer-controller}"

EFS_SG_NAME="${EFS_SG_NAME:-EFS-SG}"
EFS_CREATION_TOKEN="${EFS_CREATION_TOKEN:-fixboard-efs}"
EFS_NAME_TAG="${EFS_NAME_TAG:-FixBoard-EFS}"
EFS_CSI_SA_NAME="${EFS_CSI_SA_NAME:-efs-csi-controller-sa}"
EFS_STORAGECLASS_NAME="${EFS_STORAGECLASS_NAME:-efs-sc}"
EFS_DIRECTORY_PERMS="${EFS_DIRECTORY_PERMS:-700}"

RDS_DB_IDENTIFIER="${RDS_DB_IDENTIFIER:-fixboard-db}"
RDS_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t3.micro}"
RDS_ENGINE_VERSION="${RDS_ENGINE_VERSION:-16}"
RDS_ALLOCATED_STORAGE="${RDS_ALLOCATED_STORAGE:-20}"
RDS_MASTER_USERNAME="${RDS_MASTER_USERNAME:-fixboard}"
RDS_SUBNET_GROUP_NAME="${RDS_SUBNET_GROUP_NAME:-fixboard-db-subnet-group}"
RDS_SG_NAME="${RDS_SG_NAME:-FixBoard-RDS-SG}"
# No default on purpose — a checked-in database password is a real
# security issue, not a convenience. Required; validated in preflight.
RDS_MASTER_PASSWORD="${RDS_MASTER_PASSWORD:-}"

CONFIG_FILE_NAME="${CONFIG_FILE_NAME:-platform-config.env}"
CONFIG_FILE="${PROJECT_ROOT}/${CONFIG_FILE_NAME}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_phase() { echo; echo "=== Phase $1 -- $2 ==="; }
log_step()  { echo "--> $1"; }
log_info()  { echo "    $1"; }

# ===========================================================================
# Phase 0 — Preflight (assumed by Doc1's Phase 1 intro, not a numbered
# phase there, but the script needs to fail loudly here rather than deep
# into a partially-provisioned cluster)
# ===========================================================================
log_phase 0 "Preflight checks"

for tool in aws eksctl kubectl helm curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found in PATH." >&2
    exit 1
  fi
done
log_info "aws, eksctl, kubectl, helm, curl all present."

if [[ -z "$RDS_MASTER_PASSWORD" ]]; then
  echo "ERROR: RDS_MASTER_PASSWORD must be set (export it before running this script)." >&2
  echo "It becomes the PostgreSQL master password for the '${RDS_DB_IDENTIFIER}' RDS" >&2
  echo "instance in Phase 6. There is no default — checking in a database password" >&2
  echo "would be a real security issue, not a convenience. Checked here, before Phase 1," >&2
  echo "so a missing password fails immediately rather than after ~20 minutes of cluster" >&2
  echo "creation." >&2
  exit 1
fi
log_info "RDS_MASTER_PASSWORD is set."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
log_info "AWS account: ${ACCOUNT_ID}"
log_info "Region: ${AWS_REGION}"

# ===========================================================================
# Phase 1 — Provision the EKS Cluster
# ===========================================================================
log_phase 1 "Provision the EKS Cluster"

log_step "1.1 Create the cluster"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  log_info "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --version "$EKS_VERSION" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --node-type "$NODE_TYPE" \
    --nodes "$NODES" \
    --nodes-min "$NODES_MIN" \
    --nodes-max "$NODES_MAX" \
    --managed
fi

log_step "1.2 Wait for the cluster and nodegroup to be ready"
# Runs unconditionally, even on the skip branch above — same "resume
# correctly after an interrupted run" shape as the RDS wait in Phase 6.4.
# describe-cluster succeeds for CREATING/UPDATING/FAILED states too, not
# just ACTIVE, so "already exists" alone doesn't mean "ready" — without
# this, a re-run after the ~20-minute create got interrupted would skip
# straight to kubectl calls against a cluster/nodegroup that isn't up yet.
aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$AWS_REGION"
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" --region "$AWS_REGION"

log_step "1.3 Verify"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
kubectl get nodes

# ===========================================================================
# Phase 2 — IAM for Service Accounts (IRSA)
# ===========================================================================
log_phase 2 "IAM for Service Accounts (IRSA)"

log_step "2.1 Associate an IAM OIDC provider"
# Safely re-runnable on its own — eksctl reports "already exists" and exits 0.
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

# ---------------------------------------------------------------------------
# Shared helper: create an IRSA service account only if it isn't already
# backed by a CloudFormation stack (eksctl errors on a true re-create,
# regardless of --override-existing-serviceaccounts — that flag only
# affects the Kubernetes ServiceAccount object, not the CFN stack).
# ---------------------------------------------------------------------------
create_iamserviceaccount_if_missing() {
  local name="$1" namespace="$2" policy_arn="$3"
  shift 3
  local extra_args=("$@")

  if eksctl get iamserviceaccount \
      --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --namespace "$namespace" 2>/dev/null \
      | grep -qw "$name"; then
    log_info "IAM service account ${namespace}/${name} already exists — skipping."
  else
    eksctl create iamserviceaccount \
      --cluster "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --namespace "$namespace" \
      --name "$name" \
      --attach-policy-arn "$policy_arn" \
      --approve \
      "${extra_args[@]}"
  fi
}

# ===========================================================================
# Phase 3 — Container Registries (Amazon ECR)
# ===========================================================================
log_phase 3 "Container Registries (Amazon ECR)"

log_step "3.1 Create the repositories"
for repo in "$BACKEND_ECR_REPO" "$FRONTEND_ECR_REPO"; do
  if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    log_info "ECR repository '${repo}' already exists — skipping."
  else
    aws ecr create-repository \
      --repository-name "$repo" \
      --region "$AWS_REGION" \
      --image-scanning-configuration scanOnPush=true >/dev/null
    log_info "Created ECR repository '${repo}'."
  fi
done

log_step "3.2 Note the registry URI"
REGISTRY_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
BACKEND_ECR_URI="${REGISTRY_URI}/${BACKEND_ECR_REPO}"
FRONTEND_ECR_URI="${REGISTRY_URI}/${FRONTEND_ECR_REPO}"
log_info "Registry: ${REGISTRY_URI}"

log_step "3.3 Verify"
aws ecr describe-repositories --region "$AWS_REGION" --query "repositories[].repositoryName" --output text

# ===========================================================================
# Phase 4 — AWS Load Balancer Controller
# ===========================================================================
log_phase 4 "AWS Load Balancer Controller"

log_step "4.1 Create the IAM policy"
ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_POLICY_NAME}"
if aws iam get-policy --policy-arn "$ALB_POLICY_ARN" >/dev/null 2>&1; then
  log_info "IAM policy '${ALB_POLICY_NAME}' already exists — skipping."
else
  IAM_POLICY_FILE="${PROJECT_ROOT}/iam_policy.json"
  curl -sSL -o "$IAM_POLICY_FILE" "$ALB_IAM_POLICY_URL"
  aws iam create-policy \
    --policy-name "$ALB_POLICY_NAME" \
    --policy-document "file://${IAM_POLICY_FILE}" >/dev/null
  log_info "Created IAM policy '${ALB_POLICY_NAME}'."
fi

log_step "4.2 Create the IAM service account"
create_iamserviceaccount_if_missing \
  "$ALB_SA_NAME" "kube-system" "$ALB_POLICY_ARN" \
  --override-existing-serviceaccounts

log_step "4.3 Install via Helm"
helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$ALB_SA_NAME" \
  --wait

log_step "4.4 Verify"
kubectl get pods -n kube-system | grep aws-load-balancer

# ===========================================================================
# Phase 5 — Amazon EFS for Shared Storage
# ===========================================================================
log_phase 5 "Amazon EFS for Shared Storage"

log_step "5.1 Look up cluster networking"
VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)"
SUBNET_IDS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text | tr '\t' '\n')"
# Doc1 flags this exact lookup as prone to returning multiple/duplicate
# values across the nodegroup's instances — dedupe to a single SG.
EKS_NODE_SG="$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=${NODEGROUP_NAME}" \
  --query "Reservations[].Instances[].SecurityGroups[].GroupId" \
  --output text --region "$AWS_REGION" | tr '\t' '\n' | sort -u | head -n1)"

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "ERROR: could not determine the cluster's VPC ID." >&2
  exit 1
fi
if [[ -z "$SUBNET_IDS" ]]; then
  echo "ERROR: could not determine the cluster's subnet IDs." >&2
  exit 1
fi
if [[ -z "$EKS_NODE_SG" ]]; then
  echo "ERROR: could not determine the node security group for nodegroup '${NODEGROUP_NAME}'." >&2
  exit 1
fi
log_info "VPC: ${VPC_ID}"
log_info "Node security group: ${EKS_NODE_SG}"

log_step "5.2 Create a security group for EFS"
SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${EFS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)"
if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
  log_info "Security group '${EFS_SG_NAME}' already exists (${SG_ID}) — skipping."
else
  SG_ID="$(aws ec2 create-security-group \
    --group-name "$EFS_SG_NAME" \
    --description "EFS for EKS" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$AWS_REGION")"
  log_info "Created security group '${EFS_SG_NAME}' (${SG_ID})."
fi

log_step "5.3 Allow NFS traffic from nodes"
# set +e alone does not stop the ERR trap from firing on a non-zero command —
# only from making the shell exit — so the trap is disabled here too, or the
# expected/handled "already exists" case below would still print a bogus
# "FAILED" message.
trap - ERR
set +e
INGRESS_OUTPUT="$(aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 2049 \
  --source-group "$EKS_NODE_SG" \
  --region "$AWS_REGION" 2>&1)"
INGRESS_STATUS=$?
set -e
trap "$ERR_TRAP" ERR
if [[ $INGRESS_STATUS -ne 0 ]]; then
  if echo "$INGRESS_OUTPUT" | grep -q "InvalidPermission.Duplicate"; then
    log_info "NFS ingress rule already present — skipping."
  else
    echo "$INGRESS_OUTPUT" >&2
    exit 1
  fi
fi

log_step "5.4 Create the filesystem and mount targets"
# --creation-token idempotency only covers AWS retrying the same in-flight
# request; once a filesystem with this token has actually finished being
# created, a repeat create-file-system call errors with FileSystemAlreadyExists
# instead of returning the existing filesystem — so check first, like every
# other resource in this script.
EFS_ID="$(aws efs describe-file-systems --creation-token "$EFS_CREATION_TOKEN" --region "$AWS_REGION" \
  --query "FileSystems[0].FileSystemId" --output text 2>/dev/null || true)"
if [[ -n "$EFS_ID" && "$EFS_ID" != "None" ]]; then
  log_info "EFS filesystem with creation token '${EFS_CREATION_TOKEN}' already exists (${EFS_ID}) — skipping."
else
  EFS_ID="$(aws efs create-file-system \
    --creation-token "$EFS_CREATION_TOKEN" \
    --tags "Key=Name,Value=${EFS_NAME_TAG}" \
    --output text --query "FileSystemId" --region "$AWS_REGION")"
  log_info "Created EFS filesystem: ${EFS_ID}"
fi

# A freshly created filesystem starts in "creating" state; create-mount-target
# fails with IncorrectFileSystemLifeCycleState until it flips to "available".
# The AWS CLI has no waiter for EFS, so poll manually. Runs unconditionally
# (not just on first creation) since a re-run could still land here moments
# after create-file-system returned on a previous invocation.
EFS_STATE=""
for _ in $(seq 1 60); do
  EFS_STATE="$(aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query "FileSystems[0].LifeCycleState" --output text)"
  [[ "$EFS_STATE" == "available" ]] && break
  sleep 5
done
if [[ "$EFS_STATE" != "available" ]]; then
  echo "ERROR: EFS filesystem '${EFS_ID}' did not reach 'available' in time (last state: ${EFS_STATE})." >&2
  exit 1
fi

EXISTING_MT_SUBNETS="$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
  --query "MountTargets[].SubnetId" --output text 2>/dev/null || true)"

for subnet in $SUBNET_IDS; do
  if echo "$EXISTING_MT_SUBNETS" | grep -qw "$subnet"; then
    log_info "Mount target for ${subnet} already exists — skipping."
    continue
  fi
  trap - ERR
  set +e
  MT_OUTPUT="$(aws efs create-mount-target \
    --file-system-id "$EFS_ID" \
    --subnet-id "$subnet" \
    --security-groups "$SG_ID" \
    --region "$AWS_REGION" 2>&1)"
  MT_STATUS=$?
  set -e
  trap "$ERR_TRAP" ERR
  if [[ $MT_STATUS -ne 0 ]]; then
    # A filesystem gets one mount target per AZ, not per subnet — if the
    # VPC has multiple subnets in the same AZ, this is expected, not a
    # real failure.
    if echo "$MT_OUTPUT" | grep -q "MountTargetConflict"; then
      log_info "Mount target already covers ${subnet}'s Availability Zone — skipping."
    else
      echo "$MT_OUTPUT" >&2
      exit 1
    fi
  fi
done

log_step "5.5 Install the EFS CSI driver"
create_iamserviceaccount_if_missing \
  "$EFS_CSI_SA_NAME" "kube-system" "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"

helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name="$EFS_CSI_SA_NAME" \
  --wait

log_step "5.6 Create the StorageClass"
EFS_STORAGECLASS_FILE="${PROJECT_ROOT}/storage-class-efs.yaml"
cat > "$EFS_STORAGECLASS_FILE" <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${EFS_STORAGECLASS_NAME}
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "${EFS_DIRECTORY_PERMS}"
YAML
kubectl apply -f "$EFS_STORAGECLASS_FILE"

log_step "5.7 Verify"
aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
  --query "MountTargets[].LifeCycleState" --output text
kubectl get pods -n kube-system | grep efs-csi
kubectl get storageclass "$EFS_STORAGECLASS_NAME"

# ===========================================================================
# Phase 6 — Amazon RDS (PostgreSQL)
# ===========================================================================
log_phase 6 "Amazon RDS (PostgreSQL)"

log_step "6.1 Create a DB subnet group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  log_info "DB subnet group '${RDS_SUBNET_GROUP_NAME}' already exists — skipping."
else
  # Deliberately unquoted: --subnet-ids takes each subnet as a separate
  # argument, and SUBNET_IDS is a newline-separated list (same convention
  # already used by the `for subnet in $SUBNET_IDS` loop in Phase 5).
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnets for FixBoard RDS instance" \
    --subnet-ids $SUBNET_IDS \
    --region "$AWS_REGION" >/dev/null
  log_info "Created DB subnet group '${RDS_SUBNET_GROUP_NAME}'."
fi

log_step "6.2 Create a security group for RDS"
RDS_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${RDS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)"
if [[ -n "$RDS_SG_ID" && "$RDS_SG_ID" != "None" ]]; then
  log_info "Security group '${RDS_SG_NAME}' already exists (${RDS_SG_ID}) — skipping."
else
  RDS_SG_ID="$(aws ec2 create-security-group \
    --group-name "$RDS_SG_NAME" \
    --description "RDS access for FixBoard backend" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$AWS_REGION")"
  log_info "Created security group '${RDS_SG_NAME}' (${RDS_SG_ID})."
fi

trap - ERR
set +e
RDS_INGRESS_OUTPUT="$(aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp --port 5432 \
  --source-group "$EKS_NODE_SG" \
  --region "$AWS_REGION" 2>&1)"
RDS_INGRESS_STATUS=$?
set -e
trap "$ERR_TRAP" ERR
if [[ $RDS_INGRESS_STATUS -ne 0 ]]; then
  if echo "$RDS_INGRESS_OUTPUT" | grep -q "InvalidPermission.Duplicate"; then
    log_info "PostgreSQL ingress rule already present — skipping."
  else
    echo "$RDS_INGRESS_OUTPUT" >&2
    exit 1
  fi
fi

log_step "6.3 Create the RDS instance"
if aws rds describe-db-instances --db-instance-identifier "$RDS_DB_IDENTIFIER" --region "$AWS_REGION" >/dev/null 2>&1; then
  log_info "RDS instance '${RDS_DB_IDENTIFIER}' already exists — skipping creation."
else
  aws rds create-db-instance \
    --db-instance-identifier "$RDS_DB_IDENTIFIER" \
    --db-instance-class "$RDS_INSTANCE_CLASS" \
    --engine postgres \
    --engine-version "$RDS_ENGINE_VERSION" \
    --master-username "$RDS_MASTER_USERNAME" \
    --master-user-password "$RDS_MASTER_PASSWORD" \
    --allocated-storage "$RDS_ALLOCATED_STORAGE" \
    --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" \
    --vpc-security-group-ids "$RDS_SG_ID" \
    --no-multi-az \
    --no-publicly-accessible \
    --region "$AWS_REGION" >/dev/null
  log_info "RDS instance '${RDS_DB_IDENTIFIER}' creation requested — this takes several minutes."
fi

log_step "6.4 Wait for it and get the database endpoint"
# Runs regardless of whether the instance was just created or already
# existed — safe/idempotent, and resumes correctly if a previous run
# created the instance but died before capturing the endpoint.
aws rds wait db-instance-available --db-instance-identifier "$RDS_DB_IDENTIFIER" --region "$AWS_REGION"
RDS_ENDPOINT="$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_DB_IDENTIFIER" \
  --query "DBInstances[0].Endpoint.Address" --output text --region "$AWS_REGION")"
log_info "RDS endpoint: ${RDS_ENDPOINT}"

log_step "6.5 Verify"
aws rds describe-db-instances --db-instance-identifier "$RDS_DB_IDENTIFIER" \
  --query "DBInstances[0].DBInstanceStatus" --region "$AWS_REGION"

# ===========================================================================
# Write platform-config.env — every derived value a later step needs, so
# nothing requires copy-pasting an ID out of terminal output.
# ===========================================================================
echo
echo "=== Writing ${CONFIG_FILE} ==="

cat > "$CONFIG_FILE" <<ENV
# Generated by scripts/setup-platform.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# source this file to reuse these values in later scripts.
AWS_ACCOUNT_ID=${ACCOUNT_ID}
AWS_REGION=${AWS_REGION}
CLUSTER_NAME=${CLUSTER_NAME}

VPC_ID=${VPC_ID}
SUBNET_IDS=$(echo "$SUBNET_IDS" | tr '\n' ',' | sed 's/,$//')
EKS_NODE_SECURITY_GROUP_ID=${EKS_NODE_SG}

EFS_FILESYSTEM_ID=${EFS_ID}
EFS_SECURITY_GROUP_ID=${SG_ID}
EFS_STORAGECLASS_NAME=${EFS_STORAGECLASS_NAME}

RDS_DB_IDENTIFIER=${RDS_DB_IDENTIFIER}
RDS_ENDPOINT=${RDS_ENDPOINT}
RDS_SUBNET_GROUP_NAME=${RDS_SUBNET_GROUP_NAME}
RDS_SECURITY_GROUP_ID=${RDS_SG_ID}

ECR_REGISTRY_URI=${REGISTRY_URI}
BACKEND_ECR_REPO=${BACKEND_ECR_REPO}
BACKEND_ECR_URI=${BACKEND_ECR_URI}
FRONTEND_ECR_REPO=${FRONTEND_ECR_REPO}
FRONTEND_ECR_URI=${FRONTEND_ECR_URI}
ENV

log_info "Wrote ${CONFIG_FILE}"

# ===========================================================================
# Phase 7 — Platform Readiness (reproduced here as a summary, not a gate —
# every check above already ran inline)
# ===========================================================================
echo
echo "=== Platform Ready ==="
echo "Every dependency the Application Deployment Guide's Prerequisites"
echo "section lists is now satisfied. Continue there."
