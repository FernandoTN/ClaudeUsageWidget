# Fleet weekly-capacity forecast (Claude)

**Status:** `feat/fleet-capacity-forecast`, draft PR. Claude only — Codex and
Grok are out of scope by the owner's brief.

## The owner's ask (2026-09-22)

> "To the right of that [the next-switch hint] I want you to put how much
> weekly percentage we have left and … When are we going to hit the overall
> weekly limit? … Let's say we have 24 accounts multiplied by 100, that's
> 2,400 points that we can use weekly. First of all, how many of those points
> are actually available right now? … there's obviously more coming online
> and we also have a rate of usage … whether the consumption is higher than
> the rate at which we are renewing. It would vary by the date that they
> actually come online. For instance Saturdays are a lot of the accounts
> actually reset."

## The four quantities

A **point** is one percent of one account's weekly window: an account is
worth 100, a fleet of 24 is worth 2 400 a week. Model:
`Claude Usage/Shared/Models/FleetCapacity.swift` (pure, `now`-injectable;
`FleetCapacityTests`).

| Quantity | Definition | Live, 2026-09-22 15:30 (orchestrator) |
|---|---|---|
| **Pool** | `Σ max(0, 100 − weekly %)` over the USABLE accounts | 609 of 2 400 |
| **Ceiling** | `usable accounts × 100 / 168` points per hour | 14.3 pt/h |
| **Burn** | measured points per hour, least squares over the series | ~37 pt/h (2.6×) |
| **Runway** | when the simulated pool reaches zero | Wed 22:36, before Last renews Thu 17:00 |

**Usable** (`FleetCapacity.isUsable`): a Claude profile that holds usage
credentials, whose login is not dead, and that the auto-switch would accept
(toggle on, not a free plan) — the fleet dots' own `isLoginDead` /
`isExcluded` predicates, so the pool counts exactly what a green dot could
stand for. Two refinements taken from the prior art
(`FleetCounts.capacityRemaining`, the Insights "capacity" line):

- **One quota per account.** Profiles are grouped by `FleetCounts.accountKey`
  and read from the freshest measured member, so a duplicate pair (#60) is
  100 points and one account in the ceiling, never two.
- **A rolled-over window is full.** A weekly reset already in the past reads
  100 left (the readiness rule), not its stale percentage. A reset the API
  never reported (`unknownResetSentinel`) is not a reset: it reads its
  measured percentage and has no renewal.
- A usable account **never measured** is in neither the pool nor the ceiling;
  it is counted and shown ("+ 1 unmeasured"), never guessed.

The Insights line (`capacityRemaining`) differs on purpose: it also counts
accounts the owner excluded from the rotation ("still the owner's to use"),
and gives 0 for a rolled-over window until it is re-measured. It answers
"how much could I use by hand"; the pool answers "how much can the rotation
reach".

**The ceiling is the invariant.** Every account renews its 100 points once a
week, so no scheduling arrangement sustains a burn above
`accounts × 100 / 168`. Above it the pool drains; below it the pool refills.

## Burn — the series and the fit

`fleetCapacitySeries_v1` (`SharedDataStore`, journaled like the other
single-shot writers; registered key) holds one sample per ≥ 5 minutes,
24 hours kept (≤ 300 samples, ~12 KB): `[epochSeconds, pool, accounts,
scheduleKey]` — numbers only. `MenuBarManager.recordFleetCapacitySample` appends at
the end of every multi-profile sweep, right after the sweep's measurements
are published; `FleetCapacity.appending` drops the sample when the newest one
is younger than 5 minutes.

The fit (`FleetCapacity.burnRate`) is least squares, never first-minus-last:
background accounts are re-measured every few minutes, so the pool moves in
small steps and the endpoints carry that noise. The pool also **steps up**
when an account renews, joins or leaves, and a step regressed across reads as
negative burn. So the series is cut into runs of equal `(accounts,
scheduleKey)` and the slope is pooled within runs (one intercept per run):

- `accounts` changes on an eligibility edit, a login dying or reviving, an
  account joining.
- `scheduleKey` is `Σ` of each account's next weekly boundary in whole
  minutes (quantized like the menu-bar ranking, against the API's ±1 s
  jitter). A renewal moves one boundary a week ahead, so the key changes at
  the very moment the pool jumps. Without this, three renewals a day would
  cancel most of a day's measured burn.

A run of one sample carries no slope and is dropped.

**Evidence bar — never fabricate a runway.** A burn exists only with at
least **6 samples** in runs of two or more, whose runs span at least **60
minutes** in total (`minSamples`, `minSpan`).

## Runway — the forward simulation

`FleetCapacity.zeroTime` walks the pool forward from now at the fitted burn.
At each usable account's next weekly boundary inside the 7-day horizon it
adds back that account's **used percent as measured now**. That is
conservative: an account used further before its reset returns more, so the
estimate errs early, never late. An account whose window already rolled over
returns 0 at its next reset (what it will have used by then is unknown).

| Condition | Runway | Bar |
|---|---|---|
| < 6 samples or < 60 min of runs | `insufficientHistory` | pool alone |
| burn ≤ 0 | `notDraining` | pool alone |
| 0 < burn ≤ ceiling | `sustainable` | pool alone |
| burn > ceiling, pool hits 0 | `zero(at, nextRenewal)` | `pool·runway` |
| burn > ceiling, pool survives | `survives` | pool alone |

`survives` is unreachable over a full week: the pool plus every renewal is
at most `accounts × 100`, and a burn above the ceiling takes more than that in
168 hours. It exists so the simulation never has to invent a zero.

`nextRenewal` names the first renewal after the zero: the owner's "before
Last renews Thu 17:00".

### Judged and not implemented

With burn **below** the ceiling, a lumpy schedule can still empty the pool
for a while: say a small pool now, and every renewal falling on the weekend.
The brief says a burn at or below the ceiling shows no ETA, and that is what
ships. The simulation would find that dip. Surfacing it (e.g. "dips to 0
Fri, refills Sat") is a one-line change in `FleetCapacity.forecast` if the
owner wants it.

## Where it is shown

- **The bar** (menubar-redesign.md §2.8): `609·31h` right of the candidate
  row, in its free space only, never widening the block.
- **The Claude tile's tooltip**: one line each for the pool, the burn against
  the ceiling, and the runway (`FleetCapacityFormatting.tooltipLines`).
- **The dashboard**: a *Weekly capacity* card in the Claude section, under
  Next/Queue (`FleetCapacityCard`). It shows the pool out of its maximum,
  the burn, the ceiling and their ratio, the runway with its date and the
  renewal it misses, and the renewal profile for the next seven days (today
  first, accounts per weekday, the zero's weekday named in the runway's
  colour) so the Saturday cluster is visible.

Default behaviour with no series yet: today's bar plus the pool, the card
says "measuring".
