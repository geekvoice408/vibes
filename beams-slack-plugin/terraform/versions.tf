terraform {
  required_version = ">= 1.5"

  required_providers {
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Credentials come from the environment, for example from
# `eval "$(tctl terraform env)"`. See README "Deploy with Terraform".
provider "teleport" {
  addr = var.teleport_proxy
}

provider "docker" {
  host = var.docker_host

  dynamic "registry_auth" {
    for_each = var.registry_auth == null ? [] : [var.registry_auth]
    content {
      address  = registry_auth.value.address
      username = registry_auth.value.username
      password = registry_auth.value.password
    }
  }
}
