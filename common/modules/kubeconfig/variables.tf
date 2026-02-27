variable "control_plane_host" {
  description = "IP address of a control plane node to fetch kubeconfig from"
  type        = string
}

variable "ssh_port" {
  description = "SSH port on the control plane node"
  type        = number
  default     = 22
}

variable "ssh_private_key" {
  description = "SSH private key for authentication (null to use SSH agent)"
  type        = string
  default     = null
  sensitive   = true
}

variable "kubeconfig_server_address" {
  description = "Override the server address in kubeconfig (e.g., load balancer IP). Empty string means use control_plane_host."
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Cluster name to use in kubeconfig context"
  type        = string
}

variable "create_kubeconfig" {
  description = "Whether to create a local kubeconfig file"
  type        = bool
  default     = true
}

variable "depends_on_resources" {
  description = "Resources that must be created before fetching kubeconfig"
  type        = list(any)
  default     = []
}
