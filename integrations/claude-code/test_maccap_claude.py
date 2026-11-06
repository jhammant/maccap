import json
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

import maccap_claude as mc

MEETING = {
    "type": "final_notes", "title": "Northwind pilot", "started_at": "2026-11-06T10:00:00Z",
    "duration_seconds": 1500, "apps": ["Zoom"], "next_steps": ["(You): I'll send the pricing by Friday."],
    "transcript": "[00:01] Them: Hi, it's Priya.\n[00:05] You: Hi Priya.",
}


def fake_run(stdout, code=0, seen=None):
    def run(args, **kwargs):
        if seen is not None:
            seen.append((args, kwargs))
        return subprocess.CompletedProcess(args, code, stdout=stdout, stderr="boom" if code else "")
    return run


class ParseTests(unittest.TestCase):
    def test_finds_json_inside_a_fence_and_prose(self):
        # Arrange
        reply = 'Here you go:\n```json\n{"ai_steps": ["Draft it"], "x": {"y": 1}}\n```'
        # Act
        data = mc.parse_json(reply)
        # Assert
        self.assertEqual(data["ai_steps"], ["Draft it"])

    def test_no_json_is_none(self):
        self.assertIsNone(mc.parse_json("sorry, no"))
        self.assertIsNone(mc.parse_json(None))


class FinalNotesTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(mc, "find_claude", return_value="/bin/claude")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_reply_is_trimmed_to_limits_and_labelled(self):
        # Arrange
        reply = json.dumps({"ai_steps": [f"a{i}" for i in range(9)], "your_steps": ["y1", "y2", "y3"],
                            "waiting_on": ["Priya will send the model."], "key_points": ["k"], "open_questions": []})
        seen = []
        # Act
        result = mc.final_notes(MEETING, "sonnet", run=fake_run(reply, seen=seen))
        # Assert
        self.assertEqual(len(result["ai_steps"]), 4)
        self.assertEqual(result["your_steps"], ["y1", "y2"])
        self.assertEqual(result["model"], "Claude Code (sonnet)")
        args, kwargs = seen[0]
        self.assertIn("--tools", args)
        self.assertEqual(args[args.index("--tools") + 1], "")
        self.assertIn("Priya", kwargs["input"])

    def test_claude_failing_gives_none(self):
        self.assertIsNone(mc.final_notes(MEETING, "sonnet", run=fake_run("", code=1)))

    def test_claude_missing_gives_none(self):
        with mock.patch.object(mc, "find_claude", return_value=None):
            self.assertIsNone(mc.final_notes(MEETING, "sonnet", run=fake_run("{}")))


class FollowUpTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(mc, "find_claude", return_value="/bin/claude")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_drafts_written_to_one_private_file(self):
        # Arrange
        meeting = dict(MEETING, type="meeting_finished",
                       next_steps=["Claude: Draft the email to Priya", "You: Call finance"])
        with tempfile.TemporaryDirectory() as tmp:
            # Act
            result = mc.follow_up(meeting, "sonnet", Path(tmp), run=fake_run("## Draft the email\nHi Priya"),
                                  now=datetime(2026, 11, 6, 10, 30))
            # Assert
            path = Path(tmp) / "20261106 103000 Northwind-pilot.md"
            self.assertEqual(result, {"status": "1 draft ready", "url": path.as_uri()})
            self.assertIn("Hi Priya", path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_nothing_ticked(self):
        result = mc.follow_up(dict(MEETING, next_steps=[]), "sonnet", Path("/nonexistent"))
        self.assertEqual(result, {"status": "Nothing ticked to hand off"})

    def test_no_answer_is_reported_not_raised(self):
        result = mc.follow_up(dict(MEETING, next_steps=["Claude: x"]), "sonnet", Path("/nonexistent"),
                              run=fake_run("", code=1))
        self.assertIn("didn't answer", result["status"])


if __name__ == "__main__":
    unittest.main()
