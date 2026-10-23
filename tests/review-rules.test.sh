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
  'escaping.*(script|event|JavaScript string)'
needs 'trace: an allowlist must match the whole normalized value' $SEC \
  'allowlist.*(whole|entire|full).*(normali[sz]|value)'
needs 'trace: substring checks and unanchored regexes are not controls' $SEC \
  '(substring|unanchored).*not a control'
needs 'trace: loosened protection needs worked-before, broken-after, no equal control' $SEC \
  'worked before.*(not|no longer).*after.*(equal|same|replacement)'
needs 'trace: a loosened-protection finding names the responses and the new behavior' $SEC \
  'name the affected (responses|requests).*new behavio'
needs 'trace: loosened protection is not defence in depth' $SEC \
  'not a defen[cs]e-in-depth'
needs 'trace: a new control that does not stop its attack is reported' $SEC \
  '(new|added) (control|protection)[^.]*does not stop[^.]*report'
needs 'trace: attacker path to an unparameterized query or command is CRITICAL' $SEC \
  '(attacker|untrusted).*(query|command).*not parameterized.*CRITICAL'
needs 'trace: an admin-only value is a data or correctness finding unless the admin is a threat' $SEC \
  '(administrator|admin).*(data|correctness).*(unless|except).*threat'
needs 'trace: constants and allowlisted identifiers are controls' $SEC \
  'constant.*allowlisted identifier.*control'
needs 'idiom: framing header values' $SEC 'framing header.*(DENY|SAMEORIGIN)'
needs 'idiom: request header placed into script' $SEC '(Referer|Host|X-Forwarded).*(script block|script)'
needs 'idiom: postMessage target origin and origin check' $SEC 'postMessage.*targetOrigin.*event\.origin'
needs 'idiom: CORS text of API8 stays' $SEC 'CORS.*reflects any Origin'
needs 'origin: Referer or Origin is not authentication or object authorization' $SEC \
  'Origin.*not (an )?authentication.*not (an )?(object )?authorization'
needs 'origin: an exact allowlist that rejects a missing header can be a valid request check' $SEC \
  'exact allowlist.*(missing header|rejects a missing).*valid'
lacks 'origin: no rule calls every Origin check forgeable' $SEC 'Origin[^.]*which a client can forge or omit'

# ── verifier does not undo the trace rules ────────────────────────────────
needs 'verify: a framework default alone does not refute a security-rule finding' lib/findings.sh \
  'not refuted.*framework default'
needs 'verify: it checks the output context and what the allowlist matches' lib/findings.sh \
  'output context.*allowlist'
needs 'verify: it checks what the protection did before and after the diff' lib/findings.sh \
  'before and after this diff'

# ── noise list agrees with the security rules ─────────────────────────────
needs 'noise: defence-in-depth exclusion needs an adequate primary defence' lib/review-spec.sh \
  'defen[cs]e-in-depth.*primary defen[cs]e.*adequate'
needs 'noise: a loosened protection is not defence in depth and not speculation' lib/review-spec.sh \
  'worked before.*no equal control.*not defen[cs]e in depth.*not speculation'
needs 'noise: the loosened-protection case points at the security trace' lib/review-spec.sh \
  'report it under the security trace'
needs 'noise: a new control that does not stop its attack is reported' lib/review-spec.sh \
  '(new|added) (control|protection)[^.]*does not stop[^.]*report'

# ── scope rule ────────────────────────────────────────────────────────────
needs 'scope: moved or reformatted lines are in scope for defects the move causes' pr-autoreview.sh \
  '(moved|reformatted).*(stay in scope|in scope).*(defects|defect) the move causes'
needs 'scope: moved lines keep the pre-existing exclusion for other old defects' pr-autoreview.sh \
  'other old defect.*(move|moved).*carries over.*(out of scope|not in scope)'
needs 'scope: a security defect in moved, reformatted or adjacent code is reported' pr-autoreview.sh \
  'security defect in moved, reformatted or adjacent unchanged code that (this|the) PR touches'
needs 'scope: that finding is MEDIUM, security, and starts with Pre-existing:' pr-autoreview.sh \
  'MEDIUM finding, area security, with an issue text that starts? with .Pre-existing:'
needs 'scope: that finding is MEDIUM, never blocks, and one per PR is enough' pr-autoreview.sh \
  'MEDIUM finding never blocks.*One such finding per PR'
needs 'scope: the reviewer lowers a higher rating only for an unchanged line' pr-autoreview.sh \
  'keeps a higher severity when the cited line is an added line'
needs 'scope: the noise list leaves room for a pre-existing path through code the PR touches' lib/review-spec.sh \
  'concrete exploit path in (this diff or )?the code (this PR|the diff) touches'
needs 'trace: a pre-existing security finding runs the same trace and stays MEDIUM' $SEC \
  'pre-existing defect.*same trace.*MEDIUM'
needs 'severity: the shared ladder states the pre-existing security exception' lib/review-spec.sh \
  'exception.*pre-existing security defect.*MEDIUM.*never blocks'
needs 'severity: the exception names the Pre-existing: prefix' lib/review-spec.sh \
  'exception.*starts with .Pre-existing:'
needs 'trace: the CRITICAL rule for interpolation names the pre-existing exception' $SEC \
  'name the source in the issue text\. Rule \(5\) is the exception'
lacks 'scope: moved lines are not reported as defects of the PR whatever their origin' pr-autoreview.sh \
  'moved from elsewhere[^.]*still belong to this PR'

# ── correctness paragraphs ────────────────────────────────────────────────
COR=checks/01-correctness.md
needs 'correctness: a null check is reported only with a returning line or a nullable type' $COR \
  'null check only when.*(returns null|nullable|allows it)'
needs 'correctness: an unfollowed signature change belongs to the contract area' $COR \
  'signature.*(did not follow|not follow).*contract'
needs 'correctness: a same-name wrapper is reported only for accidental recursion or a contradicted receiver' $COR \
  '(same name|same-name).*(accident|contradict)'
needs 'correctness: intentional delegation or failover to a sibling is not a finding' $COR \
  'intentional (delegation|failover).*not a finding'
needs 'correctness: the intended receiver is confirmed with Read or Grep' $COR \
  'receiver.*(Read|Grep)'
lacks 'correctness: no rule says a wrapper must never call a sibling' $COR 'not itself or a sibling'
needs 'correctness: route names and methods are confirmed with Read or Grep first' $COR \
  'route.*(name|method).*(Read|Grep)'

# ── one finding, one defect ───────────────────────────────────────────────
needs 'finding unit: one finding is one defect that one fix removes' pr-autoreview.sh \
  'one finding is one defect.*one fix'
needs 'finding unit: every location is listed as path:line in that finding' pr-autoreview.sh \
  'every location.*path:line'
needs 'finding unit: two defects that need two fixes are two findings' pr-autoreview.sh \
  'two defects.*two fixes.*two findings'

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
for k in 'security checklist' 'moved' 'null check' 'one defect' 'official options'; do
  case "$UNREL" in *"$k"*) ok "changelog: Unreleased mentions $k" ;; *) bad "changelog: Unreleased mentions $k" 'not found' ;; esac
done

if [ "$FAILED" -eq 0 ]; then echo "PASS: review rules"; else echo "FAIL: review rules"; exit 1; fi
