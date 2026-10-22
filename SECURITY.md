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
author and the `isCrossRepository` field of each open PR with one `gh pr list`
call. A PR that `prreview once --pr` names is read, whatever its other fields
hold, when its number is a whole number. Any other PR is read only when its
record holds a number, a boolean `isCrossRepository`, an author object and a
non-empty login, and either `isCrossRepository` is false or the login is in
`PRREVIEW_GATE_TRUSTED_AUTHORS`. A missing field or a wrong type means the PR is
not trusted, even when its author is on the list. A PR whose author account was
deleted can come back with no login. The reviewer then skips it, unless
`prreview once --pr` names it. The review job checks the same rule on its own
read of the PR, before any model call. The reviewer posts nothing on a skipped
PR and logs its number only. One exception exists. With
`PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, the reviewer turns off an auto-merge that
is armed on a skipped PR, with one `gh pr merge --disable-auto` call and nothing
else. Only a user with write access can arm auto-merge, so a stranger cannot
cause that write. The list is the point where trust is decided. If a PR turns
into a fork PR after the list, the dispatcher reads it once with `gh pr view`,
and the job stops it before the diff fetch. That PR gets no model call and no
post. With the same setting, the job turns off its auto-merge. The loop that
starts the rounds counts only the PRs this rule admits, so one open fork PR from
a stranger no longer starts a full round, merged-PR scan included, every minute.
With `PRREVIEW_GATE_DISARM_AUTO_MERGE=1`, a skipped fork PR with armed
auto-merge counts as work too, so the disarm runs within one interval. The scan
of merged PRs does not look at the author. `PRREVIEW_GATE_FORK_PRS=1` turns the
rule off. The rule assumes that everyone who can push to the repository is
trusted. A repository whose workflows build branches from outside input, for
example with `pull_request_target`, breaks that assumption. Do not list an
account only because it contributed once. The list lives in the settings of the
machine that runs the reviewer.

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

**The default branch sets the rules.** The review tree is the PR's merge base
with the diff applied. Convention files (`CLAUDE.md`, `CLAUDE.local.md`,
`AGENTS.md`, `.mcp.json`, `.claude/`, README, CONTRIBUTING and
`.github/review-checks.md`) come from the newest commit of the default branch
for every PR, matched in any letter case. The copy comes after the diff is
applied. A file the default branch lacks is removed, and a file only the
default branch has is added. This also covers a PR based on another branch,
whose parent branch is not protected. If a step of the copy fails, the PR is
not reviewed that round. A file outside this list stays as the PR has it. An
old branch is reviewed with today's rules, and there is no switch to turn that
off. The author's branch is never checked out.

**Comments with PR text or model output are scanned.** Every comment that
carries PR text or model output is checked against the operator's
sensitive-patterns file before it is posted. A match, or a scan that cannot
run, means it is not posted. Two fixed notices carry neither and are not
scanned: the notice that a title, description or linked issue matched the scan,
and the title-format reminder. The reviewer will not start without that file.
The scan matches your patterns against the text as written. Text shaped to
slip past it, such as a key split by an HTML entity or by a zero-width
character other than U+200B, is not caught, so treat it as a safety net for
accidents.

**What the model writes is escaped before it is posted.** A pull request can
steer the model's words, and those words go out under the reviewer's login.
In the summary, the findings, the follow-up tickets, the refutation notes and
the list of unverified items, the reviewer puts a zero-width space into four kinds of text:

- An `@name` that GitHub would turn into a mention. An `@` inside a closed
  fenced code block stays as it is, because it is code.
- A line that starts with `/command` or with `bors`, which a bot can read as
  a command.
- The words `Automated review:` before a verdict emoji, which look like the
  banner of the reviewer.
- A line that starts with `- **HIGH**`, `- ~~**` or the like, which the next
  round would read as a finding of this round.

The text keeps its look. The sensitive-data scan reads the text without those
spaces. Links and images are not changed. The file path of a finding is not
changed either, because the next round reads the path back from the comment,
so a path that holds `@name` is posted as it is. This does not make a bot safe.
If a bot in your repository acts on commands in comments (`/lgtm`, `/approve`,
`bors r+`), run the reviewer as a GitHub App that bot does not take commands
from, not as a person it trusts.

**A comment from another App that carries the marker does not stop a
review.** The marker of a head is computable from public fields, and a bot
that repeats text can print it. The reviewer writes a warning to the log and
reviews the head. Only comments from the reviewer's own login count as its
earlier reviews.

If a wrong list of App logins (`PRREVIEW_REVIEW_APP_SLUG`) hides the
reviewer's own comments, the same review would repeat every round. So the
reviewer keeps a count on the machine: one line in its hold directory for each
verdict it posted for a head. At two verdicts for one head, it treats the head
as handled: no review, no model call, and one `WARNING:` line in the log that
names the setting. No comment author can raise this count, because the
reviewer writes it only after its own post. An App that prints the marker
cannot stop a review. The guard on an armed auto-merge still runs for such a
head.

The count has limits. The file stays while its PR is open and expires two days
after the PR closes. A repo with 1000 or more open PRs keeps all its count
files until the list is shorter, because the list may omit an open PR. If
the hold directory cannot be written, the reviewer
skips the PR before any model call and the round fails. If a record fails after
a post, the post stays and the round fails. In both cases the failure alert
runs. A person who deletes the reviewer's
comments to ask for a new review gets two before the bound stops it. After a
switch from an App back to your own account, a head that the machine posted for
twice stays stopped until its author pushes again.

**The App token is for one repository.** When the reviewer posts as a GitHub
App, it asks for an installation token for the repository of the PR only, and
not for every repository the App is installed on.

**Refutation is not a security control.** The refutation step can only remove
blocking findings. Against an author who writes the diff to fool the model, it
pushes the verdict toward approve. The red-team pass, which is off by default,
is the only step that argues against an approve. Refutation reduces false
positives. It does not stop a diff that was written to fool the model.

**It cannot merge.** It never approves or merges. Its only merge call is
`gh pr merge --disable-auto`, which is off by default. With the defaults it
leaves auto-merge alone. `PRREVIEW_GATE_DISARM_AUTO_MERGE=1` lets it turn off
an auto-merge armed on a head it has not reviewed yet. That includes a PR it
skips because of its author. A head that an earlier `prreview once --pr`
reviewed loses its auto-merge too, because the PR list does not show that
review.

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

**The cooldown limits edits, not pushes to the PR branch.** An edit of a PR's
title, description or base branch changes the review key and asks for a new
review. When the head is the same, the reviewer waits until its last comment on
the PR is `PRREVIEW_GATE_PR_COOLDOWN_MIN` minutes old (10 by default, 0 turns
it off). Repeated edits then cost one review per cooldown. A push to the PR
branch is never delayed, so an account that can push can still start one
review per push. The cooldown compares only the PR head. For a stacked PR, a
push to the parent branch leaves the head the same and can wait up to the
cooldown. `prreview once
--pr` ignores the cooldown. The wait uses the time of the reviewer's last
comment on the PR. It keeps no file. If that time cannot be read, the PR is
reviewed.

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
