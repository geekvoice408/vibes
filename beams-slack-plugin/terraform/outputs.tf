output "bot_name" {
  description = "Bot users authorize with `tsh delegation create-session --bot=...`."
  value       = teleport_bot.plugin.metadata.name
}

output "plugin_container" {
  description = "Plugin container name, for `docker logs`."
  value       = docker_container.plugin.name
}

output "tbot_container" {
  description = "tbot container name, for `docker logs`."
  value       = docker_container.tbot.name
}
