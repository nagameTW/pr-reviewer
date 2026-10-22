#!/usr/bin/env bash
# Tests for lib/loop.sh and the drivers that use it. No network, no
# gh: loop_open_pr_count takes the gh binary as its second ARGUMENT, and the
# tests pass a stub path there. No test injects a fake gh via PATH — that
# would call the real gh the moment the injection slipped.
#
# The failure this guards is why the assertions look the way they do. A
# driver that decides whether a round is worth running by counting open PRs
# on ONE repo, while the script it drives iterates a longer list, exits early
# every round when the first repo has zero open PRs and the others have PRs
# waiting, and reviews nothing. The log line is `open PRs=0`, which reads as
# "nothing to do", not as "did not look". Nothing fails and nothing is
# logged, so it lasts until someone notices an unreviewed PR.
#
# Run: bash tests/loop.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. lib/loop.sh || { echo "FAIL: cannot source lib/loop.sh"; exit 1; }
. lib/trust.sh || { echo "FAIL: cannot source lib/trust.sh"; exit 1; }
. lib/prreview-config.sh || { echo "FAIL: cannot source lib/prreview-config.sh"; exit 1; }
. lib/tools.sh || { echo "FAIL: cannot source lib/tools.sh"; exit 1; }
# macOS without the coreutils gnubin directory has gtimeout and no timeout.
# Find the commands the way the scripts do.
tools_resolve || { echo "FAIL: no timeout command or no SHA-256 command on PATH"; exit 1; }

FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; FAILED=1; }
is()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "contains '$2'" "absent";; esac; }

# ── loop_repos_of reads the REAL scripts ──────────────────────────────────
# Every check below runs against this list of repos.
export PRREVIEW_GATE_REPOS="example-org/recipes example-org/library octo/bike-shop"
# Against the actual files, not a fixture: a fixture would keep agreeing with
# itself while the drivers drifted.
GATE_REPOS="$(loop_repos_of ./pr-autoreview.sh)"
has 'the gate list includes the first repo'  'example-org/recipes' "$GATE_REPOS"
has 'the gate list includes the second repo' 'example-org/library' "$GATE_REPOS"
has 'the gate list includes the last repo'   'octo/bike-shop'      "$GATE_REPOS"
is  'the gate list has every repo in PRREVIEW_GATE_REPOS, and no more' "$(wc -w <<<"$GATE_REPOS" | tr -d ' ')" '3'


# ── loop_repos_of refuses rather than guesses ─────────────────────────────
loop_repos_of /nonexistent/script.sh >/dev/null 2>&1 \
  && bad 'a missing script is refused' 'non-zero' 'zero' \
  || ok 'a missing script is refused'
NOREPOS="$(mktemp)"; printf '#!/bin/sh\necho hi\n' > "$NOREPOS"
loop_repos_of "$NOREPOS" >/dev/null 2>&1 \
  && bad 'a script with no REPOS= is refused' 'non-zero' 'zero' \
  || ok 'a script with no REPOS= is refused'
rm -f "$NOREPOS"

# ── loop_open_pr_count sums, and fails toward "there is work" ─────────────
# The count applies the rule the round applies (lib/trust.sh), so it reads
# the trust settings from the environment. Start from a known state.
unset PRREVIEW_GATE_TRUSTED_AUTHORS PRREVIEW_GATE_FORK_PRS
STUB_DIR="$(mktemp -d)"
mkstub() {  # $1 = body
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$STUB_DIR/gh"
  chmod +x "$STUB_DIR/gh"
}
# PRs as `gh pr list --json number,author,isCrossRepository,isDraft` prints them.
PR_OWN='{"number":1,"author":{"login":"maint"},"isCrossRepository":false}'
PR_FORK='{"number":2,"author":{"login":"stranger"},"isCrossRepository":true}'
PR_FORK2='{"number":3,"author":{"login":"other"},"isCrossRepository":true}'
PR_ALICE='{"number":4,"author":{"login":"Alice"},"isCrossRepository":true}'
list() { local IFS=,; printf '[%s]' "$*"; }  # the JSON array of the PRs given
# Every repo answers with the list $1.
stub_list() { printf '%s\n' "$1" > "$STUB_DIR/all.json"; mkstub "cat '$STUB_DIR/all.json'"; }
# The LAST repo answers with the list $1 and every other repo with $2.
stub_last() {
  printf '%s\n' "$1" > "$STUB_DIR/last.json"; printf '%s\n' "$2" > "$STUB_DIR/rest.json"
  mkstub "case \"\$*\" in *bike-shop*) cat '$STUB_DIR/last.json' ;; *) cat '$STUB_DIR/rest.json' ;; esac"
}
count() { loop_open_pr_count ./pr-autoreview.sh "$STUB_DIR/gh"; }

# One PR on the LAST repo in the list and none on the first: the shape a
# single-repo count answers with 0.
stub_last "$(list "$PR_OWN")" '[]'
is 'a PR on the last repo alone still admits the round' "$(count)" '1'

stub_list "$(list "$PR_OWN" "$PR_OWN")"
is 'counts are summed across every repo' "$(count)" '6'

stub_list '[]'
is 'a genuinely empty queue skips the round' "$(count)" '0'

# gh down, gh unauthenticated, gh printing an error onto stdout: all of them
# must count as work, never as an empty queue. A transient failure read as
# zero is a review silently not happening.
mkstub 'exit 1'
is 'a failing gh counts as work, not as zero' "$(count)" '3'
mkstub 'echo "error: not logged in"'
is 'non-numeric gh output counts as work' "$(count)" '3'
mkstub 'echo ""'
is 'empty gh output counts as work' "$(count)" '3'
stub_list '{"message":"Bad credentials"}'
is 'an answer that is not a list counts as work' "$(count)" '3'
# The round refuses a list with such an entry and reports it. Admitting the
# round makes that report appear.
stub_list '[{"author":{"login":"maint"},"isCrossRepository":false}]'
is 'an entry with no number counts as work' "$(count)" '3'

is 'an unreadable driven script admits the round rather than skipping it' \
   "$(loop_open_pr_count /nonexistent/script.sh "$STUB_DIR/gh")" '1'

# ── the count skips what the round skips ──────────────────────────────────
# One fork PR from a stranger, left open, must not start a round every
# interval: the round skips it, and a round that skips everything still pays
# for the merged-PR scan.
stub_list "$(list "$PR_FORK" "$PR_FORK2")"
is 'open PRs that are all untrusted fork PRs count 0' "$(count)" '0'
stub_last "$(list "$PR_FORK" "$PR_OWN" "$PR_FORK2")" "$(list "$PR_FORK")"
is 'one trusted PR among fork PRs counts 1' "$(count)" '1'
stub_list "$(list "$PR_FORK" "$PR_FORK2")"
is 'with PRREVIEW_GATE_FORK_PRS=1 fork PRs count' \
   "$( export PRREVIEW_GATE_FORK_PRS=1; count )" '6'
stub_last "$(list "$PR_FORK" "$PR_ALICE")" "$(list "$PR_FORK")"
is 'a fork PR by an allowlisted author counts, whatever the letter case' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='bob, alice'; count )" '1'
is 'the same fork PR counts 0 when its author is not on the list' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='bob'; count )" '0'

# A field that is missing or of the wrong type is not trusted.
stub_list '[{"number":5,"author":{"login":"stranger"}}]'
is 'a PR with no isCrossRepository field counts 0' "$(count)" '0'
stub_list '[{"number":5,"author":{"login":"stranger"},"isCrossRepository":"false"}]'
is 'a PR whose isCrossRepository is not a boolean counts 0' "$(count)" '0'
stub_list '[{"number":5,"isCrossRepository":true}]'
is 'a fork PR with no author counts 0' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='stranger'; count )" '0'
stub_list '[{"number":5,"author":null,"isCrossRepository":true}]'
is 'a fork PR with a null author counts 0' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='stranger'; count )" '0'

# An allowlisted author does not excuse a bad fork flag, and a same-repository
# flag does not excuse a bad author. One record at a time, so one bad field is
# the only cause of a count of 0.
GOOD_AUTHOR='"author":{"login":"stranger"}'
for F in '' ',"isCrossRepository":null' ',"isCrossRepository":"false"' ',"isCrossRepository":"true"'; do
  stub_list "[{\"number\":5,$GOOD_AUTHOR$F}]"
  is "an allowlisted author with this fork flag counts 0: ${F:-missing}" \
     "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='stranger'; count )" '0'
done
for A in '' ',"author":null' ',"author":{}' ',"author":{"login":null}' ',"author":{"login":5}' ',"author":{"login":""}'; do
  stub_list "[{\"number\":5,\"isCrossRepository\":false$A}]"
  is "a same-repository PR with this author counts 0: ${A:-missing}" "$(count)" '0'
done
stub_list '[{"number":5,"author":{"login":"maint"},"isCrossRepository":false}]'
is 'a complete same-repository PR counts 1 per repo' "$(count)" '3'
stub_list '[{"number":5,"author":{"login":"stranger"},"isCrossRepository":true}]'
is 'a complete allowlisted fork PR counts 1 per repo' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='stranger'; count )" '3'

# The round skips a draft PR, so the count skips it too. Only a boolean true is
# a draft. A missing or non-boolean isDraft counts as not a draft, so the round
# decides.
stub_list "[{\"number\":6,$GOOD_AUTHOR,\"isCrossRepository\":false,\"isDraft\":true}]"
is 'a draft PR from the repository itself counts 0' "$(count)" '0'
stub_list "[{\"number\":6,$GOOD_AUTHOR,\"isCrossRepository\":true,\"isDraft\":true}]"
is 'a draft fork PR of an allowlisted author counts 0' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS='stranger'; count )" '0'
stub_list "[{\"number\":6,$GOOD_AUTHOR,\"isCrossRepository\":false,\"isDraft\":true},{\"number\":7,$GOOD_AUTHOR,\"isCrossRepository\":false,\"isDraft\":false}]"
is 'a PR that is ready counts when a draft is open next to it' "$(count)" '3'
for D in '' ',"isDraft":false' ',"isDraft":null' ',"isDraft":"true"' ',"isDraft":1' ',"isDraft":[true]'; do
  stub_list "[{\"number\":8,$GOOD_AUTHOR,\"isCrossRepository\":false$D}]"
  is "a PR with this isDraft counts 1 per repo: ${D:-missing}" "$(count)" '3'
done
# The draft filter changes nothing for an answer that is not a list.
stub_list '{"message":"Bad credentials"}'
is 'an answer that is not a list still counts as work' "$(count)" '3'
stub_list '[null,{"number":9,"isDraft":true}]'
is 'an entry that is not an object is not dropped as a draft' "$(count)" '3'

# One list call for each repo, and it carries what the rule reads. The default
# limit of gh is 30; the round asks for 1000, and so does the count, or a
# trusted PR behind 30 forks would not be seen.
mkstub "echo \"\$*\" >> '$STUB_DIR/args'; echo '[]'"
count >/dev/null
is  'one list call for each repo' "$(wc -l < "$STUB_DIR/args" | tr -d ' ')" '3'
has 'the list call reads the number, author, fork flag and draft flag' '--json number,author,isCrossRepository,isDraft' "$(cat "$STUB_DIR/args")"
has 'the list call asks for the same limit as the round' '--limit 1000' "$(cat "$STUB_DIR/args")"

# The loop and the round read the same process environment, and
# `prreview run` fills that from the settings file before it starts the loop
# (lib/prreview-config.sh): a login in the file counts here, and an exported
# value wins over the file here as it does in the round.
CFG="$STUB_DIR/config"
printf 'PRREVIEW_GATE_TRUSTED_AUTHORS=alice\n' > "$CFG"
stub_last "$(list "$PR_ALICE" "$PR_FORK")" '[]'
is 'a login from the settings file counts' \
   "$( prreview_config_export "$CFG"; count )" '1'
is 'an exported login wins over the settings file' \
   "$( export PRREVIEW_GATE_TRUSTED_AUTHORS=carol; prreview_config_export "$CFG"; count )" '0'
rm -rf "$STUB_DIR"

# ── loop_rotate_log keeps the driver's own log bounded ────────────────────
ROT="$(mktemp -d)/gate.log"
printf 'small\n' > "$ROT"
loop_rotate_log "$ROT" 100
is 'a log under the limit is left alone' "$(cat "$ROT")$([ -e "$ROT.1" ] && echo ' +copy')" 'small'
printf '%0200d\n' 0 > "$ROT"
# The service manager's side: a descriptor opened for appending before the
# rotation, as launchd's StandardOutPath and systemd's append: both are.
exec 9>>"$ROT"
loop_rotate_log "$ROT" 100
echo after >&9
exec 9>&-
is 'past the limit the old lines move to .1' "$(wc -c < "$ROT.1" | tr -d ' ')" 201
is '...and a writer that had the log open keeps writing into the emptied file' "$(cat "$ROT")" 'after'
printf '%0200d\n' 1 > "$ROT"; loop_rotate_log "$ROT" 100
is 'a second rotation replaces the previous copy' "$(tr -d '\n' < "$ROT.1" | tail -c 1)" '1'
printf '%0200d\n' 2 > "$ROT"
is 'a limit that is not a number falls back to 10 MB quietly' "$(loop_rotate_log "$ROT" 'ten' 2>&1)" ''
is '...so a small log stays' "$(wc -c < "$ROT" | tr -d ' ')" 201
loop_rotate_log '' 100 && ok 'no log file named is a no-op' || bad 'no log file named is a no-op' 'rc 0' 'non-zero'
loop_rotate_log /nonexistent/gate.log 100 && ok 'a missing log is a no-op' || bad 'a missing log is a no-op' 'rc 0' 'non-zero'
printf '%0200d\n' 3 > "$ROT"; chmod 000 "$ROT"
is 'a log it cannot read is left alone, quietly' "$(loop_rotate_log "$ROT" 100 2>&1; wc -c < "$ROT.1" | tr -d ' ')" 201
chmod 600 "$ROT"
has 'the gate loop rotates its own log when told where it is' \
    'loop_rotate_log "${PRREVIEW_LOOP_LOG_FILE:-}"' "$(cat review-loop.sh)"

# ── loop_prune_logs keeps the newest N and touches nothing else ───────────
# Timestamps are set explicitly instead of slept into place: the ordering has
# to be a fact about the test, not about how fast the box is.
PRUNE_DIR="$(mktemp -d)"
# touch -t takes CCYYMMDDhhmm: five files an hour apart, 01:00 .. 05:00.
for n in 1 2 3 4 5; do
  : > "$PRUNE_DIR/round-$n.log"
  touch -t "200001020${n}00" "$PRUNE_DIR/round-$n.log"
done
: > "$PRUNE_DIR/gate.log"           # not a round log
: > "$PRUNE_DIR/round-notanumber"   # not a .log either
# Older than every round log, so a prune that reached past its pattern would
# take these first.
touch -t 200001010000 "$PRUNE_DIR/gate.log" "$PRUNE_DIR/round-notanumber"

loop_prune_logs "$PRUNE_DIR" 2
is 'prune keeps exactly N round logs' \
   "$(ls "$PRUNE_DIR"/round-*.log 2>/dev/null | wc -l | tr -d ' ')" '2'
is 'prune keeps the NEWEST ones' \
   "$(cd "$PRUNE_DIR" && printf '%s\n' round-*.log | sort)" \
   "$(printf 'round-4.log\nround-5.log')"
# The oldest file in the directory is deliberately NOT a round log: a prune
# that reached for it would be deleting the driver's own append-only log.
is 'prune leaves non-round files alone' \
   "$([ -e "$PRUNE_DIR/gate.log" ] && [ -e "$PRUNE_DIR/round-notanumber" ] && echo both)" 'both'

# Failure directions: never delete more than asked, never abort the round.
loop_prune_logs "$PRUNE_DIR" 0
is 'a zero keep-count still keeps one' \
   "$(ls "$PRUNE_DIR"/round-*.log 2>/dev/null | wc -l | tr -d ' ')" '1'
loop_prune_logs "$PRUNE_DIR" notanumber
is 'a non-numeric keep-count falls back to the default, deleting nothing' \
   "$(ls "$PRUNE_DIR"/round-*.log 2>/dev/null | wc -l | tr -d ' ')" '1'
loop_prune_logs /nonexistent/dir 2 \
  && ok 'a missing log dir is a no-op, not an error' \
  || bad 'a missing log dir is a no-op, not an error' 'zero' 'non-zero'
loop_prune_logs "" 2 \
  && ok 'an empty log dir argument is a no-op, not an error' \
  || bad 'an empty log dir argument is a no-op, not an error' 'zero' 'non-zero'
rm -rf "$PRUNE_DIR"

# ── loop_script_parses: a half-written script must never RUN ──────────────
# bash executes a script LINE BY LINE, so a syntax error near the end runs
# everything above it first: one round printed
# the ticket threshold and the review-only notice, then died on `syntax error
# near unexpected token 'done'`. The file was mid-edit — the drivers run the
# working tree, not a copy — and a partially executed pr-autoreview.sh can
# post a verdict with half its logic missing. So the check happens
# BEFORE the call, and a file that does not parse is not a failed round: it
# never ran. Only a tree that stays unparseable files an alert.
PARSE_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\nfor r in a b; do\n  echo "$r"\ndone\n' > "$PARSE_DIR/good.sh"
printf '#!/usr/bin/env bash\nfor r in a b\n  echo "$r"\ndone\n'     > "$PARSE_DIR/bad.sh"
printf '#!/usr/bin/env bash\ntouch %s/ran\n' "$PARSE_DIR"           > "$PARSE_DIR/side.sh"

loop_script_parses "$PARSE_DIR/good.sh" bash \
  && ok 'a script that parses is accepted' \
  || bad 'a script that parses is accepted' 'zero' 'non-zero'
loop_script_parses "$PARSE_DIR/bad.sh" bash 2>/dev/null \
  && bad 'a script with a syntax error is refused' 'non-zero' 'zero' \
  || ok 'a script with a syntax error is refused'
loop_script_parses "$PARSE_DIR/missing.sh" bash 2>/dev/null \
  && bad 'a missing script is refused' 'non-zero' 'zero' \
  || ok 'a missing script is refused'
loop_script_parses "" bash 2>/dev/null \
  && bad 'an empty script argument is refused' 'non-zero' 'zero' \
  || ok 'an empty script argument is refused'
# -n PARSES, it does not execute. If this ever regresses into actually running
# the file, the check would run a round of the gate on every round of the loop.
loop_script_parses "$PARSE_DIR/side.sh" bash >/dev/null 2>&1
[ -e "$PARSE_DIR/ran" ] \
  && bad 'checking a script does not execute it' 'no side effect' 'the script ran' \
  || ok 'checking a script does not execute it'
# bash -n writes the syntax error to stderr. The driver prints its own line to
# a 644 log, and a raw parse error can quote a line of the file with it.
is 'the check itself is quiet' \
   "$(loop_script_parses "$PARSE_DIR/bad.sh" bash 2>&1)" ''
rm -rf "$PARSE_DIR"

# ── loop_script_snapshot: the file must not change UNDER a running round ──
# The parse check above only guards the START of a round. bash reads a script
# by byte offset as it executes, so a file rewritten while the round is still
# running shifts everything underneath it: the round dies on a syntax error or
# an unbound variable that no version of the file ever had, the middle of one
# version read at the offsets of another.
# So the round runs a SNAPSHOT, and the editor can do what it likes to the
# tree.
SNAP_DIR="$(mktemp -d)"
mkdir -p "$SNAP_DIR/lib"
printf '#!/usr/bin/env bash\n. ./lib/x.sh\necho original\n' > "$SNAP_DIR/driven.sh"
SNAP="$(loop_script_snapshot "$SNAP_DIR/driven.sh")" || bad 'a snapshot is made' 'a path' 'nothing'
is "the snapshot sits beside the original (so its relative lib/ still resolves)" \
   "$(dirname "$SNAP")" "$SNAP_DIR"
is "the snapshot is a faithful copy" "$(cat "$SNAP")" "$(cat "$SNAP_DIR/driven.sh")"

# The assertion this whole function exists for.
printf '#!/usr/bin/env bash\necho REWRITTEN\nand more lines\nand more\n' > "$SNAP_DIR/driven.sh"
is "rewriting the original does not touch the running snapshot" \
   "$(grep -c original "$SNAP")" "1"

loop_script_snapshot "$SNAP_DIR/nope.sh" >/dev/null 2>&1 \
  && bad 'a missing script yields no snapshot' 'non-zero' 'zero' \
  || ok 'a missing script yields no snapshot'
loop_script_snapshot "" >/dev/null 2>&1 \
  && bad 'an empty argument yields no snapshot' 'non-zero' 'zero' \
  || ok 'an empty argument yields no snapshot'

# A round killed mid-flight (SIGTERM at the round timeout, a reboot) leaves its
# snapshot behind, in the repo directory. Nothing else would ever clean those.
touch -t 202001010000 "$SNAP_DIR/.prreview-run-driven.sh.OLD"
touch "$SNAP_DIR/.prreview-run-driven.sh.NEW"
loop_script_snapshot "$SNAP_DIR/driven.sh" >/dev/null
[ -e "$SNAP_DIR/.prreview-run-driven.sh.OLD" ] \
  && bad 'a stale snapshot is swept' 'gone' 'still there' \
  || ok 'a stale snapshot is swept'
[ -e "$SNAP_DIR/.prreview-run-driven.sh.NEW" ] \
  && ok 'a snapshot from a round still running is left alone' \
  || bad 'a snapshot from a round still running is left alone' 'still there' 'gone'
rm -rf "$SNAP_DIR"

# Ignored, because it lands in the repo directory: a stray copy of the gate
# that git offers to commit is one somebody eventually commits.
grep -q '^\.prreview-run-\*' .gitignore \
  && ok 'the snapshot pattern is gitignored' \
  || bad 'the snapshot pattern is gitignored' 'a rule in .gitignore' 'none'

# Every driver runs the WORKING TREE of this repo, not a copy, so every driver
# carries the same hazard.
ALL_DRIVERS="review-loop.sh"
for d in $ALL_DRIVERS; do
  SRC_D="$(grep -vE '^[[:space:]]*#' "$d")"
  has "$d copies and parse-checks in one step" 'loop_script_ready' "$SRC_D"
  # The halves must NOT be called by hand. loop_script_ready exists because the
  # order matters: a driver that parse-checks the tree and then copies it has
  # checked bytes that are not the ones it runs, and a truncation landing in
  # that window yields a copy that parses, runs half the script and exits 0.
  # Comment-stripped, because the comment
  # above the call site NAMES loop_script_snapshot to explain the sweep.
  case "$SRC_D" in
    *loop_script_parses*)   bad "$d calls loop_script_parses by hand" "only loop_script_ready" "split call" ;;
    *loop_script_snapshot*) bad "$d calls loop_script_snapshot by hand" "only loop_script_ready" "split call" ;;
    *) ok "$d does not split the copy and the check apart" ;;
  esac
  # Runs the COPY, not the tree. A driver that pays for the snapshot and then
  # still hands the tree path to bash has kept the whole defect. `has` on the
  # function name alone could not tell those two apart.
  has "$d hands the copy to bash, not the tree" '"$TIMEOUT_BIN" -k "$ROUND_KILL_AFTER" "$ROUND_TIMEOUT" "$BASH_BIN" "$RUN_SH"' "$SRC_D"
  has "$d removes its snapshot afterwards"      'rm -f "$RUN_SH"'      "$SRC_D"
  # The round timeout has to be able to END the round. Plain `timeout` sends
  # SIGTERM and then waits, and bash does not act on a signal until its
  # foreground child returns — so a round whose `git fetch` hangs on a dead
  # connection keeps running with the TERM still pending, and no later round
  # starts. --kill-after is what makes ROUND_TIMEOUT a deadline rather than a
  # request.
  has "$d gives its round timeout a kill-after" '"$TIMEOUT_BIN" -k "$ROUND_KILL_AFTER"' "$SRC_D"
done

# ── timeout knobs are whole seconds, at least 1 ──────────────────────────
for v in 1 60 08; do
  loop_require_seconds K "$v" >/dev/null && ok "loop_require_seconds takes $v" \
    || bad "loop_require_seconds takes $v" 'accepted' 'refused'
done
for v in 0 00 '' abc 3o -5 '1 2'; do
  OUT="$(loop_require_seconds PRREVIEW_X "$v" 2>&1)" && bad "loop_require_seconds refuses '$v'" 'refused' 'accepted' \
    || is "loop_require_seconds names the knob and the value for '$v'" "$OUT" \
      "PRREVIEW_X must be a whole number of seconds, at least 1; got: $v — refusing to run"
done
# The gate checks its own inline. The block is read out of the script and
# run, so what is tested is what ships.
knob_block() { # $1 = script: from the first check to the end of that block
  awk '/^(for KNOB in |if ! \[ "\$REVIEW_TIMEOUT" -ge 1 \])/{f=1} f{print} f&&/^(done|fi)$/{exit}' "$1"
}
KNOB_SPECS=('pr-autoreview.sh REVIEW_TIMEOUT PRREVIEW_GATE_REVIEW_TIMEOUT'
            'pr-autoreview.sh REPAIR_TIMEOUT PRREVIEW_GATE_REPAIR_TIMEOUT'
            'pr-autoreview.sh VERIFY_TIMEOUT PRREVIEW_GATE_VERIFY_TIMEOUT'
            'pr-autoreview.sh ROUND_BUDGET PRREVIEW_GATE_ROUND_BUDGET')
for spec in "${KNOB_SPECS[@]}"; do
  read -r f var knob <<<"$spec"
  BLOCK="$(knob_block "$f")"
  for v in 0 abc; do
    OUT="$(REVIEW_TIMEOUT=900 REPAIR_TIMEOUT=300 VERIFY_TIMEOUT=600 ROUND_BUDGET=900; eval "$var=\$v"; eval "$BLOCK" 2>&1; echo "went on")"; KRC=$?
    is "$f refuses $knob=$v" "$OUT" "$knob must be a whole number of seconds, at least 1; got: $v — refusing to run"
    is "$f exits 2 on $knob=$v" "$KRC" 2
  done
done
KNOB_FILES="pr-autoreview.sh"
for f in $KNOB_FILES; do
  # shellcheck disable=SC2034  # read by the eval'd block
  OUT="$(REVIEW_TIMEOUT=900 REPAIR_TIMEOUT=300 VERIFY_TIMEOUT=600 ROUND_BUDGET=900; eval "$(knob_block "$f")" 2>&1; echo "went on")"
  is "$f goes on with its defaults" "$OUT" 'went on'
done


# ── loop_script_ready itself, not just who calls it ──────────────────────
# The wiring checks above pass against a loop_script_ready that copies and
# never checks anything. What the drivers depend on is the CHECK, and that it
# happens on the copy: an unparseable script must come back non-zero with no
# copy left on disk, or the next round's sweep is the only thing that removes
# it and the caller has a path to a file it must not run.
READY_TMP="$(mktemp -d)" || bad "mktemp failed" "a temp dir" "nothing"
printf '%s\n' '#!/usr/bin/env bash' 'echo fine' > "$READY_TMP/good.sh"
printf '%s\n' '#!/usr/bin/env bash' 'if [ 1'    > "$READY_TMP/bad.sh"

READY_GOOD="$(loop_script_ready "$READY_TMP/good.sh" bash)"
READY_GOOD_RC=$?
is 'loop_script_ready returns 0 for a script that parses' "$READY_GOOD_RC" 0
[ -s "${READY_GOOD:-/nonexistent}" ] \
  && ok "loop_script_ready prints a usable copy" \
  || bad "loop_script_ready prints a usable copy" "a readable file" "$READY_GOOD"

READY_BAD="$(loop_script_ready "$READY_TMP/bad.sh" bash)"
READY_BAD_RC=$?
# 2, not 1: the drivers branch on the two apart to print "does not parse"
# versus "could not copy", and collapsing them makes a mid-edit tree read as a
# disk failure.
is 'loop_script_ready returns 2 for a script that does not parse' "$READY_BAD_RC" 2
is 'and prints nothing when it refuses'                          "$READY_BAD"    ''
is 'loop_script_ready returns 1 when there is nothing to copy' \
   "$(loop_script_ready "$READY_TMP/missing.sh" bash >/dev/null 2>&1; echo $?)" 1
# The refused copy must be GONE, not left for the two-hour sweep.
LEFT="$(find "$READY_TMP" -maxdepth 1 -name '.prreview-run-bad.sh.*' 2>/dev/null | wc -l | tr -d ' ')"
is 'a refused copy is removed, not left on disk' "$LEFT" 0
rm -rf "$READY_TMP"

# ── and --kill-after actually kills a child that will not take a hint ─────
# The wiring checks above would pass against a `timeout -k` that did nothing.
# A child with `trap "" TERM` is the shape that needs it: TERM arrives and
# is discarded, and only the follow-up KILL ends it.
KILL_START="$(date +%s)"
"$TIMEOUT_BIN" -k 1 1 bash -c 'trap "" TERM; sleep 60' >/dev/null 2>&1
KILL_RC=$?
KILL_ELAPSED=$(( $(date +%s) - KILL_START ))
# 30s, not 4s: what is being caught is "waits out the full 60", and a loaded
# box must not turn this into a flake.
[ "$KILL_ELAPSED" -lt 30 ] \
  && ok "timeout -k ends a child that ignores SIGTERM ($KILL_ELAPSED s)" \
  || bad "timeout -k ends a child that ignores SIGTERM" "under 30s" "${KILL_ELAPSED}s"
# The exit code, not just the clock. Elapsed time alone says ok when `timeout`
# is missing, does not understand -k, or exits early for some third reason —
# the run finishes fast and the assertion above cannot tell that apart from a
# working KILL. 137 = 128 + SIGKILL(9), which
# only the --kill-after path produces here: a plain TERM this child ignores.
is 'and it ends it with SIGKILL, which is what -k adds' "$KILL_RC" 137

# ── the drivers actually use it ───────────────────────────────────────────
# Without this, the function could be perfect and the drivers could still hold
# their own single-repo `gh pr list` — which is the bug this file guards.
COUNTING_DRIVERS="review-loop.sh"
for d in $COUNTING_DRIVERS; do
  has "$d sources lib/loop.sh"        'lib/loop.sh'         "$(cat "$d")"
  has "$d asks for the whole list"    'loop_open_pr_count'  "$(cat "$d")"
  has "$d sources lib/trust.sh"       'lib/trust.sh'        "$(cat "$d")"
  # The count reads the trust settings from the environment the round
  # inherits. A line that sets or clears them for the round alone would split
  # the two.
  is  "$d does not change the trust settings for the round" \
      "$(grep -cE 'env +-[iu]|unset +PRREVIEW_GATE_(TRUSTED_AUTHORS|FORK_PRS)|PRREVIEW_GATE_(TRUSTED_AUTHORS|FORK_PRS)=' "$d")" 0
  has "$d prunes its own log dir"     'loop_prune_logs'     "$(cat "$d")"
  # Matched on `pr list --repo` alone, NOT on a leading `gh`: the drivers
  # keep the binary in "$GH", so a pattern anchored on a literal lowercase
  # `gh` would miss `"$GH" pr list --repo "example-org/recipes"` — which is
  # exactly the line that would bring that bug back.
  if grep -q 'pr list --repo' "$d"; then
    bad "$d has no hand-rolled single-repo count" 'no direct pr list --repo' 'found one'
  else
    ok "$d has no hand-rolled single-repo count"
  fi
  # The driven script's exit code has to be looked at. Without it a round
  # that never ran reads exactly like a round that found nothing, and no
  # failure alert is ever filed.
  has "$d checks the driven script's exit code" 'rc=$?'          "$(cat "$d")"
  has "$d escalates a failed round"             '"$(loop_alert_script)"' "$(cat "$d")"
  is  "$d never runs the tree's owner-alert.sh directly (unreadable tree = no alert)" "$(grep -c '"$BASH_BIN" ./owner-alert.sh' "$d")" 0
  has "$d namespaces round logs per start"      'RUN_ID'         "$(cat "$d")"
  # A multibyte locale, not plain C: pr-autoreview.sh's `${var:0:n}` counts
  # characters only under one, and under C it cuts a multibyte finding
  # short, mid-character.
  has "$d runs the driven script in a UTF-8 locale" 'LC_ALL=C.UTF-8' "$(cat "$d")"
  # Anchored on the `env` line, not on the string anywhere: the comment right
  # above it quotes `LC_ALL=C` while explaining why plain C is wrong, and a
  # loose pattern would fail on the fix itself.
  if grep -qE '^[[:space:]]*env LC_ALL=C ' "$d"; then
    bad "$d does not force the byte-semantics C locale" 'C.UTF-8' 'plain C'
  else
    ok "$d does not force the byte-semantics C locale"
  fi
done



# ── loop_alert_script: the alert must not live in the tree it reports on ──
# A tree that becomes unreadable (macOS can revoke a folder's access, for
# one) stalls the driver, and the stall alert cannot run ./owner-alert.sh
# from that same tree: "Operation not permitted", and no issue is filed.
AT="$(mktemp -d)"
printf '#!/bin/sh\n' > "$AT/copy.sh"
is 'alert script: the tree copy when it is readable' "$(cd "$AT" && printf '#!/bin/sh\n' > owner-alert.sh && PRREVIEW_ALERT_BIN="$AT/copy.sh" loop_alert_script)" './owner-alert.sh'
is 'alert script: the copy kept outside the tree when the tree has none (or cannot be read)' "$(cd "$AT" && rm -f owner-alert.sh && PRREVIEW_ALERT_BIN="$AT/copy.sh" loop_alert_script)" "$AT/copy.sh"
is 'alert script: with no copy named, the tree path' "$(cd "$AT" && unset PRREVIEW_ALERT_BIN && HOME=/h loop_alert_script)" './owner-alert.sh'
rm -rf "$AT"

# ── loop_ready_should_alert: an unparseable tree must not be silent ──────
#
# loop_script_ready failing prints a line and `continue`s. Nothing exits
# non-zero, so owner-alert.sh is never reached, so a tree left broken is a
# driver that quietly stops working for as long as nobody reads the log.
# This is the decision that ends the silence.
for N in 0 1 4; do
  loop_ready_should_alert "$N" 5 \
    && bad "no alert at $N consecutive failures (limit 5)" 'rc 1' 'rc 0' \
    || ok "no alert at $N consecutive failures (limit 5)"
done
loop_ready_should_alert 5 5 \
  && ok 'the limit round itself alerts' \
  || bad 'the limit round itself alerts' 'rc 0' "rc $?"
# Between multiples it stays quiet, or a broken tree means a gh call a minute.
for N in 6 9; do
  loop_ready_should_alert "$N" 5 \
    && bad "a round between multiples stays quiet ($N)" 'rc 1' 'rc 0' \
    || ok "a round between multiples stays quiet ($N)"
done
# ...and it comes back, because `-eq` alone announces an outage once and then
# stays silent through the rest of it — including after the operator closes
# the issue.
loop_ready_should_alert 10 5 \
  && ok 'a later multiple alerts again, so closing the issue re-arms' \
  || bad 'a later multiple alerts again, so closing the issue re-arms' 'rc 0' "rc $?"
# A limit of 0 would mean "alert on round 0", i.e. before anything failed, and
# the modulo would divide by zero.
#
# The OUTPUT is what this has to pin, not the return code. Without the guard
# `5 % 0` raises bash's own arithmetic error, and THAT returns non-zero too —
# so a code-only assertion is green with the guard and green without it, and
# pins nothing at all. What the guard actually buys is not printing
# "division by 0" into a driver's log once a round for as long as the value
# stays wrong.
ZL_OUT="$(loop_ready_should_alert 5 0 2>&1)"; ZL_RC=$?
is 'a limit of 0 never alerts' "$ZL_RC" 1
is 'a limit of 0 says nothing rather than printing an arithmetic error' "$ZL_OUT" ''
loop_ready_should_alert x 5 \
  && bad 'a non-numeric count never alerts' 'rc 1' 'rc 0' \
  || ok 'a non-numeric count never alerts'


# ── gate.log summary takes only the gate's own lines ─────────────────────
# The round log also holds review bodies the sensitive scan withheld; gate.log
# is 644. The kept lines are the REAL echo strings, read out of the scripts,
# in the shape the round log holds them: a PR job's behind the dispatcher's
# `[repo#N] ` prefix, the dispatcher's and the round-level refusals bare.
src_echo() { # $1 = file, $2 = a fixed piece of one echo line -> what it prints
  grep -F -- "$2" "$1" | sed -nE 's/.*echo "([^"]*)".*/\1/p' | head -1 \
    | sed -e 's/\$PR/12/g' -e 's/\$GATE_DEGRADED/2/g' -e 's|\$REPO|example-org/recipes|g'
}
grep -qF 'review_job "$PR" "$WT_DIR" 2>&1 | sed -u "s|^|[$REPO_KEY#$PR] |"' pr-autoreview.sh \
  && ok 'PR jobs still print behind a [repo#N] prefix' \
  || bad 'PR jobs still print behind a [repo#N] prefix' 'the sed -u prefix in pr-autoreview.sh' 'changed'
JOB='[recipes#12] '
KEEP_VERDICT="$JOB$(src_echo pr-autoreview.sh 'review-only verdict comment FAILED to post')"$'\n'"$JOB$(src_echo pr-autoreview.sh 'non-conventional title — reminder posted')"$'\n'"$(src_echo pr-autoreview.sh 'round budget spent')"
KEEP_VERDICT="$KEEP_VERDICT"$'\n'"$JOB$(src_echo pr-autoreview.sh 'review-only verdict comment posted')"
KEEP_VERDICT="$KEEP_VERDICT"$'\n'"$JOB$(src_echo pr-autoreview.sh 'split requested, not reviewed')"
KEEP_VERDICT="$KEEP_VERDICT"$'\n'"$JOB$(src_echo pr-autoreview.sh 're-posting the verdict an earlier round')"
KEEP_REFUSAL="$JOB$(src_echo pr-autoreview.sh 'refusing to review — a symlink is in the tree the failed apply left behind')
$(src_echo pr-autoreview.sh 'could not create the review worktree — skipping')
$(src_echo pr-autoreview.sh 'timeout(1) missing')
$(src_echo pr-autoreview.sh 'item(s) — repo(s), review job(s)')
$(src_echo pr-autoreview.sh 'could not read the default branch')
$(src_echo pr-autoreview.sh 'model call(s) hit rate/usage limits')
$(src_echo pr-autoreview.sh 'review job(s) died outside')
$JOB$(src_echo pr-autoreview.sh 'convergence cap did not run')
$JOB$(src_echo pr-autoreview.sh 'not acting on it (a repair may block')"
# A withheld body goes to the round log through the real print_withheld,
# then behind the same job prefix, and carries every shape the anchor keys on.
eval "$(awk '/^print_withheld\(\)/ { f = 1 } f { print } f && /^}/ { exit }' pr-autoreview.sh)"
declare -F print_withheld >/dev/null && ok 'pr-autoreview.sh defines print_withheld' \
  || bad 'pr-autoreview.sh defines print_withheld' 'a function' 'absent'
BODY_LINES='PR #12: could not read checks — skipping (fail closed)
example-org/recipes: could not read the default branch
WARNING: verdict comment posted by the body
NOTICE: 3 PR(s) skipped
2 item(s) — could not be evaluated
x — refusing to run'
GL="$(mktemp "${TMPDIR:-/tmp}/prreview-gateline-XXXX")"
# One sample per summary: each tail has a cap, and a sample pushed out by the
# others would read as a dropped shape.
while IFS= read -r l; do
  [ -n "${l#"$JOB"}" ] || { bad 'a kept sample was read out of the scripts' 'an echo string' "'$l'"; continue; }
  printf '%s\n' "$l" > "$GL"
  has "gate line kept: ${l:0:50}" "$l" "$(loop_gate_summary "$GL")"
done <<<"$KEEP_VERDICT
$KEEP_REFUSAL"
# A handled head prints its status EVERY round; kept, a PR left waiting
# would push every verdict out of the tail.
ROUND_STATUS="$JOB$(src_echo pr-autoreview.sh 'already handled — nothing to do until it changes (review-only')"
while IFS= read -r l; do
  [ -n "${l#"$JOB"}" ] || { bad 'a status sample was read out of the scripts' 'an echo string' "'$l'"; continue; }
  printf '%s\n' "$l" > "$GL"
  is "per-round status not kept: ${l:0:50}" "$(loop_gate_summary "$GL")" ''
done <<<"$ROUND_STATUS"
print_withheld "$BODY_LINES" | sed "s|^|$JOB|" > "$GL"
SUMMARY="$(loop_gate_summary "$GL")"
while IFS= read -r l; do
  case "$SUMMARY" in
    *"$l"*) bad "withheld body line dropped: $l" 'absent' 'in gate.log' ;;
    *) ok "withheld body line dropped: ${l:0:40}" ;;
  esac
done <<<"$BODY_LINES"
# A PR's refusals and the round's own refusals have separate tails: a round
# that piles up round-level NOTICEs still names the PR that was skipped, and
# a round with many skipped PRs still shows the round-level cause. The line
# that must survive is written FIRST each time, so any tail that also holds
# the other kind drops it.
PR_REFUSAL="$JOB$(src_echo pr-autoreview.sh 'refusing to review — a symlink is in the tree the failed apply left behind')"
ROUND_NOTICES="$(src_echo pr-autoreview.sh 'model call(s) hit rate/usage limits')
$(src_echo pr-autoreview.sh 'review job(s) died outside')
$(src_echo pr-autoreview.sh 'item(s) — repo(s), review job(s)')
$(src_echo pr-autoreview.sh 'timeout(1) missing')
$(src_echo pr-autoreview.sh 'could not read the default branch')"
printf '%s\n%s\n' "$PR_REFUSAL" "$ROUND_NOTICES" > "$GL"
has 'five round-level refusals do not push out the PR that was skipped' "$PR_REFUSAL" "$(loop_gate_summary "$GL")"
{ head -1 <<<"$ROUND_NOTICES"
  for n in 1 2 3 4 5; do printf '%s\n' "${PR_REFUSAL//#12]/#1$n]}"; done; } > "$GL"
has 'five skipped PRs do not push out the round-level cause' "$(head -1 <<<"$ROUND_NOTICES")" "$(loop_gate_summary "$GL")"
# The dispatcher prints a PR's skip itself, before any job exists, so that
# line has no [repo#N] prefix and still belongs with the PR refusals.
DISPATCH_SKIP="$(src_echo pr-autoreview.sh 'could not create the review worktree — skipping')"
printf '%s\n%s\n' "$DISPATCH_SKIP" "$ROUND_NOTICES" > "$GL"
has 'five round-level refusals do not push out a skip the dispatcher printed' "$DISPATCH_SKIP" "$(loop_gate_summary "$GL")"
{ head -1 <<<"$ROUND_NOTICES"
  for n in 1 2 3 4 5; do printf '%s\n' "${DISPATCH_SKIP/#PR #12/PR #1$n}"; done; } > "$GL"
has 'five dispatcher skips do not push out the round-level cause' "$(head -1 <<<"$ROUND_NOTICES")" "$(loop_gate_summary "$GL")"
printf '' > "$GL"
is 'a round with nothing to report adds nothing to gate.log' "$(loop_gate_summary "$GL")" ''
rm -f "$GL"
# Every withheld body goes through print_withheld, or one of them could.
N_FOLLOWS="$(grep -c 'withheld body follows:"$' pr-autoreview.sh)"
N_PRINTED="$(awk '/withheld body follows:"$/ { getline n; if (n ~ /^[[:space:]]*print_withheld "\$[A-Z_]+"$/) c++ } END { print c + 0 }' pr-autoreview.sh)"
is "every 'withheld body follows' line is followed by print_withheld ($N_FOLLOWS)" "$N_PRINTED" "$N_FOLLOWS"
# Model output is the same kind of text: its head goes through print_withheld.
is 'every model-output head is printed through print_withheld' \
   "$(grep -F '%.400s' pr-autoreview.sh | grep -vc 'print_withheld "$(printf '"'"'%.400s'"'"' "$[A-Z_]*")"')" 0
# A model-written field inside a gate line is flattened to one line: a newline
# in it would start a line of its own that the summary copies as a verdict.
eval "$(awk '/^one_line\(\)/ { f = 1 } f { print } f && /^}/ { exit }' pr-autoreview.sh)"
FORGED=$'x.sh:1\nPR #12: verdict comment posted \xe2\x80\x94 approve\r\n'
is 'one_line flattens CR and LF to spaces' "$(one_line "$FORGED")" \
   'x.sh:1 PR #12: verdict comment posted — approve  '
is 'one_line prints exactly one line' "$(one_line "$FORGED" | wc -l | tr -d ' ')" 1
# Longer model text (a finding, a refutation, a ruling, a reason) never shares
# a line with the gate's own words, and the label built from a finding's file
# and line is flattened where it is built.
is 'no echo prints a finding, a refutation, a ruling or a reason' \
   "$(grep -cE '^[[:space:]]*echo .*([VA]_REASON|_ISSUE\[|jq -r .\.reason)' pr-autoreview.sh)" 0
is 'the verdict is flattened where it is read, in both places it comes from' \
   "$(grep -E '(^|[^A-Z_])VERDICT="\$\(' pr-autoreview.sh | grep -vc 'VERDICT="$(one_line "$(jq -r '"'"'.verdict'"'"' <<<"')" 0
is 'every finding label is flattened where it is built' \
   "$(grep -cE '^[[:space:]]*[A-Z_]*_LABEL="\$\(jq' pr-autoreview.sh)" 0
# A file list that would not read ends the evaluation for this round;
# note_skip counts it, so the round exits 1 and a repeat files an alert. Kept
# as a tripwire, even where no such skip exists yet.
is 'every "could not read the file list" skip goes through note_skip' \
   "$(grep -F 'could not read the file list' pr-autoreview.sh | grep -vc '^[[:space:]]*note_skip "')" 0

[ "$FAILED" -eq 0 ] && echo "PASS: lib/loop.sh" || echo "FAIL: lib/loop.sh"
exit "$FAILED"
