#!/usr/bin/env bash
# Guards one recurring bug class, not one bug.
#
# Every script here runs `set -uo pipefail`. In `producer | grep -q PATTERN`,
# grep exits the instant it matches; the producer's next write gets SIGPIPE and
# dies with 141; pipefail then makes the WHOLE pipeline non-zero — so an `if`
# reads a match as a miss. The direction is what makes it dangerous: the
# pipeline only fails when grep found something, which for a sensitive-data
# scan means the hit is the case that gets dropped. The trigger is a producer
# whose output exceeds the fixed 64KiB pipe buffer; nothing else is needed, no
# attacker involved.
#
# This has now been found and fixed four separate times in this repo
# (HANDLED_BODIES and PR_FILES in pr-autoreview.sh, a changed-file listing,
# and the PR title/body scan). Reviews keep catching it one site at a time,
# so it becomes a machine check here instead.
#
# Rule: never pipe into `grep -q`. Materialize first, then `grep -q <<<"$var"`.
# The one allowed exception is the fixed 2-byte regex-validity probe
# `printf 'x\n' | grep -q...`, whose producer cannot outrun any pipe buffer.
#
# Run: bash tests/scan-discipline.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Derived, never hand-maintained. A script added later and never added to a
# hand-kept copy of this list would sit outside the rule while the test
# reported a pass. Everything tracked outside
# tests/ is in scope; the test files themselves are excluded because they
# hand-write broken fixtures on purpose.
#
# Through a FILE, not `< <(git ls-files)`: a process substitution's exit status
# is invisible, so a failed listing would read as "no files, nothing wrong".
LISTF="$(mktemp)"; trap 'rm -f "$LISTF"' EXIT
# `prreview` has no .sh suffix, so it is named.
# Test files are exempt in any tests/ directory, for the
# reason above.
git ls-files --cached --others --exclude-standard '*.sh' prreview | grep -vE '(^|/)tests/' > "$LISTF" || { echo "FAIL: git ls-files failed — refusing to report a pass"; exit 1; }
FILES=()
while IFS= read -r f; do [ -e "$f" ] && FILES+=("$f"); done < "$LISTF"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no shell scripts found — this check tested nothing"; exit 1; }

# `-[a-zA-Z]*q[a-zA-Z]*` so both -q and clustered forms (-qiE, -iqE) match.
# grep -c is deliberately NOT flagged: counting consumes all input, so it
# never early-exits and never SIGPIPEs the producer.
HITS="$(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q[a-zA-Z]*' "${FILES[@]}" \
        | grep -v "printf 'x" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"

if [ -n "$HITS" ]; then
  echo "FAIL: pipeline feeding \`grep -q\` — a match can read as a miss under pipefail."
  echo "      Materialize first:  var=\"\$(producer)\"; grep -q PATTERN <<<\"\$var\""
  sed 's/^/  /' <<<"$HITS"
  exit 1
fi

# ── second class: an unescaped backtick in a double-quoted string ───────────
# The review prompts are enormous double-quoted strings full of markdown, and
# markdown wants backticks around identifiers. In a double-quoted shell string
# a backtick is COMMAND SUBSTITUTION: the words between a pair are executed and
# replaced by their (empty) output, so the identifiers silently vanish from the
# prompt the model actually receives.
#
# Found live in a review prompt: the identifiers it exists to make the model
# look for were all being deleted before the prompt was sent. The rest of the
# file escaped them (\`like this\`), so it was a one-character slip that
# produced no error, no log line, and a quietly weaker review.
#
# The linter does NOT reliably catch it: a plain backticked word reads as a
# command call and is only SC2006, a STYLE finding filtered out at the
# -S warning bar this repo lints at. It happened to flag one instance only
# because that one looked like a variable assignment (SC2034, a warning).
# Severity depending on what sits between the backticks is not a check.
#
# Scoped to multi-line DOUBLE-quoted assignments (`VAR="` … closing `"`), which
# is where every prompt and every posted comment body lives. A backtick inside
# a SINGLE-quoted string is literal and perfectly fine — this repo has several
# of those on purpose (owner-alert.sh puts markdown into `printf '…'`), so a
# file-wide grep would be all false positives and would be switched off
# within a week.
#
# The state machine is crude by design: opening line = an assignment whose
# value starts with a double quote and does not close on the same line;
# closing line = the first line afterwards ending in an unescaped `"`. That is
# exactly the shape of the blocks at risk and nothing else in these files.
TICKS="$(awk '
  FNR == 1 { inblock = 0 }
  inblock == 0 && /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="/ {
    rest = $0; sub(/^[^=]*="/, "", rest)
    if (rest !~ /"/) { inblock = 1; next }
  }
  inblock == 1 {
    if ($0 ~ /(^|[^\\])`/) printf "%s:%d:%s\n", FILENAME, FNR, $0
    if ($0 ~ /(^|[^\\])"[[:space:]]*$/) inblock = 0
  }
' "${FILES[@]}")"

if [ -n "$TICKS" ]; then
  echo "FAIL: unescaped backtick in shell source — inside a double-quoted string that is"
  echo "      command substitution, and the text between the ticks disappears."
  echo "      Escape them for markdown:  \\\`identifier\\\`"
  sed 's/^/  /' <<<"$TICKS"
  exit 1
fi

# ── third class: a comment that accidentally becomes a linter directive ────
# A comment line beginning with the linter's own name is parsed as a DIRECTIVE.
# Write prose there and the file stops parsing — the tool reports two errors
# against the file rather than "your comment is the problem", so the message
# points nowhere near the cause.
#
# It is easy to trip even while writing a comment that explains the trap,
# which makes it something to hand to a machine.
#
# Valid directive keys per the tool's documentation; anything else after the
# name is prose and must be reworded (start the line with any other word).
# Every test file; through the list file, like FILES.
git ls-files --cached --others --exclude-standard '*.sh' | grep -E '(^|/)tests/' > "$LISTF" \
  || { echo "FAIL: git ls-files failed — refusing to report a pass"; exit 1; }
TESTS=()
while IFS= read -r f; do [ -e "$f" ] && TESTS+=("$f"); done < "$LISTF"
DIRECTIVES="$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck([[:space:]]|$)' "${FILES[@]}" "${TESTS[@]}" \
              | grep -vE '#[[:space:]]*shellcheck[[:space:]]+(disable|enable|source|source-path|shell|external-sources)=')"

if [ -n "$DIRECTIVES" ]; then
  echo "FAIL: a comment starting with the linter's name is parsed as a directive,"
  echo "      and prose there makes the whole file unparseable. Reword so the line"
  echo "      starts with a different word."
  sed 's/^/  /' <<<"$DIRECTIVES"
  exit 1
fi

# ── fourth class: a wording pass that deletes an instruction ──────────────
# Each is an instruction a wording pass could delete with no other test
# noticing. They are greps because that is all they need
# to be: each pins one string that must not disappear again.
#
# The sensitive-hit notice is the load-bearing one. Without the history
# rewrite instruction a contributor follows it literally, pushes one "delete
# the value" commit, the NET diff goes clean, the gate re-reviews and calls it
# clean, and the real value stays in the branch history where
# refs/pull/N/head keeps it forever.
WORDING_MISSING=""
# Scoped to the notice it belongs to, NOT a whole-file grep. The first version
# of this guard used `grep -qF` over the entire script and five of its six
# checks passed with the notice deleted, because the same words appear in the
# comments explaining the guard. A test that cannot fail is worse than no test:
# it reports the thing it does not check.
want() {  # $1 label, $2 anchor line, $3 required text, $4 window (default 8)
  local blk
  blk="$(grep -A "${4:-8}" -F -- "$2" pr-autoreview.sh lib/findings.sh)"
  if [ -z "$blk" ]; then
    WORDING_MISSING="$WORDING_MISSING
  $1: the notice itself is gone (no line matching \"$2\")"
  elif ! grep -qF -- "$3" <<<"$blk"; then
    WORDING_MISSING="$WORDING_MISSING
  $1: notice found but it no longer says \"$3\""
  fi
}

# The review-body sensitive hit is the load-bearing one. Without the history
# rewrite instruction a contributor follows it literally, pushes one "delete
# the value" commit, the NET diff goes clean, the gate re-reviews and calls it
# clean, and the real value stays in the branch history where
# refs/pull/N/head keeps it forever.
# Anchored on the part that identifies WHICH notice this is, not on the whole
# parenthetical: rewording the bracket is a legitimate change and should not
# trip a guard that exists to catch a deleted instruction.
SENS_REVIEW='This change or its review matched the sensitive-data scan'
want 'review-body sensitive notice keeps the history-rewrite instruction' "$SENS_REVIEW" 'rewrite the branch history'
want 'review-body sensitive notice keeps the placeholder instruction'     "$SENS_REVIEW" 'placeholder'

SENS_TITLE='The title or description matched the sensitive-data scan'
want 'title/body sensitive notice keeps the placeholder instruction' "$SENS_TITLE" 'placeholder'
want 'title/body sensitive notice keeps the history-rewrite instruction' "$SENS_TITLE" 'rewriting its history'

want 'the changes-requested verdict says how to retry' '❌ Changes requested' 'reviewed again' 1
# The prompt has to keep telling the model what the tree actually is. Deleting
# this is invisible in review and produces a model that refutes real findings
# because "line N does not say that" — measured, on the second round's first
# version.
# STACKED_CLAUSE must be set INSIDE a merge_base_allowed test. Unconditional,
# it tells every PR that its parent's code might be missing, which is an
# invitation to explain a real finding away — the opposite of the point.
SC_LINE="$(grep -n 'STACKED_CLAUSE="\$(prompt_stacked_clause' pr-autoreview.sh | cut -d: -f1)"
if [ -z "$SC_LINE" ]; then
  WORDING_MISSING="$WORDING_MISSING
  the stacked-PR clause is gone from pr-autoreview.sh"
else
  sc_start=$(( SC_LINE > 4 ? SC_LINE - 4 : 1 ))
  sc_window="$(sed -n "${sc_start},${SC_LINE}p" pr-autoreview.sh)"
  grep -q 'merge_base_allowed' <<<"$sc_window" || WORDING_MISSING="$WORDING_MISSING
  pr-autoreview.sh:$SC_LINE: the stacked-PR clause is set unconditionally (it must be inside a merge_base_allowed test)"
fi

# What the tree IS stopped being one fixed sentence when the gate started
# applying the PR's diff to its own worktree: there are now two true answers
# and the prompt must carry the one that matches what happened. So the guard
# moved from "the prompt says DEFAULT branch" to "the prompt still carries a
# computed tree clause at all" — deleting the interpolation is the change this
# has to catch, and which of the two sentences is correct is pinned in
# tests/prompt.test.sh (both halves) and tests/findings.test.sh (the verify
# prompt's two halves).
want 'the review prompt still tells the model what tree it is standing in' \
     'The diff you are reviewing is in $SLICE_DIFF' '$TREE_CLAUSE' 2
# Slicing must not let a pass read the WHOLE diff: a slice that can open the
# full diff reads the full diff, and the split has bought nothing but calls.
REVIEW_ALLOWED="$(grep -F 'ALLOWED=("Read(/$REPO_DIR/**)"' pr-autoreview.sh)"
if [ -z "$REVIEW_ALLOWED" ]; then
  WORDING_MISSING="$WORDING_MISSING
  the review call's tool allowlist is gone from pr-autoreview.sh"
elif ! grep -qF -- 'Read(/$SLICE_DIFF)' <<<"$REVIEW_ALLOWED"; then
  WORDING_MISSING="$WORDING_MISSING
  the review call grants Read on something other than its own slice diff, so a slice can read the whole PR and the split buys nothing"
fi
want 'the verify prompt still branches on whether the diff was applied' \
     'try to REFUTE it' '$tree_para' 6
# ...and the flag actually reaches it. The verify prompt defaults to the
# conservative half when $8 is absent, which is the safe direction but also a
# silent one: a caller that stops passing the flag would keep telling the
# verifier the tree is pre-change while it is post-change, and every "line N
# says something else" refutation becomes wrong evidence with nothing failing.
# Applying the PR's diff to the review tree opened a way for the change to
# write the files the prompt calls the project's conventions (CLAUDE.md,
# AGENTS.md, .claude/skills/), i.e. to supply its own review rules. Three
# versions of that guard were wrong before this one, and none of them was
# pinned by anything — so pin the guard's existence and its shape: a
# regex over the file names git lists, never a pathspec and never the text of
# the diff, because that is the axis it kept failing on (root-anchored, then
# blind to C-quoted non-ASCII headers).
#
# Lives in lib/tree.sh —
# checked the same way merge_base_allowed is checked below: the SHAPE is
# pinned where the implementation actually lives, and pr-autoreview.sh is
# separately checked for actually CALLING the shared function rather than
# just having it exist unused.
CONV_GUARD="$(grep -n 'tree_revert_convention_files()' lib/tree.sh)"
if [ -z "$CONV_GUARD" ]; then
  WORDING_MISSING="$WORDING_MISSING
  the convention-file guard is gone: a PR could add CLAUDE.md or .claude/skills/ and hand the reviewer its own rules"
else
  conv_ln="$(cut -d: -f1 <<<"$CONV_GUARD" | head -1)"
  conv_win="$(sed -n "${conv_ln},$((conv_ln + 24))p" lib/tree.sh)"
  grep -qF -- 'ls-files --others' <<<"$conv_win" || WORDING_MISSING="$WORDING_MISSING
  the convention-file guard no longer removes the untracked copies the patch created"
  grep -qF -- 'checkout --' <<<"$conv_win" || WORDING_MISSING="$WORDING_MISSING
  the convention-file guard no longer restores a TRACKED convention file the patch modified"
  # The subdirectory case is the one three versions of this guard missed, and
  # it is missed by writing a GIT PATHSPEC instead of matching the path: a
  # pathspec wildcard only tail-matches, so '*/.claude' finds nothing at all.
  # The set is a regex over the path, and it must match .claude/ at any depth.
  grep -qF -- '(^|/)\.claude/' lib/tree.sh || WORDING_MISSING="$WORDING_MISSING
  the convention set no longer matches .claude/ below the repo root (a git pathspec cannot)"
fi

# The gate's OWN call site must cross-reference $PR_FILES before trusting a
# "hit": tree_revert_convention_files cannot tell "the diff
# added this" apart from "an untracked CLAUDE.md or .claude/skills/ file was
# already in the checkout". With such a file in the checkout EVERY PR
# hits, whether or not it touched a convention path, and
# the reviewer prompt then contradicts itself (REPO_CONTEXT says hold the
# diff to CLAUDE.md; TREE_CONV_NOTE says that same file was not really
# written by the diff).
GATE_CONV_CALL="$(grep -n 'tree_revert_convention_files "\$REPO_DIR"' pr-autoreview.sh | tail -1)"
if [ -z "$GATE_CONV_CALL" ]; then
  WORDING_MISSING="$WORDING_MISSING
  pr-autoreview.sh no longer calls tree_revert_convention_files with an argument at its TREE_CONV_NOTE call site"
else
  gcc_ln="$(cut -d: -f1 <<<"$GATE_CONV_CALL")"
  # Sixteen lines: the call is followed by its could-not-tell branch and the
  # copy from the default branch before the cross-check.
  gcc_win="$(sed -n "${gcc_ln},$((gcc_ln + 16))p" pr-autoreview.sh)"
  grep -qF 'PR_FILES' <<<"$gcc_win" || WORDING_MISSING="$WORDING_MISSING"$'\n'"  pr-autoreview.sh's TREE_CONV_NOTE call site no longer cross-references \$PR_FILES — an untracked convention file would show TREE_CONV_NOTE on every PR again"
fi
# Anchored on the CALL SHAPE, not on the name appearing anywhere in the
# file (caught by mutation): `grep -qF 'tree_revert_
# convention_files' pr-autoreview.sh` (the previous version of this check)
# is satisfied by the comment ABOVE tree_revert_convention_files's real call
# site, which names the function while explaining where it moved to.
# Deleting the real call and leaving that comment in place left this
# PASSING. The pattern requires the name followed by a quoted argument,
# which only a real call has; a comment mentioning the name in prose does
# not. (Line numbers are deliberately not cited here — they drift with
# every edit; grep for the function name instead.)
#
# EVERY occurrence is checked individually, not just whether ANY line in
# the file matches (caught by mutation): a single
# `grep -qE ... "$tree_caller"` over the whole file passes the moment ONE
# call site has an argument, even while a SECOND call site in the same
# file has none — the actual regression this guard exists for (a second
# tree_has_symlinks call site in pr-autoreview.sh calling it bare, which
# crashes every review round on `${1:?...}`) sat right next to a correct
# call and was invisible to a file-wide `-q` check for exactly that reason.
# Derived from the ALREADY-derived $FILES list, not hand-maintained a second
# time: a hand-written list of today's callers here means the
# next script that starts sourcing lib/tree.sh and forgets to call
# its guards gets no check at all, the exact shape this file's header
# describes. Any file in $FILES that sources lib/tree.sh is
# in scope.
# Anchored on the SOURCE-LINE shape, not "mentions lib/tree.sh anywhere":
# a bare substring match would collect a script
# whose only reference is a cross-reference COMMENT ("see lib/tree.sh") into
# TREE_CALLERS, then demand it call guards it never needed — turning a
# harmless comment into a false-positive red across the whole suite. Matches
# both quoting styles: `. "$SCRIPT_DIR/lib/tree.sh"` (pr-autoreview.sh) and
# `. ./lib/tree.sh`.
TREE_CALLERS=()
for f in "${FILES[@]}"; do
  grep -qE '^[[:space:]]*\.[[:space:]].*lib/tree\.sh' "$f" && TREE_CALLERS+=("$f")
done
[ "${#TREE_CALLERS[@]}" -gt 0 ] || WORDING_MISSING="$WORDING_MISSING
  no tracked script sources lib/tree.sh — the symlink/convention-file guards exist but nothing loads them"

for tree_fn in tree_has_symlinks tree_revert_convention_files; do
  for tree_caller in "${TREE_CALLERS[@]}"; do
    # Numbered BEFORE the comment lines are dropped, so the line numbers in
    # a failure message point at the real file, not a post-filter count.
    CALL_LINES="$(grep -nE "(^|[^#[:alnum:]_])${tree_fn}([^[:alnum:]_]|\$)" "$tree_caller" \
      | grep -vE '^[0-9]+:[[:space:]]*#')"
    if [ -z "$CALL_LINES" ]; then
      WORDING_MISSING="$WORDING_MISSING
  $tree_caller no longer calls $tree_fn — the shared guard exists but nothing real invokes it"
      continue
    fi
    while IFS= read -r hit; do
      lineno="${hit%%:*}"
      text="${hit#*:}"
      grep -qE "^[[:space:]]*(if[[:space:]]+)?!?[[:space:]]*${tree_fn}[[:space:]]+\"" <<<"$text" \
        || WORDING_MISSING="$WORDING_MISSING
  $tree_caller:$lineno calls $tree_fn without an argument — the shared guard exists but this call site would crash on \${1:?...}"
    done <<<"$CALL_LINES"
  done
done

VERIFY_CALL="$(grep -F 'findings_verify_prompt "$REPO"' pr-autoreview.sh)"
if [ -z "$VERIFY_CALL" ]; then
  WORDING_MISSING="$WORDING_MISSING
  the second-round verify call is gone from pr-autoreview.sh"
elif ! grep -qF -- '"$TREE_CLAUSE$STACKED_CLAUSE"' <<<"$VERIFY_CALL"; then
  WORDING_MISSING="$WORDING_MISSING
  the verify call no longer passes the review's tree text (\$TREE_CLAUSE\$STACKED_CLAUSE), so the verifier can be told a tree that is not there"
fi

TITLE_REMINDER='ℹ️ Title format reminder'
want 'the title reminder still lists the valid types'  "$TITLE_REMINDER" \
     '${TITLE_TYPES}'

# Posted text has no doubled em dash. The check skips comment lines: a person
# reads a comment in the source, not on GitHub, and a check that fails on a
# comment gets worked around. DD is the doubled U+2014 as UTF-8 bytes.
DD=$'\xe2\x80\x94\xe2\x80\x94'
EMDASH_HITS="$(grep -lF -- "$DD" "${FILES[@]}" 2>/dev/null | while IFS= read -r f; do
  grep -vE '^[[:space:]]*#' "$f" | grep -qF -- "$DD" && printf '%s\n' "$f"
done)"
if [ -n "$EMDASH_HITS" ]; then
  WORDING_MISSING="$WORDING_MISSING
  posted text has a doubled em dash in: $(tr '\n' ' ' <<<"$EMDASH_HITS")"
fi

if [ -n "$WORDING_MISSING" ]; then
  echo "FAIL: a posted body lost text that carries an instruction (or a coupling):"
  printf '%s\n' "$WORDING_MISSING"
  exit 1
fi

# ── the stacked clause must agree with TREE_CLAUSE ────────────────────────
# Both sentences describe the same tree to the same model in the same prompt.
# TREE_CLAUSE reads prompt_tree_clause "$DIFF_APPLIED" and is honest when the
# apply failed; STACKED_CLAUSE said "the tree IS the parent with this PR's diff
# applied" unconditionally, so on a stacked PR whose apply failed the prompt
# carried two contradictory descriptions and neither was true. The apply is
# something the author can fail on purpose — the diff API gives a contentless
# stub for a binary file.
# The wordings live in lib/prompt.sh's prompt_stacked_clause; what
# pr-autoreview.sh has to do is pass it the state. Both halves are pinned.
sc_fn="$(sed -n '/^prompt_stacked_clause()/,/^}/p' lib/prompt.sh)"
SC_ARMS="$(grep -c 'printf ' <<<"$sc_fn")"
[ "$SC_ARMS" -ge 3 ] || {
  echo "FAIL: prompt_stacked_clause has $SC_ARMS wording(s), expected 3 — tree on the base with the diff applied, tree on the base without it, and the tree that never reached the base"
  exit 1; }
grep -qF 'STACKED_CLAUSE="$(prompt_stacked_clause "$DEFAULT_BRANCH" "$TREE_AT" "$DIFF_APPLIED")"' pr-autoreview.sh || {
  echo "FAIL: pr-autoreview.sh no longer passes TREE_AT and DIFF_APPLIED to prompt_stacked_clause — it will tell the model the diff is in a tree the apply never reached"
  exit 1; }

# ── no base may supply the conventions ───────────────────────────────────
# The tree follows the PR's own base, and a base off the default branch is an
# UNPROTECTED ref. The revert cannot help there: it walks what the PATCH
# created and what the PATCH modified, and a CLAUDE.md the PARENT branch
# committed is in neither. So anyone able to push a feature branch could
# commit their own rules to it, open a PR based on it, and have the gate read
# those rules as the project's. Every PR takes the convention files from the
# default branch (tree_force_convention_files), after the diff is applied.
#
# Pinned: pr-autoreview.sh makes the call with origin/$DEFAULT_BRANCH on both
# paths (diff applied, diff not applied), and the function keeps the three
# steps that went wrong before: the ref is checked first, the index is cleared
# with the disk, and the file comes from the ref.
n_force="$(grep -c 'tree_force_convention_files "\$REPO_DIR" "origin/\$DEFAULT_BRANCH"' pr-autoreview.sh)"
[ "$n_force" = 2 ] || {
  echo "FAIL: pr-autoreview.sh calls tree_force_convention_files $n_force time(s), expected 2 (diff applied, and diff not applied on a base tree) — a base branch can supply the review rules"; exit 1; }
force_fn="$(sed -n '/^tree_force_convention_files()/,/^}/p' lib/tree.sh)"
grep -qF -- 'checkout "$ref" --' <<<"$force_fn" || {
  echo "FAIL: the convention guard no longer takes the files from the default branch"; exit 1; }
grep -qF -- 'rm -q --cached' <<<"$force_fn" || {
  echo "FAIL: the convention guard deletes the file but leaves the parent's blob in the index — a later checkout writes it straight back out"; exit 1; }
grep -qF -- 'rev-parse --verify' <<<"$force_fn" || {
  echo "FAIL: the convention guard no longer checks that the default branch resolves — every path would take the rm arm and the tree would end up with no conventions at all"; exit 1; }

# ── the review tree is NOT gated on merge_base_allowed ────────────────────
# It needs its own check because the tree choice and this base check
# used to be one `if`. `merge_base_allowed` answers "does this PR land on the
# default branch?". It does NOT answer "which tree should the model read?", and
# while it did, a stacked PR was reviewed against the default branch with its
# diff never applied: the model read a tree missing everything the parent
# branches added, called that code missing, and the only way to get a usable
# verdict was to merge the stack one PR at a time.
#
# Structural, because the alternative is mocking gh and re-running the
# round. Comment lines are stripped from the window first — the code above
# the call explains the split and names merge_base_allowed while doing so.
#
# Anchored on `merge_base_sha "`, the helper, NOT on the compare URL it wraps.
# The URL moved into lib/merge.sh and this check went looking for a string
# pr-autoreview.sh no longer contains: the loop body stopped running, and
# re-introducing the exact coupling it exists to forbid produced no failure at
# all (confidence 0.9 — measured, the mutation was silent).
# Whatever this is anchored on has to be a call site in THIS file.
TREE_GATED=""
while IFS=: read -r ln _; do
  [ -n "$ln" ] || continue
  start=$(( ln > 12 ? ln - 12 : 1 ))
  win="$(sed -n "${start},${ln}p" pr-autoreview.sh | grep -vE '^[[:space:]]*#')"
  if grep -q 'merge_base_allowed' <<<"$win"; then
    TREE_GATED="$TREE_GATED
  pr-autoreview.sh:$ln: the review tree is gated on merge_base_allowed again — a stacked PR will be reviewed against a tree that has neither its parent's changes nor its own diff"
  fi
done <<EOF
$(grep -n 'merge_base_sha "' pr-autoreview.sh | grep -vE '^[0-9]+:[[:space:]]*#')
EOF
if [ -n "$TREE_GATED" ]; then
  echo "FAIL: the tree decision and the approve decision are coupled again."
  printf '%s\n' "$TREE_GATED"
  exit 1
fi

# ── fifth class: the linked issue text is scanned before the model can read it ──
# The README promises that a pattern match in the title or body of the issue
# the PR links stops the review. The issue text goes into the intent file that
# the model Reads, so the scan must run before that write. The real block
# runs here, lifted out of the script. Stubs stand in for gh, the post and
# the nonce.
LI_TMP="$(mktemp -d)" || { echo "FAIL: mktemp failed"; exit 1; }
trap 'rm -rf "$LISTF" "$LI_TMP"' EXIT
LI_BLOCK="$(awk '/^  ISSUE_N=""$/ { p = 1 } /^  # Dimension 11 skips itself/ { p = 0 } p { print }' pr-autoreview.sh)"
if [ "$(grep -c '' <<<"$LI_BLOCK")" -lt 15 ]; then
  echo "FAIL: could not lift the linked-issue block out of pr-autoreview.sh"; exit 1
fi
. lib/prompt.sh || { echo "FAIL: could not source lib/prompt.sh"; exit 1; }
. lib/scan.sh || { echo "FAIL: could not source lib/scan.sh"; exit 1; }
eval "li_block() { $LI_BLOCK
echo reached; }"
cat > "$LI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") [ -n "${LI_REFS-}" ] || exit 1; printf '%s' "$LI_REFS" ;;
  "issue view") printf 'TITLE: t\n\nBODY:\n%s\n' "${LI_ISSUE_BODY-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$LI_TMP/gh"
printf '%s\n' 'sk-secret[0-9]+' > "$LI_TMP/pats"
gh_post() { printf '%s\n' "$*" >> "$LI_TMP/posted"; }
findings_fence_nonce() { echo NONCE; }
# shellcheck disable=SC2034  # read by the lifted block
GH="$LI_TMP/gh" REPO=o/r PR=5 MARKER=m KEY=k DIFF="$LI_TMP/diff"
# shellcheck disable=SC2034  # the variables are read by the lifted block
li_run() {  # $1 refs json ("" = gh cannot report), $2 issue body, $3 patterns file, $4 PR description
  : > "$LI_TMP/posted"; : > "$LI_TMP/intent"
  INTENT_FILE="$LI_TMP/intent"; PATS_FILE="$3"
  INFO="$(jq -cn --arg b "$4" '{title:"t",body:$b}')"
  LI_REFS="$1" LI_ISSUE_BODY="$2" li_block 2>&1
}
li_expect() {  # $1 label, $2 output, $3 want "withheld" or "reviewed"
  local posted intent; posted="$(cat "$LI_TMP/posted")"; intent="$(cat "$LI_TMP/intent")"
  if [ "$3" = withheld ]; then
    case "$2" in *reached*) echo "FAIL: $1 - the round went on to the model"; exit 1 ;; esac
    grep -qF 'Review withheld' <<<"$posted" || { echo "FAIL: $1 - no withheld notice posted"; exit 1; }
    grep -qF 'linked issue' <<<"$posted" || { echo "FAIL: $1 - the notice does not say the linked issue matched"; exit 1; }
    ! grep -qF 'sk-secret' <<<"$posted" || { echo "FAIL: $1 - the notice quotes the value"; exit 1; }
    ! grep -qF 'sk-secret' <<<"$intent" || { echo "FAIL: $1 - the value reached the intent file"; exit 1; }
  else
    case "$2" in *reached*) ;; *) echo "FAIL: $1 - a clean issue stopped the round: $2"; exit 1 ;; esac
    [ -z "$posted" ] || { echo "FAIL: $1 - a notice was posted for a clean issue"; exit 1; }
    grep -qF 'LINKED ISSUE #' <<<"$intent" || { echo "FAIL: $1 - the clean issue text did not reach the intent file"; exit 1; }
  fi
}
REFS7='{"closingIssuesReferences":[{"number":7,"url":"https://github.com/o/r/issues/7"}]}'
li_expect 'issue body matches' "$(li_run "$REFS7" 'key sk-secret123 here' "$LI_TMP/pats" 'plain')" withheld
li_expect 'issue body is clean' "$(li_run "$REFS7" 'add a retry' "$LI_TMP/pats" 'plain')" reviewed
li_expect 'scan cannot run (no patterns file)' "$(li_run "$REFS7" 'add a retry' "$LI_TMP/none" 'plain')" withheld
li_expect 'fallback path, issue body matches' "$(li_run '' 'key sk-secret123 here' "$LI_TMP/pats" 'Fixes #9')" withheld
li_expect 'fallback path, issue body is clean' "$(li_run '' 'add a retry' "$LI_TMP/pats" 'Fixes #9')" reviewed
# No model call may sit between the PR title scan and this block.
LI_LN="$(grep -n '^  ISSUE_N=""$' pr-autoreview.sh | head -1 | cut -d: -f1)"
LI_PRE="$(sed -n "1,${LI_LN}p" pr-autoreview.sh | grep -vE '^[[:space:]]*#' | sed -n '/^  TITLE_BODY=/,$p')"
if grep -qE 'claude_call|"\$CLAUDE_BIN"' <<<"$LI_PRE"; then
  echo "FAIL: a model call sits between the title/description scan and the linked-issue scan"; exit 1
fi
SENS_ISSUE='The linked issue matched the sensitive-data scan'
want 'linked-issue sensitive notice keeps the placeholder instruction' "$SENS_ISSUE" 'placeholder'
want 'linked-issue sensitive notice keeps the edit-history instruction' "$SENS_ISSUE" 'edit history'
if [ -n "$WORDING_MISSING" ]; then
  echo "FAIL: linked-issue notice wording:"; printf '%s\n' "$WORDING_MISSING"; exit 1
fi

echo "PASS: no scan pipes into grep -q, no unescaped backticks, no prose directives, no gutted notices (${#FILES[@]} files + tests/)"
