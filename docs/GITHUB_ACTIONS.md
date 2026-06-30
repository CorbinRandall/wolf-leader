# GitHub Actions — CI/CD

## What runs automatically

| Event | Workflow | Where |
|-------|----------|-------|
| Push or PR | **CI** — `pytest` | GitHub cloud runner |
| Push to `main` | **Deploy** — tests, then prod deploy | Cloud runner + **self-hosted runner on Proxmox** |

Cloud runners cannot reach `192.168.1.x`. Deploy uses a **self-hosted runner** on Proxmox that runs the same script as `./scripts/deploy-prod.sh`.

## One-time setup (Proxmox host)

1. Open [Actions → Runners](https://github.com/CorbinRandall/wolf-leader/settings/actions/runners) → **New self-hosted runner** → Linux x64.
2. Copy the registration token.
3. On Proxmox (`192.168.1.230`):

```bash
cd /opt/wolf-leader
git pull
GITHUB_RUNNER_TOKEN='paste-token-here' ./scripts/install-github-runner.sh
```

4. Confirm the runner shows **Idle** in GitHub Settings.

## Daily workflow

```bash
# Mac — develop, test locally, push
git push origin main
# GitHub Actions tests + deploys automatically
```

Manual deploy still works:

```bash
./scripts/deploy-prod.sh
```

## Notes

- Merge to `main` triggers production deploy. Feature branches only run tests.
- The self-hosted runner needs `/opt/wolf-leader` (git clone) and `pct` access to LXC 104 — same as today.
- Runner service: `systemctl status actions.runner.*`
