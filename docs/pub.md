# pub (LXC 114) — Morning Brief publisher

`pub` (114, pve4, `pub.lan` / `192.168.139.9`) serves the claude.ai "Morning
brief" routine's output at `http://pub.lan/brief/`. The container *shell* is
Terraform-managed (`terraform/containers.tf`); the in-guest publisher —
rclone, the `publish-morning-brief` script, and its systemd oneshot/timer —
is codified by the `pub` role and the `pub.yml` playbook. See kalmia#54.

Caddy (the webserver that actually serves `/srv/www`) is hand-state and
**not** covered here — it's a follow-up candidate, tracked separately.

## Running the play

Self-provisioning, same model as `site.yml`: run it *on* the container.

```bash
# on pub, as root (no sudo/sshd on this container — enter via the PVE host:
#   ssh pve4 'pct enter 114'   or   lxc-attach -n 114):
apt-get install -y ansible git
git clone https://github.com/lentago/kalmia.git
cd kalmia
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/hosts.yml pub.yml
```

This installs rclone, deploys `/usr/local/bin/publish-morning-brief` (0755),
the `publish-morning-brief.service`/`.timer` units, enables+starts the timer,
and creates `/root/.config/rclone` (0700). It never writes
`/root/.config/rclone/rclone.conf` — that's credential material and must not
land in git (see below). If the file is missing the play logs a warning but
does not fail; the timer will simply error out on each run until the secret
is seeded.

## Seeding the rclone secret (manual — no ansible-vault precedent in kalmia)

`/root/.config/rclone/rclone.conf` holds the `[Google Drive]` OAuth remote.
The same refresh token also lives in `~/.config/rclone/rclone.conf` on the
ThinkPad — **rotate both together** if either is ever revoked.

1. Copy the known-good config from the ThinkPad (or wherever the current
   remote lives) to the container. pub runs no sshd, so stream it through the
   PVE host instead of scp — from the ThinkPad:
   ```bash
   ssh pve4 'lxc-attach -n 114 -- bash -c "umask 077; mkdir -p /root/.config/rclone; cat > /root/.config/rclone/rclone.conf"' \
     < ~/.config/rclone/rclone.conf
   ```
   (or `pct push 114 <file> /root/.config/rclone/rclone.conf` from pve4; run
   the play first if you want the directory pre-created with the right mode.)
2. Fix ownership/permissions if `scp` didn't preserve them:
   ```bash
   chmod 0600 /root/.config/rclone/rclone.conf
   ```
   (re-running the play also enforces 0600 on whatever's there, without ever
   touching the file's contents.)
3. Verify:
   ```bash
   sudo /usr/local/bin/publish-morning-brief   # should exit 0
   systemctl status publish-morning-brief.timer  # active
   ls /srv/www/brief/                            # populated, index.html present
   ```

If there's no existing config to copy, generate one with `rclone config` /
`rclone authorize` for a `Google Drive` remote scoped to the
`Hobbies/Claude-Code/morning-brief` folder, then follow steps 2-3.

## Rebuild flow

1. `terraform apply` (recreates LXC 114 per `terraform/containers.tf`).
2. Run the play (above) against the fresh container.
3. Seed the rclone secret (above).
4. Confirm per the acceptance criteria in kalmia#54: the timer is active and
   a manual run exits 0 and populates `/srv/www/brief/`.
