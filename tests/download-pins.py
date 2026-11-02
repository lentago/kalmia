#!/usr/bin/env python3
# ============================================================================
# download-pins — fail on an unpinned download anywhere in kalmia's Ansible
# (kalmia#259). Scans every task and handler file under roles/ and every
# playbook at the repo root, and reports:
#
#   * a get_url task with no `checksum`;
#   * an unarchive task whose `src` is a URL — it cannot carry a checksum, so
#     download with get_url + checksum first and unarchive the local file;
#   * a uri task with `dest` — a download to disk that cannot carry a checksum;
#   * a shell, command or raw task that runs curl or wget at all: piped or fed
#     into a shell (`| sh`, `bash <(curl …)`, `sh -c "$(curl …)"`) or saved
#     with -o/-O, it is a download get_url should make. Use uri for API calls.
#
# rpm_key URLs are not covered yet (kalmia#262).
#
# Usage: tests/download-pins.py [REPO_ROOT]   (default: the repo this file is in)
# Exit 0 when clean, 1 with one line per finding. Needs PyYAML, which Ansible
# itself depends on.
# ============================================================================
import pathlib
import re
import sys

import yaml


def names(short):
    return {short, f"ansible.builtin.{short}", f"ansible.legacy.{short}"}


GET_URL = names("get_url")
UNARCHIVE = names("unarchive")
URI = names("uri")
SHELLISH = names("shell") | names("command") | names("raw")
TASK_LISTS = ("tasks", "pre_tasks", "post_tasks", "handlers")
BLOCK_KEYS = ("block", "rescue", "always")

_SHELL = r"(?:/\S*/)?(?:ba|da|k|z)?sh\b"
PIPE_TO_SHELL = re.compile(
    r"\b(?:curl|wget)\b[^|]*\|\s*"            # curl … |
    r"(?:sudo(?:\s+-\S+)*\s+)?"                # optional sudo [-E …]
    r"(?:env\s+)?(?:\w+=(?:\"[^\"]*\"|'[^']*'|\S+)\s+)*"  # optional VAR=val …
    + _SHELL
)
FEED_TO_SHELL = re.compile(_SHELL + r"[^|]*(?:<\(|\$\()\s*(?:curl|wget)\b")
ANY_FETCH = re.compile(r"\b(?:curl|wget)\b")


class Loader(yaml.SafeLoader):
    """SafeLoader that tolerates Ansible tags such as !vault and !unsafe."""


Loader.add_multi_constructor("!", lambda loader, suffix, node: None)


def tasks_in(items):
    """Yield every task dict in a task list, descending into blocks."""
    for item in items or []:
        if not isinstance(item, dict):
            continue
        if any(k in item for k in BLOCK_KEYS):
            for key in BLOCK_KEYS:
                yield from tasks_in(item.get(key))
        else:
            yield item


def module_of(task, wanted):
    for key in task:
        if key in wanted:
            return key
    return None


def args_of(task, module):
    raw = task.get(module)
    args = dict(task.get("args") or {}) if isinstance(task.get("args"), dict) else {}
    if isinstance(raw, dict):
        args.update(raw)
    elif raw is not None:
        args["_raw_params"] = str(raw)
    return args


def command_text(args):
    parts = [args.get("_raw_params"), args.get("cmd")]
    argv = args.get("argv")
    if isinstance(argv, list):
        parts.append(" ".join(str(a) for a in argv))
    return " ".join(str(p) for p in parts if p)


def check_task(task):
    label = task.get("name") or "(unnamed task)"
    found = []
    mod = module_of(task, GET_URL)
    if mod and not args_of(task, mod).get("checksum"):
        found.append(f"get_url without checksum: {label}")
    mod = module_of(task, UNARCHIVE)
    if mod and re.match(r"^\s*(?:https?|ftp)://", str(args_of(task, mod).get("src", ""))):
        found.append(f"unarchive straight from a URL (no checksum possible): {label}")
    mod = module_of(task, URI)
    if mod and args_of(task, mod).get("dest"):
        found.append(f"uri downloading to disk (no checksum possible): {label}")
    mod = module_of(task, SHELLISH)
    if mod:
        text = " ".join(command_text(args_of(task, mod)).split())
        if PIPE_TO_SHELL.search(text) or FEED_TO_SHELL.search(text):
            found.append(f"remote script piped into a shell: {label}")
        elif ANY_FETCH.search(text):
            found.append(f"curl/wget in a {mod.split('.')[-1]} task (download with get_url + checksum): {label}")
    return found


def files_to_scan(root):
    for sub in ("tasks", "handlers"):
        yield from sorted(root.glob(f"roles/*/{sub}/**/*.yml"))
        yield from sorted(root.glob(f"roles/*/{sub}/**/*.yaml"))
    yield from sorted(p for p in root.glob("*.yml") if p.name != "requirements.yml")


def scan(path):
    doc = yaml.load(path.read_text(), Loader=Loader)  # noqa: S506 — SafeLoader subclass
    if not isinstance(doc, list):
        return []
    if path.parent.name in ("tasks", "handlers") or path.parent.parent.name in ("tasks", "handlers"):
        tasks = list(tasks_in(doc))
    else:  # a playbook: a list of plays
        tasks = []
        for play in doc:
            if isinstance(play, dict):
                for key in TASK_LISTS:
                    tasks.extend(tasks_in(play.get(key)))
    return [finding for task in tasks for finding in check_task(task)]


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
    findings = []
    for path in files_to_scan(root):
        for finding in scan(path):
            findings.append(f"{path.relative_to(root)}: {finding}")
    for line in findings:
        print(line)
    if findings:
        print(f"download-pins: {len(findings)} unpinned download(s); pin a version and a sha256 (kalmia#259)",
              file=sys.stderr)
        return 1
    print("download-pins: every download is pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
