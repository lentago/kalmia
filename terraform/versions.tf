terraform {
  required_version = ">= 1.7.0" # `import` blocks with for_each land in 1.7

  required_providers {
    proxmox = {
      # Pinned to a minor: the provider is pre-1.0 (SDKv2 → Plugin Framework
      # migration in progress) and minors can break. Bump deliberately: review
      # the provider CHANGELOG for the skipped minors, then `terraform init
      # -upgrade` and require a clean CI plan. Floor is 0.115 because
      # backup-jobs.tf uses `exclude` (0.112) and `comment` (0.115) — #104.
      source  = "bpg/proxmox"
      version = "~> 0.115"
    }
  }
}
