# What pr-reviewer looks at

This page lists the 13 items the reviewer checks, the security standards they cite, and what the reviewer does not cover. It also shows how one review runs.

Every statement matches the code in this repository. The page names functions and files, so you can find the code. It makes no claim about how many defects the reviewer finds. No measurement of that exists.

Contents:

- [The checklist](#the-checklist)
- [What the reviewer does not report](#what-the-reviewer-does-not-report)
- [How severity works](#how-severity-works)
- [Security standards the checks cite](#security-standards-the-checks-cite)
- [What the reviewer does not cover](#what-the-reviewer-does-not-cover)
- [How a review runs](#how-a-review-runs)
- [Diagrams](#diagrams)
- [Other tools](#other-tools)

## The checklist

The checklist is the folder [`checks/`](../checks/). Each file is one item. The number in the file name is the item number. The file `02b-ai-agent-security.md` is item 2b.

The reviewer sends the text of each item that applies to the model, with every slice of the diff. A slice is one part of a large diff. The reviewer cuts a big diff into slices by file and reviews each slice on its own. The function is `review_checks_render` in [`lib/review-spec.sh`](../lib/review-spec.sh). The item numbers stay fixed when you delete or add a file. You can [add, remove or change items](configuration.md#adding-your-own-checks).

Each finding names its item and a severity. A finding is one problem that the reviewer reports. A finding blocks when it makes the verdict of the review say Changes requested. The other verdict is Approved. The default severity below comes from the text of the item or from the severity ladder in [How severity works](#how-severity-works). The model can rate a single finding differently.

**1 Correctness.** A finding is a bug, an input that gets a wrong result, or a valid input that is rejected. It is also a caller broken by a changed signature, a data race, a deadlock, or an async call used without waiting for its result. Default: HIGH. CRITICAL when the bug destroys data. Applies to every PR.

**2 Security.** A finding is an exploitable flaw. The item names six areas:

- Input handling, such as injection and path traversal.
- Authentication.
- Authorization, checked per object and per field.
- Cryptography and secrets.
- Code execution, such as deserialization, eval and cross-site scripting.
- Data exposed in logs, errors and endpoints.

Every finding must pass the trace rule in [Security standards the checks cite](#security-standards-the-checks-cite). Default: CRITICAL, because the ladder rates an exploitable flaw CRITICAL. Applies to every PR.

**2b AI-agent security.** A finding is code that sends content to an LLM, gives it tools, or acts on its output. The question is what a fooled model could then reach. The item lists six cases:

- Text the application did not write steers the model, or reaches an action that no check outside the model stops.
- A secret, or personal data the task does not need, enters a prompt or a log.
- A tool has more power than its task needs, or a person does not approve a high-impact step.
- Stored memory or a search index has no record of its source, or one store serves several users with no scope filter.
- The reply of the model is used without validation.
- An LLM or tool call has no timeout.

Default: no severity of its own. The ladder applies. A missing timeout is the only resource-exhaustion case that counts as a finding. Applies only when the diff touches such code.

**3 Sensitive data.** A finding is a real private-network address, MAC address, host name or domain name. A token or credential is also a finding. This applies anywhere in the diff. Addresses and names that RFCs reserve for documentation are placeholders and are not a finding. A token with only its middle masked is a finding. A private-range address is a finding even in a test, unless the code recognizes or blocks such addresses. Default: CRITICAL, because the ladder rates exposed sensitive data CRITICAL. Applies to every PR.

**4 Project constraints.** A finding is a diff that breaks a rule the repository wrote down for itself. The rule can be in `README.md`, `CONTRIBUTING.md`, architecture notes, or an agent instruction file such as `CLAUDE.md` or `AGENTS.md`. An unwritten preference is not a constraint. Default: HIGH. CRITICAL when the rule is a safety rule, such as an action that must stay manual, opt-in or read-only. Applies to every PR.

**5 Tests.** A finding has one of three tiers:

- CRITICAL: the diff weakens CI. Examples are a deleted test file, a skip, xfail or only marker, a lower coverage floor, or a removed workflow step.
- HIGH: a bug fix has no test that would have failed before the fix.
- MEDIUM: a new feature has thin coverage, an assertion is too weak, or a test needs a live service and has no marker.

Type annotations, imports, refactors that keep behavior, dead-code deletion, and edits to config or docs do not need tests. Applies to every PR.

**6 Design.** A finding is over-engineering, needless complexity, or a change in the wrong place or against the existing architecture. Naming and comments count only when they hide the meaning. Default: MEDIUM at most for a borderline case. HIGH only when the change is clearly in the wrong place. Applies to every PR.

**7 Doc sync.** A finding is a diff that changes behavior while `README.md`, `docs/`, `CHANGELOG.md`, `.env.example` or a docstring still describes the old behavior. Default: HIGH, when a reader would follow the stale text into an error. Applies to every PR.

**8 Dependencies.** A finding is a new third-party dependency that the same diff does not declare in the manifest. It also needs a lockfile entry when the project has one. A lockfile is the file that records the exact versions in use. A dependency that is not pinned like the others is also a finding. Default: HIGH. A dependency that the standard library or an installed package could replace, or that has no reason in the PR text, is MEDIUM. Applies to every PR.

**9 Evidence-first.** A finding is a new or retuned heuristic, limit, model choice or prompt. It ships with no measurement that shows it beats what it replaces. "It looks better" is not evidence. Default: MEDIUM. The summary says which measurement would settle the question. Applies only when the diff changes one of these.

**10 Tool surface.** A finding is a tool that an LLM can call, judged by the worst thing a misled model could do with it. Applies only when the diff defines or changes such tools.

- HIGH: any one of these:
  - The tool is on no explicit allow list.
  - The tool has functions its task does not use.
  - The tool is open-ended, for example any shell command or any URL.
  - The tool acts under a shared admin account.
  - The tool leaves the allow decision to the model.
  - The tool runs a high-impact step with no person approving it.
  - The tool is from a third party. It is loaded unpinned, such as `@latest`, or from a source nobody verified.
- CRITICAL: any one of these:
  - Text from outside can reach any of the HIGH cases through the diff.
  - The diff removes or bypasses an approval step or an opt-in that already exists.
  - A tool declares less than it does, for example marked read-only but it writes.

**11 Acceptance.** A finding is a requirement of the linked issue that the diff does not deliver or narrows without saying so. Default: HIGH. A judgment about scope goes in the summary and is not a finding. Applies only when the PR links an issue.

**12 Half-fixes.** When a diff fixes a defect, the item asks where else the same defect lives. Examples are a sibling function without the new guard, a second call site, an equivalent case, or a copied expression. A comment that no longer matches its code counts. A stale doc belongs to item 7. Default: the severity of the defect being fixed. The model sets the `kind` field of these findings to `half_fix`. A HIGH one shows as MEDIUM, does not block, and keeps its original severity beside it. A CRITICAL one still blocks. Applies to every PR.

## What the reviewer does not report

The prompt gives the model one list of things to leave out. The list is `REVIEW_NOISE_LIST` in [`lib/review-spec.sh`](../lib/review-spec.sh):

- Denial of service, rate limiting and resource exhaustion. The one exception is a missing timeout on an LLM or tool call (item 2b).
- Memory-safety problems in a memory-safe language.
- Speculative vulnerabilities with no concrete exploit path in this diff.
- Style or formatting that a linter already enforces in CI.
- Code-quality remarks on a change that touches only docs. The sensitive-data check still applies.
- Praise, questions and restatements of the diff.
- Defense-in-depth suggestions where the main defense is adequate.

A finding must be about something the diff introduces, changes or leaves broken. A problem that the PR does not touch gets one line in the summary at most. The model reports no finding about punctuation style. Two cases stay findings: punctuation that changes how the code parses or runs, and punctuation that a check in the reviewed repository rejects.

## How severity works

The ladder is `SEVERITY_SPEC` in [`lib/review-spec.sh`](../lib/review-spec.sh).

| Severity | Meaning |
| --- | --- |
| CRITICAL | An exploitable security flaw, exposed sensitive data, a bug that destroys data, or CI weakened by the diff. |
| HIGH | Wrong behavior on a realistic input, a broken project rule, a bug fix with no test that failed before, docs that describe old behavior, or a change clearly in the wrong place. The author must fix it before merge. |
| MEDIUM | Worth fixing. Does not block. |
| LOW | Minor polish. A pure style remark starts with `Nit:`. |

CRITICAL and HIGH findings block. A severity label that the reviewer does not recognize blocks too. A block decides the text of the verdict only. The reviewer never stops a merge.

The model sets an `area` field on each finding, such as `test`, `convention`, `wording`, `process` or `doc`. On a doc finding it also sets an `audience` field. A round is one review of one PR. Every push starts a new round. Three rules can lower a HIGH finding to a finding that does not block:

- On a PR of 300 changed lines or more, a HIGH in the area test, convention, wording or process does not block. A HIGH doc finding for maintainers only does not block either. A doc finding is never for maintainers only when its file is one of three kinds. The file name starts with `README` or `CONTRIBUTING` at the repository root. Or the file name ends with `.env.example`. Or the file is under `docs/`. The rule is the jq expression `FINDINGS_IS_BLOCKING_JQ` in [`lib/findings.sh`](../lib/findings.sh). The file pattern is `FINDINGS_FOLLOWED_DOC_RE` in the same file.
- A HIGH finding gets MEDIUM when the model sets its `kind` field to `wording`, `judgment` or `half_fix`.
- From round 2, a HIGH on a file that the push did not change, and that no earlier round cited, becomes MEDIUM. This applies when the reviewer knows which files the push changed.

The comment lists the findings that do not block behind one fold. When two or more of them are about tests, conventions, wording, process, or a doc for maintainers or team members, the comment lists those as one item. The item is titled `Tests, docs and process (N)` and holds one line for each finding, with its severity, `path:line` and a one-line issue. A HIGH finding never joins this item, and neither does a finding that blocks, a doc finding for operators or users, or a finding that a rule lowered. One such finding stays on its own line. The grouping is part of the display only. The count, the verdict, the refutation pass, the follow-up ticket and the file list that the next round reads all use the separate findings. The function is `findings_render_soft` in [`lib/findings.sh`](../lib/findings.sh).

`FINDINGS_CONVERGE_JQ` applies the last two rules. CRITICAL is never lowered. The comment keeps the original severity of a lowered finding. [Operating the reviewer](operations.md#how-one-round-works) describes the same rules from the side of the operator.

## Security standards the checks cite

The IDs and names in the check files come from the standards. Most of them come from OWASP, the Open Worldwide Application Security Project, a non-profit group that publishes security lists. The explanations and the "In a diff" patterns are the wording of the checklist. A pattern is a place to look. It is never a finding by itself.

### The trace rule

Item 2 says: run this trace before you report a security finding, and put the result in the finding. The finding must do three things:

1. Name the entry point that an attacker controls.
2. Follow it through the code to a concrete sink. A sink is a shell, a SQL or other query, a file path, HTML, a deserializer, eval, or an outbound URL.
3. Name the control that the reviewer checked and found missing or open to bypass. Examples are an auth check, schema validation, framework escaping, parameterized queries, an allowlist, or a bounded constant.

A candidate whose trace stops before a real sink is not a finding. A candidate whose sink an existing control already covers is not a finding either. A finding cites the ID with its year, for example `A05:2025`, and the CWE number when one fits. CWE, the Common Weakness Enumeration, is a numbered catalog of software weakness types. The model must not cite an ID that the check file does not list.

### Editions

| Standard | Edition | Checked | Check files |
| --- | --- | --- | --- |
| OWASP Top 10 | 2025 | 2026-10-22 | `checks/02-security.md` |
| OWASP API Security Top 10 | 2023 | 2026-10-22 | `checks/02-security.md` |
| CWE Top 25 | 2025 | 2026-10-22 | `checks/01-correctness.md`, `checks/02-security.md`, `checks/03-sensitive-data.md` |
| OWASP Top 10 for LLM Applications | 2026 | 2026-10-22 | `checks/02b-ai-agent-security.md`, `checks/10-tool-surface.md` |
| OWASP Top 10 for Agentic Applications | 2026 | 2026-10-22 | `checks/02b-ai-agent-security.md`, `checks/10-tool-surface.md` |
| Model Context Protocol specification | 2025-06-18 | 2026-10-22 | `checks/10-tool-surface.md` |
| RFC 1918 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 2606 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 3849 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 5737 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 6761 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 7042 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |
| RFC 9542 | as numbered | 2026-10-22 | `checks/03-sensitive-data.md` |

The files `checks/02-security.md`, `checks/02b-ai-agent-security.md` and `checks/10-tool-surface.md` link their sources. In 02 and 02b, the heading line of each list states the edition. `checks/03-sensitive-data.md` names its RFCs by number and links none. The Checked column holds the date on which the edition label was last compared with the official page. On 2026-10-22 the OWASP Top 10:2025 names and the CWE numbers were compared again. The other labels carry the date of the earlier comparison. The test [`tests/how-it-reviews.test.sh`](../tests/how-it-reviews.test.sh) keeps this table and the check files in step. It fails when a check file cites a standard that has no row, or that has a row which does not list that file. It also fails when a file in the Check files column does not cite the standard, and when a row has no file or no date.

Notes on the editions:

- **CWE Top 25:2025.** The label names the list that the checks start from. The checks cite 31 CWE numbers. Six of them are not on the 2025 list: CWE-209, CWE-287, CWE-367, CWE-532, CWE-636 and CWE-798.
- **RFC 7042.** RFC 9542 replaces it. The check file names both.

### Licenses of the OWASP texts

The reviewer uses the IDs and names of the OWASP lists and writes the explanations in its own words. The license of each source, as read on 2026-10-22:

- **The OWASP web site.** The page `https://owasp.org/Top10/2025/` states CC BY 3.0 in its footer. `checks/02-security.md` states CC BY 3.0 for that page.
- **The API Security page on the web site.** It shows a copyright notice and names no license. `checks/02-security.md` states CC BY-SA 4.0 for it. This is not verified from the page.
- **The OWASP GitHub repositories.** The `LICENSE` files of `OWASP/Top10` and `OWASP/API-Security` state CC BY-SA 4.0.
- **The two GenAI pages.** The footer of each page states CC BY-SA 4.0 for all content on the site, unless otherwise specified. `checks/02b-ai-agent-security.md` states CC BY-SA 4.0 for both.

## What the reviewer does not cover

These are current limits of the checklist. The model reads code and has no shell. It runs no scanner and reads no CI result.

- **GitHub Actions workflows.** No item is about workflows. Item 2 names two patterns under A03: an action pinned by tag and not by commit SHA, and widened workflow permissions. Item 5 flags a removed workflow step. No item names `pull_request_target`, or PR text that reaches a shell step through an expression.
- **Supply-chain details.** Items 8 and A03 cover declared, pinned and locked dependencies, and `curl` piped into `sh`. No item covers install scripts, look-alike package names or dependency confusion. The reviewer looks up no advisory database.
- **Dockerfile.** No item names a Dockerfile, a base image or container settings.
- **Infrastructure as code.** Item 2 (A02) names three patterns: a rule open to `0.0.0.0/0`, a public bucket, and `"*"` actions. No item covers the rest of such code.
- **Privacy retention.** Items 2 (A09) and 2b flag personal data in logs and prompts. Item 2b also flags agent memory with no expiry and embeddings kept after their source is deleted. No item checks retention of other data, deletion on request, or consent.

Your own checks can fill a gap. See [Adding your own checks](configuration.md#adding-your-own-checks). A CI job can run a scanner for the gap. [Status and limits](../README.md#status-and-limits) lists the other limits, such as the unknown detection rate.

## How a review runs

[Operating the reviewer](operations.md#how-one-round-works) describes the seven steps of a round. This section lists the main parts of a review and the code behind each part.

1. **The rules come from the default branch.** The reviewer checks out the merge base of the PR and applies the diff on top. The merge base is the commit where the PR branch left the default branch. It never checks out the branch of the author. Then it copies the convention files from the newest commit of the default branch over the tree. Convention files hold the rules of the repository and the settings of its coding agents. The function is `tree_force_convention_files` in [`lib/tree.sh`](../lib/tree.sh). The list is `TREE_CONV_RE`: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, `.claude/`, README and CONTRIBUTING files, and `.github/review-checks.md`. A PR cannot change the rules that judge it. The checklist comes from the `checks/` folder of the reviewer, never from the PR.
2. **The diff is cut into slices.** The reviewer cuts a diff of more than 300 changed lines by file. A slice holds about 250 lines. A round has at most 8 slices. The functions are `chunk_split` and `chunk_plan` in [`lib/chunk.sh`](../lib/chunk.sh). A PR of more than 2000 changed lines or 40 files gets a request to split and no review, with three exceptions listed in [`lib/split.sh`](../lib/split.sh). Localization data files do not count toward the 40 files and are still reviewed in full. They are `.json`, `.yml`, `.yaml`, `.properties` and `.toml` files under a directory named `locale`, `locales`, `i18n`, `l10n`, `translation`, `translations`, `messages` or `lang`, and files with a translation extension (`.po`, `.pot`, `.xlf`, `.xliff`, `.arb`, `.resx`, `.strings`, `.stringsdict`). Source files always count.
3. **Each slice gets a read-only review.** The model has three tools: `Read`, `Grep` and `Glob`. They read the repository and the diff of that slice. The model runs no code. Its answer is JSON with a verdict, findings and a list of what it could not verify.
   - **The model reads a labelled copy of the diff.** The `Read` tool prints a line number in front of each line. Models copied that number into the line of a finding, and the comment pointed at the wrong code. So each line of the copy starts with a label and a tab. `NEW[n]` marks a context line or an added line, where n is its line in the file after the change. `NEW[-]` marks a removed line. The copy changes only the start of each line, and the raw diff stays as it is for `git apply` and the slice splitter. The function is `diffview_make` in [`lib/diffview.sh`](../lib/diffview.sh). If the reviewer cannot make the copy, the log shows a `WARNING` and the model reads the raw diff. The prompt then tells it to count the line from the hunk header.
4. **A second call tries to refute each blocking finding.** To refute a finding is to argue that it is wrong. Each blocking finding gets one such call. A round makes at most 6 by default. The call reads the labelled copy of the diff and gets the same line rule. A refutation removes a finding only at a confidence of 0.8 or higher with a stated reason. The function is `findings_verify_refuted` in [`lib/findings.sh`](../lib/findings.sh). A timeout or an unclear answer keeps the finding. A finding that cites a file that does not exist is dropped before this step. A finding with a line past the end of the cited file keeps its severity and gets line 0, so no finding starts or stops blocking because of its line. This runs only when the diff was applied to the tree. The function is `findings_clamp_lines` in [`lib/findings.sh`](../lib/findings.sh).
5. **An optional red team attacks an approval.** A red team is a step in which the model looks for defects that the first review missed. It reads the same labelled copy of the diff. When `PRREVIEW_GATE_REDTEAM` is on, a round that is about to approve first asks the model for candidate defects. The default limit is 3 candidates. Each candidate goes through the same refutation step. The red team cannot block by itself. See `redteam_should_run` in [`lib/redteam.sh`](../lib/redteam.sh) and [Optional: a red team before an approval](operations.md#optional-a-red-team-before-an-approval).
6. **Blocking findings carry over between rounds.** Every push is a new round. The prompt gives the model the blocking findings of the last round. It must mark each one as fixed, or repeat it with the prefix `Carried over:`. A finding that the model repeats this way is carried over, and it still blocks. The model keeps the file, the severity and the issue text of a carried finding. It keeps the line too, and changes it only when the old line is past the end of the file or is not the line of the code that the finding names. When slices give one carried finding two lines, the merge of the slices keeps the first in slice order. Copies that differ in severity, area or kind stay apart. From round 2, the model reviews the files changed since the last reviewed round. The function is `prompt_round_task_section` in [`lib/prompt.sh`](../lib/prompt.sh). The reviewer does not check that the model does this. See [Across rounds](operations.md#across-rounds).
7. **The reviewer fails closed.** The rule is to hold back a verdict that it could not reach. The cases below are the main ones. [When something fails](operations.md#when-something-fails) lists the rest.
   - Output that cannot be parsed, even after one repair call, gives no comment and a hold before the next try. The log says "no action (fail closed)" in `review_one_pr` in [`pr-autoreview.sh`](../pr-autoreview.sh).
   - A review that a repair call recovered cannot approve.
   - A slice that fails makes the comment say Changes requested, whatever the other slices found.
   - A refutation that is unclear leaves the finding in place.
   - The red team is the one step that fails open. A failed red-team call changes nothing, and the round approves as it would have without that step.

## Diagrams

Each diagram is collapsed. Open one to read it. The diagrams follow the light or dark theme of your browser.

### Overview

How the parts of the reviewer work together on your machine.

<details>
<summary>Overview: your machine, GitHub and Claude Code</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/overview-dark.svg">
  <img src="images/overview.svg" alt="Architecture of pr-reviewer. It runs on your machine. The review loop starts a round once a minute while a pull request is open. A round reads open PRs from GitHub through gh. It builds a worktree for each PR. It sends a prompt to Claude Code. Claude Code has only the tools Read, Grep and Glob. A round matches PR text and each comment against your sensitive-patterns file. It posts one comment for each new head. By default, it skips fork PRs from authors you do not trust. The reviewer never approves or merges. Its only merge call is gh pr merge --disable-auto. It turns off auto-merge on a head that the reviewer has not reviewed, and runs only with PRREVIEW_GATE_DISARM_AUTO_MERGE=1." width="720">
</picture>

</details>

### One round

One round has seven steps. The first four steps make no model call.

<details>
<summary>One review round in seven steps</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/round-dark.svg">
  <img src="images/round.svg" alt="Flowchart of one review round in seven steps. Steps 1 to 4 make no model call. Step 1 Pick: open PRs with no comment for the current head. Fork PRs from untrusted authors are skipped. If the head is unchanged and the last comment of the reviewer is under 10 minutes old, the round waits. A title, description or base edit can cause this wait. A push to the parent branch of a stacked PR can cause it too. A push to the PR branch never waits. Step 2 Scan: the title, description and linked issue are matched against your sensitive-patterns file. If a match is found, or the scan cannot run, a Review withheld notice is posted without the value. The PR is not reviewed. Step 3 Build: merge base plus PR diff, then convention files from the default branch. A PR with more than 2000 changed lines or 40 files gets a split request and no review, unless the PR is exempt. Localization data files do not count toward the 40 files. Step 4 Slice: slices of about 250 lines, up to 8. Step 5 Review: Claude Code reads the worktree. Step 6 Verify: findings that cite a missing file are dropped. One call for each blocking finding tries to refute it. Step 7 Post: model text is escaped. The comment is matched against your sensitive-patterns file. Then one comment is posted. Output that cannot be parsed is not posted." width="640">
</picture>

</details>

### One finding across rounds

Every push is a new round. The prompt asks the model to mark each earlier blocker as fixed. Or the model repeats the blocker with the prefix `Carried over:` before it. The harness does not check that the model does this. [Across rounds](operations.md#across-rounds) describes the rule.

<details>
<summary>States of one finding across rounds</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/rounds-dark.svg">
  <img src="images/rounds.svg" alt="State diagram of one finding across rounds. Each push starts a new round. A new CRITICAL or HIGH finding is blocking. On the next push, the model marks it fixed. Or the model repeats it with the prefix Carried over. A carried-over finding still blocks. It stays carried over until the model marks it fixed. A new HIGH finding can be on a file that the push did not change and that no earlier round cited. Then it is shown as MEDIUM. It does not block and is not carried over. CRITICAL is never lowered. The harness does not check that the model marks findings correctly. A round with no blocking findings posts Approved. If a PR is merged while its verdict is changes requested, it gets one alert comment." width="720">
</picture>

</details>

### Red team

An optional red team argues against an approval. It is off by default, because it adds cost and time to every approval. Run `prreview set PRREVIEW_GATE_REDTEAM 1` to turn it on.

<details>
<summary>The optional red team before an approval</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/redteam-dark.svg">
  <img src="images/redteam.svg" alt="Flowchart of the optional red team. A round has no blockers and is about to approve. One more call argues that the approval is wrong. It looks for five things in the diff. The first is parts that disagree. The next is a limit at the wrong level. The next is an error returned as success. The next is a branch that decides from other input. The last is a rule that the docs of the repo pin. If the call fails or times out, the approval stands. If there is no CRITICAL or HIGH candidate, the approval stands. Up to 3 candidates each go through one refutation call. A refuted candidate is dropped and the approval stands. A survivor is posted and marked as raised by the red team. The red team is off by default. The command prreview set PRREVIEW_GATE_REDTEAM 1 turns it on." width="720">
</picture>

</details>

## Other tools

[How pr-reviewer compares](comparison.md) puts the reviewer next to other pull-request review tools and links the vendor pages. That page also covers the login each tool needs, and when another tool fits better.
