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

# Both ends are commit IDs from ONE `gh pr view` read: the base commit and
# the head commit. A branch name can move between that read and this call.
BOID=6666666666666666666666666666666666666666
HOID=7777777777777777777777777777777777777777
: > "$LOG"; export SHA_OUT="abc123def456" SHA_RC=0
OUT="$(merge_base_sha "owner/repo" "$BOID" "$HOID")"
[ "$OUT" = "abc123def456" ] || fail "merge_base_sha must echo what gh api returns"
grep -qF "api repos/owner/repo/compare/$BOID...$HOID -q .merge_base_commit.sha" "$LOG" \
  || fail "merge_base_sha must call gh api on the compare endpoint with -q .merge_base_commit.sha"

: > "$LOG"; export SHA_OUT="" SHA_RC=1
OUT="$(merge_base_sha "owner/repo" "$BOID" "$HOID")"
[ -z "$OUT" ] || fail "a failed gh api call must yield empty output, not stale data"
# A branch name, a short SHA or any other revision is refused before gh runs.
: > "$LOG"; export SHA_OUT="abc123def456" SHA_RC=0
for bad in '' main feat/parent 'feat#x%y{branch}' deadbeef "${BOID%?}" "${BOID}6" HEAD~1 \
           AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA; do
  OUT="$(merge_base_sha "owner/repo" "$bad" "$HOID")"
  [ -z "$OUT" ] || fail "base '$bad' is not a full commit SHA: merge_base_sha must print nothing"
  OUT="$(merge_base_sha "owner/repo" "$BOID" "$bad")"
  [ -z "$OUT" ] || fail "head '$bad' is not a full commit SHA: merge_base_sha must print nothing"
done
[ -s "$LOG" ] && fail "a base or head that is not a full commit SHA must never reach gh"
unset SHA_OUT SHA_RC

# ── pr_diff_pinned ─────────────────────────────────────────────────────────
# The diff, the file list and the marker SHA must describe ONE commit. The
# stub answers a compare URL with the diff of the head SHA named in it, so a
# fetch that ignores $SHA (or reads the PR's moving head instead) gets the
# wrong diff and the assertion below says so.
SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
MB=3333333333333333333333333333333333333333
FX="$TMP/fx"; mkdir -p "$FX"
cat > "$TMP/gh" <<'EOF3'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
[ "${GH_RC:-0}" = 0 ] || exit "$GH_RC"
[ "$1" = api ] || exit 99
case "$*" in
  *"Accept: application/vnd.github.diff"*) ;;
  *"-q .merge_base_commit.sha"*) printf '%s\n' "${MB_ANSWER-}"; exit 0 ;;
  *) echo '{"merge_base_commit":{}}'; exit 0 ;;
esac
cat "$GH_FIXTURES/diff-${2##*...}" 2>/dev/null || exit 1
EOF3
chmod +x "$TMP/gh"
GH="$TMP/gh"; export GH_FIXTURES="$FX"
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n a\n+from A\ndiff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1,2 @@\n b\n+from A\n' > "$FX/diff-$SHA_A"
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n a\n+from B\ndiff --git a/b.txt b/b.txt\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1,2 @@\n b\n+from B\ndiff --git a/c.txt b/c.txt\n--- a/c.txt\n+++ b/c.txt\n@@ -1 +1,2 @@\n c\n+from B\n' > "$FX/diff-$SHA_B"
OUTF="$TMP/pinned.diff"

: > "$LOG"; rm -f "$OUTF"
FILES="$(pr_diff_pinned example/repo "$MB" "$SHA_A" "$OUTF" 2)" || fail "pr_diff_pinned must succeed when the diff has the changed-file count gh reported"
cmp -s "$OUTF" "$FX/diff-$SHA_A" || fail "the diff written must be the one for the head SHA asked for (A)"
[ "$FILES" = "$(printf 'a.txt\nb.txt')" ] || fail "the file list must come from the same diff (got: $FILES)"
grep -qF "api repos/example/repo/compare/$MB...$SHA_A -H Accept: application/vnd.github.diff" "$LOG" \
  || fail "the diff must be fetched from the compare API, pinned to merge base and head SHA, as a diff"
grep -qF "$SHA_B" "$LOG" && fail "the fetch must never name another head"
[ "$(grep -c '' "$LOG")" = 1 ] || fail "the diff is fetched once, not once for the diff and again for the file list"

: > "$LOG"; rm -f "$OUTF"
FILES="$(pr_diff_pinned example/repo "$MB" "$SHA_B" "$OUTF" 3)" || fail "pr_diff_pinned must succeed for head B"
cmp -s "$OUTF" "$FX/diff-$SHA_B" || fail "head B asked for, so the diff written must be B's, not A's"
[ "$FILES" = "$(printf 'a.txt\nb.txt\nc.txt')" ] || fail "the file list must follow the head asked for (got: $FILES)"

# A diff with fewer files than gh reported was cut short (a limit on the
# compare side). Reviewing it would approve what was never read.
: > "$LOG"
FILES="$(pr_diff_pinned example/repo "$MB" "$SHA_A" "$OUTF" 3)"; RC=$?
[ "$RC" = 4 ] || fail "one file fewer than changedFiles must fail closed with 4 (rc=$RC)"
[ -z "$FILES" ] || fail "a failed check must print no file list"
pr_diff_pinned example/repo "$MB" "$SHA_B" "$OUTF" 2 >/dev/null; RC=$?
[ "$RC" = 4 ] || fail "one file more than changedFiles must fail closed too (rc=$RC)"
for bad in '' abc -1 '2 ' '2x'; do
  pr_diff_pinned example/repo "$MB" "$SHA_A" "$OUTF" "$bad" >/dev/null; RC=$?
  [ "$RC" = 4 ] || fail "an unreadable changedFiles ('$bad') must fail closed with 4 (rc=$RC)"
done

# Both ends must be a full lowercase SHA, and gh must not be called otherwise.
: > "$LOG"
for bad in '' main abc123 "${SHA_A%?}" "${SHA_A}1" 111111111111111111111111111111111111111G \
           AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "$SHA_A"$'\n' "${SHA_A%??}"$'\n'1 HEAD~1 'a...b'; do
  pr_diff_pinned example/repo "$MB" "$bad" "$OUTF" 2 >/dev/null; RC=$?
  [ "$RC" = 1 ] || fail "head '$bad' is not a full lowercase SHA: must fail closed with 1 (rc=$RC)"
  pr_diff_pinned example/repo "$bad" "$SHA_A" "$OUTF" 2 >/dev/null; RC=$?
  [ "$RC" = 1 ] || fail "merge base '$bad' is not a full lowercase SHA: must fail closed with 1 (rc=$RC)"
done
[ -s "$LOG" ] && fail "a bad SHA must be refused before gh is called"

GH_RC=1 pr_diff_pinned example/repo "$MB" "$SHA_A" "$OUTF" 2 >/dev/null; RC=$?
[ "$RC" = 2 ] || fail "a failed API call (406, rate limit, network) must fail closed with 2 (rc=$RC)"
SHA_C=4444444444444444444444444444444444444444
pr_diff_pinned example/repo "$MB" "$SHA_C" "$OUTF" 2 >/dev/null; RC=$?
[ "$RC" = 2 ] || fail "an API call that returns an error status must fail closed with 2 (rc=$RC)"
# Not a diff at all (a JSON body, an HTML error page, an empty answer).
printf '{"message":"Not Found"}\n' > "$FX/diff-$SHA_C"
pr_diff_pinned example/repo "$MB" "$SHA_C" "$OUTF" 1 >/dev/null; RC=$?
[ "$RC" = 3 ] || fail "an answer that is not a diff must fail closed with 3 (rc=$RC)"
: > "$FX/diff-$SHA_C"
pr_diff_pinned example/repo "$MB" "$SHA_C" "$OUTF" 1 >/dev/null; RC=$?
[ "$RC" = 3 ] || fail "an empty answer for a PR that changes one file must fail closed with 3 (rc=$RC)"
# A PR that changes no files: GitHub reports changedFiles=0 and the compare
# API returns an empty body. That is an empty file list, not an unreadable
# diff. Only an empty body matches 0.
SHA_Z=5555555555555555555555555555555555555555
: > "$FX/diff-$SHA_Z"
FILES="$(pr_diff_pinned example/repo "$MB" "$SHA_Z" "$OUTF" 0)"; RC=$?
[ "$RC" = 0 ] || fail "changedFiles=0 with an empty answer must succeed (rc=$RC)"
[ -z "$FILES" ] || fail "changedFiles=0 must print no file list (got: $FILES)"
pr_diff_pinned example/repo "$MB" "$SHA_A" "$OUTF" 0 >/dev/null; RC=$?
[ "$RC" = 4 ] || fail "changedFiles=0 with a diff that holds files must fail closed with 4 (rc=$RC)"
printf '{"message":"Not Found"}\n' > "$FX/diff-$SHA_C"
pr_diff_pinned example/repo "$MB" "$SHA_C" "$OUTF" 0 >/dev/null; RC=$?
[ "$RC" = 3 ] || fail "changedFiles=0 with an answer that is not a diff must fail closed with 3 (rc=$RC)"
# Cut off inside a hunk: git refuses a patch whose hunk is shorter than it says.
head -n 8 "$FX/diff-$SHA_B" > "$FX/diff-$SHA_C"
pr_diff_pinned example/repo "$MB" "$SHA_C" "$OUTF" 2 >/dev/null; RC=$?
[ "$RC" = 3 ] || fail "a diff cut off inside a hunk must fail closed with 3 (rc=$RC)"

# ── diff_changed_files ─────────────────────────────────────────────────────
# One entry per file, the NEW name for a rename, whatever the file is: a path
# with a space, a non-ASCII path (git quotes those in the diff header), a
# binary stub, a deletion, a mode-only change, an empty new file.
FR="$TMP/fr"; mkdir -p "$FR"; git -C "$FR" init -q
printf 'a\n' > "$FR/t.txt"; printf 'x\n' > "$FR/sp ace.txt"; printf 'e\n' > "$FR/é.txt"
printf '1\n2\n3\n4\n5\n' > "$FR/old.txt"; printf 'm\n' > "$FR/mode.sh"; printf 'gone\n' > "$FR/del.txt"; printf '\000\001' > "$FR/old.bin"
git -C "$FR" add -A; git -C "$FR" -c user.email=t@example.com -c user.name=t commit -qm base
printf 'a\nb\n' > "$FR/t.txt"; printf 'y\n' > "$FR/sp ace.txt"; git -C "$FR" rm -q 'é.txt'; printf 'u\n' > "$FR/ü.txt"
git -C "$FR" mv old.txt new.txt; chmod +x "$FR/mode.sh"; git -C "$FR" rm -q del.txt; : > "$FR/empty.txt"
printf '\000\002' > "$FR/old.bin"; printf '\000\003' > "$FR/new.bin"; mkdir -p "$FR/d ir"; printf 'q\n' > "$FR/d ir/f g.txt"
git -C "$FR" add -A; git -C "$FR" diff --cached -M > "$TMP/mixed.diff"
grep -q '^rename from old.txt' "$TMP/mixed.diff" || fail "the fixture must contain a rename"
grep -q '^Binary files' "$TMP/mixed.diff" || fail "the fixture must contain a binary stub"
GOT="$(diff_changed_files "$TMP/mixed.diff")" || fail "diff_changed_files refused a valid mixed diff"
WANT="$(printf '%s\n' 'd ir/f g.txt' del.txt empty.txt mode.sh new.bin new.txt old.bin 'sp ace.txt' t.txt 'é.txt' 'ü.txt')"
[ "$GOT" = "$WANT" ] || fail "the file list of a mixed diff is wrong. want: $(tr '\n' '|' <<<"$WANT") got: $(tr '\n' '|' <<<"$GOT")"
[ "$(grep -c '' <<<"$GOT")" = "$(git -C "$FR" diff --cached -M --name-only | grep -c '')" ] \
  || fail "the count must be the number of files git itself lists"
diff_changed_files "$TMP/does-not-exist" >/dev/null && fail "an unreadable diff file must fail"

# ── the round's half ───────────────────────────────────────────────────────
# The block lifted out of pr-autoreview.sh (from the merge base lookup to the
# `esac` that maps pr_diff_pinned's answer), run with a recorder for
# note_skip. A refusal must end this PR's round with a fail-closed note before
# anything else reads the diff, and nothing in the block may post.
BLOCK="$(awk '/^  MERGE_BASE="\$\(merge_base_sha / { p = 1 } p { print } p && /^  esac$/ { exit }' pr-autoreview.sh)"
[ -n "$BLOCK" ] || fail "could not lift the pinned-diff block out of pr-autoreview.sh"
eval "pinned_block() { $BLOCK
echo reached; }"
note_skip() { echo "skip $PR: $1"; }
gh_post() { echo POSTED; }
merge_base_sha() { printf '%s' "${MB_OUT-}"; }
# shellcheck disable=SC2034  # read by the eval'd block
REPO=example/repo PR=5 PR_BASE=main PR_BASE_OID="$BOID"
run_block() { # $1 = head SHA, $2 = changedFiles in INFO (or "none")
  # shellcheck disable=SC2034  # SHA and INFO are read by the eval'd block
  SHA="$1"; DIFF="$TMP/round.diff"; : > "$DIFF"; PR_FILES=""
  # shellcheck disable=SC2034
  if [ "$2" = none ]; then INFO='{"headRefOid":"x"}'; else INFO="{\"headRefOid\":\"x\",\"changedFiles\":$2}"; fi
  : > "$LOG"; pinned_block > "$TMP/block.out" 2>&1
  BOUT="$(cat "$TMP/block.out")"
}
MB_OUT="$MB"
run_block "$SHA_A" 2
[ "$BOUT" = reached ] || fail "a diff with the reported file count must pass the block (got: $BOUT)"
cmp -s "$DIFF" "$FX/diff-$SHA_A" || fail "the round must write the diff of \$SHA (A), not another head's"
[ "$PR_FILES" = "$(printf 'a.txt\nb.txt')" ] || fail "PR_FILES must come from the same diff (got: $PR_FILES)"
run_block "$SHA_B" 3
cmp -s "$DIFF" "$FX/diff-$SHA_B" || fail "with \$SHA = B the round must write B's diff"
grep -qF "compare/$MB...$SHA_B " "$LOG" || fail "the round must ask for the diff between the merge base and \$SHA"
run_block "$SHA_A" 3
case "$BOUT" in *"skip 5:"*"(fail closed)"*) ;; *) fail "a diff one file short must skip with a fail-closed note (got: $BOUT)" ;; esac
case "$BOUT" in *reached*|*POSTED*) fail "a diff one file short must end the round without posting (got: $BOUT)" ;; esac
[ ! -e "$DIFF" ] || fail "a refused diff must not be left on disk for the next step"
run_block "$SHA_A" none
case "$BOUT" in *"skip 5:"*) ;; *) fail "a missing changedFiles must skip (got: $BOUT)" ;; esac
MB_OUT=""; run_block "$SHA_A" 2
case "$BOUT" in *"skip 5:"*"(fail closed)"*) ;; *) fail "an unresolved merge base must skip with a fail-closed note (got: $BOUT)" ;; esac
case "$BOUT" in *reached*) fail "an unresolved merge base must end the round" ;; esac
[ -s "$LOG" ] && fail "an unresolved merge base must be refused before the diff is fetched"
MB_OUT="$MB"; GH_RC=1 run_block "$SHA_A" 2
case "$BOUT" in *"skip 5:"*"could not fetch the diff"*"(fail closed)"*) ;; *) fail "a failed fetch must skip and say why (got: $BOUT)" ;; esac
# No changed files: skipped like v0.2.0 skipped an empty `gh pr diff`, with a
# note that says why. Nothing after the block may read an empty file list.
unset GH_RC; run_block "$SHA_Z" 0
case "$BOUT" in *"skip 5:"*"changes no files"*"(fail closed)"*) ;; *) fail "a PR with no changed files must skip and say why (got: $BOUT)" ;; esac
case "$BOUT" in *reached*|*POSTED*) fail "a PR with no changed files must end the round without posting (got: $BOUT)" ;; esac
[ ! -e "$DIFF" ] || fail "the empty diff must not be left on disk for the next step"
unset GH_RC MB_OUT

# The merge base comes from the PR's base commit and head commit, never from
# the base branch name. The real merge_base_sha runs here, on a stacked PR,
# and the stub records the URL each call asks for.
. lib/merge.sh || fail "could not source lib/merge.sh again"
export MB_ANSWER="$MB"
# shellcheck disable=SC2034  # read by the eval'd block
PR_BASE=feat/parent PR_BASE_OID="$BOID"
run_block "$SHA_A" 2
[ "$BOUT" = reached ] || fail "a stacked PR with a base commit must pass the block (got: $BOUT)"
grep -qF "api repos/example/repo/compare/$BOID...$SHA_A -q .merge_base_commit.sha" "$LOG" \
  || fail "the merge base must be asked for between the base commit and the head commit (log: $(tr '\n' '|' < "$LOG"))"
grep -qF "feat/parent" "$LOG" && fail "the merge base call must not name the base branch"
grep -qF "api repos/example/repo/compare/$MB...$SHA_A -H Accept: application/vnd.github.diff" "$LOG" \
  || fail "the diff must be fetched from the merge base that call returned"
unset MB_ANSWER

echo "PASS: lib/merge.sh (merge_base_allowed x6, merge_size_allowed x11, merge_base_sha x4, pr_diff_pinned, diff_changed_files + the round block, disarm_unreviewed_auto_merge x3 + caller block x3 + 1 call site)"
