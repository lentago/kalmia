# pub (LXC 114) — Morning Brief publisher

`pub` (114, pve4, `pub.lan` / `192.168.139.9`) serves the claude.ai "Morning
brief" routine's output at `http://pub.lan/brief/`. The container *shell* is
Terraform-managed (`terraform/containers.tf`); the in-guest publisher —
rclone, the `publish-morning-brief` script, and its systemd oneshot/timer —
is codified by the `pub` role and the `pub.yml` playbook. See kalmia#54.

Caddy (the webserver that actually serves `/srv/www`) is half covered: its
**config** — the Caddyfile and the sortable directory-listing template — is
role-managed since #144 (see [Caddy config](#caddy-config-and-the-sortable-index-144)),
while the caddy **package** is still installed by hand from the upstream apt
repo.

## Caddy config and the sortable index (#144)

`roles/pub/files/caddy/Caddyfile` and `roles/pub/files/caddy/browse.html` are
deployed to `/etc/caddy/` (0644, root) when `pub_caddy_manage_config` is true
and `/usr/bin/caddy` exists; otherwise the block logs a warning and skips. The
Caddyfile is checked with `caddy validate --adapter caddyfile` before it is
written, and any change to either file notifies the `Reload caddy` handler
(`systemctl reload caddy`, which the packaged unit runs as `caddy reload
--force`, so a template-only change is picked up too).

The Caddyfile is the one-liner it always was: `:80`, `root * /srv/www`, gzip,
`file_server` with `browse /etc/caddy/browse.html`. The template keeps the
root page's drop-target card and the per-folder "Index of" header, and makes
the listing sortable on Caddy's own browse parameters: the **Name**, **Size**
and **Modified** headers link to `?sort=namedirfirst|size|time&order=asc|desc`,
the active column shows an arrow, clicking it again flips the order (names
start A→Z, sizes and dates start largest/newest first). Caddy sorts
server-side and remembers the choice in `sort`/`order` cookies, so it carries
across folders; no JavaScript is involved. `http://pub.lan/?sort=time&order=desc`
is the "what was just published" view.

One path is not a file: `handle /viewport/pipeline.json` proxies to drosera's
pipeline producer on LXC 105 (`grafana-stack`, 192.168.139.20:8611; #146,
lentago/drosera#266). That guest holds the Loki credentials but mounts no web
share, so the change-pipeline document reaches the viewport bus by proxy
rather than by file, and pub keeps no credential of its own (brasenia
ADR-0005). While the producer is down the path answers 502; the brasenia
producers read that as "no rows". Check: `curl -s http://pub.lan/viewport/pipeline.json | jq .schema`.

The caddy package is not installed by the role. On a rebuild, install it from
the upstream repo first (the Debian/Ubuntu steps at
<https://caddyserver.com/docs/install#debian-ubuntu-raspbian>; the container
has `caddy-stable.list` from that recipe), then run the play. Check:

```bash
caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile
curl -s 'http://pub.lan/?sort=time&order=desc' | grep -m1 'class="active"'
```

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

## brasenia viewport runtime (#140)

pub also runs brasenia's two long-running viewport programs
([brasenia#26](https://github.com/lentago/brasenia/issues/26) Phase 2) from
the same role-managed `/srv/brasenia` checkout. Both are stdlib Python 3.9+
(Debian 12 ships 3.11) and credential-free: their only inputs are the share
and the public GitHub API. They read and write only under
`/srv/www/viewport`, which is why they run here and not on LXC 118 (no NAS
mount, by design).

- `brasenia-compositor.service` ranks the pane bus every 5 s and writes
  `viewport/current.json` (`python3 -m compositor`, WorkingDirectory
  `/srv/brasenia`).
- `brasenia-focus.service` turns session beacons in `viewport/focus/` into
  open-PR panes every 30 s (`python3 -m focus_producer`, WorkingDirectory
  `/srv/brasenia/producers/focus`).

Both are `Type=simple`, `Restart=always`, and run as the unprivileged
`brasenia` system user in the `webdrop` group. The share is a CIFS mount that
forces every file to uid/gid 1000 at mode 0770, so gid-1000 membership is
what grants writes (Caddy sits in the same group for reads); the role ensures
the group and the user. It creates `/srv/www/viewport/{panes,focus,state}`
(only when `/srv/www` is mounted) and leaves their ownership and mode to the
share. Each unit carries `RequiresMountsFor=/srv/www`, so it orders after the
share's mount unit, and `ConditionPathIsMountPoint=/srv/www`, so it skips
rather than writing to the container rootfs when the share is missing. In
this container the share is an LXC bind mount (`mp0`) present before init
starts, so the condition only ever bites on a misconfigured rebuild; the
compositor also creates the three directories itself on start. Toggle:
`pub_viewport_enabled`.

**How new code goes live.** No separate timer. The daily
`publish-cast-receiver` run already does a `git pull --ff-only` of
`/srv/brasenia`. When that pull moves `HEAD`, the script runs
`systemctl try-restart brasenia-compositor brasenia-focus`, so a merge to
brasenia `main` is running on pub within a day. Re-running the play also
restarts both services if the checkout or a unit file changed. This rides on
the Cast publisher: with `pub_cast_publish_enabled: false` there is no daily
pull, so the services only update when the play is re-run.

**Health check:**

```bash
systemctl status brasenia-compositor brasenia-focus && curl -s http://pub.lan/viewport/current.json
```

Both units should be `active (running)`. With an empty bus, `current.json`
points at the briefing (`http://pub.lan/brief/…`). Logs:
`journalctl -u brasenia-compositor -u brasenia-focus`.

## Rebuild flow

1. `terraform apply` (recreates LXC 114 per `terraform/containers.tf`).
2. Run the play (above) against the fresh container.
3. Seed the rclone secret (above).
4. Confirm per the acceptance criteria in kalmia#54: the timer is active and
   a manual run exits 0 and populates `/srv/www/brief/`.
5. Run the viewport health check (above): both brasenia services active and
   `http://pub.lan/viewport/current.json` present.
