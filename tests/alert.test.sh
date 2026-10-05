#!/usr/bin/env bash
# Tests for owner-alert.sh's issue body. No network: gh is a stub that records
# what `issue create --body` received. Run: bash tests/alert.test.sh
#
# The knobs the script already has (GH_BIN, PRREVIEW_SENSITIVE_PATTERNS_FILE,
# PRREVIEW_ALERT_WORKROOT) are enough to run it for real.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "$3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "no '$2'" "$3";; *) ok "$1";; esac; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
printf 'NEVER-MATCH-XYZZY\n' > "$T/pats"
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") echo '[]' ;;
  "issue create") while [ $# -gt 0 ]; do
                    [ "$1" = --body ] && printf '%s' "$2" > "$GH_STUB_OUT"
                    shift
                  done ;;
esac
exit 0
STUB
chmod +x "$T/gh"
run_alert() {
  rm -f "$T/body"
  # ALERT_REPEAT unset leaves the variable unset, so the script's own default
  # is what runs; -u keeps an exported one on this box out of it.
  # PRREVIEW_ALERT_REPO: the repo the issue is filed on, set so the script has
  # somewhere to file.
  env -u PRREVIEW_ALERT_REPEAT_HOURS ${ALERT_REPEAT+"PRREVIEW_ALERT_REPEAT_HOURS=$ALERT_REPEAT"} \
    PRREVIEW_ALERT_REPO=acme/pr-reviewer \
    GH_STUB_OUT="$T/body" GH_BIN="$T/gh" PRREVIEW_SENSITIVE_PATTERNS_FILE="$T/pats" \
    PRREVIEW_ALERT_WORKROOT="$T/work" bash owner-alert.sh "$@" >"$T/out" 2>&1
}
h_ago() { # $1 hours -> GitHub's updatedAt shape
  local e=$(( $(date +%s) - $1 * 3600 ))
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}


# Without a detail, on a box that has journalctl (stubbed onto PATH, in a
# subshell so the stub does not leak into the branches below).
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/journalctl"; chmod +x "$T/bin/journalctl"
(PATH="$T/bin:$PATH"; run_alert "review-loop")
BODY="$(cat "$T/body" 2>/dev/null)"
lacks 'a box with journalctl still gets the log pointer, not a journal line' 'journalctl' "$BODY"

# Without a detail, the body points at the round logs.
  # A title WITHOUT a log path, so the pointer below can only come from DIAG.
  run_alert "review-loop"
  BODY="$(cat "$T/body" 2>/dev/null)"
  has   'the body points at the round logs' '.cache/pr-reviewer/' "$BODY"
  has   'and says how to find the newest' 'ls -t' "$BODY"
  lacks 'the body never sends the reader to journalctl' 'journalctl' "$BODY"


# The dedupe still works with the new bodies: an open issue with the same
# title means no second create.
# The stub records every call, so "no create" is proven by "list was asked
# and create was not", not by the script dying earlier.
# The open issue carries a number and an updatedAt now (the comment below
# needs both, off this ONE call). GH_STUB_LAST is the updatedAt the stub reports.
cat > "$T/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$GH_STUB_OUT.calls"
case "$1 $2" in
  "issue list") printf '[{"number":42,"title":"Reviewer failed: review-loop (log: ~/.cache/pr-reviewer/gate.log)","updatedAt":"%s"}]\n' "$GH_STUB_LAST" ;;
  "issue create") printf 'CREATED' > "$GH_STUB_OUT" ;;
  "issue comment") while [ $# -gt 0 ]; do
                     [ "$1" = --body ] && printf '%s' "$2" > "$GH_STUB_OUT.comment"
                     shift
                   done ;;
esac
exit 0
STUB
# Episode updated a minute ago: no create, and no comment either (throttled).
rm -f "$T/body.calls" "$T/body.comment"
GH_STUB_LAST="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"; RC=$?
has   'the dedupe path asked gh for the open issues' 'issue list' "$(cat "$T/body.calls" 2>/dev/null)"
lacks 'an open issue with the same title stops a second create' 'issue create' "$(cat "$T/body.calls" 2>/dev/null)"
lacks 'a fresh episode (updated under the repeat window) gets no comment' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
[ "$RC" -eq 0 ] && ok 'the deduped run exits 0 (nothing to do is not a failure)' \
                || bad 'the deduped run exits 0 (nothing to do is not a failure)' 'rc 0' "rc $RC: $(cat "$T/out")"

# Episode last touched a day ago and still red: the open issue gets a
# still-failing comment, never a second issue. An "exists, not duplicating"
# exit with no comment would swallow every alert while the issue stays open.
rm -f "$T/body.calls" "$T/body.comment"
GH_STUB_LAST="2000-01-01T00:00:00Z" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"; RC=$?
has   'a stale open episode gets a comment' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
lacks 'and still no second issue' 'issue create' "$(cat "$T/body.calls" 2>/dev/null)"
COMMENT="$(cat "$T/body.comment" 2>/dev/null)"
has   'the comment names the unit' 'review-loop (log: ~/.cache/pr-reviewer/gate.log)' "$COMMENT"
has   'the comment carries the caller detail' 'exited 1 again' "$COMMENT"
has   'the comment says it is a repeat' 'Still failing' "$COMMENT"
[ "$RC" -eq 0 ] && ok 'the commented run exits 0' || bad 'the commented run exits 0' 'rc 0' "rc $RC: $(cat "$T/out")"

# An updatedAt that will not parse is NOT "due": the throttle's failure mode
# is a thread filled once a minute, so an unreadable stamp means no comment
# and a line in the log saying why.
rm -f "$T/body.calls" "$T/body.comment"
GH_STUB_LAST="not-a-timestamp" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"; RC=$?
lacks 'an unreadable updatedAt posts no comment' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
lacks 'and opens no second issue either' 'issue create' "$(cat "$T/body.calls" 2>/dev/null)"
has   'and the log says the stamp would not read' 'would not read' "$(cat "$T/out")"
[ "$RC" -eq 0 ] && ok 'the unreadable-stamp run exits 0' || bad 'the unreadable-stamp run exits 0' 'rc 0' "rc $RC: $(cat "$T/out")"

# Same stamp through a `date` that behaves like BSD's: -j fails, -d prints now.
# "not-a-timestamp" must still not read, whatever date(1) this box has.
mkdir -p "$T/datebin"
printf '#!/bin/sh\ncase " $* " in *" -j "*) exit 1 ;; *" -d "*) exec /bin/date -u +%%s ;; esac\nexec /bin/date "$@"\n' > "$T/datebin/date"
chmod +x "$T/datebin/date"
rm -f "$T/body.calls" "$T/body.comment"
( PATH="$T/datebin:$PATH"; GH_STUB_LAST="not-a-timestamp" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again" )
has   'a malformed updatedAt does not read on a BSD-like date either' 'would not read' "$(cat "$T/out")"

# PRREVIEW_ALERT_REPEAT_HOURS, the window itself. Unset is 6 hours.
rm -f "$T/body.calls"
GH_STUB_LAST="$(h_ago 7)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"
has   'unset window: a 7-hour-old episode is due (default 6 hours)' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
lacks 'and nothing says the window is malformed' 'is not a whole number' "$(cat "$T/out")"
rm -f "$T/body.calls"
GH_STUB_LAST="$(h_ago 5)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"
lacks 'unset window: a 5-hour-old episode is not' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
rm -f "$T/body.calls"
ALERT_REPEAT=0; GH_STUB_LAST="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"
has   'a 0-hour window comments even on a fresh episode' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
rm -f "$T/body.calls"
ALERT_REPEAT=999999; GH_STUB_LAST="2000-01-01T00:00:00Z" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"
lacks 'a window longer than the episode stays quiet' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
rm -f "$T/body.calls"
ALERT_REPEAT=6h; GH_STUB_LAST="$(date -u +%Y-%m-%dT%H:%M:%SZ)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"
lacks 'a non-numeric window falls back to 6 hours, not to every round' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
has   'and says it did' 'is not a whole number of hours' "$(cat "$T/out")"
# 09 is nine hours: an episode ten hours old is due. Read as octal it is an
# arithmetic error that ends the script, which also posts nothing.
rm -f "$T/body.calls"
ALERT_REPEAT=09; GH_STUB_LAST="$(h_ago 10)" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "exited 1 again"; RC=$?
has   'a leading zero is read as base 10 (09 hours, a 10-hour-old episode is due)' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
[ "$RC" -eq 0 ] && ok 'and the run exits 0' || bad 'and the run exits 0' 'rc 0' "rc $RC: $(cat "$T/out")"
unset ALERT_REPEAT

# The repeat note is outbound text too: a detail that hits the scan is withheld.
printf 'SECRET-ZEBRA-42\n' > "$T/pats"
rm -f "$T/body.calls" "$T/body.comment"
GH_STUB_LAST="2000-01-01T00:00:00Z" run_alert "review-loop (log: ~/.cache/pr-reviewer/gate.log)" "log says SECRET-ZEBRA-42"; RC=$?
lacks 'a repeat note that hits the sensitive scan is not posted' 'issue comment' "$(cat "$T/body.calls" 2>/dev/null)"
[ "$RC" -ne 0 ] && ok 'and the withheld repeat exits non-zero' || bad 'and the withheld repeat exits non-zero' 'rc 1' "rc $RC"
printf 'NEVER-MATCH-XYZZY\n' > "$T/pats"


[ "$FAILED" -eq 0 ] && echo "PASS: owner-alert.sh" || { echo "FAIL: owner-alert.sh"; exit 1; }
