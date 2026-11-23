# Claude Code transcripts (betula client)

The `claude_transcripts` role installs betula's Claude Code transcript client
([lentago/betula `clients/claude-code`](https://github.com/lentago/betula/tree/main/clients/claude-code),
ADR-0008) on every machine a person runs Claude Code on. Each session's
transcript then goes to the NAS archive (full, secrets redacted) and a scrubbed
narration goes to Grafana Cloud Loki (`{job="claude_transcript"}`), next to the
bullpen's. Rollout tracked in lentago/betula#161.

## What it changes

| Path | What |
|---|---|
| `/opt/betula/src` | betula checked out at `claude_transcripts_version` (a full commit sha) |
| `/opt/betula/claude-code/` | the client, copied from that checkout (same layout as `install.sh --apply`) |
| `/etc/claude-code/managed-settings.d/60-betula-transcripts.json` | the hook, machine-wide. Merges with `viewer_host`'s `managed-settings.json` (both run on the ThinkPad, verified 2026-11-22) |
| `/etc/systemd/system/betula-cc-sync.{service,timer}` | `cc-transcripts sync --all` every 15 minutes, as the user, for sessions the hook missed |
| `~/.local/state/betula-cc/.seeded` | marks the one-time seed. A host with existing cursors (a hand install) keeps them |
| `/etc/betula/` | the directory only. **Ansible never writes the env file** |

Seeding runs before the hook and the timer, so nothing written before the
install is backfilled.

## Which hosts

`claude_transcripts_hosts` in [`group_vars/all.yml`](../group_vars/all.yml):
xubuntu-ws, the ThinkPad, fedora-ws and the Chromebook. Keyed on the hostname
so the testbeds, which build the same profiles, never ship. The role refuses
`claude-runner*` hosts: drosera's Alloy shipper already covers the bullpen.

## The env file (once per host, by hand)

It holds a Loki `logs:write` token, so it stays out of git. From betula's
`clients/claude-code/env.example`, or from drosera's `.envrc`:

```bash
( source .envrc && printf 'GRAFANA_CLOUD_LOGS_URL=%s\nGRAFANA_CLOUD_LOGS_USER=%s\nGRAFANA_CLOUD_LOGS_TOKEN=%s\nBETULA_CC_ARCHIVE_DIR=/mnt/lentago/claude-state/transcripts\n' \
  "$GRAFANA_CLOUD_LOGS_URL" "$GRAFANA_CLOUD_LOGS_USER" "$GRAFANA_CLOUD_LOGS_TOKEN" ) \
  | sudo install -D -m 0640 -g "$(id -gn)" /dev/stdin /etc/betula/claude-code.env
```

Leave out `BETULA_CC_ARCHIVE_DIR` on a host without the NAS mount (the
Chromebook): it then ships to Loki only. Without the file at all, the hook is
installed but ships nothing.

## Rollout

Run it in your own terminal. A Claude session can't change the hook that
records it (Claude Code's safety check refuses), and sudo needs your password.

```bash
ansible-playbook site.yml --tags claude-transcripts --ask-become-pass --check --diff   # preview
ansible-playbook site.yml --tags claude-transcripts --ask-become-pass                  # apply
/opt/betula/claude-code/cc-transcripts status                                         # 0 failing
systemctl list-timers betula-cc-sync.timer
```

On a first run the preview can only plan the checkout, so it skips the copies
that read from it and shows the units it would write. Then check Grafana for
`{job="claude_transcript", worker="<host>"}` after one session turn.

## Upgrading and turning it off

Bump `claude_transcripts_version` in `roles/claude_transcripts/defaults/main.yml`
to a reviewed betula commit and re-run the tag. To stop shipping on one host,
delete the drop-in and disable the timer:

```bash
sudo rm /etc/claude-code/managed-settings.d/60-betula-transcripts.json
sudo systemctl disable --now betula-cc-sync.timer
```

and take the host out of `claude_transcripts_hosts` so the next run doesn't put
them back.
