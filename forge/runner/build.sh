#!/usr/bin/env bash
# build.sh — forge a versioned claytonia (bullpen) runner LXC template and
# publish it to a Proxmox vztmpl storage. Run as root ON A PVE NODE.
#
#   ./build.sh v1                       # build claytonia-runner-v1 from claytonia@main
#   CLAYTONIA_REF=abc123 ./build.sh v2  # pin the software layer to a commit
#   ./build.sh v1 --verify              # also instantiate + smoke-test the result
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
BUILD_VMID="${BUILD_VMID:-119}"
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
[ -f "$SUBSTRATE" ] || { echo "missing substrate: $SUBSTRATE" >&2; exit 1; }
[ -d "$OUT_CACHE" ] || { echo "vztmpl cache not found: $OUT_CACHE (is $OUT_STORAGE mounted?)" >&2; exit 1; }
[ -e "$OUT" ] && { echo "refusing to overwrite existing $OUT (bump the version)" >&2; exit 1; }
pct status "$BUILD_VMID" >/dev/null 2>&1 && { echo "build vmid $BUILD_VMID is in use" >&2; exit 1; }

cleanup(){ # destroy the throwaway on any exit path
  pct unmount "$BUILD_VMID" >/dev/null 2>&1 || true
  pct status  "$BUILD_VMID" >/dev/null 2>&1 && pct destroy "$BUILD_VMID" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- 1. throwaway build container -------------------------------------------
# PRIVILEGED on purpose: the captured rootfs then has 0-based uids (like a stock
# template), so `pct create --unprivileged` re-maps it correctly. It is
# destroyed at the end regardless.
say "create build CT $BUILD_VMID (privileged, transient)"
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
REPO_DIR=/opt/bullpen
git clone --quiet "$CLAYTONIA_URL" "$REPO_DIR"
git -C "$REPO_DIR" checkout --quiet "$CLAYTONIA_REF"
# claytonia's own bootstrap: installs + enables bullpen-gitops.timer.
BULLPEN_REPO_DIR="$REPO_DIR" bash "$REPO_DIR/gitops/install.sh"
# Force the INITIAL deploy through claytonia's OWN gitops code path. On a real
# worker provision/02–05 lay the runner down and gitops only handles later
# updates; bullpen-gitops deploys on git *drift* and a fresh clone has none, so
# it would no-op. Rewind one commit and let bullpen-gitops fast-forward back to
# origin/main, running its real deploy() — so the image ships the runner in
# place (offline-ready) with zero duplication of the deploy mapping here.
# (Requires REF on main; a detached pinned SHA fails the run-job guard below.)
git -C "$REPO_DIR" reset --hard --quiet HEAD~1
/usr/local/sbin/bullpen-gitops || true
# Enable the pollers (gitops deploys the unit files but does not enable them;
# claytonia provision 02/05 did — the forge takes that role now).
systemctl enable claude-inbox.timer claude-heartbeat.timer >/dev/null 2>&1 || true
# Sanity: the runner binary and the loop must be present + enabled.
test -x /opt/claude-runner/bin/run-job
systemctl is-enabled bullpen-gitops.timer claude-inbox.timer claude-heartbeat.timer
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
  VID="${VERIFY_VMID:-118}"
  say "verify: instantiate $NAME as unprivileged CT $VID"
  if pct status "$VID" >/dev/null 2>&1; then
    echo "verify vmid $VID in use — skipping verify" >&2
  else
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
      systemctl is-enabled bullpen-gitops.timer claude-inbox.timer claude-heartbeat.timer >/dev/null 2>&1 \
        && echo "OK   gitops + pollers enabled" || { echo "ERR  timers not enabled"; rc=1; }
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
