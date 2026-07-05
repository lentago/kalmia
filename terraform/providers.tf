provider "proxmox" {
  endpoint = "https://192.168.139.8:8006/"

  # Auth: PROXMOX_VE_API_TOKEN env var (terraform@pve!kalmia token) — never
  # in code, tfvars, or CI logs. Creation commands: README.md § Auth.

  # The cluster serves its self-signed cert; trusting the PVE CA bundle
  # instead is tracked in README.md § Phases.
  insecure = true
}
