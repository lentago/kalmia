terraform {
  required_version = ">= 1.5.0" # `import` blocks land in 1.5

  required_providers {
    proxmox = {
      # Pinned to a minor: the provider is pre-1.0 (SDKv2 → Plugin Framework
      # migration in progress) and minors can break. Bump deliberately.
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
