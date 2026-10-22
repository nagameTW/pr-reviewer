#!/usr/bin/env bash
# Tests for lib/chunk.sh, plus the per-slice tally in pr-autoreview.sh that
# decides SLICE_INCOMPLETE (the last block below). No gh, no network, no model.
# Run: bash tests/chunk.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. lib/chunk.sh || { echo "FAIL: cannot source lib/chunk.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
is() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$3" "$2"; FAILED=1; fi
}

# A small but realistic unified diff: one modified file, one added file, one
# deleted file (where +++ is /dev/null and the path only exists on the ---
# line), and one path with a space in it (the case the `diff --git` header
# cannot be parsed for).
cat > "$TMP/d.diff" <<'EOF'
diff --git a/lib/a.py b/lib/a.py
index 111..222 100644
--- a/lib/a.py
+++ b/lib/a.py
@@ -1,3 +1,4 @@
 keep
-old one
-old two
+new one
+new two
+new three
diff --git a/lib/new.py b/lib/new.py
new file mode 100644
index 000..333
--- /dev/null
+++ b/lib/new.py
@@ -0,0 +1,2 @@
+added a
+added b
diff --git a/lib/gone.py b/lib/gone.py
deleted file mode 100644
index 444..000
--- a/lib/gone.py
+++ /dev/null
@@ -1,1 +0,0 @@
-was here
diff --git a/lib/old_name.py b/lib/new_name.py
similarity index 90%
rename from lib/old_name.py
rename to lib/new_name.py
index 777..888 100644
--- a/lib/old_name.py
+++ b/lib/new_name.py
@@ -1,1 +1,1 @@
-renamed before
+renamed after
diff --git a/docs/with space.md b/docs/with space.md
index 555..666 100644
--- a/docs/with space.md
+++ b/docs/with space.md
@@ -1,1 +1,1 @@
-before
+after
EOF

mkdir -p "$TMP/parts"
SPLIT="$(chunk_split "$TMP/d.diff" "$TMP/parts")"

is 'split: one part per changed file' "$(printf '%s\n' "$SPLIT" | grep -c .)" '5'
# A byte that is not UTF-8 in the diff, under the UTF-8 locale the loop sets:
# macOS awk used to stop at it, and the split fell back to one pass.
printf 'diff --git a/a.txt b/a.txt\n+++ b/a.txt\n@@ -0,0 +1 @@\n+na\351ve\ndiff --git a/b.txt b/b.txt\n+++ b/b.txt\n@@ -0,0 +1 @@\n+ok\n' > "$TMP/latin.diff"
mkdir -p "$TMP/latin-parts"
is 'split: a byte that is not UTF-8 does not stop the split' \
   "$(LC_ALL=C.UTF-8 chunk_split "$TMP/latin.diff" "$TMP/latin-parts" | grep -c .)" '2'
# A RENAME is the case a "first path wins" reader gets backwards: `--- a/old`
# arrives before `+++ b/new`, so the file gets labelled with the name it no
# longer has, and every consumer (the slice's file list, the unreviewed list,
# the model's own sense of what it is reading) inherits the wrong name.
is 'split: a rename is labelled with the NEW path, not the old one' \
   "$(awk -F'\t' 'NR==4 {print $3}' <<<"$SPLIT")" 'lib/new_name.py'
is 'split: changed lines counted without the +++/--- headers' \
   "$(awk -F'\t' 'NR==1 {print $1}' <<<"$SPLIT")" '5'
is 'split: an added file counts only its added lines' \
   "$(awk -F'\t' 'NR==2 {print $1}' <<<"$SPLIT")" '2'
is 'split: a deleted file is still one part' \
   "$(awk -F'\t' 'NR==3 {print $1}' <<<"$SPLIT")" '1'
is 'split: path comes off +++ b/, not the diff --git header' \
   "$(awk -F'\t' 'NR==1 {print $3}' <<<"$SPLIT")" 'lib/a.py'
is 'split: a deleted file takes its path from --- a/' \
   "$(awk -F'\t' 'NR==3 {print $3}' <<<"$SPLIT")" 'lib/gone.py'
# The reason the path is not read off `diff --git a/x b/x`: that line is
# genuinely ambiguous when the name contains a space, and real repos have
# such names.
is 'split: a path with a space survives intact' \
   "$(awk -F'\t' 'NR==5 {print $3}' <<<"$SPLIT")" 'docs/with space.md'

# Every part must be reassemblable into the original diff, or a slice is
# reviewing something that is not what the PR says it is.
cat "$TMP/parts"/*.part > "$TMP/rejoined.diff"
is 'split: the parts concatenate back to the original diff byte for byte' \
   "$(cmp -s "$TMP/d.diff" "$TMP/rejoined.diff" && echo same || echo different)" 'same'

# A diff with no header at all must be refused, never silently treated as one
# empty slice: the caller's safe answer is "do not chunk", and it can only
# pick that if this says so.
: > "$TMP/empty.diff"
chunk_split "$TMP/empty.diff" "$TMP/parts" >/dev/null 2>&1 \
  && { echo "  FAIL split: an empty diff must be refused"; FAILED=1; } \
  || echo "  ok   split: an empty diff is refused"
printf 'not a diff at all\n' > "$TMP/junk.diff"
is 'split: a file with no diff --git header yields no parts' \
   "$(chunk_split "$TMP/junk.diff" "$TMP/parts" | grep -c .)" '0'
# ...and says so in its exit status, which is what the documented contract
# promises. A caller writing `chunk_split ... || fallback` must get the
# fallback; an empty plan with a zero status is a diff reviewed as zero
# slices, which reads exactly like a diff with nothing wrong in it.
chunk_split "$TMP/junk.diff" "$TMP/parts" >/dev/null 2>&1 \
  && { echo "  FAIL split: no header must be a non-zero exit, not a silent empty list"; FAILED=1; } \
  || echo "  ok   split: no header exits non-zero"

# ── chunk_plan ─────────────────────────────────────────────────────────────
plan() { printf '%s\n' "$1" | chunk_plan "$2" "$3" | cut -f1 | tr '\n' ' '; }

FOUR="$(printf '100\tp1\ta\n100\tp2\tb\n100\tp3\tc\n100\tp4\td\n')"
is 'plan: everything fits in one slice under the target' \
   "$(plan "$FOUR" 1000 8)" '1 1 1 1 '
is 'plan: a target of 250 packs two parts per slice' \
   "$(plan "$FOUR" 250 8)" '1 1 2 2 '
is 'plan: a target of 100 gives one part each' \
   "$(plan "$FOUR" 100 8)" '1 2 3 4 '

# A part alone in a slice may exceed the target: splitting a file's hunks is
# worse than an oversized slice.
BIG="$(printf '900\tp1\tbig.py\n50\tp2\tsmall.py\n')"
is 'plan: an oversized single file gets its own slice, not a split' \
   "$(plan "$BIG" 250 8)" '1 2 '

# The ceiling is the fan-out guard: past it, parts join the LAST slice rather
# than opening slice N+1. An unbounded slice count is an unbounded number of
# model calls per PR.
SIX="$(printf '100\tp1\ta\n100\tp2\tb\n100\tp3\tc\n100\tp4\td\n100\tp5\te\n100\tp6\tf\n')"
is 'plan: the slice ceiling holds and the tail joins the last slice' \
   "$(plan "$SIX" 100 3)" '1 2 3 3 3 3 '

# A typo'd knob must degrade to today's behaviour — one slice, one call —
# never to a fan-out storm or to zero slices.
is 'plan: a non-numeric target falls back to a single slice' \
   "$(plan "$FOUR" abc 8)" '1 1 1 1 '
is 'plan: a zero target falls back to a single slice' \
   "$(plan "$FOUR" 0 8)" '1 1 1 1 '
is 'plan: a ceiling of 1 falls back to a single slice' \
   "$(plan "$FOUR" 100 1)" '1 1 1 1 '
is 'plan: a non-numeric ceiling falls back to a single slice' \
   "$(plan "$FOUR" 100 xyz)" '1 1 1 1 '
is 'plan: no input yields no output, not an error' \
   "$(printf '' | chunk_plan 250 8 | grep -c .)" '0'

# The plan must never lose or duplicate a part: a dropped part is a file
# nobody reviewed, while the verdict still reads as a review of the whole PR.
is 'plan: no part goes missing' \
   "$(printf '%s\n' "$SIX" | chunk_plan 100 3 | cut -f3 | sort -u | grep -c .)" '6'
# ...and none is emitted twice. Counting DISTINCT parts cannot see a
# duplicate: a packing bug that printed one part into two slices would review
# the same hunks twice and report the same defect twice, and the count above
# would still be 6.
is 'plan: no part is emitted twice' \
   "$(printf '%s\n' "$SIX" | chunk_plan 100 3 | cut -f3 | sort | uniq -d | grep -c .)" '0'
is 'plan: the total line count matches the input' \
   "$(printf '%s\n' "$SIX" | chunk_plan 100 3 | grep -c .)" '6'

# Counting changed lines must not be fooled by CONTENT that looks like a diff
# header: a deleted `-- x` renders as `--- x`, and excluding it makes the
# slice look smaller than it is.
cat > "$TMP/sqlish.diff" <<'EOF'
diff --git a/q.sql b/q.sql
index 1..2 100644
--- a/q.sql
+++ b/q.sql
@@ -1,2 +1,2 @@
--- old comment
++ plus prefixed
EOF
is 'split: a changed line whose content starts with -- or ++ is still counted' \
   "$(chunk_split "$TMP/sqlish.diff" "$TMP/parts" | cut -f1)" '2'

# ── CHUNK_MERGE_JQ ─────────────────────────────────────────────────────────
merge() { jq -s -c "$CHUNK_MERGE_JQ"; }

A='{"verdict":"approve","summary":"Slice A is clean.","unverified":["live service"],"findings":[{"severity":"MEDIUM","file":"a.py","line":1,"issue":"minor issue"}]}'
B='{"verdict":"request_changes","summary":"Slice B has a problem.","unverified":["the payment provider"],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"major issue"}]}'

M="$(printf '%s\n%s\n' "$A" "$B" | merge)"
# One slice asking for changes must carry the whole review, or a clean slice
# silently outvotes the one that found the blocker.
is 'merge: one request_changes makes the merged verdict request_changes' \
   "$(jq -r '.verdict' <<<"$M")" 'request_changes'
is 'merge: findings from every slice survive' \
   "$(jq -r '.findings | length' <<<"$M")" '2'
is 'merge: summaries are joined, not dropped' \
   "$(jq -r '.summary' <<<"$M")" 'Slice A is clean. Slice B has a problem.'
is 'merge: unverified is unioned' \
   "$(jq -r '.unverified | length' <<<"$M")" '2'
is 'merge: all-approve stays approve' \
   "$(printf '%s\n%s\n' "$A" "$A" | merge | jq -r '.verdict')" 'approve'

# The duplicate case that is guaranteed rather than hypothetical: a carried
# finding from a prior round is copied VERBATIM by prompt rule, so two slices
# that both believe they own the file emit the identical entry.
DUP='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"major issue"}]}'
is 'merge: a verbatim duplicate collapses to one finding' \
   "$(printf '%s\n%s\n' "$B" "$DUP" | merge | jq -r '.findings | length')" '1'
# ...but two DIFFERENT findings on the same line must both survive: dedup that
# swallows a second real defect is worse than a duplicate line in a comment.
DIFF2='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"another issue"}]}'
is 'merge: two different findings on one line both survive' \
   "$(printf '%s\n%s\n' "$B" "$DIFF2" | merge | jq -r '.findings | length')" '2'

# A carried finding may be re-anchored when its old line is wrong (the round
# task says so). Slices that disagree on the new anchor must still collapse
# to one finding, so the merge keys a carried finding on file and issue.
CA='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":412,"issue":"Carried over: major issue"}]}'
CB='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"Carried over: major issue"}]}'
is 'merge: a carried finding with two different anchors collapses to one' \
   "$(printf '%s\n%s\n' "$CA" "$CB" | merge | jq -r '.findings | length')" '1'
CC='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"carried over: other issue"}]}'
is 'merge: two different carried findings both survive' \
   "$(printf '%s\n%s\n' "$CB" "$CC" | merge | jq -r '.findings | length')" '2'
NA='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":412,"issue":"same text"}]}'
NB='{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"severity":"HIGH","file":"b.py","line":9,"issue":"same text"}]}'
is 'merge: a finding that is not carried is still keyed on its line' \
   "$(printf '%s\n%s\n' "$NA" "$NB" | merge | jq -r '.findings | length')" '2'

# Two slices can return one carried finding with a different label. The merge
# keeps the variant that affects the verdict most, in either input order, so a
# LOW from an early slice cannot hide a HIGH from a later one.
mk() { printf '{"verdict":"request_changes","summary":"x","unverified":[],"findings":[{"file":"b.py","line":%s,"issue":"Carried over: major issue"%s}]}' "$1" "$2"; }
SEV_H="$(mk 9 ',"severity":"HIGH"')"
SEV_L="$(mk 412 ',"severity":"LOW"')"
is 'merge: carried HIGH then LOW keeps the HIGH' \
   "$(printf '%s\n%s\n' "$SEV_H" "$SEV_L" | merge | jq -r '[.findings[].severity] | join(",")')" 'HIGH'
is 'merge: carried LOW then HIGH keeps the HIGH' \
   "$(printf '%s\n%s\n' "$SEV_L" "$SEV_H" | merge | jq -r '[.findings[].severity] | join(",")')" 'HIGH'
is 'merge: the line of the kept variant is its own' \
   "$(printf '%s\n%s\n' "$SEV_L" "$SEV_H" | merge | jq -r '.findings[0].line')" '9'
KIND_W="$(mk 9 ',"severity":"HIGH","kind":"wording"')"
is 'merge: a carried HIGH tagged wording loses to a plain HIGH, in both orders' \
   "$(printf '%s\n%s\n' "$KIND_W" "$SEV_H" | merge | jq -r '[.findings[] | .kind // "none"] | join(",")')|$(printf '%s\n%s\n' "$SEV_H" "$KIND_W" | merge | jq -r '[.findings[] | .kind // "none"] | join(",")')" 'none|none'
AREA_T="$(mk 9 ',"severity":"HIGH","area":"test"')"
is 'merge: a carried HIGH in test area loses to a HIGH in correctness, in both orders' \
   "$(printf '%s\n%s\n' "$AREA_T" "$SEV_H" | merge | jq -r '[.findings[] | .area // "none"] | join(",")')|$(printf '%s\n%s\n' "$SEV_H" "$AREA_T" | merge | jq -r '[.findings[] | .area // "none"] | join(",")')" 'none|none'
AUD_M="$(mk 9 ',"severity":"HIGH","area":"doc","audience":"maintainer"')"
AUD_O="$(mk 9 ',"severity":"HIGH","area":"doc","audience":"operator"')"
is 'merge: a carried doc HIGH for operators beats one for maintainers, in both orders' \
   "$(printf '%s\n%s\n' "$AUD_M" "$AUD_O" | merge | jq -r '[.findings[].audience] | join(",")')|$(printf '%s\n%s\n' "$AUD_O" "$AUD_M" | merge | jq -r '[.findings[].audience] | join(",")')" 'operator|operator'
# Equal weight, different label: the merge cannot tell which one the verdict
# needs, so both stay.
AREA_S="$(mk 9 ',"severity":"HIGH","area":"security"')"
AREA_D="$(mk 9 ',"severity":"HIGH","area":"data"')"
is 'merge: carried HIGHs of equal weight in two areas both stay' \
   "$(printf '%s\n%s\n' "$AREA_S" "$AREA_D" | merge | jq -r '.findings | length')" '2'
AUD_U="$(mk 9 ',"severity":"HIGH","area":"doc","audience":"user"')"
is 'merge: carried doc HIGHs of equal weight for two audiences both stay' \
   "$(printf '%s\n%s\n' "$AUD_O" "$AUD_U" | merge | jq -r '.findings | length')" '2'
KIND_J="$(mk 9 ',"severity":"HIGH","kind":"judgment"')"
KIND_D="$(mk 9 ',"severity":"MEDIUM","kind":"defect"')"
is 'merge: carried findings of equal weight and different kind cap both stay' \
   "$(printf '%s\n%s\n' "$KIND_J" "$KIND_D" | merge | jq -r '.findings | length')" '2'
is 'merge: two equal carried variants still merge into one' \
   "$(printf '%s\n%s\n' "$AREA_S" "$AREA_S" | merge | jq -r '.findings | length')" '1'
is 'merge: equal variants written with different case and space still merge' \
   "$(printf '%s\n%s\n' "$AREA_S" "$(mk 3 ',"severity":" high ","area":"Security"')" | merge | jq -r '.findings | length')" '1'

# Eight slices of prose must not eat the cross-round memory window: the
# comment puts the summary before the findings and the next round keeps only
# the first 4500 characters, so an uncapped join cuts every finding off the
# end — including the unfixed blockers duty (a) has to carry forward.
LONGSUM="$(python3 -c 'import json;print(json.dumps({"summary":"é"*400,"findings":[]}))' 2>/dev/null)"
# 1200 characters, plus the note saying the summary was cut.
CAPPED_LEN=1230
if [ -n "$LONGSUM" ]; then
  is 'merge: a joined summary is capped, not left to eat the memory window' \
     "$(printf '%s\n%s\n%s\n%s\n' "$LONGSUM" "$LONGSUM" "$LONGSUM" "$LONGSUM" | merge | jq -r '.summary | length')" "$CAPPED_LEN"
fi
is 'merge: a short summary is left exactly as it was' \
   "$(printf '%s\n' "$A" | merge | jq -r '.summary')" 'Slice A is clean.'

is 'merge: unverified is capped at three' \
   "$(printf '%s\n' '{"unverified":["a","b","c","d","e"],"findings":[]}' | merge | jq -r '.unverified | length')" '3'
is 'merge: a slice with no findings key does not break the merge' \
   "$(printf '%s\n' '{"verdict":"approve","summary":"s"}' | merge | jq -r '.findings | length')" '0'
is 'merge: a non-object entry in findings is dropped, not carried' \
   "$(printf '%s\n' '{"verdict":"approve","findings":["oops",{"file":"a","line":1,"issue":"i"}]}' | merge | jq -r '.findings | length')" '1'
is 'merge: the merged object still has every key the harness reads' \
   "$(printf '%s\n' "$A" | merge | jq -r '[has("verdict"),has("summary"),has("unverified"),has("findings")] | all')" 'true'

# Severity order. jq's unique_by sorts, so without an explicit re-sort the
# dedup silently reorders the array by FILE PATH — and the renderer prints it
# in order, putting a LOW above a CRITICAL in the comment a person skims.
ORDER='{"findings":[{"severity":"LOW","file":"a.py","line":1,"issue":"l"},{"severity":"CRITICAL","file":"z.py","line":2,"issue":"c"},{"severity":"MEDIUM","file":"b.py","line":3,"issue":"m"},{"severity":"HIGH","file":"c.py","line":4,"issue":"h"}]}'
is 'merge: findings come back worst-first, not sorted by file path' \
   "$(printf '%s\n' "$ORDER" | merge | jq -r '[.findings[].severity] | join(",")')" \
   'CRITICAL,HIGH,MEDIUM,LOW'
# An invented severity counts as blocking downstream, so it must not sort as if
# it were a nit — same fail-closed direction as the blocking tally.
ODD='{"findings":[{"severity":"LOW","file":"a","line":1,"issue":"l"},{"severity":"BLOCKER","file":"b","line":2,"issue":"x"}]}'
is 'merge: an unrecognised severity sorts with HIGH, not with LOW' \
   "$(printf '%s\n' "$ODD" | merge | jq -r '.findings[0].severity')" 'BLOCKER'
is 'merge: severity comparison ignores case and padding' \
   "$(printf '%s\n' '{"findings":[{"severity":"low","file":"a","line":1,"issue":"l"},{"severity":" critical ","file":"b","line":2,"issue":"c"}]}' | merge | jq -r '.findings[0].issue')" 'c'

# The per-slice tally in pr-autoreview.sh that decides SLICE_INCOMPLETE.
# No test read this loop before: flip the `-eq 0` to `-ne 0`
# and every REVIEWED slice is reported missing while the dead ones pass, with
# the whole suite still green. Pinned on the text because the loop lives in
# the middle of review_one_pr and cannot be called on its own.
TALLY="$(awk -v a='SLICE_OK_N=()' -v b='if [ "$N_SLICE_OK" -eq 0 ]' \
  'index($0, a) { f = 1 } f { print } f && index($0, b) { exit }' pr-autoreview.sh)"
is 'slices: the tally loop is where it was pinned' \
   "$(grep -cF 'SLICE_OK_N[$si]=0' <<<"$TALLY")" '1'
is 'slices: a parsed sample bumps its own slice, keyed through the sample-to-slice map' \
   "$(grep -cF 'SLICE_OK_N[$SI_OF]=$(( ${SLICE_OK_N[$SI_OF]:-0} + 1 ))' <<<"$TALLY")" '1'
is 'slices: the map is SLICE_OF, falling back to the sample index' \
   "$(grep -cF 'SI_OF="${SLICE_OF[$i]:-$i}"' <<<"$TALLY")" '1'
is 'slices: a slice with zero parsed samples, and only that, marks the round incomplete' \
   "$(awk -v p='if [ "${SLICE_OK_N[$si]:-0}" -eq 0 ]; then' \
        'index($0, p) { f = 1; n = 0; next } f { n++; if (index($0, "SLICE_INCOMPLETE=1")) { print "yes"; exit } if (n > 3) { print "no"; exit } }' \
        <<<"$TALLY")" 'yes'
is 'slices: SLICE_INCOMPLETE is set in exactly one place inside the tally' \
   "$(grep -cF 'SLICE_INCOMPLETE=1' <<<"$TALLY")" '1'

# Each slice's read dir. A review call gets --restricted and --add-dir with
# the dir of its slice diff, so that dir must hold that one diff and nothing
# else. $SLICE_DIR itself holds the parts of every slice. This runs the
# slice-writing block of pr-autoreview.sh on a two-file diff that packs into
# two slices.
cat > "$TMP/two.diff" <<'EOF2'
diff --git a/one.py b/one.py
index 111..222 100644
--- a/one.py
+++ b/one.py
@@ -1,1 +1,2 @@
-one old
+one new
+one added
diff --git a/two.py b/two.py
index 333..444 100644
--- a/two.py
+++ b/two.py
@@ -1,1 +1,2 @@
-two old
+two new
+two added
EOF2
SLICE_BLOCK="$(awk -v a='SLICE_DIFFS=(); SLICE_FILES=(); SLICE_DIR=""' -v b='SLICE_DIFFS=("$DIFF"); SLICE_FILES=("")' \
  'index($0, a) { f = 1 } f { print } f && index($0, b) { d = 1 } d && /^  fi$/ { exit }' pr-autoreview.sh)"
is 'read dir: the slice-writing block is where it was pinned' \
   "$(grep -cF 'chunk_split "$DIFF" "$SLICE_DIR"' <<<"$SLICE_BLOCK")" '1'
mkdir -p "$TMP/scratch"
# shellcheck disable=SC2034  # read by the eval'd block
GATE_SCRATCH="$TMP/scratch" DIFF="$TMP/two.diff" SIZE=4 CHUNK_MIN_LINES=0 CHUNK_TARGET_LINES=1 CHUNK_MAX=8 PR=7
SLICE_DIFFS=(); SLICE_DIR=""
eval "$SLICE_BLOCK" >/dev/null
is 'read dir: the plan has two slices' "${#SLICE_DIFFS[@]}" '2'
S1_DIR="${SLICE_DIFFS[0]%/*}"
is 'read dir: slice 1 dir holds only its diff' "$(ls -A "$S1_DIR" 2>&1)" "${SLICE_DIFFS[0]##*/}"
is 'read dir: slice 1 diff has slice 1 file' "$(grep -c '^+++ b/one.py$' "${SLICE_DIFFS[0]}")" '1'
is 'read dir: slice 1 diff has no slice 2 file' "$(grep -c 'two.py' "${SLICE_DIFFS[0]}")" '0'
is 'read dir: slice 1 dir is not SLICE_DIR' "$([ "$S1_DIR" != "$SLICE_DIR" ] && echo yes)" 'yes'
is 'read dir: slice 1 dir is not GATE_SCRATCH' "$([ "$S1_DIR" != "$GATE_SCRATCH" ] && echo yes)" 'yes'
is 'read dir: slice 2 has its own dir' "$([ "${SLICE_DIFFS[1]%/*}" != "$S1_DIR" ] && echo yes)" 'yes'

# How many passes a round gets.
is 'samples: round 1 takes the first-round count'        "$(chunk_samples_for_round 1 100 2 1 1000)" 2
is 'samples: round 2 takes the later-round count'        "$(chunk_samples_for_round 2 100 2 1 1000)" 1
is 'samples: round 3 too'                                "$(chunk_samples_for_round 3 5000 2 1 1000)" 1
is 'samples: a big diff in round 1 gets at least two'    "$(chunk_samples_for_round 1 1000 1 1 1000)" 2
is 'samples: just under the floor stays at one'          "$(chunk_samples_for_round 1 999 1 1 1000)" 1
is 'samples: the floor does not lower a higher count'    "$(chunk_samples_for_round 1 5000 3 1 1000)" 3
is 'samples: a floor of 0 is off'                        "$(chunk_samples_for_round 1 5000 1 1 0)" 1
is 'samples: a big diff in round 2 is not resampled'     "$(chunk_samples_for_round 2 5000 1 1 1000)" 1
is 'samples: garbage reads as one'                       "$(chunk_samples_for_round x y z w v)" 1
is 'samples: zero reads as one'                          "$(chunk_samples_for_round 1 10 0 0 0)" 1

if [ "$FAILED" -eq 0 ]; then echo "PASS: lib/chunk.sh + pr-autoreview.sh slice tally"; else echo "FAIL: lib/chunk.sh + pr-autoreview.sh slice tally (see which line above)"; exit 1; fi
