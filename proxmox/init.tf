# Deploy kustomization manifests on the first control plane after k3s is ready

resource "null_resource" "kustomization" {
  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[keys(module.control_planes)[0]].ipv4_address
    port           = var.ssh_port
  }

  # Ensure manifest directory exists
  provisioner "remote-exec" {
    inline = ["mkdir -p /var/lib/rancher/k3s/server/manifests"]
  }

  # Deploy Proxmox CCM HelmChart (conditional)
  provisioner "remote-exec" {
    inline = var.enable_proxmox_ccm ? [
      <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/proxmox-ccm.yaml <<'MANIFEST'
      ${templatefile("${path.module}/templates/proxmox-ccm.yaml.tpl", {
      version = var.proxmox_ccm_version
      values  = indent(4, "existingConfigSecretName: proxmox-cloud-controller-manager")
})}
      MANIFEST
      EOT
] : ["echo 'Proxmox CCM disabled'"]
}

# Deploy Proxmox CSI HelmChart (conditional)
provisioner "remote-exec" {
  inline = var.enable_proxmox_csi ? [
    <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/proxmox-csi.yaml <<'MANIFEST'
      ${templatefile("${path.module}/templates/proxmox-csi.yaml.tpl", {
    version = var.proxmox_csi_version
    values  = indent(4, "existingConfigSecretName: proxmox-csi-plugin")
})}
      MANIFEST
      EOT
] : ["echo 'Proxmox CSI disabled'"]
}

# Deploy MetalLB (conditional)
provisioner "remote-exec" {
  inline = var.metallb_enabled && var.metallb_address_pool != "" ? [
    <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/metallb.yaml <<'MANIFEST'
      ${templatefile("${path.module}/templates/metallb.yaml.tpl", {
    version      = var.metallb_version
    values       = indent(4, "")
    address_pool = var.metallb_address_pool
})}
      MANIFEST
      EOT
] : ["echo 'MetalLB disabled or no address pool configured'"]
}

# Deploy ingress controller (conditional)
provisioner "remote-exec" {
  inline = var.ingress_controller == "traefik" ? [
    <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/traefik_ingress.yaml <<'MANIFEST'
      ${templatefile("${path.module}/../common/modules/k3s-addons/templates/traefik_ingress.yaml.tpl", {
    version          = ""
    target_namespace = "traefik"
    values = indent(4, yamlencode({
      deployment      = { replicas = local.ingress_replica_count }
      globalArguments = []
      service = {
        enabled = true
        type    = "LoadBalancer"
      }
    }))
})}
      MANIFEST
      EOT
] : var.ingress_controller == "nginx" ? [
<<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/nginx_ingress.yaml <<'MANIFEST'
      ${templatefile("${path.module}/../common/modules/k3s-addons/templates/nginx_ingress.yaml.tpl", {
version          = ""
target_namespace = "nginx"
values = indent(4, yamlencode({
  controller = {
    watchIngressWithoutClass = "true"
    kind                     = "Deployment"
    replicaCount             = local.ingress_replica_count
  }
}))
})}
      MANIFEST
      EOT
] : ["echo 'No ingress controller or haproxy (manual)'"]
}

# Deploy cert-manager (conditional)
provisioner "remote-exec" {
  inline = var.enable_cert_manager ? [
    <<-EOT
      cat > /var/lib/rancher/k3s/server/manifests/cert_manager.yaml <<'MANIFEST'
      ${templatefile("${path.module}/../common/modules/k3s-addons/templates/cert_manager.yaml.tpl", {
    version   = var.cert_manager_version
    bootstrap = true
    values    = indent(4, "crds:\n  enabled: true\n  keep: true")
})}
      MANIFEST
      EOT
] : ["echo 'cert-manager disabled'"]
}

# Deploy system upgrade controller (conditional)
provisioner "remote-exec" {
  inline = var.automatically_upgrade_k3s ? [
    "kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/system-upgrade-controller.yaml",
    "kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${var.sys_upgrade_controller_version}/crd.yaml",
  ] : ["echo 'Auto-upgrade disabled'"]
}

depends_on = [
  null_resource.first_control_plane,
  null_resource.control_planes,
  null_resource.agents,
]
}
