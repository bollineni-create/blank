import Foundation
import PDFKit
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import Speech
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pulls readable text (and a thumbnail) out of links, images and documents.
/// Everything here runs on-device; links are the only thing that touch the network.
enum ContentExtractor {
    struct LinkContent: Sendable {
        var title: String
        var description: String
        var text: String
        var imageURL: URL?
    }

    // MARK: Links

    static func fetchLink(_ url: URL) async throws -> LinkContent {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let mime = (response as? HTTPURLResponse)?.mimeType ?? ""

        if mime == "application/pdf" {
            let text = pdfText(PDFDocument(data: data))
            return LinkContent(title: url.lastPathComponent, description: "", text: text, imageURL: nil)
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let title = meta(html, property: "og:title") ?? firstMatch(html, #"<title[^>]*>([\s\S]*?)</title>"#) ?? url.host() ?? ""
        let description = meta(html, property: "og:description") ?? meta(html, name: "description") ?? ""
        let image = meta(html, property: "og:image").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        return LinkContent(
            title: decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines),
            description: decodeEntities(description),
            text: String(htmlToText(html).prefix(20_000)),
            imageURL: image)
    }

    static func fetchImageData(_ url: URL) async -> Data? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return thumbnail(from: data)
    }

    /// Strips scripts, styles and tags; keeps paragraphs readable.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<noscript[\s\S]*?</noscript>"#,
                        #"<nav[\s\S]*?</nav>"#, #"<footer[\s\S]*?</footer>"#, #"<svg[\s\S]*?</svg>"#, #"<!--[\s\S]*?-->"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"<(br|/p|/div|/h[1-6]|/li|/tr)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meta(_ html: String, property: String) -> String? {
        firstMatch(html, #"<meta[^>]+property=["']\#(property)["'][^>]+content=["']([^"']*)["']"#)
            ?? firstMatch(html, #"<meta[^>]+content=["']([^"']*)["'][^>]+property=["']\#(property)["']"#)
    }

    private static func meta(_ html: String, name: String) -> String? {
        firstMatch(html, #"<meta[^>]+name=["']\#(name)["'][^>]+content=["']([^"']*)["']"#)
            ?? firstMatch(html, #"<meta[^>]+content=["']([^"']*)["'][^>]+name=["']\#(name)["']"#)
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                     "&rdquo;": "”", "&ldquo;": "“"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities like &#8217; or &#x2019;
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Files

    static func pdfText(_ document: PDFDocument?) -> String {
        guard let document else { return "" }
        var pages: [String] = []
        for i in 0..<min(document.pageCount, 200) {
            if let text = document.page(at: i)?.string { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    static func pdfThumbnail(_ url: URL) -> Data? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        #if os(macOS)
        let image = page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        #else
        return page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox).jpegData(compressionQuality: 0.7)
        #endif
    }

    /// Reads text from a file on disk based on its type.
    static func text(fromFile url: URL) async -> String {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) {
            let text = pdfText(PDFDocument(url: url))
            // Scanned PDFs have no text layer; fall back to OCR on the first pages.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20, let thumb = pdfThumbnail(url) {
                return await recognizeText(in: thumb)
            }
            return text
        }
        if type.conforms(to: .image), let data = try? Data(contentsOf: url) {
            return await recognizeText(in: data)
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || ["md", "markdown", "csv", "json"].contains(url.pathExtension.lowercased()) {
            return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(50_000)) } ?? ""
        }
        if type.conforms(to: .rtf) || type.conforms(to: .html),
           let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        return ""
    }

    // MARK: Images

    /// On-device OCR using the Vision framework.
    static func recognizeText(in imageData: Data) async -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Downscaled JPEG for cards.
    static func thumbnail(from data: Data, maxPixel: Int = 600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    // MARK: Video

    /// A frame for the card and the running time, read on-device.
    static func videoInfo(_ url: URL) async -> (thumbnail: Data?, duration: Double) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let time = CMTime(seconds: duration.isFinite ? min(1, duration / 2) : 0, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time) else { return (nil, duration) }
        return (jpeg(frame.image), duration)
    }

    /// Speech-to-text for a video's audio, entirely on-device. Returns "" if unavailable or not permitted.
    static func transcribe(_ videoURL: URL) async -> String {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition
        else { return "" }

        // Pull the audio track out into a temporary .m4a for the recognizer.
        let asset = AVURLAsset(url: videoURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { return "" }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        export.outputURL = audioURL
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { return "" }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let lock = NSLock()
            var finished = false
            func finish(_ value: String) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                } else if error != nil {
                    finish("")
                }
            }
        }
        return String(text.prefix(40_000))
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
