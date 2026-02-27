locals {
  ssh_agent_identity  = var.ssh_private_key == null ? var.ssh_public_key : null
  ssh_client_identity = var.ssh_private_key == null ? var.ssh_public_key : var.ssh_private_key
  ssh_args            = "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
  name                = "${var.name}-${random_string.server.result}"

  tags = concat(
    [for k, v in var.labels : "${k}=${v}"],
    ["provisioner=terraform", "cluster=${var.name}"]
  )
}

resource "random_string" "server" {
  length  = 3
  lower   = true
  special = false
  numeric = false
  upper   = false

  keepers = {
    name = var.name
  }
}

resource "random_string" "identity_file" {
  length  = 20
  lower   = true
  special = false
  numeric = true
  upper   = false
}
