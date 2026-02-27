module "agents" {
  source   = "./modules/proxmox-host"
  for_each = local.agent_nodes

  name                         = "${local.cluster_prefix}agent-${each.value.nodepool_name}"
  node_name                    = each.value.node_name
  vm_template_id               = local.effective_vm_template_id
  template_source_node_name    = local.template_source_node_name
  cloudinit_write_files_common = local.proxmox_cloudinit_write_files_common
  cloudinit_runcmd_common      = local.proxmox_cloudinit_runcmd_common
  extra_packages               = ["qemu-guest-agent"]
  swap_size                    = var.swap_size
  cores                        = each.value.cores
  sockets                      = each.value.sockets
  memory                       = each.value.memory
  disk_size                    = each.value.disk_size
  data_disk_size               = each.value.data_disk_size
  data_disk_datastore          = each.value.data_disk_datastore
  vm_datastore                 = var.vm_datastore
  snippet_datastore            = var.snippet_datastore
  sdn_vnet_name                = proxmox_virtual_environment_sdn_vnet.k3s.id
  private_ipv4                 = cidrhost(var.network_ipv4_cidr, each.value.index + 101)
  network_gateway              = var.network_gateway
  dns_servers                  = length(var.dns_servers) > 0 ? var.dns_servers : ["1.1.1.1", "8.8.8.8"]
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_port                     = var.ssh_port
  os                           = var.vm_os
  automatically_upgrade_os     = var.automatically_upgrade_os

  labels = merge(local.labels, {
    role     = "agent"
    nodepool = each.value.nodepool_name
  })

  depends_on = [proxmox_virtual_environment_sdn_applier.apply]
}

# Install k3s agent on all agent nodes
resource "null_resource" "agents" {
  for_each = local.agent_nodes

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Upload k3s agent config
  provisioner "file" {
    content = yamlencode(merge(
      {
        node-name        = module.agents[each.key].name
        server           = "https://${var.control_plane_vip}:6443"
        token            = local.k3s_token
        flannel-iface    = local.effective_flannel_iface
        node-ip          = module.agents[each.key].private_ipv4_address
        node-external-ip = module.agents[each.key].ipv4_address
        node-label       = each.value.labels
        node-taint       = each.value.taints
        kubelet-arg      = module.k3s_config.kubelet_arg
      },
    ))
    destination = "/tmp/config.yaml"
  }

  # Install k3s agent
  provisioner "remote-exec" {
    inline = module.k3s_config.install_k3s_agent
  }

  # Start k3s-agent
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s-agent",
      "echo 'k3s agent started on ${module.agents[each.key].name}'"
    ]
  }

  depends_on = [null_resource.first_control_plane]
}
