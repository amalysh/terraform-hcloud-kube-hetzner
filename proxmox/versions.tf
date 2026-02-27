terraform {
  required_version = ">= 1.5.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.78.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.2"
    }
    remote = {
      source  = "tenstad/remote"
      version = ">= 0.1.3"
    }
  }
}
