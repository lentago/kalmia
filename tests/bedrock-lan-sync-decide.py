#!/usr/bin/env python3
"""Tests for the wait/load/switch decision in bedrock-lan-sync (kalmia #323).
Run: python3 tests/bedrock-lan-sync-decide.py"""
import importlib.util
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
