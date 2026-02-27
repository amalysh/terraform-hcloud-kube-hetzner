module "control_planes" {
  source   = "./modules/proxmox-host"
  for_each = local.control_plane_nodes

  name                         = "${local.cluster_prefix}cp-${each.value.nodepool_name}"
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
  private_ipv4                 = cidrhost(var.network_ipv4_cidr, each.value.index + 11)
  network_gateway              = var.network_gateway
  dns_servers                  = length(var.dns_servers) > 0 ? var.dns_servers : ["1.1.1.1", "8.8.8.8"]
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_port                     = var.ssh_port
  os                           = var.vm_os
  automatically_upgrade_os     = var.automatically_upgrade_os

  labels = merge(local.labels, {
    role     = "control_plane"
    nodepool = each.value.nodepool_name
  })

  depends_on = [proxmox_virtual_environment_sdn_applier.apply]
}

# Install k3s on the first control plane
resource "null_resource" "first_control_plane" {
  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port
  }

  # Upload k3s config
  provisioner "file" {
    content = yamlencode(merge(
      {
        node-name                   = module.control_planes[keys(module.control_planes)[0]].name
        cluster-init                = true
        token                       = local.k3s_token
        cluster-cidr                = var.cluster_ipv4_cidr
        service-cidr                = var.service_ipv4_cidr
        flannel-iface               = local.effective_flannel_iface
        node-ip                     = module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
        advertise-address           = module.control_planes[keys(module.control_planes)[0]].private_ipv4_address
        node-external-ip            = module.control_planes[keys(module.control_planes)[0]].ipv4_address
        disable                     = local.disable_extras
        tls-san                     = [var.control_plane_vip, module.control_planes[keys(module.control_planes)[0]].ipv4_address]
        node-label                  = local.control_plane_nodes[keys(local.control_plane_nodes)[0]].labels
        node-taint                  = local.control_plane_nodes[keys(local.control_plane_nodes)[0]].taints
        kubelet-arg                 = module.k3s_config.kubelet_arg
        kube-controller-manager-arg = module.k3s_config.kube_controller_manager_arg
        disable-cloud-controller    = var.enable_proxmox_ccm
      },
      lookup(local.cni_k3s_settings, var.cni_plugin, {}),
      local.etcd_s3_snapshots,
    ))
    destination = "/tmp/config.yaml"
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = module.k3s_config.install_k3s_server
  }

  # Start k3s
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s",
      "timeout 120 bash -c 'while [[ \"$(curl -s -o /dev/null -w ''%%{http_code}'' --insecure https://localhost:6443/readyz 2>/dev/null)\" != \"200\" ]]; do sleep 2; done'",
      "echo 'k3s is ready'"
    ]
  }

  # Deploy kube-vip static pod manifest
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /var/lib/rancher/k3s/server/manifests",
      <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/kube-vip.yaml <<'KUBEVIP'
      ${templatefile("${path.module}/templates/kube-vip.yaml.tpl", {
      vip       = var.control_plane_vip
      version   = var.kube_vip_version
      interface = local.effective_private_network_iface
})}
      KUBEVIP
      EOT
]
}

# Deploy Proxmox CCM secret + chart
provisioner "remote-exec" {
  inline = var.enable_proxmox_ccm ? [
    "kubectl -n kube-system create secret generic proxmox-cloud-controller-manager --from-literal=config.yaml='${templatefile("${path.module}/templates/proxmox-ccm-config.yaml.tpl", {
      proxmox_api_token = var.proxmox_api_token
      cluster_name      = var.cluster_name
    })}' --dry-run=client -o yaml | kubectl apply -f -",
  ] : ["echo 'Proxmox CCM disabled'"]
}

# Deploy Proxmox CSI secret
provisioner "remote-exec" {
  inline = var.enable_proxmox_csi ? [
    "kubectl -n kube-system create secret generic proxmox-csi-plugin --from-literal=config.yaml='${templatefile("${path.module}/templates/proxmox-csi-config.yaml.tpl", {
      proxmox_api_token    = var.proxmox_api_token
      csi_storage_backends = var.csi_storage_backends
      cluster_name         = var.cluster_name
    })}' --dry-run=client -o yaml | kubectl apply -f -",
  ] : ["echo 'Proxmox CSI disabled'"]
}

depends_on = [module.control_planes]
}

# Install k3s on additional control planes
resource "null_resource" "control_planes" {
  for_each = { for k, v in local.control_plane_nodes : k => v if k != keys(local.control_plane_nodes)[0] }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Upload k3s config
  provisioner "file" {
    content = yamlencode(merge(
      {
        node-name                   = module.control_planes[each.key].name
        server                      = "https://${var.control_plane_vip}:6443"
        token                       = local.k3s_token
        cluster-cidr                = var.cluster_ipv4_cidr
        service-cidr                = var.service_ipv4_cidr
        flannel-iface               = local.effective_flannel_iface
        node-ip                     = module.control_planes[each.key].private_ipv4_address
        advertise-address           = module.control_planes[each.key].private_ipv4_address
        node-external-ip            = module.control_planes[each.key].ipv4_address
        disable                     = local.disable_extras
        tls-san                     = [var.control_plane_vip, module.control_planes[each.key].ipv4_address]
        node-label                  = each.value.labels
        node-taint                  = each.value.taints
        kubelet-arg                 = module.k3s_config.kubelet_arg
        kube-controller-manager-arg = module.k3s_config.kube_controller_manager_arg
        disable-cloud-controller    = var.enable_proxmox_ccm
      },
      lookup(local.cni_k3s_settings, var.cni_plugin, {}),
      local.etcd_s3_snapshots,
    ))
    destination = "/tmp/config.yaml"
  }

  # Install k3s server (joins existing cluster via kube-vip VIP)
  provisioner "remote-exec" {
    inline = module.k3s_config.install_k3s_server
  }

  # Start k3s
  provisioner "remote-exec" {
    inline = [
      "systemctl start k3s",
      "timeout 120 bash -c 'while [[ \"$(curl -s -o /dev/null -w ''%%{http_code}'' --insecure https://localhost:6443/readyz 2>/dev/null)\" != \"200\" ]]; do sleep 2; done'",
      "echo 'k3s is ready on ${module.control_planes[each.key].name}'"
    ]
  }

  # Deploy kube-vip on additional control planes too
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /var/lib/rancher/k3s/server/manifests",
      <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/kube-vip.yaml <<'KUBEVIP'
      ${templatefile("${path.module}/templates/kube-vip.yaml.tpl", {
      vip       = var.control_plane_vip
      version   = var.kube_vip_version
      interface = local.effective_private_network_iface
})}
      KUBEVIP
      EOT
]
}

depends_on = [null_resource.first_control_plane]
}
