output "install_k3s_server" {
  description = "List of commands to install k3s server"
  value       = local.install_k3s_server
}

output "install_k3s_agent" {
  description = "List of commands to install k3s agent"
  value       = local.install_k3s_agent
}

output "cni_k3s_settings" {
  description = "CNI-specific k3s configuration settings"
  value       = local.cni_k3s_settings
}

output "kubelet_arg" {
  description = "Kubelet arguments list"
  value       = local.kubelet_arg
}

output "kube_controller_manager_arg" {
  description = "Kube controller manager argument"
  value       = local.kube_controller_manager_arg
}

output "flannel_iface" {
  description = "Network interface for flannel"
  value       = var.flannel_iface
}

output "k3s_config_update_script" {
  description = "Script to update k3s config.yaml and restart service"
  value       = <<EOF
DATE=`date +%Y-%m-%d_%H-%M-%S`
if cmp -s /tmp/config.yaml /etc/rancher/k3s/config.yaml; then
  echo "No update required to the config.yaml file"
else
  if [ -f "/etc/rancher/k3s/config.yaml" ]; then
    echo "Backing up /etc/rancher/k3s/config.yaml to /tmp/config_$DATE.yaml"
    cp /etc/rancher/k3s/config.yaml /tmp/config_$DATE.yaml
  fi
  echo "Updated config.yaml detected, restart of k3s service required"
  cp /tmp/config.yaml /etc/rancher/k3s/config.yaml
  if systemctl is-active --quiet k3s; then
    systemctl restart k3s || (echo "Error: Failed to restart k3s. Restoring /etc/rancher/k3s/config.yaml from backup" && cp /tmp/config_$DATE.yaml /etc/rancher/k3s/config.yaml && systemctl restart k3s)
  elif systemctl is-active --quiet k3s-agent; then
    systemctl restart k3s-agent || (echo "Error: Failed to restart k3s-agent. Restoring /etc/rancher/k3s/config.yaml from backup" && cp /tmp/config_$DATE.yaml /etc/rancher/k3s/config.yaml && systemctl restart k3s-agent)
  else
    echo "No active k3s or k3s-agent service found"
  fi
  echo "k3s service or k3s-agent service (re)started successfully"
fi
EOF
}

output "k3s_registries_update_script" {
  description = "Script to update k3s registries.yaml and restart service"
  value       = <<EOF
DATE=`date +%Y-%m-%d_%H-%M-%S`
if cmp -s /tmp/registries.yaml /etc/rancher/k3s/registries.yaml; then
  echo "No update required to the registries.yaml file"
else
  echo "Backing up /etc/rancher/k3s/registries.yaml to /tmp/registries_$DATE.yaml"
  cp /etc/rancher/k3s/registries.yaml /tmp/registries_$DATE.yaml
  echo "Updated registries.yaml detected, restart of k3s service required"
  cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml
  if systemctl is-active --quiet k3s; then
    systemctl restart k3s || (echo "Error: Failed to restart k3s. Restoring /etc/rancher/k3s/registries.yaml from backup" && cp /tmp/registries_$DATE.yaml /etc/rancher/k3s/registries.yaml && systemctl restart k3s)
  elif systemctl is-active --quiet k3s-agent; then
    systemctl restart k3s-agent || (echo "Error: Failed to restart k3s-agent. Restoring /etc/rancher/k3s/registries.yaml from backup" && cp /tmp/registries_$DATE.yaml /etc/rancher/k3s/registries.yaml && systemctl restart k3s-agent)
  else
    echo "No active k3s or k3s-agent service found"
  fi
  echo "k3s service or k3s-agent service restarted successfully"
fi
EOF
}

output "k3s_authentication_config_update_script" {
  description = "Script to update k3s authentication_config.yaml and restart service"
  value       = <<EOF
DATE=`date +%Y-%m-%d_%H-%M-%S`
if cmp -s /tmp/authentication_config.yaml /etc/rancher/k3s/authentication_config.yaml; then
  echo "No update required to the authentication_config.yaml file"
else
  if [ -f "/etc/rancher/k3s/authentication_config.yaml" ]; then
    echo "Backing up /etc/rancher/k3s/authentication_config.yaml to /tmp/authentication_config_$DATE.yaml"
    cp /etc/rancher/k3s/authentication_config.yaml /tmp/authentication_config_$DATE.yaml
  fi
  echo "Updated authentication_config.yaml detected, restart of k3s service required"
  cp /tmp/authentication_config.yaml /etc/rancher/k3s/authentication_config.yaml
  if systemctl is-active --quiet k3s; then
    systemctl restart k3s || (echo "Error: Failed to restart k3s. Restoring /etc/rancher/k3s/authentication_config.yaml from backup" && cp /tmp/authentication_config_$DATE.yaml /etc/rancher/k3s/authentication_config.yaml && systemctl restart k3s)
  elif systemctl is-active --quiet k3s-agent; then
    systemctl restart k3s-agent || (echo "Error: Failed to restart k3s-agent. Restoring /etc/rancher/k3s/authentication_config.yaml from backup" && cp /tmp/authentication_config_$DATE.yaml /etc/rancher/k3s/authentication_config.yaml && systemctl restart k3s-agent)
  else
    echo "No active k3s or k3s-agent service found"
  fi
  echo "k3s service or k3s-agent service (re)started successfully"
fi
EOF
}
