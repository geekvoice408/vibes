# The Machine ID bot the plugin runs as. Beam actions themselves run as each
# Slack user through delegation sessions the user grants to this bot.
resource "teleport_bot" "plugin" {
  metadata = {
    name = var.bot_name
  }

  spec = {
    roles = var.bot_roles
  }
}

# Secret tbot uses once to register its keypair with the join token below.
resource "random_password" "registration_secret" {
  length  = 40
  special = false
}

# bound_keypair tokens survive the first join (unlike single-use `token`
# tokens), so later applies leave the running tbot alone, and tbot can rejoin
# with its key after an outage.
resource "teleport_provision_token" "tbot" {
  version = "v2"
  metadata = {
    name        = "${var.bot_name}-slack-plugin"
    description = "tbot for the Beams Slack plugin"
  }

  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.plugin.metadata.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        registration_secret = random_password.registration_secret.result
      }
      recovery = {
        # Allow rejoining after outages as long as tbot still has its key and
        # join state.
        mode = "relaxed"
      }
    }
  }
}
