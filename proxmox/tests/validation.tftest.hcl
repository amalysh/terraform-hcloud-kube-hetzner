# Validation tests for the proxmox module
# Tests variable validation blocks using mock providers (no real infrastructure)

mock_provider "proxmox" {}
mock_provider "github" {}
mock_provider "remote" {}

# Minimum valid defaults for all tests
# create_vm_template = true (default) — no vm_template_id needed
variables {
  proxmox_api_token = "test@pve!token=secret"
  ssh_public_key    = "ssh-ed25519 AAAAC3test test@test"
  ssh_private_key   = "fake-key-for-testing"
  control_plane_vip = "10.0.0.100"
  proxmox_nodes     = ["pve"]
  control_plane_nodepools = [
    {
      name  = "cp-pool"
      count = 1
      # node_name omitted — inherits from proxmox_nodes
    }
  ]
  agent_nodepools = [
    {
      name  = "agent-pool"
      count = 1
    }
  ]
}

# --- Valid inputs ---

run "valid_defaults" {
  command = plan
}

# --- cluster_name validation ---

run "invalid_cluster_name_uppercase" {
  command = plan

  variables {
    cluster_name = "MyCluster"
  }

  expect_failures = [var.cluster_name]
}

run "invalid_cluster_name_special_chars" {
  command = plan

  variables {
    cluster_name = "my_cluster!"
  }

  expect_failures = [var.cluster_name]
}

run "invalid_cluster_name_starts_with_hyphen" {
  command = plan

  variables {
    cluster_name = "-cluster"
  }

  expect_failures = [var.cluster_name]
}

# --- sdn_zone_type validation ---

run "invalid_sdn_zone_type" {
  command = plan

  variables {
    sdn_zone_type = "bridge"
  }

  expect_failures = [var.sdn_zone_type]
}

run "valid_sdn_zone_vxlan" {
  command = plan

  variables {
    sdn_zone_type  = "vxlan"
    sdn_zone_peers = ["10.0.0.1"]
  }
}

run "valid_sdn_zone_simple" {
  command = plan

  variables {
    sdn_zone_type = "simple"
  }
}

run "valid_sdn_zone_vlan" {
  command = plan

  variables {
    sdn_zone_type = "vlan"
  }
}

# --- vm_os validation ---

run "invalid_vm_os" {
  command = plan

  variables {
    vm_os = "debian"
  }

  expect_failures = [var.vm_os]
}

# --- cni_plugin validation ---

run "invalid_cni_plugin" {
  command = plan

  variables {
    cni_plugin = "weave"
  }

  expect_failures = [var.cni_plugin]
}

# --- ingress_controller validation ---

run "invalid_ingress_controller" {
  command = plan

  variables {
    ingress_controller = "caddy"
  }

  expect_failures = [var.ingress_controller]
}

# --- proxmox_nodes inheritance ---

run "nodepool_inherits_proxmox_nodes" {
  command = plan

  variables {
    proxmox_nodes = ["pve1", "pve2", "pve3"]
    control_plane_nodepools = [
      {
        name  = "cp-pool"
        count = 3
      }
    ]
    agent_nodepools = [
      {
        name  = "agent-pool"
        count = 2
      }
    ]
  }
}

run "nodepool_overrides_proxmox_nodes" {
  command = plan

  variables {
    proxmox_nodes = ["pve1", "pve2", "pve3"]
    control_plane_nodepools = [
      {
        name      = "cp-pool"
        node_name = ["pve1"]
        count     = 1
      }
    ]
    agent_nodepools = [
      {
        name      = "agent-pool"
        node_name = ["pve2", "pve3"]
        count     = 2
      }
    ]
  }
}

# --- VM template creation ---

run "auto_template_defaults" {
  command = plan

  variables {
    create_vm_template = true
  }
}

run "manual_template_valid" {
  command = plan

  variables {
    create_vm_template = false
    vm_template_id     = 9000
  }
}

# --- data disk ---

run "nodepool_with_data_disk" {
  command = plan

  variables {
    agent_nodepools = [
      {
        name           = "agent-pool"
        count          = 1
        data_disk_size = 100
      }
    ]
  }
}

run "nodepool_with_data_disk_custom_datastore" {
  command = plan

  variables {
    agent_nodepools = [
      {
        name                = "agent-pool"
        count               = 1
        data_disk_size      = 200
        data_disk_datastore = "ceph-pool"
      }
    ]
  }
}
