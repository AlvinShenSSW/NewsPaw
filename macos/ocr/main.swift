import Foundation
import Vision

let maxBytes = 2 * 1024 * 1024
let supported = Set(["en-US", "ja-JP", "zh-Hans"])

func readImage() throws -> Data {
    let handle = FileHandle.standardInput
    var bytes = Data()
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        guard bytes.count + chunk.count <= maxBytes else { throw OCRFailure.invalidInput }
        bytes.append(chunk)
    }
    guard !bytes.isEmpty else { throw OCRFailure.invalidInput }
    return bytes
}

enum OCRFailure: Error {
    case invalidInput
}

do {
    guard CommandLine.arguments.count == 2 else { throw OCRFailure.invalidInput }
    let argument = CommandLine.arguments[1]
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let available = try request.supportedRecognitionLanguages().filter(supported.contains).sorted()
    let result: [String]
    if argument == "--languages" {
        result = available
    } else {
        guard available.contains(argument) else { throw OCRFailure.invalidInput }
        request.recognitionLanguages = [argument]
        let handler = VNImageRequestHandler(data: try readImage())
        try handler.perform([request])
        let observations = (request.results ?? []).sorted { left, right in
            if abs(left.boundingBox.midY - right.boundingBox.midY) < 0.007 {
                return left.boundingBox.minX < right.boundingBox.minX
            }
            return left.boundingBox.midY > right.boundingBox.midY
        }
        guard observations.count <= 100 else { throw OCRFailure.invalidInput }
        result = observations.compactMap { $0.topCandidates(1).first?.string }
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(result))
} catch {
    exit(EXIT_FAILURE)
}
