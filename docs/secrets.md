# Secrets for Claude sessions on xubuntu-ws

Two paths, one rule. Both are installed by the `dev_host` role (#343, with the
`bw` install from #341/#342).

**The rule: never print a secret.** Anything a session prints lands in its
transcript, and the nightly mirror (#286) copies transcripts to the NAS. Hand a
value to the command that needs it, and nowhere else:

```bash
bws run -- ./deploy.sh                  # secrets arrive in that command's environment
bws secret get <id> | jq -r .value | some-cmd --password-stdin   # on stdin, never echoed
```

Never `echo`, `cat`, `bws secret get` to the terminal, or put a value in a
command line, a commit, a PR or an issue.

## A. Machine secrets: `bws`

For secrets a session needs routinely. `bws` is the Bitwarden Secrets Manager
CLI, pinned and checksummed. Its access token belongs to a **machine account
that reads one project**, so its reach is only the secrets put in that project.

- The token lives in `~/.config/bws/access-token` (file mode 600, directory
  700). Ansible creates the directory and **never the token**; write it
  yourself: `install -m 600 /dev/null ~/.config/bws/access-token`, then paste.
- Every new shell exports `BWS_ACCESS_TOKEN` from that file, but only when it
  exists and is non-empty. Claude Code reads the environment once, at session
  start, so start (or restart) a session after placing the token.
- The Secrets Manager organization, project, machine account and token are set
  up in the Bitwarden web app.

## B. The personal vault: per-task `bw` unlock

An unlocked `bw` exposes the **whole personal vault** and cannot be scoped.
Unlock it for one task, then lock it.

| Command | Where | What it does |
|---|---|---|
| `bw-unlock` | your own terminal | asks for the master password, keeps the session key in `$XDG_RUNTIME_DIR/bw-session` (tmpfs, mode 600) |
| `bw-lock` | your own terminal | deletes that file and runs `bw lock` |

While the file exists, `bw` picks the key up on its own: `/usr/local/bin/bw` is
a wrapper that reads the file **when it is called**, because Claude Code
snapshots the shell environment at session start and a later
`export BW_SESSION` would never reach a running session. With no file, or with
`BW_SESSION` already set, `bw` behaves as it would without the wrapper. A key
file whose mode isn't 600, or that is a symlink, is ignored.

The directory is `$XDG_RUNTIME_DIR`, else `/run/user/<uid>`. A reboot clears
it. There is no on-disk fallback: with no tmpfs directory, `bw-unlock` fails.

## Rollout

```bash
ansible-playbook site.yml --tags dev-host,shell --ask-become-pass
```

Sudo on xubuntu-ws needs the password, so run it in your own terminal. Add
`--check --diff` first to preview. `--tags` runs detect the profile on their
own since #340. Open a new shell afterwards so `BWS_ACCESS_TOKEN` is picked up.
