#!/usr/bin/env bash
# The chain in pr-autoreview.sh that rewrites CLEANED, the review object, after
# the model answered: shape filter, coach stamp, citation check, line check,
# convergence caps, repeat mark, red-team merge, refutation drop, per-file cap.
# The real block runs here, lifted out of the script, on a real git tree. A
# recorder stands in for note_skip and holdoff_set. A jq on PATH fails the one
# call whose filter holds a marker text, and runs the real jq for every other
# call, so the guard's own jq call is never the one that fails.
#
# The claim under test: no failure of one step lets the round go on to the
# tally with an empty or cut CLEANED. A step with no check of its own
# (SHAPE, STAMP, CITE, DROP, FILE_CAP) leaves CLEANED empty, and the check
# before the tally (findings_cleaned_ok) then skips the PR. A step with its
# own check (LINE, CONV, RPT, RT merge) keeps the findings it had. In both
# cases the blocker of round 1 is still counted, or the PR is skipped.
#
# Three failure modes per step: jq exits non-zero with no output, jq exits 0
# with no output, jq exits non-zero after it printed the front of the JSON.
#
# The second claim: the counts that feed the flip guard (blockers before and
# after the citation check and the line check) are read the same way. A count
# whose jq failed is empty, and an empty count must not read as zero dropped
# blockers: that turns a request_changes whose blocker was dropped into an
# approve. The count of blockers in the tally, after the check, is the same:
# an empty count must not read as zero blockers.
#
# Run: bash tests/findings-chain.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "must not contain '$2', got: $3";; *) ok "$1";; esac; }
for h in ok bad is has lacks; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/findings.sh || { echo "FAIL: could not source lib/findings.sh"; exit 1; }
. lib/redteam.sh  || { echo "FAIL: could not source lib/redteam.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_JQ="$(command -v jq)"
export REAL_JQ

# jq that fails the call whose arguments hold $JQ_FAIL_NEEDLE: every such call,
# or only the JQ_FAIL_NTH-th one (counted in the file JQ_COUNT_F).
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/jq" <<'EOF'
#!/bin/bash
if [ -n "${JQ_FAIL_NEEDLE-}" ]; then
  for a in "$@"; do
    case "$a" in
      *"$JQ_FAIL_NEEDLE"*)
        if [ -n "${JQ_FAIL_NTH-}" ]; then
          c=$(( $(cat "$JQ_COUNT_F" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$JQ_COUNT_F"
          [ "$c" = "$JQ_FAIL_NTH" ] || exec "$REAL_JQ" "$@"
        fi
        case "${JQ_FAIL_MODE-rc}" in
          rc)    exit 5 ;;
          empty) exit 0 ;;
          cut)   printf '{"verdict":"request_changes","findings":[{"severity":"HIG'; exit 5 ;;
        esac ;;
    esac
  done
fi
exec "$REAL_JQ" "$@"
EOF
chmod +x "$STUBS/jq"

# CHAIN: from the first line of the chain to the `fi` that closes the check
# before the tally. TAIL: the tally and the verdict rule that follow it, up to
# the `fi` that closes the verdict override.
START='^  CLEANED="[$]PARSED"$'
GUARD='^  if ! findings_cleaned_ok "[$]CLEANED"; then$'
TALLY='^  FINDINGS="[$][(]jq -c --argjson blocking true'
CHAIN="$(awk -v s="$START" -v g="$GUARD" '
  $0 ~ s { p = 1 }
  p { print }
  p && $0 ~ g { q = 1 }
  p && q && /^  fi$/ { exit }' pr-autoreview.sh)"
TAIL="$(awk -v s="$TALLY" '
  $0 ~ s { p = 1 }
  p { print }
  p && /VERDICT="[$]RESOLVED"/ { q = 1 }
  p && q && /^  fi$/ { exit }' pr-autoreview.sh)"
[ "$(grep -c '' <<<"$CHAIN")" -gt 400 ] || { echo "FAIL: could not lift the CLEANED chain out of pr-autoreview.sh"; exit 1; }
[ "$(grep -c 'findings_cleaned_ok' <<<"$CHAIN")" = 1 ] || { echo "FAIL: the lifted chain has no findings_cleaned_ok check"; exit 1; }
[ "$(grep -c 'findings_resolve_verdict' <<<"$TAIL")" = 1 ] || { echo "FAIL: could not lift the tally out of pr-autoreview.sh"; exit 1; }
# The same chain with the check removed: the control that shows the cases below
# can fail.
CHAIN_NO_CHECK="$(awk -v g="$GUARD" '$0 ~ g { skip = 1 } !skip { print } skip && /^  fi$/ { skip = 0 }' <<<"$CHAIN")"
[ "$(grep -c 'findings_cleaned_ok' <<<"$CHAIN_NO_CHECK")" = 0 ] || { echo "FAIL: could not cut the check out of the chain"; exit 1; }

# What the round holds when it reaches the line after the verdict rule.
REACHED="echo \"reached tally=\${N_BLOCKING-} n=\${N_FINDINGS-} ok=\$(findings_cleaned_ok \"\$CLEANED\" && echo y || echo n) ndc=\${N_DROPPED_CITE-} resolved=\$VERDICT\""
eval "chain() { $CHAIN
$TAIL
$REACHED; }"
eval "chain_no_check() { $CHAIN_NO_CHECK
$TAIL
$REACHED; }"
# The tally alone, on a review that is whole.
eval "tally() { CLEANED=\"\$PARSED\"; VERDICT=\"\$(jq -r '.verdict' <<<\"\$CLEANED\")\"
$TAIL
$REACHED; }"

# ── stand-ins for what the script defines around the block ──────────────────
note_skip()      { echo "skip $PR: $1"; }
holdoff_set()    { echo "hold $2"; }
print_withheld() { sed 's/^/    /' <<<"$1"; }
one_line()       { printf '%s\n' "${1//[$'\r\n']/ }"; }
usage_record()   { :; }
prompt_lines_to_json()         { printf '[]'; }
prompt_repeat_blocking_files() { :; }
redteam_prompt() { printf 'red team prompt'; }
claude_call()    { cat >/dev/null; echo "MODEL CALL"; return 99; }
# A model that refutes whatever it is asked about.
claude_refutes() { cat >/dev/null; printf '%s\n' '{"type":"result","is_error":false,"result":"{\"refuted\":true,\"confidence\":0.95,\"reason\":\"the caller checks it\"}"}'; }
# A model whose red team raises one candidate.
claude_raises()  { cat >/dev/null; printf '%s\n' '{"type":"result","is_error":false,"result":"{\"candidates\":[{\"severity\":\"HIGH\",\"confidence\":0.7,\"file\":\"a.sh\",\"line\":2,\"issue\":\"a missed defect\"}]}"}'; }

HIGH='{"severity":"HIGH","confidence":0.9,"file":"a.sh","line":1,"issue":"the check can be skipped","area":"correctness"}'
MED='{"severity":"MEDIUM","confidence":0.6,"file":"a.sh","line":3,"issue":"a name is unclear"}'
REVIEW_BLOCK="{\"verdict\":\"request_changes\",\"summary\":\"s\",\"findings\":[$HIGH]}"
REVIEW_PASS="{\"verdict\":\"approve\",\"summary\":\"s\",\"findings\":[$MED]}"
# The model asked for changes on a blocker that the citation check will drop
# (the file does not exist), and listed one finding that does not block.
GHOST='{"severity":"HIGH","confidence":0.9,"file":"ghost.sh","line":1,"issue":"a file that is not there","area":"correctness"}'
REVIEW_GHOST="{\"verdict\":\"request_changes\",\"summary\":\"s\",\"findings\":[$GHOST,$MED]}"
# A review whose blocker cites a file that exists, with one finding that does
# not block.
REVIEW_TWO="{\"verdict\":\"request_changes\",\"summary\":\"s\",\"findings\":[$HIGH,$MED]}"
# The same, with a blocker that the line check will drop (a.sh has 3 lines).
FAR='{"severity":"HIGH","confidence":0.9,"file":"a.sh","line":99,"issue":"a line that is not there","area":"correctness"}'
REVIEW_FAR="{\"verdict\":\"request_changes\",\"summary\":\"s\",\"findings\":[$FAR,$MED]}"

# run_case <function> <PARSED> [env words...]: a fresh tree, the chain run in
# a subshell. Sets OUT (its output). Env words are VAR=value, set before the
# run; MODEL=refutes or MODEL=raises picks the stand-in for claude_call.
run_case() {
  local fn="$1" parsed="$2" d w
  shift 2
  d="$TMP/case-$RANDOM$RANDOM"
  mkdir -p "$d/tree" "$d/scratch" "$d/quota"
  git -C "$d/tree" init -q
  printf 'echo one\necho two\necho three\n' > "$d/tree/a.sh"
  printf 'diff --git a/a.sh b/a.sh\n' > "$d/diff"
  # shellcheck disable=SC2034  # read by the lifted block
  OUT="$( (
    PATH="$STUBS:$PATH"
    PR=7; REPO_KEY=o__r; REPO=o/r; REPO_DIR="$d/tree"; PR_FILES=a.sh; GATE_SCRATCH="$d/scratch"; QUOTA_DIR="$d/quota"
    DIFF="$d/diff"; DIFF_VIEW="$d/diff"; DIFF_DIR="$d"; export JQ_COUNT_F="$d/count"; TMPFILES=(); SIZE=50; GATE_COACH_MAX_LINES=100; GATE_FILE_CAP=8
    PARSED="$parsed"; OUT=""; REVIEW_STATUS=OK; HOLD_F="$d/hold"; REVIEW_ERR=/dev/null; REPAIR_ERR=/dev/null
    VERDICT=""; REPAIRED=0; SLICE_INCOMPLETE=0; PRIOR_CITED=""; DELTA_FILES=""; ROUND=1
    MAIN_PRIOR=""; INFO='{}'; MARKER=m; PRIOR_AUTHORS=""; VERIFY_MAX=3; VERIFY_TIMEOUT=60; REVIEW_MODEL=m
    CLAUDE_READ_TOOLS=""; TREE_CLAUSE=""; STACKED_CLAUSE=""; REVIEW_LANGUAGE_SPEC=""; SEVERITY_SPEC=""
    REVIEW_LINE_SPEC=""; REDTEAM_MAX=3
    unset ROUND_CAP_ON DELTA_KNOWN PRREVIEW_GATE_VERIFY_LINES PRREVIEW_GATE_REDTEAM DIFF_APPLIED
    MODEL=""
    for w in "$@"; do export "${w?}"; done
    case "${MODEL-}" in
      (refutes) claude_call() { claude_refutes; } ;;
      (raises)  claude_call() { claude_raises; } ;;
    esac
    "$fn" 2>&1 ) )"
}

# ── the harness runs the real chain (control for everything below) ──────────
run_case chain "$REVIEW_BLOCK"
has 'no failure: the chain reaches the tally'               "reached tally=1 n=1 ok=y" "$OUT"
lacks 'no failure: no model call and no skip'               "skip 7:" "$OUT"
lacks 'no failure: no stray model call'                     "MODEL CALL" "$OUT"
run_case chain "$REVIEW_BLOCK" JQ_FAIL_NEEDLE=no-such-filter-text JQ_FAIL_MODE=rc
has 'a marker no filter holds fails nothing'                "reached tally=1 n=1 ok=y" "$OUT"
run_case chain "$REVIEW_PASS" PRREVIEW_GATE_REDTEAM=1 MODEL=raises
has 'no failure: the red team candidate is merged'          "red team raised 1 candidate(s)" "$OUT"
has '...and counts as a second finding'                     "reached tally=1 n=2 ok=y" "$OUT"
run_case chain "$REVIEW_BLOCK" PRREVIEW_GATE_VERIFY_LINES=1 DIFF_APPLIED=1
has 'no failure: the line check runs and keeps a real line' "reached tally=1 n=1 ok=y" "$OUT"

# The line backstop runs on its own condition, with the knob off. The blocker
# that cites line 99 of a three-line file is kept with line 0, so the tally
# still counts it (n=2, one blocker), and the log names the original line.
run_case chain "$REVIEW_FAR" DIFF_APPLIED=1
has 'the line backstop keeps the blocker (knob off, diff applied)' "reached tally=1 n=2 ok=y" "$OUT"
has '...and logs the original line' "a.sh:99 is past the end of the file, set to 0" "$OUT"
run_case chain "$REVIEW_FAR"
has 'the line backstop does nothing when the diff was not applied' "reached tally=1 n=2 ok=y" "$OUT"
lacks '...and logs nothing' "set to 0" "$OUT"

# bash 3.2 finds the end of "$( )" by counting parentheses and quotes. It counts
# comments too, and a case pattern ends in a parenthesis. The run above passes
# on bash 4 and later whatever the text is, so pin the text. Without these two
# rules the line-count loop breaks on macOS, where the system bash is 3.2.
LC_BLOCK="$(sed -n '/LINE_COUNTS="\$(/,/2>\/dev\/null)"$/p' pr-autoreview.sh)"
has   'the line-count loop is found' 'LINE_COUNTS="$(' "$LC_BLOCK"
has   'its case pattern opens with a parenthesis' 'case "$f" in (/*|*..*)' "$LC_BLOCK"
is    'no comment inside it holds a single quote' "$(grep -c "^[[:space:]]*#.*'" <<<"$LC_BLOCK")" 0

# A step with no check of its own: CLEANED is left empty, the PR is skipped.
skipped() { # $1 label, then the case already ran
  has   "$1: the PR is skipped"               "skip 7:" "$OUT"
  has   "$1: the skip says it fails closed"   "(fail closed)" "$OUT"
  has   "$1: the head is held"                "hold failed" "$OUT"
  lacks "$1: the round does not reach the tally" "reached" "$OUT"
  lacks "$1: no stray model call"             "MODEL CALL" "$OUT"
}
# A step with its own check: the findings it had are kept, the blocker counts.
kept() { # $1 label, $2 expected tally line
  has   "$1: the round reaches the tally with the findings kept" "$2" "$OUT"
  lacks "$1: the PR is not skipped"            "skip 7:" "$OUT"
}

for mode in rc empty cut; do
  export JQ_FAIL_MODE="$mode"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_SHAPE_JQ"
  skipped "shape filter fails ($mode)"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_STAMP_JQ"
  skipped "coach stamp fails ($mode)"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_CITATION_JQ"
  skipped "citation check fails ($mode)"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_FILE_CAP_JQ"
  skipped "per-file cap fails ($mode)"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_DROP_JQ" MODEL=refutes
  has   "refutation drop fails ($mode): the refutation ran" "refutation REFUTED" "$OUT"
  skipped "refutation drop fails ($mode)"
  # With a check of their own. A run of the convergence caps or the repeat mark
  # that fails leaves the findings as they were, uncapped and unmarked.
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_CONVERGE_JQ"
  has   "convergence caps fail ($mode): the log says so" "convergence cap did not run" "$OUT"
  kept  "convergence caps fail ($mode)" "reached tally=1 n=1 ok=y"
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_REPEAT_MARK_JQ"
  kept  "repeat mark fails ($mode)" "reached tally=1 n=1 ok=y"
  # The line check is off by default. Its result is read without the exit
  # status, so the cut output is the one that matters: the next line of the
  # script counts findings in the cut text, jq fails, and the arithmetic on the
  # empty count is a syntax error. Bash ends a non-interactive shell on that,
  # which here is the job, so the round never reaches the tally.
  run_case chain "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_LINE_JQ" PRREVIEW_GATE_VERIFY_LINES=1 DIFF_APPLIED=1
  if [ "$mode" = cut ]; then
    lacks "line check fails ($mode): the round does not reach the tally" "reached" "$OUT"
    lacks "line check fails ($mode): no stray model call" "MODEL CALL" "$OUT"
  else
    has "line check fails ($mode): the log says so" "line-number validation could not run" "$OUT"
    kept "line check fails ($mode)" "reached tally=1 n=1 ok=y"
  fi
  # The red team is the one stage that fails open on purpose (lib/redteam.sh):
  # a failed merge drops its candidates and round 1 stands, with round 1's own
  # findings intact.
  run_case chain "$REVIEW_PASS" "JQ_FAIL_NEEDLE=.findings = ((.findings // []) + \$add)" PRREVIEW_GATE_REDTEAM=1 MODEL=raises
  has   "red team merge fails ($mode): the log says so" "could not merge the red team's candidates" "$OUT"
  kept  "red team merge fails ($mode)" "reached tally=0 n=1 ok=y"
done
unset JQ_FAIL_MODE

# ── the counts that guard the flip from request_changes to approve ──────────
# A blocker that the citation check (or the line check) drops leaves only
# findings that do not block. Without a guard the verdict rule would read that
# as "nothing blocks" and approve, so the script counts the blockers before and
# after and keeps the difference in N_DROPPED_CITE. A count whose jq failed
# comes back empty. The round must not read it as zero: the model asked for
# changes, a blocker was dropped, and that is no approve.
# The first call of FINDINGS_BLOCKING_COUNT_JQ is the count before the citation
# check, the second the count after it. With the line check on, the third and
# fourth are the same pair around it.
run_case chain "$REVIEW_GHOST"
has   'no failure: the citation check drops the blocker'     "1 of them blocking" "$OUT"
has   '...the drop is counted'                               "ndc=1" "$OUT"
has   '...and the verdict stays request_changes'             "resolved=request_changes" "$OUT"
run_case chain "$REVIEW_FAR" PRREVIEW_GATE_VERIFY_LINES=1 DIFF_APPLIED=1
has   'no failure: the line check drops the blocker'         "(1 of them blocking)" "$OUT"
has   '...the drop is counted'                               "ndc=1" "$OUT"
has   '...and the verdict stays request_changes'             "resolved=request_changes" "$OUT"
for mode in rc empty; do
  export JQ_FAIL_MODE="$mode"
  for nth in 1 2; do
    run_case chain "$REVIEW_GHOST" "JQ_FAIL_NEEDLE=$FINDINGS_BLOCKING_COUNT_JQ" "JQ_FAIL_NTH=$nth"
    lacks "citation count $nth fails ($mode): the dropped blocker does not become an approve" "resolved=approve" "$OUT"
  done
  for nth in 3 4; do
    run_case chain "$REVIEW_FAR" "JQ_FAIL_NEEDLE=$FINDINGS_BLOCKING_COUNT_JQ" "JQ_FAIL_NTH=$nth" PRREVIEW_GATE_VERIFY_LINES=1 DIFF_APPLIED=1
    lacks "line count $((nth - 2)) fails ($mode): the dropped blocker does not become an approve" "resolved=approve" "$OUT"
  done
done
unset JQ_FAIL_MODE

# ── the tally ───────────────────────────────────────────────────────────────
# The check before the tally only proves that CLEANED is a review. The tally
# then counts blockers with one more jq call, and a count that failed comes back
# empty. The verdict rule reads empty as 0 blockers, and a request_changes that
# lists a real blocker next to a finding that does not block becomes an approve.
run_case tally "$REVIEW_TWO"
has   'no failure: the tally counts the blocker'             "reached tally=1 n=2" "$OUT"
has   '...and the verdict stays request_changes'             "resolved=request_changes" "$OUT"
for mode in rc empty; do
  export JQ_FAIL_MODE="$mode"
  run_case tally "$REVIEW_TWO" "JQ_FAIL_NEEDLE=$FINDINGS_BLOCKING_COUNT_JQ"
  lacks "blocker count fails ($mode): a real blocker does not become an approve" "resolved=approve" "$OUT"
  lacks "blocker count fails ($mode): the log does not say the verdict was overridden to approve" "overridden to approve" "$OUT"
done
unset JQ_FAIL_MODE

# ── control: the same failures, with the check before the tally cut out ─────
# Shows what the check stops. The shape filter and the per-file cap each leave
# CLEANED empty. Without the check the round gets past it: it reaches the tally
# with nothing, or the check on the tally counts (further down) stops it there.
either() { case "$4" in *"$2"*|*"$3"*) ok "$1";; *) bad "$1" "expected '$2' or '$3', got: $4";; esac; }
run_case chain_no_check "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_SHAPE_JQ" JQ_FAIL_MODE=rc
lacks  'control, shape filter fails: the check is cut out'     "a findings step (jq) failed" "$OUT"
either 'control, shape filter fails, no check: the round goes on past it' "reached tally= n= ok=n" "the blocking tally (jq) failed" "$OUT"
run_case chain_no_check "$REVIEW_BLOCK" "JQ_FAIL_NEEDLE=$FINDINGS_FILE_CAP_JQ" JQ_FAIL_MODE=empty
lacks  'control, per-file cap fails: the check is cut out'     "a findings step (jq) failed" "$OUT"
either 'control, per-file cap fails, no check: the round goes on past it' "reached tally= n= ok=n" "the blocking tally (jq) failed" "$OUT"

if [ "$FAILED" -eq 0 ]; then echo "PASS: CLEANED chain"; else echo "FAIL: CLEANED chain"; exit 1; fi
