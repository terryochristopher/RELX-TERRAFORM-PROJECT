# relx Senior SRE Assessment — Amazon EKS Bonus

Containerized Hello World application deployed to **Amazon Elastic Kubernetes Service (EKS)** with Terraform, Amazon ECR, Kubernetes, automated smoke testing, and GitHub Actions. This is an **optional addition** to the original EC2/Bastion/ALB/Auto Scaling assessment; it is intentionally managed in **separate Terraform state**.

> **Deployment status:** The EKS cluster `relx-dev-eks` and managed node group `relx-dev-nodes` were reported created. The Kubernetes `sre-web` Deployment was created, an image-architecture pull failure was diagnosed, and a `sre-web` Service was initially missing. This README documents how to finish and verify the full deployment. It does **not** claim end-to-end success until the checks below pass.

## Architecture

```text
Mac / GitHub Actions
       |
       | Docker build (linux/amd64), ECR push
       v
Amazon ECR (relx-web:v2 OR Terraform-managed <project>-eks-web:<build-tag>)
       |
       v
Amazon EKS: relx-dev-eks
   |-- Managed node group: relx-dev-nodes (private subnets, two AZs)
   |-- Namespace: sre-demo
   |-- Deployment: sre-web (2 replicas)
   |-- Service: sre-web (ClusterIP, port 80)
   `-- Optional HPA (requires Metrics Server)
       |
       v
kubectl port-forward --> http://localhost:8082 --> Hello, World!

Existing AWS VPC / NAT / subnets are shared. Existing EC2 Terraform state is NOT shared.
```

**No public endpoint for the EKS application is configured in the base package.** The Kubernetes Service is `ClusterIP`. Port forwarding validates the deployed app without creating another billable load balancer. A public ALB requires a separate Ingress/controller setup (see *Optional external access*).

## Repository layout

```text
.
├── app/
│   ├── Dockerfile
│   └── index.html
├── kubernetes/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml                # optional
├── terraform/                 # existing mandatory EC2 infrastructure: unchanged
├── terraform-eks/
│   ├── versions.tf
│   ├── main.tf                 # EKS, node group, IAM, ECR
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── backend.hcl.example
├── scripts/
│   └── eks-smoke-test.sh
└── .github/workflows/
    └── eks-deploy.yml
```

The packaged Terraform code defaults to **`project_name = "relx-dev"`**. It creates EKS `relx-dev-eks`, node group `relx-dev-nodes`, and an ECR repository **`relx-dev-eks-web`**. Your earlier manual ECR push used **`relx-web:v2`** instead. These are **different repositories**. Choose one approach; do not assume Terraform owns the manually created `relx-web` repository.

## Quick start / order of operations

This is the **recommended order** when repeating the exercise from scratch. Each stage has a detailed section below.

1. Verify AWS credentials, AWS region, and the existing VPC with two private subnets in different Availability Zones.
2. Choose the separate **EKS state** S3 key and run `terraform init`, `validate`, `plan`, and `apply` from `terraform-eks/`.
3. Configure `kubectl` and confirm the nodes are `Ready`.
4. Build the Docker image explicitly for the worker-node architecture and push it to the chosen ECR repository.
5. Create the Kubernetes namespace and Service, then deploy the image and verify **two Ready pods**.
6. Test the `ClusterIP` Service using port-forwarding and the automated smoke-test script.
7. Configure GitHub Actions for the ECR build → EKS rollout → smoke-test process and verify a successful run.
8. Optionally configure HPA and external ingress; finally destroy EKS resources when finished to avoid charges.

**Do not run `terraform apply` merely to fix a Kubernetes image problem.** A broken container image is normally fixed by rebuilding/pushing the correct architecture and rolling out a corrected Deployment. Conversely, an EKS networking or IAM problem may require a Terraform update.

## 1. Prerequisites

- AWS account and AWS CLI credentials with EKS, ECR, IAM, EC2 describe, S3 state, and necessary `iam:PassRole` permissions. **Never use root access keys** in GitHub Actions.
- Terraform >= 1.10, `aws` CLI, Docker/Buildx, `kubectl`, `git`, `curl`, Bash. Confirm commands using `terraform version`, `aws --version`, `docker version`, `kubectl version --client`.
- AWS region **`us-east-1`** for the commands below (change consistently if your actual region differs).
- Existing VPC with **two private subnets in distinct Availability Zones**, routing that allows worker nodes to reach ECR and required AWS services (NAT or VPC endpoints), plus sufficient free IP addresses.
- Existing private S3 bucket with versioning, encryption and bucket-level public access blocking for remote Terraform state. The EKS state key must be different from the EC2 project.
- EKS node instances and cluster incur AWS charges. The EKS control plane, EC2 nodes, EBS, NAT and optional ALB are **not guaranteed Free Tier**.
- For private nodes, confirm the VPC DNS and route tables support node registration and ECR image pulls.

Identify your CLI identity and region:

```bash
aws sts get-caller-identity
aws configure get region
```

## 2. Identify existing VPC and subnets

```bash
aws ec2 describe-vpcs --region us-east-1 \
  --query 'Vpcs[*].[VpcId,CidrBlock]' --output table

aws ec2 describe-subnets --region us-east-1 \
  --filters Name=vpc-id,Values=YOUR_VPC_ID \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Choose two **private** subnet IDs from different AZs. Confirm their associated route tables send required outbound traffic to a NAT gateway or appropriate VPC endpoints. The original EC2 stack and EKS stack can share the VPC while maintaining independent state.

## 3. Build and test the Docker image locally

From the **repository root**:

```bash
docker build -t relx-web:local ./app
# Use 8082 because 8080 was already occupied on the local Mac.
# If a container with this name already exists, stop/remove it first.
docker run -d --name relx-web-local -p 8082:80 relx-web:local
curl -fsS http://localhost:8082/
docker logs relx-web-local
docker stop relx-web-local
docker rm relx-web-local
```

Expected page includes `<h1>Hello, World!</h1>`. If port 8082 is occupied, choose another available **host** port. The Nginx container still listens on port 80.

### Architecture compatibility: Apple Silicon vs EKS nodes

The previous deployment showed `no match for platform in manifest`; this indicates the pushed image did not contain the architecture required by the EKS node. Check the nodes:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
```

For `amd64` nodes, explicitly build an AMD64 image on the Mac:

```bash
docker buildx build --platform linux/amd64 -t relx-web:v2 --load ./app
```

Use `linux/arm64` only for compatible ARM64 nodes, or publish a multi-platform image when needed.

## 4. Push a container image to ECR

### Route A — use the existing manually created `relx-web` repository

This matches the ECR repository and image seen in the earlier pod events:

```bash
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_URI="${ECR_REGISTRY}/relx-web:v2"

aws ecr describe-repositories --region "$AWS_REGION" \
  --repository-names relx-web

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker buildx build --platform linux/amd64 -t "$IMAGE_URI" --push ./app
aws ecr describe-images --repository-name relx-web --region "$AWS_REGION" \
  --image-ids imageTag=v2
```

If the repository does not exist, create it **only if it is not already managed by Terraform**:

```bash
aws ecr create-repository --repository-name relx-web --region us-east-1
```

### Route B — use the ECR repository created by `terraform-eks`

The packaged Terraform resource is `aws_ecr_repository.web`; its default repository name is `relx-dev-eks-web`. After Terraform is applied, retrieve its full URI:

```bash
cd terraform-eks
terraform output -raw ecr_repository_url
cd ..
```

Build, tag and push an AMD64 image using that URI and a **new unique tag** (the Terraform-managed ECR repository is immutable):

```bash
export ECR_URL="$(cd terraform-eks && terraform output -raw ecr_repository_url)"
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker buildx build --platform linux/amd64 -t "${ECR_URL}:v2" --push ./app
```

**Pick Route A or B** for deployment. To use the Terraform-managed repository in GitHub Actions, set repository variable `ECR_REPOSITORY` to `relx-dev-eks-web`; to keep using the manual repository, set it to `relx-web`. Never configure two Terraform resources to manage the same ECR repository without importing it properly.

## 5. Configure isolated EKS Terraform state

From repository root:

```bash
cd terraform-eks
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
```

In `terraform.tfvars` fill in real values:

```hcl
aws_region         = "us-east-1"
project_name       = "relx-dev"
vpc_id             = "vpc-REPLACE_ME"
private_subnet_ids = ["subnet-PRIVATE_A", "subnet-PRIVATE_B"]
node_instance_types = ["t3.small"]
node_desired_size   = 2
# Optional: a specific IAM user/role requiring Kubernetes access.
# Do NOT use account root ARN here.
# eks_admin_principal_arn = "arn:aws:iam::ACCOUNT_ID:user/github-actions"
```

`backend.hcl` should identify the EKS state location (not the EC2 one):

```hcl
bucket       = "test-bucket-relx-new"
key          = "relx-eks-project/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

The bucket above is the one shown in your earlier EKS state lock output; use your actual bucket if you changed it. Your existing EC2 Terraform must use a **different backend key**. Avoid committing `terraform.tfvars`, `backend.hcl`, state files, or binary plans.

Initialize and check:

```bash
terraform init -backend-config=backend.hcl
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan
```

Check the resource changes and costs before proceeding:

```bash
terraform apply tfplan
terraform output
```

**If EKS and its nodes are already in state, do not rebuild them.** Run `terraform plan` and apply only the remaining desired changes.

### State lock errors

A `412 PreconditionFailed` for `terraform.tfstate.tflock` means lock acquisition failed on the **EKS state path**. Check for other running Terraform processes and CI jobs first. Inspect:

```bash
aws s3api head-object --bucket test-bucket-relx-new \
  --key relx-eks-project/terraform.tfstate.tflock
```

Only if the lock is confirmed stale and no operation is active, use `terraform force-unlock LOCK_ID` from `terraform-eks/`. Never delete the state file or use `-lock=false` as the routine fix. If switching buckets or state keys after deployment, **migrate the existing EKS state** instead of starting with an empty state.

### Duplicate EKS access entry (409)

If `aws_eks_access_entry.github[0]` fails because an access entry already exists, inspect:

```bash
aws eks list-access-entries --cluster-name relx-dev-eks --region us-east-1
```

The earlier duplicate concerned `arn:aws:iam::572498499202:root`. That **is not a GitHub IAM user**. Do not create another entry for it. Either omit the optional entry (`eks_admin_principal_arn = null`), import the exact preexisting entry if you intend Terraform to manage it, or provide a **distinct, intended** IAM user/role ARN. The starter grants cluster-admin to the optional principal; for real use prefer namespace-limited privileges.

## 6. Connect kubectl to EKS and verify worker nodes

```bash
aws eks update-kubeconfig --region us-east-1 --name relx-dev-eks
kubectl config current-context
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,ARCH:.status.nodeInfo.architecture
```

Expected: worker nodes in `Ready` state. If access is denied, verify your **current IAM principal** is authorized via EKS access entries or cluster creator access. AWS credentials alone do not grant Kubernetes permissions. If worker nodes are `NotReady`, check the node-group health, subnet routing, security groups and node IAM role.

## 7. Kubernetes Deployment and Service

From the repository root, create the namespace and Service first:

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/service.yaml
```

`kubernetes/service.yaml` defines `Service/sre-web` in namespace `sre-demo` with `type: ClusterIP`. A successful Deployment **does not automatically create a Service**.

### Set the real image in your Deployment

The packaged `kubernetes/deployment.yaml` uses `IMAGE_URI_PLACEHOLDER` and its container name is `web` (your separately edited local manifest may name the container `sre-web`). Replace the placeholder with the **actual** complete ECR image URI and tag, or render it without editing the source:

```bash
export IMAGE_URI="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com/relx-web:v2"
sed "s|IMAGE_URI_PLACEHOLDER|${IMAGE_URI}|g" kubernetes/deployment.yaml | \
  kubectl apply -f -
```

If your local manifest already contains the correct URI, use `kubectl apply -f kubernetes/deployment.yaml` instead. Do **not** apply the unrendered placeholder. To use Route B, substitute its ECR URI above.

**Important image/security compatibility:** The original sample manifests configure Nginx as a non-root process (`runAsUser: 101`), drop all capabilities, and use a read-only root filesystem, while the supplied Dockerfile runs the conventional Nginx image on port **80**. This combination may fail to bind the port or initialize Nginx when the image starts. If pods enter `CrashLoopBackOff`, inspect logs first. A clean production-style fix is to use an **unprivileged Nginx image on port 8080** and change the Deployment `containerPort`, named Service `targetPort`, and probe port consistently. **Before running the GitHub workflow, make sure the checked-in Dockerfile and manifest work together.** For the simplest assessment path, use the working local Nginx-on-80 Deployment (with a compatible security context), or fully migrate Dockerfile, Service and probes to an unprivileged port 8080 configuration. For a minimal demonstration, use a container/security context compatible with your chosen image; do not simply disable all hardening without explaining the tradeoff.

Verify deployment:

```bash
kubectl -n sre-demo get deployments
kubectl -n sre-demo get pods -o wide
kubectl -n sre-demo rollout status deployment/sre-web --timeout=300s
kubectl -n sre-demo get svc sre-web
kubectl -n sre-demo get endpointslices -l kubernetes.io/service-name=sre-web
```

Expected: **two Ready pods**, a `ClusterIP` Service and ready endpoints. If the image or configuration was changed imperatively using `kubectl set image`, update your source `deployment.yaml` or its deployment template too, so the next automated deployment does not revert the change.

## 8. Test the app without a public load balancer

The private `ClusterIP` Service cannot be opened directly in a public browser. Port-forwarding makes the application accessible **temporarily from your own machine**:

```bash
kubectl -n sre-demo port-forward svc/sre-web 8082:80
```

Leave that terminal open. In a second terminal:

```bash
curl -i http://localhost:8082/
```

Expected: `HTTP/1.1 200 OK` and `<h1>Hello, World!</h1>`.

To test with the provided automated script from the repository root:

```bash
bash scripts/eks-smoke-test.sh
```

It waits for the rollout, port-forwards the Service, looks for `Hello, World!`, and fails with a nonzero exit code if the app does not respond. The script defaults to **local port 18080**, avoiding the usual 8080/8082 conflicts.

### Reliability checks

```bash
kubectl -n sre-demo rollout restart deployment/sre-web
kubectl -n sre-demo rollout status deployment/sre-web
kubectl -n sre-demo get pods -w
kubectl -n sre-demo describe deployment sre-web
```

These demonstrate rolling replacement, readiness checks and resilience. The Deployment is designed for two replicas with `maxSurge: 1`, `maxUnavailable: 0`.

## 9. Optional Horizontal Pod Autoscaler

`kubernetes/hpa.yaml` scales Deployment `sre-web` from **2 to 4 pods** using a 70% CPU utilization target. It requires a working **Metrics Server**; confirm availability before applying:

```bash
kubectl top nodes
kubectl top pods -n sre-demo
kubectl apply -f kubernetes/hpa.yaml
kubectl get hpa -n sre-demo
```

If `kubectl top` says metrics are unavailable, install or enable a compatible Metrics Server add-on first. EKS managed **node group** scaling (1–3 nodes in Terraform) is separate from **pod** autoscaling. The node group does not automatically provision more nodes just because an HPA creates unschedulable pods; that needs an appropriate node autoscaling solution or sufficient capacity.

## 10. GitHub Actions — ECR build, EKS deploy, smoke test

The project includes `.github/workflows/eks-deploy.yml`. It is **manually triggered**, uses your GitHub Actions AWS access-key secrets, builds/pushes an image, applies Kubernetes manifests, waits for rollout, then runs the smoke test.

In GitHub repository **Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | Dedicated IAM CI user access key |
| Secret | `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `EKS_CLUSTER_NAME` | `relx-dev-eks` |
| Variable | `ECR_REPOSITORY` | `relx-web` if using Route A, **or** `relx-dev-eks-web` if using Route B |

GitHub's IAM identity needs ECR push permissions and `eks:DescribeCluster`, **plus EKS Kubernetes authorization** for the namespace and resources it deploys. Do not grant cluster-admin simply as a workaround if namespace-scoped access will suffice.

**Architecture in CI:** GitHub-hosted `ubuntu-latest` runners typically build AMD64 images, but for an explicit guarantee use Docker Buildx with `platforms: linux/amd64` and `docker/build-push-action` (or `docker buildx build --platform linux/amd64 --push ...`). If using ARM nodes, use the matching platform.

**Approval:** The workflow specifies `environment: production`, but that alone does not create a human approval gate. Configure **Settings → Environments → production → Required reviewers**, if supported by your GitHub plan/repository. Reviewers must approve before the job gets AWS credentials. A public repository and long-lived access keys deserve extra care; OIDC with short-lived credentials is preferable for production.

To run: commit the files, open **GitHub → Actions → EKS Bonus - Build and Deploy → Run workflow**, select `main`, and approve the protected environment if configured. Inspect the steps for Docker build, ECR push, `kubectl rollout status`, and `PASS: EKS service serves Hello, World!`.

The workflow uses a unique image tag based on commit/run metadata; **do not assume it deploys `v2`**. It renders the placeholder with the tag it just pushed. If your working local manifest differs from the checked-in template, reconcile those differences before enabling automatic deployment.

### CI/CD verification commands

After running the workflow, check the deployed image and status from a machine with kubectl access:

```bash
kubectl -n sre-demo rollout status deployment/sre-web --timeout=300s
kubectl -n sre-demo get deployments,pods,svc
kubectl -n sre-demo get deployment sre-web -o jsonpath='{.spec.template.spec.containers[*].image}'
echo
```

Make sure the image tag matches the new GitHub workflow run. If the CI runner reports `Forbidden` during `kubectl apply`, check the runner's **IAM identity**, the EKS access entry, and Kubernetes namespace authorization. If it reports `ImagePullBackOff`, inspect pod Events rather than changing credentials blindly.

### Manual approval for the EKS workflow

For a real approval gate, configure **GitHub → Settings → Environments → production → Required reviewers** (where available). The included EKS workflow references that environment. Triggering a manual `workflow_dispatch` by yourself is **not the same as an independently enforced approval**. Test the gate by observing a job waiting for review before it gets AWS credentials. Do not give a public-repo PR job access to deployment secrets.

## 11. Common troubleshooting

| Symptom | Meaning / action |
|---|---|
| `no objects passed to apply` | Empty or invalid Kubernetes manifest: `cat kubernetes/deployment.yaml`, check `apiVersion`, `kind`, `metadata`, `spec`, run `kubectl apply --dry-run=client -f ...` |
| `ErrImagePull`, `ImagePullBackOff` | `kubectl -n sre-demo describe pod POD_NAME`, inspect Events; confirm full ECR URI, tag, node IAM ECR permissions and outbound networking |
| `no match for platform in manifest` | Image architecture mismatch; rebuild/push `linux/amd64` for AMD64 nodes (the previous failure), then update Deployment image |
| `services "sre-web" not found` | Apply `kubernetes/service.yaml` in namespace `sre-demo`, then `kubectl get svc -n sre-demo` |
| `CrashLoopBackOff` | `kubectl logs -n sre-demo deployment/sre-web --all-containers=true --tail=100`; inspect non-root Nginx/port 80/security context compatibility |
| `Unauthorized` / `Forbidden` | Check IAM identity, EKS access entry and Kubernetes policy/RBAC; verify CLI and CI credentials are the intended identities |
| `Pending` pods | `kubectl describe pod ...` for resources, taints, scheduling, node capacity; confirm nodes `Ready` |
| EKS access entry 409 | Principal entry already exists; don't recreate account-root principal; inspect `aws eks list-access-entries` |
| Terraform S3 lock 412 | Another/stale state lock; check EKS-specific `.tflock` and active processes before force-unlock |
| HPA metrics `<unknown>` | Metrics Server or CPU requests/metric availability issue; test `kubectl top pods` |
| `port-forward` fails | Check Service exists, selectors match pod labels, ready endpoints exist, and local port isn't in use |

Useful commands:

```bash
kubectl get all -n sre-demo
kubectl get events -n sre-demo --sort-by=.lastTimestamp
kubectl describe pod -n sre-demo POD_NAME
kubectl logs -n sre-demo deployment/sre-web --tail=100
kubectl get deployment sre-web -n sre-demo -o jsonpath='{.spec.template.spec.containers[*].image}'
aws eks describe-nodegroup --cluster-name relx-dev-eks \
  --nodegroup-name relx-dev-nodes --region us-east-1 \
  --query 'nodegroup.health'
```

## 12. Optional: external access with an ALB

This package **does not** install AWS Load Balancer Controller or an Ingress. The following is a **separate, optional extension**, not something already deployed or tested.

1. Ensure the VPC has **two public subnets in distinct AZs**, each with a default route to the Internet Gateway. For automatic discovery, tag the intended public subnets `kubernetes.io/role/elb = 1`; confirm the controller can discover them.
2. Install the **AWS Load Balancer Controller** with the appropriate IAM permissions and cluster identity configuration (IRSA or EKS Pod Identity) using the officially supported Helm chart and IAM policy for your controller version. Don't give the controller unrestricted `AdministratorAccess`.
3. Keep `Service/sre-web` as `ClusterIP`. Use an Ingress with `alb.ingress.kubernetes.io/scheme: internet-facing`, `alb.ingress.kubernetes.io/target-type: ip`, and `ingressClassName: alb` routing path `/` to Service `sre-web` on port `80`.
4. Apply the Ingress, inspect its events, and wait for the `ADDRESS` field: `kubectl get ingress -n sre-demo`.
5. Check that the AWS ALB target group reports healthy targets. Test with `curl -i http://<actual-ingress-dns>/` and verify the Hello World response. For HTTPS, attach an ACM certificate and configure the listener appropriately.
6. **Delete the Ingress and wait for the controller to delete the ALB before destroying EKS**, so an orphaned load balancer does not continue billing.

Do not confuse this optional EKS ALB with the existing mandatory EC2 ALB. A public Ingress introduces additional charges and security exposure; port-forwarding remains sufficient for the base EKS bonus.

## 13. Security and operational considerations

The sample EKS cluster enables public API access from `0.0.0.0/0` so GitHub-hosted runners can reach it; **IAM authentication still applies**, but that exposure is a demo tradeoff. Restrict the public endpoint CIDRs or use private-only API access and VPC runners for stronger security. Separate CI deployment permissions from cluster administration. Keep ECR private, pin reviewed image versions, scan for vulnerabilities, and use immutable tags or image digests. Never commit AWS secret keys or real application credentials. Terraform remote state can contain sensitive data; guard the bucket, enable versioning, and restrict IAM access.

The bonus does not currently use AWS Secrets Manager. If you implement the separate secrets-management bonus, store credentials there and grant least-privilege retrieval permission to the workload identity; do not print secret values in logs or place them in plaintext Terraform state.

## 14. Clean up to prevent charges

**Confirm you are targeting `relx-dev-eks` and the separate EKS Terraform state before running destructive commands.** Keep the original EC2 assessment resources untouched.

From repository root:

```bash
# Remove optional workloads before destroying the cluster.
# If you created an Ingress, delete it first and confirm the ALB is removed.
# Then remove namespaced resources (works even if YAML contains placeholders):
kubectl -n sre-demo delete hpa sre-web --ignore-not-found
kubectl -n sre-demo delete deployment sre-web --ignore-not-found
kubectl -n sre-demo delete service sre-web --ignore-not-found
kubectl delete namespace sre-demo --ignore-not-found

cd terraform-eks
terraform init -backend-config=backend.hcl
terraform plan -destroy
terraform destroy
```

If you prefer explicit resource deletion (also useful when source YAML has changed), the equivalent commands are:

```bash
kubectl -n sre-demo delete deployment sre-web --ignore-not-found
kubectl -n sre-demo delete service sre-web --ignore-not-found
kubectl delete namespace sre-demo --ignore-not-found
```

**ECR cleanup:** Terraform's ECR repository has `force_delete = false`, so `terraform destroy` may fail if images remain. After verifying the exact repository name, delete its images before retrying destroy:

```bash
aws ecr list-images --repository-name relx-dev-eks-web --region us-east-1
# Delete known image tags/digests using aws ecr batch-delete-image, then retry terraform destroy.
```

The independently created `relx-web` ECR repository from Route A is **not managed by the packaged EKS Terraform**; clean it up separately only if you no longer need it, after verifying its contents. **Do not destroy the shared VPC or NAT as part of the EKS teardown**, because your mandatory EC2 assessment may still use them. Do not delete the S3 state bucket or original EC2 resources as part of this EKS cleanup. Verify in AWS Console that the EKS cluster, node group, EBS resources, and optional ALB have been removed; charges can continue for resources left behind.

## 15. Acceptance checklist

- [ ] Docker image builds and returns `Hello, World!` locally
- [ ] ECR image URI/tag exists with the worker node's CPU architecture
- [ ] EKS cluster and two managed worker nodes are healthy
- [ ] EKS uses an independent S3 Terraform state key
- [ ] Namespace `sre-demo` exists
- [ ] `Deployment/sre-web` has two Ready replicas
- [ ] `Service/sre-web` has endpoints
- [ ] `curl http://localhost:8082/` returns Hello World through port-forward
- [ ] `scripts/eks-smoke-test.sh` passes
- [ ] GitHub Actions builds, pushes, deploys and tests a new image
- [ ] Optional approval gate is demonstrably enforced
- [ ] Costs and resource cleanup steps are documented and tested
