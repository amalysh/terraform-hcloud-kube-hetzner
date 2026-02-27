output "kubeconfig" {
  description = "Full kubeconfig file content"
  value       = local.kubeconfig_external
  sensitive   = true
}

output "kubeconfig_data" {
  description = "Parsed kubeconfig data (host, certs, cluster_name)"
  value       = local.kubeconfig_data
  sensitive   = true
}

output "kubeconfig_file" {
  description = "Path to the local kubeconfig file (empty if create_kubeconfig is false)"
  value       = var.create_kubeconfig ? local_sensitive_file.kubeconfig[0].filename : ""
}
