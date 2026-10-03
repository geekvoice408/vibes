# Beams Slack Plugin: Development Memory

Last updated: 2026-10-01

A handoff for whoever picks this up next: how it works, why it is built this
way, where it runs, what was tried, and what is still open. User-facing setup
and usage are in `README.md`.

## Current state

Working end to end on the live deployment:

- `/beams` slash commands (`ls`, `add`, `exec`, `claude`, `codex`, `publish`,
  `unpublish`, `rm`, `scp`, `status`, `connect`, `disconnect`)
- Slack users authorized by matching their Slack email to a Teleport user that
  has `beam-user`
- Every beam action runs as the user through a delegation session; the plugin
  asks for one (with the exact `tsh` command) when missing or expired
- Scotty (mentions, DMs, `scotty ...`, thread follow-ups) running Claude Code
  inside beams
- `tbot` sidecar keeping the plugin identity renewed

Users own every beam created from Slack, so published URLs open for them.
The plugin never acts on beams as its own bot identity. Verified live on
2026-10-01: after connecting, Scotty ran Claude in the user's own beam. A
normal Scotty request takes about a minute (a full Claude Code session in the
beam); beam-list questions skip Claude.

## Repositories

- Code and CI: <https://github.com/geekvoice408/vibes>, directory
  `beams-slack-plugin/`, branch `main`.
- `teleport.patch` is the full diff against `gravitational/teleport`
  `v18.11.1`. CI clones Teleport at that tag, applies the patch, builds
  `teleport-slack`, bundles `tsh` 18.11.3, and pushes tags `latest`, `main`,
  and `sha-<commit>` to a private GitHub Container Registry package. The
  image is not publicly pullable; anyone else must build and host it
  themselves (README "Build and host the image"). The repo's
  `docker-compose.yml` reads the image from `BEAMS_SLACK_PLUGIN_IMAGE`.
- Edit workflow: a throwaway `git worktree` of a local Teleport clone at
  `v18.11.1`, `git apply` the patch, `git add -N .`, edit, test, then
  regenerate with `git diff --binary v18.11.1 --output=.../teleport.patch`.
  Exact commands are in `README.md` under Development.
- Versions: source `v18.11.1`, bundled `tsh` 18.11.3, `tbot` 18.11.3.
  18.11.3 binaries are published but GitHub has no `v18.11.3` (or `v18.11.2`)
  tag, so the patch stays on `v18.11.1` until a newer public tag exists.
- Run tests with `GOTOOLCHAIN=go1.25.14`. Go 1.27 crashes at init inside
  `charlievieth/strcase`, which is unrelated to this code.
- Earlier work was done by Codex in `/home/beams/work/...`. Those paths are
  obsolete.
- `assets/slack-beams-bot.png` (1024 x 1024 PNG, background `#3B2A9E`) is the
  Slack app icon; README "Set Scotty's icon" has the upload steps.
- `assets/screenshots/` holds the README screenshots. Two were edited to hide
  the real tenant name; check new screenshots for it before adding them.

## Architecture

### Slack transport

- Socket Mode only: an outbound WebSocket, no inbound ports. The `xapp-` app
  token is read from `review.app_token` even with review disabled.
- `slash_commands` envelopes become `SlashCommandEvent`. Replies go to the
  command's `response_url` as ephemeral messages, so the bot does not need to
  be in the channel for slash commands.
- `events_api` envelopes (`app_mention`, `message.*`) become
  `BeamsMessageEvent`. Scotty replies in a thread with `chat.postMessage`.
- Slash-command replies are posted as-is. Raw `tsh` output (`add`, `exec`,
  `claude`, `codex`, `publish`, ...) goes through `codeBlock`; `ls` uses
  `formatBeamsList` (same list Scotty shows); messages such as the
  authorization prompt carry their own formatting. Wrapping every multi-line
  reply used to double-wrap the prompt's code block.
- Duplicate deliveries are dropped by `channel-ts` (`recentSet`, last 1000).
- `threadQueue` allows one Scotty run per thread. Messages arriving mid-run
  get "Still working on your earlier request" and only the newest is kept;
  it runs (with `--continue`) when the current run ends. Before this,
  follow-ups started overlapping Claude runs in the same beam with no shared
  context.

### Authorization (`resolveUser` in `beams_commands.go`)

1. A Slack user ID listed in `[beams.users]` maps straight to that Teleport
   username.
2. Otherwise: Slack `users.info` gives the email (needs `users:read.email`),
   then `services.GetUserOrLoginState` loads the Teleport user with that
   username. The user is allowed only if they hold `beams.required_role`, and
   bot users are rejected.

SSO users exist in Teleport only while their login is current, so a user who
has never signed in is denied until they do.

### Identities and ownership

Every beam action (`ls`, `add`, `exec`, `claude`, `codex`, `publish`, `unpublish`,
`rm`, `scp`, and all of Scotty) runs as the user:

- `userIdentity` calls delegation `GenerateCerts` with the bot's `tbot`
  identity to mint a short-lived certificate for the user (CN checked against
  the resolved username) into a `0600` temp file, used for one `tsh` call.
- No session, or minting fails with AccessDenied/NotFound, returns
  `needsAuthorizationError`. `/beams` replies with `authorizationMessage`
  ("Before we can get started, you need to allow me to create beams as
  you..." plus `tsh delegation create-session --bot=<bot_name> ...`) and
  removes an expired session file. Nothing runs as the bot.
- Teleport enforces ownership (`beam_labels` owner == user), so users only
  see and reach their own beams.

An earlier version ran unconnected users as the bot with a per-user
`bot-beams` index; it was removed because bot-owned beams' published URLs are
unreachable for the human (see the app-label fact below). Stale `bot-beams`
files in profiles are ignored.

Teleport v18.11.1 facts behind this design, confirmed in source:

- SSO users cannot be impersonated (`GenerateUserCerts` in
  `lib/auth/auth_with_roles.go`: "Do not allow SSO users to be impersonated").
- An impersonated certificate cannot impersonate anyone else. That is why
  `tctl auth sign` identities failed earlier.
- `CreateDelegationSession` only creates a session for the calling user,
  requires MFA (`AuthorizeAdminAction`), and caps TTL at 7 days. The
  delegation service has only `CreateDelegationSession` and `GenerateCerts`,
  with no list call and no web consent page, so the bot cannot create or
  discover sessions for a user.
- Delegation `GenerateCerts` requires the caller to be a bot (`BotName` set),
  so `plugin_identity` must come from `tbot`. Its `disallow-reissue` extension
  does not block this.
- `tsh beams publish` always publishes port 8080 (HTTP, or TCP with `--tcp`).
- `tsh beams exec` runs its command over SSH as one string.
- A new beam rejects SSH until it is assigned a node, and `tsh` fails
  immediately ("is not ready to accept SSH connections"). The JSON from
  `tsh beams ls` does not expose readiness, so the plugin retries that error
  every 5s for up to 3 minutes.
- Published apps are labelled `teleport.internal/beams/owner: <owner>`. The
  `beam-user` role grants app access by
  `labels["teleport.internal/beams/owner"] == user.metadata.name`. This
  labelling happens on the Cloud side, not in the OSS tree.

### Coding agents (`/beams claude`, `/beams codex`)

`parseCommand` splits `claude`/`codex` with `agentWords`: only the beam name
and `--continue`/`-c` are split off and the prompt is kept as typed (outer
quotes stripped), because shell-style parsing rejected prompts like
"what's in this directory?". Other commands still use `shellwords`.

Both go through `runAgent` (`<name> [--continue|-c] <prompt...>`, timeout from
`claude_timeout`/`codex_timeout`, default 15m) and run as one shell-quoted
string over `tsh beams exec`:

- Claude: `claude -p <claude_args> [--continue] <prompt>`; default
  `claude_args` is `--dangerously-skip-permissions`.
- Codex: `codex exec --skip-git-repo-check <codex_args> [resume --last]
  <prompt>`; default `codex_args` is
  `--dangerously-bypass-approvals-and-sandbox`. Flags were checked against
  `codex-rs/exec/src/cli.rs`. With stdout not a terminal, `codex exec` prints
  only the final message to stdout and progress to stderr, so Slack gets the
  answer. Not yet tried live in a beam.

Beams ship both CLIs preconfigured (`~/AGENTS.md` lists the Anthropic and
OpenAI credentials). Scotty uses Claude only.

### Scotty (`beams_scotty.go`)

1. `scottyRequest` decides whether a message is for Scotty. These count:
   `app_mention`, DMs, channel messages starting with `scotty`, and replies
   in a thread the same user already has with Scotty (`FollowsThread`
   checks `<profile>/threads/<channel>-<thread_ts>`). Bot messages, edits,
   and other subtypes are ignored.
2. `Ask` requires delegation. If the user is not connected, it saves the
   request to `<profile>/threads/<key>.pending`, creates an empty thread file
   so the reply is a follow-up, and returns the "Before we can get started"
   message with `tsh delegation create-session`. A later message in the
   thread containing a UUID connects (same validation as `/beams connect`)
   and replays the pending request. If minting fails with AccessDenied or
   NotFound, the session file is removed and the user is asked again.
3. Questions only about which beams the user has (`isBeamsListQuestion`:
   mentions "beams" plus list/show/what/which/how many, and no action verb)
   are answered from `tsh beams ls` by `formatBeamsList` without running
   Claude. The thread file is still created so follow-ups work.
4. Otherwise `Ask` picks one of the user's beams: the thread's beam (then
   `claude --continue`), a beam named in the text, or the newest by expiry. If there are none it creates
   one, and the prompt tells Claude the beam is new.
5. It runs `claude -p --dangerously-skip-permissions <prompt>` through
   `tsh beams exec` as one shell-quoted string, with `claude_timeout` (15m).
   The prompt calls the beam an "ephemeral Debian runtime" (never "sandbox")
   and tells Claude to reply directly without restating the request.
6. Claude ends its reply with `SCOTTY_ACTION: publish|unpublish|create_beam`
   lines. The plugin strips those, runs the actions, and appends the results
   (for example the publish URL). `create_beam` switches the thread to the
   new beam; the thread file is marked `<beam> new` until a Claude run
   succeeds there, so the next run does not pass `--continue`.
7. Inside a beam, Claude has preconfigured Anthropic/OpenAI credentials and
   its own `tsh`. The beam's `~/AGENTS.md` says it can run
   `tsh beams publish $BEAM_ALIAS` itself. `SCOTTY_ACTION` remains as the
   path the plugin controls.

### Per-user state (`beams-profiles` volume)

```text
/var/lib/teleport-slack/beams/<slack-team-id>/<slack-user-id>/
  delegation-session   delegation session ID after /beams connect
  threads/<ch>-<ts>    beam used by each Scotty thread ("<beam> new" = no Claude conversation yet)
  threads/<ch>-<ts>.pending  request waiting for the user to authorize Scotty
  identity-*           temp delegated identities, deleted after each command
```

## Live deployment

- Host `ventura.local` (10.0.0.188), reachable with `ssh ventura.local`.
- Directory `/usr/local/docker/beams-hackathon`, Compose project
  `beams-hackathon`: `volume-init`, `tbot`, and `teleport-slack`. Its
  `docker-compose.yml` matches the one in this repo.
- Teleport tenant `example-beams-tenant.beams.sh:443`. Bot `scotty` with roles
  `access-plugin,beam-user`. `tbot` instance
  `9d773b47-bef6-4f36-b7eb-83deb955a23b` joined 2026-10-01 with token join.
- Identity file `/var/lib/teleport-slack/identity/identity` in the plugin
  container (volume `beams-hackathon_plugin-identity`).
- `config.toml` there has `bot_name = "scotty"`, `delegation_ttl = "168h"`,
  `required_role = "beam-user"`. The Slack tokens are inline in that file
  (not in the repo); moving them into `secrets/` files would be tidier.
- Rollback: pre-`tbot` copies are `config.toml.bak-20261001-145142` and
  `docker-compose.yml.bak-20261001-145142`. The old `docker run` container
  `clever_williams` is stopped but not removed. The old hand-signed
  `secrets/plugin-identity` (user `access-plugin`) is unused and can be
  deleted.
- Deploy a new image: `docker compose pull teleport-slack && docker compose up
  -d --no-deps teleport-slack`.

Test identities: Slack workspace `T03PXFLJF`, user `U049LDB6K` mapped to
`paul@geekvoice.net` (Google SSO), test channel `C0C5D5M81U7`.

## History: what was tried

1. **Impersonation** (`tctl auth sign` for dedicated per-user accounts)
   failed with "impersonation is not allowed" and then "impersonated user can
   not impersonate anyone else". It cannot work for SSO users at all.
2. **Pasted delegation session IDs** worked in principle but needed a manual
   step.
3. **Browser SSO callback** needed a public HTTPS endpoint, so it was dropped.
4. **Headless login** (`tsh ls --headless` plus `tsh headless approve`) failed
   with "MFA response of type <nil> is not supported for headless
   authentication". Headless approval needs WebAuthn or SSO MFA, and the
   account only has Google SSO, so this was removed.
5. **Bot identity with per-user isolation** needed no setup, but beams were
   owned by `bot-scotty`, so users could not open their published URLs.
   Removed.
6. **Delegation required everywhere** (current). The plugin prompts with the
   `tsh` command; Scotty accepts the session ID pasted in its thread and
   resumes the original request.
7. **A `tbot` sidecar** replaced the hand-signed `access-plugin` identity,
   which did not renew and could not use delegation.

Other fixes along the way: Socket Mode needs the `xapp-` token, not `xoxb-`;
slash commands must be registered in the Slack app; replies moved from
`chat.postMessage` to `response_url` (`channel_not_found`); `tsh` output has
ANSI colour stripped; Docker mount mistakes (creating a directory where a file
was expected, broken line continuations).

## Open items

1. Confirm a Scotty-published URL opens for its owner (Scotty already runs
   as the user; publishing as the user is not yet verified live).
2. Test `scp` and `unpublish` from Slack.
3. Confirm Teleport audit events attribute delegated actions to both the human
   and `bot-scotty`.
4. The bot may no longer need `beam-user`, since beam actions run as users.
   Verify, then drop it from `scotty`.
5. Security clean-up: rotate the GitHub token that was pasted into an earlier
   Codex conversation. Rotate the Slack tokens if they were ever shared. Delete
   the old `secrets/plugin-identity`. Remove `beam-user` from the
   `access-plugin-impersonator` role, which is no longer needed.

## Security notes

- Never log or commit Slack tokens, Teleport identities, delegation session
  IDs, or private keys.
- The plugin identity is mounted read-only. Delegated identities are minted
  per command into `0600` temp files and deleted afterwards.
- Delegated certificate usernames are checked against the resolved Teleport
  user.
- Each Slack user's actions run as their own Teleport user, so Teleport RBAC
  and the audit log apply per person. The Slack email-to-Teleport-user match
  is what decides whose delegation session a Slack user can use.
- Claude runs in beams with `--dangerously-skip-permissions`. That is
  acceptable because beams are throwaway runtimes, but anything a beam can
  reach is reachable by whoever controls the prompt.
