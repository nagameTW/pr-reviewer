#!/usr/bin/env bash
# Remember, ACROSS ROUNDS, that reviewing this exact head already failed.
#
# WHY THIS EXISTS. The gate's only record that a head has
# been reviewed is a comment carrying `$MARKER $KEY` on the PR itself. So every
# failure mode that stops the comment from being posted — a model call that
# does not complete, a rate/usage limit, a GitHub 503 on the post — leaves no
# trace at all, and the next round reads the PR as never reviewed and does the
# whole thing again. The loop runs once a minute.
#
# Without this, a head whose review keeps failing is reviewed in full again
# every round, every model call failing the same way. The gate DETECTS the
# quota hits — `claude_quota_hit` fires and QUOTA_DIR records each one — but
# that directory is a `mktemp -d` created fresh every round, so nothing could
# remember that the previous round had already hit the wall, and the only
# symptom anywhere is the subscription bill.
#
# THE DIRECTION IS SAFE. Holding off means not reviewing, and not reviewing
# means no verdict: a held head waits for one and gets no early conclusion.
# That is the same direction every other failure path in this gate takes. What
# the hold must not do is last forever, so it is a COOLDOWN with a deadline,
# and every skip says in the log when the next attempt is due.
#
# KEYED BY $KEY, which is head sha + a digest of title/body/base — the same key
# the marker uses. So an author pushing a new commit, or editing the title, gets
# a different key and is reviewed immediately: the hold is about "this exact
# thing failed", never about the PR.
#
# Source-time side effects are forbidden here.

# Two cooldowns, because the two failures deserve different patience.
#
# QUOTA: retrying sooner cannot possibly help — the limit is account-wide and
# time-based, so every attempt before it resets burns calls to be told the same
# thing. Half an hour is short against a limit that resets on the hour scale,
# and long enough to turn 30 pointless rounds into one.
#
# OTHER: a call that died once often works next time (a timeout, a transient
# 5xx from the model API, a crash). Five minutes breaks the tight spin while
# keeping the gate responsive — a PR whose review crashed still gets looked at
# within a few rounds rather than a few hours.
HOLDOFF_QUOTA_SECONDS="${PRREVIEW_GATE_HOLDOFF_QUOTA:-1800}"
HOLDOFF_FAIL_SECONDS="${PRREVIEW_GATE_HOLDOFF_FAIL:-300}"
# Ceiling for the doubling below. An outage that outlives this is not going to
# be fixed by asking sooner, and an hour is short next to how long a PR is
# allowed to wait for a human anyway.
HOLDOFF_MAX_SECONDS="${PRREVIEW_GATE_HOLDOFF_MAX:-3600}"
HOLDOFF_DIR="${PRREVIEW_GATE_HOLDOFF_DIR:-$HOME/.cache/pr-reviewer/review-holdoff}"

# pr-autoreview.sh runs this once after sourcing. A hold of 0 lets a head whose
# review failed back in every round, which is the spin this file exists to
# stop, and one that is not a number breaks the arithmetic in holdoff_set.
holdoff_knobs_ok() {
  local kv
  for kv in "PRREVIEW_GATE_HOLDOFF_QUOTA=$HOLDOFF_QUOTA_SECONDS" \
            "PRREVIEW_GATE_HOLDOFF_FAIL=$HOLDOFF_FAIL_SECONDS" \
            "PRREVIEW_GATE_HOLDOFF_MAX=$HOLDOFF_MAX_SECONDS"; do
    [ "${kv#*=}" -ge 1 ] 2>/dev/null && continue
    echo "${kv%%=*} must be a whole number of seconds, at least 1; got: ${kv#*=} — refusing to run" >&2
    return 1
  done
}

# Where this repo+PR+key's hold lives. $1 repo (owner/name), $2 pr, $3 key.
#
# The key is sanitised rather than trusted: it is derived from a PR title and
# body, which this gate treats as attacker-controlled, and it lands in a path.
# A key that is not what we expect yields no path at all rather than a path
# somewhere else — refusing is the only safe answer when the input to a
# filename is untrusted.
# Trade-off: the name keeps only the repo base name (${repo##*/}), so owner-a/x
# and owner-b/x share one hold file for the same PR number and key. Two such
# repos in one gate see each other's hold. A new name would drop the held
# verdicts that exist at upgrade, so it stays. The post count does not share
# it: holdoff_posted_path names the owner too.
holdoff_path() {
  local repo="${1-}" pr="${2-}" key="${3-}"
  case "$pr"  in ''|*[!0-9]*) return 1 ;; esac
  case "$key" in ''|*[!0-9a-zA-Z.-]*) return 1 ;; esac
  [ -n "$repo" ] || return 1
  printf '%s/%s-%s-%s' "$HOLDOFF_DIR" "${repo##*/}" "$pr" "$key"
}

# Is the hold still in force? $1 path, $2 now (epoch seconds).
# Returns 0 (hold) only for a file whose recorded deadline is still ahead.
#
# A file that cannot be read, or holds something that is not a deadline, does
# NOT hold: a corrupt state file must not be able to stop this gate reviewing.
# That is the opposite of the fail-closed rule elsewhere, and deliberately so —
# here "fail" means "review it anyway", which is the cautious direction.
holdoff_active() {
  local f="${1-}" now="${2-}" line until
  [ -r "$f" ] || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  line="$(head -1 "$f" 2>/dev/null)" || return 1
  until="${line%% *}"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -lt "$until" ]
}

# Seconds still to wait, for the log line. Never negative, never empty.
holdoff_remaining() {
  local f="${1-}" now="${2-}" line until
  line="$(head -1 "$f" 2>/dev/null)" || { printf '0'; return; }
  until="${line%% *}"
  case "$until" in ''|*[!0-9]*) printf '0'; return ;; esac
  case "$now" in ''|*[!0-9]*) printf '0'; return ;; esac
  if [ "$now" -lt "$until" ]; then printf '%s' "$(( until - now ))"; else printf '0'; fi
}

# Why the hold was set, for the log line. Reads the MIDDLE field: the
# third one is the consecutive count that drives the doubling, and a reason
# that printed as "postfail 3" would end up in an operator-facing sentence.
holdoff_reason() {
  local line rest; line="$(head -1 "${1-}" 2>/dev/null)" || { printf 'unknown'; return; }
  case "$line" in *' '*) rest="${line#* }" ;; *) printf 'unknown'; return ;; esac
  printf '%s' "${rest%% *}"
}

# Record a hold. $1 path, $2 reason (quota|failed|postfail), $3 now.
#
# postfail shares failed's cooldown but keeps its own name, because the two say
# different things to whoever reads the log: `failed` means the model call
# produced nothing, `postfail` means the review EXISTS and GitHub would not take
# it. Only the second one means a finished review was thrown away.
# Non-fatal: a state dir that cannot be written means the gate behaves exactly
# as it did before this file existed, which is worse but not wrong.
# A repeat of the SAME reason doubles the wait, up to HOLDOFF_MAX_SECONDS.
#
# A flat 300s postfail cooldown turns an outage of hours (GitHub answering 503,
# say) into one full review of every open PR every five minutes for as long as
# it lasts, a bill nobody would notice until it arrived. Doubling makes a long
# outage cost a handful of reviews instead of dozens, while a one-off blip
# still only ever costs the base wait.
#
# The count lives in the file's third field.
holdoff_set() {
  local f="${1-}" reason="${2-failed}" now="${3-}" secs max prev n i
  [ -n "$f" ] || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$reason" in
    quota)    secs="$HOLDOFF_QUOTA_SECONDS" ;;
    postfail) secs="$HOLDOFF_FAIL_SECONDS" ;;
    *)        secs="$HOLDOFF_FAIL_SECONDS"; reason="failed" ;;
  esac
  # holdoff_knobs_ok compares with `[ -ge ]`, which reads 08 as decimal;
  # `$(( ))` would read it as octal and fail.
  secs=$((10#$secs)); max=$((10#$HOLDOFF_MAX_SECONDS))
  # How many times in a row this exact reason has already been recorded. A
  # DIFFERENT reason resets the count: quota after a post failure is a new
  # problem, and inheriting the escalation would hold a head far longer than
  # either failure earned.
  n=0
  prev="$(head -1 "$f" 2>/dev/null)" || prev=""
  case "$prev" in
    *" $reason "*) n="${prev##* }"; case "$n" in ''|*[!0-9]*) n=0 ;; esac ;;
  esac
  i=0
  while [ "$i" -lt "$n" ]; do
    secs=$(( secs * 2 ))
    [ "$secs" -ge "$max" ] && { secs="$max"; break; }
    i=$(( i + 1 ))
  done
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf '%s %s %s\n' "$(( now + secs ))" "$reason" "$(( n + 1 ))" > "$f" 2>/dev/null || return 1
}

# Clear it. Called when a verdict actually reaches the PR, which is the only
# event that proves the round got all the way through.
holdoff_clear() { [ -n "${1-}" ] && rm -f "$1" 2>/dev/null; return 0; }

# The holds written since file $1 that record a review or a post failing $2
# times in a row (default 3), one name per line. A quota hold is left out:
# it clears on its own. A head that keeps failing holds, backs off and
# retries, and every round around it ends clean, so nothing said it was stuck
# (a claude that is not logged in, a comment GitHub keeps refusing). Written
# since $1 keeps it to heads this round actually tried: the hold of a PR that
# was closed while stuck is not rewritten, and stops counting.
holdoff_stuck() {
  local since="${1-}" min="${2:-3}" f line n
  [ -d "$HOLDOFF_DIR" ] && [ -e "$since" ] || return 0
  find "$HOLDOFF_DIR" -maxdepth 1 -type f -newer "$since" ! -name '*.verdict' 2>/dev/null \
    | while IFS= read -r f; do
        line="$(head -1 "$f" 2>/dev/null)" || continue
        case "$line" in *" failed "*|*" postfail "*) ;; *) continue ;; esac
        n="${line##* }"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -ge "$min" ] && printf '%s\n' "${f##*/}"
      done
}

# ── The local count of posted verdicts ─────────────────────────────────────
#
# One line per verdict that this machine posted for a key: the time, in epoch
# seconds. The file is state that no comment author can create. The reviewer
# uses it to see that it posts again and again for one head. That happens when
# the list of App logins is wrong: the reviewer cannot know its own comments,
# so each round reads the head as not reviewed. See PROMPT_LOCAL_POST_LIMIT
# in lib/prompt.sh.
#
# The file lives next to the hold and is named from the owner, the repo, the PR
# and the same checked key. Holds keep only the repo base name; this name
# keeps the owner, so owner-a/x and owner-b/x never share a count.
# Pruning (holdoff_prune) keeps the file while its PR is open, so a head that
# waits for days cannot get a new count. The file of a closed PR goes by age.
#
# Every failure here leaves the gate as it was before this file existed: a
# count that cannot be read is 0. A record that cannot be written is the
# caller's to report (holdoff_dir_writable runs before the model, and a failed
# record after a post fails the round).

# The owner and the repo in a form that is safe in a file name: owner+repo.
# $1 = owner/repo. The count file name joins every field with "+": the owner,
# the repo, the PR and the key. No owner, repo name or key holds a "+", so no
# name is the prefix of another and a prefix test is exact. An owner may hold
# an underscore (Enterprise Managed User logins, such as alice_acme). Nothing
# is printed for a name outside the GitHub name characters.
holdoff_posted_stem() {
  local owner="${1%%/*}" repo="${1#*/}"
  case "$1" in */*) ;; *) return 1 ;; esac
  case "$owner" in ''|*[!0-9a-zA-Z_-]*) return 1 ;; esac
  case "$repo"  in ''|*[!0-9a-zA-Z._-]*) return 1 ;; esac
  # GitHub names ignore case, so the stem is lower case. The prune test
  # builds its stem here too, so an open entry in any case matches the file.
  printf '%s+%s' "$owner" "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# Where the count for this repo, PR and key lives. Same arguments as holdoff_path.
holdoff_posted_path() {
  local stem
  holdoff_path "$@" >/dev/null || return 1
  stem="$(holdoff_posted_stem "${1-}")" || return 1
  printf '%s/%s+%s+%s.posted' "$HOLDOFF_DIR" "$stem" "${2-}" "${3-}"
}

# Can the count be kept? Makes the hold directory (mode 700, from umask 077) when it is
# missing, then tests that it is writable. The job runs this before any model
# call: a verdict posted with no way to count it is not bounded.
holdoff_dir_writable() {
  [ -d "$HOLDOFF_DIR" ] || ( umask 077; mkdir -p "$HOLDOFF_DIR" ) 2>/dev/null || return 1
  [ -d "$HOLDOFF_DIR" ] && [ -w "$HOLDOFF_DIR" ]
}

# How many verdicts are recorded. $1 = path. Prints 0 for a file that is
# missing or unreadable. A line that is not a time does not count.
holdoff_posted_count() {
  local n
  [ -r "${1-}" ] || { printf '0'; return 0; }
  n="$(grep -c '^[0-9][0-9]*$' "$1" 2>/dev/null)" || true
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Record one verdict. $1 = path, $2 = now (epoch seconds). Non-zero when the
# write fails; the caller logs it and goes on. The file is mode 600 in a 700
# directory, as the other state files are.
holdoff_posted_record() {
  local f="${1-}" now="${2-}" dir
  [ -n "$f" ] || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  ( umask 077; printf '%s\n' "$now" >> "$f" ) 2>/dev/null || return 1
}

# Old holds are junk, not history: once a head is superseded its file can never
# match a key again. Pruned by age so the directory cannot grow without bound.
#
# The count file (.posted) is the exception while its PR is open. $2 lists the
# open PRs, one per line: "owner/repo#N" for a PR, and a bare "owner/repo" for
# a repo whose open list is not known (all its count files stay). A count file
# of any other PR goes by age as the other files do. Without $2, every file
# goes by age.
holdoff_prune() {
  local days="${1:-2}" open="${2-}" f line stem keep
  [ -d "$HOLDOFF_DIR" ] || return 0
  find "$HOLDOFF_DIR" -maxdepth 1 -type f ! -name '*.posted' -mtime "+$days" -delete 2>/dev/null || true
  find "$HOLDOFF_DIR" -maxdepth 1 -type f -name '*.posted' -mtime "+$days" -print 2>/dev/null \
    | while IFS= read -r f; do
        keep=0
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          stem="$(holdoff_posted_stem "${line%%#*}")" || continue
          case "$line" in
            *'#'*) case "$f" in "$HOLDOFF_DIR/$stem+${line#*#}+"*) keep=1 ;; esac ;;
            *)     case "$f" in "$HOLDOFF_DIR/$stem+"*) keep=1 ;; esac ;;
          esac
        done <<<"$open"
        [ "$keep" = 1 ] || rm -f "$f" 2>/dev/null || true
      done
}

# ── The verdict cache: re-post what a previous round already paid for ──────
#
# The hold above stops the SPIN. It does not stop the WASTE: when the cooldown
# expires, the gate reviews from scratch a head whose verdict was already
# computed. For the `postfail` case that is pure loss — the review ran to
# completion, cost every model call it makes, and was discarded because GitHub
# would not take it. So the verdict is parked next to the hold, and the round
# after the cooldown re-posts it instead of asking the model again.
#
# WHAT IS PARKED is the PRE-scan body and verdict, not the text that was about
# to be posted. The outbound sensitive scan runs again on the replay, so a
# patterns file that was updated in between still gets to withhold a body that
# is no longer safe to post. Parking the post-scan text would freeze that
# decision at the moment of the failure.
#
# 600, in a 700 directory, for the same reason the loop's round logs are 700:
# the parked body is exactly the text the outbound scan exists to keep off
# GitHub, and here it lands in a file that outlives the round.
#
# EVERY failure direction is "no cache, review normally". A cache that cannot
# be read, or that belongs to another head, must never stop or alter a review —
# this is an optimisation, and an optimisation that can block is a defect. That
# is the same direction holdoff_active takes for a corrupt hold, and the
# opposite of the fail-closed rule that governs the scan.

# Where this hold's parked verdict lives. $1 = the hold path.
holdoff_verdict_path() {
  [ -n "${1-}" ] || return 1
  printf '%s.verdict' "$1"
}

# Park a verdict. $1 path, $2 key, $3 verdict, $4 body, $5 findings JSON.
#
# The key is stored INSIDE as well as being part of the path. The path already
# binds it — holdoff_path builds the name from repo+pr+key — so this is defence
# in depth against the one outcome worse than paying for the review twice:
# posting a review of one head onto another.
#
# Non-fatal, like holdoff_set: a cache that cannot be written leaves the gate
# behaving exactly as it did before this existed.
holdoff_verdict_save() {
  local f="${1-}" key="${2-}" verdict="${3-}" body="${4-}" cleaned="${5-}" dir
  [ -n "$f" ] && [ -n "$key" ] && [ -n "$verdict" ] && [ -n "$body" ] || return 1
  dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  # umask inside the subshell so the redirect that CREATES the file is covered;
  # the chmod after it is for the case where the file already existed.
  ( umask 077
    jq -n --arg k "$key" --arg v "$verdict" --arg b "$body" --arg c "$cleaned" \
      '{key:$k, verdict:$v, body:$b, cleaned:$c}' > "$f"
  ) 2>/dev/null || { rm -f "$f" 2>/dev/null; return 1; }
  chmod 600 "$f" 2>/dev/null || true
}

# Read it back. $1 path, $2 key. Prints the object on success; non-zero means
# there is nothing usable here and the caller must review normally.
#
# The shape is checked, not assumed: a file holding valid JSON that is missing
# the body, or carrying a different key, is refused rather than half-used.
holdoff_verdict_load() {
  local f="${1-}" key="${2-}"
  [ -n "$key" ] || return 1
  [ -r "$f" ] || return 1
  jq -ce --arg k "$key" \
    'select((.key == $k)
            and (.verdict | type == "string") and (.verdict != "")
            and (.body    | type == "string") and (.body    != ""))' \
    "$f" 2>/dev/null
}

# Drop it. Called wherever a verdict actually reaches the PR: the marker is
# then already on the PR, so a parked copy could only ever be posted a second
# time.
holdoff_verdict_clear() { [ -n "${1-}" ] && rm -f "$1" 2>/dev/null; return 0; }
