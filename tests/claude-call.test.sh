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

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
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
# $1 = tools, the rest = allowed rules. The prompt goes on stdin, as at
# every call site.
run_call() {
  : > "$STUB/argv"; : > "$STUB/env"; : > "$STUB/stdin"
  printf '%s\n' "$PROMPT_MARK" \
    | env CLAUDE_BIN="$STUB/claude" STUB_DIR="$STUB" \
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
REPO_DIR=/srv/example/work/repo
DIFF=/srv/example/work/scratch/prreview-diff
run_call "$CLAUDE_READ_TOOLS" "Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$DIFF)"
ARGV="$(cat "$STUB/argv")"; ENVD="$(cat "$STUB/env")"
is  'the read tool set is Read, Grep and Glob' "$CLAUDE_READ_TOOLS" 'Read,Grep,Glob'
has 'read call: --tools names only Read, Grep and Glob' '[--tools][Read,Grep,Glob]' "$ARGV"
has 'read call: the path-scoped rules reach --allowedTools, in order' \
    "[--allowedTools][Read(//srv/example/work/repo/**)][Grep(//srv/example/work/repo/**)][Glob(//srv/example/work/repo/**)][Read(//srv/example/work/scratch/prreview-diff)][--output-format]" "$ARGV"
common_flags 'read call' "$ARGV"
common_env 'read call' "$ENVD"
is  'read call: the prompt arrives on stdin' "$(cat "$STUB/stdin")" "$PROMPT_MARK"
is  'read call: the answer goes to stdout' "$(cat "$STUB/out")" '{"type":"result","result":"stub answer"}'

# ── the repair call: no tool at all ──────────────────────────────────────
# `claude --help` (2.1.305): Use "" to disable all tools. The rule that
# matches no file stays, so --allowedTools is never left without a value.
run_call "" "Read(/nonexistent-repair-scope/**)"
ARGV="$(cat "$STUB/argv")"; ENVD="$(cat "$STUB/env")"
has 'repair call: --tools is empty' '[--tools][]' "$ARGV"
lacks 'repair call: no Read, Grep or Glob tool' '[--tools][Read' "$ARGV"
common_flags 'repair call' "$ARGV"
common_env 'repair call' "$ENVD"
is  'repair call: the prompt arrives on stdin' "$(cat "$STUB/stdin")" "$PROMPT_MARK"

# ── the call sites in pr-autoreview.sh ───────────────────────────────────
# The flow is not unit-callable, so these are text pins. Comment lines do
# not count.
SITES="$(grep -E '^[^#]*claude_call ' pr-autoreview.sh)"
is  'pr-autoreview.sh has four model calls, all through claude_call' "$(printf '%s\n' "$SITES" | grep -c 'claude_call ')" 4
is  'review: reads with the read tool set' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$REVIEW_TIMEOUT" "$REVIEW_MODEL" "$CLAUDE_READ_TOOLS" "${ALLOWED[@]}"')" 1
is  'verify and red team: read with the read tool set, scoped to the clone and the diff' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$VERIFY_TIMEOUT" "$REVIEW_MODEL" "$CLAUDE_READ_TOOLS" "Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$DIFF)"')" 2
is  'repair: no tool, and a rule that matches no file' \
    "$(printf '%s\n' "$SITES" | grep -cF 'claude_call "$REPAIR_TIMEOUT" "$CHEAP_MODEL" "" "Read(/nonexistent-repair-scope/**)"')" 1
is  'the review rules are the clone, the slice diff and the intent file' \
    "$(grep -cF 'ALLOWED=("Read(/$REPO_DIR/**)" "Grep(/$REPO_DIR/**)" "Glob(/$REPO_DIR/**)" "Read(/$SLICE_DIFF)")' pr-autoreview.sh)" 1
is  'no model prompt goes in argv (-p "$(...)")' "$(grep -cE '^[[:space:]]*-p "\$\(' pr-autoreview.sh)" 0

if [ "$FAILED" -eq 0 ]; then echo "PASS: claude call"; else echo "FAIL: claude call"; exit 1; fi
