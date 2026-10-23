#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `ActivityMenu` / `NativeActivity` (route "Activity").
@MainActor
struct ActivityView: View {
    @ObservedObject var model: AppModel

    private static let usageRoute = "Activity/Data usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Internet performance, data usage, and recent network activity.")
            Card {
                SectionHeader("Latest internet speed")
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text("↓ " + DashboardKit.speed(model.network, "down")).font(.system(size: 28, weight: .semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text("↑ " + DashboardKit.speed(model.network, "up")).font(.system(size: 28, weight: .semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Run speed test") { model.perform { try await model.startSpeedTest() } }.buttonStyle(.accent)
                    SectionLink(title: "Speed test history", route: "Home/Internet")
                }.padding(.top, 18)
            }
            // Data usage is shown inline under the speed card rather than behind a link.
            Card {
                SectionHeader("Data usage")
                if model.featureData[Self.usageRoute] == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading data usage…").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                } else {
                    ManagementPage(route: Self.usageRoute, model: model)
                }
            }
            .task(id: model.networkURL) { await loadUsage() }
            HStack(alignment: .top, spacing: 16) {
                RouteRow(title: "Security activity", subtitle: "Protection and content-filter insights", route: "Activity/Security activity")
                RouteRow(title: "Network events", subtitle: "Recent changes and connection events", route: "Activity/Network events")
            }
        }
    }

    /// Loads data usage for the inline card; failures are shown by the card itself.
    private func loadUsage() async {
        model.featureData[Self.usageRoute] = nil
        try? await FeatureAreas.load(Self.usageRoute, model: model)
        if model.featureData[Self.usageRoute] == nil { model.featureData[Self.usageRoute] = .object([:]) }
    }
}
#endif
