//
//  ZipPackager.swift
//  报销整理Native
//
//  把 session 目录打成 ZIP，保存到 ~/Downloads/。
//  对应 core/packager.py:package_to_file
//
//  ZIP 结构：
//    报销单据_<sid>_<时间>/
//    ├── <各行程子目录>/<重命名后的文件>
//    ├── 本地/<文件>
//    ├── manifest.json
//    └── 报销明细.xlsx（可选；M8.5 再加）
//

import Foundation

@MainActor
enum ZipPackager {
    enum PackageError: LocalizedError {
        case sessionNotFound
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .sessionNotFound: return "会话目录不存在"
            case .zipFailed(let s): return "打包失败：\(s)"
            }
        }
    }

    /// 打包并返回 ZIP 路径（不删除 session 目录）
    static func package(session: SessionManager, includeExcel: Bool = false) throws -> URL {
        let root = session.rootDir
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw PackageError.sessionNotFound
        }

        let timestamp = Self.timestampString()
        let zipName = "报销单据_\(session.sid)_\(timestamp)"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let zipURL = downloads.appendingPathComponent("\(zipName).zip")

        // 用 /usr/bin/ditto 打包（macOS 自带）
        // - ditto 自动跳过空目录（zip 命令做不到）
        // - --sequesterRsrc 保留 metadata + 跳过 .DS_Store
        // - -X 跳过 macOS 扩展属性
        // 注意：ditto 参数顺序是「源在前，目标在后」
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c",                  // create archive
            "-k",                  // PKZip 格式
            "-X",                  // skip resource forks
            "--sequesterRsrc",
            "--noextattr",
            "--noacl",
            root.path,             // 源：整个 session 根
            zipURL.path            // 目标 zip 路径
        ]

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                throw PackageError.zipFailed("ditto exit \(task.terminationStatus)")
            }
        } catch {
            throw PackageError.zipFailed(error.localizedDescription)
        }
        return zipURL
    }

    /// 在 finalize 之后把 bills 物理文件搬到 trips/{dirname}/{targetFilename}
    static func arrangeFiles(session: SessionManager) throws {
        let root = session.rootDir
        let originals = root.appendingPathComponent("originals")
        let tripsDir = root.appendingPathComponent("trips")
        try? FileManager.default.createDirectory(at: tripsDir, withIntermediateDirectories: true)

        // 行程内
        for trip in session.manifest.trips {
            let sub = tripsDir.appendingPathComponent(trip.dirname)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for bill in trip.bills {
                try moveBill(bill, from: originals, to: sub, session: session)
            }
        }

        // 本地：只在有票据时才创建目录
        if !session.manifest.local.isEmpty {
            let localDir = tripsDir.appendingPathComponent("本地")
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            for bill in session.manifest.local {
                try moveBill(bill, from: originals, to: localDir, session: session)
            }
        }
    }

    private static func moveBill(
        _ bill: BillInfo,
        from originals: URL,
        to sub: URL,
        session: SessionManager
    ) throws {
        let src = originals.appendingPathComponent(bill.sourceFile)
        guard FileManager.default.fileExists(atPath: src.path) else { return }

        // 优先用 hotel match 后覆盖的 finalTargetName（住宿发票匹配水单后改名）
        let newName = bill.finalTargetName.isEmpty
            ? SessionManager.buildFilename(for: bill)
            : bill.finalTargetName
        let ext = (newName as NSString).pathExtension
        let base = (newName as NSString).deletingPathExtension

        var finalName = newName
        var suffix = 2

        while FileManager.default.fileExists(atPath: sub.appendingPathComponent(finalName).path) {
            // 先试字母后缀（B/C/D...），超过 26 用 _N
            if suffix <= 26 {
                finalName = "\(base)\(String(UnicodeScalar(64 + suffix)!))\(ext.isEmpty ? "" : ".\(ext)")"
            } else {
                finalName = "\(base)_\(suffix - 26)\(ext.isEmpty ? "" : ".\(ext)")"
            }
            suffix += 1
        }

        let dst = sub.appendingPathComponent(finalName)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
