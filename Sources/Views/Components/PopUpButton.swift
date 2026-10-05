//
//  PopUpButton.swift
//  报销整理Native
//
//  SwiftUI 的 Picker(.menu) 内部宽度不可控（chevron padding 导致"看起来窄"）。
//  这里用 NSPopUpButton 包一层，统一外观为圆角边框输入框风格、宽度严格可控。
//

import SwiftUI
import AppKit

/// macOS 原生下拉按钮：items 是 `(value, label)` 数组，宽度严格可控
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

        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < parent.entries.count else { return }
            parent.selection = parent.entries[idx].0
        }
    }
}
