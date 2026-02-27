variable "k3s_exec_server_args" {
  type    = string
  default = ""
}

variable "k3s_exec_agent_args" {
  type    = string
  default = ""
}

variable "initial_k3s_channel" {
  type    = string
  default = "v1.30"
}

variable "install_k3s_version" {
  type    = string
  default = ""
}

variable "preinstall_exec" {
  type    = list(string)
  default = []
}

variable "postinstall_exec" {
  type    = list(string)
  default = []
}

variable "address_for_connectivity_test" {
  type    = string
  default = "1.1.1.1"
}

variable "additional_k3s_environment" {
  type    = map(string)
  default = {}
}

variable "disable_selinux" {
  type    = bool
  default = false
}

variable "flannel_iface" {
  description = "Network interface for flannel CNI (e.g., eth1 for Hetzner, ens19 for Proxmox)"
  type        = string
  default     = "eth1"
}

variable "use_external_cloud_provider" {
  description = "Whether to set cloud-provider=external kubelet arg (true when using a CCM)"
  type        = bool
  default     = true
}

variable "cni_plugin" {
  type    = string
  default = "flannel"
  validation {
    condition     = contains(["flannel", "calico", "cilium"], var.cni_plugin)
    error_message = "Must be one of: flannel, calico, cilium."
  }
}

variable "disable_network_policy" {
  type    = bool
  default = false
}

variable "enable_wireguard" {
  type    = bool
  default = false
}

variable "interface_rename_script" {
  description = "Path to the interface rename script on the host. Set to empty string to skip."
  type        = string
  default     = "/etc/cloud/rename_interface.sh"
}

variable "k3s_registries" {
  type    = string
  default = ""
}
