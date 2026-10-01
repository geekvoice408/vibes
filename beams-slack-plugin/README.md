# Beams Slack Plugin

Slack slash-command support for managing Teleport Beams. This project extends
Teleport's Slack access plugin at the pinned `v18.11.1` release.

The image currently pins the runtime CLI to `tsh` 18.11.1. Override the
`TSH_VERSION` Docker build argument when upgrading the target tenant.

## Status

Implemented:

- Slack Socket Mode parsing and acknowledgement for `slash_commands`
- Safe, shell-free `tsh beams` execution
- Slack users authorized by Teleport role, matched by Slack email
- Short-lived delegated identities isolated per Slack workspace and user
- `ls`, `add`, `exec`, `publish`, `unpublish`, `rm`, and `scp`
- Rejection of interactive `ssh`
- Command timeouts and Slack-safe output limits
- Container and Compose scaffolding
- Beams application registration in the plugin lifecycle
- Slash-command dispatch to the command runner
- Private asynchronous command results through Slack

The Slack integration is authenticated by Machine ID. By default
(`beams.run_as = "bot"`) every Beams command runs with the plugin's own Machine
ID identity, which must hold the `beam-user` role. No `/beams connect` step is
needed, and all allowed users share the bot's beams.

Slack users are authorized through Teleport: the plugin reads the user's Slack
email and allows the command when a Teleport user with that username holds
`beams.required_role` (default config: `beam-user`). Optional `[beams.users]`
entries map specific Slack user IDs to Teleport usernames and skip the role
check. This needs:

- the `users:read` and `users:read.email` Slack bot scopes
- `read` and `list` on `user` (and optionally `user_login_state`) in the
  plugin's Teleport role

With `beams.run_as = "user"`, commands instead run as the mapped Teleport user.
`/beams connect` replies with a `tsh delegation create-session` command for the
configured bot; the user runs it from their own signed-in terminal, then runs
`/beams connect <delegation-session-id>`.

Still required:

- Add command-runner and delegation tests

## Source layout

The current development source lives in the pinned Teleport tree under
`integrations/access/slack`. `teleport.patch` contains the changes relative to
the pinned upstream commit, including newly added files.

Apply it manually with:

```sh
git clone https://github.com/gravitational/teleport.git
cd teleport
git checkout v18.11.1
git apply ../teleport.patch
```

## Runtime requirements

- Teleport and `tsh` 18.8.0 or newer
- A Beams-enabled Teleport tenant
- Slack Socket Mode, a `/beams` slash command, bot token, and app token
- Persistent encrypted storage for per-user `tsh` profiles
- A Machine ID bot identity and user-created delegation sessions

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
