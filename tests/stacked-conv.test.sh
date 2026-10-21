#!/usr/bin/env bash
# The step in pr-autoreview.sh that replaces a stacked PR's convention files
# with the default branch's versions. The real block runs here, lifted out of
# the script, on a real git repo. A recorder stands in for note_skip.
#
# Every step of the block can fail: the file list, the read of the default
# branch's tree, the checkout of a file, the removal of a file from the index
# and the removal from the disk. A failure must skip the PR and must not set
# CONV_FORCED. A path that the default branch does not have is not a failure:
# the block removes that file and the review goes on. The failures are
# injected with shell functions that shadow git and rm inside a subshell.
#
# The look-up of a path in the default branch's file list must not need a
# GNU tool. The README lists macOS and its Bash 3.2 as supported, and GNU grep
# is not on that list. A grep stub that rejects -z stands in for such a host.
#
# Run: bash tests/stacked-conv.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "must not contain '$2', got: $3";; *) ok "$1";; esac; }
for h in ok bad is has lacks; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/tree.sh  || { echo "FAIL: could not source lib/tree.sh"; exit 1; }
. lib/merge.sh || { echo "FAIL: could not source lib/merge.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do case "$a" in --) break ;; -*z*) exit 2 ;; esac; done\n'
  printf 'exec %q "$@"\n' "$(command -v grep)"; } > "$STUBS/grep"
chmod +x "$STUBS/grep"

# From the stacked-base test to the `fi` that closes it.
BLOCK="$(awk '/^    if ! merge_base_allowed "\$PR_BASE" "\$DEFAULT_BRANCH"; then$/ { p = 1 } p { print } p && /^    fi$/ { exit }' pr-autoreview.sh)"
[ "$(grep -c '' <<<"$BLOCK")" -gt 20 ] || { echo "FAIL: could not lift the stacked-base block out of pr-autoreview.sh"; exit 1; }
eval "conv_block() { $BLOCK
echo reached; }"
note_skip() { echo "skip $PR: $1"; }
GATE_SCRATCH="$TMP/scratch"; mkdir -p "$GATE_SCRATCH"
# shellcheck disable=SC2034  # read by the lifted block
DEFAULT_BRANCH=main PR=5

# A tree at the parent branch. origin/main holds the default versions.
# The parent changed CLAUDE.md, and added .claude/skills/p/SKILL.md and
# docs/CLAUDE.md. The list of tracked convention files, in git's order:
#   .claude/skills/a/SKILL.md  AGENTS.md  CLAUDE.md  docs/CLAUDE.md
# CLAUDE.md is the 3rd and docs/CLAUDE.md is the last. A failure on them
# comes after steps that worked, so a flag set per file would be set by then.
# DEFAULT_EXTRA and PARENT_EXTRA, when set, name one more file (the name may
# hold a newline) that the default commit or the parent commit adds.
build() { # $1 = directory
  local d="$1"
  mkdir -p "$d/.claude/skills/a"; git -C "$d" init -q
  printf 'main rules\n' > "$d/CLAUDE.md"
  printf 'main agents\n' > "$d/AGENTS.md"
  printf 'main skill\n' > "$d/.claude/skills/a/SKILL.md"
  printf 'main code\n' > "$d/src.py"
  [ -z "${DEFAULT_EXTRA-}" ] || printf 'main odd\n' > "$d/$DEFAULT_EXTRA"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm default
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$d/.claude/skills/p" "$d/docs"
  printf 'parent rules\n' > "$d/CLAUDE.md"
  printf 'parent skill\n' > "$d/.claude/skills/p/SKILL.md"
  printf 'parent nested rules\n' > "$d/docs/CLAUDE.md"
  printf 'parent code\n' > "$d/src.py"
  [ -z "${PARENT_EXTRA-}" ] || printf 'parent odd\n' > "$d/$PARENT_EXTRA"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm parent
}

# Injectors. Each runs inside the subshell of run_case.
# git, called as `git -C <dir> <subcommand> ...`: the subcommand is $3.
fail_ls_files() { git() { if [ "$3" = ls-files ]; then return 128; fi; command git "$@"; }; }
# The default branch's tree cannot be read: the listing fails, and so does a
# read of a single object.
fail_tree_read() { git() { case "$3" in ls-tree|cat-file) return 128 ;; esac; command git "$@"; }; }
# The listing of the default branch ends in the middle of a name: the last
# name has no NUL after it. The list cannot be trusted to be complete.
fail_lookup()   { git() { if [ "$3" = ls-tree ]; then printf 'AGENTS.md'; return 0; fi; command git "$@"; }; }
# A host where grep rejects -z (BSD grep, the macOS default). The stub exits 2
# on any option word with a z in it, and runs the real grep otherwise.
no_gnu_grep()   { PATH="$STUBS:$PATH"; }
fail_checkout() { git() { if [ "$3" = checkout ] && [ "${!#}" = CLAUDE.md ]; then return 1; fi; command git "$@"; }; }
fail_index_rm() { git() { if [ "$3" = rm ] && [ "${!#}" = docs/CLAUDE.md ]; then return 1; fi; command git "$@"; }; }
fail_file_rm()  { rm() { case "${!#}" in */docs/CLAUDE.md) return 1 ;; esac; command rm "$@"; }; }
fail_mktemp()   { mktemp() { return 1; }; }
drop_origin()   { git -C "$REPO_DIR" update-ref -d refs/remotes/origin/main; }

# run_case <injector> [PR_BASE]: a fresh tree, the block run in a subshell.
# Sets OUT (the block's output) and CF (CONV_FORCED after it, or "unset").
run_case() {
  local d="$TMP/case-$RANDOM$RANDOM" res
  build "$d"
  res="$( ( REPO_DIR="$d"; PR_BASE="${2:-feat/parent}"; TMPFILES=(); unset CONV_FORCED
            "$1"; conv_block 2>&1; echo "CONV_FORCED=${CONV_FORCED-unset}" ) )"
  CASE_DIR="$d"
  CF="${res##*CONV_FORCED=}"
  OUT="$(printf '%s' "${res%CONV_FORCED=*}")"
}

# A skipped PR: one skip line that names the step, no review, no flag.
skipped() { # $1 = label, $2 = words the skip line must hold
  has   "$1: the PR is skipped"               "skip 5:" "$OUT"
  has   "$1: the line names the step"         "$2" "$OUT"
  has   "$1: the line says it fails closed"   "(fail closed)" "$OUT"
  lacks "$1: the review does not go on"       "reached" "$OUT"
  is    "$1: one skip line only"              "$(grep -c '^skip ' <<<"$OUT")" 1
  if [ "$CF" = 1 ]; then bad "$1: CONV_FORCED is not set" "CONV_FORCED is 1"; else ok "$1: CONV_FORCED is not set"; fi
}

# ── every step works ────────────────────────────────────────────────────────
# Run in this shell, so TMPFILES and CONV_FORCED can be read afterwards.
D="$TMP/happy"; build "$D"
# shellcheck disable=SC2034  # read by the lifted block
REPO_DIR="$D" PR_BASE=feat/parent TMPFILES=(); unset CONV_FORCED
conv_block > "$TMP/happy.out" 2>&1
HOUT="$(cat "$TMP/happy.out")"
has "happy: the block ends in the review"               "reached" "$HOUT"
has "happy: the log says the files were forced back"    "convention files forced back to origin/main" "$HOUT"
lacks "happy: nothing is skipped"                       "skip 5:" "$HOUT"
is  "happy: CONV_FORCED is 1"                           "${CONV_FORCED-unset}" 1
is  "happy: a tracked convention file takes the default version" "$(cat "$D/CLAUDE.md")" "main rules"
is  "happy: an unchanged convention file stays"         "$(cat "$D/AGENTS.md")" "main agents"
[ ! -e "$D/.claude/skills/p/SKILL.md" ] && ok "happy: a skill the default branch lacks is removed from the disk" \
  || bad "happy: a skill the default branch lacks is removed from the disk" "still on disk"
[ ! -e "$D/docs/CLAUDE.md" ] && ok "happy: a nested CLAUDE.md the default branch lacks is removed from the disk" \
  || bad "happy: a nested CLAUDE.md the default branch lacks is removed from the disk" "still on disk"
is  "happy: ...and from the index"                      "$(git -C "$D" ls-files '.claude/skills/p/SKILL.md' 'docs/CLAUDE.md')" ""
is  "happy: a file that is no convention file stays"    "$(cat "$D/src.py")" "parent code"
is  "happy: the two file lists are two temp files for the EXIT trap" "${#TMPFILES[@]}" 2
for tf in "${TMPFILES[@]}"; do
  [ -f "$tf" ] && ok "happy: ...$(basename "$tf") exists" || bad "happy: ...$(basename "$tf") exists" "missing: $tf"
  case "$tf" in "$GATE_SCRATCH"/*) ok "happy: ...$(basename "$tf") is inside GATE_SCRATCH" ;; *) bad "happy: ...$(basename "$tf") is inside GATE_SCRATCH" "$tf" ;; esac
done

# ── a PR into the default branch is left alone ─────────────────────────────
run_case : main
is  "default base: the block only passes"               "$OUT" "reached"
is  "default base: CONV_FORCED is not touched"          "$CF" unset
is  "default base: no file changes"                     "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

# ── the ref must resolve first ──────────────────────────────────────────────
run_case drop_origin
skipped "no origin ref" "cannot resolve origin/main"

# ── a path that the default branch does not have is removed ────────────────
run_case :
is  "missing in default: CONV_FORCED is 1"              "$CF" 1
has "missing in default: the review goes on"            "reached" "$OUT"
lacks "missing in default: nothing is skipped"          "skip 5:" "$OUT"
[ ! -e "$CASE_DIR/docs/CLAUDE.md" ] && ok "missing in default: the file is removed from the disk" \
  || bad "missing in default: the file is removed from the disk" "still on disk"
is  "missing in default: ...and from the index"         "$(git -C "$CASE_DIR" ls-files 'docs/CLAUDE.md' '.claude/skills/p/SKILL.md')" ""
is  "missing in default: a file the default has takes its version" "$(cat "$CASE_DIR/CLAUDE.md")" "main rules"

# ── a step that fails skips the PR ─────────────────────────────────────────
run_case fail_ls_files
skipped "listing fails" "list the convention files"
is  "listing fails: no file was touched"                "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_tree_read
skipped "tree read fails" "list the files of origin/main"
is  "tree read fails: the file keeps the parent's version" "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"
[ -e "$CASE_DIR/docs/CLAUDE.md" ] && ok "tree read fails: no convention file is removed" \
  || bad "tree read fails: no convention file is removed" "docs/CLAUDE.md is gone"
is  "tree read fails: the index keeps the parent's files" "$(git -C "$CASE_DIR" ls-files 'docs/CLAUDE.md' '.claude/skills/p/SKILL.md' | wc -l | tr -d ' ')" 2

run_case fail_lookup
skipped "truncated list" "ends in the middle of a name"
is  "truncated list: the file keeps the parent's version" "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_checkout
skipped "checkout fails" "check out a convention file"
is  "checkout fails: the file keeps the parent's version" "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_index_rm
skipped "index removal fails" "from the index"

run_case fail_file_rm
skipped "file removal fails" "from the review tree"

run_case fail_mktemp
skipped "no temp file for the list" "scratch file"

# ── a host without GNU grep ─────────────────────────────────────────────────
# The stub must reject -z, or this case proves nothing.
"$STUBS/grep" -qz x /dev/null; is "stub: grep -z gives status 2" "$?" 2
printf 'a\n' | "$STUBS/grep" -q a; is "stub: grep without -z is the real grep" "$?" 0
run_case no_gnu_grep
is  "no GNU grep: CONV_FORCED is 1"                     "$CF" 1
has "no GNU grep: the review goes on"                   "reached" "$OUT"
lacks "no GNU grep: the PR is not skipped"              "skip 5:" "$OUT"
is  "no GNU grep: a file the default has takes its version" "$(cat "$CASE_DIR/CLAUDE.md")" "main rules"
[ ! -e "$CASE_DIR/docs/CLAUDE.md" ] && ok "no GNU grep: a file the default lacks is removed from the disk" \
  || bad "no GNU grep: a file the default lacks is removed from the disk" "still on disk"
is  "no GNU grep: ...and from the index"                "$(git -C "$CASE_DIR" ls-files 'docs/CLAUDE.md' '.claude/skills/p/SKILL.md')" ""

# ── a name with a newline is compared as a whole ───────────────────────────
ODD=".claude/skills/a/odd"$'\n'"name.md"
# The parent has the name. The default branch does not, but it has a file
# named like the first line of it. A look-up that splits the name at the
# newline would find that file and then fail to check out the name.
DEFAULT_EXTRA=".claude/skills/a/odd" PARENT_EXTRA="$ODD" run_case :
is  "newline name, absent: CONV_FORCED is 1"            "$CF" 1
has "newline name, absent: the review goes on"          "reached" "$OUT"
lacks "newline name, absent: nothing is skipped"        "skip 5:" "$OUT"
[ ! -e "$CASE_DIR/$ODD" ] && ok "newline name, absent: the file is removed from the disk" \
  || bad "newline name, absent: the file is removed from the disk" "still on disk"
is  "newline name, absent: ...and from the index"       "$(git -C "$CASE_DIR" ls-files -z -- "$ODD" | wc -c | tr -d ' ')" 0
is  "newline name, absent: the file named like its first line takes the default version" "$(cat "$CASE_DIR/.claude/skills/a/odd")" "main odd"
# Both branches have the name: it takes the default version.
DEFAULT_EXTRA="$ODD" PARENT_EXTRA="$ODD" run_case :
is  "newline name, present: CONV_FORCED is 1"           "$CF" 1
lacks "newline name, present: nothing is skipped"       "skip 5:" "$OUT"
is  "newline name, present: the file takes the default version" "$(cat "$CASE_DIR/$ODD")" "main odd"

if [ "$FAILED" -eq 0 ]; then echo "PASS: stacked-PR convention files"; else echo "FAIL: stacked-PR convention files"; exit 1; fi
