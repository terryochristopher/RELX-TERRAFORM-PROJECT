variable "cidr_block" {
  type        = string
  default     = "10.0.0.0/16"
  description = "vpc cidr block"
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

variable "subnet-cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "cidr range of subnet"
}

variable "privatesubnet-cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "cidr range of subnet"
}

variable "admin_cidr" {
  type        = string
  description = "Your public IPv4 address with /32 suffix"

  validation {
    condition = can(cidrhost(var.admin_cidr, 0)) && can(regex("/32$", var.admin_cidr))

    error_message = "Provide a valid IPv4 /32 admin CIDR."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key"
  sensitive   = true
}
variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "size and type of instance"
}

variable "aws_region" {
  type        = string
  default = "us-east-1"
  description = "(optional) describe your variable"
}

variable "alert_email" {
  type        = string
  description = "Email to subscribe to SNS alerts"
}