# lunaria — wall-display compositor (LXC 118, pve4)

> **Naming note:** the product this runtime serves was renamed
> `lentago/lunaria` → [`lentago/brasenia`](https://github.com/lentago/brasenia)
> on 2026-07-20, hours after creation (*Lunaria annua* is a European garden
> escape; the Lentago codename roster is New England natives only —
> *Brasenia* is watershield). The runtime still carries the legacy `lunaria`
> names (role, scripts, systemd units, service user, `/etc/default/lunaria`,
> LXC 118 hostname); **completing the rename through runtime is tracked in
> #63** per the fleet rename discipline (`shared-workflows/CLAUDE.md` →
> "Rename discipline" — legacy names are tracked debt, never permanent).
> Concept snapshot: `http://pub.lan/brasenia/concept.md`.

**lunaria** renders the Morning Brief's TV edition to a continuous H.264 HLS
stream that the play-room Roku TV's sideloaded dev channel plays. It is the
containerized productization of the 2026-07-20 Roku HLS validation (worked
example: `~/roku-hls-test/NOTES.md` on the ThinkPad). Concept and roadmap
(the pane-rubric viewport this grows into): `http://pub.lan/brasenia/concept.md`.

## Architecture

```
pub (LXC 114)                     lunaria (LXC 118, 192.168.139.19)
  publish-morning-brief             lunaria-frames.service
  Drive → /srv/www/brief/             chromium --headless shot of
    index.html  (browser)             http://pub.lan/brief/tv.html
    tv.html     (wall display)  →     + each LUNARIA_EXTRA_URLS pane
  praxis publish → /srv/www/          (praxis Obsidian graph, …)
    praxis/graph/tv.html      →     → 720px pages → frame.png rotation
                                    lunaria-stream.service
                                      ffmpeg frame.png → RTSP :8554
                                    mediamtx.service
                                      RTSP → HLS :8888 (mpegts variant)
                                            ↓
                              Roku dev channel "HLS Pipeline Test"
                              http://192.168.139.19:8888/board/index.m3u8?cookieCheck=1
```

Division of labor: **pub owns the Google Drive leg** (rclone credential lives
only there); **lunaria is credential-free** — its only input is
`http://pub.lan/`. The TV edition contract (1–4 exact 1280×720 screens) is
defined in the claude.ai Morning-brief routine's prompt; when no TV edition
exists, lunaria falls back to slicing the full brief.

**Extra panes** (`lunaria_extra_urls`, 2026-08-10): further TV-contract pages
appended to the rotation after the brief — a Phase-1.5 precursor of the
brasenia pane bus. Each is shot like a TV edition; an unreachable or failing
extra pane is skipped without touching the brief pages, so a broken pane can
never blank the display. First pane: the praxis Obsidian-graph
(`http://pub.lan/praxis/graph/tv.html`, regenerated on every praxis wiki
publish).

## Build / rebuild

1. **Guest**: created by `terraform/containers.tf` (CI apply-on-merge). No
   bind mounts, no keyctl — the API-token apply can create it from scratch.
2. **Provision** (on the container, same self-provisioning flow as pub):

   ```bash
   pct exec 118 -- bash -lc '
     apt-get update && apt-get install -y git ansible
     git clone https://github.com/lentago/kalmia /opt/kalmia
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml lunaria.yml'
   ```

3. **Display**: the Roku dev channel needs its stream URL pointed at
   `192.168.139.19` (VideoScene.xml in the app zip, then re-sideload). The
   TCL 32S327 is a 720p panel — do not bother streaming above 1280×720.

## Operational notes (hard-won 2026-07-20)

- mediamtx ≥1.19 HLS answers with a cookie-check 302 unless the player URL
  pre-bakes `?cookieCheck=1`. The Roku app URL must include it.
- The Roku Video node never retries a dead stream on its own; the sideloaded
  app carries a state-observer + 3 s Timer retry (rejoins ~1 s after the
  publisher returns). Publisher restarts on lunaria are therefore invisible
  beyond a brief freeze.
- The shooter uses a throwaway chromium profile per shot — a persistent
  profile's HTTP cache once served a stale tv.html. `--no-sandbox` is
  required in the unprivileged LXC (no user namespaces); input is our own
  pub.lan pages.
- Services are ordinary systemd units with `Restart=always` — no PID files,
  no process groups. `systemctl status mediamtx lunaria-frames lunaria-stream`
  is the whole health check; the on-screen clock overlay is the liveness
  indicator (clock advancing + stale dashboard = shooter problem, frozen
  clock = stream problem).
- Everything here is stateless: `/var/lib/lunaria` holds only rendered PNGs.
  Rebuild-from-scratch is terraform apply + the provision play; nothing to
  back up.

## RTMP live-ingest (`live` path — kalmia#102)

mediamtx also accepts LAN RTMP publishers on a generic `live` path,
remuxed through the same Roku-validated HLS leg (`hlsVariant: mpegts`) the
`board` path already uses. Runtime half of a two-repo change; the product
concept, ADR, and `VideoScene.xml` repoint are
[brasenia#17](https://github.com/lentago/brasenia/issues/17). First client:
DJI Fly's custom-RTMP live streaming (H.264/AAC, remux only — no transcode,
no recording; the drone's SD card holds the higher-quality original).

- **Generic by design.** The path is named for the protocol (`live`), not
  the producer — adding a second producer (OBS, Larix, ...) requires no
  `mediamtx.yml` changes, just the same publish URL with a different
  encoder.
- **LAN-only, credentialed.** RTMP was off (`rtmp: false`) before this;
  turning it on makes port `:1935` reachable to the whole
  `192.168.139.0/24` LAN (no Firewalla port-forward — never exposed beyond
  it). A publisher needs the `live`-path credential to push video; this
  does not weaken the LXC 118 credential-free design (brasenia ADR-0005) —
  that rule keeps a compromised display leg from reaching *other* systems,
  and a publish token only grants putting video on this one TV.
- **Fallback.** The Roku points at `live` with mediamtx's (deprecated but
  still functional in v1.19.2) `fallback: /board` — readers land on `board`
  while no one is publishing to `live`, and rejoin `live` within the
  existing 3s retry handler (brasenia ADR-0002) once a publisher appears.
  If brasenia-side bench validation finds Roku's HLS client mishandles the
  fallback redirect (see the `?cookieCheck=1` history above), the fallback
  line is the only thing to revert — plan B is a manual v0 repoint via
  `lunaria_tv_url` instead.
- **`board` is unaffected.** `lunaria-stream`'s localhost RTSP push to
  `board` keeps working unauthenticated, exactly as before; only the new
  `live` path requires a credential.

### Seeding the RTMP publish credential (manual — no ansible-vault precedent)

`roles/lunaria/files/mediamtx.yml` became
`roles/lunaria/templates/mediamtx.yml.j2`: the `live`-path publish password
is sourced from the `LUNARIA_RTMP_PUBLISH_PASS` environment variable at
play time (same `lookup('env', ...)` pattern as `GH_TOKEN` in the `repos`
role) and is never committed. If the variable is unset, the rendered
config simply grants no one publish access to `live` — RTMP live-ingest
stays off (fails closed) rather than falling open.

1. Generate a random credential and stash it in a host-local env file,
   following the existing `~/.config/kalmia/proxmox.env` precedent:
   ```bash
   mkdir -p ~/.config/kalmia
   umask 077
   printf 'export LUNARIA_RTMP_PUBLISH_PASS=%s\n' "$(openssl rand -hex 20)" \
     >> ~/.config/kalmia/lunaria-rtmp.env
   ```
2. Before running the play, source it:
   ```bash
   source ~/.config/kalmia/lunaria-rtmp.env
   ansible-playbook -i inventory/hosts.yml lunaria.yml
   ```
3. Give DJI Fly's custom-RTMP field the publish URL (`lunaria_rtmp_publish_user`
   defaults to `live` and is committed — not a secret):
   ```
   rtmp://192.168.139.19:1935/live?user=live&pass=<the credential>
   ```
   Re-running the play without sourcing the env file first is safe — it
   redeploys the config with no live-publisher credential and RTMP
   live-ingest goes back to fails-closed until re-seeded.

## Cast receiver watchdog (second client — brasenia ADR-0006, #99)

The household Chromecast joined as a **second viewport client** alongside the
Roku/HLS path ([brasenia
ADR-0006](https://github.com/lentago/brasenia/blob/main/docs/adr/0006-cast-web-receiver-second-client.md),
[brasenia#12](https://github.com/lentago/brasenia/issues/12)). A Cast **custom
web receiver** is a managed Chrome instance on the TV that fetches and renders
the receiver page itself (served from pub — see [pub.md](pub.md#cast-receiver-publishing-99));
the sender only has to *launch* it. The acceptance test is strict: **adding the
Cast client must not touch the Roku client** — the watchdog below is purely
additive and shares nothing with the mediamtx/shooter/rotator/encoder stack.

The receiver session runs independently once launched, but a power blip, a
Chromecast OS update, an ambient-mode reclaim, or an input change drops it. The
watchdog is the Cast path's analogue of the mandatory Roku retry handler
([brasenia ADR-0002](https://github.com/lentago/brasenia/blob/main/docs/adr/0002-mandatory-client-side-retry-handler.md)):

- `/usr/local/bin/lunaria-cast-watchdog` (pychromecast) discovers the
  Chromecast by friendly name, compares its running `app_id` against the
  registered receiver's App ID, and calls `start_app()` when it differs.
- `lunaria-cast-watchdog.service` (oneshot, run as `lunaria`) + its `.timer`
  re-check on a short cadence (`lunaria_cast_watchdog_interval`, default 60s;
  `OnBootSec=30s`) so recovery is unattended.
- Config is `/etc/default/lunaria-cast` (App ID + device name), rendered from
  role defaults.

### Registered 2026-08-14 — values committed

The custom web receiver is registered in the Cast Developer Console as an
**unpublished** Custom Receiver: App ID `83A58DDE`, receiver URL
`http://pub.lan/cast/` (the console accepted plain HTTP for an unpublished
app — no TLS leg needed, and no mixed content since the brief iframe is
same-scheme). The household Chromecast ("Family Room TV", Cast-platform
device) is serial-registered for development; the app never gets published,
so it launches only on that device — the same posture as the sideloaded
Roku dev channel.

`lunaria_cast_app_id` and `lunaria_cast_device_name` are **committed in the
role defaults** rather than passed via `-e`: neither is a secret (the App ID
is public in brasenia's `cast-app/app-config.json`; the friendly name is
broadcast in cleartext mDNS on the LAN), and an `-e`-only value would
silently revert `/etc/default/lunaria-cast` to a dormant placeholder on any
future provisioning run — exactly the failure mode a watchdog must not have.
The placeholder-skip logic in the watchdog script remains as a safety valve
for rebuilds from a stale checkout. Set `lunaria_cast_watchdog_enabled: false`
to skip the watchdog block entirely.

> **Runtime dependencies** (not visible to static CI): the container needs
> `python3-pychromecast` from apt and mDNS/multicast reachability to the
> Chromecast, plus internet at launch (Google's app-ID lookup). Verified only
> once the first live watchdog run launches the receiver on LXC 118.
