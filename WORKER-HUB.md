# Worker coordination hub

Double-click `worker-hub.cmd` to refresh automatic logs, send or inspect passive
pings, or explicitly wake a stopped OpenCode worker.

Double-click `worker-status.cmd` for a read-only dashboard that refreshes every
two seconds. A wave is ready for BRAIN review only when every active-wave worker
says `REPORT READY`. `WORKING` means the headless OpenCode continuation is alive;
`STANDBY` means deliberately unused in this wave; `NEEDS ATTENTION` means it
stopped without producing its expected report. Closing the dashboard does not
stop workers.

Double-click `worker-live-feed.cmd` for a combined, read-only streaming console.
It replays each worker's current turn and then polls for incremental reasoning,
response and tool updates. It shows only reasoning text the provider exposes;
encrypted/proprietary reasoning metadata is never printed. Closing the feed does
not stop or alter any worker session. A copy is appended to
`worker-live-feed.log`.

Pings are append-only in `worker-mailbox.jsonl`. Sending a ping does not wake a
session. This prevents two processes from continuing the same active session.
Only use **Wake** after confirming the target worker has stopped.

Workers can send a passive ping directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\worker-hub.ps1 -Action send -From Winter -To Ning -Kind evidence-request -Message "Check the named acceptance row and report only decisive evidence."
```

They can inspect and acknowledge their inbox with `-Action inbox -To Winter`
and `-Action ack -From Winter -Id <ping-id>`.

`BRAIN-WORKER.txt` remains authoritative for assignments and file ownership.
The mailbox cannot grant implementation authority. `gazelle-1.log` is automatic;
`gazelle-general.log` remains a separate curated artifact and is never modified
by the hub.

Each worker owns one nested folder:

- `workers/<worker>/reports/`
- `workers/<worker>/logs/`
- `workers/<worker>/dispatch/`

Do not write worker artifacts to the shared root. The root is reserved for the
clickable coordination launchers and their shared registry/mailbox scripts.
