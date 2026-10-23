#!/usr/bin/env bash
# Every model call goes through claude_call (lib/claude-call.sh). This test
# runs the real helper against a stub `claude` that records its argv, its
# environment and its stdin. Then it pins the four call sites in
# pr-autoreview.sh to the helper.
#
# A missing flag fails silently in production: the call still answers, and
# only the tool set the model gets is wider.
#
# Run: bash tests/claude-call.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "expected to contain '$2', got: $3";; esac; }
lacks() { case "$3" in *"$2"*) bad "$1" "must not contain '$2', got: $3";; *) ok "$1";; esac; }
for h in ok bad is has lacks; do command -v "$h" >/dev/null 2>&1 || { echo "  FAIL helper $h is not defined"; FAILED=1; }; done

. lib/claude-call.sh || { echo "  FAIL lib/claude-call.sh missing or broken"; echo "FAIL: claude call"; exit 1; }
. lib/tools.sh || { echo "FAIL: cannot source lib/tools.sh"; exit 1; }
# macOS without the coreutils gnubin directory has gtimeout and no timeout.
# Find the commands the way the scripts do.
tools_resolve || { echo "FAIL: no timeout command or no SHA-256 command on PATH"; exit 1; }

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
# The stub below records what reaches `claude`. This test checks which flags
# and which environment variables the helper passes. It does not check how
# Claude Code enforces them.
cat > "$STUB/claude" <<'STUB_EOF'
#!/usr/bin/env bash
# One bracketed field per argument, so an empty argument stays visible.
printf '[%s]' "$@" > "$STUB_DIR/argv"
for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
         ANTHROPIC_API_KEY HTTPS_PROXY CLAUDE_CONFIG_DIR \
         CLAUDE_CODE_DISABLE_AUTO_MEMORY ENABLE_CLAUDEAI_MCP_SERVERS; do
  printf '%s=%s\n' "$v" "${!v:-<empty-or-unset>}"
done > "$STUB_DIR/env"
cat > "$STUB_DIR/stdin"
printf '{"type":"result","result":"stub answer"}\n'
STUB_EOF
chmod +x "$STUB/claude"

PROMPT_MARK="prompt-marker-4f1c review this diff"
# $1 = tools, then the read dirs, then --, then the allowed rules. The
# prompt goes on stdin, as at every call site.
run_call() {
  : > "$STUB/argv"; : > "$STUB/env"; : > "$STUB/stdin"
  printf '%s\n' "$PROMPT_MARK" \
    | env CLAUDE_BIN="$STUB/claude" STUB_DIR="$STUB" TIMEOUT_BIN="$TIMEOUT_BIN" \
        GH_TOKEN=gh-test-value GITHUB_TOKEN=gh-test-value \
        GH_ENTERPRISE_TOKEN=gh-test-value GITHUB_ENTERPRISE_TOKEN=gh-test-value \
        ANTHROPIC_API_KEY=api-test-value HTTPS_PROXY=http://192.0.2.10:3128 \
        CLAUDE_CONFIG_DIR=/srv/example/claude-config \
        bash -c '. lib/claude-call.sh && claude_call 60 test-model "$@"' _ "$@" \
        > "$STUB/out"
}

# The flags that every call gets, the repair call too. `--tools ""` alone
# leaves MCP servers and skills in place, so the MCP and slash flags are on
# every call.
common_flags() { # $1 = label, $2 = argv
  has "$1: --setting-sources is empty"          '[--setting-sources][]' "$2"
  has "$1: --strict-mcp-config"                 '[--strict-mcp-config]' "$2"
  has "$1: --disallowedTools mcp__*"            '[--disallowedTools][mcp__*]' "$2"
  has "$1: --disable-slash-commands"            '[--disable-slash-commands]' "$2"
  has "$1: the model is pinned"                 '[--model][test-model]' "$2"
  has "$1: JSON output"                         '[--output-format][json]' "$2"
  has "$1: -p is followed by a flag, not by a prompt" '[-p][--model]' "$2"
  # --restricted confines the file tools to the cwd and the --add-dir dirs.
  # The path rules alone do not stop a rule that is wider than it looks.
  has "$1: --restricted"                        '[--restricted]' "$2"
  lacks "$1: no prompt text in argv"            'prompt-marker-4f1c' "$2"
}
common_env() { # $1 = label, $2 = env dump
  local v
  for v in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
    has "$1: $v is cleared for the child" "$v=<empty-or-unset>" "$2"
  done
  has "$1: auto memory is off"                  'CLAUDE_CODE_DISABLE_AUTO_MEMORY=1' "$2"
  has "$1: claude.ai MCP servers are off"       'ENABLE_CLAUDEAI_MCP_SERVERS=false' "$2"
  # No env -i: API-key, proxy and config-dir users need these.
  has "$1: ANTHROPIC_API_KEY is kept"           'ANTHROPIC_API_KEY=api-test-value' "$2"
  has "$1: the proxy setting is kept"           'HTTPS_PROXY=http://192.0.2.10:3128' "$2"
  has "$1: CLAUDE_CONFIG_DIR is kept"           'CLAUDE_CONFIG_DIR=/srv/example/claude-config' "$2"
}

# ── a call that reads: review, verify, red team ──────────────────────────
# The review shape: two private read dirs, one for the slice diff and one for
# the intent file.
REPO_DIR=/srv/example/work/repo
SLICE_READ=/srv/example/work/scratch/prreview-slice-ab12/slice-1
INTENT_DIR=/srv/example/work/scratch/prreview-pr-intent-cd34ef
SLICE_VIEW="$SLICE_READ/diff.numbered"
run_call "$CLAUDE_READ_TOOLS" "$SLICE_READ" "$INTENT_DIR" -- "Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$SLICE_VIEW)"
ARGV="$(cat "$STUB/argv")"; ENVD="$(cat "$STUB/env")"
is  'the read tool set is Read, Grep and Glob' "$CLAUDE_READ_TOOLS" 'Read,Grep,Glob'
has 'read call: --tools names only Read, Grep and Glob' '[--tools][Read,Grep,Glob]' "$ARGV"
has 'read call: --add-dir carries exactly the given dirs, in order' \
    "[--add-dir][$SLICE_READ][$INTENT_DIR][--allowedTools]" "$ARGV"
is  'read call: one --add-dir flag' "$(grep -o '\[--add-dir\]' <<<"$ARGV" | grep -c .)" 1
lacks 'read call: the -- separator does not reach the CLI' '[--]' "$ARGV"
has 'read call: the path-scoped rules reach --allowedTools, in order' \
    "[--allowedTools][Read(//srv/example/work/repo/**)][Grep(//srv/example/work/repo/**)][Glob(//srv/example/work/repo/**)][Read(/$SLICE_VIEW)][--output-format]" "$ARGV"
common_flags 'read call' "$ARGV"
common_env 'read call' "$ENVD"
is  'read call: the prompt arrives on stdin' "$(cat "$STUB/stdin")" "$PROMPT_MARK"
is  'read call: the answer goes to stdout' "$(cat "$STUB/out")" '{"type":"result","result":"stub answer"}'

# The verify and red-team shape: one read dir that holds the PR's diff.
DIFF_DIR=/srv/example/work/scratch/prreview-pr-diff-gh56ij
run_call "$CLAUDE_READ_TOOLS" "$DIFF_DIR" -- "Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$DIFF_DIR/pr.diff)"
ARGV="$(cat "$STUB/argv")"
has 'one-dir call: --add-dir carries exactly the diff dir' "[--add-dir][$DIFF_DIR][--allowedTools]" "$ARGV"
common_flags 'one-dir call' "$ARGV"

# A call site without the -- separator is refused before claude starts.
# Without the check, its rules would become read dirs and the reverse.
run_call "$CLAUDE_READ_TOOLS" "Read(/$REPO_DIR/**)" 2>"$STUB/err"; RC=$?
is  'no --: the call fails' "$([ "$RC" -ne 0 ] && echo failed || echo ran)" failed
has 'no --: the error names the missing --' 'no -- before' "$(cat "$STUB/err")"
is  'no --: claude does not start' "$(cat "$STUB/argv")" ''

# ── the repair call: no tool at all ──────────────────────────────────────
# `claude --help` (2.1.305): Use "" to disable all tools. The rule that
# matches no file stays, so --allowedTools is never left without a value.
run_call "" -- "Read(/nonexistent-repair-scope/**)"
ARGV="$(cat "$STUB/argv")"; ENVD="$(cat "$STUB/env")"
has 'repair call: --tools is empty' '[--tools][]' "$ARGV"
lacks 'repair call: no Read, Grep or Glob tool' '[--tools][Read' "$ARGV"
lacks 'repair call: no --add-dir' '[--add-dir]' "$ARGV"
common_flags 'repair call' "$ARGV"
common_env 'repair call' "$ENVD"
is  'repair call: the prompt arrives on stdin' "$(cat "$STUB/stdin")" "$PROMPT_MARK"

# ── the call sites in pr-autoreview.sh ───────────────────────────────────
# The flow is not unit-callable, so these are text pins. Comment lines do
# not count.
SITES="$(grep -E '^[^#]*claude_call ' pr-autoreview.sh)"
is  'pr-autoreview.sh has four model calls, all through claude_call' "$(printf '%s\n' "$SITES" | grep -c 'claude_call ')" 4
is  'review: reads with the read tool set, in the slice dir and the intent dir' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$REVIEW_TIMEOUT" "$REVIEW_MODEL" "$CLAUDE_READ_TOOLS" "${READ_DIRS[@]}" -- "${ALLOWED[@]}"')" 1
is  'verify and red team: read with the read tool set, scoped to the clone and the display copy of the diff' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$VERIFY_TIMEOUT" "$REVIEW_MODEL" "$CLAUDE_READ_TOOLS" "${DIFF_VIEW%/*}" -- "Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$DIFF_VIEW)"')" 2
lacks 'no model call can read the raw diff' 'Read(/$DIFF)' "$SITES"
lacks 'no model call is given the raw diff dir' '"$DIFF_DIR"' "$SITES"
is  'repair: no tool, no read dir, and a rule that matches no file' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$REPAIR_TIMEOUT" "$CHEAP_MODEL" "" -- "Read(/nonexistent-repair-scope/**)"')" 1
# The grouping call sits in lib/regroup.sh, in the same shape as the repair.
CL_SITES="$(grep -E '^[^#]*claude_call ' lib/regroup.sh)"
is  'grouping: lib/regroup.sh has one model call, through claude_call' "$(printf '%s\n' "$CL_SITES" | grep -c 'claude_call ')" 1
is  'grouping: the cheap model, no tool, no read dir, and a rule that matches no file' \
    "$(printf '%s\n' "$CL_SITES" | grep -cF 'claude_call "$REPAIR_TIMEOUT" "$CHEAP_MODEL" "" -- "Read(/nonexistent-repair-scope/**)"')" 1
is  'the review rules are the clone, the slice display copy and the intent file' \
    "$(grep -cF 'ALLOWED=("Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$SLICE_VIEW)")' pr-autoreview.sh)" 1
# A read dir must hold only the files of one call. $GATE_SCRATCH holds every
# PR's files, and $SLICE_DIR holds the parts of every slice.
is  'review: the slice read dir is the dir of this slice display copy' \
    "$(grep -cF 'READ_DIRS=("${SLICE_VIEW%/*}")' pr-autoreview.sh)" 1
is  'review: the intent dir is the other read dir' \
    "$(grep -cF '[ -n "$INTENT_FILE" ] && READ_DIRS+=("$INTENT_DIR")' pr-autoreview.sh)" 1
is  'each slice diff is alone in its own dir under SLICE_DIR' \
    "$(grep -cF 'SD="$SLICE_DIR/slice-$s/diff"' pr-autoreview.sh)" 1
is  'the PR diff is alone in its own dir' "$(grep -cF 'DIFF="$DIFF_DIR/pr.diff"' pr-autoreview.sh)" 1
# The display copies (lib/diffview.sh) are what the model reads. Each one is
# alone in its own dir under VIEW_ROOT: "full" for the whole diff, one dir per
# slice. diffview_make creates the dir and writes the only file in it.
is  'the display copy of the whole diff is alone in its own dir' \
    "$(grep -cF 'diffview_make "$DIFF" "$VIEW_ROOT" full' pr-autoreview.sh)" 1
is  'the display copy of each slice is alone in its own dir' \
    "$(grep -cF 'diffview_make "${SLICE_DIFFS[$SI]}" "$VIEW_ROOT" "slice-$SI"' pr-autoreview.sh)" 1
is  'an unsliced review shares the display copy of the whole diff' \
    "$(grep -cF 'SLICE_VIEWS+=("$DIFF_VIEW")' pr-autoreview.sh)" 1
is  'a display copy that cannot be made falls back to the raw diff and logs a WARNING' \
    "$(grep -cF 'WARNING: could not make the numbered copy of' pr-autoreview.sh)" 2
is  'the display copy root is removed when the job ends' \
    "$(grep -cF '[ -n "${VIEW_ROOT:-}" ] && rm -rf "$VIEW_ROOT"' pr-autoreview.sh)" 1
# The raw diff keeps every consumer that parses patch syntax.
RAW_USES="$(grep -E '^[^#]*(chunk_split|symbols_scan|pr_diff_pinned|diff_changed_files|git .*apply)' pr-autoreview.sh)"
has 'chunk_split reads the raw diff' 'chunk_split "$DIFF"' "$RAW_USES"
has 'symbols_scan reads the raw diff' 'symbols_scan "$REPO_DIR" "$DIFF"' "$RAW_USES"
lacks 'no patch parser reads a display copy' 'DIFF_VIEW' "$RAW_USES"
lacks 'no patch parser reads a slice display copy' 'SLICE_VIEW' "$RAW_USES"
is  'the intent file is alone in its own dir' "$(grep -cF 'INTENT_FILE="$INTENT_DIR/intent.txt"' pr-autoreview.sh)" 1
DIR_LINES="$(printf '%s\n' "$SITES"; grep -E '^[^#]*READ_DIRS(\+)?=' pr-autoreview.sh)"
lacks 'no read dir is $VIEW_ROOT' '"$VIEW_ROOT"' "$DIR_LINES"
lacks 'no read dir is $GATE_SCRATCH' '$GATE_SCRATCH' "$DIR_LINES"
lacks 'no read dir is $SLICE_DIR' '"$SLICE_DIR"' "$DIR_LINES"
is  'no model prompt goes in argv (-p "$(...)")' "$(grep -cE '^[[:space:]]*-p "\$\(' pr-autoreview.sh)" 0

if [ "$FAILED" -eq 0 ]; then echo "PASS: claude call"; else echo "FAIL: claude call"; exit 1; fi
