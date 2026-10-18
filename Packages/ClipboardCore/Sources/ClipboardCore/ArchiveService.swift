import Foundation
import AppleArchive
import System

public struct BackupManifest: Codable, Sendable {
    public var version: Int
    public var entryCount: Int
    public var createdAt: Date
    public var application: String
}
public struct PreparedImport: Sendable {
    public let entryCount: Int
    public let expandedBytes: Int64
    public let oldestUnpinnedDate: Date?
    let directory: URL
    let ids: [UUID]
}

public actor ArchiveService {
    private let store: HistoryStore
    public init(store: HistoryStore) { self.store = store }

    public func export(to destination: URL, password: String? = nil) async throws {
        if let password, password.count < 12 { throw CoreError.invalidData }
        await store.holdAttachments()
        do {
            try exportSnapshot(to: destination, password: password)
            await store.releaseAttachments()
        } catch { await store.releaseAttachments(); throw error }
    }
    private func exportSnapshot(to destination: URL, password: String?) throws {
        let connection = try SQLiteConnection(url: store.rootURL.appendingPathComponent("History.sqlite"), readOnly: true)
        try connection.execute("BEGIN")
        defer { try? connection.execute("ROLLBACK") }
        let count = try connection.statement("SELECT count(*) FROM entries WHERE deleted IS NULL"); _ = try count.step()
        guard count.int(0) <= Limits.archiveEntries else { throw CoreError.tooLarge }
        let manifest = BackupManifest(version: 1, entryCount: count.int(0), createdAt: Date(), application: "Clipboard")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".clipboard-\(UUID().uuidString)")
        do {
            try withWriter(url: temporary, password: password) { stream in
                var total: Int64 = 0
                func write(_ name: String, _ data: Data) throws {
                    try Task.checkCancellation()
                    total += Int64(data.count); guard total <= Limits.archiveBytes else { throw CoreError.tooLarge }
                    try Self.writeMember(name: name, data: data, stream: stream)
                }
                try write("manifest.json", JSONEncoder().encode(manifest))
                let query = try connection.statement("SELECT id FROM entries WHERE deleted IS NULL ORDER BY created,id")
                var exported = Set<String>()
                while try query.step() {
                    guard let id = query.text(0).flatMap(UUID.init(uuidString:)), let detail = try HistoryStore.detail(id, db: connection) else { throw CoreError.invalidData }
                    try write("entries/\(id.uuidString).json", JSONEncoder().encode(detail))
                    for rep in detail.representations {
                        if let name = rep.attachmentName, exported.insert(name).inserted {
                            guard PrivateFiles.isManagedName(name) else { throw CoreError.invalidData }
                            let data = try PrivateFiles.read(store.attachmentsURL.appendingPathComponent(name), limit: Limits.imageBytes)
                            guard data.count == rep.byteCount, PrivateFiles.checksum(data) == rep.checksum else { throw CoreError.inaccessibleAttachment }
                            try write("attachments/\(name)", data)
                        }
                    }
                }
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try PrivateFiles.rejectLink(destination)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private func withWriter(url: URL, password: String?, body: (ArchiveStream) throws -> Void) throws {
        guard let file = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerRead, .ownerWrite]) else { throw CoreError.invalidArchive }
        defer { try? file.close() }
        let coded: ArchiveByteStream
        if let password {
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
            try context.setPassword(password)
            guard let stream = ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context, threadCount: 1) else { throw CoreError.invalidArchive }
            coded = stream
        } else {
            guard let stream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file, threadCount: 1) else { throw CoreError.invalidArchive }
            coded = stream
        }
        guard let archive = ArchiveStream.encodeStream(writingTo: coded, threadCount: 1) else { try? coded.close(); throw CoreError.invalidArchive }
        do { try body(archive); try archive.close(); try coded.close() }
        catch { archive.cancel(); coded.cancel(); try? archive.close(); try? coded.close(); throw error }
    }
    static func writeMember(name: String, data: Data, stream: ArchiveStream) throws {
        let header = ArchiveHeader()
        header.append(.uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: .init("PAT"), value: name))
        header.append(.blob(key: .init("DAT"), size: UInt64(data.count)))
        try stream.writeHeader(header)
        try data.withUnsafeBytes { try stream.writeBlob(key: .init("DAT"), from: $0) }
    }
    public static func validateMemberPath(_ path: String) -> Bool {
        if path == "manifest.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        if parts[0] == "attachments" { return PrivateFiles.isManagedName(String(parts[1])) }
        if parts[0] == "entries", parts[1].hasSuffix(".json") { return PrivateFiles.isManagedName(String(parts[1].dropLast(5))) }
        return false
    }
    public func prepareImport(from source: URL, password: String? = nil) throws -> PreparedImport {
        let directory = store.rootURL.appendingPathComponent("Staging").appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(directory)
        try PrivateFiles.directory(directory.appendingPathComponent("entries"))
        try PrivateFiles.directory(directory.appendingPathComponent("attachments"))
        do {
            let bytes = try decode(from: source, password: password, to: directory)
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: PrivateFiles.read(directory.appendingPathComponent("manifest.json"), limit: 16384))
            guard manifest.version == 1 else { throw CoreError.unsupportedVersion }
            guard (0...Limits.archiveEntries).contains(manifest.entryCount), manifest.application == "Clipboard" else { throw CoreError.invalidArchive }
            let paths = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("entries"), includingPropertiesForKeys: nil)
            guard paths.count == manifest.entryCount else { throw CoreError.invalidArchive }
            var ids: [UUID] = [], referenced = Set<String>(), oldest: Date?
            for path in paths {
                try Task.checkCancellation()
                let detail = try JSONDecoder().decode(ClipboardEntryDetail.self, from: PrivateFiles.read(path, limit: 8 * 1024 * 1024))
                guard path.deletingPathExtension().lastPathComponent == detail.summary.id.uuidString else { throw CoreError.invalidArchive }
                let snapshot = try Self.validate(detail: detail, attachments: directory.appendingPathComponent("attachments"))
                guard snapshot.contentHash == detail.summary.contentHash else { throw CoreError.invalidArchive }
                for rep in detail.representations { if let name = rep.attachmentName { referenced.insert(name) } }
                ids.append(detail.summary.id)
                if !detail.summary.isPinned { oldest = min(oldest ?? detail.summary.createdAt, detail.summary.createdAt) }
            }
            let actual = Set(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("attachments").path))
            guard referenced == actual else { throw CoreError.invalidArchive }
            return .init(entryCount: ids.count, expandedBytes: bytes, oldestUnpinnedDate: oldest, directory: directory, ids: ids)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private func decode(from source: URL, password: String?, to directory: URL) throws -> Int64 {
        try PrivateFiles.rejectLink(source)
        guard let file = ArchiveByteStream.fileStream(path: FilePath(source.path), mode: .readOnly, options: [], permissions: []) else { throw CoreError.invalidArchive }
        defer { try? file.close() }
        let coded: ArchiveByteStream
        if let context = ArchiveEncryptionContext(from: file) {
            guard context.profile == .hkdf_sha256_aesctr_hmac__scrypt__none, let password, password.count >= 12 else { throw CoreError.invalidArchive }
            try context.setPassword(password)
            guard context.decryptAttributes(), context.rawSize <= Limits.archiveBytes else { throw CoreError.invalidArchive }
            guard let stream = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context, threadCount: 1) else { throw CoreError.invalidArchive }
            coded = stream
        } else {
            _ = try file.seek(toOffset: 0, relativeTo: .start)
            guard let stream = ArchiveByteStream.decompressionStream(readingFrom: file, threadCount: 1) else { throw CoreError.invalidArchive }
            coded = stream
        }
        guard let archive = ArchiveStream.decodeStream(readingFrom: coded, threadCount: 1) else { try? coded.close(); throw CoreError.invalidArchive }
        var total: Int64 = 0, seen = Set<String>()
        do {
            while let header = try archive.readHeader() {
                try Task.checkCancellation()
                guard header.count == 3,
                      case .uint(_, let type) = header.field(forKey: .init("TYP")), type == UInt64(ArchiveHeader.EntryType.regularFile.rawValue),
                      case .string(_, let path) = header.field(forKey: .init("PAT")), Self.validateMemberPath(path), seen.insert(path).inserted,
                      case .blob(_, let length, _) = header.field(forKey: .init("DAT")), length <= Limits.imageBytes else { throw CoreError.invalidArchive }
                if path == "manifest.json" && length > 16384 { throw CoreError.invalidArchive }
                if path.hasPrefix("entries/") && length > 8 * 1024 * 1024 { throw CoreError.invalidArchive }
                total += Int64(length)
                guard total <= Limits.archiveBytes, seen.count <= Limits.archiveEntries * 3 + 1 else { throw CoreError.tooLarge }
                var data = Data(count: Int(length))
                try data.withUnsafeMutableBytes { try archive.readBlob(key: .init("DAT"), into: $0) }
                try PrivateFiles.write(data, to: directory.appendingPathComponent(path))
            }
            try archive.close(); try coded.close()
            return total
        } catch { archive.cancel(); coded.cancel(); try? archive.close(); try? coded.close(); throw error }
    }
    static func validate(detail: ClipboardEntryDetail, attachments: URL) throws -> ClipboardSnapshot {
        let s = detail.summary
        guard s.preview.count <= 240, s.modifiedAt.timeIntervalSince1970.isFinite, s.byteCount >= 0 else { throw CoreError.invalidArchive }
        let reps = try detail.representations.map { rep -> CapturedRepresentation in
            let data: Data
            if let inline = rep.data, rep.attachmentName == nil { data = inline }
            else if let name = rep.attachmentName, rep.data == nil, PrivateFiles.isManagedName(name) { data = try PrivateFiles.read(attachments.appendingPathComponent(name), limit: Limits.imageBytes) }
            else { throw CoreError.invalidArchive }
            guard data.count == rep.byteCount, PrivateFiles.checksum(data) == rep.checksum else { throw CoreError.invalidArchive }
            return .init(itemIndex: rep.itemIndex, type: rep.type, data: data)
        }
        let snapshot = ClipboardSnapshot(kind: s.kind, text: detail.text, representations: reps, sourceBundleID: s.sourceBundleID, createdAt: s.createdAt)
        try PayloadRules.validate(snapshot)
        try PayloadRules.validateImage(snapshot)
        guard reps.reduce(0, { $0 + $1.data.count }) == s.byteCount else { throw CoreError.invalidArchive }
        return snapshot
    }
    public func discard(_ prepared: PreparedImport) throws { try FileManager.default.removeItem(at: prepared.directory) }
}

extension HistoryStore {
    public func commitImport(_ prepared: PreparedImport) throws -> Int {
        var created: [String] = [], imported = 0
        do {
            try db.transaction {
                for id in prepared.ids {
                    try Task.checkCancellation()
                    let url = prepared.directory.appendingPathComponent("entries/\(id.uuidString).json")
                    var detail = try JSONDecoder().decode(ClipboardEntryDetail.self, from: PrivateFiles.read(url, limit: 8 * 1024 * 1024))
                    let snapshot = try ArchiveService.validate(detail: detail, attachments: prepared.directory.appendingPathComponent("attachments"))
                    if let existing = try Self.detail(id, db: db, includingDeleted: true) {
                        guard existing.summary.contentHash == snapshot.contentHash else { throw CoreError.conflictingIdentity }
                        continue
                    }
                    for index in detail.representations.indices {
                        if let old = detail.representations[index].attachmentName {
                            let name = UUID().uuidString
                            let data = try PrivateFiles.read(prepared.directory.appendingPathComponent("attachments/\(old)"), limit: Limits.imageBytes)
                            try PrivateFiles.write(data, to: attachmentsURL.appendingPathComponent(name)); created.append(name)
                            detail.representations[index].attachmentName = name
                        }
                    }
                    try insertDetail(detail); imported += 1
                }
            }
            return imported
        } catch {
            for name in created { try? FileManager.default.removeItem(at: attachmentsURL.appendingPathComponent(name)) }
            throw error
        }
    }
}
