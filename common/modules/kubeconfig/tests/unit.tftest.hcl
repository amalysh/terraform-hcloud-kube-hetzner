# Tests for common/modules/kubeconfig
# Uses mock_provider for remote and override_data for the SSH-fetched kubeconfig

mock_provider "remote" {}

# Sample kubeconfig YAML for testing
# Uses base64-encoded placeholder values for certs
variables {
  control_plane_host = "203.0.113.10"
  ssh_private_key    = "fake-key-for-testing"
  cluster_name       = "test-cluster"
  create_kubeconfig  = false
}

override_data {
  target = data.remote_file.kubeconfig
  values = {
    content = <<-YAML
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: https://127.0.0.1:6443
        certificate-authority-data: dGVzdC1jYS1kYXRh
      name: default
    contexts:
    - context:
        cluster: default
        user: default
      name: default
    current-context: default
    users:
    - name: default
      user:
        client-certificate-data: dGVzdC1jbGllbnQtY2VydA==
        client-key-data: dGVzdC1jbGllbnQta2V5
    YAML
  }
}

# --- Kubeconfig parsing ---

run "parses_kubeconfig" {
  command = plan

  assert {
    condition     = output.kubeconfig_data.cluster_name == "test-cluster"
    error_message = "cluster_name should match the variable"
  }

  assert {
    condition     = can(regex("test-cluster", output.kubeconfig))
    error_message = "kubeconfig content should contain cluster name replacing 'default'"
  }

  assert {
    condition     = output.kubeconfig_data.client_certificate == "test-client-cert"
    error_message = "client_certificate should be base64-decoded"
  }

  assert {
    condition     = output.kubeconfig_data.client_key == "test-client-key"
    error_message = "client_key should be base64-decoded"
  }

  assert {
    condition     = output.kubeconfig_data.cluster_ca_certificate == "test-ca-data"
    error_message = "cluster_ca_certificate should be base64-decoded"
  }
}

run "server_address_default" {
  command = plan

  variables {
    kubeconfig_server_address = ""
  }

  assert {
    condition     = can(regex("203\\.0\\.113\\.10", output.kubeconfig_data.host))
    error_message = "When kubeconfig_server_address is empty, should use control_plane_host"
  }
}

run "server_address_override" {
  command = plan

  variables {
    kubeconfig_server_address = "10.0.0.1"
  }

  assert {
    condition     = can(regex("10\\.0\\.0\\.1", output.kubeconfig_data.host))
    error_message = "When kubeconfig_server_address is set, it should replace the server address"
  }
}

run "create_kubeconfig_false" {
  command = plan

  variables {
    create_kubeconfig = false
  }

  assert {
    condition     = output.kubeconfig_file == ""
    error_message = "kubeconfig_file should be empty when create_kubeconfig is false"
  }
}

run "create_kubeconfig_true" {
  command = plan

  variables {
    create_kubeconfig = true
  }

  assert {
    condition     = output.kubeconfig_file == "test-cluster_kubeconfig.yaml"
    error_message = "kubeconfig_file should be <cluster_name>_kubeconfig.yaml"
  }
}
