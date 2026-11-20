import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for a history row; visible to Clipcairn only, so other apps never receive it.
enum EntryDrag {
    static let type = UTType(exportedAs: "com.cracya01.clipcairn.entry")

    static func provider(_ id: Int64) -> NSItemProvider {
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(String(id).utf8), nil)
            return nil
        }
        return p
    }

    static func load(_ providers: [NSItemProvider], _ then: @escaping @MainActor (Int64) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return false }
        p.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let id = Int64(String(decoding: data, as: UTF8.self)) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(id) } }
        }
        return true
    }
}

/// Highlights a drop target while an entry is dragged over it.
struct PinDropTarget: ViewModifier {
    let onDrop: @MainActor (Int64) -> Void
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if targeted { Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -1) }
            }
            .onDrop(of: [EntryDrag.type], isTargeted: $targeted) { EntryDrag.load($0, onDrop) }
    }
}

struct HistoryView: View {
    @ObservedObject var m: HistoryModel
    let store: ClipStore
    @ObservedObject var settings = AppSettings.shared
    let actions: HistoryController
    @FocusState private var searchFocused: Bool
    /// Shared by the selection highlight, so it slides from row to row.
    @Namespace private var selectionNS

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider().opacity(0.5)
                DetailView(m: m)
            }
            Divider().opacity(0.5)
            footer
        }
        .onChange(of: m.focusSearch) { _, _ in searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索剪贴板历史…", text: $m.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            Button { actions.showFilterMenu() } label: {
                HStack(spacing: 4) {
                    Text(m.filter?.title ?? "全部类型")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help("按类型筛选（⌘P）")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: List

    /// Pinned entries sit in their own area that does not scroll with the history (as in Raycast).
    private var list: some View {
        let pinned = m.sections.first { $0.id == "pinned" }
        let history = m.sections.filter { $0.id != "pinned" }
        return VStack(spacing: 0) {
            if let pinned {
                pinnedArea(pinned)
                Divider().opacity(0.5)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(history) { section in
                            sectionTitle(section.title)
                            ForEach(section.entries) { e in row(e, pinned: false) }
                        }
                        if m.ordered.isEmpty {
                            Text(store.entries.isEmpty ? "还没有剪贴板记录" : "没有匹配的记录")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .onChange(of: m.selectedID) { _, id in
                    if let id, m.scrollToSelection, history.contains(where: { $0.entries.contains { $0.id == id } }) {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        // One glass highlight moves between rows (as in macOS 26 lists and Raycast).
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: m.selectedID)
    }

    private func pinnedArea(_ section: HistoryModel.Section) -> some View {
        // Grows with the pins; beyond about six rows it scrolls on its own.
        let rowsHeight = CGFloat(max(section.entries.count, 1)) * 37
        return VStack(alignment: .leading, spacing: 1) {
            sectionTitle(section.title)
                .modifier(PinDropTarget { id in m.pin(id, before: section.entries.first?.id) })
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if section.entries.isEmpty {
                        Text("把记录拖到这里钉选，或按 ⌘.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .contentShape(Rectangle())
                            .modifier(PinDropTarget { id in m.pin(id, before: nil) })
                    }
                    ForEach(section.entries) { e in
                        row(e, pinned: true)
                            // Dropped on a pinned row: placed before it.
                            .modifier(PinDropTarget { id in if id != e.id { m.pin(id, before: e.id) } })
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(rowsHeight, 37 * 6))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func row(_ e: ClipEntry, pinned: Bool) -> some View {
        Row(entry: e, selected: e.id == m.selectedID, ns: selectionNS)
            .id(e.id)
            .contentShape(Rectangle())
            .onDrag { EntryDrag.provider(e.id) }
            .onContinuousHover { phase in
                switch phase {
                case .active: m.hoverSelect(e.id)
                case .ended: if m.hoveredID == e.id { m.hoveredID = nil }
                }
            }
            .simultaneousGesture(TapGesture().onEnded { m.select(byMouse: e.id) })
            .onTapGesture(count: 2) {
                m.select(byMouse: e.id)
                m.primary()
            }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            Text("剪贴板历史").foregroundStyle(.secondary)
            if m.isEdited {
                Text("已编辑，将按纯文本粘贴")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button { m.primary() } label: {
                HStack(spacing: 6) {
                    Text(m.primaryTitle).fontWeight(.medium)
                    KeyCap("↩")
                }
            }
            .buttonStyle(.plain)
            .disabled(m.selected == nil)
            Divider().frame(height: 14)
            Button { actions.showActionsMenu() } label: {
                HStack(spacing: 6) {
                    Text("操作").foregroundStyle(.secondary)
                    KeyCap("⌘")
                    KeyCap("K")
                }
            }
            .buttonStyle(.plain)
            .disabled(m.selected == nil)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

struct KeyCap: View {
    let s: String
    init(_ s: String) { self.s = s }
    var body: some View {
        Text(s)
            .font(.system(size: 11, weight: .medium))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.09)))
    }
}

// MARK: - Row

struct Row: View {
    let entry: ClipEntry
    let selected: Bool
    let ns: Namespace.ID

    var body: some View {
        HStack(spacing: 9) {
            EntryIcon(entry: entry).frame(width: 22, height: 22)
            Text(entry.displayTitle.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 13))
            Spacer(minLength: 0)
            if entry.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.clear)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
    }
}

/// Decoded row icons, so scrolling does not decode PNGs or look up file icons again.
@MainActor
enum IconCache {
    private static var images: [String: NSImage] = [:]
    static func image(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let i = images[key] { return i }
        guard let i = make() else { return nil }
        if images.count > 2000 { images.removeAll() }
        images[key] = i
        return i
    }
}

struct EntryIcon: View {
    let entry: ClipEntry
    var body: some View {
        switch entry.kind {
        case .image:
            if let img = IconCache.image("t\(entry.id)", { entry.thumb.flatMap { NSImage(data: $0) } }) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
            } else { symbol("photo") }
        case .file:
            let first = (entry.text ?? "").split(separator: "\n").first.map(String.init) ?? ""
            Image(nsImage: IconCache.image("f\(first)", { NSWorkspace.shared.icon(forFile: first) }) ?? NSImage()).resizable()
        case .link:
            if let img = IconCache.image("i\(entry.id)-\(entry.icon?.count ?? 0)", { entry.icon.flatMap { NSImage(data: $0) } }) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else { symbol("link") }
        case .email: symbol("envelope")
        case .color:
            Circle().fill(Color(nsColor: ColorParser.parse(entry.text ?? "") ?? .gray))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .padding(2)
        case .text: symbol(entry.formatted ? "doc.richtext" : "doc.text")
        }
    }
    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15)).foregroundStyle(.secondary)
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var m: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            if let e = m.selected {
                preview(e)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.5)
                InfoPanel(entry: e, text: e.kind.isTextual ? m.draft : nil)
                    .frame(height: 190)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func preview(_ e: ClipEntry) -> some View {
        switch e.kind {
        case .image:
            if let img = m.image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(14)
            } else {
                Text("无法显示图片").foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach((e.text ?? "").split(separator: "\n").map(String.init), id: \.self) { p in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 28, height: 28)
                            Text(p).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        default:
            VStack(spacing: 0) {
                if e.kind == .color, let c = ColorParser.parse(m.draft) {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: c))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
                        .frame(height: 70).padding([.horizontal, .top], 14)
                }
                if e.kind == .link, let img = m.linkPreview {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding([.horizontal, .top], 14)
                }
                TextEditor(text: $m.draft)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
        }
    }
}

struct InfoPanel: View {
    let entry: ClipEntry
    let text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("信息").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                row("来源") {
                    HStack(spacing: 5) {
                        if let bid = entry.sourceBundle,
                           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        }
                        Text(entry.sourceName ?? "未知")
                    }
                }
                row("内容类型") { Text(contentType) }
                if let t = text {
                    row("字符数") { Text("\(t.count)") }
                    row("单词数") { Text("\(Self.wordCount(t))") }
                }
                if entry.kind == .image {
                    row("尺寸") { Text("\(entry.width)×\(entry.height)") }
                }
                if entry.kind == .image || entry.kind == .file {
                    row("大小") { Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteSize), countStyle: .file)) }
                }
                row("复制时间") { Text(Self.copiedTitle(entry.created)) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .font(.system(size: 12.5))
    }

    private var contentType: String {
        if entry.kind == .text && entry.formatted { return "文本（带格式）" }
        if entry.kind == .file {
            let n = (entry.text ?? "").split(separator: "\n").count
            return n > 1 ? "文件（\(n) 个）" : "文件"
        }
        return entry.kind.title
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                value()
            }
            .frame(height: 26)
            Divider().opacity(0.5)
        }
    }

    static func wordCount(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    static func copiedTitle(_ d: Date) -> String {
        let t = DateFormatter()
        t.dateFormat = "HH:mm:ss"
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天 \(t.string(from: d))" }
        if cal.isDateInYesterday(d) { return "昨天 \(t.string(from: d))" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}
