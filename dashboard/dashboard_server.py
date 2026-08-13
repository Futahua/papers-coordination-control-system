#!/usr/bin/env python3
"""Local-only browser dashboard for the Papers worker/BRAIN coordination tools.

Read-only aggregator over the coordination log directory. Combines the
information and live behaviour of worker-status.cmd (per-member authoritative
state/report) and worker-live-feed.cmd (incremental per-member live stream
previews) plus a distinct CLI BRAIN panel (watcher/decision state, checkpoint,
incremental run stream, live usage telemetry).

Sources are read-only: worker-registry.json, worker-mailbox.jsonl,
workers/<key>/logs/<key>.log (each member's own stream), workers/<key>/reports/*.md
(the authoritative latest report), and brain/*.json / brain/brain-checkpoint.md /
brain/runs/*.log. Worker data is never duplicated or mutated.

Standard library only (http.server, sqlite3 not required). Binds 127.0.0.1 on a
deterministic documented port. Clean shutdown via GET /api/shutdown or Ctrl+C.
"""

import datetime as dt
import glob
import json
import os
import re
import subprocess
import sqlite3
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
DEFAULT_PORT = 8765

MAX_STREAM_BYTES = 12 * 1024   # bounded dashboard preview per response
MAX_LINES = 80                 # dashboard preview, not a transcript viewer
MAX_MAILBOX_MESSAGE = 160
MAX_CHECKPOINT = 600
WORKERS = ["winter", "gazelle", "roketpuncha", "ning"]
# This is the exact store consumed by the OpenCode desktop session UI.  The
# dashboard opens it read-only and never creates or changes a worker record.
OPENCODE_DB = os.path.join(os.path.expanduser("~"), ".local", "share", "opencode", "opencode.db")


def running_worker_sessions():
    """Return session ids owned by live OpenCode workers in one bounded query."""
    if os.name != "nt":
        return set()
    command = (
        "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
        "Get-CimInstance Win32_Process | "
        "Where-Object { $_.Name -eq 'opencode.exe' } | "
        "Select-Object -ExpandProperty CommandLine | ConvertTo-Json -Compress"
    )
    try:
        startup = subprocess.STARTUPINFO()
        startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup.wShowWindow = 0
        raw = subprocess.check_output(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
            text=True, encoding="utf-8", errors="replace", timeout=4, startupinfo=startup,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        lines = json.loads(raw) if raw.strip() else []
        if isinstance(lines, str):
            lines = [lines]
        sessions = set()
        for line in lines or []:
            sessions.update(re.findall(r"\bses_[A-Za-z0-9]+\b", str(line)))
        return sessions
    except Exception:
        return set()


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except Exception:
        return None


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except Exception:
        return ""


def now_iso():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def decode_stream_chunk(chunk):
    """Decode UTF-8 worker logs and UTF-16LE PowerShell redirect logs."""
    if chunk.startswith(b"\xff\xfe") or (len(chunk) >= 8 and chunk[1::2].count(0) > len(chunk[1::2]) // 3):
        return chunk.decode("utf-16", errors="replace")
    return chunk.decode("utf-8", errors="replace")


def repair_windows_mojibake(text):
    """Repair old CP-1253/UTF-8 double-decoding in redirected CLI output."""
    substitutions = {
        "ΓÇÖ": "’", "ΓÇö": "—", "ΓÇô": "–", "ΓÇ£": "“",
        "ΓÇ¥": "”", "ΓÇá": "…", "ΓÇ░": "≤",
    }
    for broken, clean in substitutions.items():
        text = text.replace(broken, clean)
    if "Γ" not in text:
        return text
    try:
        repaired = text.encode("cp1253").decode("utf-8")
        return repaired if repaired.count("�") <= text.count("�") else text
    except UnicodeError:
        return text


def load_registry(root):
    reg = read_json(os.path.join(root, "worker-registry.json")) or {}
    out = {}
    for key in WORKERS:
        value = reg.get(key) or {}
        out[key] = {
            "key": key,
            "name": value.get("displayName") or key.title(),
            "session": value.get("sessionId") or None,
            "log": value.get("log") or f"{key}-1.log",
        }
    return out


def report_info(path):
    if not path or not os.path.isfile(path):
        return None
    title = ""
    for line in read_text(path).splitlines():
        if line.startswith("#"):
            title = line.lstrip("# ").strip()
            break
    return {
        "file": os.path.basename(path),
        "title": title or os.path.basename(path),
        "mtime": dt.datetime.fromtimestamp(os.path.getmtime(path)).isoformat(timespec="seconds"),
        "size": os.path.getsize(path),
    }


def latest_report(root, key):
    folder = os.path.join(root, "workers", key, "reports")
    try:
        files = [os.path.join(folder, name) for name in os.listdir(folder) if name.endswith(".md")]
    except Exception:
        return None
    if not files:
        return None
    return report_info(max(files, key=os.path.getmtime))


def latest_mailbox(root, key, not_before=None):
    path = os.path.join(root, "worker-mailbox.jsonl")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except Exception:
        return None
    acknowledged = set()
    for line in lines:
        try:
            event = json.loads(line)
            if event.get("event") == "ack" and event.get("pingId"):
                acknowledged.add(str(event["pingId"]))
        except Exception:
            continue
    latest = None
    for line in reversed(lines):
        try:
            event = json.loads(line)
        except Exception:
            continue
        if event.get("event") == "ping" and str(event.get("to", "")).lower() == key:
            if str(event.get("id") or "") in acknowledged:
                continue
            if not_before is not None and event.get("at"):
                try:
                    sent_at = dt.datetime.fromisoformat(str(event["at"]))
                    if sent_at < not_before:
                        continue
                except Exception:
                    pass
            kind = str(event.get("kind") or "info").lower()
            # Informational broadcasts are transient.  Attention/correction
            # pings remain visible until coordination resolves them.
            if kind == "info" and event.get("at"):
                try:
                    sent_at = dt.datetime.fromisoformat(str(event["at"]))
                    if (dt.datetime.now().astimezone() - sent_at).total_seconds() > 15 * 60:
                        continue
                except Exception:
                    pass
            latest = {
                "kind": kind,
                "message": (event.get("message") or "")[:MAX_MAILBOX_MESSAGE],
            }
            break
    return latest


def latest_brain_attention(root, key, not_before=None):
    """Latest unacknowledged current-wave blocker sent by this worker to BRAIN."""
    path = os.path.join(root, "worker-mailbox.jsonl")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            events = [json.loads(line) for line in handle if line.strip()]
    except Exception:
        return None
    acknowledged = {str(event.get("pingId")) for event in events if event.get("event") == "ack"}
    for event in reversed(events):
        if event.get("event") != "ping" or str(event.get("id") or "") in acknowledged:
            continue
        if str(event.get("from") or "").lower() != key or str(event.get("to") or "").lower() not in ("brain", "all"):
            continue
        if str(event.get("kind") or "").lower() not in ("blocker", "conflict", "evidence-request", "help"):
            continue
        try:
            if not_before is not None and dt.datetime.fromisoformat(str(event.get("at"))) < not_before:
                continue
        except Exception:
            continue
        return {"kind": "attention", "message": (event.get("message") or "")[:MAX_MAILBOX_MESSAGE]}
    return None


def member_log_path(root, registry, prefer_dispatch=False):
    key = registry["key"]
    if prefer_dispatch:
        dispatch = os.path.join(root, "workers", key, "dispatch")
        try:
            candidates = glob.glob(os.path.join(dispatch, "*.out.log"))
            if candidates:
                output = max(candidates, key=os.path.getmtime)
                error = output[:-8] + ".err.log"
                if os.path.exists(error) and os.path.getsize(output) == 0:
                    try:
                        with open(error, "r", encoding="utf-8", errors="replace") as handle:
                            error_text = handle.read()
                            if "server_is_overloaded" in error_text or "service_unavailable_error" in error_text:
                                return error
                    except Exception:
                        pass
                return output
        except Exception:
            pass
    return os.path.join(root, "workers", key, "logs", registry["log"])


def log_stats(root, registry, prefer_dispatch=False):
    path = member_log_path(root, registry, prefer_dispatch)
    try:
        return {
            "size": os.path.getsize(path),
            "mtime": dt.datetime.fromtimestamp(os.path.getmtime(path)).isoformat(timespec="seconds"),
        }
    except Exception:
        return {"size": 0, "mtime": None}


def stream_tail(path, after=0, max_bytes=MAX_STREAM_BYTES):
    """Bounded incremental tail. after=0 returns the latest max_bytes (aligned to
    a line boundary); a later request with after=<size> returns only new bytes."""
    try:
        size = os.path.getsize(path)
    except Exception:
        return {"after": 0, "next": 0, "size": 0, "lines": []}
    if after < 0:
        after = 0
    if after > size:
        after = size
    read_from = after
    if after == 0 and size > max_bytes:
        read_from = size - max_bytes
    if read_from == size:
        return {"after": after, "next": size, "size": size, "lines": []}
    try:
        with open(path, "rb") as handle:
            handle.seek(read_from)
            chunk = handle.read(size - read_from)
    except Exception:
        return {"after": after, "next": size, "size": size, "lines": []}
    lines = repair_windows_mojibake(decode_stream_chunk(chunk)).splitlines()
    # Drop the partial first line only when we aligned to a bounded-tail offset
    # on the FIRST request (after==0); incremental `after` reads always start at
    # a prior line boundary, so their first line is complete.
    if after == 0 and read_from > 0:
        lines = lines[1:]
    return {"after": after, "next": size, "size": size, "lines": lines[-MAX_LINES:]}


def native_session_parts(session_id, limit=MAX_LINES):
    """Return native renderable OpenCode parts for one session.

    OpenCode updates a part in place while it is streaming.  Therefore this
    deliberately returns the latest bounded set on every request rather than
    pretending a byte-offset log is authoritative; the browser reconciles by
    stable part id and redraws a changed in-progress part exactly as desktop
    does.  ``None`` means the local database is unavailable, allowing the
    existing dispatch-log feed to remain a graceful fallback.
    """
    if not session_id or not os.path.isfile(OPENCODE_DB):
        return None
    try:
        db_uri = "file:" + urllib.parse.quote(OPENCODE_DB.replace("\\", "/")) + "?mode=ro"
        con = sqlite3.connect(db_uri, uri=True, timeout=1)
        try:
            cur = con.cursor()
            cur.execute(
                """
                SELECT p.rowid, p.data, m.data
                FROM part AS p
                JOIN message AS m ON m.id = p.message_id
                WHERE m.session_id = ?
                ORDER BY p.time_created DESC
                LIMIT ?
                """,
                (session_id, limit),
            )
            rows = list(reversed(cur.fetchall()))
        finally:
            con.close()
    except (sqlite3.Error, OSError, ValueError):
        return None

    parts = []
    for rowid, raw, message_raw in rows:
        try:
            part = json.loads(raw)
            message = json.loads(message_raw)
        except (TypeError, json.JSONDecodeError):
            continue
        part_type = str(part.get("type") or "")
        text = part.get("text")
        active = not isinstance((message.get("time") or {}).get("completed"), (int, float))
        if part_type in ("reasoning", "text") and isinstance(text, str) and text.strip():
            parts.append({
                "id": str(rowid), "partId": part.get("id"), "kind": "reasoning",
                "text": text, "active": active,
            })
            continue
        if part_type != "tool":
            continue
        state = part.get("state") if isinstance(part.get("state"), dict) else {}
        input_data = state.get("input") if isinstance(state.get("input"), dict) else {}
        tool = str(part.get("tool") or "tool")
        # This matches the action shown by OpenCode's tool component: the
        # provider's tool name plus its own description/path, never an
        # invented summary of the command.
        detail = str(input_data.get("description") or input_data.get("filePath") or input_data.get("query") or "")
        command = input_data.get("command")
        if not detail and isinstance(command, str):
            detail = command.replace("\r", " ").replace("\n", " ").strip()
        parts.append({
            "id": str(rowid), "partId": part.get("id") or part.get("callID"), "kind": "tool",
            "tool": tool, "status": str(state.get("status") or "pending"),
            "detail": detail[:500], "active": active or str(state.get("status") or "") in ("pending", "running"),
        })
    return parts


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def brain_status(root):
    budget = read_json(os.path.join(root, "brain", "budget.json"))
    controller = read_json(os.path.join(root, "brain", "controller-state.json"))
    watcher = read_json(os.path.join(root, "brain", "watcher.json"))
    wave = read_json(os.path.join(root, "brain", "wave.json"))
    checkpoint = read_text(os.path.join(root, "brain", "brain-checkpoint.md")).strip()
    busy = os.path.exists(os.path.join(root, "brain", "brain-run.lock"))

    watcher_state = str(watcher.get("state") or "UNKNOWN") if watcher else "UNKNOWN"
    # The current watcher is a scheduled one-minute tick, so it deliberately
    # has no resident PID. Its fresh heartbeat is the liveness signal.
    scheduler = bool(watcher and watcher.get("scheduler"))
    if scheduler:
        try:
            heartbeat = dt.datetime.fromisoformat(str(watcher.get("heartbeatAt")))
            # Allow multiple scheduler periods for launch jitter. A live lock
            # is stronger evidence than a heartbeat while IgnoreNew suppresses
            # overlapping ticks during a decision.
            watcher_alive = (dt.datetime.now().astimezone() - heartbeat).total_seconds() < 240 or busy
        except Exception:
            watcher_alive = False
    else:
        watcher_alive = process_alive(watcher.get("pid")) if watcher else False

    if busy:
        state = "WORKING - decision in progress"
    elif watcher_alive and watcher_state == "ERROR":
        state = "ERROR - " + str(watcher.get("lastError") or "watcher error")
    elif watcher_alive and watcher_state == "INVOKING":
        state = "CLAIMING - decision event detected"
    elif watcher_alive:
        state = "WATCHING - waiting for an event"
    else:
        state = "STOPPED - completion events are not handled"

    usage = None
    if budget and budget.get("remainingPercent") is not None and budget.get("resetAt"):
        now = dt.datetime.now().astimezone()
        try:
            reset = dt.datetime.fromisoformat(str(budget["resetAt"]))
        except Exception:
            reset = now + dt.timedelta(days=1)
        try:
            observed = dt.datetime.fromisoformat(str(budget.get("observedAt") or budget.get("updatedAt")))
        except Exception:
            observed = now
        days = max(1.0 / 24.0, (reset - now).total_seconds() / 86400.0)
        usable = max(0.0, float(budget.get("remainingPercent") or 0.0) - float(budget.get("reservePercent") or 0.0))
        age_minutes = (now - observed).total_seconds() / 60.0
        usage = {
            "remainingPercent": budget.get("remainingPercent"),
            "reservePercent": budget.get("reservePercent"),
            "usedPercent": budget.get("usedPercent"),
            "safePacePerDay": round(usable / days, 1),
            "resetAt": reset.isoformat(timespec="seconds"),
            "freshness": "STALE" if age_minutes >= 2 else "live",
            "ageMinutes": round(age_minutes, 1),
            "runsToday": controller_runs_today(root),
        }

    last_decision = None
    if controller and controller.get("lastCompletedAt"):
        last_decision = {
            "at": controller.get("lastCompletedAt"),
            "model": controller.get("model"),
        }

    desktop_action = None
    for line in checkpoint.splitlines():
        if line.lower().startswith("creator action needed:"):
            desktop_action = line.split(":", 1)[1].strip().strip("*").strip()
            break

    # A checkpoint is the last completed BRAIN cycle and can remain on disk while a
    # newer manager correction/wave is already authoritative. Never carry an old
    # desktop ping into a current wave that explicitly revoked it or resumed work.
    wave_status = str(wave.get("status") or "").upper() if wave else ""
    wave_checkpoint = str(wave.get("creatorCheckpoint") or "").lower() if wave else ""
    ping_revoked = (
        "no desktop ping" in wave_checkpoint
        or "do not ping" in wave_checkpoint
        or any(marker in wave_status for marker in (
            "REJECTED", "CORRECTION", "DISPATCH", "WORKING", "ASSIGNED", "BLOCKED"
        ))
    )
    if ping_revoked:
        desktop_action = None

    return {
        "state": state,
        "watcherAlive": watcher_alive,
        "watcherState": watcher_state,
        "busy": busy,
        "wave": (wave.get("waveId"), wave.get("status")) if wave else None,
        "checkpoint": checkpoint[:MAX_CHECKPOINT],
        "desktopAction": desktop_action,
        "lastDecision": last_decision,
        "usage": usage,
        "updatedAt": now_iso(),
    }


def controller_runs_today(root):
    stamp = dt.datetime.now().strftime("%Y%m%d")
    try:
        runs = glob.glob(os.path.join(root, "brain", "runs", f"{stamp}-*.log"))
    except Exception:
        return 0
    return len(runs)


def latest_brain_run(root):
    try:
        candidates = [
            path
            for path in glob.glob(os.path.join(root, "brain", "runs", "*.log"))
            if os.path.basename(path) not in ("watcher.out.log", "watcher.err.log")
        ]
    except Exception:
        return None
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def brain_run_tail(root, after=0):
    path = latest_brain_run(root)
    if not path:
        return {"after": 0, "next": 0, "size": 0, "file": None, "lines": [], "parts": []}
    tail = stream_tail(path, after)
    # Codex BRAIN logs are JSONL transport events rather than an OpenCode
    # database.  Agent messages are the native, user-visible reasoning text
    # available from that transport; preserve them verbatim and leave command
    # metadata out of the reasoning stream.
    readable, parts = [], []
    for position, line in enumerate(tail.get("lines", [])):
        try:
            event = json.loads(line)
        except Exception:
            # Compatibility with a plain-text diagnostic/fallback BRAIN log.
            # These lines are already readable and must remain observable.
            if line.strip():
                readable.append(line)
            continue
        item = event.get("item") if isinstance(event, dict) else None
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        if item_type == "agent_message":
            message = str(item.get("text") or "").strip()
            if message:
                parts.append({"id": str(item.get("id") or f"{tail.get('next')}:{position}"), "kind": "reasoning", "text": message, "active": False})
        elif item_type == "command_execution":
            command = str(item.get("command") or "").replace("\r", " ").replace("\n", " ").strip()
            parts.append({
                "id": str(item.get("id") or f"{tail.get('next')}:{position}"), "kind": "tool", "tool": "command",
                "status": str(item.get("status") or "pending").lower(), "detail": command[:500],
                "active": str(item.get("status") or "") == "in_progress",
            })
        elif item_type == "file_change":
            changes = item.get("changes") if isinstance(item.get("changes"), list) else []
            names = [os.path.basename(str(change.get("path") or "")) for change in changes if isinstance(change, dict)]
            parts.append({
                "id": str(item.get("id") or f"{tail.get('next')}:{position}"), "kind": "tool", "tool": "file change",
                "status": str(item.get("status") or "pending").lower(), "detail": ", ".join(names),
                "active": str(item.get("status") or "") == "in_progress",
            })
    tail["lines"] = readable[-MAX_LINES:]
    tail["parts"] = parts[-MAX_LINES:]
    tail["mode"] = "native-reasoning" if parts else "log-fallback"
    tail["file"] = os.path.basename(path)
    return tail


def build_status(root):
    registry = load_registry(root)
    brain = brain_status(root)
    no_active_lanes = "active lanes: none" in str(brain.get("checkpoint") or "").lower()
    wave = read_json(os.path.join(root, "brain", "wave.json")) or {}
    try:
        wave_started_at = dt.datetime.fromtimestamp(
            os.path.getmtime(os.path.join(root, "brain", "wave.json")),
            tz=dt.datetime.now().astimezone().tzinfo,
        ) - dt.timedelta(seconds=2)
    except Exception:
        wave_started_at = None
    active_workers = {
        key for key, value in (wave.get("workers") or {}).items()
        if isinstance(value, dict) and value.get("active") is True
    }
    if "workers" not in wave:  # compatibility with legacy wave fixtures/state
        active_workers = set(registry)
    members = {}
    running_sessions = running_worker_sessions()
    for key, reg in registry.items():
        lane = (wave.get("workers") or {}).get(key) or {}
        # A verified OpenCode process is stronger than a stale active flag, but
        # never stronger than the lane's explicit terminal result.  A duplicate
        # launcher can leave a persistent session alive and merely produce
        # “standing by” chatter; that is not actual work.
        running = bool(reg.get("session") and reg["session"] in running_sessions)
        lane_complete = str(lane.get("status") or "").upper() in {"LANE_COMPLETE", "COMPLETE", "STOPPED"}
        if lane_complete:
            running = False
        in_wave = ((isinstance(lane, dict) and lane.get("active") is True) or running) and not lane_complete
        if running and not lane_complete:
            active_workers.add(key)
        expected_report = str(lane.get("report") or "")
        expected_path = os.path.join(root, *expected_report.replace("\\", "/").split("/")) if expected_report else None
        report = report_info(expected_path) if expected_path else latest_report(root, key)
        if in_wave and report is None:
            report = {
                "file": os.path.basename(expected_report),
                "title": str(lane.get("lane") or "Current wave report pending"),
                "mtime": None,
                "size": 0,
                "pending": True,
            }
        attention = latest_brain_attention(root, key, wave_started_at) if in_wave else None
        has_report = bool(report and report.get("size", 0) > 0)
        member_state = (("WORKING - draft written" if has_report else "WORKING") if running else ("REPORT READY" if has_report else "NEEDS ATTENTION")) if in_wave else "STANDBY"
        current_log = member_log_path(root, reg, in_wave)
        provider_unavailable = False
        if in_wave and not running and current_log.endswith(".err.log"):
            try:
                with open(current_log, "r", encoding="utf-8", errors="replace") as handle:
                    provider_unavailable = "server_is_overloaded" in handle.read()
            except Exception:
                pass
        if provider_unavailable:
            member_state = "PROVIDER UNAVAILABLE - retry scheduled"
        if attention:
            if not provider_unavailable:
                member_state = "ATTENTION REQUESTED"
        elif in_wave and not running and not has_report:
            stats = log_stats(root, reg, True)
            if stats.get("mtime"):
                try:
                    age = dt.datetime.now().astimezone() - dt.datetime.fromisoformat(stats["mtime"])
                    if age.total_seconds() >= 30 * 60:
                        member_state = "POSSIBLY STALLED"
                except Exception:
                    pass
        members[key] = {
            "key": key,
            "name": reg["name"],
            "session": reg["session"],
            "state": member_state,
            "lane": lane.get("lane") if in_wave else None,
            "report": report,
            "mailbox": None if no_active_lanes or key not in active_workers else (attention or latest_mailbox(root, key, wave_started_at)),
            "log": log_stats(root, reg, in_wave),
        }
    return {"members": members, "brain": brain, "updatedAt": now_iso()}


class DashboardHandler(BaseHTTPRequestHandler):
    root = None

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    def send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_asset(self, name, content_type):
        path = os.path.join(self.root, "dashboard", name)
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except Exception:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        route = parsed.path

        if route == "/":
            self.send_asset("dashboard.html", "text/html; charset=utf-8")
            return
        if route in ("/dashboard.css",):
            self.send_asset("dashboard.css", "text/css; charset=utf-8")
            return
        if route in ("/dashboard.js",):
            self.send_asset("dashboard.js", "text/javascript; charset=utf-8")
            return
        if route == "/api/health":
            self.send_json({"ok": True})
            return
        if route == "/api/status":
            self.send_json(build_status(self.root))
            return
        if route == "/api/stream":
            member = (query.get("member") or [""])[0].lower()
            if member not in WORKERS:
                self.send_json({"error": "unknown member"}, 400)
                return
            after = int((query.get("after") or ["0"])[0] or 0)
            registry = load_registry(self.root)
            wave = read_json(os.path.join(self.root, "brain", "wave.json")) or {}
            lane = (wave.get("workers") or {}).get(member) or {}
            # Opt-in keeps the byte-tail endpoint backwards-compatible for
            # status scripts and diagnostic callers; the dashboard itself
            # always asks for the native stream.
            wants_native = (query.get("native") or [""])[0] == "1"
            native_parts = native_session_parts(registry[member].get("session")) if wants_native else None
            if native_parts is not None:
                # The part text is the exact native reasoning payload from the
                # worker's OpenCode session.  ``after`` is intentionally not
                # used here: active parts are updated in place while streaming.
                self.send_json({
                    "member": member,
                    "file": "OpenCode native reasoning",
                    "mode": "native-reasoning",
                    "after": after,
                    "next": after,
                    "size": len(native_parts),
                    "parts": native_parts,
                    "lines": [],
                })
                return
            path = member_log_path(self.root, registry[member], lane.get("active") is True)
            self.send_json({"member": member, "file": os.path.basename(path), **stream_tail(path, after)})
            return
        if route == "/api/brain-stream":
            after = int((query.get("after") or ["0"])[0] or 0)
            self.send_json(brain_run_tail(self.root, after))
            return
        if route == "/api/shutdown":
            self.send_json({"ok": True, "shutdown": True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self.send_error(404)


def create_server(root, port=DEFAULT_PORT):
    DashboardHandler.root = root
    return ThreadingHTTPServer((HOST, port), DashboardHandler)


def main():
    import sys
    # Assets live in <logs>/dashboard; coordination data lives in <logs>.
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]):
        root = os.path.abspath(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT
    server = create_server(root, port)
    print(f"Papers coordination dashboard: http://{HOST}:{port}")
    print(f"Data root (read-only): {root}")
    print("Stop: open /api/shutdown in the browser, or Ctrl+C here.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
