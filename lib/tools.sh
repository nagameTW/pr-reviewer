#!/usr/bin/env bash
# Which command sets a deadline and which command makes a SHA-256 digest.
# Homebrew's coreutils installs gtimeout and gsha256sum. macOS has shasum and
# no timeout. An entry script calls tools_resolve once at startup, and every
# call site reads TIMEOUT_BIN or SHA256_BIN.
#
# The values are command names, not paths. The shell looks a name up on PATH
# at the call, as it did for the plain command. SHA256_BIN can hold more than
# one word ("shasum -a 256"), so a call site leaves it unquoted.
# A call site reads ${TIMEOUT_BIN:-timeout} and ${SHA256_BIN:-sha256sum}, so a
# lib that a test sources alone still works.
# Source-time side effects are forbidden here.

# tools_first CMD...: prints the first CMD whose program is on PATH, and
# returns 1 when none is. Only the first word of a CMD is looked up.
tools_first() {
  local c
  for c in "$@"; do
    command -v "${c%% *}" >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# tools_resolve: sets TIMEOUT_BIN and SHA256_BIN. A tool with no match on PATH
# leaves its variable empty and makes the status 1. The caller prints the
# message, so each script says it in its own way.
# shellcheck disable=SC2034  # read by the scripts that source this lib
tools_resolve() {
  TIMEOUT_BIN="$(tools_first timeout gtimeout)"
  SHA256_BIN="$(tools_first sha256sum gsha256sum "shasum -a 256")"
  [ -n "$TIMEOUT_BIN" ] && [ -n "$SHA256_BIN" ]
}
