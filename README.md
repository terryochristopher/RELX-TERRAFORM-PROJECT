# RELX-TERRAFORM-PROJECT
Automated AWS infrastructure using Terraform, featuring secure networking, Auto Scaling, monitoring, and CI/CD.

# AWS Site Reliability Engineering — Terraform Infrastructure

A hands-on Senior Site Reliability Engineering (SRE) project demonstrating automated AWS infrastructure provisioning, private application hosting, load balancing, CPU-based Auto Scaling, observability, and a review-gated CI/CD deployment workflow.

The project deploys a **Hello, World!** web application on Amazon EC2 instances in private subnets and makes it accessible through an internet-facing Application Load Balancer (ALB). Infrastructure is managed with Terraform, while EC2 user data handles application setup and CloudWatch Agent installation.

> **Status:** Infrastructure-as-code project / deployment exercise. Deployment, tests, and alert delivery must be verified in the target AWS account; this README does not imply they have already passed.

## Architecture

```text
                            Internet / Browser
                                    |
                              Internet Gateway
                                    |
                    +---------------+---------------+
                    |            AWS VPC             |
                    |                                |
Admin laptop --SSH--> Bastion Host (Public Subnet)   |
                    |                                |
                    | Public Subnet A  Public Subnet B|
                    |        \         /              |
                    |         Public ALB              |
                    |             | HTTP :80          |
                    |       Target Group              |
                    |          /     \                |
                    | Private Subnet A  Private Subnet B
                    |       EC2 web instances         |
                    |       Auto Scaling Group        |
                    |        min 1 / max 3            |
                    |                                |
                    | Private instance outbound       |
                    | -> NAT Gateway (public subnet)  |
                    +--------------------------------+
                              |               |
                         CloudWatch         SNS email
                     CPU / memory metrics   notifications

GitHub Actions -> AWS OIDC role -> Terraform -> S3 remote state
```

**Traffic paths:** Users reach the ALB on HTTP port 80; the ALB forwards to the private web instances on port 80. Administrative SSH reaches the Bastion host only from the configured administrator `/32` IP, then reaches private instances from the Bastion security group. Private instances use NAT for outbound package downloads and CloudWatch API access. The ALB requires two public subnets in different Availability Zones.

## Services and tools

| Component | Purpose |
| --- | --- |
| Terraform | Declarative infrastructure provisioning and management |
| Amazon VPC | Isolated network with public and private subnets |
| Internet Gateway | Public subnet internet routing |
| NAT Gateway | Outbound internet access for private instances |
| Amazon EC2 (`t2.micro` by default) | Bastion host and private web servers |
| Application Load Balancer | Public HTTP entry point and target health checks |
| EC2 Auto Scaling Group | Maintains 1–3 web instances; scales based on CPU |
| CloudWatch Agent and alarms | Memory collection, CPU monitoring, threshold alerts |
| Amazon SNS | Email notifications for configured alarms |
| IAM role / instance profile | Temporary credentials for web-instance metric publishing |
| Amazon S3 | Versioned, encrypted remote Terraform state |
| GitHub Actions | Terraform checks, plan, approval-gated apply, smoke testing |

## Repository structure

```text
relx-sre/
├── .github/
│   └── workflows/
│       └── terraform.yml
├── scripts/
│   └── smoke-test.sh
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── versions.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── templates/
│       └── user_data.sh.tftpl
├── .gitignore
└── README.md
```

> If your own repository uses a different layout (for example, `.tf` files at the repository root or a separate `backend.tf`), run the Terraform commands from **that** directory and adjust paths as needed. The file names above reflect the supplied starter structure.

## Prerequisites

Before deployment, ensure that you have:

- An AWS account, a selected deployment region (examples below use `us-east-1`), and permissions to create VPC, EC2, IAM, ALB, Auto Scaling, CloudWatch, SNS, S3 and related resources.
- Terraform **1.6 or later** (and an AWS provider compatible with `versions.tf`), AWS CLI v2, Git, `curl`, and an SSH client installed.
- AWS credentials configured locally using an AWS profile, IAM Identity Center/SSO, or another supported short-lived credential method. Do not commit access keys.
- A public IPv4 address to permit SSH to the Bastion host, expressed as a `/32` CIDR.
- An SSH public/private key pair. Only the **public** key is passed to Terraform; keep the private key local.
- A valid email address to receive Amazon SNS alerts; the subscription requires confirmation.
- A globally unique, separately managed S3 bucket for Terraform state.
- Awareness that **this exercise can incur AWS charges**, especially for the NAT Gateway, ALB, public IPv4 addresses, EC2/EBS and CloudWatch usage.

Check tools and AWS identity:

```bash
terraform --version
aws --version
aws sts get-caller-identity
```

Find your current public IPv4 address:

```bash
curl -4 https://checkip.amazonaws.com
```

Create an SSH key if needed:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/relx-bastion
cat ~/.ssh/relx-bastion.pub
```

Your private key is `~/.ssh/relx-bastion` and must **never** be added to GitHub. If your local network changes, update `admin_cidr` to your new public IP before attempting SSH again.

## 1. Clone and configure the project

```bash
git clone https://github.com/<YOUR-USERNAME>/<YOUR-REPOSITORY>.git
cd <YOUR-REPOSITORY>
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform/terraform.tfvars` with values appropriate to your AWS account and machine:

```hcl
aws_region         = "us-east-1"
project_name       = "sre-exercise"
admin_cidr         = "YOUR_PUBLIC_IPV4/32"
ssh_public_key     = "ssh-ed25519 YOUR_REAL_PUBLIC_KEY"
alert_email        = "your-email@example.com"
enable_nat_gateway = true
```

The example addresses and key text are placeholders and will not work without replacement. An optional variable `instance_type` defaults to `t2.micro`; `vpc_cidr` defaults to `10.42.0.0/16` in the supplied starter. Never commit real secrets or generated Terraform state/plan files. `ssh_public_key` is public by design, but keeping personal machine-specific values out of the repository is still good practice.

## 2. Bootstrap the S3 backend

The remote-state bucket must exist **before** Terraform initializes its backend. Keep this bucket outside the application Terraform configuration so that destroying the application does not also destroy its state.

```bash
export AWS_REGION=us-east-1
export STATE_BUCKET="replace-with-globally-unique-sre-state-bucket"

aws s3api create-bucket \
  --bucket "$STATE_BUCKET" \
  --region "$AWS_REGION"
```

For regions other than `us-east-1`, create the bucket with the appropriate `--create-bucket-configuration LocationConstraint=<REGION>`.

Enable public-access blocking, versioning, and server-side encryption:

```bash
aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```


The supplied `versions.tf` declares an S3 backend with configuration supplied at initialization. S3 native state locking uses `use_lockfile=true`, which requires a Terraform version that supports that option (Terraform **1.10+**). **Use Terraform 1.10 or later for the commands below**, even though the original starter's minimum required version is 1.6. Alternatively, update the backend configuration for an older supported locking approach.

From the `terraform/` directory:

```bash
terraform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=relx/sre/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

If you previously initialized **local state** and need to move it to S3, use `terraform init -migrate-state` with the same backend arguments. If switching between remote backends, first inspect the current state and backend carefully; do not overwrite or abandon existing state.

### Backend access permissions

The identity running Terraform needs access to list the relevant bucket prefix and read/write its state object. With native S3 state locking, it also needs to create, read and delete the associated `.tflock` object. Grant these permissions only to approved deployment identities; avoid making the bucket public.

## 3. Validate and deploy with Terraform

From `terraform/`:

```bash
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
```

Review the planned resources, including the VPC/subnets, NAT Gateway, ALB, Bastion host, Auto Scaling Group, IAM role/profile, CloudWatch alarms and SNS topic/subscription. If the plan is correct, apply it:

```bash
terraform apply tfplan
```

The first deployment may take a few minutes because NAT, ALB, EC2 initialization and target health checks are not instant. **Do not treat a successful `apply` as proof that the application is healthy.**

View the Terraform outputs:

```bash
terraform output
terraform output -raw alb_url
terraform output -raw bastion_public_ip
terraform output -raw asg_name
```

The supplied starter defines `alb_url`, `bastion_public_ip`, `asg_name`, `sns_topic_arn` and `vpc_id` outputs. If your local code uses other names, check `outputs.tf` and adjust the commands.

## 4. Test the Hello World application

The EC2 user-data script creates `/opt/sre-app/index.html` and a systemd service named `sre-web`, which serves it using Python's built-in HTTP server on port 80.

Open the URL from:

```bash
terraform output -raw alb_url
```

Expected page content:

```text
Hello, World!
```

Run an automated HTTP check:

```bash
curl --fail --show-error "$(terraform output -raw alb_url)"
```

Or run the included smoke test from `terraform/`:

```bash
bash ../scripts/smoke-test.sh "$(terraform output -raw alb_url)"
```


The smoke test retries until the ALB responds with `Hello, World!` or returns a failure. This confirms that the ALB, target group and web service can deliver the page; it does not by itself prove high availability or Auto Scaling.

### Check target group health

In AWS Console, navigate to **EC2 → Target Groups → your web target group → Targets**. Confirm at least one target is **Healthy**. If targets remain unhealthy, investigate security groups, port 80, instance user data and ALB health check path `/`.

## 5. Test Bastion and private-subnet access

Confirm that the Bastion host has a public IP and that its security group permits inbound TCP 22 **only from `admin_cidr`**. Private web instances should not have publicly routable IP addresses.

Retrieve the public Bastion IP:

```bash
terraform output -raw bastion_public_ip
```

Find a private web instance IP in the EC2 console (or via `aws ec2 describe-instances`). Then connect **through** Bastion using SSH ProxyJump without copying your private key onto the Bastion:

```bash
chmod 600 ~/.ssh/relx-bastion
ssh -i ~/.ssh/relx-bastion \
  -J ec2-user@<BASTION_PUBLIC_IP> \
  ec2-user@<PRIVATE_WEB_INSTANCE_IP>
```

These commands assume the selected Amazon Linux AMI uses `ec2-user`. Once connected, inspect the application and initialization:

```bash
sudo systemctl status sre-web
curl --fail http://localhost/
sudo tail -n 100 /var/log/cloud-init-output.log
sudo systemctl status amazon-cloudwatch-agent
```

The web instances' security group intentionally allows HTTP port 80 from **both** the ALB security group and Bastion security group. This is necessary to reconcile the assessment's Bastion-only HTTP wording with the separate requirement for a working ALB. There is **no** public internet CIDR directly permitted to reach the web instances on port 80.

## 6. Verify Auto Scaling

The supplied ASG configuration uses:

| Configuration | Value |
| --- | --- |
| Minimum instances | 1 |
| Desired instances | 1 |
| Maximum instances | 3 |
| Scaling policy | Target tracking |
| Metric | `ASGAverageCPUUtilization` |
| CPU target | 70% |
| Target group | Web ALB target group |

Check the Auto Scaling Group in **EC2 → Auto Scaling Groups** and verify that the active instances are registered with the ALB target group.

To exercise scale-out, generate a **controlled** CPU workload on a test web instance or use a suitable load generator, monitor the CloudWatch CPU metrics and **EC2 → Auto Scaling Groups → Activity**, and check whether additional instances are launched. Keep the test bounded to avoid unnecessary charges, and do not assume a simple Hello World HTTP request will be CPU-intensive enough to trigger scaling. Let the instances return to normal utilization and observe the scale-in behavior. A target of 70% is an approximate control objective, not a strict trigger at exactly 70.0%.

## 7. Verify CloudWatch and SNS

### CPU monitoring

EC2 publishes CPU utilization metrics without requiring the CloudWatch Agent. The project configures a separate alarm above **70% CPU**, based on its evaluation settings, and sends alarm actions to the SNS topic.

### Memory monitoring

The EC2 user-data script installs and configures the CloudWatch Agent to publish `mem_used_percent` under the custom namespace **`SREExercise/Web`**, aggregated using the `AutoScalingGroupName` dimension. The project also defines an **80% memory alarm** as an additional safeguard.

To inspect metrics: **CloudWatch → Metrics**, then look under `AWS/EC2` for CPU utilization and `SREExercise/Web` for memory metrics. Allow time for the agent to initialize and publish its first datapoints. If memory metrics do not appear, check the agent service, configuration file, IAM instance profile permissions and private-instance egress.

### Email alerts

After applying Terraform, locate the **AWS SNS subscription confirmation email** and click its confirmation link. Until confirmed, that email address will not receive SNS alarm notifications. In **CloudWatch → Alarms**, check alarm state and configured SNS actions.

For a non-disruptive notification test, you can publish a sample message to the topic (requires permission to `sns:Publish`):

```bash
aws sns publish \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --message "relx SRE project: SNS notification test" \
  --subject "SRE Exercise Test"
```

This tests SNS delivery, **not** the CloudWatch alarm evaluation. To test an actual alarm transition, use a controlled workload and observe the alarm state change.

## 8. CI/CD with GitHub Actions

The supplied workflow is `.github/workflows/terraform.yml`. It supports validation, planning, manual approval of apply, and an ALB smoke test. Deployment credentials should be obtained through GitHub's **OIDC federation with AWS IAM**, not long-lived AWS access keys stored in GitHub.

Under **GitHub repository → Settings → Secrets and variables → Actions → Variables**, configure:

| Variable | Example / use |
| --- | --- |
| `AWS_REGION` | `us-east-1` |
| `AWS_GITHUB_ROLE_ARN` | AWS IAM role ARN for GitHub OIDC |
| `TF_STATE_BUCKET` | Precreated S3 backend bucket name |
| `ADMIN_CIDR` | Current public IPv4 address with `/32` |
| `SSH_PUBLIC_KEY` | Full text of the SSH **public** key |
| `ALERT_EMAIL` | SNS notification email |

Create the GitHub OIDC provider and a trust-restricted AWS IAM role separately, scoped to this repository and allowed branches/environments. Grant the role required AWS provisioning permissions and minimal S3 backend access. The starter **does not create this deployment role for you**.

### Required approval configuration

In **Settings → Environments**, create an environment named `production` and configure **Required reviewers** where your GitHub plan/repository settings support it. Restrict deployment branches appropriately. In the workflow, the apply job targets this environment; approval must be configured in GitHub settings to be enforced. A workflow comment or environment name alone does **not** establish a functioning approval gate.

### Running the workflow

- **Pull request:** Runs Terraform format/initialization/validation and a plan when the necessary AWS OIDC and repository-variable access is available. Fork-based pull requests may require additional handling.
- **Manual plan:** Go to **Actions → Terraform validate, plan, apply and smoke test → Run workflow**, then select `plan`.
- **Manual apply:** Select `apply`. After the plan job, approve the `production` environment request. The workflow applies the saved Terraform plan and runs the ALB Hello World smoke test.
- **Manual destroy:** Select `destroy`, review/approve the `production` environment request, then allow Terraform to remove the managed infrastructure.

> **Workflow review note:** The supplied starter runs `terraform fmt -recursive` in the validation job, which formats files but does not fail the job for formatting drift. For strict CI validation, change this step to `terraform fmt -check -recursive`. Also ensure the Terraform version installed in CI supports `use_lockfile=true`, and review the IAM/OIDC trust policy before public repository use.

### Suggested commit history

```text
chore: initialize Terraform provider and S3 backend
feat: provision VPC, subnets, internet and NAT routing
feat: add Bastion access and private EC2 security groups
feat: deploy Hello World service with user data
feat: configure ALB, target group and Auto Scaling
feat: add CloudWatch monitoring and SNS alerts
ci: add Terraform checks and approval-gated deployment
 docs: document setup, testing, security and teardown
```

## 9. Security and cost decisions

**Security:** Private web instances have no direct public ingress. SSH to the Bastion host is limited to the administrator's IP. The web security group allows HTTP only from the ALB/Bastion security groups. EC2 EBS roots are encrypted, IMDSv2 is required, and a dedicated instance role grants narrow CloudWatch permissions. Terraform state must be private, encrypted, versioned and access-restricted. The demo uses plain HTTP for simplicity; production deployments should use **HTTPS with an ACM certificate** and redirect HTTP to HTTPS.

**Cost:** `t2.micro` is specified to match the exercise, but no particular EC2 configuration is guaranteed to be free under your account's current Free Tier eligibility. **NAT Gateway, ALB, public IPv4 addresses, EBS storage, CloudWatch, and S3 may all incur charges.** The starter uses **one NAT Gateway** to reduce expenses, but this is a single-AZ outbound dependency. A production high-availability design might use one NAT Gateway per AZ or private connectivity alternatives.

The NAT Gateway is used because private web instances install software and send metrics over the network during boot. Do **not** disable NAT in the current implementation unless you also provide another working path for packages and CloudWatch (for example, prebuilt images and properly scoped VPC endpoints). Keep the exercise deployed only while needed, and review AWS Billing/Cost Explorer regularly.

## 10. Troubleshooting

| Symptom | What to check |
| --- | --- |
| `terraform init` fails | S3 bucket name/region, credentials, state object and `.tflock` permissions, Terraform version |
| Subnet overlap error | Ensure each subnet has a non-overlapping CIDR within the VPC |
| `admin_cidr` prompt | Set a valid public IPv4 `/32` in `terraform.tfvars` or pass it using `-var` |
| ALB returns 503 | Target group health, ASG instance initialization, HTTP port 80, web service status |
| SSH to Bastion fails | Current public IP, security-group rule, key pair, Bastion public IP and `ec2-user` |
| Private instance cannot install packages | NAT Gateway status, private default route, NAT public routing, DNS and egress security rules |
| Memory metrics absent | CloudWatch Agent logs/status, instance-profile permissions and outbound connectivity |
| SNS emails absent | Confirm subscription, topic ARN, alarm actions and actual alarm state |
| GitHub deployment fails | OIDC role/trust configuration, repository variables, AWS access, protected environment and Terraform version |

## 11. Cleanup: avoid unwanted charges

**Destroy the infrastructure before deleting the S3 state or repository settings.** From the same Terraform directory and backend used for deployment:

```bash
cd terraform
terraform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=relx/sre/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="use_lockfile=true"
terraform plan -destroy
terraform destroy
```

Review the destroy plan and confirm the operation when prompted. If you prefer GitHub Actions, use the workflow's `destroy` action and protected-environment approval, then verify the run succeeds.

Afterward, verify in AWS that the following resources are gone: **ASG and EC2 instances, ALB/target group, Bastion host, NAT Gateway, Elastic IP, subnets/VPC, CloudWatch alarms, SNS topic and the project IAM resources**. Inspect the AWS console for resources that might have been created manually or left behind after failed Terraform runs. If destruction fails, fix the cause and rerun rather than deleting the state file.

The S3 state bucket is intentionally **not** destroyed by application Terraform. Keep it if you plan to redeploy. If you are completely finished and have verified successful teardown, you may remove its objects and versions, then delete the bucket using an administrator-approved process. Be careful: versioned objects require deleting **all versions and delete markers** before a bucket can be deleted. Also decommission any temporary GitHub deployment IAM role/OIDC trust created specifically for this exercise. Review AWS Billing afterward for lingering chargeable resources.

## Assumptions and limitations

- The web app is a **static demonstration page**, not a production service. Python `http.server` is used for simplicity, not hardened production hosting.
- The ALB is internet-facing on **HTTP port 80**, matching the exercise; HTTPS is recommended for production.
- Two public and two private subnets are used across two Availability Zones. The ASG starts with one instance and can grow to three.
- CPU-based scaling is required and implemented; memory collection and a separate memory alarm are included, but **memory-based Auto Scaling is not implemented**.
- The assessment mentions HTTP from Bastion only, but also requires public ALB traffic. The web server therefore accepts port 80 from both **ALB and Bastion security groups**, with no direct public HTTP rule.
- The S3 state backend and GitHub OIDC deployment role are **bootstrap dependencies** maintained separately from the application stack.
- Docker/ECS/EKS, Terratest and Secrets Manager bonus features are **not included** in the starter implementation.
- Infrastructure creation, ALB availability, GitHub reviewer enforcement and SNS email confirmation have to be verified in the deployment account; this repository's configuration alone does not prove successful tests.

---