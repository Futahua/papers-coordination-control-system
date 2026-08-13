import datetime as dt
import glob
import json
import os
import sqlite3
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
REGISTRY = os.path.join(ROOT, "worker-registry.json")
DB = "file:C:/Users/admin/.local/share/opencode/opencode.db?mode=ro"
FEED_LOG = os.path.join(ROOT, "worker-live-feed.log")
BRAIN_ROOT = os.path.join(ROOT, "brain")
BRAIN_RUNS = os.path.join(BRAIN_ROOT, "runs")
BRAIN_CHECKPOINT = os.path.join(BRAIN_ROOT, "brain-checkpoint.md")
POLL_SECONDS = 0.35
BRAIN_REPLAY_BYTES = 48 * 1024


def configure_console():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)


def load_workers():
    with open(REGISTRY, "r", encoding="utf-8") as handle:
        raw = json.load(handle)
    workers = []
    for key, value in raw.items():
        if key == "brain" or not value.get("sessionId"):
            continue
        workers.append(
            {
                "key": key,
                "name": value["displayName"],
                "session": value["sessionId"],
            }
        )
    return workers


def connect():
    con = sqlite3.connect(DB, uri=True, timeout=1.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA query_only=ON")
    con.execute("PRAGMA busy_timeout=1000")
    return con


def decode(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {}


def latest_user_start(con, session_id):
    rows = con.execute(
        "SELECT time_created, data FROM message WHERE session_id=? ORDER BY time_created DESC LIMIT 30",
        (session_id,),
    ).fetchall()
    for row in rows:
        data = decode(row["data"])
        if data.get("role") == "user":
            return int(row["time_created"])
    return 0


def compact_json(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, default=str)


def render_part(data):
    kind = data.get("type", "unknown")
    if kind in ("reasoning", "text"):
        return kind.upper(), str(data.get("text") or "")
    if kind == "tool":
        state = data.get("state") or {}
        payload = {
            "tool": data.get("tool"),
            "status": state.get("status"),
            "input": state.get("input"),
        }
        if "output" in state:
            payload["output"] = state.get("output")
        if "error" in state:
            payload["error"] = state.get("error")
        return "TOOL", compact_json(payload)
    if kind == "step-finish":
        payload = {
            "reason": data.get("reason"),
            "tokens": data.get("tokens"),
            "cost": data.get("cost"),
        }
        return "STEP", compact_json(payload)
    if kind == "step-start":
        return "STEP", "started"
    return kind.upper(), compact_json(data)


class Feed:
    def __init__(self, workers):
        self.workers = workers
        self.turn_starts = {}
        self.seen = {}
        self.headers = set()
        self.brain_file = None
        self.brain_offset = 0
        self.brain_checkpoint = None
        self.log = open(FEED_LOG, "a", encoding="utf-8", buffering=1)

    def emit(self, text=""):
        print(text, flush=True)
        self.log.write(text + "\n")

    def start_banner(self):
        self.emit("=" * 78)
        self.emit(f"PAPERS WORKERS + CLI BRAIN LIVE FEED — {dt.datetime.now().isoformat(timespec='seconds')}")
        self.emit("Read-only. Replays current worker turns and the latest bounded BRAIN tail, then follows updates.")
        self.emit("Ctrl+C closes this feed only; it does not stop workers or the BRAIN watcher.")
        self.emit("=" * 78)

    def latest_brain_run(self):
        candidates = [
            path
            for path in glob.glob(os.path.join(BRAIN_RUNS, "*.log"))
            if os.path.basename(path) not in ("watcher.out.log", "watcher.err.log")
        ]
        if not candidates:
            return None
        return max(candidates, key=lambda path: os.path.getmtime(path))

    def poll_brain_run(self):
        path = self.latest_brain_run()
        if path is None:
            return
        if path != self.brain_file:
            self.brain_file = path
            size = os.path.getsize(path)
            self.brain_offset = max(0, size - BRAIN_REPLAY_BYTES)
            if self.brain_offset and self.brain_offset % 2:
                self.brain_offset -= 1
            stamp = dt.datetime.fromtimestamp(os.path.getmtime(path)).strftime("%H:%M:%S")
            self.emit(f"\n{'=' * 20} CLI BRAIN · RUN STREAM · {os.path.basename(path)} [{stamp}] {'=' * 8}")
            if self.brain_offset:
                self.emit(f"[initial replay capped to the latest {BRAIN_REPLAY_BYTES // 1024} KB]")

        size = os.path.getsize(path)
        if size < self.brain_offset:
            self.brain_offset = 0
        if size == self.brain_offset:
            return
        with open(path, "rb") as handle:
            handle.seek(self.brain_offset)
            chunk = handle.read(size - self.brain_offset)
        self.brain_offset = size
        if chunk.startswith((b"\xff\xfe", b"\xfe\xff")):
            text = chunk.decode("utf-16", errors="replace")
        elif chunk and chunk.count(b"\x00") > len(chunk) // 5:
            text = chunk.decode("utf-16-le", errors="replace")
        else:
            text = chunk.decode("utf-8", errors="replace")
        if text:
            print(text, end="" if text.endswith("\n") else "\n", flush=True)
            self.log.write(text)
            if not text.endswith("\n"):
                self.log.write("\n")

    def poll_brain_checkpoint(self):
        try:
            with open(BRAIN_CHECKPOINT, "r", encoding="utf-8", errors="replace") as handle:
                body = handle.read().strip()
        except FileNotFoundError:
            return
        if not body or body == self.brain_checkpoint:
            return
        self.brain_checkpoint = body
        self.emit(f"\n{'=' * 20} CLI BRAIN · CHECKPOINT {'=' * 20}")
        self.emit(body)

    def poll_brain(self):
        self.poll_brain_run()
        self.poll_brain_checkpoint()

    def refresh_turn_start(self, con, worker):
        latest = latest_user_start(con, worker["session"])
        old = self.turn_starts.get(worker["session"])
        if old is None:
            self.turn_starts[worker["session"]] = latest
        elif latest > old:
            self.turn_starts[worker["session"]] = latest
            self.emit(f"\n{'=' * 20} {worker['name']} · NEW TURN {'=' * 20}")

    def poll_worker(self, con, worker):
        self.refresh_turn_start(con, worker)
        start = self.turn_starts.get(worker["session"], 0)
        rows = con.execute(
            "SELECT id, time_created, time_updated, data FROM part "
            "WHERE session_id=? AND time_created>=? ORDER BY time_created, id",
            (worker["session"], start),
        ).fetchall()
        for row in rows:
            data = decode(row["data"])
            label, rendered = render_part(data)
            key = (worker["session"], row["id"])
            previous = self.seen.get(key, "")
            if rendered == previous:
                continue
            stamp = dt.datetime.fromtimestamp(row["time_created"] / 1000).strftime("%H:%M:%S")
            if key not in self.headers:
                self.emit(f"\n[{stamp}] {worker['name'].upper()} · {label}")
                self.headers.add(key)
                delta = rendered
            elif rendered.startswith(previous):
                delta = rendered[len(previous) :]
            else:
                self.emit(f"\n[{stamp}] {worker['name'].upper()} · {label} UPDATED")
                delta = rendered
            if delta:
                # Preserve complete exposed text/tool output while keeping worker blocks legible.
                print(delta, end="" if delta.endswith("\n") else "\n", flush=True)
                self.log.write(delta)
                if not delta.endswith("\n"):
                    self.log.write("\n")
            self.seen[key] = rendered

    def run(self):
        self.start_banner()
        while True:
            try:
                with connect() as con:
                    for worker in self.workers:
                        self.poll_worker(con, worker)
                self.poll_brain()
            except sqlite3.Error as exc:
                self.emit(f"[database temporarily unavailable: {exc}]")
            except OSError as exc:
                self.emit(f"[BRAIN feed temporarily unavailable: {exc}]")
            time.sleep(POLL_SECONDS)


def main():
    configure_console()
    feed = Feed(load_workers())
    try:
        feed.run()
    except KeyboardInterrupt:
        feed.emit("\nLive feed closed. Workers were not stopped.")


if __name__ == "__main__":
    main()
