# terraform/compute/outputs.tf

output "master_public_ip" {
  description = "Master's public IP (from networking) — for SSH and DNS."
  value       = local.public_ip_address
}

output "ssh_command" {
  description = "SSH into the master (adjust -i if your private key name differs)."
  value       = "ssh -i ${trimsuffix(pathexpand(var.ssh_public_key_paths[0]), ".pub")} ${var.admin_username}@${local.public_ip_address}"
}

output "master_private_ip" {
  description = "Master's private IP."
  value       = var.master_private_ip
}

output "worker_private_ips" {
  description = "Map of worker name -> private IP."
  value       = { for name, w in var.workers : name => w.private_ip }
}

output "master_vm_id" {
  description = "Master VM resource ID (storage module attaches data disks to this)."
  value       = azurerm_linux_virtual_machine.master.id
}

output "worker_vm_ids" {
  description = "Map of worker name -> VM resource ID (for storage/Longhorn disks)."
  value       = { for name, vm in azurerm_linux_virtual_machine.worker : name => vm.id }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../ansible/inventory/hosts.ini"
  content = templatefile("${path.module}/../../ansible/inventory/hosts.ini.tftpl", {
    master_public_ip   = local.public_ip_address
    worker_private_ips = { for name, w in var.workers : name => w.private_ip }
  })
}
