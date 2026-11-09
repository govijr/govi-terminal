# GitHub and Linear

Open **Tasks** using the list button in the toolbar, or **Tasks — GitHub and
Linear** in the command palette. Account setup is also in **Settings →
Connections**. Terminals keep running underneath the Tasks pane.

## Connect

- **GitHub:** install [GitHub CLI](https://cli.github.com/), run
  `gh auth login --hostname github.com`, then choose **Connect GitHub**.
  Tasks → Connections can open sign-in in a new terminal when the CLI is
  installed. Govi uses the CLI's authentication and never copies its token.
  Disconnecting Govi leaves other tools' sign-in intact.
- **Linear:** create a personal API key in Linear's account security settings
  and enter it in the secure field. Govi verifies the account before storing the
  key in a bundle-specific Keychain item. Read permission loads issues; Write
  and Create comments permissions enable their respective actions. Restrict
  the key to the teams you need. Disconnect removes Govi's saved key. Revoke
  the key in Linear if it should no longer work anywhere.

This version uses GitHub CLI and Linear's GraphQL API. It needs no hosted Govi
service and does not change agents' MCP configuration. A branded Linear OAuth
sign-in requires registering a Govi OAuth application; personal-key setup is
the working authentication path in this version.

## Start from an issue

1. Select GitHub or Linear. GitHub initially uses the focused checkout's origin;
   another owner/repository can be entered. Toggle Assigned to me and refresh.
2. Select an issue, or open it by GitHub number / Linear identifier. Review or
   edit the brief containing its description and recent comments.
3. Choose a local checkout and an installed Claude Code, Codex, Cursor or Pi.
   Other agents can use Copy Brief and the existing launcher.
4. For new issues, optionally create a worktree and review the branch name.
   It starts at the checkout's current HEAD. GitHub tasks require an origin
   matching the source repository. Linear remembers the checkout per team.
5. Start Agent opens a new workspace with the brief as its initial prompt.
   The issue remains linked above the terminal and in recovery metadata.
   Returning to Tasks fetches fresh source content. Recovery never resends
   the initial prompt or repeats a remote action.

Account keys are not put in prompts or added to agent environments. The brief
goes to the selected agent/provider when launched. Govi persists issue references
and local repository mappings; full remote content stays in memory. Agent tools
can retain prompts in their own histories.

## Review and share results

- Pull Requests shows open GitHub PRs, check results and review decisions.
  Use Review Feedback as Task includes general and inline review comments in
  a brief. Choose an existing checkout of the PR's head branch. This action
  does not fetch or switch branches automatically.
- New Pull Request uses the focused terminal's repository and branch. Review
  the title, base, body and draft setting. Commit and push from Changes first.
  Govi checks that the branch is unchanged and GitHub has the same commit.
  Creation never pushes, forks or merges automatically.
- Post Comment sends the displayed comment to the selected issue or PR.
  Linear's Update Status applies the chosen team workflow state. Agent completion
  never posts a comment or changes issue status automatically.
- Mutation requests are never retried automatically. If a connection times out,
  check the service before sending again.

GitHub.com is supported; GitHub Enterprise is not included. Lists load up to
100 open issues or 50 open PRs. Direct lookup can open issues outside the list,
including closed issues. Briefs are limited to 30,000 characters and shorten long
descriptions/comments. Open the source for complete history. These are local
workspaces, not cloud agents or remote triggers.

## Validation

Run `./govi/test-integrations.sh` from the app folder. It uses isolated GitHub CLI
and Linear HTTP fixtures and temporary Git repositories, without live accounts
or remote writes. It covers URL/argument validation, old recovery compatibility,
partial GraphQL errors, read/write requests, check formats, inline comments,
private draft cleanup, quoting, unpushed branches and branch changes.

References: [GitHub CLI](https://cli.github.com/manual/),
[Linear API](https://linear.app/developers/graphql),
[Linear authentication](https://linear.app/docs/api-and-webhooks).
