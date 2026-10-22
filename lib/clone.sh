#!/usr/bin/env bash
# Clone-or-repair for the throwaway working copies the gate keeps of the
# repos it checks. pr-autoreview.sh uses it for the review clone (+ a fetch
# --prune after).
#
# Split out so it can be tested without the main script.
# Source-time side effects are forbidden here.
# Callers provide $GH (gh binary) in scope.

# Run a network git or gh call under a deadline. Such a call has none of its
# own: a connection that goes away without an RST leaves the client blocked on
# a read with nothing to wake it. The driving loop's round timeout can only
# kill the whole round, every repo's reviews with it, so each network call
# still gets its own bound here.
# Every caller already refuses to start without a timeout command (see
# lib/tools.sh), so this needs no fallback. -k: TERM first so git can unwind
# its lockfiles, KILL if it will not.
clone_net_run() { "${TIMEOUT_BIN:-timeout}" -k 10 "${PRREVIEW_CLONE_NET_TIMEOUT:-600}" "$@"; }

# A git transport call under the same deadline, authenticated by gh's own
# login. `gh repo clone` authenticates the clone, but a later plain `git fetch`
# of a private repo over https asks git's credential helper, and a machine
# with none configured (Linux without `gh auth setup-git`) fails every fetch
# with "could not read Username". The empty value first clears any helper set
# elsewhere, so the fetch works the same on every machine. An ssh remote
# ignores credential helpers. GIT_TERMINAL_PROMPT=0: when gh has no login to
# give, git would otherwise ask for a username on a terminal and sit there
# until the deadline; failing at once takes the caller's fail-closed skip.
clone_net_git() {
  GIT_TERMINAL_PROMPT=0 clone_net_run git -c credential.helper= -c "credential.helper=!\"$GH\" auth git-credential" "$@"
}

# Every caller runs this once, before its first clone or fetch. timeout(1)
# reads a deadline of 0 as "none", which is the outage above, and exits 125 on
# one it cannot parse, which ensure_usable_clone would report as a failed clone
# and skip the repo every round.
clone_net_timeout_ok() {
  [ "${PRREVIEW_CLONE_NET_TIMEOUT:-600}" -ge 1 ] 2>/dev/null && return 0
  echo "PRREVIEW_CLONE_NET_TIMEOUT must be a whole number of seconds, at least 1; got: ${PRREVIEW_CLONE_NET_TIMEOUT-} — refusing to run" >&2
  return 1
}

# $1 = owner/name, $2 = target directory, $3 = the directory to create it under.
# Returns non-zero on failure; every caller treats that as "skip this repo",
# never "carry on against whatever is there".
ensure_usable_clone() {
  local repo="$1" dir="$2" root="$3"
  # `[ -d "$dir/.git" ]` alone is not enough. A clone interrupted by a reboot,
  # a Ctrl-C, or the round's timeout leaves a .git behind with nothing
  # usable in it, and that shape would never be rebuilt: every later round
  # passes the -d test, fails at fetch, skips the repo, and repeats forever
  # until a human runs rm -rf. Fail-closed but permanently stuck, which is its
  # own kind of outage.
  if [ -d "$dir" ] && ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$repo: $dir is not a usable git clone — removing and re-cloning"
    rm -rf "$dir" || { echo "$repo: could not remove $dir"; return 1; }
  fi
  [ -d "$dir/.git" ] && return 0
  mkdir -p "$root" || { echo "$repo: cannot create $root"; return 1; }
  clone_net_run "$GH" repo clone "$repo" "$dir" -- --quiet \
    || { echo "$repo: could not clone into $dir"; return 1; }
}
