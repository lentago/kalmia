# brasenia — the wall display's runtime (LXC 118, pve4)

> **Naming note:** this runtime was named `lunaria`, the product's first
> name. The product became [`lentago/brasenia`](https://github.com/lentago/brasenia)
> on 2026-07-20, hours after creation: *Lunaria annua* is a European garden
> escape, and the Lentago codename roster is New England natives only;
> *Brasenia* is watershield. The runtime rename was completed by #63
> (2026-10-29). LXC 118 was rebuilt as `brasenia`, and the role, playbook,
> units, service user, `/etc/default/brasenia` and paths all carry the new
> name. Concept snapshot: `http://pub.lan/brasenia/concept.md`.

**The runtime** renders the viewport's panes to a continuous 4K stream, HEVC
(H.265) video served as HLS (HTTP Live Streaming: a playlist of short video
segments over plain HTTP), that the office Roku's sideloaded dev channel plays
(#167). It is the
containerized productization of the 2026-07-20 Roku HLS validation (worked
example: `~/roku-hls-test/NOTES.md` on the ThinkPad); the 720p play-room Roku
it first served was retired on 2026-10-28. Concept and roadmap (the
pane-rubric viewport this grows into): `http://pub.lan/brasenia/concept.md`.

## Architecture

```
pub (LXC 114)                       brasenia (LXC 118, 192.168.139.19)
  brasenia compositor →               brasenia-render.service
    viewport/current.json (pointer)     one warm Chromium (sandboxed), every
    viewport/lineup.json  (line-up)     line-up item rendered ahead at 3x
                                        → the pointer's pages → frame.png
                                        → each item's first page, 1080p →
                                          /run/brasenia-peek (the remote's peek)
                                      brasenia-stream.service
                                        ffmpeg frame.png → HEVC 5 fps →
                                        HLS (MPEG-TS) in /run/brasenia-hls
                                      brasenia-hls-serve.service
                                        /run/brasenia-hls → :8080, /peek/
                                              ↓
                              office Roku dev channel "brasenia"
                              http://192.168.139.19:8080/master.m3u8
```

Division of labor: **pub owns the Google Drive leg** (the rclone credential
lives only there). **LXC 118 is credential-free**: its inputs are
`http://pub.lan/` and, for link panes, the sites in `brasenia_allowed_sites`.

**The renderer** (`brasenia-render`, kalmia#194, 2026-10-29) replaced
`lunaria-frames`' shooting, `lunaria-shooter` and `lunaria-peek`.
- **How it renders:** it keeps one headless Chromium running, driven over the
  DevTools protocol on a pipe (`--remote-debugging-pipe`, stdlib Python). A
  pane renders in about 1–2 s, against about 3 s for the old cold launch per
  shot.
- **What it keeps ready:** a 4K image of every item in the compositor's
  line-up (`brasenia_lineup_url`), so a switch is a file swap.
- **Order:** the item on screen first, then the household's default resting
  pane, then the rest, one at a time and 2 s apart, at `Nice=5` so the encoder
  keeps its CPU.
- **Off the main loop:** rendering runs on a worker thread. A slow or stuck
  render (calls time out after 15–30 s) never holds up reading the pointer,
  switching to an item that is already rendered, or turning pages.
- **When an item renders again:**
  - when it is new, or when its content revision (`rev`, lentago/brasenia
    ADR-0016) changes
  - a link pane also every `source.refresh_s`
  - an item without a `rev` (the status card, or an older compositor) every
    `brasenia_regen_interval` seconds while on screen and `brasenia_peek_regen`
    otherwise
- **Failures:** a failed render keeps the previous image and is retried after
  30 s. A render that times out, or a crashed Chromium, gets a fresh browser
  for the next render, and the browser is restarted every 6 h anyway.
- **Bad input:** the pointer and line-up are validated. Link pane settings are
  clamped to the contract's ranges (1–4 screens, a refresh of 10 s to a day),
  so a malformed line-up can't stop the loop or make it spin. Items that
  leave the line-up are forgotten, and their images deleted.

**What is on screen** (#142, lentago/brasenia#59).
- **The pointer:** the renderer polls `brasenia_pointer_url` (the compositor's
  `viewport/current.json` on pub) every `brasenia_pointer_poll` seconds (1).
- **A pane:** when the pointer names a pane (`fallback` null), the screen shows
  that pane's pages. A pub.lan pane that also offers `brasenia_prefer_rendition`
  beside its `pane.html` (the Family Brief's `detail.html` desk edition,
  lentago/brasenia#56) is shown as that rendition.
- **The fallbacks:** on `fallback: "status"` it shows the status card. On
  `fallback: "briefing"`, or a 404 (no compositor), it shows the briefing slot
  (`brasenia_briefing_url`, the Family Brief, lentago/brasenia#76).
- **Bands:** each band (one 16:9 screenful of a pane) stays up
  `brasenia_band_dwell` seconds before the next. When the pointer is unreadable,
  the current bands keep going, and the journal
  gets one line after 30 s and one when it is readable again.
- **A pin:** `brasenia_pin_url` pins the screen to one page instead.

**Bands.** Pane-contract pages are laid out at 1280×720 CSS pixels and
rendered at `brasenia_scale` (3: 3840×2160), one band per 720 px with content,
up to 4. A page that declares `<meta name="brasenia-canvas" content="1920x1080">`
(lentago/brasenia ADR-0019) is laid out at 1920×1080 per band instead, at 2×,
so its bands are the same 3840×2160. Producers move to that canvas one at a
time; a page without the tag renders as before. Link panes (lentago/brasenia
ADR-0016) are laid out at their `source.viewport`, with `prefers-color-scheme`
set to `source.theme`. Their first `source.screens` bands are each fitted onto
a full-size band.

**Which sites.** The gate stops anyone on the LAN who can add a link pane
from pointing the wall at an arbitrary URL. Sites in `brasenia_allowed_sites`
are trusted by definition (the household lists them), so the gate does not
defend against a malicious allowed site.

What is enforced, each request checked by DevTools `Fetch`, and every hop of a
redirect too:
- **Panes without a link source** (our pane-contract pages) render only from
  pub.lan. Their documents, frames included, are checked against the rule
  below.
- **Documents** must be pub.lan, or, while Chromium is sandboxed, a host in
  `brasenia_allowed_sites` or a subdomain of one (`github.com` also allows
  `gist.github.com`).
  - In a link render, no document may be on a private address except pub.lan,
    so an allowed name that resolves to the LAN is refused. Private here means
    RFC1918, CGNAT and Tailscale (100.64/10), loopback, link-local, IPv6 ULA
    and site-local, and `.lan`/`.local` names.
  - The final URL is checked again before the capture.
  - Example: `github.com/<org>.png`, which redirects to
    `avatars.githubusercontent.com`, is refused.
- **Subresources of a link render** (scripts, images, requests) may reach
  public hosts, such as GitHub's CDNs, and never a private one. Names are
  resolved, and answers are trusted for one render only.
- **Each link render gets its own disposable browser context**, with popups
  disabled (`window.open`). Every child frame or worker is attached before it
  runs and stays paused unless the same interception is on it.
- **Tested on 118:** a link render of a page with a cross-site iframe, a LAN
  iframe, a LAN image and a script fetching a LAN service. All four were
  blocked, and the page saw its request fail.

Limits, each with why it is acceptable here:
- **WebSocket connections** are not seen by `Fetch`. Only an allowed, trusted
  site's page could open one, and its context is gone within seconds.
- **`rel=preconnect`** opens TCP connections without sending a request. It is
  the same trusted-site case, and no data is exchanged. DNS prefetching and
  WebRTC's UDP are switched off (`--dns-prefetch-disable`,
  `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`).
- **Service and shared workers** may not be attached (unverified). They live
  in the render's context, which is disposed after the render.
- **Popups** are stopped only by replacing `window.open`. `target=_blank`
  needs a click, and nothing clicks.
- **DNS rebinding**, a name that answers publicly to this check and privately
  to Chromium, has a window of one render. Names are resolved again for every
  link render.
- **Odd URLs** may parse differently in Python than in Chromium. The `Fetch`
  check, which sees the URL Chromium actually requests, is the gate; the
  Python pre-check is a fast path only.

- **Refusals:** a refused link pane is shown once as a notice page naming the
  site, rather than leaving an older pane up. It is tried again when it
  changes, or when the sandbox comes back after a refusal made without it.

The sandbox and the gate are described under Operational notes.

**The remote's peek** (lentago/brasenia#80). On the office Roku, Up/Down steps
through the panes and shows the next one at once as an image over the live
video. It only looks: the stream keeps showing what the compositor decided.
The renderer writes each item's first page at 1920×1080 (the Roku UI plane's
limit) to `/run/brasenia-peek/<id>.png`, plus `index.json`: the items in line-up
order, each with its image's path and time. `brasenia-hls-serve` serves that
directory at `/peek/`. These are the same renders as the stream's.

**The 4K stream** (#167). The encoder writes HEVC (Roku plays H.264 only up to
1080p) with ffmpeg's own HLS muxer into `/run/brasenia-hls`. That is tmpfs, so
about 2 MB of segments every 2 s never touches the disk. `brasenia-hls-serve`,
a small stdlib server, serves playlists and finished segments on
`brasenia_hls_port`.
- **Why not mediamtx:** its MPEG-TS HLS is H.264-only, and its fMP4 HLS
  declares `#EXT-X-VERSION:10`, which the Roku rejects (`HLS playlist
  unsupported version`).
- **The playlist** is 3 segments of 2 s (kalmia#193), so the Roku joins 4–6 s
  behind live. The app rejoins when it drifts further (lentago/brasenia
  ADR-0015).
- **Restarts:** `omit_endlist` and epoch-numbered segments mean an encoder
  restart never leaves a finished playlist behind or runs the sequence
  backwards. The stream 404s for about 10 s, and the app's retry handler
  rejoins.
- **Size:** at 5 fps the encoder takes about 1.4 cores and 620 MB, hence
  4 cores / 4 GB; 10 fps did not fit 2 cores.

## Build / rebuild

LXC 118 is disposable: everything on it comes from Terraform and
`brasenia.yml`, and `/var/lib/brasenia` holds only rendered PNGs. A rebuild
takes the wall dark from the destroy until the first frame after
provisioning, about 5–10 minutes. Schedule it outside the pe-publish windows
(21:50–22:10Z, 23:20–23:40Z).

The role provisions a **fresh guest only**: it no longer stops or removes the
units of the old renderer (`lunaria-*`, the Cast watchdog), so on a guest that
predates the rename the old `lunaria-hls-serve` would still hold :8080 and
`brasenia-hls-serve` would fail to bind. Rebuild such a guest, don't re-run the
play on it.

1. **Guest.** `container.brasenia` in `terraform/containers.tf`, created by
   the CI apply on merge:
   - hostname `brasenia`, unprivileged, 4 cores, 4 GB, 10 GB on `local-lvm`,
     Debian 12
   - static `192.168.139.19/24`, because the Roku plays the stream by IP
   - MAC pinned to `BC:24:11:8D:F9:C8`, so the Firewalla keeps the same
     device
   - `features { nesting = true }` for Chromium's sandbox

   The API token can create it with nesting: on create the provider sends
   `nesting=1` alone, which PVE allows with `VM.Allocate`. On update it sends
   every flag, which PVE refuses (see terraform/README, "Rails"). To rebuild
   on purpose, change `terraform_data.brasenia_rebuild`'s input. The
   container's `replace_triggered_by` turns that into one destroy-then-create
   of VMID 118. If an apply records the new input but fails before the
   container is destroyed, change the input again: the CI apply takes no
   `-replace`, and an unchanged input plans no replacement. If the destroy
   succeeded and the create failed, the next apply creates it with no change.
2. **Provision**, as root on pve4, once the guest is up (the same
   self-provisioning flow as pub):

   ```bash
   pct exec 118 -- env LC_ALL=C.UTF-8 bash -lc '
     apt-get update && apt-get install -y git ansible
     git clone https://github.com/lentago/kalmia /opt/kalmia
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml brasenia.yml'
   ```
3. **Verify:**
   - `pct exec 118 -- hostname` reads `brasenia`.
   - `pct exec 118 -- systemctl is-active brasenia-render brasenia-stream brasenia-hls-serve`.
   - `pct exec 118 -- id brasenia`, and `/etc/default/brasenia` exists in the
     guest.
   - The sandbox works: `pct exec 118 -- su -s /bin/sh brasenia -c 'unshare
     --user --map-root-user true'` succeeds, and no Chromium in the guest runs
     with `--no-sandbox`.
   - `pct exec 118 -- journalctl -u brasenia-render` shows the panes rendering.
   - `curl -s http://192.168.139.19:8080/master.m3u8` answers.
4. **Display:** the office Roku's dev channel plays
   `http://192.168.139.19:8080/master.m3u8` (brasenia's `VideoScene.xml`;
   sideload with brasenia's `scripts/deploy-roku.sh`). It rejoins on its own
   once the stream is back, through its retry handler. The Roku must have
   Settings → Display type on 4K or Auto, or it plays the stream below 4K.

## Operational notes (hard-won 2026-07-20)

- The Roku Video node never retries a dead stream on its own; the sideloaded
  app carries a state-observer + 3 s Timer retry (rejoins ~1 s after the
  publisher returns). Publisher restarts on LXC 118 are therefore invisible
  beyond a brief freeze.
- The renderer's one Chromium has its HTTP cache disabled
  (`Network.setCacheDisabled`): a persistent profile's cache once served a
  stale tv.html, which is why the old shooter used a throwaway profile per shot.
- **Chromium's sandbox and the sites it renders (kalmia#194).** The sandbox
  needs user namespaces, which the unprivileged LXC has only with `nesting`
  (`terraform/containers.tf`, set 2026-10-29). The renderer checks with
  `unshare --user` when it starts and runs Chromium without `--no-sandbox`
  when namespaces work.
  - pub.lan pages always render. If the sandboxed Chromium cannot start, an
    unsandboxed one renders pub.lan pages only, so a sandbox problem cannot
    blank the screen. The journal says so, and the sandbox is tried again
    every 10 minutes.
  - Any other site renders only when Chromium is sandboxed and the host, or a
    parent domain, is in `brasenia_allowed_sites` (github.com by default). Those
    sites are brasenia's link panes (brasenia ADR-0016). A refused one is shown
    as a notice page.
  - To check the sandbox: `pct exec 118 -- su -s /bin/sh brasenia -c 'unshare
    --user --map-root-user true' && echo sandbox-ok`.
- Services are ordinary systemd units with `Restart=always` — no PID files,
  no process groups. `systemctl status brasenia-render brasenia-stream
  brasenia-hls-serve` is the whole health check; the on-screen clock overlay is the liveness
  indicator (clock advancing + stale pane = renderer problem, frozen
  clock = stream problem). `journalctl -u brasenia-render` logs each render
  with its time, and each switch.
- Everything here is stateless: `/var/lib/brasenia` holds only rendered PNGs.
  Rebuild-from-scratch is terraform apply + the provision play; nothing to
  back up.

## RTMP live ingest — retired 2026-10-29 (kalmia#213)

mediamtx used to accept LAN RTMP publishers on a credentialed `live` path
(kalmia#102), with DJI Fly as the first client. After #167 the Roku played
`brasenia-hls-serve` instead of mediamtx, so nothing read that path. It was
retired so that Roku stays the focus
([decision on #213](https://github.com/lentago/kalmia/issues/213#issuecomment-6512421770)).
mediamtx had no other job, so it went too, along with its three LAN listeners
(`:1935` RTMP, `:8554` RTSP, `:8888` HLS), the unauthenticated `board` publish,
and the `BRASENIA_RTMP_PUBLISH_PASS` credential. On a guest built before the
retirement, the role stops, disables and removes it.

Bringing it back starts in brasenia: a new decision that supersedes ADR-0007
and picks a route to the screen (the options comment on #213 sets out three).
Then revert the change that closed #213 to restore the mediamtx install, its
config and the credential seeding, and build the chosen route. One gotcha from
the old path still applies: mediamtx ≥1.19 HLS answers with a cookie-check 302
unless the player URL pre-bakes `?cookieCheck=1`.

## Cast receiver watchdog — retired 2026-10-28

The Chromecast that was the viewport's second client (brasenia ADR-0006) is
gone, and Roku is the client platform
([brasenia ADR-0010](https://github.com/lentago/brasenia/blob/main/docs/adr/0010-roku-is-the-client-platform.md)).
The watchdog this role used to install (`lunaria-cast-watchdog` and its
timer, `/etc/default/lunaria-cast`, `python3-pychromecast`; #99) was removed
by the role until LXC 118 was rebuilt for #63; the rebuilt container never had
it, and the cleanup tasks went with the rebuild. pub's publishing of the receiver page is retired
separately (#174).
