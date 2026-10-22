# How pr-reviewer reviews

Line references in this page (`file:line`) match commit `c520527`. Run `git show c520527:<file>` to read the cited lines.

This page shows what pr-reviewer looks at, how one review runs, and how that compares with human reviewers and with other AI review tools. It states facts from the code. It makes no claim about how many defects the tool finds. No measurement of that exists yet.

Contents:

- [1. What it checks](#1-what-it-checks)
- [2. How a review runs](#2-how-a-review-runs)
- [3. Known limits](#3-known-limits)
- [4. Tools to run in CI next to the reviewer](#4-tools-to-run-in-ci-next-to-the-reviewer)
- [5. How others review, and how this compares](#5-how-others-review-and-how-this-compares)
- [6. Sources](#6-sources)

## 1. What it checks

### 1.1 How the checklist reaches the model

- The checklist is the directory `checks/`. Each file is one item. The model reads the full text of each file (`lib/review-spec.sh:109-115`).
- The number in the file name is the item number. The file `02b-ai-agent-security.md` is item 2b (`lib/review-spec.sh:109-115`).
- Thirteen items ship: 1, 2, 2b, 3, 4, 5, 6, 7, 8, 9, 10, 11 and 12. Together they are about 31 KB. The limit is 64 KiB (`lib/review-spec.sh:124`, `lib/review-spec.sh:149-150`).
- The reviewer reads the checklist once at start. If the checklist is broken, the reviewer refuses to run (`pr-autoreview.sh:472-477`).
- The reviewer reads it again for each PR. If the list is broken or no item applies, it skips the PR. It does not approve the PR (`pr-autoreview.sh:1857-1858`, `lib/review-spec.sh:156-158`).
- The text goes into the prompt under the heading `Review dimensions:`. The list of things not to report follows it (`pr-autoreview.sh:1998-2001`).
- A file can start with `applies_to: <globs>` to limit it to some paths. In a glob, `*` also matches `/`. A file with no `applies_to` applies to every PR (`lib/review-spec.sh:117-123`, `lib/review-spec.sh:190-201`).
- Front matter accepts only `applies_to`, blank lines and `#` comment lines. Any other line is an error. The closing `---` is required (`lib/review-spec.sh:170-184`).
- No shipped item uses `applies_to`. All 13 items go to the model on every PR.
- Four items decide for themselves. Items 2b and 10 tell the model to skip them silently when the diff does not match (`checks/02b-ai-agent-security.md:1`, `checks/10-tool-surface.md:1`). Item 9 applies only to a changed heuristic, limit, model choice or prompt (`checks/09-evidence-first.md:1`). Item 11 applies only when linked-issue text exists (`checks/11-acceptance.md:1`).
- One checklist serves all watched repos (`pr-autoreview.sh:472`, `prreview:67`). A repo adds its own rules in `.github/review-checks.md` (see item 4).
- `prreview checks list|path|add|remove` manages the checklist. The built-in directory cannot be changed in place. `add` and `remove` refuse and tell the user to run `prreview setup` first (`prreview:670-716`, `prreview:691`, `prreview:712`).

### 1.2 The items

Every finding carries one severity and one tag for the area it belongs to. Section 1.4 explains severity. Every item also leaves out the global list in section 1.3. An item that leaves out more says so.

#### Item 1: Correctness

File: `checks/01-correctness.md:1-3`

The model looks for:

- Bugs and broken logic.
- Realistic inputs that the code does not handle.
- Regressions in callers of anything whose signature or meaning the diff changed.
- A data race: two threads touch the same state with no lock or atomic operation.
- Check-then-act: a condition is checked and used in two steps, and something can change it between them (CWE-367).
- Locks taken in different orders on different paths (deadlock).
- An async call whose result is used without `await`.
- A shared file or temporary path that two runs can write at the same time.

Severity: the ladder in section 1.4. A realistic input that gets a wrong result is HIGH, not MEDIUM.

#### Item 2: Security

File: `checks/02-security.md:1-29`

The model looks for:

- Input-validation flaws: SQL, command, path-traversal and template injection.
- Authentication and authorization bypass.
- Weak cryptography and bad handling of secrets.
- Code execution: unsafe deserialization, `eval`, cross-site scripting.
- Data exposure in logs, error messages and endpoints.
- Missing per-object checks. Code that takes an object id from the request must confirm that this caller may act on that object (API1:2023).
- Mass assignment. An update must not let the caller set fields they may not change. A response must not return fields they may not see (API3:2023).

The reference lists in this file give the model a place to look. Section 1.5 names them. Examples of the patterns:

- A01: a record loaded by a request-supplied id with no owner or role check.
- A03: a CI action pinned by tag instead of commit SHA. A download piped into `sh`.
- A04: TLS verification turned off, such as `verify=False`.
- A05: `shell=True` with a variable. `innerHTML` or `dangerouslySetInnerHTML` with user data.
- A08: `pickle.loads`, or `yaml.load` with an unsafe loader.
- API7: a fetch of a user-supplied URL with no block on private and link-local addresses.

The model must do a trace before it reports a security finding. It writes the result in the finding:

1. Name the entry point that an attacker controls.
2. Follow it to a concrete sink: a shell, a query, a file path, HTML, a deserializer, `eval` or an outbound URL.
3. Name each existing control that the model checked and found absent or bypassable.

A candidate whose trace stops before a real sink is not a finding. A candidate whose sink an existing control covers is not a finding.

A listed pattern is never a finding by itself. A finding that matches an entry cites the ID, and a CWE if one fits. The example in the file is "A05:2025 Injection, CWE-89". The model must not cite an ID that is not listed.

It does not report: rate limits, quotas, cost caps and retry caps. One exception exists. A missing timeout on an LLM or tool call is a finding (item 2b).

Severity: an exploitable security flaw is CRITICAL (section 1.4).

#### Item 2b: AI-agent security

File: `checks/02b-ai-agent-security.md:1-27`

This item applies only when the diff touches code that sends content to an LLM, gives tools to one, or acts on its output. Otherwise the model skips it silently. The item starts from one premise: the model will sometimes be fooled. The model judges the code around the LLM by what a fooled model could reach.

The model looks for six kinds of problem:

- (a) Prompt injection (LLM01:2026, ASI01):
  - Outside text written into the instructions.
  - Outside text mixed into a prompt with nothing that marks its source.
  - A path where steered output can start an action that no check outside the model stops.
- (b) Sensitive information disclosure (LLM02:2026, LLM08:2026):
  - A secret in a prompt, system prompt or tool description.
  - Personal data that the task does not need, sent to an outside provider.
  - Full prompts and replies kept in logs or traces.
- (c) Excessive agency (LLM03:2026, ASI02, ASI03):
  - A tool with more functions or permissions than its task needs.
  - A tool that acts under a shared service or admin credential.
  - A high-impact or irreversible step with no person who approves it.
- (d) Memory and retrieval (ASI06, LLM09:2026):
  - Stored content with no check and no record of its source.
  - One store shared across users with no scope filter inside the query.
  - The agent's own output saved back as trusted memory.
- (e) Improper output handling (LLM10:2026). Model output gets the same validation and encoding as user input.
- (f) Unbounded consumption (LLM06:2026). An LLM or tool call with no timeout is a finding.

Citation rule: cite the ID with its year. The file says that LLM06:2025 and LLM06:2026 are different risks. Do not cite an ID that the file does not list. Do not invent a CWE number.

Severity: the ladder in section 1.4.

#### Item 3: Sensitive data

File: `checks/03-sensitive-data.md:1-8`

The model looks for these values anywhere in the diff:

- A real private-range IP address.
- A real MAC address.
- A real host or domain name that is not a documentation placeholder.
- A token or credential: API key, password, private key, session cookie, or a connection string with a password.

Values that count as placeholders:

| Kind | Placeholder values |
| --- | --- |
| IP address | `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` (RFC 5737). `2001:db8::/32` (RFC 3849) |
| MAC address | `00-00-5E-00-53-00` to `-FF` and `01-00-5E-90-10-00` to `-FF` (RFC 9542) |
| Name | `.test`, `.example`, `.invalid`, `example.com`, `example.net`, `example.org` (RFC 2606, RFC 6761) |
| Token | A value made only of `x`, `X`, `0` or `*`. A word such as `changeme`, `REPLACE_ME`, `<your-token>` or `${TOKEN}` |

Rules with a sharp edge:

- A host address in `10.0.0.0/8`, `172.16.0.0/12` or `192.168.0.0/16` is a finding. This holds in a comment and in a test that calls it an example.
- One exception exists. Code whose job is to recognize or block private addresses is not a finding, and neither are that code's own tests.
- The three blocks written as networks name no host. They are not a finding.
- A token that keeps any part that could be real is a finding. An example is a token with only its middle masked.
- Prefixes the file names: `ghp_`, `github_pat_`, `AKIA`, `xoxb-`, `xoxp-`, `sk-` and `-----BEGIN ... PRIVATE KEY-----`.
- A credential in code or config is CWE-798.

The reviewer also runs a separate scan with your own `sensitive-patterns` file. That scan reads the PR title, the description, the linked issue and every comment the reviewer is about to post. Section 2.1 describes it in steps 4, 9 and 16. It does not read the diff. It is not part of item 3.

Severity: sensitive data exposed is CRITICAL.

#### Item 4: Project constraints

File: `checks/04-project-constraints.md:1`

The model looks for a diff that breaks a rule the repo wrote down for itself. Sources of rules:

- `CLAUDE.md` or `AGENTS.md`.
- `README` and `CONTRIBUTING`.
- `.github/review-checks.md`. It is free text. The model applies each check in it like a numbered item and tags the finding `area=constraint`. The code does not parse the file (`lib/prompt.sh:91`).

It does not report: an undocumented preference. The file says an undocumented preference is not a constraint.

Severity:

- Breaking a documented rule is HIGH.
- Breaking a documented safety rule is CRITICAL. An example is an action the docs say must stay manual, opt-in or read-only.

#### Item 5: Tests

File: `checks/05-tests.md:1-3`

The model looks for three levels of problem:

- (a) CI weakened by the diff. This is CRITICAL. The model must confirm in the diff that the line really disables a test or lowers a floor:
  - A deleted test file.
  - A skip or xfail added, such as `@pytest.mark.skip` or `it.skip`.
  - An `only` added, such as `it.only` or `describe.only`.
  - A lowered coverage floor, such as `--cov-fail-under` or `coverageThreshold`.
  - A removed workflow step.
- (b) A bug fix with no test that would have failed before the fix. This is HIGH. The model names the test file and line that should exist.
- (c) A weak test. This is MEDIUM:
  - A new feature with thin coverage.
  - An assertion too weak to notice a break.
  - A fixture that never reaches the branch.
  - A test that needs a live outside service and is not marked as an integration test.

It does not report:

- A call such as `.skip(` in ordinary code. That is not a disabled test.
- A demand for tests on type annotations, imports, refactors that keep behavior, dead-code deletion, or edits to config or docs only.

#### Item 6: Design

File: `checks/06-design.md:1`

The model looks for:

- Over-engineering: code that solves a problem someone speculates will come.
- Needless complexity.
- A change in the wrong place, or one that does not fit the existing architecture.
- Names or comments, but only when they truly obscure meaning.

Severity: HIGH only when the problem is unambiguous. Borderline design taste is MEDIUM at most.

#### Item 7: Doc sync

File: `checks/07-doc-sync.md:1`

The model looks for a diff that changes behavior while `README`, `docs/`, `CHANGELOG`, `.env.example` or a docstring still describes the old behavior.

Severity: a stale doc that a reader would follow into an error is HIGH.

#### Item 8: Dependencies

File: `checks/08-dependencies.md:1`

The model looks for:

- A new third-party dependency that the diff does not declare in the manifest (and the lockfile, if the repo has one).
- A new dependency pinned less strictly than the rest of the project.
- A new dependency where the standard library or an installed package would do.
- A new dependency with no reason in the PR description.

Severity:

- A missing declaration is HIGH. An unpinned addition is HIGH when the rest are pinned.
- A dependency that is not needed, or has no stated reason, is MEDIUM.

#### Item 9: Evidence-first

File: `checks/09-evidence-first.md:1`

This item applies only to a changed heuristic, limit, model choice or prompt. The model looks for a change that ships with no measurement showing it beats what it replaces. For a new one, the comparison is the behavior without it. The summary says what measurement would settle the question. The file says never to treat "it looks better" as evidence.

Severity: MEDIUM.

#### Item 10: Tool surface

File: `checks/10-tool-surface.md:1-3`

This item applies only when the diff defines or changes tools that an LLM can call. Examples are MCP servers, function-calling tools and agent plugins. The model judges each tool by the worst thing a misled model could do with it.

HIGH cases:

- A callable tool that no explicit allow list names.
- A tool with functions its task does not use.
- An open-ended tool where a narrow one would do. Examples are any shell command, any URL or any query.
- A tool that acts under a shared service or admin credential.
- An allow-or-deny decision left to the model.
- A high-impact or irreversible action with no person who approves the exact action.
- A third-party tool, plugin, MCP server or prompt template loaded unpinned (`@latest`, a bare URL) or from an unverified source (ASI04).

CRITICAL cases:

- Any HIGH case that outside text can reach through this diff. Outside text means a user message, a fetched page, a file or a tool result. A fetch tool that requests any address the model names is an example (SSRF).
- A diff that removes or bypasses an existing approval step or opt-in.
- A tool that declares less than it does. An example is a tool marked read-only that writes.

Names, descriptions and results from a remote tool server are untrusted input. They are never instructions about which tool to call.

#### Item 11: Acceptance

File: `checks/11-acceptance.md:1`

This item applies only when the reviewer has linked-issue text. Section 2.1, step 9 says how the reviewer gets that text. The model looks for an acceptance criterion that the PR leaves undelivered or silently narrows. Judgment calls about scope go in the summary, not in a finding.

Severity: HIGH.

#### Item 12: Half-fixes

File: `checks/12-half-fixes.md:1`

When the diff fixes a defect, the model looks for the same defect elsewhere in the diff:

- A sibling function without the new guard.
- A second call site that reads the same field without the new default.
- A check extended for one case and not for an equivalent case.
- The same expression copied by hand in another place.
- A code comment that no longer matches the code beside it.

A doc file that still describes the old behavior belongs to item 7, at item 7's severity.

Severity: an unfixed sibling gets the severity of the defect that the diff fixes. The model tags it `kind=half_fix`. The kind cap then shows it as MEDIUM, so it does not block (`lib/findings.sh:756-757`). The comment lists the original severity beside it.

The reviewer gives this item a symbol table (section 2.3).

### 1.3 What it does not report

The prompt gives the model one list of things to leave out. The prompt calls them noise (`lib/review-spec.sh:207`, `pr-autoreview.sh:2001`):

- Denial of service, rate limiting and resource exhaustion. The one exception is a missing timeout on an LLM or tool call (item 2b).
- Memory-safety problems in a memory-safe language.
- Speculative vulnerabilities with no concrete exploit path in this diff.
- Style or formatting that a linter already enforces in CI.
- Code-quality remarks on a change that touches only docs. Sensitive-data checks still apply.
- Praise, questions and restatements of the diff.
- Defence-in-depth suggestions where the main defence is adequate.

Other limits in the prompt:

- A finding must be about something this diff introduces, changes or leaves broken. That covers the changed lines and any caller, test, doc or config that the change breaks. A problem that already existed and that the PR does not touch gets one line in the summary at most (`pr-autoreview.sh:2003`).
- An improvement beyond what the linked issue asked for is MEDIUM at most, if the diff did not break the thing (`pr-autoreview.sh:2011`).
- The model reports no finding about punctuation style. Two exceptions exist. Punctuation that changes how code parses or runs is reportable. So is punctuation that a check in the reviewed repo rejects (`lib/review-spec.sh:96`).
- The PR title and description are claims to check. A description that does not match the diff is a finding (`lib/prompt.sh:119`, `pr-autoreview.sh:1749`).
- The reviewer finds up to 10 lines in the description that claim "tests pass", "verified" or "validated". The model must name the hunk that is the evidence. A claim with no evidence goes in the summary. It is never a finding on its own (`lib/prompt.sh:565-573`).

### 1.4 How severity is decided

Severity ladder (`lib/review-spec.sh:26`):

| Severity | Meaning |
| --- | --- |
| CRITICAL | An exploitable security flaw. Sensitive data exposed. A bug that destroys data. CI weakened by the diff. |
| HIGH | Wrong behavior on realistic input. A broken project rule. A bug fix with no test that failed before. Docs that describe old behavior after a change. A change clearly in the wrong place. The author must fix it before merge. |
| MEDIUM | Worth fixing. Does not block. |
| LOW | Minor polish. A pure style remark starts with `Nit:`. |

Calibration in the prompt (`lib/review-spec.sh:25`): three cases must be HIGH, not MEDIUM.

1. A realistic input gets a wrong result, or valid input is rejected.
2. A fix leaves the case it cites no better, or worse.
3. A change to a default, limit or fallback alters behavior at many call sites, and only synthetic tests support it.

When the model is unsure between HIGH and MEDIUM on a wrong output, it picks HIGH.

Which findings block (a block decides the verdict text, not the merge). The rules are in `lib/findings.sh:577-598`:

- CRITICAL blocks.
- MEDIUM and LOW never block.
- A severity label that the harness does not recognize blocks.
- A missing severity is read as HIGH (`lib/findings.sh:552-554`).
- A HIGH in the area `correctness`, `security`, `contract`, `data`, `silent-failure`, `sibling`, `dependency`, `constraint` or `design` blocks. A missing or invented area is read as `correctness` (`lib/findings.sh:561-566`).
- A HIGH in the area `test`, `convention`, `wording` or `process` blocks only in coach mode.
- A HIGH in the area `doc` blocks, unless its audience is `maintainer`. A maintainer-only doc finding (a docstring, a comment, a design note) blocks only in coach mode. A doc finding on a README, CONTRIBUTING, `.env.example` or `docs/` file is never maintainer-only (`lib/findings.sh:605-619`).

Mode depends on diff size. Under 300 changed lines, the reviewer is a coach. From 300 changed lines, it is a gatekeeper. The code comment calls 300 "a default to tune, not a measured threshold" (`pr-autoreview.sh:298`, `pr-autoreview.sh:1839-1843`, `pr-autoreview.sh:292-297`).

Two caps lower a HIGH to MEDIUM (`lib/findings.sh:744-765`). CRITICAL is never capped. The comment keeps the original severity.

- Kind cap: a HIGH tagged `wording`, `judgment` or `half_fix` becomes MEDIUM (`lib/findings.sh:756-757`).
- Late cap, from round 2: a HIGH on a file outside the changes since the last round becomes MEDIUM. No earlier round may have cited that file (`lib/findings.sh:758-763`). The cap is off when the list of files changed since the last round is unknown (`pr-autoreview.sh:1828-1830`).

The model chooses the tags. A demoted finding skips the refutation step and is not carried to the next round (`lib/findings.sh:662-667`).

### 1.5 Standards the checks cite

The IDs and category names in the table are the standards' own. The explanations and the "In a diff" patterns are the checklist's wording. Each check file links its source.

On 2026-10-22 a person compared each edition label with the official page. The Checked column holds that date. The test `tests/how-it-reviews.test.sh` keeps this table and the check files in step. It fails when a check cites a standard that has no row, and when a row has no check that cites it.

| Standard | Edition | Checked | Source | Check file | What it covers | License, as the check file states | How the text is used |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OWASP Top 10 | 2025 | 2026-10-22 | [47] | `checks/02-security.md` | Ten web-application risk categories, A01 to A10. A01 includes SSRF. A05 includes XSS. | CC BY-SA 4.0 | Own words plus citation. Findings cite the ID. |
| OWASP API Security Top 10 | 2023 | 2026-10-22 | [48] | `checks/02-security.md` | API1 to API10. Examples: object-level authorization, mass assignment, SSRF. | CC BY-SA 4.0 | Own words plus citation. |
| CWE Top 25 | 2025 | 2026-10-22 | [49] | `checks/01-correctness.md`, `checks/02-security.md`, `checks/03-sensitive-data.md` | CWE numbers cited per entry, for example CWE-89 and CWE-639. Notes on memory-safety weaknesses. | Not stated | CWE numbers only. The file says each explanation is the checklist's wording. |
| OWASP Top 10 for LLM Applications | 2026 | 2026-10-22 | [50] | `checks/02b-ai-agent-security.md`, `checks/10-tool-surface.md` | LLM01 to LLM10. Examples: prompt injection, excessive agency, unbounded consumption. | CC BY-SA 4.0 | Own words plus citation. Findings cite ID and year. |
| OWASP Top 10 for Agentic Applications | 2026 | 2026-10-22 | [51] | `checks/02b-ai-agent-security.md`, `checks/10-tool-surface.md` | ASI01 to ASI10. Examples: goal hijack, tool misuse, memory poisoning. | CC BY-SA 4.0 | Own words plus citation. |
| Model Context Protocol specification | 2025-06-18 | 2026-10-22 | [52] | `checks/10-tool-surface.md` | Tool annotations from a server you do not trust are untrusted. | Not stated | URL cited in the check file. |
| RFC 1918 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | Private IPv4 address blocks. | Not stated | Reserved ranges taken from the RFC. |
| RFC 2606 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | Reserved names for documentation and tests, such as `example.com`. | Not stated | Reserved names taken from the RFC. |
| RFC 3849 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | IPv6 documentation prefix `2001:db8::/32`. | Not stated | Reserved range taken from the RFC. |
| RFC 5737 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | Three IPv4 documentation blocks. | Not stated | Reserved ranges taken from the RFC. |
| RFC 6761 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | Special-use domain names. | Not stated | Reserved names taken from the RFC. |
| RFC 7042 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | Older rules for MAC address documentation ranges. RFC 9542 obsoletes it. | Not stated | Named beside RFC 9542 in the check file. |
| RFC 9542 | as numbered | 2026-10-22 | [53] | `checks/03-sensitive-data.md` | MAC address documentation ranges. | Not stated | Reserved ranges taken from the RFC. |

The model must not cite an ID that is not in these lists. The checks name a few other items that are not standards, such as CVE-2025-32434 as an example under LLM04.

#### How the check on 2026-10-22 went

No edition label changed. Each label matches the official page. These differences remain:

- **Word "final".** The check files call the OWASP Top 10:2025 and the API Security Top 10:2023 "final editions". The 2025 page calls itself a release. Neither page uses the word "final". The table does not use it.
- **License.** The OWASP Top 10:2025 page states CC BY 3.0. The API Security page states no license and shows a copyright notice only. The check files state CC BY-SA 4.0 for the OWASP lists. This page repeats what each source states. It does not decide which license applies.
- **LLM Top 10 2026.** The resource page has the title "OWASP GenAI LLM Top 10 2026". OWASP announced the edition on 2026-09-02. The entry names are in a download that was not read. The public LLM Top 10 page still lists the 2025 edition. The 2026 entry names in `checks/02b-ai-agent-security.md` are therefore not verified here.
- **Agentic Applications.** The resource page title says "for 2026". The release post of 2025-12-09 lists ASI01 to ASI10. The names match the check file apart from small wording differences, such as "Tool Misuse" for ASI02.
- **CWE numbers.** The page of the 2025 list carries that year in its title. The checks cite 31 CWE numbers. Six are not on the 2025 list: CWE-209, CWE-287, CWE-367, CWE-532, CWE-636 and CWE-798. The label "CWE Top 25:2025" names the list the checks start from. It does not say that every cited number is on it.
- **MCP.** The page of version 2025-06-18 says: "clients MUST consider tool annotations to be untrusted unless they come from trusted servers".
- **RFCs.** RFC 7042 is obsolete. RFC 9542 replaces it, as the check file says. RFC 1918 and RFC 2606 are updated by RFC 6761. RFC 3849 is updated by RFC 9637. The ranges that the check lists are unchanged.

Pages read on 2026-10-22:

- https://top10.owasp.org/2025
- https://api-security.owasp.org/editions/2023/en/0x11-t10
- https://cwe.mitre.org/top25/archive/2025/2025_cwe_top25.html
- https://genai.owasp.org/resource/owasp-genai-llm-top-10-2026/
- https://genai.owasp.org/2026/09/01/owasp-genai-security-project-unveils-2026-top-10-for-llm-applications-new-agent-control-standard-and-sponsors-as-community-tops-30000-members/
- https://genai.owasp.org/llm-top-10/
- https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/
- https://genai.owasp.org/2025/12/09/owasp-top-10-for-agentic-applications-the-benchmark-for-agentic-security-in-the-age-of-autonomous-ai/
- https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- https://www.rfc-editor.org/rfc/rfc1918, and the same path with 2606, 3849, 5737, 6761, 7042 and 9542.

## 2. How a review runs

Steps run in this order. A step that fails stops the review of that PR. The reviewer then posts nothing or posts a fixed notice, as each step says.

### 2.1 Pipeline

1. **The reviewer sees the PR.**
   - A loop checks every 60 seconds (`review-loop.sh:70`). It counts the open PRs that the round would review. It starts a round when the count is above 0. With a count of 0, it starts a round on every 15th check (`review-loop.sh:62`, `review-loop.sh:125`, `lib/loop.sh:85-114`).
   - The count leaves out draft PRs and the fork PRs that the author filter skips (`lib/loop.sh:35-41`, `lib/loop.sh:94-99`).
   - With `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, a skipped PR with armed auto-merge counts as work, draft or not, because the round turns off that auto-merge (`lib/loop.sh:43-53`, `lib/loop.sh:100-106`).
   - A count that fails reads as 1, so the round runs (`lib/loop.sh:107-109`).
   - The loop runs a parse-checked copy of `pr-autoreview.sh` with a time limit of 3900 seconds (`review-loop.sh:51`, `review-loop.sh:151`).
   - A round covers each open PR that is not a draft and whose latest commit (the head) has no review yet (`pr-autoreview.sh:3327-3343`).
   - No label selects or excludes a PR. The only label in the code is `review-followup`, on follow-up issues (`pr-autoreview.sh:663`).
   - A PR from a branch in the repo is reviewed, whoever opened it. A PR from a fork is skipped unless one of three things holds:
     - Its author is in `PRREVIEW_GATE_TRUSTED_AUTHORS`.
     - `prreview once --pr` names it.
     - `PRREVIEW_GATE_FORK_PRS=1` is set.
   - The rule is `pr_author_trusted` and `trust_plan_prs` (`lib/trust.sh:34-54`, `lib/trust.sh:63-80`). A PR with a missing or wrong-typed field is skipped. Login matching ignores letter case. A PR whose author account was deleted has no login. It is skipped unless a command names it (`lib/trust.sh:6-9`, `lib/trust.sh:25-33`).
   - The code comment states the trade-off. The rule treats everyone who can push to the repository as trusted (`lib/trust.sh:11-16`).
   - The dispatcher applies the rule to the list of PRs. The job applies it again to its own read of the PR, before any model call or diff fetch (`pr-autoreview.sh:3281-3290`, `pr-autoreview.sh:921-933`).
   - A skipped PR gets no comment. The round prints one `WARNING:` line with the count (`pr-autoreview.sh:3469`, `lib/trust.sh:109-111`). A draft fork PR counts as skipped (`pr-autoreview.sh:3285-3286`).
   - One write can reach a skipped PR. With `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the reviewer turns off an armed auto-merge on it (`pr-autoreview.sh:3291-3310`, `lib/merge.sh:26`).
2. **The reviewer computes the review key.**
   - The key is the head SHA plus the first 12 hex digits of a SHA-256 hash. The hash covers the title, the description and the base branch name (`lib/prompt.sh:220-236`).
   - For a PR whose base is not the default branch, the base commit SHA is also in the hash (`lib/prompt.sh:226`, `lib/prompt.sh:231-232`).
   - A PR with no full 40-digit head or base SHA has no key. The reviewer skips it and counts a failure (`pr-autoreview.sh:962-963`).
   - A head counts as reviewed when a comment by the reviewer's own login or App has `<!-- pr-reviewer KEY -->` on its first line (`pr-autoreview.sh:974-979`, `lib/prompt.sh:197-204`).
   - A new review starts when the key changes. These events change the key:
     - A new commit.
     - An edit to the title, description or base branch.
     - For a stacked PR, a push to the parent branch.
   - A fixed notice carries the same marker. A notice marks the head as handled until the key changes (`pr-autoreview.sh:1048`, `pr-autoreview.sh:1069`, `pr-autoreview.sh:1504`, `pr-autoreview.sh:606`).
   - After a failure, the head waits before the next try. The wait is 300 seconds for a failed call and 1800 seconds for a usage limit. It doubles on a repeat of the same reason, up to 3600 seconds (`lib/holdoff.sh:42-47`, `lib/holdoff.sh:132-158`, `pr-autoreview.sh:1022-1028`).
3. **The reviewer limits the work in a round.** Up to 2 PRs run at the same time (`pr-autoreview.sh:118`, `pr-autoreview.sh:3362`). After 900 seconds, the round starts no new review (`pr-autoreview.sh:101`, `pr-autoreview.sh:3363-3366`).
4. **The reviewer scans the PR title and description for your sensitive patterns.**
   - It matches the title and the description against your `sensitive-patterns` file. This happens before any model call (`pr-autoreview.sh:1042-1043`).
   - On a match, or if the scan cannot run, the reviewer posts a fixed "Review withheld" notice. It makes no model call (`pr-autoreview.sh:1044-1054`).
   - Editing the title or description changes the key, so the PR gets a new review.
   - An optional title check is off by default (`pr-autoreview.sh:327`). When `PRREVIEW_GATE_TITLE_CHECK=1`, a title that is not a Conventional Commits title gets a reminder and no review (`pr-autoreview.sh:1060-1075`).
   - The linked issue gets the same scan in step 9, after the reviewer builds the diff.
5. **The reviewer builds the tree that the model reads.**
   - It gets the merge base from the GitHub compare API. It fetches the diff as `compare/<merge base>...<head SHA>` (`lib/merge.sh:70-73`, `lib/merge.sh:132-136`, `pr-autoreview.sh:1178-1180`).
   - If the number of files in the diff differs from the number GitHub reports, it skips the PR (`lib/merge.sh:138-139`).
   - It checks out the merge base. It never checks out the PR branch (`pr-autoreview.sh:1265`, `pr-autoreview.sh:1380`).
   - It applies the diff with `git apply`, all or nothing. If the diff does not apply, the model reviews the tree without the change, and the prompt says so (`pr-autoreview.sh:1445-1460`, `lib/prompt.sh:72-80`).
   - Binary files stay out of the tree. The prompt tells the model how many there are (`pr-autoreview.sh:1375-1381`, `lib/tree.sh:239-245`).
   - A symlink guard runs before and after the patch. A link that points outside the tree, into `.git`, to a directory, or nowhere is refused. A link that the author's patch adds gets a "Refused" comment (`lib/tree.sh:41-85`, `pr-autoreview.sh:1125-1135`, `pr-autoreview.sh:1433-1444`, `pr-autoreview.sh:599-614`).
6. **The reviewer restores the rules.** Section 2.2 explains how.
7. **The reviewer checks size.**
   - Size is added lines plus deleted lines (`pr-autoreview.sh:1471`).
   - Above 2000 lines or 40 files, there is no review. The reviewer posts a fixed "Please split" comment with a suggested file grouping (`pr-autoreview.sh:260-261`, `pr-autoreview.sh:1474-1523`, `lib/split.sh:99-108`).
   - Three cases are exempt. An exempt PR is reviewed in full (`lib/split.sh:21`, `lib/split.sh:26-32`, `lib/split.sh:36-80`):
     - 90% or more of the changed lines are deletions.
     - Every file matches the lock, generated, snapshot or migration pattern.
     - The description has a paragraph that starts `split-exempt:`.
8. **The reviewer cuts the diff into slices.**
   - Above 300 changed lines, it cuts the diff by file into slices of about 250 lines, at most 8. It never splits one file's hunks. Extra files join the last slice (`pr-autoreview.sh:1581`, `pr-autoreview.sh:307-308`, `lib/chunk.sh:44-102`, `lib/chunk.sh:122-141`).
   - At 300 lines or fewer, there is one slice. If slicing fails, the model gets the whole diff in one pass (`pr-autoreview.sh:1576-1579`).
   - Each slice gets one pass by default. Round 1 gets two passes from 1000 changed lines (`pr-autoreview.sh:226`, `pr-autoreview.sh:234`, `pr-autoreview.sh:240`, `lib/chunk.sh:214-223`).
   - A model reports on its own slice only. It must repeat an unfixed blocker from an earlier round, even for a file in no slice (`pr-autoreview.sh:1981-1989`).
   - At most 8 review calls run at the same time for one PR (`pr-autoreview.sh:132`, `pr-autoreview.sh:2067`).
9. **The reviewer adds context beyond the diff.** Section 2.3 lists it. This step also reads the linked issue and scans it:
   - GitHub tells the reviewer which issue the PR closes. The reviewer keeps only an issue of the same repo (`pr-autoreview.sh:1694-1703`).
   - If `gh` cannot answer, a pattern match on the description finds `close`, `fix` or `resolve` keywords instead (`lib/prompt.sh:24-38`, `pr-autoreview.sh:1704-1706`).
   - The reviewer reads the issue title and body. It matches them against your `sensitive-patterns` file, as in step 4 (`pr-autoreview.sh:1710-1718`).
   - On a match, or if the scan cannot run, the reviewer posts a fixed "Review withheld" notice. The notice does not quote the value. It makes no model call (`pr-autoreview.sh:1718-1729`).
   - Editing the issue does not change the review key. To get a new review, the author pushes a commit or edits the PR description (`pr-autoreview.sh:1722`).
   - If no match is found, the issue text goes into the intent file between markers that carry a random value. The author cannot forge the markers (`pr-autoreview.sh:1737-1739`).
   - With no issue text, the prompt tells the model to skip item 11 silently (`lib/prompt.sh:118-120`).
10. **The model reviews.** Section 2.4 lists what it can and cannot do. The model reads the checklist (section 1) and replies with one JSON object (`lib/review-spec.sh:53`).
    - The review, the refutation and the red team use the model `claude-opus-5-5`. The repair call uses `claude-sonnet-5-5` (`lib/review-spec.sh:12`, `pr-autoreview.sh:38`, `pr-autoreview.sh:499`, `pr-autoreview.sh:2253`).
    - Time limits: 900 seconds for a review, 600 seconds for a refutation or red team call, 300 seconds for a repair call (`pr-autoreview.sh:143`, `pr-autoreview.sh:149`, `pr-autoreview.sh:160`).
11. **The harness parses and, if needed, repairs the reply.**
    - It recovers the JSON even when prose surrounds it (`lib/findings.sh:233-248`).
    - If the review call did not finish, the reviewer does not repair. It holds the head (`pr-autoreview.sh:2214-2234`).
    - If the call finished but the reply does not parse, one repair call runs. It uses the cheaper model, no tools and the first 20000 bytes. It may not add, drop or reword a finding (`pr-autoreview.sh:2235-2254`, `lib/findings.sh:278`, `lib/findings.sh:324-355`).
    - A repaired review can block but never approves. The comment says it "may be incomplete" (`lib/findings.sh:318-321`, `pr-autoreview.sh:2919-2923`, `pr-autoreview.sh:3065-3069`).
    - If nothing usable remains, the reviewer posts nothing and holds the head (`pr-autoreview.sh:2282-2309`).
12. **The harness merges the slices.**
    - The verdict is `request_changes` if any slice says so.
    - Findings are the union of all slices. Duplicates on file, line and issue text are removed. The list is sorted by severity (`lib/chunk.sh:186-202`, `pr-autoreview.sh:2171`).
    - A slice counts as unreviewed only if all its passes failed. Then the round cannot approve. The comment lists the unreviewed files (`pr-autoreview.sh:2150-2165`, `pr-autoreview.sh:2900-2903`, `pr-autoreview.sh:3004-3012`).
13. **The harness filters findings with no model.**
    - It drops a finding whose file exists in neither the diff nor the tree. A dropped blocker stops the round from turning `request_changes` into `approve` (`lib/findings.sh:466-469`, `pr-autoreview.sh:2347-2394`, `pr-autoreview.sh:2379-2384`).
    - It applies the two caps from section 1.4 (`lib/findings.sh:744-765`, `pr-autoreview.sh:2505-2515`).
    - By default it does not check line numbers. `PRREVIEW_GATE_VERIFY_LINES=1` turns that check on (`pr-autoreview.sh:2411`).
14. **A second call tries to refute each blocker.** Section 2.5 explains.
15. **The harness recomputes the verdict.**
    - The model's verdict is advice. Any blocking finding gives `request_changes` (`lib/findings.sh:396-408`, `pr-autoreview.sh:2908-2913`).
    - If only MEDIUM and LOW findings remain, the verdict is `approve`. Two cases are the exception: a blocker was dropped for a bad citation, or the reply was repaired.
    - A `request_changes` with no findings stays. It is the model's way to say it could not finish.
16. **The reviewer scans the comment and posts it.**
    - The body is matched against your sensitive patterns. A scan that cannot decide counts as a match (`pr-autoreview.sh:3149`, `lib/scan.sh:61-83`).
    - On a match, the reviewer posts a fixed "Review withheld" notice. The full body goes to the local round log only. The verdict becomes `request_changes` (`pr-autoreview.sh:3150-3165`).
    - The same scan covers the split request, the symlink notice, follow-up issue text and the post-merge alert (`pr-autoreview.sh:1498-1501`, `pr-autoreview.sh:609-612`, `pr-autoreview.sh:3221`, `pr-autoreview.sh:3246`, `pr-autoreview.sh:3452`).
    - Three fixed notices carry no PR text and no model output. They are not scanned. They are the title-and-description notice, the linked-issue notice and the title reminder (`pr-autoreview.sh:1044-1073`, `pr-autoreview.sh:1718-1729`).
    - The comment goes out with `gh pr comment`. If the post fails, the reviewer holds the head and saves the finished body. The next try scans and posts it again with no model call (`pr-autoreview.sh:3171`, `pr-autoreview.sh:3178-3208`, `pr-autoreview.sh:1541-1564`, `lib/holdoff.sh:235-253`).
17. **After the post.**
    - Follow-up issues are off by default. When on, they use findings at or above a set severity (default HIGH) (`pr-autoreview.sh:326`, `lib/findings.sh:841-852`, `pr-autoreview.sh:3210-3259`).
    - After the PR loop, the round looks at the last 10 merged PRs from the last 48 hours. If one merged while the reviewer's last comment asked for changes, it posts one alert comment. A marker stops a second alert (`pr-autoreview.sh:3410-3413`, `pr-autoreview.sh:3419-3462`).
    - The round logs the tokens and cost of each call. The log is local. It is not in the PR comment (`lib/findings.sh:61-64`, `pr-autoreview.sh:3479-3491`).

### 2.2 Why a PR cannot change its own review rules

Four facts hold this in place:

- The checklist lives in the reviewer's own directory, outside the reviewed repo (`pr-autoreview.sh:472-477`).
- Before the review, the harness restores these files from the merge base: `CLAUDE.md` and `AGENTS.md` at any depth, anything under `.claude/`, any `README*` or `CONTRIBUTING*` file, and `.github/review-checks.md`. Files the patch created are deleted. Files it changed are restored (`lib/tree.sh:183-199`, `lib/tree.sh:207-224`, `pr-autoreview.sh:1419-1428`).
- For a PR based on another branch, each of these files in the tree is replaced with the default branch's copy. A file that the default branch lacks is removed (`pr-autoreview.sh:1285-1373`).
- A PR's edit to these files shows only in the diff. The model reviews it as a change to the rules. It never applies it as a rule (`lib/prompt.sh:91`).

One limit applies. The match is exact in file name case. An edit to `readme.md` is not restored (`lib/tree.sh:183`, `lib/tree.sh:199`).

### 2.3 Context beyond the diff

- **The whole tree.** The model may read any file in the worktree. That includes the files of other slices, in their post-change form. It cannot see another slice's diff (`pr-autoreview.sh:1976-1980`, `pr-autoreview.sh:2043-2044`).
- **The repo's rules.** A pointer to the convention files and to `.github/review-checks.md` (`lib/prompt.sh:91`).
- **The PR title and description, and the linked issue.** The file is marked as untrusted claims. The linked issue is the title and body of a same-repo issue that GitHub reports as closed by the PR. Step 9 of section 2.1 shows how the reviewer scans it (`pr-autoreview.sh:1671-1752`).
- **Claims in the description.** Up to 10 lines that say "tests pass", "verified" and similar (`lib/prompt.sh:565-573`).
- **A symbol table.** It is on by default and costs no model call (`pr-autoreview.sh:290`, `pr-autoreview.sh:1925-1932`).
  - For each definition the diff changes, it lists `path:line` references in files the diff did not touch.
  - It lists no source text.
  - It reads definitions in Python, JavaScript, TypeScript and shell files. It searches references in `*.py`, `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.sh` and `*.bash` files (`lib/symbols.sh:22-46`, `lib/symbols.sh:66`).
  - Limits: 20 symbols, 8 references for each, names of 3 or more characters. A definition in a `test/` or `tests/` path is skipped. A name with more than 24 hits is dropped (`lib/symbols.sh:43-44`, `lib/symbols.sh:58`, `lib/symbols.sh:73`).
  - It is a text search. It cannot see a removed call or a string literal (`pr-autoreview.sh:285-289`).
- **Earlier rounds.** From round 2, the prompt holds the last 3 verdicts that the reviewer posted. Each is cut at 4500 characters. Comments by people are not fed back (`lib/prompt.sh:174`, `lib/prompt.sh:178-185`, `lib/prompt.sh:300-311`).
  - The model must mark each earlier blocking finding as fixed, or repeat it word for word with a `Carried over:` prefix (`pr-autoreview.sh:1866-1911`).
  - The model must not reopen a finding that a refutation dropped, unless the code changed.
  - The model then looks for new defects only in files changed since the last reviewed round. It also looks at files that had a prior line "N more finding(s) on this file".
  - The harness does not check that the model repeats a finding word for word.

Quoted PR text in the prompt sits between markers that carry a new random value each round. A PR cannot close its own block early (`pr-autoreview.sh:1994`). The README calls this an instruction to the model, not a sandbox. The tool limits in the next section are what hold.

### 2.4 What the model can and cannot do

| Question | Answer | Where |
| --- | --- | --- |
| Read files in the repo tree? | Yes. It has `Read`, `Grep` and `Glob`, limited to the review worktree. | `pr-autoreview.sh:2039`, `lib/claude-call.sh:48`, `lib/claude-call.sh:73` |
| Read the diff? | Yes. A review call sees its own slice. A refutation call sees the full diff. | `pr-autoreview.sh:2039`, `pr-autoreview.sh:2701` |
| Read the PR title, description and linked issue? | Yes, as a file marked untrusted. | `pr-autoreview.sh:2040`, `pr-autoreview.sh:1749` |
| Run code, tests or shell commands? | No. Only the three read tools exist. | `lib/claude-call.sh:6-10`, `lib/claude-call.sh:34-35`, `lib/claude-call.sh:73` |
| Write or edit files? | No. No write tool exists. | `lib/claude-call.sh:73` |
| Fetch a URL or search the web? | No. No web or fetch tool exists. The `claude` process still sends the prompt to the model API, as every call does. | `lib/claude-call.sh:73` |
| Use MCP servers, skills, slash commands or user settings? | No. A flag turns off each one. | `lib/claude-call.sh:11-20`, `lib/claude-call.sh:72-74` |
| Read outside the tree? | No. Claude Code confines the file tools to the worktree and the call's own directories. A symlink guard runs on the tree. | `lib/claude-call.sh:21-27`, `lib/tree.sh:41-85` |
| See GitHub tokens? | No. The four token variables are empty for the child process. It also has no shell. | `lib/claude-call.sh:34-35`, `lib/claude-call.sh:70` |
| See another slice's diff? | No. It can read the other slices' files in the tree. | `pr-autoreview.sh:1976-1980`, `pr-autoreview.sh:2043-2044` |
| See CI results, other people's comments or commit messages? | No. The only comments fed back are the reviewer's own earlier verdicts. | `pr-autoreview.sh:1991-2029`, `lib/prompt.sh:178-185` |
| Post, approve, merge or push? | No. The harness posts one comment. | `pr-autoreview.sh:3171` |
| Change the rules it is judged by? | No. The convention files and `.github/review-checks.md` are restored. The checklist is read from the reviewer's own directory. | `lib/tree.sh:183-224`, `pr-autoreview.sh:472-477`, `pr-autoreview.sh:1419-1428` |
| Set the verdict? | No. The harness recomputes it from the findings. | `pr-autoreview.sh:2908-2913`, `lib/findings.sh:396-408` |
| Drop a blocking finding? | Only the refutation call can, under the rules in 2.5. | `lib/findings.sh:995-1012` |
| Lower a HIGH finding? | Yes, by the tags it chooses (`kind`, `area`). It cannot lower a CRITICAL. | `lib/findings.sh:744-765`, `lib/findings.sh:592-598` |
| Be fooled by text in the PR? | Possibly. The prompt calls the text data. The tool limits above hold even if the model is fooled. | `pr-autoreview.sh:1994` |

### 2.5 The refutation step

- The step runs only if a blocking finding remains (`lib/findings.sh:1042-1105`, `pr-autoreview.sh:2663-2803`).
- Each blocker gets its own call. All calls start together. They use the same model and the same read-only tools as the review. They see the full diff (`pr-autoreview.sh:2684-2706`).
- At most 6 blockers are checked in a round. CRITICAL goes first. The rest stand unverified, and the log says so (`pr-autoreview.sh:176`, `pr-autoreview.sh:2676-2680`, `lib/findings.sh:983`).
- The call is told to try to prove the finding wrong by reading the code. It checks four things. Does the code exist? Does the failure happen on a named realistic input? Does a guard already prevent it? Does the "missing" thing exist? (`lib/findings.sh:1057-1075`)
- It must not refute on a line-number mismatch alone. "Not sure" means not refuted.
- The harness deletes a finding only when the reply says `refuted: true`, has a confidence of 0.8 or higher, and gives a reason (`lib/findings.sh:995`, `lib/findings.sh:1002-1012`).
- A timeout, a crash, a reply that does not parse, a hedge or a low confidence leaves the finding standing (`pr-autoreview.sh:2775-2790`).
- A refuted finding appears struck through in the comment, with the reason and confidence (`pr-autoreview.sh:2765-2768`).
- The refutation uses the same model as the review. It is the only check on a blocker (`pr-autoreview.sh:2701`).

An optional red team is off by default. When `PRREVIEW_GATE_REDTEAM=1` and a round is about to approve, one more call looks for up to 3 CRITICAL or HIGH candidates. Each goes through citation checks and refutation. The red team cannot block on its own. It is the only stage that fails open. If its call fails, the approval stands (`lib/redteam.sh:41-52`, `lib/redteam.sh:61-66`, `lib/redteam.sh:92-101`, `pr-autoreview.sh:2568-2642`).

### 2.6 What a comment contains

The comment has these parts, in this order (`pr-autoreview.sh:2925-3120`):

1. A hidden marker line, `<!-- pr-reviewer KEY -->`.
2. A banner: `Automated review: ✅ Approved` or `Automated review: ❌ Changes requested`. It shows a count of blocking and non-blocking findings.
3. A summary. The first sentence is visible. The rest is in a fold.
4. The blocking list. Each line has the severity, `file:line` and the first sentence of the finding. A fold holds the rest, the model's confidence, the area, and any demotion or repeat note.
5. "Files not reviewed", if a slice failed.
6. A fold with the findings that do not block.
7. A fold with findings dropped by the refutation step.
8. A fold, "What this review could not verify", with 1 to 3 items from the model.
9. A fold with notes: citation and repair warnings, the demotion tally and the large-PR note.
10. A footer that says the verdict is advisory.

The text below is an invented example. It is not output from a real run. The PR, the repo and the code do not exist.

```text
<!-- pr-reviewer KEY -->
Automated review: ❌ Changes requested (1 blocking, 1 not blocking)

Summary: The PR adds an order search route. The route builds its SQL with
string formatting. [fold: 2 more sentences]

Blocking
- CRITICAL src/orders.py:42  The search term goes into the SQL text as a string.
  [fold]
  The term comes from the request query string (entry point). The f-string at
  line 42 passes it to `cursor.execute` (sink). No parameter binding and no
  allow list stands between them. A request with a quote character changes
  the query. Bind the term as a parameter.
  A05:2025 Injection, CWE-89 | confidence 0.9 | area: security

Not blocking [fold]
- MEDIUM tests/test_orders.py:12  The test checks only one search term and
  never reaches the empty-result branch.

What this review could not verify [fold]
- Behavior under real database load.

<sub>Review-only: this verdict is advisory. It cannot merge and does not read
CI results; a merge over an open blocking finding gets an alert afterwards.</sub>
```

A comment over 40000 characters is cut at a line boundary. The model's text has `<details>` and `<!--` escaped (`lib/findings.sh:486-494`, `pr-autoreview.sh:3134-3140`, `lib/findings.sh:1160-1162`, `lib/findings.sh:1251-1256`).

### 2.7 What it never does

The code makes only these writes to GitHub:

- `gh pr comment` (`pr-autoreview.sh:613`, `pr-autoreview.sh:1051`, `pr-autoreview.sh:1072`, `pr-autoreview.sh:1510`, `pr-autoreview.sh:3171`, `pr-autoreview.sh:3456`, and the linked-issue notice at `pr-autoreview.sh:1726`).
- `gh issue create` and `gh issue comment` for follow-up issues. This happens only when you turn follow-up issues on (`pr-autoreview.sh:653-664`).
- `gh pr merge --disable-auto`. This happens only when `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`. The default is off (`lib/merge.sh:26`, `pr-autoreview.sh:336`).
- A request for an App installation token (`lib/app.sh:56`).
- With `PRREVIEW_ALERT_REPO` set, one `reviewer-alert` label and one issue for each failure episode in that alert repo (`owner-alert.sh:5-9`, `owner-alert.sh:138-140`).

A search of the scripts finds none of these:

- `gh pr review`, which would submit a formal approval or a change request.
- `gh pr merge` without `--disable-auto`.
- `git push`.
- A call to a checks, statuses or CI endpoint.

A cross banner does not stop a merge. The reviewer never reads CI results. GitHub's pull-request write permission also allows approvals. The reviewer's code never uses that.

## 3. Known limits

These limits follow from the code. Section 5.4 lists what the checklist does not cover.

- **A fork PR is not reviewed by default.** The reviewer skips it unless its author is in `PRREVIEW_GATE_TRUSTED_AUTHORS`, `prreview once --pr owner/repo#N` names it, or `PRREVIEW_GATE_FORK_PRS=1` is set (`lib/trust.sh:6-9`, `pr-autoreview.sh:924`). Anyone can open a fork PR, and each push to it would start a new model call.
- **A rename can hide a file from a path-limited check.** For a renamed file, the list of changed paths holds the new name only (`lib/merge.sh:84-87`). A PR that moves a file out of a matching path does not trigger an item whose `applies_to` matches the old path. No shipped item uses `applies_to` today (`lib/review-spec.sh:190-201`).
- **A copied checklist does not receive new built-in items.** A user who copied the checklist keeps the copy as it is. To get a new built-in item, run `prreview setup` and answer `y` to "Copy them into your copy?". The default answer is `n` (`prreview:432`, `prreview:685`).
- **Item 2b can be removed to cut the prompt size.** Item 2b is 10,641 bytes, about a third of the checklist text, and it goes into every prompt even when the diff has no LLM code. To remove it, run `prreview setup` to copy the checklist, then `prreview checks remove 2b` (`prreview:706-712`). The cost is that the copy no longer receives later built-in items, unless you run `prreview setup` again and answer `y`. Nobody has measured the saving in dollars.
- **`.github/review-checks.md` applies to every PR.** It has no `applies_to`. The reviewer restores the file from the merge base, passes the model a pointer to it, and does not parse it (`lib/tree.sh:183-199`, `lib/prompt.sh:91`).

## 4. Tools to run in CI next to the reviewer

The reviewer reads the diff with a model. The model has no shell, so the reviewer runs no scanner (`lib/claude-call.sh:73`). The reviewer does not read CI results. A CI job can add checks that a model read does not give. Each tool below does one job:

- **zizmor.** It scans GitHub Actions workflow files for injection and over-wide permissions. The checklist has no item for workflow injection.
- **CodeQL.** GitHub code scanning. It follows data flow through the code and can scan workflow files. A model that reads a diff can miss a flow that spans many files.
- **gitleaks.** It scans commits for secrets with fixed rules for known token formats. The reviewer's sensitive-data item asks a model to look at the diff, and the model can miss a token.

## 5. How others review, and how this compares

### 5.1 Human reviewers

**What the standards say**

- Google's standard is to approve a change once it definitely improves the health of the code. The change need not be perfect [1].
- Google's guide tells reviewers to look at the design first, then at the details. It names deadlocks and races as things to check [2][3].
- Google's guide says that with no rule, a reviewer asks for consistency with the surrounding code [2].
- Google says a change of about 100 lines is reasonable and 1000 lines is usually too large [5]. GitLab's guide names about 200 lines [18].
- Google asks reviewers to say which parts they reviewed when they review only part of a change [2]. It also asks for quick responses [4] and for comments that state how much a point matters [6]. Conventional Comments is a public convention for such labels [7].

**What studies measured**

- Bacchelli and Bird studied review at Microsoft [8]. In a sample of 570 comments, 78 were about defects, and 65 of those were logic defects. Another 55 comments (about 10%) asked to remove unnecessary or unused code. 52 (about 9%) were about readability. Five were about security. Three were about exception handling. The paper reports that understanding the change is the main challenge.
- Czerwonka and colleagues report that about 15% of review comments point out a possible defect [10].
- Bosu and colleagues find that comments on config and build files are less useful. The share of useful comments falls as a change gets larger [9].
- At Google, reviewers leave formatting to automated tools [12].
- Spadini and colleagues find that reviewers discuss test files about half as often as production files [13]. In reviews of test files, 12% of improvement comments were about naming.
- Pascarella and colleagues rank the information a reviewer needs. Understanding the intent and the reason for a change ranks high [14].
- In a case-control study of Chromium OS, security defects were more likely to be found when the review took longer. They were less likely to be found when one review touched more directories [15].
- Fregnan and colleagues ran an experiment on file order [16]. When the defect was in the last file, reviewers' odds of catching it were 64% lower.

**What project checklists add**

Public review guides from large projects name more areas than the studies measure:

- Mozilla: compatibility, resources not released, threading, preferences, accessibility and internationalization [17].
- GitLab: feature flags, database migrations, background-job compatibility, legal approval for new dependencies, observability and performance [18].
- Rust: regression tests and risk labels on rollups [19].
- Kubernetes: a CLA label on pull requests and review guidelines that route changes to experts [20][21].
- Linux kernel: documented user-space interfaces, a build that works for each patch so that bisect works, and `Reviewed-by` as a statement by an accountable person [22][23].

**How a human review usually runs**

1. Read the description and any linked issue. Decide whether the change should exist [3][18].
2. Judge scope, size and risk. Route to an expert if needed [4][21].
3. Look at CI [11][18].
4. Build context. Run the code if needed [8][18].
5. Read the main logic first [3].
6. Read every line a human wrote [2].
7. Look beyond the diff: callers, conventions, related PRs [13][14].
8. Write comments with a priority [6][7].
9. Approve, request changes or approve with notes [1][22].
10. Respond fast [4].

**Known weak points of human review**

- Position matters. Later files get fewer comments [16].
- Test files get less attention [13].
- A larger change brings a lower share of useful comments [9][10].
- Style can crowd out substance [8].

### 5.2 AI review tools

The table lists what each tool's public docs say. The docs were read on 2026-10-22. Tools change. Check the current docs before you rely on a row. A blank "not stated" means the pages read did not say.

| Tool | What it covers | Context beyond the diff | Built-in tools | Noise controls |
| --- | --- | --- | --- | --- |
| CodeRabbit [24][25] | Bugs, security, style, docs, tests, PR title and description | Learnings, past issues and PRs, Jira, MCP, linked repos, `CLAUDE.md`, `AGENTS.md` | 50 or more, including Semgrep, OSV-Scanner, actionlint, zizmor and Hadolint | Profiles, path filters, auto-pause after 5 commits |
| GitHub Copilot code review [26][27] | Bugs, security, style | Repo-level agent context, instruction files, MCP | Not stated on the pages read | Reviews once by default. Skips lockfiles and SVG. |
| Greptile [28][29] | Bugs | Full code graph, custom rules, rules learned from about 10 PRs | Not stated | Strictness 1 to 3. Rule usage counts. |
| Qodo and PR-Agent [30][31] | Bugs, security, tests, docs, ticket compliance | Context engine across repos | Not stated | `/review` can be tuned |
| Cursor Bugbot [32] | Bugs | `BUGBOT.md`, learned rules | Not stated | Effort levels, incremental review, config read from the base branch |
| Graphite Agent [33] | Real bugs, logic, edge cases. Not style. | The whole codebase | Not stated | Learns from team responses |
| Sourcery [34] | General review plus a security section | Not stated | A security scan section, tools not named | Skips drafts and bots |
| Bito [35] | Bugs, smells, security, performance | Symbol index, AST, embeddings | fbinfer, Dependency-Check, Snyk | Merges results from several expert reviewers |
| Amazon Q Developer [36] | Static analysis, secrets, IaC, dependency scans, quality, deployment risk | Git diff or the whole project | Rule-based detectors plus generative AI | Severity levels, filters |
| Claude Code Review (hosted) [38][39] | Correctness by default | The diff and surrounding code, `CLAUDE.md`, `REVIEW.md` read from the base branch | None. It does not build or run the code. | Several agents find, verify, dedupe and rank. Nit cap. |
| OpenAI Codex review [40] | Only P0 and P1 issues | `AGENTS.md` review rules, threat model | None | P0 and P1 filter. Lint is left to CI. |
| Kodus [41] | PR and CLI review | Rules, memory, issues | Not stated | Severity flags |
| claude-code-security-review [37] | Injection, authentication, cryptography, data exposure, supply chain | The diff and surrounding files | None | Editable exclusion list. Its docs say it is not hardened against prompt injection and fits only trusted PRs. |

Four notes on the table:

- The Claude Code Review docs say a review neither approves nor blocks. A clean result does not mean the code has no bugs [38].
- Greptile, Qodo, Graphite and others publish accuracy numbers from their own benchmarks. These are vendor claims. Each vendor's benchmark ranks that vendor first. This page does not repeat them.
- Some of those benchmarks share the same repos or the same bug-planting method. Their results are not independent of each other.
- The pages read did not name OWASP or CWE as the source of any tool's checks.

**Independent studies of AI review**

| Study | What it measured |
| --- | --- |
| SWE-PRBench [42] | 350 PRs and eight models. With the diff alone, models found 15% to 31% of the problems that humans flagged. More context made all eight models worse. |
| SWR-Bench [43] | 1,000 PRs checked by people. Combining several reviews raised F1 by up to 43.67%. |
| A study of CodeRabbit feedback [44] | 31,073 pieces of review feedback. 36.4% were accepted and 56.3% were rejected. |
| RevMate [45] | In two organizations, over 587 patch reviews, developers accepted 8.1% and 7.2% of generated comments. |
| Sun and colleagues [46] | 16 GitHub AI review actions. Developers acted on 0.9% to 19.2% of valid AI comments. They acted on 60% of human comments. |

These studies measure other tools. They say nothing about pr-reviewer. They show why noise control and context size matter to any tool.

### 5.3 Comparison

Column key for pr-reviewer: Yes means a check or rule covers it. Partial means some of it. No means nothing covers it. The check file is in brackets.

| Dimension | Human practice | Common in AI tools | pr-reviewer |
| --- | --- | --- | --- |
| Correctness and logic | Core aim. 78 of 570 sampled comments [8]. About 15% in another study [10]. | All tools in 5.2 | Yes (01) |
| Edge cases and error handling | Mostly simple logic errors. Few exception-handling comments [8]. | Most tools | Partial (01, 02 A10). No check on retry safety. |
| Concurrency | Google names deadlocks and races [2]. Mozilla has a threading section [17]. | Not stated in the docs read | Yes (01) |
| Resource lifecycle | Mozilla names resources that are not released [17]. | Not stated in the docs read | Partial. Only on error paths, in a security context (02 A10). |
| Security | About 1% of sampled comments [8]. Detection depends on review time and scope [15]. | Most tools. Some run scanners (CodeRabbit, Bito, Amazon Q). | Yes (02, 02b, 03, 10). No check on privacy minimization. |
| Performance | Mozilla, GitLab and Rust name it [17][18][19]. | Bito lists it [35]. | No. The noise list drops resource exhaustion. The model cannot run code to measure. |
| Design and need for the change | Google reads design first [2][3]. | Rarely named | Partial (06, and a description that does not match the diff) |
| Complexity | About 10% of sampled comments [8]. | Rarely named | Yes (06) |
| Readability and naming | About 9% of sampled comments [8]. | Style is named by CodeRabbit, Copilot and Sourcery. | Partial. Only when a name or comment obscures meaning (06). |
| Style and formatting | Automated at Google [12]. Seen as low value [9]. | Some tools review it. Graphite and Codex leave it out. | No, by design. The noise list drops what a linter enforces. |
| Local habits not written down | Google: match the surrounding code [2]. | Tools read rule files. | No, by design. Item 4 accepts only rules the repo wrote down. |
| Tests | Test files get half the discussion [13]. Rust requires regression tests [19]. | CodeRabbit and Qodo | Yes (05) |
| Docs, description, commit message | Google, Mozilla, Rust and the kernel name them [2][17][19][22]. | CodeRabbit, Qodo | Partial (07, 04, the claims check). It does not read commit messages. The title check is off by default. |
| Compatibility and interfaces | Mozilla, GitLab and the kernel name them [17][18][23]. | Rarely named | Partial (01 for callers, plus the symbol table for 7 file types). No check on wire or stored formats. |
| Migrations and data | GitLab names migrations [18]. | Amazon Q lists deployment risk [36]. | Partial. Data-destroying bugs are CRITICAL (area `data`). No check on reversibility, scale or backfill. |
| Release, flags, rollback, observability | Mozilla, GitLab, Rust and the kernel name parts of it [17][18][19][22]. | Not stated | No |
| Dependencies and supply chain | GitLab requires legal approval. Kubernetes uses a CLA label [18][20]. | CodeRabbit, Bito and Amazon Q run dependency scanners [25][35][36]. | Partial (08, 02 A03). No check on install scripts, look-alike package names, dependency confusion or licenses. |
| Build, CI and config files | Config and build comments are less useful [9]. Reviewers look at CI first [11][18]. | CodeRabbit runs workflow linters [25]. | Partial. 05 covers CI weakened by the diff. 02 A03 covers pinning and permissions. No check on workflow injection, Docker or infrastructure code. It does not read CI results. |
| Accessibility and internationalization | Mozilla [17] | Not stated | No. A repo can add a rule in `.github/review-checks.md`. |
| Change size | About 100 lines reasonable, 1000 too large [5]. | Not stated | Yes. Above 2000 lines or 40 files it asks for a split. Above 300 lines it slices. |
| Routing to experts | Kubernetes and Google route reviews [4][21]. | Not stated | No. The tool only comments. |
| Praise and teaching | Part of human review | Not stated | No. Praise is on the noise list. |

Features that several AI tools share:

| Feature | Tools | pr-reviewer |
| --- | --- | --- |
| Rule files in the repo | CodeRabbit, Copilot, Greptile, Bugbot, Codex, Claude Code Review, Kodus | Yes. `checks/` and `.github/review-checks.md` |
| Rules read from the base branch | Claude Code Review, Bugbot [32][39] | Yes. This follows the same rule as those two tools (section 2.2). |
| A verification pass on findings | Claude Code Review [38] | Yes. The refutation step (section 2.5). |
| Incremental review on later pushes | Bugbot, CodeRabbit, Sourcery | Yes. From round 2 the model checks earlier blockers and files changed since. |
| Learning from reviewer feedback | CodeRabbit, Greptile, Bugbot, Graphite, Kodus | No. Comments by people are not fed back. |
| Built-in scanners | CodeRabbit, Bito, Amazon Q | No. The model has no shell, so the reviewer runs no scanner. Section 4 names tools to run in CI. |
| CI status as input | Not covered in the docs read | No. The reviewer does not read CI results (README). |
| Review depth levels | Claude Code Review, Copilot, Bugbot | Partial. One setting, `PRREVIEW_GATE_SAMPLES`, sets the passes for each slice. |
| Review started by a comment command | Claude Code Review, Bugbot | No. The reviewer polls. |
| One-click fix, merge gate or check run | Several | No, by design. The reviewer only comments. |

### 5.4 What pr-reviewer does not cover, and why

- **Workflow files, Docker and infrastructure code.** Only item 5(a) and the A03 and A02 patterns reach them. The checklist has no item for workflow injection or container settings. A repo can add one in `.github/review-checks.md`. Section 4 names tools to run in CI for workflow files.
- **Supply-chain detail.** Item 8 and A03 cover declared, pinned dependencies. Nothing covers install scripts, look-alike names or dependency confusion.
- **Migrations, rollout and observability.** No item covers them. The README states a project aim: predictable review behavior ahead of review breadth.
- **Performance.** The noise list drops resource-exhaustion findings. The model cannot run code, so it cannot measure load.
- **Scanner results and CI results.** The model has no shell. The reviewer does not read CI. The README says so.
- **Style, naming and unwritten habits.** The noise list drops style that a linter enforces. Item 4 accepts only written rules.
- **Learning from feedback and comment commands.** Not built.
- **Accuracy.** No measurement of the finding rate or the false-alarm rate exists yet.

Where behavior is a limit of the design, the tool says so in its output. The comment has a fold, "What this review could not verify". The footer says it does not read CI results.

## 6. Sources

Read on 2026-10-22 unless a note says otherwise.

Human review practice

1. Google, The Standard of Code Review. https://google.github.io/eng-practices/review/reviewer/standard.html
2. Google, What to look for in a code review. https://google.github.io/eng-practices/review/reviewer/looking-for.html
3. Google, Navigating a CL in review. https://google.github.io/eng-practices/review/reviewer/navigate.html
4. Google, Speed of code reviews. https://google.github.io/eng-practices/review/reviewer/speed.html
5. Google, Small CLs. https://google.github.io/eng-practices/review/developer/small-cls.html
6. Google, How to write code review comments. https://google.github.io/eng-practices/review/reviewer/comments.html
7. Conventional Comments. https://conventionalcomments.org/
8. Bacchelli and Bird, Expectations, Outcomes, and Challenges of Modern Code Review, 2013. https://web.eecs.umich.edu/~weimerw/2018-481/readings/codereview.pdf
9. Bosu and others, Characteristics of Useful Code Reviews, 2015. https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/bosu2015useful.pdf
10. Czerwonka and others, Code Reviews Do Not Find Bugs, 2015. https://microsoft.com/en-us/research/wp-content/uploads/2015/05/PID3556473.pdf
11. Code Reviewing in the Trenches: Understanding Challenges, Best Practices and Tool Needs. https://www.michaelagreiler.com/wp-content/uploads/2019/03/Code-Reviewing-in-the-Trenches-Understanding-Challenges-Best-Practices-and-Tool-Needs.pdf
12. Sadowski and others, Modern Code Review: A Case Study at Google, 2018. https://sback.it/publications/icse2018seip.pdf
13. Spadini and others, When Testing Meets Code Review, 2018. https://sback.it/publications/icse2018b.pdf
14. Pascarella and others, Information Needs in Contemporary Code Review, 2018. https://sback.it/publications/cscw2018.pdf
15. Paul and others, Why Security Defects Go Unnoticed during Code Reviews, 2021. https://arxiv.org/pdf/2102.06909
16. Fregnan and others, First Come First Served: The Impact of File Position on Code Review, 2022. https://arxiv.org/pdf/2208.04259
17. Mozilla, Reviewer checklist. https://firefox-source-docs.mozilla.org/contributing/reviewer_checklist.html
18. GitLab, Code review guidelines. https://docs.gitlab.com/development/code_review/
19. Rust compiler team, Reviews. https://forge.rust-lang.org/compiler/reviews.html
20. Kubernetes, Pull requests guide. https://www.kubernetes.dev/docs/guide/pull-requests/
21. Kubernetes, Review guidelines. https://github.com/kubernetes/community/blob/master/contributors/guide/review-guidelines.md
22. Linux kernel, Submitting patches. https://docs.kernel.org/process/submitting-patches.html
23. Linux kernel, Submit checklist. https://docs.kernel.org/process/submit-checklist.html

AI review tools (public documentation)

24. CodeRabbit, Configuration reference. https://docs.coderabbit.ai/reference/configuration
25. CodeRabbit, Tools list. https://docs.coderabbit.ai/tools/list
26. GitHub, Copilot code review concepts. https://docs.github.com/en/copilot/concepts/agents/code-review
27. GitHub, Use Copilot code review. https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review
28. Greptile, Introduction. https://www.greptile.com/docs/introduction
29. Greptile, Custom standards. https://www.greptile.com/docs/code-review/custom-standards.md
30. Qodo, Tools list. https://docs.qodo.ai/v1/tools/tools-list
31. Qodo, Platform overview. https://docs.qodo.ai/qodo-platform-overview
32. Cursor, Bugbot. https://cursor.com/docs/bugbot
33. Graphite, Graphite Agent. https://graphite.com/docs/graphite-agent
34. Sourcery, Code review. https://docs.sourcery.ai/Code-Review/
35. Bito, AI Code Review Agent overview. https://docs.bito.ai/ai-code-review-agent/overview
36. AWS, Amazon Q Developer code reviews. https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/code-reviews.html
37. Anthropic, claude-code-security-review. https://github.com/anthropics/claude-code-security-review
38. Claude Code, Code Review. https://code.claude.com/docs/en/code-review
39. Claude Code, Customize Code Review. https://code.claude.com/docs/en/code-review-customize
40. OpenAI, Codex GitHub integration. https://learn.chatgpt.com/docs/third-party/github
41. Kodus. https://github.com/kodustech/kodus-ai

Studies of AI review

42. SWE-PRBench. https://arxiv.org/abs/2603.26130
43. SWR-Bench. https://arxiv.org/abs/2509.01494
44. A study of CodeRabbit review feedback. https://arxiv.org/abs/2607.03316
45. RevMate. https://arxiv.org/abs/2411.07091
46. Sun and others, AI code review actions on GitHub. https://arxiv.org/abs/2508.18771

Standards cited by the checks

47. OWASP Top 10:2025. https://top10.owasp.org/2025 (the check files link https://owasp.org/Top10/2025/, which redirects to it)
48. OWASP API Security Top 10, 2023. https://api-security.owasp.org/editions/2023/en/0x11-t10
49. MITRE, CWE Top 25, 2025. https://cwe.mitre.org/top25/archive/2025/2025_cwe_top25.html
50. OWASP Top 10 for LLM Applications, 2026. https://genai.owasp.org/resource/owasp-genai-llm-top-10-2026/ and the release post https://genai.owasp.org/2026/09/01/owasp-genai-security-project-unveils-2026-top-10-for-llm-applications-new-agent-control-standard-and-sponsors-as-community-tops-30000-members/
51. OWASP Top 10 for Agentic Applications, 2026. https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/ and the release post https://genai.owasp.org/2025/12/09/owasp-top-10-for-agentic-applications-the-benchmark-for-agentic-security-in-the-age-of-autonomous-ai/
52. Model Context Protocol specification, tools, 2025-06-18. https://modelcontextprotocol.io/specification/2025-06-18/server/tools
53. RFC 1918, 5737, 3849, 9542, 7042, 2606 and 6761. https://www.rfc-editor.org/rfc/rfc1918 and the same path with each number.
