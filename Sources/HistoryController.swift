import AppKit
import SwiftUI

/// Owns the history panel: showing/hiding, keyboard shortcuts, menus and sheets.
@MainActor
final class HistoryController: NSObject {
    let model: HistoryModel
    let panel = HistoryPanel()
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(model: HistoryModel) {
        self.model = model
        super.init()
        model.panel = panel
        panel.setContent(HistoryView(m: model, store: model.store, actions: self))
        panel.onResignKey = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.willOpen()
        panel.present()
        installKeyMonitor()
    }

    func hide() {
        panel.orderOut(nil)
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if let k = mouseMonitor { NSEvent.removeMonitor(k); mouseMonitor = nil }
    }

    // MARK: Keyboard

    /// True while the preview's text editor (not the search field) has keyboard focus.
    private var editorFocused: Bool {
        guard let tv = panel.firstResponder as? NSTextView else { return false }
        return !tv.isFieldEditor
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel, self.panel.attachedSheet == nil else { return e }
            return self.handle(e) ? nil : e
        }
        // Right-click on a list row opens the same actions menu as ⌘K, at the pointer (as in Raycast).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            guard let self, e.window === self.panel, self.panel.attachedSheet == nil,
                  let id = self.model.hoveredID else { return e }
            self.model.selectedID = id
            self.showActionsMenu(at: e.locationInWindow)
            return nil
        }
    }

    /// Returns true when the key was handled.
    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (e.keyCode, mods) {
        case (53, []):                                   // Esc
            hide(); return true
        case (126, []) where !editorFocused:             // ↑
            model.move(-1); return true
        case (125, []) where !editorFocused:             // ↓
            model.move(1); return true
        case (36, []), (76, []):                         // ↩ (⇧↩ in the editor inserts a newline)
            model.primary(); return true
        case (36, [.command]):                           // ⌘↩
            model.copy(); return true
        case (36, [.option]):                            // ⌥↩
            model.pastePlainText(); return true
        default: break
        }
        switch (key, mods) {
        case ("k", [.command]): showActionsMenu(); return true
        case ("p", [.command]): showFilterMenu(); return true
        case (".", [.command]): model.togglePin(); return true
        case ("e", [.command]): rename(); return true
        case ("o", [.command]): model.openLink(); return true
        case ("x", [.control]): model.delete(); return true
        case ("f", [.command]): model.focusSearch += 1; return true
        case ("w", [.command]): hide(); return true
        case (",", [.command]): hide(); model.openSettings(); return true
        default: return false
        }
    }

    // MARK: Menus

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private var menuActions: [MenuAction] = []

    private func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [],
                      enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        menuActions.append(a)
        let it = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = a
        it.isEnabled = enabled
        return it
    }

    private func popUp(_ menu: NSMenu, atRight: Bool, at location: NSPoint? = nil) {
        menu.autoenablesItems = false
        guard let content = panel.contentView else { return }
        let b = content.bounds
        let point = location.map { content.convert($0, from: nil) }
            ?? (atRight ? NSPoint(x: b.maxX - 250, y: 46) : NSPoint(x: b.maxX - 180, y: b.maxY - 46))
        panel.holdOpen = true
        menu.popUp(positioning: nil, at: point, in: content)
        panel.holdOpen = false
        menuActions.removeAll()
    }

    func showFilterMenu() {
        let menu = NSMenu()
        let all = item("全部类型", "0", .command) { [weak self] in self?.model.filter = nil }
        all.state = model.filter == nil ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        let kinds: [ClipKind] = [.text, .image, .file, .link, .email, .color]
        for (i, k) in kinds.enumerated() {
            let it = item("仅\(k.title)", "\(i + 1)", .command) { [weak self] in self?.model.filter = k }
            it.state = model.filter == k ? .on : .off
            menu.addItem(it)
        }
        popUp(menu, atRight: false)
    }

    func showActionsMenu(at location: NSPoint? = nil) {
        guard let e = model.selected else { return }
        let m = model
        let menu = NSMenu()
        let pasteTitle = m.primaryTitle.hasPrefix("粘贴") ? m.primaryTitle : "粘贴到 \(m.targetApp?.localizedName ?? "当前 App")"
        menu.addItem(item(pasteTitle, "\r", []) { m.paste() })
        menu.addItem(item("复制到剪贴板", "\r", .command) { m.copy() })
        if e.kind.isTextual {
            menu.addItem(item("按纯文本粘贴", "\r", .option) { m.pastePlainText() })
        }
        if e.kind == .image {
            menu.addItem(item("按 PNG 粘贴") { m.pastePNG() })
            menu.addItem(.separator())
            menu.addItem(item("复制图片中的文字") { m.copyRecognizedText() })
            menu.addItem(item("复制二维码内容") { m.copyQRCode() })
        }
        if e.kind == .link || e.kind == .email {
            menu.addItem(item(e.kind == .link ? "在浏览器中打开" : "写邮件", "o", .command) { m.openLink() })
        }
        menu.addItem(item("分享…") { [weak self] in self?.share() })
        menu.addItem(.separator())
        menu.addItem(item(e.pinned ? "取消钉选" : "钉选", ".", .command) { m.togglePin() })
        menu.addItem(item("重命名…", "e", .command) { [weak self] in self?.rename() })
        menu.addItem(.separator())
        menu.addItem(item("删除", "x", .control) { m.delete() })
        popUp(menu, atRight: true, at: location)
    }

    // MARK: Sheets

    private func sheet(_ alert: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        panel.holdOpen = true
        alert.beginSheetModal(for: panel) { [weak self] r in
            self?.panel.holdOpen = false
            done(r)
            self?.panel.makeKey()
        }
    }

    func rename() {
        guard let e = model.selected else { return }
        let a = NSAlert()
        a.messageText = "重命名"
        a.informativeText = "只改列表里显示的名字，内容不变。留空则恢复原标题。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = e.name ?? ""
        field.placeholderString = e.title
        a.accessoryView = field
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        sheet(a) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.model.store.rename(e.id, field.stringValue)
        }
    }

    func share() {
        let items = model.shareItems()
        guard !items.isEmpty, let content = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        panel.holdOpen = true
        let rect = NSRect(x: content.bounds.maxX - 200, y: 40, width: 1, height: 1)
        picker.show(relativeTo: rect, of: content, preferredEdge: .maxY)
    }
}

extension HistoryController: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            panel.holdOpen = false
            if service != nil { hide() } else { panel.makeKey() }
        }
    }
}
