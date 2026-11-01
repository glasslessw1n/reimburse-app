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
import ImageIO

enum OCRError: Error {
    case invalidImage
    case visionFailed(Error)
    case noTextFound
}

/// continuation 一次性 resume 守卫：Vision 的完成回调与 perform 抛错两条路径
/// 在个别失败模式下都可能触发，无守卫的双 resume 会直接崩溃
private final class ResumeGuard: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

struct OCRService {
    /// 超过这个长边（px）的图片先降采样再识别：手机照片动辄 4000+ px，
    /// Vision 内部缩放前先缩一份，省内存也更快，精度无损（发票文字远大于所需分辨率）
    private static let maxPixelDimension = 3000

    /// 把单张图片（jpg/png/bmp/webp）的 Data 转为识别文本
    /// 走 ImageIO 读取像素 + EXIF 方向（旧实现经 NSImage/tiff 往返会丢方向，竖拍照片侧着识别）
    static func recognize(imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw OCRError.invalidImage
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelW = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelH = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        if max(pixelW, pixelH) > maxPixelDimension {
            // 大图：缩略图通道一次完成降采样 + 方向烘焙
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw OCRError.invalidImage
            }
            return try await recognize(cgImage: thumb, orientation: .up)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.invalidImage
        }
        let rawOrientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        return try await recognize(cgImage: cgImage, orientation: orientation)
    }

    /// CGImage → 文本
    /// - Parameter level: .accurate 为正式识别；.fast 仅用于版式探测等粗粒度场景
    /// - Parameter orientation: 图片的 EXIF 方向（PDF 渲染图恒为 .up）
    static func recognize(
        cgImage: CGImage,
        level: VNRequestTextRecognitionLevel = .accurate,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> String {
        let resumeGuard = ResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                guard resumeGuard.tryResume() else { return }
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
            request.recognitionLevel = level
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            // 发票里的票号、乘客名、酒店名是专有名词，语言纠错反而会把对的改错
            request.usesLanguageCorrection = false
            request.revision = VNRecognizeTextRequestRevision3

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    if resumeGuard.tryResume() {
                        continuation.resume(throwing: OCRError.visionFailed(error))
                    }
                }
            }
        }
    }
}
