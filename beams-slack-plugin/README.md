# Beams Slack Plugin

Slack slash-command support for managing Teleport Beams. This project extends
Teleport's Slack access plugin at pinned commit
`1283425b60ec5f60d509ba4c791183d452923ff7`.

The image currently pins the runtime CLI to `tsh` 18.11.2. Override the
`TSH_VERSION` Docker build argument when upgrading the target tenant.

## Status

Implemented:

- Slack Socket Mode parsing and acknowledgement for `slash_commands`
- Safe, shell-free `tsh beams` execution
- Isolated Teleport profile directories per Slack workspace and user
- `ls`, `add`, `exec`, `publish`, `unpublish`, `rm`, and `scp`
- Rejection of interactive `ssh`
- Command timeouts and Slack-safe output limits
- Container and Compose scaffolding

Still required before an end-to-end Slack test:

- Register the Beams application in the plugin lifecycle
- Dispatch slash events to the command runner
- Post asynchronous results to Slack
- Implement per-user Teleport SSO initiation and callback completion
- Add command-runner and authentication tests

## Source layout

The current development source lives in the pinned Teleport tree under
`integrations/access/slack`. `teleport.patch` contains the changes relative to
the pinned upstream commit, including newly added files.

Apply it manually with:

```sh
git clone https://github.com/gravitational/teleport.git
cd teleport
git checkout 1283425b60ec5f60d509ba4c791183d452923ff7
git apply ../teleport.patch
```

## Runtime requirements

- Teleport and `tsh` 18.8.0 or newer
- A Beams-enabled Teleport tenant
- Slack Socket Mode, a `/beams` slash command, bot token, and app token
- Persistent encrypted storage for per-user `tsh` profiles
- A public HTTPS endpoint for the Teleport SSO callback

The container runs as UID/GID `10001` and stores profiles under
`/var/lib/teleport-slack/beams`.

## Automated container builds

The GitHub Actions workflow at
`.github/workflows/beams-slack-plugin-container.yml` builds pull requests and
publishes `main` builds to:

```text
ghcr.io/geekvoice408/beams-slack-plugin
```

Published tags include `latest`, `main`, and `sha-<commit>`.
