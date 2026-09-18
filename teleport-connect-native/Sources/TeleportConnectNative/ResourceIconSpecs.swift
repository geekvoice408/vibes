/// Combined icon table: custom (hand-added, homelab) entries take precedence over Teleport's
/// own set on name collision, since they're more likely to be exactly what this user meant.
let resourceIconSpecs: [String: (dark: String, light: String)] =
    teleportResourceIconSpecs.merging(customResourceIconSpecs) { _, custom in custom }

let resourceIconNames: [String] = Array(resourceIconSpecs.keys).sorted()
