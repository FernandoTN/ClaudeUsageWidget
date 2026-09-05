# Transcript rate-limit attribution (auto-switch policy)

Which account a transcript `rate_limit` event belongs to, which WINDOW it
names, and when the auto-switch may act on it. Branches
`fix/transcript-limit-attribution` (#158) and `fix/transcript-limit-class`
(window classification, below).

**Status:** #158 merged as main `4352b40` (squash), deployed by the
orchestrating session 2026-09-04 23:25:01 (pid 73406); preview and post-merge
suites 612 / 0, Release green. Window classification (#165,
`fix/transcript-limit-class`): merged as main `c22d614` (squash) on
2026-09-05; preview and post-merge suites 632 / 0, Release green; deploy
staged by the orchestrating session behind the next Claude switch.

## The window (2026-09-05 15:47, main `8c2eec0`, deployed `fd626cf`, pid 39798)

| Time (PDT) | What happened |
| --- | --- |
| 15:47:16–29 | Four transcripts recorded `error: "rate_limit"` with the text **"You've reached your Fable limit. Run /usage-credits to continue or switch models with /model."** — no reset time in the text. The owner, 'Memori', read session 89 %, Fable weekly 97→100 %. |
| 15:47:26.378 | `transcript says limit, live read says 89% — ignoring event for 'Memori' (attributed by clock)` — corroborated against the SESSION window; the limit was FABLE. |
| 15:47:31.164 | `AutoSwitch: Switching from 'Memori' to 'dFernando'` — the header reading (Fable 100 % ≥ 99 %) did the right thing five seconds later. |
| 15:47:31.600 | `could not corroborate … — E3003`, then `'Memori' hit its session limit …, resets unknown (30min stamp)` — still called a session limit, with a 30-minute placeholder reset and clock attribution because no reset stamp could match. |

No false hop, but three defects: a genuine Fable event was dismissed as
contradicted because the session had headroom; a Fable event stamped as a
session hit misplaces the account's readiness, dot colour and "capacity
returns" sort key; and with no reset in the text, reset-stamp attribution
never applied to Fable events at all.

### Message catalogue → window (`LimitWindow`, `LocalLimitSignalService.classifyWindow`)

Shapes in 21 days of transcripts (2026-09-05) and the CLI 2.1.261 string
table; the window picks every stamp, percentage and threshold downstream.

| Transcript text | Window | Reset in text | Attribution stamp | Corroborated against | Stamped on the profile |
| --- | --- | --- | --- | --- | --- |
| `You've hit your session limit · resets 2:50am (Zone)` | `.session` | yes | `sessionResetTime` | `effectiveSessionPercentage` vs session threshold | `rateLimitedUntil` = reset, `sessionResetTime` |
| `You've hit your weekly limit · resets Aug 22 at 3pm (Zone)` (dated form, newly parsed) | `.weekly` | yes | `weeklyResetTime` | `weeklyPercentage` vs weekly threshold (headers carry it) | `weeklyPercentage` = 100, `weeklyResetTime` = reset |
| `You've reached your Fable 5 limit. Run /usage-credits …` | `.fableWeekly` | **no** | window STATE (below) | `fableWeeklyPercentage` vs weekly threshold — own endpoint only; a header rescue carries no Fable window and is `unavailable` | `fableWeeklyPercentage` = 100 |
| `You've hit your Fable 5 limit · resets Sep 5 at 9pm (Zone)` | `.fableWeekly` | yes | `fableWeeklyResetTime` | as above | as above + `fableWeeklyResetTime` = reset |
| anything else (`monthly spend limit`, `Sonnet limit`, …) | `.unknown` | — | the session's, as before | the session's, as before | as `.session` |

Rules added on top of the ones below:

- **Attribution by window state.** When the text carries no reset, the owner
  at event time whose NAMED window already reads at the limit is the one it
  names — the current owner first (its live read decides), then the previous
  owners of the 15-minute lookback; nobody at the limit → clock. "At the
  limit" is the window's auto-switch threshold capped at 95 %
  (`windowStateFloor`: the weekly default is 99 %, and a Fable window
  measured at 97 % a sweep ago is the account a Fable 429 names). Only the
  named window is evidence: a session at 100 % says nothing about a Fable
  429, and an account with no Fable window is never picked.
- **Corroboration in the named window.** A Fable event is confirmed when the
  live Fable weekly ≥ the weekly threshold and contradicted only when THAT
  window shows headroom; the log line names it: `transcript says FABLE
  limit, live read Fable 40% — ignoring …`. An account-level Retry-After
  confirms a session event only; a header rescue answers session and weekly
  events, never a Fable one (the probe is skipped — it would spend quota for
  nothing).
- **The stamp lands on the named window** (`ClaudeUsage.stampLimitHit`): a
  Fable hit reads Fable 100 (readiness `.weeklyHit`, "capacity returns" at
  the Fable reset), never the session. **The 30-minute placeholder is gone**:
  an event without a reset records `resets unknown`, the session reads 100
  through its percentage instead of a synthetic `rateLimitedUntil`, and no
  placeholder ever takes part in stamp matching. The incident ring carries
  the window (`Incident.window`) and the Insights row says "Fable 429
  contradicted — live read 40 %, ignored".

Replay of the 15:47 sequence (`testReplayOfTheFableIncidentIsConfirmedNotContradicted`):
the text classifies as `.fableWeekly` with no reset; window state names the
owner (Fable 100 %); the live read session 89 % / Fable 100 % CONFIRMS it.

## The incident (2026-09-04, unified log + profile store + transcripts)

| Time (PDT) | What happened |
| --- | --- |
| 22:52:45.768 | `AutoSwitch: Switching from 'dFr(fermin-dev)' to 'dJormun'` — dFr at 95 %, dJormun measured with headroom. |
| 22:53:35–22:53:42 | Three Claude Code transcripts (subagents of one session) recorded `error: "rate_limit"`, text "You've hit your session limit · resets 3:40am (America/Los_Angeles)". |
| 22:53:45.535 | `transcript rate-limit event — 'dJormun' hit its session limit … resets 10:40:00 +0000`. |
| 22:53:45.538 | `AutoSwitch: Switching from 'dJormun' to 'Google'`. |
| 22:53:45 | dJormun's OWN endpoint read session **22 %** in the same second (stored `sessionResetTime` 03:49:59 local). dFr's stored reset is **03:39:59** local at 100 %. "resets 3:40am" is dFr's window. |

Cause: the event was attributed to the ACTIVE login by the wall clock. Running
Claude Code sessions keep the previous owner's token in memory for a while
after a switch — their in-flight and immediately following requests still hit
the old account — so for a window after every switch, transcript 429s belong
to the OUTGOING owner. The false hop abandoned dJormun's fresh window and landed
the fleet's context re-read on Google (0→58 % in 4 min); with ~20 concurrent
lanes each such hop costs ~30–40 % of a window.

The other event of the day (22:15:17, 'dLucifer', "resets 2:50am") was checked
and was NOT misattributed: the outgoing owner ('Outlook', left at 21:59:02)
holds a 02:39:59 reset, and the header rescue at 22:15:18 measured dLucifer at
101 % with its 5-hour window rejected.

A second defect surfaced in the same forensics: `SwitchEvent.from` recorded the
FOCUSED profile, not the outgoing owner — every automatic Claude switch of the
day names 'xLucifer(dev)' as the account it left. The rule is fixed in
`ProfileManager.activateProfileDetailed` (`outgoingNameForHistory`): the
outgoing account is the owner of the target's provider login, the focus only
the fallback when no pointer exists.

## Rules (`TranscriptLimitAttribution`, `MenuBarManager.applyTranscriptRateLimitEvent`)

1. **Attribute by evidence, not by clock.** The event's parsed reset time is
   compared with the cached `sessionResetTime` of the owner at event time and
   of the previous owners named by the switch history within the last
   15 minutes (`previousOwnerLookback`), tolerance ±3 min
   (`resetMatchTolerance` — the endpoint reports xx:x9:59.889 where the
   transcript says the next minute; verified on both of the day's events). A
   stamp counts as evidence only when its window was still open at the event
   and carries measured usage (a healed boundary pairs with 0 %).
   - Matches the current owner → corroborate (rule 2).
   - Matches a previous owner only → the hit is recorded against THAT profile
     (affirmed stamp, incident ring), logged as `attributed to previous owner
     '<name>' (reset match) — no switch`, and nothing switches.
   - Matches both → the current owner, because rule 2's live read decides.
   - Nobody has an evidence-grade stamp, or the text carried no reset → the
     clock owner, corroborated.
   - The current owner's measured window disagrees and no recent previous
     owner matches → `unmatched`, ignored (the normal sweep keeps measuring).
2. **Corroborate before switching.** The blamed current owner is re-measured
   live with its own credentials — the usage endpoint, else the Messages-API
   header rescue already used for blind owners; an account-level Retry-After
   counts as confirmation. Confirmed (≥ the session threshold) or unavailable →
   the event is stamped and handed to `checkAutoSwitchIfNeeded` as before.
   Contradicted (headroom) → no stamp, no switch, logged as `transcript says
   limit, live read says N% — ignoring event`, incident flagged
   `contradicted`. The candidate walk's own TARGET re-measure is unchanged.
3. **Post-switch grace** (`postSwitchGrace` = 120 s, half-open): a transcript
   event inside it whose reset does not match the new owner's window — or
   carries no reset — is never actionable. Header/endpoint readings of the
   new owner are unaffected.
4. **Incident ring.** `FleetInsights.Incident.tripwire` carries the
   disposition (`actedOn(basis, liveRead)` / `previousOwner(currentOwner)` /
   `contradicted(livePercent)` / `postSwitchGrace` / `unmatched`); the
   Insights incidents section renders "429 from the previous owner — ignored,
   <owner> kept the login" and the other outcomes. Rows are filed under the
   profile the event was attributed TO.

Owner rulings honoured: the auto-switch never fires on inference — this
removes one (clock attribution); only server-affirmed or measured values drive
the decision; no synthetic value is ever written. Tests:
`TranscriptLimitAttributionTests` (13, pure, incl. the incident replay).
