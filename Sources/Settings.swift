import AppKit
import Carbon
import ServiceManagement

// MARK: - Shortcut

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Shortcut.names[Int(keyCode)] ?? "键\(keyCode)")
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let names: [Int: String] = {
        var d: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in f.enumerated() { d[k] = "F\(i + 1)" }
        return d
    }()
}

enum HotAction: String, Codable, CaseIterable, Identifiable {
    case open, pasteNext, resetSequence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "打开剪贴板历史"
        case .pasteNext: return "连续粘贴"
        case .resetSequence: return "重置粘贴顺序"
        }
    }
    var defaultShortcut: Shortcut? {
        switch self {
        case .open: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
        case .pasteNext, .resetSequence: return nil
        }
    }
}

// MARK: - Options

enum Retention: String, CaseIterable, Identifiable {
    case day, week, month, threeMonths, sixMonths, year, forever
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "1 天"
        case .week: return "1 周"
        case .month: return "1 个月"
        case .threeMonths: return "3 个月"
        case .sixMonths: return "6 个月"
        case .year: return "1 年"
        case .forever: return "永久"
        }
    }
    /// nil = keep forever.
    var seconds: TimeInterval? {
        let d: TimeInterval = 86400
        switch self {
        case .day: return d
        case .week: return 7 * d
        case .month: return 30 * d
        case .threeMonths: return 91 * d
        case .sixMonths: return 182 * d
        case .year: return 365 * d
        case .forever: return nil
        }
    }
}

enum PrimaryAction: String, CaseIterable, Identifiable {
    case paste, copy
    var id: String { rawValue }
    var title: String { self == .paste ? "粘贴到当前 App" : "复制到剪贴板" }
}

enum OCRMode: String, CaseIterable, Identifiable {
    case fast, accurate
    var id: String { rawValue }
    var title: String { self == .fast ? "快速" : "精确" }
}

struct DisabledApp: Codable, Equatable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var recording: Bool { didSet { d.set(recording, forKey: "recording") } }
    @Published var retention: Retention { didSet { d.set(retention.rawValue, forKey: "retention") } }
    @Published var primaryAction: PrimaryAction { didSet { d.set(primaryAction.rawValue, forKey: "primaryAction") } }
    @Published var preferPlainText: Bool { didSet { d.set(preferPlainText, forKey: "preferPlainText") } }
    @Published var linkPreviews: Bool { didSet { d.set(linkPreviews, forKey: "linkPreviews") } }
    @Published var moveUsedToTop: Bool { didSet { d.set(moveUsedToTop, forKey: "moveUsedToTop") } }
    @Published var ocrEnabled: Bool { didSet { d.set(ocrEnabled, forKey: "ocrEnabled") } }
    @Published var ocrMode: OCRMode { didSet { d.set(ocrMode.rawValue, forKey: "ocrMode") } }
    @Published var recordUniversalClipboard: Bool { didSet { d.set(recordUniversalClipboard, forKey: "recordUniversalClipboard") } }
    @Published var sequenceTimeout: Double { didSet { d.set(sequenceTimeout, forKey: "sequenceTimeout") } }
    @Published var sequenceNewline: Bool { didSet { d.set(sequenceNewline, forKey: "sequenceNewline") } }
    @Published var disabledApps: [DisabledApp] {
        didSet { d.set(try? JSONEncoder().encode(disabledApps), forKey: "disabledApps") }
    }
    @Published var shortcuts: [HotAction: Shortcut] {
        didSet {
            let m = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
            d.set(try? JSONEncoder().encode(m), forKey: "shortcuts")
            onShortcutsChanged?()
        }
    }
    var onShortcutsChanged: (() -> Void)?

    private init() {
        recording = d.object(forKey: "recording") as? Bool ?? true
        retention = Retention(rawValue: d.string(forKey: "retention") ?? "") ?? .threeMonths
        primaryAction = PrimaryAction(rawValue: d.string(forKey: "primaryAction") ?? "") ?? .paste
        preferPlainText = d.bool(forKey: "preferPlainText")
        linkPreviews = d.object(forKey: "linkPreviews") as? Bool ?? true
        moveUsedToTop = d.object(forKey: "moveUsedToTop") as? Bool ?? true
        ocrEnabled = d.object(forKey: "ocrEnabled") as? Bool ?? true
        ocrMode = OCRMode(rawValue: d.string(forKey: "ocrMode") ?? "") ?? .accurate
        // Raycast: "Save Universal Clipboard Items Immediately", off by default (saved after paste).
        recordUniversalClipboard = d.object(forKey: "recordUniversalClipboard") as? Bool ?? false
        sequenceTimeout = d.object(forKey: "sequenceTimeout") as? Double ?? 60
        sequenceNewline = d.object(forKey: "sequenceNewline") as? Bool ?? true
        if let data = d.data(forKey: "disabledApps"),
           let apps = try? JSONDecoder().decode([DisabledApp].self, from: data) {
            disabledApps = apps
        } else {
            disabledApps = [
                DisabledApp(bundleID: "com.apple.Passwords", name: "密码"),
                DisabledApp(bundleID: "com.apple.keychainaccess", name: "钥匙串访问"),
            ]
        }
        if let data = d.data(forKey: "shortcuts"),
           let m = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            var s: [HotAction: Shortcut] = [:]
            for (k, v) in m { if let a = HotAction(rawValue: k) { s[a] = v } }
            shortcuts = s
        } else {
            var s: [HotAction: Shortcut] = [:]
            for a in HotAction.allCases { if let def = a.defaultShortcut { s[a] = def } }
            shortcuts = s
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Clipcairn: login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
