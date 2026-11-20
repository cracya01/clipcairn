import AppKit
import Combine
import SwiftUI

@main
enum ClipcairnMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var store: ClipStore!
    private var watcher: ClipboardWatcher!
    private var paster: Paster!
    private var history: HistoryController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cleanupTimer: Timer?
    private var bag = Set<AnyCancellable>()
    private var dataURL: URL!

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            try openStore()
        } catch {
            fatalAlert(error)
            return
        }
        watcher = ClipboardWatcher(store: store)
        paster = Paster(store: store, watcher: watcher)
        let model = HistoryModel(store: store, paster: paster)
        model.openSettings = { [weak self] in self?.showSettings() }
        history = HistoryController(model: model)

        Hotkeys.shared.handler = { [weak self] action in self?.run(action) }
        Hotkeys.shared.register(settings.shortcuts)
        settings.onShortcutsChanged = { [weak self] in
            guard let self else { return }
            Hotkeys.shared.register(self.settings.shortcuts)
            self.rebuildMenu()
        }

        setUpStatusItem()
        firstRunIfNeeded()
        watcher.start()

        store.applyRetention(settings.retention)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.applyRetention(self.settings.retention)
            }
        }
        settings.$retention.dropFirst().sink { [weak self] r in
            DispatchQueue.main.async { self?.store.applyRetention(r) }
        }.store(in: &bag)
        settings.$recording.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }.store(in: &bag)
    }

    // MARK: Storage

    private func openStore() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipcairn", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.db")
        dataURL = url
        let exists = FileManager.default.fileExists(atPath: url.path)
        var key = try KeyStore.read()
        if key == nil {
            // Never replace the key of an existing database: the old data would become unreadable.
            if exists { throw StartupError.keyMissing(url.path) }
            key = try KeyStore.create()
        }
        let db = try Database(path: url.path, key: key!)
        store = try ClipStore(db: db)
    }

    enum StartupError: Error, CustomStringConvertible {
        case keyMissing(String)
        var description: String {
            switch self {
            case .keyMissing(let p):
                return "钥匙串里找不到数据库密钥，但加密数据库已经存在：\n\(p)\n\n为了不丢数据，Clipcairn 不会新建密钥或覆盖这个文件。"
            }
        }
    }

    private func fatalAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Clipcairn 无法打开剪贴板历史"
        a.informativeText = "\(error)"
        a.alertStyle = .critical
        a.addButton(withTitle: "退出")
        a.runModal()
        NSApp.terminate(nil)
    }

    // MARK: First run

    private func firstRunIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didFirstRun") else { return }
        d.set(true, forKey: "didFirstRun")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Clipcairn 已在菜单栏运行"
        a.informativeText = """
        按 \(settings.shortcuts[.open]?.display ?? "快捷键") 打开剪贴板历史。

        还需要两项授权：
        1. 读取剪贴板：macOS 会询问是否允许 Clipcairn 读取剪贴板，请允许，并在系统设置里设为「始终允许」。
        2. 辅助功能：用来把内容自动粘贴到当前 App。接下来会打开授权提示。
        """
        a.addButton(withTitle: "好")
        a.runModal()
        Paster.requestAccessibility()
    }

    // MARK: Actions

    private func run(_ action: HotAction) {
        switch action {
        case .open: history.toggle()
        case .pasteNext: paster.pasteNext()
        case .resetSequence: paster.resetSequence()
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipcairn")
        rebuildMenu()
    }

    private final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
    private var targets: [Target] = []

    private func menuItem(_ title: String, _ action: HotAction? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let t = Target(run)
        targets.append(t)
        let item = NSMenuItem(title: title, action: #selector(Target.fire), keyEquivalent: "")
        item.target = t
        if let a = action, let s = settings.shortcuts[a] {
            item.title = "\(title)    \(s.display)"
        }
        return item
    }

    private func rebuildMenu() {
        targets.removeAll()
        let m = NSMenu()
        m.addItem(menuItem("打开剪贴板历史", .open) { [weak self] in self?.history.show() })
        m.addItem(menuItem("连续粘贴", .pasteNext) { [weak self] in self?.paster.pasteNext() })
        m.addItem(menuItem("重置粘贴顺序", .resetSequence) { [weak self] in self?.paster.resetSequence() })
        m.addItem(.separator())
        m.addItem(menuItem(settings.recording ? "暂停记录" : "恢复记录") { [weak self] in
            self?.settings.recording.toggle()
        })
        m.addItem(menuItem("设置…") { [weak self] in self?.showSettings() })
        m.addItem(.separator())
        m.addItem(menuItem("退出 Clipcairn") { NSApp.terminate(nil) })
        statusItem.menu = m
        statusItem.button?.appearsDisabled = !settings.recording
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Clipcairn 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(dataPath: dataURL.path, store: store))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
