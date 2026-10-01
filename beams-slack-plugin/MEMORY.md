# Beams Slack Plugin — Development Memory

Last updated: 2026-10-01

## Goal

Extend Teleport's Slack access plugin with `/beams` slash commands that let an
authorized Slack user manage Teleport Beams:

- connect their Teleport identity
- list beams
- create beams
- execute commands
- publish and unpublish services
- remove beams
- copy files with SCP

The plugin runs as a Docker container and uses Slack Socket Mode, so it does not
require a public HTTP callback, inbound HTTPS routing, or port 8080.

## Repositories and branches

### CI and distributable patch

Repository:

```text
https://github.com/geekvoice408/vibes
```

Local checkout:

```text
/home/beams/work/vibes-ci
```

Branch:

```text
main
```

The CI workflow is:

```text
.github/workflows/beams-slack-plugin-container.yml
```

The plugin build context is:

```text
beams-slack-plugin/
```

CI builds and publishes:

```text
ghcr.io/geekvoice408/beams-slack-plugin:latest
```

### Teleport source workspace

Local checkout:

```text
/home/beams/work/teleport-v18
```

Base:

```text
gravitational/teleport v18.11.1
```

Working branch:

```text
beams-slack-v18
```

The modified Teleport tree is not pushed directly. Its complete diff against
the `v18.11.1` tag is stored in:

```text
beams-slack-plugin/teleport.patch
```

The Docker build downloads/checks out Teleport v18.11.1 and applies this patch.

Avoid the older `/home/beams/work/vibes` and `/home/beams/work/teleport`
directories. Their Git metadata was lost and they contain AppleDouble files.

## Important implementation files

Within the patched Teleport source:

```text
integrations/access/slack/beams_app.go
integrations/access/slack/beams_commands.go
integrations/access/slack/Dockerfile.beams
integrations/access/slack/docker-compose.beams.yml
integrations/access/slack/config.go
integrations/access/slack/bot.go
integrations/access/slack/socketmode.go
integrations/access/slack/types.go
integrations/access/slack/README.md
integrations/access/slack/cmd/teleport-slack/example_config.toml
```

## Current architecture

### Slack transport

The app uses Slack Socket Mode:

- the container opens an outbound WebSocket to Slack
- slash commands arrive as Socket Mode envelopes
- envelopes are acknowledged
- replies use Slack's slash-command `response_url`
- ephemeral responses avoid requiring the bot to be a member of every channel

The Slack app must have:

- Socket Mode enabled
- an app-level token, beginning with `xapp-`, with `connections:write`
- a bot token, beginning with `xoxb-`
- a `/beams` slash command registered in the Slack app configuration

Earlier failures and resolutions:

- `not_allowed_token_type`: a bot token was incorrectly used for Socket Mode;
  Socket Mode requires the app-level `xapp-` token.
- Slack said `/beams is not a valid command`: the command had not yet been
  registered in the Slack app.
- `unsupported interaction event type ""`: slash-command Socket Mode envelopes
  were not parsed; slash-command dispatch was added.
- `channel_not_found`: replies were initially sent with `chat.postMessage`;
  replies now use the slash command's `response_url`.

### Teleport plugin identity

The underlying Slack access plugin still requires its Teleport Machine ID
identity. Teleport's dynamic identity file reader expects the identity base path
and may also read companion files such as:

```text
plugin-identity
plugin-identity-cert.pub
```

The entire secrets directory should be mounted at the configured directory,
instead of mounting a directory onto the identity filename.

Example container mount:

```bash
-v "$PWD/secrets:/var/lib/teleport/plugins/slack:ro"
```

The identity path in `config.toml` must match the actual basename, for example:

```toml
identity = "/var/lib/teleport/plugins/slack/plugin-identity"
```

Initial attempts to create or use an impersonating identity with `tctl auth
sign --user=...` failed because:

```text
access denied: impersonation is not allowed
```

and later:

```text
impersonated user can not impersonate anyone else
```

The implementation was changed to use Teleport Machine ID delegation sessions
instead of chained impersonation.

### Slack user authorization

`resolveUser` in `beams_commands.go` decides who may run commands:

1. If the Slack user ID is in `[beams.users]`, use that Teleport username.
2. Otherwise call Slack `users.info` for the user's email (needs
   `users:read.email`), look up the Teleport user with that username via
   `services.GetUserOrLoginState`, and allow only if it holds
   `beams.required_role` (e.g. `beam-user`). Bots are rejected.

SSO users only exist in Teleport while their login is current; a user who has
never signed in (or whose SSO user expired) is denied until they sign in.

Observed test identity:

```text
Slack user: U049LDB6K
Teleport user: paul@geekvoice.net
```

Observed Slack workspace/team:

```text
T03PXFLJF
```

Observed test channel:

```text
C0C5D5M81U7
```

Observed Teleport proxy:

```text
super-grass.beams.sh:443
```

### Run modes

Chosen per Slack user on every command (the `run_as` setting was removed):

- Not connected (default): commands run with `plugin_identity`. Teleport shows
  the bot (currently user `access-plugin`) as owner. The plugin records beams a
  Slack user created in `<profile>/bot-beams` and only lists/targets those;
  `ls` prunes expired names.
- Connected (`delegation-session` file exists): new beams and `ls` use a
  delegated identity for the user, minted into a temp file per command.
  Bot-owned beams in the index still run as the bot.

Teleport v18 facts behind this (checked in source):

- SSO users cannot be impersonated (`GenerateUserCerts`).
- Only the user can create a delegation session for themselves, with MFA;
  max TTL 7 days.
- Delegation `GenerateCerts` requires a bot caller (`BotName` set), so
  delegation needs `plugin_identity` from `tbot`, not `tctl auth sign`.

Current plugin identity: `tctl auth sign --user=access-plugin` (roles
`access-plugin`, `beam-user`), allowed by role `access-plugin-impersonator`.
It does not renew; switching to `tbot` for bot `scotty` is pending.

`/beams claude <beam> [--continue] <prompt>` runs `claude -p` in the beam via
`tsh beams exec`, as one shell-quoted string, with `claude_timeout` (15m).

### Scotty (natural language)

`beams_scotty.go`: Slack `events_api` envelopes (`app_mention`, `message.im`,
optional `message.channels`) become `BeamsMessageEvent`s. `Ask` picks a beam
(thread state in `<profile>/threads/<channel>-<thread_ts>`, a beam named in
the text, or newest by expiry; creates one if none), runs `claude -p` there
with a prompt describing the `SCOTTY_ACTION: publish|unpublish|create_beam`
protocol, executes those actions outside the beam, and replies in-thread.
Same-thread follow-ups pass `--continue`. `tsh beams publish` always exposes
port 8080. `tsh beams exec` sends its command over SSH, so commands are one
shell string (`/beams exec <beam> "cd /app && make"`).

### Delegation flow (after `/beams connect`)

Headless login was removed (see "Resolved: Teleport v18 headless MFA"). The
connection flow is:

1. User runs `/beams connect`. The plugin replies with the exact command:

   ```bash
   tsh delegation create-session --proxy=<proxy> --bot=<bot_name> \
     --allow-all --session-ttl=<delegation_ttl>
   ```

2. The user runs it from their own terminal, where their normal `tsh login`
   (Google SSO, any MFA) already works.
3. The user runs `/beams connect <delegation-session-id>`.
4. The plugin immediately calls the delegation `GenerateCerts` API with its
   Machine ID identity to validate the session, checks the certificate username
   matches the Slack mapping, and stores the session ID.
5. For each Beams command, the plugin mints a short-lived certificate for the
   mapped human user and runs `tsh beams` with it.

The session ID is not a bearer secret: only the named bot can redeem it.

Profiles are isolated below:

```text
/var/lib/teleport-slack/beams/<slack-team-id>/<slack-user-id>/
```

This directory should be backed by the Docker volume:

```text
beams-profiles:/var/lib/teleport-slack/beams
```

## Supported slash commands

```text
/beams connect [<delegation-session-id>]
/beams status
/beams ls
/beams add [--region=<region>]
/beams exec <name> <command...>
/beams publish <name> [--tcp]
/beams unpublish <name>
/beams rm <name>
/beams scp <src> <dst>
```

Interactive SSH is intentionally unavailable in Slack:

```text
/beams ssh
```

Users should use `/beams exec` for non-interactive commands.

Commands are parsed with shellwords and executed with argument arrays, not via
`sh -c`.

## Resolved: Teleport v18 headless MFA

Headless approval failed with
`MFA response of type <nil> is not supported for headless authentication`.
Teleport v18 requires a WebAuthn or SSO MFA response to approve headless
logins, and the account only has Google SSO (no WebAuthn device), so
`--mfa-mode=browser` (browser WebAuthn) can never succeed.

Rather than tune MFA modes, the headless bootstrap was removed. Users create the
delegation session from their own `tsh` and paste the ID into Slack. This
keeps per-user consent and attribution, needs no inbound callback, and works
with any MFA the tenant supports.

## Docker invocation

The current design does not need `-p 8080:8080`.

Example:

```bash
docker run --rm \
  -v "$PWD/config.toml:/etc/teleport-slack/config.toml:ro" \
  -v "$PWD/secrets:/var/lib/teleport/plugins/slack:ro" \
  -v "beams-profiles:/var/lib/teleport-slack/beams" \
  ghcr.io/geekvoice408/beams-slack-plugin:latest
```

Important Docker errors encountered:

- `config.toml: is a directory`: the host `config.toml` path did not exist, so
  Docker created a directory. Create the actual file before mounting it.
- `invalid reference format` followed by `zsh: command not found: -v`: a
  multiline command had a malformed continuation, usually whitespace after a
  backslash.
- `invalid volume specification`: the source and destination mount paths were
  accidentally concatenated without a colon.
- `not a directory`: a directory was mounted onto a file path, or the expected
  host file did not exist.

## Build and patch workflow

Make changes in:

```text
/home/beams/work/teleport-v18
```

The new source files are intent-to-add in Git so they appear in the generated
diff.

Regenerate the distributable patch:

```bash
git diff --binary v18.11.1 \
  --output=/home/beams/work/vibes-ci/beams-slack-plugin/teleport.patch
```

Validate the patch against a clean v18.11.1 worktree:

```bash
tmpdir=$(mktemp -d)
git worktree add --detach "$tmpdir" v18.11.1
git -C "$tmpdir" apply --check \
  /home/beams/work/vibes-ci/beams-slack-plugin/teleport.patch
git worktree remove "$tmpdir" --force
```

Then commit the updated patch in:

```text
/home/beams/work/vibes-ci
```

and push `main` to trigger the container workflow.

This environment does not have local Go, `gofmt`, Docker, or `gh`, so GitHub
Actions is the compilation and container-build validation path.

## Relevant pushed commits

Chronological history:

```text
941e953  Pin build to Teleport v18
1dbba24  Add slash-command dispatch
aa7b733  Fix slash-command Socket Mode envelope parsing
37d95e9  Reply using slash-command response URLs
f520b5f  Initial tctl impersonation attempt
97f3b99  Replace impersonation with Machine ID delegation sessions
41aac92  Add browser callback connection flow
560e4c0  Replace public callback with outbound-only headless login attempt
6961da1  Use supported tsh ls headless bootstrap and preserve login context
c3048c0  Show CLI headless approval command
75d1dd9  Add --mfa-mode=browser to the approval command
```

The current repository head when this document was created is:

```text
75d1dd9
```

## Security notes

- Do not log Slack tokens, Teleport identities, delegation credentials, or
  generated private keys.
- Keep the plugin identity mounted read-only.
- Keep generated per-user profiles in the dedicated Docker volume.
- Generated user identities are short-lived.
- Validate that delegated certificate usernames match the configured Slack
  user mapping.
- Beams currently inherit the user's permissions during the beta, so Slack
  authorization and user mapping are security boundaries.
- A GitHub personal access token was pasted into the development conversation
  and used temporarily for pushes. It must be rotated. Do not store it in this
  repository or in this file.

## Immediate next steps

1. Test bot-mode isolation, `/beams claude`, and `@scotty` in Slack (needs
   the Event Subscriptions and scopes listed in README).
2. Move `plugin_identity` to `tbot` for `scotty`, then test `/beams connect`.
3. Test `/beams add`, then `/beams exec`, `/beams publish`, `/beams unpublish`,
   `/beams scp`, and `/beams rm`.
4. Rotate the exposed GitHub PAT.
