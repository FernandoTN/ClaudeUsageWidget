# Transcript rate-limit attribution (auto-switch policy)

Which account a transcript `rate_limit` event belongs to, and when the
auto-switch may act on it. Branch `fix/transcript-limit-attribution`.

**Status:** draft PR open; awaiting the orchestrating session's gate.

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
