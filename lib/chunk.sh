#!/usr/bin/env bash
# Splitting one PR's diff into review-sized slices. No gh, no network, no
# model call — the whole point is that the packing decision is testable.
# Source-time side effects are forbidden here.
#
# Why this exists. Review quality falls with diff size, and not gently. One
# study (arXiv:2606.15689, https://arxiv.org/abs/2606.15689, Figure 3, which
# measured Claude Haiku 4.5 only) reports F1 of 0.657 under 10 changed
# lines and 0.80 at 10-50, then 0.070 at 50-150 and 0.043 at 150-600, about
# a 15x drop. A PR of a few hundred changed lines is ordinary, so without
# slicing most reviews would run in one pass well past the point where that
# study saw one pass find things.
#
# The size ceiling (merge_size_allowed in lib/merge.sh) does not fix that and
# was never meant to: it only turns away the extreme tail. This is the other
# half — review a large diff in several passes, each one a fraction of the
# whole.
#
# What it deliberately does NOT do: split a single file's hunks apart. A
# reviewer handed half a function's changes reasons about a function it cannot
# see, which is the failure the whole idea is trying to avoid. A file bigger
# than the target is its own slice, oversized, and that is the honest outcome.

# Split a unified diff into one part file per changed file.
# $1 = the diff file, $2 = a directory to write parts into (must exist).
# Echoes one line per part: "<changed-lines>\t<part-path>\t<file-path>",
# in the order the diff presents them. Non-zero (and no output) if the diff
# holds no `diff --git` header at all, which the caller must treat as "do not
# chunk", never as "nothing to review".
#
# changed-lines counts + and - lines inside hunks, so it matches what GitHub
# reports as additions+deletions and what every size number in this repo
# means. Inside hunks, not "everything except a +++/--- prefix": a deleted
# line whose own content starts with `--` (an SQL comment, a markdown rule)
# renders as `--- ...` and was being dropped from the count.
#
# The file path is read off the `+++ b/...` line, falling back to `--- a/...`
# for a deletion where +++ is /dev/null. Not off the `diff --git a/x b/x`
# header: that line puts two paths on one line with no separator that a path
# cannot contain, so a filename with a space in it is genuinely ambiguous
# there and unambiguous here. Git C-quotes exotic names (`"a/\303\251.py"`)
# and those come through quoted; that only mislabels the file list shown to
# the model, never which hunks land in which slice.
chunk_split() {
  local diff="${1-}" dir="${2-}"
  [ -s "$diff" ] && [ -d "$dir" ] || return 1
  # LC_ALL=C: a diff is bytes, not text in the locale. macOS awk under a
  # UTF-8 locale stops at the first byte that is not UTF-8 (a file in a
  # legacy non-UTF-8 encoding), and the split would quietly fall back to one
  # pass.
  LC_ALL=C awk -v dir="$dir" '
    /^diff --git / {
      if (n > 0) close(out)
      n++
      out = sprintf("%s/%04d.part", dir, n)
      cnt[n] = 0; path[n] = ""
    }
    n == 0 { next }
    {
      print > out
      # The two sides are tracked SEPARATELY and resolved at the end. A single
      # "first one wins" slot looks equivalent and is not: `--- a/old.py`
      # arrives before `+++ b/new.py`, so a RENAME was labelled with the path
      # the file no longer has. The fixture that missed it had identical a/
      # and b/ paths on every file, which is every case except the one that
      # breaks. Caught by the gate reviewing this very change.
      if (substr($0, 1, 6) == "+++ b/") newp[n] = substr($0, 7)
      else if (substr($0, 1, 7) == "+++ \"b/") newp[n] = substr($0, 8)
      else if (substr($0, 1, 6) == "--- a/") oldp[n] = substr($0, 7)
      else if (substr($0, 1, 7) == "--- \"a/") oldp[n] = substr($0, 8)
      # Count changed lines only INSIDE hunks. The first version excluded the
      # file headers by their +++/--- prefix instead, which also silently
      # excluded any real changed line whose CONTENT starts with ++ or --: a
      # deleted SQL comment `-- x` becomes `--- x` in the diff and stopped
      # being counted. Headers all sit before the first @@, so the position
      # test is both simpler and exact.
      if ($0 ~ /^@@/) inhunk[n] = 1
      c = substr($0, 1, 1)
      if (inhunk[n] == 1 && (c == "+" || c == "-")) cnt[n]++
    }
    END {
      if (n > 0) close(out)
      for (i = 1; i <= n; i++) {
        # The POST-change path is what every consumer wants: the slice file
        # list, the unreviewed-files list, and what the model is told it is
        # looking at. The old path is the fallback for a deletion, where
        # there is no new side.
        # NOTE: no apostrophes anywhere inside this awk program. It is a
        # single-quoted shell string, so one apostrophe in a comment ends it
        # and bash starts parsing awk as shell.
        p = (newp[i] != "" ? newp[i] : (oldp[i] != "" ? oldp[i] : "(unknown)"))
        printf "%d\t%s/%04d.part\t%s\n", cnt[i], dir, i, p
      }
      # Non-zero when there was nothing to split, because the comment above
      # promises it and a caller is entitled to write `chunk_split ... ||
      # fallback`. The first version only produced no output, so that caller
      # would have got an empty plan and NO fallback — a diff reviewed as
      # zero slices reads exactly like a diff with nothing wrong in it.
      if (n == 0) exit 1
    }
  ' "$diff"
}

# Pack parts into slices. Reads chunk_split's output on stdin, echoes the same
# lines with a leading "<slice-index>\t".
# $1 = target changed-lines per slice, $2 = the hard ceiling on slice count.
#
# Greedy first-fit in diff order, and the order is not an accident: git groups
# a diff by path, so neighbouring parts are usually the same subsystem, and a
# slice that holds one subsystem reads better than one assembled by size.
#
# Two rules the packing must obey, both learned from what the caller does with
# the answer:
#   - a part alone in a slice is allowed to exceed the target. The alternative
#     is splitting a file, which is worse (see the header).
#   - once the ceiling is reached everything else joins the LAST slice rather
#     than opening a new one. An unbounded slice count is an unbounded number
#     of model calls per PR, and this gate already fans out across PRs; the
#     tail of one enormous PR is better reviewed shallowly than not at all.
# A target or ceiling that is not a positive number falls back to one slice —
# a typo'd knob must degrade to today's behaviour, never to a fan-out storm.
chunk_plan() {
  local target="${1-}" max="${2-}"
  case "$target" in ''|*[!0-9]*) target=0 ;; esac
  case "$max" in ''|*[!0-9]*) max=0 ;; esac
  if [ "$target" -le 0 ] || [ "$max" -le 1 ]; then
    LC_ALL=C awk '{ print "1\t" $0 }'
    return 0
  fi
  LC_ALL=C awk -F'\t' -v target="$target" -v max="$max" '
    BEGIN { OFS = "\t"; slice = 1; used = 0 }
    {
      lines = $1 + 0
      # Start a new slice only when this part would push a NON-EMPTY slice
      # past the target, and only while slices remain.
      if (used > 0 && used + lines > target && slice < max) { slice++; used = 0 }
      used += lines
      print slice, $0
    }
  '
}

# Merge the slices' JSON replies back into ONE object of exactly the shape
# the rest of the harness already parses. Input is a slurped array of the
# per-slice objects (`jq -s`); output is one object.
#
# The merge is mechanical on purpose — no second model call to reconcile.
# A reconciler is one more place to lose a finding, and everything downstream
# (shape filter, citation check, convergence caps, verdict recompute) already
# operates on the merged array and does not care which pass produced an entry.
#
# verdict: request_changes if ANY slice asked for it. The harness recomputes
# the verdict from severities anyway, so this only has to avoid being the
# optimistic answer while that recompute runs.
#
# summary is CAPPED, and the number is not taste. The posted comment puts the
# summary before the findings, and the cross-round memory keeps only the
# first 4500 characters of each round (lib/prompt.sh says how that was
# sized). Eight slices each writing a 2-4 sentence summary joins to more than
# that on its own, so the next round would inherit a window full of prose with
# every finding cut off the end — and duty (a), carrying unfixed blockers
# forward, reads exactly the part that got cut.
#
# findings: deduped on file+line+issue text. Slices are told to report only
# about their own files, so exact duplicates should be rare — except for the
# one case where they are guaranteed and wanted: a carried finding from a
# prior round, which the prompt requires be copied with its issue text, so two
# slices that both think they own it collapse to one here.
# A carried finding is keyed on file+issue and not on its line, because the
# round task lets a slice move a wrong line to the right one. Two slices can
# then give two lines for one finding.
# Entries that share a key may still disagree on severity, area, audience or
# kind. The merge merges only entries with an identical profile: the same
# severity as written, area, audience (only read on a doc) and kind cap. It
# keeps every distinct profile, and it does not rank or drop an entry by how
# much it blocks. The real convergence caps run after the merge and in later
# rounds they depend on the round, so no rank made here is safe. A variant
# that is a minor one in round 1 can be the only blocker after the late cap.
# Trade-off: one finding can appear twice, once per profile. Between identical
# entries the first slice in the input wins, and the line of a kept entry is
# the line its own slice gave.
#
# unverified: unioned and capped at 3, matching the single-pass contract. Six
# slices each declaring three residual risks would otherwise bury the reader
# in the one field that exists to be read.
#
# The severity re-sort is not cosmetic and it is not optional. jq's unique_by
# SORTS, so deduping by file+line+issue silently reorders the array by file
# path — and the renderer downstream prints the array in order, which would
# put a LOW above a CRITICAL in the comment a person skims. The ladder is
# spelled out here, and not taken from lib/findings.sh, because it only orders
# the output. Anything unrecognised sorts with HIGH, the same fail-closed
# direction the blocking tally takes.
# The truncation mark is the one string in this merge a reader sees;
# everything else here is structure.
CHUNK_SUMMARY_CUT=' (summary too long, truncated)'
# shellcheck disable=SC2034  # read by the scripts that source this lib
CHUNK_MERGE_JQ='
  def sev_rank:
    ((.severity // "") | tostring | ascii_upcase | gsub("^\\s+|\\s+$"; "")) as $s
    | if   $s == "CRITICAL" then 0
      elif $s == "MEDIUM"   then 2
      elif $s == "LOW"      then 3
      else 1 end;
  def txt(f): f | if type == "string" then (gsub("^\\s+|\\s+$"; "") | ascii_downcase) else "" end;
  def profile:
    txt(.area) as $a | txt(.kind) as $k
    | [txt(.severity), $a,
       (if $a == "doc" then txt(.audience) else "" end),
       (if (["wording", "judgment", "half_fix"] | index($k)) != null then "capped" else "" end)];
  { verdict: (if any(.[]; (.verdict // "") == "request_changes")
              then "request_changes" else "approve" end),
    summary: ([.[].summary // empty | select(type == "string")] | join(" ")
              | if length > 1200 then .[0:1200] + "'"$CHUNK_SUMMARY_CUT"'" else . end),
    unverified: ([.[].unverified[]? | select(type == "string")] | unique | .[0:3]),
    findings: ([.[].findings[]? | select(type == "object")]
               | group_by([(.file // "" | tostring),
                           (if ((.issue // "" | tostring) | test("^\\s*carried[ -]over"; "i"))
                            then "carried" else (.line // 0 | tostring) end),
                           (.issue // "" | tostring)])
               | map(unique_by(profile)) | add // []
               | sort_by(sev_rank)) }'

# How many independent review passes a round gets.
# $1 round, $2 changed lines, $3 first-round samples, $4 later-round samples,
# $5 the size from which a first round always gets at least two passes.
# Round 1 searches, so it is the round worth sampling; later rounds verify and
# stay at $4. A first round on a diff of $5 lines or more gets at least two
# passes whatever $3 says: on a diff that big a first round with no HIGH is
# rare.
# So a single pass that comes back empty there is more likely the pass
# that missed than the PR that is clean. It is folded into the sample count
# rather than run as a separate "recheck" call. Bad input reads as 1.
chunk_samples_for_round() {
  local round="${1:-1}" size="${2:-0}" r1="${3:-1}" later="${4:-1}" floor="${5:-0}" n
  for v in round size r1 later floor; do
    case "${!v}" in '' | *[!0-9]*) eval "$v=0" ;; esac
  done
  if [ "$round" -le 1 ]; then n="$r1"; else n="$later"; fi
  [ "$n" -ge 1 ] || n=1
  if [ "$round" -le 1 ] && [ "$floor" -gt 0 ] && [ "$size" -ge "$floor" ] && [ "$n" -lt 2 ]; then n=2; fi
  printf '%s\n' "$n"
}

