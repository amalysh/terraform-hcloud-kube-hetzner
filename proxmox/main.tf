## SDN Networking ##

# SDN zone names have a max of 8 characters in Proxmox
locals {
  sdn_zone_id = substr(var.cluster_name, 0, 8)
  sdn_vnet_id = substr("${var.cluster_name}vn", 0, 8)
}

# Create SDN Zone based on zone type
resource "proxmox_virtual_environment_sdn_zone_vxlan" "k3s" {
  count = var.sdn_zone_type == "vxlan" ? 1 : 0
  id    = local.sdn_zone_id
  peers = var.sdn_zone_peers
}

resource "proxmox_virtual_environment_sdn_zone_vlan" "k3s" {
  count  = var.sdn_zone_type == "vlan" ? 1 : 0
  id     = local.sdn_zone_id
  bridge = var.sdn_bridge
}

resource "proxmox_virtual_environment_sdn_zone_simple" "k3s" {
  count = var.sdn_zone_type == "simple" ? 1 : 0
  id    = local.sdn_zone_id
}

locals {
  sdn_zone_name = local.sdn_zone_id
}

# Create VNet (becomes a bridge on each PVE node)
resource "proxmox_virtual_environment_sdn_vnet" "k3s" {
  id   = local.sdn_vnet_id
  zone = local.sdn_zone_name

  depends_on = [
    proxmox_virtual_environment_sdn_zone_vxlan.k3s,
    proxmox_virtual_environment_sdn_zone_vlan.k3s,
    proxmox_virtual_environment_sdn_zone_simple.k3s,
  ]
}

# Create Subnet with gateway and optional SNAT
resource "proxmox_virtual_environment_sdn_subnet" "k3s" {
  cidr    = var.network_ipv4_cidr
  gateway = var.network_gateway
  snat    = var.enable_sdn_snat
  vnet    = proxmox_virtual_environment_sdn_vnet.k3s.id

  depends_on = [proxmox_virtual_environment_sdn_vnet.k3s]
}

# Apply SDN configuration to all PVE nodes
resource "proxmox_virtual_environment_sdn_applier" "apply" {
  depends_on = [proxmox_virtual_environment_sdn_subnet.k3s]
}

## K3s Token ##

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}
