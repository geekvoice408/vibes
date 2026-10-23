#if os(macOS)
import SwiftUI
import EeroCore

/// Two-column list of a menu route's children from `FeatureCatalog` (port of `NativeFeatureMenu`).
/// Used for "Settings", for catalog parents such as "Settings/Advanced networking", and below a
/// failed feature load.
@MainActor
struct FeatureMenuView: View {
    @EnvironmentObject private var model: AppModel
    let parent: String
    var explanation: Bool = true

    init(parent: String, explanation: Bool = true) {
        self.parent = parent
        self.explanation = explanation
    }

    var body: some View {
        let entries = Array(FeatureCatalog.children(parent))
        VStack(alignment: .leading, spacing: 0) {
            if explanation {
                Subtitle(parent == "Settings" ? "Manage your network, account, and desktop preferences."
                                              : "Choose a setting to view details and make changes.")
            }
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: entries.count, by: 2)), id: \.self) { i in
                    GridRow {
                        RouteRow(title: entries[i].title, subtitle: entries[i].description, route: entries[i].path)
                        if i + 1 < entries.count {
                            RouteRow(title: entries[i + 1].title, subtitle: entries[i + 1].description, route: entries[i + 1].path)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
        }
    }
}
#endif
