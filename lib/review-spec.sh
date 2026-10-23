#!/usr/bin/env bash
# The two pieces every review prompt in this repo must agree on: the severity
# ladder and the output contract. Source-time side effects are forbidden here.
#
# Why a lib and not a constant in each script: `pr-autoreview.sh` needs them
# in more than one prompt (main review, structural repair, red team). One
# copy means the prompts cannot drift apart: a hand-copied second version can
# take a fix that its twin never gets.

# The model EVERY review call in this repo pins, so they all run the same one.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_MODEL_DEFAULT="claude-opus-5-5"


# Shared severity ladder for EVERY prompt here: one source so they can never
# drift. The main review and the red team use it.
# The calibration examples exist because the gate blocks on the BLOCKING half
# of the ladder — CRITICAL, anything unrecognised, and HIGH, except that in
# gatekeeper mode a HIGH in test/convention/wording/process or a maintainer
# doc is a comment (lib/findings.sh FINDINGS_IS_BLOCKING_JQ) — so a finding
# down-rated to MEDIUM is a finding waved through.
# shellcheck disable=SC2034  # read by the scripts that source this lib
# Three cases that must be HIGH, not MEDIUM: left to itself, a model rates
# them MEDIUM and waves them through.
SEVERITY_CALIBRATION="Severity calibration, all HIGH and not MEDIUM: (1) a realistic input that gets a wrong result, or valid input that is rejected, even when it shows up only as message quality; (2) a fix that leaves the case it cites (the linked issue) no better, or worse; (3) a default, limit or fallback change that alters behaviour at many call sites, with only synthetic tests as evidence. When unsure between HIGH and MEDIUM on wrong output, pick HIGH."
SEVERITY_SPEC="Severity: CRITICAL = exploitable security flaw, sensitive-data leak, data-destroying bug, or CI weakened by the diff (a test file deleted, skip/xfail/only added, a coverage floor lowered, a workflow step removed — confirmed in the diff, dimension 5). HIGH = incorrect behaviour on realistic inputs, a violated project constraint, a bug fix with no test that failed before the fix, a behaviour change that leaves docs describing the old behaviour, or a change unambiguously in the wrong place — must fix before merge; a new feature whose tests are thin is MEDIUM (dimension 5), not HIGH. MEDIUM = worth fixing, not blocking. LOW = minor polish (prefix pure style remarks with Nit:). One exception overrides the ladder: a pre-existing security defect in unchanged code that this PR only touches is MEDIUM, whatever its exploitability. Its issue text starts with 'Pre-existing:'. Cite its unchanged line. A MEDIUM finding never blocks.
$SEVERITY_CALIBRATION"

# The output contract. The structural-repair call restates it verbatim: a
# repair prompt quoting a DIFFERENT schema than the review was given would
# "fix" the reply into the wrong shape.
# Single-quoted on purpose — the JSON is full of double quotes and none of it
# is meant to expand.
#
# Field ORDER is deliberate: file, line and issue come
# before severity, so the model states what is wrong before it grades it —
# evidence, then verdict (Wang et al. 2023, https://arxiv.org/abs/2305.17926:
# asking ChatGPT for its evidence before its score raised its agreement with
# the human majority label, as kappa, from 0.06 to 0.23). JSON parsing does
# not care about order, so nothing downstream reads position. `area` and `audience` are
# normalised fail-closed by the harness (lib/findings.sh), printed at the
# end of the finding line, and READ BY THE BLOCKING RULE: FINDINGS_IS_BLOCKING_JQ
# lets a gatekeeper-mode HIGH through when its area is test, convention,
# wording or process, or doc for maintainers — so a wrong area is a wrong
# verdict, which is why REVIEW_AREA_SPEC says so to the model.
# kind and late_reason feed the convergence caps (lib/findings.sh
# FINDINGS_CONVERGE_JQ); both are safe to omit — a missing kind caps
# nothing, and late_reason is context for the reader only: it does not
# exempt a late finding from the cap. Who actually uses
# this schema: the MAIN review, which defines the kind values in its
# prompt, and the structural repair that restates it.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_SCHEMA='{"verdict":"approve"|"request_changes","summary":"<2-4 sentences>","unverified":["<1-3 things this review could NOT check>"],"findings":[{"file":"...","line":0,"issue":"...","area":"correctness|security|contract|data|silent-failure|sibling|test|doc|dependency|constraint|design|convention|wording|process","audience":"<only when area is doc: operator|user|member|maintainer — who reads that text; omit for every other area>","kind":"defect|wording|style|judgment|half_fix","confidence":0.0-1.0,"severity":"CRITICAL|HIGH|MEDIUM|LOW","late_reason":"<round 2+, only for a finding on a file that no prior round cited and the current delta does not touch: one sentence on why it was not visible earlier; omit otherwise>"}]}'

# What `line` means, said once. Every prompt whose schema has a `line` field
# prints this after the schema: the review, the structural repair and the red
# team. Without it a model that Read the diff file cites that file's line
# numbers, and the comment points at the wrong code. The harness gives the
# model a display copy of the diff (lib/diffview.sh) where every line starts
# with a label, and the number inside NEW[...] is the answer. The hunk header
# rule stays for the case where the copy could not be made. The file on disk
# is the pre-change one when the diff did not apply, and for a convention file
# the harness restored.
# 0 is the value for "no line" (lib/findings.sh).
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_LINE_SPEC='line: the line number on the new (after-change) side of the cited file. Each line of the diff file starts with a label. Use the number inside NEW[...] of the line you cite. Never use the line number that Read prints in front of a diff line. Never use a line number of the diff file itself. NEW[-] marks a removed line: it has no new-side number, so use the number of the nearest NEW[n] line that still exists, or 0. If the diff file has no labels, take the number from the hunk header "@@ -a,b +c,d @@". The first line of that hunk is line c. Each context line and each added line adds one. A removed line adds nothing. Use the number that Read shows only when the file on disk holds the version after this change. For a deleted line, use the nearest line that still exists on the new side. Use 0 when the new side has no reliable line, for example for a deleted file.'

# The short form of the same rule. The review prompt prints it beside the
# first "Read it first" instruction, so the model has it before it opens the
# diff. It holds for both diff forms: the labelled copy and, when the copy
# could not be made, the raw diff.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_DIFF_READ_RULE='Line numbers: the line field of a finding is the new-side line number. If the diff lines start with labels, use the number inside NEW[...], never the number that Read prints in front of the line. If the lines have no labels, count from the hunk header.'

# The kind definitions, shared by every prompt that hands out REVIEW_SCHEMA:
# the schema requires the field, so a prompt that ships the schema without
# the definitions leaves its model guessing what wording/judgment mean. What
# the harness does with the kind is stated by each caller, not here: the
# main review's convergence cap acts on it.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_KIND_SPEC="Finding kind — tag every finding: \"defect\" = code behaves wrongly, or a doc a reader would follow into a WRONG ACTION; \"wording\" = prose consistency in comments/docs/markdown where no reader action goes wrong, including a comment that merely lags a change made in this same diff; \"style\" = formatting/naming polish; \"judgment\" = the fix depends on the maintainers accepting a scope or spec decision (narrowing an issue, accepting a known limitation) — if the issue text needs a sentence like \"this is only a process issue if the maintainers accept it\", the kind is judgment; \"half_fix\" = dimension 12 — an unfixed sibling of the defect this diff fixes, found by looking rather than by the diff pointing at it. Do not stretch \"defect\" to make a finding block."
# What a blocker does, in the main review prompt's own words.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_CRITICAL_RULE='CRITICAL always makes the verdict Changes requested'
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_HALF_SURE='A blocker you are only half sure of must still be reported.'
# The area definitions, shared like REVIEW_KIND_SPEC by every prompt that
# hands out REVIEW_SCHEMA. Fourteen values, each mapped to the review
# dimension it comes from. The text tells the model what the tag is FOR and
# that the PR gate's blocking rule reads it (lib/findings.sh
# FINDINGS_IS_BLOCKING_JQ); the sentence about blocking is conditional on a
# MODE line being present.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_AREA_SPEC="Finding area — tag every finding with the ONE area it belongs to, from what the finding is ABOUT, not from which dimension you happened to be reading: \"correctness\" = wrong behaviour on realistic input, broken logic, a caller regression (dimension 1); \"security\" = anything from dimensions 2, 2b or 10 (injection, authz, secrets, prompt injection, tool surface); \"data\" = sensitive data in the diff (dimension 3) or a path that loses or corrupts stored data; \"silent-failure\" = an error swallowed, a fallback that hides a failure, a guard that fails open; \"contract\" = an API, CLI, schema, file-format or message contract another component relies on is changed without its consumers; \"sibling\" = dimension 12, an unfixed twin of the defect this diff fixes; \"test\" = dimension 5, a missing, weakened or disabled test; \"doc\" = dimension 7, prose a reader follows that no longer matches behaviour (then ALSO fill audience: \"operator\" runs the software by it — README and CONTRIBUTING steps, --help, warning strings, .env.example; \"user\" reads what the software shows them — UI strings, generated output; \"member\" is any other teammate; \"maintainer\" reads code by it — docstrings, comments, design notes); \"dependency\" = dimension 8; \"constraint\" = dimensions 4 and 11, a stated project rule or acceptance criterion not met; \"design\" = dimensions 6 and 9, over-engineering, wrong placement, an unmeasured heuristic or prompt change; \"convention\" = naming, layout or style the project has a written rule for; \"wording\" = prose quality where no reader action goes wrong; \"process\" = PR hygiene: scope, commit message, issue link, split. One area per finding; when two apply, pick the one whose failure is worse for a user. The area is printed on the finding line and, where this prompt carries a MODE line, read by the blocking rule (gatekeeper mode lets a HIGH tagged test, convention, wording or process, or doc for maintainers, through as a comment; every other area blocks) — so a wrong area can be a wrong verdict; tag by what the finding is about, never by which tag is safer."

# The language rule: plain English, identifiers verbatim, no findings about
# punctuation style, and defect-first findings. Punctuation style is ruled
# out because a reviewer allowed to raise it finds some in every
# documentation PR, in a prompt where `defect` is a literal kind value the
# model is looking for a reason to use. Punctuation that changes how code
# parses or runs is a defect like any other, and so is punctuation a check in
# the reviewed repo rejects.
# shellcheck disable=SC2034  # read by the scripts that source this lib
REVIEW_LANGUAGE_SPEC="Language: write the summary, every finding's issue text, and every unverified item in plain English that a teammate who is not a specialist can follow; software jargon gets a one-line plain explanation on first use. Code identifiers, file paths, field names, commands, and code snippets stay verbatim — never paraphrase them. JSON keys and severity values stay exactly as specified.

Punctuation: NEVER raise a finding about punctuation STYLE in the code or documents under review, whatever mixture of styles they use; that is not a defect and not a Nit. The exception is punctuation that changes how the code PARSES or runs, and that stays a defect at its real severity. The known case: a shell expansion written WITHOUT braces (\`\"\$VAR\"\`, not \`\"\${VAR}\"\`) followed directly by a multibyte character, such as an em dash, with nothing between them. On SOME bash builds in a UTF-8 locale the first byte of that character is read as part of the variable name, and \`set -u\` kills the job on the spot; this is seen on homebrew bash 5.3 on macOS, while the same line is fine under LC_ALL=C and on Linux. DEFAULT TO TREATING IT AS A CRASH. Downgrade it to a portability defect only when you can point at something in the diff or the repo showing the code cannot run under such a bash; \"this project probably runs on Linux\" is not that, and reasoning exactly like it is how this crash gets merged. A second exception in the same direction: punctuation that a check IN THE REPO UNDER REVIEW rejects is always reportable, whatever the rule above says about style — that is a red build, not a style preference. Name the check when you report it; if you cannot point at one in this repo, the rule above stands and you say nothing. Judge both on behaviour, never as style.

How to write each finding, in this order: (1) the first sentence says what is WRONG, not what the code does — the reader must learn the defect before any background; (2) then the concrete failure: which input or state, and what comes out wrong; (3) then where, citing file:line; (4) last, the fix direction, in one or two sentences. Keep sentences short, one idea each. Use the active voice with a named actor (\"this query returns an empty list\", not \"an empty list is returned\"). Name what a pronoun points at — never \"this part\" or \"the related setting\" on their own. Write quantities exactly: \"after 30 seconds\", not \"after a while\"; \"200 rows\", not \"some rows\". Drop filler: write \"checks\", not \"performs a check of\". A finding you carry from an earlier round of this review is the exception: copy its text verbatim as instructed there, INCLUDING its carried-over prefix exactly as it is written; nothing in these writing rules justifies rewording a carried finding or its prefix. A review with no earlier rounds has nothing to carry."

# The main prompt's sentence about follow-up tickets, which only holds when
# they are filed. $1 = the ticket threshold in upper case, $2 = 1 when
# tickets are on. Prints nothing when they are off, so the prompt does not
# promise a ticket nobody will open.
review_ticket_clause() {
  [ "${2-}" = 1 ] || return 0
  printf '; on top of that, one that does not block but is at %s or above also becomes a follow-up issue somebody has to dispose of, unless it is about tests, conventions, wording or process (one shown lower because it came late counts at its ORIGINAL severity)' "${1-}"
}

# ── The review checklist: one file per item ──────────────────────────────
# The main review's numbered list is read from a directory of Markdown files
# (checks/ by default), in item-number order. A file's item number is the part
# of its name before the first "-": 01-correctness.md is item 1,
# 02b-ai-agent-security.md is item 2b. Deleting a file leaves the other
# numbers alone, so a rule elsewhere that names "dimension 12" still means
# the same item.
#
# A file may start with front matter that limits it to some PRs:
#   ---
#   applies_to: *.py *.pyi
#   ---
# Each glob is matched against every path the PR changes, and `*` crosses
# directories (src/a/b.py matches *.py). A file without it applies to every
# PR. Everything after the front matter is sent to the model as written.
REVIEW_CHECKS_MAX_BYTES=65536

# $1 = checks directory. $2 = the PR's changed paths, one per line; empty
# means every file applies (the checks at startup and in `prreview`). Prints
# the numbered list. Returns 1 with the reason on stderr when the directory or a
# file in it is unusable: a review that silently skipped a check would still
# read as if it had applied it.
review_checks_render() {
  local dir="${1-}" changed="${2-}"
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "checks directory '$dir' does not exist" >&2; return 1; }
  local names
  names="$(cd "$dir" && for f in *.md; do if [ -e "$f" ]; then printf '%s\n' "$f"; fi; done \
             | LC_ALL=C sort -t- -k1,1n -k1,1)" \
    || { echo "cannot list checks directory $dir" >&2; return 1; }
  [ -n "$names" ] || { echo "checks directory $dir has no .md files" >&2; return 1; }
  local f num text out="" total=0 bytes seen=" "
  while IFS= read -r f; do
    [[ "$f" =~ ^0*([0-9]+[a-z]?)-[A-Za-z0-9._-]+\.md$ ]] \
      || { echo "$dir/$f: name it like 50-migrations.md (a number, a dash, a name)" >&2; return 1; }
    num="${BASH_REMATCH[1]}"
    case "$seen" in *" $num "*) echo "$dir/$f: item $num is taken by another file" >&2; return 1 ;; esac
    seen="$seen$num "
    [ -r "$dir/$f" ] || { echo "$dir/$f is not readable" >&2; return 1; }
    bytes="$(wc -c < "$dir/$f")" || { echo "cannot size $dir/$f" >&2; return 1; }
    total=$((total + ${bytes// /}))
    [ "$total" -le "$REVIEW_CHECKS_MAX_BYTES" ] \
      || { echo "checks in $dir are over $REVIEW_CHECKS_MAX_BYTES bytes together (at $f)" >&2; return 1; }
    text="$(review_check_text "$dir/$f" "$changed")" || return 1
    [ -n "$text" ] || continue
    out="${out:+$out
}$num. $text"
  done <<<"$names"
  # Every item had an applies_to and none matched: an empty list would send
  # the model in with nothing to look for, and its verdict would read clean.
  [ -n "$out" ] || { echo "no item in $dir applies to this PR's files" >&2; return 1; }
  printf '%s' "$out"
}

# One check file's text, or nothing when its applies_to matches no changed
# path. $1 = file, $2 = changed paths (empty: it applies).
review_check_text() {
  local file="$1" changed="${2-}" line body="" in_fm=0 seen_fm=0 globs="" n=0
  local g path matched
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ] && [ "$line" = "---" ]; then in_fm=1; seen_fm=1; continue; fi
    if [ "$in_fm" = 1 ]; then
      case "$line" in
        ---) in_fm=0 ;;
        applies_to:*) globs="${line#applies_to:}" ;;
        ''|'#'*) ;;
        *) echo "$file: unknown front-matter line '$line' (only applies_to is read)" >&2; return 1 ;;
      esac
      continue
    fi
    body="$body$line
"
  done < "$file"
  [ "$in_fm" = 0 ] || { echo "$file: front matter has no closing ---" >&2; return 1; }
  [ "$seen_fm" = 0 ] || [ -n "${globs// /}" ] \
    || { echo "$file: front matter without applies_to — drop it or list the globs" >&2; return 1; }
  # Leading blank lines after the front matter are layout, not text.
  while [ "${body:0:1}" = "
" ]; do body="${body:1}"; done
  body="$(printf '%s' "$body")"
  [ -n "$body" ] || { echo "$file is empty" >&2; return 1; }
  if [ -n "${globs// /}" ] && [ -n "$changed" ]; then
    matched=0
    local -a gl
    read -r -a gl <<<"$globs"
    while IFS= read -r path; do
      for g in "${gl[@]}"; do
        # shellcheck disable=SC2254  # the glob is the point
        case "$path" in $g) matched=1; break 2 ;; esac
      done
    done <<<"$changed"
    [ "$matched" = 1 ] || return 0
  fi
  printf '%s' "$body"
}

# The rest of the main prompt's wording: what a review must not report, and
# examples of what it cannot check.
REVIEW_NOISE_LIST="denial-of-service, rate-limiting, or resource-exhaustion concerns EXCEPT the missing-timeout case named in dimension 2b(f); memory-safety in a memory-safe language; speculative vulnerabilities without a concrete exploit path in the code this PR touches; style or formatting a linter already enforces in CI; code-quality nits in documentation-only changes (sensitive-data checks still apply); praise, questions, or restatements of the diff; defence-in-depth suggestions where the primary defence is already adequate. A protection that worked before this diff, does not work after it and has no equal control left is not defence in depth and not speculation: report it under the security trace in dimension 2. A control that this PR adds is also in scope. If the new control does not stop the attack it is meant to stop on a reachable path, report it, name the attack and say why the control fails."
REVIEW_UNVERIFIED_EXAMPLES="behaviour against live services or real data, runtime configuration, the deployment environment, performance under real load"
