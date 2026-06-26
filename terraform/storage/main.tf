# terraform/storage/main.tf

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# ---------------------------------------------------------------------------
# Read networking (resource group + location) and compute (worker VM IDs).
# ---------------------------------------------------------------------------
data "terraform_remote_state" "networking" {
  backend = "local"
  config = {
    path = "../networking/terraform.tfstate"
  }
}

data "terraform_remote_state" "compute" {
  backend = "local"
  config = {
    path = "../compute/terraform.tfstate"
  }
}

locals {
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group_name
  location            = data.terraform_remote_state.networking.outputs.location

  # map of worker name -> VM resource ID, e.g. { worker01 = "/subscriptions/.../worker01" }
  worker_vm_ids = data.terraform_remote_state.compute.outputs.worker_vm_ids
}

# ---------------------------------------------------------------------------
# One empty managed data disk per worker (Longhorn consumes these)
# ---------------------------------------------------------------------------
resource "azurerm_managed_disk" "longhorn" {
  for_each = local.worker_vm_ids

  name                 = "${var.prefix}-k3s-${each.key}-longhorn-disk"
  resource_group_name  = local.resource_group_name
  location             = local.location
  storage_account_type = var.disk_type
  create_option        = "Empty"
  disk_size_gb         = var.disk_size_gb
  tags                 = var.tags
}

# ---------------------------------------------------------------------------
# Attach each disk to its worker VM.
# caching = "None" is the safe choice for Longhorn: it manages its own
# replication/consistency, and host write-caching could risk integrity on
# a host failure.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_machine_data_disk_attachment" "longhorn" {
  for_each = local.worker_vm_ids

  managed_disk_id    = azurerm_managed_disk.longhorn[each.key].id
  virtual_machine_id = each.value
  lun                = var.lun
  caching            = "None"
}
