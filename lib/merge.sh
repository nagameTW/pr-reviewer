#!/usr/bin/env bash
# Four questions about a PR that pr-autoreview.sh and tests share:
# whether it targets the default branch, whether it is small enough for one
# review pass to count, its merge base (which the review tree is built on), and
# an auto-merge armed on a head the gate has not reviewed yet.
# Source-time side effects are forbidden here: tests must be able to source
# this file without an App private key, network, or token minting.
# Callers provide $GH (gh binary) and $REPO (owner/name) in scope.

# Disarm an auto-merge armed on a head this gate has not reviewed yet. An
# armed auto-merge waits only for GitHub's own conditions, and ANY
# collaborator's approve can meet them, so it merges a head the gate never
# reviewed, or one it asked changes on. The caller runs this on every head it
# has not handled yet.
# $1 = PR info JSON (autoMergeRequest), $2 = PR number. Prints one line when
# it acts; returns 1 only when the disarm itself failed.
#
# pr-autoreview.sh sets GATE_DISARM_AUTO_MERGE. Off leaves GitHub's
# auto-merge to whoever armed it: a token scoped to commenting could not
# disarm it anyway, and a failed disarm skips the PR every round. 0 makes
# this a no-op; a caller that sets nothing gets it on.
disarm_unreviewed_auto_merge() {
  [ "${GATE_DISARM_AUTO_MERGE:-1}" = 1 ] || return 0
  [ "$(jq -r '.autoMergeRequest != null' <<<"${1-}" 2>/dev/null)" = true ] || return 0
  if "$GH" pr merge "$2" --repo "$REPO" --disable-auto >/dev/null 2>&1; then
    echo "PR #$2: auto-merge was armed on a head this gate has not reviewed yet — disarmed until this head is reviewed"
  else
    echo "PR #$2: auto-merge is armed on a head this gate has not reviewed yet, and disarming it FAILED — will try again next round"
    return 1
  fi
}

# Does the PR target the repo's DEFAULT branch?
# $1 = the PR's base branch, $2 = the repo's default branch.
#
# A stacked PR (base is another feature branch) gets a weaker review than it
# looks. Its tree is built on its own merge base, which sits on the AUTHOR's
# parent branch, an unprotected ref, so the convention files in it are the
# author's to write. The caller forces those back to the default branch's
# versions, so the author cannot choose what counts as "the project's
# conventions", and tells the model what tree it is reading
# (prompt_stacked_clause in lib/prompt.sh). The prompts were made to say what
# the tree actually is; this keeps that answer honest for a stacked PR.
#
# Fail closed on a missing value: not knowing where a PR lands is not a reason
# to treat it as landing on the default branch.
merge_base_allowed() {
  local base="${1-}" default="${2-}"
  [ -n "$base" ] && [ -n "$default" ] && [ "$base" = "$default" ]
}

# The merge base's commit SHA between $2 and $3 in $1 (owner/name), via the
# GitHub compare API — the call pr-autoreview.sh makes before applying a
# PR's diff, so a three-dot diff is applied to the commit git itself agrees
# is the merge base, not the (possibly moved) default-branch tip. Shared so a
# future change to HOW this is resolved reaches every caller together: it
# used to be two hand-copied `-q '.merge_base_commit.sha'` calls with no test
# able to tell them apart.
# Echoes the SHA (or an empty/malformed string on failure — validating the
# shape is the caller's job) and does not itself fail closed.
# $1 = owner/name, $2 = base ref, $3 = head sha. The base ref is the PR's
# own and goes into a URL path, where a `%` or `#` in it would change what the
# URL asks for, and `gh api` fills in `{owner}`, `{repo}` and `{branch}`
# itself, so those three characters are percent-encoded. Git's ref-name rules
# already keep out `?`, spaces and `..`.
merge_base_sha() {
  local base="${2-}"
  base="${base//%/%25}"; base="${base//#/%23}"; base="${base//\{/%7B}"
  "$GH" api "repos/${1-}/compare/${base}...${3-}" -q '.merge_base_commit.sha' 2>/dev/null
}

# Is this PR small enough that ONE review pass is worth acting on?
# $1 = changed lines (additions + deletions), $2 = changed files,
# $3 = the line ceiling, $4 = the file ceiling.
#
# Not an ergonomics rule. Review quality falls with diff size: F1 0.657
# under 10 changed lines and 0.80 at 10-50, then 0.043-0.070 past 50
# (arXiv:2606.15689, Figure 3, Claude Haiku 4.5 only; lib/chunk.sh has the
# buckets). Human review shows the same shape: the SmartBear study of 2,500
# reviews at Cisco concludes that a review should stay under 200 lines and
# not exceed 400, because anything larger overwhelms the reviewer. Google's
# eng-practices guide says "1000 lines is usually too large".
#
# The failure this closes: an oversized diff does not produce a WORSE
# verdict, it produces a CONFIDENT one from a pass that silently read a
# fraction of the change, and a confident approve is what gets a PR merged.
# Refusing is the honest move, and this ceiling is how the gate makes it.
#
# The ceilings are the caller's (PRREVIEW_GATE_MAX_REVIEW_*), deliberately well
# above a normal PR's size: the point is to catch the change nobody could
# review in one pass, not to turn away every ordinary feature branch. Over
# either ceiling the caller asks the author to split the PR instead of
# reviewing it, unless an exemption applies (lib/split.sh).
#
# Fail closed on anything non-numeric: not knowing how big a change is is not
# a reason to trust one pass over it. A ceiling that is
# not a positive number switches the rule OFF rather than holding everything,
# because a typo'd env var must not stop the gate from working.
merge_size_allowed() {
  local lines="${1-}" files="${2-}" max_lines="${3-}" max_files="${4-}"
  case "$max_lines" in ''|*[!0-9]*) max_lines=0 ;; esac
  case "$max_files" in ''|*[!0-9]*) max_files=0 ;; esac
  case "$lines" in ''|*[!0-9]*) return 1 ;; esac
  case "$files" in ''|*[!0-9]*) return 1 ;; esac
  [ "$max_lines" -gt 0 ] && [ "$lines" -gt "$max_lines" ] && return 1
  [ "$max_files" -gt 0 ] && [ "$files" -gt "$max_files" ] && return 1
  return 0
}
