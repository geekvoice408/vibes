# Beams Slack Plugin

Manage [Teleport Beams](https://goteleport.com/) from Slack, either with a
`/beams` slash command or by asking **Scotty** in plain language ("@scotty
make a webpage about things to do in Seattle and publish it").

It is Teleport's Slack access plugin (pinned to `v18.11.1`) with a Beams app
added. It runs as a container next to `tbot`, talks to Slack over Socket Mode,
and needs no inbound ports or public URL.

## What it does

- **`/beams` slash commands**: list, create, run commands in, publish, copy
  files to, and delete beams. Replies are private to the person who ran them.
- **Scotty**: mention the app, DM it, or start a message with `scotty`.
  Scotty picks or creates one of your beams, runs Claude Code inside it with
  your request, publishes the result if asked, and replies in a thread.
  Replies in that thread continue the same beam and Claude conversation.
- **Who you are**: the plugin looks up your Slack email, finds the Teleport
  user with that username, and lets you in only if that user has the
  configured role (`beam-user`). No list of Slack IDs to maintain.
- **Privacy between users**: each person only sees and acts on their own
  beams, even when they share the bot's identity.

## Slash commands

```text
/beams help
/beams status
/beams ls
/beams add [--region=<region>]
/beams exec <name> <command...>
/beams claude <name> [--continue] <prompt...>
/beams publish <name> [--tcp]
/beams unpublish <name>
/beams rm <name>
/beams scp <src> <dst>             # remote side is <name>:<path>
/beams connect [<delegation-session-id>]
/beams disconnect
```

- `exec` runs over SSH as a single shell string, so quote commands that use
  `&&`, pipes, or redirects: `/beams exec crisp-array "cd /app && make"`.
- `claude` runs `claude -p` in the beam (15 minute limit) and posts the answer.
  `--continue` resumes the previous Claude conversation in that beam.
- `publish` exposes port 8080 in the beam as a Teleport app.
- Interactive `/beams ssh` is not supported; use `exec`.
- A brand-new beam takes a moment to accept SSH; commands retry for up to 3
  minutes.

## Scotty

Talk to Scotty in any of these ways:

- `@scotty <request>` in a channel the app is in
- a direct message to the app
- a channel message starting with `scotty` (needs the `message.channels` event)
- a reply in a thread Scotty is already working in (no mention needed)

For each request Scotty:

1. Picks the beam: the one this thread already uses, a beam you named, or your
   newest beam. If you have none, it creates one.
2. Runs Claude Code in that beam with your request. Claude is told to serve
   anything it wants to share on port 8080 in the background.
3. Carries out actions Claude asks for (`publish`, `unpublish`,
   `create_beam`) from outside the beam, since Claude cannot manage beams from
   inside the VM.
4. Replies in the thread with Claude's answer and any published URL.

Scotty cannot delete beams; use `/beams rm`.

## Who owns a beam

Teleport records the identity that created a beam as its owner, and that owner
decides who can open the beam's published URL.

| How you use it | Beam owner in Teleport | Can you open the published URL? |
| --- | --- | --- |
| Default (not connected) | `bot-scotty` | Only with extra RBAC (see below) |
| After `/beams connect` | your Teleport user | Yes |

**Connecting (recommended).** Run `/beams connect`. The plugin replies with a
command like:

```sh
tsh delegation create-session --proxy=super-grass.beams.sh:443 --bot=scotty --allow-all --session-ttl=168h
```

Run it in a terminal where you are logged in with `tsh`, then run
`/beams connect <id>` with the ID it prints. For the next 7 days, beams you
create from Slack or Scotty are owned by you. `/beams disconnect` switches back
to the shared bot. Beams you created through the bot before connecting stay
reachable.

Why there is a manual step: Teleport v18 does not let a bot impersonate an SSO
user, and only the user can create a delegation session for themselves (with
MFA). There is no API for the bot to do it on your behalf.

**Without connecting.** Beams are owned by `bot-scotty`. Slack still keeps
them private to you, but the `beam-user` role only grants access to apps owned
by your own user, so you cannot open the published URL. A cluster admin can
allow it with a role such as:

```yaml
kind: role
version: v8
metadata:
  name: beams-slack-apps
spec:
  allow:
    app_labels:
      teleport.internal/beams/owner: bot-scotty
```

Anyone with that role can open every app Scotty published while not
connected, not just their own.

## Setup

### 1. Teleport

The plugin runs as a Machine ID bot (named `scotty` here) with two roles:

- `access-plugin`: the role Teleport's Slack plugin normally uses. It must
  also allow `read` and `list` on `user` and `user_login_state` so the plugin
  can match Slack emails to Teleport users.
- `beam-user`: lets the bot create and use beams.

```sh
tctl bots add scotty --roles=access-plugin,beam-user    # or: tctl bots update scotty --set-roles=...
tctl bots instances add scotty                         # prints a one-time join token
```

Each person who uses the plugin needs a Teleport user whose username is their
Slack email (true for typical SSO setups) and the `beam-user` role. SSO users
only exist in Teleport while their login is current, so someone who has never
signed in is told to sign in once and retry.

### 2. Slack app

Create or update a Slack app at <https://api.slack.com/apps>:

- **Socket Mode**: on. Create an app-level token (`xapp-...`) with
  `connections:write`.
- **Slash Commands**: add `/beams`.
- **Event Subscriptions**: on (no request URL needed with Socket Mode).
  Subscribe to bot events `app_mention`, `message.im`, `message.channels`,
  and `message.groups` for private channels. The plugin ignores channel
  messages that are not meant for Scotty.
- **OAuth & Permissions, Bot Token Scopes**: `commands`, `chat:write`,
  `users:read`, `users:read.email`, `app_mentions:read`, `im:history`,
  `channels:history`, `groups:history`.
- **App Home**: enable the Messages tab and "Allow users to send messages".
  Set the display name to `scotty`.
- **Install / Reinstall to Workspace** after any scope change, then
  `/invite` the app to the channels where it should listen.

### 3. Run it

From a directory containing this repo's `docker-compose.yml`, `tbot.yaml`,
your `config.toml`, and a `secrets/` directory:

```sh
printf '%s' '<join-token>' > secrets/tbot-token
docker volume create beams-profiles    # first install only
docker compose up -d
docker compose logs tbot               # should show "Identity initialized successfully"
```

The stack has three services:

- `volume-init` gives the shared volumes to UID 10001 and exits.
- `tbot` joins as `scotty` and keeps an identity file renewed (every 20
  minutes) in the `plugin-identity` volume. The join token is only used once;
  `tbot` renews from the `tbot-state` volume afterwards. If that volume is
  lost, or `tbot` is down longer than its 1 hour certificate, create a new
  instance token.
- `teleport-slack` is the plugin, from
  `ghcr.io/geekvoice408/beams-slack-plugin:latest`. `secrets/` is mounted at
  `/var/lib/teleport/plugins/slack`, and per-user state lives in the external
  `beams-profiles` volume.

To deploy a new image:

```sh
docker compose pull teleport-slack && docker compose up -d --no-deps teleport-slack
```

### 4. Configuration

Start from `config.toml.example`. The Beams settings:

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Turn on `/beams` and Scotty |
| `proxy` | `teleport.addr` | Teleport proxy for `tsh` |
| `plugin_identity` | `teleport.identity` | Identity file from `tbot` |
| `tsh_path` | `tsh` | `tsh` binary (bundled in the image) |
| `profiles_dir` | temp dir | Per-user state; use the `beams-profiles` volume |
| `required_role` | none | Teleport role a Slack user's matching Teleport user must have |
| `users` | none | Optional `"<slack-user-id>" = "<teleport-user>"` overrides that skip the role check |
| `bot_name` | none | Bot named in delegation sessions (`scotty`); needed for `/beams connect` |
| `delegation_ttl` | `168h` | Session length suggested by `/beams connect` (Teleport max 7 days) |
| `identity_ttl` | `15m` | Lifetime of per-command delegated certificates (max 1h) |
| `command_timeout` | `2m` | Limit for normal commands |
| `claude_timeout` | `15m` | Limit for `/beams claude` and Scotty |
| `claude_args` | `["--dangerously-skip-permissions"]` | Extra Claude Code flags. Print mode cannot ask for tool approval, and beams are throwaway sandbox VMs. |

`required_role` or `users` must be set. Socket Mode reuses `review.app_token`
for the `xapp-` token even when access-request review is disabled.

## Development

The plugin source is a patch against Teleport, not a fork.
`teleport.patch` holds every change relative to `v18.11.1`, including new
files, and the Docker build applies it to a fresh checkout.

```sh
git clone https://github.com/gravitational/teleport.git && cd teleport
git worktree add --detach ../tp v18.11.1 && cd ../tp
git apply /path/to/beams-slack-plugin/teleport.patch && git add -N .
# edit integrations/access/slack/...
go build ./integrations/access/slack/... && go vet ./integrations/access/slack/
GOTOOLCHAIN=go1.25.14 go test ./integrations/access/slack/
git diff --binary v18.11.1 --output=/path/to/beams-slack-plugin/teleport.patch
```

- `git add -N .` makes new files show up in the diff.
- Run tests with Go 1.25 (`GOTOOLCHAIN=go1.25.14`). A dependency
  (`charlievieth/strcase`) panics at startup under Go 1.27.
- The tests use a fake `tsh` script, so no Teleport cluster is needed.

Main files under `integrations/access/slack/`:

| File | Purpose |
| --- | --- |
| `beams_app.go` | Socket Mode loop, slash-command and Scotty message handlers |
| `beams_commands.go` | `/beams` commands, user lookup, per-user isolation, delegation, `tsh` runner |
| `beams_scotty.go` | Scotty request parsing, beam choice, Claude prompt, actions |
| `socketmode.go`, `types.go` | Slash-command and Events API envelope decoding |
| `bot.go` | Slack replies (`response_url` and threaded `chat.postMessage`) |
| `config.go` | `[beams]` settings and validation |

## Container builds

`.github/workflows/beams-slack-plugin-container.yml` builds pull requests and
publishes `main` to `ghcr.io/geekvoice408/beams-slack-plugin` with tags
`latest`, `main`, and `sha-<commit>`. The image bundles `tsh` 18.11.1;
override the `TSH_VERSION` build argument when the tenant is upgraded.
