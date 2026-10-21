#!/usr/bin/env bash
# The one way this repo starts a model call (claude_call), and the check that
# the installed Claude Code is new enough for it (claude_version_check).
# Sourced by pr-autoreview.sh and prreview.
#
# Each flag removes something that a prompt-injected diff could use:
#   --tools            sets which built-in tools exist. --allowedTools only
#                      decides which tools run without a prompt. Without
#                      --tools, the CLI defaults include Bash, and Claude Code
#                      runs read-only shell commands with no allow rule.
#   --strict-mcp-config, --disallowedTools "mcp__*"
#                      start no MCP server from the operator's own config, and
#                      deny an MCP tool that gets through. `--tools ""` alone
#                      does not remove MCP tools, so every call gets these.
#   --disable-slash-commands
#                      loads no skill and no command from the reviewed repo.
#   --setting-sources ""
#                      loads no settings file. A rule in ~/.claude/settings.json
#                      (or defaultMode bypassPermissions) cannot widen the
#                      --allowedTools rules. Auth, model and tools stay as set.
#   --restricted, --add-dir DIR...
#                      confine the file tools to the cwd (the review clone)
#                      and the --add-dir dirs. This holds even when a path
#                      rule is wider than it looks. Each DIR is made for one
#                      call or one slice and holds only the files it must
#                      read, so a call cannot read another PR's or another
#                      slice's files. Never add $GATE_SCRATCH itself.
# Not CLAUDE_CONFIG_DIR: the login lives under that directory. A gate-owned
# path there made every call answer "Not logged in · Please run /login".
#
# The prompt comes on stdin. In argv, other local users can read it in the
# process list, and Linux refuses one argument over 128 KiB.
#
# The GitHub token variables are cleared for the child. This is defense in
# depth only: the model has no shell, so it cannot read its environment.
# The rest of the environment stays. Proxy, Bedrock, Vertex and
# CLAUDE_CONFIG_DIR users need it.

# 2.1.295 applies --tools to tools that register after launch. 2.1.304 fails
# every request on Vertex, Bedrock and gateways when --tools leaves out
# ToolSearch, and 2.1.305 fixes that. These tool sets have no ToolSearch.
CLAUDE_MIN_VERSION="2.1.305"
# The tools of a call that reads the review clone.
# shellcheck disable=SC2034  # read by pr-autoreview.sh
CLAUDE_READ_TOOLS="Read,Grep,Glob"
# Seconds for `claude --version`. It makes no API call.
CLAUDE_VERSION_TIMEOUT=20

# claude_call SECONDS MODEL TOOLS [DIR...] -- RULE...
# TOOLS is "$CLAUDE_READ_TOOLS", or "" for no tool. Each DIR is one --add-dir
# entry, and a call with no tool gives none. Each RULE is one --allowedTools
# entry, and a call gives at least one. The prompt is read from stdin, and the
# JSON answer goes to stdout.
# The -- is required. Without it, a call site from before DIR existed would
# send its rules as dirs, so the call fails before claude starts.
claude_call() {
  local secs="$1" model="$2" tools="$3" dirs=()
  shift 3
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do dirs+=("$1"); shift; done
  if [ "$#" -eq 0 ]; then
    echo "claude_call: no -- before the --allowedTools rules" >&2
    return 2
  fi
  shift
  # One --add-dir flag takes all dirs. It is left out when there is no dir.
  [ "${#dirs[@]}" -gt 0 ] && dirs=(--add-dir "${dirs[@]}")
  GH_TOKEN='' GITHUB_TOKEN='' GH_ENTERPRISE_TOKEN='' GITHUB_ENTERPRISE_TOKEN='' \
  CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 ENABLE_CLAUDEAI_MCP_SERVERS=false \
    timeout "$secs" "$CLAUDE_BIN" -p --model "$model" --setting-sources "" \
      --tools "$tools" --strict-mcp-config --disallowedTools "mcp__*" \
      --disable-slash-commands --restricted ${dirs[@]+"${dirs[@]}"} \
      --allowedTools "$@" --output-format json
}

# claude_version_ok TEXT: 0 when TEXT, the output of `claude --version` such
# as "2.1.305 (Claude Code)", starts with CLAUDE_MIN_VERSION or a later one.
# Each field is compared as an integer, so 2.1.1000 is later than 2.1.305.
# As in SemVer, build metadata (+...) is ignored, and a pre-release (-...)
# comes before its release: 2.1.306-beta.1 passes, 2.1.305-rc.1 does not.
# Text that is not three numbers is refused.
claude_version_ok() {
  local v="${1%%[[:space:]]*}" pre="" maj min pat want_maj want_min want_pat
  v="${v%%+*}"
  case "$v" in
    *-) return 1 ;;
    *-*) pre="${v#*-}"; v="${v%%-*}" ;;
  esac
  case "$v" in *[!0-9.]* | .* | *. | *..* | *.*.*.*) return 1 ;; esac
  case "$v" in *.*.*) ;; *) return 1 ;; esac
  IFS=. read -r maj min pat <<<"$v"
  IFS=. read -r want_maj want_min want_pat <<<"$CLAUDE_MIN_VERSION"
  # 10# reads a field such as 08 as decimal, not as octal.
  maj=$((10#$maj)); min=$((10#$min)); pat=$((10#$pat))
  if [ "$maj" -ne "$want_maj" ]; then [ "$maj" -gt "$want_maj" ]; return; fi
  if [ "$min" -ne "$want_min" ]; then [ "$min" -gt "$want_min" ]; return; fi
  if [ "$pat" -ne "$want_pat" ]; then [ "$pat" -gt "$want_pat" ]; return; fi
  [ -z "$pre" ]
}

# claude_version_check: 0 when the installed claude is new enough. If not, it
# prints the version it found and the version it needs, and returns 1.
claude_version_check() {
  local out
  out="$(timeout "$CLAUDE_VERSION_TIMEOUT" "${CLAUDE_BIN:-claude}" --version </dev/null 2>/dev/null)"
  claude_version_ok "$out" && return 0
  echo "Claude Code $CLAUDE_MIN_VERSION or later is required, and '${CLAUDE_BIN:-claude} --version' printed '${out:-nothing}'. Update it with 'claude update', then try again."
  return 1
}
