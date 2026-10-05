variable "teleport_proxy" {
  description = "Teleport proxy address of the Beams tenant, host:port."
  type        = string
}

variable "bot_name" {
  description = "Machine ID bot the plugin runs as. Users name it in `tsh delegation create-session --bot=...`."
  type        = string
  default     = "scotty"
}

variable "bot_roles" {
  description = "Roles for the bot. access-plugin is Teleport's preset role for access plugins and includes reading users, which the Slack email lookup needs."
  type        = list(string)
  default     = ["access-plugin", "beam-user"]
}

variable "required_role" {
  description = "Teleport role a Slack user's matching Teleport user must hold to use the plugin."
  type        = string
  default     = "beam-user"
}

variable "slack_bot_token" {
  description = "Slack bot token (xoxb-...)."
  type        = string
  sensitive   = true
}

variable "slack_app_token" {
  description = "Slack app-level token (xapp-...) with the connections:write scope, used for Socket Mode."
  type        = string
  sensitive   = true
}

variable "access_request_recipients" {
  description = "Slack channels for the underlying access plugin's access request notifications. The plugin requires at least one."
  type        = list(string)
  default     = ["beams-access"]
}

variable "docker_host" {
  description = "Docker daemon to deploy to, for example unix:///var/run/docker.sock or ssh://user@host."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "registry_auth" {
  description = "Credentials for the registry hosting plugin_image, if it is private."
  type = object({
    address  = string
    username = string
    password = string
  })
  default   = null
  sensitive = true
}

variable "plugin_image" {
  description = "Plugin image you built and pushed (README \"Build and host the image\"). Prefer an immutable tag such as sha-<commit>."
  type        = string
}

variable "tbot_image" {
  description = "tbot image."
  type        = string
  default     = "public.ecr.aws/gravitational/tbot-distroless:18.11.3"
}

variable "name_prefix" {
  description = "Prefix for Docker container and volume names."
  type        = string
  default     = "beams-slack"
}

variable "delegation_ttl" {
  description = "Delegation session length suggested to users (Teleport allows up to 168h)."
  type        = string
  default     = "168h"
}

variable "agent_timeout" {
  description = "Time limit for Claude Code and Codex runs."
  type        = string
  default     = "15m"
}

variable "log_severity" {
  description = "Plugin log level: DEBUG, INFO, WARN, or ERROR."
  type        = string
  default     = "INFO"
}
