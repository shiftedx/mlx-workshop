from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.workflow_protocol import ProtocolError, load_journal


FIXTURES = Path(__file__).parent / "fixtures" / "protocol" / "v1"
REQUIRED_FIELDS = {
    "schema_version",
    "run_id",
    "sequence",
    "timestamp",
    "type",
    "stage",
    "payload",
}


def decode_lines(path: Path, *, tolerate_corrupt_tail: bool = False) -> list[dict]:
    events: list[dict] = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            if tolerate_corrupt_tail and index == len(lines) - 1:
                break
            raise
    return events


class ProtocolFixtureTests(unittest.TestCase):
    def assert_v1_journal(self, name: str) -> list[dict]:
        events = decode_lines(FIXTURES / name)
        self.assertTrue(events)
        run_id = events[0]["run_id"]
        for expected_sequence, event in enumerate(events, start=1):
            self.assertEqual(set(event), REQUIRED_FIELDS)
            self.assertEqual(event["schema_version"], 1)
            self.assertEqual(event["run_id"], run_id)
            self.assertEqual(event["sequence"], expected_sequence)
            self.assertTrue(event["timestamp"].endswith("Z"))
            self.assertIsInstance(event["payload"], dict)
        return events

    def test_v1_scenario_fixtures_have_contiguous_valid_envelopes(self) -> None:
        expected_terminal_types = {
            "pass.jsonl": "run.completed",
            "blocked.jsonl": "plan.blocked",
            "progress.jsonl": "resource.pressure",
            "failed.jsonl": "run.state",
            "cancelled.jsonl": "run.cancelled",
        }
        for name, terminal_type in expected_terminal_types.items():
            with self.subTest(name=name):
                events = self.assert_v1_journal(name)
                self.assertEqual(events[-1]["type"], terminal_type)

    def test_corrupt_final_line_recovers_only_complete_events(self) -> None:
        events = decode_lines(FIXTURES / "corrupt-tail.jsonl", tolerate_corrupt_tail=True)
        self.assertEqual([event["sequence"] for event in events], [1, 2])
        self.assertEqual(events[-1]["payload"]["state"], "interrupted")

    def test_unknown_v1_event_preserves_sequence_for_forward_compatibility(self) -> None:
        events = self.assert_v1_journal("unknown-future-event.jsonl")
        self.assertEqual(events[1]["type"], "stage.telemetry-from-a-future-v1-writer")
        self.assertEqual(events[2]["sequence"], 3)

    def test_future_schema_fixture_requires_protocol_mismatch(self) -> None:
        event = decode_lines(FIXTURES / "future-schema.jsonl")[0]
        self.assertGreater(event["schema_version"], 1)

    def test_journal_loader_rejects_invalid_envelope_types_and_timestamps(self) -> None:
        valid = decode_lines(FIXTURES / "pass.jsonl")[0]
        corruptions = (
            {**valid, "sequence": True},
            {**valid, "timestamp": "2026-07-09T22:00:00.000+01:00"},
            {**valid, "type": 7},
            {**valid, "stage": 7},
        )
        for index, event in enumerate(corruptions):
            with self.subTest(index=index), tempfile.TemporaryDirectory() as directory:
                journal = Path(directory) / "events.jsonl"
                journal.write_text(json.dumps(event) + "\n", encoding="utf-8")
                with self.assertRaises(ProtocolError):
                    load_journal(journal, valid["run_id"])


if __name__ == "__main__":
    unittest.main()
