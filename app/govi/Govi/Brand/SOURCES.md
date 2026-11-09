# Brand assets and usage integration references

- GoviWordmark.png: original image supplied by the user. Rendered as a theme-tinted mask without redrawing the lettering.
- Claude, Codex/OpenAI, Cursor, Grok, OpenCode glyphs: vinzdg/codenotch, commit 183fc2f835dbe46855cf1bf0f7c03e05d5f811c8, windows/codenotch/glyphs. Original brands retain their marks. MIT notice included in ../Licenses/CodeNotch-LICENSE.txt.
- Pi: official earendil-works/pi repository, apps/p2/public/icons/favicon.svg.
- Usage endpoint and credential-format references: https://github.com/vinzdg/codenotch/tree/183fc2f835dbe46855cf1bf0f7c03e05d5f811c8/Sources/Providers . Govi has an independent, narrower read-only integration. It does not install CodeNotch or invoke model requests.
- Codex usage semantics: https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt (the provider reports consumed percentages).
- Claude Code's built-in `/usage` report: https://code.claude.com/docs/en/costs#using-the-usage-command . Govi prefers the installed CLI in print mode, with hooks, tools, MCP servers and session persistence disabled; OAuth usage is a fallback when the CLI cannot report limits.
- Grok credit usage and current-period fields: https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-shell/src/extensions/billing.rs .

Usage support: Claude CLI/OAuth windows, Codex primary/secondary/additional windows, Cursor plan percentages/spend limits, Grok credit percentages, OpenCode Go windows. Every provider uses remaining capacity: full rings mean 100% available, empty rings mean none. Hover percentages carry a "left" caption, and tooltip/accessibility values use the same "% left" wording for every provider. The outer ring follows the primary/session window, with a secondary/weekly window on the inner ring; all windows and supplied reset times are listed in the tooltip. Pi has no aggregate quota. Expired credentials are renewed by the user's CLI, not overwritten by Govi. Connected accounts retain an unavailable indicator when a refresh fails before the first reading. OAuth tokens and raw usage responses are not logged, persisted, or sent to other providers.
