variable "ssh_port" {
  description = "SSH port for sshd_config hardening"
  type        = number
  default     = 22
}

variable "ssh_max_auth_tries" {
  description = "Maximum SSH authentication attempts"
  type        = number
  default     = 6
}

variable "dns_servers" {
  description = "Custom DNS servers (empty = use DHCP DNS via NetworkManager)"
  type        = list(string)
  default     = []
}

variable "k3s_registries" {
  description = "K3s registries.yaml content (empty = skip)"
  type        = string
  default     = ""
}
