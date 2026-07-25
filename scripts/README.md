# scripts/

Automation for the manual steps in **Doc1 — Platform Setup**. Read Doc1
first; it explains *why* each step exists. These scripts just re-run the
*what*, quickly, for those who've already done it manually once (e.g.
rebuilding the platform after a teardown, or tearing it down when done).

## setup-platform.sh

Provisions everything FixBoard's Kubernetes deployment needs before the
application itself goes on: the EKS cluster, IAM OIDC/IRSA, ECR
repositories, the AWS Load Balancer Controller, Amazon EFS + its CSI
driver, and an Amazon RDS PostgreSQL instance. Mirrors Doc1's Phases 1–6
in order, with the same phase/step numbering in its output.

FixBoard's database runs on RDS, not in-cluster — there's no EBS CSI
driver or StatefulSet involved anywhere in this script.

**Platform only.** It does not install the External Secrets Operator and
does not create any FixBoard application resources (namespace, secrets,
Deployments, Services, Ingress) — that's Doc2's territory, still manual
for now.

### Requirements

- AWS CLI, configured (`aws sts get-caller-identity` must succeed)
- `eksctl`, `kubectl`, `helm`, `curl` on `PATH`
- IAM permissions to create/read: EKS clusters, IAM OIDC providers, IAM
  policies/roles (via eksctl's CloudFormation stacks), ECR repositories,
  EC2 security groups, EFS filesystems/mount targets, and RDS
  instances/subnet groups
- **`RDS_MASTER_PASSWORD` set in the environment before running.** This
  becomes the PostgreSQL master password for the RDS instance created in
  Phase 6. There's no default — the script fails immediately in
  preflight (before Phase 1's ~20-minute cluster creation even starts)
  if it isn't set, rather than checking in a database password as a
  convenience default.
  export RDS_MASTER_PASSWORD='<choose-a-strong-password>'

### Usage

```bash
./scripts/setup-platform.sh
```

Run it from anywhere — it locates the repo root relative to its own
path, so `cd`ing into `scripts/` first isn't necessary.

It's safe to re-run. Each phase checks whether its resource already
exists before creating it (cluster, ECR repos, IAM policy, the EFS
security group, EFS mount targets per subnet, IRSA service accounts, the
RDS DB subnet group, the RDS security group, the RDS instance) and skips
creation with a note instead of failing. A few AWS calls are naturally
idempotent and are just re-run every time without a check first —
`associate-iam-oidc-provider` (Doc1 notes this itself), `efs
create-file-system` (idempotent on `--creation-token`), the Helm
installs (`helm upgrade --install`), and the `kubectl apply` StorageClass
step.

If a step fails, the script stops immediately (`set -euo pipefail` plus
an `ERR` trap) — it does not continue past a failure and leave the
platform half-provisioned. Fix the reported error and re-run; completed
steps will be skipped on the retry.

**The RDS instance always gets a wait, even on a re-run that finds it
already exists.** `aws rds wait db-instance-available` and the endpoint
capture run unconditionally after the exists-check/create branch, not
just on first creation — so a re-run after a previous run created the
instance but died before capturing the endpoint (e.g. a laptop sleeping
mid-provision) resumes correctly instead of getting stuck. This is also
the one step in either script most worth a real run to confirm: AWS
CLI's `wait` subcommands have a fixed default timeout, and if a
particular `db.t3.micro` Postgres 16 provision happens to run long, the
wait could time out even though the instance is still legitimately
coming up, not actually failed.

### Configuration

Everything is a variable near the top of the script, defaulted to Doc1's
values, overridable by exporting the same name before running:

| Variable | Default | What it controls |
|---|---|---|
| `CLUSTER_NAME` | `ridgeline-fixboard` | EKS cluster name |
| `AWS_REGION` | `us-east-1` | Region for every AWS resource |
| `EKS_VERSION` | `1.30` | Kubernetes version |
| `NODEGROUP_NAME` | `fixboard-workers` | Managed node group name |
| `NODE_TYPE` | `t3.medium` | Worker instance type |
| `NODES` / `NODES_MIN` / `NODES_MAX` | `2` / `2` / `4` | Node group autoscaling range |
| `BACKEND_ECR_REPO` | `fixboard-backend` | Backend image repository name |
| `FRONTEND_ECR_REPO` | `fixboard-frontend` | Frontend image repository name |
| `ALB_POLICY_NAME` | `AWSLoadBalancerControllerIAMPolicy` | IAM policy name for the ALB controller |
| `ALB_IAM_POLICY_URL` | v2.9.0 policy doc on GitHub | Source of the ALB controller's IAM policy document |
| `ALB_SA_NAME` | `aws-load-balancer-controller` | IRSA service account name (namespace: `kube-system`) |
| `EFS_SG_NAME` | `EFS-SG` | Security group name for EFS/NFS traffic |
| `EFS_CREATION_TOKEN` | `fixboard-efs` | EFS filesystem idempotency token |
| `EFS_NAME_TAG` | `FixBoard-EFS` | `Name` tag on the EFS filesystem |
| `EFS_CSI_SA_NAME` | `efs-csi-controller-sa` | IRSA service account name for the EFS CSI driver |
| `EFS_STORAGECLASS_NAME` | `efs-sc` | Name of the generated EFS StorageClass |
| `EFS_DIRECTORY_PERMS` | `700` | `directoryPerms` in the EFS StorageClass |
| `RDS_DB_IDENTIFIER` | `fixboard-db` | RDS instance identifier |
| `RDS_INSTANCE_CLASS` | `db.t3.micro` | RDS instance size |
| `RDS_ENGINE_VERSION` | `16` | PostgreSQL engine version |
| `RDS_ALLOCATED_STORAGE` | `20` | Storage size in GiB |
| `RDS_MASTER_USERNAME` | `fixboard` | PostgreSQL master username |
| `RDS_MASTER_PASSWORD` | *(none — required)* | PostgreSQL master password; see Requirements above |
| `RDS_SUBNET_GROUP_NAME` | `fixboard-db-subnet-group` | DB subnet group name |
| `RDS_SG_NAME` | `FixBoard-RDS-SG` | Security group name for Postgres traffic (port 5432) |
| `CONFIG_FILE_NAME` | `platform-config.env` | Output config filename (written to the repo root) |

Example — different cluster name and region:

```bash
CLUSTER_NAME=my-fixboard-cluster AWS_REGION=us-west-2 ./scripts/setup-platform.sh
```

### Output

An EFS StorageClass manifest is generated at the repo root (matching
Doc1's own "save as ..." instruction) and applied: `storage-class-efs.yaml`.
If the ALB IAM policy doesn't exist yet, `iam_policy.json` is also
downloaded there.

At the end, **`platform-config.env`** is written to the repo root with
every value a later step might need — nothing after this script requires
copy-pasting an ID out of terminal output. It's gitignored, and
deliberately does **not** include `RDS_MASTER_PASSWORD` — that value
only ever lives in the environment variable you set, matching Doc2's own
"secrets don't sit in a file in the repo" stance:

```
AWS_ACCOUNT_ID=...
AWS_REGION=...
CLUSTER_NAME=...
VPC_ID=...
SUBNET_IDS=...          # comma-separated
EKS_NODE_SECURITY_GROUP_ID=...
EFS_FILESYSTEM_ID=...
EFS_SECURITY_GROUP_ID=...
EFS_STORAGECLASS_NAME=...
RDS_DB_IDENTIFIER=...
RDS_ENDPOINT=...
RDS_SUBNET_GROUP_NAME=...
RDS_SECURITY_GROUP_ID=...
ECR_REGISTRY_URI=...
BACKEND_ECR_REPO=...
BACKEND_ECR_URI=...
FRONTEND_ECR_REPO=...
FRONTEND_ECR_URI=...
```

Source it in later scripts/sessions with `source platform-config.env`.
`RDS_ENDPOINT` is what the Application Deployment Guide's Phase 2 and
Phase 3 need — the Secrets Manager `DATABASE_URL` and the
`postgres-service` ExternalName Service both point at it.

### Verifying it worked

The script's own output walks through Doc1's Phase 7 readiness checklist
inline (nodes ready, ECR repos present, controller/CSI-driver pods
running, the EFS StorageClass registered, the RDS instance available) as
each phase completes. To
re-check any of it later without re-running the script, the checks are
exactly Doc1 Phase 7's:

```bash
kubectl get nodes
aws ecr describe-repositories --query "repositories[].repositoryName"
kubectl get pods -n kube-system | grep aws-load-balancer
kubectl get pods -n kube-system | grep efs-csi
kubectl get storageclass efs-sc
aws rds describe-db-instances --db-instance-identifier fixboard-db \
  --query "DBInstances[0].DBInstanceStatus" --region us-east-1    # "available"
```

### Not included here

- **Teardown.** See `cleanup-platform.sh` below.
- **App deployment.** Doc2's namespace, secrets (External Secrets
  Operator), Deployments, Services, and Ingress are out of scope for
  this script by design.

## cleanup-platform.sh

Reverses everything `setup-platform.sh` creates, matching Doc1 Phase 8
(Infrastructure Teardown): the RDS instance and its subnet group and
security group, ECR repositories, the EFS filesystem and its mount
targets, the EFS security group, the two IRSA service accounts, and
finally the EKS cluster itself. Full teardown — brings the AWS account
back to zero footprint/zero cost for this exercise.

**Platform only**, same boundary as `setup-platform.sh` — it never
touches FixBoard application resources. It actively refuses to run if
the `fixboard` namespace is still on the cluster (see Guards below);
run Doc2's own Cleanup phase first.

### Requirements

Same as `setup-platform.sh` minus `curl`: AWS CLI (configured), `eksctl`,
`kubectl` on `PATH`.

### Usage

```bash
./scripts/cleanup-platform.sh
```

It reads `platform-config.env` (written by `setup-platform.sh`) if
present, and uses the resource IDs in it — the actual EFS filesystem ID
and the EFS/RDS security group IDs, rather than re-deriving them via an
AWS CLI lookup. If that file is missing (or a particular value in it
is), it falls back to the same lookups Doc1 and `setup-platform.sh` use
(EFS by its `--creation-token`, either security group by name + VPC ID).
Either way, cluster/region/repo names/etc. can still be overridden the
same way as `setup-platform.sh` — an explicit environment variable
always wins over whatever's in the config file.

**It is safe to re-run.** Every delete is tolerant of the resource
already being gone (already deleted manually, or left over from a
previous partial run) — that's logged as a skip, not an error. Any
*other* failure still stops the script immediately, same fail-loud
behavior as `setup-platform.sh`.

### Guards

Two checks run before anything is deleted:

1. **App-level cleanup check.** If the cluster is reachable, the script
   runs `kubectl get namespace fixboard`. If it's still there, the
   script aborts with a message to run the Application Deployment
   Guide's (Doc2) Cleanup phase first. If kubectl can't be reached at
   all (bad kubeconfig, network issue — as opposed to a clean "namespace
   not found"), the script also aborts rather than risk tearing down the
   platform out from under an app it couldn't actually verify was gone.
   If the cluster itself doesn't exist, there's nothing to check, so it
   proceeds straight to guard 2.

2. **Typed confirmation.** The script prints exactly what it's about to
   delete, then requires typing the cluster name (not `y`/`n`) to
   continue:

   ```
   Type the cluster name (ridgeline-fixboard) to confirm:
   ```

   Anything else aborts with nothing deleted.

### Deletion order

RDS instance → RDS DB subnet group + RDS security group → ECR
repositories → EFS mount targets → EFS filesystem → EFS security group →
IAM service accounts (`aws-load-balancer-controller`,
`efs-csi-controller-sa`) → EKS cluster.

The RDS instance is the one step that isn't wrapped in the generic
`delete_tolerant` helper: if it exists, the script triggers the delete
*and then waits for it to finish* (`aws rds wait db-instance-deleted`)
before moving on to the subnet group/security group, since those can't
be removed while the instance still references them — the same
"delete → wait → then remove what's underneath" shape as the EFS mount
target step below it. **This wait is the other real timing risk to
confirm on an actual account** — same category as the create-side wait
in `setup-platform.sh`, just in reverse.

The EFS security group and the RDS security group now share a small
`find_security_group_id` / `delete_security_group_with_retry` pair of
helpers (both look up "a security group by name, optionally scoped to a
VPC" and both need the same `DependencyViolation` retry — RDS's own ENI,
not just EFS's mount-target ENIs, can take a few seconds to release
after the instance is gone) — factored out instead of duplicated a
third time, same idempotency behavior as before.

### Verifying it worked

At the end the script re-checks Doc1 8.8 itself and prints PASS/FAIL per
resource, then a final summary — `TEARDOWN COMPLETE` (exit 0) or
`TEARDOWN INCOMPLETE` (exit 1, safe to just re-run). On a clean pass, it
also deletes `platform-config.env`, since its values wouldn't refer to
anything that still exists.

```bash
eksctl get cluster --region us-east-1                                    # ridgeline-fixboard not listed
aws ecr describe-repositories --query "repositories[].repositoryName"    # fixboard-backend/frontend not listed
aws efs describe-file-systems --query "FileSystems[].Name"               # FixBoard-EFS not listed
aws rds describe-db-instances --db-instance-identifier fixboard-db       # Error: DBInstanceNotFound
```
