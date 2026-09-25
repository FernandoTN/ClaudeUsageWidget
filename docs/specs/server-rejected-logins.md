# Server-rejected Claude logins: condemn, switch away, tell the owner

Status: implemented (draft PR). Hook installation is the operator's step.

## The defect

`ProfileCredentialStatusCache.hasDeadLogin` judges a Claude login by the
stored token's structure: is it expired, is there a refresh token. It never
asks the server. A token the server has invalidated is structurally perfect,
so that rule never called it dead. The auto-switch trigger
(`MenuBarManager.isQuotaExhausted`) is usage-based, and a refused login
generates no usage. Such an account was never marked dead, never exhausted,
and never switched away from.

Measured twice on 2026-09-24:

- **03:31.** A 3-hour fleet stall: 161 `Login expired · Please run /login`
  errors across 41 sessions. The preflight had called the login "live and
  fresh" 4.5 s before the first one. Throughout, the widget's reads of that
  account came back `429 Rate limit exceeded` (~170 ×). It ended when the owner
  ran `/login` by hand.
- **20:31.** The same shape again.

`/login` is interactive OAuth and cannot be automated. Switching away from a
dead login can be, and with 24 accounts that is full recovery.

## What the app does now

`ObservedDeadLogins` (`Shared/Services/ObservedDeadLogins.swift`) holds a
per-profile **verdict**, in memory, separate from the fingerprint-keyed
credential memo. Two detectors feed it.

### Detector A: the widget's own reads

A usage read refused with `.apiUnauthorized` (HTTP 401/403, from
`oauth/usage` or from the Messages-API header probe) advances that profile's
run. The profile is condemned when:

1. two such refusals arrive **consecutively**, with no successful read between
   them. Any success ends the run. A failure that is not `.apiUnauthorized` is
   neutral: it neither advances nor resets the run. That covers 429s, URL and
   DNS errors, timeouts, 5xx, and an expired stored token;
2. both refusals hit **the same stored login** (`ProfileStore.credentialRevision`).
   A refresh, adoption or re-sync in between starts a new run, so a refusal
   that raced a token refresh cannot carry over to the new token;
3. **another Claude account's `oauth/usage` read succeeded after the run
   began.** This is the control. It proves the endpoint accepts this app and
   that the refusal follows this login. Without it, a systemic refusal (an
   endpoint change, a blocked surface) would condemn every account in turn.

The sweep, the popover's manual refresh, the header probe and the
candidate-walk re-verify all report into it. A refusal during the re-verify
also excludes that candidate from the current walk, so the fleet is never
switched into a login the server refused a second ago.

### Detector B: the fleet's own verdict

The widget is blind in exactly the incident window: its reads were 429'd.
The CLI sessions are not blind. Two sources give markers `{at, sessionId}`
for every turn that ended on `authentication_failed`:

- **The transcripts.** The CLI writes
  `{"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,…}`
  ("Login expired · Please run /login") into the session transcript, exactly
  as it writes rate-limit deaths. The existing tripwire walk
  (`LocalLimitSignalService.scanTranscriptSignals`) now returns both kinds
  from the same tail reads. **This source needs no installation.** Checked
  against the 2026-09-24 transcripts: 251 marker lines from 52 sessions,
  the first at 10:30:58Z (03:30:58 PDT).
- **The StopFailure hook journal**, below. It is independent of transcript
  layout and carries the CLI's own closed error enum.

Each sweep, after the identity adoption, `evaluateFleetMarkers` runs against
the **active** Claude login:

- **3 distinct sessions within 120 s** condemn it, whatever the widget's own
  reads say. Only distinct `session_id`s count, never lines, so one
  crash-looping session cannot condemn a login alone.
- **120 s grace after the active login changes**, whether a new owner or a new
  token for the same owner (a `/login` repair). Running sessions finish their
  in-flight turns on the login that was just replaced, and those failures
  belong to it. This is the same reasoning as the transcript tripwire's
  post-switch rule. Without the grace, a switch would condemn the next account,
  and then the next, all the way through the fleet.
- **A watermark.** Markers already acted on never condemn again, so a
  re-condemnation needs new sessions failing.
- **A circuit breaker: at most 3 fleet condemnations per 30 minutes.** Past
  that, the failures are not following any one login (an auth outage, a
  proxy, a CLI bug). Further switches would only burn every running session's
  prompt cache once per account. Recovery pauses; the owner gets one notice
  per trip.

The thresholds, replayed against the full 2026-09-24 transcripts (whole
files, not tails):

| Burst (PDT) | Lines | Sessions | Max distinct sessions in 120 s | Detector B |
|---|---|---|---|---|
| 03:30:58, lasted 78 min | 204 | 47 | 36 | trips on the first sweep |
| 05:00:59 | 3 | 2 | 1 | never |
| 05:28:37 | 6 | 3 | 2 | never |
| 06:00:58 | 12 | 4 | 2 | never |
| 20:00:14, lasted 22 min | 26 | 15 | 13 | trips on the first sweep |

Both incidents cross 3-in-120 s at once. None of the stragglers in between
comes close. The walk with the 120 s lookback measured 0.28 s per sweep on
this machine, against 0.26 s at the old 90 s.

### The recovery

- `hasDeadLogin` ORs the verdict in, read live and never memoized, so the
  dashboard, dots, popover and Accounts page show the login as dead.
- `isQuotaExhausted(…, loginCondemned:)`: an active account with a condemned
  login is exhausted, so the ordinary candidate walk runs.
  `candidateHasHeadroom(…, loginCondemned:)` is its mirror: a condemned login
  is never a target, whether from the ranked walk, the stale re-verify, the
  queued peek or the fleet-tile prediction. The flag is injectable and
  defaults to off, following the `ignoreFableWeekly` pattern from #176.
- On condemnation the owner is notified **once**. The registry returns a
  verdict only on the read that condemned. A login already flagged dead by
  the refresh path has had its re-login notice and gets no second one.
- The switch history records `reason: "login rejected by the server (…)"`.
- The verdict **lifts on the next successful usage read** of that profile,
  including a header rescue. That is how a login repaired with `/login` (and
  adopted by identity) returns to rotation.
- **In memory only.** A relaunch re-derives the verdict from fresh evidence.
  A persisted flag would be one more way to retire a good account for good.

Nothing here re-authenticates, launches a login flow, or touches another
account's credentials. The steps are exactly: condemn, switch away, tell the
owner.

## Installing the StopFailure hook (operator step)

Claude Code (2.1.281+) fires `StopFailure` when a turn ends on an API error.
Its payload is `{hook_event_name, session_id, cwd, error, error_details?,
last_assistant_message?, …}`. `error` is a closed enum, and the event's matcher
field is `error`. The hook is fire-and-forget: output and exit codes are
ignored.

`scripts/hooks/cuw-stop-failure.sh` appends one line,
`{"ts":<epoch s>,"session_id":"…","cwd":"…","error":"authentication_failed"}`,
to `~/Library/Application Support/Claude Usage/stop-failures.jsonl`, but only
for `authentication_failed`. Any other value exits after a `case` match, with
no subprocess. The journal truncates itself past 64 KiB, keeping the newest
200 lines. The widget reads at most its last 64 KiB and ignores any line it
cannot parse. Measured: ~100 ms on the append path, ~15 ms otherwise.

```bash
mkdir -p ~/.claude/hooks
install -m 0755 scripts/hooks/cuw-stop-failure.sh ~/.claude/hooks/cuw-stop-failure.sh
```

Merge into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "StopFailure": [
      {
        "matcher": "authentication_failed",
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/cuw-stop-failure.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

The matcher keeps the CLI from spawning the hook for any other error; the
script checks the value again anyway. To test the script, **not** against the
live journal (a probe line there is real evidence to the running widget):

```bash
printf '{"session_id":"probe","cwd":"/tmp","error":"authentication_failed"}' \
  | CUW_STOP_FAILURE_JOURNAL=/tmp/cuw-probe.jsonl ~/.claude/hooks/cuw-stop-failure.sh
cat /tmp/cuw-probe.jsonl
```

## Reading it in the log

```bash
/usr/bin/log show --predicate 'process == "Claude Usage"' --last 1h \
  | grep -E "login rejected by the server|verdict lifted|automatic recovery is paused"
```

- `⛔️ MenuBarManager: 'X' login rejected by the server (<evidence>) — switching the fleet away from it`
- `AutoSwitch: Switching from 'X' to 'Y' (login rejected by the server: <evidence>)`
- `MenuBarManager: 'X' login answered a usage read — server-rejected verdict lifted, back in rotation`

## Not covered

- Single-profile display mode fetches through the legacy
  `ClaudeAPIService.fetchUsageData()` path and does not feed detector A.
  The fleet runs multi-profile.
- Codex and Grok keep their own dead-login lifecycles. This is Claude only.
- A 401 on the ACTIVE account is re-read only after the existing 5-minute
  auth backoff, so detector A takes about 5 minutes on its own. The header
  probe (60 s cadence) and detector B are the fast paths.
