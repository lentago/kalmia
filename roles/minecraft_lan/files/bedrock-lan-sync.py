#!/usr/bin/env python3
"""Serve the Bedrock world announced on pub.lan (kalmia #297, docs/minecraft-lan.md).

The announcement (ANNOUNCE_URL, JSON) names one world:
  {"slug": "Some-World", "title": "Some World", "file": "Some-World.mcworld", "sha256": "<64 hex>"}
The .mcworld sits next to the announcement. A new world (by slug and hash) is downloaded,
checked against the hash, unpacked into worlds/<slug>-<hash[:8]>, and the server is switched to
it. Earlier world directories are kept, so switching back to one resumes where it was left. Run
by bedrock-lan-sync.timer; also starts the server if it should be running and isn't.

Prints "switched to ...", "serving ..." or "no world announced ...".
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
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

URL = os.environ.get("ANNOUNCE_URL", "http://pub.lan/minecraft/lan.json")
HOME = Path(os.environ.get("BEDROCK_HOME", "/opt/bedrock"))
USER = os.environ.get("BEDROCK_USER", "bedrock")
WORLDS, PROPS, STATE = HOME / "worlds", HOME / "server.properties", HOME / "lan-state.json"
SERVICE = "bedrock-server.service"


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
    current = props()
    same = current.get("level-name") == name and current.get("server-name") == title
    if same and systemctl("is-active", "--quiet", SERVICE):
        print(f"serving {title} ({name})")
        return
    set_props({"level-name": name, "server-name": title})
    if not systemctl("restart", SERVICE):
        sys.exit(f"could not start {SERVICE}; see journalctl -u {SERVICE}")
    STATE.write_text(json.dumps({"world": name, "title": title, "sha256": sha}) + "\n")
    print(f"switched to {title} ({name})")


if __name__ == "__main__":
    main()
