# Agent Usage

A native macOS menu bar app that shows how much is left of your AI coding
agents' plans — Claude Code, Codex, GitHub Copilot, Cursor and OpenCode Go —
at a glance. It is a native port of five providers from the
[Agent Usage](https://github.com/raycast/extensions/tree/main/extensions/agent-usage)
Raycast extension, without Raycast running underneath it.

## Use

- The menu bar shows a gauge icon. Hover it for each agent's number.
- **Click** for a Liquid Glass panel with a card per agent account: plan, the
  headline percentage, a bar per limit with its reset time, and extra facts
  (credits, reset credits, extra usage). **Right-click** for every agent's number
  in a menu, Refresh All, Settings and Quit.
- Numbers refresh every 15 minutes (5, 15, 30 or 60 in Settings), and when the
  panel opens if they are more than two minutes old. `⌘R` refreshes in the panel.
- An optional global shortcut shows and hides the panel from any app.

The headline is the binding constraint, as in the extension: the tightest
window that limits what the account can actually spend. Colours follow it:
green from 50 %, amber from 20 %, red below.

## Agents

| Agent | Where the numbers come from | Setup |
|---|---|---|
| **Claude Code** | Anthropic's OAuth usage endpoint, with Claude Code's own login (keychain, or `~/.claude/.credentials.json`) | Run `claude` and sign in |
| **Codex** | ChatGPT's Codex usage endpoint, for every login in `~/.codex` (`auth.json` and `accounts/*.auth.json`) | Run `codex login`; add more Codex homes in Settings |
| **GitHub Copilot** | GitHub's `copilot_internal/user` endpoint | `gh auth login`, or `GITHUB_TOKEN`/`GH_TOKEN` in your shell, or a token in Settings |
| **Cursor** | cursor.com's dashboard API, with the login Cursor.app keeps | Sign in to Cursor.app, or paste a cursor.com Cookie header in Settings |
| **OpenCode Go** | The workspace's Go page on opencode.ai (there's no API) | Workspace ID and `auth` cookie in Settings |

Each agent can be switched off in Settings → Agents. Tokens you enter (Copilot,
Cursor's and OpenCode Go's cookies) are kept in the login keychain.

Details carried over from the extension:

- **Claude**: an expired access token is refreshed and written back to where
  Claude Code keeps it, so both stay signed in. The keychain is read through
  `/usr/bin/security`, as the extension did, so the keychain item's existing
  access grant keeps working. Model-scoped weekly limits (Opus, Sonnet, …) and
  extra usage are shown when the plan has them.
- **Codex**: 5-hour, weekly and code-review windows, additional per-model limits,
  credits and rate-limit reset credits. Several logins appear as separate cards.
- **Copilot**: AI credits (premium requests) and chat. The same token found in
  several places is one account.
- **Cursor**: total plan usage with the Auto and API pools, or request counts on
  older plans; on-demand spend (yours and the team's). The headline is the
  tighter of Auto and API.
- **OpenCode Go**: rolling (2 h), weekly and monthly usage; monthly is the headline.

### Moving over from the Raycast extension

Most agents need nothing: they read the same local logins the extension did. Copy
the **OpenCode Go workspace ID and auth cookie**, a **Copilot token** or **Cursor
cookie** if you had set one, and any **additional Codex homes** from Raycast → Settings → Extensions →
Agent Usage into Settings → Agents.

## Build

Requires macOS 14+ and Xcode (Swift 6 toolchain). Liquid Glass needs macOS 26;
older systems get a material fallback.

```sh
swift test               # parsing for all five agents, account discovery
./Scripts/bundle.sh      # → build/AgentUsage.app, installed in /Applications
```

`bundle.sh` wraps the binary in an `.app`, signs it with your Developer ID or
Apple Development certificate (falling back to ad-hoc; set `CODESIGN_IDENTITY`
to choose one) so its keychain items survive rebuilds, and installs it over
`/Applications/AgentUsage.app`, quitting and relaunching a running copy. Pass
`--no-install` to stop at `build/`. The icon is drawn by
`swift Scripts/make-icon.swift`.

## License

[GPL-3.0-or-later](LICENSE). The provider logic and agent icons are ported from
the MIT-licensed Agent Usage Raycast extension; see [NOTICE](NOTICE). Product
names and logos belong to their owners; this is an unofficial client.
