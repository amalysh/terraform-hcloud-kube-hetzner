# Import shared k3s configuration from common module
module "k3s_config" {
  source = "./common/modules/k3s-config"

  k3s_exec_server_args          = var.k3s_exec_server_args
  k3s_exec_agent_args           = var.k3s_exec_agent_args
  initial_k3s_channel           = var.initial_k3s_channel
  install_k3s_version           = var.install_k3s_version
  preinstall_exec               = var.preinstall_exec
  postinstall_exec              = var.postinstall_exec
  address_for_connectivity_test = var.address_for_connectivity_test
  additional_k3s_environment    = var.additional_k3s_environment
  disable_selinux               = var.disable_selinux
  flannel_iface                 = "eth1"
  use_external_cloud_provider   = true
  cni_plugin                    = var.cni_plugin
  disable_network_policy        = var.disable_network_policy
  enable_wireguard              = var.enable_wireguard
  # Hetzner-specific interface rename script
  interface_rename_script = "/etc/cloud/rename_interface.sh"
  k3s_registries          = var.k3s_registries
}
