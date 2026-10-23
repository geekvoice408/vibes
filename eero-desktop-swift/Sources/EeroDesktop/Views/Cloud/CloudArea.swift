#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import EeroCore

/// Port of AdditionalCloudFeatures.cs (additional wifi, subnet content filters, per-band security,
/// multiple static IPs and the business guest portal, including asset upload from ExtendedFeatures.cs).
enum CloudArea: FeatureArea {
    static let additionalWifi = "Settings/Additional wifi networks"
    static let contentFilters = "Home/Security & privacy/Content filters"
    static let businessPortal = "Settings/Business guest wifi"
    static let multiStatic = "Settings/Advanced networking/Multiple static IPs"

    static func handles(_ route: String) -> Bool {
        [additionalWifi, contentFilters, businessPortal, multiStatic].contains(route)
    }

    static func load(_ route: String, model: AppModel) async throws -> JSON? {
        guard await model.api.signedIn else { return nil }
        switch route {
        case additionalWifi, contentFilters: return try await model.api.send("GET", model.featureURL("subnets_config"))
        case businessPortal: return try await model.api.send("GET", model.featureURL("captive_portal/configurations"))
        case multiStatic: return try await model.api.send("GET", "/2.3/networks/" + model.networkId + "/multistaticip")
        default: return nil
        }
    }

    static func previewData(_ route: String) -> JSON? {
        if route == businessPortal {
            return .obj(("configurations", JSON.array([.obj(("configuration_id", 5), ("header", "Welcome to Maple House"), ("sub_header", "Guest wifi"),
                                                            ("color_theme", "Dark"), ("capture_email", false), ("capture_name", false),
                                                            ("access_expiration_in_minutes", 240))])))
        }
        return nil
    }

    static func view(_ route: String, model: AppModel) -> AnyView {
        switch route {
        case additionalWifi: return AnyView(AdditionalWifiPage(route: route, model: model))
        case contentFilters: return AnyView(SubnetFiltersPage(route: route, model: model))
        case businessPortal: return AnyView(BusinessPortalPage(route: route, model: model))
        default: return AnyView(MultiStaticPage(route: route, model: model))
        }
    }
}

/// `Uri.EscapeDataString`.
func cloudEscape(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
}

// MARK: - Additional wifi networks

struct AdditionalWifiPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route] ?? .null
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Additional wifi networks", route: route)
            ForEach(Array(cloudEntries(data, "subnets", "configurations").enumerated()), id: \.offset) { _, subnet in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudDetails(value: subnet)
                        CloudFlow {
                            CloudLocal("Edit wifi network", model) { subnetEdit(subnet) }
                            CloudAction("Content filters", model) { try await editSubnetFilters(subnet, ui: ui, model: model) }
                            let type = subnet.s("subnet_type")
                            if type == "A" || type == "B" {
                                CloudAction("Delete additional network", model) {
                                    if !(await model.confirm("Delete this additional wifi network? Connected devices will disconnect.")) { return }
                                    try await model.cloudChange("DELETE", model.featureURL("subnets_config/" + type), nil, "Additional wifi network deleted.")
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            CloudLocal("Add additional wifi network", model) { subnetEdit(nil) }
            CloudNote("The service enforces the number of SSIDs, available subnet types and subscription requirements for your hardware.")
        }
        .cloudSheets(ui, model: model)
    }

    /// Port of `SubnetEdit`.
    private func subnetEdit(_ subnet: JSON?) {
        let s = subnet ?? .null
        var fields: [CloudField] = [
            .text("name", "Wifi name", s.s("name")),
            .password("password", "New password (blank keeps current when editing)"),
            .bool("enabled", "Enabled", subnet == nil || s.b("enabled")),
            .bool("open_network", "Open network without a password", s.b("open_network")),
            .bool("wan_access", "Allow internet access", subnet == nil || s.b("wan_access")),
            .text("rate", "Bandwidth limit percentage (1–100)", s.s("rate_limit_pct").nilIfEmpty ?? "100"),
        ]
        if subnet == nil {
            fields.append(.choice("type", "Additional wifi slot", "A", ["A", "B"]))
            fields.append(.choice("kind", "Purpose", "IoT", ["IoT", "Business", "Kids", "Guest"]))
        }
        let model = self.model
        ui.form(subnet == nil ? "Add additional wifi" : "Edit additional wifi", fields, model: model) { v in
            try CloudValidation.ssid(v.v("name"))
            guard let rate = Int(v.v("rate")), (1...100).contains(rate) else { throw EeroError.argument("Enter a bandwidth percentage between 1 and 100.") }
            let password = v.v("password").nilIfEmpty ?? s.s("password")
            if !v.flag("open_network") { try CloudValidation.password(password) }
            var body = JSON.obj(("name", v.v("name").trimmingCharacters(in: .whitespacesAndNewlines)), ("enabled", v.flag("enabled")),
                                ("open_network", v.flag("open_network")), ("wan_access", v.flag("wan_access")), ("rate_limit_pct", rate))
            if subnet != nil {
                for key in ["network_id", "subnet_id", "subnet_type", "subnet_kind", "dedicated_subnet"] where !s[key].isNull { body[key] = s[key] }
            } else {
                body["network_id"] = .string(model.networkId)
                body["subnet_type"] = .string(v.v("type"))
                body["subnet_kind"] = .string(v.v("kind"))
            }
            if !v.flag("open_network") { body["password"] = .string(password) }
            if !(await model.confirm("Save this wifi network? Devices using it may disconnect.")) { return }
            try await model.cloudChange("PUT", model.featureURL("subnets_config"), body, "Wifi subnet saved.")
        }
    }
}

/// Port of `EditSubnetFilters`.
@MainActor
func editSubnetFilters(_ subnet: JSON, ui: CloudPresenter, model: AppModel) async throws {
    let id = subnet.s("subnet_id").nilIfEmpty ?? subnet.s("subnet_type")
    if id.isEmpty { throw EeroError.operation("eero did not provide a subnet identifier.") }
    let data = try await model.cloudRead(model.featureURL("subnets_config/" + cloudEscape(id) + "/dns_policies/content_filters"))
    var map: [String: Bool] = [:]
    for candidate in [data.get("dns_policies"), data.get("unified_content_filters", "dns_policies"), data.get("premium_dns", "dns_policies"),
                      data.get("premium_dns", "unified_content_filters", "dns_policies")] {
        if case .object(let values) = candidate { for (k, v) in values { if case .bool(let b) = v { map[k] = b } } }
    }
    if map.isEmpty { throw EeroError.operation("No editable content filters were returned for this subnet.") }
    let keys = map.keys.sorted()
    ui.form("Wifi content filters", keys.map { CloudField.bool($0, cloudHuman($0), map[$0]!) }, model: model) { v in
        var filters: [String: JSON] = [:]
        for k in keys { filters[k] = .bool(v.flag(k)) }
        try await model.cloudChange("PUT", model.featureURL("subnets_config/dns_policies/content_filters"),
                                    .obj(("subnets", JSON.array([.string(id)])), ("content_filters", JSON.object(filters))), "Subnet content filters updated.")
    }
}

// MARK: - Content filters by wifi network

struct SubnetFiltersPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route]
        let subnets = cloudEntries(data ?? .null, "subnets")
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Unified content filters by wifi network", route: route)
            ForEach(Array(subnets.enumerated()), id: \.offset) { _, subnet in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudHeading(subnet.first("name", "subnet_type"))
                        CloudAction("Edit content filters", model) { try await editSubnetFilters(subnet, ui: ui, model: model) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let data, !data.isNull, subnets.isEmpty { CloudNote("No configurable subnets were returned.", size: 14) }
        }
        .cloudSheets(ui, model: model)
    }
}

// MARK: - Security by radio band

/// Port of `BandSecurity`; the "Security by radio band" action of the wireless settings page.
struct BandSecurityButton: View {
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        CloudAction("Security by radio band", model) {
            let path = try model.featureURL("wpa3_per_band")
            let data = try await model.cloudRead(path)
            let modes = ["WPA2", "WPA2_WPA3", "WPA3"]
            ui.form("Security by radio band", [.choice("band_2_4_ghz", "2.4 GHz security", data.s("band_2_4_ghz"), modes),
                                               .choice("band_5_ghz", "5 GHz security", data.s("band_5_ghz"), modes)],
                    description: "6 GHz uses WPA3 as required by that band; this endpoint edits the 2.4 and 5 GHz modes.", model: model) { v in
                if !(await model.confirm("Change wifi authentication modes? Some devices may need to reconnect or may not support the new mode.")) { return }
                try await model.cloudChange("PUT", path, .obj(("band_2_4_ghz", v.v("band_2_4_ghz")), ("band_5_ghz", v.v("band_5_ghz"))),
                                            "Per-band wifi security updated.")
            }
        }
        .cloudSheets(ui, model: model)
    }
}

// MARK: - Multiple static IPs

struct MultiStaticPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route]
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Multiple static IPs · requires ISP support", route: route)
            CloudObjectCard(value: data)
            CloudLocal("Configure static public IPs", model) { configure(data ?? .null) }
        }
        .cloudSheets(ui, model: model)
    }

    private func configure(_ data: JSON) {
        let lan = data["multistaticip_settings"], nat = data["multistaticip_settings_nat_portfwd"]
        let model = self.model
        ui.form("Multiple static IPs", [
            .bool("enabled", "Enable multiple static IPs", data.b("enabled")),
            .choice("type", "Mode", data.s("type").nilIfEmpty ?? "PublicLAN", ["PublicLAN", "NATWithPortFwd"]),
            .text("subnet", "Public LAN subnet address", lan.s("subnet_ip")),
            .text("mask", "Public LAN subnet mask", lan.s("subnet_mask")),
            .text("router", "Public LAN router address", lan.s("router_ip")),
            .text("start", "NAT public IP range start", nat.s("subnet_ip_start")),
            .text("end", "NAT public IP range end", nat.s("subnet_ip_end")),
        ], model: model) { v in
            var body = JSON.obj(("enabled", v.flag("enabled")), ("type", v.v("type")))
            if v.flag("enabled") {
                if v.v("type") == "PublicLAN" {
                    body["multistaticip_settings"] = .obj(("subnet_ip", try CloudValidation.ipv4(v.v("subnet"))),
                                                          ("subnet_mask", try CloudValidation.ipv4(v.v("mask"))),
                                                          ("router_ip", try CloudValidation.ipv4(v.v("router"))))
                } else {
                    body["multistaticip_settings_nat_portfwd"] = .obj(("subnet_ip_start", try CloudValidation.ipv4(v.v("start"))),
                                                                      ("subnet_ip_end", try CloudValidation.ipv4(v.v("end"))))
                }
            }
            if !(await model.confirm("Apply multiple-static-IP settings supplied by your ISP? Incorrect values can disrupt internet access.")) { return }
            try await model.cloudChange("PUT", "/2.3/networks/" + model.networkId + "/multistaticip", body, "Multiple static IP settings updated.")
        }
    }
}

// MARK: - Business guest wifi

struct BusinessPortalPage: View {
    let route: String
    @ObservedObject var model: AppModel
    @StateObject private var ui = CloudPresenter()

    var body: some View {
        let data = model.featureData[route] ?? .null
        VStack(alignment: .leading, spacing: 12) {
            CloudSub(text: "Business guest wifi · existing portal configurations", route: route)
            SectionLink(title: "eero Insight", route: "Settings/Business guest wifi/eero Insight", model: model)
            ForEach(Array(cloudEntries(data, "configurations").enumerated()), id: \.offset) { _, config in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CloudDetails(value: config)
                        CloudFlow {
                            CloudLocal("Edit portal branding", model) { portalEdit(config) }
                            CloudAction("Upload logo", model) { try await uploadPortalAsset(config, logo: true) }
                            CloudAction("Upload terms PDF", model) { try await uploadPortalAsset(config, logo: false) }
                            CloudLocal("Visitor information", model) { visitorInformation(config) }
                            CloudAction("Use for guest wifi", model) {
                                guard let id = Int(config.first("configuration_id", "id")) else { throw EeroError.operation("Missing portal configuration ID.") }
                                if !(await model.confirm("Use this sign-in portal for guest wifi?")) { return }
                                try await model.cloudChange("PUT", model.featureURL("captive_portal/subnet_id/GUEST"),
                                                            .obj(("captive_portal_configuration_id", id)), "Guest portal configuration selected.")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            CloudNote("Edit existing portal text, theme, visitor fields, session duration and hosted links, or upload a PNG/JPEG logo and terms PDF. New business provisioning and cellular/accessory activation still depend on their service integrations.")
        }
        .cloudSheets(ui, model: model)
    }

    private func visitorInformation(_ config: JSON) {
        let model = self.model
        ui.form("Visitor information", [.bool("email", "Capture visitor email", config.b("capture_email")),
                                        .bool("name", "Capture visitor name", config.b("capture_name"))], model: model) { v in
            guard let id = Int(config.first("configuration_id", "id")) else { throw EeroError.operation("Missing portal configuration ID.") }
            try await model.cloudChange("PUT", model.featureURL("captive_portal/configuration"),
                                        .obj(("id", id), ("capture_email", v.flag("email")), ("capture_name", v.flag("name"))),
                                        "Visitor information settings updated.")
        }
    }

    /// Port of `PortalEdit`.
    private func portalEdit(_ config: JSON) {
        let model = self.model
        ui.form("Guest portal branding", [
            .text("header", "Heading", config.s("header")),
            .text("sub_header", "Subheading", config.s("sub_header")),
            .choice("color_theme", "Theme", config.s("color_theme").nilIfEmpty ?? "Light", ["Light", "Dark"]),
            .text("minutes", "Session duration in minutes", config.s("access_expiration_in_minutes")),
            .text("logo", "Hosted business logo URL (optional)", config.s("business_logo_url")),
            .text("terms", "Hosted business terms URL (optional)", config.s("business_terms_of_service_url")),
        ], model: model) { v in
            guard let id = Int(config.first("configuration_id", "id")), let minutes = Int(v.v("minutes")), (1...525600).contains(minutes) else {
                throw EeroError.argument("Enter a session duration between 1 and 525600 minutes.")
            }
            for key in ["logo", "terms"] where !v.v(key).isEmpty {
                if !CloudValidation.httpsURL(v.v(key)) { throw EeroError.argument("Use HTTPS URLs for hosted assets and terms.") }
            }
            let body = JSON.obj(("id", id), ("header", v.v("header")), ("sub_header", v.v("sub_header")), ("color_theme", v.v("color_theme")),
                                ("access_expiration_in_minutes", minutes), ("business_logo_url", v.v("logo")),
                                ("business_terms_of_service_url", v.v("terms")))
            try await model.cloudChange("PUT", model.featureURL("captive_portal/configuration"), body, "Guest portal branding updated.")
        }
    }

    /// Port of `UploadPortalAsset` (ExtendedFeatures.cs).
    private func uploadPortalAsset(_ config: JSON, logo: Bool) async throws {
        if model.preview { throw EeroError.operation("Sign in to upload a portal asset.") }
        let configId = try ExtendedContracts.identifier(config.first("configuration_id", "id"))
        let picker = NSOpenPanel()
        picker.title = logo ? "Select guest portal logo" : "Select guest terms PDF"
        picker.allowedContentTypes = logo ? [.png, .jpeg] : [.pdf]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let file = picker.url else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > (logo ? 5 : 10) * 1024 * 1024 { throw EeroError.argument("This file is too large. Logos support up to 5 MB; PDFs up to 10 MB.") }
        let bytes = try Data(contentsOf: file)
        let mime = try ExtendedContracts.portalMime(file.path, bytes, logo)
        if !(await model.confirm("Upload \(file.lastPathComponent) (\((bytes.count + 1023) / 1024) KB) as the guest portal \(logo ? "logo" : "terms document")? Guests will be able to access the uploaded asset.")) { return }
        let type = logo ? "CaptivePortalLogo" : "CaptivePortalToS", ext = file.pathExtension.lowercased()
        let upload = try await model.api.send("GET", model.featureURL("file/import/upload_link?importJobType=" + type + "&fileExtension=" + ext))
        try await PortalUpload.send(upload, bytes, mime)
        try await model.cloudChange("POST", model.featureURL("file/import/job"), try ExtendedContracts.importJob(upload.s("import_file_path"), logo, configId),
                                    "Asset uploaded and import requested. Refresh the portal after processing finishes.")
    }
}

// MARK: - Portal upload

/// Port of `PortalUpload` (ExtendedFeatures.cs): PUT to the signed S3 URL with a separate, cookie-less
/// session that never forwards the eero session and does not follow redirects.
enum PortalUpload {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func send(_ upload: JSON, _ data: Data, _ mime: String, session: URLSession? = nil) async throws {
        let url = try ExtendedContracts.uploadUrl(upload.s("signed_upload_url"))
        let key = upload.s("kms_key_id")
        if key.isEmpty || key.count > 2048 || key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw EeroError.data("The upload encryption key is missing or invalid.")
        }
        let http: URLSession
        if let session { http = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 120
            http = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }
        defer { if session == nil { http.finishTasksAndInvalidate() } }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        request.setValue("aws:kms", forHTTPHeaderField: "x-amz-server-side-encryption")
        request.setValue(key, forHTTPHeaderField: "x-amz-server-side-encryption-aws-kms-key-id")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await http.upload(for: request, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            throw EeroError.operation("The storage service rejected the upload (\(status)). No import was requested.")
        }
    }
}
#endif
