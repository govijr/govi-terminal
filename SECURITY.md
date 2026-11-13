# Security policy

## Reporting a vulnerability

Please don't report security problems in public issues, discussions or pull
requests.

Report them privately through GitHub instead:

1. Go to the [Security tab](https://github.com/govijr/govi-terminal/security) of this repository.
2. Choose **Report a vulnerability**.
3. Describe the problem, how to reproduce it, and what an attacker could do
   with it.

You should get a reply within 7 days. We'll keep you updated while we work on
a fix, and credit you in the release notes unless you'd rather stay anonymous.

## Supported versions

Govi hasn't had a numbered release yet. Security fixes go to the `main`
branch.

## Scope

Govi runs terminals, shells and coding agents with your user account's
permissions, so these are especially important:

- the local control socket and the `govi` CLI and MCP server,
- the inline suggestion socket and the shell integration,
- the agent hook helper (`govi-notify`),
- handling of GitHub, Linear and Jev credentials stored in Keychain,
- remote host connections and host-key handling,
- the browser and editor panes.

Problems in the Ghostty terminal engine that also affect Ghostty should be
reported to [Ghostty](https://github.com/ghostty-org/ghostty/security) as
well.
