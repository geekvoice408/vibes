import Foundation

/// Swift port of shared/components/UnifiedResources/shared/guessAppIcon.ts + the primaryIconName
/// selection logic in viewItemsFactory.ts (getDatabaseIconName + the per-kind switch). Names
/// returned here are keys into `resourceIconSpecs` (ResourceIconSpecs.generated.swift).
enum GuessAppIcon {
    static func forApp(
        name: String,
        friendlyName: String,
        awsConsole: Bool,
        teleportIconLabel: String?
    ) -> String {
        if let override = teleportIconLabel {
            if override == "default" { return "application" }
            if resourceIconSpecs[override] != nil { return override }
        }

        let n = withoutWhiteSpaces(name).lowercased()
        let fn = withoutWhiteSpaces(friendlyName).lowercased()

        func match(_ target: String) -> Bool {
            n.contains(target) || (!fn.isEmpty && fn.contains(target))
        }

        if awsConsole {
            if match("quick"), match("sight") || match("suite") {
                return "awsquicksight"
            }
            return "awsidentityandaccessmanagementiam"
        }

        if resourceIconSpecs[n] != nil { return n }
        if !fn.isEmpty, resourceIconSpecs[fn] != nil { return fn }

        if match("adobe") {
            if match("creative") { return "adobecreativecloud" }
            if match("marketo") { return "adobemarketo" }
            return "adobe"
        }
        if match("atlassian") {
            if match("bitbucket") { return "atlassianbitbucket" }
            if match("jiraservice") { return "atlassianjiraservice" }
            if match("status") { return "atlassianstatus" }
            return "atlassian"
        }
        if match("google") {
            if match("analytic") { return "googleanalytics" }
            if match("calendar") { return "googlecalendar" }
            if match("cloud") { return "googlecloud" }
            if match("drive") { return "googledrive" }
            if match("gemini") { return "gemini" }
            if match("tag") { return "googletag" }
            if match("voice") { return "googlevoice" }
            return "google"
        }
        if match("microsoft") {
            if match("active") { return "microsoftactivedirectory" }
            if match("ads") { return "microsoftadvertising" }
            if match("advertising") { return "microsoftadvertising" }
            if match("ad") { return "microsoftactivedirectory" }
            if match("code") { return "microsoftvisualstudiocode" }
            if match("excel") { return "microsoftexcel" }
            if match("drive") { return "microsoftonedrive" }
            if match("note") { return "microsoftonenote" }
            if match("outlook") { return "microsoftoutlook" }
            if match("powerpoint") { return "microsoftpowerpoint" }
            if match("team") { return "microsoftteams" }
            if match("word") { return "microsoftword" }
            return "microsoft"
        }
        if match("gcp") { return "googlecloud" }
        if match("azure") { return "azure" }

        if let found = resourceIconNames.first(where: { match($0) }) {
            return found
        }
        return "application"
    }

    /// Best-effort icon for an auth connector (Google-OIDC, Entra ID, Okta, GitHub, etc.) — no
    /// dedicated icon set exists for these upstream, so reuse whatever's already in
    /// resourceIconSpecs when the connector's name obviously names a recognized provider.
    static func forAuthProvider(displayName: String, type: String) -> String? {
        let n = displayName.lowercased()
        if n.contains("google") { return "google" }
        if n.contains("entra") || n.contains("azure") || n.contains("microsoft") { return "microsoft" }
        if n.contains("okta") { return "okta" }
        if n.contains("github") { return "github" }
        if type == "github" { return "github" }
        return nil
    }

    static func forDatabase(protocol proto: String) -> String {
        switch proto {
        case "postgres": "postgres"
        case "mysql": "mysqllarge"
        case "mongodb": "mongo"
        case "cockroachdb": "cockroach"
        case "snowflake": "snowflake"
        case "dynamodb": "dynamo"
        case "redis": "redis"
        case "oracle": "oracle"
        default: "database"
        }
    }

    private static func withoutWhiteSpaces(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var modified = text.replacingOccurrences(
            of: #"\[[^\]]*\]|\([^)]*\)"#,
            with: "",
            options: .regularExpression
        )
        if modified.isEmpty { modified = text }
        return modified.replacingOccurrences(of: #"-|\s"#, with: "", options: .regularExpression)
    }
}
