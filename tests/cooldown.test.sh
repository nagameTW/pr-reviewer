#!/usr/bin/env bash
# Tests for lib/cooldown.sh: the same-head cooldown. No git, no gh, no model.
# Run: bash tests/cooldown.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
is() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$3" "$2"; FAILED=1; fi; }
[ -f lib/cooldown.sh ] || { echo "  FAIL lib/cooldown.sh does not exist"; exit 1; }
. lib/cooldown.sh || { echo "  FAIL cannot source lib/cooldown.sh"; exit 1; }

SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OTHER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOW="$(jq -nr '"2026-10-22T12:00:00Z" | fromdateiso8601')"
ago() { jq -nr --argjson n "$NOW" --argjson s "$1" '$n - $s | todate'; }

# ── the decision ──────────────────────────────────────────────────────────
is 'same head, 60 s ago, 10 min: skip, 540 s left' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 60)" "$NOW" 10)" 'skip 540'
is 'a new head is never delayed' \
   "$(cooldown_decide "$SHA" "$OTHER" "$(ago 60)" "$NOW" 10)" 'review'
is 'the cooldown is over at exactly 10 min' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 600)" "$NOW" 10)" 'review'
is 'one second before the end: still a skip' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 599)" "$NOW" 10)" 'skip 1'
is 'after the cooldown: review' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 3600)" "$NOW" 10)" 'review'
is '0 turns it off' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 1)" "$NOW" 0)" 'review'
is 'a leading zero is a decimal number' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 60)" "$NOW" 010)" 'skip 540'
is 'no earlier comment: review' \
   "$(cooldown_decide "$SHA" '' '' "$NOW" 10)" 'review'
# Fail-safe: a time that cannot be read never skips. A skip that can never end
# leaves the PR without a review. One extra review costs one model run.
is 'an empty time: review, and say the time was unreadable' \
   "$(cooldown_decide "$SHA" "$SHA" '' "$NOW" 10)" 'review unreadable-time'
is 'a text that is not a time: review, and say so' \
   "$(cooldown_decide "$SHA" "$SHA" 'yesterday' "$NOW" 10)" 'review unreadable-time'
is 'a time in the future: review, and say so' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago -300)" "$NOW" 10)" 'review unreadable-time'
is 'a time with a fraction of a second: review, and say so' \
   "$(cooldown_decide "$SHA" "$SHA" '2026-10-22T11:59:30.123Z' "$NOW" 10)" 'review unreadable-time'
is 'a value of more than 9 digits is capped, not wrapped: skip' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 60)" "$NOW" 99999999999999999999 | cut -d' ' -f1)" 'skip'
is 'a minutes value that is not a number: review' \
   "$(cooldown_decide "$SHA" "$SHA" "$(ago 60)" "$NOW" abc)" 'review'

# ── the last comment of the reviewer ──────────────────────────────────────
M=pr-reviewer
mk() { # login first-line createdAt
  jq -n --arg l "$1" --arg b "$2" --arg t "$3" '{author:{login:$l},body:($b + "\n\n> **Automated review: ✅ Approved**"),createdAt:$t}'
}
info() { jq -sc '{reviews:[],comments:.}'; }
K1="$SHA-0123456789ab"; K2="$OTHER-0123456789ab"
INFO="$( { mk app/rev "<!-- $M $K2 -->" 2026-10-22T11:00:00Z
           mk app/rev "<!-- $M $K1 -->" 2026-10-22T11:30:00Z
           mk app/rev "<!-- $M postmerge-blocker -->" 2026-10-22T11:59:00Z
           mk mallory "<!-- $M $K2 -->" 2026-10-22T11:59:30Z; } | info)"
is 'the last comment of the reviewer wins, a marker without a head is ignored, a stranger is ignored' \
   "$(cooldown_last_gate_comment "$INFO" "$M" rev)" "$SHA 2026-10-22T11:30:00Z"
is 'a stranger alone gives nothing' \
   "$(cooldown_last_gate_comment "$(mk mallory "<!-- $M $K1 -->" 2026-10-22T11:30:00Z | info)" "$M" rev)" ''
is 'a marker below the first line does not count' \
   "$(cooldown_last_gate_comment "$(mk app/rev "hello
<!-- $M $K1 -->" 2026-10-22T11:30:00Z | info)" "$M" rev)" ''
is 'input that is not JSON gives nothing' "$(cooldown_last_gate_comment 'x' "$M" rev)" ''
is 'a comment with no createdAt gives the head and an empty time' \
   "$(cooldown_last_gate_comment "$(jq -nc --arg b "<!-- $M $K1 -->" '{comments:[{author:{login:"rev"},body:$b}]}')" "$M" rev)" "$SHA "

# ── the setting ───────────────────────────────────────────────────────────
is 'default is 10 minutes' "$(unset PRREVIEW_GATE_PR_COOLDOWN_MIN; . lib/cooldown.sh; echo "$COOLDOWN_MIN")" 10
for v in 0 7 010 999999999 1000000000 99999999999999999999; do
  is "setting $v is accepted" "$(PRREVIEW_GATE_PR_COOLDOWN_MIN=$v bash -c '. lib/cooldown.sh; cooldown_knob_ok && echo ok')" ok
done
for v in -1 1.5 ten ' 5'; do
  is "setting '$v' is refused" "$(PRREVIEW_GATE_PR_COOLDOWN_MIN=$v bash -c '. lib/cooldown.sh; cooldown_knob_ok 2>&1 || echo refused' | tail -1)" refused
done

if [ "$FAILED" -eq 0 ]; then echo "PASS: lib/cooldown.sh"; else echo "FAIL: lib/cooldown.sh"; exit 1; fi
