# Why Claude logins keep "expiring": two causes, and neither is the running sessions

**Date:** 2026-10-02 · **Status:** read-only investigation. No app code was changed. No
token was refreshed, redeemed, revoked or applied, no account was switched, and nothing was
written to the Keychain, the preferences, `~/.claude.json` or `~/.claude/.credentials.json`.
**Resolved** on 2026-10-09: see section 8.
**Base:** `origin/main` `2a3db9b`
**Claude Code under test:** `2.1.287` (native binary `~/.local/share/claude/versions/2.1.287`).
Every live session and the background daemon ran this version. `2.1.285` and `2.1.286` are
also on disk and contain the same refresh-safeguard strings.
**Times** are local (PDT, UTC−7) unless marked `Z`.

Account names are replaced with the synthetic roster (Atlas (dev), Cedar, Delta, Echo, Fjord,
Granite, Harbor, Iris, Juniper (dev)). The assignment is for this note only and does not
match earlier documents. Tokens are never shown. Where a token is identified, it is by the
first 12 hex characters of its SHA-256.

Each finding is labelled **VERIFIED** (read directly from code, a log line or a stored
value) or **INFERRED** (a conclusion drawn from verified facts).

---

## Verdict

**The hypothesis is refuted.** Running Claude Code sessions do not keep refreshing the
account they started on, and they cannot invalidate the copy the widget saved at switch
time. A session re-reads the shared store before every refresh and redeems only the refresh
token that is in the store at that moment.

Eight logins died in eight days for two unrelated reasons:

| Cause | Deaths | What it is |
|---|---|---|
| **A. The login reached the end of its lifetime** | 2 verified, 4 consistent but unverifiable | Every Claude Code login carries a server-enforced deadline (`refreshTokenExpiresAt`). After it, the refresh grant returns HTTP 400 and only `/login` renews it. With 24 logins whose deadlines are spread over about four weeks, close to one lapses per day. The widget never reads the field. |
| **B. The widget rotated a token it had just handed to the CLI** | 1 verified, 1 inferred | The 90 % preflight and the 90 % auto-switch fire from the same usage reading. The preflight refreshes the candidate's token while the activation applies the old one. The CLI is left holding a consumed refresh token, and the switch-away re-sync then overwrites the widget's good token with the dead one. |

**Write-back answer (question 1):** a session does write a refreshed token back to the
shared store, but only through a compare-and-swap on the refresh token it redeemed, under a
cross-process lock. A session that started under one account cannot overwrite the active
account's credential with another account's token. **VERIFIED** in the 2.1.287 code.

---

## The eight deaths

Rows are in the order of the orchestrator's table.

| # | Account | Reported death | State at death | Stored access-token expiry | Recorded login deadline | Cause |
|---|---|---|---|---|---|---|
| 1 | Cedar | 09-25 06:49 | inactive | replaced by a later `/login` | replaced (now 10-22 15:54) | A, unverifiable |
| 2 | Delta | 09-25 22:28 | inactive | replaced | replaced (now 10-24 12:11) | A, unverifiable |
| 3 | Echo | 09-27 ~10:00 | **active**, 6 sessions failed 09:56:04–09:59:48 | 09-27 10:34:06 | 10-07 03:09 (not reached) | B, **INFERRED** |
| 4 | Fjord | 09-29 07:40 | inactive | replaced | replaced (now 10-27 22:48) | A, unverifiable |
| 5 | Granite | 09-29 07:55 | inactive | replaced | replaced (now 10-28 12:07) | A, unverifiable |
| 6 | Harbor | ~09-29 | inactive, excluded from rotation | 09-29 15:42:09 | **09-29 14:47:10** | A, **VERIFIED** |
| 7 | Juniper (dev) | 10-02 05:24 (first 401 at 05:31) | **active**, 7 sessions failed 05:20:18–05:23:59 | 10-02 05:51:37 | 10-16 13:58 (not reached) | B, **VERIFIED** |
| 8 | Iris | 10-02 08:38 | inactive since 07:13 | 10-02 08:33:41 | **10-02 04:45:41** | A, **VERIFIED** |

The two causes leave different fingerprints in the stored credential:

- **Cause A:** the recorded deadline is in the past, and the login is flagged dead at the
  first refresh attempt after it. The access token ran its full eight hours. No session
  ever failed on the account.
- **Cause B:** the recorded deadline is still in the future. The account died while it was
  the active login, with a wave of `Login expired · Please run /login` in the session
  transcripts, and the stored access token still had part of its hour left.

### Why "dies shortly after being active" looked true

It is an artifact of when the widget notices, not of when the login dies.

- Under cause A the widget finds out at the first refresh attempt after the deadline, which
  is when the stored access token expires. Access tokens live eight hours, and the preflight
  refreshes a candidate shortly before it becomes active, so many access-token expiries fall
  a few hours after an active stint. Iris's "85 minutes after rotating off" is its access
  token (issued 00:33:41) reaching eight hours. Its login had already lapsed at 04:45:41,
  **before** the 05:24 activation.
- Under cause B the account dies within seconds of becoming active, not after leaving.
  Juniper was switched in at 05:20:08 and the first session failed at 05:20:18. The 05:31
  timestamp in the table is only the widget's own first 401.
- Harbor is excluded from rotation and had not been active at all. It died on its deadline.

**29 of 32 sessions predating the 07:13 switch** is true and irrelevant: those sessions
adopted the new login on their next request (section 1) and never refreshed Iris's token.
The shared Keychain token's expiry stayed at 08:33:41 for Iris's whole 05:24–07:13 stint,
which means nobody refreshed it. **VERIFIED** from the widget's
`Using system Keychain credentials (expires …)` line, logged twice per sweep.

---

## 1. How Claude Code reads, refreshes and writes credentials

Read from the JavaScript embedded in the 2.1.287 binary (about 41 MB of readable source at
byte offset 177,839,745). Function names are minified, so each is given with a stable string
that can be searched for.

### The store

**VERIFIED.** The store is the Keychain item `Claude Code-credentials` (account = the macOS
user) with `~/.claude/.credentials.json` as a fallback.

- A read shells out to `security find-generic-password … -w` with a 2-second timeout and
  caches the result for 30 seconds.
- The file is read only when the Keychain has no item or the read fails.
- A write shells out to `security add-generic-password -U`. It writes the Keychain only,
  and falls back to the file only if the Keychain write fails outright. Otherwise the file
  is left as it was (it is deleted when the Keychain read had been empty).

### When a session reads

**VERIFIED.** Not once at startup, and not blindly on every request. A session keeps the
credentials in memory and runs a refresh check (`$i` → `gl`; 27 call sites in 18 modules,
including the code that builds request credentials) before API work. That check:

1. Stats `~/.claude/.credentials.json`. If its mtime differs from the last one seen
   (`lastCredentialsMtimeMs`), the session drops its in-memory copy and its Keychain cache
   and reads the store again. The widget rewrites that file on every switch, so this is how
   the fleet follows a switch at its next request.
2. Returns immediately if the access token is more than 5 minutes from expiry
   (`_F`: `now + 300000 >= expiresAt`).

### When the access token expires

**VERIFIED.** The session never refreshes from memory. In `gl`:

1. It records the access token it entered with, clears its caches and reads the store
   fresh. If the store's access token is different, it adopts the store and stops
   (`tengu_oauth_token_refresh_race_resolved`). A session that still holds the previous
   account's token takes this exit. It adopts the new account and redeems nothing.
2. Otherwise it takes a cross-process lock (`~/.claude/.oauth_refresh.lock`, with a legacy
   lock beside it), clears its caches, reads the store again under the lock, and repeats
   the same comparison.
3. Only then does it post **the refresh token it just read from the store** to
   `https://platform.claude.com/v1/oauth/token`.

A 401 from the API follows the same shape (`wK`): re-read the store; if the store's access
token differs from the one that failed, adopt it; otherwise force the refresh above.

### Does it write the refreshed token back?

**VERIFIED.** Yes, through a compare-and-swap (`WQn`, string
`OAuth refresh CAS save failed`):

```js
zn().mutate((K) => {
  let G = K.claudeAiOauth?.refreshToken;
  if (!(K.claudeAiOauth != null && (G === "" || G === postedRefreshToken)))
    return adoptedSibling = true, K;          // store changed under us: write nothing
  return { ...K, claudeAiOauth: merge(K.claudeAiOauth, refreshedTokens) };
})
```

The new tokens are written only if the store still holds the refresh token that was
redeemed (or the empty dead-marker). If the widget switched the store to another account
while the request was in flight, the write is skipped
(`tengu_oauth_refresh_save_adopted_newer_write`) and the session adopts the store.

So **the active account's credential cannot be overwritten with another account's token.**
The worse bug the brief warned about does not exist in this CLI.

What remains is narrow: a refresh already in flight at the instant of a switch redeems the
outgoing account's refresh token and then discards the result, which would strand that
account. It needs a session to be refreshing in the same one or two seconds as a switch.
It was not observed. In the retained log the CLI performed no refresh at all, because the
widget's preflight keeps every token more than an hour fresh at switch time.

### What the CLI does when the refresh grant is refused

**VERIFIED.** On `invalid_grant` it remembers the refresh token as dead and overwrites the
store's login with a dead-marker (`VQn`, `tengu_oauth_refresh_token_marked_dead_invalid_grant`):

```js
{ ...h, refreshToken: "", accessToken: "", expiresAt: 0 }
```

It does this only if the store still holds that refresh token. Every session then shows
`Login expired · Please run /login`. This marker matters in section 3.

### Other findings

- **`/login` does not revoke the login it replaces. VERIFIED.** The normal path calls the
  logout routine with `preserveInProcessTokens: true`, which skips the revoke call.
  `/logout` does revoke the stored refresh token server-side (`POST …/oauth/token/revoke`),
  as does the Console-profile login path. Running `/logout` while a fleet account is the
  shared login would kill that account. The command history shows no `/logout`.
- **The background daemon runs its own proactive refresh** a few minutes before expiry
  (`[supervisor] auth: proactive refresh …` in `~/.claude/daemon.log`). It goes through the
  same locked path. Its last successful refresh was on 08-30. Since then every attempt
  logged `token still valid`, because the widget refreshes first.

---

## 2. Cause A: the login has a deadline, and the widget does not look at it

### The evidence

**VERIFIED.** Each stored credential has a `claudeAiOauth.refreshTokenExpiresAt` field. The
CLI sets it from the token endpoint's `refresh_token_expires_in` (30 days if the server
sends none at login), keeps the previous value when a refresh response carries none, and
shows a notice from it:

> Your login expires in N days · run /login to renew

The notice appears inside three days (`oauth-expiry`) and is high-priority inside one. The
fleet never sees it: it is drawn only in an attended session and only for the account that
is active at that moment.

**VERIFIED.** The widget never reads the field. `grep -rn refreshTokenExpiresAt "Claude Usage"`
returns nothing. `refreshOAuthToken` (`ClaudeCodeSyncService.swift:594-645`) copies
`access_token`, `refresh_token`, `expires_in` and `scope` from the response and ignores
`refresh_token_expires_in`, so the stored field keeps the last value the CLI wrote.

**VERIFIED.** The field was read (value only, never the tokens) for all 24 Claude logins at
09:28 on 10-02:

| Group | Count | Recorded deadline | State |
|---|---|---|---|
| Healthy | 20 | all in the future, 6.4 to 26.1 days out | alive |
| Dead, deadline passed | 2 (Harbor, Iris) | 09-29 14:47:10 and 10-02 04:45:41 | each died at the first refresh attempt after the deadline |
| Dead, deadline not reached | 2 (Echo, Juniper) | 10-07 and 10-16 | both died while active (cause B) |

The two deadline deaths bracket the recorded value inside one eight-hour refresh cycle:

| Account | Last successful refresh | Recorded deadline | Next attempt | Result |
|---|---|---|---|---|
| Harbor | 09-29 07:42:09 | 09-29 14:47:10 | at access-token expiry, 15:42:09 | refused, flagged dead |
| Iris | 10-02 00:33:41 | 10-02 04:45:41 | 08:38:40 | HTTP 400, flagged dead |

**INFERRED, with high confidence:** the deadline is enforced by the server and is not
moved by token rotation. Harbor is the clean case. It is excluded from rotation, so for
weeks only the widget refreshed it, three times a day, and the login still ended on the
recorded deadline. If rotation extended the lifetime, the stale recorded value would be
meaningless, some of the 20 healthy logins would show a deadline in the past, and neither
dead login would have died within hours of its own.

**INFERRED:** the base rate explains the complaint. 24 logins with deadlines spread over
about four weeks is 0.8 to 0.9 lapses per day, which is "about one a day".

### Rows 1, 2, 4 and 5

**Not verifiable.** Their old credentials were replaced by the repair `/login`, so the old
deadline is gone. They fit cause A and not cause B:

- All four were inactive when they died, and the session transcripts show no
  authentication failure at those times. Fleet-wide `Login expired` waves in the last two
  weeks occur only on 09-24 (two), 09-27 09:56 and 10-02 05:20.
- An inactive account is touched only by the widget.
- Their current deadlines are among the six latest of the 24 and fall in the same order as
  their deaths.

### The same deadline, hit while active

**VERIFIED.** Iris was made the active login at 05:24:10, 39 minutes **after** its login
had lapsed. The preflight called it "live and fresh" at 05:20:11, and the activation gate
passed it, because both look only at the access token. Nothing failed because the access
token was good until 08:33:41 and Iris rotated off at 07:13. Had it stayed active, the first
CLI refresh at about 08:28 would have been refused, the CLI would have written its
dead-marker, and every session would have stopped.

**INFERRED:** that is the shape of the two fleet stalls on 09-24 (204 failures across 47
sessions from 03:30:58, and 26 across 15 sessions from 20:00:14). No token evidence from
that day survives.

### Upcoming deadlines (live logins only)

| Date | Logins reaching their deadline |
|---|---|
| 10-08 | 2 |
| 10-09 | 1 |
| 10-10 | 1 |
| 10-11 | 1 |
| 10-12 | 1 |
| 10-14 | 3 |
| 10-16 | 4 |
| 10-17 | 1 |
| 10-22 | 2 |
| 10-24 | 2 |
| 10-27 | 1 |
| 10-28 | 1 |

This is a prediction that can be checked: the two logins due on 10-08 (18:10 and 20:29)
should be refused at their first refresh after those times unless `/login` is run first.

---

## 3. Cause B: the preflight refresh races the activation

**VERIFIED** for Juniper from the widget's log, the session transcripts and the code.

### Timeline, 10-02

| Time | Event |
|---|---|
| 04:44:07 | `Preflight[75% claude]: next candidate 'Juniper' login is live and fresh`. Its access token has 67 minutes left, above the preflight's one-hour window, so it is not refreshed. |
| 05:20:08.312 | Atlas, the active account, crosses 90 % session. The session auto-switch threshold on this machine is 90 %. |
| 05:20:08.317 | `AutoSwitch: Switching from 'Atlas' to 'Juniper'`. The same reading also arms `Preflight[90%]` for Juniper, whose token now has 31 minutes left. The preflight starts redeeming Juniper's refresh token. |
| 05:20:08.339 | Outgoing account re-synced. |
| 05:20:08.341 – .362 | Activation writes Juniper's **stored** credential, the one being redeemed, to `.credentials.json` and the shared Keychain item. |
| 05:20:08.682 | `OAuth token refreshed via refresh_token grant (new expiry: … 20:20:08 +0000)`. The preflight's request has returned. |
| 05:20:08.704 | The rotated token is saved to Juniper's profile only. Nothing is written to the shared store. |
| 05:20:08.705 | `Preflight[90% claude]: next candidate 'Juniper' login is live and fresh`. |
| 05:20:11.711 | First sweep read after the switch: `Using credentials file (token outlives Keychain's: … 12:51:37 +0000 vs 1970-01-01 00:00:00 +0000)`. The Keychain login already holds `expiresAt: 0`, the CLI's dead-marker. |
| 05:20:18 | First session records `Login expired · Please run /login`. Seven sessions by 05:23:02. |
| 05:24:10.524 | `'Juniper' login rejected by the server (3 sessions failed authentication)`. The widget switches to Iris. |
| 05:24:10.537 | The outgoing re-sync reads the system login. The Keychain holds the dead-marker, so the file wins the expiry tiebreak. |
| 05:24:10.557 | `Keychain: Saved profile credential cli-creds`: the file's consumed token is written over Juniper's profile, replacing the token refreshed at 05:20:08. |
| 05:31:39 | Usage read with that token: 401, 20 minutes before its nominal expiry. |
| 05:50:09 | Refresh with the consumed refresh token: HTTP 400. `Claude account needs re-login`. |

Juniper's stored copy today is the consumed one (access `225958ee030b`, expiry 05:51:37;
refresh `5bf662557a91`). The token issued at 05:20:08 exists nowhere.

### The three defects that combine

1. **The preflight and the switch fire together.** `checkAutoSwitchIfNeeded` calls
   `preflightNextCandidateIfNeeded` (`MenuBarManager.swift:3725`) and then evaluates the
   switch threshold in the same call. The milestones are `[25, 50, 75, 90]`
   (`MenuBarManager.swift:3991`). With the threshold at 90 %, the last milestone and the
   switch are the same event. The preflight's guard against refreshing the provider owner
   (`MenuBarManager.swift:4086`) is evaluated before the switch claims ownership.
2. **The activation does not wait for a refresh in flight.** `ensureFreshCredentials`
   returns `false` at once when another caller holds the per-profile mutex
   (`ClaudeCodeSyncService.swift:669`). The activation's own freshness step
   (`ProfileManager.swift:713`) treats that as "nothing to do" and applies whatever is
   stored (`ProfileManager.swift:748-757`). The preflight was started with
   `syncToSystem: false` (`MenuBarManager.swift:4144-4149`), so its result never reaches
   the CLI.
3. **The switch-away re-sync can downgrade a profile.** `readSystemCredentials` returns
   the file when its token expires later than the Keychain's
   (`ClaudeCodeSyncService.swift:53-62`). After the CLI writes its dead-marker
   (`expiresAt: 0`), the widget's own stale file always wins. `resyncBeforeSwitching`
   (`ClaudeCodeSyncService.swift:1197-1230`) then saves it over the profile without
   comparing it with what the profile already holds. This is the two-store race the
   earlier review flagged, in the form in which it does damage.

### How often it can fire

**INFERRED.** It needs the candidate's token to fall inside the one-hour window between
the 75 % and 90 % readings, and the activation to reach its apply step before the refresh
returns. The activation skips the "verify a stale candidate" fetch when the candidate's
cached usage is under three minutes old, and then reaches the apply in about 20 ms against
about 370 ms for the refresh. That is a few percent of switches, at roughly ten switches a
day. Two cases in eight days fits.

With the default 95 % threshold the two events are minutes apart and the race needs a
single reading to jump from below 90 % to 95 % or more.

### Echo (row 3)

**INFERRED.** The widget's log for 09-27 is gone. Echo's stored state matches Juniper's:
it died while active (six sessions failed from 09:56:04), the outgoing re-sync ran at
10:00:07, the recorded deadline is ten days in the future, and the stored access token had
38 minutes left when the first session failed, inside the preflight's one-hour window.

---

## 4. Is the account dead, or only the widget's copy? (question 2)

In every case the Anthropic account is fine. What died is the login.

- **Iris. VERIFIED.** The widget's copy is byte-identical to what the shared Keychain held
  while Iris was active: same access-token expiry (08:33:41) throughout, and no profile
  credential save was logged at the 07:13:37 re-sync (saves are logged only when the value
  changes). The refresh token is the one saved at switch time. It was refused because the
  login's deadline had passed. No other copy exists.
- **Juniper. VERIFIED.** The widget's copy is the consumed token re-read from the file.
  The good copy was overwritten.
- **Harbor. VERIFIED.** Deadline passed, as Iris.

No refresh-token fingerprint is shared between two profiles, and no two profiles are
stamped with the same account. **VERIFIED.**

---

## 5. The widget's sync logic (question 4)

**VERIFIED** from the code and the retained log.

**When it saves a token into a profile**

- On switch-away: `resyncBeforeSwitching` copies the system login into the outgoing
  profile, guarded by the account-identity check.
- In the sweep, when a profile's access token is within 5 minutes of expiry
  (`MenuBarManager.swift:2641-2663`): for the active profile it adopts the shared Keychain
  login if that expires later, otherwise it redeems the refresh token itself inside the
  last 2 minutes and writes the result to the shared store. For a background profile it
  redeems and saves to the profile only.
- In the preflight, with a one-hour freshness window.
- At activation, before applying.

**Does it re-read after a switch?** Yes, twice per 30-second sweep
(`Using system Keychain credentials …`), but only to adopt into the profile that owns the
shared login. A profile that has rotated off is never compared with anything again. Its
copy is the only copy.

**Who refreshes in practice.** In the retained 6.5 hours the widget performed 19 refreshes
and the CLI none. Each widget refresh was followed by exactly one profile-credential save.
There is no sign of a refreshed token being lost to a stale profile save.

**Latent, not observed.** The widget refreshes the active account without taking the CLI's
`.oauth_refresh.lock`. If both redeem the same refresh token, the loser gets a 400. Today
the CLI goes first at 5 minutes and the widget waits until 2, so they do not collide.

---

## 6. What a fix would have to do (described only, not implemented)

### For cause A

Nothing app-side can extend a login. Renewal needs `/login` in a browser. The widget can
make it predictable.

1. Read `refreshTokenExpiresAt` and show days left per account. Notify a few days ahead,
   listing every login due in the same window so they are renewed in one sitting.
2. Treat a login past its deadline as dead in the candidate filter, the preflight verdict
   and the activation gate. Today an account in that state can be made the fleet's login
   and stalls it at the next refresh.
3. When the widget refreshes a token, take `refresh_token_expires_in` from the response and
   store it, as the CLI does, so the field stays true.
4. Rank or warn on the active account's remaining lifetime, so a login is not left active
   across its deadline.

### For cause B

1. An activation must never apply a credential while a refresh of that profile is in
   flight. It should wait for the in-flight refresh and apply its result, instead of
   skipping.
2. A refresh that completes after its profile became the provider owner must write its
   result to the shared store. The decision belongs at completion, not at start.
3. Do not run the preflight from the same reading that triggers the switch.
4. The re-sync must not downgrade. A system login that is the CLI's dead-marker, or that
   expires earlier than what the profile already holds, is not newer.
5. Drop the "later expiry wins" preference for the file when the Keychain entry is the
   dead-marker. That state means the CLI found the login dead, not that the file is fresher.
6. When the CLI store holds the dead-marker and the owning profile holds a newer token for
   the same account, re-apply it before condemning the account.

### Shared-store etiquette

Take the CLI's refresh lock around any widget refresh of the active account, or leave the
active account's refreshes to the CLI and only adopt.

---

## 7. What could not be verified, and why

- **Rows 1, 2, 4 and 5.** Their old credentials were overwritten by the repair login.
- **Echo's race.** The unified log keeps about 6.5 hours of this app's messages (02:44 to
  09:17 on 10-02). Everything before that is gone.
- **Server behaviour.** Nothing was sent to the token endpoint, so these stay inferences:
  - what anchors the deadline. The recorded deadlines do not sit a whole number of days
    after any of the 38 completed `/login` commands in the transcripts, so it is not simply
    "login plus N days". The lifetime of a fresh login is therefore not known. It may be
    tied to the browser session that authorized it;
  - whether a refresh performed by the CLI (different host, sends `scope`) is treated
    differently from the widget's. It can be watched passively: read
    `refreshTokenExpiresAt` in the shared item before and after a CLI-performed refresh;
  - whether redeeming a refresh token revokes the access token issued with it, or whether
    presenting a consumed refresh token revokes the whole family. Juniper's old access
    token was refused 20 minutes early, which fits either;
  - whether Juniper's rotated token would still have worked had it been kept.
- **CLI versions before 2.1.285.** The deaths of 09-25 to 09-29 ran 2.1.282 to 2.1.285.
  Only 2.1.285 and later are on disk.
- **Runtime confirmation of the CLI reading.** The refresh path was read statically from
  minified code. No session was run under a debugger or with debug logging.
- **The 09-24 fleet stalls.** Their shape matches a deadline reached while active. No
  token evidence from that day survives.
- **The in-flight refresh at the instant of a switch** (section 1). Possible by the code,
  not observed.

---

## 8. Resolved by (2026-10-09)

Cause B struck twice more on 10-08/09, eight hours apart, each time on a healthy account
whose deadline was weeks away. The widget's log showed the exact order: the switch applied
the target's stored pair, and the 90 % preflight redeemed that pair's refresh token in the
same second. Session transcripts showed nine sessions failing within three seconds of each
redemption (07:50:25Z and 15:22:4xZ). So redeeming a Claude refresh token revokes the access
token issued with it at once, not only the old refresh token. Writing the rotated pair to
the CLI afterwards is therefore not enough: any redemption of a login the CLI is using kills
its in-flight requests.

The fix (owner's decision, 2026-10-09: "Fix it, plus deadline check"):

1. **The widget never redeems a login the CLI holds.** `ClaudeRefreshPolicy.decide` runs
   at the moment of every Claude redemption. It refuses when:
   - the CLI's store holds that refresh token, compared by fingerprint in memory;
   - the pointer names the profile;
   - an activation is handing the login over.

   The CLI can be redeeming the same token in its own process, so the widget leaves the
   CLI's login to the CLI and adopts its rotation. The activation renews before it
   applies, with the preflight's one-hour window. It waits for a redemption already in
   flight instead of skipping it, and always re-reads the store afterwards. A rotated pair
   reaches the CLI only as a repair, when the CLI holds the very token just consumed. The
   preflight skips a login being handed over and re-checks ownership after its await.
   Fixes 1 to 3 of section 6, B.
2. **Newest login wins.** `ClaudeLoginLifetime.isNewer` compares two logins:
   - The dead-marker is never newer than anything.
   - Two different logins (deadlines more than 60 s apart): the later deadline wins.
     Each `/login` gets a fixed deadline that refreshes never move (cause A above).
   - Within one login: a lapsed deadline loses, then the later access-token expiry wins,
     and a tie is not newer.

   The store read returns nothing when the Keychain holds the dead-marker, and never
   falls back to the file. The switch-away re-sync, the Keychain adoption and identity
   adoption replace a stored login only with a newer one. An ordinary save to the
   profile store only moves a login forward. Explicit replacements (a sync, a
   redemption's own save) are the exception. Fixes 4 and 5 of section 6, B.
3. **Deadline check.** `refreshTokenExpiresAt` is read in milliseconds or seconds. A login at
   or within one hour of its deadline is not a switch target (`candidateHasHeadroom`, so
   the walk, the queue peek, the stale re-verify and the fleet tile). The preflight verdict
   is not live for it, and the activation gate refuses it with the expired-login handling.
   A refresh the widget performs now stores the server's `refresh_token_expires_in` the way
   the CLI does. Fix 2 of section 6, A, and part of fix 3.

Not done here: fix 6 of B (re-applying a newer stored login over the dead-marker before
condemning) and the days-ahead deadline notice (fix 1 of A). The CLI refresh lock is no
longer needed: the widget never redeems the CLI's login. The
fleet detector's 120-second post-switch grace explains why both accounts were condemned
only about 30 minutes after they died. With the rotation gone it no longer delays
anything, and it is unchanged.

---

## Appendix: how to re-check, read-only

Deadline and expiry of one profile's stored login, without printing a token:

```bash
security find-generic-password -s "com.claudewidget.cli-creds-<PROFILE-UUID>" \
  -a profile-credential -w | python3 -c '
import sys, json, datetime
o = json.load(sys.stdin)["claudeAiOauth"]
f = lambda ms: datetime.datetime.fromtimestamp(ms / 1000).strftime("%m-%d %H:%M:%S")
print("access token expires", f(o["expiresAt"]))
print("login deadline      ", f(o["refreshTokenExpiresAt"]))'
```

The shared login is service `Claude Code-credentials`, account `$USER`.

Widget log (retention is hours, capture early):

```bash
/usr/bin/log show --predicate 'subsystem == "com.claudeusagewidget.app"' --info --last 8h \
  | grep -E "OAuth token refresh|Using credentials file|Re-synced|Preflight\[|Switching from|Saved profile credential"
```

Strings to find the CLI code paths in a newer binary: `OAuth refresh CAS save failed`,
`tengu_oauth_token_refresh_race_resolved`, `tengu_oauth_refresh_save_adopted_newer_write`,
`tengu_oauth_refresh_token_marked_dead_invalid_grant`, `lastCredentialsMtimeMs`,
`.oauth_refresh.lock`, `refresh_token_expires_in`, `Your login expires in`.
