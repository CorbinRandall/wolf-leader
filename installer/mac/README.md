# Wolf Leader for macOS

A native SwiftUI app (macOS 14+). Drag it to Applications; the first launch walks through setup in
one window, then it becomes your dashboard: stats, recent chats, projects, search, shares, themes and
update checks against this repo's branch. Same answer file as the Windows installer (contract:
[`../CONFIG.md`](../CONFIG.md), [`../PROMPT.md`](../PROMPT.md)).

## Build

- **Xcode:** File > Open > `installer/mac/WolfLeaderApp/Package.swift`, pick the `WolfLeader` scheme,
  Run. Setup files are read straight from the repo when run this way.
- **App + DMG:** `bash installer/mac/build-app.sh [version]` writes `dist/Wolf Leader.app` and
  `dist/WolfLeader-<version>.dmg` (app bundle, icon, bundled setup files, ad-hoc signature,
  drag-to-Applications window).
- **From a clone:** double-click `start.command` in the repo root (builds once, then opens the app;
  `--rebuild` forces a fresh build).

First launch of an unsigned build:

- macOS 14: right-click the app > **Open** > **Open**.
- macOS 15 or newer: open it once, then **System Settings > Privacy & Security > Open Anyway**.

## Files

| Path | What it does |
|---|---|
| `WolfLeaderApp/` | The app. `Core/` theme, config, hub client, shared components; `Onboarding/` first-launch setup; `Main/` the dashboard |
| `build-app.sh` | Builds the `.app` and the `.dmg` on a Mac |
| `install.sh` | The install engine the app runs. Saves an undo point first, then does what the answer file and toggles say. `--dry-run` prints every action |
| `ini.sh` | Strict `wolf-leader-setup.ini` parser and validator (bash + awk, no python) |

DMG art: `installer/assets/dmg-drag.png` and `dmg-drag@2x.png` (`make_dmg_background.py`).

## Undo

Before changing anything, `install.sh` copies every file it may touch to
`~/Library/Application Support/WolfLeader/backup-<YYYYMMDD-HHMM>/` and writes `restore.sh` there.
The app's **Settings > Setup > Undo last install** runs it, or:

```bash
bash ~/Library/Application\ Support/WolfLeader/backup-*/restore.sh
```

Keychain entries, Login Items, installed apps and Docker containers are not undone by it.

## Logs

`~/Library/Logs/WolfLeader/install.log`. Share passwords never appear in it, on a command line,
or in any file except a mode-600 temp file that `install.sh` deletes as soon as it starts.

## Preview on any machine

```bash
HOME=/tmp/fakehome bash installer/mac/install.sh --ini wolf-leader-setup.ini --mode connect \
  --git-name "Test" --git-email test@example.com --dry-run
```
