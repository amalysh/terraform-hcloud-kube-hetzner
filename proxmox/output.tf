output "cluster_name" {
  value = var.cluster_name
}

output "control_planes_public_ipv4" {
  value = {
    for k, v in module.control_planes : k => v.ipv4_address
  }
}

output "control_planes_private_ipv4" {
  value = {
    for k, v in module.control_planes : k => v.private_ipv4_address
  }
}

output "agents_public_ipv4" {
  value = {
    for k, v in module.agents : k => v.ipv4_address
  }
}

output "agents_private_ipv4" {
  value = {
    for k, v in module.agents : k => v.private_ipv4_address
  }
}

output "control_plane_vip" {
  description = "Virtual IP for the k3s API server (managed by kube-vip)"
  value       = var.control_plane_vip
}

output "k3s_endpoint" {
  description = "k3s API endpoint"
  value       = "https://${var.control_plane_vip}:6443"
}

output "k3s_token" {
  value     = local.k3s_token
  sensitive = true
}

output "kubeconfig" {
  description = "Full kubeconfig for the cluster"
  value       = module.kubeconfig.kubeconfig
  sensitive   = true
}

output "kubeconfig_data" {
  description = "Parsed kubeconfig data"
  value       = module.kubeconfig.kubeconfig_data
  sensitive   = true
}

output "sdn_zone_name" {
  description = "Name of the Proxmox SDN zone"
  value       = local.sdn_zone_name
}

output "sdn_vnet_name" {
  description = "Name of the Proxmox SDN VNet"
  value       = proxmox_virtual_environment_sdn_vnet.k3s.id
}
