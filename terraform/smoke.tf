# Phase-0 smoke check: proves endpoint reachability and token auth without
# touching any guest. Remove once real resources are imported.
data "proxmox_virtual_environment_nodes" "cluster" {}

output "cluster_nodes" {
  description = "Node names visible to the terraform@pve token."
  value       = data.proxmox_virtual_environment_nodes.cluster.names
}
