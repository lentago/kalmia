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

## Cast receiver publishing (#99)

pub also hosts brasenia's Cast **custom web receiver** page for the household
Chromecast — the second viewport client
([brasenia ADR-0006](https://github.com/lentago/brasenia/blob/main/docs/adr/0006-cast-web-receiver-second-client.md);
watchdog sender in [lunaria.md](lunaria.md#cast-receiver-watchdog-second-client--brasenia-adr-0006-99)).
pub owns receiver **hosting only**; the receiver HTML is authored in brasenia
([brasenia#13](https://github.com/lentago/brasenia/issues/13)) and served here,
never forked.

- `/usr/local/bin/publish-cast-receiver` rsyncs the receiver from a local
  brasenia checkout's `cast-app/` (`pub_cast_receiver_src`) into the web share
  (`pub_cast_receiver_dest`, default `/srv/www/cast`). Like
  `publish-morning-brief` it is credential-free and skips cleanly (exit 0) when
  the web share is not mounted or the source is absent.
- `publish-cast-receiver.service` (oneshot) + its `.timer` republish daily
  (`pub_cast_timer_oncalendar`) — the receiver is static, so this only keeps the
  share fresh and recovers if it is remounted/cleared.
- Config is `/etc/default/publish-cast-receiver` (source + dest), rendered from
  role defaults.

**The registered URL.** `/srv/www` on pub is the NAS web share
(`/volume1/lentago/web`) mounted here, so `pub_cast_receiver_dest=/srv/www/cast`
is `/volume1/lentago/web/cast/` on the NAS and serves at **`http://pub.lan/cast/`**.
That URL — `http://pub.lan/cast/` — is what gets registered as the receiver's
application URL in the Google Cast Developer Console.

> **Checkout is role-managed (since 2026-08-14).** The role clones the public
> brasenia repo (credential-free https) to `pub_cast_checkout`
> (`/srv/brasenia`), and the publisher does an opportunistic `git pull
> --ff-only` before each rsync, so the served receiver tracks brasenia `main`
> within a day of a merge — no re-provisioning needed. If GitHub is
> unreachable the pull is skipped and the existing checkout republishes; set
> `pub_cast_publish_enabled: false` to skip the whole block.

## Rebuild flow

1. `terraform apply` (recreates LXC 114 per `terraform/containers.tf`).
2. Run the play (above) against the fresh container.
3. Seed the rclone secret (above).
4. Confirm per the acceptance criteria in kalmia#54: the timer is active and
   a manual run exits 0 and populates `/srv/www/brief/`.
