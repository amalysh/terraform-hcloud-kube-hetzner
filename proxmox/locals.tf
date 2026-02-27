locals {
  ssh_agent_identity = var.ssh_private_key == null ? var.ssh_public_key : null
  k3s_token          = var.k3s_token == null ? random_password.k3s_token.result : var.k3s_token

  cluster_prefix = "${var.cluster_name}-"

  # Resolve template: auto-created (single template) or user-provided
  effective_vm_template_id  = var.create_vm_template ? proxmox_virtual_environment_vm.template[0].vm_id : var.vm_template_id
  template_source_node_name = var.create_vm_template ? local.template_node_name : null

  # Interface names: eth1 when we control the template (udev rename), ens19 when user provides their own
  effective_flannel_iface         = var.create_vm_template ? "eth1" : var.flannel_iface
  effective_private_network_iface = var.create_vm_template ? "eth1" : var.private_network_iface

  # Node calculations
  control_plane_count    = sum([for v in var.control_plane_nodepools : v.count])
  agent_count            = sum([for v in var.agent_nodepools : v.count])
  is_single_node_cluster = (local.control_plane_count + local.agent_count) == 1

  using_klipper_lb                  = var.enable_klipper_metal_lb || local.is_single_node_cluster
  allow_scheduling_on_control_plane = local.is_single_node_cluster ? true : var.allow_scheduling_on_control_plane

  # Disable k3s built-in extras
  disable_extras = concat(
    var.enable_local_storage ? [] : ["local-storage"],
    local.using_klipper_lb ? [] : ["servicelb"],
    ["traefik"],
    var.enable_metrics_server ? [] : ["metrics-server"]
  )

  # Default k3s node labels
  default_agent_labels = concat([], var.automatically_upgrade_k3s ? ["k3s_upgrade=true"] : [])
  default_control_plane_labels = concat(
    local.allow_scheduling_on_control_plane ? [] : ["node.kubernetes.io/exclude-from-external-load-balancers=true"],
    var.automatically_upgrade_k3s ? ["k3s_upgrade=true"] : []
  )
  default_control_plane_taints = local.allow_scheduling_on_control_plane ? [] : ["node-role.kubernetes.io/control-plane:NoSchedule"]
  default_agent_taints         = var.cni_plugin == "cilium" ? ["node.cilium.io/agent-not-ready:NoExecute"] : []

  # Flatten control plane nodes with round-robin placement
  # node_name falls back to var.proxmox_nodes when not set per-pool
  control_plane_nodes = merge([
    for pool_index, nodepool_obj in var.control_plane_nodepools : {
      for node_index in range(nodepool_obj.count) :
      format("%s-%s-%s", pool_index, node_index, nodepool_obj.name) => {
        nodepool_name       = nodepool_obj.name
        node_name           = coalesce(nodepool_obj.node_name, var.proxmox_nodes)[node_index % length(coalesce(nodepool_obj.node_name, var.proxmox_nodes))]
        cores               = nodepool_obj.cores
        sockets             = nodepool_obj.sockets
        memory              = nodepool_obj.memory
        disk_size           = nodepool_obj.disk_size
        data_disk_size      = nodepool_obj.data_disk_size
        data_disk_datastore = nodepool_obj.data_disk_datastore
        labels              = concat(local.default_control_plane_labels, nodepool_obj.labels)
        taints              = concat(local.default_control_plane_taints, nodepool_obj.taints)
        kubelet_args        = nodepool_obj.kubelet_args
        index               = node_index
      }
    }
  ]...)

  # Flatten agent nodes with round-robin placement
  agent_nodes = merge([
    for pool_index, nodepool_obj in var.agent_nodepools : {
      for node_index in range(nodepool_obj.count) :
      format("%s-%s-%s", pool_index, node_index, nodepool_obj.name) => {
        nodepool_name       = nodepool_obj.name
        node_name           = coalesce(nodepool_obj.node_name, var.proxmox_nodes)[node_index % length(coalesce(nodepool_obj.node_name, var.proxmox_nodes))]
        cores               = nodepool_obj.cores
        sockets             = nodepool_obj.sockets
        memory              = nodepool_obj.memory
        disk_size           = nodepool_obj.disk_size
        data_disk_size      = nodepool_obj.data_disk_size
        data_disk_datastore = nodepool_obj.data_disk_datastore
        labels              = concat(local.default_agent_labels, nodepool_obj.labels)
        taints              = concat(local.default_agent_taints, nodepool_obj.taints)
        kubelet_args        = nodepool_obj.kubelet_args
        index               = node_index
      }
    }
  ]...)

  # Etcd S3 backup settings
  etcd_s3_snapshots = length(keys(var.etcd_s3_backup)) > 0 ? merge({ "etcd-s3" = true }, var.etcd_s3_backup) : {}

  # Labels
  labels = {
    provisioner = "terraform"
    engine      = "k3s"
    cluster     = var.cluster_name
  }

  # Kured options
  kured_options = merge({
    "reboot-command"          = "/usr/bin/systemctl reboot"
    "pre-reboot-node-labels"  = "kured=rebooting"
    "post-reboot-node-labels" = "kured=done"
    "period"                  = "5m"
    "reboot-sentinel"         = "/sentinel/reboot-required"
  }, {})

  # Ingress controller settings
  ingress_controller_service_names = {
    "traefik" = "traefik"
    "nginx"   = "nginx-ingress-nginx-controller"
    "haproxy" = "haproxy-kubernetes-ingress"
  }

  ingress_controller_install_resources = {
    "traefik" = ["traefik_ingress.yaml"]
    "nginx"   = ["nginx_ingress.yaml"]
    "haproxy" = ["haproxy_ingress.yaml"]
  }

  ingress_replica_count = local.agent_count > 2 ? 3 : (local.agent_count == 2 ? 2 : 1)

  # CNI install resources
  cni_install_resources = {
    "calico" = ["https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/calico.yaml"]
    "cilium" = ["cilium.yaml"]
  }

  cni_k3s_settings = module.k3s_config.cni_k3s_settings

  # Cloud-init injection strings (shared base + Proxmox-specific extras)
  proxmox_cloudinit_write_files_common = join("", [
    module.cloudinit_common.write_files,
    var.create_vm_template ? <<-UDEV

# Proxmox: udev interface rename (auto-created template)
- content: |
    SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:00:12.0", NAME="eth0"
    SUBSYSTEM=="net", ACTION=="add", KERNELS=="0000:00:13.0", NAME="eth1"
  path: /etc/udev/rules.d/70-persistent-net.rules
UDEV
    : "",
  ])

  proxmox_cloudinit_runcmd_common = join("", [
    module.cloudinit_common.runcmd,
    <<-PROXMOX

# Proxmox: enable qemu-guest-agent
- [systemctl, enable, '--now', 'qemu-guest-agent']
PROXMOX
    ,
    var.create_vm_template ? <<-UDEV

# Proxmox: reload udev rules for interface renaming
- [udevadm, control, '--reload-rules']
UDEV
    : "",
  ])
}

# Import shared cloud-init configuration
module "cloudinit_common" {
  source             = "../common/modules/cloudinit-common"
  ssh_port           = var.ssh_port
  ssh_max_auth_tries = var.ssh_max_auth_tries
  dns_servers        = var.dns_servers
  k3s_registries     = var.k3s_registries
}

# Import shared k3s configuration
module "k3s_config" {
  source = "../common/modules/k3s-config"

  k3s_exec_server_args          = var.k3s_exec_server_args
  k3s_exec_agent_args           = var.k3s_exec_agent_args
  initial_k3s_channel           = var.initial_k3s_channel
  install_k3s_version           = var.install_k3s_version
  preinstall_exec               = var.preinstall_exec
  postinstall_exec              = var.postinstall_exec
  address_for_connectivity_test = var.address_for_connectivity_test
  additional_k3s_environment    = var.additional_k3s_environment
  disable_selinux               = var.disable_selinux
  flannel_iface                 = local.effective_flannel_iface
  use_external_cloud_provider   = var.enable_proxmox_ccm
  cni_plugin                    = var.cni_plugin
  disable_network_policy        = var.disable_network_policy
  enable_wireguard              = var.enable_wireguard
  # Skip Hetzner-specific interface rename on Proxmox (handled via udev in cloud-init)
  interface_rename_script = ""
}
