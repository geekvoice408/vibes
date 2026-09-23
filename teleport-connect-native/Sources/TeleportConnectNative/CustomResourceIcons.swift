// Icons for self-hosted apps that aren't in Teleport's own design-system icon set (which is
// aimed at enterprise SaaS, not homelab tools). Sourced from github.com/selfhst/icons
// (CC-BY-4.0), a project maintained specifically for this: dashboard icons for self-hosted
// software. Merged with teleportResourceIconSpecs in ResourceIconSpecs.swift.
//
// Using the plain (non -dark/-light-suffixed) filenames deliberately: unlike Teleport's own
// icon set, several of selfhst/icons' "-dark"/"-light" variants ship as bare, colorless SVG
// paths (no fill at all, so they render solid black) — the plain filename is consistently the
// real full-color logo, and full-color logos read fine on both a light and dark background.
let customResourceIconSpecs: [String: (dark: String, light: String)] = [
    "loki": (dark: "loki.svg", light: "loki.svg"),
    "prowlarr": (dark: "prowlarr.svg", light: "prowlarr.svg"),
    "sonarr": (dark: "sonarr.svg", light: "sonarr.svg"),
    "radarr": (dark: "radarr.svg", light: "radarr.svg"),
    "aruba": (dark: "hpe-aruba.svg", light: "hpe-aruba.svg"),
    "nzbget": (dark: "nzbget.svg", light: "nzbget.svg"),
    // No SVG available upstream for tunarr, only a PNG — NSImage loads it the same way.
    "tunarr": (dark: "tunarr.png", light: "tunarr.png"),

    // Keyed by this user's actual app name (not the upstream project name) so the direct
    // lookup in GuessAppIcon hits without relying on substring matching.
    "seerr": (dark: "overseerr.svg", light: "overseerr.svg"),
    "overseerr": (dark: "overseerr.svg", light: "overseerr.svg"),
    "scrypted": (dark: "scrypted.svg", light: "scrypted.svg"),
    "semaphore": (dark: "semaphore-ui.svg", light: "semaphore-ui.svg"),
    // "synology-ui" becomes "synologyui" after guessAppIcon strips dashes; registering
    // "synology" alone still matches it via the substring fallback scan.
    "synology": (dark: "synology.svg", light: "synology.svg"),
    "tantulli": (dark: "tautulli.svg", light: "tautulli.svg"),
    "tautulli": (dark: "tautulli.svg", light: "tautulli.svg"),

    "homeassistant": (dark: "home-assistant.svg", light: "home-assistant.svg"),
    // The Kubernetes Dashboard project doesn't have its own logo — it uses the Kubernetes
    // wheel mark, which Teleport's own icon set already ships as "kube" (kube.svg).
    "k8sdashboard": (dark: "kube.svg", light: "kube.svg"),

    // No real logo exists for this one (looks like an internal/custom tool) — an original
    // little robot icon instead of guessing at a brand that isn't there.
    "poebounce": (dark: "poe-bounce.svg", light: "poe-bounce.svg"),

    // Servers whose "board_info" label names the hardware get this instead of the generic
    // server icon — see AppModel.row(from:)'s .server case.
    "raspberrypi": (dark: "raspberry-pi.svg", light: "raspberry-pi.svg"),

    // Original icon (no real brand to match) for this specific personal server: beach/media
    // server/production themed per request.
    "ventura": (dark: "ventura.svg", light: "ventura.svg"),

    // Servers with a "work-tools" label (name or value) get a crossed hammer/wrench icon.
    "worktools": (dark: "work-tools.svg", light: "work-tools.svg"),
]
