import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CSQLite
@testable import ClipboardCore

@MainActor final class ClipboardCoreTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws { await MainActor.run { for root in roots { try? FileManager.default.removeItem(at: root) }; roots.removeAll() } }
    private func location() -> URL { let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Clipboard-Test-\(UUID().uuidString)"); roots.append(root); return root }
    private func store() throws -> HistoryStore { try HistoryStore(rootURL: location()) }

    func testCombinedEditingPreservesOriginalHistoryAndReverts() async throws {
        let store = try store()
        let first = try await store.insert(.plainText("First"))
        let second = try await store.insert(.plainText("Second"))
        var draft = CombinedCopyDraft(ids: [second, first], text: "Second\n\nFirst")
        try draft.set("Edited combined copy", otherDraftBytes: 0)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.text, "Edited combined copy")
        XCTAssertEqual(draft.ids, [second, first])
        let original = try await store.detail(first)
        XCTAssertEqual(original?.text, "First")
        draft.revert()
        XCTAssertEqual(draft.text, "Second\n\nFirst")
        XCTAssertFalse(draft.hasChanges)
    }
    func testCombinedDraftLimitsDoNotLosePreviousEdits() throws {
        var draft = CombinedCopyDraft(ids: [UUID(), UUID()], text: "Original")
        try draft.set("Edited", otherDraftBytes: 0)
        XCTAssertThrowsError(try draft.set(String(repeating: "x", count: Limits.textBytes + 1), otherDraftBytes: 0))
        XCTAssertThrowsError(try draft.set("More edits", otherDraftBytes: Limits.draftBytes))
        XCTAssertEqual(draft.text, "Edited")
        try draft.set("Original", otherDraftBytes: Limits.draftBytes)
        XCTAssertEqual(draft.editedByteCount, 0)
    }

    func testRoundTripPaginationSearchAndLiteralQueries() async throws {
        let store = try store()
        let id = try await store.insert(.plainText("hello café Swift clipboard"))
        let page = try await store.page(.init(search: "café Swift"))
        XCTAssertEqual(page.entries.map(\.id), [id]); XCTAssertEqual(page.totalCount, 1)
        let detail = try await store.detail(id)
        XCTAssertEqual(detail?.text, "hello café Swift clipboard")
        for query in ["\"", "OR", "*", "hello\" OR *", "()", "hello NEAR clipboard"] { _ = try await store.page(.init(search: query)) }
        let snapshot = try await store.materialize(id)
        XCTAssertEqual(snapshot.text, detail?.text)
    }
    func testSaveIsExplicitAndDropsRichRepresentation() async throws {
        let store = try store()
        let original = ClipboardSnapshot(kind: .text, text: "Original", representations: [.init(type: PayloadRules.textType, data: Data("Original".utf8)), .init(type: "public.rtf", data: Data("{\\rtf1 Original}".utf8))])
        let id = try await store.insert(original)
        var drafts = DraftStore(); try drafts.set("Draft", for: id, original: "Original")
        let before = try await store.detail(id); XCTAssertEqual(before?.text, "Original")
        let materialized = try await store.materialize(id, draft: drafts.text(for: id)); XCTAssertEqual(materialized.text, "Draft")
        try await store.saveText(id, text: "Saved")
        let saved = try await store.detail(id)
        XCTAssertEqual(saved?.text, "Saved"); XCTAssertEqual(saved?.representations.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.attachmentsURL.path).count, 0)
        let search = try await store.page(.init(search: "Original")); XCTAssertEqual(search.totalCount, 0)
    }
    func testPinnedRetentionAndCountLimit() async throws {
        let store = try store(), now = Date()
        let old = now.addingTimeInterval(-50 * 86400)
        let pinned = try await store.insert(.plainText("keep", date: old), pinned: true)
        _ = try await store.insert(.plainText("expire", date: old))
        _ = try await store.insert(.plainText("recent one", date: now.addingTimeInterval(-1)))
        _ = try await store.insert(.plainText("recent two", date: now))
        try await store.retention(days: 30, maximumCount: 1, now: now)
        let page = try await store.page(.init())
        XCTAssertEqual(page.totalCount, 2); XCTAssertTrue(page.entries.contains { $0.id == pinned })
    }
    func testDeleteUndoAndExpiration() async throws {
        let store = try store(), now = Date()
        let id = try await store.insert(.plainText("deletion"))
        let token = try await store.markDeleted([id], now: now)
        let removed = try await store.detail(id); XCTAssertNil(removed)
        try await store.undoDelete(token, now: now.addingTimeInterval(5))
        let restored = try await store.detail(id); XCTAssertNotNil(restored)
        _ = try await store.markDeleted([id], now: now)
        try await store.purgeExpired(now: now.addingTimeInterval(11))
        try await store.undoDelete(token, now: now.addingTimeInterval(12))
        let gone = try await store.detail(id); XCTAssertNil(gone)
    }
    func testFilesAreReferencesAndOriginalSurvivesClear() async throws {
        let root = location(); try PrivateFiles.directory(root)
        let original = root.appendingPathComponent("Original.txt"); try PrivateFiles.write(Data("user file".utf8), to: original)
        let store = try store()
        _ = try await store.insert(.init(kind: .files, representations: [.init(type: PayloadRules.fileType, data: Data(original.absoluteString.utf8))]))
        try await store.clear(includePinned: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testMarkersAndConsecutiveHashSemantics() throws {
        XCTAssertTrue(PayloadRules.shouldSkip(types: ["org.nspasteboard.ConcealedType"], source: nil, excluded: []))
        XCTAssertTrue(PayloadRules.shouldSkip(types: [], source: "sensitive.app", excluded: ["sensitive.app"]))
        XCTAssertFalse(PayloadRules.shouldSkip(types: [], source: nil, excluded: ["sensitive.app"]))
        XCTAssertEqual(ClipboardSnapshot.plainText("same").contentHash, ClipboardSnapshot.plainText("same").contentHash)
        XCTAssertNotEqual(ClipboardSnapshot.plainText("same").contentHash, ClipboardSnapshot.plainText("different").contentHash)
    }
    func testCommandShiftSelectionAndDraftBudget() throws {
        let ids = (0..<5).map { _ in UUID() }; var selection = SelectionState()
        selection.select(ids[1], ordered: ids); selection.select(ids[3], ordered: ids, command: true)
        XCTAssertEqual(selection.ids, [ids[1], ids[3]])
        selection.select(ids[4], ordered: ids, shift: true); XCTAssertEqual(selection.ids, [ids[3], ids[4]])
        selection.select(ids[3], ordered: ids, command: true); XCTAssertEqual(selection.ids, [ids[4]])
        var drafts = DraftStore()
        let big = String(repeating: "x", count: Limits.textBytes)
        for id in ids.prefix(4) { try drafts.set(big, for: id, original: "") }
        XCTAssertThrowsError(try drafts.set("extra", for: ids[4], original: ""))
        drafts.remove(ids[0]); try drafts.set("extra", for: ids[4], original: "")
        try drafts.set("same", for: ids[4], original: "same"); XCTAssertNil(drafts.text(for: ids[4]))
    }
    func testDateFiltersAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 15))!
        let today = try XCTUnwrap(DateFilter.today.range(now: now, calendar: calendar))
        XCTAssertEqual(today.upperBound.timeIntervalSince(today.lowerBound), 23 * 3600)
        let week = try XCTUnwrap(DateFilter.week.range(now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: week.lowerBound, to: week.upperBound).day, 7)
    }
    func testPrivatePermissionsAndSymlinkRejection() async throws {
        let store = try store(); _ = try await store.insert(.plainText("private"))
        let directory = try FileManager.default.attributesOfItem(atPath: store.rootURL.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for suffix in ["", "-wal", "-shm"] {
            let path = store.rootURL.appendingPathComponent("History.sqlite").path + suffix
            if FileManager.default.fileExists(atPath: path) { let attributes = try FileManager.default.attributesOfItem(atPath: path); XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600) }
        }
        let link = store.rootURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.rootURL.appendingPathComponent("History.sqlite"))
        XCTAssertThrowsError(try PrivateFiles.read(link, limit: 100))
    }
    func testFutureMigrationAndCorruptDatabasePreserved() throws {
        let root = location(); try PrivateFiles.directory(root)
        let path = root.appendingPathComponent("History.sqlite")
        do { let db = try SQLiteConnection(url: path); try db.execute("PRAGMA user_version=99") }
        XCTAssertThrowsError(try HistoryStore(rootURL: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        let corruptRoot = location(); try PrivateFiles.directory(corruptRoot)
        let corrupt = corruptRoot.appendingPathComponent("History.sqlite"); let data = Data("not a database".utf8)
        try PrivateFiles.write(data, to: corrupt)
        XCTAssertThrowsError(try HistoryStore(rootURL: corruptRoot)); XCTAssertEqual(try Data(contentsOf: corrupt), data)
    }
    func testFailedWriteLeavesExistingHistory() async throws {
        let store = try store(); let id = try await store.insert(.plainText("existing"))
        try await store.forceReadOnly()
        do { _ = try await store.insert(.plainText("new")); XCTFail("Expected write failure") } catch {}
        let detail = try await store.detail(id); XCTAssertEqual(detail?.text, "existing")
    }
    func testArchivePathsRejectTraversalAndSpecialNames() {
        for path in ["../escape", "/absolute", "entries/../../x", "attachments/..", "attachments/a/b", "entries//x.json", "manifest.json/", "unknown"] { XCTAssertFalse(ArchiveService.validateMemberPath(path)) }
        XCTAssertTrue(ArchiveService.validateMemberPath("entries/\(UUID().uuidString).json"))
        XCTAssertTrue(ArchiveService.validateMemberPath("attachments/\(UUID().uuidString)"))
    }
    func testPlainArchiveRoundTripAndRepeatedImport() async throws {
        try await roundTrip(password: nil)
    }
    func testEncryptedArchiveRoundTripAndWrongPassword() async throws {
        try await roundTrip(password: "a sufficiently long password")
    }
    private func roundTrip(password: String?) async throws {
        let source = try store(), destination = try store()
        let id = try await source.insert(.plainText("backup café"), pinned: true)
        let archiveRoot = location(); try PrivateFiles.directory(archiveRoot)
        let url = archiveRoot.appendingPathComponent("history.backup")
        let exporter = ArchiveService(store: source)
        try await exporter.export(to: url, password: password)
        let importer = ArchiveService(store: destination)
        if password != nil {
            do { _ = try await importer.prepareImport(from: url, password: "wrong but long password"); XCTFail("Expected authentication failure") } catch {}
        }
        let prepared = try await importer.prepareImport(from: url, password: password)
        XCTAssertEqual(prepared.entryCount, 1)
        let count = try await destination.commitImport(prepared); XCTAssertEqual(count, 1)
        let twice = try await destination.commitImport(prepared); XCTAssertEqual(twice, 0)
        let detail = try await destination.detail(id); XCTAssertEqual(detail?.text, "backup café"); XCTAssertEqual(detail?.summary.isPinned, true)
        try await destination.saveText(id, text: "different")
        do { _ = try await destination.commitImport(prepared); XCTFail("Expected conflict") } catch { XCTAssertTrue(error is CoreError) }
        let unchanged = try await destination.detail(id); XCTAssertEqual(unchanged?.text, "different")
        try await importer.discard(prepared)
        if password != nil {
            var data = try Data(contentsOf: url); data[data.count / 2] ^= 1
            let damaged = archiveRoot.appendingPathComponent("damaged"); try PrivateFiles.write(data, to: damaged)
            do { _ = try await importer.prepareImport(from: damaged, password: password); XCTFail("Expected tampering failure") } catch {}
        }
    }
    func testLegacyDisabledPasteSettingDoesNotPreventLoadingPreferences() throws {
        var original = AppSettings()
        original.appearance = "Dark"
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy["automaticPaste"] = false
        let decoded = try AppSettings.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded, original)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(saved["automaticPaste"])
    }
    func testSettingsValidation() throws {
        var settings = AppSettings(); XCTAssertEqual(settings.retentionDays, 30)
        settings.retentionDays = -1; XCTAssertThrowsError(try settings.validate())
        settings.retentionDays = nil; settings.pollingInterval = 0; XCTAssertThrowsError(try settings.validate())
        settings.pollingInterval = 0.5; settings.version = 2; XCTAssertThrowsError(try settings.validate())
    }
    func testTenThousandEntriesPagedSearchAndBoundedResults() async throws {
        let store = try store()
        try await store.seedBenchmark(count: 10_000)
        let started = ContinuousClock.now
        let page = try await store.page(.init(search: "entry"), offset: 9900)
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(page.totalCount, 10_000); XCTAssertEqual(page.entries.count, 100)
        let first = try await store.page(.init()); XCTAssertEqual(first.entries.count, 100)
        print("10,000-entry indexed page/search duration: \(elapsed)")
    }
}
private extension HistoryStore {
    func forceReadOnly() throws { try db.execute("PRAGMA query_only=ON") }
    func seedBenchmark(count: Int) throws {
        try db.transaction {
            for index in 0..<count {
                let snapshot = ClipboardSnapshot.plainText("Benchmark entry \(index) searchable Swift text", date: Date(timeIntervalSince1970: Double(index)))
                let rep = snapshot.representations[0]
                let summary = ClipboardEntrySummary(id: UUID(), kind: snapshot.kind, preview: snapshot.text!, createdAt: snapshot.createdAt, modifiedAt: snapshot.createdAt, sourceBundleID: nil, isPinned: false, byteCount: rep.data.count, contentHash: snapshot.contentHash)
                try insertDetail(.init(summary: summary, text: snapshot.text, representations: [.init(itemIndex: 0, type: rep.type, data: rep.data, attachmentName: nil, byteCount: rep.data.count, checksum: PrivateFiles.checksum(rep.data))]))
            }
        }
    }
}
