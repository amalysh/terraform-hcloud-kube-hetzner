# Cloud-init user data snippet
resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore
  node_name    = var.node_name

  source_raw {
    data = var.cloudinit_user_data != "" ? var.cloudinit_user_data : templatefile("${path.module}/../../../common/templates/cloudinit.ubuntu.yaml.tpl", {
      hostname                     = local.name
      sshAuthorizedKeys            = concat([var.ssh_public_key], var.ssh_additional_public_keys)
      cloudinit_write_files_common = var.cloudinit_write_files_common
      cloudinit_runcmd_common      = var.cloudinit_runcmd_common
      swap_size                    = var.swap_size
      extra_packages               = var.extra_packages
    })
    file_name = "${local.name}-user-data.yaml"
  }
}

# VM creation via clone from template
resource "proxmox_virtual_environment_vm" "server" {
  name      = local.name
  node_name = var.node_name

  clone {
    vm_id        = var.vm_template_id
    node_name    = var.template_source_node_name
    datastore_id = var.vm_datastore
    full         = true
  }

  cpu {
    cores   = var.cores
    sockets = var.sockets
    type    = "host"
  }

  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = var.disk_size
    discard      = "on"
    iothread     = true
  }

  # Optional data disk
  dynamic "disk" {
    for_each = var.data_disk_size > 0 ? [1] : []
    content {
      datastore_id = var.data_disk_datastore != "" ? var.data_disk_datastore : var.vm_datastore
      interface    = "scsi1"
      size         = var.data_disk_size
      discard      = "on"
      iothread     = true
    }
  }

  # Primary NIC (public/management network, stays on default bridge)
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # Second NIC (private/SDN network)
  network_device {
    bridge = var.sdn_vnet_name
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  # Cloud-init configuration
  initialization {
    datastore_id      = var.vm_datastore
    user_data_file_id = proxmox_virtual_environment_file.user_data.id

    ip_config {
      # First NIC: DHCP for public/management
      ipv4 {
        address = "dhcp"
      }
    }

    ip_config {
      # Second NIC: Static IP on SDN network
      ipv4 {
        address = "${var.private_ipv4}/24"
        gateway = var.network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  tags = local.tags

  # Prevent destroying if certain attributes change
  lifecycle {
    ignore_changes = [
      clone,
      disk[0].size,
      node_name, # Placement is initial only; HA/migration handles moves
    ]
  }

  # Wait for qemu-guest-agent to report the IPs
  provisioner "local-exec" {
    command = <<-EOT
      echo '${local.ssh_client_identity}' > /tmp/${random_string.identity_file.result}
      chmod 600 /tmp/${random_string.identity_file.result}
    EOT
  }

  # Wait for the VM to be reachable via SSH (10 min timeout)
  provisioner "local-exec" {
    command = <<-EOT
      timeout 600 bash -c '
        until ssh ${local.ssh_args} -p ${var.ssh_port} -i /tmp/${random_string.identity_file.result} -o ConnectTimeout=2 root@${self.ipv4_addresses[0][0]} test -e /etc/node-ready 2>/dev/null
        do
          echo "Waiting for node ${local.name} to be ready..."
          sleep 3
        done
      '
    EOT
  }

  provisioner "local-exec" {
    command = "rm /tmp/${random_string.identity_file.result}"
  }

  # Disable auto upgrades if requested
  provisioner "remote-exec" {
    when = create
    inline = var.os == "ubuntu" ? (
      var.automatically_upgrade_os ? ["echo 'Auto-upgrades enabled'"] : ["systemctl --now disable unattended-upgrades || true"]
      ) : (
      var.automatically_upgrade_os ? ["echo 'Auto-upgrades enabled'"] : ["systemctl --now disable transactional-update.timer || true"]
    )

    connection {
      user           = "root"
      private_key    = var.ssh_private_key
      agent_identity = local.ssh_agent_identity
      host           = self.ipv4_addresses[0][0]
      port           = var.ssh_port
    }
  }
}
