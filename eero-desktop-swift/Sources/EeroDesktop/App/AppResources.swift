#if os(macOS)
import Foundation

/// Resource bundle lookup that works both for `swift run` and inside a packaged .app, where
/// SwiftPM's generated `Bundle.module` would look next to the .app instead of in Contents/Resources.
enum AppResources {
    static let bundle: Bundle = {
        let name = "EeroDesktop_EeroDesktop.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()
}
#endif
