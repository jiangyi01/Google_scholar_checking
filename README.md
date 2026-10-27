# ScholarBar

English | [简体中文](README.zh-CN.md)

A macOS menu-bar widget that shows your Google Scholar citation count and tells you which paper just got cited.

## Features

- **Menu bar**: 🎓 your total citations, plus a green `+N` when new citations arrive. Right-click for Refresh / Open profile / Settings / Quit.
- **Popover panel**: total citations, h-index, i10-index, change over the last 7 / 30 days, and a citations-per-year chart.
  - **Recent** lists which papers gained citations and when. Click a row to see the newest citing papers.
  - **All papers** lists your papers sorted by citations.
- **Notifications** when new citations show up.
- **OpenAlex fallback**: when Google Scholar temporarily limits automatic access (CAPTCHA / HTTP 429), ScholarBar switches to the [OpenAlex](https://openalex.org) open API to keep reporting new citations, tagged "OpenAlex".
  - The headline total always comes from Scholar.
  - Once Scholar is back, citations OpenAlex already reported are not announced a second time.
- **Easy to open**: click the app icon in the Dock, on the Desktop or in Launchpad to open the panel. If the menu-bar icon is hidden behind the notch, the panel opens as a regular window on the screen your mouse is on. ScholarBar can also start at login.

The interface is in Chinese.

## Install

Requires macOS 14+ and a Swift toolchain. The Command Line Tools are enough; you don't need Xcode.

```bash
./build_app.sh --run
```

This builds the app, installs it to `~/Applications/ScholarBar.app` (ad-hoc signed) and launches it. On first launch, paste your Scholar profile link (`https://scholar.google.com/citations?user=…`).

Optional: paste a free OpenAlex API key in Settings (get one yourself at <https://openalex.org/settings/api>). Without a key, ScholarBar shares OpenAlex's free daily allowance with everyone else on your network. The key is stored in your login Keychain.

## How ScholarBar accesses Google Scholar

Scholar has no official API. ScholarBar reads your **public** profile page, and only rarely:

- Every 2 hours by default. You can choose 1–24 hours, and each interval varies by ±20%.
- A manual refresh needs at least 5 minutes since the last one.
- No automatic refreshes between 1 and 7 am.
- After Scholar asks for verification, ScholarBar backs off for 6, then 12, then 24 hours. For the week after that it refreshes at most every 6 hours.
- Every block is logged to `~/Library/Application Support/ScholarBar/blocks.log`.

ScholarBar never tries to get around Scholar's verification. While Scholar is limiting access, OpenAlex fills in.

## Command line

```bash
.build/release/ScholarBar --check <profile URL or user ID>   # fetch once and print the result
~/Applications/ScholarBar.app/Contents/MacOS/ScholarBar --login-item on|off|status
```

For debugging:
- `SCHOLARBAR_STATE_DIR=<dir>` uses a throwaway data folder.
- `--snapshot out.png` and `--snapshot-window out.png` render the panel to an image.

## Data

Everything stays on your Mac, in `~/Library/Application Support/ScholarBar/state.json`: the citation snapshot, the log of new citations, and the history of totals.

## Project layout

| File | Purpose |
|---|---|
| `ScholarAPI.swift` | Fetches and parses the Scholar profile page |
| `OpenAlexAPI.swift` / `OpenAlexKey.swift` | Matches papers to OpenAlex and reads their citation counts; Keychain storage for the API key |
| `AppModel.swift` / `Models.swift` | Scheduling, backoff, diffing, OpenAlex fallback and de-duplication, persistence |
| `PopoverView.swift` / `StatusBarController.swift` / `App.swift` | Menu-bar item, popover, window and app entry points |
| `Notifier.swift` | System notifications |
| `tools/make_icon.swift` | Generates `Resources/AppIcon.icns` |
