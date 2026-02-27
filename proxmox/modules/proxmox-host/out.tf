# Output interface matches the hcloud host module for compatibility

output "ipv4_address" {
  description = "Public/management IPv4 address"
  value       = proxmox_virtual_environment_vm.server.ipv4_addresses[0][0]
}

output "private_ipv4_address" {
  description = "Private IPv4 address (SDN network)"
  value       = var.private_ipv4
}

output "name" {
  description = "VM name"
  value       = local.name
}

output "id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.server.vm_id
}
