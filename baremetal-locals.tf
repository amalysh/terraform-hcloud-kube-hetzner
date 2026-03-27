locals {
  # ---
  # Flatten Robot Nodepools
  # ---
  robot_nodes = merge([
    for pool_idx, pool in var.robot_nodepools : {
      for node_key, node in pool.nodes :
      "${pool_idx}-${node_key}-${pool.name}" => {
        nodepool_name     = pool.name
        pool_idx          = pool_idx
        os                = pool.os
        vswitch_id        = pool.vswitch_id
        vlan_id           = pool.vlan_id
        mtu               = pool.mtu
        name              = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${pool.name}-${node_key}"
        ipv4_address      = node.ipv4_address
        node_key          = node_key
        network_interface = node.network_interface
        flannel_iface     = coalesce(pool.flannel_iface, "vlan${pool.vlan_id}")
        ssh_port          = coalesce(node.ssh_port, var.ssh_port)
        selinux           = node.selinux
        labels = concat(
          local.default_agent_labels,
          ["instance.hetzner.cloud/is-root-server=true"],
          node.enable_longhorn && node.longhorn_disks_config == null ? ["node.longhorn.io/create-default-disk=true"] : ["node.longhorn.io/create-default-disk=false"],
          node.labels
        )
        taints                     = concat(local.default_agent_taints, node.taints)
        kubelet_args               = node.kubelet_args
        enable_longhorn            = node.enable_longhorn
        longhorn_disks_config      = node.longhorn_disks_config
        longhorn_volume_mount_path = coalesce(node.longhorn_volume_mount_path, "/var/longhorn")
      }
    }
  ]...)

  # ---
  # Flatten External Nodepools
  # ---
  external_nodes = merge([
    for pool_idx, pool in var.external_nodepools : {
      for node_key, node in pool.nodes :
      "${pool_idx}-${node_key}-${pool.name}" => {
        nodepool_name = pool.name
        os            = pool.os
        full_mesh     = pool.full_mesh
        name          = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${pool.name}-${node_key}"
        ipv4_address  = node.ipv4_address
        ssh_port      = coalesce(node.ssh_port, var.ssh_port)
        selinux       = node.selinux
        labels = concat(
          local.default_agent_labels,
          ["instance.hetzner.cloud/is-root-server=true"],
          node.enable_longhorn && node.longhorn_disks_config == null ? ["node.longhorn.io/create-default-disk=true"] : ["node.longhorn.io/create-default-disk=false"],
          node.labels
        )
        taints                     = concat(local.default_agent_taints, node.taints)
        kubelet_args               = node.kubelet_args
        enable_longhorn            = node.enable_longhorn
        longhorn_disks_config      = node.longhorn_disks_config
        longhorn_volume_mount_path = coalesce(node.longhorn_volume_mount_path, "/var/longhorn")
      }
    }
  ]...)

  # ---
  # WireGuard IP Allocation
  # ---
  external_node_keys_sorted = sort(keys(local.external_nodes))
  external_node_wg_ips = {
    for idx, key in local.external_node_keys_sorted :
    key => cidrhost(var.wireguard_network_cidr, idx + 101)
  }

  cp_keys_sorted = sort(keys(local.control_plane_nodes))
  cp_wg_ips = {
    for idx, key in local.cp_keys_sorted :
    key => cidrhost(var.wireguard_network_cidr, idx + 1)
  }

  has_external_nodes = length(local.external_nodes) > 0
  has_robot_nodes    = length(local.robot_nodes) > 0
  # Note: anytrue([]) returns false, so these are both false when no external nodes exist.
  any_non_full_mesh = anytrue([for k, v in local.external_nodes : !v.full_mesh])
  any_full_mesh     = anytrue([for k, v in local.external_nodes : v.full_mesh])

  # Cloud agents + robot nodes that need WG tunnels (for full_mesh external pools).
  # Avoid conditional to prevent Terraform type-mismatch errors — filter produces empty map naturally.
  _all_potential_mesh_nodes = merge(local.agent_nodes, local.robot_nodes)
  full_mesh_agent_nodes     = { for k, v in local._all_potential_mesh_nodes : k => v if local.any_full_mesh }

  # ---
  # Bare Metal Kubelet Args & Provider ID
  # ---
  # Robot kubelet args: when CCM Robot support is enabled, use cloud-provider=external
  # so the CCM can initialize the node. Otherwise, skip it to avoid the uninitialized taint.
  # TODO: uncomment the conditionals when robot_ccm_enabled variable is added
  # robot_kubelet_arg = var.robot_ccm_enabled ? local.kubelet_arg : ["volume-plugin-dir=/var/lib/kubelet/volumeplugins"]
  robot_kubelet_arg = ["volume-plugin-dir=/var/lib/kubelet/volumeplugins"]

  # Provider ID: without CCM Robot support, use "baremetal://" prefix so the CCM
  # can't parse it and won't delete the node when it goes NotReady.
  # With CCM Robot support, use "hrobot://<server_number>" so the CCM manages it.
  # TODO: uncomment the conditional when robot_ccm_enabled variable is added
  # robot_provider_id_prefix = var.robot_ccm_enabled ? "hrobot://" : "baremetal://"
  robot_provider_id_prefix = "baremetal://"

  # External nodes are never managed by hcloud CCM — always skip cloud-provider=external.
  external_kubelet_arg        = ["volume-plugin-dir=/var/lib/kubelet/volumeplugins"]
  external_provider_id_prefix = "baremetal://"

  # ---
  # Bare Metal Pre-install Commands (no hcloud-specific interface renaming)
  # ---
  baremetal_pre_install_k3s_commands = concat(
    [
      "set -ex",
      "mkdir -p /etc/rancher/k3s",
      "[ -f /tmp/config.yaml ] && mv /tmp/config.yaml /etc/rancher/k3s/config.yaml",
      "chmod 0600 /etc/rancher/k3s/config.yaml",
      "[ -e /etc/rancher/k3s/k3s.yaml ] && exit 0",
      local.install_additional_k3s_environment,
      local.install_system_alias,
      local.install_kubectl_bash_completion,
    ],
    var.preinstall_exec,
    ["timeout 180s /bin/sh -c 'while ! ping -c 1 ${var.address_for_connectivity_test} >/dev/null 2>&1; do echo \"Waiting for connectivity...\"; sleep 5; done; echo Connected'"]
  )

  install_k3s_agent_baremetal = concat(
    local.baremetal_pre_install_k3s_commands,
    [format(local.k3s_install_command, "agent ${var.k3s_exec_agent_args}")],
    var.disable_selinux ? [] : local.apply_k3s_selinux,
    local.common_post_install_k3s_commands
  )

  # ---
  # Base setup script for bare metal nodes (packages, services, hardening)
  # ---
  # NOTE: No leading indentation inside heredocs - content is written verbatim to the node.
  # Terraform's <<-EOT strips leading tabs but NOT spaces, so we keep content left-aligned.
  baremetal_ubuntu_base_setup = <<-EOT
set -ex
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get install -y open-iscsi nfs-common policycoreutils telnet vim curl network-manager wireguard-tools

# Disable unnecessary services
systemctl disable --now snapd snapd.seeded snapd.socket apport ufw 2>/dev/null || true

# OS auto-upgrades (controlled by automatically_upgrade_os variable)
%{if var.automatically_upgrade_os~}
systemctl enable --now unattended-upgrades 2>/dev/null || true
%{else~}
systemctl disable --now unattended-upgrades 2>/dev/null || true
%{endif~}

# Switch to NetworkManager (same as cloud agent cloud-init)
for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] && sed -i 's/renderer:/#renderer:/g' "$f"
done
cat > /etc/netplan/00-kube-hetzner-config.yaml <<'NMEOF'
network:
  version: 2
  renderer: NetworkManager
NMEOF
chmod 600 /etc/netplan/00-kube-hetzner-config.yaml
netplan apply
systemctl restart NetworkManager
systemctl disable --now systemd-networkd systemd-networkd.socket
systemctl enable NetworkManager

# SSH hardening
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/kube-hetzner.conf <<'SSHEOF'
PasswordAuthentication no
X11Forwarding no
MaxAuthTries ${var.ssh_max_auth_tries}
AllowTcpForwarding no
AllowAgentForwarding no
SSHEOF
systemctl restart ssh

# Multipath blacklist
echo -e 'blacklist {\n  devnode "^sd[a-z0-9]+"\n}' >> /etc/multipath.conf

# Journald limits
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limits.conf <<'JEOF'
[Journal]
SystemMaxUse=3G
MaxRetentionSec=1week
JEOF
systemctl restart systemd-journald

# Bash aliases
echo 'alias k=kubectl' >> /etc/profile.d/k3s.sh

# Reboot to apply hostname, kernel updates, and NetworkManager switch.
# Schedule reboot in 1 minute — returns immediately so the script exits cleanly.
# The reboot_wait resource handles waiting for the node to come back.
shutdown -r +1 "Rebooting for bare metal provisioning"
EOT

  baremetal_microos_base_setup = <<-EOT
set -ex
transactional-update pkg install -y open-iscsi nfs-client xfsprogs lvm2 cryptsetup \
  policycoreutils wireguard-tools bind-utils bash-completion mtr tcpdump git cifs-utils

# Disable rebootmgr (kured handles reboots)
systemctl disable --now rebootmgr.service 2>/dev/null || true

# OS auto-upgrades (controlled by automatically_upgrade_os variable)
%{if var.automatically_upgrade_os~}
systemctl enable --now transactional-update.timer 2>/dev/null || true
%{else~}
systemctl disable --now transactional-update.timer 2>/dev/null || true
%{endif~}

# SSH hardening
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/kube-hetzner.conf <<'SSHEOF'
PasswordAuthentication no
X11Forwarding no
MaxAuthTries ${var.ssh_max_auth_tries}
AllowTcpForwarding no
AllowAgentForwarding no
SSHEOF
systemctl restart sshd

# Multipath blacklist
echo -e 'blacklist {\n  devnode "^sd[a-z0-9]+"\n}' >> /etc/multipath.conf

# Journald limits
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limits.conf <<'JEOF'
[Journal]
SystemMaxUse=3G
MaxRetentionSec=1week
JEOF
systemctl restart systemd-journald

echo 'alias k=kubectl' >> /etc/profile.d/k3s.sh

# MicroOS requires reboot after transactional-update to apply changes.
# Use nohup + sleep to allow the SSH session to close cleanly before reboot.
# Schedule reboot in 1 minute — returns immediately so the script exits cleanly.
# The reboot_wait resource handles waiting for the node to come back.
shutdown -r +1 "Rebooting for bare metal provisioning"
EOT

  # Reboot wait: no content needed — the reboot_wait resources use local-exec
  # to wait for SSH to go down and come back up.

  # ---
  # Firewall: hcloud rules to inject for external nodes
  # ---
  external_node_public_ips = [for k, v in local.external_nodes : "${v.ipv4_address}/32"]

  baremetal_firewall_rules_inbound = local.has_external_nodes ? [
    {
      description = "Allow WireGuard from external nodes"
      direction   = "in"
      protocol    = "udp"
      port        = tostring(var.wireguard_port)
      source_ips  = local.external_node_public_ips
    },
  ] : []

  baremetal_firewall_rules_outbound = local.has_external_nodes && var.restrict_outbound_traffic ? [
    {
      description     = "Allow WireGuard to external nodes"
      direction       = "out"
      protocol        = "udp"
      port            = tostring(var.wireguard_port)
      destination_ips = local.external_node_public_ips
    }
  ] : []

  baremetal_firewall_rules = concat(local.baremetal_firewall_rules_inbound, local.baremetal_firewall_rules_outbound)

  # ---
  # Autoscaler cloud-init: WG route commands for gateway mode
  # Empty string when no external nodes or full_mesh only — cloud-init templates produce no extra lines.
  # ---
  baremetal_autoscaler_runcmd = local.any_non_full_mesh ? join("\n", [
    "- ip route replace ${var.wireguard_network_cidr} via ${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}",
    "- mkdir -p /etc/systemd/network",
    "- |",
    "  cat > /etc/systemd/network/99-wg-route.network <<ROUTEEOF",
    "  [Match]",
    "  Name=eth1",
    "  ",
    "  [Route]",
    "  Destination=${var.wireguard_network_cidr}",
    "  Gateway=${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}",
    "  ROUTEEOF",
  ]) : ""

  # ---
  # iptables script for bare metal nodes
  # ---
  baremetal_iptables_script = templatefile("${path.module}/templates/baremetal_iptables.sh.tpl", {
    rules                  = local.firewall_rules_list
    wireguard_port         = var.wireguard_port
    has_external           = local.has_external_nodes
    restrict_outbound      = var.restrict_outbound_traffic
    network_ipv4_cidr      = var.network_ipv4_cidr
    wireguard_network_cidr = var.wireguard_network_cidr
    cluster_ipv4_cidr      = var.cluster_ipv4_cidr
    service_ipv4_cidr      = var.service_ipv4_cidr
  })
}
