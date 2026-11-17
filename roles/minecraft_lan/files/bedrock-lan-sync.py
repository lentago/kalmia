#!/usr/bin/env python3
"""Serve the Bedrock world announced on pub.lan (kalmia #297, docs/minecraft-lan.md).

The announcement (ANNOUNCE_URL, JSON) names one world:
  {"slug": "Some-World", "title": "Some World", "file": "Some-World.mcworld", "sha256": "<64 hex>"}
The .mcworld sits next to the announcement. A new world (by slug and hash) is downloaded,
checked against the hash, unpacked into worlds/<slug>-<hash[:8]>, and the server is switched to
it. Earlier world directories are kept, so switching back to one resumes where it was left. Run
by bedrock-lan-sync.timer; also starts the server if it should be running and isn't.

A new copy of the world being played (same slug, new hash) waits while anyone is on the server,
and loads on the first tick with nobody on (or at the server's next start). A different slug
switches at once. Players are counted with the server's own console `list`.

Prints "switched to ...", "serving ...", "waiting ..." or "no world announced ...".
"""
import hashlib
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

URL = os.environ.get("ANNOUNCE_URL", "http://pub.lan/minecraft/lan.json")
HOME = Path(os.environ.get("BEDROCK_HOME", "/opt/bedrock"))
USER = os.environ.get("BEDROCK_USER", "bedrock")
WORLDS, PROPS, STATE = HOME / "worlds", HOME / "server.properties", HOME / "lan-state.json"
SERVICE = "bedrock-server.service"
CONSOLE = Path(os.environ.get("BEDROCK_CONSOLE", "/run/bedrock/console"))
PLAYERS_RE = re.compile(r"There are (\d+)/\d+ players online")


def world_slug(level_name: str) -> str:
    """The slug of a worlds/<slug>-<hash[:8]> directory name."""
    m = re.fullmatch(r"(.+)-[0-9a-f]{8}", level_name)
    return m.group(1) if m else level_name


def decide(current_level: str, current_title: str, name: str, title: str, active: bool, players) -> str:
    """What to do with the announced world: "serve" (already on it), "load" (restart onto it),
    "switch" (a different world: restart onto it) or "wait" (a new copy of the world being played
    while players are on). `players` is a callable returning the count, only called when it matters."""
    if current_level == name and current_title == title and active:
        return "serve"
    if not active:
        return "load"
    if world_slug(current_level) != world_slug(name):
        return "switch"
    return "wait" if players() > 0 else "load"


def players_online(wait: float = 10.0) -> int:
    """Ask the server's console `list` and read the answer from the journal. 0 when the console
    doesn't answer (server down or starting)."""
    try:
        fd = os.open(CONSOLE, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return 0
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        os.write(fd, b"list\n")
    except OSError:
        return 0
    finally:
        os.close(fd)
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        time.sleep(0.5)
        out = subprocess.run(["journalctl", "-u", SERVICE, "--since", since, "-o", "cat", "--no-pager"],
                             capture_output=True, text=True).stdout
        found = PLAYERS_RE.findall(out)
        if found:
            return int(found[-1])
    return 0


def systemctl(*args) -> bool:
    return subprocess.run(["systemctl", *args], capture_output=True).returncode == 0


def set_props(values: dict):
    text = PROPS.read_text()
    for k, v in values.items():
        v = v.replace("\n", " ")
        text, n = re.subn(rf"^{re.escape(k)}=.*$", lambda _: f"{k}={v}", text, flags=re.M)
        if not n:
            text = text.rstrip("\n") + f"\n{k}={v}\n"
    tmp = PROPS.with_name(PROPS.name + ".tmp")
    tmp.write_text(text)
    shutil.copymode(PROPS, tmp)
    os.chown(tmp, *ids())
    os.replace(tmp, PROPS)


def props() -> dict:
    return dict(ln.split("=", 1) for ln in PROPS.read_text().splitlines() if "=" in ln and not ln.startswith("#"))


def ids():
    pw = pwd.getpwnam(USER)
    return pw.pw_uid, pw.pw_gid


def chown_tree(path: Path):
    uid, gid = ids()
    for root, dirs, files in os.walk(path):
        os.chown(root, uid, gid)
        for n in dirs + files:
            os.chown(os.path.join(root, n), uid, gid, follow_symlinks=False)


def unpack(archive: Path, dest: Path):
    """Extract a .mcworld (a zip of the world folder) into dest, refusing anything that would land
    outside it or isn't a plain file or directory."""
    tmp = Path(tempfile.mkdtemp(prefix=".incoming-", dir=WORLDS))
    try:
        with zipfile.ZipFile(archive) as z:
            for m in z.infolist():
                kind = (m.external_attr >> 16) & 0o170000
                target = (tmp / m.filename).resolve()
                if kind not in (0, 0o100000, 0o040000) or not target.is_relative_to(tmp.resolve()):
                    sys.exit(f"refusing archive member {m.filename!r}")
                z.extract(m, tmp)
        if not (tmp / "level.dat").exists():
            sys.exit("the announced world has no level.dat at its top level")
        chown_tree(tmp)
        os.rename(tmp, dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    try:
        with urllib.request.urlopen(URL, timeout=20) as r:
            ann = json.load(r)
    except Exception as e:  # noqa: BLE001 - no announcement yet, or pub.lan unreachable
        print(f"no world announced at {URL} ({e})")
        return
    slug, title, file, sha = ann.get("slug", ""), ann.get("title", ""), ann.get("file", ""), ann.get("sha256", "")
    if not (re.fullmatch(r"[A-Za-z0-9-]{1,64}", slug) and re.fullmatch(r"[0-9a-f]{64}", sha)
            and re.fullmatch(r"[^/\\]{1,128}\.mcworld", file) and 0 < len(title) <= 64):
        sys.exit(f"malformed announcement: {ann!r}")
    name = f"{slug}-{sha[:8]}"
    dest = WORLDS / name
    current = props()
    seen = []

    def count() -> int:
        seen.append(players_online())
        return seen[-1]

    action = decide(current.get("level-name", ""), current.get("server-name", ""), name, title,
                    systemctl("is-active", "--quiet", SERVICE), count)
    if action == "serve":
        print(f"serving {title} ({name})")
        return
    if action == "wait":
        n = seen[-1]
        print(f"waiting: a new copy of {title} ({name}) is announced, {n} player(s) online; "
              f"it loads when nobody is on")
        return
    if not dest.exists():
        url = urllib.parse.urljoin(URL, urllib.parse.quote(file))
        fd, tmp = tempfile.mkstemp(prefix=".download-", dir=HOME)
        try:
            h = hashlib.sha256()
            with os.fdopen(fd, "wb") as out, urllib.request.urlopen(url, timeout=600) as r:
                while chunk := r.read(1 << 20):
                    h.update(chunk)
                    out.write(chunk)
            if h.hexdigest() != sha:
                sys.exit(f"{url} does not match the announced SHA-256; not serving it")
            unpack(Path(tmp), dest)
        finally:
            Path(tmp).unlink(missing_ok=True)
    set_props({"level-name": name, "server-name": title})
    if not systemctl("restart", SERVICE):
        sys.exit(f"could not start {SERVICE}; see journalctl -u {SERVICE}")
    STATE.write_text(json.dumps({"world": name, "title": title, "sha256": sha}) + "\n")
    print(f"switched to {title} ({name})")


if __name__ == "__main__":
    main()
