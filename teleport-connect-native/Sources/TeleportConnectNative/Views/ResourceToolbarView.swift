import SwiftUI

/// Mirrors FilterPanel.tsx: Types/Access Requests/Health Status filters on the left,
/// Refresh/grid-list toggle/Sort on the right. Access Requests and Health Status are shown
/// for visual parity but aren't wired up yet (Phase E scope — access requests, resource health).
struct ResourceToolbarView: View {
    let model: AppModel

    var body: some View {
        HStack {
            HStack(spacing: Theme.space[2]) {
                Menu {
                    ForEach(ResourceKind.allCases, id: \.self) { kind in
                        Button {
                            if model.selectedKindFilters.contains(kind) {
                                model.selectedKindFilters.remove(kind)
                            } else {
                                model.selectedKindFilters.insert(kind)
                            }
                        } label: {
                            Label(kind.filterLabel, systemImage: model.selectedKindFilters.contains(kind) ? "checkmark" : "")
                        }
                    }
                } label: {
                    toolbarChip(
                        "Types",
                        badge: model.selectedKindFilters.isEmpty ? nil : "\(model.selectedKindFilters.count)"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    model.showAccessRequestsFilterInfo.toggle()
                } label: {
                    toolbarChip("Access Requests", chevron: true).opacity(0.6)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { model.showAccessRequestsFilterInfo },
                    set: { model.showAccessRequestsFilterInfo = $0 }
                )) {
                    notImplementedNote("Filtering by access-requestable resources isn't implemented in the native app yet.")
                }

                Button {
                    model.showHealthStatusFilterInfo.toggle()
                } label: {
                    toolbarChip("Health Status", chevron: true).opacity(0.6)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { model.showHealthStatusFilterInfo },
                    set: { model.showHealthStatusFilterInfo = $0 }
                )) {
                    notImplementedNote("Resource health filtering isn't implemented in the native app yet.")
                }
            }

            Spacer()

            HStack(spacing: Theme.space[2]) {
                Button {
                    Task { await model.refreshSelectedCluster() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh")

                Picker("", selection: Binding(
                    get: { model.resourceViewMode },
                    set: { model.resourceViewMode = $0 }
                )) {
                    Image(systemName: "square.grid.2x2").tag(ResourceViewMode.grid)
                    Image(systemName: "list.bullet").tag(ResourceViewMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)

                Menu {
                    ForEach([SortField.name, .kind], id: \.self) { field in
                        Button {
                            model.sortField = field
                        } label: {
                            Label(field.rawValue, systemImage: model.sortField == field ? "checkmark" : "")
                        }
                    }
                    Divider()
                    Button {
                        model.sortAscending.toggle()
                    } label: {
                        Label(model.sortAscending ? "Ascending" : "Descending", systemImage: model.sortAscending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    toolbarChip("\(model.sortField.rawValue), \(model.sortAscending ? "A - Z" : "Z - A")")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, Theme.space[1])
    }

    private func notImplementedNote(_ text: String) -> some View {
        Text(text)
            .font(Theme.uiFontSmall)
            .foregroundStyle(Theme.textMuted)
            .frame(width: 240)
            .padding(Theme.space[2])
    }

    private func toolbarChip(_ title: String, badge: String? = nil, chevron: Bool = true) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12))
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .background(Theme.brand)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
        }
        .foregroundStyle(Theme.textSlightlyMuted)
        .padding(.horizontal, Theme.space[2])
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiiSmall)
                .strokeBorder(Theme.buttonBorder, lineWidth: 1)
        )
    }
}
