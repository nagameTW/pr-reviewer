#!/usr/bin/env bash
# Invariant tests for the parallel review pool. No gh, no network, no
# model call — pure text checks over pr-autoreview.sh, the same contract as
# tests/scan-discipline.test.sh: these pin SHAPES that a later edit could
# silently break, because nothing at runtime would say so.
#
# THE invariant: review_one_pr()'s body must never contain a bare `continue`.
# The body used to be the PR loop's inline body, full of PR-level continues;
# inside a function a `continue` is not in any loop, so bash prints a warning
# and FALLS THROUGH to the next statement — a guard that meant "skip this PR"
# keeps right on reviewing it. All 17 were converted to `return`; this test is
# what stops the 18th from sneaking back in with a copy-pasted guard.
# Run: bash tests/parallel-discipline.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }

# The function runs to the first column-0 `}` — cleanup_job's brace is
# indented, and no line inside the body is a bare `}` (asserted below by
# requiring the range to reach the job-preamble markers AND `return 0`).
BODY="$(awk '/^review_one_pr\(\) \{/,/^\}$/' pr-autoreview.sh)"

[ -n "$BODY" ] && ok "review_one_pr() found" \
  || bad "review_one_pr() found" "function marker missing — renamed?"

# Range sanity: the extraction must cover the head (TMPFILES reset), the
# tail (return 0) and be BIG — a bare `}` accidentally introduced mid-body
# would silently shrink the range and turn every check below into a pass
# over a fragment.
grep -q 'TMPFILES=()' <<<"$BODY" && ok "range covers the job preamble" \
  || bad "range covers the job preamble" "TMPFILES=() not inside the extracted function"
grep -q '^  return 0$' <<<"$BODY" && ok "range covers the function tail" \
  || bad "range covers the function tail" "trailing return 0 not inside the extracted function"
BODY_LINES="$(wc -l <<<"$BODY")"
[ "${BODY_LINES:-0}" -gt 1000 ] && ok "range is the full body ($BODY_LINES lines)" \
  || bad "range is the full body" "only $BODY_LINES lines extracted — a stray column-0 } cut the range short"

# The invariant itself. Comment lines are excluded: prose may legitimately
# discuss the keyword (and did, before it was reworded).
LEFT="$(grep -vE '^[[:space:]]*#' <<<"$BODY" | grep -nE '(^|[^A-Za-z0-9_`])continue([^A-Za-z0-9_`]|$)')" || LEFT=""
[ -z "$LEFT" ] && ok "no bare continue inside review_one_pr" \
  || bad "no bare continue inside review_one_pr" "$(head -5 <<<"$LEFT")"

# The sibling invariant. Why it matters: the job runs
# as a background subshell, so an `exit 1` written as a fail-closed way out
# leaves $? nonzero, cleanup_job files a CRASH marker, the round counts a
# degraded item and ends non-zero, and the failure alert opens a ticket — the
# opposite of what the author intended. `return 0` is the only way out.
#
# TWO exits are legitimate and stay: the INT/TERM traps, which exist so the
# EXIT trap (and the worktree removal) still runs when the service is
# stopped. They are allow-listed by their exact text rather than by a looser
# pattern, so `trap 'exit 1' ERR` — which WOULD file a bogus crash — still
# fails here.
# 130/143 are also the two codes cleanup_job excludes from the CRASH check,
# and that pairing is the actual invariant: an exit code the trap can produce
# must be one cleanup_job forgives.
#
# `(` excluded as a preceding character so the log strings this script
# writes ("... ended without a result event (exit $ADV_CLI_RC)") are not read
# as code. Comment lines stripped as above.
ALLOWED_EXITS="trap 'exit 130' INT|trap 'exit 143' TERM"
LEFT_EXIT="$(grep -vE '^[[:space:]]*#' <<<"$BODY" \
  | grep -vE "^[[:space:]]*($ALLOWED_EXITS)[[:space:]]*$" \
  | grep -nE '(^|[^A-Za-z0-9_`(])exit([^A-Za-z0-9_(]|$)')" || LEFT_EXIT=""
[ -z "$LEFT_EXIT" ] && ok "no unsanctioned exit inside review_one_pr" \
  || bad "no unsanctioned exit inside review_one_pr" "$(head -5 <<<"$LEFT_EXIT")"

# The pairing above, checked rather than asserted in prose: every code the
# allow-listed traps can exit with must appear in cleanup_job's forgive list.
# Adding `trap 'exit 129' HUP` without touching cleanup_job would otherwise
# turn a routine signal into an alert ticket.
FORGIVE="$(grep -n 'rc" -ne' <<<"$BODY")"
for code in 130 143; do
  grep -q "\-ne \"\?$code\"\?" <<<"$FORGIVE" && ok "cleanup_job forgives $code" \
    || bad "cleanup_job forgives $code" "the INT/TERM traps exit $code but cleanup_job counts it as a crash"
done

# Job-scope cleanup: the job must RESET the inherited TMPFILES before
# trapping, or its EXIT trap deletes the patterns file and the round's
# shared temps out from under every other job.
grep -q 'trap cleanup_job EXIT' <<<"$BODY" && ok "job traps its own cleanup" \
  || bad "job traps its own cleanup" "trap cleanup_job EXIT not found in the function"

# Dispatcher shape: a bare `wait` must follow the spawn loop — the
# post-merge tripwire reads PR comments the jobs post, and the round
# summary must not print before the work it summarises.
awk '/review_job "\$PR" "\$WT_DIR" 2>&1/,/^wait$/' pr-autoreview.sh | grep -q '^wait$' \
  && ok "dispatcher reaps all jobs before the tripwire" \
  || bad "dispatcher reaps all jobs before the tripwire" "no bare wait after the spawn line"

# Slot before budget: the pool-gate wait can cost a full
# review chain, so the budget must be read AFTER it — checked first, it
# admits a job long after the budget was spent and pushes the round past
# the round timeout. Pin the ORDER of the two lines inside the dispatcher.
DISPATCH="$(awk '/^for PR in \$OPEN_PRS/,/^wait$/' pr-autoreview.sh | grep -vE '^[[:space:]]*#')"
POOL_LN="$(grep -n 'jobs -pr | wc -l' <<<"$DISPATCH" | head -1 | cut -d: -f1)"
BUDGET_LN="$(grep -n 'ROUND_BUDGET' <<<"$DISPATCH" | head -1 | cut -d: -f1)"
if [ -n "$POOL_LN" ] && [ -n "$BUDGET_LN" ] && [ "$POOL_LN" -lt "$BUDGET_LN" ]; then
  ok "pool gate runs before the budget check"
else
  bad "pool gate runs before the budget check" "pool at line ${POOL_LN:-none}, budget at line ${BUDGET_LN:-none} of the dispatcher"
fi

if [ "$FAILED" -eq 0 ]; then echo "PASS: parallel discipline"; else echo "FAIL: parallel discipline"; exit 1; fi
