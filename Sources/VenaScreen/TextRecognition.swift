import AppKit
import Vision

/// Reads the text in a screenshot with Vision, Apple's on-device OCR.
/// Nothing leaves the Mac. If the image has no text but has a QR code or
/// barcode, its contents are returned instead.
enum TextRecognition {
    /// Runs off the main thread and calls back on it with the text found,
    /// or nil when there is nothing readable.
    static func recognize(_ url: URL, completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = recognizeSync(url)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func recognizeSync(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.recognitionLanguages = ["es-ES", "en-US"]

        let codes = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([text, codes])

        let lines = (text.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !lines.isEmpty { return lines.joined(separator: "\n") }

        let payloads = (codes.results ?? []).compactMap(\.payloadStringValue)
        return payloads.isEmpty ? nil : payloads.joined(separator: "\n")
    }
}
