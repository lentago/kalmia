# minecraft-lan — Bedrock Dedicated Server for the LAN (LXC 125, pve4)

A Bedrock Dedicated Server for the household's Bedrock clients (#297), so
worlds reach tablets without importing `.mcworld` files: Android's Files app
often won't hand those to the game, and the game has no import button on
Android.

**How clients join: add it as a server.** In Minecraft, **Play → Servers →
Add Server**, address `192.168.139.2`, port `19132`. The server also shows
under **Play → Friends → LAN Games**, but with 1.26.62 clients a join from
that list never contacts the server and fails with `InitialConnection-145`
("Boat"); see Transport below (#299).

| | |
|---|---|
| Guest | LXC 125 `minecraft-lan`, pve4, 192.168.139.2, Debian 12, 2c / 4 GiB / 16 GB |
| Defined in | [`terraform/minecraft-lan.tf`](../terraform/minecraft-lan.tf) (CI apply-on-merge) |
| Provisioned by | `minecraft-lan.yml` + the `minecraft_lan` role |
| Server | `/opt/bedrock/server` → `bds-<version>`; user `bedrock`; `bedrock-server.service` |
| World sync | `bedrock-lan-sync.timer` (every minute) runs `/usr/local/bin/bedrock-lan-sync` |
| Ports | UDP 7551 (NetherNet LAN discovery); NetherNet game traffic on `server-udp-ports` (19132, from the stock file); `server-port` 19132 / `server-portv6` 19133 set by the role. LAN only (nothing is forwarded) |

## Which world it serves

The `cpitzi/minecraft-builds` publisher writes `http://pub.lan/minecraft/lan.json`
next to the worlds it publishes:

```json
{"slug": "Some-World", "title": "Some World", "file": "Some-World.mcworld", "sha256": "…"}
```

The sync timer reads it. A world it hasn't seen (by slug and hash) is
downloaded, checked against the hash (an integrity check: it catches a
truncated or corrupt download, not tampering, since the hash arrives over the
same plain HTTP from pub.lan), unpacked into
`/opt/bedrock/worlds/<slug>-<hash[:8]>`, and the server is restarted on it. The
title becomes the name in the LAN list. Earlier world directories are kept, so
announcing an older world again resumes it where it was left, and a rebuilt
world (new hash) starts fresh beside the old one.

Trust: the guest serves whatever pub.lan announces. pub.lan is LAN-only, and
anyone who could rewrite it or impersonate it on the LAN could make the server
run a different world. The unpacker refuses archive members that are links or
would land outside the world directory, and the server runs as the unprivileged
`bedrock` user, so the most such a change can do is put a different world on
the server.

The timer is the only unit enabled at boot. It starts the server once a world
is announced, so the server never creates a stray default world. To take the
server down, stop the timer too: `systemctl stop bedrock-lan-sync.timer bedrock-server`.

## Settings

The role owns these `server.properties` lines (`minecraft_lan_properties`):
creative, peaceful, cheats allowed, 8 players, online mode (Xbox Live sign-in,
as on Realms, so the guest needs the WAN), the allowlist off (the stock file
turns it on, which would refuse every unlisted player), LAN visibility on, and
`default-player-permission-level=operator`. The last is a deliberate trust
decision: every player who can reach the server (a device on the main LAN,
signed in to Xbox Live; nothing is forwarded) can use commands without
per-player setup. Set `member` if the LAN ever carries devices whose players
shouldn't. `client-side-chunk-generation-enabled=false` makes the server send real chunks out to each client's render distance; with it on, clients draw distant chunks from the seed (plain grass in a flat world), so builds far from a player were invisible until they got close. `level-name` and `server-name` belong to the sync script.

**Transport: NetherNet**, the 1.26 default and the only one 1.26 clients use.
With `transport=raknet` the server logs "NetherNet is the only supported
transport type. Players will not be able to connect to your game without
NetherNet", and clients neither list it nor connect (#300 tried it). On
NetherNet a dedicated server takes joins on a dual-stack **TCP** socket on
`server-port` (an HTTP signaling handshake), then negotiates a UDP connection
for gameplay on `server-udp-ports` (`bedrock_server_how_to.html`, § Transport).
A client joining an **added server** does exactly that, and it works: the first
successful join, from a 1.26.62 ChromeOS client, went this way (#299).

A join from **LAN Games** doesn't: packet captures on the guest's interface
show the client broadcasting discovery (UDP 7551) and the server answering, but
no TCP or UDP from the client to the server at all during the join, which
fails with `InitialConnection-145`. The client-side LAN path apparently expects
something a dedicated server doesn't do; it's outside our control. LAN
visibility stays on (the list entry is harmless, discovery is how
`tools/lan_server.py` checks the server, and a future client may join from it).
The server's HTTPS connections to Microsoft close after about 90 seconds on any
host (also seen on a workstation running the same server), so those closes are
routine; joins through an added server work while they're closed, but whether
they play a part in the LAN Games path failing isn't known.

`server.properties` and `worlds/` live in `/opt/bedrock` and are linked into
each version directory, so an upgrade keeps both.

## Console

The server's stdin is a FIFO, so commands can be written to it and replies
read from the journal:

```bash
echo "list" > /run/bedrock/console
journalctl -u bedrock-server -n 20 --no-pager
```

`systemctl stop bedrock-server` sends `stop`, which saves the world, and waits
for the server to exit.

## Upgrading the server

Clients only join a server of their own version, and the tablets update
themselves, so when they move to a new Bedrock release:

1. Download the Linux server zip from minecraft.net by hand (its bot check
   blocks scripts) and stage it on the NAS in `cpitzi/minecraft-ci`.
2. In one PR, bump `minecraft_lan_bds_version`/`_sha256` together with
   `minecraft_runner_bds_version`/`_sha256`.
3. Re-run the playbook here (below). The new version unpacks beside the old one
   and the server restarts on it with the same worlds.

## Build / rebuild

1. **Allowlist:** its one mount (the staging share, read-only) is in
   `pve_host_mount_hook_allow`. Push it to pve4 before the guest's first apply
   (see [`docs/pve-host.md`](pve-host.md)).
2. **Guest and mount:** merged `terraform/minecraft-lan.tf` creates the CT and
   the apply attaches the mount. Check from pve4: `pct exec 125 -- findmnt -t cifs`.
3. **Firewalla:** a new MAC starts WAN-blocked until it's approved in the
   Firewalla app. Approve it before provisioning: the play installs packages,
   and the server needs Xbox Live. The MAC is pinned in Terraform, so a rebuild
   keeps the approval.
4. **Provision**, on the container:

   ```bash
   ssh root@pve4 "pct exec 125 -- env LC_ALL=C.UTF-8 bash -lc '
     apt-get update && apt-get install -y git ansible
     if [ -d /opt/kalmia ]; then git -C /opt/kalmia pull --ff-only; else git clone https://github.com/lentago/kalmia /opt/kalmia; fi
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml minecraft-lan.yml'"
   ```

5. **Check:** the play's last task prints what the sync did. From the LAN, the
   server answers NetherNet LAN discovery (UDP 7551) with its title, version
   and world (cpitzi/minecraft-builds has `tools/lan_server.py discover`), TCP
   19132 accepts connections, and a client joins it as an added server
   (Play → Servers → Add Server, `192.168.139.2`, port `19132`).
