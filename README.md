# Papers Coordination Control System

Windows-first controller and read-only local dashboard for coordinating one persistent Codex CLI **BRAIN** with persistent OpenCode worker sessions.

This is a complete control-plane backup: the event-driven BRAIN controller, worker dispatcher, watcher, terminal views, and dashboard. The only excluded material is live/private runtime state—credentials, session IDs, messages, logs, reports, product code, and executable deployments.

## Architecture

```text
Creator / Desktop Codex
        │ manager request + visual judgement
        ▼
Codex CLI BRAIN ── bounded decision ──► persistent OpenCode workers
        │                                      │
        ├── wave.json / mailbox / reports ◄────┘
        │
        ├── event-fingerprinted watcher
        ▼
read-only dashboard + terminal status/live feed
```

- `brain/brain-control.ps1` — deterministic event gate, bounded CLI BRAIN turn, persistent BRAIN session, safe dispatch.
- `brain/watcher-supervisor.ps1` / `brain/watcher-loop.cmd` — one isolated watcher check per minute; no polling model calls for unchanged evidence.
- `brain/worker-run.ps1` / `worker-hub.ps1` — dispatch, wake, acknowledgement, and mailbox transport for worker sessions.
- `dashboard/` — local, read-only browser dashboard. When present, it reads native OpenCode reasoning parts from the OpenCode SQLite store in read-only mode.
- `worker_live_status.ps1` / `worker_live_feed.py` — terminal status and live-feed views.

## Requirements

1. Windows 10/11 with PowerShell 5+.
2. Git, Python 3.11+ and the Codex CLI available on `PATH`.
3. OpenCode desktop/CLI, with one persistent session per worker.
4. A separately authenticated Codex CLI account for the BRAIN. Do **not** share the Desktop Codex account/home if you want independent usage telemetry.
5. A target task repository and one authoritative BRAIN-to-worker handoff document.

## Recreate the installation

The original installation lives at a coordination root such as:

```text
D:\PapersControl\logs\
├── brain\
├── dashboard\
├── workers\winter\{dispatch,logs,reports}\
├── workers\gazelle\{dispatch,logs,reports}\
├── workers\roketpuncha\{dispatch,logs,reports}\
└── workers\ning\{dispatch,logs,reports}\
```

Clone this repository into that root, then update the absolute paths at the top of the PowerShell/Python files to match your coordination root and task repository. The live version intentionally uses explicit paths so that scheduled tasks and background processes cannot silently target a different project.

### 1. Create the private runtime state

These files are intentionally ignored by Git. Create them locally from the following shapes:

`worker-registry.json`

```json
{
  "winter": { "displayName": "Winter", "sessionId": "ses_your_opencode_session", "log": "workers\\winter\\logs\\winter-1.log", "curatedLog": "workers\\winter\\logs\\winter-general.log" },
  "gazelle": { "displayName": "Gazelle", "sessionId": "ses_your_opencode_session", "log": "workers\\gazelle\\logs\\gazelle-1.log", "curatedLog": "workers\\gazelle\\logs\\gazelle-general.log" },
  "roketpuncha": { "displayName": "RoketPuncha", "sessionId": "ses_your_opencode_session", "log": "workers\\roketpuncha\\logs\\roketpuncha-1.log", "curatedLog": "workers\\roketpuncha\\logs\\roketpuncha-general.log" },
  "ning": { "displayName": "Ning", "sessionId": "ses_your_opencode_session", "log": "workers\\ning\\logs\\ning-1.log", "curatedLog": "workers\\ning\\logs\\ning-general.log" }
}
```

`brain/budget.json`

```json
{ "remainingPercent": 100, "reservePercent": 20, "resetAt": "2026-12-31T00:00:00+00:00", "updatedAt": "2026-01-01T00:00:00+00:00" }
```

`brain/wave.json`

```json
{
  "waveId": "001-first-bounded-lane",
  "status": "DISPATCH_READY",
  "workers": {
    "gazelle": {
      "active": true,
      "lane": "bounded implementation lane",
      "assignment": "LEAD HINT: mechanism=…; first=…; avoid=…; proof=…; stop=…. TASK: …",
      "report": "workers/gazelle/reports/gazelle-001.md",
      "status": "DISPATCH_READY"
    }
  }
}
```

Also create these empty or initial files:

```text
worker-mailbox.jsonl
brain/brain-session.json       # created automatically after first successful BRAIN turn
brain/controller-state.json    # created automatically
brain/watcher.json             # created automatically
brain/manager-request.md       # Status: DONE until you have an approved request
brain/BRAIN-WORKER.txt         # authoritative EOF assignment for the active wave
brain/current-truth.md         # concise, current project truth
brain/eye-check-gate.json      # gates visual check until exhaustive implementation
```

Use the checked-in `brain/brain-instructions.md`, `brain/NEW-MANAGER-HANDOFF.md`, and `WORKER-HUB.md` as the operating contract.

### 2. Create an isolated BRAIN CLI home

The supplied scripts expect an isolated home, e.g. `D:\Programs\CodexBrainB`. Create it and authenticate the Codex CLI there:

```powershell
New-Item -ItemType Directory -Force D:\Programs\CodexBrainB | Out-Null
$env:CODEX_HOME = 'D:\Programs\CodexBrainB'
codex login
```

Run `BRAIN-BUDGET.cmd` and write the observed remaining percentage/reset into `brain/budget.json`. This is deliberately manual because the interactive usage UI is the reliable source of truth.

### 3. Establish worker sessions

Create/open one OpenCode session per worker and place its `ses_…` ID in `worker-registry.json`. Workers must operate in their persistent session, report compact evidence, and ping `brain` through `worker-hub.ps1`; they must not merely create documentation and stop.

### 4. Run locally

```powershell
# Dashboard (read-only, localhost:8765)
.\worker-dashboard.cmd

# Optional terminal status/live feed
.\worker-status.cmd
.\worker-live-feed.cmd

# Start the one-minute BRAIN watcher
.\BRAIN-START.cmd

# Inspect without consuming a BRAIN turn
.\BRAIN-STATUS.cmd
```

The dashboard binds only to `127.0.0.1` by default. If exposing it through Tailscale, use a reverse proxy or a deliberate, authenticated bind change; do not publish the control surface directly to the internet.

## Operating model

1. Desktop manager records product judgement in `brain/manager-request.md` and changes `Status` to `READY`.
2. The watcher calculates a stable fingerprint of wave/request/compact evidence. Unchanged state does not invoke the model.
3. The BRAIN performs one bounded coordination turn, writes a checkpoint, dispatches only authoritative EOF assignments, and exits.
4. Workers stay in persistent sessions, complete their lane, write a compact report, and ping the BRAIN.
5. The BRAIN reviews real completion evidence and continues only the smallest justified next lane. It must not request an eye check until the exhaustive agenda/gate allows it.

## Verification

```powershell
Set-Location dashboard
python -m unittest dashboard_server_test.py
```

Then run `brain/system-self-test.ps1` from the coordination root before enabling the watcher.

## Public-repository safety

Never commit runtime state, OpenCode/Codex authentication, `ses_…` IDs, worker/BRAIN reasoning, reports, mailbox messages, your product repository, screenshots, or executable backups. `.gitignore` enforces this boundary for the normal live directories.

## License

MIT. See [LICENSE](LICENSE).
