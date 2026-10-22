#!/usr/bin/env bash
# Tests for lib/redteam.sh — the third round that attacks "nothing blocks".
# No network, no model call: run  bash tests/redteam.test.sh
#
# Three things are pinned here, and they are different kinds of thing.
#
# GATING. The stage is only sound because it fires on the approve path and
# nowhere else: a round that already blocks has nothing to attack, and a round
# that cannot approve cannot be helped by a candidate. redteam_should_run is
# where that lives, and it delegates the hard half to findings_resolve_verdict
# so there is one answer in this repo to "will this round approve?".
#
# SHAPE. Whatever a model hands back, what reaches the findings list must be
# renderable and verifiable. The direction of the shape filter is the INVERSE
# of the main review's widened ladder — malformed drops instead of blocking —
# and that inversion is the fail-open rule made concrete, so it is asserted
# rather than left to be re-derived.
#
# PROMPT. The five defect classes are each a kind of defect a first round
# tends to miss. A prompt that quietly loses one of them still
# produces candidates, so nothing else would notice the loss.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fail() { echo "FAIL: $1"; exit 1; }

. ./lib/findings.sh   || fail "lib/findings.sh will not source"
. ./lib/redteam.sh    || fail "lib/redteam.sh will not source"
. ./lib/review-spec.sh || fail "lib/review-spec.sh will not source"
. ./lib/prompt.sh     || fail "lib/prompt.sh will not source"

# ── default OFF ───────────────────────────────────────────────────────────
# The stage ships disabled, so turning it on is a deliberate choice. A default
# that flipped by accident would put a new model call on every approved PR.
( unset PRREVIEW_GATE_REDTEAM; redteam_enabled ) \
  && fail "redteam_enabled is TRUE with nothing set — the stage must default off"
for v in 1 true TRUE yes YES on ON; do
  ( export PRREVIEW_GATE_REDTEAM="$v"; redteam_enabled ) \
    || fail "PRREVIEW_GATE_REDTEAM=$v should enable the stage"
done
for v in 0 false no off "" nonsense; do
  ( export PRREVIEW_GATE_REDTEAM="$v"; redteam_enabled ) \
    && fail "PRREVIEW_GATE_REDTEAM=$v must NOT enable the stage"
done

# ── redteam_should_run: fires on the approve path, nowhere else ────────────
# args: verdict n_blocking n_findings dropped repaired incomplete
redteam_should_run approve 0 0 0 0 0 || fail "a clean approve is exactly when this must fire"
redteam_should_run approve 0 3 0 0 0 || fail "an approve with MEDIUM/LOW findings is still an approve"

# A round that already blocks: nothing to attack, and its blockers will spend
# the verify budget themselves.
redteam_should_run request_changes 1 1 0 0 0 \
  && fail "must not fire when something already blocks"
redteam_should_run approve 2 2 0 0 0 \
  && fail "blocking count decides, not the model's own verdict string"

# A repaired review may block but may never approve, so a candidate cannot
# change the outcome — the call would be spent for nothing.
redteam_should_run approve 0 1 1 1 0 \
  && fail "must not fire on a repaired review"
# Same for a round with a slice that produced no usable review.
redteam_should_run approve 0 1 1 0 1 \
  && fail "must not fire when part of the diff was not reviewed"

# The flip guard is the delegated half. request_changes with findings left and
# nothing dropped resolves to approve, so the PR is on the approve path.
redteam_should_run request_changes 0 2 0 0 0 \
  || fail "request_changes that resolves to approve IS the approve path"
# With a blocker dropped by the citation check the flip is refused, so the
# round holds and there is nothing to attack.
redteam_should_run request_changes 0 2 1 0 0 \
  && fail "must not fire on a round the flip guard is holding"
# But an APPROVE with a citation drop still approves — the guard only stops
# request_changes from becoming approve — so the stage must still fire. This is
# the case a naive "any dropped flag means skip" would have missed, leaving the
# one round that approves without a path list also the one with no red team.
redteam_should_run approve 0 1 1 0 0 \
  || fail "an approve stays an approve even with a citation drop — the stage must still fire"

# ── candidate shape filter ────────────────────────────────────────────────
ISSUE_TXT='broken'
PREAMBLE='I read the whole diff and found one problem:'
TRAILER='That is everything I found.'
NO_JSON='I see no problem in this diff.'
EXISTING='existing finding'
cand() { jq -c --argjson max "${2:-3}" "$REDTEAM_CANDIDATES_JQ" <<<"$1"; }

OUT="$(cand '{"candidates":[{"severity":"HIGH","file":"a.py","line":7,"confidence":0.7,"issue":"'"$ISSUE_TXT"'"}]}')"
[ "$(jq -r 'length' <<<"$OUT")" = 1 ] || fail "a well-formed HIGH candidate was dropped"
[ "$(jq -r '.[0].redteam' <<<"$OUT")" = "true" ] \
  || fail "a candidate must be marked redteam:true — the author's line and the render annotation both read it"
[ "$(jq -r '.[0].kind' <<<"$OUT")" = "defect" ] \
  || fail "kind must be fixed at defect; any other value produces a candidate that cannot block"

# MEDIUM and LOW cannot change the verdict, so they are not candidates.
for sev in MEDIUM LOW NIT ""; do
  N="$(jq -r 'length' <<<"$(cand "{\"candidates\":[{\"severity\":\"$sev\",\"file\":\"a.py\",\"issue\":\"x\"}]}")")"
  [ "$N" = 0 ] || fail "severity '$sev' must not become a candidate (got $N)"
done
# Case and whitespace are the model's, not a contract.
for sev in high "  High  " critical; do
  N="$(jq -r 'length' <<<"$(cand "{\"candidates\":[{\"severity\":\"$sev\",\"file\":\"a.py\",\"issue\":\"x\"}]}")")"
  [ "$N" = 1 ] || fail "severity '$sev' should normalise into a candidate"
done

# Unrenderable and unverifiable entries DROP. This is the inverse of
# FINDINGS_SEVERITY_JQ's widened ladder, where an unrecognised severity blocks:
# there, fail-closed protects the verdict; here, a candidate the gate cannot read
# is one it can neither show the author nor hand to the refutation pass, so
# blocking on it would hold a PR over a garbled bonus answer.
for bad in '{"candidates":["a string"]}' \
           '{"candidates":[{"severity":"HIGH","issue":"no file"}]}' \
           '{"candidates":[{"severity":"HIGH","file":"   ","issue":"blank file"}]}' \
           '{"candidates":[{"severity":"HIGH","file":"a.py"}]}' \
           '{"candidates":[{"severity":"HIGH","file":"a.py","issue":"  "}]}' \
           '{"candidates":[{"severity":"HIGH","file":["a.py"],"issue":"list file"}]}' \
           '{}' '{"candidates":[]}'; do
  N="$(jq -r 'length' <<<"$(cand "$bad")")"
  [ "$N" = 0 ] || fail "malformed input should yield no candidates: $bad"
done

# Missing optionals get defaults rather than dropping the candidate: a real
# defect reported without a line number is still a real defect.
OUT="$(cand '{"candidates":[{"severity":"HIGH","file":"a.py","issue":"'"$ISSUE_TXT"'"}]}')"
[ "$(jq -r '.[0].line' <<<"$OUT")" = "0" ] || fail "a missing line should default to 0"
[ "$(jq -r '.[0].confidence' <<<"$OUT")" = "0.5" ] || fail "a missing confidence should default to 0.5"

# The cap is what keeps one approved PR from becoming fifteen model calls.
MANY='{"candidates":[
  {"severity":"HIGH","file":"a","issue":"1"},{"severity":"HIGH","file":"b","issue":"2"},
  {"severity":"HIGH","file":"c","issue":"3"},{"severity":"HIGH","file":"d","issue":"4"},
  {"severity":"HIGH","file":"e","issue":"5"}]}'
[ "$(jq -r 'length' <<<"$(cand "$MANY" 2)")" = 2 ] || fail "the candidate cap is not applied"
[ "$(jq -r 'length' <<<"$(cand "$MANY" 3)")" = 3 ] || fail "the candidate cap is not applied at 3"

# ── REDTEAM_MAX sanitisation ─────────
# lib/redteam.sh collapses a non-numeric or sub-1 PRREVIEW_GATE_REDTEAM_MAX
# to 3. Unguarded, `PRREVIEW_GATE_REDTEAM_MAX=abc` reaches
# `jq --argjson max "$REDTEAM_MAX"` downstream as a bare identifier, jq fails
# to parse it as JSON, and the red-team stage fails open — silently, since
# fail-open is this stage's own documented default. A test that only ran the
# happy path (a numeric REDTEAM_MAX) could not catch that line being deleted.
for bad in abc 0 ""; do
  MAX_OUT="$(PRREVIEW_GATE_REDTEAM_MAX="$bad" bash -c '
    . ./lib/findings.sh >/dev/null 2>&1
    . ./lib/redteam.sh   >/dev/null 2>&1
    printf "%s" "$REDTEAM_MAX"')"
  [ "$MAX_OUT" = "3" ] \
    || fail "PRREVIEW_GATE_REDTEAM_MAX='$bad' should sanitise to 3, got '$MAX_OUT'"
done
# A valid override must survive untouched.
MAX_OUT="$(PRREVIEW_GATE_REDTEAM_MAX=7 bash -c '
  . ./lib/findings.sh >/dev/null 2>&1
  . ./lib/redteam.sh   >/dev/null 2>&1
  printf "%s" "$REDTEAM_MAX"')"
[ "$MAX_OUT" = "7" ] || fail "a valid PRREVIEW_GATE_REDTEAM_MAX=7 should not be sanitised away, got '$MAX_OUT'"

# ── the whole reply chain, on what a model actually returns ───────────────
# Every assertion above feeds the jq clean JSON, which is not what arrives. The
# reply travels findings_strip_fence -> findings_extract_json -> the jq, and
# pr-autoreview.sh — the ONLY caller of this chain — runs exactly that
# chain. A model that opens with one sentence of prose, or wraps the object
# in a fence, is the common case, not the edge — the extract helper exists
# because throwing such a reply away costs a whole review.
chain() {
  local raw="$1" j
  j="$(findings_extract_json "$(findings_strip_fence "$raw")" 'has("candidates")')" || return 1
  jq -c --argjson max 3 "$REDTEAM_CANDIDATES_JQ" <<<"$j"
}
ONE='{"candidates":[{"severity":"HIGH","file":"a.py","line":4,"issue":"'"$ISSUE_TXT"'"}]}'

[ "$(jq -r 'length' <<<"$(chain "$ONE")")" = 1 ] \
  || fail "a bare JSON reply does not survive the chain"
[ "$(jq -r 'length' <<<"$(chain "$(printf '```json\n%s\n```' "$ONE")")")" = 1 ] \
  || fail "a fenced reply does not survive the chain"
[ "$(jq -r 'length' <<<"$(chain "$(printf '%s\n%s' "$PREAMBLE" "$ONE")")")" = 1 ] \
  || fail "a reply with a prose preamble does not survive the chain"
[ "$(jq -r 'length' <<<"$(chain "$(printf '%s\n\n%s' "$ONE" "$TRAILER")")")" = 1 ] \
  || fail "a reply with trailing prose does not survive the chain"

# The empty answer is the one this stage expects MOST, and it has to come back
# as "ran, found nothing" rather than "produced nothing usable". pr-autoreview.sh
# tests `has("candidates")` for exactly this reason: asking for a non-empty
# list would file every clean PR under the failure branch — the same trap as
# testing the verify answer's `.refuted` instead of `has("refuted")`.
EMPTY='{"candidates":[]}'
chain "$EMPTY" >/dev/null || fail "an empty candidate list must parse, not fail"
[ "$(jq -r 'length' <<<"$(chain "$EMPTY")")" = 0 ] || fail "an empty list should yield no candidates"
chain "$(printf '```\n%s\n```' "$EMPTY")" >/dev/null \
  || fail "a fenced empty list must parse"

# Prose with no object at all IS the failure branch, and it must be reported as
# one — fail-open means the round approves anyway, but the log has to be
# able to tell "looked and found nothing" from "never produced an answer".
chain "$NO_JSON" >/dev/null \
  && fail "a reply with no JSON object must NOT parse as an empty candidate list"
chain '' >/dev/null && fail "an empty reply must not parse"
chain '{"findings":[]}' >/dev/null \
  && fail "an object without a candidates key must not parse as a red-team answer"

# ── the prompt ────────────────────────────────────────────────────────────
# The tree text ($4) is the one the main review gets. The three-state check
# against the real call site is at the end of this file.
P="$(redteam_prompt "o/r" 42 "/tmp/d.diff" "$(prompt_tree_clause 1)" "- **HIGH** a.py:1 — $EXISTING" \
     "$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC")"
[ -n "$P" ] || fail "redteam_prompt produced nothing"

# The five classes. Each is a kind of defect that gets past review; a prompt
# that loses one still returns candidates, so the loss would be invisible.
for shape in "contradicting ITSELF" "WRONG LEVEL" "SUCCESS-SHAPED" \
             "DIFFERENT input" "spec THIS REPO PINS"; do
  grep -qF "$shape" <<<"$P" || fail "the prompt lost the '$shape' defect class"
done

# "Nothing" has to be a first-class answer. A red team rewarded for finding
# something finds something, and a stage justified by a handful of real misses
# cannot survive inventing candidates.
grep -qF 'empty list is a legitimate' <<<"$P" \
  || fail "the prompt must say an empty answer is legitimate"
grep -qF '{"candidates":[]}' <<<"$P" \
  || fail "the prompt must show the empty answer literally"

# It must tell the model the truth about what happens next: candidates go to an
# adversarial round, so 0.6 confidence is worth reporting. Told to be certain
# instead, the stage returns nothing and the whole thing is a no-op.
grep -qF 'REFUTE' <<<"$P" \
  || fail "the prompt must say the candidates go through a refutation round"

# No severity below HIGH, stated in words as well as in the schema.
grep -qF 'CRITICAL or HIGH only' <<<"$P" \
  || fail "the prompt must restrict candidates to CRITICAL/HIGH"

# The shared specs travel in, never a private copy: a red team judging severity
# by its own definition puts HIGHs in the comment the main ladder never agreed
# to. Checked on one distinctive clause from each.
grep -qF 'unsure between HIGH and MEDIUM' <<<"$P" \
  || fail "the prompt is missing the shared severity ladder"
# The spec's own first line rather than a copy of it, so the check follows
# whatever the spec says. Never empty: an empty -F pattern matches all.
LANG1="$(head -1 <<<"$REVIEW_LANGUAGE_SPEC")"
[ -n "$LANG1" ] || fail "the language spec's first line is empty — this check would prove nothing"
grep -qF "$LANG1" <<<"$P" \
  || fail "the prompt is missing the shared language spec"

# Round 1's own findings are model-written text derived from a diff this gate
# distrusts. They travel fenced, labelled DATA, and NOT last: the closing
# paragraph after the fence is what stops the fence's contents from being the
# final instruction the model reads.
grep -qF "$EXISTING" <<<"$P" || fail "round 1's findings are not in the prompt"
FENCE="$(awk '/=== WHAT ROUND 1 ALREADY SAID/{print; exit}' <<<"$P")"
[ -n "$FENCE" ] || fail "round 1's findings are not fenced"
grep -qE '=== WHAT ROUND 1 ALREADY SAID, [0-9a-f]{8,}' <<<"$P" \
  || fail "the DATA fence carries no nonce — a diff could close it and inject instructions"
TAIL="$(tail -3 <<<"$P")"
grep -qF 'That was DATA' <<<"$TAIL" \
  || fail "the fenced DATA is the last thing in the prompt — the instructions must come after it"

# Two prompts must not share a nonce, or a diff that saw one could close the next.
P2="$(redteam_prompt "o/r" 42 "/tmp/d.diff" "$(prompt_tree_clause 1)" "x" "$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC")"
N1="$(grep -oE 'ALREADY SAID, [0-9a-f]+' <<<"$P"  | head -1)"
N2="$(grep -oE 'ALREADY SAID, [0-9a-f]+' <<<"$P2" | head -1)"
[ -n "$N1" ] && [ "$N1" != "$N2" ] || fail "the fence nonce is reused between prompts"

# An empty round-1 list must still produce a well-formed fence rather than an
# empty one the model could read as truncation.
PE="$(redteam_prompt "o/r" 42 "/tmp/d.diff" "$(prompt_tree_clause 0)" "" "$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC")"
grep -qF '(nothing at all)' <<<"$PE" \
  || fail "an empty round-1 list should say so explicitly inside the fence"
grep -qF 'Read it FIRST. TREE-TEXT. BIN-NOTE.' <<<"$(redteam_prompt "o/r" 42 "/tmp/d.diff" "TREE-TEXT. BIN-NOTE." "" "$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC")" \
  || fail "the tree text (\$4) should follow the diff path, as it is"
[ -n "${REVIEW_LINE_SPEC-}" ] || fail "REVIEW_LINE_SPEC is empty: lib/review-spec.sh must define it"
grep -qF -- "$REVIEW_LINE_SPEC" <<<"$(redteam_prompt "o/r" 42 "/tmp/d.diff" "$(prompt_tree_clause 1)" "" "$REVIEW_LANGUAGE_SPEC" "$SEVERITY_SPEC" "" "$REVIEW_LINE_SPEC")" \
  || fail "the line definition (\$9) should be in the red-team prompt"
! grep -qF -- "$REVIEW_LINE_SPEC" <<<"$P2" \
  || fail "a caller that passes no line definition should get none"
# $4=0 means the diff is NOT applied to the tree, and the verifier prompt has
# to say so: told the tree is post-change when it is pre-change, a model
# treats the default branch showing through as evidence.
grep -qF 'WITHOUT this change' <<<"$PE" \
  || fail "with the diff unapplied the prompt must say the tree is the BEFORE state"
grep -qF 'AS THIS PR HAS IT' <<<"$P" \
  || fail "with the diff applied the prompt must say line numbers line up"

# ── the wiring in pr-autoreview.sh ────────────────────────────────────────
SRC="$(cat pr-autoreview.sh)"
grep -qF 'redteam_should_run' <<<"$SRC" \
  || fail "pr-autoreview.sh does not gate the stage on redteam_should_run"
# The candidates must be APPENDED before the second round, not posted straight.
RT_LINE="$(grep -n 'Third round: red-team' pr-autoreview.sh | cut -d: -f1)"
V_LINE="$(grep -n 'Second round: try to refute' pr-autoreview.sh | cut -d: -f1)"
[ -n "$RT_LINE" ] && [ -n "$V_LINE" ] || fail "cannot find both round stages in pr-autoreview.sh"
[ "$RT_LINE" -lt "$V_LINE" ] \
  || fail "the red team runs AFTER the refutation pass — its candidates would block unverified"

# The red team must run AFTER convergence,
# not before: if it moved ahead of
# FINDINGS_CONVERGE_JQ, the late cap
# would demote every candidate about a file outside this round's delta — by
# definition almost all of them, since a red-team candidate is something
# earlier rounds missed — silently deleting the whole stage's output while
# run-all.sh still prints ALL PASS. lib/redteam.sh's own comment and
# pr-autoreview.sh's wiring comment both say this in prose; this pins it as
# a line-order fact a future re-ordering cannot get past unnoticed.
CONV_LINE="$(grep -n 'FINDINGS_CONVERGE_JQ" <<<"\$CLEANED"' pr-autoreview.sh | cut -d: -f1)"
[ -n "$CONV_LINE" ] || fail "cannot find the convergence-cap call site in pr-autoreview.sh"
[ "$CONV_LINE" -lt "$RT_LINE" ] \
  || fail "the red team runs BEFORE the convergence caps — its candidates would be late-capped away"

# The fail-open rule, asserted because it is the only one in this repo and the
# next reader's instinct will be to "fix" it into a hold.
grep -qF 'fails OPEN by design' <<<"$SRC" \
  || fail "pr-autoreview.sh must say out loud that the red-team stage fails open"
grep -qF 'fail-open' <<<"$(cat lib/redteam.sh)" \
  || grep -qF 'FAIL-OPEN' <<<"$(cat lib/redteam.sh)" \
  || fail "lib/redteam.sh must document the fail-open exception"

# A refuted CANDIDATE is not a refuted blocker. Conflating the two makes an
# approving comment tell the author round 1 had meant to block.
grep -qF 'N_REFUTED_RT' <<<"$SRC" \
  || fail "pr-autoreview.sh does not separate red-team refutations from round 1's"
grep -qF 'N_REFUTED_R1' <<<"$SRC" \
  || fail "pr-autoreview.sh does not compute the round-1-only refutation count"
# The subtraction itself, not just the variable names, must be pinned:
# a `grep` for N_REFUTED_RT/N_REFUTED_R1
# passes whether the sign, the operand order, or the floor is right or wrong.
# pr-autoreview.sh must call the extracted pure function rather than
# re-deriving the subtraction inline, the same convention redteam_should_run
# and findings_resolve_verdict already follow.
grep -qF 'redteam_refuted_round1_count' <<<"$SRC" \
  || fail "pr-autoreview.sh must compute N_REFUTED_R1 via redteam_refuted_round1_count, not an inline subtraction"
[ "$(redteam_refuted_round1_count 3 3)" = "0" ] \
  || fail "all refuted were red-team candidates -> round-1 count must be 0"
[ "$(redteam_refuted_round1_count 3 1)" = "2" ] \
  || fail "a mix of round-1 and red-team refutations must subtract correctly"
[ "$(redteam_refuted_round1_count 2 0)" = "2" ] \
  || fail "no red-team refutations -> round-1 count is the whole total"
[ "$(redteam_refuted_round1_count 0 0)" = "0" ] \
  || fail "nothing refuted -> round-1 count is 0"
[ "$(redteam_refuted_round1_count 1 3)" = "0" ] \
  || fail "an RT count larger than the total must floor at 0, not go negative"

# The surviving candidate has to be labelled in what the author reads: a HIGH
# appearing in round 3 on a file the delta never touched is otherwise a mystery.
RT_TAG='raised by the red team'
grep -qF "$RT_TAG" <<<"$(cat lib/findings.sh)" \
  || fail "FINDINGS_RENDER_JQ does not annotate a surviving red-team finding"

# ── citation check on red-team candidates ─
# A red-team candidate is a MODEL GUESS about a defect nobody has looked at
# yet — the prompt explicitly invites 0.6-confidence reports — so an invented
# file path is more likely here than in round 1's own findings, and unlike
# round 1's findings nothing else in the pipeline checks the path before the
# fail-open refutation pass. RT_ADD must be run through the same
# FINDINGS_CITATION_JQ round 1's findings already go through.
# Comments stripped before the check: this section's own wiring comment NAMES
# FINDINGS_CITATION_JQ to explain the design, so a grep against the raw text
# would still pass with the actual filter call deleted — checked by mutation,
# not assumed.
RT_SECTION_CODE="$(awk '/Third round: red-team/{f=1} f{print} f&&/Second round: try to refute/{exit}' pr-autoreview.sh \
                   | grep -vE '^[[:space:]]*#')"
grep -qF 'findings_cite' <<<"$RT_SECTION_CODE" \
  || fail "the red-team candidate block does not citation-check RT_ADD — an invented file path reaches the refutation pass unchecked"
grep -qE 'RT_ADD="\$\(findings_cite ' <<<"$RT_SECTION_CODE" \
  || fail "RT_ADD must be run through findings_cite in actual code, not just mentioned near it"

# The mechanism itself: REDTEAM_CANDIDATES_JQ produces the candidate shape,
# then FINDINGS_CITATION_JQ (wrapped/unwrapped as pr-autoreview.sh does it)
# must keep a candidate citing a KNOWN path and drop one citing an invented
# path — exercised directly, not just grepped for, so a broken wrap/unwrap
# (wrong key, wrong argjson name) fails this even though the grep above would
# still pass.
RAW='{"candidates":[
  {"severity":"HIGH","file":"real.py","line":3,"issue":"real problem"},
  {"severity":"HIGH","file":"invented/nonexistent.py","line":9,"issue":"model guess"}]}'
CANDS="$(jq -c --argjson max 3 "$REDTEAM_CANDIDATES_JQ" <<<"$RAW")"
KNOWN='["real.py"]'
FILTERED="$(jq -c --argjson known "$KNOWN" "$FINDINGS_CITATION_JQ" <<<"{\"findings\":$CANDS}" | jq -c '.findings')"
[ "$(jq -r 'length' <<<"$FILTERED")" = 1 ] \
  || fail "citation-checking red-team candidates should drop the invented path and keep the real one"
[ "$(jq -r '.[0].file' <<<"$FILTERED")" = "real.py" ] \
  || fail "citation-checking red-team candidates kept the wrong candidate"
# ── shape 5 gets an index, not an instruction to go searching ─────────────
#
# A sentence telling the stage to look for the repo's own spec was not enough:
# the step that never happened was opening the spec. The index is the lever;
# the prompt asking harder was not.
TT="$(mktemp -d)"
trap 'rm -rf "$TT"' EXIT
git -C "$TT" init -q 2>/dev/null || fail "cannot init a fixture repo"
mkdir -p "$TT/docs" "$TT/node_modules/pkg" "$TT/.claude/skills" "$TT/src"
: > "$TT/docs/style-guide.md"
: > "$TT/README.md"
: > "$TT/src/app.py"
: > "$TT/node_modules/pkg/readme.md"
: > "$TT/.claude/skills/code-style.md"
git -C "$TT" add README.md docs/style-guide.md src/app.py 2>/dev/null

IDX="$(redteam_spec_index "$TT")"
grep -qx 'docs/style-guide.md' <<<"$IDX" || fail "the spec index misses docs/*.md — a spec the repo pins often lives there"
grep -qx 'README.md' <<<"$IDX"            || fail "the spec index misses a top-level document"
# Untracked counts: a convention file kept in the checkout but out of git is
# still where a repo writes its rules.
grep -qx '.claude/skills/code-style.md' <<<"$IDX" \
  || fail "the spec index skips untracked files — a repo's conventions can live there"
# An untracked CLAUDE.md can also be listed in .git/info/exclude, and
# `--exclude-standard` honours .git/info/exclude as well as .gitignore, so
# a listing built on it would silently drop the file from the index.
printf 'CLAUDE.md\n' >> "$TT/.git/info/exclude"
: > "$TT/CLAUDE.md"
grep -qx 'CLAUDE.md' <<<"$(redteam_spec_index "$TT")" \
  || fail "the spec index drops a file hidden via .git/info/exclude"
grep -q 'node_modules' <<<"$IDX" && fail "the spec index includes node_modules — dependency docs are not this repo's spec"
grep -q 'src/app.py'   <<<"$IDX" && fail "the spec index includes source files — it is a document list, not a tree dump"

# A cap, because the list rides inside a prompt.
: > "$TT/docs/a.md"; : > "$TT/docs/b.md"; : > "$TT/docs/c.md"
[ "$(redteam_spec_index "$TT" 2 | wc -l | tr -d ' ')" = "2" ] || fail "the spec index ignores its cap"

# ── REDTEAM_SPEC_MAX sanitisation ────
# Same shape as the REDTEAM_MAX sanitisation tested above, and the same
# reason it matters: unlike REDTEAM_MAX, REDTEAM_SPEC_MAX used to be set from
# PRREVIEW_GATE_REDTEAM_SPEC_MAX with NO source-time sanitisation, so
# redteam_spec_index's own fallback (`case "$max" in ''|*[!0-9]*) max=
# "$REDTEAM_SPEC_MAX" ;; esac`) just reassigned the SAME unsanitised value —
# `PRREVIEW_GATE_REDTEAM_SPEC_MAX=abc` in a hand-written settings file reached
# `head -n "abc"`, head errored, and the whole document index came back
# empty with no sign anything had gone wrong. A test that only exercised a
# numeric override (the cap test just above) could not catch that.
for bad in abc 0 ""; do
  SPECMAX_OUT="$(PRREVIEW_GATE_REDTEAM_SPEC_MAX="$bad" bash -c '
    . ./lib/findings.sh >/dev/null 2>&1
    . ./lib/redteam.sh   >/dev/null 2>&1
    printf "%s" "$REDTEAM_SPEC_MAX"')"
  [ "$SPECMAX_OUT" = "80" ] \
    || fail "PRREVIEW_GATE_REDTEAM_SPEC_MAX='$bad' should sanitise to 80, got '$SPECMAX_OUT'"
done
# And the index itself must still produce output under the bad value — the
# actual symptom this MEDIUM is about, not just the sanitised number.
SPECMAX_IDX="$(PRREVIEW_GATE_REDTEAM_SPEC_MAX=abc bash -c '
  . ./lib/findings.sh >/dev/null 2>&1
  . ./lib/redteam.sh   >/dev/null 2>&1
  redteam_spec_index "'"$TT"'"')"
[ -n "$SPECMAX_IDX" ] \
  || fail "PRREVIEW_GATE_REDTEAM_SPEC_MAX=abc silently empties the whole document index"
# A valid override must survive untouched.
SPECMAX_OUT="$(PRREVIEW_GATE_REDTEAM_SPEC_MAX=7 bash -c '
  . ./lib/findings.sh >/dev/null 2>&1
  . ./lib/redteam.sh   >/dev/null 2>&1
  printf "%s" "$REDTEAM_SPEC_MAX"')"
[ "$SPECMAX_OUT" = "7" ] || fail "a valid PRREVIEW_GATE_REDTEAM_SPEC_MAX=7 should not be sanitised away, got '$SPECMAX_OUT'"

# redteam_spec_total_count reports the UNCAPPED count — the number
# redteam_prompt needs to tell whether the list it shows is everything or a
# cut.
EXPECT_TOTAL="$(redteam_spec_candidates "$TT" | sort -u | wc -l | tr -d ' ')"
[ "$(redteam_spec_total_count "$TT")" = "$EXPECT_TOTAL" ] \
  || fail "the total count does not match the tree — got $(redteam_spec_total_count "$TT"), expected $EXPECT_TOTAL"
[ "$(redteam_spec_total_count "$TT")" -gt "$(redteam_spec_index "$TT" 2 | wc -l | tr -d ' ')" ] \
  || fail "the total count must exceed a cap that is actually cutting something, or this assertion proves nothing"

# redteam_prompt says so when the cap actually cut something — a missing
# document a reader cannot tell apart from "this repo just doesn't have one".
REDTEAM_SPEC_MAX_SAVE="$REDTEAM_SPEC_MAX"
REDTEAM_SPEC_MAX=2
P_TRUNC="$(redteam_prompt repo 1 /dev/null 1 '' '' '' "$TT")"
grep -q 'more matching document(s) exist' <<<"$P_TRUNC" \
  || fail "a truncated spec index does not tell the model anything was cut"
REDTEAM_SPEC_MAX=80
P_FULL="$(redteam_prompt repo 1 /dev/null 1 '' '' '' "$TT")"
grep -q 'more matching document(s) exist' <<<"$P_FULL" \
  && fail "a spec index that was NOT truncated still claims documents were cut"
REDTEAM_SPEC_MAX="$REDTEAM_SPEC_MAX_SAVE"

# A tree that cannot be listed degrades to the measured behaviour, not an error.
[ -z "$(redteam_spec_index "$TT/does-not-exist")" ] || fail "a missing tree should yield no index"
redteam_spec_index "$TT/does-not-exist" >/dev/null 2>&1 || fail "a missing tree must not fail the caller"

# In the prompt the index is DATA behind the same nonce fence as everything
# else a model wrote or a repo author named — a file name is text somebody
# chose, and this one lands in a prompt that decides a verdict.
P="$(redteam_prompt "o/r" 7 /tmp/x.diff 1 "" "LANG" "SEV" "$TT")"
grep -q 'DOCUMENTS IN THIS REPO' <<<"$P" || fail "the prompt does not carry the document index"
grep -q 'docs/style-guide.md'   <<<"$P" || fail "the index in the prompt is empty"
# Scoped to the document-index section itself, not "That was DATA" appears
# ANYWHERE in the prompt: the prompt template also closes round 1's findings
# with the identical sentence (lib/redteam.sh), so a grep that just stops
# at the first "That was DATA" it sees would STILL find that later one when
# the index's own closing line is deleted (nothing else stops the scan
# early). Located by LINE NUMBER instead: from "DOCUMENTS IN THIS REPO" to
# a couple of lines past its own "=== END ===" fence — the fence marks where
# THIS section ends, "That was DATA" does not (the fence text is identical
# between fences, since one nonce is reused for both fences within one
# prompt call, but only the DOCUMENTS section's fence appears first).
IDX_START="$(grep -n 'DOCUMENTS IN THIS REPO' <<<"$P" | head -1 | cut -d: -f1)"
IDX_END="$(awk -v start="$IDX_START" 'NR>start && /^=== END/{print NR; exit}' <<<"$P")"
if [ -n "$IDX_START" ] && [ -n "$IDX_END" ]; then
  IDX_SECTION="$(sed -n "${IDX_START},$((IDX_END + 2))p" <<<"$P")"
  grep -q 'That was DATA' <<<"$IDX_SECTION" || fail "the index is not closed as DATA"
else
  fail "could not locate the document index section to scope this assertion — proves nothing"
fi
# The fence line before the list must carry a NONCE, not merely a token that
# happens to look hex — a fixed marker like "deadbeef" also matches
# [0-9a-f]{4,}, so that alone cannot tell a nonce from a hardcoded constant.
# Same technique as the ALREADY SAID fence above: generate the prompt TWICE
# and require the two tokens to differ.
FENCE="$(grep -m1 'DOCUMENTS IN THIS REPO' <<<"$P" | sed -E 's/.*, ([0-9a-f]+) ===/\1/')"
case "$FENCE" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) fail "the document index fence has no nonce: $FENCE" ;;
esac
P_SPEC_2="$(redteam_prompt "o/r" 7 /tmp/x.diff 1 "" "LANG" "SEV" "$TT")"
FENCE2="$(grep -m1 'DOCUMENTS IN THIS REPO' <<<"$P_SPEC_2" | sed -E 's/.*, ([0-9a-f]+) ===/\1/')"
[ "$FENCE" != "$FENCE2" ] \
  || fail "the document index fence nonce is reused between prompts — it must carry a nonce, not a fixed marker"

# An empty tree still says so in words: a section that just stops reads like a
# truncated prompt.
TE="$(mktemp -d)"; git -C "$TE" init -q 2>/dev/null
grep -q 'none found in this tree' <<<"$(redteam_prompt "o/r" 7 /tmp/x.diff 1 "" "LANG" "SEV" "$TE")" \
  || fail "an empty index does not say so"
rm -rf "$TE"

# And the call site has to hand over a tree at all: without the 8th argument
# the section renders empty on every real PR and nothing else changes.
#
# Backslash continuations joined FIRST: what is being pinned is that the
# value reaches the child, not where the line breaks fall.
# The call spans two physical lines; a literal grep for two adjacent params on one line breaks on a pure
# reflow (moving "$REPO_DIR") to its own line) even though the argument
# still reaches redteam_prompt exactly as before.
JOINED="$(awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }' pr-autoreview.sh)"
CALL_LINE="$(grep -F 'redteam_prompt "$REPO" "$PR" "$DIFF_VIEW" "$TREE_CLAUSE$STACKED_CLAUSE" "$RT_PRIOR"' <<<"$JOINED")"
[ -n "$CALL_LINE" ] || fail "pr-autoreview.sh's redteam_prompt call site was not found — this assertion proves nothing"
[ -n "$CALL_LINE" ] && grep -qF '"$SEVERITY_SPEC" "$REPO_DIR" ' <<<"$CALL_LINE" \
  || fail "pr-autoreview.sh does not pass the review tree to redteam_prompt"

# The tree text. The red team and the verifier read the same tree as the main
# review, so they get the same description of it. Before, each got a text of
# its own, chosen on DIFF_APPLIED alone. For a stacked PR on its parent branch
# (TREE_AT=base) that text was false in both apply states. Each line below is
# lifted from pr-autoreview.sh and run, once for each tree state, on a
# stacked PR.
TC_SRC="$(grep -E '^  TREE_CLAUSE="\$\(prompt_tree_clause ' pr-autoreview.sh)"
SC_SRC="$(grep -E '^    STACKED_CLAUSE="\$\(prompt_stacked_clause ' pr-autoreview.sh)"
RV_SRC="$(grep -F 'The diff you are reviewing is in $SLICE_VIEW' pr-autoreview.sh)"
RT_ARGS="$(sed -n 's/.*"\$(redteam_prompt \([^)]*\))".*/\1/p' <<<"$JOINED")"
VF_ARGS="$(sed -n 's/.*"\$(findings_verify_prompt \([^)]*\))".*/\1/p' <<<"$JOINED")"
[ -n "$TC_SRC" ] && [ -n "$SC_SRC" ] && [ -n "$RV_SRC" ] && [ -n "$RT_ARGS" ] && [ -n "$VF_ARGS" ] \
  || fail "could not lift the tree clause, the stacked clause, the review prompt line, the red-team call or the verify call out of pr-autoreview.sh"
# shellcheck disable=SC2034  # read by the eval'd lines
{ REPO=o/r PR=42 DIFF_VIEW=/tmp/d.view RT_PRIOR="" REPO_DIR="$TE" DEFAULT_BRANCH=main
  SLICE_VIEW=/tmp/d.view REPO_CONTEXT=CTX INTENT_CLAUSE="" SLICE_CLAUSE=""
  TREE_CONV_NOTE="" TREE_BIN_NOTE=" BIN-NOTE."
  V_SEV=HIGH V_FILE=a.py V_LINE=1 V_ISSUE=x; }
for st in "1 base" "0 base" "0 default"; do
  # shellcheck disable=SC2034  # read by the eval'd lines
  DIFF_APPLIED="${st% *}" TREE_AT="${st#* }"
  eval "$TC_SRC"; eval "$SC_SRC"
  RV="$(eval "printf '%s' \"$RV_SRC\"")"
  RT="$(eval "redteam_prompt $RT_ARGS")"
  TC="$(prompt_tree_clause "$DIFF_APPLIED" "$TREE_AT")"
  grep -qF -- "$TC$TREE_BIN_NOTE$STACKED_CLAUSE" <<<"$RV" \
    || fail "tree state '$st': the review prompt does not carry the tree text this test expects"
  grep -qF -- "$TC$TREE_BIN_NOTE$STACKED_CLAUSE" <<<"$RT" \
    || fail "tree state '$st': the red-team prompt does not carry the review prompt's tree text"
  VF="$(eval "findings_verify_prompt $VF_ARGS")"
  grep -qF -- "$TC$TREE_BIN_NOTE$STACKED_CLAUSE" <<<"$VF" \
    || fail "tree state '$st': the verify prompt does not carry the review prompt's tree text"
done

echo "PASS"
