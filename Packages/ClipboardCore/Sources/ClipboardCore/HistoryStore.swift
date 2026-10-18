import Foundation
import CSQLite
import ImageIO

public actor HistoryStore {
    public nonisolated let rootURL: URL
    public nonisolated var attachmentsURL: URL { rootURL.appendingPathComponent("Attachments", isDirectory: true) }
    let db: SQLiteConnection
    private var backupReaders = 0
    static let columns = "id,kind,preview,created,modified,source,pinned,bytes,hash"

    public init(rootURL: URL) throws {
        try PrivateFiles.directory(rootURL)
        let rootURL = rootURL.resolvingSymlinksInPath()
        self.rootURL = rootURL
        try PrivateFiles.directory(rootURL.appendingPathComponent("Attachments"))
        try PrivateFiles.directory(rootURL.appendingPathComponent("Staging"))
        let dbURL = rootURL.appendingPathComponent("History.sqlite")
        if FileManager.default.fileExists(atPath: dbURL.path) { try PrivateFiles.rejectLink(dbURL) }
        else { try PrivateFiles.write(Data(), to: dbURL) }
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: dbURL.path + suffix) { try PrivateFiles.rejectLink(URL(fileURLWithPath: dbURL.path + suffix)) }
        db = try SQLiteConnection(url: dbURL)
        try db.execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-2048;")
        let version = try db.statement("PRAGMA user_version")
        _ = try version.step()
        guard version.int(0) <= 1 else { throw CoreError.unsupportedVersion }
        if version.int(0) == 0 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE entries(id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT, preview TEXT NOT NULL, created REAL NOT NULL, modified REAL NOT NULL, source TEXT, pinned INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL, hash TEXT NOT NULL, deleted REAL, delete_token TEXT);
                CREATE INDEX entry_order ON entries(deleted,created DESC,id DESC);
                CREATE INDEX entry_pin_order ON entries(deleted,pinned,created DESC,id DESC);
                CREATE INDEX entry_kind_order ON entries(deleted,kind,created DESC,id DESC);
                CREATE TABLE representations(entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, item_index INTEGER NOT NULL, type TEXT NOT NULL, data BLOB, attachment TEXT, bytes INTEGER NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY(entry_id,ordinal));
                CREATE TABLE cleanup(name TEXT PRIMARY KEY);
                CREATE VIRTUAL TABLE search USING fts5(text, content='entries', content_rowid='rowid', tokenize='unicode61');
                CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN INSERT INTO search(rowid,text) VALUES(new.rowid,new.text); END;
                CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.rowid,old.text); END;
                CREATE TRIGGER entries_au AFTER UPDATE OF text ON entries BEGIN INSERT INTO search(search,rowid,text) VALUES('delete',old.rowid,old.text); INSERT INTO search(rowid,text) VALUES(new.rowid,new.text); END;
                PRAGMA user_version=1;
                """)
            }
        }
        if sqlite3_libversion_number() >= 3_042_000 { try db.execute("INSERT INTO search(search,rank) VALUES('secure-delete',1)") }
        let check = try db.statement("PRAGMA quick_check(1)")
        guard try check.step(), check.text(0) == "ok" else { throw CoreError.storage(SQLITE_CORRUPT) }
        for suffix in ["", "-wal", "-shm"] {
            let path = dbURL.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
    }

    @discardableResult public func insert(_ snapshot: ClipboardSnapshot, id: UUID = UUID(), pinned: Bool = false) throws -> UUID {
        try Task.checkCancellation()
        try PayloadRules.validate(snapshot)
        try PayloadRules.validateImage(snapshot)
        var staged: [String] = []
        do {
            let reps = try snapshot.representations.map { rep -> StoredRepresentation in
                if ["public.png", "public.tiff", "public.rtf"].contains(rep.type) {
                    let name = UUID().uuidString
                    try PrivateFiles.write(rep.data, to: attachmentsURL.appendingPathComponent(name))
                    staged.append(name)
                    return .init(itemIndex: rep.itemIndex, type: rep.type, data: nil, attachmentName: name, byteCount: rep.data.count, checksum: PrivateFiles.checksum(rep.data))
                }
                return .init(itemIndex: rep.itemIndex, type: rep.type, data: rep.data, attachmentName: nil, byteCount: rep.data.count, checksum: PrivateFiles.checksum(rep.data))
            }
            let preview: String
            if let text = snapshot.text { preview = String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(240)) }
            else if snapshot.kind == .files {
                preview = snapshot.representations.compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:))?.lastPathComponent }.joined(separator: ", ")
            } else { preview = "Image" }
            let summary = ClipboardEntrySummary(id: id, kind: snapshot.kind, preview: String(preview.prefix(240)), createdAt: snapshot.createdAt, modifiedAt: snapshot.createdAt, sourceBundleID: snapshot.sourceBundleID, isPinned: pinned, byteCount: snapshot.representations.reduce(0) { $0 + $1.data.count }, contentHash: snapshot.contentHash)
            try Task.checkCancellation()
            try db.transaction { try insertDetail(.init(summary: summary, text: snapshot.text, representations: reps)); try Task.checkCancellation() }
            return id
        } catch {
            for name in staged { try? FileManager.default.removeItem(at: attachmentsURL.appendingPathComponent(name)) }
            throw error
        }
    }
    func insertDetail(_ detail: ClipboardEntryDetail) throws {
        let s = detail.summary
        let q = try db.statement("INSERT INTO entries(id,kind,text,preview,created,modified,source,pinned,bytes,hash) VALUES(?,?,?,?,?,?,?,?,?,?)", [
            .text(s.id.uuidString), .text(s.kind.rawValue), detail.text.map(SQLValue.text) ?? .null, .text(s.preview), .real(s.createdAt.timeIntervalSince1970), .real(s.modifiedAt.timeIntervalSince1970), s.sourceBundleID.map(SQLValue.text) ?? .null, .int(s.isPinned ? 1 : 0), .int(s.byteCount), .text(s.contentHash)
        ]); _ = try q.step()
        for (ordinal, rep) in detail.representations.enumerated() {
            let r = try db.statement("INSERT INTO representations VALUES(?,?,?,?,?,?,?,?)", [.text(s.id.uuidString), .int(ordinal), .int(rep.itemIndex), .text(rep.type), rep.data.map(SQLValue.blob) ?? .null, rep.attachmentName.map(SQLValue.text) ?? .null, .int(rep.byteCount), .text(rep.checksum)])
            _ = try r.step()
        }
    }
    static func summary(_ q: SQLiteStatement) throws -> ClipboardEntrySummary {
        guard let id = q.text(0).flatMap(UUID.init(uuidString:)), let kind = q.text(1).flatMap(ClipboardKind.init(rawValue:)), let preview = q.text(2), let hash = q.text(8) else { throw CoreError.invalidData }
        return .init(id: id, kind: kind, preview: preview, createdAt: Date(timeIntervalSince1970: q.real(3)), modifiedAt: Date(timeIntervalSince1970: q.real(4)), sourceBundleID: q.text(5), isPinned: q.int(6) != 0, byteCount: q.int(7), contentHash: hash)
    }
    static func detail(_ id: UUID, db: SQLiteConnection, includingDeleted: Bool = false) throws -> ClipboardEntryDetail? {
        let q = try db.statement("SELECT \(columns),text FROM entries WHERE id=? \(includingDeleted ? "" : "AND deleted IS NULL")", [.text(id.uuidString)])
        guard try q.step() else { return nil }
        let s = try summary(q)
        let reps = try db.statement("SELECT item_index,type,data,attachment,bytes,checksum FROM representations WHERE entry_id=? ORDER BY ordinal", [.text(id.uuidString)])
        var result: [StoredRepresentation] = []
        while try reps.step() {
            guard let type = reps.text(1), let checksum = reps.text(5) else { throw CoreError.invalidData }
            result.append(.init(itemIndex: reps.int(0), type: type, data: reps.data(2), attachmentName: reps.text(3), byteCount: reps.int(4), checksum: checksum))
        }
        return .init(summary: s, text: q.text(9), representations: result)
    }
    public func detail(_ id: UUID) throws -> ClipboardEntryDetail? { try Self.detail(id, db: db) }
    public func materialize(_ id: UUID, draft: String? = nil) throws -> ClipboardSnapshot {
        guard let detail = try detail(id) else { throw CoreError.invalidData }
        if let draft { return .plainText(draft) }
        let reps = try detail.representations.map { rep -> CapturedRepresentation in
            let data: Data
            if let inline = rep.data { data = inline }
            else if let name = rep.attachmentName, PrivateFiles.isManagedName(name) { data = try PrivateFiles.read(attachmentsURL.appendingPathComponent(name), limit: Limits.imageBytes) }
            else { throw CoreError.inaccessibleAttachment }
            guard data.count == rep.byteCount, PrivateFiles.checksum(data) == rep.checksum else { throw CoreError.inaccessibleAttachment }
            return .init(itemIndex: rep.itemIndex, type: rep.type, data: data)
        }
        return .init(kind: detail.summary.kind, text: detail.text, representations: reps, sourceBundleID: detail.summary.sourceBundleID, createdAt: detail.summary.createdAt)
    }
    static func filter(_ query: HistoryQuery) -> (String, [SQLValue]) {
        var clauses = ["deleted IS NULL"], values: [SQLValue] = []
        if !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let words = query.search.split(whereSeparator: { $0.isWhitespace }).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
            clauses.append("rowid IN (SELECT rowid FROM search WHERE search MATCH ?)"); values.append(.text(words))
        }
        if let range = query.dateFilter.range(now: query.now) { clauses.append("created>=? AND created<?"); values += [.real(range.lowerBound.timeIntervalSince1970), .real(range.upperBound.timeIntervalSince1970)] }
        if query.dateFilter == .pinned { clauses.append("pinned=1") }
        if let kind = query.kind { clauses.append("kind=?"); values.append(.text(kind.rawValue)) }
        return (clauses.joined(separator: " AND "), values)
    }
    public func page(_ query: HistoryQuery, offset: Int = 0, limit: Int = 100) throws -> HistoryPage {
        try Task.checkCancellation()
        guard query.search.utf8.count <= 4096 else { throw CoreError.tooLarge }
        let (whereSQL, args) = Self.filter(query)
        let count = try db.statement("SELECT count(*) FROM entries WHERE \(whereSQL)", args)
        _ = try count.step()
        let q = try db.statement("SELECT \(Self.columns) FROM entries WHERE \(whereSQL) ORDER BY \(query.pinnedFirst ? "pinned DESC," : "")created DESC,id DESC LIMIT ? OFFSET ?", args + [.int(max(1, min(limit, 100))), .int(max(offset, 0))])
        var entries: [ClipboardEntrySummary] = []
        while try q.step() { try Task.checkCancellation(); entries.append(try Self.summary(q)) }
        return .init(entries: entries, totalCount: count.int(0), offset: offset)
    }
    public func orderedIDs(_ query: HistoryQuery) throws -> [UUID] {
        guard query.search.utf8.count <= 4096 else { throw CoreError.tooLarge }
        let (whereSQL, args) = Self.filter(query)
        let q = try db.statement("SELECT id FROM entries WHERE \(whereSQL) ORDER BY \(query.pinnedFirst ? "pinned DESC," : "")created DESC,id DESC", args)
        var ids: [UUID] = []
        while try q.step() { try Task.checkCancellation(); if let id = q.text(0).flatMap(UUID.init(uuidString:)) { ids.append(id) } }
        return ids
    }
    public func setPinned(_ id: UUID, pinned: Bool) throws {
        let q = try db.statement("UPDATE entries SET pinned=? WHERE id=? AND deleted IS NULL", [.int(pinned ? 1 : 0), .text(id.uuidString)]); _ = try q.step()
    }
    public func saveText(_ id: UUID, text: String) throws {
        try saveTexts([id: text])
    }
    public func saveTexts(_ texts: [UUID: String]) throws {
        try db.transaction {
            for (id, text) in texts {
                guard let old = try Self.detail(id, db: db), old.summary.kind.isText else { throw CoreError.invalidData }
                let snapshot = ClipboardSnapshot.plainText(text)
                try PayloadRules.validate(snapshot)
                try queueAttachments(id)
                let remove = try db.statement("DELETE FROM representations WHERE entry_id=?", [.text(id.uuidString)]); _ = try remove.step()
                let q = try db.statement("UPDATE entries SET kind=?,text=?,preview=?,modified=?,bytes=?,hash=? WHERE id=?", [.text(snapshot.kind.rawValue), .text(text), .text(String(text.replacingOccurrences(of: "\n", with: " ").prefix(240))), .real(Date().timeIntervalSince1970), .int(text.utf8.count), .text(snapshot.contentHash), .text(id.uuidString)]); _ = try q.step()
                let r = snapshot.representations[0]
                let insert = try db.statement("INSERT INTO representations VALUES(?,0,0,?,?,NULL,?,?)", [.text(id.uuidString), .text(r.type), .blob(r.data), .int(r.data.count), .text(PrivateFiles.checksum(r.data))]); _ = try insert.step()
            }
        }
        try drainCleanup()
    }
    @discardableResult public func markDeleted(_ ids: Set<UUID>, now: Date = Date(), undoSeconds: Double = 10) throws -> UUID {
        let token = UUID()
        try db.transaction {
            for id in ids {
                let q = try db.statement("UPDATE entries SET deleted=?,delete_token=? WHERE id=? AND deleted IS NULL", [.real(now.timeIntervalSince1970 + undoSeconds), .text(token.uuidString), .text(id.uuidString)]); _ = try q.step()
            }
        }
        return token
    }
    public func undoDelete(_ token: UUID, now: Date = Date()) throws {
        let q = try db.statement("UPDATE entries SET deleted=NULL,delete_token=NULL WHERE delete_token=? AND deleted>?", [.text(token.uuidString), .real(now.timeIntervalSince1970)]); _ = try q.step()
    }
    func queueAttachments(_ id: UUID) throws {
        let q = try db.statement("INSERT OR IGNORE INTO cleanup SELECT attachment FROM representations WHERE entry_id=? AND attachment IS NOT NULL", [.text(id.uuidString)]); _ = try q.step()
    }
    public func purgeExpired(now: Date = Date(), limit: Int = 250) throws {
        guard backupReaders == 0 else { return }
        let q = try db.statement("SELECT id FROM entries WHERE deleted<=? LIMIT ?", [.real(now.timeIntervalSince1970), .int(limit)])
        var ids: [UUID] = []
        while try q.step() { if let id = q.text(0).flatMap(UUID.init(uuidString:)) { ids.append(id) } }
        try db.transaction {
            for id in ids { try queueAttachments(id); let d = try db.statement("DELETE FROM entries WHERE id=?", [.text(id.uuidString)]); _ = try d.step() }
        }
        try drainCleanup()
    }
    public func retention(days: Int?, maximumCount: Int? = nil, now: Date = Date(), protectedIDs: Set<UUID> = []) throws {
        guard backupReaders == 0 else { return }
        let protected = protectedIDs.map { SQLValue.text($0.uuidString) }
        let protection = protected.isEmpty ? "" : " AND id NOT IN (" + Array(repeating: "?", count: protected.count).joined(separator: ",") + ")"
        if let days {
            guard days > 0 else { throw CoreError.invalidData }
            let q = try db.statement("UPDATE entries SET deleted=0 WHERE pinned=0 AND deleted IS NULL AND created<?\(protection)", [.real(now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)] + protected); _ = try q.step()
        }
        if let max = maximumCount {
            guard max > 0 else { throw CoreError.invalidData }
            let q = try db.statement("UPDATE entries SET deleted=0 WHERE pinned=0 AND deleted IS NULL AND id IN (SELECT id FROM entries WHERE deleted IS NULL AND pinned=0 ORDER BY created DESC,id DESC LIMIT -1 OFFSET ?)\(protection)", [.int(max)] + protected); _ = try q.step()
        }
        try purgeExpired(now: now)
    }
    public func clear(includePinned: Bool) throws {
        guard backupReaders == 0 else { throw CoreError.invalidData }
        let clause = includePinned ? "" : "WHERE pinned=0"
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO cleanup SELECT attachment FROM representations WHERE attachment IS NOT NULL AND entry_id IN (SELECT id FROM entries \(clause))")
            try db.execute("DELETE FROM entries \(clause)")
        }
        try drainCleanup()
        try db.execute("INSERT INTO search(search) VALUES('optimize'); PRAGMA wal_checkpoint(TRUNCATE)")
    }
    func drainCleanup() throws {
        guard backupReaders == 0 else { return }
        let q = try db.statement("SELECT name FROM cleanup")
        var names: [String] = []
        while try q.step() { if let name = q.text(0) { names.append(name) } }
        for name in names {
            guard PrivateFiles.isManagedName(name) else { throw CoreError.invalidData }
            let url = attachmentsURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try PrivateFiles.rejectLink(url); try FileManager.default.removeItem(at: url) }
            let d = try db.statement("DELETE FROM cleanup WHERE name=?", [.text(name)]); _ = try d.step()
        }
    }
    public func reconcileAttachments() throws {
        guard backupReaders == 0 else { return }
        try drainCleanup()
        let q = try db.statement("SELECT attachment FROM representations WHERE attachment IS NOT NULL")
        var referenced = Set<String>()
        while try q.step() { if let name = q.text(0) { referenced.insert(name) } }
        for file in try FileManager.default.contentsOfDirectory(at: attachmentsURL, includingPropertiesForKeys: nil) {
            if PrivateFiles.isManagedName(file.lastPathComponent), !referenced.contains(file.lastPathComponent) { try PrivateFiles.rejectLink(file); try FileManager.default.removeItem(at: file) }
        }
    }
    func holdAttachments() { backupReaders += 1 }
    func releaseAttachments() { backupReaders = max(0, backupReaders - 1) }
    public func checkpoint() throws { try db.execute("PRAGMA wal_checkpoint(PASSIVE)") }
}
