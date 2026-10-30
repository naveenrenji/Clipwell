import Foundation
import Vision

/// On-device text recognition for copied images, so screenshots are searchable.
/// Runs on its own low-priority queue; nothing leaves the Mac.
enum OCR {
    private static let queue = DispatchQueue(label: "clipboard.ocr", qos: .utility)
    private static let maxFileBytes = 25_000_000
    private static let maxCharacters = 50_000

    static func recognize(imageAt path: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let size = attributes?[.size] as? Int, size <= maxFileBytes else { return completion(nil) }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
            } catch {
                return completion(nil)
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            completion(text.isEmpty ? nil : String(text.prefix(maxCharacters)))
        }
    }
}
