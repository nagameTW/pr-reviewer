#!/usr/bin/env bash
# tree_force_convention_files (lib/tree.sh): the step that replaces the
# convention files of a review tree with the default branch's versions. It
# runs for every PR. This file builds the hard case, a tree on a parent
# branch, on a real git repo.
#
# Every step can fail: the file list of the tree, the read of the default
# branch's tree, the checkout of a file, the removal of a file from the index
# and the removal from the disk. A failure must return 1 with a sentence in
# TREE_CONV_ERR and must not set TREE_CONV_FORCED. A path that the default
# branch does not have is not a failure: the function removes that file and
# the review goes on. The failures are injected with shell functions that
# shadow git, rm and tr inside a subshell.
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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do case "$a" in --) break ;; -*z*) exit 2 ;; esac; done\n'
  printf 'exec %q "$@"\n' "$(command -v grep)"; } > "$STUBS/grep"
chmod +x "$STUBS/grep"

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
fail_gitdir()   { git() { if [ "$3" = rev-parse ] && [ "$4" = --absolute-git-dir ]; then return 128; fi; command git "$@"; }; }
fail_tr()       { tr() { cat >/dev/null; return 1; }; }
drop_origin()   { git -C "$REPO_DIR" update-ref -d refs/remotes/origin/main; }

# run_case <injector>: a fresh tree, the function run in a subshell.
# Sets OUT (its error sentence), RC and CF (TREE_CONV_FORCED after it).
run_case() {
  local d="$TMP/case-$RANDOM$RANDOM" res
  build "$d"
  res="$( ( REPO_DIR="$d"; "$1"; tree_force_convention_files "$d" origin/main; r=$?
            echo "RC=$r ERR=${TREE_CONV_ERR-unset} CF=${TREE_CONV_FORCED-unset}" ) 2>&1 )"
  CASE_DIR="$d"
  RC="${res#*RC=}"; RC="${RC%% *}"
  OUT="${res#*ERR=}"; OUT="${OUT%% CF=*}"
  CF="${res##*CF=}"
}

# A failed run: returns 1, one sentence that names the step, no flag.
skipped() { # $1 = label, $2 = words the sentence must hold
  is    "$1: it returns 1"                    "$RC" 1
  has   "$1: the sentence names the step"     "$2" "$OUT"
  if [ "$CF" = 1 ]; then bad "$1: TREE_CONV_FORCED is not set" "TREE_CONV_FORCED is 1"; else ok "$1: TREE_CONV_FORCED is not set"; fi
}

# ── every step works ────────────────────────────────────────────────────────
# Run in this shell, so TREE_CONV_FORCED can be read afterwards.
D="$TMP/happy"; build "$D"
tree_force_convention_files "$D" origin/main; HRC=$?
is  "happy: it returns 0"                               "$HRC" 0
is  "happy: TREE_CONV_FORCED is 1"                      "${TREE_CONV_FORCED-unset}" 1
is  "happy: there is no error sentence"                 "${TREE_CONV_ERR-unset}" ""
is  "happy: a tracked convention file takes the default version" "$(cat "$D/CLAUDE.md")" "main rules"
is  "happy: an unchanged convention file stays"         "$(cat "$D/AGENTS.md")" "main agents"
[ ! -e "$D/.claude/skills/p/SKILL.md" ] && ok "happy: a skill the default branch lacks is removed from the disk" \
  || bad "happy: a skill the default branch lacks is removed from the disk" "still on disk"
[ ! -e "$D/docs/CLAUDE.md" ] && ok "happy: a nested CLAUDE.md the default branch lacks is removed from the disk" \
  || bad "happy: a nested CLAUDE.md the default branch lacks is removed from the disk" "still on disk"
is  "happy: ...and from the index"                      "$(git -C "$D" ls-files '.claude/skills/p/SKILL.md' 'docs/CLAUDE.md')" ""
is  "happy: a file that is no convention file stays"    "$(cat "$D/src.py")" "parent code"
is  "happy: the index agrees with the disk, so no later checkout undoes it" "$(git -C "$D" diff --name-only | grep -c 'CLAUDE.md\|SKILL.md')" 0

# ── the ref must resolve first ──────────────────────────────────────────────
run_case drop_origin
skipped "no origin ref" "cannot resolve origin/main"
is  "no origin ref: no file was touched"                "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"
[ -e "$CASE_DIR/docs/CLAUDE.md" ] && ok "no origin ref: no convention file is removed" \
  || bad "no origin ref: no convention file is removed" "docs/CLAUDE.md is gone"

# ── a path that the default branch does not have is removed ────────────────
run_case :
is  "missing in default: it returns 0"                  "$RC" 0
is  "missing in default: TREE_CONV_FORCED is 1"         "$CF" 1
[ ! -e "$CASE_DIR/docs/CLAUDE.md" ] && ok "missing in default: the file is removed from the disk" \
  || bad "missing in default: the file is removed from the disk" "still on disk"
is  "missing in default: ...and from the index"         "$(git -C "$CASE_DIR" ls-files 'docs/CLAUDE.md' '.claude/skills/p/SKILL.md')" ""
is  "missing in default: a file the default has takes its version" "$(cat "$CASE_DIR/CLAUDE.md")" "main rules"

# ── a step that fails stops the review ─────────────────────────────────────
run_case fail_gitdir
skipped "no git directory" "git directory"

run_case fail_ls_files
skipped "listing fails" "list the convention files"
is  "listing fails: no file was touched"                "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

run_case fail_tr
skipped "lowercasing fails" "list the convention files"
is  "lowercasing fails: no file was touched"            "$(cat "$CASE_DIR/CLAUDE.md")" "parent rules"

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

run_case fail_index_rm
skipped "index removal fails" "from the index"

run_case fail_file_rm
skipped "file removal fails" "from the review tree"

# ── a host without GNU grep ─────────────────────────────────────────────────
# The stub must reject -z, or this case proves nothing.
"$STUBS/grep" -qz x /dev/null; is "stub: grep -z gives status 2" "$?" 2
printf 'a\n' | "$STUBS/grep" -q a; is "stub: grep without -z is the real grep" "$?" 0
run_case no_gnu_grep
is  "no GNU grep: it returns 0"                         "$RC" 0
is  "no GNU grep: TREE_CONV_FORCED is 1"                "$CF" 1
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
is  "newline name, absent: it returns 0"                "$RC" 0
[ ! -e "$CASE_DIR/$ODD" ] && ok "newline name, absent: the file is removed from the disk" \
  || bad "newline name, absent: the file is removed from the disk" "still on disk"
is  "newline name, absent: ...and from the index"       "$(git -C "$CASE_DIR" ls-files -z -- "$ODD" | wc -c | tr -d ' ')" 0
is  "newline name, absent: the file named like its first line takes the default version" "$(cat "$CASE_DIR/.claude/skills/a/odd")" "main odd"
# Both branches have the name: it takes the default version.
DEFAULT_EXTRA="$ODD" PARENT_EXTRA="$ODD" run_case :
is  "newline name, present: it returns 0"               "$RC" 0
is  "newline name, present: the file takes the default version" "$(cat "$CASE_DIR/$ODD")" "main odd"

# ── names are matched in any letter case ───────────────────────────────────
# The parent has docs/readme.md and Readme.txt-style names the default lacks,
# and a lowercase claude.md. Fixture names are lowercase, so the pattern in
# upper case has to match them.
CD="$TMP/case-names"; build "$CD"
printf 'parent lower\n' > "$CD/docs/readme.md"; printf 'parent local\n' > "$CD/claude.local.md"
printf '{}\n' > "$CD/.mcp.json"
git -C "$CD" add -A; git -C "$CD" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm lower
tree_force_convention_files "$CD" origin/main
is  "any case: it returns 0"                            "$?" 0
[ ! -e "$CD/docs/readme.md" ] && [ ! -e "$CD/claude.local.md" ] && [ ! -e "$CD/.mcp.json" ] \
  && ok "any case: lowercase readme.md, claude.local.md and .mcp.json that the default lacks are removed" \
  || bad "any case: lowercase readme.md, claude.local.md and .mcp.json that the default lacks are removed" "one is still on disk"

if [ "$FAILED" -eq 0 ]; then echo "PASS: convention files of the review tree"; else echo "FAIL: convention files of the review tree"; exit 1; fi
