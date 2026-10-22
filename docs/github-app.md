# Posting as a GitHub App

By default the comments come from the account `gh` is logged in as. With a
GitHub App they come from `<app-name>[bot]` instead, so they are easy to tell
apart from people's comments. The token used for posting then carries only
the App's permissions, not your account's.

`prreview setup` walks through it at the "Who posts" step:

1. It prints a link that opens GitHub's "Register new GitHub App" page with
   the fields filled in: no webhook, private, and these repository
   permissions:
   - **Pull requests: read and write**, to read PRs and post the review.
   - **Issues: read and write**. A comment on a PR is an issue comment in
     GitHub's API, and `PRREVIEW_GATE_TICKETS=1` opens issues.
   - **Metadata: read**, which GitHub adds to every App.

   For an organization's App, take that same link and change only its start,
   `https://github.com/settings/apps/new`, to
   `https://github.com/organizations/<org>/settings/apps/new`. Keep everything
   after the `?`: it sets the permissions and turns the webhook off. A bare
   URL opens an App with no permissions, and the first comment then fails.
2. On the App's page, note the **App ID**, click **Generate a private key**,
   and install the App (**Install App**) on every account or organization
   that owns a repository you review. GitHub lets a private App be installed
   only on the account that owns it. If your repositories belong to more than
   one account or organization, make the App public under **Advanced** on its
   settings page first. That lets other accounts install it; each
   installation still sees only the repositories it is given.
3. Give `prreview setup` the App ID and the downloaded `.pem` file. It copies the
   key to `~/.config/pr-reviewer/app.pem`, readable only by you, and
   checks that the App can see every listed repository. One it cannot see
   is named, with the link to install the App there or add the repository
   to it (an App installed on "Only select repositories" sees only those).

Only posting goes through the App: comments, and the follow-up issues
`PRREVIEW_GATE_TICKETS=1` opens. Reading PRs, cloning, the loop's alert issues and
`PRREVIEW_GATE_DISARM_AUTO_MERGE` still use `gh`, so `gh` still needs to be logged
in. To go back to your own account, run `prreview setup` and pick 1 at "Who posts".

Switching from your account to an App changes whose comments count as the
reviewer's own: the next round finds no comment from the App on any open PR
and reviews every one of them again. Switching back leaves alone the heads the
App already commented on, and logs a warning for each of them every round
until its author pushes again.

