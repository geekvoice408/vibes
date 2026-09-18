import SwiftUI

/// Mirrors StatusBar/StatusBar.tsx: bottom bar with a breadcrumb of the active document's
/// cluster path on the left.
struct StatusBarView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.space[1]) {
            if let cluster = model.clusters.first(where: { $0.uri == model.selectedClusterURI }) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                Text(cluster.name)
                    .font(.system(size: 12))
            }
            if model.selectedTab == .resources, !model.resourcesLoading, model.resourcesError == nil {
                Text("·").foregroundStyle(Theme.textDisabled)
                Text(resourceCountText).font(.system(size: 12))
            }
            if let message = model.statusMessage {
                Text("·").foregroundStyle(Theme.textDisabled)
                Text(message).font(.system(size: 12))
            }
            Spacer()
        }
        .foregroundStyle(Theme.textSlightlyMuted)
        .padding(.horizontal, Theme.space[2])
        .frame(height: Theme.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.levelSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.spotBackground1).frame(height: 1)
        }
    }

    private var resourceCountText: String {
        let visible = model.visibleResources.count
        let total = model.resources.count
        let noun = total == 1 ? "resource" : "resources"
        return visible == total ? "\(total) \(noun)" : "\(visible) of \(total) \(noun)"
    }
}
