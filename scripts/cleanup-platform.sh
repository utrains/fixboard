#!/usr/bin/env bash
#
# cleanup-platform.sh — reverses everything scripts/setup-platform.sh
# creates, matching Doc1 Phase 8 (Infrastructure Teardown). Full
# teardown: EKS cluster, IAM service accounts, EFS, ECR repos, security
# groups — brings the AWS account back to zero cost/zero footprint.
#
# Run Doc2's own Cleanup phase FIRST (delete the fixboard namespace and
# everything in it) — this script checks for that and refuses to run
# otherwise. This script is platform-only, same boundary as
# setup-platform.sh: it never touches FixBoard application resources.
set -euo pipefail
shopt -s inherit_errexit

trap 'echo; echo "==> FAILED at line ${LINENO}. Aborting — nothing past this point ran." >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configurable values — same names/defaults as setup-platform.sh.
# ---------------------------------------------------------------------------
CONFIG_FILE_NAME="${CONFIG_FILE_NAME:-platform-config.env}"
CONFIG_FILE="${PROJECT_ROOT}/${CONFIG_FILE_NAME}"

# ---------------------------------------------------------------------------
# Logging helpers (match setup-platform.sh's style)
# ---------------------------------------------------------------------------
log_step()  { echo "--> $1"; }
log_info()  { echo "    $1"; }

# ---------------------------------------------------------------------------
# Load platform-config.env if present, into CFG_-prefixed variables so it
# can supply resource IDs without silently clobbering an explicit env-var
# override the caller passed in. Precedence: explicit env var > config
# file > re-derive via AWS CLI (same lookups Doc1/setup-platform.sh use).
# ---------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  log_info "Found ${CONFIG_FILE} — will use it for resource IDs where available."
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    declare "CFG_${key}=${value}"
  done < "$CONFIG_FILE"
else
  log_info "${CONFIG_FILE} not found — re-deriving resource IDs via AWS CLI lookups."
fi

CLUSTER_NAME="${CLUSTER_NAME:-${CFG_CLUSTER_NAME:-ridgeline-fixboard}}"
AWS_REGION="${AWS_REGION:-${CFG_AWS_REGION:-us-east-1}}"

BACKEND_ECR_REPO="${BACKEND_ECR_REPO:-${CFG_BACKEND_ECR_REPO:-fixboard-backend}}"
FRONTEND_ECR_REPO="${FRONTEND_ECR_REPO:-${CFG_FRONTEND_ECR_REPO:-fixboard-frontend}}"

EFS_SG_NAME="${EFS_SG_NAME:-EFS-SG}"
EFS_CREATION_TOKEN="${EFS_CREATION_TOKEN:-fixboard-efs}"

RDS_DB_IDENTIFIER="${RDS_DB_IDENTIFIER:-fixboard-db}"
RDS_SUBNET_GROUP_NAME="${RDS_SUBNET_GROUP_NAME:-fixboard-db-subnet-group}"
RDS_SG_NAME="${RDS_SG_NAME:-FixBoard-RDS-SG}"

ALB_SA_NAME="${ALB_SA_NAME:-aws-load-balancer-controller}"
EFS_CSI_SA_NAME="${EFS_CSI_SA_NAME:-efs-csi-controller-sa}"

FIXBOARD_NAMESPACE="${FIXBOARD_NAMESPACE:-fixboard}"

# Hints only — used to skip a re-derivation lookup when we already know
# the value. Never trusted blindly for the actual delete calls below;
# each one is re-validated by the AWS API call itself.
VPC_ID_HINT="${CFG_VPC_ID:-}"
EFS_ID_HINT="${CFG_EFS_FILESYSTEM_ID:-}"
EFS_SG_ID_HINT="${CFG_EFS_SECURITY_GROUP_ID:-}"
RDS_SG_ID_HINT="${CFG_RDS_SECURITY_GROUP_ID:-}"

for tool in aws eksctl kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found in PATH." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Run a delete command, tolerating "already gone" as success. Any other
# failure is fatal — fail loudly and stop, matching setup-platform.sh.
# ---------------------------------------------------------------------------
delete_tolerant() {
  local description="$1"
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    log_info "Deleted: ${description}"
    return 0
  fi
  if echo "$output" | grep -qiE "notfound|does not exist|no such (stack|cluster|entity)|could not find|resourcenotfoundexception|no cluster found"; then
    log_info "Already gone, skipping: ${description}"
    return 0
  fi
  echo "$output" >&2
  echo "ERROR: failed to delete ${description}" >&2
  exit 1
}

# ===========================================================================
# Guard 1 — refuse to run while the app is still deployed. Doc2's Cleanup
# phase must run first: delete the app's Kubernetes resources before
# tearing down the platform underneath them, not the other way around.
# ===========================================================================
log_step "Checking that the '${FIXBOARD_NAMESPACE}' namespace is gone (Doc2 cleanup must run first)"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ERROR: cluster '${CLUSTER_NAME}' exists but 'aws eks update-kubeconfig' failed —" >&2
    echo "cannot verify the '${FIXBOARD_NAMESPACE}' namespace is gone. Aborting rather than" >&2
    echo "risk tearing down the platform out from under a live app." >&2
    exit 1
  fi

  set +e
  NS_OUTPUT="$(kubectl get namespace "$FIXBOARD_NAMESPACE" 2>&1)"
  NS_STATUS=$?
  set -e

  if [[ $NS_STATUS -eq 0 ]]; then
    echo "ERROR: the '${FIXBOARD_NAMESPACE}' namespace still exists on cluster '${CLUSTER_NAME}'." >&2
    echo "Run the Application Deployment Guide's Cleanup phase (Doc2) first — delete the" >&2
    echo "app's Kubernetes resources before tearing down the platform underneath them." >&2
    exit 1
  elif echo "$NS_OUTPUT" | grep -qi "notfound"; then
    log_info "Namespace '${FIXBOARD_NAMESPACE}' not present — safe to proceed."
  else
    echo "ERROR: could not verify whether '${FIXBOARD_NAMESPACE}' exists (kubectl error below)." >&2
    echo "Aborting rather than risk tearing down the platform out from under a live app." >&2
    echo "$NS_OUTPUT" >&2
    exit 1
  fi
else
  log_info "Cluster '${CLUSTER_NAME}' not reachable — nothing to check, proceeding."
fi

# ===========================================================================
# Guard 2 — explicit, typed confirmation. This deletes real, billed AWS
# infrastructure and cannot be undone.
# ===========================================================================
echo
echo "############################################################"
echo "#  DESTRUCTIVE ACTION — FULL PLATFORM TEARDOWN"
echo "############################################################"
echo
echo "This will permanently delete, in ${AWS_REGION}:"
echo "  - The RDS instance '${RDS_DB_IDENTIFIER}' (and all data in it), its DB subnet"
echo "    group, and its security group"
echo "  - ECR repositories '${BACKEND_ECR_REPO}' and '${FRONTEND_ECR_REPO}' (and every image in them)"
echo "  - The EFS filesystem backing FixBoard's uploads (and every file on it)"
echo "  - The EFS security group ('${EFS_SG_NAME}')"
echo "  - IAM service accounts '${ALB_SA_NAME}', '${EFS_CSI_SA_NAME}'"
echo "  - The EKS cluster '${CLUSTER_NAME}' — control plane, node groups, and the"
echo "    VPC/networking eksctl created for it"
echo
echo "This cannot be undone."
echo
read -r -p "Type the cluster name (${CLUSTER_NAME}) to confirm: " CONFIRM_INPUT
if [[ "$CONFIRM_INPUT" != "$CLUSTER_NAME" ]]; then
  echo "Input did not match '${CLUSTER_NAME}'. Aborting — nothing was deleted." >&2
  exit 1
fi
log_info "Confirmed. Proceeding with teardown."

# ---------------------------------------------------------------------------
# Shared VPC lookup — both the RDS and EFS security group deletions below
# need it to disambiguate a security group by name; derive it once.
# ---------------------------------------------------------------------------
VPC_ID="$VPC_ID_HINT"
if [[ -z "$VPC_ID" ]]; then
  VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || true)"
  [[ "$VPC_ID" == "None" ]] && VPC_ID=""
fi

find_security_group_id() {
  local sg_name="$1"
  local result
  if [[ -n "$VPC_ID" ]]; then
    result="$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${sg_name}" "Name=vpc-id,Values=${VPC_ID}" \
      --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)"
  else
    result="$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${sg_name}" \
      --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)"
  fi
  [[ "$result" == "None" ]] && result=""
  echo "$result"
}

# ENIs from mount targets (EFS) or ENIs RDS itself created (RDS) can take a
# few seconds to fully release after the resource using them is gone —
# retry on DependencyViolation instead of failing immediately.
delete_security_group_with_retry() {
  local sg_id="$1" description="$2"
  local attempt output status
  for attempt in 1 2 3; do
    set +e
    output="$(aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      log_info "Deleted: ${description} (${sg_id})"
      return 0
    fi
    if echo "$output" | grep -qiE "notfound|does not exist"; then
      log_info "Already gone, skipping: ${description} (${sg_id})"
      return 0
    fi
    if echo "$output" | grep -qi "DependencyViolation" && [[ $attempt -lt 3 ]]; then
      log_info "${description} still has a dependency (attempt ${attempt}/3) — waiting 10s and retrying."
      sleep 10
      continue
    fi
    echo "$output" >&2
    echo "ERROR: failed to delete ${description} (${sg_id})" >&2
    exit 1
  done
}

# ===========================================================================
# 1 — Delete the RDS instance (Doc1 8.1)
# ===========================================================================
log_step "1. Delete the RDS instance"
if aws rds describe-db-instances --db-instance-identifier "$RDS_DB_IDENTIFIER" --region "$AWS_REGION" >/dev/null 2>&1; then
  set +e
  RDS_DELETE_OUTPUT="$(aws rds delete-db-instance --db-instance-identifier "$RDS_DB_IDENTIFIER" \
    --skip-final-snapshot --region "$AWS_REGION" 2>&1)"
  RDS_DELETE_STATUS=$?
  set -e
  if [[ $RDS_DELETE_STATUS -ne 0 ]]; then
    echo "$RDS_DELETE_OUTPUT" >&2
    echo "ERROR: failed to delete RDS instance '${RDS_DB_IDENTIFIER}'" >&2
    exit 1
  fi
  log_info "Delete requested for RDS instance '${RDS_DB_IDENTIFIER}' — waiting for it to finish (this can take several minutes)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$RDS_DB_IDENTIFIER" --region "$AWS_REGION"
  log_info "RDS instance '${RDS_DB_IDENTIFIER}' deleted."
else
  log_info "RDS instance '${RDS_DB_IDENTIFIER}' not found — already gone, skipping."
fi

# ===========================================================================
# 2 — Delete the RDS DB subnet group and security group (Doc1 8.2)
# ===========================================================================
log_step "2. Delete the RDS DB subnet group and security group"
delete_tolerant "RDS DB subnet group '${RDS_SUBNET_GROUP_NAME}'" \
  aws rds delete-db-subnet-group --db-subnet-group-name "$RDS_SUBNET_GROUP_NAME" --region "$AWS_REGION"

RDS_SG_ID="$RDS_SG_ID_HINT"
if [[ -z "$RDS_SG_ID" ]]; then
  RDS_SG_ID="$(find_security_group_id "$RDS_SG_NAME")"
fi
if [[ -z "$RDS_SG_ID" ]]; then
  log_info "No RDS security group found (name: ${RDS_SG_NAME}) — already gone, skipping."
else
  delete_security_group_with_retry "$RDS_SG_ID" "RDS security group"
fi

# ===========================================================================
# 3 — Delete ECR repositories (Doc1 8.6)
# ===========================================================================
log_step "3. Delete ECR repositories"
for repo in "$BACKEND_ECR_REPO" "$FRONTEND_ECR_REPO"; do
  delete_tolerant "ECR repository '${repo}'" \
    aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION"
done

# ===========================================================================
# 4 — Delete EFS mount targets, then the filesystem (Doc1 8.3)
# ===========================================================================
log_step "4. Delete EFS mount targets and the filesystem"

EFS_ID="$EFS_ID_HINT"
if [[ -z "$EFS_ID" ]]; then
  EFS_ID="$(aws efs describe-file-systems --creation-token "$EFS_CREATION_TOKEN" \
    --region "$AWS_REGION" --query "FileSystems[0].FileSystemId" --output text 2>/dev/null || true)"
  [[ "$EFS_ID" == "None" ]] && EFS_ID=""
fi

if [[ -z "$EFS_ID" ]]; then
  log_info "No EFS filesystem found (creation token: ${EFS_CREATION_TOKEN}) — already gone, skipping."
else
  log_info "EFS filesystem: ${EFS_ID}"
  MOUNT_TARGET_IDS="$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
    --query "MountTargets[].MountTargetId" --output text 2>/dev/null || true)"

  for mt in $MOUNT_TARGET_IDS; do
    delete_tolerant "EFS mount target ${mt}" \
      aws efs delete-mount-target --mount-target-id "$mt" --region "$AWS_REGION"
  done

  if [[ -n "$MOUNT_TARGET_IDS" ]]; then
    log_info "Waiting for mount targets to finish deleting..."
    WAITED=0
    while :; do
      REMAINING="$(aws efs describe-mount-targets --file-system-id "$EFS_ID" --region "$AWS_REGION" \
        --query "length(MountTargets)" --output text 2>/dev/null || echo 0)"
      [[ "$REMAINING" == "0" || -z "$REMAINING" ]] && break
      if [[ $WAITED -ge 120 ]]; then
        log_info "Still waiting after 120s — proceeding; the filesystem delete below will fail loudly if they're not actually gone."
        break
      fi
      sleep 5
      WAITED=$((WAITED + 5))
    done
  fi

  delete_tolerant "EFS filesystem ${EFS_ID}" \
    aws efs delete-file-system --file-system-id "$EFS_ID" --region "$AWS_REGION"
fi

# ===========================================================================
# 5 — Delete the EFS security group (Doc1 8.4)
# ===========================================================================
log_step "5. Delete the EFS security group"

SG_ID="$EFS_SG_ID_HINT"
if [[ -z "$SG_ID" ]]; then
  SG_ID="$(find_security_group_id "$EFS_SG_NAME")"
fi

if [[ -z "$SG_ID" ]]; then
  log_info "No EFS security group found (name: ${EFS_SG_NAME}) — already gone, skipping."
else
  delete_security_group_with_retry "$SG_ID" "EFS security group"
fi

# ===========================================================================
# 6 — Delete IAM service accounts (Doc1 8.5)
# ===========================================================================
log_step "6. Delete IAM service accounts"
for sa in "$ALB_SA_NAME" "$EFS_CSI_SA_NAME"; do
  delete_tolerant "IAM service account kube-system/${sa}" \
    eksctl delete iamserviceaccount \
      --cluster "$CLUSTER_NAME" \
      --region "$AWS_REGION" \
      --namespace kube-system \
      --name "$sa"
done

# ===========================================================================
# 7 — Delete the cluster (Doc1 8.7)
# ===========================================================================
log_step "7. Delete the EKS cluster (10-15 minutes)"
delete_tolerant "EKS cluster '${CLUSTER_NAME}'" \
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"

# ===========================================================================
# Verify (Doc1 8.8)
# ===========================================================================
echo
echo "=== Verifying teardown ==="
ALL_CLEAR=true

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "FAIL: cluster '${CLUSTER_NAME}' still exists."
  ALL_CLEAR=false
else
  echo "PASS: cluster '${CLUSTER_NAME}' gone."
fi

for repo in "$BACKEND_ECR_REPO" "$FRONTEND_ECR_REPO"; do
  if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "FAIL: ECR repository '${repo}' still exists."
    ALL_CLEAR=false
  else
    echo "PASS: ECR repository '${repo}' gone."
  fi
done

REMAINING_EFS="$(aws efs describe-file-systems --creation-token "$EFS_CREATION_TOKEN" \
  --region "$AWS_REGION" --query "FileSystems[0].FileSystemId" --output text 2>/dev/null || true)"
if [[ -n "$REMAINING_EFS" && "$REMAINING_EFS" != "None" ]]; then
  echo "FAIL: EFS filesystem still present: ${REMAINING_EFS}"
  ALL_CLEAR=false
else
  echo "PASS: no orphaned EFS filesystem."
fi

if aws rds describe-db-instances --db-instance-identifier "$RDS_DB_IDENTIFIER" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "FAIL: RDS instance '${RDS_DB_IDENTIFIER}' still exists."
  ALL_CLEAR=false
else
  echo "PASS: RDS instance '${RDS_DB_IDENTIFIER}' gone."
fi

echo
if $ALL_CLEAR; then
  echo "=== TEARDOWN COMPLETE — all platform resources removed. No further AWS charges should accrue. ==="
else
  echo "=== TEARDOWN INCOMPLETE — see FAIL lines above. Re-running this script is safe; it skips whatever's already gone. ===" >&2
  exit 1
fi

if [[ -f "$CONFIG_FILE" ]]; then
  rm -f "$CONFIG_FILE"
  log_info "Removed ${CONFIG_FILE} (its values no longer refer to anything that exists)."
fi
