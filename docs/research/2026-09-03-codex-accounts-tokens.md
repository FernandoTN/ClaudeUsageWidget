<!-- Research run 2026-09-03/04 (Grok 4.6, xhigh; read-only; no shell/HTTP, so citations are local files, the 2026-09-03 audit, public docs and RFCs). Cross-checked by the dispatching session against openai/codex source: codex-rs/cli/src/login.rs login_with_chatgpt -> clear_existing_auth_before_login -> logout_with_revoke(codex_home) revokes the refresh token found in THAT home (codex-rs/login/src/auth/revoke.rs, RFC 7009) before the new browser flow starts. -->

# Codex CLI accounts and tokens — implications for a multi-account widget

**Scope:** `codex-cli 0.153.0`, widget `CodexUsageService.swift`, live `~/.codex` on 2026-09-03/04. Secrets inspected only as shapes/lifetimes.

## Established facts (cited)

**OAuth is authorization-code + PKCE + local callback.** `~/.codex/log/codex-login.log` (2026-07-09): browser login; callback `path=/auth/callback has_code=true has_state=true state_valid=true`; exchange `issuer=https://auth.openai.com/` `token_endpoint=https://auth.openai.com/oauth/token` `redirect_uri=http://localhost:1455/auth/callback`; HTTP 200. That is RFC 7636 PKCE + a loopback redirect (RFC 8252), not device-code unless `--device-auth` is used. Public client id `app_EMoamEEZ73f0CkXaXp7hrann` is both the widget’s `oauthClientId` (`CodexUsageService.swift:31`) and the live JWT `client_id` / id-token `aud`.

**What `auth.json` stores (live file, 2026-09-04).** Top-level: `auth_mode` (`"chatgpt"`), `OPENAI_API_KEY` (null on a ChatGPT login), `tokens`, `last_refresh` (ISO-8601 with 6-digit fractional seconds — CLI-written). `tokens`: `id_token` (JWT), `access_token` (JWT), `refresh_token` (opaque, `rt.1.` prefix, not a JWT), `account_id` (UUID). `tokens.account_id` equals the id-token/access-token claim `https://api.openai.com/auth.chatgpt_account_id`. That UUID is what the widget sends as `ChatGPT-Account-Id` (`CodexUsageService.swift:652`). It is the ChatGPT **account**, not the platform org: the access token also carries `poid` = `org-…`, and the id token carries `organizations[]` (`id`, `is_default`, `role`, `title` e.g. `"Personal"`).

**Lifetimes (decoded claims, this machine).** Access token `iat`→`exp` = **864000 s = 10.00 days** (matches audit). Id token = **3600 s**. Refresh token has **no local `exp`**. Access-token `scp`: `openid profile email offline_access api.connectors.read api.connectors.invoke`. Id token carries `chatgpt_plan_type` (`"pro"` here), `chatgpt_account_id`, subscription start/until, and `organizations[]`. Docs: ChatGPT sign-in uses the Plus/Pro/Business/Edu/Enterprise plan ([developers.openai.com/codex](https://developers.openai.com/codex), [help.openai.com — Codex in ChatGPT](https://help.openai.com/en/articles/11369540-codex-in-chatgpt)); API-key login is **platform billing**, not that subscription.

**Refresh rotation is real.** CLI `last_refresh` moves while the access JWT is unchanged (widget comment + audit observation 4). The widget merges a rotated `refresh_token` when the token endpoint returns one (`CodexUsageService.swift:339–343`). RFC 6749: a successful refresh **may** issue a new refresh token; the old one is then unusable.

**Login/logout revoke is in the CLI, in the login crate.** Audit of binary 0.153.0: symbol `codex_login::auth::manager::logout_with_revoke`, URL `https://auth.openai.com/oauth/revoke`, referenced from `codex-rs/login/src/server.rs:671` (the **login** server, not only `codex logout`). RFC 7009: POST the token (typically the refresh token) + `client_id`; the AS **SHOULD** invalidate the whole grant (refresh + access). Live:

| Time (PDT 2026-09-03) | Event | Effect |
|---|---|---|
| 13:49:57 | `codex login` for account B rewrote `auth.json` | From 13:50:17, account A (different UUID; access JWT still in date until 09-11) 401s on `wham/usage` |
| 15:52 | `auth.json` vanished (`codex logout` or equivalent) | Both accounts 401 on usage **and** the refresh grant itself returns HTTP 401 |

That is grant death of the **displaced** session, not JWT expiry. `~/.codex/installation_id` exists (UUID). `$CODEX_HOME` is honored by the CLI; the widget hardcodes `~/.codex` (`CodexUsageService.swift:35–39`; audit M11).

**Usage.** Widget: `GET https://chatgpt.com/backend-api/wham/usage` with Bearer + `ChatGPT-Account-Id` (`CodexUsageService.swift:33, 646–657`). Parser (`:786–825`): `rate_limit.primary_window` / `secondary_window` with `used_percent`, `reset_at` or `reset_after_seconds`, `limit_window_seconds`; `plan_type` logged. Live 2026-07-29 and 2026-09-03: primary is **7-day** (`limit_window_seconds` ≥ 6 d or `window_minutes: 10080`), `secondary` null → widget `hasSessionWindow = false`. Local transcripts (`~/.codex/sessions/**/*.jsonl` `token_count.rate_limits`, 2026-09-03/04): `{limit_id:"codex", primary:{used_percent, window_minutes:10080, resets_at}, secondary:null, plan_type:"pro", credits}`. June 2026 transcripts still had 5h primary (`window_minutes:300`) + weekly secondary. `session_meta` has **no** `account_id`. `limit_id` is the product name `"codex"`, not per-account.

**Widget refresh vs CLI.** Widget POSTs JSON `{client_id, grant_type:refresh_token, refresh_token, scope:"openid profile email"}` (`:314–319`). Live access-token `scp` is **wider** (`offline_access` + connector scopes). RFC 6749 §6: an omitted `scope` keeps the grant; a supplied `scope` must be equal or narrower — this call can downscope.

**Dead-login code (post-incident).** Terminal refresh: `invalid_grant` / `invalid_client` / `unauthorized_client`, or HTTP 401 with no code (`refreshFailureIsTerminal`, `:497–503`). Usage 401/403 forces one cooldown-gated refresh; a 200 clears the flag (`recordUsageSuccess`). Apply gate is liveness, not JWT `exp` (`applyDecision`, `:574–585`).

## Unverified / inferred (labeled)

- **Inference — login revokes the current file’s grant, not “the whole machine.”** `logout_with_revoke` living in the **login** server plus the 13:49 A-dies-when-B-logs-in incident is enough to explain sequential `codex login` on one `CODEX_HOME`: the CLI revokes whatever refresh token is in that home’s `auth.json`, then writes the new family. RFC 7009 SHOULD also kill that grant’s access token — matching A’s immediate usage 401 while its JWT `exp` was still days away. This does **not** require per-`installation_id` revocation of every family ever minted on the Mac. A machine-wide bind is **unproven**; the experiment is: `CODEX_HOME=~/.codex-b codex login` as B and watch whether A’s tokens in default `~/.codex` still 200. If they do, isolation works.
- **Inference — refresh-token reuse detection.** Auth0-style rotation (OpenAI’s issuer looks like that family): redeeming an already-rotated RT returns `invalid_grant` and **may** revoke the whole family. The CLI error “refresh token was revoked” matches. Not proven from OpenAI docs. Practical consequence: widget and CLI must not redeem the same RT concurrently (audit M1).
- **Unknown — refresh-token lifetime.** No `exp` on the opaque RT. Families from 09-01 still had unexpired **access** JWTs on 09-03; that does not bound RT life. Treat RT as valid until revoke, reuse, or an undocumented idle timeout.
- **Unknown — exact `/oauth/revoke` body and server radius.** Binary has the URL; RFC 7009 shape is `token` + `token_type_hint=refresh_token` + `client_id`. Whether the POST includes `x-codex-installation-id`, and whether the AS revokes only that grant, the family, or every Codex session for the account, is **not** visible client-side. Observation (2) (both families dead after logout) is explained by two sequential revokes (13:49 displaced A, 15:52 revoked B) without account-global logout.
- **Inference — CLI on usage/responses 401.** Typical `codex-rs/core` path: refresh once, retry, then prompt login. Not re-read in this session.
- **Inference — `wham/usage` does not spend generation quota.** It is a dashboard GET; 6k+ transcript snapshots exist without a matching widget GET. Unproven. 429s exist (widget now types them `.apiRateLimited`); per-IP vs per-account split is **unmeasured**.
- **Inference — third-party refresh ToS.** The client id is public in `openai/codex`. Redeeming it is impersonating the official public client. Technical risk is rotation/reuse, not a secret leak. Policy risk is unofficial ChatGPT OAuth + unofficial `chatgpt.com` APIs ([OpenAI Terms](https://openai.com/policies/terms-of-use)). Prefer **adopt** the CLI’s write over extra redemptions.

## What differs for Codex vs Claude — and why

| | Claude Code | Codex CLI |
|---|---|---|
| Home | Keychain item `Claude Code-credentials*` + `~/.claude/.credentials.json` | Single file ` $CODEX_HOME/auth.json` (default `~/.codex`) |
| Identity stamp | No id in the JSON; widget calls `api.anthropic.com/api/oauth/profile` → `claudeAccountUUID` | `tokens.account_id` = ChatGPT account UUID; also in JWT |
| Access-token life | Hours (CLI `expiresAt`) | **10 days** — expiry is a terrible liveness signal |
| Refresh | Rotates; widget + CLI share one Keychain slot | Rotates; CLI **and** widget both write the same file if the account is active |
| Login N accounts on one home | New `/login` replaces the shared item; old copies can still refresh **until** that grant is revoked | `codex login` / `logout` call **`/oauth/revoke`** on the current file → displaced copies 401 even with a valid-looking JWT (live 13:49 / 15:52) |
| Isolation knob | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` (separate `auth.json`, `installation_id`, sessions) |
| Usage API | `oauth/usage` (5h + weekly + per-model); 429 is information | `wham/usage` — **weekly-only** today; 5h window gone since ~2026-07-29 |
| Zero-network fallback | Transcripts + `cachedUsageUtilization`; account uuid present | Rich `token_count.rate_limits`, but **no account field**; only trustworthy for whoever currently owns that home |
| Dead flag | 400/401/403 on refresh (Claude still broader) | Must be **grant** verdict only (`invalid_grant` / token-endpoint 401). Usage 401 is not death |
| API-key mode | Console key ≠ Max subscription | `--with-api-key` = platform billing; `wham/usage` will not show ChatGPT plan bars |

## Recommendations for the widget

**(a) Safe procedure for several Codex accounts on one Mac.** Do **not** `codex login` / `codex logout` repeatedly in default `~/.codex`. Each login/logout revokes the grant sitting in that file; copies in the widget die with it (13:49). For each account *i*:

1. `CODEX_HOME=$HOME/.codex-accounts/<label> codex login` (browser/PKCE). First run mints a **new** `installation_id` + `auth.json`.
2. In the widget: Sync **from that path** (today Sync only reads `~/.codex` — needs a path picker or `CODEX_HOME`).
3. Never login/logout in a home whose family you still need.
4. Default `~/.codex` is the **switcher slot** the vanilla `codex` binary uses. After import, only the widget (or a wrapper that sets `CODEX_HOME`) should write it.
5. Skip `--with-api-key` for subscription tiles. Skip `--with-access-token` unless a refresh token is also stored — access JWTs die in 10 days with no heal.

**(b) Per-account `CODEX_HOME`.** Yes for **onboarding**; not required as the runtime layout. Keep storing one `auth.json` blob per profile in Keychain (current design). Honor `CODEX_HOME` when reading/writing the **active** CLI home (fix M11). Optional: remember `codexHomePath` per profile for re-sync. Switching still writes the active blob to the user’s default home so `codex` without env works. Confirm with the experiment in Unverified: if B’s isolated login 401s A, isolation failed and OpenAI is binding something machine-global — then N live ChatGPT OAuth families on one Mac are not possible.

**(c) Refresh cadence and single-writer.** Inactive profiles: the widget is the only writer — refresh when the access JWT is inside the 2-minute `freshFor` window, persist Keychain, do **not** write `auth.json` unless `account_id` matches. Active owner: **CLI is the writer.** Adopt `auth.json` first (`adoptAuthFileIfSameAccount`, already compares `last_refresh`). Redeem only if the file is stale **and** the access JWT is actually near expiry. Never 401-force-refresh with a 10-year `freshFor` while `last_refresh` is recent (that is the reuse-detection footgun). After any redemption of the owner, write `auth.json` immediately and fail loudly if the write fails. **Omit `scope` on refresh** (or send the live `scp`); today’s `"openid profile email"` can downscope `offline_access`. One in-flight redemption per profile (already). Do not refresh two profiles that share an `account_id`.

**(d) Dead-login criteria.** Flag **only** on: refresh body `error=invalid_grant` (or `invalid_client` / `unauthorized_client`); or HTTP 401 from `auth.openai.com/oauth/token`. Clear on any 200 from `wham/usage`, any successful refresh, same-`account_id` adoption of a fresher file, or manual Sync. Do **not** flag on: usage 401/403 (probe + one cooldown-gated refresh first); 429; 5xx; transport; missing `auth.json` (logout of the current slot only); JWT `exp` in the future. Apply-to-CLI gate: refuse on measured usage 401/403 or expired JWT; on unknown, refuse only if already flagged. Missing `auth.json` is not “all Codex profiles are dead.”