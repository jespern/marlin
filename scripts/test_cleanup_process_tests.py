import dataclasses
import unittest

from cleanup_process_tests import LEGACY_SCRIPT, Process, is_leftover, parse_snapshot, safe_group


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.loop = Process(
            19428, 1, 19428, 501, "Tue Sep 22 13:00:00 2026",
            "bash -c " + LEGACY_SCRIPT + "/private/tmp/marlin-process-io-escapee-2fb3ddfd/escapee.pid",
        )

    def test_matches_exact_orphan_fixture(self):
        self.assertTrue(is_leftover(self.loop, 501))
        for changes in (
            {"ppid": 999}, {"uid": 502}, {"pgid": 888}, {"pid": 1, "pgid": 1},
            {"command": "marlin daemon --ready-stdout"},
            {"command": self.loop.command + " extra"},
            {"command": self.loop.command.replace("marlin-process-io-escapee", "another-project")},
            {"command": self.loop.command.replace("while :", "while false")},
        ):
            with self.subTest(changes=changes):
                self.assertFalse(is_leftover(dataclasses.replace(self.loop, **changes), 501))

    def test_parses_macos_ps_newlines_and_start_time(self):
        command = self.loop.command.replace("\n", "\\012")
        listing = f"19428 1 19428 501 Tue Sep 22 13:00:00 2026 {command}\n"
        self.assertEqual(parse_snapshot(listing), {19428: self.loop})
        with self.assertRaises(ValueError):
            parse_snapshot("19428 1\n")

    def test_refuses_pid_reuse_or_unexpected_group_members(self):
        sleeper = Process(20000, self.loop.pid, self.loop.pgid, 501, self.loop.started, "sleep 1")
        current = {self.loop.pid: self.loop, sleeper.pid: sleeper}
        self.assertTrue(safe_group(self.loop, current, 501))
        self.assertFalse(safe_group(self.loop, {}, 501))
        changed = dict(current)
        changed[self.loop.pid] = dataclasses.replace(self.loop, started="Wed Sep 23 13:00:00 2026")
        self.assertFalse(safe_group(self.loop, changed, 501))
        for change in ({"command": "marlin"}, {"ppid": 999}, {"uid": 502}):
            changed = dict(current)
            changed[sleeper.pid] = dataclasses.replace(sleeper, **change)
            self.assertFalse(safe_group(self.loop, changed, 501))


if __name__ == "__main__":
    unittest.main()
