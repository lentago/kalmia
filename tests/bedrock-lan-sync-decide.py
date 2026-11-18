#!/usr/bin/env python3
"""Tests for the wait/load/switch decision in bedrock-lan-sync (kalmia #323).
Run: python3 tests/bedrock-lan-sync-decide.py"""
import importlib.util
import io
import json
import subprocess
from contextlib import redirect_stdout
import unittest
from pathlib import Path
from unittest.mock import MagicMock, Mock, call, patch

spec = importlib.util.spec_from_file_location(
    "sync", Path(__file__).resolve().parent.parent / "roles/minecraft_lan/files/bedrock-lan-sync.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

OLD, NEW, OTHER = "My-World-aaaaaaaa", "My-World-bbbbbbbb", "Other-cccccccc"


def players(n):
    def f():
        if n is None:
            raise AssertionError("players should not be asked")
        return n
    return f


class Decide(unittest.TestCase):
    def test_up_to_date(self):
        self.assertEqual(sync.decide(OLD, "T", OLD, "T", True, players(None)), "serve")

    def test_new_copy_with_players_waits(self):
        self.assertEqual(sync.decide(OLD, "T", NEW, "T", True, players(2)), "wait")

    def test_new_copy_empty_loads(self):
        self.assertEqual(sync.decide(OLD, "T", NEW, "T", True, players(0)), "load")

    def test_new_slug_switches_at_once(self):
        self.assertEqual(sync.decide(OLD, "T", OTHER, "U", True, players(None)), "switch")

    def test_server_down_loads(self):
        self.assertEqual(sync.decide(OLD, "T", NEW, "T", False, players(None)), "load")

    def test_same_name_but_down_starts(self):
        self.assertEqual(sync.decide(OLD, "T", OLD, "T", False, players(None)), "load")

    def test_slug(self):
        self.assertEqual(sync.world_slug(NEW), "My-World")
        self.assertEqual(sync.world_slug(""), "")


class Sync(unittest.TestCase):
    def run_sync(self, reply, *, level=NEW, fifo_error=None, journal_error=None, journal_status=0):
        slug, hash_prefix = level.rsplit("-", 1)
        sha = hash_prefix * 8
        announcement = {"slug": slug, "title": "Updated Title", "sha256": sha, "file": "world.mcworld"}
        out = io.StringIO()
        state = Mock()
        with (
            patch.object(sync.urllib.request, "urlopen", return_value=io.StringIO(json.dumps(announcement))),
            patch.object(sync, "props", return_value={"level-name": OLD, "server-name": "T"}),
            patch.object(sync, "set_props") as set_props,
            patch.object(sync, "systemctl", return_value=True) as service,
            patch.object(sync, "WORLDS", MagicMock()),
            patch.object(sync, "STATE", state),
            patch.object(sync.os, "open", return_value=3),
            patch.object(sync.os, "write", return_value=5, side_effect=fifo_error) as write,
            patch.object(sync.os, "close") as close,
            patch.object(sync.time, "monotonic", side_effect=[0, 0, 10, 10]),
            patch.object(sync.time, "sleep"),
            patch.object(
                sync.subprocess, "run",
                return_value=subprocess.CompletedProcess([], journal_status, reply, "journal error"),
                side_effect=journal_error,
            ),
            redirect_stdout(out),
        ):
            sync.main()
        write.assert_called_once_with(3, b"list\n")
        close.assert_called_once_with(3)
        return out.getvalue(), set_props, service, state

    def assert_pending(self, reply, reason, **kwargs):
        output, set_props, service, state = self.run_sync(reply, **kwargs)
        self.assertIn(reason, output)
        self.assertIn("waiting:", output)
        set_props.assert_not_called()
        self.assertEqual(service.call_args_list, [call("is-active", "--quiet", sync.SERVICE)])
        state.write_text.assert_not_called()
        return output

    def test_fifo_error_holds_update(self):
        self.assert_pending("", "console list command failed", fifo_error=BrokenPipeError("closed"))

    def test_missing_or_unrecognized_reply_holds_update(self):
        for reply in ("", "There are zero players online", "There are 0/8 players onlineish"):
            with self.subTest(reply=reply):
                self.assert_pending(reply, "no recognizable console list reply")

    def test_journal_failure_holds_even_with_zero_in_output(self):
        self.assert_pending("There are 0/8 players online:", "journalctl exited 1", journal_status=1)

    def test_journal_timeout_holds_update(self):
        self.assert_pending("", "could not read the console reply",
                            journal_error=subprocess.TimeoutExpired("journalctl", 10))

    def test_players_online_hold_update(self):
        self.assert_pending("There are 2/8 players online: Alice, Bob", "2 player(s) online")

    def test_title_change_waits_with_accurate_log(self):
        output = self.assert_pending("There are 1/8 players online: Alice", "title change", level=OLD)
        self.assertNotIn("new world copy", output)

    def test_confirmed_zero_applies_world_or_title_change(self):
        for level in (NEW, OLD):
            with self.subTest(level=level):
                output, set_props, service, state = self.run_sync("There are 0/8 players online:", level=level)
                set_props.assert_called_once_with({"level-name": level, "server-name": "Updated Title"})
                self.assertEqual(service.call_args_list, [
                    call("is-active", "--quiet", sync.SERVICE), call("restart", sync.SERVICE),
                ])
                state.write_text.assert_called_once()
                self.assertIn("switched to Updated Title", output)


if __name__ == "__main__":
    unittest.main()
