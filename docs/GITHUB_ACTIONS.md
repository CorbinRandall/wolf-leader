# GitHub Actions

The included `CI` workflow runs the test suite on pushes and pull requests. It uses GitHub-hosted runners and needs no repository secrets.

Production deployment is intentionally not included as an automatic workflow. A public fork cannot know another owner's server address, checkout path, runner labels, or deployment command. An automatic self-hosted job with missing private infrastructure waits and eventually appears as a cancelled check.

## Add deployment for your installation

1. Verify the app locally and decide which host will run it.
2. Add a self-hosted GitHub runner for your own repository, or use your hosting provider's deployment action.
3. Store host-specific values as GitHub repository variables or secrets. Do not commit IP addresses, credentials, usernames, or absolute private paths.
4. Create a deployment workflow in your fork. Prefer `workflow_dispatch` while setting it up; add a push trigger only after the runner is reliably online.
5. Keep CI and deployment separate so a missing private runner cannot make healthy code look broken.

Wolf Leader's local `scripts/setup.sh` and `docker compose up -d --build` commands are the portable deployment foundation. Environment-specific wrappers belong in the installer's private configuration or fork.
