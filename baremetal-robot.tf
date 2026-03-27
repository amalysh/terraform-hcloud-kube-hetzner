# ---
# vSwitch Subnet
# ---
resource "hcloud_network_subnet" "robot" {
  count        = length(var.robot_nodepools)
  network_id   = data.hcloud_network.k3s.id
  type         = "vswitch"
  network_zone = var.network_region
  vswitch_id   = var.robot_nodepools[count.index].vswitch_id
  ip_range     = local.network_ipv4_subnets[200 + count.index]
}

# ---
# Computed: private IP from subnet (same pattern as cloud agents: cidrhost(subnet, key + 101))
# ---
locals {
  robot_node_private_ipv4 = {
    for k, v in local.robot_nodes : k =>
    cidrhost(
      hcloud_network_subnet.robot[v.pool_idx].ip_range,
      tonumber(v.node_key) + 101
    )
  }
}

# ---
# K3s Agent Config
# ---
locals {
  k3s-robot-agent-config = { for k, v in local.robot_nodes : k => merge(
    {
      node-name        = v.name
      server           = "https://${var.use_control_plane_lb ? hcloud_load_balancer_network.control_plane.*.ip[0] : module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token            = local.k3s_token
      kubelet-arg      = concat(["provider-id=${local.robot_provider_id_prefix}${v.name}"], local.robot_kubelet_arg, var.k3s_global_kubelet_args, var.k3s_agent_kubelet_args, v.kubelet_args)
      node-ip          = "${local.robot_node_private_ipv4[k]},${v.ipv4_address}"
      node-external-ip = v.ipv4_address
      node-label       = v.labels
      node-taint       = v.taints
    },
    { flannel-iface = v.flannel_iface },
    var.agent_nodes_custom_config,
    v.selinux ? { selinux = true } : {}
  ) }
}

# ---
# Base Setup (packages, services, hardening)
# ---
resource "null_resource" "robot_base_setup" {
  for_each = local.robot_nodes

  triggers = {
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
resource "null_resource" "robot_base_setup_reboot_wait" {
  for_each = local.robot_nodes

  triggers = {
    base_setup_id = null_resource.robot_base_setup[each.key].id
  }

  # Wait for node to go down (ping every 5s, up to 2min — shutdown is scheduled +1min)
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for ${each.value.ipv4_address} to go down..."
      for i in $(seq 1 24); do
        if ! ping -c 1 -W 2 ${each.value.ipv4_address} >/dev/null 2>&1; then
          echo "Node is down after $((i*5))s"
          break
        fi
        sleep 5
      done
    EOT
  }

  # Wait for SSH to come back (up to 10min)
  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
    timeout        = "10m"
  }

  provisioner "remote-exec" {
    inline = ["echo 'Node ${each.value.name} is back after reboot'"]
  }

  depends_on = [null_resource.robot_base_setup]
}

# ---
# VLAN Interface Setup
# ---
resource "null_resource" "robot_vlan_setup" {
  for_each = local.robot_nodes

  triggers = {
    node_ip    = each.value.ipv4_address
    private_ip = local.robot_node_private_ipv4[each.key]
    vlan_id    = each.value.vlan_id
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
      "nmcli connection delete vlan${each.value.vlan_id} 2>/dev/null || true",
      "nmcli connection add type vlan con-name vlan${each.value.vlan_id} ifname vlan${each.value.vlan_id} vlan.parent $NIC vlan.id ${each.value.vlan_id}",
      "nmcli connection modify vlan${each.value.vlan_id} 802-3-ethernet.mtu ${each.value.mtu}",
      "nmcli connection modify vlan${each.value.vlan_id} ipv4.addresses '${local.robot_node_private_ipv4[each.key]}/${split("/", hcloud_network_subnet.robot[each.value.pool_idx].ip_range)[1]}'",
      "nmcli connection modify vlan${each.value.vlan_id} ipv4.method manual",
      # Route private network through vSwitch gateway (first IP in subnet)
      "nmcli connection modify vlan${each.value.vlan_id} +ipv4.routes '${var.network_ipv4_cidr} ${cidrhost(hcloud_network_subnet.robot[each.value.pool_idx].ip_range, 1)}'",
      # Activate
      "nmcli connection down vlan${each.value.vlan_id} 2>/dev/null || true",
      "nmcli connection up vlan${each.value.vlan_id}",
    ]
  }

  depends_on = [
    null_resource.robot_base_setup,
    null_resource.robot_base_setup_reboot_wait,
    hcloud_network_subnet.robot
  ]
}

# ---
# K3s Config Upload
# ---
resource "null_resource" "robot_agent_config" {
  for_each = local.robot_nodes

  triggers = {
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
    null_resource.robot_vlan_setup
  ]
}

# ---
# K3s Install & Start
# ---
resource "null_resource" "robot_agents" {
  for_each = local.robot_nodes

  triggers = {
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
    null_resource.first_control_plane,
    null_resource.robot_agent_config,
    null_resource.robot_vlan_setup,
    hcloud_network_subnet.robot
  ]
}

# ---
# K3s Registries
# ---
resource "null_resource" "robot_registries" {
  for_each = local.robot_nodes

  triggers = {
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

  depends_on = [null_resource.robot_agents]
}

# ---
# Firewall (iptables)
# ---
resource "null_resource" "robot_firewall" {
  for_each = local.robot_nodes

  triggers = {
    rules_hash = sha1(local.baremetal_iptables_script)
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  provisioner "file" {
    content     = local.baremetal_iptables_script
    destination = "/tmp/k3s-firewall.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/k3s-firewall.sh",
      "/tmp/k3s-firewall.sh",
    ]
  }

  depends_on = [null_resource.robot_vlan_setup]
}

# ---
# Ingress LB Targets (Robot nodes registered on Hetzner LB)
# ---
resource "hcloud_load_balancer_target" "robot" {
  for_each         = local.has_external_load_balancer ? {} : local.robot_nodes
  type             = "ip"
  load_balancer_id = hcloud_load_balancer.cluster[0].id
  ip               = local.robot_node_private_ipv4[each.key]

  depends_on = [
    hcloud_load_balancer.cluster,
    hcloud_network_subnet.robot,
    null_resource.robot_agents
  ]
}

# ---
# Longhorn Disk Configuration
# ---
resource "null_resource" "robot_longhorn_disks" {
  for_each = {
    for k, v in local.robot_nodes : k => v
    if v.longhorn_disks_config != null && var.enable_longhorn
  }

  triggers = {
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

  depends_on = [null_resource.robot_agents]
}

resource "null_resource" "robot_longhorn_unschedule" {
  for_each = {
    for k, v in local.robot_nodes : k => v
    if !v.enable_longhorn && var.enable_longhorn
  }

  triggers = {
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

  depends_on = [null_resource.robot_agents]
}

# ---
# Cleanup on node removal: drain k8s node, stop services, remove configs
# ---
resource "null_resource" "robot_cleanup" {
  for_each = local.robot_nodes

  # All connection details must be in triggers — destroy provisioners can only reference self.triggers
  triggers = {
    node_name          = each.value.name
    node_ip            = each.value.ipv4_address
    ssh_port           = each.value.ssh_port
    vlan_id            = each.value.vlan_id
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
      private_key    = self.triggers.ssh_private_key != "" ? self.triggers.ssh_private_key : null
      agent_identity = self.triggers.ssh_agent_identity != "" ? self.triggers.ssh_agent_identity : null
      host           = self.triggers.cp_ip
      port           = self.triggers.cp_ssh_port
    }
    inline = [
      "kubectl drain ${self.triggers.node_name} --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>/dev/null || true",
      "kubectl delete node ${self.triggers.node_name} --timeout=30s 2>/dev/null || true",
    ]
  }

  # Stop services and clean up on the bare metal node
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    connection {
      user           = "root"
      private_key    = self.triggers.ssh_private_key != "" ? self.triggers.ssh_private_key : null
      agent_identity = self.triggers.ssh_agent_identity != "" ? self.triggers.ssh_agent_identity : null
      host           = self.triggers.node_ip
      port           = self.triggers.ssh_port
    }
    inline = [
      "systemctl stop k3s-agent 2>/dev/null || true",
      "systemctl disable k3s-agent 2>/dev/null || true",
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "nmcli connection delete vlan${self.triggers.vlan_id} 2>/dev/null || true",
      "nft delete table inet k3s-firewall 2>/dev/null || true",
      "rm -f /etc/rancher/k3s/config.yaml /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [null_resource.robot_agents]
}
