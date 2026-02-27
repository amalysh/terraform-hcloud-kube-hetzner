variable "name" {
  type = string
}

variable "node_name" {
  description = "Proxmox VE node to place the VM on"
  type        = string
}

variable "vm_template_id" {
  description = "VM template ID to clone from"
  type        = number
}

variable "template_source_node_name" {
  description = "Node where the source template lives (null = same node as target)"
  type        = string
  default     = null
}

variable "cloudinit_write_files_common" {
  description = "Injected write_files YAML fragment for cloud-init"
  type        = string
  default     = ""
}

variable "cloudinit_runcmd_common" {
  description = "Injected runcmd YAML fragment for cloud-init"
  type        = string
  default     = ""
}

variable "extra_packages" {
  description = "Additional packages to install via cloud-init (e.g., qemu-guest-agent)"
  type        = list(string)
  default     = []
}

variable "swap_size" {
  description = "Swap file size (e.g., 512M, 1G). Empty = no swap."
  type        = string
  default     = ""
}

variable "ssh_additional_public_keys" {
  description = "Additional SSH public keys for node access"
  type        = list(string)
  default     = []
}

variable "cores" {
  type    = number
  default = 2
}

variable "sockets" {
  type    = number
  default = 1
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 40
}

variable "data_disk_size" {
  description = "Additional data disk size in GB (0 = no data disk)"
  type        = number
  default     = 0
}

variable "data_disk_datastore" {
  description = "Storage for data disk (empty = use vm_datastore)"
  type        = string
  default     = ""
}

variable "vm_datastore" {
  type    = string
  default = "local-lvm"
}

variable "snippet_datastore" {
  description = "Storage for cloud-init snippets"
  type        = string
  default     = "local"
}

variable "sdn_vnet_name" {
  description = "SDN VNet bridge name to connect the private NIC to"
  type        = string
}

variable "private_ipv4" {
  description = "Static private IP for the node (within SDN subnet)"
  type        = string
}

variable "network_gateway" {
  description = "Gateway IP for the private network"
  type        = string
}

variable "dns_servers" {
  description = "DNS servers for the node"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "ssh_port" {
  type    = number
  default = 22
}

variable "cloudinit_user_data" {
  description = "Custom cloud-init user data (full #cloud-config YAML)"
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels to set on the Proxmox VM (as tags)"
  type        = map(string)
  default     = {}
}

variable "automatically_upgrade_os" {
  type    = bool
  default = true
}

variable "os" {
  description = "Operating system: ubuntu or microos"
  type        = string
  default     = "ubuntu"
}
