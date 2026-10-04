//
//  ZipPackager.swift
//  报销整理Native
//
//  把 session 目录的 trips/ 打成 ZIP，保存到 ~/Downloads/。
//  对应 core/packager.py:package_to_file
//
//  ZIP 结构：
//    报销单据_<时间>/
//    ├── <mmdd-mmdd 城市>/<重命名后的文件>  ← 行程 1
//    ├── <mmdd-mmdd 城市>/<重命名后的文件>  ← 行程 2
//    └── ...
//
//  不包含 manifest.json、originals/、报销明细.xlsx
//

import Foundation

@MainActor
enum ZipPackager {
    enum PackageError: LocalizedError {
        case sessionNotFound
        case tripsDirMissing
        case zipFailed(String)

        var errorDescription: String? {
            switch self {
            case .sessionNotFound: return "会话目录不存在"
            case .tripsDirMissing: return "行程目录未生成，请先完成整理"
            case .zipFailed(let s): return "打包失败：\(s)"
            }
        }
    }

    /// 打包并返回 ZIP 路径（不删除 session 目录）
    /// - Parameter includeExcel: 是否生成 报销明细.xlsx 放入 ZIP
    static func package(session: SessionManager, includeExcel: Bool = true) throws -> URL {
        let root = session.rootDir
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw PackageError.sessionNotFound
        }

        let tripsDir = root.appendingPathComponent("trips")
        guard FileManager.default.fileExists(atPath: tripsDir.path) else {
            throw PackageError.tripsDirMissing
        }

        let timestamp = Self.timestampString()
        let zipFolderName = "报销单据\(timestamp)"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let zipURL = downloads.appendingPathComponent("\(zipFolderName).zip")

        // 用临时 staging 目录让 zip 顶层是「报销单据_<时间>/」
        // 结构：
        //   报销单据_<时间>/
        //   ├── [可选] 报销明细.xlsx
        //   ├── <mmdd-mmdd 城市>/<文件>.pdf
        //   └── <mmdd-mmdd 城市>/<文件>.pdf
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reimburse-staging-\(UUID().uuidString)")
        let stagingFolder = stagingRoot.appendingPathComponent(zipFolderName)
        do {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            // 把 trips 下的各行程子目录复制到 staging
            let contents = try FileManager.default.contentsOfDirectory(at: tripsDir, includingPropertiesForKeys: nil)
            for src in contents {
                let dst = stagingFolder.appendingPathComponent(src.lastPathComponent)
                try FileManager.default.copyItem(at: src, to: dst)
            }
            // 勾选时才生成报销明细.xlsx
            if includeExcel {
                let xlsxURL = stagingFolder.appendingPathComponent("报销明细.xlsx")
                do {
                    try ExcelBuilder.build(bills: session.manifest.bills, outputURL: xlsxURL)
                } catch {
                    FileHandle.standardError.write(Data("[ZipPackager] Excel 生成失败: \(error.localizedDescription)\n".utf8))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw PackageError.zipFailed("staging 失败：\(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
        }

        // 用 ditto 打包（macOS 自带，自动跳过空目录和 .DS_Store）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c",                  // create archive
            "-k",                  // PKZip 格式
            "-X",                  // skip resource forks
            "--sequesterRsrc",
            "--noextattr",
            "--noacl",
            stagingRoot.path,      // 源：临时目录（顶层是 报销单据_<时间>）
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
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
