#if os(macOS)
import SwiftUI

@main
enum Main {
    static func main() { EeroDesktopApp.main() }
}
#else
import EeroCore

@main
enum Main {
    static func main() {
        print("eero Desktop is a macOS application. Build it on macOS 14 or later; on this platform only the EeroCore library and its tests are available.")
    }
}
#endif
