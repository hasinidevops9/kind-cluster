# Region from this workstation's AWS CLI config (~/.aws/config).
variable "aws_region" {
  type        = string
  description = "AWS region. Defaults to the configured CLI region."
  default     = "us-east-1"

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must be set. This workstation's AWS CLI config uses us-east-1."
  }
}

variable "instance_type" {
  type        = string
  description = "Kind EC2 instance type. m7i-flex.large is 2 vCPU and 8 GiB."
  default     = "m7i-flex.large"
}

variable "root_volume_gb" {
  type        = number
  description = "Root gp3 volume size in GiB."
  default     = 40

  validation {
    condition     = var.root_volume_gb >= 40
    error_message = "root_volume_gb must be at least 40."
  }
}

variable "ami_owner" {
  type        = string
  description = "Owner of the RHEL 9 DevOps Practice AMI."
  default     = "973714476881"
}

variable "ami_name" {
  type        = string
  description = "RHEL-compatible AMI name."
  default     = "Redhat-9-DevOps-Practice"
}

# This AMI enables password login for ec2-user.
variable "ssh_user" {
  type        = string
  description = "SSH user for the RHEL practice AMI."
  default     = "ec2-user"
}

# Set TF_VAR_ssh_password or pass -var / a gitignored tfvars file.
# sensitive hides the value in plan output. Terraform still stores it in state.
variable "ssh_password" {
  type        = string
  description = "SSH password for the RHEL practice AMI. Supply it at runtime."
  sensitive   = true

  validation {
    condition     = length(var.ssh_password) > 0
    error_message = "Set ssh_password at runtime, for example with TF_VAR_ssh_password."
  }
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to open SSH. The lab workstation public address is the default."
  default     = "54.152.240.135/32"

  validation {
    condition     = can(cidrhost(var.ssh_ingress_cidr, 0))
    error_message = "ssh_ingress_cidr must be a valid CIDR block."
  }
}

variable "kind_cluster_name" {
  type        = string
  description = "Single-node Kind cluster name."
  default     = "kind"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.kind_cluster_name))
    error_message = "kind_cluster_name must be a lowercase DNS label."
  }
}
