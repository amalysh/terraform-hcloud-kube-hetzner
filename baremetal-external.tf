# ---
# WireGuard Key Generation (auto-generated, no user input needed)
# ---
resource "wireguard_asymmetric_key" "external_node" {
  for_each = local.external_nodes
}

resource "wireguard_asymmetric_key" "cp_wg" {
  for_each = local.has_external_nodes ? local.control_plane_nodes : {}
}

resource "wireguard_asymmetric_key" "agent_wg" {
  for_each = local.full_mesh_agent_nodes
}

# ---
# WireGuard Config Templates
# ---
locals {
  # WireGuard config for each control plane
  cp_wg_configs = {
    for cp_key in local.cp_keys_sorted :
    cp_key => templatefile("${path.module}/templates/baremetal_wg_cp.conf.tpl", {
      address     = "${local.cp_wg_ips[cp_key]}/32"
      listen_port = var.wireguard_port
      private_key = wireguard_asymmetric_key.cp_wg[cp_key].private_key
      peers = [
        for ext_key in local.external_node_keys_sorted : {
          public_key  = wireguard_asymmetric_key.external_node[ext_key].public_key
          allowed_ips = "${local.external_node_wg_ips[ext_key]}/32"
        }
      ]
    }) if local.has_external_nodes
  }

  # WireGuard config for each external node
  external_wg_configs = {
    for ext_key, ext_node in local.external_nodes :
    ext_key => templatefile("${path.module}/templates/baremetal_wg_external.conf.tpl", {
      address     = "${local.external_node_wg_ips[ext_key]}/32"
      private_key = wireguard_asymmetric_key.external_node[ext_key].private_key
      cp_peers = [
        for cp_key in local.cp_keys_sorted : {
          public_key  = wireguard_asymmetric_key.cp_wg[cp_key].public_key
          endpoint    = "${module.control_planes[cp_key].ipv4_address}:${var.wireguard_port}"
          allowed_ips = "${module.control_planes[cp_key].private_ipv4_address}/32, ${local.cp_wg_ips[cp_key]}/32"
        }
      ]
      agent_peers = ext_node.full_mesh ? [
        for agent_key, agent_node in local.full_mesh_agent_nodes : {
          public_key  = wireguard_asymmetric_key.agent_wg[agent_key].public_key
          endpoint    = "${try(module.agents[agent_key].ipv4_address, local.robot_nodes[agent_key].ipv4_address)}:${var.wireguard_port}"
          allowed_ips = "${try(module.agents[agent_key].private_ipv4_address, local.robot_node_private_ipv4[agent_key])}/32"
        }
      ] : []
    })
  }

  # K3s config for external nodes
  k3s-external-agent-config = { for k, v in local.external_nodes : k => merge(
    {
      node-name        = v.name
      server           = "https://${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token            = local.k3s_token
      kubelet-arg      = concat(["provider-id=${local.external_provider_id_prefix}${v.name}"], local.external_kubelet_arg, var.k3s_global_kubelet_args, var.k3s_agent_kubelet_args, v.kubelet_args)
      flannel-iface    = "wg-mesh"
      node-ip          = "${local.external_node_wg_ips[k]},${v.ipv4_address}"
      node-external-ip = v.ipv4_address
      node-label       = v.labels
      node-taint       = v.taints
    },
    var.agent_nodes_custom_config,
    v.selinux ? { selinux = true } : {}
  ) }
}

# ---
# WireGuard on Control Planes
# ---
resource "null_resource" "cp_wireguard" {
  for_each = local.has_external_nodes ? local.control_plane_nodes : {}

  triggers = {
    config_hash        = sha1(try(local.cp_wg_configs[each.key], ""))
    cp_ip              = module.control_planes[each.key].ipv4_address
    cp_ssh_port        = var.ssh_port
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  # Install wireguard and create config directory first
  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[each.key].ipv4_address
      port           = var.ssh_port
    }
    inline = [
      "apt-get install -y wireguard 2>/dev/null || zypper install -y wireguard-tools 2>/dev/null || true",
      "mkdir -p /etc/wireguard",
    ]
  }

  provisioner "file" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[each.key].ipv4_address
      port           = var.ssh_port
    }
    content     = local.cp_wg_configs[each.key]
    destination = "/etc/wireguard/wg-mesh.conf"
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[each.key].ipv4_address
      port           = var.ssh_port
    }
    inline = concat(
      [
        "chmod 600 /etc/wireguard/wg-mesh.conf",
        "systemctl enable wg-quick@wg-mesh",
        "systemctl restart wg-quick@wg-mesh",
      ],
      local.any_non_full_mesh ? [
        "sysctl -w net.ipv4.ip_forward=1",
        "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wg-forward.conf",
      ] : []
    )
  }

  # Cleanup when all external nodes are removed
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
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "rm -f /etc/wireguard/wg-mesh.conf",
      "rm -f /etc/sysctl.d/99-wg-forward.conf",
      "sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true",
    ]
  }

  depends_on = [null_resource.first_control_plane]
}

# ---
# WireGuard on External Nodes
# ---
resource "null_resource" "external_base_setup" {
  for_each = local.external_nodes

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
resource "null_resource" "external_base_setup_reboot_wait" {
  for_each = local.external_nodes

  triggers = {
    base_setup_id = null_resource.external_base_setup[each.key].id
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

  depends_on = [null_resource.external_base_setup]
}

resource "null_resource" "external_wireguard" {
  for_each = local.external_nodes

  triggers = {
    config_hash = sha1(local.external_wg_configs[each.key])
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
      "apt-get install -y wireguard 2>/dev/null || zypper install -y wireguard-tools 2>/dev/null || true",
      "mkdir -p /etc/wireguard",
    ]
  }

  provisioner "file" {
    content     = local.external_wg_configs[each.key]
    destination = "/etc/wireguard/wg-mesh.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /etc/wireguard/wg-mesh.conf",
      "systemctl enable wg-quick@wg-mesh",
      "systemctl restart wg-quick@wg-mesh",
      # Verify connectivity to first CP via WG tunnel
      "timeout 60 bash -c 'until ping -c 1 ${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address} >/dev/null 2>&1; do echo \"Waiting for WG tunnel...\"; sleep 2; done'",
    ]
  }

  depends_on = [
    null_resource.external_base_setup,
    null_resource.external_base_setup_reboot_wait,
    null_resource.cp_wireguard
  ]
}

# ---
# Cloud Agent WG Config (full_mesh=true only)
# ---
resource "null_resource" "agent_wireguard" {
  for_each = local.full_mesh_agent_nodes

  triggers = {
    config_hash        = sha1(join(",", [for k, v in local.external_nodes : wireguard_asymmetric_key.external_node[k].public_key if v.full_mesh]))
    node_ip            = try(module.agents[each.key].ipv4_address, local.robot_nodes[each.key].ipv4_address)
    ssh_port           = contains(keys(local.robot_nodes), each.key) ? each.value.ssh_port : var.ssh_port
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = try(module.agents[each.key].ipv4_address, local.robot_nodes[each.key].ipv4_address)
      port           = contains(keys(local.robot_nodes), each.key) ? each.value.ssh_port : var.ssh_port
    }
    inline = [
      "apt-get install -y wireguard 2>/dev/null || zypper install -y wireguard-tools 2>/dev/null || true",
      "mkdir -p /etc/wireguard",
    ]
  }

  provisioner "file" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = try(module.agents[each.key].ipv4_address, local.robot_nodes[each.key].ipv4_address)
      port           = contains(keys(local.robot_nodes), each.key) ? each.value.ssh_port : var.ssh_port
    }
    content = templatefile("${path.module}/templates/baremetal_wg_agent.conf.tpl", {
      address     = try("${module.agents[each.key].private_ipv4_address}/32", "${local.robot_node_private_ipv4[each.key]}/32")
      listen_port = var.wireguard_port
      private_key = wireguard_asymmetric_key.agent_wg[each.key].private_key
      peers = [
        for ext_key, ext_node in local.external_nodes : {
          public_key  = wireguard_asymmetric_key.external_node[ext_key].public_key
          endpoint    = "${ext_node.ipv4_address}:${var.wireguard_port}"
          allowed_ips = "${local.external_node_wg_ips[ext_key]}/32"
        } if ext_node.full_mesh
      ]
    })
    destination = "/etc/wireguard/wg-mesh.conf"
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = try(module.agents[each.key].ipv4_address, local.robot_nodes[each.key].ipv4_address)
      port           = contains(keys(local.robot_nodes), each.key) ? each.value.ssh_port : var.ssh_port
    }
    inline = [
      "chmod 600 /etc/wireguard/wg-mesh.conf",
      "systemctl enable wg-quick@wg-mesh",
      "systemctl restart wg-quick@wg-mesh",
    ]
  }

  # Cleanup when full_mesh external nodes are removed
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
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "rm -f /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [
    null_resource.first_control_plane,
    null_resource.external_wireguard
  ]
}

# ---
# Cloud Agent Routing (full_mesh=false: CPs as gateways)
# ---
resource "null_resource" "agent_wg_route" {
  for_each = local.any_non_full_mesh ? local.agent_nodes : {}

  triggers = {
    wg_cidr            = var.wireguard_network_cidr
    node_ip            = module.agents[each.key].ipv4_address
    ssh_port           = var.ssh_port
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.agents[each.key].ipv4_address
      port           = var.ssh_port
    }
    inline = [
      "nmcli connection modify eth1 +ipv4.routes '${var.wireguard_network_cidr} ${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}'",
      "nmcli connection up eth1",
    ]
  }

  # Remove WG route when external nodes are removed
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
      "nmcli connection modify eth1 -ipv4.routes '${self.triggers.wg_cidr}' 2>/dev/null || true",
      "nmcli connection up eth1 2>/dev/null || true",
    ]
  }

  depends_on = [
    null_resource.cp_wireguard,
    null_resource.agents
  ]
}

resource "null_resource" "robot_wg_route" {
  for_each = local.any_non_full_mesh ? local.robot_nodes : {}

  triggers = {
    wg_cidr            = var.wireguard_network_cidr
    node_ip            = each.value.ipv4_address
    ssh_port           = each.value.ssh_port
    vlan_id            = each.value.vlan_id
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = each.value.ipv4_address
      port           = each.value.ssh_port
    }
    inline = [
      "nmcli connection modify vlan${each.value.vlan_id} +ipv4.routes '${var.wireguard_network_cidr} ${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}'",
      "nmcli connection up vlan${each.value.vlan_id}",
    ]
  }

  # Remove WG route when external nodes are removed
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
      "nmcli connection modify vlan${self.triggers.vlan_id} -ipv4.routes '${self.triggers.wg_cidr}' 2>/dev/null || true",
      "nmcli connection up vlan${self.triggers.vlan_id} 2>/dev/null || true",
    ]
  }

  depends_on = [
    null_resource.cp_wireguard,
    null_resource.robot_vlan_setup
  ]
}

# ---
# K3s Config Upload
# ---
resource "null_resource" "external_agent_config" {
  for_each = local.external_nodes

  triggers = {
    config = sha1(yamlencode(local.k3s-external-agent-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = each.value.ipv4_address
    port           = each.value.ssh_port
  }

  provisioner "file" {
    content     = yamlencode(local.k3s-external-agent-config[each.key])
    destination = "/tmp/config.yaml"
  }

  provisioner "remote-exec" {
    inline = [local.k3s_config_update_script]
  }

  depends_on = [
    null_resource.external_wireguard,
    null_resource.cp_wireguard
  ]
}

# ---
# K3s Install & Start
# ---
resource "null_resource" "external_agents" {
  for_each = local.external_nodes

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

  provisioner "remote-exec" {
    inline = local.install_k3s_agent_baremetal
  }

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
    null_resource.external_agent_config,
    null_resource.external_wireguard
  ]
}

# ---
# K3s Registries
# ---
resource "null_resource" "external_registries" {
  for_each = local.external_nodes

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

  depends_on = [null_resource.external_agents]
}

# ---
# Firewall (iptables)
# ---
resource "null_resource" "external_firewall" {
  for_each = local.external_nodes

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

  depends_on = [null_resource.external_wireguard]
}

# ---
# Longhorn Disk Configuration
# ---
resource "null_resource" "external_longhorn_disks" {
  for_each = {
    for k, v in local.external_nodes : k => v
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

  depends_on = [null_resource.external_agents]
}

resource "null_resource" "external_longhorn_unschedule" {
  for_each = {
    for k, v in local.external_nodes : k => v
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

  depends_on = [null_resource.external_agents]
}

# ---
# Cleanup on node removal: drain k8s node, stop services, remove configs
# ---
resource "null_resource" "external_cleanup" {
  for_each = local.external_nodes

  triggers = {
    node_name          = each.value.name
    node_ip            = each.value.ipv4_address
    ssh_port           = each.value.ssh_port
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
      "nft delete table inet k3s-firewall 2>/dev/null || true",
      "rm -f /etc/rancher/k3s/config.yaml /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [null_resource.external_agents]
}
