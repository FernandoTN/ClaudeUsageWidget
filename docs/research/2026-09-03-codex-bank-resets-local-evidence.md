# Codex "bank resets" — what they actually are, and what the widget can show

**Date:** 2026-09-03 · **Status:** read-only investigation, nothing modified, no reset triggered
**Local CLI under test:** `codex-cli 0.153.0` (native binary
`/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`)

---

## 1. Official name

The feature is **"usage limit resets"** in user-facing copy and
**rate limit reset credits** in the wire/protocol vocabulary. There is no
"bank" anywhere in the product; that is informal shorthand. Evidence:

| Surface | Exact string | Source |
|---|---|---|
| Slash command help | `view account usage or use a usage limit reset` | `codex-rs/tui/src/slash_command.rs:115` (`SlashCommand::Usage`) |
| Usage menu subtitle | `View account usage or redeem an earned reset.` | `codex-rs/tui/src/chatwidget/usage.rs:51` |
| Menu item | `Redeem usage limit reset` | `usage.rs:64` |
| Count copy | `You have {n} usage limit reset(s) available.` | `usage.rs:37-41`, `reset_label()` at `usage.rs:579-585` |
| Idle hint | `• You have 2 usage limit resets available. Run /usage to use one.` | snapshot `…__rate_limit_reset_available_hint.snap` |
| Picker title | `Usage limit resets` | `usage.rs:111`, `usage.rs:210` |

**How the CLI surfaces it:** `/usage` opens a two-item menu — "Show usage" and
"Redeem usage limit reset". Choosing the second opens a picker listing each
credit as e.g. `Full reset (Weekly + 5 hr)` with `Expires 09:39 on 18 Jun 2026.`,
then a confirmation step. Rendered proof:
`codex-rs/tui/src/chatwidget/snapshots/codex_tui__chatwidget__tests__rate_limit_reset_popup_states.snap`
and `…__usage_command_menu.snap`. It is **not** on `/status`.

The binary carries the same identifiers — `strings` on the native binary yields
`struct RateLimitResetCreditsSummary with 1 element`, `RateLimitResetCreditDetails with 7 elements`,
`ClientRequest::ConsumeAccountRateLimitResetCredit`, and the four literal URL paths in §2.

---

## 2. Endpoints (all four literals present in the local binary)

Base URL for ChatGPT-auth accounts is `https://chatgpt.com/backend-api`.
`PathStyle` picks the prefix (`codex-rs/backend-client/src/client/rate_limit_resets.rs:126-152`):

| Purpose | ChatGPT path style | Codex-API path style | Method |
|---|---|---|---|
| Usage + available count | `/wham/usage` | `/api/codex/usage` | GET |
| Credit detail list | `/wham/rate-limit-reset-credits` | `/api/codex/rate-limit-reset-credits` | GET |
| **Redeem one** | `/wham/rate-limit-reset-credits/consume` | `/api/codex/rate-limit-reset-credits/consume` | **POST** |

Headers are the same ones the widget already sends: `Authorization: Bearer <access_token>`
and `ChatGPT-Account-Id: <tokens.account_id>`.

---

## 3. Where COUNT and EXPIRY live

### 3a. Count — already in the payload the widget fetches today

`GET /backend-api/wham/usage` carries a top-level `rate_limit_reset_credits`
object. **Verified live** (2026-09-03, all five local Codex homes, HTTP 200):
the key is present and currently `null` on every account, because all five have
zero credits.

```
"rate_limit_reset_credits": null,
```

When non-zero it is `{"available_count": <int>}` — a single field. Sources:
`RateLimitResetCreditsSummary` in `codex-rs/backend-client/src/types.rs:22-25`, and the
test fixture asserting `Some(RateLimitResetCreditsSummary { available_count: 3 })`
at `codex-rs/backend-client/src/client/rate_limit_resets_tests.rs:100`.

The CLI relies on this: `GetAccountRateLimitsParams.exclude_reset_credit_details`
is documented as *"Skip the separate reset-credit detail lookup for background
usage polls. The usage response still includes the available count"*
(`codex-rs/app-server-protocol/src/protocol/v2/account.rs:320-323`).

### 3b. Expiry — only in the detail endpoint

`GET /backend-api/wham/rate-limit-reset-credits`. **Verified live**, HTTP 200:

```json
{
  "available_count": 0,
  "credits": [],
  "history_enabled": false,
  "immediate_reset_purchase_eligible": false,
  "total_earned_count": 0
}
```

Each element of `credits[]`, from the canonical fixture at
`rate_limit_resets_tests.rs:104-124` (a superset of what the Rust type consumes):

```json
{
  "id": "credit-1",
  "reset_type": "codex_rate_limits",
  "status": "available",
  "granted_at": "2026-06-17T00:00:00Z",
  "expires_at": "2026-07-17T00:00:00Z",
  "redeem_started_at": null,
  "redeemed_at": null,
  "profile_image_url": "https://example.test/avatar.png",
  "profile_user_id": "@friend",
  "title": "Full reset (Weekly + 5 hr)",
  "description": "Ready to redeem"
}
```

Field contract (`types.rs:27-41`, `account.rs:361-376`):

- `id` — opaque string, the thing you pass to redeem a specific credit.
- `reset_type` — `"codex_rate_limits"`; anything else maps to `Unknown`.
- `status` — `available` | `redeeming` | `redeemed` | unknown.
- `granted_at` — **RFC 3339 string** on the wire; the CLI parses it to a Unix second.
- `expires_at` — RFC 3339 string, **or `null` meaning it never expires**.
- `title` / `description` — backend-authored display copy, nullable. The TUI falls
  back to `"Full reset"` / `"Reset your current usage limits."`
  (`codex-rs/tui/src/chatwidget/reset_credits.rs:45-57`).

`available_count` can exceed `credits.length` — the backend may cap the list
(`account.rs:352-356`). Sort available credits by `expires_at` ascending, treating
`null` as last; that is exactly what the CLI does (`reset_credits.rs:28`).

**Three live fields the open-source client ignores** (serde drops unknowns), so
they are undocumented but real: `total_earned_count` (lifetime earned),
`history_enabled`, and `immediate_reset_purchase_eligible` — the last strongly
implies a paid instant-reset path exists server-side. Only `total_earned_count`
appears anywhere in the repo, and only inside tests.

**How credits are earned:** the `profile_user_id: "@friend"` and
`profile_image_url` fields plus the "earned reset" wording indicate they are
granted/gifted per account rather than purchased. Not confirmed further.

---

## 4. Can a reset be TRIGGERED by an API call? Yes.

**Not called during this investigation.** From source only:

```
POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
Content-Type: application/json

{ "redeem_request_id": "<idempotency key, UUID recommended>",
  "credit_id": "<optional; omit to let the backend pick the next credit>" }
```

`credit_id` is omitted entirely when absent (`skip_serializing_if`), it is not
sent as null — `rate_limit_resets.rs:15-20`. Note the body key is
`redeem_request_id`, while the app-server protocol calls the same value
`idempotencyKey` (`account.rs:403-410`); the processor passes one straight to the
other (`account_processor/rate_limit_resets.rs:66-76`).

Response (`types.rs:105-118`):

```json
{ "code": "reset", "credit": {...}, "windows_reset": 2 }
```

`code` ∈ `reset` | `nothing_to_reset` | `no_credit` | `already_redeemed`.
`windows_reset` is how many rate-limit windows were cleared. The CLI ignores the
`credit` object. Meanings, from `account.rs:423-434`:

- `reset` — a credit was consumed and eligible windows were reset.
- `nothing_to_reset` — no current window is eligible (UI: *"Your usage does not need a reset right now."*).
- `no_credit` — account has none available.
- `already_redeemed` — that same idempotency key already succeeded.

Preconditions the CLI enforces before allowing it: the account must be ChatGPT-auth,
not API-key (`rate_limit_resets.rs` → `auth.uses_codex_backend()`), the
idempotency key must be non-empty, and `credit_id` must not be an empty string.
Client timeout is 10 s for consume, 5 s for the detail list.

---

## 5. Operational hazards for the widget

1. **The detail endpoint is aggressively rate limited.** Probing five accounts
   back to back, the first two returned HTTP 200 and the remaining three returned
   **HTTP 429**. The limit appears to be per-IP, not per-account, since separate
   accounts tripped it. Do not poll it. `/wham/usage` did **not** 429 across all
   five accounts in the same burst.
2. **Never send `x-openai-codex-luna-reserve: 1`.** That header on `/wham/usage`
   opts the client into "Luna Reserve", and the source is explicit that it is
   *"Opt in only for clients that can apply Reserve, not for passive account usage
   readers"* — it also lets the backend record experiment exposure
   (`rate_limit_resets.rs:24-33`, `account.rs:311-317`). A widget is a passive reader.
3. **`ordinary_usage_allowed`** is a backend permission field, and the protocol
   warns clients *"must not infer recovery from percentages or reset times"*
   (`account.rs:330-332`). Worth reading if the widget ever gates UI on "am I blocked".
4. Timestamps are **RFC 3339 strings** in `credits[]`, unlike the `reset_at`
   Unix seconds the widget already parses in `rate_limit.primary_window`. Two
   different formats in the same feature.

---

## 6. Unverified

- The non-null shape of `rate_limit_reset_credits` in `/wham/usage` was **not**
  observed live — every local account has zero credits, so it was `null` in all
  five reads. The shape `{"available_count": N}` rests on the Rust type and its
  test fixture, which is strong but not a live observation.
- A populated `credits[]` array was never seen live, same reason.
- `immediate_reset_purchase_eligible` semantics are a guess from the name.
- How credits are earned is not established.
- The consume endpoint was never called, so its live response is unconfirmed.
- Whether `/wham/usage` alone is enough to drive an "Activate reset" button is
  untested at non-zero balance.

---

## 7. Recommendation: ship display-only first

The widget currently has **no** reset-credit handling — a grep for
`reset_credit|resetCredit|rate-limit-reset|available_count|availableCount`
across all `*.swift` returns nothing.

**Phase 1, display-only, zero extra network cost.** `CodexUsageService` already
fetches `/wham/usage` per profile (`CodexUsageService.swift:34`, parse at
`:1000-1041`). Add one optional read in the existing parse:

```swift
let resetCredits = (json["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? Int
```

Treat `null`/absent as "unknown", not zero — `null` is what a zero-credit account
returns today, so the two are indistinguishable from this endpoint alone. Show a
badge only when the value is > 0. This costs no new request and no new failure mode.

**Phase 2, expiry detail — only on demand.** Call
`/wham/rate-limit-reset-credits` **only when the user opens the Codex account
detail view**, never on the refresh timer, and cache the result. The 429 observed
above makes a polled fetch actively harmful across five accounts.

**Phase 3, "Activate reset" — defer, and gate it behind a confirmation.** The
POST is well-specified and safe to implement, but it spends a scarce
non-refundable credit. If built: generate a fresh UUID per attempt, reuse that
same UUID on retry, pass `credit_id` from the picker so the user chooses which
credit, and surface all four outcome codes distinctly — `nothing_to_reset` in
particular means the credit was *not* spent and the user should try later.

**Minimal fetch to get value today:** one extra dictionary lookup in the response
the widget already parses. Everything beyond that is optional.
