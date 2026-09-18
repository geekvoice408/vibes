import SwiftUI

/// Mirrors ResourceTab.tsx: "All Resources" / "Pinned Resources" with a brand-colored
/// underline on the selected tab.
struct ResourceTabsView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Theme.space[4]) {
            tab("All Resources", kind: .all)
            tab("Pinned Resources", kind: .pinned)
            Spacer()
        }
    }

    private func tab(_ title: String, kind: ResourceTabKind) -> some View {
        let selected = model.resourceTab == kind
        return Button {
            model.resourceTab = kind
        } label: {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? Theme.brand : Theme.textMain)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Theme.brand : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
    }
}
