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

### Slack user mapping

Slack user IDs are explicitly mapped to Teleport usernames in configuration.
The observed test mapping is:

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

### Delegation flow

The intended connection flow is:

1. User runs `/beams connect`.
2. The plugin starts an isolated Teleport profile for the Slack team/user pair.
3. The plugin starts a supported headless login using:

   ```bash
   tsh ls --headless --format=json --proxy=<proxy> --user=<user>
   ```

   Teleport v18 does not support `tsh login --headless`. Headless login is only
   enabled through commands such as `tsh ls`, `tsh ssh`, and `tsh scp`.

4. The plugin extracts the `/web/headless/<request-id>` URL from `tsh` stderr.
5. Slack receives an approval command and browser fallback.
6. The human approves the request using their authenticated local `tsh`.
7. The temporary user profile creates a delegation session:

   ```bash
   tsh delegation create-session \
     --bot=<configured-bot-name> \
     --allow-all \
     --session-ttl=<configured-ttl>
   ```

8. The delegation session ID is stored under the persistent per-user profile.
9. For each Beams command, the plugin calls Teleport's delegation API to mint a
   short-lived certificate for the mapped human user.
10. The plugin verifies the certificate's username and executes `tsh beams`
    with the generated identity.

Profiles are isolated below:

```text
/var/lib/teleport-slack/beams/<slack-team-id>/<slack-user-id>/
```

This directory should be backed by the Docker volume:

```text
beams-profiles:/var/lib/teleport-slack/beams
```

The initiating login process is detached from the short-lived Slack request
context and has a bounded ten-minute timeout. Before that fix, Slack could
cancel the login process as soon as the approval URL was returned.

CLI failures are now captured in a `connect-error` file and surfaced by
`/beams status`, instead of always appearing as a fifteen-second URL timeout.

## Supported slash commands

```text
/beams connect
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

## Current blocker: Teleport v18 headless MFA

The headless request is created successfully and appears in Teleport Connect,
but approval currently fails.

Browser approval first failed with:

```text
TypeError: Cannot read properties of undefined (reading 'webauthn_response')
```

Terminal approval with browser MFA:

```bash
tsh headless approve \
  --mfa-mode=browser \
  --user=paul@geekvoice.net \
  --proxy=super-grass.beams.sh:443 \
  <request-id>
```

fails with:

```text
MFA response of type <nil> is not supported for headless authentication
```

Teleport v18's auth server requires headless approval to include either:

- a WebAuthn response, or
- an SSO response

OTP and an empty response are not accepted.

The account inspection showed this MFA device:

```text
Google SSO
```

No WebAuthn/passkey device was shown. Therefore `--mfa-mode=browser` is likely
the wrong mode: in Teleport it means browser-based WebAuthn, not generic
browser-based SSO.

The next experiment is:

```bash
tsh headless approve \
  --mfa-mode=sso \
  --user=paul@geekvoice.net \
  --proxy=super-grass.beams.sh:443 \
  <request-id>
```

If this succeeds, change the generated approval command in
`beams_commands.go` from:

```text
--mfa-mode=browser
```

to:

```text
--mfa-mode=sso
```

A better follow-up implementation would make the approval MFA mode
configurable, for example:

```toml
[beams]
mfa_mode = "sso"
```

and validate it against Teleport's supported values:

```text
auto, cross-platform, platform, otp, sso, browser
```

For headless approval, only WebAuthn, SSO, and browser WebAuthn can satisfy the
server's phishing-resistant MFA requirement.

If SSO mode also returns a nil response, inspect the Teleport tenant's
authentication/MFA policy. At that point the headless flow may not be usable
with this tenant configuration. The remaining designs would be:

- enroll a WebAuthn/passkey device and approve with `browser`, `platform`, or
  `cross-platform`
- fix/enable SSO MFA challenges for headless authentication
- restore an inbound browser callback flow
- stop using per-user delegation and run as a service identity, which changes
  attribution and authorization semantics

The outbound-only headless flow remains the preferred architecture if SSO or
WebAuthn approval can be made to work.

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

1. Create a fresh request with `/beams connect`.
2. Approve it using `--mfa-mode=sso`.
3. If approval succeeds, update the plugin's generated approval command and
   preferably add a configurable `beams.mfa_mode`.
4. Confirm `/beams status` reports the delegation connection.
5. Test `/beams ls`.
6. Test `/beams add`, then `/beams exec`, `/beams publish`, `/beams unpublish`,
   `/beams scp`, and `/beams rm`.
7. Confirm all actions are attributed to both the human user and delegated
   workload identity in Teleport audit events.
8. Rotate the exposed GitHub PAT.
