# Proxmox VE Firewall - Cluster-level security group for k3s nodes

resource "proxmox_virtual_environment_cluster_firewall_security_group" "k3s" {
  name    = "${var.cluster_name}-k3s"
  comment = "Firewall rules for ${var.cluster_name} k3s cluster"

  # Allow SSH
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = tostring(var.ssh_port)
    comment = "Allow SSH"
  }

  # Allow Kube API
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "6443"
    comment = "Allow Kube API Server"
  }

  # Allow HTTP/HTTPS for ingress
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "80"
    comment = "Allow HTTP"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "443"
    comment = "Allow HTTPS"
  }

  # Allow VXLAN (for SDN overlay)
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "4789"
    comment = "Allow VXLAN overlay"
  }

  # Allow k3s inter-node communication
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "10250"
    comment = "Allow Kubelet API"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "2379:2380"
    comment = "Allow etcd peer communication"
  }

  # Allow Flannel VXLAN
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "udp"
    dport   = "8472"
    comment = "Allow Flannel VXLAN"
  }

  # Allow ICMP
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "icmp"
    comment = "Allow ICMP ping"
  }
}
