# HA groups for VM failover (PVE 8.x only)
# When enable_ha_groups is true, creates HA groups and assigns VMs
# for automatic failover management across Proxmox nodes.
#
# NOTE: On PVE 9.x, HA groups were migrated to affinity rules.
# The bpg/proxmox provider does not yet support affinity rules
# (see https://github.com/bpg/terraform-provider-proxmox/issues/2097).

resource "proxmox_virtual_environment_hagroup" "control_plane" {
  count = var.enable_ha_groups ? 1 : 0

  group      = "${var.cluster_name}-cp"
  comment    = "Control plane HA group for ${var.cluster_name}"
  restricted = true

  nodes = {
    for node in distinct(flatten([
      for np in var.control_plane_nodepools : coalesce(np.node_name, var.proxmox_nodes)
    ])) : node => null # null = equal priority
  }
}

resource "proxmox_virtual_environment_hagroup" "agent" {
  count = var.enable_ha_groups ? 1 : 0

  group      = "${var.cluster_name}-ag"
  comment    = "Agent HA group for ${var.cluster_name}"
  restricted = true

  nodes = {
    for node in distinct(flatten([
      for np in var.agent_nodepools : coalesce(np.node_name, var.proxmox_nodes)
    ])) : node => null
  }
}

resource "proxmox_virtual_environment_haresource" "control_plane" {
  for_each = var.enable_ha_groups ? local.control_plane_nodes : {}

  resource_id = "vm:${module.control_planes[each.key].id}"
  group       = proxmox_virtual_environment_hagroup.control_plane[0].group
  state       = "started"
  comment     = "Managed by Terraform"
}

resource "proxmox_virtual_environment_haresource" "agent" {
  for_each = var.enable_ha_groups ? local.agent_nodes : {}

  resource_id = "vm:${module.agents[each.key].id}"
  group       = proxmox_virtual_environment_hagroup.agent[0].group
  state       = "started"
  comment     = "Managed by Terraform"
}
