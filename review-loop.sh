#!/usr/bin/env bash
# Review-gate driver. Runs pr-autoreview.sh once a minute for as long as
# there are open PRs anywhere the gate would review (a fork PR that the round
# skips does not count), and every IDLE_EVERY rounds when there are none.
#
set -uo pipefail

# The checkout this script lives in, next to pr-autoreview.sh.
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$GATE_DIR" || { echo "no gate repo at $GATE_DIR"; exit 1; }
. ./lib/loop.sh || { echo "lib/loop.sh missing — refusing to run"; exit 1; }
. ./lib/tools.sh || { echo "lib/tools.sh missing — refusing to run"; exit 1; }
. ./lib/trust.sh || { echo "lib/trust.sh missing — refusing to run"; exit 1; }
# The round below runs under a deadline, so the loop needs a timeout command.
tools_resolve
[ -n "$TIMEOUT_BIN" ] || { echo "timeout(1) missing (also tried gtimeout) — refusing to run" >&2; exit 1; }
# The open-PR count reads the PR list with jq. Without it every count fails,
# and each failed count asks for a round.
command -v jq >/dev/null 2>&1 || { echo "jq missing — refusing to run" >&2; exit 1; }
# Once, up front: a repo list that cannot be read here (PRREVIEW_GATE_REPOS
# unset or empty) makes every round below fail the same way, once a minute,
# for as long as nobody looks.
# In a subshell: an unset `${VAR:?}` inside loop_repos_of's eval exits the
# shell that runs it.
if ! ( loop_repos_of ./pr-autoreview.sh ) >/dev/null 2>&1; then
  echo "no repositories to review: PRREVIEW_GATE_REPOS is empty. Run 'prreview setup', or 'prreview repos add owner/repo' — refusing to run" >&2
  exit 2
fi

LOG_DIR="${1:-$HOME/.cache/pr-reviewer/gate-logs}"
mkdir -p "$LOG_DIR"
# 700: a round log can contain a body the sensitive scan WITHHELD from GitHub —
# pr-autoreview.sh prints those to stdout, and here stdout is a file that sticks
# around for KEEP_LOGS rounds.
chmod 700 "$LOG_DIR" 2>/dev/null || true

BASH_BIN="${PRREVIEW_LOOP_BASH:-$(command -v bash)}"
GH="${GH_BIN:-$(command -v gh)}"
# What each round runs under. Named here rather than inline on the `env` line
# below.
LOOP_PATH="$PATH"
LOOP_CLAUDE="${CLAUDE_BIN:-$(command -v claude)}"
KEEP_LOGS="${PRREVIEW_LOOP_KEEP_LOGS:-500}"
# A ceiling on the whole round: pr-autoreview.sh gives its model calls, and
# its clone and fetch (lib/clone.sh), a timeout(1) of their own, but most gh
# calls have none, and one wedged on the network would stall every later round.
# 3900, not 3000: a first round on a diff of
# 1000 lines or more runs two samples per slice — 16 calls over an 8-call
# cap is two waves of REVIEW_TIMEOUT (the derivation is at ROUND_BUDGET in
# pr-autoreview.sh).
ROUND_TIMEOUT="${PRREVIEW_LOOP_ROUND_TIMEOUT:-3900}"
# --kill-after, because SIGTERM alone is not a deadline here. A network call
# blocked on a dead connection does not return: timeout sends TERM at
# ROUND_TIMEOUT, bash does not act on a signal until its foreground child
# returns, and plain `timeout` would then wait for a child that is never
# going to come back, with every repo the loop reviews stopped behind it. KILL
# goes to the command's process group, so it reaches the stuck grandchild
# too; the grace period is for the round's own trap cleanup.
ROUND_KILL_AFTER="${PRREVIEW_LOOP_ROUND_KILL_AFTER:-60}"
loop_require_seconds PRREVIEW_LOOP_ROUND_TIMEOUT "$ROUND_TIMEOUT" || exit 2
loop_require_seconds PRREVIEW_LOOP_ROUND_KILL_AFTER "$ROUND_KILL_AFTER" || exit 2
IDLE_EVERY="${PRREVIEW_LOOP_IDLE_EVERY:-15}"
# A divisor below. 0, `3o`, or an octal-looking `08` is an arithmetic error
# there, and bash abandons the whole `while` on one; nothing follows it, so
# the loop exits 1 on its first idle round. A word dies the same way, as an
# unbound name under set -u. `[ -ge ]` reads 08 as decimal, hence the 10# pin.
[ "$IDLE_EVERY" -ge 1 ] 2>/dev/null \
  || { echo "PRREVIEW_LOOP_IDLE_EVERY must be a whole number, at least 1; got: $IDLE_EVERY — refusing to run" >&2; exit 2; }
IDLE_EVERY=$((10#$IDLE_EVERY))
INTERVAL="${PRREVIEW_LOOP_INTERVAL:-60}"
loop_require_seconds PRREVIEW_LOOP_INTERVAL "$INTERVAL" || exit 2

# Stamped once per START, not per round. `i` restarts at 1 every relaunch, so
# a plain round-<i>.log means the first round after a restart overwrites the
# last round before it — and that is usually the one you came back to read.
RUN_ID="$(date +%Y%m%dT%H%M%S)"

# Consecutive rounds that could not even prepare the script to run, and how
# many of them go by before this driver says so out loud. A parse error in
# the tree makes every round print a line and skip; nothing in that path
# exits non-zero, so nothing files an alert, so the only signal is a log
# nobody is reading. 5 rounds is long enough that a
# mid-edit save does not page anyone and short enough that a tree left broken
# is noticed the same hour.
READY_FAIL_RAW="${PRREVIEW_LOOP_READY_FAIL_LIMIT:-5}"
# Digits AND at least 2. 0 is all digits and turns this whole alert off
# silently, which puts the driver straight back into a quiet stall
# with nothing on screen to say the alarm was disarmed; 1 makes
# every single failing round file an alert, i.e. a gh call a minute, which is
# what the modulo exists to avoid.
case "$READY_FAIL_RAW" in
  ''|*[!0-9]*) echo "PRREVIEW_LOOP_READY_FAIL_LIMIT must be a whole number, got: $READY_FAIL_RAW" >&2; exit 2 ;;
esac
# Base 10 pinned before either comparison. `08` is all digits so the case
# above lets it through, and
# then bash reads the leading zero as octal: `[ 08 -lt 2 ]` ERRORS rather than
# answering, so the floor below silently does not fire either, and every later
# `$((n % limit))` prints "value too great for base" into the driver's log
# while the alert never comes. Measured, not
# assumed. RAW is kept so the message quotes what the operator typed.
READY_FAIL_LIMIT=$((10#$READY_FAIL_RAW))
if [ "$READY_FAIL_LIMIT" -lt 2 ]; then
  echo "PRREVIEW_LOOP_READY_FAIL_LIMIT must be at least 2 (0 would disarm the stall alert, 1 would file one every round), got: $READY_FAIL_RAW" >&2
  exit 2
fi
READY_FAILS=0

i=0
while true; do
  i=$((i + 1))
  # Across EVERY repo pr-autoreview.sh reviews, read from pr-autoreview.sh
  # itself (lib/loop.sh says why).
  n="$(loop_open_pr_count ./pr-autoreview.sh "$GH")"
  # Nothing else ever pruned these; see loop_prune_logs.
  loop_prune_logs "$LOG_DIR" "$KEEP_LOGS"
  # This loop's own log, when whoever started it says where that is.
  loop_rotate_log "${PRREVIEW_LOOP_LOG_FILE:-}"
  echo "[round $i] open PRs=$n at $(date +%H:%M:%S)"
  # Zero open PRs is NOT the same as nothing to do. pr-autoreview.sh runs a
  # post-merge tripwire over the last ~48h of merges after the PR loop, and the
  # moment someone merges the last open PR is exactly when the count hits 0
  # and that tripwire is most needed. This loop keeps the cheap admission
  # check but breaks out of it on a slow cadence so the tripwire still gets
  # its turn.
  if [ "$n" -gt 0 ] || [ $((i % IDLE_EVERY)) -eq 0 ]; then
    LOG="$LOG_DIR/round-$RUN_ID-$i.log"
    rc=0
    # C.UTF-8, not C. `${var:0:n}` counts CHARACTERS only in a multibyte
    # locale; under plain C bash falls back to BYTES, and pr-autoreview.sh
    # deliberately uses that expansion (not `printf '%.Ns'`) precisely so a
    # finding in multibyte text (emoji, say) is not cut short,
    # mid-character. Measured: `${s:0:10}` on a long run
    # of three-byte characters (€, say) gives three characters and a stray
    # byte under LC_ALL=C and all ten characters under C.UTF-8.
    # C keeps deterministic collation and messages, .UTF-8 restores character
    # semantics; the multibyte crash that made plain C look safe is fixed
    # and guarded for every file in this path by
    # tests/multibyte-interpolation.test.sh.
    # Run a parse-checked private copy, not the tree. bash reads a script by
    # byte offset as it executes, so an edit landing mid-round is read at the
    # wrong offsets — measured as "syntax error" and "unbound variable" in
    # files that were never wrong. The copy sits next to the original
    # so its relative lib/ still resolves.
    #
    # The check is on the COPY, and that ordering is the whole point.
    # Checking the tree and then copying it answered for bytes that are not
    # the ones about to run: an edit landing in between leaves a copy nobody
    # checked, and a truncation falling between two complete statements
    # yields a copy that PARSES, runs half the script, and exits 0 — a round
    # that looks clean and ran half a gate.
    RUN_SH="$(loop_script_ready ./pr-autoreview.sh "$BASH_BIN")" || {
      ready_rc=$?
      READY_FAILS=$((READY_FAILS + 1))
      case "$ready_rc" in
        2) echo "[round $i] ./pr-autoreview.sh does not parse — not run this round ($READY_FAILS in a row)" ;;
        *) echo "[round $i] could not copy ./pr-autoreview.sh to run it — not run this round ($READY_FAILS in a row)" ;;
      esac
      if loop_ready_should_alert "$READY_FAILS" "$READY_FAIL_LIMIT"; then
        echo "[alert] ./pr-autoreview.sh has not been runnable for $READY_FAILS rounds in a row — filing an alert"
        env GH_BIN="$GH" "$BASH_BIN" "$(loop_alert_script)" \
          "review-loop: the tree has not been runnable, so no PR is being reviewed" 2>&1 | tail -2 || true
      fi
      sleep "$INTERVAL"
      continue
    }
    READY_FAILS=0
    # PRREVIEW_ONCE_PR= : only `prreview once --pr` names a PR. A value in the
    # environment of this loop would name the same PR in every round.
    env LC_ALL=C.UTF-8 LANG=C.UTF-8 PRREVIEW_ONCE_PR= \
        PATH="$LOOP_PATH" \
        CLAUDE_BIN="$LOOP_CLAUDE" GH_BIN="$GH" \
        "$TIMEOUT_BIN" -k "$ROUND_KILL_AFTER" "$ROUND_TIMEOUT" "$BASH_BIN" "$RUN_SH" > "$LOG" 2>&1 || rc=$?
    # The round above has already finished — the line is synchronous — so this
    # is cleanup, not a race. A copy outliving a KILLED driver is swept by the
    # next snapshot (loop_script_snapshot, siblings older than two hours).
    rm -f "$RUN_SH"
    # Verdicts and refusals only, and only the gate's own lines: the round
    # log also holds withheld review bodies (lib/loop.sh).
    loop_gate_summary "$LOG"
    # A round that never RAN must not read like a round that found nothing.
    # pr-autoreview.sh exits 1 when a dependency is missing, and again at the
    # end when items could not be evaluated — deliberately, so the alert
    # fires. Nothing else watches that exit code, so this loop does it by
    # hand: print the code, point at the round log, and file a
    # one-issue-per-episode alert. owner-alert.sh dedupes on its own title, so
    # a failure repeating every minute still files exactly ONE issue, and
    # closing that issue re-arms it. Never allowed to kill the loop.
    #
    # GH_BIN is passed IN so the alert runs the same gh as the rounds:
    # without it owner-alert.sh looks for its own, and one it cannot find
    # stops the alert at `gh missing`, filing nothing. The name carries the
    # log path so the issue title itself says where to look.
    if [ "$rc" -ne 0 ]; then
      # The PATH, not the contents. `tail` here would copy the round log into
      # the driver's own stdout, i.e. into ~/.cache/pr-reviewer/gate.log — a
      # file created by shell redirection (644) in a directory that is not
      # 700 — and pr-autoreview.sh prints bodies the sensitive scan WITHHELD
      # from GitHub. That is the whole reason $LOG_DIR is chmod 700 above.
      echo "[round $i] pr-autoreview.sh EXITED $rc — see $LOG (may contain withheld content; that directory is 700)"
      env GH_BIN="$GH" "$BASH_BIN" "$(loop_alert_script)" \
        "review-loop (log: ~/.cache/pr-reviewer/gate.log)" 2>&1 | tail -2 || true
    fi
  fi
  sleep "$INTERVAL"
done
