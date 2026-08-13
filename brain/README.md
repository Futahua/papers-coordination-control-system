# Account B CLI BRAIN

This folder separates the inexpensive headless development loop from the creator-facing
Codex Desktop task.

## Roles

- Account A / Codex Desktop is the Manager. It talks with the creator, records product
  judgment and requests an eye check. It does not continuously poll workers or reread logs.
- Account B / Codex CLI is the BRAIN. It performs one bounded coordination decision, then
  exits. It delegates implementation and routine tests to OpenCode workers.
- Winter, Gazelle, RoketPuncha and Ning are the worker pool. Their compact reports are the
  normal evidence surface. Full reasoning logs are exceptional diagnostics only.
- `brain-control.ps1` is the deterministic controller. Waiting and status checks consume no
  Codex allowance.

## First setup

1. Double-click `BRAIN-B-LOGIN.cmd` and sign in with the new Plus account. This uses the
   isolated `D:\Programs\CodexBrainB` home and does not replace Account A's login.
2. Double-click `BRAIN-BUDGET.cmd`. Copy the weekly remaining percentage and reset time from
   the Account B usage dashboard or from `/status` in its CLI.
3. Put the next creator request in `manager-request.md` and change `Status` to `READY`.
4. Double-click `BRAIN-RUN-ONCE.cmd`. This makes one Account B decision and exits.
5. Use `BRAIN-STATUS.cmd` whenever desired. It is mechanical and costs no model usage.

`BRAIN-WATCH.cmd` may remain open for long AFK periods. It does not stream logs or repeatedly
call Codex. It invokes one decision only when a READY request changes or when an active wave
transitions to all reports ready or any lane needs attention. Attention is immediate even while
unrelated lanes remain working. Event fingerprints prevent repeat
charges for an unchanged state.

Before each invocation, the controller builds `brain-input-snapshot.md` with only the request,
budget, wave, registry and active compact reports (each capped at 12 KB). Account B starts in
this controller folder, not in a product repository, so routine cycles do not auto-load large
product manuals. Full CLI event output goes into `brain/runs`; the console shows only the final
checkpoint.

Routing invocations disable apps, browsers, computer use, image generation, plugins,
multi-agent, goals, hooks and skill discovery. Account B retains shell access for bridge and
manifest work, while optional tool schemas do not inflate every routine turn.

## Budget behavior

The controller computes:

`safe daily pace = max(0, remaining percent - protected reserve) / days until reset`

Every actual BRAIN decision uses Sol with low/light reasoning. Allowance is reserved by invoking only on a new
fingerprinted coordination event; waiting, status checks and dispatch are deterministic and
model-free. There is no fixed daily invocation ceiling; live allowance and the protected
reserve govern continuation. Model and reasoning effort do not change automatically. At or below the
protected reserve, automatic runs stop and require an explicit override.

The watcher records Account B invocation counts for visibility but does not impose a fixed
daily ceiling. Fingerprints prevent unchanged-event repetition, and the live allowance plus
protected reserve govern continuation.
Use `BRAIN-START.cmd` to start the watcher invisibly and `BRAIN-STOP.cmd` to stop only its
exact recorded process. Worker sessions are never stopped by either command.

The CLI currently exposes remaining limits through interactive `/status` and the usage
dashboard; there is no dependable local machine-readable percentage used here. Update
`budget.json` after checking either surface. Authentication files never enter this folder.
Nothing belonging to this controller is stored on the C: drive.
The controller also points its child process TEMP and TMP at the same D: home. Its private
Codex CLI package is installed under `D:\Programs\CodexBrainB\runtime`; the
already-installed Windows and Node executables may themselves reside on C:, but controller
configuration, authentication, session data, npm cache and temporary output are directed to
D:.
