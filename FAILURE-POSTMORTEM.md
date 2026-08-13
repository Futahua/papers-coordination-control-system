# Failure postmortem: August 10–13 coordination run

This is the failure ledger for the first long-running Papers coordination run. It is intentionally blunt. A green test, a generated report, a model response, or a dispatched wave is not a product milestone. The run is successful only when the creator receives a finished, visually correct product.

No private session IDs, credentials, worker transcripts, product source, or creator data are included here.

## Outcome

The control plane kept producing activity for roughly three days, but it did not deliver a trustworthy eye-test build. It repeatedly converted one unresolved native-input problem into new diagnostic waves while reporting `progress`, `DISPATCH_READY`, or `WATCHING`. More than one hundred controller turns were shown during the run. The product remained blocked, workers were frequently idle, and the creator had to keep interpreting and repairing the coordinator itself.

The product was not dead. The automation was no longer an effective manager.

## Confirmed failures

### 1. Manager and BRAIN roles were not kept distinct

- The desktop Codex manager is the creator-facing authority but cannot be pinged mechanically.
- The CLI BRAIN is mechanically reachable and should coordinate workers, but early framing treated the two roles as interchangeable.
- Worker messages therefore sometimes requested an impossible desktop response, while the CLI BRAIN failed to act on work it could handle itself.

Required correction: every action must name its reachable owner. `CLI BRAIN` handles reports, retries, hints, dispatch, and bounded recovery. `DESKTOP MANAGER` is requested only for a genuinely creator-facing decision or a final visual check.

### 2. The BRAIN did not retain enough durable context

- Repeated CLI invocations behaved like fresh agents rereading a thin event summary.
- The active agenda, prior rejections, accepted behavior, and reasons an eye check was forbidden were not reliably present in every turn.
- This produced “dementia”: later turns rediscovered old facts, contradicted earlier judgements, or declared a milestone from a single report.

Required correction: every turn must load one compact `current-truth` document, the unresolved acceptance ledger, the active wave, and the last decision receipt. A session ID is not a substitute for durable truth.

### 3. The event watcher was unreliable and falsely authoritative

- The watcher stopped without a truthful terminal state.
- The supervisor repeatedly restarted an absent watcher, producing restart storms.
- Status could say `WATCHING` even when completion events would not be handled.
- A prior claim could remain incomplete and require a manager retry without a deterministic recovery path.
- Polling and process-presence checks were confused with proof that the control loop was healthy.

Required correction: health is a lease with an owner PID, heartbeat, last successful event fingerprint, last completed decision, and explicit degraded state. A stopped or duplicate process must never be rendered as healthy.

### 4. Retry storms consumed turns without increasing evidence

- The same blocker was repackaged into many sequential waves.
- One incident produced about seventeen reruns; the run eventually displayed more than one hundred controller invocations.
- New wave numbers and new report filenames created an illusion of progress while the underlying blocker was unchanged.

Required correction: fingerprint the blocker and evidence. After two unchanged failures, stop automatic redispatch, synthesize the shared cause once, and change mechanism or escalate. Never mint a new wave solely to rename the same failure.

### 5. Usage telemetry was wrong, stale, and mixed across accounts

- The dashboard displayed percentages that disagreed with the active Codex account.
- Old-account telemetry reappeared after authentication changed.
- Stale telemetry was presented alongside live state without enough separation.
- Informational controller-run counts looked like model-usage counts.

Required correction: telemetry must include the exact isolated CLI home/account identity, source timestamp, freshness, and source type. If identity cannot be proven, display `unknown`; never merge or guess.

### 6. Model policy was not enforced reliably

- The requested BRAIN model changed between Terra and Sol-light, and the dashboard/history did not make the effective policy trustworthy.
- High-quality models were used for repetitive rereads while workers lacked useful up-front guidance.
- The model could be capable yet still make poor decisions because the prompt omitted current product truth.

Required correction: record requested model, effective model, reasoning level, and purpose on each decision receipt. Model choice never compensates for missing context or a bad retry policy.

### 7. Eye checks were requested prematurely and repeatedly

- The system requested “early visual eye check” and later “true eye check” while the authoritative problem agenda remained unresolved.
- A report-ready state was treated as visual acceptance.
- The creator was asked to spend scarce attention on builds where only a button outline had changed or where obvious known defects remained.
- The action prompt did not explain exactly what to inspect or what had already been proven.

Required correction: the eye-check gate is fail-closed. It opens only when every recorded problem has implementation evidence, automated evidence where applicable, and an explicit BRAIN reconciliation. The prompt must list the exact behaviors to inspect. No “scrutiny for scrutiny’s sake.”

### 8. Worker completion did not reliably trigger BRAIN action

- Reports could be ready while the BRAIN remained idle or “farted.”
- Workers sometimes created documents but did not ping the BRAIN.
- The dashboard could show `REPORT READY`, `draft written`, `STANDBY`, and `loading current run` inconsistently.

Required correction: a report is complete only after an atomic report receipt and mailbox event. Worker state is derived from the current run receipt, not transcript text or file existence alone.

### 9. Worker sessions could idle, spam, or disappear without recovery

- Gazelle repeatedly emitted “standing by” text while the dashboard still treated the session as meaningful work.
- The creator repeatedly received “restore/reconcile the Gazelle worker” instead of an automatic bounded session recovery.
- Provider restoration and session reachability became sticky informational pings rather than transient events.

Required correction: idle prose is not activity. Track last meaningful tool/action/report timestamp. Reattach a known persistent session automatically when safe; otherwise create one explicit recovery request and suppress duplicates until state changes.

### 10. The BRAIN did too little reasoning before dispatch

- Workers often had to rediscover the problem, relevant files, likely mechanism, proof requirement, and stop condition.
- The BRAIN mostly routed reports instead of converting cross-worker evidence into useful hints.
- Conversely, later diagnostic waves over-reasoned the same blocked native path without changing approach.

Required correction: before every assignment provide a short lead hint: likely mechanism, first files/checks, known traps, required proof, and stop boundary. During work, intervene only on new evidence or a repeated blocker.

### 11. Work was serialized behind one prolonged lane

- A long Gazelle native-validation/soak lane effectively held the wave open while other workers sat standby.
- “Always busy” was interpreted poorly: either workers were idle, or new diagnostic work risked duplicating/contaminating the active lane.

Required correction: split the agenda into independent lanes with declared write scopes. Keep read-only audit, implementation, test-hardening, and UI work parallel when they do not overlap. A prolonged soak is a background gate, not the sole active wave.

### 12. Evidence quality was repeatedly overstated

- Mocks, CDP, disposable harnesses, and process observations were at times treated as substitutes for the creator’s real native workflow.
- “Pass” reports did not necessarily exercise the installed current-source pair, physical input, elevation boundary, or actual persisted state.
- Reports sometimes proved the harness rather than the product.

Required correction: every acceptance item declares its evidence class: unit, integration, isolated native, installed native, or creator visual. A lower class cannot close a higher-class requirement.

### 13. Native/elevated boundaries were discovered too late

- The run repeatedly hit AHK startup, elevation, input injection, parser, receipt, and endpoint boundaries one at a time.
- The automation continued producing waves instead of first mapping the complete privilege/startup chain.

Required correction: perform a single boundary audit before native validation: source identity, installed identity, elevation, task owner, process parent/child, port ownership, handshake, physical-input permission, cleanup, and exact receipt path.

### 14. Product acceptance was fragmented across reports

- The creator’s numbered eye-test findings were not always the sole authoritative agenda.
- Narrow successes were allowed to overshadow unresolved failures.
- Corrections such as “no title,” shared-card 1:1 parity, balanced responsive wrapping, and consecutive reorder reliability had to be restated.

Required correction: maintain one acceptance ledger with `unresolved`, `implemented`, `mechanically proven`, and `creator accepted`. Reports append evidence to items; they do not redefine or silently close them.

### 15. Dashboard status could not be trusted at a glance

- It initially returned 404 and referenced a missing Python path.
- PowerShell windows appeared periodically.
- Transcripts could grow indefinitely, making the page infinitely long.
- Mobile layout required horizontal scrolling, locked vertical scrolling, and produced excessively tall cards.
- Encoding corruption appeared in BRAIN output.
- Scrollbars, dense statistics, stale notices, and harsh working colors reduced readability.
- Card state could say standby while a worker was visibly running.
- “Loading current run” could persist without distinguishing loading, idle, disconnected, or stale.

Required correction: dashboard state must come from receipts and health leases; transcript windows are bounded and independently scrollable; mobile is single-column and width-safe; encoding is UTF-8 end-to-end; stale data is visibly stale; cosmetic animation never invents activity.

### 16. Notifications were noisy, eerie, sticky, or meaningless

- An unfriendly generated sound was used before switching to a normal Windows notification.
- Old informational pings remained indefinitely.
- Desktop-manager pings could recur minutes later for no meaningful milestone.

Required correction: notify once per new actionable fingerprint, use the standard Windows notification sound, expire informational notices automatically, and require a reason plus concrete requested action.

### 17. Status vocabulary conflated activity, progress, and success

- `WORKING`, `WATCHING`, `DISPATCH_READY`, `REPORT READY`, and `progress` often described transport state rather than product progress.
- A green card could mean text was streaming, not that the worker was performing useful work.

Required correction: separate transport (`connected`, `running`, `idle`, `stale`), work (`assignment`, `last meaningful action`), evidence (`none`, `draft`, `report ready`, `accepted`), and product gate (`blocked`, `continuing`, `eye-test ready`).

### 18. The system lacked a deterministic terminal condition

- Workers could finish and stand by while the BRAIN continued diagnostics.
- The BRAIN could stop on a blocker that it should resolve itself, or continue forever on a blocker that needed a mechanism change.
- “Do not ping until resolved” was not encoded as a strict policy.

Required correction: each wave has one terminal result: `accepted`, `superseded`, `mechanism-change-required`, or `creator-decision-required`. Only the last may ping the creator before the true eye-test gate.

### 19. The control system became a competing project

- Time and Desktop Codex usage were spent repairing watcher, telemetry, dashboard, worker dispatch, and UI while the actual Backpack remained unfinished.
- The creator had to manage the manager.

Required correction: the control system has a strict maintenance budget and must fail open to direct product work. If coordination reliability drops below the self-test contract, freeze automation and return ownership to the desktop manager—as was ultimately required here.

## Mandatory safeguards for the next version

1. One durable current-truth and acceptance ledger loaded every turn.
2. One persistent BRAIN session, with continuity verified rather than assumed.
3. Atomic worker run/report/ack receipts; no transcript-derived authority.
4. Event fingerprints and a two-strike unchanged-blocker circuit breaker.
5. Health leases for watcher, BRAIN, dispatcher, and each worker.
6. Account-bound, timestamped telemetry or `unknown`.
7. Evidence classes that cannot be promoted implicitly.
8. Fail-closed eye-test gate tied to every unresolved creator item.
9. Parallel non-overlapping lanes; background soaks never monopolize the wave.
10. A pre-dispatch lead hint and bounded mid-run intervention policy.
11. One actionable notification per new fingerprint; no sticky info pings.
12. A direct-work fallback that freezes the coordinator before it burns another day.

## Current disposition

The automated BRAIN/worker loop was frozen for product recovery. Direct product work is the authority until the Backpack reaches a genuine eye-test build. This control system should be treated as a separate project and must pass its own fault-injection/self-tests before it is trusted with unattended work again.

