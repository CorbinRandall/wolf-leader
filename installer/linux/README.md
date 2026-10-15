# Wolf Leader for Linux

Download `WolfLeader-linux-<version>.tar.gz` from the release, then:

```bash
tar xzf WolfLeader-linux-*.tar.gz
./wolf-leader/wolf-leader-setup
```

Setup asks the same questions as the Mac app and the Windows wizard: connect to your hub or start a
new one (needs Docker), then paste the setup prompt into your AI agent and paste its answer back.
It connects Claude Code and Cursor, turns on Claude Code's background save, and adds Wolf Leader to
your app menu (it opens the hub's web page). Tested on Ubuntu 24.04 and Fedora 41.

Undo: the last lines of setup print the `restore.sh` to run.

Build the download yourself: `bash installer/linux/build-linux.sh <version>`.
