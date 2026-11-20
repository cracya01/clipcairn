import AppKit
import SwiftUI

/// State and actions of the clipboard history panel.
@MainActor
final class HistoryModel: ObservableObject {
    let store: ClipStore
    let paster: Paster
    let settings = AppSettings.shared
    weak var panel: HistoryPanel?
    var openSettings: () -> Void = {}

    @Published var query = "" { didSet { refresh() } }
    @Published var filter: ClipKind? { didSet { refresh() } }   // nil = all types
    @Published var selectedID: Int64? { didSet { if oldValue != selectedID { selectionChanged() } } }
    @Published var draft = ""                   // editable text of the selected entry
    @Published private(set) var image: NSImage? // full image of the selected entry
    @Published private(set) var linkPreview: NSImage?
    @Published var focusSearch = 0              // bump to focus the search field
    @Published private(set) var targetApp: NSRunningApplication?
    /// Cached list, rebuilt only when the query, filter or entries change.
    @Published private(set) var sections: [Section] = []
    private(set) var ordered: [ClipEntry] = []
    /// False when the selection came from the mouse, so the list does not jump.
    private(set) var scrollToSelection = true
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var imageTask: Task<Void, Never>?
    private var storeSub: Any?

    init(store: ClipStore, paster: Paster) {
        self.store = store
        self.paster = paster
        storeSub = store.$entries.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func refresh() {
        // The pinned area always shows while browsing, so entries can be dragged into it.
        sections = Self.buildSections(filtered, alwaysShowPinned: query.isEmpty && filter == nil)
        ordered = sections.flatMap(\.entries)
        ensureSelection()
    }

    /// Selects the row under the mouse, but only when the mouse really moved
    /// (not when the list scrolls under a resting pointer).
    /// Selection by click: never scrolls the list.
    func select(byMouse id: Int64) {
        scrollToSelection = false
        selectedID = id
    }

    /// Row currently under the mouse (for the right-click menu).
    var hoveredID: Int64?

    func hoverSelect(_ id: Int64) {
        hoveredID = id
        let loc = NSEvent.mouseLocation
        guard loc != lastMouse, selectedID != id else { lastMouse = loc; return }
        lastMouse = loc
        // Stays false until the keyboard moves the selection: the list's onChange runs after
        // this returns, so resetting it here would still scroll a half-visible row into view.
        scrollToSelection = false
        selectedID = id
    }

    // MARK: Listing

    struct Section: Identifiable {
        let id: String
        let title: String
        let entries: [ClipEntry]
    }

    var filtered: [ClipEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.entries.filter { e in
            if let f = filter, e.kind != f { return false }
            guard !q.isEmpty else { return true }
            return e.displayTitle.localizedCaseInsensitiveContains(q)
                || (e.text?.localizedCaseInsensitiveContains(q) ?? false)
                || (e.ocr?.localizedCaseInsensitiveContains(q) ?? false)
                || (e.name?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private static func buildSections(_ all: [ClipEntry], alwaysShowPinned: Bool) -> [Section] {
        var out: [Section] = []
        let pinned = all.filter(\.pinned).sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
        if !pinned.isEmpty || alwaysShowPinned { out.append(Section(id: "pinned", title: "钉选", entries: pinned)) }
        let cal = Calendar.current
        var current: (key: Date, entries: [ClipEntry])?
        for e in all where !e.pinned {
            let day = cal.startOfDay(for: e.sortTime)
            if current?.key == day {
                current?.entries.append(e)
            } else {
                if let c = current { out.append(Section(id: "\(c.key.timeIntervalSince1970)", title: Self.dayTitle(c.key), entries: c.entries)) }
                current = (day, [e])
            }
        }
        if let c = current { out.append(Section(id: "\(c.key.timeIntervalSince1970)", title: Self.dayTitle(c.key), entries: c.entries)) }
        return out
    }

    var selected: ClipEntry? {
        guard let id = selectedID else { return nil }
        return store.entries.first { $0.id == id }
    }

    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日 EEEE"
        return f.string(from: d)
    }

    // MARK: Opening

    func willOpen() {
        targetApp = NSWorkspace.shared.frontmostApplication
        query = ""
        filter = nil
        lastMouse = NSEvent.mouseLocation
        scrollToSelection = true
        refresh()
        selectedID = ordered.first?.id
        selectionChanged()
        focusSearch += 1
    }

    func ensureSelection() {
        let list = ordered
        if let id = selectedID, list.contains(where: { $0.id == id }) { return }
        selectedID = list.first?.id
    }

    func move(_ delta: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selectedID } ?? -1
        scrollToSelection = true
        selectedID = list[max(0, min(list.count - 1, i + delta))].id
    }

    private func selectionChanged() {
        let e = selected
        draft = e?.text ?? ""
        image = nil
        linkPreview = nil
        imageTask?.cancel()
        guard let e else { return }
        if e.kind == .image, let d = Classifier.imageData(in: store.items(of: e.id))?.data {
            // Decode off the main thread; large screenshots would stall the list otherwise.
            imageTask = Task { [weak self] in
                let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                    guard let cg = ImageInfo.cgImage(d) else { return nil }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }.value
                guard !Task.isCancelled, let self, self.selectedID == e.id else { return }
                self.image = img
            }
        }
        if e.kind == .link, let d = store.preview(of: e.id) { linkPreview = NSImage(data: d) }
    }

    /// The selected text was changed in the preview and not pasted yet.
    var isEdited: Bool {
        guard let e = selected, e.kind.isTextual else { return false }
        return draft != (e.text ?? "")
    }

    var primaryTitle: String {
        if settings.primaryAction == .copy { return "复制到剪贴板" }
        return "粘贴到 \(targetApp?.localizedName ?? "当前 App")"
    }

    // MARK: Actions

    func close() { panel?.orderOut(nil) }

    func primary() {
        if settings.primaryAction == .paste { paste() } else { copy() }
    }

    func paste() { use(paste: true, content: nil) }
    func copy() { use(paste: false, content: nil) }

    func pastePlainText() {
        guard let e = selected, let s = isEdited ? draft : e.text else { return }
        use(paste: true, content: .plainText(s))
    }

    func pastePNG() { use(paste: true, content: .png) }

    /// Pastes or copies the selected entry. Edited text goes out as plain text and becomes
    /// a new history entry; the original entry stays as it was.
    private func use(paste: Bool, content: Paster.Content?) {
        guard let e = selected else { return }
        if isEdited {
            let text = draft
            let clip = NewClip(kind: Classifier.textKind(text), formatted: false, title: Classifier.title(of: text),
                               text: text, sourceBundle: e.sourceBundle, sourceName: e.sourceName,
                               byteSize: text.utf8.count,
                               items: [ClipItem(types: [(NSPasteboard.PasteboardType.string.rawValue, Data(text.utf8))])])
            guard let new = store.add(clip) else { return }
            paster.write(new, as: .plainText(text))
        } else {
            guard paster.write(e, as: content ?? paster.defaultContent(for: e)) else {
                NSLog("Clipcairn: write failed for entry \(e.id)")
                NSSound.beep(); return
            }
            paster.afterUse(e)
        }
        close()
        if paste, !Paster.sendPasteKeystroke() {
            HUD.show("已复制。自动粘贴需要「辅助功能」权限")
        }
    }

    func copyRecognizedText() {
        guard let e = selected, e.kind == .image else { return }
        let finish: (String?) -> Void = { [weak self] text in
            guard let self else { return }
            guard let text, !text.isEmpty else { HUD.show("图片里没有识别到文字"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.close()
            HUD.show("已复制识别出的文字")
        }
        if let t = e.ocr, !t.isEmpty { finish(t); return }
        guard let d = Classifier.imageData(in: store.items(of: e.id))?.data else { return }
        let accurate = settings.ocrMode == .accurate
        Task.detached(priority: .userInitiated) {
            let t = TextRecognizer.recognize(d, accurate: accurate)
            await MainActor.run { finish(t) }
        }
    }

    func copyQRCode() {
        guard let e = selected, e.kind == .image,
              let d = Classifier.imageData(in: store.items(of: e.id))?.data else { return }
        let codes = TextRecognizer.qrCodes(d)
        guard !codes.isEmpty else { HUD.show("图片里没有二维码"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codes.joined(separator: "\n"), forType: .string)
        close()
        HUD.show("已复制二维码内容")
    }

    func openLink() {
        guard let e = selected, let s = e.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let url: URL?
        switch e.kind {
        case .link: url = URL(string: s)
        case .email: url = URL(string: s.hasPrefix("mailto:") ? s : "mailto:\(s)")
        default: url = nil
        }
        guard let url else { return }
        close()
        NSWorkspace.shared.open(url)
    }

    /// Pins (or moves a pinned) entry so it sits right before `target` in the pinned area,
    /// or at the end when `target` is nil. Used by drag and drop.
    func pin(_ id: Int64, before target: Int64?) {
        let pins = store.entries.filter { $0.pinned && $0.id != id }
            .sorted { ($0.pinnedAt ?? .distantPast) < ($1.pinnedAt ?? .distantPast) }
        var at = Date()
        if let target, let i = pins.firstIndex(where: { $0.id == target }), let t = pins[i].pinnedAt {
            let prev = i > 0 ? (pins[i - 1].pinnedAt ?? t.addingTimeInterval(-2)) : t.addingTimeInterval(-2)
            at = Date(timeIntervalSince1970: (prev.timeIntervalSince1970 + t.timeIntervalSince1970) / 2)
        } else if let last = pins.last?.pinnedAt, last >= at {
            at = last.addingTimeInterval(1)
        }
        store.setPinned(id, true, at: at)
        selectedID = id
    }

    func togglePin() {
        guard let e = selected else { return }
        store.setPinned(e.id, !e.pinned)
    }

    func shareItems() -> [Any] {
        guard let e = selected else { return [] }
        switch e.kind {
        case .image: return image.map { [$0] } ?? []
        case .file: return (e.text ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        case .link: return [URL(string: e.text ?? "") as Any].compactMap { $0 }
        default: return [isEdited ? draft : (e.text ?? "")]
        }
    }

    func delete() {
        guard let e = selected else { return }
        let list = ordered
        let i = list.firstIndex { $0.id == e.id } ?? 0
        store.delete([e.id])
        let rest = ordered
        selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
    }
}
