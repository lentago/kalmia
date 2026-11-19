#!/usr/bin/env python3
"""Every pre_task in site.yml must carry the `always` tag (kalmia#251).

The pre_tasks detect workstation_profile and load the profile and OS-family
vars. Untagged, a tag-limited run (`--tags shell`) skips them and roles render
from their own defaults, or `when: workstation_profile == ...` is false.
"""
import sys
import yaml

plays = yaml.safe_load(open("site.yml"))
bad = []
for play in plays:
    for task in play.get("pre_tasks", []):
        tags = task.get("tags", [])
        if isinstance(tags, str):
            tags = [tags]
        if "always" not in tags:
            bad.append(task.get("name", "<unnamed>"))
if bad:
    print("pre_tasks missing `tags: always` in site.yml:", *bad, sep="\n  - ")
    sys.exit(1)
print("ok: every pre_task is tagged always")
