# terraform/compute/main.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# ---------------------------------------------------------------------------
# Read networking's outputs from its local state file.
# This is the link between the two modules: compute consumes what
# networking produced (resource group, subnet, public IP), without
# either one being a child of a parent module.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "networking" {
  backend = "local"

  config = {
    path = "../networking/terraform.tfstate"
  }
}

locals {
  resource_group_name = data.terraform_remote_state.networking.outputs.resource_group_name
  location            = data.terraform_remote_state.networking.outputs.location
  private_subnet_id   = data.terraform_remote_state.networking.outputs.private_subnet_id
  public_ip_id        = data.terraform_remote_state.networking.outputs.public_ip_id
  public_ip_address   = data.terraform_remote_state.networking.outputs.public_ip_address

  ssh_public_keys = [for path in var.ssh_public_key_paths : file(pathexpand(path))]
}

# ---------------------------------------------------------------------------
# Master: NIC (static private IP + the public IP from networking) + VM
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "master" {
  name                = "${var.prefix}-k3s-master-nic"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.private_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.master_private_ip
    public_ip_address_id          = local.public_ip_id
  }
}

resource "azurerm_linux_virtual_machine" "master" {
  name                  = "${var.prefix}-k3s-master"
  computer_name         = "k3s-master"
  resource_group_name   = local.resource_group_name
  location              = local.location
  size                  = var.master_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.master.id]
  tags                  = var.tags

  dynamic "admin_ssh_key" {
    for_each = local.ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }
}

# ---------------------------------------------------------------------------
# Workers: one NIC + one VM per entry in var.workers (no public IPs)
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "worker" {
  for_each            = var.workers
  name                = "${var.prefix}-k3s-${each.key}-nic"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.private_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
  }
}

resource "azurerm_linux_virtual_machine" "worker" {
  for_each              = var.workers
  name                  = "${var.prefix}-k3s-${each.key}"
  computer_name         = "k3s-${each.key}"
  resource_group_name   = local.resource_group_name
  location              = local.location
  size                  = var.worker_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.worker[each.key].id]
  tags                  = var.tags

  dynamic "admin_ssh_key" {
    for_each = local.ssh_public_keys
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }
}
