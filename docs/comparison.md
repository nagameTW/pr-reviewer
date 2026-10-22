# How pr-reviewer compares

This page puts pr-reviewer next to other pull-request review tools. Every row about another tool links to the page it comes from. The pages were read in October 2026. Most vendor pages show no date. Tools change, so check the linked page before you rely on a row. "Not found" means the page does not say. It does not mean "no".

This page lists no price and no review quality. pr-reviewer has no published accuracy number yet. See [Accuracy](#accuracy).


## Where pr-reviewer differs

Each point names the code that does it. The code paths are at the commit that you read.

- **It runs on your machine and needs no admin rights.** A loop polls once a minute. It needs your `gh` login and your Claude Code login. It needs no workflow file, GitHub App or webhook. [`prreview`](../prreview) checks the Claude Code login with `claude auth status`.
- **The default branch supplies the rules for every PR.** The reviewer applies the diff of the PR first. Then it copies these files from the default branch:
  - `CLAUDE.md` and `AGENTS.md`
  - any README or CONTRIBUTING file
  - `.mcp.json` and `.claude/`
  - `.github/review-checks.md`

  The function is `tree_force_convention_files` in [`lib/tree.sh`](../lib/tree.sh). The file list is the variable `TREE_CONV_RE` in the same file.
- **The model gets three read tools.** The tools are `Read`, `Grep` and `Glob`, and nothing else. The `--tools` option sets them ([`lib/claude-call.sh`](../lib/claude-call.sh), variable `CLAUDE_READ_TOOLS` and function `claude_call`). The code refuses a Claude Code older than 2.1.305 (same file, function `claude_version_check`). Your code never runs.
- **A second call tries to refute each blocking finding.** A refutation removes a finding only at confidence 0.8 or higher ([`lib/findings.sh`](../lib/findings.sh), function `findings_verify_refuted`). The step can only remove findings. It lowers false alarms. It is not a security control ([SECURITY.md](../SECURITY.md)).
- **It scans a comment against your own patterns before it posts.** A match, or a scan that cannot run, replaces the comment with a short notice ([`lib/scan.sh`](../lib/scan.sh), function `scan_hit_or_unknown`. [`pr-autoreview.sh`](../pr-autoreview.sh), function `review_one_pr`, calls it before the final post).
- **It posts nothing when a step fails.** If the output cannot be parsed, even after one repair call, the result is "no action (fail closed)" ([`pr-autoreview.sh`](../pr-autoreview.sh), function `review_one_pr`).
- **Unfixed blocking findings carry over to the next round.** The round prompt tells the model to mark them "Carried over:" ([`pr-autoreview.sh`](../pr-autoreview.sh), function `review_one_pr`).
- **Claims in the PR text are checked against the diff.** The prompt gives the model sentences such as "tests pass" or "verified" as claims to check ([`lib/prompt.sh`](../lib/prompt.sh), function `prompt_claims_section`).
- **It comments and nothing more.** Every verdict is a `gh pr comment` ([`pr-autoreview.sh`](../pr-autoreview.sh), function `review_one_pr`). It makes one merge-related call: `gh pr merge --disable-auto`. This call disarms an auto-merge on a head that the reviewer has not reviewed ([`lib/merge.sh`](../lib/merge.sh), function `disarm_unreviewed_auto_merge`).
- **A second, adversarial pass is off by default.** The red team runs only when `PRREVIEW_GATE_REDTEAM` is set ([`lib/redteam.sh`](../lib/redteam.sh), function `redteam_enabled`).

## Tools side by side

| Tool | Runs on | What you install | Approve or merge | Project rules are read from | Sources |
| --- | --- | --- | --- | --- | --- |
| pr-reviewer | Your machine, polling once a minute | `gh` and Claude Code logins. No admin rights | Comments only. No approval, no merge | The default branch, for every PR | [README](../README.md), [`lib/tree.sh`](../lib/tree.sh), [`lib/merge.sh`](../lib/merge.sh) |
| claude-code-action | Your GitHub runner | Claude GitHub App, a repo secret and a workflow file. You must be a repo admin | Cannot approve or merge. It can push commits to the PR branch | A fixed list of files is restored from the base branch. The rest stays at the PR head | [README][cca-readme], [security][cca-security], [limits][cca-limits] |
| Claude Code `/code-review` | Your own Claude Code session | Claude Code only | `--comment` posts inline comments. No approve or merge option found | Follows your `CLAUDE.md` on your checkout. A base-branch rule not found | [local review docs][cc-local] |
| Anthropic Code Review (managed) | Anthropic infrastructure | An organization Owner turns it on and installs the Claude GitHub App. Team and Enterprise plans only | "A review never approves or blocks the pull request" | `REVIEW.md` from the base or default branch | [Code Review][cc-review], [customize][cc-customize], [costs][cc-costs] |
| CodeRabbit | Vendor service. Self-hosting is Enterprise only | The CodeRabbit GitHub app. It needs owner-level permissions | An opt-in workflow requests changes and approves. `@coderabbitai approve` works only if it is on | `.coderabbit.yaml` is read from the feature branch under review, so the PR can change it | [pricing][cr-pricing], [FAQ][cr-faq], [GitHub setup][cr-github], [request changes][cr-request], [YAML config][cr-yaml] |
| Qodo PR-Agent | Your infrastructure: GitHub Action, CLI, Docker or webhook | A workflow file and an LLM key. GitLab, Bitbucket and Azure DevOps need a webhook or app | "Won't approve PRs" | `.pr_agent.toml` is read from the default branch | [README][pa-readme], [FAQ][pa-faq], [config options][pa-config] |
| GitHub Copilot code review | GitHub | No app. An org policy must allow code review | A "Comment" review by default. Approvals are a public preview, off by default | Instructions are read from the head branch, so the PR can change them | [about][gh-about], [use][gh-use] |
| OpenCodeReview | CLI on your machine, or GitHub Actions, GitLab CI, GitFlic CI or Gerrit | `npm install -g @alibaba-group/open-code-review` and a provider key. PR comments need a workflow file and `pull_request_target` | Posts reviews with `event: "COMMENT"` | Not found | [README][ocr-readme], [CI][ocr-ci], [post script][ocr-post] |
| Kodus | Self-hosted on a VM (2 CPU, 8 GB RAM, 60 GB disk) or Kodus Cloud | Connect a Git provider | Request Changes and Auto-approve are optional. The sample config has both off | `kodus-config.yml` at the repo root. The branch it is read from not found | [README][kodus-readme], [policy][kodus-policy], [config][kodus-config] |

## What the tools list for scanners, context and learning

These columns come from each vendor's own documentation.

| Tool | Built-in scanners | Learns from feedback or past PRs | Sources |
| --- | --- | --- | --- |
| CodeRabbit | 50 or more, including Semgrep, OSV-Scanner, actionlint, zizmor and Hadolint | Yes, "learnings", and past issues and PRs | [tools][cr-tools], [learnings][cr-learn], [configuration][cr-config] |
| Bito | `fbinfer`, Dependency-Check and Snyk | Not checked | [overview][bito] |
| Amazon Q Developer review | Rule-based detectors plus generative AI: SAST, secrets, IaC and SCA | Not checked | [code reviews][amazonq] |
| Greptile | Not found | Yes, rules learned from about 10 PRs, with rule usage counts | [introduction][greptile-intro], [custom standards][greptile-rules] |
| Cursor Bugbot | Not found | Yes, learned rules. It reads its config from the base branch | [Bugbot docs][bugbot] |
| Graphite Agent | Not found | Yes, from team responses | [Graphite docs][graphite] |
| Kodus | Not found | Yes, Kody Rules and Memory | [README][kodus-readme] |
| Claude Code Review (managed) | None. It does not build or run your code | Not checked. Several agents find, verify, de-duplicate and rank findings | [Code Review][cc-review], [customize][cc-customize] |

## Login

**It uses your Claude Code login.** Anthropic's [legal and compliance page][cc-legal] says the advertised Pro and Max limits "assume ordinary, individual usage". The page gives no number (read 2026-10-21). Anthropic decides whether an always-on poller counts. An API key avoids the question. But a key set in your shell does not reach the background service. Run `prreview run` from a terminal that has the key ([details](operations.md#where-to-run-it)).

Other tools, per their docs:

- claude-code-action takes an OAuth token for a Claude subscription. It needs a workflow file and a secret ([GitHub Actions docs][cc-actions]).
- OpenCodeReview has a delegation mode. The mode reuses the subscription quota of the host agent ([delegation doc][ocr-delegate]).
- The PR-Agent docs describe model provider API keys through LiteLLM. They do not describe a subscription login ([changing a model][pa-model]).
- CodeRabbit runs its own models. No option to use your own Claude login was found ([FAQ][cr-faq]).
- The terms forbid routing requests through Free, Pro or Max credentials "on behalf of their users". One Claude Code login is for one person. So a Claude login that a team shares does not fit pr-reviewer ([legal and compliance page][cc-legal]).

## When pr-reviewer fits

- You want unattended reviews on a machine you already own, with your own Claude Code login.
- You cannot install an App or add a workflow file, for example when you lack repo admin rights.
- You want the default branch to set the review rules for every PR, with no way for a PR to edit them.
- You want the model limited to reading, with PR text handled as data and every comment scanned before it posts.
- You want a comment and not a gate.


## When another tool fits

- **You want built-in scanners.** CodeRabbit lists 50 or more ([tools][cr-tools]). Bito and Amazon Q list their own scanners ([Bito][bito], [Amazon Q][amazonq]). pr-reviewer has none.
- **You want the tool to learn from feedback.** CodeRabbit, Greptile, Cursor Bugbot, Graphite Agent and Kodus do ([CodeRabbit][cr-learn], [Greptile][greptile-rules], [Bugbot][bugbot], [Graphite][graphite], [Kodus][kodus-readme]). pr-reviewer does not.
- **You want fixes that the tool applies for you.** The docs list Copilot, Cursor Bugbot and CodeRabbit as offering them ([Copilot][gh-use], [Bugbot][bugbot], [CodeRabbit][cr-config]). pr-reviewer is built not to change your code.
- **You want a merge gate.** CodeRabbit can request changes and approve ([request changes][cr-request]). Kodus can request changes and auto-approve ([policy][kodus-policy]). Copilot approvals are in public preview ([use][gh-use]). pr-reviewer never approves. It never submits a GitHub review.
- **You do not want a machine to keep running.** CodeRabbit runs as a vendor service ([FAQ][cr-faq]). Anthropic's managed Code Review runs on Anthropic infrastructure ([Code Review][cc-review]). claude-code-action runs on your GitHub runner. So it does not depend on your computer being on ([README][cca-readme]). pr-reviewer pauses when the machine sleeps.
- **You use GitLab, Bitbucket or Azure DevOps.** PR-Agent supports all three ([README][pa-readme]). OpenCodeReview supports GitLab CI and Gerrit ([README][ocr-readme]). pr-reviewer uses `gh` and works on GitHub only.
- **You want to ask follow-up questions inside the PR.** claude-code-action answers `@claude` in a PR ([README][cca-readme]).
- **You need hidden characters removed from PR text.** claude-code-action cleans hidden content from its input ([security][cca-security]). pr-reviewer does not. It wraps PR text in markers with a random value. It tells the model that the text is data. [SECURITY.md](../SECURITY.md) says this is an instruction to the model and not a sandbox.
- **A team shares one reviewer.** See [Login](#login). The terms do not allow routing a shared Claude login through other people's use.

## Accuracy

pr-reviewer has no published accuracy number yet. A paired benchmark is in progress. It scores seeded-bug PRs against clean PRs. Until it reports, treat the detection rate of pr-reviewer as unknown.

The numbers that other vendors publish are vendor claims. Each vendor's benchmark ranks its own tool first. Some of them share the same repos or the same bug-seeding method. So they are not independent ([Greptile][greptile-bench], [Entelligence][entelligence], [Qodo][qodo-bench]).

| Source | Number | What it is |
| --- | --- | --- |
| Greptile | 82% on its own benchmark | Vendor claim ([benchmarks][greptile-bench]) |
| Qodo | F1 60.1% on its own benchmark | Vendor claim. Details not verified ([benchmark][qodo-bench]) |
| Cursor Bugbot | "70% or more resolved before merge" | Vendor claim. It is the vendor's own usage metric, not precision or recall ([Bugbot][bugbot-page]) |
| OpenAI Codex review | F1 45.4% | A competing vendor's benchmark, so a vendor claim ([Entelligence][entelligence]) |

Independent studies:

- SWE-PRBench has 350 PRs and eight models. With only the diff, the models found 15% to 31% of the problems that human reviewers flagged. More context made all eight models worse ([arXiv][swe-prbench]).
- SWR-Bench has 1,000 verified PRs. Merging several review runs raised F1 by up to 43.67% ([arXiv][swr-bench]).
- A field study covers 31,073 CodeRabbit review responses. Developers accepted 36.4% and rejected 56.3% (academic, abstract only, [arXiv][cr-field]).
- RevMate covers 587 or more patch reviews in two organizations. Teams accepted 8.1% and 7.2% of the generated comments ([arXiv][revmate]).
- A study of 16 GitHub AI-review actions found that 0.9% to 19.2% of valid AI comments were acted on. For human comments, the figure was 60% ([arXiv][sun25]).


[cca-readme]: https://github.com/anthropics/claude-code-action
[cca-security]: https://github.com/anthropics/claude-code-action/blob/main/docs/security.md
[cca-limits]: https://github.com/anthropics/claude-code-action/blob/main/docs/capabilities-and-limitations.md
[cc-local]: https://code.claude.com/docs/en/code-review-local
[cc-review]: https://code.claude.com/docs/en/code-review
[cc-customize]: https://code.claude.com/docs/en/code-review-customize
[cc-costs]: https://code.claude.com/docs/en/code-review-costs
[cc-legal]: https://code.claude.com/docs/en/legal-and-compliance
[cc-actions]: https://code.claude.com/docs/en/github-actions
[cr-pricing]: https://www.coderabbit.ai/pricing
[cr-faq]: https://docs.coderabbit.ai/faq
[cr-github]: https://docs.coderabbit.ai/platforms/github-com
[cr-request]: https://docs.coderabbit.ai/pr-reviews/request-changes-workflow
[cr-yaml]: https://docs.coderabbit.ai/getting-started/yaml-configuration
[cr-config]: https://docs.coderabbit.ai/reference/configuration
[cr-tools]: https://docs.coderabbit.ai/tools/list
[cr-learn]: https://docs.coderabbit.ai/guides/learnings
[pa-readme]: https://github.com/The-PR-Agent/pr-agent
[pa-faq]: https://github.com/The-PR-Agent/pr-agent/blob/main/docs/docs/faq/index.md
[pa-config]: https://github.com/The-PR-Agent/pr-agent/blob/main/docs/docs/usage-guide/configuration_options.md
[pa-model]: https://github.com/The-PR-Agent/pr-agent/blob/main/docs/docs/usage-guide/changing_a_model.md
[gh-about]: https://docs.github.com/en/copilot/concepts/agents/code-review
[gh-use]: https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review
[ocr-readme]: https://github.com/alibaba/open-code-review
[ocr-ci]: https://github.com/alibaba/open-code-review/blob/main/pages/src/content/docs/en/integrations/ci.md
[ocr-delegate]: https://github.com/alibaba/open-code-review/blob/main/pages/src/content/docs/en/integrations/delegate.md
[ocr-post]: https://github.com/alibaba/open-code-review/blob/main/scripts/github-actions/post-review-comments.js
[kodus-readme]: https://github.com/kodustech/kodus-ai
[kodus-policy]: https://docs.kodus.io/en/how_to_use/code_review/policy.md
[kodus-config]: https://docs.kodus.io/en/how_to_use/code_review/configs/general.md
[bito]: https://docs.bito.ai/ai-code-review-agent/overview
[amazonq]: https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/code-reviews.html
[greptile-intro]: https://www.greptile.com/docs/introduction
[greptile-rules]: https://www.greptile.com/docs/code-review/custom-standards.md
[greptile-bench]: https://www.greptile.com/benchmarks
[bugbot]: https://cursor.com/docs/bugbot
[bugbot-page]: https://cursor.com/bugbot
[graphite]: https://graphite.com/docs/graphite-agent
[qodo-bench]: https://qodo.ai/ai-code-review-benchmark/
[entelligence]: https://entelligence.ai/code-review-benchmark-2026
[swe-prbench]: https://arxiv.org/abs/2603.26130
[swr-bench]: https://arxiv.org/abs/2509.01494
[cr-field]: https://arxiv.org/abs/2607.03316
[revmate]: https://arxiv.org/abs/2411.07091
[sun25]: https://arxiv.org/abs/2508.18771
