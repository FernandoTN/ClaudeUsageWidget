<!-- Research run 2026-09-03/04 (Grok 4.6, xhigh; read-only tools; web access if available). Companion to 2026-09-03-codex-bank-resets-local-evidence.md, which is the authoritative source for endpoint shapes (verified live + from openai/codex source). -->

# Codex “bank resets” — research report (2026-09-03)

**Scope:** `codex-cli 0.153.0` (native binary under `@openai/codex-darwin-arm64`), widget `CodexUsageService`, live `~/.codex/sessions` JSONL, extracted `openai/codex` sources in the job tmp (`bc_types.rs`, `rlr_tests.rs`, `tui_usage.rs`, `asp_account.rs`). No consume POST was issued. Secrets inspected as shapes only.

## Established facts (cited)

**Name.** OpenAI’s product copy is **“usage limit reset(s)”**; the wire/protocol name is **rate-limit reset credits**. There is no “bank” string in the CLI (`strings` dump `codex_strings.txt`; TUI `tui_usage.rs`). TUI: `/usage` subtitle *“View account usage or redeem an earned reset.”*; menu item *“Redeem usage limit reset”*; picker title *“Usage limit resets”*; count *“You have {n} usage limit reset(s) available.”* (`tui_usage.rs:37–64, 111, 210, 579–584`). Idle hint: *“You have N usage limit reset(s) available. Run /usage to use one.”* (`tui_usage.rs:555–566`). **Not on `/status`.** App-server RPCs: `account/rateLimits/read`, `account/rateLimitResetCredit/consume` (binary strings).

**Who gets them.** ChatGPT-auth only. Binary: *“chatgpt authentication required for rate limit reset credits”* / *“api key auth is not supported”*. README: Codex via ChatGPT **Plus, Pro, Business, Edu, or Enterprise** ([help.openai.com/en/articles/11369540-codex-in-chatgpt](https://help.openai.com/en/articles/11369540-codex-in-chatgpt)). Client tests deserialize a `plus` usage payload with `available_count: 3` (`rlr_tests.rs:93–101`). Live session `plan_type` here is `"pro"`. Accrual rate / per-period cap is **not** in the client. Credits are **earned** (`NoCredit` = *“no earned reset credits”*, `asp_account.rs:428`).

**What a redeem does.** Outcome `Reset`: *“A reset credit was consumed and the eligible rate-limit windows were reset”* (`asp_account.rs:424–425`). Fixture consume body returns `"windows_reset": 2` with a credit titled `"Full reset (Weekly + 5 hr)"` (`rlr_tests.rs:115, 157–168`). Fallback TUI copy if the backend omits title: *“Reset your current usage limits.”* (binary). Today’s `wham/usage` on this machine is **weekly-only** (`limit_window_seconds` 604800, `secondary_window` null — widget parser `CodexUsageService.swift:1020–1038`; live JSONL 2026-09-04).

**Where the count lives — already on the GET the widget uses.**

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <tokens.account_id>
```

(`rlr_tests.rs:57–70`; widget `CodexUsageService.swift:34, 862–868`.) Extra top-level field `rate_limit_reset_credits`: `null` or `{"available_count": <int>}` (`bc_types.rs:22–25, 49`; `asp_account.rs:339`; `rlr_tests.rs:93–101`). Widget parser **drops it** (`parseUsageResponse` only reads `rate_limit.*` windows — `CodexUsageService.swift:1000–1066`; grep of `*.swift` for `rate_limit_reset_credits` is empty). `token_count.rate_limits` in `~/.codex/sessions/**/*.jsonl` has **no** reset-credit field (live 2026-09-04: `primary` / `credits{has_credits,unlimited,balance}` / `plan_type` — that `credits` object is **API-credit balance**, always `{has_credits:false, unlimited:false, balance:"0"}` here).

**Expiry — sibling GET only.**

```
GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
```

(`rlr_tests.rs:62–65`.) Response type `RateLimitResetCreditsDetails`: `{credits[], available_count}` (`bc_types.rs:27–42`). Fixture row:

```json
{
  "id": "credit-1",
  "reset_type": "codex_rate_limits",
  "status": "available",
  "granted_at": "2026-06-17T00:00:00Z",
  "expires_at": "2026-07-17T00:00:00Z",
  "title": "Full reset (Weekly + 5 hr)",
  "description": "Ready to redeem"
}
```

(`rlr_tests.rs:103–128`; extra keys `redeem_started_at`, `redeemed_at`, `profile_image_url`, `profile_user_id`, `total_earned_count` are on the wire; the Rust struct keeps only the seven fields.) `expires_at` is RFC 3339 **or null = never expires** (`asp_account.rs:371–373`; fixture credit-2). `available_count` may exceed `credits.length` (backend may cap the list — `asp_account.rs:352–356`). Detail GET times out → CLI *falls back to the usage response* (binary).

**Trigger — implemented in the official CLI.**

```
POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
Authorization: Bearer <access_token>
ChatGPT-Account-Id: <account_id>
Content-Type: application/json

{"redeem_request_id": "<UUID>", "credit_id": "<optional>"}
```

(`rlr_tests.rs:66–90`.) Omit `credit_id` entirely when unset (not `null`) so the backend picks the next credit. TUI generates a UUID at confirmation and **reuses it on retry** (`tui_usage.rs:241–261, 405–421`). Response: `{ "code": "reset"|"nothing_to_reset"|"no_credit"|"already_redeemed", "windows_reset": <int>, "credit": {...} }` (`bc_types.rs:106–118`; CLI ignores `credit`). After `reset`/`already_redeemed` the TUI shows *“Usage reset. Checking your remaining resets…”* then *“Usage reset. You have N usage limit reset(s) left.”* and refreshes snapshots (`tui_usage.rs:370–463`). `nothing_to_reset` → *“Your usage does not need a reset right now.”* (credit **not** spent). `no_credit` → *“No usage limit resets are available.”* Codex-API twins (API-key path): `/api/codex/usage`, `/api/codex/rate-limit-reset-credits`, `…/consume` (`rlr_tests.rs:44–56`).

**Docs.** Feature is specified in **`openai/codex`** (`codex-rs/backend-client`, `codex-rs/tui`, `codex-rs/app-server-protocol`). No help.openai.com article *about reset credits* appears in the 0.153.0 binary (only [11369540](https://help.openai.com/en/articles/11369540-codex-in-chatgpt) for plan inclusion, plus unrelated help IDs). This session could not fetch the live help/developers pages.

## Unverified / inferred (labeled)

- **Inference — accrual.** `profile_user_id: "@friend"` plus “earned reset” wording ⇒ grants/gifts, not a published monthly allotment. How many, which plans, and the grant rule are **unknown**.
- **Inference — 30-day life.** Fixture `granted_at`→`expires_at` is 30 days; not a documented SLA. `null` expiry is first-class.
- **Inference — account-global.** Requests are keyed by `ChatGPT-Account-Id`; usage windows are account-level, so a redeem would clear windows for **every Codex session of that account**, not one TUI. Unproven against a second machine.
- **Inference — waste-safe.** `nothing_to_reset` is a distinct code and the TUI does not decrement the count; backend appears not to spend a credit when no window is eligible. Consume was **not** called here.
- **Inference — ToS.** Same unofficial `chatgpt.com/backend-api` surface the widget already GETs. A third-party **POST consume** is a mutating impersonation of the official public client. Policy risk: [OpenAI Terms](https://openai.com/policies/terms-of-use). Prefer displaying count; if redeeming, match the CLI’s body/headers/idempotency exactly.
- **Unverified this session:** live `wham/usage` `rate_limit_reset_credits` values, live detail GET, 429 on the detail endpoint. Those live probes are claimed in `docs/research/2026-09-03-codex-bank-resets-local-evidence.md` (all five local homes: usage key present and `null`; detail `{available_count:0, credits:[], history_enabled:false, immediate_reset_purchase_eligible:false, total_earned_count:0}`; detail GET 429 after two accounts). This session did not re-hit the network.
- **Unverified:** exact `x-openai-codex-luna-reserve` header name (not in this binary’s strings). Protocol *does* have `supportsLunaReserve` (`asp_account.rs:316–319`); a widget should not opt into Luna Reserve.

## Widget recommendation

| Need | How | Cadence |
|---|---|---|
| Count per Codex account | Parse `rate_limit_reset_credits.available_count` from the existing `GET /wham/usage`. Treat `null`/absent as “none shown”, not a hard zero (zero-credit accounts serialize as `null`). Show a badge only when `> 0`. | Current sweep — **no extra request** |
| Expiry / titles | `GET /wham/rate-limit-reset-credits` **on demand** (popover / Codex account page), never on the 30s timer. Cache. Sort available rows by `expires_at` ascending, `null` last. | User-opened detail only |
| “Activate reset” | **Implementable**, same POST as the CLI. Gate: ChatGPT-auth profile, `available_count > 0`, confirmation naming the credit. Fresh UUID per attempt; reuse on retry; send `credit_id` from the picker. Surface all four `code`s. Then re-GET `/wham/usage` (windows + remaining count). | User click only |

**Do not** poll the detail endpoint from the sweep (claimed 429). **Do not** read session JSONL for this — `token_count` has no reset-credit field.

**What the CLI would show afterwards:** `/usage` → Redeem → picker (`title` or “Full reset”, `Expires …` or no expiry) → “Use this reset?” → “Resetting your usage…” → “Usage reset. You have N usage limit reset(s) left.” plus refreshed window percentages. `nothing_to_reset` keeps the credit. Ship **display of `available_count` first**; redeem is a scarce, non-refundable account-wide action.