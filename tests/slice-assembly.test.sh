#!/usr/bin/env bash
# The step in pr-autoreview.sh that writes one diff file per slice for a large
# PR. The real block runs here, lifted out of the script, on a real diff split
# and packed by lib/chunk.sh. Only `cat` is replaced, by a stub on PATH that
# fails for chosen part files.
#
# The block promises (its own comments) that it never reviews part of the
# diff. Either the slices together hold every byte of the diff, or the review
# falls back to the whole diff in one pass. A slice that lost a whole file's
# hunks and was still used would review part of the diff and report a verdict
# on all of it.
#
# The fixture is six files of 100 changed lines. With a target of 250 lines the
# packing is three slices of two parts each:
#   slice 1 = 0001.part 0002.part
#   slice 2 = 0003.part 0004.part
#   slice 3 = 0005.part 0006.part
#
# A second stub, `awk`, changes the output of one call of the block. It tells
# the calls apart by their -v variable: chunk_plan sets `target`, the
# selector of one slice sets `s`, and every other call (chunk_split too) runs
# the real awk. A planner or a selector that prints a prefix and then fails
# gives slices that agree with each other, so the count check alone passes.
#
# Run: bash tests/slice-assembly.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
for h in ok bad is has; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/chunk.sh || { echo "FAIL: could not source lib/chunk.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
REAL_CAT="$(command -v cat)"
REAL_AWK="$(command -v awk)"
ORIG_PATH="$PATH"

# A cat that fails for the part files named in CAT_FAIL_PARTS (space separated
# base names). Mode "partial" first writes 40 bytes, as a full disk would.
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do\n'
  printf '  for p in ${CAT_FAIL_PARTS-}; do\n'
  printf '    case "$a" in\n'
  printf '      */"$p") [ "${CAT_FAIL_MODE-}" != partial ] || head -c 40 "$a"; exit 1 ;;\n'
  printf '    esac\n'
  printf '  done\n'
  printf 'done\n'
  printf 'exec "$CAT_REAL" "$@"\n'; } > "$STUBS/cat"
chmod +x "$STUBS/cat"

# AWK_MODE picks the fault. Every fault writes $STUB_FIRED, so a case whose
# stub never ran cannot pass by doing nothing.
#   plan-prefix-fail    chunk_plan prints its first 4 rows and exits 1
#   plan-prefix-ok      chunk_plan prints its first 4 rows and exits 0
#   plan-dup-ok         chunk_plan prints all rows and the last row again
#   plan-full-fail      chunk_plan prints all rows and exits 1
#   select-prefix-fail  the selector of slice 2 prints its first row and exits 1
cat > "$STUBS/awk" <<'STUB'
#!/bin/bash
mode="${AWK_MODE-}"
case "$mode:$*" in
  plan-*:*"-v target="*|select-*:*"-v s=2 "*) ;;
  *) exec "$AWK_REAL" "$@" ;;
esac
: > "$STUB_FIRED"
out="$("$AWK_REAL" "$@")"
case "$mode" in
  plan-dup-ok) printf '%s\n' "$out"; printf '%s\n' "$out" | tail -n 1 ;;
  plan-full-fail) printf '%s\n' "$out" ;;
  plan-*) printf '%s\n' "$out" | head -n 4 ;;
  select-*) printf '%s\n' "$out" | head -n 1 ;;
esac
case "$mode" in *-fail) exit 1 ;; esac
STUB
chmod +x "$STUBS/awk"

# From the reset of the slice arrays to the `fi` that closes the one-pass
# fallback. The two `fi` lines at two spaces of indent are the SIZE test and
# that fallback test.
BLOCK="$(awk '/^  SLICE_DIFFS=\(\); SLICE_FILES=\(\); SLICE_DIR=""$/ { p = 1 } p { print } p && /^  fi$/ { if (++k == 2) exit }' pr-autoreview.sh)"
[ "$(grep -c '' <<<"$BLOCK")" -gt 30 ] || { echo "FAIL: could not lift the slice block out of pr-autoreview.sh"; exit 1; }
eval "slice_block() { $BLOCK
}"

GATE_SCRATCH="$TMP/scratch"; mkdir -p "$GATE_SCRATCH"
DIFF="$TMP/pr.diff"
for i in 1 2 3 4 5 6; do
  printf 'diff --git a/f%s.txt b/f%s.txt\nnew file mode 100644\nindex 0000000..1111111\n--- /dev/null\n+++ b/f%s.txt\n@@ -0,0 +1,100 @@\n' "$i" "$i" "$i"
  for n in $(seq 1 100); do printf '+file %s line %s\n' "$i" "$n"; done
done > "$DIFF"
# shellcheck disable=SC2034  # read by the lifted block
SIZE=600 CHUNK_MIN_LINES=300 CHUNK_TARGET_LINES=250 CHUNK_MAX=8 PR=5

# run_case <n> <fail-parts> <mode> [awk-mode]. Prints "<slices> <whole|PARTIAL>":
# how many diff files the review would get, and whether together they hold
# the diff.
FIRED="$TMP/fired"
run_case() {
  (
    rm -f "$FIRED"
    export CAT_REAL="$REAL_CAT" CAT_FAIL_PARTS="$2" CAT_FAIL_MODE="$3"
    export AWK_REAL="$REAL_AWK" AWK_MODE="${4-}" STUB_FIRED="$FIRED"
    PATH="$STUBS:$ORIG_PATH"
    slice_block >"$TMP/out-$1" 2>&1
    PATH="$ORIG_PATH"; hash -r
    if "$REAL_CAT" "${SLICE_DIFFS[@]}" | cmp -s - "$DIFF"; then cov=whole; else cov=PARTIAL; fi
    echo "${#SLICE_DIFFS[@]} $cov"
  )
}

echo "no failure"
is "three slices that hold the whole diff" "$(run_case 1 '' fail)" "3 whole"

echo "every part of one slice fails"
is "falls back to the whole diff in one pass" "$(run_case 2 '0003.part 0004.part' fail)" "1 whole"
has "says how many slices could be written" "only 2 of 3 slices" "$(cat "$TMP/out-2")"

# The slices hold every byte of the diff, or the review is the whole diff in
# one pass. Anything else reviews part of the diff.
complete() { # $1 = name, $2 = run_case result, $3 = what the result shows
  case "$2" in "1 whole"|"3 whole") ok "$1";; *) bad "$1" "got '$2': $3";; esac
}

echo "one part of a two-part slice fails to read"
complete "second part of a slice lost" "$(run_case 3 '0002.part' fail)" "slice 1 is reviewed without f2.txt"
complete "first part of a slice lost" "$(run_case 4 '0003.part' fail)" "slice 2 is reviewed without f3.txt"

echo "one part of a two-part slice is cut short by a failed write"
complete "second part cut after 40 bytes" "$(run_case 5 '0004.part' partial)" "slice 2 holds 40 bytes of f4.txt"

# A planner or a selector that fails after it printed a prefix. The slices
# built from that prefix agree with each other, so only the status of the
# planner and of the selector, and a plan that covers every part, can tell.
fired() { [ -e "$FIRED" ] && echo yes || echo no; }

echo "the planner prints a valid prefix and exits non-zero"
is "falls back to the whole diff in one pass" "$(run_case 6 '' fail plan-prefix-fail)" "1 whole"
is "the planner stub ran" "$(fired)" yes
has "says the plan does not cover the diff" "slice plan" "$(cat "$TMP/out-6")"

echo "the planner prints a plan that leaves out the last parts and exits 0"
is "falls back to the whole diff in one pass" "$(run_case 7 '' fail plan-prefix-ok)" "1 whole"
is "the planner stub ran" "$(fired)" yes
has "says the plan does not cover the diff" "slice plan" "$(cat "$TMP/out-7")"

echo "the planner prints the last part twice and exits 0"
is "falls back to the whole diff in one pass" "$(run_case 8 '' fail plan-dup-ok)" "1 whole"
is "the planner stub ran" "$(fired)" yes

# The plan is complete, so the coverage check passes. Only the status of the
# planner can reject it.
echo "the planner prints the complete plan and exits non-zero"
is "falls back to the whole diff in one pass" "$(run_case 10 '' fail plan-full-fail)" "1 whole"
is "the planner stub ran" "$(fired)" yes
has "says the plan does not cover the diff" "slice plan" "$(cat "$TMP/out-10")"

echo "the selector of slice 2 prints a prefix and exits non-zero"
is "falls back to the whole diff in one pass" "$(run_case 9 '' fail select-prefix-fail)" "1 whole"
is "the selector stub ran" "$(fired)" yes
has "says how many slices could be written" "only 2 of 3 slices" "$(cat "$TMP/out-9")"

echo "the selection of each slice is in a file registered in TMPFILES"
SEL_LIST="$( ( PATH="$STUBS:$ORIG_PATH"; export CAT_REAL="$REAL_CAT" AWK_REAL="$REAL_AWK" STUB_FIRED="$FIRED"
               slice_block >/dev/null 2>&1; PATH="$ORIG_PATH"; hash -r
               for f in ${TMPFILES[@]+"${TMPFILES[@]}"}; do [ -e "$f" ] && printf '%s\n' "$f"; done ) )"
has "a rows file under the scratch directory" "$GATE_SCRATCH/prreview-slice-rows-" "$SEL_LIST"

if [ "$FAILED" -eq 0 ]; then echo "PASS: slice assembly"; else echo "FAIL: slice assembly"; exit 1; fi
