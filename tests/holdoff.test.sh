#!/usr/bin/env bash
# Tests for lib/holdoff.sh — the cross-round memory that stops the gate
# re-reviewing a head whose review just failed.
#
# Run: bash tests/holdoff.test.sh
#
# What this guards is a cost defect with no functional symptom. The gate's only
# record that a head was reviewed is a comment on the PR, so a round that fails
# before posting leaves nothing behind and the next round does the entire review
# again, against the same head, every round.
# Nothing breaks; the only symptom is the bill.
#
# The assertions below are mostly about the DIRECTION of each failure, because
# that is what makes this safe: a hold means "do not review", which means "do
# not approve", so a wrong hold delays a verdict and never lets a PR through
# early. A corrupt state file, by contrast, must NOT hold — an unreadable file
# that stopped reviews would be the one way this mechanism could hurt.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf '  ok   %s\n' "$*"; }
is()   { [ "$2" = "$3" ] && ok "$1" || fail "$1: expected '$3', got '$2'"; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export PRREVIEW_GATE_HOLDOFF_DIR="$TMP/hold"
export PRREVIEW_GATE_HOLDOFF_QUOTA=1800
export PRREVIEW_GATE_HOLDOFF_FAIL=300
# shellcheck source=/dev/null
. ./lib/holdoff.sh || { echo "lib/holdoff.sh will not source"; exit 1; }

NOW=1000000

# ── path: untrusted input never becomes a path ────────────────────────────
# $KEY is derived from a PR title and body, which this gate treats as
# attacker-controlled. A key that is not what we expect must yield NO path at
# all rather than a path somewhere else.
P="$(holdoff_path "o/r" 42 "abc123-def456")" || P=""
[ -n "$P" ] || fail "a well-formed key produced no path"
case "$P" in */r-42-abc123-def456) ok "path is repo-pr-key under the hold dir" ;;
  *) fail "unexpected path shape: $P" ;; esac
for bad in "../../etc/passwd" "a/b" "a b" 'a$b' "" "a;rm"; do
  holdoff_path "o/r" 42 "$bad" >/dev/null 2>&1 \
    && fail "key '$bad' was accepted into a filename"
done
ok "keys with path or shell metacharacters are refused"
for badpr in "" "abc" "1x" "-1"; do
  holdoff_path "o/r" "$badpr" "abc" >/dev/null 2>&1 \
    && fail "pr '$badpr' was accepted"
done
ok "a non-numeric PR number is refused"

# ── set / active / clear ──────────────────────────────────────────────────
F="$TMP/hold/r-42-abc"
holdoff_active "$F" "$NOW" && fail "a hold that was never set is active"
ok "no state file means no hold"

holdoff_set "$F" quota "$NOW" || fail "holdoff_set failed"
holdoff_active "$F" "$NOW" || fail "a fresh quota hold is not active"
ok "a quota hold is active immediately"
is "the quota cooldown is the full window" \
   "$(holdoff_remaining "$F" "$NOW")" "1800"
is "the reason survives for the log line" "$(holdoff_reason "$F")" "quota"

# The deadline is a deadline: one second before it holds, at it does not.
holdoff_active "$F" "$(( NOW + 1799 ))" || fail "the hold expired one second early"
holdoff_active "$F" "$(( NOW + 1800 ))" && fail "the hold outlived its deadline"
ok "the hold ends exactly at its deadline, not before or after"
is "remaining never goes negative" "$(holdoff_remaining "$F" "$(( NOW + 9999 ))")" "0"

# A non-quota failure gets the shorter patience: retrying a crashed call often
# works, and holding it for half an hour would delay real reviews.
G="$TMP/hold/r-43-abc"
holdoff_set "$G" failed "$NOW" || fail "holdoff_set(failed) failed"
is "a non-quota failure holds for the short window" \
   "$(holdoff_remaining "$G" "$NOW")" "300"
is "an unrecognised reason is treated as an ordinary failure" \
   "$( holdoff_set "$TMP/hold/r-44-abc" nonsense "$NOW"; holdoff_remaining "$TMP/hold/r-44-abc" "$NOW")" "300"

holdoff_clear "$F"
holdoff_active "$F" "$NOW" && fail "the hold survived holdoff_clear"
ok "clearing removes the hold"
holdoff_clear "$TMP/hold/never-existed" || fail "clearing a missing hold returned non-zero"
ok "clearing something that is not there is not an error"

# ── a corrupt state file must NOT hold ────────────────────────────────────
# This is the one direction that could hurt: a file this code cannot read must
# never be able to stop the gate reviewing. Everything else here fails toward
# "wait"; this one fails toward "review anyway", on purpose.
for junk in "" "not-a-number quota" "-5 quota" "  " $'\n'; do
  printf '%s' "$junk" > "$TMP/hold/junk"
  holdoff_active "$TMP/hold/junk" "$NOW" \
    && fail "a corrupt state file ('$junk') held the review back"
done
ok "a corrupt state file does not hold — it fails toward reviewing"
is "remaining on a corrupt file is 0, not empty" \
   "$(printf 'garbage' > "$TMP/hold/junk"; holdoff_remaining "$TMP/hold/junk" "$NOW")" "0"
is "reason on a corrupt file is a word, not empty" \
   "$(printf '123' > "$TMP/hold/junk2"; holdoff_reason "$TMP/hold/junk2")" "unknown"

# A `now` the caller failed to compute must not hold either.
holdoff_set "$F" quota "$NOW"
holdoff_active "$F" "" && fail "an empty 'now' held the review back"
holdoff_active "$F" "abc" && fail "a non-numeric 'now' held the review back"
ok "an unusable clock reading does not hold"

# ── prune ─────────────────────────────────────────────────────────────────
touch "$TMP/hold/old"; touch -t 200001010000 "$TMP/hold/old" 2>/dev/null
touch "$TMP/hold/new"
holdoff_prune 2
[ -e "$TMP/hold/new" ] || fail "prune removed a current hold"
[ -e "$TMP/hold/old" ] && fail "prune kept a stale hold"
ok "prune drops stale holds and keeps current ones"

# ── stuck heads ───────────────────────────────────────────────────────────
rm -f "$TMP/hold"/*
touch -t 200001010000 "$TMP/mark"
for _ in 1 2 3; do holdoff_set "$TMP/hold/r-1-k" failed "$NOW"; done
for _ in 1 2; do holdoff_set "$TMP/hold/r-2-k" postfail "$NOW"; done
for _ in 1 2 3; do holdoff_set "$TMP/hold/r-3-k" postfail "$NOW"; done
for _ in 1 2 3; do holdoff_set "$TMP/hold/r-4-k" quota "$NOW"; done
: > "$TMP/hold/r-1-k.verdict"
is "stuck: three failures in a row, of the review or the post, count; quota and two do not" \
   "$(holdoff_stuck "$TMP/mark" 3 | sort | tr '\n' ' ')" "r-1-k r-3-k "
touch "$TMP/mark2"; sleep 1; holdoff_set "$TMP/hold/r-3-k" postfail "$NOW"
is "stuck: only holds written since the mark" "$(holdoff_stuck "$TMP/mark2" 3)" "r-3-k"
is "stuck: a missing mark reports nothing" "$(holdoff_stuck "$TMP/nope" 3)" ""

# ── the wiring in pr-autoreview.sh ────────────────────────────────────────
SRC="$(cat pr-autoreview.sh)"
grep -qF 'holdoff_stuck "$ROUND_MARK" 3' <<<"$SRC" || fail "pr-autoreview.sh never asks which heads are stuck"
grep -qF 'lib/holdoff.sh' <<<"$SRC" || fail "pr-autoreview.sh does not source lib/holdoff.sh"
grep -qF 'holdoff_active' <<<"$SRC"  || fail "pr-autoreview.sh never checks the hold"
grep -qF 'holdoff_set'    <<<"$SRC"  || fail "pr-autoreview.sh never records a hold"
grep -qF 'holdoff_clear'  <<<"$SRC"  || fail "pr-autoreview.sh never clears a hold"
grep -qF 'holdoff_prune'  <<<"$SRC"  || fail "pr-autoreview.sh never prunes"

# The check has to sit BEFORE the model work, or it saves nothing. Compared by
# line number against the first thing that costs a call.
#
# Located by the MAIN path's own `if` form, not `head -1` over every
# holdoff_active: another branch gained its own
# check above it, `head -1` silently moved onto that one, and this assertion
# stopped covering the path it names. Both would still pass the comparison,
# so nothing would have gone red if someone moved the real one past the model
# call — the exact regression this line exists to catch.
L_HOLD="$(grep -n '^  if \[ -n "\$HOLD_F" \] && holdoff_active' pr-autoreview.sh | head -1 | cut -d: -f1)"
L_CALL="$(grep -n 'Slice a large diff across several review passes' pr-autoreview.sh | head -1 | cut -d: -f1)"
[ -n "$L_HOLD" ] && [ -n "$L_CALL" ] && [ "$L_HOLD" -lt "$L_CALL" ] \
  || fail "the hold is checked at line ${L_HOLD:-?}, after the review work starts at ${L_CALL:-?} — it would save nothing"
ok "the hold is checked before anything calls the model"


# A quota hit must set the LONG hold, not the short one: retrying inside a
# rate-limit window cannot succeed, and the short window would still spin.
grep -qF 'holdoff_set "$HOLD_F" quota' <<<"$SRC" \
  || fail "a quota hit does not record a quota-length hold"

ok "a quota hit records the long hold"

# ── a delivery that fails is the expensive half ───────────────────────────
#
# The review ran, cost every model call it was going to cost, and then GitHub
# would not take the comment that carries the marker. Without a hold the next
# round reads the PR as never reviewed and pays for the whole thing again, 60
# seconds later — the same spin the quota case pays, but starting from a review
# that actually succeeded.
is "postfail keeps its own name in the journal" \
   "$(holdoff_set "$TMP/hold/pf" postfail "$NOW"; holdoff_reason "$TMP/hold/pf")" "postfail"
is "postfail uses the short cooldown, not the quota one" \
   "$(rm -f "$TMP/hold/pf1"; holdoff_set "$TMP/hold/pf1" postfail 1000; head -1 "$TMP/hold/pf1" | cut -d' ' -f1)" \
   "$(( 1000 + HOLDOFF_FAIL_SECONDS ))"

# ── the same failure twice in a row waits longer ──────────────────────────
#
# An outage of hours (GitHub answering 503, say) under a flat postfail
# cooldown is one COMPLETE review of every open PR every five minutes, for as
# long as the outage lasts — a bill nobody sees until it arrives.
rm -f "$TMP/hold/esc"
holdoff_set "$TMP/hold/esc" postfail 1000
is "first postfail waits the base" \
   "$(head -1 "$TMP/hold/esc" | cut -d' ' -f1)" "$(( 1000 + HOLDOFF_FAIL_SECONDS ))"
holdoff_set "$TMP/hold/esc" postfail 2000
is "second in a row doubles" \
   "$(head -1 "$TMP/hold/esc" | cut -d' ' -f1)" "$(( 2000 + HOLDOFF_FAIL_SECONDS * 2 ))"
holdoff_set "$TMP/hold/esc" postfail 3000
is "third in a row doubles again" \
   "$(head -1 "$TMP/hold/esc" | cut -d' ' -f1)" "$(( 3000 + HOLDOFF_FAIL_SECONDS * 4 ))"
is "the reason is still one word, not 'postfail 3'" \
   "$(holdoff_reason "$TMP/hold/esc")" "postfail"

# The doubling has a ceiling: an outage that outlives it will not be fixed by
# asking sooner either.
for _ in 1 2 3 4 5 6 7 8; do holdoff_set "$TMP/hold/esc" postfail 4000; done
is "the wait is capped" \
   "$(head -1 "$TMP/hold/esc" | cut -d' ' -f1)" "$(( 4000 + HOLDOFF_MAX_SECONDS ))"

# A different reason is a different problem: inheriting the escalation would
# hold a head far longer than either failure on its own earned.
holdoff_set "$TMP/hold/esc" quota 5000
is "a new reason resets the escalation" \
   "$(head -1 "$TMP/hold/esc" | cut -d' ' -f1)" "$(( 5000 + HOLDOFF_QUOTA_SECONDS ))"

# Every branch where the verdict fails to reach the PR records the hold, and
# every branch where it LANDS clears it. Source shape, because these live
# inside review_one_pr and cannot be called alone.
#
# The branch, not a line window. This used to take `grep -A2 -B6 "$msg"`, which
# reaches six lines up and lands inside the PREVIOUS branch: the assertion for
# 'approve FAILED to post' was satisfied by the holdoff_set belonging to the
# size-hold branch above it, so deleting the line it meant to guard left the
# test green. branch_of walks back only as far
# as the nearest `else` / `; then`, which is where the branch actually begins.
branch_of() {  # $1 = a unique fragment of that branch's echo line
  awk -v pat="$1" '
    /(^|[[:space:]])else[[:space:]]*$/ || /;[[:space:]]*then[[:space:]]*$/ { buf = "" }
    { buf = buf $0 "\n" }
    index($0, pat) { printf "%s", buf; found = 1; exit }
    END { if (!found) exit 1 }
  ' pr-autoreview.sh
}

# The list is READ OUT OF THE SOURCE, not hand-kept. The comment here used to
# say "every branch" while naming two of them; a third and a fourth were added
# later and nothing noticed. Every one of
# these branches spells its message "... FAILED to post", so that is the
# enumerator.
#
# The FULL match (with "PR #$PR: " still attached) is what gets passed to
# branch_of, not the stripped display text:
# branch_of does a plain substring search over the whole file, and a longer
# message elsewhere in it can end in the same words as the plain-verdict-path
# message ("approve FAILED to post"). Searching on the stripped tail
# alone let branch_of match the FIRST, longer occurrence in file order and
# silently mis-isolate the later, unrelated plain-verdict-path branch — the
# exact same failure mode this function was already named for,
# just from an overlap between two enumerated entries instead of one term
# haunting a fixed line window. Stripped only for the human-readable message.
#
NFAIL=0
while IFS= read -r WFULL; do
  [ -n "$WFULL" ] || continue
  NFAIL=$((NFAIL + 1))
  W="${WFULL#PR #\$PR: }"
  BLK="$(branch_of "$WFULL")" \
    || { fail "could not isolate the branch that reports '$W'"; continue; }
  grep -qF 'holdoff_set "$HOLD_F" postfail' <<<"$BLK" \
    || fail "the branch that reports '$W' does not hold the head — the completed review is discarded AND re-run next round"
  case "$W" in
    *)
      grep -qF 'holdoff_verdict_save "$REPLAY_F"' <<<"$BLK" \
        || fail "the branch that reports '$W' does not park the verdict — the next round re-buys a review that was already paid for" ;;
  esac
done <<<"$(grep -oE 'PR #\$PR: [^"]*FAILED to post' pr-autoreview.sh | sort -u)"
[ "$NFAIL" -ge 2 ] || fail "only $NFAIL undelivered-verdict branch(es) found — the enumerator broke and this check is vacuous"
[ "$RC" = 0 ] && ok "all $NFAIL undelivered-verdict branches hold the head and park the verdict"

# The other side: a verdict that LANDED must clear both, or a stale parked
# verdict outlives the head it belongs to. One branch once did not while all
# the others did.
NLAND=0
for W in 'review-only verdict comment posted' 'split requested, not reviewed'; do
  NLAND=$((NLAND + 1))
  BLK="$(branch_of "$W")" \
    || { fail "could not isolate the branch that reports '$W'"; continue; }
  grep -qF 'holdoff_verdict_clear "$REPLAY_F"' <<<"$BLK" \
    || fail "the branch that reports '$W' delivered the verdict but did not clear the parked copy"
  grep -qF 'holdoff_clear "$HOLD_F"' <<<"$BLK" \
    || fail "the branch that reports '$W' delivered the verdict but did not clear the hold"
done
[ "$RC" = 0 ] && ok "all $NLAND delivered-verdict branches clear the hold and the parked verdict"

# Every one of them must report the REAL wait, not the config default:
# postfail doubles on a repeat (lib/holdoff.sh holdoff_set), and a log line
# pinned to the base default reads "5 minutes" through an outage the doubling
# has actually pushed to an hour. Same enumerator and same branch_of as above,
# so a branch added later is covered without anyone remembering to add it here.
#
# Passes the FULL match to branch_of, exactly like the loop above — this one
# was left on the stripped form one round longer and so
# was silently checking another branch whose message ends in the same
# tail, never the plain-verdict branch it names. See that loop's comment for
# why the prefix has to stay attached.
NWAIT=0
while IFS= read -r WFULL; do
  [ -n "$WFULL" ] || continue
  NWAIT=$((NWAIT + 1))
  W="${WFULL#PR #\$PR: }"
  BLK="$(branch_of "$WFULL")" \
    || { fail "could not isolate the branch that reports '$W'"; continue; }
  grep -qF 'holdoff_remaining' <<<"$BLK" \
    || fail "the branch that reports '$W' does not compute its wait with holdoff_remaining — it will print the base default even when postfail has doubled it"
done <<<"$(grep -oE 'PR #\$PR: [^"]*FAILED to post' pr-autoreview.sh | sort -u)"
[ "$NWAIT" -ge 2 ] || fail "only $NWAIT wait-reporting branch(es) found — the enumerator broke and this check is vacuous"
[ "$RC" = 0 ] && ok "all $NWAIT wait-reporting branches use the real computed wait, not the base default"


# ── the verdict cache: re-post what a previous round already paid for ─────
# The hold alone stops the SPIN, not the WASTE: when the cooldown expires the
# gate still re-reviews a head whose verdict was already computed and paid for.
# A post failure is the expensive half — the review ran to completion, cost
# every model call it makes, and was thrown away because GitHub would not take
# it. So the verdict is parked next to the hold and re-posted without asking
# the model again.
#
# Direction of every failure here is "review it again": a cache that cannot be
# read, or belongs to a different head, must never stop or alter a review. It
# is an optimisation, and an optimisation that can block is a defect.
VP="$(holdoff_verdict_path "$TMP/hold/repo-7-abc")"
is "the cache sits next to its hold" "$VP" "$TMP/hold/repo-7-abc.verdict"
holdoff_verdict_path "" >/dev/null 2>&1 \
  && fail "an empty hold path yields a cache path" \
  || ok "an empty hold path yields no cache path"

# A body holds review text verbatim: newlines, quotes, multibyte text, and
# the marker comment. Round-tripping it through anything lossy would re-post a
# mangled verdict, which is worse than re-reviewing.
BODY_HEAD='> **Automated review: ❌ not passed, naïve café** — "quoted", $dollar, `backtick`'
BODY_ITEM='- item 1 (über): lib/x.sh:12'
BODY_IN="<!-- pr-reviewer abc -->

> [!CAUTION]
$BODY_HEAD
$BODY_ITEM"
CLEANED_IN='{"verdict":"request_changes","findings":[{"severity":"HIGH"}]}'
holdoff_verdict_save "$VP" "abc" "request_changes" "$BODY_IN" "$CLEANED_IN" \
  || fail "saving a verdict failed"
LOADED="$(holdoff_verdict_load "$VP" "abc")" || fail "loading the verdict just saved failed"
is "the verdict round-trips"  "$(jq -r '.verdict' <<<"$LOADED")" "request_changes"
is "the body round-trips"     "$(jq -r '.body'    <<<"$LOADED")" "$BODY_IN"
is "the findings round-trip"  "$(jq -r '.cleaned' <<<"$LOADED")" "$CLEANED_IN"

# The key is head sha + a digest of title/body/base. A cache written for one
# head must never be re-posted onto another: that would put a review of code
# nobody wrote onto a PR, which is the one outcome worse than paying twice.
holdoff_verdict_load "$VP" "different-key" >/dev/null 2>&1 \
  && fail "a cache written for another key was accepted" \
  || ok "a cache written for another key is refused"

# 600/700, for the same reason the round logs are 700: the parked body is
# the PRE-scan text, so it can hold exactly the values the outbound scan exists
# to keep off GitHub.
# GNU form FIRST, BSD second. `-f` means two different things: BSD "use this
# format", GNU "show the FILE SYSTEM instead of the file". Measured on a box
# with both binaries: GNU `stat -f '%Lp' FILE` exits 1, so the
# `||` does fire — but it has already printed five lines of filesystem status
# to stdout, so mode() came back as that block with "600" on the end and both
# assertions below failed on Linux. The other order is unambiguous: BSD rejects
# `-c` outright (rc=1, nothing on stdout) and GNU accepts it, so each platform
# answers on its first try.
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
is "the cache file is 600"      "$(mode "$VP")"            "600"
is "the cache directory is 700" "$(mode "$(dirname "$VP")")" "700"

# Every unreadable shape answers the same way: no cache, review normally.
printf 'not json at all\n' > "$TMP/hold/corrupt.verdict"
holdoff_verdict_load "$TMP/hold/corrupt.verdict" "abc" >/dev/null 2>&1 \
  && fail "a corrupt cache was accepted" || ok "a corrupt cache is refused"
printf '{"key":"abc"}\n' > "$TMP/hold/partial.verdict"
holdoff_verdict_load "$TMP/hold/partial.verdict" "abc" >/dev/null 2>&1 \
  && fail "a cache with no body was accepted" || ok "a cache with no body is refused"
holdoff_verdict_load "$TMP/hold/nothing-here.verdict" "abc" >/dev/null 2>&1 \
  && fail "a missing cache was accepted" || ok "a missing cache is refused"

holdoff_verdict_clear "$VP"
[ -e "$VP" ] && fail "clearing left the cache behind" || ok "clearing removes the cache"

# Pruning covers it too. A parked verdict outlives its usefulness the moment
# the head moves, and it is the biggest file this directory holds.
mkdir -p "$TMP/hold"
printf '{"key":"old"}\n' > "$TMP/hold/stale-1-old.verdict"
touch -t 202001010000 "$TMP/hold/stale-1-old.verdict"
holdoff_prune 2
[ -e "$TMP/hold/stale-1-old.verdict" ] \
  && fail "prune left a stale verdict cache behind" || ok "prune removes stale verdict caches"

# ── the gate actually uses it ─────────────────────────────────────────────
# Source shape again: these live inside review_one_pr.
#
# Asked BEFORE the model. A cache consulted after the review has already run
# saves nothing at all, which is the whole point of this change.
LOAD_LN="$(grep -n 'holdoff_verdict_load' pr-autoreview.sh | head -1 | cut -d: -f1)"
CALL_LN="$(grep -n 'timeout "$REVIEW_TIMEOUT" "$CLAUDE_BIN" -p --model "$REVIEW_MODEL"' pr-autoreview.sh | head -1 | cut -d: -f1)"
[ -n "$LOAD_LN" ] && [ -n "$CALL_LN" ] && [ "$LOAD_LN" -lt "$CALL_LN" ] \
  && ok "the parked verdict is looked for before the model is called" \
  || fail "the parked verdict is not looked for before the model is called (load=$LOAD_LN review call=$CALL_LN)"

# Saved wherever a VERDICT fails to reach the PR: the same branches that hold.
#
# Both counts are comment-filtered and the save side is matched WITH its
# argument: a bare count also counts the comments
# that only mention the function, and can then pass on a coincidence.
N_SET="$(grep -c '^[^#]*holdoff_set "$HOLD_F" postfail' pr-autoreview.sh)"
N_SAVE="$(grep -c '^[^#]*holdoff_verdict_save "$REPLAY_F"' pr-autoreview.sh)"
is "every undelivered verdict is parked, not just held" "$N_SAVE" "$N_SET"

# Cleared wherever one lands. A parked verdict that outlives its delivery would
# be re-posted onto a PR that already has it.
N_CLR="$(grep -c 'holdoff_clear "$HOLD_F"' pr-autoreview.sh)"
N_VCLR="$(grep -c 'holdoff_verdict_clear' pr-autoreview.sh)"
[ "$N_VCLR" -ge "$N_CLR" ] \
  && ok "every landed verdict clears its parked copy" \
  || fail "a landed verdict leaves its parked copy behind (clear=$N_CLR verdict_clear=$N_VCLR)"

# ── the seam holds: both paths must leave the same variables set ──────────
# The replay skips the whole review — about 1400 lines — and lands in the same
# delivery block. So every variable the delivery block reads has to be set on
# BOTH paths, and the script runs under `set -u`: a variable only the review
# path assigns does not read as empty on the replay, it kills the round.
#
# This is the assertion that makes the seam safe to keep. Adding one line to
# the delivery block that reads something computed during the review is an easy
# and completely invisible mistake, and it would only ever fire on the rare
# path — after a post failure, which is exactly when the gate is already
# unhappy.
#
# Which delivery-block variables in $1 (a script shaped like pr-autoreview.sh:
# REPLAY-SEAM-BEGIN, an `if [ -n "$REPLAY_JSON" ]; then ... else ... fi`, then
# REPLAY-SEAM-END) are NOT provably set on both sides of the seam. Prints them
# space-separated; empty means clean. Non-zero and silent when the markers
# are not found — the caller has its own assertion for that.
#
# Four ways a name is legitimately in scope on both paths, and each is
# checked for real rather than assumed:
#
#   1. Set in BEFORE — runs on every path, unconditionally, ahead of the
#      `if`, so no ordering check is needed.
#   2. Bound by a `for`/`read` in BEFORE — same reasoning as 1.
#   3. Set inside the replay branch itself (REPLAY) — but REPLAY has to stop
#      at that branch's own `else`, not a fixed line count. A flat
#      `sed -n "SB,SB+45p"` used to run past the branch and a few lines into
#      the review-only body below it; a name first assigned in those
#      bled-over lines read as "set on the replay path too" when it plainly
#      was not. The branch always opens
#      right after SB and always closes with a same-indent `else` before the
#      ~1400-line body starts, so that line is the real boundary — no guess.
#   4. Set inside DELIVERY itself, or bound there by a `for`/`read` — but
#      only if that happens AT OR BEFORE the first read, not merely
#      "somewhere in the block". A bare `grep -q "$V="` against the whole
#      block cannot tell a value computed early from one only assigned on a
#      line the read has already passed on the replay path; that is the same
#      set -u kill this whole check exists to catch, just moved inside
#      DELIVERY instead of across the seam.
holdoff_seam_missing_vars() {
  local f="$1" sb se else_ln replay_end before replay delivery v missing=""
  local assign_ln bind_ln use_ln
  sb="$(grep -n 'REPLAY-SEAM-BEGIN' "$f" | cut -d: -f1)"
  se="$(grep -n 'REPLAY-SEAM-END'   "$f" | cut -d: -f1)"
  [ -n "$sb" ] && [ -n "$se" ] && [ "$sb" -lt "$se" ] || return 1
  else_ln="$(awk -v sb="$sb" -v se="$se" 'NR>sb && NR<se && $0=="  else" {print NR; exit}' "$f")"
  replay_end=$(( ${else_ln:-$((sb + 1))} - 1 ))
  before="$(sed -n "1,$((sb - 1))p" "$f")"
  replay="$(sed -n "${sb},${replay_end}p" "$f")"
  delivery="$(sed -n "$((se + 1)),\$p" "$f" | grep -v '^[[:space:]]*#')"
  # `${VAR:-...}` is stripped first: a default IS the both-paths answer, and
  # this gate uses that idiom deliberately all over the delivery block.
  for v in $(printf '%s\n' "$delivery" \
               | sed 's/\${[A-Z][A-Z0-9_]*:-[^}]*}//g' \
               | grep -oE '\$\{?[A-Z][A-Z0-9_]{2,}\}?' | tr -d '${}' | sort -u); do
    case "$v" in BASH*|PATH|HOME|IFS|OSTYPE|PWD|RANDOM|SECONDS|LC_ALL|LANG|PIPESTATUS) continue ;; esac
    # Assignment is matched anywhere on the line, not just at its start:
    # `if ! VAR="$(...)"` and `for VAR in` are both used here, and anchoring
    # on the start reads them as never assigned.
    grep -qE "(^|[^A-Za-z0-9_])$v=" <<<"$before" && continue
    grep -qE "(for|read( -[a-zA-Z])*)( [A-Za-z0-9_]+)* $v([;[:space:]]|\$)" <<<"$before" && continue
    grep -qE "(^|[^A-Za-z0-9_])$v=" <<<"$replay" && continue
    # Constants live in the libs this script sources, not in the script.
    grep -qhE "(^|[^A-Za-z0-9_])$v=" lib/*.sh >/dev/null 2>&1 && continue
    # DELIVERY may supply its own value, but only strictly before the first
    # read this loop is checking.
    assign_ln="$(grep -nE "(^|[^A-Za-z0-9_])$v=" <<<"$delivery" | head -1 | cut -d: -f1)"
    bind_ln="$(grep -nE "(for|read( -[a-zA-Z])*)( [A-Za-z0-9_]+)* $v([;[:space:]]|\$)" <<<"$delivery" | head -1 | cut -d: -f1)"
    use_ln="$(grep -nE "\\\$\\{?$v\\}?([^A-Za-z0-9_]|\$)" <<<"$delivery" | head -1 | cut -d: -f1)"
    [ -n "$assign_ln" ] && [ -n "$use_ln" ] && [ "$assign_ln" -le "$use_ln" ] && continue
    [ -n "$bind_ln" ] && [ -n "$use_ln" ] && [ "$bind_ln" -le "$use_ln" ] && continue
    missing="$missing $v"
  done
  printf '%s\n' "$missing"
}

is "the seam opens exactly once" "$(grep -c 'REPLAY-SEAM-BEGIN' pr-autoreview.sh)" "1"
is "the seam closes exactly once" "$(grep -c 'REPLAY-SEAM-END' pr-autoreview.sh)" "1"

if MISSING="$(holdoff_seam_missing_vars pr-autoreview.sh)"; then
  [ -z "$MISSING" ] \
    && ok "every variable the delivery block reads is set on both paths" \
    || fail "the replay path leaves these unset, and set -u makes that fatal:$MISSING"
else
  fail "the replay seam markers were not found — the assertion above proves nothing"
fi

# ── the tightened exemptions actually catch what the loose ones missed ────
# Fixture scripts shaped like the real seam, each with exactly one planted
# violation, run through the SAME function above. Grepping pr-autoreview.sh
# for the fix cannot tell a real tightening from a comment edit; only running
# the check against a script it must reject can.
SEAMTMP="$TMP/seam"
mkdir -p "$SEAMTMP"

# Every fixture's `else` is indented exactly two spaces — not a style choice,
# that is the literal boundary marker holdoff_seam_missing_vars looks for
# (matching how it always appears in pr-autoreview.sh itself).
#
# A name first assigned a few lines into the review-only `else` — exactly
# where the old fixed-size REPLAY window used to still be reading — read in
# DELIVERY and set nowhere else. The old window covered this; the real `else`
# boundary must not.
cat > "$SEAMTMP/bleed.sh" <<'EOF'
#!/usr/bin/env bash
# REPLAY-SEAM-BEGIN
if [ -n "$REPLAY_JSON" ]; then
  OK_VAR="fine"
  else
  # a few lines of review-only setup before the value in question
  NOISE_1=1
  NOISE_2=2
  NOISE_3=3
  ZZTEST_BLEED_VAR="leaked from the review-only branch"
fi
# REPLAY-SEAM-END
echo "$OK_VAR $ZZTEST_BLEED_VAR"
EOF
BLEED_MISSING="$(holdoff_seam_missing_vars "$SEAMTMP/bleed.sh")"
case " $BLEED_MISSING " in
  *' ZZTEST_BLEED_VAR '*) ok "a name from the review-only branch is caught, not exempted as REPLAY" ;;
  *) fail "a name from the review-only branch is caught, not exempted as REPLAY: got missing='$BLEED_MISSING'" ;;
esac

# A name DELIVERY reads before it assigns it. The old "assigned somewhere in
# DELIVERY" exemption cleared this; on the replay path this line runs first
# and set -u kills the round exactly the way an unset review-only name would.
cat > "$SEAMTMP/order.sh" <<'EOF'
#!/usr/bin/env bash
# REPLAY-SEAM-BEGIN
if [ -n "$REPLAY_JSON" ]; then
  :
  else
  :
fi
# REPLAY-SEAM-END
echo "$ZZTEST_ORDER_VAR"
ZZTEST_ORDER_VAR="assigned too late to help the read above"
EOF
ORDER_MISSING="$(holdoff_seam_missing_vars "$SEAMTMP/order.sh")"
case " $ORDER_MISSING " in
  *' ZZTEST_ORDER_VAR '*) ok "a DELIVERY read-before-set is caught, not exempted as DELIVERY-self" ;;
  *) fail "a DELIVERY read-before-set is caught, not exempted as DELIVERY-self: got missing='$ORDER_MISSING'" ;;
esac

# A `for` binding that DELIVERY reads before the loop runs — same shape as
# above, for exemption 4's for/read half instead of its plain-assignment half.
cat > "$SEAMTMP/loop-order.sh" <<'EOF'
#!/usr/bin/env bash
# REPLAY-SEAM-BEGIN
if [ -n "$REPLAY_JSON" ]; then
  :
  else
  :
fi
# REPLAY-SEAM-END
echo "$ZZTEST_LOOP_VAR"
for ZZTEST_LOOP_VAR in a b c; do :; done
EOF
LOOP_MISSING="$(holdoff_seam_missing_vars "$SEAMTMP/loop-order.sh")"
case " $LOOP_MISSING " in
  *' ZZTEST_LOOP_VAR '*) ok "a DELIVERY for-loop bound after its read is caught, not exempted as FOR-READ" ;;
  *) fail "a DELIVERY for-loop bound after its read is caught, not exempted as FOR-READ: got missing='$LOOP_MISSING'" ;;
esac

# And a clean script — one legitimate example of each of the four ways —
# still passes. The three fixtures above prove the tightening bites; this one
# proves it does not bite everything.
cat > "$SEAMTMP/clean.sh" <<'EOF'
#!/usr/bin/env bash
ZZTEST_BEFORE_VAR="set ahead of the seam"
for ZZTEST_BEFORE_LOOP in x y z; do :; done
# REPLAY-SEAM-BEGIN
if [ -n "$REPLAY_JSON" ]; then
  ZZTEST_REPLAY_VAR="set on the replay path"
  else
  ZZTEST_REPLAY_VAR="recomputed on the review path"
fi
# REPLAY-SEAM-END
ZZTEST_DELIVERY_VAR="set before its own read"
echo "$ZZTEST_BEFORE_VAR $ZZTEST_BEFORE_LOOP $ZZTEST_REPLAY_VAR $ZZTEST_DELIVERY_VAR"
EOF
CLEAN_MISSING="$(holdoff_seam_missing_vars "$SEAMTMP/clean.sh")"
is "a script using all four legitimate ways stays clean" "$CLEAN_MISSING" ""

# ── the three holds are refused up front when they cannot work ──────────
holdoff_knobs_ok 2>/dev/null && ok 'holdoff_knobs_ok takes the values this file runs with' \
  || fail 'holdoff_knobs_ok takes the values this file runs with'
for spec in 'HOLDOFF_QUOTA_SECONDS PRREVIEW_GATE_HOLDOFF_QUOTA' 'HOLDOFF_FAIL_SECONDS PRREVIEW_GATE_HOLDOFF_FAIL' \
            'HOLDOFF_MAX_SECONDS PRREVIEW_GATE_HOLDOFF_MAX'; do
  read -r var knob <<<"$spec"
  for v in 0 abc 3o; do
    OUT="$(eval "$var=\$v"; holdoff_knobs_ok 2>&1)"; KRC=$?
    is "holdoff_knobs_ok refuses $knob=$v" "$KRC:$OUT" \
       "1:$knob must be a whole number of seconds, at least 1; got: $v — refusing to run"
  done
done
# `[ -ge ]` reads 08 as decimal and lets it through, so holdoff_set has to
# read it that way too: `$(( ))` takes it as bad octal and the hold is never
# written, which is the every-round retry this file exists to stop.
for spec in 'HOLDOFF_QUOTA_SECONDS quota' 'HOLDOFF_FAIL_SECONDS failed'; do
  read -r var reason <<<"$spec"
  OUT="$(eval "$var=08"; holdoff_knobs_ok 2>&1 \
         && holdoff_set "$TMP/hold/r-80-$reason" "$reason" "$NOW" 2>&1 \
         && holdoff_remaining "$TMP/hold/r-80-$reason" "$NOW")"
  is "a $reason hold of 08 seconds is 8 seconds" "$OUT" "8"
done
OUT="$(HOLDOFF_MAX_SECONDS=08; holdoff_knobs_ok 2>&1 \
       && holdoff_set "$TMP/hold/r-81-abc" failed "$NOW" 2>&1 \
       && holdoff_set "$TMP/hold/r-81-abc" failed "$NOW" 2>&1 \
       && holdoff_remaining "$TMP/hold/r-81-abc" "$NOW")"
is "a ceiling of 08 caps the doubled hold at 8 seconds" "$OUT" "8"
grep -qE '^holdoff_knobs_ok \|\| exit 2$' pr-autoreview.sh \
  && ok 'pr-autoreview.sh refuses a bad hold before its first review' \
  || fail 'pr-autoreview.sh refuses a bad hold before its first review'

[ "$RC" = 0 ] && echo "PASS: lib/holdoff.sh"
exit "$RC"
