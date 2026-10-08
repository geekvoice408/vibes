import Foundation

/// The bridge's tools, exactly as mcp/serverlife-mcp.mjs declares them: the
/// names, descriptions and input schemas a client sees, and the control verb
/// each one forwards to. (Generated from the original's TOOLS array.)
enum MCPTools {
    struct Tool {
        var name: String
        var description: String
        var verb: String
        var inputSchema: JSON
    }

    static let all: [Tool] = {
        guard let list = try? JSON.parse(definitions) else { return [] }
        return list.items.map { t in
            Tool(name: t["name"].string ?? "", description: t["description"].string ?? "", verb: t["verb"].string ?? "",
                 inputSchema: t["inputSchema"])
        }
    }()

    static let definitions = #"""
[
  {
    "name": "serverlife_status",
    "description": "What ServerLife is: version, platform, whether tsh and ssh were found, and which Teleport clusters are logged in.",
    "verb": "status",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_list_hosts",
    "description": "Every host ServerLife can open: Teleport nodes (with labels), ssh_config aliases and saved profiles. Use before opening a session to get names right.",
    "verb": "list_hosts",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "Substring match over names, clusters and labels."
        },
        "limit": {
          "type": "number",
          "description": "Maximum hosts to return (default 200)."
        }
      }
    }
  },
  {
    "name": "serverlife_list_sessions",
    "description": "The sessions currently open, per tab, with their panes and connection state.",
    "verb": "list_sessions",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_open_session",
    "description": "Open one session in ServerLife. The host is named as a person would: a Teleport node hostname, an ssh_config alias, a saved profile name, or \"local\".",
    "verb": "open_session",
    "inputSchema": {
      "type": "object",
      "required": [
        "host"
      ],
      "properties": {
        "host": {
          "type": "string",
          "description": "Host name, alias, profile name, or \"local\"."
        },
        "login": {
          "type": "string",
          "description": "Remote user to connect as."
        },
        "cluster": {
          "type": "string",
          "description": "Teleport cluster, when the same name exists in several."
        },
        "filesOnly": {
          "type": "boolean",
          "description": "Open the file browser with no terminal."
        },
        "split": {
          "type": "string",
          "enum": [
            "right",
            "down"
          ],
          "description": "Split the focused pane instead of opening a tab."
        },
        "tmux": {
          "type": "boolean",
          "description": "Run the session inside tmux on the host, so it survives this window going away. Left unset, the host’s own setting decides. Not available on hosts that ask for MFA per session."
        },
        "tmuxSession": {
          "type": "string",
          "description": "Which tmux session to attach to or create. Defaults to the host’s setting."
        }
      }
    }
  },
  {
    "name": "serverlife_open_sessions",
    "description": "Open a set of sessions in one go — the usual way to set up for a piece of work. Each entry takes the same fields as open_session; one failure does not stop the rest.",
    "verb": "open_sessions",
    "inputSchema": {
      "type": "object",
      "required": [
        "sessions"
      ],
      "properties": {
        "sessions": {
          "type": "array",
          "description": "Sessions to open, in order.",
          "items": {
            "type": "object",
            "required": [
              "host"
            ],
            "properties": {
              "host": {
                "type": "string"
              },
              "login": {
                "type": "string"
              },
              "cluster": {
                "type": "string"
              },
              "filesOnly": {
                "type": "boolean"
              },
              "split": {
                "type": "string",
                "enum": [
                  "right",
                  "down"
                ]
              },
              "tmux": {
                "type": "boolean"
              },
              "tmuxSession": {
                "type": "string"
              }
            }
          }
        },
        "stopOnError": {
          "type": "boolean",
          "description": "Stop at the first failure instead of carrying on."
        }
      }
    }
  },
  {
    "name": "serverlife_list_tmux",
    "description": "What tmux has running on a host, so you can resume a session rather than start another. Says whether tmux is installed there, and lists each session with its window count and whether something is attached. Dials the host to ask.",
    "verb": "list_tmux",
    "inputSchema": {
      "type": "object",
      "required": [
        "host"
      ],
      "properties": {
        "host": {
          "type": "string",
          "description": "Host name, alias or profile name."
        },
        "cluster": {
          "type": "string",
          "description": "Teleport cluster, when the same name exists in several."
        },
        "login": {
          "type": "string",
          "description": "Remote user to connect as."
        }
      }
    }
  },
  {
    "name": "serverlife_close_session",
    "description": "Close a session tab, by index (from list_sessions) or title. With all=true, closes every session.",
    "verb": "close_session",
    "inputSchema": {
      "type": "object",
      "properties": {
        "index": {
          "type": "number"
        },
        "title": {
          "type": "string"
        },
        "all": {
          "type": "boolean"
        }
      }
    }
  },
  {
    "name": "serverlife_list_layouts",
    "description": "Saved layouts — named arrangements of tabs and panes that can be reopened as a set.",
    "verb": "list_layouts",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_load_layout",
    "description": "Open a saved layout by name. This replaces whatever is open, dialling each session again.",
    "verb": "load_layout",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string"
        },
        "id": {
          "type": "string"
        }
      }
    }
  },
  {
    "name": "serverlife_save_layout",
    "description": "Save what is open now as a named layout.",
    "verb": "save_layout",
    "inputSchema": {
      "type": "object",
      "required": [
        "name"
      ],
      "properties": {
        "name": {
          "type": "string"
        }
      }
    }
  },
  {
    "name": "serverlife_list_clusters",
    "description": "Teleport clusters: which are logged in, as whom, when the certificate expires, which tsh home each is in, and which are saved for re-login.",
    "verb": "list_clusters",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_login_command",
    "description": "The tsh login command for a cluster, ready to paste into a terminal (TELEPORT_HOME included where it matters). Returns the command; it does not run it.",
    "verb": "login_command",
    "inputSchema": {
      "type": "object",
      "properties": {
        "cluster": {
          "type": "string"
        },
        "proxy": {
          "type": "string"
        },
        "user": {
          "type": "string"
        },
        "home": {
          "type": "string"
        }
      }
    }
  },
  {
    "name": "serverlife_list_beams",
    "description": "Beams — ephemeral sandbox VMs — on every logged-in cluster that runs the service, with their region and expiry. Use before syncing to one, to get the name right.",
    "verb": "list_beams",
    "inputSchema": {
      "type": "object",
      "properties": {
        "proxy": {
          "type": "string",
          "description": "Limit to one cluster proxy address."
        }
      }
    }
  },
  {
    "name": "serverlife_sync_preview",
    "description": "What a folder synchronisation would do between this machine and a server or a beam, without doing any of it: which files would be uploaded, downloaded or deleted, and why. Always worth calling before sync_apply, and the only safe way to check a direction.",
    "verb": "sync_preview",
    "inputSchema": {
      "type": "object",
      "required": [
        "local",
        "remote"
      ],
      "properties": {
        "host": {
          "type": "string",
          "description": "Server: a Teleport node hostname or an ssh_config alias."
        },
        "beam": {
          "type": "string",
          "description": "Beam name (or UUID), instead of host."
        },
        "cluster": {
          "type": "string",
          "description": "Teleport cluster, when the name exists in several."
        },
        "login": {
          "type": "string",
          "description": "Remote user to connect as."
        },
        "local": {
          "type": "string",
          "description": "Absolute path to the folder on this machine."
        },
        "remote": {
          "type": "string",
          "description": "Absolute path to the folder on the server or beam."
        },
        "direction": {
          "type": "string",
          "enum": [
            "up",
            "down",
            "both"
          ],
          "description": "up = this machine to the server (default), down = the other way, both = newer side wins."
        },
        "compare": {
          "type": "string",
          "enum": [
            "both",
            "size",
            "time"
          ],
          "description": "What makes two files the same. Default both (size and time)."
        },
        "delete": {
          "type": "boolean",
          "description": "Include removing what the source does not have. Off by default."
        }
      }
    }
  },
  {
    "name": "serverlife_sync_apply",
    "description": "Run a folder synchronisation between this machine and a server or a beam. Transfers appear in the app's transfer queue. Deleting is opt-in: without delete:true nothing is removed, only copied. Call sync_preview first and show the user what it will do.",
    "verb": "sync_apply",
    "inputSchema": {
      "type": "object",
      "required": [
        "local",
        "remote"
      ],
      "properties": {
        "host": {
          "type": "string",
          "description": "Server: a Teleport node hostname or an ssh_config alias."
        },
        "beam": {
          "type": "string",
          "description": "Beam name (or UUID), instead of host."
        },
        "cluster": {
          "type": "string",
          "description": "Teleport cluster, when the name exists in several."
        },
        "login": {
          "type": "string",
          "description": "Remote user to connect as."
        },
        "local": {
          "type": "string",
          "description": "Absolute path to the folder on this machine."
        },
        "remote": {
          "type": "string",
          "description": "Absolute path to the folder on the server or beam."
        },
        "direction": {
          "type": "string",
          "enum": [
            "up",
            "down",
            "both"
          ]
        },
        "compare": {
          "type": "string",
          "enum": [
            "both",
            "size",
            "time"
          ]
        },
        "delete": {
          "type": "boolean",
          "description": "Also remove what the source does not have — including folders, with their contents. Off by default; ask the user before turning it on."
        }
      }
    }
  },
  {
    "name": "serverlife_list_forwards",
    "description": "Port forwards: the tunnels open right now, and the ones the user has saved as favourites. Worth checking before opening anything, so a port already in use is not fought over.",
    "verb": "list_forwards",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_open_forward",
    "description": "Open one of the user’s saved tunnels, dialling its host first if needed. Only saved favourites can be opened — arbitrary ports and destinations cannot be asked for through this interface. list_forwards has the names.",
    "verb": "open_forward",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Favourite name, as listed by list_forwards."
        },
        "id": {
          "type": "string",
          "description": "Its id, if the name is ambiguous."
        }
      }
    }
  },
  {
    "name": "serverlife_list_requests",
    "description": "The HTTP requests the user has saved in Network Tools, with the method and URL of each.",
    "verb": "list_requests",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_run_request",
    "description": "Run one of the user’s saved HTTP requests and return the status, timing and body. Only saved requests can be run — this is not a way to fetch an arbitrary URL from the user’s machine.",
    "verb": "run_request",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "description": "Request name, as listed by list_requests."
        },
        "id": {
          "type": "string"
        },
        "limit": {
          "type": "number",
          "description": "Maximum body characters to return (default 4000)."
        }
      }
    }
  },
  {
    "name": "serverlife_list_macros",
    "description": "The macros the user has saved, with the command each one runs.",
    "verb": "list_macros",
    "inputSchema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "serverlife_run_macro",
    "description": "Run one of the user's saved macros in the focused session. Only saved macros can be run — there is no way to run an arbitrary command through this interface.",
    "verb": "run_macro",
    "inputSchema": {
      "type": "object",
      "required": [
        "name"
      ],
      "properties": {
        "name": {
          "type": "string",
          "description": "Macro name, as listed by list_macros."
        },
        "allPanes": {
          "type": "boolean",
          "description": "Run it in every pane of the focused tab."
        }
      }
    }
  }
]
"""#
}
