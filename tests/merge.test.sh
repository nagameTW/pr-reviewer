#!/usr/bin/env bash
# Tests for lib/merge.sh. No framework: run  bash tests/merge.test.sh
# — prints PASS and exits 0, or names the first failing assertion.
# The fake gh logs every invocation and exits per-scenario codes, so these
# tests need no network, token, or real gh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. lib/merge.sh || { echo "FAIL: could not source lib/merge.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/gh.log"

fail() { echo "FAIL: $1"; exit 1; }

export GH_LOG="$LOG"
# ── merge_base_allowed ────────────────────────────────────────────────────
# A stacked PR is not treated as a PR into the default branch. Its review tree
# is built from its own base with the diff applied, so the parent's changes are
# there; what this answer still changes is that the convention files are taken
# from the DEFAULT branch (the author must not get to choose what counts as the
# project's conventions) and the prompt says the PR is stacked.
merge_base_allowed main main      || fail "a PR targeting the default branch must count as one"
merge_base_allowed feat/parent main && fail "a stacked PR must NOT count as targeting the default branch"
merge_base_allowed '' main        && fail "an unknown base must NOT count as the default branch (fail closed)"
merge_base_allowed main ''        && fail "an unknown default branch must NOT match any base (fail closed)"
merge_base_allowed '' ''          && fail "both unknown must NOT count as the default branch"
merge_base_allowed develop develop || fail "a repo whose default branch is not main must still work"

# ── merge_size_allowed ────────────────────────────────────────────────────
# The rule exists because an oversized diff does not produce a worse verdict,
# it produces a confident one from a pass that read a fraction of the change,
# and a confident approve is what gets a PR merged. So the interesting
# assertions are the fail-closed ones, not the happy path.
merge_size_allowed 120 4 1000 50    || fail "an ordinary PR must be within the one-pass ceiling"
merge_size_allowed 1000 50 1000 50  || fail "exactly at the ceiling is still allowed"
merge_size_allowed 1001 4 1000 50   && fail "over the line ceiling must be held"
merge_size_allowed 120 51 1000 50   && fail "over the file ceiling must be held"
merge_size_allowed 0 0 1000 50      || fail "an empty diff is not oversized"

# Fail closed on an unreadable size: not knowing how big a change is must not
# read as "small". This is the branch that fires if gh ever stops returning
# additions/deletions.
merge_size_allowed '' 4 1000 50     && fail "an unknown line count must be held"
merge_size_allowed 120 '' 1000 50   && fail "an unknown file count must be held"
merge_size_allowed abc 4 1000 50    && fail "a non-numeric line count must be held"

# ...but a typo'd ceiling switches the rule OFF rather than holding every PR:
# a bad env var must not stop the gate from working at all.
merge_size_allowed 99999 999 '' ''     || fail "an unset ceiling must disable the rule"
merge_size_allowed 99999 999 0 0       || fail "a zero ceiling must disable the rule"
merge_size_allowed 99999 999 abc abc   || fail "a non-numeric ceiling must disable the rule"

# ── disarm_unreviewed_auto_merge ───────────────────────────────────────────
cat > "$TMP/gh" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
exit "${IMMEDIATE_RC:-0}"
EOF2
chmod +x "$TMP/gh"
GH="$TMP/gh"; REPO="example/repo"

: > "$LOG"; export IMMEDIATE_RC=0
OUT="$(disarm_unreviewed_auto_merge '{"autoMergeRequest":{"enabledAt":"x"}}' 7)" \
  || fail "disarming an armed auto-merge should report success"
grep -qx 'pr merge 7 --repo example/repo --disable-auto' "$LOG" \
  || fail "an armed auto-merge must be disarmed with gh pr merge --disable-auto"
grep -qF 'disarmed until this head is reviewed' <<<"$OUT" \
  || fail "disarming must say so in the round log"

: > "$LOG"
OUT="$(disarm_unreviewed_auto_merge '{"autoMergeRequest":null}' 8)" \
  || fail "nothing armed is not a failure"
[ -s "$LOG" ] && fail "nothing armed must not call gh"
[ -z "$OUT" ] || fail "nothing armed must print nothing"

: > "$LOG"; export IMMEDIATE_RC=1
OUT="$(disarm_unreviewed_auto_merge '{"autoMergeRequest":{"enabledAt":"x"}}' 9)" \
  && fail "a failed disarm must return non-zero"
grep -qF 'disarming it FAILED' <<<"$OUT" || fail "a failed disarm must say so"
unset IMMEDIATE_RC

# GATE_DISARM_AUTO_MERGE=0 (off): an armed auto-merge is
# left alone, and a token that could not disarm it does not skip the PR.
: > "$LOG"; export IMMEDIATE_RC=1
OUT="$(GATE_DISARM_AUTO_MERGE=0 disarm_unreviewed_auto_merge '{"autoMergeRequest":{"enabledAt":"x"}}' 10)" \
  || fail "with the disarm switched off, an armed auto-merge is not a failure"
[ -s "$LOG" ] && fail "with the disarm switched off, gh must not be called"
unset IMMEDIATE_RC

# The caller's half. It runs the block itself, lifted out of pr-autoreview.sh
# (from `HEAD_HANDLED=0` to the `fi` closing the disarm), with the disarm
# replaced by a recorder: on every head without a verdict it disarms, a
# failed disarm ends this PR's round before any review, and a verdict (not
# the anchor refusal, which is no verdict) skips it.
BLOCK="$(awk '/^  HEAD_HANDLED=0$/ { p = 1 } p { print } p && /disarm_unreviewed_auto_merge/ { d = 1 } d && /^  fi$/ { exit }' pr-autoreview.sh)"
[ -n "$BLOCK" ] || fail "could not lift the HEAD_HANDLED block out of pr-autoreview.sh"
eval "handled_block() { $BLOCK
echo reached; }"
disarm_unreviewed_auto_merge() { echo "disarm $2"; return "${DISARM_RC:-0}"; }
note_skip() { echo "skip $PR: $1"; }
# shellcheck disable=SC2034  # read by the eval'd block
MARKER=pr-reviewer KEY=K9 INFO='{}' PR=5
HANDLED_BODIES="<!-- pr-reviewer K9 -->"
[ "$(handled_block)" = reached ] || fail "a head with a verdict must not be disarmed"
# shellcheck disable=SC2034  # read by the eval'd block
HANDLED_BODIES="<!-- pr-reviewer K8 -->"
[ "$(handled_block)" = "disarm 5
reached" ] || fail "a head with no verdict (an older head's marker only) must be disarmed"
DISARM_RC=1
[ "$(handled_block)" = "disarm 5
skip 5: auto-merge could not be disarmed — skipping (fail closed)" ] \
  || fail "a failed disarm must be counted as a skip and end this PR's round before the review"
unset DISARM_RC
unset -f note_skip
. lib/merge.sh

# Where it sits: ahead of the first exit past HANDLED_BODIES (the fail-closed
# skips, the anchor refusal), and the already-handled block reads the same
# flag. Nothing skips it: the auto-merge is GitHub's, and this reviewer's
# verdicts do not block it.
CODE="$(grep -nvE '^[[:space:]]*#' pr-autoreview.sh)"
BODIES_AT="$(grep -n '^  HANDLED_BODIES=' pr-autoreview.sh | head -1 | cut -d: -f1)"
FIRST_EXIT="$(awk -F: -v b="$BODIES_AT" '$1 > b && /return 0/ && !/disarm_unreviewed_auto_merge|could not be disarmed/ { print $1; exit }' <<<"$CODE")"
TOP_AT="$(awk -F: -v b="$BODIES_AT" '$1 > b && /disarm_unreviewed_auto_merge/ { print $1; exit }' <<<"$CODE")"
[ -n "$BODIES_AT" ] && [ -n "$FIRST_EXIT" ] && [ -n "$TOP_AT" ] \
  || fail "could not find HANDLED_BODIES, its first exit, or the disarm in pr-autoreview.sh"
[ "$TOP_AT" -lt "$FIRST_EXIT" ] \
  || fail "the disarm must come before the first exit past HANDLED_BODIES ($TOP_AT < $FIRST_EXIT)"
HANDLED_AT="$(grep -n 'already handled this exact head' pr-autoreview.sh | head -1 | cut -d: -f1)"
HANDLED_IF="$(sed -n "$((HANDLED_AT + 1))p" pr-autoreview.sh)"
grep -qF 'if [ "$HEAD_HANDLED" = 1 ]; then' <<<"$HANDLED_IF" \
  || fail "the already-handled block must read HEAD_HANDLED, or the two can disagree on what a verdict is"

# ── merge_base_sha ─────────────────────────────────────────────────────────
# One shared call (two hand-copied
# `gh api ... -q '.merge_base_commit.sha'` calls, no test able to tell them
# apart if one drifted).
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
printf '%s' "${SHA_OUT:-}"
exit "${SHA_RC:-0}"
EOF
chmod +x "$TMP/gh"
GH="$TMP/gh"

: > "$LOG"; export SHA_OUT="abc123def456" SHA_RC=0
OUT="$(merge_base_sha "owner/repo" "main" "deadbeef")"
[ "$OUT" = "abc123def456" ] || fail "merge_base_sha must echo what gh api returns"
grep -qF "api repos/owner/repo/compare/main...deadbeef -q .merge_base_commit.sha" "$LOG" \
  || fail "merge_base_sha must call gh api on the compare endpoint with -q .merge_base_commit.sha"

: > "$LOG"; export SHA_OUT="" SHA_RC=1
OUT="$(merge_base_sha "owner/repo" "main" "deadbeef")"
[ -z "$OUT" ] || fail "a failed gh api call must yield empty output, not stale data"
: > "$LOG"; export SHA_OUT="abc123def456" SHA_RC=0
OUT="$(merge_base_sha "owner/repo" "feat#x%y{branch}" "deadbeef")"
grep -qF "api repos/owner/repo/compare/feat%23x%25y%7Bbranch}...deadbeef " "$LOG" \
  || fail "a #, % or { in the base ref must be percent-encoded, not change the URL"
unset SHA_OUT SHA_RC

echo "PASS: lib/merge.sh (merge_base_allowed x6, merge_size_allowed x11, merge_base_sha x3, disarm_unreviewed_auto_merge x3 + caller block x3 + 1 call site)"
