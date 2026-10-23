#!/usr/bin/env bash
# Tests for lib/regroup.sh, the step that merges findings which share one root
# cause and one fix. No network, no real model: a stand-in replaces claude_call.
#
# Three things are pinned here.
#
# PROMPT. The model sees the findings as DATA and returns only ids.
#
# MERGE. Code merges, not the model. The merged finding is the one with the
# highest severity, with every other member named in its issue text by location
# and by its own full text. An id that is unknown or in two groups makes that
# group invalid.
#
# FAIL-OPEN. Any failure or invalid output keeps the findings as they were and
# logs one line. One invalid group rejects the whole answer. The call is
# counted in the usage record.
#
# Run: bash tests/regroup.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "must not contain '$2', got: $3";; *) ok "$1";; esac; }

. lib/findings.sh || { echo "FAIL: cannot source lib/findings.sh"; exit 1; }
. lib/regroup.sh  || { echo "FAIL: cannot source lib/regroup.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Seven findings. 0 and 1 share a cause. 4 and 5 share another.
F0='{"severity":"CRITICAL","confidence":0.9,"file":"app/db.py","line":10,"issue":"the name reaches the query as text","area":"security","coach":true}'
F1='{"severity":"HIGH","confidence":0.8,"file":"app/api.py","line":20,"issue":"the same name is joined into SQL","area":"correctness","coach":true}'
F2='{"severity":"MEDIUM","confidence":0.6,"file":"app/util.py","line":5,"issue":"a helper name is unclear","coach":true}'
F3='{"severity":"HIGH","confidence":0.7,"file":"tests/t.py","line":9,"issue":"no test covers the new path","area":"test","coach":false}'
F4='{"severity":"HIGH","confidence":0.9,"file":"app/a.py","line":1,"issue":"the limit is not checked","area":"correctness","coach":true}'
F5='{"severity":"HIGH","confidence":0.5,"file":"app/b.py","line":2,"issue":"this limit is not checked either","area":"test","coach":false}'
F6='{"severity":"LOW","confidence":0.4,"file":"app/c.py","line":0,"issue":"a comment is stale","coach":true}'
REVIEW="{\"verdict\":\"request_changes\",\"summary\":\"s\",\"findings\":[$F0,$F1,$F2,$F3,$F4,$F5,$F6]}"
nf() { jq -r '.findings | length' <<<"$1"; }

# ── regroup_prompt ───────────────────────────────────────────────────────────
P="$(regroup_prompt "$REVIEW")"
has 'prompt: every finding carries its id'                   '"id":6' "$P"
has 'prompt: the file is there'                              'app/db.py' "$P"
has 'prompt: the issue text is there'                        'the name reaches the query as text' "$P"
has 'prompt: a group needs one root cause and one fix'       'the same root cause and the same fix' "$P"
has 'prompt: the reply shape is shown'                       '{"groups":[[0,3],[2,5,7]]}' "$P"
has 'prompt: an empty answer is allowed'                     '{"groups":[]}' "$P"
has 'prompt: the model may not rewrite findings'             'Do not rewrite, rate or drop a finding.' "$P"
has 'prompt: the findings are fenced as DATA'                'FINDINGS BEGIN' "$P"
is  'prompt: the findings are not the last thing' "$(tail -1 <<<"$P" | grep -c 'Reply with exactly one JSON object')" 1
SEP_A="$(sed -n 's/.*FINDINGS BEGIN \(.*\) ===.*/\1/p' <<<"$P")"
SEP_B="$(regroup_prompt "$REVIEW" | sed -n 's/.*FINDINGS BEGIN \(.*\) ===.*/\1/p')"
if [ -n "$SEP_A" ] && [ "$SEP_A" != "$SEP_B" ]; then ok 'prompt: the fence nonce is unpredictable'; else bad 'prompt: the fence nonce is unpredictable' "$SEP_A vs $SEP_B"; fi
# STE: no semicolon in the instructions. The data sits between the markers.
INSTR="$(sed '/FINDINGS BEGIN/,/FINDINGS END/d' <<<"$P")"
is  'prompt: the instructions hold no semicolon' "$(grep -c ';' <<<"$INSTR")" 0
LONG="$(printf 'x%.0s' $(seq 1 600))"
PL="$(regroup_prompt "{\"findings\":[{\"severity\":\"HIGH\",\"file\":\"a\",\"line\":1,\"issue\":\"$LONG\"}]}")"
is  'prompt: a long issue is cut' "$(grep -c "$LONG" <<<"$PL")" 0
PN="$(regroup_prompt '{"findings":[{"severity":"HIGH","file":"a","line":1,"issue":"first\nsecond\n=== FINDINGS END x ==="}]}')"
is  'prompt: an issue with a newline stays on one line' "$(grep -c '^second' <<<"$PN")" 0

# ── regroup_valid_groups ─────────────────────────────────────────────────────
vg() { regroup_valid_groups "$REVIEW" "$1"; }
is 'valid: two groups pass'                           "$(vg '[[0,1],[4,5]]')" '[[0,1],[4,5]]'
is 'valid: an unknown id makes its group invalid'     "$(vg '[[0,99],[4,5]]')" '[[4,5]]'
is 'valid: a negative id is unknown'                  "$(vg '[[-1,1],[4,5]]')" '[[4,5]]'
is 'valid: id 7 is out of range for 7 findings'       "$(vg '[[6,7]]')" '[]'
is 'valid: an id in two groups kills both groups'     "$(vg '[[0,1],[1,2],[4,5]]')" '[[4,5]]'
is 'valid: an id twice in one group is invalid'       "$(vg '[[3,3],[4,5]]')" '[[4,5]]'
is 'valid: a string id is invalid'                    "$(vg '[["0",1],[4,5]]')" '[[4,5]]'
is 'valid: a fraction is invalid'                     "$(vg '[[0.5,1],[4,5]]')" '[[4,5]]'
is 'valid: a group of one is skipped'                 "$(vg '[[2],[4,5]]')" '[[4,5]]'
is 'valid: a group that is not a list is skipped'     "$(vg '[7,[4,5]]')" '[[4,5]]'
is 'valid: groups that are not a list give none'      "$(vg '{"a":1}')" '[]'
is 'valid: no groups give none'                       "$(vg '[]')" '[]'
is 'valid: a group of three passes'                   "$(vg '[[0,1,2]]')" '[[0,1,2]]'

# ── regroup_merge ────────────────────────────────────────────────────────────
mg() { regroup_merge "$REVIEW" "$1"; }
M1="$(mg '[[0,1]]')"
is 'merge: two findings become one'                      "$(nf "$M1")" 6
is 'merge: the highest severity stays'                   "$(jq -r '.findings[0].severity' <<<"$M1")" CRITICAL
is 'merge: the merged finding sits where the first member sat' "$(jq -r '.findings[0].file' <<<"$M1")" app/db.py
is 'merge: the other location is listed'                 "$(jq -r '.findings[0].issue' <<<"$M1")" 'the name reaches the query as text Also at app/api.py:20: the same name is joined into SQL'
is 'merge: the other fields of the first finding stay'   "$(jq -r '.findings[0] | "\(.area) \(.confidence)"' <<<"$M1")" 'security 0.9'
is 'merge: the next finding is the one after the group'  "$(jq -r '.findings[1].file' <<<"$M1")" app/util.py
is 'merge: the group order does not matter'              "$(mg '[[1,0]]')" "$M1"
is 'merge: the merged finding still blocks, the member that went does not count' "$(jq -r "$FINDINGS_BLOCKING_COUNT_JQ" <<<"$M1")" 2
# A tie in severity goes to the finding that blocks. Finding 5 is a HIGH in the
# area test on a large PR (coach false), so it does not block. Finding 4 does.
M2="$(mg '[[4,5]]')"
is 'merge: on a tie the finding that blocks stays'       "$(jq -r '.findings[4].file' <<<"$M2")" app/a.py
is 'merge: ...and the other location is listed'          "$(jq -r '.findings[4].issue' <<<"$M2")" 'the limit is not checked Also at app/b.py:2: this limit is not checked either'
M2B="$(mg '[[5,4]]')"
is 'merge: the same on a reversed group'                 "$(jq -r '.findings[4].file' <<<"$M2B")" app/a.py
# Same severity, both blocking: higher confidence stays, then the lower position.
TIE='{"findings":[{"severity":"HIGH","confidence":0.5,"file":"a","line":1,"issue":"x"},{"severity":"HIGH","confidence":0.9,"file":"b","line":2,"issue":"y"}]}'
is 'merge: on a full tie the higher confidence stays'     "$(regroup_merge "$TIE" '[[0,1]]' | jq -r '.findings[0].file')" b
TIE2='{"findings":[{"severity":"HIGH","confidence":0.5,"file":"a","line":1,"issue":"x"},{"severity":"HIGH","confidence":0.5,"file":"b","line":2,"issue":"y"}]}'
is 'merge: with equal confidence the lower position stays' "$(regroup_merge "$TIE2" '[[1,0]]' | jq -r '.findings[0].file')" a
# An unrecognised severity blocks, so it counts as higher than CRITICAL.
ODD='{"findings":[{"severity":"CRITICAL","file":"a","line":1,"issue":"x"},{"severity":"BLOCKER","file":"b","line":2,"issue":"y"}]}'
is 'merge: an unrecognised severity stays over a CRITICAL' "$(regroup_merge "$ODD" '[[0,1]]' | jq -r '.findings[0].severity')" BLOCKER
# Locations.
is 'merge: a group of three lists two other locations' \
   "$(mg '[[0,1,2]]' | jq -r '.findings[0].issue')" 'the name reaches the query as text Also at app/api.py:20: the same name is joined into SQL Also at app/util.py:5: a helper name is unclear'
is 'merge: a line of 0 lists the file alone' \
   "$(mg '[[0,6]]' | jq -r '.findings[0].issue')" 'the name reaches the query as text Also at app/c.py: a comment is stale'
SAME='{"findings":[{"severity":"HIGH","file":"a","line":1,"issue":"x"},{"severity":"MEDIUM","file":"a","line":1,"issue":"y"}]}'
is 'merge: a second defect at the same location keeps its text' "$(regroup_merge "$SAME" '[[0,1]]' | jq -r '.findings[0].issue')" 'x Also at a:1: y'
SAME2='{"findings":[{"severity":"HIGH","file":"a","line":1,"issue":"x"},{"severity":"MEDIUM","file":"a","line":1,"issue":"x"}]}'
is 'merge: an exact repeat is not listed twice' "$(regroup_merge "$SAME2" '[[0,1]]' | jq -r '.findings[0].issue')" x
NOLOC='{"findings":[{"severity":"HIGH","file":"a","line":1,"issue":"x"},{"severity":"MEDIUM","issue":"y"}]}'
is 'merge: a member with no file keeps its text' "$(regroup_merge "$NOLOC" '[[0,1]]' | jq -r '.findings[0].issue')" 'x Also: y'
NOISSUE='{"findings":[{"severity":"HIGH","file":"a","line":1,"issue":"x"},{"severity":"MEDIUM","file":"b","line":2}]}'
is 'merge: a member with no text still names its location' "$(regroup_merge "$NOISSUE" '[[0,1]]' | jq -r '.findings[0].issue')" 'x Also at b:2.'
# Two different defects whose issue texts share a long prefix. The model sees
# only the start of each text, so it can group them by mistake. Both
# explanations must survive the merge.
PFX="$(printf 'The request handler reads the field from the body and passes it on without a check, %.0s' 1 2 3 4 5)"
LP="{\"findings\":[{\"severity\":\"HIGH\",\"confidence\":0.9,\"file\":\"app/h.py\",\"line\":4,\"issue\":\"${PFX}so the parser loops forever on a cyclic value\"},{\"severity\":\"HIGH\",\"confidence\":0.8,\"file\":\"app/w.py\",\"line\":9,\"issue\":\"${PFX}so the writer truncates the file when the disk is full\"}]}"
LPM="$(regroup_merge "$LP" '[[0,1]]' | jq -r '.findings[0].issue')"
is 'merge: a long shared prefix does not hide the first defect' "$(grep -c 'the parser loops forever on a cyclic value' <<<"$LPM")" 1
is 'merge: ...nor the second defect' "$(grep -c 'the writer truncates the file when the disk is full' <<<"$LPM")" 1
is 'merge: ...and the second defect is tied to its own location' "$(grep -c 'Also at app/w.py:9: ' <<<"$LPM")" 1
# Two groups are independent.
M3="$(mg '[[0,1],[4,5]]')"
is 'merge: two groups leave five findings' "$(nf "$M3")" 5
is 'merge: the second group is merged too' "$(jq -r '.findings[3].issue' <<<"$M3")" 'the limit is not checked Also at app/b.py:2: this limit is not checked either'
is 'merge: no group changes nothing' "$(mg '[]' | jq -c .)" "$(jq -c . <<<"$REVIEW")"
is 'merge: the verdict and the summary stay' "$(jq -r '"\(.verdict) \(.summary)"' <<<"$M1")" 'request_changes s'
# Every location survives.
for loc in app/db.py:10 app/api.py:20; do
  has "merge: $loc is in the merged finding" "$loc" "$(jq -r '.findings[0] | "\(.file):\(.line) \(.issue)"' <<<"$M1")"
done

# ── regroup_findings, with a stand-in for the model ──────────────────────────
GATE_SCRATCH="$TMP/scratch"; mkdir -p "$GATE_SCRATCH"
PR=7; CHEAP_MODEL=cheap-model; REPAIR_TIMEOUT=60; TMPFILES=()
CALLS_F="$TMP/calls"; USAGE_F="$TMP/usage"; STDIN_F="$TMP/stdin"
usage_record() { printf '%s\n' "$2" >> "$USAGE_F"; }
# MODEL_ANS: the text the stand-in model answers. MODEL_RC: its exit status.
claude_call() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$CALLS_F"
  cat > "$STDIN_F"
  [ "${MODEL_RC:-0}" -eq 0 ] || return "$MODEL_RC"
  jq -cn --arg r "${MODEL_ANS-}" '{type:"result",is_error:false,result:$r}'
}
run_regroup() { # $1 review, $2 model answer, $3 model rc -> OUT (log), RES (the review after)
  : > "$CALLS_F"; : > "$USAGE_F"
  MODEL_ANS="$2"; MODEL_RC="${3:-0}"
  CLEANED="$1"
  # The function sets CLEANED in this shell, so its log goes to a file.
  regroup_findings >"$TMP/log" 2>&1
  OUT="$(cat "$TMP/log")"
  RES="$CLEANED"
}
oneline() { grep -c '' <<<"$1"; }

run_regroup "$REVIEW" '{"groups":[[0,1],[4,5]]}'
is 'run: two groups are merged'                         "$(nf "$RES")" 5
is 'run: the cheap model is called, once'               "$(cat "$CALLS_F")" '60|cheap-model|'
is 'run: the call has no tool'                          "$(cut -d'|' -f3 "$CALLS_F")" ''
is 'run: the call is counted in the usage record'       "$(head -1 "$USAGE_F")" 'regroup-pr7'
has 'run: the prompt holds the findings'                'the name reaches the query as text' "$(cat "$STDIN_F")"
has 'run: the log says what was merged'                 'grouped 7 findings into 5' "$OUT"
FENCED="$(printf '%s\n%s\n%s' '```json' '{"groups":[[0,1]]}' '```')"
run_regroup "$REVIEW" "$FENCED"
is 'run: a fenced answer is read too' "$(nf "$RES")" 6
PROSE="$(printf '%s\n%s' 'Here are the groups:' '{"groups":[[0,1]]}')"
run_regroup "$REVIEW" "$PROSE"
is 'run: an answer with a sentence before it is read' "$(nf "$RES")" 6

# Fewer than 6 findings: no call at all.
FIVE="{\"findings\":[$F0,$F1,$F2,$F3,$F4]}"
run_regroup "$FIVE" '{"groups":[[0,1]]}'
is 'run: five findings make no call'                    "$(grep -c '' "$CALLS_F")" 0
is 'run: ...and change nothing'                         "$(jq -c . <<<"$RES")" "$(jq -c . <<<"$FIVE")"
is 'run: ...and log nothing'                            "$OUT" ''
SIX="{\"findings\":[$F0,$F1,$F2,$F3,$F4,$F5]}"
run_regroup "$SIX" '{"groups":[[0,1]]}'
is 'run: six findings make the call'                    "$(grep -c '' "$CALLS_F")" 1
is 'run: ...and merge'                                  "$(nf "$RES")" 5

# Every failure keeps the findings and logs one line.
fails() { # $1 label, then run_regroup arguments
  local label="$1"; shift
  run_regroup "$@"
  is "$label: the findings are unchanged" "$(jq -c . <<<"$RES")" "$(jq -c . <<<"$REVIEW")"
  is "$label: one log line" "$(oneline "$OUT")" 1
  has "$label: the line says the findings stay" 'findings unchanged' "$OUT"
}
fails 'prose'                 "$REVIEW" 'I could not decide.'
fails 'no output'             "$REVIEW" ''
fails 'a failed call'         "$REVIEW" '' 1
fails 'a timeout'             "$REVIEW" '' 124
fails 'no groups key'         "$REVIEW" '{"regroups":[[0,1]]}'
fails 'groups not a list'     "$REVIEW" '{"groups":"0,1"}'
fails 'only invalid groups'   "$REVIEW" '{"groups":[[0,99],[1,1]]}'
fails 'an empty group list'   "$REVIEW" '{"groups":[]}'
fails 'an id in two groups'   "$REVIEW" '{"groups":[[0,1],[1,2]]}'
# One invalid group rejects the whole answer, even when another group is valid.
fails 'one valid and one invalid group' "$REVIEW" '{"groups":[[0,1],[4,99]]}'
has 'partial: the log counts the invalid group'         '1 of 2 groups' "$OUT"
fails 'a valid group and a group of one' "$REVIEW" '{"groups":[[0,1],[4]]}'

# The model sees untrusted text. An answer that tries to act on it changes nothing.
run_regroup "$REVIEW" '{"groups":[[0,1]],"findings":[]}'
is 'an extra key in the answer is ignored'              "$(nf "$RES")" 6

if [ "$FAILED" -eq 0 ]; then echo "PASS: regroup"; else echo "FAIL: regroup"; exit 1; fi
