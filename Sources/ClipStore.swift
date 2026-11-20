import AppKit

enum ClipKind: String {
    case text, image, file, link, email, color

    var title: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        case .link: return "链接"
        case .email: return "邮箱"
        case .color: return "颜色"
        }
    }
    /// Kinds whose content is plain text and can be edited in the preview.
    var isTextual: Bool { self != .image && self != .file }
}

/// One pasteboard item: every type it carried, with the original bytes.
struct ClipItem {
    var types: [(type: String, data: Data)]
}

struct ClipEntry: Identifiable, Equatable {
    let id: Int64
    var created: Date
    var sortTime: Date
    var kind: ClipKind
    var formatted: Bool
    var title: String
    var name: String?
    var text: String?
    var ocr: String?
    var sourceBundle: String?
    var sourceName: String?
    var pinned: Bool
    var pinnedAt: Date?
    var width: Int
    var height: Int
    var byteSize: Int
    var thumb: Data?
    var icon: Data?

    var displayTitle: String {
        if let n = name, !n.isEmpty { return n }
        return title
    }
}

/// A capture before it is stored.
struct NewClip {
    var kind: ClipKind
    var formatted: Bool
    var title: String
    var text: String?
    var sourceBundle: String?
    var sourceName: String?
    var width = 0
    var height = 0
    var byteSize = 0
    var thumb: Data?
    var items: [ClipItem]
}

@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var entries: [ClipEntry] = []   // sorted by sortTime, newest first
    private let db: Database

    init(db: Database) throws {
        self.db = db
        try db.exec("""
        CREATE TABLE IF NOT EXISTS entries(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created REAL NOT NULL,
          sort_time REAL NOT NULL,
          kind TEXT NOT NULL,
          formatted INTEGER NOT NULL DEFAULT 0,
          title TEXT NOT NULL,
          name TEXT,
          text TEXT,
          ocr TEXT,
          source_bundle TEXT,
          source_name TEXT,
          pinned INTEGER NOT NULL DEFAULT 0,
          pinned_at REAL,
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          byte_size INTEGER NOT NULL DEFAULT 0,
          thumb BLOB,
          icon BLOB,
          preview BLOB
        );
        CREATE TABLE IF NOT EXISTS items(
          entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
          idx INTEGER NOT NULL,
          type TEXT NOT NULL,
          data BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS items_entry ON items(entry_id);
        """)
        try reload()
    }

    func reload() throws {
        var out: [ClipEntry] = []
        try db.query("""
        SELECT id, created, sort_time, kind, formatted, title, name, text, ocr, source_bundle, source_name,
               pinned, pinned_at, width, height, byte_size, thumb, icon
        FROM entries ORDER BY sort_time DESC, id DESC
        """) { r in
            out.append(ClipEntry(
                id: r.int(0),
                created: Date(timeIntervalSince1970: r.double(1)),
                sortTime: Date(timeIntervalSince1970: r.double(2)),
                kind: ClipKind(rawValue: r.text(3) ?? "") ?? .text,
                formatted: r.int(4) != 0,
                title: r.text(5) ?? "",
                name: r.text(6),
                text: r.text(7),
                ocr: r.text(8),
                sourceBundle: r.text(9),
                sourceName: r.text(10),
                pinned: r.int(11) != 0,
                pinnedAt: r.int(11) != 0 ? Date(timeIntervalSince1970: r.double(12)) : nil,
                width: Int(r.int(13)),
                height: Int(r.int(14)),
                byteSize: Int(r.int(15)),
                thumb: r.blob(16),
                icon: r.blob(17)))
        }
        entries = out
    }

    @discardableResult
    func add(_ c: NewClip) -> ClipEntry? {
        let now = Date()
        do {
            var newID: Int64 = 0
            try db.transaction {
                try db.run("""
                INSERT INTO entries(created, sort_time, kind, formatted, title, text, source_bundle, source_name,
                                    width, height, byte_size, thumb)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970),
                      .text(c.kind.rawValue), .int(c.formatted ? 1 : 0), .text(c.title),
                      c.text.map { .text($0) } ?? .null,
                      c.sourceBundle.map { .text($0) } ?? .null,
                      c.sourceName.map { .text($0) } ?? .null,
                      .int(Int64(c.width)), .int(Int64(c.height)), .int(Int64(c.byteSize)),
                      c.thumb.map { .blob($0) } ?? .null])
                newID = db.lastInsertID
                for (i, item) in c.items.enumerated() {
                    for t in item.types {
                        try db.run("INSERT INTO items(entry_id, idx, type, data) VALUES(?,?,?,?)",
                                   [.int(newID), .int(Int64(i)), .text(t.type), .blob(t.data)])
                    }
                }
            }
            let e = ClipEntry(id: newID, created: now, sortTime: now, kind: c.kind, formatted: c.formatted,
                              title: c.title, name: nil, text: c.text, ocr: nil,
                              sourceBundle: c.sourceBundle, sourceName: c.sourceName,
                              pinned: false, pinnedAt: nil, width: c.width, height: c.height,
                              byteSize: c.byteSize, thumb: c.thumb, icon: nil)
            entries.insert(e, at: 0)
            return e
        } catch {
            NSLog("Clipcairn: insert failed: \(error)")
            return nil
        }
    }

    /// All pasteboard items of an entry, with every type's original bytes.
    func items(of id: Int64) -> [ClipItem] {
        var items: [Int: ClipItem] = [:]
        do {
            try db.query("SELECT idx, type, data FROM items WHERE entry_id = ? ORDER BY idx, rowid", [.int(id)]) { r in
                let i = Int(r.int(0))
                items[i, default: ClipItem(types: [])].types.append((r.text(1) ?? "", r.blob(2) ?? Data()))
            }
        } catch {
            NSLog("Clipcairn: read items failed: \(error)")
        }
        return items.keys.sorted().compactMap { items[$0] }
    }

    func preview(of id: Int64) -> Data? {
        var out: Data?
        try? db.query("SELECT preview FROM entries WHERE id = ?", [.int(id)]) { r in out = r.blob(0) }
        return out
    }

    private func update(_ id: Int64, _ change: (inout ClipEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    func setOCR(_ id: Int64, _ text: String) {
        try? db.run("UPDATE entries SET ocr = ? WHERE id = ?", [.text(text), .int(id)])
        update(id) { $0.ocr = text }
    }

    func setLinkVisuals(_ id: Int64, icon: Data?, preview: Data?) {
        try? db.run("UPDATE entries SET icon = ?, preview = ? WHERE id = ?",
                    [icon.map { .blob($0) } ?? .null, preview.map { .blob($0) } ?? .null, .int(id)])
        update(id) { $0.icon = icon }
    }

    /// `at` orders pinned entries (oldest first); defaults to now, i.e. the end of the pinned list.
    func setPinned(_ id: Int64, _ pinned: Bool, at: Date? = nil) {
        let t = at ?? Date()
        try? db.run("UPDATE entries SET pinned = ?, pinned_at = ? WHERE id = ?",
                    [.int(pinned ? 1 : 0), pinned ? .double(t.timeIntervalSince1970) : .null, .int(id)])
        update(id) { $0.pinned = pinned; $0.pinnedAt = pinned ? t : nil }
    }

    func rename(_ id: Int64, _ name: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let v: String? = (n?.isEmpty ?? true) ? nil : n
        try? db.run("UPDATE entries SET name = ? WHERE id = ?", [v.map { .text($0) } ?? .null, .int(id)])
        update(id) { $0.name = v }
    }

    /// Moves an entry to the top after it was used (setting "使用后移到最上面").
    func touch(_ id: Int64) {
        let t = Date()
        try? db.run("UPDATE entries SET sort_time = ? WHERE id = ?", [.double(t.timeIntervalSince1970), .int(id)])
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: i)
        e.sortTime = t
        entries.insert(e, at: 0)
    }

    func delete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        do {
            try db.transaction {
                for id in ids { try db.run("DELETE FROM entries WHERE id = ?", [.int(id)]) }
            }
            let set = Set(ids)
            entries.removeAll { set.contains($0.id) }
            try? db.exec("PRAGMA incremental_vacuum;")
        } catch {
            NSLog("Clipcairn: delete failed: \(error)")
        }
    }

    /// Removes unpinned entries copied before the retention cutoff.
    func applyRetention(_ r: Retention) {
        guard let secs = r.seconds else { return }
        let cutoff = Date().addingTimeInterval(-secs).timeIntervalSince1970
        do {
            try db.run("DELETE FROM entries WHERE pinned = 0 AND created < ?", [.double(cutoff)])
            if db.changes > 0 {
                try reload()
                try? db.exec("PRAGMA incremental_vacuum;")
            }
        } catch {
            NSLog("Clipcairn: retention cleanup failed: \(error)")
        }
    }
}
