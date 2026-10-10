# GitHub Actions — CI/CD

## What runs automatically

| Event | Workflow | Where |
|-------|----------|-------|
| Push or PR | **CI** — `pytest` | GitHub cloud runner |
| Push to `main` | **Deploy** — tests, then prod deploy | Cloud runner + **self-hosted runner on Proxmox** |

Cloud runners cannot reach your LAN. Deploy uses a **self-hosted runner** on Proxmox that runs the same script as `./scripts/deploy-prod.sh`.

## One-time setup (Proxmox host)

1. Open **Settings → Actions → Runners** in your GitHub repo → **New self-hosted runner** → Linux x64.
2. Copy the registration token.
3. On your Proxmox host:

```bash
cd /opt/wolf-leader
git pull
GITHUB_REPO='<owner>/wolf-leader' GITHUB_RUNNER_TOKEN='paste-token-here' ./scripts/install-github-runner.sh
```

4. Confirm the runner shows **Idle** in GitHub Settings.
5. Add a repository variable `WOLF_LEADER_VMID` (Settings → Secrets and variables → Actions → Variables) set to the hub container id.

## Daily workflow

```bash
# Mac — develop, test locally, push
git push origin main
# GitHub Actions tests + deploys automatically
```

Manual deploy still works:

```bash
WOLF_LEADER_PROXMOX_HOST=root@<proxmox-host> WOLF_LEADER_VMID=<ctid> ./scripts/deploy-prod.sh
```

## Notes

- Merge to `main` triggers production deploy. Feature branches only run tests.
- The self-hosted runner needs `/opt/wolf-leader` (git clone) and `pct` access to the hub LXC (`WOLF_LEADER_VMID`).
- Runner service: `systemctl status actions.runner.*`
