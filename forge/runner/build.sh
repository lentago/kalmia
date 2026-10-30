#!/usr/bin/env bash
# build.sh — forge a versioned claytonia (bullpen) runner LXC template and
# publish it to a Proxmox vztmpl storage. Run as root ON A PVE NODE.
#
#   BUILD_VMID=N ./build.sh v2                          # build claytonia-runner-v2 from claytonia@main
#   BUILD_VMID=N VERIFY_VMID=M ./build.sh v2 --verify   # also instantiate + smoke-test the result
#
# BUILD_VMID (and VERIFY_VMID for --verify) have no default: pick VMIDs free
# across the whole cluster. The build refuses one that any node already uses.
#
# It is a "script + pct capture" builder (see forge/README.md § Tooling): the
# portable recipe is substrate.sh + claytonia's own gitops/install.sh; only this
# per-target wrapper is LXC/Proxmox-specific. Two layers go into the image:
#   1. substrate  — kalmia's OS contract (packages, claude user, Claude Code, gh,
#                   secret placeholders, first-boot de-templating).
#   2. software   — claytonia@REF's gitops loop, installed + force-deployed once,
#                   so the image ships claytonia's real runner and self-updates.
# Neither secrets nor NAS runtime state are ever baked.
set -euo pipefail

VERSION="${1:?usage: build.sh <version> [--verify]   e.g. build.sh v1}"
case "$VERSION" in v*) : ;; *) VERSION="v${VERSION}" ;; esac
VERIFY=0; [ "${2:-}" = "--verify" ] && VERIFY=1

# ---- config (env-overridable) ------------------------------------------------
CLAYTONIA_URL="${CLAYTONIA_URL:-https://github.com/lentago/claytonia.git}"
CLAYTONIA_REF="${CLAYTONIA_REF:-main}"
BASE_TEMPLATE="${BASE_TEMPLATE:-local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst}"
# No default: a hardcoded VMID eventually collides with a live guest (the old
# 119/118 defaults did, claytonia#65). Pick one free across the cluster.
BUILD_VMID="${BUILD_VMID:?set BUILD_VMID to a VMID free across the cluster (the throwaway build CT)}"
BUILD_STORAGE="${BUILD_STORAGE:-local-lvm}"   # throwaway rootfs
DISK_GB="${DISK_GB:-12}"
OUT_STORAGE="${OUT_STORAGE:-neptune}"         # publish target (must allow vztmpl)
OUT_CACHE="${OUT_CACHE:-/mnt/pve/neptune/template/cache}"
RETAIN="${RETAIN:-3}"                         # keep this many claytonia-runner-v* templates
NAME="claytonia-runner-${VERSION}"
OUT="${OUT_CACHE}/${NAME}.tar.zst"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBSTRATE="${SUBSTRATE:-$HERE/substrate.sh}"

say(){ echo "=== $* ==="; }
# Cluster-wide: `pct status` sees only this node, so a VMID in use on another
# node used to pass. `nextid --vmid` is the same check `pct create` applies.
# Returns 1 only for "already exists"; any other failure (no quorum, no
# permission) stops the build with pvesh's own message.
vmid_free(){
  local out
  out="$(pvesh get /cluster/nextid --vmid "$1" 2>&1)" && return 0
  case "$out" in *"already exists"*) return 1 ;; esac
  echo "cannot check VMID $1 cluster-wide: $out" >&2; exit 1
}
[ -f "$SUBSTRATE" ] || { echo "missing substrate: $SUBSTRATE" >&2; exit 1; }
[ -d "$OUT_CACHE" ] || { echo "vztmpl cache not found: $OUT_CACHE (is $OUT_STORAGE mounted?)" >&2; exit 1; }
[ -e "$OUT" ] && { echo "refusing to overwrite existing $OUT (bump the version)" >&2; exit 1; }
vmid_free "$BUILD_VMID" || { echo "build vmid $BUILD_VMID is in use somewhere in the cluster" >&2; exit 1; }
if [ "$VERIFY" = 1 ]; then
  VERIFY_VMID="${VERIFY_VMID:?--verify needs VERIFY_VMID, a VMID free across the cluster}"
  [ "$VERIFY_VMID" != "$BUILD_VMID" ] || { echo "VERIFY_VMID must differ from BUILD_VMID" >&2; exit 1; }
  vmid_free "$VERIFY_VMID" || { echo "verify vmid $VERIFY_VMID is in use somewhere in the cluster" >&2; exit 1; }
fi

# Destroy this run's containers on any exit path, and nothing else: only once
# this run has tried to create one, and only if it carries this run's hostname,
# so a create that half-failed is cleaned up and a guest that took the VMID in
# between is not.
BUILT=0; VERIFYING=0
ours(){ pct config "$1" 2>/dev/null | grep -qx "hostname: $2"; }
cleanup(){
  if [ "$BUILT" = 1 ] && ours "$BUILD_VMID" claytonia-forge-build; then
    pct unmount "$BUILD_VMID" >/dev/null 2>&1 || true
    pct destroy "$BUILD_VMID" --force >/dev/null 2>&1 || true
  fi
  if [ "$VERIFYING" = 1 ] && ours "$VERIFY_VMID" forge-verify; then
    pct destroy "$VERIFY_VMID" --force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---- 1. throwaway build container -------------------------------------------
# PRIVILEGED on purpose: the captured rootfs then has 0-based uids (like a stock
# template), so `pct create --unprivileged` re-maps it correctly. It is
# destroyed at the end regardless.
say "create build CT $BUILD_VMID (privileged, transient)"
BUILT=1
pct create "$BUILD_VMID" "$BASE_TEMPLATE" \
  --hostname claytonia-forge-build \
  --cores 2 --memory 2048 --swap 512 \
  --rootfs "${BUILD_STORAGE}:${DISK_GB}" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --nameserver 192.168.139.1 --searchdomain local \
  --unprivileged 0 --start 1 >/dev/null

say "wait for network egress"
for i in $(seq 1 30); do
  pct exec "$BUILD_VMID" -- getent hosts github.com >/dev/null 2>&1 && break
  [ "$i" = 30 ] && { echo "no DNS/egress after 30s — a fresh CT lands in Firewalla 'learning' (default-block)." >&2
                     echo "Fix: classify its MAC / restart FireMain, then re-run. See forge/runner/README.md." >&2; exit 1; }
  sleep 1
done

# ---- 2. substrate layer (kalmia) --------------------------------------------
say "apply substrate.sh"
pct exec "$BUILD_VMID" -- bash -s < "$SUBSTRATE"

# ---- 3. software layer (claytonia gitops — referenced, not copied) ----------
say "install claytonia software layer @ ${CLAYTONIA_REF}"
pct exec "$BUILD_VMID" -- env \
  CLAYTONIA_URL="$CLAYTONIA_URL" CLAYTONIA_REF="$CLAYTONIA_REF" bash -s <<'SOFTWARE'
set -euo pipefail
REPO_DIR=/opt/claytonia
git clone --quiet "$CLAYTONIA_URL" "$REPO_DIR"
git -C "$REPO_DIR" checkout --quiet "$CLAYTONIA_REF"
# claytonia's own bootstrap: installs + enables claytonia-gitops.timer.
CLAYTONIA_REPO_DIR="$REPO_DIR" bash "$REPO_DIR/gitops/install.sh"
# Force the INITIAL deploy through claytonia's OWN gitops code path. On a real
# worker provision/02–05 lay the runner down and gitops only handles later
# updates; claytonia-gitops deploys on git *drift* and a fresh clone has none, so
# it would no-op. Rewind one commit and let claytonia-gitops fast-forward back to
# origin/main, running its real deploy() — so the image ships the runner in
# place (offline-ready) with zero duplication of the deploy mapping here.
# (Requires REF on main; a detached pinned SHA fails the run-job guard below.)
git -C "$REPO_DIR" reset --hard --quiet HEAD~1
/usr/local/sbin/claytonia-gitops || true
# Enable the pollers (gitops deploys the unit files but does not enable them;
# claytonia provision 02/05 did — the forge takes that role now).
systemctl enable claude-inbox.timer claude-heartbeat.timer >/dev/null 2>&1 || true
# Sanity: the runner binary and the loop must be present + enabled.
test -x /opt/claude-runner/bin/run-job
systemctl is-enabled claytonia-gitops.timer claude-inbox.timer claude-heartbeat.timer
echo SOFTWARE_DONE
SOFTWARE

# ---- 4. de-identify (strip per-instance + build state) ----------------------
say "de-identify"
pct exec "$BUILD_VMID" -- bash -s <<'CLEAN'
set -uo pipefail
# Unique-per-clone identity (regenerated first boot / by systemd).
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
# Build detritus — none of this belongs in a shipped image.
apt-get clean; rm -rf /var/lib/apt/lists/*
rm -rf /tmp/* /var/tmp/* /srv/jobs 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -f /root/.bash_history /home/claude/.bash_history
journalctl --rotate >/dev/null 2>&1 || true; journalctl --vacuum-time=1s >/dev/null 2>&1 || true
echo CLEAN_DONE
CLEAN

# ---- 5. capture -> vztmpl (atomic write-then-rename) ------------------------
say "capture rootfs -> ${OUT}"
pct stop "$BUILD_VMID"
pct mount "$BUILD_VMID" >/dev/null
ROOTFS="/var/lib/lxc/${BUILD_VMID}/rootfs"
[ -d "$ROOTFS/etc" ] || { echo "rootfs not mounted at $ROOTFS" >&2; exit 1; }
# Exclude every device node: `pct create --unprivileged` extracts in a userns
# where mknod is EPERM, so any char/block node (e.g. a package's chroot dev like
# postfix's /var/spool/postfix/dev/*) makes the extract fail with tar exit 2.
# Proxmox rebuilds /dev itself; a runner needs none of these.
EXCL="$(mktemp)"; ( cd "$ROOTFS" && find . -xdev \( -type b -o -type c \) ) > "$EXCL"
# tar exit 1 == benign warnings (e.g. an ignored socket); only >1 is fatal.
set +e
tar --numeric-owner --xattrs --acls --warning=no-file-ignored \
    --anchored --exclude-from="$EXCL" \
    -C "$ROOTFS" -cf - . | zstd -T0 -19 -q -o "${OUT}.partial"
caps=( "${PIPESTATUS[@]}" ); set -e; rm -f "$EXCL"
[ "${caps[0]}" -gt 1 ] && { echo "tar failed (${caps[0]})" >&2; exit 1; }
[ "${caps[1]}" -ne 0 ] && { echo "zstd failed (${caps[1]})" >&2; exit 1; }
pct unmount "$BUILD_VMID"
sha256sum "${OUT}.partial" | sed "s# .*# ${NAME}.tar.zst#" > "${OUT}.sha256"
mv -f "${OUT}.partial" "$OUT"
say "published $(pvesm list "$OUT_STORAGE" --content vztmpl | grep -F "$NAME" || echo "$OUT")"
echo "volid: ${OUT_STORAGE}:vztmpl/${NAME}.tar.zst"

# ---- 6. retention -----------------------------------------------------------
say "retention (keep last ${RETAIN})"
ls -1 "${OUT_CACHE}"/claytonia-runner-v*.tar.zst 2>/dev/null \
  | sort -t v -k2 -n | head -n -"${RETAIN}" | while read -r old; do
    echo "prune $(basename "$old")"; rm -f "$old" "${old%.tar.zst}"*.sha256 "${old}".sha256 2>/dev/null || true
  done

# ---- 7. optional verify -----------------------------------------------------
# Verify runs AFTER publish, so a soft check (host-key regen timing) must not
# fail the build; the verify CT is always torn down.
if [ "$VERIFY" = 1 ]; then
  VID="$VERIFY_VMID"   # required and checked free at the start
  say "verify: instantiate $NAME as unprivileged CT $VID"
  if ! vmid_free "$VID"; then
    echo "verify vmid $VID was taken during the build — skipping verify" >&2
  else
    VERIFYING=1
    pct create "$VID" "${OUT_STORAGE}:vztmpl/${NAME}.tar.zst" \
      --hostname forge-verify --cores 1 --memory 512 \
      --rootfs "${BUILD_STORAGE}:8" --net0 name=eth0,bridge=vmbr0,ip=dhcp \
      --features nesting=1 --unprivileged 1 --start 1 >/dev/null
    sleep 12
    set +e
    pct exec "$VID" -- bash -c '
      rc=0
      id claude >/dev/null 2>&1 && echo "OK   claude user" || { echo "ERR  claude user"; rc=1; }
      su - claude -c "PATH=\$HOME/.local/bin:\$PATH claude --version" >/dev/null 2>&1 \
        && echo "OK   Claude Code" || { echo "ERR  Claude Code"; rc=1; }
      test -x /opt/claude-runner/bin/run-job && echo "OK   runner deployed" || { echo "ERR  runner missing"; rc=1; }
      systemctl is-enabled claytonia-gitops.timer claude-inbox.timer claude-heartbeat.timer >/dev/null 2>&1 \
        && echo "OK   gitops + pollers enabled" || { echo "ERR  timers not enabled"; rc=1; }
      [ "$(node -p "process.versions.node.split(\".\")[0]" 2>/dev/null)" = 22 ] \
        && echo "OK   node 22" || { echo "ERR  node is not 22 ($(node --version 2>&1))"; rc=1; }
      [ -d /opt/claytonia ] && [ ! -e /opt/bullpen ] \
        && echo "OK   /opt/claytonia, no /opt/bullpen" || { echo "ERR  checkout path (want /opt/claytonia, no /opt/bullpen)"; rc=1; }
      grep -q "OAUTH_TOKEN=." /etc/claude-runner/token.env 2>/dev/null \
        && { echo "ERR  token BAKED (must be empty)"; rc=1; } || echo "OK   token placeholder empty"
      ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 \
        && echo "OK   ssh host keys regenerated" || echo "WARN ssh host keys not up yet (first-boot timing)"
      exit $rc'
    vrc=$?
    set -e
    pct stop "$VID" >/dev/null 2>&1 || true
    pct destroy "$VID" --force >/dev/null 2>&1 || true
    [ "$vrc" = 0 ] && say "verify passed" \
      || echo "=== verify reported issues (rc=$vrc) — template IS published; inspect above ===" >&2
  fi
fi

say "done: ${NAME}"
