# osmunda k3s node pool — the new Kubernetes platform (C01 phase 1,
# lentago/.github#119). The first guests this layer stands up for the k8s work.
# This layer owns only the two containers' *existence and shape*; the in-guest
# k3s install, the host-side LXC accommodations below, and the cluster join all
# live in the osmunda repo and run at k3s install time — not here.
#
# Placement: k3s-1 on pve5, k3s-2 on pve4 — deliberately split across two PVE
# hosts so losing a single node can't take the whole pair down at once.
#
# VMIDs 119 and 122 — the next two free IDs ascending (118 `lunaria` is the
# current top LXC; 120/121 are the `*-test` testbed VMs, 116/117 are the
# claytonia-owned bullpen pool). See README.md § Guest inventory.
#
# Unprivileged + nesting: precedent is the n8n Docker LXC (113 in
# containers.tf), which runs a containerized workload unprivileged with
# nesting + keyctl. k3s needs those same two features. The tradeoff of staying
# unprivileged (vs. a privileged LXC): the guest is UID-shifted with no direct
# host-root escape — safer on shared infra — but a handful of privileged
# operations (loading kernel modules, certain sysctls, exposing /dev/kmsg) must
# be arranged on the *host* rather than from inside the guest. That's
# acceptable: k3s ships its own userspace networking and those host-side tweaks
# are applied at install time (documented below), so this stays the repo's
# default posture — every kalmia-owned LXC is unprivileged.
#
# ─── k3s-in-LXC requirements (load-bearing; NOT expressible by this layer) ───
# Running k3s inside an unprivileged LXC needs host-side accommodations the
# bpg/proxmox provider cannot express — they are raw `lxc.*` config / host-node
# changes, not container-resource attributes. They are applied at k3s install
# time by the osmunda provisioning; recorded here so the dependency is visible
# from the guest definition itself:
#
#   * /dev/kmsg — kubelet/containerd expect this device, but an unprivileged
#     LXC has none. Provisioning creates it (commonly a boot unit doing
#     `ln -s /dev/console /dev/kmsg`, or an `lxc.mount.entry`).
#   * cgroup v2 controllers — the container must see the cpu/cpuset/memory
#     controllers delegated to it. The cluster is unified cgroup2 already and
#     k3s runs with the systemd cgroup driver; controller delegation into an
#     unprivileged guest is a host-side `lxc.cgroup2.*` / systemd-delegation
#     step done at install time.
#   * swap accounting / swap off — kubelet wants swap disabled (or explicit
#     NodeSwap config). These containers set `swap = 0` for that reason; memory
#     cgroup swap accounting on the host is assumed enabled.
#   * nesting + keyctl (set BELOW) — the only two pieces this layer *can*
#     express: nesting lets runc/containerd run nested, keyctl grants the
#     kernel keyring containerd's snapshotter needs.
#
# Any further `lxc.mount.entry` / apparmor tweaks a later add-on needs (e.g. a
# Longhorn/CSI storage driver) are likewise install-time host concerns, out of
# scope for this file.

locals {
  k3s_nodes = {
    "k3s-1" = { vm_id = 119, node_name = "pve5" }
    "k3s-2" = { vm_id = 122, node_name = "pve4" }
  }
}

resource "proxmox_virtual_environment_container" "k3s" {
  for_each = local.k3s_nodes

  node_name     = each.value.node_name
  vm_id         = each.value.vm_id
  description   = "osmunda k3s node (${each.key}) — Kubernetes platform, C01 phase 1 (lentago/.github#119). In-guest k3s install/join provisioned from the osmunda repo; this layer owns only the container.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
    keyctl  = true # containerd keyring — see k3s-in-LXC notes above
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 6144
    swap      = 0 # kubelet wants swap off — see k3s-in-LXC notes above
  }

  disk {
    datastore_id = "local-lvm"
    size         = 24
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = each.key

    dns {
      domain  = "local"
      servers = ["192.168.139.1"]
    }

    # DHCP on the LAN — leases/reservations are handled on the LAN DHCP server,
    # not pinned here (unlike the imported static-IP service LXCs).
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  lifecycle {
    # template_file_id is create-only and cannot be reconciled later — same
    # guard the other created/imported containers carry (see lunaria, 118).
    ignore_changes = [operating_system]
  }
}
