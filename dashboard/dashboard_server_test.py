#!/usr/bin/env python3
"""Noninteractive tests for the local coordination dashboard.

Uses fixture files in a temporary data root and a live server on an ephemeral
port. No browser, no real worker data, no network beyond 127.0.0.1.
"""

import json
import os
import tempfile
import threading
import unittest
from unittest import mock
import datetime as dt

import dashboard_server as dash


def make_root(tmp):
    root = os.path.join(tmp, "logs")
    os.makedirs(os.path.join(root, "dashboard"))
    os.makedirs(os.path.join(root, "workers", "winter", "logs"))
    os.makedirs(os.path.join(root, "workers", "winter", "reports"))
    os.makedirs(os.path.join(root, "workers", "ning", "logs"))
    os.makedirs(os.path.join(root, "workers", "ning", "reports"))
    os.makedirs(os.path.join(root, "workers", "gazelle", "logs"))
    os.makedirs(os.path.join(root, "workers", "roketpuncha", "logs"))
    os.makedirs(os.path.join(root, "brain", "runs"))
    registry = {
        "brain": {"displayName": "BRAIN"},
        "winter": {"displayName": "Winter", "sessionId": "ses-w", "log": "winter-1.log"},
        "gazelle": {"displayName": "Gazelle", "sessionId": "ses-g", "log": "gazelle-1.log"},
        "roketpuncha": {"displayName": "RoketPuncha", "sessionId": "ses-r", "log": "roketpuncha-1.log"},
        "ning": {"displayName": "Ning", "sessionId": "ses-n", "log": "ning-1.log"},
    }
    with open(os.path.join(root, "worker-registry.json"), "w", encoding="utf-8") as handle:
        json.dump(registry, handle)
    with open(os.path.join(root, "worker-mailbox.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"event": "ping", "to": "ning", "kind": "handoff", "message": "dashboard lane"}) + "\n")
    with open(os.path.join(root, "workers", "ning", "logs", "ning-1.log"), "w", encoding="utf-8") as handle:
        handle.write("ning line one\nning line two\n")
    with open(os.path.join(root, "workers", "winter", "logs", "winter-1.log"), "w", encoding="utf-8") as handle:
        handle.write("winter-only line\n")
    with open(os.path.join(root, "workers", "ning", "reports", "ning-023.md"), "w", encoding="utf-8") as handle:
        handle.write("# NING 023 REPORT\ncontent\n")
    budget = {"remainingPercent": 88, "reservePercent": 20, "usedPercent": 12,
              "resetAt": "2026-08-18T21:05:15+07:00", "observedAt": "2026-08-11T22:00:00+07:00"}
    with open(os.path.join(root, "brain", "budget.json"), "w", encoding="utf-8") as handle:
        json.dump(budget, handle)
    with open(os.path.join(root, "brain", "controller-state.json"), "w", encoding="utf-8") as handle:
        json.dump({"lastCompletedAt": "2026-08-11T22:15:47+07:00", "model": "gpt-5.6-terra"}, handle)
    with open(os.path.join(root, "brain", "watcher.json"), "w", encoding="utf-8") as handle:
        json.dump({"pid": 999999, "state": "WATCHING"}, handle)
    with open(os.path.join(root, "brain", "wave.json"), "w", encoding="utf-8") as handle:
        json.dump({"waveId": "w1", "status": "DISPATCHED"}, handle)
    with open(os.path.join(root, "brain", "brain-checkpoint.md"), "w", encoding="utf-8") as handle:
        handle.write("Outcome: test wave\n")
    with open(os.path.join(root, "brain", "runs", "20260811-120000-gpt-5.6-terra.log"), "w", encoding="utf-8") as handle:
        handle.write("brain run line A\nbrain run line B\n")
    for name in ("dashboard.html", "dashboard.css", "dashboard.js"):
        with open(os.path.join(root, "dashboard", name), "w", encoding="utf-8") as handle:
            handle.write(f"<{name}>")
    return root


class StatusMappingTests(unittest.TestCase):
    def test_live_worker_with_report_is_working_draft_not_report_ready(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            report_dir = os.path.join(root, "workers", "gazelle", "reports")
            os.makedirs(report_dir, exist_ok=True)
            with open(os.path.join(report_dir, "gazelle-current.md"), "w", encoding="utf-8") as handle:
                handle.write("# draft\n")
            with open(os.path.join(root, "brain", "wave.json"), "w", encoding="utf-8") as handle:
                json.dump({"waveId": "w2", "status": "WORKING", "workers": {"gazelle": {"active": True, "report": "workers/gazelle/reports/gazelle-current.md"}}}, handle)
            with mock.patch.object(dash, "running_worker_sessions", return_value={"ses-g"}):
                self.assertEqual(dash.build_status(root)["members"]["gazelle"]["state"], "WORKING - draft written")

    def test_current_correction_wave_revokes_stale_desktop_ping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            with open(os.path.join(root, "brain", "brain-checkpoint.md"), "w", encoding="utf-8") as handle:
                handle.write("Creator action needed: PING DESKTOP MANAGER NOW - true eye check\n")
            with open(os.path.join(root, "brain", "wave.json"), "w", encoding="utf-8") as handle:
                json.dump({
                    "waveId": "033-corrections",
                    "status": "DISPATCH_READY",
                    "creatorCheckpoint": "Progress only. No desktop ping until C1-C5 are resolved."
                }, handle)
            self.assertIsNone(dash.brain_status(root)["desktopAction"])

    def test_current_milestone_wave_retains_desktop_ping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            with open(os.path.join(root, "brain", "brain-checkpoint.md"), "w", encoding="utf-8") as handle:
                handle.write("Creator action needed: PING DESKTOP MANAGER NOW - true eye check\n")
            with open(os.path.join(root, "brain", "wave.json"), "w", encoding="utf-8") as handle:
                json.dump({
                    "waveId": "034-milestone",
                    "status": "MILESTONE_IMPLEMENTATION_READY_FOR_CREATOR_EYE_CHECK",
                    "creatorCheckpoint": "Ready for the single true eye check."
                }, handle)
            self.assertEqual(
                dash.brain_status(root)["desktopAction"],
                "PING DESKTOP MANAGER NOW - true eye check"
            )

    def test_registry_maps_four_members_with_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            reg = dash.load_registry(root)
            self.assertEqual(sorted(reg), ["gazelle", "ning", "roketpuncha", "winter"])
            self.assertEqual(reg["ning"]["name"], "Ning")

    def test_status_has_members_and_latest_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            status = dash.build_status(root)
            self.assertEqual(sorted(status["members"]), ["gazelle", "ning", "roketpuncha", "winter"])
            self.assertEqual(status["members"]["ning"]["report"]["title"], "NING 023 REPORT")
            self.assertIsNone(status["members"]["winter"]["report"])

    def test_mailbox_ping_mapped_to_member(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            status = dash.build_status(root)
            self.assertEqual(status["members"]["ning"]["mailbox"]["kind"], "handoff")

    def test_worker_blocker_to_brain_is_visible_as_attention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            with open(os.path.join(root, "brain", "wave.json"), "w", encoding="utf-8") as handle:
                json.dump({"waveId": "w2", "status": "WORKING", "workers": {"ning": {"active": True}}}, handle)
            event = {"event": "ping", "id": "block-1", "at": dt.datetime.now().astimezone().isoformat(),
                     "from": "ning", "to": "brain", "kind": "blocker", "message": "need a lane decision"}
            with open(os.path.join(root, "worker-mailbox.jsonl"), "a", encoding="utf-8") as handle:
                handle.write(json.dumps(event) + "\n")
            status = dash.build_status(root)
            self.assertEqual(status["members"]["ning"]["state"], "ATTENTION REQUESTED")
            self.assertEqual(status["members"]["ning"]["mailbox"]["kind"], "attention")


class StreamSeparationTests(unittest.TestCase):
    def test_member_streams_are_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            reg = dash.load_registry(root)
            ning = dash.member_log_path(root, reg["ning"])
            winter = dash.member_log_path(root, reg["winter"])
            ning_tail = dash.stream_tail(ning)
            winter_tail = dash.stream_tail(winter)
            self.assertIn("ning line one", "\n".join(ning_tail["lines"]))
            self.assertNotIn("winter-only", "\n".join(ning_tail["lines"]))
            self.assertIn("winter-only", "\n".join(winter_tail["lines"]))

    def test_incremental_after_cursor_returns_only_new_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            reg = dash.load_registry(root)
            ning = dash.member_log_path(root, reg["ning"])
            first = dash.stream_tail(ning, 0)
            self.assertEqual(first["lines"], ["ning line one", "ning line two"])
            second = dash.stream_tail(ning, first["next"])
            self.assertEqual(second["lines"], [])
            with open(ning, "a", encoding="utf-8") as handle:
                handle.write("ning line three\n")
            third = dash.stream_tail(ning, first["next"])
            self.assertEqual(third["lines"], ["ning line three"])

    def test_tail_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            reg = dash.load_registry(root)
            ning = dash.member_log_path(root, reg["ning"])
            with open(ning, "w", encoding="utf-8") as handle:
                for i in range(dash.MAX_LINES + 100):
                    handle.write(f"bulk line {i}\n")
            tail = dash.stream_tail(ning, 0, max_bytes=48 * 1024)
            self.assertLessEqual(len(tail["lines"]), dash.MAX_LINES)
            self.assertNotIn("bulk line 0", tail["lines"][0])


class BrainPayloadTests(unittest.TestCase):
    def test_brain_status_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            brain = dash.brain_status(root)
            self.assertIn(brain["state"], ("WATCHING - waiting for an event", "STOPPED - completion events are not handled"))
            self.assertEqual(brain["wave"][0], "w1")
            self.assertEqual(brain["lastDecision"]["model"], "gpt-5.6-terra")
            self.assertIsNotNone(brain["usage"])
            self.assertEqual(brain["usage"]["remainingPercent"], 88)

    def test_scheduled_heartbeat_has_multi_tick_grace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            heartbeat = dt.datetime.now().astimezone() - dt.timedelta(seconds=180)
            with open(os.path.join(root, "brain", "watcher.json"), "w", encoding="utf-8") as handle:
                json.dump({"scheduler": True, "heartbeatAt": heartbeat.isoformat(), "state": "WATCHING"}, handle)
            self.assertEqual(dash.brain_status(root)["state"], "WATCHING - waiting for an event")

    def test_active_lock_is_working_even_with_stale_heartbeat(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            heartbeat = dt.datetime.now().astimezone() - dt.timedelta(minutes=10)
            with open(os.path.join(root, "brain", "watcher.json"), "w", encoding="utf-8") as handle:
                json.dump({"scheduler": True, "heartbeatAt": heartbeat.isoformat(), "state": "INVOKING"}, handle)
            open(os.path.join(root, "brain", "brain-run.lock"), "w", encoding="utf-8").close()
            self.assertEqual(dash.brain_status(root)["state"], "WORKING - decision in progress")

    def test_stale_heartbeat_without_lock_is_stopped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            heartbeat = dt.datetime.now().astimezone() - dt.timedelta(minutes=10)
            with open(os.path.join(root, "brain", "watcher.json"), "w", encoding="utf-8") as handle:
                json.dump({"scheduler": True, "heartbeatAt": heartbeat.isoformat(), "state": "WATCHING"}, handle)
            self.assertEqual(dash.brain_status(root)["state"], "STOPPED - completion events are not handled")

    def test_brain_run_tail_bounded_incremental(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp)
            first = dash.brain_run_tail(root, 0)
            self.assertTrue(first["file"].endswith(".log"))
            self.assertIn("brain run line A", "\n".join(first["lines"]))
            second = dash.brain_run_tail(root, first["next"])
            self.assertEqual(second["lines"], [])


class HttpApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = make_root(cls._tmp.name)
        cls.server = dash.create_server(cls.root, 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls._tmp.cleanup()

    def http_get(self, path):
        import urllib.request
        return urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5)

    def test_index_serves_html(self):
        with self.http_get("/") as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b"<dashboard.html>", response.read())

    def test_assets_served(self):
        for asset in ("/dashboard.css", "/dashboard.js"):
            with self.http_get(asset) as response:
                self.assertEqual(response.status, 200)

    def test_status_api_is_json_with_four_members_and_brain(self):
        with self.http_get("/api/status") as response:
            self.assertEqual(response.status, 200)
            payload = json.loads(response.read())
            self.assertEqual(sorted(payload["members"]), ["gazelle", "ning", "roketpuncha", "winter"])
            self.assertIn("brain", payload)

    def test_stream_api_separates_and_is_incremental(self):
        with self.http_get("/api/stream?member=ning&after=0") as response:
            self.assertEqual(response.status, 200)
            first = json.loads(response.read())
            self.assertEqual(first["member"], "ning")
            self.assertIn("ning line one", "\n".join(first["lines"]))
        with self.http_get(f"/api/stream?member=ning&after={first['next']}") as response:
            second = json.loads(response.read())
            self.assertEqual(second["lines"], [])

    def test_brain_stream_api(self):
        with self.http_get("/api/brain-stream?after=0") as response:
            self.assertEqual(response.status, 200)
            payload = json.loads(response.read())
            self.assertTrue(payload["file"].endswith(".log"))

    def test_unknown_route_is_404(self):
        import urllib.error
        with self.assertRaises(urllib.error.HTTPError) as context:
            self.http_get("/nope")
        self.assertEqual(context.exception.code, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)
