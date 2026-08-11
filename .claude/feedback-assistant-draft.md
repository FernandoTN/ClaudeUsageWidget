# Feedback Assistant draft — WindowServer occlusion-datagram storm hits every menu-bar host (macOS 27 beta)

> Reconstructed 2026-08-10 (the original draft lived in a since-cleaned job
> dir, `~/.claude/jobs/e772a89f/tmp/feedback-assistant-draft.md`). Kept in-repo
> so it survives. Update the OS-build line before filing if a newer seed lands.

## Title
WindowServer/SkyLight fence wedge floods all NSStatusItem hosts with occlusion
datagrams after display-on — sustained multi-process CPU burn (macOS 27 Beta 4
AND Beta 5)

## Area
WindowServer / SkyLight / CoreAnimation

## Summary
A latent WindowServer wedge forms within minutes of boot and, while present,
every display-on event ignites a storm: WindowServer streams occlusion
datagrams continuously to EVERY process hosting NSStatusItems (measured
90-360 datagrams/s per host), driving each victim to a sustained 4-10% CPU
and WindowServer itself to 27-96% CPU, until display-off quenches it. The
wedge re-forms after process relaunch, after logout, after a clean cold boot,
and — new — on the first day of Beta 5 (26A5406e).

## Build history
- First observed: Aug 5 (26A5388g, Beta 4), coinciding with the first
  "timed out fence/transaction/synchronize" lines in WindowServer's log;
  frequency accelerated 3 → 13 → 302/day over Aug 5-7.
- Cold-boot experiment (Aug 10, 10:09, still 26A5388g): storm re-formed ~5
  minutes after boot on a fresh WindowServer carrying only 4 timeout lines.
- Beta 5 (26A5406e) installed Aug 10 16:53, first boot 16:57: storm active
  again the same evening (measured 18:56-19:32 and 20:18-… display-on
  windows) — the defect is NOT fixed in 26A5406e.

## Victim processes (log-verified during one ignition, zero user interaction)
MenuBarAgent, ControlCenter, ChatGPTHelper, Wispr Flow, Tailscale, Granola
(×2), Google Drive, GeminiAppLauncher, Docker Desktop, Claude Usage (our
app). Burn is proportional to each host's status-item count.

## Reproduction (on an affected machine)
1. Wait for the wedge to form (minutes to hours after boot; formation has
   coincided with Dock space-transition / menu-bar-reveal NSSceneFenceAction
   broadcasts landing on a WindowServer already logging fence timeouts).
2. Turn the display off, then on. Within 32-131 seconds, occlusion-datagram
   churn ignites in every menu-bar host with no interaction.
3. Turn the display off: churn quenches within seconds. The wedge itself
   persists (survived 10.3h display-off and a 37-min clamshell sleep).

## Measurements (2026-08-10 evening, 26A5406e, one live episode)
- One NSStatusItem host (Claude Usage, 3 status items): ~674 log lines/s of
  which ~259/s occlusion datagrams; 4.7% CPU sustained; all threads parked
  in healthy runloops (sample attached to earlier sysdiagnose).
- Simultaneously: Tailscale ~119 lines/s, Wispr Flow ~148 lines/s,
  ~238 occlusion lines/s across the third-party host set.
- WindowServer: 31.5% CPU sustained (measured by cputime delta over 30s),
  3.5h after boot.

## Triage fingerprint
- SkyLight: "synchronize timed out for <CA context id>" — one context id
  repeats for hours (Aug 7: 675cdf6a, 10:15-20:20).
- Per-host: continuous occlusion-state datagram delivery to every
  NSStatusItem scene while the display is on.

## Attachments
- sysdiagnose captured DURING a live Beta 4 episode:
  sysdiagnose_2026.08.07_21-16-27-0700_macOS_Mac_26A5388g.tar.gz (Desktop).
- Recommended before filing: capture a second sysdiagnose during a live
  Beta 5 episode (`sudo sysdiagnose` while the menu-bar hosts are churning —
  the wedge is active whenever the widget's StormWatchdog banner is up).

## Why we believe this is OS-side, not app-side
Simultaneous (within 120ms) ignition across unrelated apps 3+ minutes after
the last user interaction; churn ignites on display-wake with zero
interaction; identical behavior across app relaunches, logout, cold boot,
and two OS builds; a single app cannot opt out of NSSceneFenceAction
broadcasts; per-app forensics (14 addenda in this repo's
.claude/HANDOFF-DEEP-DIAGNOSIS-REPORT.md) verified the app's own scene
mechanics clean throughout.
