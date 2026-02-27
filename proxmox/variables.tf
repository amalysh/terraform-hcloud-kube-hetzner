## Provider ##

variable "proxmox_api_token" {
  description = "Proxmox API token (format: user@realm!token-name=secret-value)"
  type        = string
  sensitive   = true
}

## Cluster ##

variable "cluster_name" {
  description = "Name of the Kubernetes cluster (used in resource naming and labels)"
  type        = string
  default     = "k3s"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9\\-]*[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be lowercase alphanumeric with hyphens, not starting/ending with hyphen."
  }
}

## SSH ##

variable "ssh_public_key" {
  description = "SSH public key for node access"
  type        = string
}

variable "ssh_private_key" {
  description = "SSH private key for provisioning (null to use SSH agent)"
  type        = string
  default     = null
  sensitive   = true
}

variable "ssh_port" {
  description = "SSH port on cluster nodes"
  type        = number
  default     = 22
}

## SDN Networking ##

variable "sdn_zone_type" {
  description = "Proxmox SDN zone type: vxlan (recommended for multi-node PVE), evpn, vlan, or simple"
  type        = string
  default     = "vxlan"
  validation {
    condition     = contains(["vxlan", "evpn", "vlan", "simple"], var.sdn_zone_type)
    error_message = "Must be one of: vxlan, evpn, vlan, simple."
  }
}

variable "sdn_zone_peers" {
  description = "List of Proxmox node IPs for VXLAN/EVPN peer-to-peer communication (required for vxlan/evpn zones)"
  type        = list(string)
  default     = []
}

variable "sdn_vlan_tag" {
  description = "VLAN tag for vlan zone type"
  type        = number
  default     = null
}

variable "sdn_bridge" {
  description = "Physical bridge interface for VLAN zones (e.g., vmbr0)"
  type        = string
  default     = "vmbr0"
}

variable "network_ipv4_cidr" {
  description = "IPv4 CIDR for the k8s node network (SDN subnet)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "network_gateway" {
  description = "Gateway IP for the SDN subnet. Must be within network_ipv4_cidr."
  type        = string
  default     = "10.0.0.1"
}

variable "enable_sdn_snat" {
  description = "Enable SNAT on the SDN subnet for outbound internet access"
  type        = bool
  default     = true
}

variable "cluster_ipv4_cidr" {
  description = "CIDR for Kubernetes pod network"
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_ipv4_cidr" {
  description = "CIDR for Kubernetes service network"
  type        = string
  default     = "10.43.0.0/16"
}

## Proxmox Nodes ##

variable "proxmox_nodes" {
  description = "Default list of Proxmox VE nodes for round-robin VM placement. Nodepools inherit this unless they set their own node_name."
  type        = list(string)
  default     = ["pve"]
}

## VM Configuration ##

variable "create_vm_template" {
  description = "Auto-create VM template from cloud image. When false, vm_template_id is required."
  type        = bool
  default     = true
}

variable "vm_template_id" {
  description = "Proxmox VM template ID. Required when create_vm_template = false."
  type        = number
  default     = null
}

variable "cloud_image_url" {
  description = "Custom cloud image URL. Leave empty to use the default for vm_os."
  type        = string
  default     = ""
}

variable "image_datastore" {
  description = "Proxmox storage for downloading cloud images (must support 'iso' content type). Note: local-lvm does NOT support iso content."
  type        = string
  default     = "local"
}

variable "vm_datastore" {
  description = "Proxmox storage for VM disks (e.g., local-lvm, ceph-pool)"
  type        = string
  default     = "local-lvm"
}

variable "snippet_datastore" {
  description = "Proxmox storage for cloud-init snippets (must have 'snippets' content type enabled)"
  type        = string
  default     = "local"
}

variable "vm_os" {
  description = "Default VM OS: ubuntu or microos"
  type        = string
  default     = "ubuntu"
  validation {
    condition     = contains(["ubuntu", "microos"], var.vm_os)
    error_message = "Must be ubuntu or microos."
  }
}

## Control Plane ##

variable "control_plane_nodepools" {
  description = "List of control plane nodepool configurations"
  type = list(object({
    name                = string
    node_name           = optional(list(string)) # Override proxmox_nodes for this pool
    cores               = optional(number, 2)
    sockets             = optional(number, 1)
    memory              = optional(number, 4096) # MB
    disk_size           = optional(number, 40)   # GB
    data_disk_size      = optional(number, 0)    # Additional data disk in GB (0 = none)
    data_disk_datastore = optional(string, "")   # Storage for data disk (empty = use vm_datastore)
    count               = number
    labels              = optional(list(string), [])
    taints              = optional(list(string), [])
    kubelet_args        = optional(list(string), [])
  }))
  default = [
    {
      name  = "cp-pool"
      count = 3
    }
  ]
}

## Agent Nodes ##

variable "agent_nodepools" {
  description = "List of agent nodepool configurations"
  type = list(object({
    name                = string
    node_name           = optional(list(string)) # Override proxmox_nodes for this pool
    cores               = optional(number, 2)
    sockets             = optional(number, 1)
    memory              = optional(number, 4096) # MB
    disk_size           = optional(number, 40)   # GB
    data_disk_size      = optional(number, 0)    # Additional data disk in GB (0 = none)
    data_disk_datastore = optional(string, "")   # Storage for data disk (empty = use vm_datastore)
    count               = number
    labels              = optional(list(string), [])
    taints              = optional(list(string), [])
    kubelet_args        = optional(list(string), [])
  }))
  default = [
    {
      name  = "agent-pool"
      count = 2
    }
  ]
}

## Load Balancing ##

variable "control_plane_vip" {
  description = "Virtual IP for kube-vip (control plane HA). Must be a free IP in the same network as nodes."
  type        = string
}

variable "kube_vip_version" {
  description = "kube-vip version tag (e.g., v0.8.7)"
  type        = string
  default     = "v0.8.7"
}

variable "metallb_enabled" {
  description = "Enable MetalLB for LoadBalancer services (required for ingress without cloud LB)"
  type        = bool
  default     = true
}

variable "metallb_address_pool" {
  description = "IP range for MetalLB address pool (e.g., 10.0.10.0/28 or 10.0.10.10-10.0.10.20)"
  type        = string
  default     = ""
}

variable "metallb_version" {
  description = "MetalLB Helm chart version"
  type        = string
  default     = "0.14.9"
}

## Kubernetes Configuration ##

variable "initial_k3s_channel" {
  type    = string
  default = "v1.30"
}

variable "install_k3s_version" {
  type    = string
  default = ""
}

variable "k3s_exec_server_args" {
  type    = string
  default = ""
}

variable "k3s_exec_agent_args" {
  type    = string
  default = ""
}

variable "k3s_token" {
  description = "Pre-defined k3s token for cluster recovery (null = auto-generated)"
  type        = string
  default     = null
  sensitive   = true
}

## CNI ##

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

## Ingress ##

variable "ingress_controller" {
  type    = string
  default = "traefik"
  validation {
    condition     = contains(["traefik", "nginx", "haproxy", "none"], var.ingress_controller)
    error_message = "Must be one of: traefik, nginx, haproxy, none."
  }
}

## Add-ons ##

variable "enable_cert_manager" {
  type    = bool
  default = true
}

variable "cert_manager_version" {
  type    = string
  default = ""
}

variable "enable_longhorn" {
  type    = bool
  default = false
}

variable "enable_rancher" {
  type    = bool
  default = false
}

variable "automatically_upgrade_k3s" {
  type    = bool
  default = true
}

variable "automatically_upgrade_os" {
  type    = bool
  default = true
}

## Proxmox CCM/CSI ##

variable "enable_proxmox_ccm" {
  description = "Enable Proxmox Cloud Controller Manager (sergelogvinov/proxmox-cloud-controller-manager)"
  type        = bool
  default     = true
}

variable "proxmox_ccm_version" {
  description = "Proxmox CCM Helm chart version"
  type        = string
  default     = "0.2.25"
}

variable "enable_proxmox_csi" {
  description = "Enable Proxmox CSI driver (sergelogvinov/proxmox-csi-plugin)"
  type        = bool
  default     = true
}

variable "proxmox_csi_version" {
  description = "Proxmox CSI Helm chart version"
  type        = string
  default     = "0.5.5"
}

variable "csi_storage_backends" {
  description = "List of Proxmox storage names for CSI provisioning (e.g., [\"local-lvm\", \"ceph-pool\"])"
  type        = list(string)
  default     = ["local-lvm"]
}

## HA Groups ##

variable "enable_ha_groups" {
  description = "Create Proxmox HA groups and assign VMs for automatic failover. PVE 8.x only — PVE 9.x uses affinity rules (not yet supported by provider)."
  type        = bool
  default     = false
}

## Misc ##

variable "dns_servers" {
  description = "Custom DNS servers for nodes"
  type        = list(string)
  default     = []
}

variable "swap_size" {
  description = "Swap file size (e.g., 512M, 1G). Empty = no swap."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|[1-9][0-9]{0,3}(G|M)$", var.swap_size))
    error_message = "Invalid swap size. Examples: 512M, 1G"
  }
}

variable "address_for_connectivity_test" {
  type    = string
  default = "1.1.1.1"
}

variable "create_kubeconfig" {
  type    = bool
  default = true
}

variable "kubeconfig_server_address" {
  description = "Override the server address in kubeconfig (default: control_plane_vip)"
  type        = string
  default     = ""
}

variable "preinstall_exec" {
  type    = list(string)
  default = []
}

variable "postinstall_exec" {
  type    = list(string)
  default = []
}

variable "flannel_iface" {
  description = "Network interface for flannel. Must match the SDN VNet interface name inside VMs (e.g., ens19 for second NIC on Proxmox)."
  type        = string
  default     = "ens19"
}

variable "private_network_iface" {
  description = "Name of the private network interface inside VMs (SDN VNet NIC)"
  type        = string
  default     = "ens19"
}

variable "sys_upgrade_controller_version" {
  description = "System upgrade controller version"
  type        = string
  default     = "v0.14.2"
}

variable "kured_version" {
  description = "Kured version (null to auto-fetch latest)"
  type        = string
  default     = null
}

variable "allow_scheduling_on_control_plane" {
  type    = bool
  default = false
}

variable "disable_selinux" {
  type    = bool
  default = true
}

variable "k3s_registries" {
  type    = string
  default = ""
}

variable "additional_k3s_environment" {
  type    = map(string)
  default = {}
}

variable "enable_klipper_metal_lb" {
  type    = bool
  default = false
}

variable "enable_local_storage" {
  type    = bool
  default = false
}

variable "enable_metrics_server" {
  type    = bool
  default = true
}

variable "disable_kube_proxy" {
  type    = bool
  default = false
}

variable "cilium_routing_mode" {
  type    = string
  default = "tunnel"
}

variable "cilium_values" {
  type    = string
  default = ""
}

variable "calico_values" {
  type    = string
  default = ""
}

variable "etcd_s3_backup" {
  type    = map(string)
  default = {}
}

variable "ssh_max_auth_tries" {
  type    = number
  default = 6
}
