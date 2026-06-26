# terraform/storage/variables.tf

variable "subscription_id" {
  description = "Azure subscription ID (same one in secrets/terraform.tfvars)."
  type        = string
  sensitive   = true
}

variable "prefix" {
  description = "Naming prefix applied to every resource."
  type        = string
  default     = "gaire-platform"
}

variable "disk_size_gb" {
  description = "Size of each worker's Longhorn data disk, in GB."
  type        = number
  default     = 50
}

variable "disk_type" {
  description = "Managed disk storage type for the data disks."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "lun" {
  description = "LUN for the data disk on each worker (one disk per worker, so a single value is fine)."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "gaire-platform"
    managed_by = "terraform"
  }
}
