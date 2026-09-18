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

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space[3]) {
            ResourceIconImage(
                name: row.iconName,
                fallbackSymbol: ResourceIconStyle.symbol(for: row.kind),
                fallbackTint: ResourceIconStyle.tint(for: row.kind)
            )
            .frame(width: 45, height: 45)

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
        .frame(height: 110, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovered ? Color.clear : Theme.spotBackground0, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: isHovered ? .black.opacity(0.25) : .clear, radius: 6, y: 2)
        .overlay(alignment: .topLeading) {
            pinButton
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
