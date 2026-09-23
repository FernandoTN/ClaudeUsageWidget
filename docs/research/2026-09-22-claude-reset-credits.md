# Claude "bank resets": what they actually are, and what the widget can show

**Date:** 2026-09-22 · **Status:** read-only investigation. No app code was changed and no
instrumentation was added. **Nothing was claimed, redeemed or activated.**
**Base:** `origin/main` `3cf2b60`
**Local CLI under test:** Claude Code `2.1.280` (native binary
`~/.local/share/claude/versions/2.1.280`, installed 2026-09-22 09:30 local)

"Bank resets" is the owner's shorthand. It was used the same way for Codex (see
`2026-09-03-codex-bank-resets-local-evidence.md`), and it is not a product term. On the
Claude side there are **two** reset programs. Both are claimed through one endpoint.

| Program (wire id) | What the user sees | Shape | Closest to Codex "usage limit resets"? |
|---|---|---|---|
| **`cedar_ember`** | "**limit reset**" / "Use your reset", command `/limit-reset` | A **bank of grants**, each with `resets_left`, `resets_total`, a use-by date (`ends_at`), and the list of windows it refills | **Yes.** This is the banked, countable, expiring mechanism |
| **`juniper_tide`** | "Reset your session limit now · uses weekly limit · 1/week" (same `/limit-reset` command) | A **weekly allowance**: `available`, `next_available_at`, `resets_per_week` (default 1). Refills the 5-hour session only | No. Nothing is banked; it is closer to an experiment arm |

**Verdict on Q1, in one line:** the mechanism is on the wire, in the same
`api.anthropic.com/api/oauth/usage` response the widget already fetches, as the top-level
keys `cedar_ember` and `juniper_tide`. They are `null` on the plain read the widget makes.
They are populated only when the request adds `?at_wall=1` or `?cedar_ember=1`, and even
then the server tells the widget's own client identity `eligible: false,
ineligible_reason: "surface"`, with an empty grant list. **The per-account count is not
observable by the widget as it identifies itself today.**

---

## 1. Does it exist on the wire? What the widget ignores

### The widget's read

- Endpoint: `GET https://api.anthropic.com/api/oauth/usage`, Bearer OAuth token plus
  `anthropic-beta: oauth-2025-04-20`, `User-Agent: ClaudeUsageWidget/<ver>`
  (`Claude Usage/Shared/Services/ClaudeAPIService.swift:100-154`).
- Decoder: `parseUsageResponse` (`ClaudeAPIService.swift:327`) is **not** a strict
  `Decodable`. It is a permissive `JSONSerialization` dictionary walk that consumes exactly
  these keys, so unknown keys are dropped silently and never cause a failure:
  - `five_hour.{utilization,resets_at}` (`:341`)
  - `seven_day.{utilization,resets_at}` (`:353`)
  - `seven_day_opus.utilization` (`:364`)
  - `seven_day_sonnet.{utilization,resets_at}` (`:373`)
  - `limits[]` entries with `kind == "weekly_scoped"` and `scope.model.display_name == "Fable"`
    (`:388`)

### What the endpoint actually returns (live, 2026-09-22 ~23:50Z)

I captured four accounts with each profile's own stored token and the widget's honest
User-Agent: one plain read and four `?at_wall=1&skip_spend=1` reads, 4 s apart. The capture
recorded names, types and non-sensitive flags only; tokens were never printed, and expired
tokens would have been skipped rather than refreshed (none were expired). Accounts are
anonymized as P0, P1, P8 and P13.

Top-level keys on the **plain** read (the widget's read). Keys marked ✱ are consumed by the
widget; every other key is ignored today:

```
five_hour ✱        {utilization: float, resets_at: str|null, limit_dollars, used_dollars,
                    remaining_dollars, locked_reason}      (last four: null on all four accounts)
seven_day ✱        same shape
seven_day_opus ✱   null        seven_day_sonnet ✱ null
seven_day_oauth_apps, seven_day_cowork, seven_day_omelette      null
tangelo, iguana_necktie, omelette_promotional                   null
nimbus_quill       {utilization, resets_at, limit_dollars, used_dollars, remaining_dollars,
                    locked_reason}                          (populated: a window the app ignores)
cinder_cove, copper_kite, harbor_lantern, wattle_ember, amber_ladder, amber_gauge   null
juniper_tide       null            <- reset program, null unless asked for
cedar_ember        null            <- reset program, null unless asked for
extra_usage        {is_enabled, monthly_limit, used_credits, utilization, currency,
                    decimal_places, disabled_reason, user_disabled, spend_limit_reached,
                    credits_ever_enabled, daily, weekly}
limits[3] ✱(Fable) [{kind: "session"|"weekly_all"|"weekly_scoped", group, percent, severity,
                    resets_at, scope{model{id,display_name},surface}|null, is_active}]
spend              {used{amount_minor,currency,exponent}, limit{…}, percent, severity, enabled,
                    disabled_reason, cap{money,credits{…}}, balance, auto_reload, disclaimer,
                    can_purchase_credits, can_toggle}
member_dashboard_available  bool
seven_day_breakdown {as_of, window_started_at, rows[4]{key, display_name, percent}}
```

On the `?at_wall=1&skip_spend=1` read, `spend` and `extra_usage` become `null` (so
`skip_spend` skips the spend and extra-usage computation) and the two program blocks are
populated. The result was identical on all four accounts (weekly 28 %, 85 %, 97 % and 96 %;
session 0 to 40 %):

```
cedar_ember:  {eligible: false, ineligible_reason: "surface", at_limit: false, exhausted: [],
               grants: [], next_grant_id: null, weekly_resets_at: null,
               cooldown_until: null, event_props: null}
juniper_tide: {eligible: false, ineligible_reason: "surface", in_experiment: false, arm: null,
               available: false, next_available_at: null, weekly_resets_at: null,
               resets_per_week: 1, event_props: null}
```

`"surface"` is one of the server's ineligibility reasons (list in §2). The server evidently
identifies the calling client, and the widget is not an eligible surface. Consequence:
**`grants: []` here is UNKNOWN, not zero**. This is the same rule as Codex's null count
(`ClaudeUsage.swift:105-115`).

The at-wall and cedar-ember variants are the CLI's own reads (`nx`/`qR` in the CLI; the path
table is the literal `AG={plain:"/api/oauth/usage", at_wall:"/api/oauth/usage?at_wall=1&skip_spend=1",
cedar_ember:"/api/oauth/usage?cedar_ember=1&skip_spend=1"}`). The CLI makes the at-wall read
**automatically whenever a session hits a limit** (`uDr` → `ee(…,"wall")` → `Je(s)`,
default `read:"at_wall"`), so these reads are routine traffic from the owner's fleet, not
something exotic.

---

## 2. Name and semantics

Source for everything in this section: the `cedar_ember` / `juniper_tide` module in the
2.1.280 binary (a bun chunk at byte offset ~195 189 040, 47 KB). Its zod schemas, claim
function and user-facing copy are verbatim. The copy table lives in a separate chunk
(`var Tz="limit-reset"; var iFr="tengu_cedar_ember", Np={…}`). Both programs are
**byte-identical in 2.1.277 (Sep 18)** and 2.1.278: the client code predates "today".
Whatever was released today was a server-side or flag switch-on, or the claude.ai web
surface (§6).

### Names

| Surface | String |
|---|---|
| Slash command | `/limit-reset`. Description when cedar_ember is on: "Use an available limit reset and keep working". When only juniper_tide is on: "Reset your session limit now and keep working; once a week, still counts toward your weekly limit" |
| Offer label | "Use your reset now ({left} left, until {date})" |
| Rate-limit notice | "/limit-reset to refill your limits · {resets} left · use by {date}" |
| Confirm dialog | "Use your reset?" / "Refills your {limits} now · your weekly reset day stays {week}" / "{resets} left · use by {deadline}" / "Yes, use my reset" · "No, keep it" |
| Success | "Limits reset · your weekly reset day stays {week} · {resets} left" |
| Server-driven copy flag `tengu_wise_bear_copy` (cached in `~/.claude.json`) | "Use your limit reset to reset it now: `clau.de/reset`", flag `only_if_unused_reset: true` |
| `clau.de/reset` | `302 → https://claude.ai/new#settings/usage` (verified with curl) |

The product name is therefore **"limit reset"** (plural "resets"). "Bank" appears nowhere.

### `cedar_ember` status block (from `?at_wall=1` or `?cedar_ember=1` reads)

| Field | Type | Meaning / evidence |
|---|---|---|
| `eligible` | bool | Required |
| `ineligible_reason` | enum | `config_off, tier, seat, mobile, surface, cli_version, no_grant, tenure, other_experiment, unavailable, unknown` |
| `at_limit` | bool | The server's own "at a limit now" verdict |
| `exhausted` | [limit type] | Which windows are exhausted now |
| `grants` | [grant] | The bank (below) |
| `next_grant_id` | string? | The grant the server will spend next; only it is offered |
| `weekly_resets_at` | ISO string? | Used in the copy "your weekly reset day stays {week}" |
| `cooldown_until` | ISO string? | Set after a claim; see §3 |
| `event_props` | object? | Rollout dimensions: `surface` (claude_ai / claude_code_cli), `tier` (claude_pro / claude_max_5x / claude_max_20x / claude_team), `tenure_bucket`, `billing_path`, `billing_period`, `extra_usage_state` |

A **grant** has these fields:

- `id` (`^[a-z0-9_-]{1,40}$`), `label`
- **`resets_total`** and **`resets_left`** (int ≥ 0)
- `starts_at`, **`ends_at`** (ISO, nullable = no deadline)
- **`clears`**: the limit types it refills
- `paused`, `usable_now`
- **`use_requires_limit`** (default true)
- `percent_used` (per limit type, 0–100)
- **`blocking`**: limit types that block its use

Limit types are `five_hour, seven_day, seven_day_overage_included, seven_day_opus,
seven_day_sonnet, seven_day_cowork, seven_day_omelette, seven_day_oauth_apps`.

Answers to the brief's questions:

- **Count, not boolean.** The balance is the sum of `resets_left` over the grants (the CLI's
  `Le()`). Each grant carries its own total and remaining count.
- **What it clears is per grant, server-stated.** `clears` lists the windows. The copy
  renders it as "session", "weekly" or a model limit ("Refills your session and weekly
  limits now"). The confirm and success copy both say **"your weekly reset day stays
  {week}"**: a reset refills usage but does *not* move the weekly anchor. A grant whose
  `blocking` contains an exhausted window cannot be used ("Your reset doesn't refill your
  {X}, so it can't be used until that resets").
- **Fable.** `clears` has no Fable-scoped key, and the widget's Fable window lives in
  `limits[]` as `weekly_scoped`. Whether a grant refills the Fable weekly is **not
  established** (§6).
- **Expiry.** Yes. `ends_at` is the use-by date ("use by {date}"). The client drops a grant
  past `ends_at`, and the server has an `expired` reason.
- **Conditional eligibility.** Three gates:
  - Account level: tier, tenure, seat, surface, CLI version and experiment reasons, as
    listed above.
  - Grant level: `usable_now` and `paused`.
  - Timing: `use_requires_limit`. When true (the default), the grant only works at a limit
    ("You have a reset saved for when you reach a usage limit"). When false, it can be spent
    **early**, after an extra confirm ("You still have {percent}% of your {limit} left —
    use your reset anyway?").
- **Per account or per org?** Status is read with the account's OAuth token. The claim is
  addressed to `/api/organizations/{orgUuid}/…` using the token's
  `oauthAccount.organizationUuid`. For personal Pro/Max accounts, org = account, so it is
  effectively per account. For a Team seat (`seat` is an ineligibility reason), the
  semantics are **not established**.
- **Client flag.** The CLI shows cedar_ember only when GrowthBook `tengu_cedar_ember.enabled
  == true` (`yX()`). For the account currently logged into the CLI, that flag is **absent**
  from `~/.claude.json` `cachedGrowthBookFeatures` (cached 23:43Z today). Meanwhile
  `tengu_nifty_lemur` (juniper_tide's copy and flag) is `enabled: true, version: 1`. Only
  the CLI's current account is cached; the other accounts' flags are unknown.

### `juniper_tide` status block

`eligible`, `ineligible_reason` (`tier, tenure, surface, mobile, cli_version, not_at_wall,
weekly_limit, no_weekly_limit, other_experiment, extra_usage, unavailable, unknown`),
`in_experiment`, `arm` (`control` | `reset`), `available`, `next_available_at`,
`weekly_resets_at`, `resets_per_week` (default 1), `event_props`. The client offers it only
at a **session** wall (`Mr()` clears only `rateLimitType == "five_hour"`). Copy: "Session
limit reset · next reset available {date} · your weekly limit still applies". It is an A/B
arm with a weekly allowance, not a bank.

### Is `hasExtraUsageEnabled` the same thing? No.

`~/.claude.json` `oauthAccount.hasExtraUsageEnabled` corresponds to the usage response's
**`extra_usage`** block: pay-as-you-go credits (`monthly_limit`, `used_credits`, `currency`,
`disabled_reason`), managed by the CLI's `/usage-credits` command (renamed from
`/extra-usage`). Its spend is summarized by the `spend` block. Three facts separate it from
the reset programs:

- It is a separate top-level block.
- `cedar_ember.event_props.extra_usage_state` (`not_configured | disabled | enabled`) is
  recorded as an independent attribute *of* a reset.
- `juniper_tide` lists **`extra_usage` as an ineligibility reason**, so enabling
  pay-as-you-go can make an account ineligible for the weekly session reset.

For the CLI's current account: `hasExtraUsageEnabled: false`,
`cachedExtraUsageDisabledReason: "org_level_disabled"`.

---

## 3. Activation: the call, its cost, and what cannot be undone

**The call (identified, NOT made):**

```
POST {BASE_API_URL}/api/organizations/{organizationUuid}/reset_rate_limits
Authorization: Bearer <that account's OAuth access token>      Content-Type: application/json
{"program": "cedar_ember", "grant_id": "<next_grant_id>", "request_id": "<uuid>"}
```

The path and body are verbatim from the CLI's claim function (`Ge`). `BASE_API_URL` is the
literal `"https://api.anthropic.com"` in the binary, so the host is inferred from that
constant; this exact call was never observed. Timeouts: 25 s per request, 35 s overall. The
`request_id` must match `^[A-Za-z0-9_-]{1,64}$`. The CLI refuses to send a malformed grant
or request id.

juniper_tide uses the same path with `{"program": "juniper_tide"}` and **no** grant id or
request id.

**Responses** (`result` enum, plus `reason`, `resets_left`, `cleared[]`,
`weekly_resets_at`, `cooldown_until`):

| `result` | Grant spent? | CLI copy |
|---|---|---|
| `reset` | **Yes** | "Limits reset · your weekly reset day stays {week} · {resets} left" |
| `not_limited` | No | "Your limit had already reset on its own · nothing was used" |
| `cooldown` | No | "Another reset was just started on your account … try again in a minute" |
| `already_used` | Earlier, yes | "That reset was already used · nothing changed just now" |
| `ineligible` | No | "This reset isn't available any more · nothing was used" |
| `unavailable` / HTTP error / timeout / unreadable body | **UNKNOWN** | "Couldn't confirm the reset went through · if you're still at the limit in a moment, try again"; on the second miss: "Still couldn't confirm your reset · nothing more was used · … contact support" |
| HTTP 429 | No (`rate_limited`) | "Couldn't reset your limits · nothing was used · try again in a moment" |
| HTTP 401/403 | No (`auth_error`) | "Couldn't reset your limits with this login · run /login, then try again" |

**Idempotency.** The key is the client-minted `request_id`. After an `unavailable` or
`error` outcome, the CLI records an **unsettled claim** (grant id, request id, account
epoch, timestamp). It **re-sends the same `request_id`** on any retry of that grant for 10
minutes within the same account epoch (`Jt`/`Qe`/`Dt`, `Zn = 600000`), and only mints a new
one once the claim settles. The server's `already_used` on a retry is rendered as "Your
earlier reset went through after all". So the server de-duplicates on `request_id`. That is
**inferred** from client behaviour, not documented. `cooldown` is a separate server-side
guard against two concurrent claims on one account.

**Reversible?** No. There is no un-claim endpoint and no refund path in the client. A
`reset` decrements `resets_left` for good. The copy is careful to say "nothing was used"
only on outcomes where that is known.

**Failure modes that matter to the widget:**

1. **Ambiguous outcome → double spend.** A timeout, 5xx or unreadable body leaves the grant
   possibly spent. Retrying with a *fresh* `request_id` can spend a **second** grant. The
   Codex path already keys its redeem id per (profile, window)
   (`CodexResetCredits.swift:589-615`). A Claude port must key on (profile, grant id) and
   persist the unsettled claim across relaunches.
2. **"Anytime" grants bypass the server's guard.** With `use_requires_limit == false`, the
   server accepts a claim while the account has headroom and spends the grant. The widget's
   "measured at its limit" gate (`CodexResetCredits.swift:532-544`) must be enforced
   client-side; the server will not enforce it for these grants.
3. **Wrong account.** The claim spends a grant in the organization the token belongs to. The
   widget must use the profile's **own** stored token together with its stamped
   `Profile.claudeOrganizationUUID` (already persisted from `api/oauth/profile`:
   `ClaudeCodeSyncService.swift:785,828`). It must never use the shared `Claude
   Code-credentials` login, which is the ACTIVE account's (see the contamination history in
   CLAUDE.md).
4. **Surface gate.** If the claim is gated like the status read, a claim sent with the
   widget's honest identity would come back `ineligible` (reason `surface`). That is a
   no-spend outcome, but it means activation from the widget may be impossible without
   presenting as the CLI. **Owner decision, not a technical one.** I did not test it.

---

## 4. The Codex path end to end (the template)

| Stage | Where | Notes |
|---|---|---|
| Count, free, from the sweep | `CodexUsageService.parseUsageResponse` → `resetCreditCount` / `resetCreditApplicableCount` (`CodexUsageService.swift:1109-1126`, helpers `CodexResetCredits.swift:314-339`) | Read out of the usage payload the sweep already fetches. **nil = unknown, never 0** |
| Stored | `ClaudeUsage.codexResetCreditsAvailable` / `…Applicable` / `…MeasuredAt` (`ClaudeUsage.swift:105-129`) | Persisted with the profile's usage |
| Detail, on demand only | `CodexUsageService.fetchResetCredits` (`CodexResetCredits.swift:366-420`), cached 600 s, process-wide 5 s spacing, per-profile cache `CodexResetCreditsState` (`:234-254`) | Never called from a timer or a loop over profiles (per-IP 429s) |
| ⇄ selector menu | `ActiveSelectorMenuModel.swift:97-99` (row "Usage limit resets: N available · expires … (as of …)", `resetsRowTitle` `:300-308`), fed by `OwnerRow.resetCreditsAvailable` / `resetsDetail` (`ProviderActiveSelection.swift:189-200, 467-470`) and `MenuBarManager.swift:4292-4294` (cached details only) | **Provider owner row only, Codex only**, shown only when count > 0 |
| Accounts inspector | `AccountsView.swift:475-478` mounts `CodexResetsCard` under the "Resets" fact (Codex profiles only) | The card: count line, "Usable now: N", Details (per-credit expiry), the gate reason in plain sight, the rule caption (`CodexResetsCard.swift:54-93`) |
| Activation (the only one) | "Use one usage limit reset…" button → `NSAlert` confirm naming the profile and evidence age → `activateReset(evidence:)` (`CodexResetsCard.swift:61-66, 109-132` → `CodexResetCredits.swift:471-528`) | Enabled only with count > 0 AND `readiness.isAtLimit` AND an own-endpoint measurement (`CodexResetsFormatting.canRedeem`, `CodexResetsCard.swift:169-172`). Never automatic |
| Post-spend | `invalidateAfterReset` clears the cache, the redeem id, the throttle stamps and the count; posts `.codexResetActivated` (`CodexResetCredits.swift:626-649`) | Percentages are left for the next measured fetch |
| Tile / popover / roster / fleet dots | **Not shown.** No reference in `MenuBarIconRenderer`, `PopoverContentView`, `DashboardView` or `DashboardRosterBands` | The count never reaches the menu bar |
| Copy | `Localizable.strings:859, 949, 1255-1280, 1304-1305` | "Usage limit resets: none or unknown" is the null wording |

---

## 5. Visualization proposal (idiom-matching, no menu-bar width cost)

Principle: **reuse the Codex shape. Generalize, don't fork.** `OwnerRow.resetCreditsAvailable`
/ `resetsDetail`, the selector row and the inspector card are already provider-shaped in
all but name. The Claude version fills the same slots.

- **Model.** Store a provider-neutral count on `ClaudeUsage`: available, next-grant use-by,
  measured-at, and eligibility. Either generalize the `codexResetCredits*` trio or add a
  parallel `limitResets*` trio. Keep a per-profile detail cache parallel to
  `CodexResetCreditsState`, holding grants, `clears`, `blocking`, `use_requires_limit`,
  `ends_at` and `next_grant_id`. **nil / ineligible-by-surface = unknown, never 0.**
- **Menu bar tiles and fleet dots: nothing.** No glyph, no badge, no width. Dot pitch,
  diameter, row pitch and column caps are untouched. Codex never put the count there either.
- **⇄ selector, Claude owner row** (mirrors `ActiveSelectorMenuModel.swift:97`), shown only
  with a known count > 0:

  ```
  ● Atlas            active · 96% week
    ↻ Limit resets: 2 · use by Oct 3 · refills session + weekly
  ```

- **Accounts inspector, "Resets" fact for Claude profiles.** A `ClaudeResetsCard` built from
  `CodexResetsCard`'s parts:

  ```
  Resets   Limit resets: 2 left                       Details   [Use one limit reset…]
           Next: "Welcome reset" · refills session + weekly · use by Oct 3
           ⚠ The account still has headroom; a reset now would be wasted.
           A reset refills this account's windows now; the weekly reset day stays Tue.
           Never used automatically.
  ```

  Unknown state, which is today's reality for every account:
  `Limit resets: unknown — Claude only reports them to Claude Code (clau.de/reset)`.
- **Confirm alert.** Echo the CLI's own wording: "Refills your {limits} now · your weekly
  reset day stays {week} · {n} left · use by {deadline}". Add the widget's evidence line (at
  limit, measured N s ago), as the Codex alert does. For an anytime grant with headroom,
  **do not offer the button at all.** The Codex rule "only at a measured limit" is stricter
  than the CLI's early-use confirm; keep it.
- **juniper_tide.** At most one caption on the same card ("Weekly session reset: available ·
  next {date}"). It has no count to bank and is only offered at a session wall.

---

## 6. What could NOT be established, and what would settle it

1. **Does any of these accounts hold a grant?** The widget's identity gets `surface` on
   every account (4 of 4 sampled), so the true count was not read.
   Settles it (either works):
   - The owner opens **claude.ai → Settings → Usage** (`clau.de/reset`) on an account and
     reports what it shows.
   - The owner runs `/limit-reset` in Claude Code on one account and answers **"No, keep
     it"**. The confirm dialog shows the count and deadline before anything is spent.

   A read presenting the CLI's client identity would also answer it. I did **not** do this:
   it means impersonating the CLI, and that is the owner's call.
2. **Is the claim surface-gated too?** Unknown until a claim is attempted from a non-CLI
   identity. Not to be tested without the owner's word, because on an eligible account a
   claim spends a grant.
3. **Does a grant refill the Fable weekly?** `clears` has no Fable-scoped key. Settle it by
   reading `clears` on a real grant and comparing Fable `limits[]` before and after a
   (owner-approved) reset.
4. **Which surface did the owner see "online today"?** The client code is unchanged since
   ≥ 2.1.277 (Sep 18), so it was a server-side enablement or the claude.ai web page. I could
   not inspect the web page: the browser extension was not connected in this session. Also
   unknown: which web endpoint claude.ai uses. It is plausibly the same `reset_rate_limits`
   under `claude.ai/api/organizations/…`, but that is unverified.
5. **Per-account flag state.** `tengu_cedar_ember` is absent and `tengu_nifty_lemur` is
   enabled, but only for the account the CLI is logged into now. The other accounts' flags
   are unknown.
6. **Server idempotency on `request_id`** is inferred from the client's retry logic, not
   observed.
7. **Side effects of the status read.** It is assumed to be a pure read: the CLI issues it
   automatically at every wall. Server-side experiment-exposure logging is possible and
   cannot be ruled out from the client.
8. **Team / org semantics** (`seat` reason, org-scoped claim path) were not tested. All
   local accounts are personal.
