# Trust, cost and limits

This page holds the details behind the [Safety and cost](../README.md#safety-and-cost) and [Status and limits](../README.md#status-and-limits) sections of the README. [SECURITY.md](../SECURITY.md) has the full security model.

Contents:

- [Trust](#trust)
- [Cost](#cost)
- [Limits](#limits)

## Trust

- Run the reviewer on a machine only you use. The service runs as your user. It uses your `gh` login and your Claude Code login. It also uses the key of a GitHub App, if you set one up. Anyone who can act as that user can post as you.
- The reviewer reads three kinds of PR:
  - A PR from a branch of the repo itself.
  - A PR by a login in `PRREVIEW_GATE_TRUSTED_AUTHORS`.
  - A PR that you name with `prreview once --pr`.

  It skips every other fork PR. It posts nothing on a skipped PR.
- The model can only read. `--tools` limits Claude Code to `Read`, `Grep` and `Glob` in a worktree for each PR. A worktree is a separate working directory of git. The model has no shell and no web tools. Your code never runs.
- The prompt says that PR text is data. That is an instruction to the model. It is not a sandbox. The tool limits above hold if the model is tricked. They need Claude Code 2.1.305 or later. The reviewer checks `claude --version` at startup and refuses an older version.
- Every comment that carries PR text or model output is scanned against your sensitive-patterns file before the reviewer posts it. If the scan finds a match, or cannot run, a short notice replaces the comment. The notice does not quote the value.
- Model text is escaped before it is posted. In the summary, the findings and the other lists of the comment, an `@name`, a line that starts with `/command` or `bors`, and a line that looks like a finding get a zero-width space. A mention does not notify. A command does not act. A later round does not read the line as a finding. [SECURITY.md](../SECURITY.md) describes the limits of this escaping.
- A GitHub App token covers one repository. The reviewer asks for a token for the repository of the PR only.
- The reviewer posts what the model wrote. Your repo can have a bot that acts on comment commands such as `/lgtm` or `bors r+`. In that case, post as a GitHub App that the bot does not take commands from.

### Your Claude Code login

Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) says the advertised Pro and Max limits "assume ordinary, individual usage". The page gives no number (read 2026-10-21). Anthropic decides whether an always-on poller counts.

An API key avoids the question. A key set in your shell does not reach the background service. Run `prreview run` from a terminal that has the key. See [Where to run it](operations.md#where-to-run-it).

## Cost

### When a round starts

- Every push to the PR starts a new round at once.
- An edit of the PR title, description or base branch also starts a round. So does a push to the parent branch of a stacked PR. When the head is unchanged, these last two cases wait until the last comment of the reviewer is 10 minutes old (`PRREVIEW_GATE_PR_COOLDOWN_MIN`).

### Model calls in one round

One round can make these model calls:

- One review call for each slice. A slice is a part of the diff of about 250 lines. A round has up to 8 slices.
- A second review call for each slice. This happens in a first round on a diff of 1000 lines or more, and in the first round of a split-exempt PR ([definition](operations.md#how-one-round-works)).
- One refutation call for each blocking finding, up to 6.
- One repair call.

The largest first round makes 16 review calls, 6 refutation calls and 1 repair call. No test run has covered that case. Its cost is unknown.

### Cost of test runs

The runs below took place in September and October 2026. The dollar figure is what `claude -p` reports. On a subscription, it counts against your usage limits and not against a bill.

| Run | What was reviewed | Cost |
| --- | --- | --- |
| A | The demo PR. See [the demo](demo.md) | Round 1: $0.54. Three rounds: $1.14 |
| B | A second test PR | $0.75. A push that changed nothing then cost $0.73 |
| C | A small clean PR, with the red team on | Review $0.34. The red team added $0.23 |

The red team is an optional step that argues against an approval. See [Optional: a red team before an approval](operations.md#optional-a-red-team-before-an-approval).

## Limits

- The reviewer reads code and nothing else. It does not run your tests. It does not read your CI results.
- A verdict is a comment. It is not a GitHub review state. The Approved comment says "Automated review, not a GitHub approval."
- No one has counted how many bugs it finds or how many false alarms it raises.
- It works with GitHub only. It pauses while the machine sleeps. Only the maintainer's own machine checks WSL2. See [windows.md](windows.md).
- Bedrock, Vertex and gateways are not tested.
- The reviewer sends the code of each PR to Anthropic. Do not use it on code that may not go to Anthropic.
- Two known limits are listed in [Known limits](../SECURITY.md#known-limits).

The reviewer fits poorly in three cases:

- Several people share one Claude login.
- You need a required check that blocks a merge.
- The code may not go to Anthropic.

[comparison.md](comparison.md) compares the reviewer with other tools and says when another tool fits better.
