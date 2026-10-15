// A QR code drawn with block characters, two rows per line, for scanning from a terminal.
import CoreImage
import Foundation

public enum TerminalQR {
    public static func render(_ text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Dark modules; a quiet zone of 2 around.
        func dark(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && pixels[y * w + x] < 128 }
        var lines: [String] = []
        for y in stride(from: -2, to: h + 2, by: 2) {
            var line = ""
            for x in -2 ..< w + 2 {
                // Light on dark terminals: draw the light modules.
                switch (!dark(x, y), !dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
