variable "cidr_block" {
    type = string
    default = "10.0.0.0/16"
    description = "vpc cidr block"
}

variable "project-name" {
    type = string
    default = "relx"
    description = "relx project"
}

variable "environment" {
    type = string
    default = "dev"
    description = "current environment"
}

variable "subnet-cidr" {
    type = string
    default = "10.0.1.0/24"
    description = "cidr range of subnet"
}

variable "privatesubnet-cidr" {
    type = string
    default = "10.0.2.0/24"
    description = "cidr range of subnet"
}

variable "admin_cidr" {
  type        = string
  description = "Your public IPv4 address with /32 suffix, for example 203.0.113.4/32"

  validation {
    condition = can(cidrhost(var.admin_cidr, 0)) && can(regex("/32$", var.admin_cidr))

    error_message = "Provide a valid IPv4 /32 admin CIDR."
  }
}