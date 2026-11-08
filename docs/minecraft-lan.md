# minecraft-lan — Bedrock Dedicated Server for the LAN (LXC 125, pve4)

A Bedrock Dedicated Server that Bedrock clients on the LAN find under
**Play → Friends → LAN Games** (#297). It exists so worlds reach tablets
without importing `.mcworld` files: Android's Files app often won't hand those
to the game, and the game has no import button on Android.

| | |
|---|---|
| Guest | LXC 125 `minecraft-lan`, pve4, 192.168.139.2, Debian 12, 2c / 4 GiB / 16 GB |
| Defined in | [`terraform/minecraft-lan.tf`](../terraform/minecraft-lan.tf) (CI apply-on-merge) |
| Provisioned by | `minecraft-lan.yml` + the `minecraft_lan` role |
| Server | `/opt/bedrock/server` → `bds-<version>`; user `bedrock`; `bedrock-server.service` |
| World sync | `bedrock-lan-sync.timer` (every minute) runs `/usr/local/bin/bedrock-lan-sync` |
| Ports | UDP 19132 / 19133, LAN only (nothing is forwarded) |

## Which world it serves

The `cpitzi/minecraft-builds` publisher writes `http://pub.lan/minecraft/lan.json`
next to the worlds it publishes:

```json
{"slug": "Some-World", "title": "Some World", "file": "Some-World.mcworld", "sha256": "…"}
```

The sync timer reads it. A world it hasn't seen (by slug and hash) is
downloaded, checked against the hash, unpacked into
`/opt/bedrock/worlds/<slug>-<hash[:8]>`, and the server is restarted on it. The
title becomes the name in the LAN list. Earlier world directories are kept, so
announcing an older world again resumes it where it was left, and a rebuilt
world (new hash) starts fresh beside the old one.

The timer is the only unit enabled at boot. It starts the server once a world
is announced, so the server never creates a stray default world. To take the
server down, stop the timer too: `systemctl stop bedrock-lan-sync.timer bedrock-server`.

## Settings

The role owns these `server.properties` lines (`minecraft_lan_properties`):
creative, peaceful, cheats allowed, 8 players, online mode (Xbox Live sign-in,
as on Realms, so the guest needs the WAN), LAN visibility on, and
`default-player-permission-level=operator`. Anyone who can reach it is on the
LAN, so they can use commands without per-player setup. `level-name` and
`server-name` belong to the sync script.

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
     git clone https://github.com/lentago/kalmia /opt/kalmia 2>/dev/null || git -C /opt/kalmia pull --ff-only
     cd /opt/kalmia && ansible-playbook -i inventory/hosts.yml minecraft-lan.yml'"
   ```

5. **Check:** the play's last task prints what the sync did. From the LAN, the
   server answers a RakNet unconnected ping on UDP 19132 with its title, and a
   tablet lists it under LAN Games.
