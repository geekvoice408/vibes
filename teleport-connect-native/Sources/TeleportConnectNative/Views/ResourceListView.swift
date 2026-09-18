import SwiftUI

/// Mirrors DocumentCluster + shared/components/UnifiedResources/UnifiedResources.tsx: a
/// toolbar (type/status filters, refresh, grid-list toggle, sort), All/Pinned tabs, and either
/// a card grid or a compact list of the cluster's resources.
struct ResourceListView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space[2]) {
            ResourceToolbarView(model: model)
            ResourceTabsView(model: model)
            content
        }
        .padding(.horizontal, Theme.space[3])
        .padding(.top, Theme.space[2])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.levelSunken)
    }

    @ViewBuilder
    private var content: some View {
        if model.resourcesLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.resourcesError {
            VStack(spacing: Theme.space[2]) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.interactiveDanger)
                Text(error).font(Theme.uiFontSmall).foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                HStack(spacing: Theme.space[2]) {
                    Button("Retry") { Task { await model.refreshSelectedCluster() } }
                    if let uri = model.selectedClusterURI {
                        Button("Log In") { Task { await model.startLogin(clusterURI: uri) } }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand)
                    }
                }
            }
            .padding(Theme.space[4])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleResources.isEmpty {
            Text(model.resourceTab == .pinned ? "No pinned resources" : "No resources found")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                switch model.resourceViewMode {
                case .grid:
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.space[2])],
                        spacing: Theme.space[2]
                    ) {
                        ForEach(model.visibleResources) { row in
                            ResourceCardView(model: model, row: row)
                        }
                    }
                    .padding(.bottom, Theme.space[3])
                case .list:
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleResources) { row in
                            ResourceListRowView(model: model, row: row)
                            Divider().overlay(Theme.spotBackground1)
                        }
                    }
                }
            }
        }
    }
}

private struct ResourceListRowView: View {
    let model: AppModel
    let row: ResourceRow

    private var isHovered: Bool { model.hoveredResourceID == row.id }

    var body: some View {
        HStack(spacing: Theme.space[2]) {
            ResourceIconImage(
                name: row.iconName,
                fallbackSymbol: ResourceIconStyle.symbol(for: row.kind),
                fallbackTint: ResourceIconStyle.tint(for: row.kind)
            )
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textMain)
                Text(row.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer()

            ResourceActionButton(model: model, row: row)
        }
        .padding(.horizontal, Theme.space[3])
        .padding(.vertical, Theme.space[2])
        .background(isHovered ? Theme.spotBackground0 : Color.clear)
        .onHover { model.hoveredResourceID = $0 ? row.id : nil }
    }
}
