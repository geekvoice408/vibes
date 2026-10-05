# Beams Slack Plugin

<img src="assets/slack-beams-bot.png" alt="Teleport Beams Bot" width="128" align="right">

Manage [Teleport Beams](https://goteleport.com/) from Slack, either with a
`/beams` slash command or by asking the **Teleport Beams Bot** in plain language ("@Teleport Beams Bot
make a webpage about things to do in Seattle and publish it").

It is Teleport's Slack access plugin with a Beams app added. It is built from
the Teleport `v18.11.1` source (the newest public v18.11 tag) and ships with
`tsh` 18.11.3; the `tbot` sidecar runs 18.11.3 too. See
[Versions](#versions). It runs as a container next to `tbot`, talks to Slack
over Socket Mode, and needs no inbound ports or public URL.

**[Usage](#usage)** · **[Installation](#installation)** ·
**[Deploy with Terraform](#deploy-with-terraform)** ·
**[Development](#development)**

## What it does

- **`/beams` slash commands**: list, create, run commands in, publish, copy
  files to, and delete beams. Replies are private to the person who ran them.
- **Teleport Beams Bot**: mention `@Teleport Beams Bot`, DM it, or start a
  message with "Teleport Beams Bot". Questions get a quick answer from Claude
  or Codex through Teleport, with every request in the audit log. Requests
  that need a computer go to one of your beams, where Claude Code or Codex does
  the work, publishes the result if asked, and replies in a thread. Replies in
  that thread continue the same conversation.
- **Who you are**: the plugin looks up your Slack email, finds the Teleport
  user with that username, and lets you in only if that user has the
  configured role (`beam-user`). No list of Slack IDs to maintain.
- **Acts as you**: every beam action runs as your own Teleport user, so you
  own your beams, can open their published URLs, and only see your own. You
  authorize this once (up to 7 days) with a `tsh` command the plugin gives
  you.

Ask for a web page and get back a URL you can open:

<img src="assets/screenshots/bot-publish-webpage.png" alt="Teleport Beams Bot builds a page about Seattle's Ballard neighborhood in a beam and replies with the published URL" width="560">

## Usage

**Teleport Beams** are short-lived computers in the cloud where AI assistants
can do work for you, safely. Each beam belongs to you, everything done in it
is recorded under your name, and it cleans itself up after a day.

Here's what you can do, right in Slack:

- **Ask the bot for things in plain English.** For example: "@Teleport Beams Bot make
  a webpage about things to do in Ballard and share it." Teleport Beams Bot does the work in
  one of your beams and replies with a link. Mention it in a channel, and it
  answers in a thread under your message:

  <img src="assets/screenshots/bot-ask-in-channel.png" alt="A user mentions @Teleport Beams Bot in a channel asking for a webpage about fun things to do in Seattle" width="560">

  <img src="assets/screenshots/bot-ask-thread.png" alt="Teleport Beams Bot replies in the thread that it is working in the user's beam" width="480">

- **Just ask questions.** Something like "what should I eat for lunch?" gets a
  quick answer from Claude (or Codex) without starting a beam, and follow-ups
  in the thread keep the conversation going. Requests that need a computer,
  like writing code or building a page, go to a beam automatically. Every
  request is recorded in Teleport's audit log under your name.
- **Keep going in the same thread** to make changes, like "make the title
  bigger."
- **Share what you made.** Ask the bot to publish it and you get a link you can
  open after signing in to Teleport.
- **See your beams** by asking "how many beams do I have?"
- **Start fresh** by asking for a new beam, and **clean up** by asking Teleport Beams Bot
  to "delete curious-shield", "delete this beam" in its thread, or "delete
  all my beams".
- **Pick your assistant.** Teleport Beams Bot uses Claude Code unless you say "use codex"
  (or "use claude" to switch back):

  <img src="assets/screenshots/bot-codex.png" alt="A request ending in 'use codex' gets 'Using Codex for this thread.' and Codex's answer" width="480">

Comfortable with commands? `/beams help` lists everything, including running
Claude Code or Codex yourself (see [Slash commands](#slash-commands)).

Teleport Beams Bot gives this same overview if you ask it "what can I do with beams?"
or "what is a beam?":

<img src="assets/screenshots/bot-what-is-a-beam.png" alt="Teleport Beams Bot answers 'what is a beam' with a plain-language overview of Teleport Beams and what you can do in Slack" width="560">

Learn more in the [Teleport Beams docs](https://goteleport.com/docs/beams/).

## Slash commands

```text
/beams help
/beams status
/beams ls
/beams add [--region=<region>]
/beams exec <name> <command...>
/beams claude <name> [--continue] <prompt...>
/beams codex <name> [--continue] <prompt...>
/beams publish <name> [--tcp]
/beams unpublish <name>
/beams rm <name>
/beams scp <src> <dst>             # remote side is <name>:<path>
/beams connect [<delegation-session-id>]
/beams disconnect
```

- `ls` lists your beams with region, time left, and published URL:

  <img src="assets/screenshots/beams-ls.png" alt="/beams ls listing four beams with their regions, expiry times, and published URLs" width="720">

- `exec` runs over SSH as a single shell string, so quote commands that use
  `&&`, pipes, or redirects: `/beams exec crisp-array "cd /app && make"`.
  Other commands are split into words like a shell, so wrap any argument
  that contains an apostrophe in double quotes. Beam names pasted from Slack
  code formatting (with backticks) work as is.
- `claude` and `codex` run a coding agent in the beam and post its answer:
  Claude Code (`claude -p`) or Codex (`codex exec`). Both come preinstalled
  and preconfigured in every beam. Each run has a 15 minute limit, and
  `--continue` (or `-c`) resumes that agent's previous conversation in the
  beam, for example `/beams codex fabled-firefly -c add a dark mode`.
  Everything after the beam name (and `-c`) is sent as typed, so prompts can
  contain apostrophes without quoting. Teleport Beams Bot can use either one; see
  [Teleport Beams Bot](#teleport-beams-bot).
- `publish` exposes port 8080 in the beam as a Teleport app.
- Interactive `/beams ssh` is not supported; use `exec`.
- A brand-new beam takes a moment to accept SSH; commands retry for up to 3
  minutes.
- Until you connect, every beam command replies with the authorization
  instructions instead of running.

## Teleport Beams Bot

Talk to Teleport Beams Bot in any of these ways:

- `@Teleport Beams Bot <request>` in a channel the app is in
- a direct message to the app
- a channel message starting with "Teleport Beams Bot" (needs the
  `message.channels` event)
- a reply in a thread Teleport Beams Bot is already working in (no mention needed)

The first time (and again when your authorization expires), Teleport Beams Bot
sets up access with you in a direct message, so nothing about your credentials
is posted in a shared channel. The thread just gets a note that it has messaged
you, and the DM says:

> **Before we can get started, you need to allow me to create beams as you.**
>
> 1. Run this in a terminal (`tsh` signs you in to Teleport if needed):
>    `tsh delegation create-session --proxy=... --user=you@example.com ...`
> 2. Reply to me here with the session ID it prints and I'll pick up your
>    request in its thread.

The command already includes your Teleport username, matched from your Slack
email. Reply to the DM with the session ID (or the whole command output);
Teleport Beams Bot connects you and then carries out your original request back
in the thread where you asked it. This is the same connection `/beams connect`
makes, and it lasts up to 7 days.

In the channel, the thread only gets a pointer to the DM, and the request is
answered there once you're connected:

<img src="assets/screenshots/bot-authorize-thread.png" alt="The bot replies in the channel thread that it sent a direct message to set up access, then answers the request after the user connects" width="560">

The direct message with the instructions, and the reply with the session ID
(the tenant name, email, and session ID are hidden):

<img src="assets/screenshots/bot-authorize-dm.png" alt="Teleport Beams Bot's direct message with the tsh delegation command, and the user's reply with the session ID (hidden)" width="720">

Questions about which beams you have ("how many beams do I have", "list my
beams") are answered straight from `tsh beams ls` in a second or two. Anything
else starts a Claude Code or Codex session in a beam, which usually takes a minute or
more; Teleport Beams Bot posts "On it" right away so you know it is working. Teleport Beams Bot works
on one request per thread at a time: if you send another message while it is
busy, it replies "Still working on your earlier request" and handles your
newest message as soon as the current one finishes.

<img src="assets/screenshots/bot-list-beams.png" alt="Teleport Beams Bot answers 'how many beams do I have' with a list of beams, regions, and expiry times" width="560">

### Chat answers

Questions that don't need a computer ("what should I eat for lunch?", "explain
DNS like I'm five") are answered by the model directly, with no beam. Teleport
Beams Bot asks Teleport for a short-lived certificate for the tenant's `anthropic`
app (or `openai` with "use codex") as you, through your delegation, and sends
the request through Teleport's app proxy, which adds the provider's API key.
Every chat request is an app session in Teleport's audit log, attributed to you
and the bot.

The model is told to hand off anything that needs a computer: writing,
running, or testing code, creating files or pages, installing software,
publishing, or managing beams. Those requests continue in a beam as described
below, with the chat so far passed to the coding agent as context. Once a
thread is working in a beam, follow-ups go to the agent in that beam, and
naming one of your beams always goes straight to it. If the model apps aren't
available, every request goes to a beam as before.

The chat models are set with `chat_claude_model` (default `claude-sonnet-4-5`)
and `chat_codex_model` (default `gpt-5`); the tenant maps these names to the
models it serves. `disable_chat = true` turns chat answers off.

### Work in a beam

For requests that need a computer, Teleport Beams Bot:

1. Picks one of your own beams: the one this thread already uses, a beam you
   named, or your newest. If you have none, it creates one, owned by you.
2. Runs a coding agent in that beam with your request: Claude Code by
   default, or Codex if you say "use codex", "with codex", or start with
   "codex". The thread keeps using that agent (say "use claude" to switch
   back), and switching starts a fresh conversation. The agent is told to
   serve anything it wants to share on port 8080 in the background.
3. Carries out actions the agent asks for (`publish`, `unpublish`,
   `create_beam`) from outside the beam, since it cannot manage beams from
   inside the VM.
4. Replies in the thread with the agent's answer and any published URL.

Asking for another beam creates one, and the rest of that thread works in it:

<img src="assets/screenshots/bot-create-beam.png" alt="Teleport Beams Bot creates a new beam on request" width="560">

To delete beams, tell Teleport Beams Bot "delete" followed by their names (for example
"delete curious-shield and mint-arc"), "delete this beam" in the beam's
thread, or "delete all my beams". Teleport Beams Bot handles this itself rather than asking the coding agent, and
only when the beam names come right after the word "delete" or "remove", so a
request like "remove the header from the page in mint-arc" is still sent to
the agent. You can also use `/beams rm <name>`.

Teleport Beams Bot is an engineer at heart, not a transporter operator, so
don't ask it for a lift.

## Authorizing the plugin to act as you

Teleport v18 does not let a bot impersonate an SSO user, and only you can
create a delegation session for yourself (with MFA). So the first time you use
`/beams` or Teleport Beams Bot, and again when your authorization expires, the plugin
replies:

> **Before we can get started, you need to allow me to create beams as you.**
>
> 1. Run this in a terminal (`tsh` signs you in to Teleport if needed):
>    `tsh delegation create-session --proxy=example-beams-tenant.beams.sh:443 --user=you@example.com --bot=teleport-beams-bot --allow-all --session-ttl=168h`
> 2. Run `/beams connect <session-id>` with the ID it prints.

With slash commands the prompt is a reply only you can see. This is how it
looks (the tenant name and email are hidden):

<img src="assets/screenshots/beams-connect-prompt.png" alt="The plugin's private reply asking the user to run tsh delegation create-session and then /beams connect" width="720">

Run it, then hand back the session ID it prints:

- with Teleport Beams Bot: reply to its direct message; it then carries out
  your request in the thread where you asked it
- with slash commands: `/beams connect <session-id>`

For the next 7 days every beam action runs as your Teleport user: beams are
owned by you, published URLs open for you, and Teleport keeps your beams
separate from everyone else's. `/beams disconnect` forgets the session.

The plugin never creates or touches beams as its own bot identity.

## Installation

### 1. Teleport

The plugin runs as a Machine ID bot (named `teleport-beams-bot` here). Its role needs
`read` and `list` on `user` and `user_login_state` so it can match Slack
emails to Teleport users. The deployment uses `access-plugin` (the role
Teleport's Slack plugin normally uses, extended with those rules) plus
`beam-user`. Beam actions themselves run as each user through delegation, so
the bot does not strictly need `beam-user` any more.

```sh
tctl bots add teleport-beams-bot --roles=access-plugin,beam-user    # or: tctl bots update teleport-beams-bot --set-roles=...
tctl bots instances add teleport-beams-bot                         # prints a one-time join token
```

Each person who uses the plugin needs a Teleport user whose username is their
Slack email (true for typical SSO setups) and the `beam-user` role. SSO users
only exist in Teleport while their login is current, so someone who has never
signed in is told to sign in once and retry.

### 2. Slack app

The quickest way is to create the app from
[`slack-app-manifest.yaml`](slack-app-manifest.yaml): at
<https://api.slack.com/apps>, choose **Create New App → From a manifest**, pick
your workspace, and paste the file. It sets up everything below except the
app-level token and the icon. To configure an existing app by hand instead:

- **Socket Mode**: on. Create an app-level token (`xapp-...`) with
  `connections:write`.
- **Slash Commands**: add `/beams`.
- **Event Subscriptions**: on (no request URL needed with Socket Mode).
  Subscribe to bot events `app_mention`, `message.im`, `message.channels`,
  and `message.groups` for private channels. The plugin ignores channel
  messages that are not meant for Teleport Beams Bot.
- **OAuth & Permissions, Bot Token Scopes**: `commands`, `chat:write`,
  `users:read`, `users:read.email`, `app_mentions:read`, `im:history`,
  `channels:history`, `groups:history`.
- **App Home**: enable the Messages tab and "Allow users to send messages".
  Set the display name to `Teleport Beams Bot`.
- **App icon**: see [Set the bot's icon](#set-the-bots-icon) below.
- **Install / Reinstall to Workspace** after any scope change, then
  `/invite` the app to the channels where it should listen. Once added, it
  shows under the channel's **Agents & apps** tab:

  <img src="assets/screenshots/slack-channel-app.png" alt="The Teleport Beams app listed under a channel's Agents and apps tab" width="480">

#### Set the bot's icon

The bot's icon is [`assets/slack-beams-bot.png`](assets/slack-beams-bot.png), a
1024 x 1024 PNG.

1. Download it. On GitHub, open the file and click **Download raw file**, or
   use the copy in your clone of this repo.
2. At <https://api.slack.com/apps>, open the app and go to **Basic
   Information**.
3. Scroll to **Display Information**. Under **App icon**, click **Add App
   Icon** (or the current icon) and upload `slack-beams-bot.png`. Slack accepts
   square images from 512 x 512 to 2000 x 2000 pixels.
4. Set **Background color** to `#3B2A9E`, the icon's own purple, so it
   blends in. Set **App name** to `Teleport Beams Bot` and fill in a short description if
   you like.
5. Click **Save Changes**. The new icon appears on the bot's messages and
   profile within a few minutes. No reinstall is needed for the icon.

### 3. Build and host the image

The plugin image is not published publicly, so build it yourself and put it
in a registry your Docker host can pull from (or build it on that host).
From this directory:

```sh
docker build --platform linux/amd64 -t <registry>/beams-slack-plugin:latest .
docker push <registry>/beams-slack-plugin:latest
```

The build clones Teleport, applies `teleport.patch`, and bundles `tsh`, so it
takes a while. Then tell Compose which image to run:

```sh
export BEAMS_SLACK_PLUGIN_IMAGE=<registry>/beams-slack-plugin:latest
```

`docker-compose.yml` refuses to start without it. You can also put the value
in a `.env` file next to `docker-compose.yml`.

### 4. Run it

Run it with Docker Compose as below, or let Terraform deploy everything,
including the Teleport bot and join token: see
[Deploy with Terraform](#deploy-with-terraform).

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
- `tbot` joins as `teleport-beams-bot` and keeps an identity file renewed (every 20
  minutes) in the `plugin-identity` volume. The join token is only used once;
  `tbot` renews from the `tbot-state` volume afterwards. If that volume is
  lost, or `tbot` is down longer than its 1 hour certificate, create a new
  instance token.
- `teleport-slack` is the plugin, running the image you built and set in
  `BEAMS_SLACK_PLUGIN_IMAGE`. `secrets/` is mounted at
  `/var/lib/teleport/plugins/slack`, and per-user state lives in the external
  `beams-profiles` volume.

To deploy a new image, build and push it again, then:

```sh
docker compose pull teleport-slack && docker compose up -d --no-deps teleport-slack
```

### 5. Configuration

Start from `config.toml.example`. The Beams settings:

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Turn on `/beams` and Teleport Beams Bot |
| `proxy` | `teleport.addr` | Teleport proxy for `tsh` |
| `plugin_identity` | `teleport.identity` | Identity file from `tbot` |
| `tsh_path` | `tsh` | `tsh` binary (bundled in the image) |
| `profiles_dir` | temp dir | Per-user state; use the `beams-profiles` volume |
| `required_role` | none | Teleport role a Slack user's matching Teleport user must have |
| `users` | none | Optional `"<slack-user-id>" = "<teleport-user>"` overrides that skip the role check |
| `bot_name` | none | Bot named in delegation sessions (`teleport-beams-bot`); required to use Beams |
| `delegation_ttl` | `168h` | Session length in the suggested `tsh` command (Teleport max 7 days) |
| `identity_ttl` | `15m` | Lifetime of per-command delegated certificates (max 1h) |
| `command_timeout` | `2m` | Limit for normal commands |
| `claude_timeout` | `15m` | Limit for `/beams claude` and the bot's Claude runs |
| `claude_args` | `["--dangerously-skip-permissions"]` | Extra Claude Code flags. Print mode cannot ask for tool approval, and beams are throwaway runtimes. |
| `codex_timeout` | `15m` | Limit for `/beams codex` and the bot's Codex runs |
| `chat_claude_model` | `claude-sonnet-4-5` | Model for chat answers through the `anthropic` app |
| `chat_codex_model` | `gpt-5` | Model for chat answers through the `openai` app ("use codex") |
| `disable_chat` | `false` | Send every request to a coding agent in a beam instead of answering chat questions directly |
| `codex_args` | `["--dangerously-bypass-approvals-and-sandbox"]` | Extra Codex flags, for the same reason. `--skip-git-repo-check` is always added because a beam's home directory is not a Git repository. |

`required_role` or `users` must be set. Socket Mode reuses `review.app_token`
for the `xapp-` token even when access-request review is disabled.

## Deploy with Terraform

[`terraform/`](terraform) deploys the whole stack in one apply:

- **Teleport:** the `teleport-beams-bot` bot (roles `access-plugin`, Teleport's preset
  role for access plugins, plus `beam-user`) and a `bound_keypair` join token
  with a generated registration secret. Unlike a one-time join token, it isn't
  used up, so later applies leave the running `tbot` alone, and `tbot` can
  rejoin with its key after an outage.
- **Docker:** the `tbot` and plugin containers and their volumes, on the local
  Docker daemon or a remote one over SSH. The configs and Slack tokens are
  copied into the containers as files, so the host needs no checkout.

The Slack app and the plugin image stay manual: Slack has no Terraform
provider for apps, and the image has to be built and pushed somewhere your
Docker host can pull from.

### Bootstrap

1. **Slack app.** Create it from the manifest and set its icon ([Slack
   app](#2-slack-app)). Install it to the workspace, then copy the **Bot User
   OAuth Token** (`xoxb-…`, under **OAuth & Permissions**) and create an
   app-level token (`xapp-…`) with `connections:write` under **Basic
   Information → App-Level Tokens**.
2. **Plugin image.** Build and push it ([Build and host the
   image](#3-build-and-host-the-image)). Use an immutable tag such as
   `sha-<commit>`, so Terraform deploys exactly that build.
3. **Teleport credentials for Terraform.** Sign in as a Teleport user who can
   create bots, roles and join tokens (for example with the `editor` role),
   then let `tctl` mint short-lived credentials for the provider:

   ```sh
   tsh login --proxy=example-beams-tenant.beams.sh:443
   eval "$(tctl terraform env)"
   ```

4. **Docker access.** Make sure `docker ps` works against the target host. For
   a remote host, use SSH (`docker_host = "ssh://user@host"`); your SSH user
   needs to be allowed to use Docker there.
5. **Variables.** Copy the example and fill it in. The file is git-ignored.

   ```sh
   cd terraform
   cp terraform.tfvars.example terraform.tfvars
   ```

   At minimum set `teleport_proxy`, `plugin_image`, `slack_bot_token`, and
   `slack_app_token` (or pass the tokens as `TF_VAR_slack_bot_token` and
   `TF_VAR_slack_app_token`). See `variables.tf` for the rest.
6. **Apply.**

   ```sh
   terraform init
   terraform apply
   ```

7. **Check it.** `tbot` should log "Identity initialized successfully" and the
   plugin "Receiving Socket Mode events":

   ```sh
   docker logs beams-slack-tbot
   docker logs beams-slack-plugin
   ```

   Then `/invite` the app to a channel and ask it "what can I do with beams?".

Users still need a Teleport user named after their Slack email with the
`beam-user` role, and they authorize the bot the first time they use it
([Authorizing the plugin to act as you](#authorizing-the-plugin-to-act-as-you)).

### Updating and secrets

- **New plugin build:** push it, set `plugin_image` to the new tag, and
  `terraform apply`. Only the plugin container is replaced.
- **Rotating Slack tokens:** update the variables and apply; the plugin
  container is recreated with the new files.
- **State holds secrets.** The Slack tokens and the bot's registration secret
  are in Terraform state, so keep state in an encrypted, access-controlled
  backend rather than a shared or committed `terraform.tfstate`.
- Destroying the stack deletes the volumes, including users' delegation
  sessions; they will be asked to authorize the bot again.

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
| `beams_app.go` | Socket Mode loop, slash-command and Teleport Beams Bot message handlers |
| `beams_commands.go` | `/beams` commands, user lookup, delegation and authorization prompts, `tsh` runner |
| `beams_bot.go` | Teleport Beams Bot request parsing, beam and agent choice, agent prompt, actions |
| `socketmode.go`, `types.go` | Slash-command and Events API envelope decoding |
| `bot.go` | Slack replies (`response_url` and threaded `chat.postMessage`) |
| `config.go` | `[beams]` settings and validation |

## Container builds

The original repository has a GitHub Actions workflow
(`.github/workflows/beams-slack-plugin-container.yml`) that builds pull
requests and pushes `main` to a private GitHub Container Registry package with
tags `latest`, `main`, and `sha-<commit>`. That package is not publicly
accessible, so use your own registry as described in
[Build and host the image](#3-build-and-host-the-image). The image bundles
`tsh` 18.11.3; override the `TSH_VERSION` build argument when the tenant is
upgraded.

## Versions

| Piece | Version | Set in |
| --- | --- | --- |
| Plugin source (`teleport.patch` base) | `v18.11.1` | `Dockerfile` `TELEPORT_REF` |
| Bundled `tsh` | 18.11.3 | `Dockerfile` `TSH_VERSION` |
| `tbot` sidecar | 18.11.3 | `docker-compose.yml` |

Teleport published 18.11.3 binaries without a public `v18.11.3` source tag,
so the plugin is built from `v18.11.1`, the newest tag available. Mixing patch
releases within 18.11 is supported. Move `TELEPORT_REF` (and rebase
`teleport.patch`) when a newer tag is published.
