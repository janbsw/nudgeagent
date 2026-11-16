import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Pure, thread-safe image helpers: OCR, JPEG encoding, perceptual fingerprint.
/// Everything stays in memory; nothing is ever written to disk.
enum ScreenImageProcessing {
    static let maxOCRChars = 8000
    static let jpegMaxSide = 1280
    static let jpegQuality = 0.6
    static let fingerprintSide = 16
    /// Mean absolute difference (0...255) below which two fingerprints count as the same image.
    static let unchangedThreshold = 3.0

    // MARK: OCR

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "de-DE"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []

        struct Item { let text: String; let box: CGRect }
        let items: [Item] = observations.compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let t = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Item(text: t, box: obs.boundingBox)
        }
        // Vision uses normalized coordinates with origin bottom-left. Group into rows
        // top-to-bottom, then sort each row left-to-right.
        let sorted = items.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Item]] = []
        var rowMidY: CGFloat = 0
        var rowHeight: CGFloat = 0
        for item in sorted {
            if var last = rows.last,
               abs(item.box.midY - rowMidY) < max(rowHeight, item.box.height) * 0.5 {
                last.append(item)
                rows[rows.count - 1] = last
            } else {
                rows.append([item])
                rowMidY = item.box.midY
                rowHeight = item.box.height
            }
        }
        var out = ""
        outer: for row in rows {
            for item in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                if !out.isEmpty { out += "\n" }
                out += item.text
                if out.count >= maxOCRChars { break outer }
            }
        }
        if out.count > maxOCRChars { out = String(out.prefix(maxOCRChars)) }
        return out
    }

    // MARK: Resize and JPEG

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = Double(maxSide) / Double(longest)
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let small = downscaled(image, maxSide: jpegMaxSide)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, small, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Fingerprint

    /// 16x16 grayscale downsample, 256 bytes.
    static func fingerprint(_ image: CGImage) -> [UInt8]? {
        let side = fingerprintSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return ok ? pixels : nil
    }

    static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
