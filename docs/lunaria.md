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

**lunaria** renders the Family Brief pane to a continuous 4K HEVC HLS stream
that the office Roku's sideloaded dev channel plays (#167). It is the
containerized productization of the 2026-07-20 Roku HLS validation (worked
example: `~/roku-hls-test/NOTES.md` on the ThinkPad); the 720p play-room Roku
it first served was retired on 2026-10-28. Concept and roadmap (the
pane-rubric viewport this grows into): `http://pub.lan/brasenia/concept.md`.

## Architecture

```
pub (LXC 114)                       lunaria (LXC 118, 192.168.139.19)
  family-brief producer               lunaria-frames.service
    compositor → viewport/        →     chromium --headless, 3x scale, of
      current.json (the pointer)          the pointer's pane (its detail.html
                                          desk edition when it has one)
                                        → 3840x2160 page → frame.png
                                      lunaria-stream.service
                                        ffmpeg frame.png → HEVC 5 fps →
                                        HLS (MPEG-TS) in /run/lunaria-hls
                                      lunaria-hls-serve.service
                                        /run/lunaria-hls → :8080
                                              ↓
                              office Roku dev channel "brasenia"
                              http://192.168.139.19:8080/master.m3u8
```

Division of labor: **pub owns the Google Drive leg** (rclone credential lives
only there); **lunaria is credential-free** — its only input is
`http://pub.lan/`. The briefing rotation (the pointer's `briefing` fallback,
or no compositor at all) shows the Family Brief from brasenia's briefing slot
(lentago/brasenia#76): `lunaria_tv_url` is its `detail.html` desk edition,
shot as a TV edition, and `lunaria_full_url` its `pane.html`, sliced if the
TV edition is unreachable. Until 2026-10-28 these were the morning brief at
`/brief/`, which stopped publishing on 2026-08-31.

**Extra panes** (`lunaria_extra_urls`, 2026-08-10): further TV-contract pages
appended to the briefing rotation, a Phase-1.5 precursor of the brasenia pane
bus. Each is shot like a TV edition; an unreachable or failing extra pane is
skipped without touching the brief pages, so a broken pane can never blank the
display. Empty since 2026-10-28: the one entry, the praxis Obsidian graph
(`http://pub.lan/praxis/graph/tv.html`), was dropped. Its export had been
retired on 2026-08-18, and anything that should share the screen now claims a
pane on the bus.

**The 4K office stream** (#167). The office Roku is the viewport's screen:
`lunaria-frames` follows the pointer as described below
(lentago/brasenia#59). When the pointer names a pane that also offers the
`lunaria_prefer_rendition` file beside its `pane.html` (the Family Brief's
`family-today/detail.html`, a 1920×1080 desk edition that zooms to fit the
1280×720 viewport; lentago/brasenia#56), the shooter shoots that instead.
`lunaria_pin_url` can pin the display to one page instead, never reading the
pointer and re-shooting every `lunaria_regen_interval` seconds, with the
same keep-the-old-pages rules. Pages keep the 1280×720 pane
contract; `lunaria_scale: 3` has Chromium render them at 3840×2160 (device
scale factor), and the clock overlay scales with them. The encoder writes
HEVC (Roku plays H.264 only up to 1080p) with ffmpeg's own HLS muxer into
`/run/lunaria-hls` (tmpfs, so ~2 MB of segments every 2 s never touches the
disk), and `lunaria-hls-serve`, a small stdlib server, serves playlists and
finished segments on `lunaria_hls_port`. Not mediamtx: its MPEG-TS HLS is
H.264-only, and its fMP4 HLS declares `#EXT-X-VERSION:10`, which the Roku
rejects (`HLS playlist unsupported version`). `omit_endlist` and
epoch-numbered segments mean an encoder restart never leaves a finished
playlist behind or runs the sequence backwards: the stream 404s for ~10 s
and the app's retry handler rejoins. At 5 fps the encoder is ~1.4 cores and
~620 MB, hence 4 cores / 4 GB; 10 fps did not fit 2 cores. An empty
`lunaria_prefer_rendition` always shoots `pane.html`, and `lunaria_scale: 1` a
1280×720 stream.

**Following the viewport pointer** (#142). The viewport pointer is the file
the brasenia compositor writes on pub, `http://pub.lan/viewport/current.json`,
naming what the wall should show right now; this runtime is the Roku/HLS
adapter, the leg that turns that page into the video stream the Roku plays
(brasenia#26). `lunaria-frames` polls `lunaria_pointer_url` every
`lunaria_pointer_poll` seconds (5) over HTTP. When the pointer names a pane
(`fallback` null) or the status card (`fallback: "status"`), the TV shows that
URL alone, shot as a TV-contract page. When the pointer says
`fallback: "briefing"`, or is absent (404 — no compositor), the TV shows the
brief plus the extra panes as above. The rotation is re-shot when `url` or
`decided_at` changes and every `lunaria_regen_interval` seconds, so a pane
that updates in place is re-rendered. When the pointer is unreadable (pub
down, a non-404 error, bad JSON, a schema other than 1), the existing pages
keep rotating and the journal gets one line after 30 s, plus one when it is
readable again; a failed shoot also keeps the existing pages and is retried
after 30 s. Capture runs in the background (into `pages.next`, swapped in
when complete), so a stalled Chromium never stops the rotation or the
polling.

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

3. **Display**: the office Roku's dev channel plays
   `http://192.168.139.19:8080/master.m3u8` (brasenia's `VideoScene.xml`;
   sideload with brasenia's `scripts/deploy-roku.sh`). The Roku must have
   Settings → Display type on 4K or Auto, or it plays the stream below 4K.

## Operational notes (hard-won 2026-07-20)

- mediamtx ≥1.19 HLS answers with a cookie-check 302 unless the player URL
  pre-bakes `?cookieCheck=1`. That applies to mediamtx paths (`live`) only;
  the display stream on `lunaria-hls-serve` needs no query string.
- The Roku Video node never retries a dead stream on its own; the sideloaded
  app carries a state-observer + 3 s Timer retry (rejoins ~1 s after the
  publisher returns). Publisher restarts on lunaria are therefore invisible
  beyond a brief freeze.
- The shooter uses a throwaway chromium profile per shot — a persistent
  profile's HTTP cache once served a stale tv.html. `--no-sandbox` is
  required in the unprivileged LXC (no user namespaces); input is our own
  pub.lan pages.
- Services are ordinary systemd units with `Restart=always` — no PID files,
  no process groups. `systemctl status lunaria-frames lunaria-stream
  lunaria-hls-serve` is the whole health check; the on-screen clock overlay is the liveness
  indicator (clock advancing + stale dashboard = shooter problem, frozen
  clock = stream problem).
- Everything here is stateless: `/var/lib/lunaria` holds only rendered PNGs.
  Rebuild-from-scratch is terraform apply + the provision play; nothing to
  back up.

## RTMP live-ingest (`live` path — kalmia#102)

> **Since #167** `lunaria-stream` no longer publishes to mediamtx `board`,
> so `live`'s `fallback: /board` has nothing to fall back to, and the office
> Roku plays the HEVC stream from `lunaria-hls-serve`, not mediamtx. The
> notes below describe the path as built; what the live-ingest pane becomes
> for an HEVC client is [brasenia#17](https://github.com/lentago/brasenia/issues/17)'s
> question.

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

## Cast receiver watchdog — retired 2026-10-28

The Chromecast that was the viewport's second client (brasenia ADR-0006) is
gone, and Roku is the client platform
([brasenia ADR-0010](https://github.com/lentago/brasenia/blob/main/docs/adr/0010-roku-is-the-client-platform.md)).
The watchdog this role used to install (`lunaria-cast-watchdog` and its
timer, `/etc/default/lunaria-cast`, `python3-pychromecast`; #99) is now
removed by the role: the last block of `roles/lunaria/tasks/main.yml` makes
sure it is absent. pub's publishing of the receiver page is retired
separately (#174).
