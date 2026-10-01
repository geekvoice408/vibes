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
- `ls`, `add`, `exec`, `claude`, `publish`, `unpublish`, `rm`, and `scp`
- `@scotty` mentions, DMs, and `scotty ...` messages handled by Claude Code in a beam
- Rejection of interactive `ssh`
- Command timeouts and Slack-safe output limits
- Container and Compose scaffolding
- Beams application registration in the plugin lifecycle
- Slash-command dispatch to the command runner
- Private asynchronous command results through Slack

The Slack integration is authenticated by Machine ID.

By default every Beams command runs with the plugin's own identity, which must
hold the `beam-user` role. Teleport records that identity as the beam owner, so
the plugin keeps a per-Slack-user index of the beams each person created and
only shows or acts on those. No setup is needed.

A user who wants beams owned by their own Teleport user runs `/beams connect`.
The plugin replies with a `tsh delegation create-session` command (up to 7
days); after `/beams connect <delegation-session-id>`, new beams are created as
that user. Beams created earlier through the bot remain reachable.
`/beams disconnect` returns to the shared bot. Delegation requires
`plugin_identity` to be a `tbot` output for `bot_name`.

`/beams claude <name> [--continue] <prompt>` runs Claude Code in print mode
inside a beam and posts its answer. It passes `--dangerously-skip-permissions`
by default (override with `beams.claude_args`) and is bounded by
`beams.claude_timeout`.

### Scotty: plain-language requests

Mention the app (`@scotty create a beam`), send it a direct message, or start a
channel message with `scotty`. The plugin picks the beam for the thread, a beam
named in the message, or the user's newest beam, creating one if needed. It
then runs Claude Code there with the request. Claude can ask the plugin to
`publish`, `unpublish`, or `create_beam` by ending its reply with
`SCOTTY_ACTION:` lines; the plugin runs them and replies in the thread with the
published URL. Follow-ups in the same thread continue the Claude conversation and need no
mention.
Published apps are served from port 8080 in the beam.

Slack app setup for Scotty (Socket Mode needs no request URL):

- Event Subscriptions: enable, then subscribe to bot events `app_mention`,
  `message.im`, and `message.channels` (plus `message.groups` for private
  channels). Channel message events let thread replies continue without a
  mention and let plain `scotty ...` messages work; the plugin ignores other
  channel chatter.
- Bot token scopes: `app_mentions:read`, `chat:write`, `im:history`,
  `channels:history`, and `groups:history` for private channels
- App Home: enable the Messages tab so users can DM the app
- Rename the app's bot display name to `scotty`, reinstall, and invite it to
  channels where it should listen

Slack users are authorized through Teleport: the plugin reads the user's Slack
email and allows the command when a Teleport user with that username holds
`beams.required_role` (default config: `beam-user`). Optional `[beams.users]`
entries map specific Slack user IDs to Teleport usernames and skip the role
check. This needs:

- the `users:read` and `users:read.email` Slack bot scopes
- `read` and `list` on `user` (and optionally `user_login_state`) in the
  plugin's Teleport role

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

## Running with tbot

`docker-compose.yml` runs `tbot` beside the plugin. `tbot` joins as the
`scotty` bot and keeps `/var/lib/teleport-slack/identity/identity` renewed, so
no hand-signed identity is needed and `/beams connect` delegation works.

```sh
tctl bots update scotty --set-roles=access-plugin,beam-user
tctl bots instances add scotty      # copy the join token it prints
printf '%s' '<join-token>' > secrets/tbot-token
docker volume create beams-profiles  # first install only
docker compose up -d
```

`secrets/` is mounted at `/var/lib/teleport/plugins/slack` and can hold
`slack-bot-token` and `slack-app-token`; see `config.toml.example` for the
paths. `beams-profiles` is an external volume so per-user beam indexes survive
re-creating the stack. The join token is used once; afterwards
`tbot` renews from the `tbot-state` volume. If that volume is lost or `tbot`
stays down past its certificate TTL, add a new instance token.

## Automated container builds

The GitHub Actions workflow at
`.github/workflows/beams-slack-plugin-container.yml` builds pull requests and
publishes `main` builds to:

```text
ghcr.io/geekvoice408/beams-slack-plugin
```

Published tags include `latest`, `main`, and `sha-<commit>`.
