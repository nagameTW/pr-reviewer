#!/usr/bin/env bash
# What a loop driver needs besides the loop itself, among them the admission
# check, log pruning, the parse-checked copy it runs, which alert script to
# call, and the summary it writes to gate.log. Split out so it can be tested
# without gh or a network, and so there is only ONE copy of it. Source-time
# side effects are forbidden here.
#
# Why the admission check reads the driven script's own repo list: a driver
# that polled a repo of its own choosing, while the script it drives iterates
# a LONGER list, would exit early whenever that one repo had no open PRs,
# with PRs waiting on the others, and nothing would be reviewed. The log line
# for that is `open PRs=0`, which reads as "nothing to do" and not as "did
# not look".

# The repo list the driven script itself iterates, read from that script.
# $1 = path to the driven script. Prints the list; non-zero when it cannot be
# read at all.
#
# grep + eval of the assignment, rather than a second hand-written list here:
# two copies of a list drift apart. A driven script declares it
# on one line as `REPOS=...`, which eval honours even inside an environment
# override, and the tests below pin that shape from both ends.
loop_repos_of() {
  local script="${1-}" line
  # Deliberately shadowing: eval assigns into this local, not the caller's env.
  local REPOS=""
  [ -n "$script" ] && [ -r "$script" ] || return 1
  line="$(grep -m1 -E '^REPOS=' "$script" 2>/dev/null)" || return 1
  [ -n "$line" ] || return 1
  eval "$line" 2>/dev/null || return 1
  [ -n "$REPOS" ] || return 1
  printf '%s\n' "$REPOS"
}

# The JSON array $1 without its draft PRs: the entries that are objects whose
# isDraft is the boolean true. Every other entry stays, so trust_plan_prs can
# refuse a bad one. A $1 that is not an array is printed as it is, for the same
# reason. Fails when $1 is not JSON.
loop_without_drafts() {
  jq -c 'if type == "array" then map(select((type == "object" and .isDraft == true) | not)) else . end' <<<"${1-}"
}

# How many PRs in the JSON array $1 the round skips and disarms: skipped by
# trust_plan_prs, with the same environment settings as the round, and with a
# non-null autoMergeRequest. Drafts stay in. Fails when $1 is not usable.
loop_armed_skips() {
  local plan
  plan="$(trust_plan_prs "${1-}" "${PRREVIEW_GATE_TRUSTED_AUTHORS-}" "${PRREVIEW_GATE_FORK_PRS-}" "" 2>/dev/null)" || return 1
  jq -r --arg skips "$(printf '%s\n' "$plan" | sed -n 's/^skip //p')" '
      ($skips | split("\n")) as $s
      | [.[] | select(.autoMergeRequest != null and ((.number | tostring) as $n | any($s[]; . == $n)))]
      | length' <<<"${1-}"
}

# How many open PRs the round would review, across every repo the driven
# script covers. $1 = path to the driven script, $2 = gh binary (default `gh`).
#
# The count applies the rule of the round: trust_plan_prs (lib/trust.sh), with
# PRREVIEW_GATE_TRUSTED_AUTHORS and PRREVIEW_GATE_FORK_PRS read from the
# environment. The round inherits the same environment from the loop, and
# `prreview run` fills it from the settings file before it starts the loop, so
# both see the same values. A count that includes the PRs the round skips
# starts a full round every interval for as long as one fork PR stays open,
# and each round pays for the merged-PR scan. The scan itself stays unfiltered.
# A draft PR does not count, because the round skips it. Only a boolean true
# is a draft. A missing or non-boolean isDraft counts as not a draft, so the
# round decides. With PRREVIEW_GATE_DISARM_AUTO_MERGE=1 the call also reads
# autoMergeRequest, and a skipped PR with armed auto-merge counts as work,
# because the round disarms it. That check reads the list with its drafts, as
# the round does.
# The loop needs lib/trust.sh sourced and jq on PATH. The call asks for the
# same limit as the round. It reads the fields that the rule needs (number,
# author, isCrossRepository) and isDraft. The round reads the labels too, and
# the rule does not use them. The answer is read once.
#
# Every failure direction answers 1 per repo, i.e. "assume there is work". A
# round that runs with nothing to do costs one `gh pr list` per repo; a round
# skipped because a transient error read as zero costs a review nobody notices
# is missing, and the log says `open PRs=0` either way. That asymmetry is the
# whole reason the count is generous. An empty answer, a list that is not a
# list, and an entry without a number are such failures: the round refuses
# them and says so.
# Trade-off: trust_plan_prs runs one jq call per PR, about 1000 calls for a
# repository at the limit, once per interval.
loop_open_pr_count() {
  local script="${1-}" gh="${2:-gh}" repos r list all plan n armed fields total=0
  repos="$(loop_repos_of "$script")" || { printf '1\n'; return 0; }
  fields=number,author,isCrossRepository,isDraft
  # The round disarms auto-merge on skipped PRs only with this setting, and
  # then it asks for the field in its own list call. Do the same here.
  [ "${PRREVIEW_GATE_DISARM_AUTO_MERGE-}" != 1 ] || fields="$fields,autoMergeRequest"
  for r in $repos; do
    # An empty answer is not an empty list: jq reads no input as no entries.
    if list="$("$gh" pr list --repo "$r" --state open --limit 1000 --json "$fields" 2>/dev/null)" \
       && [ -n "${list//[[:space:]]/}" ] \
       && all="$list" \
       && list="$(loop_without_drafts "$list" 2>/dev/null)" \
       && plan="$(trust_plan_prs "$list" "${PRREVIEW_GATE_TRUSTED_AUTHORS-}" "${PRREVIEW_GATE_FORK_PRS-}" "" 2>/dev/null)"; then
      n="$(printf '%s\n' "$plan" | grep -c '^review ' || true)"
      if [ "${PRREVIEW_GATE_DISARM_AUTO_MERGE-}" = 1 ]; then
        # A skipped PR with armed auto-merge is work: the round disarms it. The
        # round does not drop drafts before it disarms, so read the whole list.
        armed="$(loop_armed_skips "$all" 2>/dev/null)" || armed=1
        case "$armed" in '' | *[!0-9]*) armed=1 ;; esac
        n=$((n + armed))
      fi
    else
      n=1
    fi
    case "$n" in '' | *[!0-9]*) n=1 ;; esac
    total=$((total + n))
  done
  printf '%s\n' "$total"
}

# Keep the newest $2 round logs in $1 and delete the rest. Nothing else ever
# prunes them: a driver running once a minute writes thousands in a week, in
# ~/.cache where XDG says anything may be wiped but nothing actually is. A
# round that runs writes one file; empty rounds write none, so this grows
# with real work.
#
# Nothing outside the round-*.log pattern is touched, and a missing directory
# is a no-op — this runs unattended once a minute and must never be the thing
# that stops a round.
#
# `ls -t` output is parsed, which is unsafe for arbitrary filenames and fine
# here: the only writer is the driver next to this file and it names them
# round-<n>.log.
loop_prune_logs() {
  local dir="${1-}" keep="${2:-500}" f
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  case "$keep" in '' | *[!0-9]*) keep=500 ;; esac
  [ "$keep" -ge 1 ] || keep=1
  ls -t "$dir"/round-*.log 2>/dev/null | tail -n "+$((keep + 1))" | while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f"
  done
  return 0
}

# The driver's own log ($1), the file its stdout is appended to, kept under $2
# bytes: past that it is copied to $1.1, replacing the previous copy, and
# emptied in place. Emptied rather than moved, because the service manager
# holds the file open for appending and a moved file would keep receiving
# every line. The driver is its only writer and calls this between rounds, so
# no line is lost. An empty $1 (nobody said where the log is) does nothing,
# and like loop_prune_logs this never stops a round.
loop_rotate_log() {
  local f="${1-}" max="${2:-10485760}" size
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] && [ -w "$f" ] || return 0
  case "$max" in '' | *[!0-9]*) max=10485760 ;; esac
  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')" || return 0
  [ "${size:-0}" -gt "$max" ] || return 0
  cp -p "$f" "$f.1" 2>/dev/null && : > "$f"
  return 0
}


# Does $1 parse? $1 = path to the driven script, $2 = the bash that will run
# it (default `bash`; pass the driver's own $BASH_BIN, because the parser that
# matters is the one about to execute the file).
#
# Every driver here runs this repo's WORKING TREE, and bash executes a script
# LINE BY LINE — a syntax error near the end runs everything above it first.
# A pr-autoreview.sh caught mid-edit can get as far as
# posting before it dies, i.e. a partially defined gate one branch away from
# acting with half its logic missing. A round that never ran is not a red
# round either: the caller skips and logs one line. Only a tree that stays
# unparseable round after round files an alert (loop_ready_should_alert
# below); one per edit would be noise about an editor, not about the machine.
#
# Deliberately silent: `bash -n` reports the error on stderr and can quote the
# offending line with it, and the drivers' own stdout is a 644 log while their
# round logs are 700 for exactly that reason. The caller prints the path.
#
# -n parses without executing, so this is safe to call every round; a missing
# or unreadable file is refused rather than guessed at.
loop_script_parses() {
  local script="${1-}" bash_bin="${2:-bash}"
  [ -n "$script" ] && [ -r "$script" ] || return 1
  "$bash_bin" -n "$script" 2>/dev/null
}

# A private copy of $1 to run this round, in the SAME directory. Prints the
# copy's path; non-zero when one cannot be made.
#
# The other half of the same hazard. loop_script_parses
# guards the START of a round; bash reads a script by BYTE OFFSET as it
# executes, so a file rewritten while the round is still running leaves the
# interpreter reading one version at another version's offsets: it reports
# a syntax error or an unbound variable that is in no file that ever existed,
# in the middle of reviewing a real PR.
#
# SAME DIRECTORY, not $TMPDIR: a driven script resolves its libraries from
# its own path (`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`),
# so a copy anywhere else finds no lib/ and dies on the first source.
# The name is dot-prefixed so `*.sh` globs (the tests, shellcheck runs) do
# not pick it up, and .gitignore carries the pattern so a stray copy never
# shows up as something to commit.
#
# Sweeps siblings older than two hours first: a round killed at its
# timeout, or by a reboot, leaves its copy behind and nothing else
# would ever remove it. Two hours is comfortably longer than the longest round
# ceiling in this repo — a copy older than that cannot belong to a round
# still running.
loop_script_snapshot() {
  local script="${1-}" dir base snap
  [ -n "$script" ] && [ -r "$script" ] || return 1
  dir="$(dirname "$script")"
  base="$(basename "$script")"
  find "$dir" -maxdepth 1 -name '.prreview-run-*' -mmin +120 -delete 2>/dev/null || true
  snap="$(mktemp "$dir/.prreview-run-$base.XXXXXX" 2>/dev/null)" || return 1
  # cat, not cp: cp would carry the source's mode, and this file is the gate.
  cat "$script" > "$snap" 2>/dev/null || { rm -f "$snap" 2>/dev/null; return 1; }
  chmod 700 "$snap" 2>/dev/null || true
  printf '%s\n' "$snap"
}

# Has "could not prepare the script to run" been true long enough to stop
# being a blip? $1 = consecutive failures so far, $2 = the limit.
#
# WHY A DRIVER NEEDS THIS. loop_script_ready failing makes a round print one
# line and `continue`. Nothing else happens: no non-zero exit, so no
# owner-alert.sh, so no issue. Before the drivers ran a checked copy, a
# broken tree made the driven script exit non-zero and that path DID alert;
# adding the copy closed the hole the copy was for and opened this one. A
# tree left unparseable is then a gate that quietly stops reviewing, for as
# long as nobody happens to read the log.
#
# Fires ON the limit and every $2 rounds after it, never every round. `-eq`
# alone would announce an outage once and stay silent through the rest of it,
# including after the operator closes the issue. Every round instead would
# mean a gh call a minute for as long as the tree stays broken. owner-alert.sh
# dedupes on its own title, so the repeats collapse into one open issue and
# closing it re-arms.
# Which owner-alert.sh a driver runs. The tree's own copy when it can be
# read; otherwise the copy PRREVIEW_ALERT_BIN names, kept outside the tree.
# When the tree itself cannot be read (macOS privacy protection revoking the
# folder it sits in, say), every round prints "could not copy" and reaches the
# stall alert, and `./owner-alert.sh` in that same tree cannot run either: it
# dies with "Operation not permitted" and nobody hears. Only a copy outside
# the tree, which PRREVIEW_ALERT_BIN names, can say the tree is gone.
loop_alert_script() {
  local copy="${PRREVIEW_ALERT_BIN:-./owner-alert.sh}"
  if [ -r ./owner-alert.sh ]; then printf '%s\n' ./owner-alert.sh
  else printf '%s\n' "$copy"; fi
}

loop_ready_should_alert() {
  local n="${1:-0}" limit="${2:-0}"
  case "$n$limit" in *[!0-9]*) return 1 ;; esac
  [ "$limit" -gt 0 ] || return 1
  [ "$n" -ge "$limit" ] && [ $((n % limit)) -eq 0 ]
}

# A private copy of $1 that has been parse-checked. Prints the copy's path.
# Exit 1 = no copy could be made, exit 2 = the copy does not parse; callers
# keep their two distinct messages off that.
#
# The two steps belong together, and in THIS order. Checking the TREE and then
# copying it answers for bytes that are not the ones about to run: an edit
# landing between the check and the copy leaves a copy nobody checked, and a
# truncation that happens to fall between two complete statements produces a
# copy that PARSES, runs the first half of the driven script, and exits 0 — a
# round that looks clean and is not, with no non-zero rc and no alert. That is
# strictly worse than the split had before the copy existed, where a broken
# tree at least died loudly. Checking the copy closes the window, and reads
# the file one time fewer than the split version did.
# Nothing stops a caller from calling the
# two halves by hand in the wrong order, so tests/loop.test.sh pins that
# none of the drivers does.
loop_script_ready() {
  local script="${1-}" bash_bin="${2:-bash}" copy
  copy="$(loop_script_snapshot "$script")" || return 1
  loop_script_parses "$copy" "$bash_bin" || { rm -f "$copy" 2>/dev/null; return 2; }
  printf '%s\n' "$copy"
}

# True when $2, the value of knob $1, is a whole number of seconds, at least
# 1; otherwise names the knob and its value and returns 1, and the driver
# refuses to start. The round timeouts go straight into timeout(1): a value it
# cannot parse exits 125 every round, and a kill-after of 0 means "never send
# KILL", which brings back the wedged round the kill-after exists to end.
# test(1) errors on anything that is not an integer, and 2>/dev/null turns
# that error into the refusal.
loop_require_seconds() {
  [ "${2-}" -ge 1 ] 2>/dev/null && return 0
  echo "$1 must be a whole number of seconds, at least 1; got: ${2-} — refusing to run" >&2
  return 1
}


# gate.log's summary of one round: the verdict lines, then the refusal lines,
# from round log $1. Only lines the gate printed itself, anchored on their
# prefix: the round log also holds review bodies the sensitive scan WITHHELD
# and the head of model output that would not parse (pr-autoreview.sh prints
# both there indented, in a 700 dir) and gate.log is 644. A PR job's lines
# arrive behind the `[repo#N] ` the dispatcher adds (pr-autoreview.sh,
# `sed -u`). A line without that prefix is either the dispatcher's own about
# one PR, printed before its job started (`PR #N: `), or round-level: a
# missing dependency, the end-of-round count of what could not be evaluated.
# A round-level line about one repo starts with its `owner/name: `.
# Three tails, so no kind of line can push another out: verdicts, a PR job's
# refusals, the round's own refusals. The holdoff prints a line per PR per
# round and would bury the verdicts; a round
# that hits the quota, a dead job and a fail-closed skip at once prints
# round-level NOTICEs that would bury the one line naming which PR and why.
# Every WARNING and NOTICE the gate prints names something that went wrong
# this round, so the word itself keeps them: inside a PR job's line, or as
# the round-level line's own prefix.
LOOP_JOB_PREFIX='\[[A-Za-z0-9_.-]+#[0-9]+\] '
LOOP_PR_LINE="^(${LOOP_JOB_PREFIX}|PR #[0-9]+: )"
LOOP_GATE_LINE="^(${LOOP_JOB_PREFIX})?"'(PR #[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|NOTICE|WARNING): '
# `verdict comment posted` is how a review-only repo's PR ends: a comment,
# never an approve. `split requested`: the gate asked the author to split
# an oversized PR.
# `not acting on it` is a PR the gate reviewed and then set aside.
# `re-posting` finishes a head an earlier round decided.
# `reminder posted` and `notice posted` end a PR that got only the title
# reminder or the sensitive-scan notice. `post-merge alert posted` and
# `ticket filed` are the round acting on a merged PR or opening a follow-up
# issue; a failed append to one reads `FAILED to`. A successful append is
# left out: a long-lived PR appends every round it stays blocked.
# `prreview status` shows these from gate.log. Not kept: the lines a handled head
# prints EVERY round ("already handled" and the like), which would push the
# verdicts out of the tail.
LOOP_GATE_VERDICT='(budget spent|FAILED to|verdict comment posted|third consecutive round|split requested|re-posting|reminder posted|notice posted|post-merge alert posted|ticket filed)'
LOOP_GATE_REFUSAL='(skipping|could not|fail closed|refusing to|not acting on it|WARNING|NOTICE)'
LOOP_ROUND_REFUSAL='^((NOTICE|WARNING): |[^[ ].* — refusing to run|[0-9]+ item\(s\) — .* could not be evaluated)'
loop_gate_summary() {
  grep -aE "${LOOP_GATE_LINE}.*${LOOP_GATE_VERDICT}" "$1" | tail -6
  local refusals
  refusals="$(grep -aE "${LOOP_GATE_LINE}.*${LOOP_GATE_REFUSAL}|${LOOP_ROUND_REFUSAL}" "$1")" || return 0
  grep -aE "$LOOP_PR_LINE" <<<"$refusals" | tail -4
  grep -avE "$LOOP_PR_LINE" <<<"$refusals" | tail -4
}
