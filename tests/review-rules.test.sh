#!/usr/bin/env bash
# Pins the key concepts of the review rules in the prompts. Each assertion
# names one idea by a few words that must stay together, never a whole
# sentence and never the name of one benchmark case, so a rewording that keeps
# the idea passes. Run: bash tests/review-rules.test.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILED=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n    %s\n' "$1" "$2"; FAILED=1; }
# needs LABEL FILE REGEX: the file contains a line that matches the regex
# (case-insensitive, extended).
needs() { if grep -qiE -- "$3" "$2"; then ok "$1"; else bad "$1" "no match in $2 for: $3"; fi; }
# lacks LABEL FILE REGEX: the file has no match
lacks() { if grep -qiE -- "$3" "$2"; then bad "$1" "unexpected match in $2 for: $3"; else ok "$1"; fi; }

SEC=checks/02-security.md

# ── security trace rules ─────────────────────────────────────────────────
needs 'trace: HTML escaping does not cover script blocks, event attributes or JS strings' $SEC \
  'HTML escaping does not protect[^.]*script[^.]*event[^.]*JavaScript string'
needs 'trace: an allowlist must match the whole normalized value' $SEC \
  'allowlist is a control only when it matches the whole value after normalization'
needs 'trace: substring checks and unanchored regexes are not controls' $SEC \
  'substring check or an unanchored regular expression is not a control'
needs 'trace: loosened protection needs worked-before, broken-after, no equal control' $SEC \
  'worked before the diff, does not work after it, and no equal control remains'
needs 'trace: a loosened-protection finding names the responses and the new behavior' $SEC \
  'Name the affected responses and the new behavior'
needs 'trace: loosened protection is not defence in depth' $SEC \
  'not a defence-in-depth suggestion'
needs 'trace: attacker path to an unparameterized query or command is CRITICAL' $SEC \
  'path an attacker can really use reaches a query or command that is not parameterized, report it as CRITICAL'
needs 'trace: an admin-only value is a data or correctness finding unless the admin is a threat' $SEC \
  'only an administrator[^.]*data or correctness finding[^.]*unless[^.]*threat model'
needs 'trace: constants and allowlisted identifiers are controls' $SEC \
  'constant or an allowlisted identifier is a control'
needs 'idiom: framing header values' $SEC 'framing header[^;]*other than DENY or SAMEORIGIN'
needs 'idiom: Referer or Origin as access control' $SEC 'Referer or Origin[^;]*access control'
needs 'idiom: request header placed into script' $SEC 'request header \(Referer, Host, X-Forwarded-\*\) written into a script block'
needs 'idiom: postMessage target origin and origin check' $SEC 'postMessage[^;]*targetOrigin[^;]*event\.origin'
needs 'idiom: CORS text of API8 stays' $SEC 'CORS that reflects any Origin or allows \* with credentials'

# ── verifier does not undo the trace rules ────────────────────────────────
needs 'verify: a framework default alone does not refute a security-rule finding' lib/findings.sh \
  'not refuted only because a framework default or a general control'
needs 'verify: it checks output context, allowlist matching and before-and-after behavior' lib/findings.sh \
  'Check the actual output context, what the allowlist matches, and what the protection'

# ── noise list agrees with the security rules ─────────────────────────────
needs 'noise: defence-in-depth exclusion needs an adequate primary defence' lib/review-spec.sh \
  'defence-in-depth suggestions where the primary defence is already adequate'
needs 'noise: a loosened protection is not defence in depth and not speculation' lib/review-spec.sh \
  'worked before this diff, does not work after it and has no equal control left is not defence in depth and not speculation'
needs 'noise: the loosened-protection case points at the security trace' lib/review-spec.sh \
  'report it under the security trace'

if [ "$FAILED" -eq 0 ]; then echo "PASS: review rules"; else echo "FAIL: review rules"; exit 1; fi
