locals {
  additional_k3s_environment = join("\n",
    [
      for var_name, var_value in var.additional_k3s_environment :
      "${var_name}=\"${var_value}\""
    ]
  )

  install_additional_k3s_environment = <<-EOT
  cat >> /etc/environment <<EOF
  ${local.additional_k3s_environment}
  EOF
  set -a; source /etc/environment; set +a;
  EOT

  install_system_alias = <<-EOT
  cat > /etc/profile.d/00-alias.sh <<EOF
  alias k=kubectl
  EOF
  EOT

  install_kubectl_bash_completion = <<-EOT
  cat > /etc/bash_completion.d/kubectl <<EOF
  if command -v kubectl >/dev/null; then
    source <(kubectl completion bash)
    complete -o default -F __start_kubectl k
  fi
  EOF
  EOT

  common_pre_install_k3s_commands = concat(
    [
      "set -ex",
      # rename the private network interface (provider-specific script)
      var.interface_rename_script != "" ? var.interface_rename_script : "echo 'Skipping interface rename'",
      # prepare the k3s config directory
      "mkdir -p /etc/rancher/k3s",
      # move the config file into place and adjust permissions
      "[ -f /tmp/config.yaml ] && mv /tmp/config.yaml /etc/rancher/k3s/config.yaml",
      "chmod 0600 /etc/rancher/k3s/config.yaml",
      # if the server has already been initialized just stop here
      "[ -e /etc/rancher/k3s/k3s.yaml ] && exit 0",
      local.install_additional_k3s_environment,
      local.install_system_alias,
      local.install_kubectl_bash_completion,
    ],
    # User-defined commands to execute just before installing k3s.
    var.preinstall_exec,
    # Wait for a successful connection to the internet.
    ["timeout 180s /bin/sh -c 'while ! ping -c 1 ${var.address_for_connectivity_test} >/dev/null 2>&1; do echo \"Ready for k3s installation, waiting for a successful connection to the internet...\"; sleep 5; done; echo Connected'"]
  )

  common_post_install_k3s_commands = concat(var.postinstall_exec, ["restorecon -v /usr/local/bin/k3s"])

  # @fixme SELinux for Ubuntu
  apply_k3s_selinux = ["if test -e /usr/share/selinux/packages/k3s.pp; then /sbin/semodule -v -i /usr/share/selinux/packages/k3s.pp; fi"]

  k3s_install_command = "curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_SELINUX_RPM=true %{if var.install_k3s_version == ""}INSTALL_K3S_CHANNEL=${var.initial_k3s_channel}%{else}INSTALL_K3S_VERSION=${var.install_k3s_version}%{endif} INSTALL_K3S_EXEC='%s' sh -"

  install_k3s_server = concat(
    local.common_pre_install_k3s_commands,
    [format(local.k3s_install_command, "server ${var.k3s_exec_server_args}")],
    var.disable_selinux ? [] : local.apply_k3s_selinux,
    local.common_post_install_k3s_commands
  )

  install_k3s_agent = concat(
    local.common_pre_install_k3s_commands,
    [format(local.k3s_install_command, "agent ${var.k3s_exec_agent_args}")],
    var.disable_selinux ? [] : local.apply_k3s_selinux,
    local.common_post_install_k3s_commands
  )

  # CNI-specific k3s settings
  cni_k3s_settings = {
    "flannel" = {
      disable-network-policy = var.disable_network_policy
      flannel-backend        = var.enable_wireguard ? "wireguard-native" : "vxlan"
    }
    "calico" = {
      disable-network-policy = true
      flannel-backend        = "none"
    }
    "cilium" = {
      disable-network-policy = true
      flannel-backend        = "none"
    }
  }

  # Kubelet args — cloud-provider=external only when using a CCM
  kubelet_arg                 = concat(var.use_external_cloud_provider ? ["cloud-provider=external"] : [], ["volume-plugin-dir=/var/lib/kubelet/volumeplugins"])
  kube_controller_manager_arg = "flex-volume-plugin-dir=/var/lib/kubelet/volumeplugins"
}
