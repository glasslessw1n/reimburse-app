//
//  DropZone.swift
//  报销整理Native
//
//  拖拽 + 点击上传文件。支持 pdf / jpg / png / bmp / webp。
//

import SwiftUI
import UniformTypeIdentifiers
import Synchronization

struct DropZone: View {
    @Binding var isTargeted: Bool
    let onFiles: ([URL]) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .foregroundStyle(isTargeted
                    ? .brandOrange
                    : Color.gray.opacity(0.3))
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted
                              ? .brandOrange.opacity(0.06)
                              : (isHovering ? .brandOrange.opacity(0.03) : Color.gray.opacity(0.03)))
                )

            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.gray.opacity(0.6))
                Text("把发票、单据拖进来")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("支持 PDF / JPG / PNG · 一次可拖多张")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 180)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onTapGesture {
            openPicker()
        }
        .onHover { isHovering = $0 }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collected = Mutex<[URL]>([])
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url = url else { return }
                collected.withLock { $0.append(url) }
            }
        }
        group.notify(queue: .main) {
            let filtered = collected.withLock { $0 }.filter { isSupported($0) }
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
