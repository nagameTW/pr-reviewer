# Security policy

The reviewer passes the text of pull requests to a model that can read files,
and then posts the result under your GitHub account. By default it reads only
PRs from branches of the repository itself and PRs from authors you list. So
the security model is worth stating plainly.

## Reporting a vulnerability

Report privately through GitHub's security advisories:

**https://github.com/nagameTW/pr-reviewer/security/advisories/new**

Please do not open a public issue for a security problem. Expect a first
response within a few days. Once there is a fix, I will agree on the
disclosure timing with you.

The useful details are the commit you ran, the `PRREVIEW_*` settings that differ
from the defaults, and a pull request (title, description and diff) that
reproduces it. Redact tokens, hostnames and anything your sensitive-patterns
file would have caught before you send it.

## Supported versions

The project is pre-1.0, so only the latest commit on `main` gets fixes.

## The security model

These hold by design. If you can break one, that is a vulnerability.

**Fork PRs are skipped unless the author is trusted.** The reviewer reads the
author and the `isCrossRepository` field of each open PR with one
`gh pr list` call. It reads a PR when the field is false, when the author is in
`PRREVIEW_GATE_TRUSTED_AUTHORS`, or when `prreview once --pr` names the PR.
The review job checks the same rule on its own read of the PR, before any
model call. A missing or unreadable field means the PR is not trusted. The
reviewer posts nothing on a skipped PR and logs its number only.
`PRREVIEW_GATE_FORK_PRS=1` turns the rule off. The rule assumes that everyone
who can push to the repository is trusted. A repository whose workflows build
branches from outside input, for example with `pull_request_target`, breaks
that assumption. Do not list an account only because it contributed once. The
list lives in the settings of the machine that runs the reviewer.

**The pull request is data.** The model reads titles, descriptions, diffs and
repository files with its read-only tools, and the prompt says that none of
that text is an instruction. PR text placed in the prompt itself sits between
markers with a new random value every round, so it cannot close its block
early. This is an instruction to the model, not a sandbox; the tool limits
below are what hold if the model is fooled.

**The model can only read, and only the review clone.** Claude Code runs
headless with `--tools "Read,Grep,Glob"`, so no other built-in tool, a shell
and web tools included, exists in the session. Each of the three is limited
to the review clone, plus `Read` on the round's own scratch copies of the diff
and of the PR's title and description (with the title and body of the issue
the PR links, when it links one). The output-repair call gets no tool
(`--tools ""`). With `--restricted`, Claude Code itself confines the file
tools to the review clone and the call's private directories. Each of those
holds only the call's diff or slice, or the PR's title and description, so a
call cannot read another PR's scratch files or another slice's scratch diff.
A slice review can still read every source file in the review clone. Every
call also gets `--strict-mcp-config` and `--disallowedTools "mcp__*"`, so no
MCP server starts, and `--disable-slash-commands`, so no skill or command from
the reviewed repo loads. The reviewer passes an empty `--setting-sources`, so
Claude Code loads no user, project or local settings file. The check of the
tool set on Claude Code 2.1.305 did not test this flag. These flags need
Claude Code 2.1.305 or later. The reviewer checks `claude --version` at
startup and refuses an older version.

Every prompt goes to Claude Code on stdin, never on the command line, so
other users of the machine cannot read it in the process list. The `claude`
process starts with `GH_TOKEN`, `GITHUB_TOKEN`, `GH_ENTERPRISE_TOKEN` and
`GITHUB_ENTERPRISE_TOKEN` empty. That is defense in depth only: the model has
no shell to read its environment with.

Checked on Claude Code 2.1.305 with these flags: the session's tool list was
exactly `Glob`, `Grep` and `Read`, with no MCP server, skill or slash command.
A `Bash` call got "No such tool available", and a `Read` outside the clone
was refused. Before these flags, `Bash` was in the tool set. In the same
check, the shell commands `ls`, `cat`, `git log` and `git show` ran inside the
clone without an allow rule.

**The merge base sets the rules.** The review tree is the PR's merge base with
the diff applied, and convention files such as `CLAUDE.md` are read as they are
at the PR's merge base. For a PR based on another branch, the merge base is on
that branch, so each convention file the tree has is replaced with the default
branch's version, or removed when the default branch does not have it. A file
that only the default branch has is not added. If a step of the replacement
fails, the PR is not reviewed that round. The match is exact in file name
case, so a PR's edit to a differently cased file such as `readme.md` is not
restored. The author's branch is never checked out.

**Comments with PR text or model output are scanned.** Every comment that
carries PR text or model output is checked against the operator's
sensitive-patterns file before it is posted. A match, or a scan that cannot
run, means it is not posted. Two fixed notices carry neither and are not
scanned: the notice that a title or description matched the scan, and the
title-format reminder. The reviewer will not start without that file.
The scan matches your patterns against the text as written. Text shaped to
slip past it, such as a key split by an HTML entity or a zero-width
character, is not caught, so treat it as a safety net for accidents.

**What the model writes is posted as written.** A pull request can steer
the model's words, and those words go out under the reviewer's identity. If a
bot in your repository acts on commands in comments (`/lgtm`, `/approve`,
`bors r+`), run the reviewer as a GitHub App that bot does not take commands
from, not as a person it trusts.

**Refutation is not a security control.** The refutation step can only remove
blocking findings. Against an author who writes the diff to fool the model, it
pushes the verdict toward approve. The red-team pass, which is off by default,
is the only step that argues against an approve. Refutation reduces false
positives. It does not stop a diff that was written to fool the model.

**It cannot merge.** It never approves or merges. Its only merge call is
`gh pr merge --disable-auto`, which is off by default. With the defaults it
leaves auto-merge alone. `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` lets it turn off
an auto-merge armed on a head it has not reviewed yet.

**Scratch files stay private.** Diffs, slices and raw model output are written
under the reviewer's own work directory, not a shared `/tmp`.

## Known limits

**The review key of a PR into the default branch does not include the base
commit.** The reviewer does not review a PR again while its review key stays
the same. The key holds the head commit, the title, the description and the
base branch name. For a PR based on another branch, it also holds the base
commit, so a push to the parent branch starts a new review. For a PR into the
default branch, it does not. If commits from the PR's own history reach the
default branch through another PR, the PR's net change can differ from the
reviewed one, and no new review runs. For example, the head history of the
PR is M, C, H. M is the merge base, C adds a change, and H reverts C, so the
net diff of the PR is empty. When C reaches the default branch through
another PR, the merge base moves to C and the net diff becomes the revert of
C. The head commit H, the title, the description and the base branch name
have not changed, so the key stays the same and no new review runs. Version
0.3.0 will add the merge base commit ID to the key of every PR.

## In scope

- A PR from a fork, by an author who is not trusted, that reaches a model call
  without `prreview once --pr` and without `PRREVIEW_GATE_FORK_PRS=1`.
- Text in a pull request that makes the reviewer post something it should not:
  content from outside the repository, text the sensitive-data scan should
  have caught, or instructions followed as if they came from the operator.
- A way for the model to read outside the review clone, or to run a command.
- A pull request that gets itself reviewed against conventions it changed.
- A comment by someone other than the reviewer's account that the reviewer
  mistakes for its own earlier verdict.

## Out of scope

- The model being wrong about the code. A missed bug or a false finding is a
  bug report, not a vulnerability.
- Anything that needs control of the machine the reviewer runs on, or of the
  `gh` and `claude` credentials the operator gave it.
- Claude Code, `gh` and GitHub themselves. Report those upstream.
- Someone with write access to the repository editing or deleting the
  reviewer's comments. The reviewer keeps what it has reviewed in those
  comments, so such a person can make a head look reviewed or hide a verdict;
  they can also push and merge, which is the larger power. Use branch
  protection for what must not be bypassed.
