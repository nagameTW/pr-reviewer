#!/usr/bin/env bash
# The step in pr-autoreview.sh that replaces a stacked PR's convention files
# with the default branch's versions. The real block runs here, lifted out of
# the script, on a real git repo. A recorder stands in for note_skip.
#
# Every step of the block can fail: the file list, the checkout of a file,
# the removal of a file from the index and the removal from the disk. A
# failure must skip the PR and must not set CONV_FORCED. The failures are
# injected with shell functions that shadow git and rm inside a subshell.
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
build() { # $1 = directory
  local d="$1"
  mkdir -p "$d/.claude/skills/a"; git -C "$d" init -q
  printf 'main rules\n' > "$d/CLAUDE.md"
  printf 'main agents\n' > "$d/AGENTS.md"
  printf 'main skill\n' > "$d/.claude/skills/a/SKILL.md"
  printf 'main code\n' > "$d/src.py"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm default
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  mkdir -p "$d/.claude/skills/p" "$d/docs"
  printf 'parent rules\n' > "$d/CLAUDE.md"
  printf 'parent skill\n' > "$d/.claude/skills/p/SKILL.md"
  printf 'parent nested rules\n' > "$d/docs/CLAUDE.md"
  printf 'parent code\n' > "$d/src.py"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm parent
}

# Injectors. Each runs inside the subshell of run_case.
# git, called as `git -C <dir> <subcommand> ...`: the subcommand is $3.
fail_ls_files() { git() { if [ "$3" = ls-files ]; then return 128; fi; command git "$@"; }; }
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
is  "happy: the file list is one temp file for the EXIT trap" "${#TMPFILES[@]}" 1
[ -f "${TMPFILES[0]:-/nonexistent}" ] && ok "happy: ...and it exists under the scratch directory" \
  || bad "happy: ...and it exists under the scratch directory" "missing: ${TMPFILES[0]:-none}"
case "${TMPFILES[0]:-}" in "$GATE_SCRATCH"/*) ok "happy: ...inside GATE_SCRATCH" ;; *) bad "happy: ...inside GATE_SCRATCH" "${TMPFILES[0]:-none}" ;; esac

# ── a PR into the default branch is left alone ─────────────────────────────
run_case : main
is  "default base: the block only passes"               "$OUT" "reached"
is  "default base: CONV_FORCED is not touched"          "$CF" unset
is  "default base: no file changes"                     "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

# ── the ref must resolve first ──────────────────────────────────────────────
run_case drop_origin
skipped "no origin ref" "cannot resolve origin/main"

# ── a step that fails skips the PR ─────────────────────────────────────────
run_case fail_ls_files
skipped "listing fails" "list the convention files"
is  "listing fails: no file was touched"                "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_checkout
skipped "checkout fails" "check out a convention file"
is  "checkout fails: the file keeps the parent's version" "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_index_rm
skipped "index removal fails" "from the index"

run_case fail_file_rm
skipped "file removal fails" "from the review tree"

run_case fail_mktemp
skipped "no temp file for the list" "scratch file"

if [ "$FAILED" -eq 0 ]; then echo "PASS: stacked-PR convention files"; else echo "FAIL: stacked-PR convention files"; exit 1; fi
