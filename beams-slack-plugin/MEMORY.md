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
- Teleport Beams Bot (mentions, DMs, "Teleport Beams Bot ...", thread
  follow-ups; formerly called Scotty) running Claude Code
  inside beams
- `tbot` sidecar keeping the plugin identity renewed

Users own every beam created from Slack, so published URLs open for them.
The plugin never acts on beams as its own bot identity. Verified live on
2026-10-01: after connecting, the bot ran Claude in the user's own beam. A
normal bot request takes about a minute (a full Claude Code session in the
beam); beam-list questions skip Claude.

The bot was renamed from "Scotty" to "Teleport Beams Bot" on 2026-10-05: the
typed trigger is now "Teleport Beams Bot ..." (`botPrefix`; "scotty ..." no
longer triggers), and new deployments name the Machine ID bot
`teleport-beams-bot`. Existing deployments keep whatever `bot_name` they were
set up with; renaming that bot would invalidate users' delegation sessions.

## Repositories

- Code and CI: <https://github.com/geekvoice408/vibes>, directory
  `beams-slack-plugin/`, branch `main`.
- Mirrored to the PUBLIC repo `phall-teleport/stuff` (`beams-slack-plugin/`).
  Its `MEMORY.md` is a redacted copy without hosts, Slack/Teleport
  identifiers, or security notes. Sync README, code, and Terraform there, but
  never copy this `MEMORY.md` over it; edit the public copy separately.
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
- When CI is unavailable, build on the Docker host with a local-only tag
  (README "Building on the Docker host instead"); avoid registry-style tags
  because Watchtower-style updaters would replace them.
- Run tests with `GOTOOLCHAIN=go1.25.14`. Go 1.27 crashes at init inside
  `charlievieth/strcase`, which is unrelated to this code.
- Earlier work was done by Codex in `/home/beams/work/...`. Those paths are
  obsolete.
- `assets/slack-beams-bot.png` (1024 x 1024 PNG, background `#3B2A9E`) is the
  Slack app icon; README "Set the bot's icon" has the upload steps.
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
  `BeamsMessageEvent`. The bot replies in a thread with `chat.postMessage`.
- Slash-command replies are posted as-is. Raw `tsh` output (`add`, `exec`,
  `claude`, `codex`, `publish`, ...) goes through `codeBlock`; `ls` uses
  `formatBeamsList` (same list the bot shows); messages such as the
  authorization prompt carry their own formatting. Wrapping every multi-line
  reply used to double-wrap the prompt's code block.
- Duplicate deliveries are dropped by `channel-ts` (`recentSet`, last 1000).
- `threadQueue` allows one bot run per thread. Messages arriving mid-run
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
`rm`, `scp`, and all bot requests) runs as the user:

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
OpenAI credentials). The bot uses either; see below.

### Teleport Beams Bot (`beams_bot.go`)

1. `botRequest` decides whether a message is for the bot. These count:
   `app_mention`, DMs, channel messages starting with "Teleport Beams Bot"
   (`botPrefix`), and replies in a thread the same user already has with the
   bot (`FollowsThread`
   checks `<profile>/threads/<channel>-<thread_ts>`). Bot messages, edits,
   and other subtypes are ignored.
2. `Handle` requires delegation. If the user is not connected, it saves the
   request to `<profile>/pending-request` and sends the "Before we can get
   started" instructions by DM (see below). A later message containing a UUID
   connects (same validation as `/beams connect`) and resumes the pending
   request in its original thread. If minting fails with AccessDenied or
   NotFound, the session file is removed and the user is asked again.
2b. Agent choice: `requestedAgent` looks for "use/with/via/through/ask
   codex|claude" or a leading "codex"/"claude". The thread file is
   `<beam> [new] <claude|codex>` (older files without an agent mean Claude).
   Claude is the default; switching agents adds "Using X for this thread."
   and starts a fresh conversation (no `--continue`/`resume`).
3. Questions only about which beams the user has (`isBeamsListQuestion`:
   mentions "beams" plus list/show/what/which/how many, and no action verb)
   are answered from `tsh beams ls` by `formatBeamsList` without running
   Claude. The thread file is still created so follow-ups work.
4. Otherwise `Handle` picks one of the user's beams: the thread's beam (then
   `claude --continue`), a beam named in the text, or the newest by expiry. If there are none it creates
   one, and the prompt tells Claude the beam is new.
5. It runs `claude -p --dangerously-skip-permissions <prompt>` through
   `tsh beams exec` as one shell-quoted string, with `claude_timeout` (15m).
   The prompt calls the beam an "ephemeral Debian runtime" (never "sandbox")
   and tells Claude to reply directly without restating the request.
6. Claude ends its reply with `BEAMS_BOT_ACTION: publish|unpublish|create_beam`
   lines. The plugin strips those, runs the actions, and appends the results
   (for example the publish URL). `create_beam` switches the thread to the
   new beam; the thread file is marked `<beam> new` until a Claude run
   succeeds there, so the next run does not pass `--continue`.
7. Inside a beam, Claude has preconfigured Anthropic/OpenAI credentials and
   its own `tsh`. The beam's `~/AGENTS.md` says it can run
   `tsh beams publish $BEAM_ALIAS` itself. `BEAMS_BOT_ACTION` remains as the
   path the plugin controls.

Easter egg: a request that is only "beam me up" (optionally "Scotty",
`beamMeUp` regex) gets a random reply in the voice of Star Trek's Scotty from `beamMeUpReplies`
before any authorization or Teleport call, and no "On it" message.

"What can I do with beams" style questions (`beamsIntroQuestion`) return the
static `beamsIntro`, a summary of https://goteleport.com/docs/beams/ framed
around this bot's commands, the same instant way (`isInstantRequest`). Update
it if the Beams docs (limits, features) change.

Deleting: `removeTargets` treats a request as a delete only when beam names
(or "beam"/"this"/"it") directly follow delete/remove/rm/destroy/"get rid
of"; the plugin then runs `tsh beams rm` itself (no agent) and clears the
thread's beam if deleted. Slash and bot arguments have Slack code
backticks trimmed (`trimSlackCode`); pasting a code-formatted beam name used
to fail with "does not exist". `cleanTSHError` drops tsh's "cannot relogin in
non-interactive session" line.

Authorization is set up in a DM: `Handle` returns an `AskResult`. For an
unauthorized request in a channel, `Reply` is only a pointer and `DM` carries
the instructions (posted with `chat.postMessage` to the user ID). The request
is saved in `<profile>/pending-request` (channel, thread_ts, text). When a
session ID arrives (normally in the DM), `Resume` sends the request back to
its original thread, which the app runs through the usual thread queue. In a
DM the instructions are the reply itself. "On it" is skipped while the user
is not connected (`Connected`). The `tsh delegation create-session` command
includes `--user=<resolved Teleport username>`.

Chat answers (`beams_chat.go`): in threads with no beam yet (thread file beam
`-`), and when no beam is named, `chatTurn` asks the model first. `callLLMApp`
finds the `anthropic`/`openai` app (`ListResources` on app servers labelled
`teleport.internal/beams/app-type=llm`), mints an app certificate as the user
with delegation `GenerateCerts` + `RouteToApp` (this starts an audited app
session for the user via the bot), and POSTs to `https://<public_addr>/v1/messages`
(`x-api-key: teleport`) or `/v1/chat/completions` (`Bearer teleport`); Teleport
injects the real key and maps model names (Bedrock Mantle behind the scenes).
`tsh proxy app` cannot be used: tbot and delegated certs both carry
disallow-reissue. A reply with a line that is just `HANDOFF` (`isHandoff`;
models sometimes write a sentence first, which once leaked "HANDOFF" into
Slack) sends the request to a beam with the chat history in the prompt; any
text around it is dropped. The prompt keeps commands and short scripts the
user runs themselves (e.g. a curl check) as chat answers; Paul wanted that
rather than a beam for "write a script to test connectivity". History lives in
`<profile>/threads/<key>.chat` (last 20 messages). Only "no LLM app" errors
(NotFound/NotImplemented) fall back to the beam path; model errors are
reported. The OpenAI app is Bedrock-backed on the test tenant (`gpt-5` maps
to `openai.gpt-5.6-luna`), and those models are only served on the Responses
API, so Codex chat POSTs `/v1/responses` (`instructions`, `input`,
`max_output_tokens` 4096, `store: false`); Chat Completions returned "isn't
supported on this route". Config: `chat_claude_model`, `chat_codex_model`,
`disable_chat`. Not yet verified live: whether the tenant accepts the default
model names.

"delete all my beams" deletes every beam the user owns (`removeTargets` needs
"all"/"every" plus "beams").

Acknowledgements: the app posts "Just a moment while I look into this." unless
`ThreadUsesBeam` (thread already has a beam, or chat is off), in which case it
posts "On it. Working in your beam...". When a possible chat request moves to
a beam, `Handle` posts "This needs a computer, so I'm working in one of your
beams..." through `reportProgress` (a callback the app puts in the context).

Attachments (`beams_files.go`): events carry `files` (uploads arrive as
subtype `file_share`, now accepted; file-only messages become "Here's an
attachment."). The app downloads them with `Bot.DownloadSlackFile` (plain
HTTP with the bot token, only `files.slack.com`/`files-origin.slack.com`,
needs `files:read`; Slack returns an HTML login page without it), up to 5
files of 20 MB, and passes them in the context (`withAttachments`). Chat
sends up to 2 images of 3.5 MB (Teleport's model proxy caps requests at
10 MiB) as Anthropic `image` blocks or Responses `input_image` data URLs;
history keeps "[attached name]". Otherwise the request goes to a beam and
files are copied with `tsh beams scp` into `/tmp/slack-attachments/`.

Approval for Claude (`claudeForBot`, `planInstructions`): bot requests run
`claude -p --permission-mode plan` (permission flags from `claude_args` are
dropped). In -p mode ExitPlanMode is disabled, so the plan comes back as the
result text; the prompt asks Claude to end a plan with `BEAMS_BOT_ACTION:
approve`, which writes `threads/<key>.approval` and appends "Reply *yes* to
go ahead...". Other actions except tell are ignored while planning. The next
message consumes the marker (`takeApproval`): whole-message yes
(`yesReply`) reruns `--dangerously-skip-permissions --continue "The user
approved your plan..."`; whole-message no (`noReply`) cancels; anything else
reruns in plan mode with "The user replied to your plan: ...". Approval needs
`continued` (same beam/agent, not fresh). Codex and `/beams claude` keep
acting without approval; `claude_skip_approval` restores the old behaviour.
Verified live in a beam 2026-10-05. Agent commands end with `< /dev/null`
since Claude Code otherwise waits 3s for stdin ("no stdin data received").
Without --dangerously-skip-permissions and without plan mode, -p runs stop at
the first denied tool and report `permission_denials` in --output-format
json; plan mode was chosen so the whole plan is approved at once.

Demo skits (`beams_demo.go`, `demo_skits`, off by default): "zendesk" +
"ticket" replies with a made-up ticket number (no Zendesk call). "live
website ... down" runs tsh inside a beam (thread's, newest, or a new one;
`demoTSH` = `tsh beams exec <beam> "'tsh' ..."`, since tsh in a beam is
logged in as the owner via a delegation session; Paul wanted beams used, not
the plugin's own tsh): `tsh apps ls`, takes the app with a `hosted-on`
label, runs `tsh ssh <demo_ssh_login>@<host> "systemctl is-active nginx ||
true"`, and if not active writes
`threads/<key>.demo-fix` and offers to start it; the next message in the
thread ("yes"/"no") consumes it: `systemctl start nginx` (sudo -n if the
login isn't root), then is-active and `curl -w %{http_code}` of the app URI
from the server. "notify ... owner" DMs `demo_service_owner` (looked up
with FindPeople) "There's an issue with the live website." and records them
in `threads/<key>.demo-owner`; a successful fix in that thread DMs "The
issue was resolved." plus the reason (nginx had stopped on <host>, with the
systemctl status saved in the fix). Runs before delete/list/chat in Handle.

Telling people (`beams_tell.go`): the chat model and coding agents can emit
`BEAMS_BOT_ACTION: tell <person> :: <message>` (`tellInstructions` in both
prompts). `<person>` is a name or `<@ID>`; `FindSlackPeople` uses `users.info`
for a mention, else pages `users.list` (skipping deleted, bots, Slackbot) and
`matchPeople` picks: full real name or handle exactly, else a display name or
any word of a name. Display names don't win outright since they're often a
first name. 0 or 2+ matches send nothing and return a note. Channel threads:
post in the thread `<@them> message from <@requester>: ...`; DMs (`D` channel):
DM the person instead (`chat.postMessage` to the user ID). Chat-stage tells go
out immediately, even when the model also answers HANDOFF (tell lines come
first, `chatTurn` returns them); the agent prompt then lists them under
"already sent", and `told` (per request, keyed by Slack user ID) drops repeats.
`botRequest` now strips only the bot's own mention (`BotUserID` via
`auth.test` at startup) so `<@ID>` mentions of others reach the model; if
`auth.test` fails it strips all mentions as before. Logged as kind `tell`
with `to_slack_user_id`. Paul asked for incident notes to add "we're on it".

`EmitAuditEvent` was tested live as the bot (2026-10-05): with an
`event: create` rule on the bot's roles it gets past RBAC and fails with
"this request can be only executed by a teleport built-in server"
(`getLocalServerID` needs a host certificate). Without the rule:
`access denied to perform action "create" on "event"`. A rule on the
generated `bot-<name>` role does nothing, since the tbot output carries the
bot's assigned roles, not that one.

Demo setup on the tenant: app `livewebsite` (label `hosted-on: webserver`,
URI http://127.0.0.1) on node `webserver` (renamed from phall-test, same
resource ID; Debian 13, nginx). Ventura's config.toml has `demo_skits =
true`, `demo_ssh_login = "paul_hall"` (Paul's choice, not root) and
`demo_service_owner = "Paul Hall"`. paul_hall has passwordless sudo for
`systemctl start nginx` (checked 2026-10-05 from a beam). Not verified:
whether paul@geekvoice.net (whose beams the Slack user gets) has the
paul_hall login; paul.hall@goteleport.com does (root, paul_hall, beams).

Request log (`beams_audit.go`): plugins can't call `EmitAuditEvent` (only
built-in Teleport servers can), and `app.session.llm_request` has
provider/model/tokens but no prompt. So `logRequest` writes an INFO line
"Beams bot request" with kind (chat/beam/delete/list/slash), Slack and
Teleport users, request text (<= 2000 chars, off with `omit_request_text`),
and for chat the app session ID parsed from the app certificate
(`tlsca.FromSubject` -> `RouteToApp.SessionID`) to join with
`app.session.llm_request`. `connect` is not logged. Beam work text is already
in Teleport's audit via the SSH exec command line. Chat Q&A gets there the same
way: after a chat answer (not a handoff), `recordChatInBeam` runs
`printf '%s\n' 'Teleport Beams Bot chat (<agent>)' 'Q: ...' 'A: ...'` as the
user via `tsh beams exec` in their newest beam, in a goroutine with
`context.WithoutCancel` so the answer isn't delayed. Always on (Paul wanted no
opt-out); skipped only when the user has no beams. Each text is clipped at
32 KiB to stay under Linux's 128 KiB per-argument limit. To see these, query
`exec` events (the session list and `tsh recordings ls` show only
`session.end`, which has no command).

Failed tsh commands include the last 1000 bytes of stdout in the error
(`outputTail`), since a coding agent explains failures there (for example a
model API error after ~3 minutes of retries) and stderr only says "Process
exited with status 1".

### Per-user state (`beams-profiles` volume)

```text
/var/lib/teleport-slack/beams/<slack-team-id>/<slack-user-id>/
  delegation-session   delegation session ID after /beams connect
  threads/<ch>-<ts>.chat  chat messages for threads answered without a beam
  threads/<ch>-<ts>    beam used by each bot thread ("<beam> new" = no Claude conversation yet)
  pending-request      request (with its channel and thread) waiting for the user to authorize the bot
  identity-*           temp delegated identities, deleted after each command
```

## Terraform

`terraform/` deploys the stack: `teleport_bot` (default roles: preset
`access-plugin`, which already has user/user_login_state read, plus
`beam-user`), a `bound_keypair` `teleport_provision_token` with a
`random_password` registration secret (`recovery.mode = relaxed`), and
kreuzwerker/docker volumes plus `volume-init`, `tbot`, and plugin containers.
Configs and Slack tokens are `upload`ed into the containers from
`templates/*.tftpl` and variables, so state holds secrets. Provider creds:
`eval "$(tctl terraform env)"` (temporary bot with the preset
`terraform-provider` role). The Slack app comes from `slack-app-manifest.yaml`;
the image is built and pushed by hand. `terraform validate` passes with
teleport v18.11.3, kreuzwerker/docker v3.9.0, random v3.9.1. Not yet applied
anywhere; ventura still uses Compose.

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
- 2026-10-05: GitHub Actions had an incident, so the plugin image was built on
  ventura (`/usr/local/docker/beams-hackathon/build/`, tag
  `beams-slack-plugin:local-64df879` (earlier `local-9b24cf6`, `local-d016bb2`, `local-4487392`, `local-beccb8a`, `local-758c0b9`, `local-0d3b4c5`, `local-a077c6d`, `local-0faee65`, `local-398933f`)) and compose's `teleport-slack` image
  line points at that local tag (backup `docker-compose.yml.bak-*`). Switch
  back to `ghcr.io/geekvoice408/beams-slack-plugin:latest` and pull once CI
  works. Watchtower runs on ventura, which is why the local tag is distinct.

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
   `tsh` command; the bot accepts the session ID pasted in its thread and
   resumes the original request.
7. **A `tbot` sidecar** replaced the hand-signed `access-plugin` identity,
   which did not renew and could not use delegation.

Other fixes along the way: Socket Mode needs the `xapp-` token, not `xoxb-`;
slash commands must be registered in the Slack app; replies moved from
`chat.postMessage` to `response_url` (`channel_not_found`); `tsh` output has
ANSI colour stripped; Docker mount mistakes (creating a directory where a file
was expected, broken line continuations).

## Open items

1. Confirm a bot-published URL opens for its owner (the bot already runs
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
