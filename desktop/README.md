# Wolf Leader desktop app

One app for Windows, Mac and Linux, from one codebase. It follows the Mac app
(`installer/mac/WolfLeaderApp`) screen for screen and is meant to replace it once it has
caught up, so every platform moves forward together.

## Layout

| Folder | What it is |
|---|---|
| `src/core/` | Everything that isn't a screen: finding the AI tools, talking to each one (Claude, Codex, and the Agent Client Protocol for the rest), chats, and hub sync. Plain Node, no Electron. |
| `src/main/` | The app window and the list of requests the screens can make of the core. |
| `src/ui/` | The screens (React): sidebar, home, chat, project page, search, settings. |

Chats are stored in the same form the Mac app uses and synced through the hub, so a chat
started in either app continues in the other.

## Run it

```bash
npm install
npm start
```

## Check the screens without clicking

```bash
WOLF_SHOTS=/tmp/shots WOLF_ROUTES="home,projects,project:7,settings:hub" npx electron .
```

It saves a picture of each screen and quits. Add
`WOLF_TEST_SEND="claude|say hello"` to run one real chat first and picture that too.
GitHub does this on a fresh Windows machine for every change (`.github/workflows/desktop.yml`).

## Build the downloads

```bash
npm run dist:win     # Windows installer
npm run dist:mac     # Mac disk image
npm run dist:linux   # Linux AppImage
```

## Not here yet (the Mac app has them)

Voice, sharing your screen, screen control, the rest of Library (bring in, AI tools setup,
backups, cleanup), shares, the project board, and project files synced to the server.
