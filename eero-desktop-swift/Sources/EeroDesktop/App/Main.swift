#if os(macOS)
import SwiftUI
import EeroCore

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Port of `--connection-test <path>`: unauthenticated HTTPS check that writes a JSON report.
        if args.count > 2, args[1] == "--connection-test" {
            let path = args[2]
            Task.detached { exit(await ConnectionDiagnostics.run(path: path)) }
            dispatchMain()
        }
        EeroDesktopApp.main()
    }
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
