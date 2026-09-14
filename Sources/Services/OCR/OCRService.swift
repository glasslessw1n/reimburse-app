//
//  OCRService.swift
//  报销整理Native
//
//  Apple Vision 文字识别（VNRecognizeTextRequest）。
//  对应 core/ocr.py:image_to_text
//
//  Vision 文档：
//  - 支持中英文混合（revision 3+ 默认开启）
//  - macOS 14 上 revision 自动选最新；可显式设 .latest
//  - recognitionLevel = .accurate 慢但准；.fast 快但差；发票选 accurate
//

import Foundation
@preconcurrency import Vision
import AppKit

enum OCRError: Error {
    case invalidImage
    case visionFailed(Error)
    case noTextFound
}

struct OCRService {
    /// 把单张图片（jpg/png/bmp/webp）的 Data 转为识别文本
    static func recognize(imageData: Data) async throws -> String {
        guard let nsImage = NSImage(data: imageData),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else {
            throw OCRError.invalidImage
        }
        return try await recognize(cgImage: cgImage)
    }

    /// CGImage → 文本
    static func recognize(cgImage: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    continuation.resume(throwing: OCRError.visionFailed(err))
                    return
                }
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.revision = VNRecognizeTextRequestRevision3

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: OCRError.visionFailed(error))
                }
            }
        }
    }
}
