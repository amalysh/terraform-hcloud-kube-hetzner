# ---
# Computed: private IP from vSwitch subnet (uses master's global vswitch_subnet)
# ---
locals {
  robot_node_private_ipv4 = var.vswitch_id != null ? {
    for k, v in local.robot_nodes : k =>
    cidrhost(
      hcloud_network_subnet.vswitch_subnet[0].ip_range,
      tonumber(v.node_key) + 101
    )
  } : {}
}

# ---
# K3s Agent Config
# ---
locals {
  k3s-robot-agent-config = { for k, v in local.robot_nodes : k => merge(
    {
      node-name        = v.name
      server           = local.k3s_endpoint
      token            = local.k3s_token
      kubelet-arg      = concat(["provider-id=${local.robot_provider_id_prefix}${v.name}"], local.robot_kubelet_arg, var.k3s_global_kubelet_args, var.k3s_agent_kubelet_args, v.kubelet_args)
      node-ip          = "${local.robot_node_private_ipv4[k]},${v.ipv4_address}"
      node-external-ip = v.ipv4_address
      node-label       = v.labels
      node-taint       = v.taints
    },
    { flannel-iface = v.flannel_iface },
    var.agent_nodes_custom_config,
    local.prefer_bundled_bin_config,
    v.selinux ? { selinux = true } : {}
  ) }
}

# ---
# Base Setup (packages, services, hardening)
# ---
resource "terraform_data" "robot_base_setup" {
  for_each = local.robot_nodes

  triggers_replace = {
    node_ip = each.value.ipv4_address
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  # Set hostname first (per-node value, can't be in shared script)
  provisioner "remote-exec" {
    inline = [
      "hostnamectl set-hostname ${each.value.name}",
      "echo ${each.value.name} > /etc/hostname",
    ]
  }

  provisioner "remote-exec" {
    inline = [each.value.os == "ubuntu" ? local.baremetal_ubuntu_base_setup : local.baremetal_microos_base_setup]
  }
}

# Wait for node to come back after reboot (hostname, OS upgrade, NetworkManager switch).
resource "terraform_data" "robot_base_setup_reboot_wait" {
  for_each = local.robot_nodes

  triggers_replace = {
    base_setup_id = terraform_data.robot_base_setup[each.key].id
  }

  # Two-phase reboot wait: first confirm the node went DOWN (SSH unreachable),
  # then wait for it to come back UP. This avoids the race where a fixed sleep
  # passes before shutdown -r +1 actually fires, causing subsequent steps to
  # run on a node that hasn't rebooted yet.
  provisioner "local-exec" {
    command = <<-EOT
      echo "Phase 1: Waiting for ${each.value.ipv4_address} to go down (shutdown -r +1)..."
      for i in $(seq 1 30); do
        if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -p ${each.value.ssh_port} root@${each.value.ipv4_address} "echo ok" 2>/dev/null | grep -q ok; then
          echo "Node ${each.value.name} is down"
          break
        fi
        sleep 5
      done
      echo "Phase 2: Waiting for ${each.value.ipv4_address} to come back..."
      for i in $(seq 1 60); do
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -p ${each.value.ssh_port} root@${each.value.ipv4_address} "echo ok" 2>/dev/null | grep -q ok; then
          echo "Node ${each.value.name} is back after reboot"
          exit 0
        fi
        sleep 5
      done
      echo "ERROR: Node ${each.value.ipv4_address} did not come back within 5 minutes"
      exit 1
    EOT
  }

  depends_on = [terraform_data.robot_base_setup]
}

# ---
# VLAN Interface Setup
# ---
resource "terraform_data" "robot_vlan_setup" {
  for_each = local.robot_nodes

  triggers_replace = {
    node_ip    = each.value.ipv4_address
    private_ip = local.robot_node_private_ipv4[each.key]
    vlan_id    = var.vlan_id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -ex",
      # Auto-detect NIC if not specified: use the default route interface
      "NIC=${each.value.network_interface != null ? each.value.network_interface : "$(ip -o -4 route show default | awk '{print $5}' | head -1)"}",
      # Create persistent VLAN connection via NetworkManager (survives reboot)
      "nmcli connection delete vlan${var.vlan_id} 2>/dev/null || true",
      "nmcli connection add type vlan con-name vlan${var.vlan_id} ifname vlan${var.vlan_id} vlan.parent $NIC vlan.id ${var.vlan_id}",
      "nmcli connection modify vlan${var.vlan_id} 802-3-ethernet.mtu ${local.vswitch_mtu}",
      "nmcli connection modify vlan${var.vlan_id} ipv4.addresses '${local.robot_node_private_ipv4[each.key]}/${split("/", hcloud_network_subnet.vswitch_subnet[0].ip_range)[1]}'",
      "nmcli connection modify vlan${var.vlan_id} ipv4.method manual",
      # Route private network through vSwitch gateway (first IP in subnet)
      "nmcli connection modify vlan${var.vlan_id} +ipv4.routes '${var.network_ipv4_cidr} ${cidrhost(hcloud_network_subnet.vswitch_subnet[0].ip_range, 1)}'",
      # Activate
      "nmcli connection down vlan${var.vlan_id} 2>/dev/null || true",
      "nmcli connection up vlan${var.vlan_id}",
    ]
  }

  depends_on = [
    terraform_data.robot_base_setup,
    terraform_data.robot_base_setup_reboot_wait,
    hcloud_network_subnet.vswitch_subnet
  ]
}

# ---
# K3s Config Upload
# ---
resource "terraform_data" "robot_agent_config" {
  for_each = local.robot_nodes

  triggers_replace = {
    config = sha1(yamlencode(local.k3s-robot-agent-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  provisioner "file" {
    content     = yamlencode(local.k3s-robot-agent-config[each.key])
    destination = "/tmp/config.yaml"
  }

  provisioner "remote-exec" {
    inline = [local.k3s_config_update_script]
  }

  depends_on = [
    terraform_data.robot_vlan_setup
  ]
}

# ---
# K3s Install & Start
# ---
resource "terraform_data" "robot_agents" {
  for_each = local.robot_nodes

  triggers_replace = {
    node_ip = each.value.ipv4_address
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  # Install k3s agent
  provisioner "remote-exec" {
    inline = local.install_k3s_agent_baremetal
  }

  # Start k3s-agent and wait
  provisioner "remote-exec" {
    inline = concat(
      var.enable_longhorn || var.enable_iscsid ? ["systemctl enable --now iscsid"] : [],
      [
        "systemctl start k3s-agent 2> /dev/null",
        <<-EOT
        timeout 120 bash <<EOF
          until systemctl status k3s-agent > /dev/null; do
            systemctl start k3s-agent 2> /dev/null
            echo "Waiting for the k3s agent to start..."
            sleep 2
          done
        EOF
        EOT
      ]
    )
  }

  depends_on = [
    terraform_data.first_control_plane,
    terraform_data.robot_agent_config,
    terraform_data.robot_vlan_setup,
    hcloud_network_subnet.vswitch_subnet
  ]
}

# ---
# K3s Registries
# ---
resource "terraform_data" "robot_registries" {
  for_each = local.robot_nodes

  triggers_replace = {
    registries = var.k3s_registries
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  provisioner "file" {
    content     = var.k3s_registries
    destination = "/tmp/registries.yaml"
  }

  provisioner "remote-exec" {
    inline = [local.k3s_registries_update_script]
  }

  depends_on = [terraform_data.robot_agents]
}

# ---
# Firewall (iptables)
# ---
resource "terraform_data" "robot_firewall" {
  for_each = local.robot_nodes

  triggers_replace = {
    rules_hash = sha1(local.baremetal_iptables_script)
  }

  # Step 1: Enable TCP forwarding on CP (required for bastion SSH tunneling)
  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
      port           = var.ssh_port
    }
    inline = [
      "sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config.d/kube-hetzner.conf",
      "systemctl reload sshd 2>/dev/null || systemctl reload ssh",
      "sleep 2",
    ]
  }

  # Step 2: Upload firewall script via CP bastion to robot's private IP.
  # When user IP changes, bare metal nftables blocks direct SSH but CP
  # can always reach robot via vSwitch private network.
  provisioner "file" {
    connection {
      user                = "root"
      private_key         = var.ssh_private_key
      agent_identity      = local.ssh_agent_identity
      host                = local.robot_node_private_ipv4[each.key]
      port                = each.value.ssh_port
      bastion_host        = module.control_planes[keys(module.control_planes)[0]].ipv4_address
      bastion_port        = var.ssh_port
      bastion_user        = "root"
      bastion_private_key = var.ssh_private_key
    }
    content     = local.baremetal_iptables_script
    destination = "/tmp/k3s-firewall.sh"
  }

  # Step 3: Execute firewall script on robot
  provisioner "remote-exec" {
    connection {
      user                = "root"
      private_key         = var.ssh_private_key
      agent_identity      = local.ssh_agent_identity
      host                = local.robot_node_private_ipv4[each.key]
      port                = each.value.ssh_port
      bastion_host        = module.control_planes[keys(module.control_planes)[0]].ipv4_address
      bastion_port        = var.ssh_port
      bastion_user        = "root"
      bastion_private_key = var.ssh_private_key
    }
    inline = [
      "chmod +x /tmp/k3s-firewall.sh",
      "/tmp/k3s-firewall.sh",
    ]
  }

  # Step 4: Disable TCP forwarding on CP
  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
      port           = var.ssh_port
    }
    inline = [
      "sed -i 's/^AllowTcpForwarding yes/AllowTcpForwarding no/' /etc/ssh/sshd_config.d/kube-hetzner.conf",
      "systemctl reload sshd 2>/dev/null || systemctl reload ssh",
    ]
  }

  depends_on = [terraform_data.robot_vlan_setup]
}

# ---
# Ingress LB Targets (Robot nodes as IP targets)
# Note: label_selector targets only work with hcloud Cloud VMs.
# Robot dedicated servers must be added as IP targets.
# Requires robot_ccm_enabled with credentials, otherwise CCM removes IP targets
# it doesn't recognize. Without this, robot nodes are still reachable via
# overlay network through cloud nodes that are LB targets.
# ---
resource "hcloud_load_balancer_target" "robot" {
  for_each         = local.has_external_load_balancer || !local.use_robot_ccm ? {} : local.robot_nodes
  type             = "ip"
  load_balancer_id = hcloud_load_balancer.cluster[0].id
  ip               = local.robot_node_private_ipv4[each.key]

  depends_on = [
    hcloud_load_balancer.cluster,
    hcloud_load_balancer_network.cluster,
    hcloud_network_subnet.vswitch_subnet,
    terraform_data.robot_agents
  ]
}

# ---
# Longhorn Disk Configuration
# ---
resource "terraform_data" "robot_longhorn_disks" {
  for_each = {
    for k, v in local.robot_nodes : k => v
    if v.longhorn_disks_config != null && var.enable_longhorn
  }

  triggers_replace = {
    config = each.value.longhorn_disks_config
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      timeout 120 bash <<EOF
        until kubectl get nodes.longhorn.io ${each.value.name} -n longhorn-system > /dev/null 2>&1; do
          echo "Waiting for longhorn node ${each.value.name} to appear..."
          sleep 5
        done
      EOF
      EOT
      ,
      "kubectl -n longhorn-system patch nodes.longhorn.io ${each.value.name} --type=merge -p '{\"spec\":{\"disks\":${each.value.longhorn_disks_config}}}'",
    ]
  }

  depends_on = [terraform_data.robot_agents]
}

resource "terraform_data" "robot_longhorn_unschedule" {
  for_each = {
    for k, v in local.robot_nodes : k => v
    if !v.enable_longhorn && var.enable_longhorn
  }

  triggers_replace = {
    node_name = each.value.name
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOT
      timeout 120 bash <<EOF
        until kubectl get nodes.longhorn.io ${each.value.name} -n longhorn-system > /dev/null 2>&1; do
          echo "Waiting for longhorn node ${each.value.name} to appear..."
          sleep 5
        done
      EOF
      EOT
      ,
      "kubectl -n longhorn-system patch nodes.longhorn.io ${each.value.name} --type=merge -p '{\"spec\":{\"allowScheduling\":false}}'",
    ]
  }

  depends_on = [terraform_data.robot_agents]
}

# ---
# Cleanup on node removal: drain k8s node, stop services, remove configs
# ---
resource "terraform_data" "robot_cleanup" {
  for_each = local.robot_nodes

  # All connection details must be in triggers — destroy provisioners can only reference self.triggers
  triggers_replace = {
    node_name          = each.value.name
    node_ip            = each.value.ipv4_address
    ssh_port           = each.value.ssh_port
    vlan_id            = var.vlan_id
    cp_ip              = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    cp_ssh_port        = var.ssh_port
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  # Drain and delete the k8s node from a control plane
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    connection {
      user           = "root"
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.cp_ip
      port           = self.triggers_replace.cp_ssh_port
    }
    inline = [
      "kubectl drain ${self.triggers_replace.node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true",
      "kubectl delete node ${self.triggers_replace.node_name} --timeout=30s 2>/dev/null || true",
    ]
  }

  # Stop services and clean up on the bare metal node
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    connection {
      user           = "root"
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.node_ip
      port           = self.triggers_replace.ssh_port
    }
    inline = [
      "systemctl stop k3s-agent 2>/dev/null || true",
      "systemctl disable k3s-agent 2>/dev/null || true",
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "nmcli connection delete vlan${self.triggers_replace.vlan_id} 2>/dev/null || true",
      "nft delete table inet k3s-firewall 2>/dev/null || true",
      "rm -f /etc/rancher/k3s/config.yaml /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [terraform_data.robot_agents]
}

# State migration: null_resource → terraform_data
moved {
  from = null_resource.robot_base_setup
  to   = terraform_data.robot_base_setup
}
moved {
  from = null_resource.robot_base_setup_reboot_wait
  to   = terraform_data.robot_base_setup_reboot_wait
}
moved {
  from = null_resource.robot_vlan_setup
  to   = terraform_data.robot_vlan_setup
}
moved {
  from = null_resource.robot_agent_config
  to   = terraform_data.robot_agent_config
}
moved {
  from = null_resource.robot_agents
  to   = terraform_data.robot_agents
}
moved {
  from = null_resource.robot_registries
  to   = terraform_data.robot_registries
}
moved {
  from = null_resource.robot_firewall
  to   = terraform_data.robot_firewall
}
moved {
  from = null_resource.robot_longhorn_disks
  to   = terraform_data.robot_longhorn_disks
}
moved {
  from = null_resource.robot_longhorn_unschedule
  to   = terraform_data.robot_longhorn_unschedule
}
moved {
  from = null_resource.robot_cleanup
  to   = terraform_data.robot_cleanup
}
