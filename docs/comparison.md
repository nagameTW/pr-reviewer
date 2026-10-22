# How pr-reviewer compares

This page puts pr-reviewer next to the tools people most often ask about. It lists facts that a reader can check. It does not list price or review quality, because no measurement of pr-reviewer's detection rate exists yet.

The rows for other tools come from the maintainer's research notes, written in October 2026. Nobody re-read each project's page for this release, and the rows link only to home pages. Tools change. Check the project's own documentation before you rely on a row. "Not stated" means the notes found no statement. It does not mean "no".

## The short version

pr-reviewer is a poller that you run on your own machine. It needs your `gh` login and your Claude Code login. It needs no workflow file, no GitHub App, no webhook and no repo admin rights. In return, it works only while the machine is on, and it only works on GitHub.

Pick another tool when you need one of these:

- A review that runs on GitHub's runners, so it does not depend on your computer being on.
- A required check that blocks a merge. pr-reviewer only comments.
- A platform other than GitHub. pr-reviewer uses `gh`.
- A chat-style helper that you can ask follow-up questions inside the PR.
- A reviewer that a whole team shares. One Claude Code login is for one person, and pr-reviewer is meant for a machine that only you use.

## Facts side by side

| Tool | Where it runs | What it needs to install | Can it approve or merge | Rule files come from |
| --- | --- | --- | --- | --- |
| pr-reviewer | Your machine, by polling once a minute | `gh` and Claude Code logins. No admin rights | No. It comments. Its only merge call is `gh pr merge --disable-auto`, off by default | The default branch, for every PR |
| [claude-code-action](https://github.com/anthropics/claude-code-action) | A GitHub Actions runner | A workflow file and a secret in the repo | Its tag mode can commit and push | A fixed list, read from the base branch |
| Claude Code `/code-review` | Your terminal, in one session you start by hand | Claude Code only | Not stated | Not stated |
| [CodeRabbit](https://www.coderabbit.ai/) | The vendor's service | The vendor's GitHub app | Not stated | Its `.coderabbit.yaml` is read from the feature branch |
| [Qodo PR-Agent](https://github.com/qodo-ai/pr-agent) | Your CI | A workflow file, plus a model provider key | Not stated | The default branch |
| [GitHub Copilot code review](https://docs.github.com/en/copilot) | GitHub | A Copilot plan | Not stated | Instructions are read from the head branch |

## What the model can do

| Tool | Tools the model has in a review |
| --- | --- |
| pr-reviewer | `Read`, `Grep` and `Glob`, set with `--tools`. No shell, no web, no MCP server. Needs Claude Code 2.1.305 or later |
| claude-code-action | Tag mode has file edit and git commit wrappers |
| Claude Code `/code-review` | Not enforced as read-only |
| CodeRabbit | Its docs say it can run shell commands and static analysis |
| Qodo PR-Agent | Each PR-Agent tool is one model call with no tools |
| GitHub Copilot code review | Its docs list GitHub MCP and Playwright MCP as on by default |

## Login

pr-reviewer uses the `claude` CLI with your own Claude Code login. `prreview setup` checks it with `claude auth status`. It reads and stores no Claude credential.

Whether an always-on reviewer counts as ordinary individual use of a subscription is Anthropic's call. The terms have changed more than once. Read the current terms before you leave it running. An API key avoids the question. Claude Code reads `ANTHROPIC_API_KEY` from the environment of the process that runs it, and the background service does not get the variables of your shell.

claude-code-action can take an OAuth token for a subscription, but it needs a workflow file and a secret. The PR-Agent docs describe a model provider key. They do not describe a subscription login.

## Where pr-reviewer is weaker

- It runs only on GitHub, and only while the machine is on and awake.
- It posts as your own `gh` account unless you set up a [GitHub App](github-app.md).
- It comments only. It cannot gate a merge.
- Nobody has counted how many bugs it finds or how many false alarms it raises.
- It does not strip hidden content from PR text. A zero-width character or an HTML comment in a PR description reaches the prompt as written. The prompt wraps PR text in markers with a random value and tells the model that the text is data. SECURITY.md says plainly that this is an instruction to the model, not a sandbox.
- Its protection depends on the Claude Code version. The tool limits need 2.1.305 or later.

## Where it differs on purpose

- It sends every blocking finding through a second model call that tries to refute it. This lowers false alarms. It is not a security control, because it can only remove findings. See [SECURITY.md](../SECURITY.md).
- It scans each comment that carries PR text or model output against your own sensitive-data patterns file before it posts. A hit, or a scan that cannot run, means nothing is posted. The patterns are your own regex list, so the scan catches accidents and nothing more.
- It posts a verdict as a comment, labeled as an automated review. It never submits a GitHub approval.
