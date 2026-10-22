#!/usr/bin/env bash
# Safety checks on a tree about to be handed to the model, in a lib so a
# hole found once is closed for every caller rather than drifting.
# Source-time side effects are forbidden here.

# Is there a symlink under $1 (excluding .git) this guard does not accept: one
# that leads out of the tree, into .git, to a folder or nowhere, or from a
# convention file to a file that is not one?
# $1 = the tree's root directory.
#
# The model's tool scope is a PATH pattern (Read(/$1/**)), and a symlink
# inside the tree pointing outside it — say, at a credentials file or the
# App's private key — makes a literally in-scope path read something the
# tree never actually contains. Whether the tool layer resolves symlinks
# before matching its own rules is not something a review harness should
# bet on either way, so such a link refuses the review outright.
#
# A link whose final target is inside the tree reads nothing the tree does
# not already hold, and refusing those made a repo with one ordinary
# `AGENTS.md -> CLAUDE.md` unreviewable. So every link is followed to the
# end (tree_link_target): a regular file inside the tree and outside .git is
# fine; outside, into .git, dangling, looping, or anything that cannot be
# resolved refuses. So does ANY link to a directory, even one inside: the path
# after it can go on with `..`, which the OS resolves from the target while a
# path pattern reads it from the link, so `docs/sub/../../x` matches the tree's
# pattern and opens x beside the tree. A file cannot be walked through.
# And a link at a convention path (TREE_CONV_RE) must lead to a convention
# file git tracks under that exact name: only those are restored from the base
# before this runs, so `AGENTS.md -> docs/x.md` would let a PR that edits
# docs/x.md write the rules it is judged by.
#
# Walking the filesystem, not `git ls-tree`: a symlink can arrive from a
# source `git ls-tree` never sees (an extracted archive, a patch applied on
# top of the checkout), and the PR's diff goes on with `git apply`.
# A tree-walk covers whichever one actually happened without the caller
# needing to say so.
#
# Callers that put MORE content into the tree after this check (a patch
# applied afterwards) must call it again — this function only answers for
# the tree AS IT STANDS at the moment it runs.
tree_has_symlinks() {
  # A caller under `set -uo pipefail` that forgets the argument
  # used to die on a bare "$1: unbound variable" — true either way, but the
  # actual failure (which guard, which call site) was left to the reader to
  # reconstruct. This says it once, by name, at the point it happened.
  local dir="${1:?tree_has_symlinks needs a directory}" all root gitid link target lid hit=""
  # find's own status, not the pipeline's: a find that died half way (an
  # unreadable directory) must not read as "no symlinks".
  # NUL-separated, and a newline inside a name becomes \001, so a name that
  # held one stays one line instead of two innocent-looking ones. Any name
  # with \001 in it then refuses outright: resolving it would open whatever
  # file the PR named with a real \001, not the link.
  all="$(find "$dir" -path "$dir/.git" -prune -o -type l -print0 2>/dev/null \
         | LC_ALL=C tr '\n\0' '\001\n'; [ "${PIPESTATUS[*]}" = "0 0" ])" \
    || { echo "could not walk the whole review tree to look for symlinks — refusing to review (fail closed)"; return 0; }
  [ -n "$all" ] || return 1
  root="$(cd -P "$dir" 2>/dev/null && pwd -P)" \
    || { echo "could not resolve the review tree's own path — refusing to review (fail closed)"; return 0; }
  # No id for a .git that is there would switch the .git check off.
  gitid=""
  if [ -e "$root/.git" ] || [ -L "$root/.git" ]; then
    gitid="$(tree_file_id "$root/.git")" \
      || { echo "could not identify the review tree's .git — refusing to review (fail closed)"; return 0; }
  fi
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in *$'\001'*) hit="$hit$link"$'\n'; continue ;; esac
    target="$(tree_link_target "$link")" || target=""
    # The path worked out must be the file the OS opens through the link: a
    # name ending in a newline, which $(...) drops, would make them two.
    lid="$(tree_file_id_followed "$link")" || lid=""
    [ -n "$lid" ] && [ "$lid" = "$(tree_file_id "$target")" ] || target=""
    case "$target/" in
      "$root/"*)
        [ -f "$target" ] && [ ! -d "$target" ] \
          && ! tree_path_in "$target" "$root" "$gitid" \
          && ! tree_conv_link_escapes "${link#"$dir"/}" "$root" "$target" && continue ;;
    esac
    hit="$hit$link"$'\n'
  done <<<"$all"
  [ -n "$hit" ] || return 1
  echo "symlink(s) that lead to a directory, out of the review tree, into .git, from a convention file to anything but a convention file git tracks, or nowhere — refusing to review (fail closed):"
  head -5 <<<"${hit%$'\n'}" | sed 's/^/  /'
  return 0
}

# 0 when path $1, under root $2, is the entry whose device:inode is $3 or
# sits below it; an empty $3 matches nothing. By identity, not by name: on a
# case-insensitive filesystem (macOS by default) `.GIT/config` opens
# `.git/config`, and `cd -P` keeps the spelling it was given.
tree_path_in() {
  local p="${1-}" root="${2-}" id="${3-}"
  [ -n "$id" ] || return 1
  while [ "${#p}" -gt "${#root}" ]; do
    [ "$(tree_file_id "$p")" = "$id" ] && return 0
    p="${p%/*}"
  done
  return 1
}

# 0 when link path $1, relative to tree root $2, is a convention file and
# its target $3 is not one tree_force_convention_files handles. The link is
# matched in any case: a case-insensitive filesystem opens agents.md when
# AGENTS.md is asked for. The target is matched by device:inode against the
# files git tracks under a convention name in any case, the set the restore
# works from: `docs/claude.md` is in it, `docs/x.md` is not. The names are
# lowercased as a whole list, so a lookup costs no process per file. A listing
# git could not give matches nothing.
tree_conv_link_escapes() {
  # C locale for tr and =~ alike: under UTF-8 a byte that is not valid
  # UTF-8 makes macOS tr fail and =~ miss, and either one would read a
  # convention link as "not a convention file" and let it through.
  local LC_ALL=C l f lf id
  l="$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"${1-}")" || return 0
  [[ $l =~ $TREE_CONV_RE ]] || return 1
  id="$(tree_file_id "${3-}")" || return 0
  while IFS= read -r -d '' f <&3 && IFS= read -r -d '' lf <&4; do
    [[ $lf =~ $TREE_CONV_RE ]] && [ "$(tree_file_id "$2/$f")" = "$id" ] && return 1
  done 3< <(git -C "${2-}" ls-files -z 2>/dev/null) \
       4< <(git -C "${2-}" ls-files -z 2>/dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]')
  return 0
}

# device:inode of $1 itself, a link's own and not its target's (no -L):
# followed, a tracked `AGENTS.md -> docs/x.md` would match its own target and
# vouch for it. GNU's stat first: BSD's has no -c and fails it, while GNU's
# -f means --file-system and would print something else.
tree_file_id() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }

# device:inode of what $1 finally leads to, links followed by the OS itself.
# Only ever compared with tree_file_id of a path worked out separately.
tree_file_id_followed() { stat -L -c '%d:%i' "$1" 2>/dev/null || stat -L -f '%d:%i' "$1" 2>/dev/null; }

# The physical path symlink $1 finally points at, every link on the way
# followed. Fails for a dangling link, a loop, or more than 40 hops.
tree_link_target() {
  local p="${1:?tree_link_target needs a path}" n=0 t
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    t="$(readlink "$p")" || return 1
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  [ -e "$p" ] || return 1
  if [ -d "$p" ]; then
    (cd -P "$p" 2>/dev/null && pwd -P)
    return
  fi
  t="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$t" "$(basename "$p")"
}

# Every convention file of a review tree comes from the default branch, for
# every PR. Two functions do it, in this order, after the PR's diff is applied:
#   1. tree_revert_convention_files undoes what the diff wrote.
#   2. tree_force_convention_files copies the default branch's versions in.
# The copy comes AFTER the diff. The diff is computed against the merge base,
# so a convention file that is newer on the default branch would make the
# patch fail if it were copied first.
#
# The convention set, in three shapes (pr-autoreview.sh reads two of them):
# a regex over a LOWERCASED path, words for the prompt note that tells the
# model which files on disk are NOT the PR's, and tree_conv_filter, which
# applies the regex to a list of names in any letter case. Names are matched
# in any case: a macOS checkout opens readme.md when README.md is asked for.
# shellcheck disable=SC2034  # read by pr-autoreview.sh
TREE_CONV_RE='(^|/)(claude|agents|claude\.local)\.md$|(^|/)\.mcp\.json$|(^|/)\.claude/|(^|/)(readme|contributing)(\.[^/]*)?$|^\.github/review-checks\.md$'
# shellcheck disable=SC2034  # read by pr-autoreview.sh
TREE_CONV_NAMES='CLAUDE.md, CLAUDE.local.md, AGENTS.md, .mcp.json, anything under .claude/, any README or CONTRIBUTING file, .github/review-checks.md, in any letter case'

# Print, NUL-ended, the names in NUL-ended list file $1 that are convention
# files, in any letter case. Returns 2 when the list cannot be read whole.
# The list is lowercased once with LC_ALL=C tr, which maps byte to byte, so
# the two lists stay in step and a lookup costs no process per name. tr and
# the lists live in a file beside $1: a process substitution would hide a tr
# that died half way, and a short list reads as "fewer convention files".
tree_conv_filter() {
  # C locale for tr and =~ alike, as in tree_conv_link_escapes: a byte that is
  # not valid UTF-8 would make =~ miss, and the file would stay on disk.
  local LC_ALL=C list="${1:?tree_conv_filter needs a list file}" n="" l=""
  LC_ALL=C tr '[:upper:]' '[:lower:]' <"$list" >"$list.lc" || return 2
  [ "$(wc -c <"$list")" = "$(wc -c <"$list.lc")" ] || return 2
  while IFS= read -r -d '' n <&3 && IFS= read -r -d '' l <&4; do
    if [[ $l =~ $TREE_CONV_RE ]]; then printf '%s\0' "$n" || return 2; fi
  done 3<"$list" 4<"$list.lc"
  # A last name with no NUL after it: git ended the list in the middle of a name.
  [ -z "$n" ] || return 2
  return 0
}

# Revert any convention file that a patch just added or modified in $1, so a
# change that edits its own governing rules is not judged by the rules it
# just wrote: otherwise a PR loosening its own constraint reviews as
# compliant with the constraint it loosened.
# $1 = the tree's root directory.
#
# Untracked ones (added by the patch) are deleted outright; tracked ones
# (modified) are restored from the index (`checkout --` with no ref): the
# state the tree was checked out to before the patch landed, the PR's merge
# base. tree_force_convention_files then replaces that state with the default
# branch's.
#
# THROUGH GIT, not a regex over diff text: matching author-controlled text is
# the weak link, asking git which files exist is not. The names git lists are
# then matched by tree_conv_filter, a regex over the path. Not a git pathspec:
# `git ls-files -- '*/.claude'` returns nothing at all for a path like
# .claude/skills/x/SKILL.md, because a git pathspec wildcard only tail-matches,
# so a pathspec form silently misses every `.claude/` directory below the repo
# root.
#
# Returns 0 if anything was reverted, 1 if nothing matched (the common case,
# not a failure) — the caller uses this to decide whether the model needs
# telling that some on-disk content is not what the PR actually wrote — and 2
# when git could not answer or a restore failed. 2 is not "nothing matched":
# a listing that failed reads exactly like an empty one, and treating it as
# such reviews a PR against rules it may have just written.
tree_revert_convention_files() {
  local dir="${1:?tree_revert_convention_files needs a directory}" conv hit=1
  # Each list goes to a file inside the tree's own .git and is read from
  # there, so git's exit status is seen; a process substitution hides it.
  local gd
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" && [ -d "$gd" ] || return 2
  git -C "$dir" ls-files --others -z > "$gd/conv-untracked" 2>/dev/null || return 2
  tree_conv_filter "$gd/conv-untracked" > "$gd/conv-untracked-hit" || return 2
  while IFS= read -r -d '' conv; do
    hit=0
    rm -rf "${dir:?}/$conv"
  done < "$gd/conv-untracked-hit"
  # One checkout PER FILE. `git checkout -- <many pathspecs>` aborts the
  # whole command as soon as one pathspec matches nothing, and most of these
  # match nothing in any given repo — so the batch form silently restores
  # NOTHING while looking like it worked.
  git -C "$dir" diff --name-only -z > "$gd/conv-changed" 2>/dev/null || return 2
  tree_conv_filter "$gd/conv-changed" > "$gd/conv-changed-hit" || return 2
  while IFS= read -r -d '' conv; do
    hit=0
    git -C "$dir" checkout -- "$conv" 2>/dev/null || return 2
  done < "$gd/conv-changed-hit"
  return "$hit"
}

# Make every convention file in tree $1 the version in commit $2, whatever the
# PR or its parent branch wrote:
#   - a convention file in the tree that $2 has is replaced with $2's copy;
#   - a convention file in the tree that $2 lacks is removed (disk and index);
#   - a convention file that only $2 has is added.
# Returns 0 when done and sets TREE_CONV_FORCED to 1 when it touched a file,
# else 0 (and to 0 on a failure). Returns 1 and sets TREE_CONV_ERR to a sentence when a step failed,
# and the caller must not review: a tree where one convention file still comes
# from the PR or its parent holds rules that the author chose. Nothing is
# removed before both file lists are read, so a failed read leaves the tree as
# it was.
#
# Why the index matters: `rm` alone leaves the blob staged, the path then
# shows up in `git diff --name-only`, and a later `git checkout -- <path>`
# writes the old version straight back. Removals run before copies, so on a
# filesystem that ignores case, removing Readme.md cannot delete a README.md
# that was just copied in.
# Trade-off: a name is compared with each convention name of $2 in turn. A
# repo with 100 convention files takes 100 string comparisons per tree file
# that matches, which is nothing next to the git calls.
# shellcheck disable=SC2034  # TREE_CONV_FORCED and TREE_CONV_ERR are read by pr-autoreview.sh
tree_force_convention_files() {
  local dir="${1:?tree_force_convention_files needs a directory}" ref="${2:?tree_force_convention_files needs a commit}"
  local gd p q have touched=0
  local -a want=()
  TREE_CONV_FORCED=0; TREE_CONV_ERR=""
  # Before anything is removed: against an unresolvable ref every path would
  # take the removal arm and the tree would end up with no conventions at all.
  git -C "$dir" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 \
    || { TREE_CONV_ERR="cannot resolve $ref to copy the convention files from"; return 1; }
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" && [ -d "$gd" ] \
    || { TREE_CONV_ERR="could not find the git directory of the review tree"; return 1; }
  git -C "$dir" ls-files -z > "$gd/conv-all-tree" 2>/dev/null \
    && tree_conv_filter "$gd/conv-all-tree" > "$gd/conv-have" \
    || { TREE_CONV_ERR="could not list the convention files in the review tree"; return 1; }
  git -C "$dir" ls-tree -r --name-only -z "$ref" > "$gd/conv-all-ref" 2>/dev/null \
    || { TREE_CONV_ERR="could not list the files of $ref"; return 1; }
  tree_conv_filter "$gd/conv-all-ref" > "$gd/conv-want" \
    || { TREE_CONV_ERR="the file list of $ref ends in the middle of a name"; return 1; }
  # The wanted names go into an array once, so a look-up is a string
  # comparison. grep -z is GNU only, and macOS has no GNU grep.
  # `read -d ''` keeps a newline inside a name.
  while IFS= read -r -d '' p; do want[${#want[@]}]="$p"; done < "$gd/conv-want"
  while IFS= read -r -d '' p; do
    have=1
    for q in ${want[@]+"${want[@]}"}; do
      if [ "$q" = "$p" ]; then have=0; break; fi
    done
    if [ "$have" = 1 ]; then
      git -C "$dir" rm -q --cached -- "$p" 2>/dev/null \
        || { TREE_CONV_ERR="could not remove a convention file from the index"; return 1; }
      rm -f "${dir:?}/$p" \
        || { TREE_CONV_ERR="could not delete a convention file from the review tree"; return 1; }
      touched=1
    fi
  done < "$gd/conv-have"
  for p in ${want[@]+"${want[@]}"}; do
    git -C "$dir" checkout "$ref" -- "$p" 2>/dev/null \
      || { TREE_CONV_ERR="could not check out a convention file from $ref"; return 1; }
    touched=1
  done
  TREE_CONV_FORCED="$touched"
  return 0
}

# The binary files patch $1 changes, one path per line, for `git apply
# --exclude`. The GitHub diff API renders a binary file as a "Binary files ... differ"
# stub with no content, and one stub makes `git apply` refuse the whole patch,
# so a PR that adds an image would lose every text change from the tree too.
# Excluding the stubs keeps the text changes and still keeps every binary file
# off the disk the model can Read (an image can carry rendered instructions).
#
# Returns 1, printing nothing, when git cannot read the patch or a binary path
# is one --exclude would read as a pattern (* ? [ \), C-quoted by git, or a
# rename: excluding it could match other files and silently drop their
# changes, so the caller keeps the old all-or-nothing apply for that PR.
tree_binary_paths() {
  local patch="${1:?tree_binary_paths needs a patch file}" out bins
  out="$(git apply --numstat "$patch" 2>/dev/null)" || return 1
  bins="$(awk -F'\t' '$1 == "-" && $2 == "-" { print $3 }' <<<"$out")"
  case "$bins" in *'*'* | *'?'* | *'['* | *'\'* | *'"'* | *' => '*) return 1 ;; esac
  [ -z "$bins" ] || printf '%s\n' "$bins"
}
