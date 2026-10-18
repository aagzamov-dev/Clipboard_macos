import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppleArchive
import System
@testable import ClipboardCore

@MainActor final class AttachmentAndFailureTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws { await MainActor.run { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = [] } }
    private func root() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Attachments-\(UUID().uuidString)"); try PrivateFiles.directory(url); roots.append(url); return url }
    private func image() throws -> Data {
        let bytes = Data(repeating: 180, count: 4 * 4 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData(); let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output)); return data as Data
    }
    func testImageAttachmentsBackupMissingFilesAndCleanup() async throws {
        let store = try HistoryStore(rootURL: root())
        let data = try image()
        let id = try await store.insert(.init(kind: .image, representations: [.init(type: "public.png", data: data)]))
        let loaded = try await store.detail(id)
        let detail = try XCTUnwrap(loaded)
        XCTAssertNil(detail.representations[0].data)
        let name = try XCTUnwrap(detail.representations[0].attachmentName)
        let archive = try root().appendingPathComponent("image.backup")
        try await ArchiveService(store: store).export(to: archive)
        let destination = try HistoryStore(rootURL: root()), importer = ArchiveService(store: destination)
        let prepared = try await importer.prepareImport(from: archive)
        _ = try await destination.commitImport(prepared); try await importer.discard(prepared)
        let restored = try await destination.materialize(id); XCTAssertEqual(restored.representations.first?.data, data)
        _ = try await store.markDeleted([id], now: .distantPast)
        try await store.purgeExpired()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentsURL.appendingPathComponent(name).path))
        let loadedDestination = try await destination.detail(id)
        let destinationDetail = try XCTUnwrap(loadedDestination)
        try FileManager.default.removeItem(at: destination.attachmentsURL.appendingPathComponent(destinationDetail.representations[0].attachmentName!))
        do { _ = try await destination.materialize(id); XCTFail("Missing attachment should fail") } catch {}
        let retained = try await destination.detail(id); XCTAssertNotNil(retained)
    }
    func testOrphanReconciliationAndOriginalFilesUntouched() async throws {
        let store = try HistoryStore(rootURL: root())
        let orphan = store.attachmentsURL.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.write(Data("orphan".utf8), to: orphan)
        let unknown = store.attachmentsURL.appendingPathComponent("unmanaged-user-file")
        try PrivateFiles.write(Data("leave alone".utf8), to: unknown)
        try await store.reconcileAttachments()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }
    func testInvalidImagesAndOversizedTextDoNotChangeHistory() async throws {
        let store = try HistoryStore(rootURL: root())
        do { _ = try await store.insert(.init(kind: .image, representations: [.init(type: "public.png", data: Data("not an image".utf8))])); XCTFail("Expected invalid image") } catch {}
        do { _ = try await store.insert(.plainText(String(repeating: "x", count: Limits.textBytes + 1))); XCTFail("Expected size rejection") } catch {}
        let page = try await store.page(.init()); XCTAssertEqual(page.totalCount, 0)
    }
    func testEmptyAndEmbeddedNullTextRoundTrip() async throws {
        let store = try HistoryStore(rootURL: root())
        for text in ["", "before\0after"] {
            let id = try await store.insert(.plainText(text))
            let snapshot = try await store.materialize(id); XCTAssertEqual(snapshot.text, text); XCTAssertEqual(snapshot.representations.first?.data, Data(text.utf8))
        }
    }
    func testConsecutiveDeduplicationDoesNotSuppressLaterRecopiesOrFailedWrites() {
        var gate = ConsecutiveDeduplicator()
        XCTAssertTrue(gate.accepts("a")); XCTAssertTrue(gate.accepts("a"))
        gate.committed("a"); XCTAssertFalse(gate.accepts("a")); XCTAssertTrue(gate.accepts("b"))
        gate.committed("b"); XCTAssertTrue(gate.accepts("a")); gate.reset(); XCTAssertTrue(gate.accepts("b"))
    }
    func testMaliciousArchiveMembersAreRejectedBeforeExtraction() async throws {
        let store = try HistoryStore(rootURL: root()), service = ArchiveService(store: store)
        for path in ["../escape", "/tmp/escape", "attachments/../../escape"] {
            let url = try root().appendingPathComponent("malicious")
            try writeArchive(url, path: path)
            do { _ = try await service.prepareImport(from: url); XCTFail("Expected traversal rejection") } catch {}
        }
        let page = try await store.page(.init()); XCTAssertEqual(page.totalCount, 0)
    }
    private func writeArchive(_ url: URL, path: String) throws {
        let file = try XCTUnwrap(ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerRead, .ownerWrite]))
        let compression = try XCTUnwrap(ArchiveByteStream.compressionStream(using: .lzfse, writingTo: file))
        let archive = try XCTUnwrap(ArchiveStream.encodeStream(writingTo: compression))
        try ArchiveService.writeMember(name: path, data: Data("malicious".utf8), stream: archive)
        try archive.close(); try compression.close(); try file.close()
    }
    func testImportConflictRollsBackEarlierEntriesAndAttachments() async throws {
        let source = try HistoryStore(rootURL: root()), target = try HistoryStore(rootURL: root())
        let newID = UUID(), conflictID = UUID()
        _ = try await source.insert(.init(kind: .image, representations: [.init(type: "public.png", data: try image())]), id: newID)
        _ = try await source.insert(.plainText("archive value"), id: conflictID)
        _ = try await target.insert(.plainText("keep existing"), id: conflictID)
        let file = try root().appendingPathComponent("backup")
        try await ArchiveService(store: source).export(to: file)
        let importer = ArchiveService(store: target), prepared = try await importer.prepareImport(from: file)
        let ordered = PreparedImport(entryCount: prepared.entryCount, expandedBytes: prepared.expandedBytes, oldestUnpinnedDate: prepared.oldestUnpinnedDate, directory: prepared.directory, ids: [newID, conflictID])
        do { _ = try await target.commitImport(ordered); XCTFail("Expected identity conflict") } catch {}
        let page = try await target.page(.init()); XCTAssertEqual(page.totalCount, 1)
        let existing = try await target.detail(conflictID); XCTAssertEqual(existing?.text, "keep existing")
        let files = try FileManager.default.contentsOfDirectory(atPath: target.attachmentsURL.path); XCTAssertTrue(files.isEmpty)
        try await importer.discard(prepared)
    }
    func testUnsavedDraftProtectionDuringRetention() async throws {
        let store = try HistoryStore(rootURL: root())
        let id = try await store.insert(.plainText("editing", date: Date().addingTimeInterval(-60 * 86400)))
        try await store.retention(days: 30, protectedIDs: [id])
        let retained = try await store.detail(id); XCTAssertNotNil(retained)
        try await store.retention(days: 30)
        let removed = try await store.detail(id); XCTAssertNil(removed)
    }
    func testCancelledImportDoesNotCommitAnyEntries() async throws {
        let source = try HistoryStore(rootURL: root()), target = try HistoryStore(rootURL: root())
        _ = try await source.insert(.plainText("original"))
        let file = try root().appendingPathComponent("backup")
        try await ArchiveService(store: source).export(to: file)
        let service = ArchiveService(store: target), prepared = try await service.prepareImport(from: file)
        let task = Task { () -> Int in try await Task.sleep(for: .seconds(1)); return try await target.commitImport(prepared) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        let page = try await target.page(.init()); XCTAssertEqual(page.totalCount, 0)
        try await service.discard(prepared)
    }
}
