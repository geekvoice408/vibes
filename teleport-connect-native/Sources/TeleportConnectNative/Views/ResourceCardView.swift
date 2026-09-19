import SwiftUI

/// Mirrors CardsView/ResourceCard.tsx: fixed-height card with a 45x45 icon, name + action
/// button row, type/description row, and wrapping label pills. Skips the real component's
/// resize-observer-driven label expansion and multi-select checkbox — those are secondary to
/// getting the overall card shape and information density right.
struct ResourceCardView: View {
    let model: AppModel
    let row: ResourceRow

    private var isPinned: Bool { model.pinnedResourceIDs.contains(row.id) }
    private var isHovered: Bool { model.hoveredResourceID == row.id }
    private var customIconPath: String? { model.customIcons[row.name.lowercased()] }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space[3]) {
            ResourceIconImage(
                name: row.iconName,
                customFilePath: customIconPath,
                fallbackSymbol: ResourceIconStyle.symbol(for: row.kind),
                fallbackTint: ResourceIconStyle.tint(for: row.kind)
            )
            .frame(width: 45, height: 45)
            .contextMenu {
                Button("Set Custom Icon…") { model.pickCustomIcon(forResourceName: row.name) }
                if customIconPath != nil {
                    Button("Remove Custom Icon") { model.removeCustomIcon(forResourceName: row.name) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.space[1]) {
                    Text(row.name)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMain)
                        .lineLimit(1)
                    Spacer(minLength: Theme.space[2])
                    ResourceActionButton(model: model, row: row)
                }

                HStack(spacing: 4) {
                    Image(systemName: ResourceIconStyle.symbol(for: row.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSlightlyMuted)
                    Text(row.typeLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSlightlyMuted)
                        .lineLimit(1)
                    if !row.description.isEmpty {
                        Text(row.description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }

                if !row.labels.isEmpty {
                    labelPills
                }
            }
        }
        .padding(Theme.space[3])
        .padding(.leading, Theme.space[3])
        .padding(.trailing, row.hasHealthWarning ? Theme.space[5] : Theme.space[3])
        .frame(height: 110, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    row.hasHealthWarning ? Theme.interactiveAlert : (isHovered ? Color.clear : Theme.spotBackground0),
                    lineWidth: row.hasHealthWarning ? 2 : 2
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: isHovered ? .black.opacity(0.25) : .clear, radius: 6, y: 2)
        .overlay(alignment: .topLeading) {
            pinButton
        }
        .overlay(alignment: .trailing) {
            if row.hasHealthWarning {
                healthWarningBadge
            }
        }
        .onHover { model.hoveredResourceID = $0 ? row.id : nil }
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isPinned {
            Theme.tonalPrimary1
        } else if isHovered {
            Theme.levelSurface
        } else {
            Color.clear
        }
    }

    /// Approximates CardsView/WarningRightEdgeBadgeSvg.tsx — a warning wedge on the card's
    /// right edge; clicking it shows the health message/error (StatusInfo.tsx's detail panel,
    /// simplified to a popover here instead of a full sliding side panel).
    private var healthWarningBadge: some View {
        Button {
            model.showingHealthInfoForResourceID = row.id
        } label: {
            ZStack {
                Rectangle().fill(Theme.interactiveAlert).frame(width: 28)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 28)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 8, topTrailingRadius: 8))
        .help("Show Connection Issue")
        .popover(isPresented: Binding(
            get: { model.showingHealthInfoForResourceID == row.id },
            set: { if !$0 { model.showingHealthInfoForResourceID = nil } }
        )) {
            HealthWarningDetailView(row: row)
        }
    }

    private var pinButton: some View {
        Button {
            model.togglePinned(row.id)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .foregroundStyle(isPinned ? Theme.brand : Theme.textDisabled)
        }
        .buttonStyle(.plain)
        .opacity(isPinned || isHovered ? 1 : 0)
        .padding(6)
    }

    private var labelPills: some View {
        let shown = Array(row.labels.prefix(3))
        let more = row.labels.count - shown.count
        return HStack(spacing: 4) {
            ForEach(shown, id: \.self) { label in
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSlightlyMuted)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Theme.spotBackground0)
                    .clipShape(Capsule())
                    .lineLimit(1)
            }
            if more > 0 {
                Text("+ \(more) more")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(Theme.textSlightlyMuted)
            }
        }
    }
}

/// Simplified stand-in for StatusInfo.tsx's UnhealthyStatusInfo panel — that's a full sliding
/// side panel with a troubleshooting-guide link and a per-backend-server breakdown; this is a
/// popover with just the status/message/error tshd itself reported.
struct HealthWarningDetailView: View {
    let row: ResourceRow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space[2]) {
            HStack(spacing: Theme.space[1]) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.interactiveAlert)
                Text(row.kind == .database ? "Database Connection Issue" : "Kubernetes Cluster Issue")
                    .font(Theme.uiFontMedium)
            }
            Text("Status: \(row.healthStatus)").font(.system(size: 12)).foregroundStyle(Theme.textMain)
            if !row.healthMessage.isEmpty {
                Text(row.healthMessage).font(.system(size: 12)).foregroundStyle(Theme.textSlightlyMuted)
            }
            if !row.healthError.isEmpty {
                Text(row.healthError).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.space[3])
        .frame(width: 300)
    }
}

/// Mirrors ResourceActionButtonWrapper: a pill button with interactive.tonal.neutral[0]
/// (aka spotBackground[0]) background and no border. Label depends on resource kind — "Connect"
/// for infra resources, "Launch" for apps (opens the app URL), "Log In" for SAML apps.
struct ResourceActionButton: View {
    let model: AppModel
    let row: ResourceRow

    var body: some View {
        switch row.kind {
        case .server where !row.logins.isEmpty:
            Menu {
                ForEach(row.logins, id: \.self) { login in
                    Button(login) {
                        guard let clusterURI = model.selectedClusterURI else { return }
                        model.connectToServer(login: login, row: row, clusterURI: clusterURI)
                    }
                }
            } label: {
                pill("Connect")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

        case .app:
            Button {
                if let url = row.launchURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                pill(row.isSAMLApp ? "Log In" : "Launch")
            }
            .buttonStyle(.plain)
            .disabled(row.launchURL == nil)

        default:
            pill("Connect").opacity(0.5)
        }
    }

    private func pill(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textMain)
            .padding(.horizontal, Theme.space[2])
            .frame(height: 22)
            .background(Theme.spotBackground0)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiiSmall))
    }
}
