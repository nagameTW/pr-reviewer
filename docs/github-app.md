# Posting as a GitHub App

By default the comments come from the account that `gh` is logged in as. With a
GitHub App, they come from `<app-name>[bot]` instead. So people can tell them
apart from comments of people. The token that posts then carries only the
permissions of the App, not those of your account.

`prreview setup` walks through it at the "Who posts" step:

1. It prints a link that opens the "Register new GitHub App" page of GitHub, with
   the fields filled in. The App has no webhook and is private. It has these
   repository permissions:
   - **Pull requests: read and write**, to read PRs and post the review.
   - **Issues: read and write**. A comment on a PR is an issue comment in the API
     of GitHub. `PRREVIEW_GATE_TICKETS=1` opens issues.
   - **Metadata: read**, which GitHub adds to every App.

   For the App of an organization, take that same link. Change only its start,
   `https://github.com/settings/apps/new`, to
   `https://github.com/organizations/<org>/settings/apps/new`. Keep everything
   after the `?`. It sets the permissions and turns the webhook off. A bare URL
   opens an App with no permissions, and the first comment then fails.
2. On the page of the App, note the **App ID**. Click **Generate a private key**.
   Install the App (**Install App**) on every account or organization that owns a
   repository you review. GitHub lets you install a private App only on the
   account that owns it. Your repositories can belong to more than one account or
   organization. In that case, make the App public under **Advanced** on its
   settings page first. That lets other accounts install it. Each installation
   still sees only the repositories it is given.
3. Give `prreview setup` the App ID and the downloaded `.pem` file. It copies the
   key to `~/.config/pr-reviewer/app.pem`. Only you can read that copy. It checks
   that the App can see every listed repository. It names each repository that
   the App cannot see. It gives the link to install the App there or to add the
   repository to it. An App installed on "Only select repositories" sees only
   those.

Only posting goes through the App. This covers comments and the follow-up issues
that `PRREVIEW_GATE_TICKETS=1` opens. Reading PRs, cloning, the alert issues of
the loop and `PRREVIEW_GATE_DISARM_AUTO_MERGE` still use `gh`. So `gh` must stay
logged in. To go back to your own account, run `prreview setup` and pick 1 at
"Who posts".

Switching from your account to an App changes whose comments count as comments of
the reviewer. The next round finds no comment from the App on any open PR. It
reviews every open PR again. Switching back leaves alone the heads that the App
already commented on. It logs a warning for each of them in every round until its
author pushes again.
