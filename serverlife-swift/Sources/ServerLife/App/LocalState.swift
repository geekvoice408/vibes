import SwiftUI

// `@State` does not compile with the Command Line Tools: on the macOS 27 SDK
// it is a macro whose plugin ships only with Xcode. `@StateObject` is a plain
// property wrapper, so per-view state lives in one of these instead:
//
//     @StateObject private var text = Local("")
//     TextField("Name", text: $text.value)

/// One value of per-view state.
final class Local<T>: ObservableObject {
    @Published var value: T
    init(_ initial: T) { value = initial }
}

/// A boolean flag (hover, disclosure, "editing").
final class LocalFlag: ObservableObject {
    @Published var on: Bool
    init(_ initial: Bool = false) { on = initial }
    func toggle() { on.toggle() }
}

/// Shows a hover popover after a short delay so it does not flash while the
/// pointer scans a list; hides immediately.
final class HoverPopover: ObservableObject {
    @Published var shown = false
    private var work: DispatchWorkItem?

    func enter(delay: Double = 0.45) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.shown = true }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func exit() {
        work?.cancel(); work = nil
        shown = false
    }
}
