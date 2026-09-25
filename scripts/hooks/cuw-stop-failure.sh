#!/bin/sh
# Claude Usage widget: StopFailure hook.
#
# Claude Code runs this when a turn ends on an API error, with a JSON payload on
# stdin: {hook_event_name:"StopFailure", session_id, cwd, error, error_details?,
# last_assistant_message?, ...}. `error` is a closed enum (rate_limit,
# overloaded, authentication_failed, oauth_org_not_allowed, account_on_hold,
# verification_required, billing_error, invalid_request, model_not_found,
# server_error, max_output_tokens, cloud_credential_error, unknown).
#
# For `authentication_failed`, and only that value, it appends one JSON line
# {ts, session_id, cwd, error} to the widget's journal. Every other value exits
# at once. The widget reads the journal each sweep: 3 distinct sessions within
# 120 s condemn the active Claude login, and the fleet is switched to another
# account (CLAUDE.md "Server-rejected Claude logins").
#
# The hook is fire-and-forget: Claude Code ignores its output and exit code.
# It must stay fast, since it runs inside the session that just failed. The
# common path is one `case` match and no subprocess.
#
# Install: see docs/specs/server-rejected-logins.md.

journal="${CUW_STOP_FAILURE_JOURNAL:-$HOME/Library/Application Support/Claude Usage/stop-failures.jsonl}"
max_bytes=65536
keep_lines=200

payload=$(/bin/cat)

# Cheap pre-filter: nothing that could be an authentication failure goes further.
case "$payload" in
  *authentication_failed*) ;;
  *) exit 0 ;;
esac

# Exact top-level field reads. A phrase quoted inside last_assistant_message is
# a JSON-escaped string and never matches a top-level key.
field() {
  printf '%s' "$payload" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

[ "$(field error)" = "authentication_failed" ] || exit 0

session=$(field session_id)
[ -n "$session" ] || exit 0

# JSON string escaping for the two free-text fields.
escape() {
  printf '%s' "$1" | /usr/bin/tr -d '\000-\037' | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ts=$(/bin/date +%s)
line=$(printf '{"ts":%s,"session_id":"%s","cwd":"%s","error":"authentication_failed"}' \
  "$ts" "$(escape "$session")" "$(escape "$(field cwd)")")

dir=$(/usr/bin/dirname "$journal")
[ -d "$dir" ] || /bin/mkdir -p "$dir" || exit 0

# Self-truncating: past max_bytes, keep only the newest lines. The widget only
# reads the last 120 s, so dropping old lines loses nothing it uses.
if [ -f "$journal" ]; then
  size=$(/usr/bin/stat -f %z "$journal" 2>/dev/null || echo 0)
  if [ "$size" -gt "$max_bytes" ]; then
    tmp="$journal.$$"
    /usr/bin/tail -n "$keep_lines" "$journal" > "$tmp" 2>/dev/null && /bin/mv -f "$tmp" "$journal"
    /bin/rm -f "$tmp"
  fi
fi

printf '%s\n' "$line" >> "$journal"
exit 0
