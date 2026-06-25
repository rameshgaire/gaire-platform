# terraform/networking/outputs.tf

output "resource_group_name" {
  description = "Resource group name (consumed by compute/storage)."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region."
  value       = azurerm_resource_group.this.location
}

output "vnet_name" {
  description = "Virtual network name."
  value       = azurerm_virtual_network.this.name
}

output "vnet_id" {
  description = "Virtual network ID."
  value       = azurerm_virtual_network.this.id
}

output "public_subnet_id" {
  description = "Public subnet ID (reserved for a future LB/gateway)."
  value       = azurerm_subnet.public.id
}

output "private_subnet_id" {
  description = "Private subnet ID (all K3s nodes attach here)."
  value       = azurerm_subnet.private.id
}

output "nsg_id" {
  description = "Network security group ID."
  value       = azurerm_network_security_group.this.id
}

output "public_ip_id" {
  description = "Public IP resource ID (attach to the master NIC in compute)."
  value       = azurerm_public_ip.master.id
}

output "public_ip_address" {
  description = "The allocated public IP (use for SSH + DNS A records)."
  value       = azurerm_public_ip.master.ip_address
}
