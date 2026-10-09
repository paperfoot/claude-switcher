import json
import os
import stat
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import tempfile
import unittest
from unittest import mock

from bridge import event_log


ALLOWED_EVENTS = (
    "switch_started",
    "switch_finished",
    "browser_profile_finished",
    "native_error",
    "browser_error",
)


def _records_on_disk(base: Path) -> list[dict]:
    records: list[dict] = []
    for path in (base / "events.jsonl.1", base / "events.jsonl"):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                records.append(value)
    return records


class EventLogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tmp_path = Path(temporary.name)

    def test_emit_accepts_allowed_events_and_fields(self):
        for event in ALLOWED_EVENTS:
            with self.subTest(event=event):
                self._check_allowed_event(self.tmp_path, event)

    def _check_allowed_event(self, tmp_path: Path, event: str) -> None:
        base = tmp_path / "private-log"

        event_log.emit(
            base,
            event,
            scope="chrome",
            ok=True,
            partial=False,
            rolledBack=True,
            browserReady=False,
            profileCount=2,
            expectedProfiles=3,
            durationMs=17,
        )

        record = event_log.recent(base, limit=1)[0]
        assert record["event"] == event
        assert record["scope"] == "chrome"
        assert record["ok"] is True
        assert record["partial"] is False
        assert record["rolledBack"] is True
        assert record["browserReady"] is False
        assert record["profileCount"] == 2
        assert record["expectedProfiles"] == 3
        assert record["durationMs"] == 17


    def test_emit_silently_discards_unknown_events_and_invalid_fields(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"
        event_log.emit(base, "switch_started", durationMs=1)

        event_log.emit(base, "account_email_changed", email="nobody@example.invalid")
        event_log.emit(
            base,
            "switch_finished",
            scope="safari",
            ok=1,
            partial="false",
            rolledBack=None,
            browserReady=[],
            profileCount=True,
            expectedProfiles=-1,
            durationMs="8",
            arbitrary="discard me",
        )

        records = event_log.recent(base, limit=20)
        assert [record["event"] for record in records] == [
            "switch_started",
            "switch_finished",
        ]
        invalid_record = records[-1]
        for field in (
            "scope",
            "ok",
            "partial",
            "rolledBack",
            "browserReady",
            "profileCount",
            "expectedProfiles",
            "durationMs",
            "arbitrary",
        ):
            assert field not in invalid_record


    def test_secret_shaped_values_are_never_persisted(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"
        fake_values = {
            "email": "private.person@example.invalid",
            "cookies": "session=FAKE_COOKIE_9f617",
            "token": "sk_live_FAKE_TOKEN_86c4",
            "url": "https://user:FAKE_PASSWORD@example.invalid/private?token=FAKE",
            "exception": "Authorization: Bearer FAKE_BEARER_1148",
            "message": "reset code FAKE-302991",
        }

        event_log.emit(
            base,
            "browser_error",
            scope="claude",
            error="sk_live_FAKE_ERROR_SLOT_65b1",
            failureStep="https://example.invalid/?secret=FAKE_STEP_SLOT_592f",
            **fake_values,
        )

        record = event_log.recent(base, limit=1)[0]
        assert record["event"] == "browser_error"
        assert record["scope"] == "claude"
        assert record["error"] == "unknown_error"
        assert "failureStep" not in record
        for field in fake_values:
            assert field not in record

        persisted = (base / "events.jsonl").read_text(encoding="utf-8")
        for secret in (*fake_values.values(), "FAKE_ERROR_SLOT_65b1", "FAKE_STEP_SLOT_592f"):
            assert secret not in persisted


    def test_log_directory_and_files_are_private(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"
        event_log.emit(base, "switch_started")

        assert stat.S_IMODE(base.stat().st_mode) == 0o700
        assert stat.S_IMODE((base / "events.jsonl").stat().st_mode) == 0o600


    def test_emit_is_durable_across_processes(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"
        repository = Path(__file__).resolve().parent.parent
        script = (
            "from pathlib import Path; "
            "from bridge.event_log import emit; "
            "emit(Path(__import__('sys').argv[1]), 'switch_finished', ok=True, durationMs=43)"
        )

        subprocess.run(
            [sys.executable, "-c", script, os.fspath(base)],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )

        record = event_log.recent(base, limit=1)[0]
        assert record["event"] == "switch_finished"
        assert record["ok"] is True
        assert record["durationMs"] == 43


    def test_rotation_keeps_one_bounded_backup_and_recent_is_chronological(self) -> None:
        tmp_path = self.tmp_path
        patch = mock.patch.object(event_log, "MAX_BYTES", 512)
        patch.start()
        self.addCleanup(patch.stop)
        base = tmp_path / "private-log"

        for index in range(40):
            event_log.emit(
                base,
                "browser_profile_finished",
                scope="chrome",
                ok=True,
                profileCount=index,
                durationMs=index,
            )

        current = base / "events.jsonl"
        backup = base / "events.jsonl.1"
        assert current.is_file()
        assert backup.is_file()
        assert not (base / "events.jsonl.2").exists()
        assert stat.S_IMODE(current.stat().st_mode) == 0o600
        assert stat.S_IMODE(backup.stat().st_mode) == 0o600

        lines = current.read_bytes().splitlines() + backup.read_bytes().splitlines()
        largest_entry = max(len(line) + 1 for line in lines)
        assert current.stat().st_size <= event_log.MAX_BYTES + largest_entry
        assert backup.stat().st_size <= event_log.MAX_BYTES + largest_entry

        expected = _records_on_disk(base)
        actual = event_log.recent(base, limit=200)
        assert actual == expected
        assert actual[-1]["durationMs"] == 39
        assert [record["durationMs"] for record in actual] == sorted(
            record["durationMs"] for record in actual
        )


    def test_recent_skips_malformed_lines_and_bounds_limit(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"
        event_log.emit(base, "switch_started", durationMs=1)
        with (base / "events.jsonl").open("ab") as handle:
            handle.write(b"{malformed json}\n\n[]\n42\n")
        event_log.emit(base, "switch_finished", durationMs=2)

        assert [record["durationMs"] for record in event_log.recent(base, limit=20)] == [1, 2]
        assert [record["durationMs"] for record in event_log.recent(base, limit=0)] == [2]

        monkeypatch_max = event_log.MAX_BYTES
        try:
            event_log.MAX_BYTES = 10_000_000
            for index in range(3, 208):
                event_log.emit(base, "switch_finished", durationMs=index)
            bounded = event_log.recent(base, limit=10_000)
            assert len(bounded) == 200
            assert bounded[-1]["durationMs"] == 207
        finally:
            event_log.MAX_BYTES = monkeypatch_max


    def test_emit_never_raises_when_storage_is_unusable(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "not-a-directory"
        base.write_text("occupied", encoding="utf-8")

        event_log.emit(base, "switch_started", ok=True)

        assert base.read_text(encoding="utf-8") == "occupied"


    def test_concurrent_writers_produce_whole_json_records(self) -> None:
        tmp_path = self.tmp_path
        base = tmp_path / "private-log"

        def write(index: int) -> None:
            event_log.emit(
                base,
                "browser_profile_finished",
                scope="chrome",
                ok=True,
                profileCount=index,
                durationMs=index,
            )

        with ThreadPoolExecutor(max_workers=20) as executor:
            list(executor.map(write, range(20)))

        raw_lines = (base / "events.jsonl").read_text(encoding="utf-8").splitlines()
        parsed = [json.loads(line) for line in raw_lines]
        assert len(parsed) == 20
        assert all(isinstance(record, dict) for record in parsed)
        assert {record["durationMs"] for record in parsed} == set(range(20))
