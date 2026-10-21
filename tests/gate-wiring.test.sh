#!/usr/bin/env bash
# Pins the WIRING in pr-autoreview.sh — the lines that
# connect a lib function to the review flow. Each one is a place where a review round found the function
# right and the wiring wrong (or absent), and where undoing the wiring
# turns nothing else red. Text pins, on purpose: the flow is not
# unit-callable. Run: bash tests/gate-wiring.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
pin() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1" "not found in $3: $2"; fi; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2'";; esac; }
before() { # $1 name, $2 first, $3 second, $4 file: first must appear on an earlier line
  local a b; a="$(grep -nF -- "$2" "$4" | head -1 | cut -d: -f1)"; b="$(grep -nF -- "$3" "$4" | head -1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$1"; else bad "$1" "'$2' at ${a:-none}, '$3' at ${b:-none}"; fi
}
# Every helper used below is defined above. A helper that is not defined
# exits 127 to stderr and the file prints PASS regardless — this repo's
# recurring test bug; the guard turns it into a red line.
for h in ok bad pin before is has; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

# The review checklist (checks/): validated once before any PR is touched,
# then rendered per PR against its changed paths, and the prompt's list is
# exactly that render. A gate that skipped the startup check would find a
# broken file only mid-round; one that rendered without PR_FILES would send
# every language pack to every PR.
pin    'the job reads its review key from the shared helper' 'KEY="$(prompt_review_key "$INFO")"' pr-autoreview.sh
pin    'startup refuses a jq that cannot render the comment' '*) echo "this jq ($(jq --version 2>&1)) cannot run the comment renderer — refusing to run"; exit 1 ;;' pr-autoreview.sh
pin    'the dispatcher skips a handled head without a worktree' 'prompt_head_handled "$PRE" "$MARKER" "$PRIOR_AUTHORS"; then' pr-autoreview.sh
DISPATCH="$(awk '/^for PR in /,/^done$/' pr-autoreview.sh)"
if [ "$(grep -n 'prompt_head_handled' <<<"$DISPATCH" | cut -d: -f1)" -lt "$(grep -n 'worktree add' <<<"$DISPATCH" | cut -d: -f1)" ] \
   && grep -qF 'if PRE="$("$GH" pr view "$PR" --repo "$REPO" --json "$PRE_FIELDS" 2>/dev/null)"; then' <<<"$DISPATCH"; then
  ok 'the handled-head check runs before the worktree is created, from one pre-check call'
else
  bad 'the handled-head check runs before the worktree is created, from one pre-check call' "$(grep -n -E 'prompt_head_handled|worktree add|PRE=' <<<"$DISPATCH")"
fi
pin    'binary files are excluded by path so the text changes still apply' 'apply --whitespace=nowarn ${BIN_EXCLUDES[@]+"${BIN_EXCLUDES[@]}"} "$DIFF"' pr-autoreview.sh
pin    'the model is told which binary files are missing from the tree' 'TREE_CLAUSE="$(prompt_tree_clause "$DIFF_APPLIED" "$TREE_AT")$TREE_CONV_NOTE$TREE_BIN_NOTE"' pr-autoreview.sh
pin    '...and so are the red team' '"$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC" "$REPO_DIR" "$TREE_BIN_NOTE")"' pr-autoreview.sh
pin    '...the verifier' '"$V_ISSUE" "$DIFF_APPLIED" "$TREE_BIN_NOTE")"' pr-autoreview.sh
pin    'job log lines carry the repo key, so two repos with one name stay apart' 'sed -u "s|^|[$REPO_KEY#$PR] |"' pr-autoreview.sh
pin    'a broken checks directory stops the gate at startup' 'review_checks_render "$CHECKS_DIR" >/dev/null \' pr-autoreview.sh
pin    'each PR gets the checks that apply to its changed paths' 'REVIEW_CHECKS="$(review_checks_render "$CHECKS_DIR" "$PR_FILES")" \' pr-autoreview.sh
is     'the prompt list is the rendered checklist, nothing else' "$(awk '/^Review dimensions:$/{getline; print; exit}' pr-autoreview.sh)" '$REVIEW_CHECKS'
is     'nothing sits between the checklist and the exclusions' "$(awk '/^Review dimensions:$/{getline; getline; getline; print; exit}' pr-autoreview.sh | cut -c1-13)" 'Do NOT report'

# App identity (lib/app.sh): the token is minted per repo owner, only when
# this repo posts as the App, and a failed mint skips the repo instead of
# posting under the gh login. The cross-round memory counts the gh login's
# own comments as the gate's only where that login is the one posting.
pin    'the App token is minted for this very repo' 'if ! APP_TOKEN="$(app_token_for "$REVIEW_APP_ID" "$REVIEW_APP_KEY" "$REPO")" || [ -z "$APP_TOKEN" ]; then' pr-autoreview.sh
before 'the identity is decided before the token is minted' 'POST_AS_APP="$GATE_APP"' 'if [ "$POST_AS_APP" = 1 ]; then' pr-autoreview.sh
pin    'the gh login counts as the gate only where it posts' '[ "$POST_AS_APP" = 1 ] || PRIOR_AUTHORS="${REVIEW_APP_SLUG:+$REVIEW_APP_SLUG }$OWNER_LOGIN"' pr-autoreview.sh

# Per-file cap: applied to CLEANED itself, and BEFORE the tally —
# capping only the render left findings that blocked with no comment line
# and no verification next round (three rounds running).
pin    'the per-file cap rewrites CLEANED, not just the render' 'CLEANED="$(jq -c --argjson cap "$GATE_FILE_CAP" "$FINDINGS_FILE_CAP_JQ" <<<"$CLEANED")"' pr-autoreview.sh
before 'the per-file cap runs before the blocking tally' 'CLEANED="$(jq -c --argjson cap "$GATE_FILE_CAP" "$FINDINGS_FILE_CAP_JQ" <<<"$CLEANED")"' 'N_BLOCKING="$(jq -r "$FINDINGS_BLOCKING_COUNT_JQ" <<<"$CLEANED")"' pr-autoreview.sh
# Coach/gatekeeper stamp: without it every finding reads as
# coach mode and every HIGH blocks — silently the old rule.
pin    'the coach flag is stamped onto CLEANED' 'CLEANED="$(jq -c --argjson coach "$COACH" "$FINDINGS_STAMP_JQ" <<<"$CLEANED")"' pr-autoreview.sh
before 'the coach stamp comes before the merge-rule readers (partition)' 'CLEANED="$(jq -c --argjson coach "$COACH" "$FINDINGS_STAMP_JQ" <<<"$CLEANED")"' 'FINDINGS="$(jq -c --argjson blocking true "$FINDINGS_PARTITION_JQ" <<<"$CLEANED"' pr-autoreview.sh
# Duty (c) of the memory section follows the late cap switch, like the
# round task section: no "demoted anyway" promise on a round the cap is off.
pin    'duty (c) has the cap-on wording'  'DUTY_C="A NEW HIGH about a file no earlier round cited' pr-autoreview.sh
pin    'duty (c) has the cap-off wording' 'DUTY_C="This round the harness demotes NOTHING' pr-autoreview.sh
before 'duty (c) is chosen by the late cap switch' 'if [ "${ROUND_CAP_ON:-0}" = 1 ]; then' 'DUTY_C="A NEW HIGH' pr-autoreview.sh
pin    'duty (c) text is the switched variable' '(c) Spend the round on duty (a) plus what changed since the last reviewed round. $DUTY_C' pr-autoreview.sh
# Symbol table: built on the review tree from the same diff, BEFORE the
# section is rendered, behind its knob.
pin    'the symbol table is built from the review tree, the diff and the file list' 'SYM_NOTES="$(symbols_scan "$REPO_DIR" "$DIFF" "$PR_FILES" 2>/dev/null)"' pr-autoreview.sh
pin    'the symbol table has its own prompt section' 'SYMBOLS_SECTION="$(symbols_prompt_section "$SYM_NOTES"' pr-autoreview.sh
pin    'the symbol table section is in the prompt' '$SYMBOLS_SECTION' pr-autoreview.sh
SYM_LN="$(grep -nF 'SYM_NOTES="$(symbols_scan' pr-autoreview.sh | head -1 | cut -d: -f1)"
SYM_GUARD="$( [ -n "$SYM_LN" ] && sed -n "$((SYM_LN - 1))p" pr-autoreview.sh | sed 's/^[[:space:]]*//')"
if [ "$SYM_GUARD" = 'if [ "$GATE_SYMBOLS" = 1 ]; then' ]; then ok 'the symbol table is behind PRREVIEW_GATE_SYMBOLS'; else bad 'the symbol table is behind PRREVIEW_GATE_SYMBOLS' "line before symbols_scan is: ${SYM_GUARD:-<none>}"; fi
# Split request: decided and posted BEFORE the replay seam and
# every model call, and the old size hold survives only under its knob.
before 'the split request is decided before the replay seam' 'SPLIT_TEXT="$(split_request_text' '# ── REPLAY-SEAM-BEGIN' pr-autoreview.sh
before 'the split request is decided before the main review is planned' 'SPLIT_TEXT="$(split_request_text' 'ROUND_SAMPLES="$(chunk_samples_for_round' pr-autoreview.sh
pin    'the split-exemption claim section is in the prompt' '$SPLIT_SECTION' pr-autoreview.sh
pin    'an exempt oversize PR doubles its first-round samples' 'SAMPLES_ROUND1 * ${SPLIT_X:-1}' pr-autoreview.sh
# A review that ran but left nothing usable is held, or the next round pays
# for the same review a minute later, and every minute after that.
pin    'an unusable review that ran holds the head' '[ "$REVIEW_STATUS" = "OK" ] && [ -n "${HOLD_F:-}" ] && holdoff_set "$HOLD_F" failed "$(date +%s)"' pr-autoreview.sh
pin    'the repo list asks gh for more than its default 30 PRs' 'pr list --repo "$REPO" --state open --limit 1000' pr-autoreview.sh
# ...and the split request is excluded from the ROUND readers only: the
# memory/round count (PROMPT_REAL_REVIEWS_JQ) and the verdict-shaped
# count skip it, and the post-merge alert's last verdict body keeps it, so
# merging over a split request still reads as merging over a block.
GUARD_AT="$(grep -n 'if ! findings_cleaned_ok "$CLEANED"; then' pr-autoreview.sh | head -1 | cut -d: -f1)"
TALLY_AT="$(grep -n '^  N_BLOCKING=' pr-autoreview.sh | head -1 | cut -d: -f1)"
is  'a failed findings jq step fails closed ahead of the tally'         "$([ -n "$GUARD_AT" ] && [ -n "$TALLY_AT" ] && [ "$GUARD_AT" -lt "$TALLY_AT" ] && echo yes)" yes
is  'the review call reads its prompt from a file, not an argument'    "$(grep -c -- 'claude_call "$REVIEW_TIMEOUT" "$REVIEW_MODEL"' pr-autoreview.sh) $(grep -c -- '<"$PROMPT_F" >"$SLICE_RAW_F"' pr-autoreview.sh)" '1 1'
is  'no loop counts down through seq (BSD seq 0 -1 prints two numbers)' "$(grep -hE 'seq 0 \$\(\(' pr-autoreview.sh lib/*.sh | grep -vcE '^[[:space:]]*#')" 0
near() { # $1 file, $2 definition line pattern, $3 window: the lines right after the definition
  local l; l="$(grep -nE "$2" "$1" | head -1 | cut -d: -f1)"; [ -n "$l" ] && sed -n "${l},$((l + $3))p" "$1"; }
is  'the round readers skip the split request by tag'               "$(. lib/prompt.sh && grep -cE '(^|\|)split($|\|)' <<<"$PROMPT_ROUND_SKIP_TAGS")" 1
has 'round memory (PROMPT_REAL_REVIEWS_JQ) skips the split request'  'PROMPT_ROUND_SKIP_TAGS' "$(near lib/prompt.sh '^PROMPT_REAL_REVIEWS_JQ=' 6)"
has 'the verdict-shaped count skips the split request'              'PROMPT_ROUND_SKIP_TAGS' "$(near lib/prompt.sh '^PROMPT_VERDICT_SHAPED_JQ=' 4)"
is  'the post-merge alert last verdict body KEEPS the split request' "$(near lib/prompt.sh '^prompt_last_verdictish_body\(\)' 12 | grep -c 'split)\|PROMPT_ROUND_SKIP_TAGS')" 0
# Startup order: nothing above the lib source lines may read a name a lib
# defines — under set -u that is a dead gate on every round (the
# split-exemption default was read before lib/split.sh was sourced).
LIB_LN="$(grep -nF '. "$SCRIPT_DIR/lib/split.sh"' pr-autoreview.sh | head -1 | cut -d: -f1)"
EARLY="$( [ -n "$LIB_LN" ] && sed -n "1,${LIB_LN}p" pr-autoreview.sh | grep -v '^[[:space:]]*#' | grep -c 'SPLIT_EXEMPT_RE_DEFAULT')"
if [ -n "$LIB_LN" ] && [ "${EARLY:-1}" = 0 ]; then ok 'no code above the lib/split.sh source line reads SPLIT_EXEMPT_RE_DEFAULT'; else bad 'no code above the lib/split.sh source line reads SPLIT_EXEMPT_RE_DEFAULT' "lib sourced at ${LIB_LN:-none}, early reads: ${EARLY:-?}"; fi

# One way to start the model: claude_call (lib/claude-call.sh). A call
# written outside it gets none of its tool limits, and every other test
# stays green. Print mode (-p, --print) is how a script runs the model, so
# no other line may use it, under any name: a literal claude, $CLAUDE_BIN or
# another variable. The --version, --help, auth status and -x checks do not
# use print mode. mkdir -p and cp -p are the other commands here that take
# -p. A single-quoted span is text, such as the hint in a setup message.
print_mode_lines() { # stdin: shell source. stdout: the lines that use print mode.
  grep -vE '^[[:space:]]*#' \
    | sed -E "s/'[^']*'//g; s/(mkdir|cp)[[:space:]]+-p//g" \
    | grep -E '(^|[[:space:]])(-p|--print)([[:space:]]|=|$)'
}
OTHERS=()
for f in pr-autoreview.sh review-loop.sh owner-alert.sh prreview lib/*.sh; do [ "$f" = lib/claude-call.sh ] || OTHERS+=("$f"); done
is  'no model call outside lib/claude-call.sh' "$(cat "${OTHERS[@]}" | print_mode_lines | head -3)" ''
CALL_BODY="$(awk '/^claude_call\(\) \{/{f=1} f{print} f&&/^\}/{exit}' lib/claude-call.sh 2>/dev/null)"
is  'claude_call is in lib/claude-call.sh and starts the binary in print mode' \
    "$(print_mode_lines <<<"$CALL_BODY" | grep -c '"$CLAUDE_BIN" -p')" 1
is  '...and nothing else in that file uses print mode' \
    "$( (grep -vFx "$CALL_BODY" lib/claude-call.sh 2>/dev/null || cat lib/claude-call.sh 2>/dev/null) | print_mode_lines | head -3)" ''
is  'no --allowedTools outside lib/claude-call.sh' "$(grep -hE '^[^#]*--allowedTools' "${OTHERS[@]}" | wc -l | tr -d ' ')" 0
before 'the Claude Code version is checked before the lock' 'claude_version_check || exit 1' 'LOCKFILE=' pr-autoreview.sh

# The diff, the file list and the marker SHA describe ONE commit. A moving
# `gh pr diff` call (head at the time of the call) would let a force-push
# between the reads attach a verdict to a head nobody reviewed, and re-reading
# headRefOid after the fact does not close an A-B-A swap. So: one compare-API
# fetch pinned to the SHA from the same `gh pr view` read, the file list taken
# from that file, the count checked against that read's changedFiles.
is     'no moving gh pr diff call is left in the gate or its libs' "$(grep -n 'pr diff' pr-autoreview.sh lib/*.sh | tr '\n' ' ')" ''
pin    'the PR info read carries changedFiles, the count the diff is checked against' 'headRefOid,isDraft,reviews,comments,title,body,additions,deletions,changedFiles,autoMergeRequest,baseRefName' pr-autoreview.sh
pin    'the diff is fetched for the SHA the key was made from, with the file count of the same read' 'pr_diff_pinned "$REPO" "$MERGE_BASE" "$SHA" "$DIFF" "$(jq -r '"'"'.changedFiles // ""'"'"' <<<"$INFO")"' pr-autoreview.sh
before 'the merge base is resolved before the diff is fetched' 'MERGE_BASE="$(merge_base_sha "$REPO" "$PR_BASE" "$SHA")"' 'pr_diff_pinned "$REPO"' pr-autoreview.sh
before 'the diff is fetched before it is applied to the tree' 'pr_diff_pinned "$REPO"' 'APPLY_ERR="$(git -C "$REPO_DIR" apply' pr-autoreview.sh
before 'the file list exists before anything reads it' 'pr_diff_pinned "$REPO"' 'REVIEW_CHECKS="$(review_checks_render' pr-autoreview.sh
is     'the merge base is looked up once' "$(grep -c 'MERGE_BASE="$(merge_base_sha' pr-autoreview.sh)" 1

if [ "$FAILED" -eq 0 ]; then echo "PASS: gate wiring"; else echo "FAIL: gate wiring"; exit 1; fi
