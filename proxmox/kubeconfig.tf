module "kubeconfig" {
  source = "../common/modules/kubeconfig"

  control_plane_host        = module.control_planes[keys(module.control_planes)[0]].ipv4_address
  ssh_port                  = var.ssh_port
  ssh_private_key           = var.ssh_private_key
  kubeconfig_server_address = var.kubeconfig_server_address != "" ? var.kubeconfig_server_address : var.control_plane_vip
  cluster_name              = var.cluster_name
  create_kubeconfig         = var.create_kubeconfig

  depends_on = [null_resource.first_control_plane]
}
