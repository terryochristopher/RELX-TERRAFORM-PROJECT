variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "(optional) describe your variable"
}

variable "project-name" {
  type        = string
  default     = "relx"
  description = "relx project"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "current environment"
}

variable "cidr_block" {
  type        = string
  default     = "10.0.0.0/16"
  description = "vpc cidr block"
}

variable "enable_nat_gateway" {
  type        = bool
  default     = true
  description = "Required by user data package installation and memory monitoring. Incurs hourly/data costs."
}

variable "project_name" {
  type        = string
  description = "Short name used for new resources."
  default     = "relx-dev"
}
variable "vpc_id" {
  type        = string
  description = "Existing VPC ID from the mandatory Terraform stack."
}
variable "private_subnet_ids" {
  type        = list(string)
  description = "At least two private subnet IDs in different AZs; must reach ECR/EKS via NAT or endpoints."
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnet IDs in different AZs."
  }
}
variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.small"]
  description = "EKS managed node group types; these incur charges."
}
variable "node_desired_size" {
  type    = number
  default = 2
}
variable "eks_admin_principal_arn" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional IAM user/role ARN to grant EKS cluster-admin access (e.g. GitHub Actions IAM user)."
}
