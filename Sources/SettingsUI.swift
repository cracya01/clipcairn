import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var s = AppSettings.shared
    let dataPath: String
    let store: ClipStore
    @State private var axOK = AXIsProcessTrusted()
    @State private var access = NSPasteboard.general.accessBehavior
    @State private var loginOK = AppSettings.shared.launchAtLogin
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("通用") {
                Toggle("记录剪贴板", isOn: $s.recording)
                Toggle("开机自动启动", isOn: Binding(get: { loginOK }, set: { s.launchAtLogin = $0; loginOK = s.launchAtLogin }))
                ForEach(HotAction.allCases) { a in
                    LabeledContent(a.title) { ShortcutField(action: a) }
                }
            }
            Section("剪贴板历史") {
                Picker("保留时长", selection: $s.retention) {
                    ForEach(Retention.allCases) { Text($0.title).tag($0) }
                }
                Picker("回车 / 双击", selection: $s.primaryAction) {
                    ForEach(PrimaryAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("默认按纯文本粘贴", isOn: $s.preferPlainText)
                Toggle("显示链接的图标和预览图（会访问对应网站）", isOn: $s.linkPreviews)
                Toggle("粘贴或复制后把该条移到最上面", isOn: $s.moveUsedToTop)
                Toggle("立即保存其他 Apple 设备复制的内容", isOn: $s.recordUniversalClipboard)
                Text("关闭时，iPhone、iPad 等通过通用剪贴板传来的内容在这台 Mac 上粘贴后才保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("文字识别") {
                Toggle("识别图片中的文字（可搜索）", isOn: $s.ocrEnabled)
                Picker("识别模式", selection: $s.ocrMode) {
                    ForEach(OCRMode.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!s.ocrEnabled)
            }
            Section("连续粘贴") {
                Picker("超时后从头开始", selection: $s.sequenceTimeout) {
                    Text("30 秒").tag(30.0)
                    Text("1 分钟").tag(60.0)
                    Text("3 分钟").tag(180.0)
                }
                Toggle("每次粘贴文本后换行", isOn: $s.sequenceNewline)
            }
            Section("不记录这些 App 里复制的内容") {
                ForEach(s.disabledApps) { app in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) { s.disabledApps.removeAll { $0 == app } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加 App…") { addApp() }
            }
            Section("权限") {
                LabeledContent("辅助功能（自动粘贴）") {
                    if axOK { Text("已授权").foregroundStyle(.green) } else {
                        Button("去授权") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                LabeledContent("读取剪贴板") {
                    Text(accessText).foregroundStyle(access == .alwaysAllow ? .green : .orange)
                }
                if access != .alwaysAllow {
                    Text("macOS 默认会在 App 读取剪贴板时询问。请在系统设置里把 Clipcairn 的剪贴板访问设为「始终允许」，否则复制时可能反复弹窗或记录不到。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("数据") {
                LabeledContent("数据库（已加密）") {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dataPath)])
                    }
                }
                Text(dataPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("删除记录") {
                LabeledContent("删除最近复制的记录") {
                    Menu("选择时间段") {
                        ForEach([("最近 5 分钟", 300.0), ("最近 15 分钟", 900), ("最近 30 分钟", 1800),
                                 ("最近 1 小时", 3600), ("最近 24 小时", 86400)], id: \.0) { item in
                            Button(item.0) { deleteRecent(item.0, item.1) }
                        }
                    }
                    .fixedSize()
                }
                LabeledContent("删除全部记录") {
                    Button("全部删除…", role: .destructive) { deleteAll() }
                }
                Text("删除前会确认，删除后无法恢复。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onReceive(tick) { _ in
            axOK = AXIsProcessTrusted()
            access = NSPasteboard.general.accessBehavior
        }
    }

    private func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: button)
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func deleteRecent(_ title: String, _ secs: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-secs)
        let list = store.entries.filter { $0.created >= cutoff }
        guard !list.isEmpty else {
            _ = confirm("\(title)没有记录", "", "好")
            return
        }
        let pinned = list.filter(\.pinned).count
        let detail = pinned > 0 ? "其中 \(pinned) 条是钉选的，也会一起删除。删除后无法恢复。" : "删除后无法恢复。"
        if confirm("删除\(title)复制的 \(list.count) 条记录？", detail, "删除") {
            store.delete(list.map(\.id))
        }
    }

    private func deleteAll() {
        let list = store.entries
        guard !list.isEmpty else { return }
        let pinned = list.filter(\.pinned).count
        let detail = pinned > 0 ? "包括 \(pinned) 条钉选记录。删除后无法恢复。" : "删除后无法恢复。"
        if confirm("删除全部 \(list.count) 条剪贴板记录？", detail, "全部删除") {
            store.delete(list.map(\.id))
        }
    }

    private var accessText: String {
        switch access {
        case .alwaysAllow: return "始终允许"
        case .alwaysDeny: return "始终拒绝"
        case .ask: return "每次询问"
        default: return "尚未询问"
        }
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            guard let bid = Bundle(url: url)?.bundleIdentifier,
                  !s.disabledApps.contains(where: { $0.bundleID == bid }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            s.disabledApps.append(DisabledApp(bundleID: bid, name: name))
        }
    }
}

/// Click, then press a key combination to set a shortcut. Delete clears it.
struct ShortcutField: View {
    let action: HotAction
    @ObservedObject var s = AppSettings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "请按下快捷键…" : (s.shortcuts[action]?.display ?? "未设置")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if s.shortcuts[action] != nil && !recording {
                Button { s.shortcuts[action] = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        Hotkeys.shared.register([:])   // let the current shortcuts be typed while recording
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                  // Esc cancels
            if e.keyCode == 51 { s.shortcuts[action] = nil; stop(); return nil }  // Delete clears
            let mods = Shortcut.carbonModifiers(e.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }        // needs a modifier
            s.shortcuts[action] = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        Hotkeys.shared.register(s.shortcuts)
    }
}
