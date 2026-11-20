import AppKit
import ApplicationServices
import Carbon

/// Writes entries back to the pasteboard and pastes them into the frontmost app.
@MainActor
final class Paster {
    private let store: ClipStore
    private let watcher: ClipboardWatcher
    private let settings = AppSettings.shared

    // Paste-sequentially state
    private var seqIndex = 0
    private var seqLast: Date?
    private var seqNewestID: Int64?

    init(store: ClipStore, watcher: ClipboardWatcher) {
        self.store = store
        self.watcher = watcher
    }

    enum Content {
        case original            // every captured format
        case plainText(String)
        case png
    }

    // MARK: Pasteboard

    /// Puts content on the general pasteboard, tagged so the watcher does not record it again.
    @discardableResult
    func write(_ entry: ClipEntry, as content: Content, appendNewline: Bool = false) -> Bool {
        let pb = NSPasteboard.general
        switch content {
        case .plainText(let s):
            pb.clearContents()
            pb.setString(appendNewline ? s + "\n" : s, forType: .string)
        case .png:
            let items = store.items(of: entry.id)
            guard let img = Classifier.imageData(in: items),
                  let png = img.type == "public.png" ? img.data : ImageInfo.png(img.data) else { return false }
            pb.clearContents()
            pb.setData(png, forType: .png)
        case .original:
            let items = store.items(of: entry.id)
            guard !items.isEmpty else { return false }
            pb.clearContents()
            // As in Maccy: write every type onto one pasteboard item; writing separate items makes
            // some apps paste formatted text twice. Only file URLs go as separate items, so several
            // copied files paste as several files.
            let fileURL = NSPasteboard.PasteboardType.fileURL.rawValue
            for item in items {
                for t in item.types where t.type != fileURL {
                    var data = t.data
                    if appendNewline, t.type == NSPasteboard.PasteboardType.string.rawValue,
                       let s = String(data: data, encoding: .utf8) {
                        data = Data((s + "\n").utf8)
                    }
                    pb.setData(data, forType: NSPasteboard.PasteboardType(t.type))
                }
            }
            let files: [NSPasteboardItem] = items.flatMap { $0.types }.filter { $0.type == fileURL }.map { t in
                let p = NSPasteboardItem()
                p.setData(t.data, forType: .fileURL)
                return p
            }
            if !files.isEmpty { pb.writeObjects(files) }
        }
        pb.setString("", forType: NSPasteboard.PasteboardType(ClipboardWatcher.ownMarker))
        watcher.markOwnWrite()
        return true
    }

    /// Content used by the primary paste/copy action for an entry.
    func defaultContent(for entry: ClipEntry) -> Content {
        if settings.preferPlainText, entry.kind.isTextual, let s = entry.text { return .plainText(s) }
        return .original
    }

    func afterUse(_ entry: ClipEntry) {
        if settings.moveUsedToTop { store.touch(entry.id) }
    }

    // MARK: Keystrokes

    static var canPaste: Bool { AXIsProcessTrusted() }

    private static var askedThisLaunch = false

    /// Shows the system's Accessibility prompt, at most once per launch.
    static func requestAccessibility(force: Bool = false) {
        guard force || !askedThisLaunch else { return }
        askedThisLaunch = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Sends ⌘V to the frontmost app. Returns false when Accessibility access is missing.
    @discardableResult
    static func sendPasteKeystroke(after delay: TimeInterval = 0.08) -> Bool {
        guard canPaste else {
            requestAccessibility()
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let v = keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
            // ⌘ plus the "left ⌘ key" device flag (0x08), as Maccy/Flycut do for app compatibility.
            let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
            let src = CGEventSource(stateID: .combinedSessionState)
            // Keep keys the user is typing right now out of the synthetic paste.
            src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Key code that types `char` in the current keyboard layout (e.g. "v" is not on the
    /// QWERTY V key in Dvorak). Falls back to nil when the layout can't be read.
    static func keyCode(for char: Character) -> CGKeyCode? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = String(char)
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, chars.count, &len, &chars)
                if st == noErr, len > 0, String(utf16CodeUnits: chars, count: len) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    // MARK: Paste sequentially

    /// Pastes the next older entry each time, starting with the newest.
    /// The sequence restarts after the timeout or when something new was copied.
    func pasteNext() {
        let ordered = store.entries.sorted { $0.created > $1.created }
        guard let newest = ordered.first else { return }
        let now = Date()
        let expired = seqLast.map { now.timeIntervalSince($0) > settings.sequenceTimeout } ?? true
        if expired || seqNewestID != newest.id {
            seqIndex = 0
            seqNewestID = newest.id
        }
        guard seqIndex < ordered.count else {
            NSSound.beep()
            return
        }
        let entry = ordered[seqIndex]
        let newline = settings.sequenceNewline && entry.kind.isTextual
        guard write(entry, as: .original, appendNewline: newline) else { return }
        Paster.sendPasteKeystroke()
        seqIndex += 1
        seqLast = now
    }

    func resetSequence() {
        seqIndex = 0
        seqLast = nil
        seqNewestID = nil
        HUD.show("粘贴顺序已重置")
    }
}

/// A small transient message near the top of the screen.
@MainActor
enum HUD {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 40)
        let p = window ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return p
        }()
        window = p
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 20
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
        fx.addSubview(label)
        p.contentView = fx
        let screen = NSScreen.main?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 40,
                          width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        hideWork?.cancel()
        let w = DispatchWorkItem { p.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}
