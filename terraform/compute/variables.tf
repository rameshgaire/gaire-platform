# terraform/compute/variables.tf

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

variable "admin_username" {
  description = "Linux admin user created on every node."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_paths" {
  description = "Public keys installed on every node's authorized_keys (must have at least one)."
  type        = list(string)
  default = [
    "~/.ssh/gaire-platform-admin.pub",   # interactive / admin SSH
    "~/.ssh/gaire-platform-ansible.pub", # Ansible automation
  ]
}

variable "master_vm_size" {
  description = "VM size for the K3s master."
  type        = string
  default     = "Standard_B2als_v2" # 2 vCPU / 4 GB
}

variable "worker_vm_size" {
  description = "VM size for each K3s worker."
  type        = string
  default     = "Standard_B2als_v2" # 2 vCPU / 4 GB
}

variable "master_private_ip" {
  description = "Static private IP for the master (must be in the private subnet, above .3)."
  type        = string
  default     = "10.10.2.10"
}

variable "workers" {
  description = "Map of worker nodes -> their static private IPs."
  type = map(object({
    private_ip = string
  }))
  default = {
    worker01 = { private_ip = "10.10.2.11" }
    worker02 = { private_ip = "10.10.2.12" }
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size per node (Longhorn data disks come from the storage module)."
  type        = number
  default     = 30
}

variable "os_disk_type" {
  description = "OS disk storage type."
  type        = string
  default     = "StandardSSD_LRS"
}

variable "image_publisher" {
  description = "Marketplace image publisher."
  type        = string
  default     = "Canonical"
}

variable "image_offer" {
  description = "Marketplace image offer (Ubuntu 24.04 LTS)."
  type        = string
  default     = "0001-com-ubuntu-server-jammy"
}

variable "image_sku" {
  description = "Image SKU. 'server' = Gen2, 'server-gen1' = Gen1."
  type        = string
  default     = "22_04-lts-gen2"
}

variable "image_version" {
  description = "Image version."
  type        = string
  default     = "latest"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project    = "gaire-platform"
    managed_by = "terraform"
  }
}
