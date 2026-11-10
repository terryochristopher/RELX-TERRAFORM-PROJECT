# GitHub Actions setup for PointClickCare SRE

This workflow assumes the starter project layout: Terraform files in `terraform/` and the test in `scripts/smoke-test.sh`. If your Terraform `.tf` files are in the repository root, remove the `working-directory: terraform` defaults, change the `terraform/**` path filter, change the plan artifact path, and update the smoke test path accordingly.

## Before first run

1. Create the S3 state bucket separately; enable versioning, encryption, public-access blocking. Keep it outside the stack being destroyed. Ensure `terraform/versions.tf` has `backend "s3" {}` and AWS provider.
2. Configure AWS IAM OIDC provider `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com` (once per account).
3. Create AWS plan and apply IAM roles with trust restricted to your GitHub repo, and permissions scoped to relevant AWS services and state bucket. For the plan role, use subject `repo:OWNER/REPO:ref:refs/heads/main`. For the apply role, use subject `repo:OWNER/REPO:environment:production`. Both require audience `sts.amazonaws.com`. Do not use wildcard repository trust. Plan role needs read/discovery plus access to remote S3 state and lock objects; it may need extra scoped write access depending on what resources Terraform refreshes or evaluates. Apply role needs permissions to create/update/delete the specific project resources plus state access. IAM role and policy creation can require `iam:PassRole`, role creation, and role policy permissions. Restrict those to named project roles, not unrestricted IAM. Grant `s3:ListBucket` for bucket and `s3:GetObject`, `s3:PutObject` on state; lock file additionally requires `s3:DeleteObject` for `.tflock`.
4. Under **GitHub Settings → Secrets and variables → Actions → Variables**, set: `AWS_REGION`, `TF_STATE_BUCKET`, `ADMIN_CIDR` (public IPv4 `/32`), `SSH_PUBLIC_KEY` (full `.pub` contents), `ALERT_EMAIL`, `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`. A public SSH key is not secret. Avoid putting private SSH keys or AWS access keys in GitHub.
5. Under **Settings → Environments**, create `production`, restrict deployment branches to `main`, and enable required reviewers if available for your plan/repository type. Without required reviewers, `environment: production` does **not** itself guarantee manual approval.
6. Verify the repository has `terraform/outputs.tf` defining `alb_url`, and `scripts/smoke-test.sh` is present. The smoke test waits up to ~5 minutes for ALB health and searches for `Hello, World!`.
7. Ensure `.gitignore` excludes `.terraform/`, `*.tfstate*`, `*.tfplan`, `tfplan`, `*.tfvars` (if locally sensitive), and `.terraform.lock.hcl` **should normally be committed** for reproducible providers.

## Run

- Push a pull request: `terraform fmt -check -recursive`, `terraform init -backend=false`, and `terraform validate` run without AWS authentication.
- Go to **Actions → Terraform CI/CD → Run workflow**, select `main` and `plan` to review intended resources.
- Select `apply` to create a saved plan, upload a short-lived artifact, then pause for production reviewer approval before applying that **same plan** and testing the ALB. Plans can contain sensitive data; only authorized repo users should access artifacts.
- Select `destroy` and enter `DESTROY`; production approval gates teardown. S3 backend bucket is not deleted automatically.

## Important safety notes

- AWS costs are possible for ALB, NAT, public IPv4, EBS, and monitoring. Destroy the application after testing.
- GitHub approval features vary by GitHub plan and repository visibility. Verify `production` actually enforces a reviewer gate before considering this a compliant manual approval step.
- Do not merge untrusted changes to the main branch without review. Apply role trust is environment-scoped and workflow jobs must be protected by branch controls, CODEOWNERS and reviews.
- The workflow is not executed against your AWS account here. Run `terraform validate`, review OIDC policies and confirm a plan before applying.
