# terraform/storage/outputs.tf

output "longhorn_disk_ids" {
  description = "Map of worker name -> managed data disk resource ID."
  value       = { for name, disk in azurerm_managed_disk.longhorn : name => disk.id }
}

output "longhorn_disk_size_gb" {
  description = "Provisioned size of each Longhorn data disk."
  value       = var.disk_size_gb
}

output "longhorn_disk_lun" {
  description = "LUN the disk is attached at (used to find the device later, e.g. /dev/disk/azure/scsi1/lun0)."
  value       = var.lun
}
