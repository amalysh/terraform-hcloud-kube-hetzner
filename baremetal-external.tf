# ---
# Cilium node encryption opt-out: label CPs BEFORE kustomization applies Cilium values.
# When Cilium + external nodes + enable_wireguard: nodeEncryption is ON with a custom
# opt-out selector (node-encryption-opt-out=true). CPs must have this label before Cilium
# reads the selector, otherwise Cilium BPF blocks etcd traffic (bootstrap chicken-and-egg).
# External nodes get the label via k3s node-label at registration time.
# ---
resource "terraform_data" "cp_node_encryption_opt_out" {
  count = local.is_cilium_cni && local.has_external_nodes && var.enable_wireguard ? 1 : 0

  triggers_replace = {
    cp_nodes = join(",", [for k, v in module.control_planes : v.name])
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port

    bastion_host        = local.ssh_bastion.bastion_host
    bastion_port        = local.ssh_bastion.bastion_port
    bastion_user        = local.ssh_bastion.bastion_user
    bastion_private_key = local.ssh_bastion.bastion_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "kubectl label nodes --overwrite -l node-role.kubernetes.io/control-plane node-encryption-opt-out=true",
    ]
  }

  depends_on = [
    terraform_data.first_control_plane,
  ]
}

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
      # Cilium + WireGuard encryption: Cilium creates cilium_wg0 tunnels between all nodes.
      # When a CP sends VXLAN through cilium_wg0 to the external node, the kernel picks
      # the wg-mesh interface Address as the source IP (since the route to the external
      # node goes via wg-mesh). The external node's cilium_wg0 then checks the decrypted
      # packet's source against allowed_ips. If the source doesn't match, it's an RX error.
      #
      # With overlay IP (172.22.0.x): kernel picks 172.22.0.x as source, but cilium_wg0
      # allowed_ips is 10.255.0.x/32 → mismatch → RX error → pod traffic to CPs fails.
      # With private IP (10.255.0.x): kernel picks 10.255.0.x as source → matches → works.
      #
      # Flannel: needs overlay IP because flannel-iface=wg-mesh routes pod traffic
      # through the WG overlay network using these addresses.
      address     = local.is_cilium_cni ? "${module.control_planes[cp_key].private_ipv4_address}/32" : "${local.cp_wg_ips[cp_key]}/32"
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
      listen_port = var.wireguard_port
      private_key = wireguard_asymmetric_key.external_node[ext_key].private_key
      cp_peers = [
        for idx, cp_key in local.cp_keys_sorted : {
          public_key = wireguard_asymmetric_key.cp_wg[cp_key].public_key
          endpoint   = "${module.control_planes[cp_key].ipv4_address}:${var.wireguard_port}"
          # Cilium: only route CP private IP through wg-mesh (no overlay IP needed).
          # Flannel: also route CP overlay IP for flannel-iface=wg-mesh.
          # Assigned gateway CP: also routes all cloud node IPs — autoscaled nodes
          # (and non-full-mesh agents) don't have wg-mesh and route via this CP.
          # The broad CIDR enables both outgoing routing and WireGuard reverse path
          # filtering for forwarded traffic. Only the assigned CP gets this to avoid
          # AllowedIPs trie conflicts (WireGuard maps each CIDR to one peer).
          allowed_ips = join(", ", compact([
            "${module.control_planes[cp_key].private_ipv4_address}/32",
            local.is_cilium_cni ? "" : "${local.cp_wg_ips[cp_key]}/32",
            cp_key == local.external_node_gateway_cp[ext_key] ? var.network_ipv4_cidr : "",
          ]))
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
    local.prefer_bundled_bin_config,
    v.selinux ? { selinux = true } : {}
  ) }
}

# ---
# WireGuard on Control Planes
# ---
resource "terraform_data" "cp_wireguard" {
  for_each = local.has_external_nodes ? local.control_plane_nodes : {}

  triggers_replace = {
    config_hash        = sha1(try(local.cp_wg_configs[each.key], ""))
    enable_forwarding  = local.any_non_full_mesh || length(var.autoscaler_nodepools) > 0
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
      timeout        = "10m"
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
        "systemctl restart wg-quick@wg-mesh || (sleep 5 && systemctl restart wg-quick@wg-mesh)",
      ],
      # Enable IP forwarding on CPs for gateway mode, or when autoscaler is enabled
      # (autoscaled nodes don't have wg-mesh and route to external nodes via CP).
      local.any_non_full_mesh || length(var.autoscaler_nodepools) > 0 ? [
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
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.cp_ip
      port           = self.triggers_replace.cp_ssh_port
    }
    inline = [
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "rm -f /etc/wireguard/wg-mesh.conf",
      "rm -f /etc/sysctl.d/99-wg-forward.conf",
      "sysctl -w net.ipv4.ip_forward=0 2>/dev/null || true",
    ]
  }

  # Wait for ALL control planes to be ready, not just the first one.
  # CPs may reboot during initial setup; SSHing too early causes connection loss.
  depends_on = [terraform_data.first_control_plane, terraform_data.control_planes]
}

# ---
# Hetzner Network Route: return path for external → autoscaled traffic.
# When a CP forwards traffic from external nodes to autoscaled nodes via eth1,
# Hetzner's anti-spoofing drops packets with foreign source IPs unless a
# network route exists. This route tells the Hetzner gateway to accept forwarded
# traffic for the WG overlay CIDR.
# The in-cluster route-failover CronJob updates the gateway on CP failure.
# ---
resource "hcloud_network_route" "wireguard_overlay" {
  for_each    = local.has_external_nodes ? local.external_node_wg_ips : {}
  network_id  = data.hcloud_network.k3s.id
  destination = "${each.value}/32"
  gateway     = module.control_planes[local.external_node_gateway_cp[each.key]].private_ipv4_address

  depends_on = [hcloud_network_subnet.control_plane]
}

# ---
# Route Failover CronJob (monitors CP health, updates hcloud_network_route on failure)
# Runs in-cluster using the existing hcloud secret — no API token on external nodes.
# ---
resource "terraform_data" "wg_gw_route_failover" {
  count = local.has_external_nodes && length(var.autoscaler_nodepools) > 0 ? 1 : 0

  triggers_replace = {
    manifest_hash      = sha1(local.wg_gw_route_failover_yaml)
    cp_ip              = module.control_planes[local.cp_keys_sorted[0]].ipv4_address
    ssh_port           = var.ssh_port
    ssh_private_key    = var.ssh_private_key != null ? var.ssh_private_key : ""
    ssh_agent_identity = local.ssh_agent_identity != null ? local.ssh_agent_identity : ""
  }

  provisioner "file" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[local.cp_keys_sorted[0]].ipv4_address
      port           = var.ssh_port
    }
    content     = local.wg_gw_route_failover_yaml
    destination = "/tmp/wg-gw-route-failover.yaml"
  }

  provisioner "remote-exec" {
    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = module.control_planes[local.cp_keys_sorted[0]].ipv4_address
      port           = var.ssh_port
    }
    inline = ["kubectl apply -f /tmp/wg-gw-route-failover.yaml"]
  }

  # Cleanup on destroy
  provisioner "remote-exec" {
    when       = destroy
    on_failure = continue
    connection {
      user           = "root"
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.cp_ip
      port           = self.triggers_replace.ssh_port
    }
    inline = [
      "kubectl delete cronjob wg-gw-route-failover -n kube-system 2>/dev/null || true",
      "kubectl delete clusterrolebinding wg-gw-route-failover 2>/dev/null || true",
      "kubectl delete clusterrole wg-gw-route-failover 2>/dev/null || true",
      "kubectl delete serviceaccount wg-gw-route-failover -n kube-system 2>/dev/null || true",
    ]
  }

  depends_on = [terraform_data.first_control_plane, terraform_data.kustomization]
}

# WireGuard on External Nodes
# ---
resource "terraform_data" "external_base_setup" {
  for_each = local.external_nodes

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
resource "terraform_data" "external_base_setup_reboot_wait" {
  for_each = local.external_nodes

  triggers_replace = {
    base_setup_id = terraform_data.external_base_setup[each.key].id
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

  depends_on = [terraform_data.external_base_setup]
}

resource "terraform_data" "external_wireguard" {
  for_each = local.external_nodes

  triggers_replace = {
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
      "systemctl restart wg-quick@wg-mesh || (sleep 5 && systemctl restart wg-quick@wg-mesh)",
      # Verify connectivity to first CP via WG tunnel
      "timeout 60 bash -c 'until ping -c 1 ${module.control_planes[keys(module.control_planes)[0]].private_ipv4_address} >/dev/null 2>&1; do echo \"Waiting for WG tunnel...\"; sleep 2; done'",
    ]
  }

  depends_on = [
    terraform_data.external_base_setup,
    terraform_data.external_base_setup_reboot_wait,
    terraform_data.cp_wireguard
  ]
}

# ---
# Cloud Agent WG Config (full_mesh=true only)
# ---
resource "terraform_data" "agent_wireguard" {
  for_each = local.full_mesh_agent_nodes

  triggers_replace = {
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
      "systemctl restart wg-quick@wg-mesh || (sleep 5 && systemctl restart wg-quick@wg-mesh)",
    ]
  }

  # Cleanup when full_mesh external nodes are removed
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
      "systemctl stop wg-quick@wg-mesh 2>/dev/null || true",
      "systemctl disable wg-quick@wg-mesh 2>/dev/null || true",
      "rm -f /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [
    terraform_data.first_control_plane,
    terraform_data.external_wireguard
  ]
}

# ---
# Cloud Agent Routing (full_mesh=false: CPs as gateways)
# ---
resource "terraform_data" "agent_wg_route" {
  for_each = local.any_non_full_mesh ? local.agent_nodes : {}

  triggers_replace = {
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
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.node_ip
      port           = self.triggers_replace.ssh_port
    }
    inline = [
      "nmcli connection modify eth1 -ipv4.routes '${self.triggers_replace.wg_cidr}' 2>/dev/null || true",
      "nmcli connection up eth1 2>/dev/null || true",
    ]
  }

  depends_on = [
    terraform_data.cp_wireguard,
    terraform_data.agents
  ]
}

resource "terraform_data" "robot_wg_route" {
  for_each = local.any_non_full_mesh ? local.robot_nodes : {}

  triggers_replace = {
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
      private_key    = self.triggers_replace.ssh_private_key != "" ? self.triggers_replace.ssh_private_key : null
      agent_identity = self.triggers_replace.ssh_agent_identity != "" ? self.triggers_replace.ssh_agent_identity : null
      host           = self.triggers_replace.node_ip
      port           = self.triggers_replace.ssh_port
    }
    inline = [
      "nmcli connection modify vlan${self.triggers_replace.vlan_id} -ipv4.routes '${self.triggers_replace.wg_cidr}' 2>/dev/null || true",
      "nmcli connection up vlan${self.triggers_replace.vlan_id} 2>/dev/null || true",
    ]
  }

  depends_on = [
    terraform_data.cp_wireguard,
    terraform_data.robot_vlan_setup
  ]
}

# ---
# K3s Config Upload
# ---
resource "terraform_data" "external_agent_config" {
  for_each = local.external_nodes

  triggers_replace = {
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
    terraform_data.external_wireguard,
    terraform_data.cp_wireguard
  ]
}

# ---
# K3s Install & Start
# ---
resource "terraform_data" "external_agents" {
  for_each = local.external_nodes

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
    terraform_data.first_control_plane,
    terraform_data.external_agent_config,
    terraform_data.external_wireguard
  ]
}

# ---
# K3s Registries
# ---
resource "terraform_data" "external_registries" {
  for_each = local.external_nodes

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

  depends_on = [terraform_data.external_agents]
}

# ---
# Firewall (iptables)
# ---
resource "terraform_data" "external_firewall" {
  for_each = local.external_nodes

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
    ]
  }

  # Step 2: Upload firewall script via CP bastion to external node's WG IP.
  # When user IP changes, bare metal nftables blocks direct SSH but CP
  # can always reach external node via wg-mesh.
  provisioner "file" {
    connection {
      user                = "root"
      private_key         = var.ssh_private_key
      agent_identity      = local.ssh_agent_identity
      host                = local.external_node_wg_ips[each.key]
      port                = each.value.ssh_port
      bastion_host        = module.control_planes[keys(module.control_planes)[0]].ipv4_address
      bastion_port        = var.ssh_port
      bastion_user        = "root"
      bastion_private_key = var.ssh_private_key
    }
    content     = local.baremetal_iptables_script
    destination = "/tmp/k3s-firewall.sh"
  }

  # Step 3: Execute firewall script on external node
  provisioner "remote-exec" {
    connection {
      user                = "root"
      private_key         = var.ssh_private_key
      agent_identity      = local.ssh_agent_identity
      host                = local.external_node_wg_ips[each.key]
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

  depends_on = [terraform_data.external_wireguard]
}

# ---
# Longhorn Disk Configuration
# ---
resource "terraform_data" "external_longhorn_disks" {
  for_each = {
    for k, v in local.external_nodes : k => v
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

  depends_on = [terraform_data.external_agents]
}

resource "terraform_data" "external_longhorn_unschedule" {
  for_each = {
    for k, v in local.external_nodes : k => v
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

  depends_on = [terraform_data.external_agents]
}

# ---
# Cleanup on node removal: drain k8s node, stop services, remove configs
# ---
resource "terraform_data" "external_cleanup" {
  for_each = local.external_nodes

  triggers_replace = {
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
      "nft delete table inet k3s-firewall 2>/dev/null || true",
      "rm -f /etc/rancher/k3s/config.yaml /etc/wireguard/wg-mesh.conf",
    ]
  }

  depends_on = [terraform_data.external_agents]
}

# State migration: null_resource → terraform_data
moved {
  from = null_resource.cp_wireguard
  to   = terraform_data.cp_wireguard
}
moved {
  from = null_resource.external_base_setup
  to   = terraform_data.external_base_setup
}
moved {
  from = null_resource.external_base_setup_reboot_wait
  to   = terraform_data.external_base_setup_reboot_wait
}
moved {
  from = null_resource.external_wireguard
  to   = terraform_data.external_wireguard
}
moved {
  from = null_resource.agent_wireguard
  to   = terraform_data.agent_wireguard
}
moved {
  from = null_resource.agent_wg_route
  to   = terraform_data.agent_wg_route
}
moved {
  from = null_resource.robot_wg_route
  to   = terraform_data.robot_wg_route
}
moved {
  from = null_resource.external_agent_config
  to   = terraform_data.external_agent_config
}
moved {
  from = null_resource.external_agents
  to   = terraform_data.external_agents
}
moved {
  from = null_resource.external_registries
  to   = terraform_data.external_registries
}
moved {
  from = null_resource.external_firewall
  to   = terraform_data.external_firewall
}
moved {
  from = null_resource.external_longhorn_disks
  to   = terraform_data.external_longhorn_disks
}
moved {
  from = null_resource.external_longhorn_unschedule
  to   = terraform_data.external_longhorn_unschedule
}
moved {
  from = null_resource.external_cleanup
  to   = terraform_data.external_cleanup
}
