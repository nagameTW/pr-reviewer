#!/usr/bin/env bash
# Failure alert. $1 names what failed and is the dedupe key; a second
# argument, when given, adds the detail.
#
# Files ONE issue per failure episode on the alert repo (REPO below).
# If an open reviewer-alert issue for the same $1 exists, no second issue:
# it adds a "Still failing" comment when that issue has not been updated for
# PRREVIEW_ALERT_REPEAT_HOURS, and stays quiet otherwise.
# Closing the issue after fixing re-arms the alert.
#
# Offline is never a failure: this only
# fires when the box is up and a job actually ran red. A powered-off box
# triggers nothing, by design.
#
# Safety: the body is a template, plus the caller's second argument when one
# is given; the outbound sensitive scan runs on the whole body anyway and
# fails closed.
set -uo pipefail

FAILED_UNIT="${1:?usage: owner-alert.sh <failed-unit-name> [detail]}"
DETAIL="${2:-}"
REPO="${PRREVIEW_ALERT_REPO:-}"
# No alert repo configured (PRREVIEW_ALERT_REPO is optional) means the
# loop's own log line is the whole alert, so say so and succeed rather than
# fail every call.
[ -n "$REPO" ] || { echo "alert: PRREVIEW_ALERT_REPO is not set — not filed ($FAILED_UNIT)"; exit 0; }
GH="${GH_BIN:-$(command -v gh)}"
PATTERNS_FILE="${PRREVIEW_SENSITIVE_PATTERNS_FILE:-$HOME/.config/pr-reviewer/sensitive-patterns}"
LABEL="reviewer-alert"
TITLE="Reviewer failed: $FAILED_UNIT"

[ -x "$GH" ] || { echo "gh missing: $GH"; exit 1; }
command -v jq >/dev/null || { echo "jq missing"; exit 1; }

# Sensitive-patterns: fail closed, same contract as the review gate.
SCAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCAN_LIB_DIR/lib/scan.sh" || { echo "lib/scan.sh missing — refusing to post"; exit 1; }
# This script owns no other temp file, so the trap is added here rather than
# in lib/scan.sh: a lib-installed EXIT trap would REPLACE the caller's, and
# other callers already clean their own files with one. Not /tmp:
# the loaded pattern content decides whether outbound text
# gets blocked, the same category GATE_SCRATCH exists to protect.
# Validated before the /owner-alert-scratch suffix is appended:
# checking the combined path made an error like
# PRREVIEW_ALERT_WORKROOT=tmpdir print "got 'tmpdir/owner-alert-scratch'",
# leading whoever set it to go looking for a string they never typed.
ALERT_WORKROOT_BASE="${PRREVIEW_ALERT_WORKROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/pr-reviewer/work}"
case "$ALERT_WORKROOT_BASE" in
  /*) ;;
  *) echo "PRREVIEW_ALERT_WORKROOT must be an absolute path (got '$ALERT_WORKROOT_BASE') — refusing to run" >&2; exit 1 ;;
esac
ALERT_WORKROOT="$ALERT_WORKROOT_BASE/owner-alert-scratch"
mkdir -p "$ALERT_WORKROOT" || { echo "cannot create $ALERT_WORKROOT" >&2; exit 1; }

# Reclaim leftovers from a run killed mid-flight: only reap
# ones old enough that they cannot be the run in progress right now.
find "$ALERT_WORKROOT" -maxdepth 1 -name 'pats-*' -mtime +1 -delete 2>/dev/null || true

PATS_FILE="$(mktemp "$ALERT_WORKROOT/pats-XXXX")"
trap 'rm -f "$PATS_FILE"' EXIT
SCAN_WHY="$(scan_patterns_load "$PATTERNS_FILE" "$PATS_FILE")" \
  || { rm -f "$PATS_FILE"; echo "$SCAN_WHY — refusing to post"; exit 1; }

# Episode dedupe: an open alert for this $1 means whoever reads the alert
# repo already knows THAT it failed — but not that it is STILL failing.
# Silence here can hide an outage for days: the episode issue stays open,
# every later red round matches it, and nothing says the loop is still
# down. So the open issue gets a comment instead, throttled to one per
# REPEAT_HOURS so a loop that runs every minute cannot fill the thread.
REPEAT_HOURS="${PRREVIEW_ALERT_REPEAT_HOURS:-6}"
# Not a whole number ("6h") used to break the $(( )) below, and a failed test
# there reads as "due": one comment per round. Base 10, so 08 is 8 hours.
case "$REPEAT_HOURS" in
  '' | *[!0-9]*)
    echo "alert: PRREVIEW_ALERT_REPEAT_HOURS='$REPEAT_HOURS' is not a whole number of hours — using 6"
    REPEAT_HOURS=6 ;;
  *) REPEAT_HOURS=$((10#$REPEAT_HOURS)) ;;
esac
# updatedAt rides on the SAME list call that finds the issue: a second call
# (`gh issue view`) that failed used to read as "due", turning the throttle
# into one comment per round for as long as the read failed.
OPEN_JSON="$("$GH" issue list --repo "$REPO" --state open --label "$LABEL" --json number,title,updatedAt 2>/dev/null \
  | jq -c --arg t "$TITLE" '[.[] | select(.title == $t)] | first // empty')"
OPEN="$(jq -r '.number // empty' <<<"${OPEN_JSON:-null}" 2>/dev/null)"
if [ -n "$OPEN" ]; then
  LAST="$(jq -r '.updatedAt // empty' <<<"$OPEN_JSON" 2>/dev/null)"
  # BSD form first, GNU second: the first
  # form has to FAIL cleanly on the other platform, and GNU `date -d` on a
  # BSD box does not (it reads -d as a flag and prints now). Only a stamp of
  # GitHub's shape reaches either: anything else would get that "now" on a
  # BSD box and "would not read" on a GNU one.
  LAST_EPOCH=""
  case "$LAST" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      LAST_EPOCH="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST" +%s 2>/dev/null || date -u -d "$LAST" +%s 2>/dev/null || true)" ;;
  esac
  NOW_EPOCH="$(date -u +%s)"
  case "$LAST_EPOCH" in '' | *[!0-9]*) LAST_EPOCH="" ;; esac
  [ -n "$LAST_EPOCH" ] && [ "$LAST_EPOCH" -gt $((NOW_EPOCH + 60)) ] && LAST_EPOCH=""
  if [ -z "$LAST_EPOCH" ]; then
    # Unreadable is NOT "due": the failure mode this throttle exists for is
    # a thread filled every minute, so a timestamp we cannot read means no
    # comment this round, said out loud in the log.
    echo "alert: open issue #$OPEN for $FAILED_UNIT already exists but its updatedAt would not read ('$LAST') — not commenting this round"
    exit 0
  fi
  if [ $(( NOW_EPOCH - LAST_EPOCH )) -lt $(( REPEAT_HOURS * 3600 )) ]; then
    echo "alert: open issue #$OPEN for $FAILED_UNIT already exists and was updated under ${REPEAT_HOURS}h ago — not commenting"
    exit 0
  fi
  NOTE="$(printf 'Still failing at %s: `%s`%s' "$(date '+%F %H:%M %Z')" "$FAILED_UNIT" "${DETAIL:+ — $DETAIL}")"
  if scan_hit_or_unknown "$PATS_FILE" "$NOTE"; then
    echo "alert: repeat note matched sensitive patterns (or the scan could not run) — withholding, not posting"
    exit 1
  fi
  "$GH" issue comment "$OPEN" --repo "$REPO" --body "$NOTE" || exit 1
  echo "alert: open issue #$OPEN for $FAILED_UNIT already exists — added a still-failing note"
  exit 0
fi

# Where to look. The loop writes its own output to gate.log and each
# round's to <loop>-logs/, so the logs are the pointer wherever it runs.
DIAG_LOGS='the round logs are under `~/.cache/pr-reviewer/gate-logs/` (`round-*.log`; `ls -t` for the newest, the names do not sort by time).'
DIAG="Diagnose: $DIAG_LOGS"
BODY="$(printf '`%s` failed on the reviewer host at %s.%s\n\n%s\n\nOne issue per failure episode. Close this after fixing to re-arm the alert. It fires only when a run on a machine that is up actually fails; a machine that is switched off files nothing.' \
  "$FAILED_UNIT" "$(date '+%F %H:%M %Z')" "${DETAIL:+ $DETAIL}" "$DIAG")"

# Materialized, never piped into `grep -q`: an early-quitting grep SIGPIPEs
# the producer, and under `pipefail` the pipeline then reports non-zero EVEN
# ON A MATCH — a hit reads as a miss, in the one direction that matters for an
# outbound scan. $BODY is a bounded template today so it cannot actually reach
# the 64KiB pipe buffer, but the idiom is the bug, not the current size.
if scan_hit_or_unknown "$PATS_FILE" "$BODY"; then
  echo "alert: body matched sensitive patterns (or the scan could not run) — withholding, not posting"
  exit 1
fi

"$GH" label create "$LABEL" --repo "$REPO" --color B60205 \
  --description "Reviewer failure alert" >/dev/null 2>&1 || true
"$GH" issue create --repo "$REPO" --label "$LABEL" --title "$TITLE" --body "$BODY" || exit 1
echo "alert: filed issue for $FAILED_UNIT"
