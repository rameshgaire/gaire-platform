# terraform/networking/variables.tf

variable "subscription_id" {
  description = "Azure subscription ID. Put this in secrets/terraform.tfvars (never commit it)."
  type        = string
  sensitive   = true
}

variable "prefix" {
  description = "Naming prefix applied to every resource."
  type        = string
  default     = "gaire-platform"
}

variable "location" {
  description = "Azure region. Change to whatever is closest to you."
  type        = string
  default     = "Australia East"
}

variable "vnet_address_space" {
  description = "Address space for the VNET."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "public_subnet_prefixes" {
  description = "Public subnet prefix (reserved for a future load balancer / gateway)."
  type        = list(string)
  default     = ["10.10.1.0/24"]
}

variable "private_subnet_prefixes" {
  description = "Private subnet prefix (all K3s nodes live here)."
  type        = list(string)
  default     = ["10.10.2.0/24"]
}

variable "ssh_source_address" {
  description = "CIDR allowed to reach SSH (22). Lock this to your control node's /32, not '*'."
  type        = string
  default     = "*"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "gaire-platform"
    managed_by = "terraform"
  }
}
