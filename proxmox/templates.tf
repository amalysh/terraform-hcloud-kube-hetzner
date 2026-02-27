check "vm_template_required" {
  assert {
    condition     = var.create_vm_template || var.vm_template_id != null
    error_message = "vm_template_id is required when create_vm_template = false."
  }
}

locals {
  cloud_image_urls = {
    ubuntu  = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    microos = "https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2"
  }
  cloud_image_url    = var.cloud_image_url != "" ? var.cloud_image_url : local.cloud_image_urls[var.vm_os]
  template_node_name = var.proxmox_nodes[0]
}

# Download cloud image to the first Proxmox node
resource "proxmox_virtual_environment_download_file" "cloud_image" {
  count        = var.create_vm_template ? 1 : 0
  content_type = "iso"
  datastore_id = var.image_datastore
  node_name    = local.template_node_name
  url          = local.cloud_image_url
  file_name    = "${var.cluster_name}-cloud-image.img"
}

# Create a single VM template on the first Proxmox node.
# Cross-node cloning is handled by the host module's clone block
# with node_name (source) and datastore_id (target).
resource "proxmox_virtual_environment_vm" "template" {
  count     = var.create_vm_template ? 1 : 0
  name      = "${var.cluster_name}-template"
  node_name = local.template_node_name
  template  = true

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.vm_datastore
    file_id      = proxmox_virtual_environment_download_file.cloud_image[0].id
    interface    = "scsi0"
    size         = 10
    discard      = "on"
    iothread     = true
  }

  # Two NICs matching the VM layout: public + private SDN
  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  scsi_hardware = "virtio-scsi-pci"

  serial_device {}

  lifecycle {
    ignore_changes = [network_device]
  }
}
