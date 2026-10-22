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

# ── scope rule ────────────────────────────────────────────────────────────
needs 'scope: moved or reformatted added lines still belong to the PR' pr-autoreview.sh \
  'Added lines that were moved from elsewhere or only reformatted still belong to this PR'
needs 'scope: such lines get defects only, and the issue says the code was moved' pr-autoreview.sh \
  'report only defects on them, and say in the issue text that the code was moved'

# ── correctness paragraphs ────────────────────────────────────────────────
COR=checks/01-correctness.md
needs 'correctness: a null check is reported only with a returning line or a nullable type' $COR \
  'missing null check only when you can point to the line that returns null[^.]*or to a type that allows it'
needs 'correctness: an unfollowed signature change belongs to the contract area' $COR \
  'changed signature that a caller or an implementer did not follow[^.]*\.[^.]*contract'
needs 'correctness: a same-name wrapper must call the wrapped object' $COR \
  'wrapper, cache or delegate that calls a method of the same name must call the wrapped object'
needs 'correctness: route names and methods are confirmed with Read or Grep first' $COR \
  'route parameter name or an HTTP method[^.]*Read or Grep'

# ── one finding, one defect ───────────────────────────────────────────────
needs 'finding unit: one finding is one defect that one fix removes' pr-autoreview.sh \
  'One finding is one defect that one fix removes'
needs 'finding unit: every location is listed as path:line in that finding' pr-autoreview.sh \
  'List every location of that defect as path:line in that finding'
needs 'finding unit: two defects that need two fixes are two findings' pr-autoreview.sh \
  'Two defects that need two fixes are two findings'
needs 'finding unit: the unit rule follows the pattern completeness rule' pr-autoreview.sh \
  'Pattern completeness.*One finding is one defect'

# ── comparison page lists the official options with a date ────────────────
CMP=docs/comparison.md
needs 'comparison: a section for the official security options' $CMP '^## Official options for security review'
for opt in '/security-review' 'claude-code-security-review' 'Claude Code GitHub Actions' 'GitHub Copilot code review' 'CodeQL'; do
  needs "comparison: a table row for $opt" $CMP "^\\| [^|]*${opt}"
done
needs 'comparison: the section says when the pages were read' $CMP 'pages were read on 2026-10-'
needs 'comparison: the section calls the options another choice, not a replacement' $CMP 'other choices next to pr-reviewer, not replacements'
needs 'comparison: the price is dated' $CMP '2025-03-04 price post'

# ── changelog records the changes under Unreleased ────────────────────────
UNREL="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md)"
for k in 'security checklist' 'verification step' 'noise list' 'moved or reformatted' 'null check' 'one defect that one fix' 'official options'; do
  case "$UNREL" in *"$k"*) ok "changelog: Unreleased mentions $k" ;; *) bad "changelog: Unreleased mentions $k" 'not found' ;; esac
done

if [ "$FAILED" -eq 0 ]; then echo "PASS: review rules"; else echo "FAIL: review rules"; exit 1; fi
