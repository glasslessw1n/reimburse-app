//
//  PopUpButton.swift
//  报销整理Native
//
//  SwiftUI 的 Picker(.menu) 内部宽度不可控（chevron padding 导致"看起来窄"）。
//  这里用 NSPopUpButton 包一层，统一外观为圆角边框输入框风格、宽度严格可控。
//

import SwiftUI
import AppKit

/// macOS 原生下拉按钮（统一外观：圆角边框 + 系统蓝/灰底色 + chevron）
struct PopUpButton<Item: Hashable & Equatable, ItemLabel: View>: NSViewRepresentable {
    let items: [Item]
    @Binding var selection: Item
    let width: CGFloat
    let itemLabel: (Item) -> ItemLabel

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let btn = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        btn.bezelStyle = .texturedRounded   // 圆角风格
        btn.font = .systemFont(ofSize: 13)
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        rebuild(btn)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        rebuild(btn)
        // 同步 selection
        if let popup = btn as? NSPopUpButton {
            let titles = items.map { title(for: $0) }
            if let idx = items.firstIndex(of: selection) {
                if popup.indexOfSelectedItem != idx {
                    popup.selectItem(at: idx)
                }
            } else if popup.indexOfSelectedItem >= titles.count {
                popup.selectItem(at: 0)
            }
        }
    }

    private func rebuild(_ btn: NSButton) {
        guard let popup = btn as? NSPopUpButton else { return }
        popup.removeAllItems()
        for item in items {
            let title = self.title(for: item)
            popup.addItem(withTitle: title)
        }
        if let idx = items.firstIndex(of: selection) {
            popup.selectItem(at: idx)
        }
    }

    private func title(for item: Item) -> String {
        // 简单映射：itemLabel 是 SwiftUI View，不能直接拿 title
        // 这里用 NSStringFromStringRepresentation fallback
        // 调用方可以传 Text-based label，但我们这里只取 rawValue 字符串
        if let s = item as? String { return s }
        return "\(item)"
    }

    final class Coordinator: NSObject {
        let parent: PopUpButton
        init(_ parent: PopUpButton) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < parent.items.count else { return }
            parent.selection = parent.items[idx]
        }
    }
}

/// 便利初始化：items 是 `(value, label)` 数组
struct PopUpButtonWithLabel<Item: Hashable & Equatable>: NSViewRepresentable {
    let entries: [(Item, String)]
    @Binding var selection: Item
    let width: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let btn = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        btn.bezelStyle = .texturedRounded
        btn.font = .systemFont(ofSize: 13)
        btn.target = context.coordinator
        btn.action = #selector(Coordinator.changed(_:))
        rebuild(btn)
        return btn
    }

    func updateNSView(_ btn: NSButton, context: Context) {
        rebuild(btn)
        if let popup = btn as? NSPopUpButton {
            if let idx = entries.firstIndex(where: { $0.0 == selection }) {
                if popup.indexOfSelectedItem != idx {
                    popup.selectItem(at: idx)
                }
            }
        }
    }

    private func rebuild(_ btn: NSButton) {
        guard let popup = btn as? NSPopUpButton else { return }
        popup.removeAllItems()
        for (_, label) in entries {
            popup.addItem(withTitle: label)
        }
        if let idx = entries.firstIndex(where: { $0.0 == selection }) {
            popup.selectItem(at: idx)
        }
    }

    final class Coordinator: NSObject {
        let parent: PopUpButtonWithLabel
        init(_ parent: PopUpButtonWithLabel) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < parent.entries.count else { return }
            parent.selection = parent.entries[idx].0
        }
    }
}
