#if os(macOS)
import SwiftUI
import EeroCore

/// Port of `ActivityMenu` / `NativeActivity` (route "Activity").
@MainActor
struct ActivityView: View {
    @ObservedObject var model: AppModel

    /// `PreviewFeature("Activity/Data usage")`.
    static let previewUsage: JSON = .obj(("series", JSON.array([.obj(("type", "download"), ("sum", 13_400_000_000.0), ("values", JSON.array([
        .obj(("time", "2026-10-16"), ("value", 1_200_000_000.0)), .obj(("time", "2026-10-17"), ("value", 2_100_000_000.0)),
        .obj(("time", "2026-10-18"), ("value", 1_600_000_000.0)), .obj(("time", "2026-10-19"), ("value", 2_800_000_000.0)),
        .obj(("time", "2026-10-20"), ("value", 1_800_000_000.0)), .obj(("time", "2026-10-21"), ("value", 2_200_000_000.0)),
        .obj(("time", "2026-10-22"), ("value", 1_700_000_000.0)),
    ])))])))

    private var usage: JSON? {
        let route = "Activity/Data usage"
        if model.preview { return FeatureAreas.area(for: route)?.previewData(route) ?? Self.previewUsage }
        return model.featureData[route]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Subtitle("Internet performance, data usage, and recent network activity.")
            HStack(alignment: .top, spacing: 24) {
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
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 12) {
                    RouteRow(title: "Data usage", subtitle: "Daily, weekly, and monthly usage by device", route: "Activity/Data usage")
                    RouteRow(title: "Security activity", subtitle: "Protection and content-filter insights", route: "Activity/Security activity")
                    RouteRow(title: "Network events", subtitle: "Review recent changes and connection events", route: "Activity/Network events")
                }
                // Fixed-width side column, so the speed card can't squeeze it.
                .frame(width: 300, alignment: .topLeading)
            }
            if let usage, !usage.isNull {
                SectionHeader("Data usage").padding(.bottom, 8)
                ActivityChart(data: usage, bytes: true)
            }
        }
    }
}
#endif
