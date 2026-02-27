# Unit tests for common/modules/k3s-config
# All tests use command = plan (no providers needed, pure computation)

# --- Default outputs ---

run "defaults" {
  command = plan

  assert {
    condition     = length(output.install_k3s_server) > 0
    error_message = "install_k3s_server should be non-empty"
  }

  assert {
    condition     = length(output.install_k3s_agent) > 0
    error_message = "install_k3s_agent should be non-empty"
  }

  assert {
    condition     = output.flannel_iface == "eth1"
    error_message = "Default flannel_iface should be eth1"
  }

  assert {
    condition     = length(output.kubelet_arg) > 0
    error_message = "kubelet_arg should be non-empty"
  }

  assert {
    condition     = output.kube_controller_manager_arg == "flex-volume-plugin-dir=/var/lib/kubelet/volumeplugins"
    error_message = "kube_controller_manager_arg should set flex-volume-plugin-dir"
  }
}

# --- CNI settings ---

run "cni_flannel" {
  command = plan

  variables {
    cni_plugin = "flannel"
  }

  assert {
    condition     = output.cni_k3s_settings["flannel"]["flannel-backend"] == "vxlan"
    error_message = "Flannel should default to vxlan backend"
  }

  assert {
    condition     = output.cni_k3s_settings["flannel"]["disable-network-policy"] == false
    error_message = "Flannel should not disable network policy by default"
  }
}

run "cni_flannel_wireguard" {
  command = plan

  variables {
    cni_plugin       = "flannel"
    enable_wireguard = true
  }

  assert {
    condition     = output.cni_k3s_settings["flannel"]["flannel-backend"] == "wireguard-native"
    error_message = "Flannel with wireguard should use wireguard-native backend"
  }
}

run "cni_flannel_network_policy_disabled" {
  command = plan

  variables {
    cni_plugin             = "flannel"
    disable_network_policy = true
  }

  assert {
    condition     = output.cni_k3s_settings["flannel"]["disable-network-policy"] == true
    error_message = "Flannel should respect disable_network_policy"
  }
}

run "cni_calico" {
  command = plan

  variables {
    cni_plugin = "calico"
  }

  assert {
    condition     = output.cni_k3s_settings["calico"]["flannel-backend"] == "none"
    error_message = "Calico should set flannel-backend to none"
  }

  assert {
    condition     = output.cni_k3s_settings["calico"]["disable-network-policy"] == true
    error_message = "Calico should disable k3s network policy (uses its own)"
  }
}

run "cni_cilium" {
  command = plan

  variables {
    cni_plugin = "cilium"
  }

  assert {
    condition     = output.cni_k3s_settings["cilium"]["flannel-backend"] == "none"
    error_message = "Cilium should set flannel-backend to none"
  }

  assert {
    condition     = output.cni_k3s_settings["cilium"]["disable-network-policy"] == true
    error_message = "Cilium should disable k3s network policy (uses its own)"
  }
}

run "cni_invalid" {
  command = plan

  variables {
    cni_plugin = "weave"
  }

  expect_failures = [var.cni_plugin]
}

# --- Kubelet args ---

run "kubelet_with_ccm" {
  command = plan

  variables {
    use_external_cloud_provider = true
  }

  assert {
    condition     = contains(output.kubelet_arg, "cloud-provider=external")
    error_message = "kubelet_arg should contain cloud-provider=external when CCM is used"
  }

  assert {
    condition     = contains(output.kubelet_arg, "volume-plugin-dir=/var/lib/kubelet/volumeplugins")
    error_message = "kubelet_arg should always contain volume-plugin-dir"
  }
}

run "kubelet_without_ccm" {
  command = plan

  variables {
    use_external_cloud_provider = false
  }

  assert {
    condition     = !contains(output.kubelet_arg, "cloud-provider=external")
    error_message = "kubelet_arg should NOT contain cloud-provider=external when CCM is not used"
  }

  assert {
    condition     = contains(output.kubelet_arg, "volume-plugin-dir=/var/lib/kubelet/volumeplugins")
    error_message = "kubelet_arg should still contain volume-plugin-dir"
  }
}

# --- Install commands ---

run "install_server_command" {
  command = plan

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("get.k3s.io.*server", cmd))])
    error_message = "install_k3s_server should contain k3s install curl with 'server'"
  }
}

run "install_agent_command" {
  command = plan

  assert {
    condition     = anytrue([for cmd in output.install_k3s_agent : can(regex("get.k3s.io.*agent", cmd))])
    error_message = "install_k3s_agent should contain k3s install curl with 'agent'"
  }
}

run "version_pinned" {
  command = plan

  variables {
    install_k3s_version = "v1.30.1+k3s1"
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("INSTALL_K3S_VERSION=v1\\.30\\.1\\+k3s1", cmd))])
    error_message = "Pinned version should appear in install command"
  }
}

run "channel_used" {
  command = plan

  variables {
    install_k3s_version = ""
    initial_k3s_channel = "stable"
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("INSTALL_K3S_CHANNEL=stable", cmd))])
    error_message = "Channel should appear when version is not pinned"
  }
}

# --- SELinux ---

run "selinux_enabled" {
  command = plan

  variables {
    disable_selinux = false
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("semodule", cmd))])
    error_message = "SELinux module install should be present when selinux is enabled"
  }
}

run "selinux_disabled" {
  command = plan

  variables {
    disable_selinux = true
  }

  assert {
    condition     = alltrue([for cmd in output.install_k3s_server : !can(regex("semodule", cmd))])
    error_message = "SELinux module install should NOT be present when selinux is disabled"
  }
}

# --- Interface and connectivity ---

run "custom_flannel_iface" {
  command = plan

  variables {
    flannel_iface = "ens19"
  }

  assert {
    condition     = output.flannel_iface == "ens19"
    error_message = "flannel_iface should reflect custom value"
  }
}

run "interface_rename_skip" {
  command = plan

  variables {
    interface_rename_script = ""
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("Skipping interface rename", cmd))])
    error_message = "Empty interface_rename_script should produce skip message"
  }
}

# --- Pre/post install exec ---

run "preinstall_exec" {
  command = plan

  variables {
    preinstall_exec = ["echo pre-test-marker"]
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : cmd == "echo pre-test-marker"])
    error_message = "preinstall_exec commands should appear in install_k3s_server"
  }
}

run "postinstall_exec" {
  command = plan

  variables {
    postinstall_exec = ["echo post-test-marker"]
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : cmd == "echo post-test-marker"])
    error_message = "postinstall_exec commands should appear in install_k3s_server"
  }
}

# --- Additional environment ---

run "additional_env" {
  command = plan

  variables {
    additional_k3s_environment = {
      FOO = "bar"
    }
  }

  assert {
    condition     = anytrue([for cmd in output.install_k3s_server : can(regex("FOO=\"bar\"", cmd))])
    error_message = "Additional environment variables should appear in install commands"
  }
}

# --- Update scripts ---

run "scripts_contain_keywords" {
  command = plan

  assert {
    condition     = can(regex("config\\.yaml", output.k3s_config_update_script))
    error_message = "k3s_config_update_script should reference config.yaml"
  }

  assert {
    condition     = can(regex("registries\\.yaml", output.k3s_registries_update_script))
    error_message = "k3s_registries_update_script should reference registries.yaml"
  }

  assert {
    condition     = can(regex("authentication_config\\.yaml", output.k3s_authentication_config_update_script))
    error_message = "k3s_authentication_config_update_script should reference authentication_config.yaml"
  }

  assert {
    condition     = can(regex("systemctl", output.k3s_config_update_script))
    error_message = "k3s_config_update_script should restart via systemctl"
  }
}
