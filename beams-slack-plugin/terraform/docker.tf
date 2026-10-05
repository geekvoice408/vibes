locals {
  # Both containers run as this UID; the image's teleport-slack user and tbot.
  uid = "10001"

  identity_dir = "/var/lib/teleport-slack/identity"
  secrets_dir  = "/var/lib/teleport-slack/secrets"
  profiles_dir = "/var/lib/teleport-slack/beams"
}

resource "docker_volume" "tbot_state" {
  name = "${var.name_prefix}-tbot-state"
}

resource "docker_volume" "plugin_identity" {
  name = "${var.name_prefix}-plugin-identity"
}

# Per-user delegation sessions and bot thread state.
resource "docker_volume" "beams_profiles" {
  name = "${var.name_prefix}-beams-profiles"
}

resource "docker_image" "busybox" {
  name         = "busybox:1.37"
  keep_locally = true
}

resource "docker_image" "tbot" {
  name         = var.tbot_image
  keep_locally = true
}

resource "docker_image" "plugin" {
  name         = var.plugin_image
  keep_locally = true
}

# New volumes are owned by root; hand them to the UID both containers run as.
resource "docker_container" "volume_init" {
  name     = "${var.name_prefix}-volume-init"
  image    = docker_image.busybox.image_id
  command  = ["chown", "-R", "${local.uid}:${local.uid}", "/tbot", "/identity", "/beams"]
  attach   = true
  must_run = false

  volumes {
    volume_name    = docker_volume.tbot_state.name
    container_path = "/tbot"
  }
  volumes {
    volume_name    = docker_volume.plugin_identity.name
    container_path = "/identity"
  }
  volumes {
    volume_name    = docker_volume.beams_profiles.name
    container_path = "/beams"
  }
}

resource "docker_container" "tbot" {
  name    = "${var.name_prefix}-tbot"
  image   = docker_image.tbot.image_id
  command = ["start", "-c", "/etc/tbot.yaml"]
  user    = "${local.uid}:${local.uid}"
  restart = "unless-stopped"

  security_opts = ["no-new-privileges:true"]
  capabilities {
    drop = ["ALL"]
  }

  upload {
    file = "/etc/tbot.yaml"
    content = templatefile("${path.module}/templates/tbot.yaml.tftpl", {
      proxy               = var.teleport_proxy
      token               = teleport_provision_token.tbot.metadata.name
      registration_secret = random_password.registration_secret.result
      identity_dir        = local.identity_dir
    })
  }

  volumes {
    volume_name    = docker_volume.tbot_state.name
    container_path = "/var/lib/tbot"
  }
  volumes {
    volume_name    = docker_volume.plugin_identity.name
    container_path = local.identity_dir
  }

  depends_on = [docker_container.volume_init]
}

resource "docker_container" "plugin" {
  name    = "${var.name_prefix}-plugin"
  image   = docker_image.plugin.image_id
  restart = "unless-stopped"

  security_opts = ["no-new-privileges:true"]
  capabilities {
    drop = ["ALL"]
  }

  upload {
    file = "/etc/teleport-slack/config.toml"
    content = templatefile("${path.module}/templates/config.toml.tftpl", {
      proxy                     = var.teleport_proxy
      identity_file             = "${local.identity_dir}/identity"
      secrets_dir               = local.secrets_dir
      profiles_dir              = local.profiles_dir
      bot_name                  = teleport_bot.plugin.metadata.name
      required_role             = var.required_role
      delegation_ttl            = var.delegation_ttl
      agent_timeout             = var.agent_timeout
      access_request_recipients = jsonencode(var.access_request_recipients)
      log_severity              = var.log_severity
    })
  }
  upload {
    file    = "${local.secrets_dir}/slack-bot-token"
    content = var.slack_bot_token
  }
  upload {
    file    = "${local.secrets_dir}/slack-app-token"
    content = var.slack_app_token
  }

  volumes {
    volume_name    = docker_volume.plugin_identity.name
    container_path = local.identity_dir
    read_only      = true
  }
  volumes {
    volume_name    = docker_volume.beams_profiles.name
    container_path = local.profiles_dir
  }

  # The plugin exits if the identity is missing at start; restart covers the
  # first seconds while tbot joins.
  depends_on = [docker_container.tbot]
}
