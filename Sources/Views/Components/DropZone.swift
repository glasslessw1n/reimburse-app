//
//  DropZone.swift
//  报销整理Native
//
//  拖拽 + 点击上传文件。支持 pdf / jpg / png / bmp / webp。
//

import SwiftUI
import UniformTypeIdentifiers

struct DropZone: View {
    @Binding var isTargeted: Bool
    let onFiles: ([URL]) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundColor(isTargeted
                    ? Color(red: 0.98, green: 0.36, blue: 0.10)
                    : Color.gray.opacity(0.3))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted
                              ? Color(red: 0.98, green: 0.36, blue: 0.10).opacity(0.06)
                              : Color.gray.opacity(0.03))
                )

            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundColor(.gray.opacity(0.6))
                Text("把发票拖进来")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text("支持 PDF / JPG / PNG · 一次可拖多张")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(height: 180)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onTapGesture {
            openPicker()
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                lock.lock(); collected.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let filtered = collected.filter { isSupported($0) }
            if !filtered.isEmpty { onFiles(filtered) }
        }
        return true
    }

    private func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["pdf", "jpg", "jpeg", "png", "bmp", "webp"].contains(ext)
    }

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.pdf,
            UTType.jpeg,
            UTType.png,
            UTType.bmp,
            UTType("org.webmproject.webp") ?? .image
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            onFiles(panel.urls)
        }
    }
}
