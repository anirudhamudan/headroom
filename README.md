<p align="center">
  <img src="Assets/icon-1024.png" width="128" alt="Headroom icon">
</p>

# Headroom

Claude usage limits in your Mac menu bar.

Headroom shows your current 5-hour session usage at a glance. Click it to see your weekly limits and when each one resets. A small dot appears next to the percentage when any limit is getting close.

> **Unofficial.** Headroom is an independent project. It is not made by, affiliated with, or endorsed by Anthropic. "Claude" is a trademark of Anthropic.

## Before you start

Headroom reads your usage through **[Claude Code](https://docs.claude.com/en/docs/claude-code)**, so you need:

- A Mac running macOS 13 (Ventura) or later
- A Claude subscription (Pro, Max, Team, or Enterprise)
- Claude Code installed and signed in. If you've never used it, open Terminal and run `claude`, then follow the sign-in steps.

If you only use Claude in the browser or the Claude desktop app, Headroom won't be able to see your usage yet.

## Install

1. Download **Headroom.zip** from the [latest release](../../releases/latest).
2. Open the zip and drag **Headroom** into your **Applications** folder.
3. Open Headroom. macOS will say it can't verify the app, because it isn't from the App Store or a paid Apple developer account. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Headroom message. Confirm with your password or Touch ID.
5. Headroom appears in your menu bar. You only need to do steps 3–4 once.

To start Headroom when you log in: **System Settings → General → Login Items** → click **+** → choose Headroom.

## Using it

- **Menu bar:** your current session usage, e.g. `48%`. A yellow dot means a limit is getting close; red means one is used up.
- **Click it** to see each limit, how much is used, and when it resets.
- **Gear menu:** turn on automatic sign-in renewal, or quit.

### "Your Claude Code sign-in expired"

Claude Code's sign-in only lasts a few hours and renews while Claude Code is running. You can either open Terminal and run `claude` once, or click **Renew automatically** so Headroom renews it for you.

Automatic renewal is off by default because it saves the renewed sign-in back to where Claude Code keeps it. In the rare case Headroom and Claude Code renew at the same moment, you may need to sign in to Claude Code again with `/login`.

## How it works

- Reads the sign-in that Claude Code stores in your macOS Keychain (`Claude Code-credentials`), and, only if you turn on renewal, writes the renewed one back.
- Calls the same usage endpoint Claude Code uses for `/usage`. **This endpoint is undocumented** and may change or stop working at any time.
- Refreshes when you open the panel (at most once a minute) and every 5 minutes, and backs off if Anthropic rate-limits it.
- Talks only to Anthropic. No analytics, no other servers.

## Build from source

Requires Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/anirudhamudan/headroom.git
cd headroom
./build.sh --install
open /Applications/Headroom.app
```

`./build.sh --release` builds a universal (Apple silicon + Intel) app and zips it to `build/Headroom.zip`.

## License

[MIT](LICENSE)
