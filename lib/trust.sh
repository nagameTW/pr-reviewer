#!/usr/bin/env bash
# Which pull requests the reviewer reads, decided by who wrote them. Sourced by
# pr-autoreview.sh and prreview, and tested without gh. Source-time side
# effects are forbidden here.
#
# A PR from a fork is not reviewed unless one of three things holds: its
# author is in PRREVIEW_GATE_TRUSTED_AUTHORS, `prreview once --pr` names it,
# or PRREVIEW_GATE_FORK_PRS=1 turns the rule off. Anyone can open a fork PR,
# and every push to it would start a new model call.
#
# Trade-off: the rule treats everyone who can push to the repository as
# trusted. A repository whose workflows build branches from outside input
# breaks that assumption. Do not put an account in
# PRREVIEW_GATE_TRUSTED_AUTHORS only because it contributed once. The list
# lives on the machine that runs the reviewer, so each maintainer sets it
# there.

# pr_author_trusted JSON ALLOWED TRIGGER
# JSON is one PR as gh prints it. ALLOWED lists logins, separated by spaces or
# commas. TRIGGER is the number of the PR that `prreview once --pr` named, or
# empty. Returns 0 in two cases:
#   1. .number is a whole number and equals TRIGGER. The maintainer named this
#      PR, so its other fields do not matter.
#   2. Every one of these holds: .number is a number, .isCrossRepository is a
#      boolean, .author is an object and .author.login is a non-empty string.
#      Then either isCrossRepository is false, or the login is in ALLOWED
#      (letter case does not matter).
# Returns 1 in every other case, a missing field, a wrong type and text that
# is not JSON included. The type check comes first, so an allowlisted login
# cannot excuse a bad fork flag, and a same-repository flag cannot excuse a
# bad author.
# Trade-off: a PR whose author account was deleted can come back with no
# login. The rule then skips it, unless `prreview once --pr` names it.
pr_author_trusted() {
  local allowed="${2-}"
  allowed="${allowed//,/ }"
  jq -e --arg allowed "$allowed" --arg trigger "${3-}" '
    type == "object" and (
      ($trigger != "" and (.number | type == "number" and . == floor and tostring == $trigger))
      or (
        (.number | type == "number")
        and (.isCrossRepository | type == "boolean")
        and (.author | type == "object")
        and (.author.login | type == "string" and . != "")
        and (.isCrossRepository == false
             or ((.author.login | ascii_downcase) as $login
                 | [$allowed | ascii_downcase | scan("[^ \t\n]+")] | any(. == $login)))
      )
    )
  ' <<<"${1-}" >/dev/null 2>&1
}

# trust_plan_prs LIST ALLOWED FORK_PRS TRIGGER
# LIST is the JSON array of `gh pr list`. Prints "review N" or "skip N" for each
# PR, in list order. FORK_PRS=1 reviews every PR. A non-empty TRIGGER reviews
# that PR and ignores the others. Returns 1, with no usable output, when LIST
# is not an array or an entry has no whole number.
# Trade-off: one jq call per PR, about 1000 calls for a repository at the
# 1000-PR limit.
trust_plan_prs() {
  local list="${1-}" allowed="${2-}" fork="${3-}" trigger="${4-}" rows n item
  rows="$(jq -r 'if type == "array"
                 then .[] | [(.number | if type == "number" then tostring else "" end), tojson] | join("\t")
                 else error("not a list") end' <<<"$list" 2>/dev/null)" || return 1
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r n item; do
    case "$n" in '' | *[!0-9]*) return 1 ;; esac
    if [ -n "$trigger" ]; then
      [ "$n" != "$trigger" ] || echo "review $n"
    elif [ "$fork" = 1 ] || pr_author_trusted "$item" "$allowed" ""; then
      echo "review $n"
    else
      echo "skip $n"
    fi
  done <<<"$rows"
  return 0
}

# trust_parse_pr_ref REF
# REF is owner/repo#N. Prints "owner/repo N", or returns 1 for anything else:
# a missing part, a number that starts with 0, a URL, extra text.
trust_parse_pr_ref() {
  local ref="${1-}"
  [[ "$ref" =~ ^([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)#([1-9][0-9]{0,8})$ ]] || return 1
  printf '%s/%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# trust_listed_repo REPO LIST
# Prints the entry of LIST (space-separated owner/repo) that equals REPO,
# ignoring letter case, or returns 1.
trust_listed_repo() {
  local want item
  want="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  for item in ${2-}; do
    if [ "$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
      printf '%s\n' "$item"
      return 0
    fi
  done
  return 1
}

# trust_warning N
# The line a round prints when N fork PRs were not reviewed. It begins with
# WARNING:, so gate.log keeps it (lib/loop.sh).
trust_warning() {
  printf "WARNING: %s PR(s) from forks were not reviewed. Their authors are not in PRREVIEW_GATE_TRUSTED_AUTHORS. PRREVIEW_GATE_FORK_PRS=1 reviews all fork PRs. 'prreview once --pr owner/repo#N' reviews one.\n" "${1-0}"
}

# trust_warning_count FILE
# The N of the last trust_warning line in the round log FILE, or 0. Only a
# line at the start of a log line counts. A job's lines carry a [repo#N] prefix.
trust_warning_count() {
  local n
  n="$(grep -aE '^WARNING: [0-9]+ PR\(s\) from forks were not reviewed' "${1-}" 2>/dev/null | tail -1 | sed 's/^WARNING: \([0-9]*\) .*/\1/')"
  printf '%s\n' "${n:-0}"
}
