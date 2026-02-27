module "kubeconfig" {
  source = "./common/modules/kubeconfig"

  control_plane_host = module.control_planes[keys(module.control_planes)[0]].ipv4_address
  ssh_port           = var.ssh_port
  ssh_private_key    = var.ssh_private_key
  cluster_name       = var.cluster_name
  create_kubeconfig  = var.create_kubeconfig

  # Pre-compute the server address: use LB if enabled, otherwise let the module default to control_plane_host
  kubeconfig_server_address = var.kubeconfig_server_address != "" ? var.kubeconfig_server_address : (
    var.use_control_plane_lb ? hcloud_load_balancer.control_plane[0].ipv4 : ""
  )

  depends_on = [null_resource.control_planes]
}
