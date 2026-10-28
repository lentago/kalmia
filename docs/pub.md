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

One path is not a file: `handle /viewport/pipeline.json` forwards requests to
drosera's pipeline producer on LXC 105 (`grafana-stack`, 192.168.139.20:8611;
#146, lentago/drosera#266). That guest holds the Loki credentials but mounts no
web share, so the change-pipeline document reaches the viewport bus (the
`web/viewport/` folder on the share, where brasenia's producers read and write
the wall display's panes) through pub rather than as a file on the share, and
pub keeps no credential of its own (brasenia ADR-0005). While the producer is down the path answers 502; the brasenia
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

## brasenia checkout and daily update (#174)

The role clones the public brasenia repo (credential-free https) to
`pub_brasenia_checkout` (`/srv/brasenia`); the brasenia viewport services
(below) run from it.

- `/usr/local/bin/brasenia-update` does a `git pull --ff-only` of the
  checkout and, when that moves `HEAD`, runs `systemctl try-restart` of the
  four brasenia services. It is credential-free and best-effort: if GitHub is
  unreachable it logs and stays on the current commit.
- `brasenia-update.service` (oneshot) and its `.timer` run it daily
  (`pub_brasenia_update_oncalendar`, 06:00 Eastern), so a merge to brasenia
  `main` is running on pub within a day. To deploy at once:
  `systemctl start brasenia-update`.

**Retired: Cast receiver publishing (#99).** pub used to publish brasenia's
Cast custom web receiver to `http://pub.lan/cast/` with `publish-cast-receiver`,
which also carried the daily pull above. The Cast client was retired on
2026-10-28 ([brasenia
ADR-0010](https://github.com/lentago/brasenia/blob/main/docs/adr/0010-roku-is-the-client-platform.md)).
The role now removes the publisher's units, script and env file and the
published `/srv/www/cast`.

## Family Brief document (#163)

pub also publishes the claude.ai "Family Brief" routine's document for the wall
display. Once the routine gains its STEP 5b (not added yet), it writes the
JSON it stores on its dashboard page, byte for byte, as a single `latest.json`
in a Drive folder, replacing the old copy. Until then the folder doesn't exist
and the publisher skips. pub syncs that file to `/srv/www/family-brief/`, so it serves at
**`http://pub.lan/family-brief/latest.json`**, and brasenia's family-brief
producer turns it into the `family-today` pane (see the viewport runtime
below; the producer lands with
[brasenia#48](https://github.com/lentago/brasenia/pull/48)). No Caddy change is involved; the existing `file_server` on `/srv/www`
serves the path.

- `/usr/local/bin/publish-family-brief` runs `rclone copy` of `latest.json`
  from `pub_family_brief_src` into a local staging directory, checks it the
  way the producer does (a JSON object with `schema` 1 and a `YYYY-MM-DD`
  `date`), then copies it to `latest.json.tmp` on the share and `mv`s
  it into place, the same swap `publish-morning-brief` uses for `index.html`.
  The producer never sees a half-written file, and a malformed upload leaves
  the previous document serving. Like the other publishers it skips cleanly
  (exit 0) when the share is not mounted, the Drive folder doesn't exist, or
  the folder has no `latest.json` yet.
- `publish-family-brief.service` (oneshot) + its `.timer` run every 15
  minutes from 06:00 to 09:45 `America/New_York`, every day
  (`pub_family_brief_timer_oncalendar`). The routine runs at about 06:47,
  weekends included, which the weekday Morning Brief timer would miss.
- Config is `/etc/default/publish-family-brief` (source + dest), rendered from
  role defaults. It uses the same root `[Google Drive]` rclone remote as the
  Morning Brief, so there is no second secret to seed.
- **The folder name is a pair.** `pub_family_brief_src` is
  `Google Drive:Hobbies/Claude-Code/family-brief`, next to the Morning Brief's
  folder (confirmed 2026-10-26). STEP 5b must write to the same folder; change
  both together.
  Toggle: `pub_family_brief_enabled`.

Check, after the morning run:

```bash
curl -s http://pub.lan/family-brief/latest.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["date"])'
journalctl -u publish-family-brief --since today
```

## brasenia viewport runtime (#140)

pub also runs brasenia's long-running viewport programs
([brasenia#26](https://github.com/lentago/brasenia/issues/26) Phase 2) from
the same role-managed `/srv/brasenia` checkout. All are stdlib Python 3.9+
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
- `brasenia-pipeline.service` (#148, brasenia#36) reads
  `http://pub.lan/viewport/pipeline.json` every 15 s and keeps
  `viewport/panes/change-pipeline/` up while a change is in flight
  (`python3 -m pipeline_producer`, WorkingDirectory
  `/srv/brasenia/producers/pipeline`). While the document is a 502 (drosera's
  producer not yet deployed on LXC 105) it logs "unreadable" and writes
  nothing.
- `brasenia-family-brief.service` (#163, brasenia#48) reads
  `http://pub.lan/family-brief/latest.json` every 60 s
  (`pub_viewport_family_brief_interval`) and keeps
  `viewport/panes/family-today/` up as an `ambient` pane while the brief is
  dated today or yesterday (`python3 -m family_brief_producer`,
  WorkingDirectory `/srv/brasenia/producers/family-brief`). An older brief
  removes the pane; an unreachable document leaves it to its 30-minute TTL.
  The unit needs brasenia#48 on `main`: until then the module is missing and
  the unit restarts every 10 s, then comes up on its own once the daily pull
  brings the producer in.

All are `Type=simple`, `Restart=always`, and run as the unprivileged
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

**How new code goes live.** `brasenia-update` (above) pulls `/srv/brasenia`
daily and restarts the four brasenia services when the pull moves `HEAD`, so
a merge to brasenia `main` is running on pub within a day;
`systemctl start brasenia-update` deploys at once. Re-running the play also
restarts the services if the checkout or a unit file changed.

**Health check:**

```bash
systemctl status brasenia-compositor brasenia-focus brasenia-pipeline brasenia-family-brief && curl -s http://pub.lan/viewport/current.json
```

All four units should be `active (running)`. With an empty bus, `current.json`
points at the briefing (`http://pub.lan/brief/…`). Logs:
`journalctl -u brasenia-compositor -u brasenia-focus -u brasenia-pipeline -u brasenia-family-brief`.
A live family-brief producer logs `family-today: brief of <date> rendered for
<date>`, and `/srv/www/viewport/panes/family-today/manifest.json` reads
`"class": "ambient"`.

## Signal sink (#165)

Everything else pub serves is static. `pub-signals` is the one write path: a
page served here can record a checkbox ticked or cleared, and whatever acts on
it reads the log back later. It is stdlib Python and credential-free, like the
viewport programs, and runs as the `pub-signals` system user in the share's
gid-1000 `webdrop` group, the same write path they use.

- **Route.** Caddy proxies `/api/signals*` to `127.0.0.1:8620`
  (`pub_signals_port`; the Caddyfile hard-codes the port, so change both
  together). The service binds localhost only, so the route is the only way in.
- **Write.** `POST /api/signals/<namespace>` with a JSON object `{"id",
  "action", "label"}` appends one line to
  `/srv/www/signals/<namespace>.jsonl` (`ts` in UTC, `id`, `action`, `label`
  when given, and `client` from `X-Forwarded-For`). `label` is optional
  context for whoever reads the log.
- **Read.** `GET /api/signals/<namespace>` returns `{"namespace", "state"}`,
  the latest action per id, which is what a page needs to show which boxes are
  already ticked. `GET /api/signals` lists the allowed namespaces and actions.
  The raw log is also served statically at `http://pub.lan/signals/`, and the
  workstation reads it at `/mnt/lentago/web/signals/`.
- **Clients.** `pe-wiki`, a private wiki's checklist (`dismiss` / `undo`),
  and `rubric`, brasenia's viewport configurator at
  `http://pub.lan/viewport/configure.html`. That page records `set` with the
  new value in `label`, or `undo` to return a setting to its default. The
  brasenia compositor reads `signals/rubric.jsonl` and applies the latest
  action per setting (lentago/brasenia ADR-0011).
- **Limits.** Namespaces (`pub_signals_namespaces`, first client `pe-wiki`)
  and actions (`pub_signals_actions`: `dismiss`, `undo`, `set`) are allowlists; any
  other value answers 404 or 400. Bodies over 4 KiB answer 413, ids are capped
  at 300 characters and labels at 500. A LAN client can append bounded lines to
  known files and nothing else.
- **No acknowledgements.** The sink never rewrites a log. The consumer works
  out what is still pending by comparing the log with its own state (an id
  whose latest action is `dismiss` and that it still shows), so applying a
  signal twice is harmless and nothing has to be marked done here.

The unit carries the same `RequiresMountsFor` / `ConditionPathIsMountPoint`
pair as the viewport units, so it skips rather than writing to the container
rootfs when the share is missing. Toggle: `pub_signals_enabled`. Adding a
client is a namespace in the defaults and a re-run of the play.

**Health check:**

```bash
systemctl status pub-signals && curl -s http://pub.lan/api/signals
curl -s -X POST http://pub.lan/api/signals/pe-wiki -d '{"id":"healthcheck","action":"undo"}'
```

The first call lists the namespaces and actions; the POST answers
`{"ok": true, ...}` and appends a line (an `undo` for an id nothing shows is a
no-op for any consumer). Logs: `journalctl -u pub-signals`.

## Rebuild flow

1. `terraform apply` (recreates LXC 114 per `terraform/containers.tf`).
2. Run the play (above) against the fresh container.
3. Seed the rclone secret (above).
4. Confirm per the acceptance criteria in kalmia#54: the timer is active and
   a manual run exits 0 and populates `/srv/www/brief/`.
5. Run the viewport health check (above): both brasenia services active and
   `http://pub.lan/viewport/current.json` present.
