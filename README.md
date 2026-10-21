# Headroom

Claude usage limits in your Mac menu bar.

Headroom shows your current 5-hour session usage at a glance, and opens a small panel with your weekly limits and when each one resets. A dot appears next to the percentage when any limit is getting close.

> **Unofficial.** Headroom is an independent project. It is not made by, affiliated with, or endorsed by Anthropic. "Claude" is a trademark of Anthropic.

## How it works

- Reads the sign-in token that [Claude Code](https://docs.claude.com/en/docs/claude-code) stores in your macOS Keychain (`Claude Code-credentials`). It never writes to it or refreshes it.
- Calls the same usage endpoint Claude Code uses for `/usage`. **This endpoint is undocumented** and may change or stop working at any time.
- Refreshes when you open the panel (at most once a minute) and every 5 minutes, and backs off if the server rate-limits it.
- Nothing is sent anywhere except Anthropic's API.

## Requirements

- macOS 13 or later on Apple silicon
- Xcode command line tools (`xcode-select --install`)
- Claude Code, signed in with a Claude subscription (Pro, Max, Team, or Enterprise)

## Install

```bash
./build.sh --install
open /Applications/Headroom.app
```

To start it at login: System Settings → General → Login Items → add Headroom.

If it says you're not signed in, run `claude` in Terminal and type `/login`.
