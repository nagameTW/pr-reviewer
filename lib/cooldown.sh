# shellcheck shell=bash
# The same-head cooldown. An edit of a PR's title, description or base branch
# changes the review key and asks for a new review of a head that was just
# reviewed. A
# stolen account, a bot or a careless author can repeat that edit and spend
# model usage on every round. This file holds the decision that stops it.
#
# One rule. The head SHA has not changed since the reviewer's last comment on
# the PR, and that comment is younger than the cooldown: skip the PR in this
# round. A push to the PR branch never waits, because a new head differs from
# the head in that comment. For a stacked PR, a push to the parent branch can
# wait up to the cooldown. See the trade-off above cooldown_decide. The data is
# the comment list the dispatcher already reads. There is no state file.

# Minutes. 0 turns the cooldown off.
COOLDOWN_MIN="${PRREVIEW_GATE_PR_COOLDOWN_MIN:-10}"

# pr-autoreview.sh runs this once after sourcing.
cooldown_knob_ok() {
  case "$COOLDOWN_MIN" in
    '' | *[!0-9]*)
      echo "PRREVIEW_GATE_PR_COOLDOWN_MIN must be a whole number of minutes (0 turns it off); got: $COOLDOWN_MIN — refusing to run" >&2
      return 1 ;;
  esac
}

# The head SHA and the time of the reviewer's last comment that carries a head,
# printed as "<sha> <time>". Prints nothing when there is none.
# $1 = `gh pr view --json comments,reviews` output, $2 = marker, $3 = the
# logins of the reviewer. Only the first line of a body counts, as in
# prompt_gate_bodies: a stranger can type the marker anywhere else. A marker
# that holds no 40-digit head (postmerge-blocker) is not a review comment.
# The time is createdAt, or submittedAt for a review.
cooldown_last_gate_comment() {
  jq -r --arg m "${2-}" --arg allowed "${3-}" '
    ($allowed | split(" ") | map(select(length > 0))) as $ok
    | [(.reviews // [])[], (.comments // [])[]
       | select((((.author.login // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $l
                 | ($ok | index($l)) != null))
       | ((.body // "") | split("\n") | .[0] // "") as $first
       | select($first | startswith("<!-- " + $m + " "))
       | ($first | ltrimstr("<!-- " + $m + " ") | .[0:40]) as $sha
       | select($sha | test("^[0-9a-f]{40}$"))
       | {sha: $sha, at: (.createdAt // .submittedAt // "")}]
    | sort_by(.at) | .[-1] // empty | .sha + " " + .at' <<<"${1-}" 2>/dev/null
}

# What to do with a PR whose last comment of the reviewer is known.
# $1 = head SHA now, $2 = head SHA of that comment, $3 = its time (ISO 8601,
# like 2026-10-22T11:30:00Z), $4 = now in epoch seconds, $5 = minutes.
# Prints one of these and always returns 0:
#   skip <seconds left>     same head, comment inside the cooldown
#   review                  anything else
#   review unreadable-time  same head, but the time is empty, not a time to the
#                           second, or in the future
# Trade-off: this function compares only the head SHA of the PR. The review key
# of a stacked PR (a PR whose base is not the default branch) also holds the
# base commit. A push to the parent branch changes the key and leaves the head
# the same. This function then skips the PR until the reviewer's last comment
# is old enough. The wait ends after PRREVIEW_GATE_PR_COOLDOWN_MIN minutes. The
# PR is not lost. A fix needs the base commit in the dispatcher call.
# Fail-safe: a time that cannot be read never skips. A skip that cannot end
# would leave the PR without a review. The cost of a wrong "review" is one
# extra model run.
cooldown_decide() {
  local head="${1-}" last="${2-}" at="${3-}" now="${4-}" min="${5-}" epoch age left
  case "$min" in '' | *[!0-9]*) echo review; return 0 ;; esac
  # More than 9 digits is over 1900 years: cap it before the arithmetic below
  # can overflow.
  [ "${#min}" -le 9 ] || min=999999999
  min=$((10#$min))
  if [ "$min" -eq 0 ] || [ -z "$last" ] || [ "$head" != "$last" ]; then echo review; return 0; fi
  epoch="$(jq -nr --arg t "$at" '$t | fromdateiso8601' 2>/dev/null)"
  case "$epoch" in '' | *[!0-9]*) echo "review unreadable-time"; return 0 ;; esac
  age=$((now - epoch))
  if [ "$age" -lt 0 ]; then echo "review unreadable-time"; return 0; fi
  left=$((min * 60 - age))
  if [ "$left" -gt 0 ]; then echo "skip $left"; else echo review; fi
}
