import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// Runs only on the image provided by the isolated-window capture path.
/// It never reads the desktop, moves the cursor, or opens a window.
final class WindowImageRecognizer {
    private var models: [String: VNCoreMLModel] = [:]

    func recognize(arguments: [String: Any]) throws -> [String: Any] {
        guard let encoded = arguments["image_base64"] as? String,
              let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RuntimeError.message("recognize requires a valid image_base64 value.")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw RuntimeError.message("Image dimensions are outside the supported range.")
        }
        var observations: [[String: Any]] = []
        var warnings: [String] = []
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let languages = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["zh-Hans", "en-US"].filter { languages.contains($0) }
        try VNImageRequestHandler(cgImage: image).perform([request])
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.25 else { continue }
            observations.append([
                "kind": "text", "text": candidate.string,
                "confidence": candidate.confidence,
                "frame": frame(observation.boundingBox, width: width, height: height),
            ])
        }

        if let modelPath = arguments["model_path"] as? String, !modelPath.isEmpty {
            do {
                let model = try model(at: modelPath)
                let icons = VNCoreMLRequest(model: model)
                icons.imageCropAndScaleOption = .scaleFill
                try VNImageRequestHandler(cgImage: image).perform([icons])
                if let results = icons.results as? [VNRecognizedObjectObservation] {
                    for observation in results.prefix(1000) where observation.confidence >= 0.25 {
                        observations.append([
                            "kind": "icon", "text": observation.labels.first?.identifier ?? "icon",
                            "confidence": observation.confidence,
                            "frame": frame(observation.boundingBox, width: width, height: height),
                        ])
                    }
                } else {
                    warnings.append("The local icon model returned an unsupported output format.")
                }
            } catch {
                warnings.append("Local icon recognition failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("No local icon model was configured; this result contains text recognition only.")
        }
        return ["width": width, "height": height, "observations": observations, "warnings": warnings]
    }

    private func model(at path: String) throws -> VNCoreMLModel {
        if let cached = models[path] { return cached }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeError.message("The existing local icon model was not found.")
        }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        defer {
            if compiled != url { try? FileManager.default.removeItem(at: compiled) }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
        models[path] = model
        return model
    }

    private func frame(_ bounds: CGRect, width: Int, height: Int) -> [String: Double] {
        let clipped = bounds.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return [
            "x": clipped.minX * Double(width),
            "y": (1 - clipped.maxY) * Double(height),
            "width": clipped.width * Double(width),
            "height": clipped.height * Double(height),
        ]
    }
}
