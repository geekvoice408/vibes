# Beams Slack Plugin: Development Memory

Last updated: 2026-10-01

A handoff for whoever picks this up next: how it works, why it is built this
way, where it runs, what was tried, and what is still open. User-facing setup
and usage are in `README.md`.

## Current state

Working end to end on the live deployment:

- `/beams` slash commands (`ls`, `add`, `exec`, `claude`, `publish`,
  `unpublish`, `rm`, `scp`, `status`, `connect`, `disconnect`)
- Slack users authorized by matching their Slack email to a Teleport user that
  has `beam-user`
- Per-user isolation of bot-owned beams in Slack
- Scotty (mentions, DMs, `scotty ...`, thread follow-ups) running Claude Code
  inside beams
- `tbot` sidecar keeping the plugin identity renewed

Open problem: beams created without `/beams connect` are owned by
`bot-scotty`, so their owner cannot open the published URL. See
"Open items".

## Repositories

- Code and CI: <https://github.com/geekvoice408/vibes>, directory
  `beams-slack-plugin/`, branch `main`.
- `teleport.patch` is the full diff against `gravitational/teleport`
  `v18.11.1`. CI clones Teleport at that tag, applies the patch, builds
  `teleport-slack`, bundles `tsh` 18.11.1, and pushes
  `ghcr.io/geekvoice408/beams-slack-plugin:{latest,main,sha-<commit>}`.
- Edit workflow: a throwaway `git worktree` of a local Teleport clone at
  `v18.11.1`, `git apply` the patch, `git add -N .`, edit, test, then
  regenerate with `git diff --binary v18.11.1 --output=.../teleport.patch`.
  Exact commands are in `README.md` under Development.
- Run tests with `GOTOOLCHAIN=go1.25.14`. Go 1.27 crashes at init inside
  `charlievieth/strcase`, which is unrelated to this code.
- Earlier work was done by Codex in `/home/beams/work/...`. Those paths are
  obsolete.

## Architecture

### Slack transport

- Socket Mode only: an outbound WebSocket, no inbound ports. The `xapp-` app
  token is read from `review.app_token` even with review disabled.
- `slash_commands` envelopes become `SlashCommandEvent`. Replies go to the
  command's `response_url` as ephemeral messages, so the bot does not need to
  be in the channel for slash commands.
- `events_api` envelopes (`app_mention`, `message.*`) become
  `BeamsMessageEvent`. Scotty replies in a thread with `chat.postMessage`.
- Duplicate deliveries are dropped by `channel-ts` (`recentSet`, last 1000).

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

Chosen per Slack user on every command:

- **Not connected (default):** `tsh` runs with `plugin_identity`, the `tbot`
  output for `bot-scotty`. Teleport records `bot-scotty` as owner. The plugin
  records which beams each Slack user created in
  `<profiles_dir>/<team>/<user>/bot-beams`. `ls` shows only those (and prunes
  expired ones), and `exec`/`claude`/`publish`/`unpublish`/`rm`/`scp` refuse
  other names with "you have no beam named ...".
- **Connected (`delegation-session` file present):** the plugin calls
  delegation `GenerateCerts` with its bot identity to mint a short-lived
  certificate for the user into a temp file for each command. New beams are
  owned by the user. Beams in the user's `bot-beams` index still run as the
  bot.

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

### Scotty (`beams_scotty.go`)

1. `scottyRequest` decides whether a message is for Scotty. These count:
   `app_mention`, DMs, channel messages starting with `scotty`, and replies
   in a thread the same user already has with Scotty (`FollowsThread`
   checks `<profile>/threads/<channel>-<thread_ts>`). Bot messages, edits,
   and other subtypes are ignored.
2. `Ask` picks the beam: the thread's beam (then `claude --continue`), a beam
   named in the text, or the newest by expiry. If there are none it creates
   one, and the prompt tells Claude the beam is new.
3. It runs `claude -p --dangerously-skip-permissions <prompt>` through
   `tsh beams exec` as one shell-quoted string, with `claude_timeout` (15m).
4. Claude ends its reply with `SCOTTY_ACTION: publish|unpublish|create_beam`
   lines. The plugin strips those, runs the actions, and appends the results
   (for example the publish URL).
5. Inside a beam, Claude has preconfigured Anthropic/OpenAI credentials and
   its own `tsh`. The beam's `~/AGENTS.md` says it can run
   `tsh beams publish $BEAM_ALIAS` itself. `SCOTTY_ACTION` remains as the
   path the plugin controls.

### Per-user state (`beams-profiles` volume)

```text
/var/lib/teleport-slack/beams/<slack-team-id>/<slack-user-id>/
  bot-beams            beams this user created through the bot
  delegation-session   delegation session ID after /beams connect
  threads/<ch>-<ts>    beam used by each Scotty thread
  identity-*           temp delegated identities, deleted after each command
```

## Live deployment

- Host `ventura.local` (10.0.0.188), reachable with `ssh ventura.local`.
- Directory `/usr/local/docker/beams-hackathon`, Compose project
  `beams-hackathon`: `volume-init`, `tbot`, and `teleport-slack`. Its
  `docker-compose.yml` matches the one in this repo.
- Teleport tenant `super-grass.beams.sh:443`. Bot `scotty` with roles
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
5. **Bot identity with per-user isolation** is the current default. It needs
   no setup, but Teleport ownership is `bot-scotty`.
6. **Opt-in delegation** (`/beams connect`) on top for real ownership.
7. **A `tbot` sidecar** replaced the hand-signed `access-plugin` identity,
   which did not renew and could not use delegation.

Other fixes along the way: Socket Mode needs the `xapp-` token, not `xoxb-`;
slash commands must be registered in the Slack app; replies moved from
`chat.postMessage` to `response_url` (`channel_not_found`); `tsh` output has
ANSI colour stripped; Docker mount mistakes (creating a directory where a file
was expected, broken line continuations).

## Open items

1. **Published URLs for bot-owned beams.** The owner cannot open them. Options
   discussed, not yet chosen:
   - Make `/beams connect` easier. Scotty would prompt in-thread with the
     `tsh delegation create-session` command, accept the session ID pasted in
     the thread, and prompt again when the session expires.
   - Add a role granting `app_labels: teleport.internal/beams/owner:
     bot-scotty`. This works immediately, but every holder can open every
     bot-published app.
   - Both: the role as a fallback, delegation for real ownership.
2. Test `/beams connect` end to end with `scotty` and confirm new beams show
   the user as owner and that the URL opens.
3. Test `scp` and `unpublish` from Slack.
4. Confirm Teleport audit events attribute delegated actions to both the human
   and `bot-scotty`.
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
- In bot mode, the plugin's Slack checks (email-to-role match plus the
  `bot-beams` index) are the only thing keeping one user away from another's
  beams. Teleport sees every unconnected user as `bot-scotty`.
- Claude runs in beams with `--dangerously-skip-permissions`. That is
  acceptable because beams are throwaway sandbox VMs, but anything a beam can
  reach is reachable by whoever controls the prompt.
