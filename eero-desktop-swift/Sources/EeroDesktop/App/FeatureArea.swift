#if os(macOS)
import SwiftUI
import EeroCore

/// A feature area owns a set of routes (e.g. "Settings/Advanced networking/DNS"):
/// it fetches their data and renders their page. This replaces the giant route
/// switches in the Windows `LoadFeature` / `RenderFeature`.
@MainActor
protocol FeatureArea {
    /// True when this area renders `route`.
    static func handles(_ route: String) -> Bool
    /// Fetches data for `route` (stored by the caller in `model.featureData[route]`). Return nil when nothing needs loading.
    static func load(_ route: String, model: AppModel) async throws -> JSON?
    /// Sample data for `route` in preview mode.
    static func previewData(_ route: String) -> JSON?
    /// The page content for `route`.
    static func view(_ route: String, model: AppModel) -> AnyView
}

extension FeatureArea {
    static func previewData(_ route: String) -> JSON? { nil }
}

@MainActor
enum FeatureAreas {
    /// Every registered area, first match wins. Areas match exact routes; the dashboard area also
    /// claims top-level pages the shell renders itself, so it goes last.
    static let all: [any FeatureArea.Type] = [
        AppearanceArea.self,
        ConversationArea.self,
        BluetoothArea.self,
        VpnArea.self,
        NetworkCreationArea.self,
        NetworkingArea.self,
        ProfilesSecurityArea.self,
        CloudArea.self,
        ExtendedArea.self,
        EverydayArea.self,
        RuntimeArea.self,
        BillingArea.self,
        SupportArea.self,
        CoreFeatureArea.self,
        ManagementArea.self,
        DashboardArea.self,
    ]

    static func area(for route: String) -> (any FeatureArea.Type)? { all.first { $0.handles(route) } }

    /// Loads a feature route into `model.featureData` (port of `LoadFeature`).
    static func load(_ route: String, model: AppModel) async throws {
        guard let area = area(for: route) else { return }
        if model.preview { model.featureData[route] = area.previewData(route) ?? .object([:]); return }
        if let data = try await area.load(route, model: model) { model.featureData[route] = data }
    }
}
#endif
