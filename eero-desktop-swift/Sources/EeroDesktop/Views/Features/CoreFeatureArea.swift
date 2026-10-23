#if os(macOS)
import SwiftUI
import EeroCore

/// Routes rendered directly by the Windows `RenderFeature` switch in `FeatureUi.cs`
/// (rather than by a page method in another file).
enum CoreFeatureArea: FeatureArea {
    static let routes: Set<String> = ["Activity/Network events"]

    static func handles(_ route: String) -> Bool { routes.contains(route) }
    static func load(_ route: String, model: AppModel) async throws -> JSON? { try await FeatureLoads.load(route, model: model) }
    static func previewData(_ route: String) -> JSON? { FeatureLoads.previewData(route) }

    static func view(_ route: String, model: AppModel) -> AnyView {
        AnyView(FeatureRoutePage(route: route, model: model) { data in
            ObjectCards(data, "Network events")
        })
    }
}

// MARK: - Generic page scaffolding (FeatureUi.cs helpers)

/// Lays out a feature page for `route`: shows the stored load error (with "Try again") in place of the page,
/// as `RenderFeature` did for an `ApiException`, and hosts feature dialogs.
struct FeatureRoutePage<Content: View>: View {
    let route: String
    @ObservedObject var model: AppModel
    @ViewBuilder let content: (JSON) -> Content

    var body: some View {
        let data = model.featureData[route] ?? .null
        VStack(alignment: .leading, spacing: 12) {
            if let message = FeatureLoads.error(data) {
                FeatureErrorView(message: message, route: route, model: model)
            } else {
                content(data)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .featureDialogs(model)
    }
}

/// Port of the error branch of `RenderFeature`.
struct FeatureErrorView: View {
    let message: String
    let route: String
    @ObservedObject var model: AppModel

    var body: some View {
        FeatureCard { Text(message).font(.system(size: 15)).foregroundStyle(.red) }
        FeatureNote("Availability depends on your account permissions, subscription, hardware and firmware.")
        Button("Try again") { model.perform("Loading…") { try await FeatureAreas.load(route, model: model) } }
        FeatureCatalogLinks(parent: route, model: model, explanation: false)
    }
}

/// A content card (the shell's `Card` with the feature-page padding).
struct FeatureCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        Card(padding: 18) { VStack(alignment: .leading, spacing: 8, content: content) }
    }
}

/// Port of `Sub`: a subtitle, omitted when it only repeats the page name.
struct FeatureSub: View {
    let text: String
    let route: String
    init(_ text: String, route: String) { self.text = text; self.route = route }
    var body: some View {
        let last = route.split(separator: "/").last.map(String.init) ?? route
        VStack(alignment: .leading, spacing: 0) {
            if text.caseInsensitiveCompare(last) != .orderedSame {
                Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Color.clear.frame(height: 10)
        }
    }
}

/// Section heading (`Text(title, 20, …, true)`).
struct FeatureHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 20, weight: .semibold)).padding(.top, 6) }
}

/// Muted explanatory text (`Text(…, 13, "#64738A")`).
struct FeatureNote: View {
    let text: String
    var size: CGFloat = 13
    init(_ text: String, size: CGFloat = 13) { self.text = text; self.size = size }
    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Port of `Detail(panel, name, value)`.
struct FeatureDetail: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "Unavailable" : value).font(.system(size: 15)).textSelection(.enabled)
        }
    }
}

/// Port of `Section(title, route)`: a link button that navigates to another feature page.
struct FeatureSectionButton: View {
    let title: String
    let route: String
    @ObservedObject var model: AppModel
    init(_ title: String, _ route: String, model: AppModel) { self.title = title; self.route = route; self.model = model }
    var body: some View { SectionLink(title: title, route: route, model: model) }
}

/// Port of `ActionRow`: buttons that wrap onto further lines.
struct FeatureActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { FeatureFlowLayout(spacing: 8) { content() } }
}

/// A simple wrapping layout used by `FeatureActionRow`.
struct FeatureFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { y += row + spacing; x = 0; row = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Port of `FeatureMenu(parent, explanation)`: the catalog entries below `parent`, in two columns.
struct FeatureCatalogLinks: View {
    let parent: String
    @ObservedObject var model: AppModel
    var explanation = true

    var body: some View {
        let entries = Array(FeatureCatalog.children(parent))
        VStack(alignment: .leading, spacing: 10) {
            if explanation {
                FeatureNote(parent == "Settings" ? "Manage your network, account, and desktop preferences." : "Choose a setting to view details and make changes.", size: 14)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 12) {
                ForEach(entries, id: \.path) { entry in
                    Button { model.navigate(entry.path) } label: {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title).font(.system(size: 14, weight: .semibold))
                                if !entry.description.isEmpty {
                                    Text(entry.description).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.title)
                }
            }
        }
    }
}
#endif
