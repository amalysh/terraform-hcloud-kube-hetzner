# Validation tests for the Hetzner root module
# Tests the 25 variable validation blocks using mock providers (no real infrastructure)

mock_provider "hcloud" {}
mock_provider "github" {}
mock_provider "remote" {}

# Minimum valid defaults for all tests
# Version variables are set explicitly to avoid GitHub data source calls (which return null when mocked)
variables {
  hcloud_token        = "fake-token-for-testing"
  ssh_public_key      = "ssh-ed25519 AAAAC3test test@test"
  ssh_private_key     = "fake-key-for-testing"
  hetzner_ccm_version = "v1.20.0"
  hetzner_csi_version = "v2.10.0"
  kured_version       = "1.16.0"
  calico_version      = "v3.29.0"
  control_plane_nodepools = [
    {
      name        = "cp-pool"
      os          = "microos"
      server_type = "cpx21"
      location    = "fsn1"
      labels      = []
      taints      = []
      count       = 1
    }
  ]
  agent_nodepools = [
    {
      name        = "agent-pool"
      os          = "microos"
      server_type = "cpx21"
      location    = "fsn1"
      labels      = []
      taints      = []
      count       = 1
    }
  ]
  # Provide at least one autoscaler nodepool to avoid autoscaler-agents.tf line 3 crash
  autoscaler_nodepools = [
    {
      name        = "autoscaler-pool"
      os          = "microos"
      server_type = "cpx21"
      location    = "fsn1"
      min_nodes   = 0
      max_nodes   = 3
    }
  ]
}

override_data {
  target = data.hcloud_image.microos_x86_snapshot
  values = {
    id = "12345"
  }
}

override_data {
  target = data.hcloud_image.microos_arm_snapshot
  values = {
    id = "12346"
  }
}

override_data {
  target = data.hcloud_network.k3s
  values = {
    id   = "99999"
    name = "k3s-network"
  }
}

# Note: No valid_minimal plan test — the root module has too many interconnected
# data sources (GitHub releases, hcloud_image snapshots) for mock-based plan testing.
# Only variable validation tests are included here, which work because validations
# run before the plan phase.

# --- cluster_name ---

run "invalid_cluster_name_uppercase" {
  command = plan

  variables {
    cluster_name = "MyCluster"
  }

  expect_failures = [var.cluster_name]
}

run "invalid_cluster_name_special" {
  command = plan

  variables {
    cluster_name = "my_cluster!"
  }

  expect_failures = [var.cluster_name]
}

# --- ssh_port ---

run "invalid_ssh_port_negative" {
  command = plan

  variables {
    ssh_port = -1
  }

  expect_failures = [var.ssh_port]
}

run "invalid_ssh_port_high" {
  command = plan

  variables {
    ssh_port = 70000
  }

  expect_failures = [var.ssh_port]
}

# --- cni_plugin ---

run "invalid_cni_plugin" {
  command = plan

  variables {
    cni_plugin = "weave"
  }

  expect_failures = [var.cni_plugin]
}

# --- ingress_controller ---

run "invalid_ingress_controller" {
  command = plan

  variables {
    ingress_controller = "caddy"
  }

  expect_failures = [var.ingress_controller]
}

# --- initial_k3s_channel ---

run "invalid_initial_k3s_channel" {
  command = plan

  variables {
    initial_k3s_channel = "nightly"
  }

  expect_failures = [var.initial_k3s_channel]
}

# --- rancher_install_channel ---

run "invalid_rancher_install_channel" {
  command = plan

  variables {
    rancher_install_channel = "beta"
  }

  expect_failures = [var.rancher_install_channel]
}

# --- rancher_hostname ---

run "invalid_rancher_hostname" {
  command = plan

  variables {
    rancher_hostname = "not a hostname"
  }

  expect_failures = [var.rancher_hostname]
}

# --- lb_hostname ---

run "invalid_lb_hostname" {
  command = plan

  variables {
    lb_hostname = "not valid"
  }

  expect_failures = [var.lb_hostname]
}

# --- rancher_bootstrap_password ---

run "invalid_rancher_password_short" {
  command = plan

  variables {
    rancher_bootstrap_password = "tooshort"
  }

  expect_failures = [var.rancher_bootstrap_password]
}

# --- dns_servers ---

run "invalid_dns_servers_too_many" {
  command = plan

  variables {
    dns_servers = ["1.1.1.1", "8.8.8.8", "8.8.4.4", "9.9.9.9"]
  }

  expect_failures = [var.dns_servers]
}

# --- cilium_routing_mode ---

run "invalid_cilium_routing_mode" {
  command = plan

  variables {
    cilium_routing_mode = "direct"
  }

  expect_failures = [var.cilium_routing_mode]
}

# --- longhorn_fstype ---

run "invalid_longhorn_fstype" {
  command = plan

  variables {
    longhorn_fstype = "btrfs"
  }

  expect_failures = [var.longhorn_fstype]
}

# --- longhorn_replica_count ---

run "invalid_longhorn_replica_count" {
  command = plan

  variables {
    longhorn_replica_count = 0
  }

  expect_failures = [var.longhorn_replica_count]
}

# --- cluster_autoscaler_log_level ---

run "invalid_autoscaler_log_level" {
  command = plan

  variables {
    cluster_autoscaler_log_level = 10
  }

  expect_failures = [var.cluster_autoscaler_log_level]
}

# --- cluster_autoscaler_stderr_threshold ---

run "invalid_autoscaler_stderr" {
  command = plan

  variables {
    cluster_autoscaler_stderr_threshold = "DEBUG"
  }

  expect_failures = [var.cluster_autoscaler_stderr_threshold]
}

# --- control_plane_nodepools uniqueness ---

run "duplicate_control_plane_names" {
  command = plan

  variables {
    control_plane_nodepools = [
      {
        name        = "same-name"
        os          = "microos"
        server_type = "cpx21"
        location    = "fsn1"
        labels      = []
        taints      = []
        count       = 1
      },
      {
        name        = "same-name"
        os          = "microos"
        server_type = "cpx21"
        location    = "fsn1"
        labels      = []
        taints      = []
        count       = 1
      }
    ]
  }

  expect_failures = [var.control_plane_nodepools]
}

# --- agent_nodepools uniqueness ---

run "duplicate_agent_names" {
  command = plan

  variables {
    agent_nodepools = [
      {
        name        = "same-name"
        os          = "microos"
        server_type = "cpx21"
        location    = "fsn1"
        labels      = []
        taints      = []
        count       = 1
      },
      {
        name        = "same-name"
        os          = "microos"
        server_type = "cpx21"
        location    = "fsn1"
        labels      = []
        taints      = []
        count       = 1
      }
    ]
  }

  expect_failures = [var.agent_nodepools]
}

# --- agent_nodepools count vs nodes ---

run "agent_nodepool_both_count_and_nodes" {
  command = plan

  variables {
    agent_nodepools = [
      {
        name        = "bad-pool"
        os          = "microos"
        server_type = "cpx21"
        location    = "fsn1"
        labels      = []
        taints      = []
        count       = 2
        nodes = {
          "0" = {}
        }
      }
    ]
  }

  expect_failures = [var.agent_nodepools]
}

# --- base_domain ---

run "invalid_base_domain" {
  command = plan

  variables {
    base_domain = "not valid domain!"
  }

  expect_failures = [var.base_domain]
}

# --- system_upgrade_window_options ---

run "invalid_system_upgrade_window_partial" {
  command = plan

  variables {
    system_upgrade_window_options = {
      days     = "Mon,Tue"
      start    = ""
      end      = ""
      timezone = ""
    }
  }

  expect_failures = [var.system_upgrade_window_options]
}

# --- ingress_replica_count ---

run "invalid_ingress_replica_count" {
  command = plan

  variables {
    ingress_replica_count = -1
  }

  expect_failures = [var.ingress_replica_count]
}

# --- existing_network_id ---

run "invalid_existing_network_id_multiple" {
  command = plan

  variables {
    existing_network_id = ["id1", "id2"]
  }

  expect_failures = [var.existing_network_id]
}
