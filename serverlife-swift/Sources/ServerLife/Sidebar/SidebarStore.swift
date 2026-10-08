import Foundation

/// The store the sidebar's models read and write. `Store.shared` in the app;
/// tests point it at a throwaway `Store(dir:)` so nothing touches the real file.
@MainActor
enum SB {
    static var store: Store = .shared
}
