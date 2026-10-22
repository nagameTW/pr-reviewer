#!/usr/bin/env bash
# Tests for lib/tree.sh: tree_has_symlinks, tree_revert_convention_files,
# tree_force_convention_files.
# No network, no gh, no model call: run  bash tests/tree.test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. lib/tree.sh || { echo "FAIL: could not source lib/tree.sh"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── tree_has_symlinks ───────────────────────────────────────────────────────
DIR="$TMP/plain"
mkdir -p "$DIR/sub"
echo x > "$DIR/a.txt"
echo x > "$DIR/sub/b.txt"
tree_has_symlinks "$DIR" && fail "an ordinary tree with no symlinks must not refuse"

ln -s /etc/passwd "$DIR/sub/link"
OUT="$(tree_has_symlinks "$DIR")" || fail "a symlink anywhere under the tree must be found"
grep -qF "$DIR/sub/link" <<<"$OUT" || fail "the offending path must be named in the output"

# Links that stay inside the tree read nothing the tree does not hold, and
# refusing them made a repo with one AGENTS.md -> CLAUDE.md unreviewable.
# Everything that leaves the tree, lands in .git, or cannot be resolved
# still refuses. $TMP sits behind a symlink on macOS (/var -> /private/var),
# so every case below also checks that the tree root and the targets are
# compared as physical paths.
inside_fixture() { # $1 = where to build a tree whose every link stays inside
  mkdir -p "$1/docs" "$1/sub" "$1/.claude"
  git init -q "$1" || fail "git init failed"
  echo rules > "$1/CLAUDE.md"; echo x > "$1/sub/f"; echo notes > "$1/docs/claude.md"
  ln -s CLAUDE.md "$1/AGENTS.md"
  ln -s ../CLAUDE.md "$1/docs/rules.md"
  ln -s "$1/sub/f" "$1/abs-inside"
  ln -s AGENTS.md "$1/chain-inside"
  ln -s ../CLAUDE.md "$1/sub/AGENTS.md"
  git -C "$1" add -A || fail "git add failed"
}
IN="$TMP/inside"; inside_fixture "$IN"
tree_has_symlinks "$IN" >/dev/null && fail "links that resolve inside the tree must not refuse: $(tree_has_symlinks "$IN")"
refuses() { # $1 label, $2 link target, $3 link name, made in a fresh fixture
  local t="$TMP/case-$RANDOM$RANDOM" out
  inside_fixture "$t"
  ln -s "$2" "$t/$3" || fail "could not make the $1 link"
  out="$(tree_has_symlinks "$t")" || fail "$1 must refuse"
  grep -qF "$t/$3" <<<"$out" || fail "$1: the refusal must name $3 (got: $out)"
  [ "$(grep -c '^  ' <<<"$out")" = 1 ] || fail "$1: only the escaping link may be named (got: $out)"
}
echo secret > "$TMP/outside-secret"
refuses 'a relative link out of the tree' ../outside-secret leak
refuses 'an absolute link out of the tree' /etc/passwd leak
refuses 'a link to the parent of the tree' .. up
refuses 'a link into .git' .git/config gitcfg
refuses 'a link to .git itself' .git gitdir
# A directory link lets the path after it climb with `..` from the target:
# docs/subdir/../../x matches the tree's pattern and opens x beside the tree.
refuses 'a link to a directory inside the tree' ../sub docs/subdir
# A convention file is restored from the base before this runs; one that
# links elsewhere would take its content from a file the PR can edit.
refuses 'a convention file that links to a file outside the convention set' f sub/CLAUDE.md
refuses '...named in another case' f sub/claude.md
refuses '...anywhere under .claude/' ../sub/f .claude/rules.md
# Only a file git tracks under a convention name is restored, so an untracked
# one will not do.
# Names are matched in any letter case, the way the restore matches them, so
# a link to docs/claude.md is a link to a convention file the restore handles.
# This case once refused it, back when only exact-case names were restored.
LC="$TMP/link-to-lowercase-conv"; inside_fixture "$LC"; ln -s ../docs/claude.md "$LC/sub/CLAUDE.md"; git -C "$LC" add -A
tree_has_symlinks "$LC" >/dev/null && fail "a convention link to a tracked convention file named in another case must pass: $(tree_has_symlinks "$LC")"
# A tracked convention link must not vouch for its own target: that holds
# only while the id is the link's own, not the file it leads to.
TL="$TMP/tracked-conv-link"; inside_fixture "$TL"; echo x > "$TL/docs/x.md"
rm "$TL/AGENTS.md"; ln -s docs/x.md "$TL/AGENTS.md"; git -C "$TL" add -A
tree_has_symlinks "$TL" >/dev/null || fail "a tracked convention link to a file that is not one must refuse"
U="$TMP/untracked-conv"; inside_fixture "$U"; mkdir -p "$U/docs/new"; echo x > "$U/docs/new/CLAUDE.md"
mkdir -p "$U/sub2"; ln -s ../docs/new/CLAUDE.md "$U/sub2/AGENTS.md"
tree_has_symlinks "$U" >/dev/null || fail "a convention link to a convention-named file git does not track must refuse"
# A newline splits find's list into two lines, each of which could be an
# ordinary file; the whole name has to be judged as one link.
NL="$TMP/newline"; inside_fixture "$NL"; touch "$NL/x" "$NL/y"
ln -s "$TMP/outside-secret" "$NL/x"$'\n'"y" || fail "could not make the newline link"
( cd "$NL" && tree_has_symlinks "$NL" >/dev/null ) || fail "a link whose name holds a newline must refuse"
# ...even beside a regular file whose name holds \001 where the newline was,
# which is what the newline turns into on the way through.
NL1="$TMP/newline-001"; inside_fixture "$NL1"; touch "$NL1/x"$'\001'"y"
ln -s "$TMP/outside-secret" "$NL1/x"$'\n'"y" || fail "could not make the second newline link"
tree_has_symlinks "$NL1" >/dev/null || fail "a newline link must refuse even beside a file named with \\001"
# $(...) drops a trailing newline, so a link to the folder "x<newline>"
# would be worked out as the file "x" beside it, and let through.
TN="$TMP/trailing-newline"; inside_fixture "$TN"; echo x > "$TN/x"; mkdir "$TN/x"$'\n'
ln -s "x"$'\n' "$TN/nl-dir" || fail "could not make the trailing-newline link"
tree_has_symlinks "$TN" >/dev/null || fail "a link whose target name ends in a newline must refuse"
# A byte that is not UTF-8 made macOS tr fail and =~ miss under a UTF-8
# locale, so the link read as "not a convention file". APFS will not make
# such a name, other filesystems will: judge the path string directly.
( export LC_ALL=en_US.UTF-8; tree_conv_link_escapes $'d\xff/AGENTS.md' "$IN" "$IN/sub/f" ) \
  || fail "a convention link whose path holds a non-UTF-8 byte must still be judged as one"
refuses '...to the tree root itself' . self
refuses '...or to it from a subdirectory' .. sub/up
# macOS filesystems ignore case by default, so these open the real .git; on a
# case-sensitive one they dangle, which refuses too.
refuses 'a link into .git spelled in another case' .GIT/config gitcase
refuses '...reached through a subdirectory' sub/../.Git gitcase2
WT="$TMP/worktree-style"; mkdir -p "$WT"; echo 'gitdir: /elsewhere' > "$WT/.git"; ln -s .GIT "$WT/gitfile"
tree_has_symlinks "$WT" >/dev/null || fail "a link to a worktree's .git file, in another case, must refuse"
refuses 'a dangling link' no-such-file dangling
refuses 'a link that climbs out through a subdirectory' docs/../../outside-secret sneaky
mkdir -p "$TMP/outdir"; echo secret > "$TMP/outdir/key"
refuses 'a directory link out of the tree' ../outdir outlink
# A sibling whose name starts with the tree's own must not pass a prefix check.
mkdir -p "$TMP/inside-evil"; echo secret > "$TMP/inside-evil/key"
refuses 'a link into a sibling that shares the tree name as a prefix' ../inside-evil/key prefix
C="$TMP/chain"; inside_fixture "$C"; ln -s ../outside-secret "$C/hop1"; ln -s hop1 "$C/hop2"
OUT="$(tree_has_symlinks "$C")" || fail "a chain whose last hop leaves the tree must refuse"
grep -qF "$C/hop2" <<<"$OUT" || fail "every link of the escaping chain is named, including the first hop"
L="$TMP/loop"; inside_fixture "$L"; ln -s b "$L/a"; ln -s a "$L/b"
tree_has_symlinks "$L" >/dev/null || fail "a symlink loop must refuse"

# A step that cannot run is not a pass: a .git whose id cannot be read, or a
# walk whose second half died, would each let through what they guard.
# One plain in-tree link, so no other check refuses first.
G="$TMP/plain-link"; mkdir -p "$G/sub"; git init -q "$G"; echo x > "$G/sub/f"; ln -s sub/f "$G/x"
tree_has_symlinks "$G" >/dev/null && fail "the plain-link fixture must pass as it stands"
( tree_file_id() { return 1; }; tree_has_symlinks "$G" >/dev/null ) \
  || fail "a tree whose .git cannot be identified must refuse"
( tr() { cat >/dev/null; return 1; }; tree_has_symlinks "$G" >/dev/null ) \
  || fail "a walk whose name translation failed must refuse"

# A symlink INSIDE .git must not trigger a refusal — this function is meant to
# guard the reviewed CONTENT, and walking into .git risks flagging something
# git itself put there (an alternates file, a submodule gitlink) as if the
# patch had.
DIR2="$TMP/gitlink"
mkdir -p "$DIR2/.git"
ln -s /etc/passwd "$DIR2/.git/inside-link"
tree_has_symlinks "$DIR2" && fail "a symlink inside .git must be pruned, not reported"

# A walk that could not finish is not a clean tree: an unreadable directory
# makes find exit non-zero, and that must refuse. Skipped as
# root, which reads everything.
if [ "$(id -u)" != 0 ]; then
  DIR3="$TMP/unreadable"
  mkdir -p "$DIR3/locked"
  chmod 000 "$DIR3/locked"
  OUT="$(tree_has_symlinks "$DIR3")" || { chmod 700 "$DIR3/locked"; fail "a tree find could not fully walk must refuse"; }
  chmod 700 "$DIR3/locked"
  grep -qF 'could not walk' <<<"$OUT" || fail "the refusal must say the walk failed"
fi

# ── tree_revert_convention_files ────────────────────────────────────────────

# git has to answer: a tree it cannot read is "could not tell" (2), never
# "nothing to restore" (1), or a PR is reviewed against its own rules.
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"
printf 'x\n' > "$NOGIT/CLAUDE.md"
tree_revert_convention_files "$NOGIT"; RC=$?
[ "$RC" = 2 ] || fail "a tree git cannot read must return 2, got $RC"
# A real git repo: the function reads git's own tracked/untracked state
# (ls-files --others, diff --name-only), not the filesystem directly.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
mkdir -p "$REPO/.claude/skills/existing"
printf 'original conventions\n' > "$REPO/CLAUDE.md"
printf 'original agents rules\n' > "$REPO/AGENTS.md"
printf 'original src\n' > "$REPO/src.py"
printf 'kept\n' > "$REPO/.claude/skills/existing/SKILL.md"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

# Nothing touched a convention path — must be a no-op and report "no hit".
printf 'changed src only\n' > "$REPO/src.py"
tree_revert_convention_files "$REPO" \
  && fail "a patch touching no convention file must report no hit (exit 1)"
[ "$(cat "$REPO/src.py")" = "changed src only" ] \
  || fail "an ordinary file must be left alone when nothing convention-shaped changed"
git -C "$REPO" checkout -q -- src.py

# A patch modifies the TRACKED CLAUDE.md and adds an UNTRACKED, NESTED
# .claude/skills/new/SKILL.md — the exact subdirectory shape three earlier
# versions of this guard missed by writing a git pathspec instead of a
# shell-case path match. AGENTS.md (root, tracked) and docs/CLAUDE.md
# (nested, untracked) ride along in the same scenario: lib/tree.sh's case
# has six arms (CLAUDE.md, */CLAUDE.md, AGENTS.md, */AGENTS.md, .claude/*,
# */.claude/*) and only three were exercised anywhere in this file before —
# AGENTS.md and */AGENTS.md could be deleted from the case entirely and
# every assertion here would still pass.
printf 'the PR rewrote its own rules\n' > "$REPO/CLAUDE.md"
printf 'the PR rewrote the agent rules too\n' > "$REPO/AGENTS.md"
mkdir -p "$REPO/.claude/skills/new" "$REPO/docs"
printf 'author-written rule\n' > "$REPO/.claude/skills/new/SKILL.md"
printf 'author-written nested rules\n' > "$REPO/docs/CLAUDE.md"
printf 'changed src too\n' > "$REPO/src.py"

tree_revert_convention_files "$REPO" \
  || fail "a patch touching CLAUDE.md and .claude/ must report a hit (exit 0)"
[ "$(cat "$REPO/CLAUDE.md")" = "original conventions" ] \
  || fail "the tracked convention file must be restored to its committed content"
[ "$(cat "$REPO/AGENTS.md")" = "original agents rules" ] \
  || fail "the tracked AGENTS.md must be restored to its committed content too"
[ -e "$REPO/.claude/skills/new/SKILL.md" ] \
  && fail "the untracked NESTED convention file the patch added must be deleted"
[ -e "$REPO/docs/CLAUDE.md" ] \
  && fail "the untracked NESTED docs/CLAUDE.md the patch added must be deleted too"
[ "$(cat "$REPO/.claude/skills/existing/SKILL.md")" = "kept" ] \
  || fail "an existing, untouched convention file must survive"
[ "$(cat "$REPO/src.py")" = "changed src too" ] \
  || fail "a non-convention file the same patch touched must be left alone"
git -C "$REPO" checkout -q -- CLAUDE.md AGENTS.md src.py
rm -rf "$REPO/.claude/skills/new" "$REPO/docs"

# A .claude/ NOT at the repo root — the specific shape a plain `.claude/*`
# case pattern (root-anchored) does not match, and the one three earlier
# versions of this guard missed by writing a GIT PATHSPEC instead: measured
# separately, `git ls-files -- '*/.claude'` returns nothing at all for a
# nested payload/.claude/skills/x/SKILL.md. A nested docs/AGENTS.md rides
# along — the other case arm the earlier fix left unexercised — and an
# untracked NON-convention file (newsrc.py) rides along too: without it,
# deleting the `conv_is_convention` guard out of the untracked-files loop
# entirely (so `rm -rf` fires on every untracked path) would still pass
# every assertion in this file, because nothing here ever proved an
# ordinary new source file survives.
mkdir -p "$REPO/packages/web/.claude/skills/nested" "$REPO/docs"
printf 'nested author-written rule\n' > "$REPO/packages/web/.claude/skills/nested/SKILL.md"
printf 'nested agent rules\n' > "$REPO/docs/AGENTS.md"
printf 'a brand new source file\n' > "$REPO/newsrc.py"
tree_revert_convention_files "$REPO" \
  || fail "a .claude/ directory below the repo root must still be caught (the */.claude/* case)"
[ -e "$REPO/packages/web/.claude/skills/nested/SKILL.md" ] \
  && fail "a NESTED (non-root) .claude/ file the patch added must be deleted too"
[ -e "$REPO/docs/AGENTS.md" ] \
  && fail "a NESTED (non-root) AGENTS.md the patch added must be deleted too (the */AGENTS.md case)"
[ "$(cat "$REPO/newsrc.py")" = "a brand new source file" ] \
  || fail "an untracked NON-convention file must survive — the guard must not delete every untracked path"

# ── the convention files of every PR come from the default branch ──────────
# The flow of pr-autoreview.sh on throwaway repos: the tree is at the merge
# base, the PR's diff is applied, the PR's own convention files are reverted,
# and the convention files of origin/main are copied in. Names are lowercase
# in every fixture, so the match has to work in any letter case.
flow_fixture() { # $1 = directory; leaves a tree at the merge base with the PR applied
  local d="$1"
  g() { git -C "$d" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
  mkdir -p "$d/.github"; git init -q "$d"
  printf 'old readme\n' > "$d/readme.md"
  printf 'checklist v1\n' > "$d/.github/review-checks.md"
  printf 'code 1\n' > "$d/src.py"
  g add -A; g commit -qm merge-base
  git -C "$d" branch pr
  # The default branch moves on: a newer readme and a newer checklist.
  printf 'default readme\n' > "$d/readme.md"
  printf 'checklist v2\n' > "$d/.github/review-checks.md"
  printf 'default notes\n' > "$d/notes.md"
  g add -A; g commit -qm default-moves; git -C "$d" update-ref refs/remotes/origin/main HEAD
  # The PR edits the readme, adds convention files and edits code.
  g checkout -q pr
  printf 'pr readme\n' > "$d/readme.md"
  printf 'pr rules\n' > "$d/contributing.md"
  printf 'pr local rules\n' > "$d/claude.local.md"
  printf '{"pr":1}\n' > "$d/.mcp.json"
  printf 'code 2\n' > "$d/src.py"
  g add -A; g commit -qm pr; git -C "$d" diff HEAD~1 HEAD > "$d.patch"
  g checkout -q --detach pr~1
  git -C "$d" apply "$d.patch" || fail "the fixture's patch must apply to the merge base"
}
FL="$TMP/flow"; flow_fixture "$FL"
git -C "$FL" checkout -q -f --detach origin/main || fail "the fixture could not check out the default branch"
git -C "$FL" apply --check "$FL.patch" 2>/dev/null \
  && fail "the fixture must show why the copy comes after the diff: the diff does not apply to the newer default branch"
flow_fixture "$TMP/flow2"; FL="$TMP/flow2"
tree_revert_convention_files "$FL"; RC=$?
[ "$RC" = 0 ] || fail "the PR wrote convention files, the revert must report a hit (got $RC)"
tree_force_convention_files "$FL" origin/main || fail "copying the convention files must work: ${TREE_CONV_ERR-}"
[ "$(cat "$FL/readme.md")" = "default readme" ] \
  || fail "a readme.md the PR modified must come from the default branch (got: $(cat "$FL/readme.md"))"
[ "$(cat "$FL/.github/review-checks.md")" = "checklist v2" ] \
  || fail "the checklist of the default branch is newer than the merge base's: the review must get the newer one"
[ -e "$FL/contributing.md" ] && fail "a contributing.md that the PR adds must be removed"
[ -e "$FL/claude.local.md" ] && fail "a claude.local.md that the PR adds must be removed"
[ -e "$FL/.mcp.json" ] && fail "a .mcp.json that the PR adds must be removed"
[ "$(cat "$FL/src.py")" = "code 2" ] || fail "a file that is no convention file keeps the PR's change"
[ -e "$FL/notes.md" ] && fail "a file that is no convention file is not copied from the default branch"
[ -z "$(git -C "$FL" ls-files -- contributing.md claude.local.md .mcp.json)" ] \
  || fail "a convention file that the default branch lacks must leave the index too"
[ "${TREE_CONV_FORCED-}" = 1 ] || fail "TREE_CONV_FORCED must say that files were copied"
# A convention file that only the default branch has comes in even when the
# tree never had it (the checklist of a PR cut before the default branch got one).
NC="$TMP/flow-new-checklist"; mkdir -p "$NC/.github"; git init -q "$NC"
printf 'code\n' > "$NC/src.py"
git -C "$NC" add -A; git -C "$NC" -c user.email=t@example.com -c user.name=t commit -qm base
printf 'new checklist\n' > "$NC/.github/review-checks.md"
git -C "$NC" add -A; git -C "$NC" -c user.email=t@example.com -c user.name=t commit -qm default
git -C "$NC" update-ref refs/remotes/origin/main HEAD; git -C "$NC" checkout -q --detach HEAD~1
tree_force_convention_files "$NC" origin/main || fail "copying into a tree that lacks the file must work: ${TREE_CONV_ERR-}"
[ "$(cat "$NC/.github/review-checks.md" 2>/dev/null)" = "new checklist" ] \
  || fail "a checklist that only the default branch has must be copied into the tree"
# A ref that does not resolve is an error with a reason, not a tree without rules.
tree_force_convention_files "$NC" origin/nope; RC=$?
[ "$RC" = 1 ] || fail "an unresolvable ref must return 1 (got $RC)"
grep -qF 'cannot resolve origin/nope' <<<"${TREE_CONV_ERR-}" || fail "the error must name the ref (got: ${TREE_CONV_ERR-})"
ERR="$( ( tree_force_convention_files ) 2>&1 )"; RC=$?
[ "$RC" -ne 0 ] && grep -qF "tree_force_convention_files needs a directory" <<<"$ERR" \
  || fail "tree_force_convention_files with no argument must name itself in the error (got: $ERR)"

# ── both functions must NAME themselves in a missing-argument error, not
#    just crash on a bare unbound-variable message (the
#    ${1:?...} guards added for exactly that have no assertion anywhere in
#    this file — checking only the exit code would not catch reverting to a
#    bare "$1", because `set -u` already fails closed on that too; the
#    error TEXT is the only thing the named guard actually adds) ─────────
ERR="$( ( tree_has_symlinks ) 2>&1 )"; RC=$?
[ "$RC" -ne 0 ] || fail "tree_has_symlinks with no argument must exit non-zero, not succeed"
grep -qF "tree_has_symlinks needs a directory" <<<"$ERR" \
  || fail "tree_has_symlinks with no argument must name itself in the error (got: $ERR)"
ERR="$( ( tree_revert_convention_files ) 2>&1 )"; RC=$?
[ "$RC" -ne 0 ] || fail "tree_revert_convention_files with no argument must exit non-zero, not succeed"
grep -qF "tree_revert_convention_files needs a directory" <<<"$ERR" \
  || fail "tree_revert_convention_files with no argument must name itself in the error (got: $ERR)"

# No assertion count in this message: it drifted from the real count twice
# before because nothing forces an edit here when a test is
# added or removed elsewhere in the file.
# ── tree_binary_paths ───────────────────────────────────────────────────────
# A PR diff as the GitHub diff API renders it: a text hunk plus binary stubs with no
# content. The text change must still reach the tree, the binaries must not.
BR="$TMP/bin"; mkdir -p "$BR"; git -C "$BR" init -q
printf 'a\n' > "$BR/t.txt"; printf '\000\001' > "$BR/old.bin"
git -C "$BR" add -A; git -C "$BR" -c user.email=t@t -c user.name=t commit -qm base
printf 'a\nb\n' > "$BR/t.txt"; printf '\000\002' > "$BR/old.bin"; mkdir -p "$BR/img"; printf '\000\003' > "$BR/img/new.png"
git -C "$BR" add -A; git -C "$BR" diff --cached > "$TMP/pr.diff"; git -C "$BR" reset -q --hard
grep -q '^Binary files' "$TMP/pr.diff" || fail "the fixture must render binaries as stubs, the way the diff API does"
git -C "$BR" apply "$TMP/pr.diff" 2>/dev/null && fail "the fixture must reproduce the failure: a stub makes the whole apply refuse"
BINS="$(tree_binary_paths "$TMP/pr.diff")" || fail "tree_binary_paths refused a patch with plain binary paths"
[ "$BINS" = "$(printf 'img/new.png\nold.bin')" ] || [ "$BINS" = "$(printf 'old.bin\nimg/new.png')" ] \
  || fail "tree_binary_paths must list exactly the binary files (got: $BINS)"
EXC=(); while IFS= read -r p; do EXC+=("--exclude=$p"); done <<<"$BINS"
git -C "$BR" apply "${EXC[@]}" "$TMP/pr.diff" || fail "with the binaries excluded the text change must apply"
[ "$(cat "$BR/t.txt")" = "$(printf 'a\nb')" ] || fail "the text change must be in the tree"
[ ! -e "$BR/img/new.png" ] || fail "an added binary must stay off the disk"
[ "$(od -An -tx1 "$BR/old.bin" | tr -d ' ')" = 0001 ] || fail "a modified binary must keep its old content"
printf 'diff --git a/t.txt b/t.txt\n--- a/t.txt\n+++ b/t.txt\n@@ -1 +1,2 @@\n a\n+b\n' > "$TMP/text.diff"
[ -z "$(tree_binary_paths "$TMP/text.diff")" ] || fail "a patch with no binaries lists nothing"
tree_binary_paths "$TMP/text.diff" >/dev/null || fail "a patch with no binaries is not an error"
# A path --exclude would read as a pattern: '*.png' excluded as a pattern
# would also drop a text file's changes, so the helper refuses instead.
sed 's#img/new.png#img/*.png#g' "$TMP/pr.diff" > "$TMP/glob.diff"
tree_binary_paths "$TMP/glob.diff" >/dev/null && fail "a binary path with a glob character must be refused"
printf 'not a patch\n' > "$TMP/junk.diff"
tree_binary_paths "$TMP/junk.diff" >/dev/null && fail "a patch git cannot read must be refused"

echo "PASS: lib/tree.sh (tree_has_symlinks, tree_revert_convention_files, tree_force_convention_files, tree_binary_paths)"
