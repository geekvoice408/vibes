#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import EeroCore

/// A wifi-join QR code (port of the QRCoder image in `ShowWifiQr`), generated with Core Image.
struct WifiQRCode: View {
    let payload: String
    var size: CGFloat = 320

    init(payload: String, size: CGFloat = 320) { self.payload = payload; self.size = size }
    /// Encodes the network with `FeatureContracts.wifiQr`, like the Windows client.
    init(name: String, password: String, size: CGFloat = 320) {
        self.init(payload: FeatureContracts.wifiQr(name, password), size: size)
    }

    var body: some View {
        if let image = WifiQRCode.image(payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Wifi QR code")
        } else {
            Text("The QR code could not be generated.").foregroundStyle(.red)
        }
    }

    /// Renders `text` as a QR code with error-correction level Q, `scale` pixels per module.
    static func image(_ text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Port of the "Wifi QR code" dialog.
struct WifiQRSheet: View {
    let name: String
    let password: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join " + name).font(.system(size: 23, weight: .semibold))
            WifiQRCode(name: name, password: password)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            Text("This QR code contains your wifi credentials. Anyone who scans it can join the network.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(28)
        .frame(minWidth: 420)
    }
}
#endif
