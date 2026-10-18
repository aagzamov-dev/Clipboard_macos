import AppKit
import XCTest
import ClipboardCore
@testable import ClipboardPlatform

@MainActor final class PlatformTests: XCTestCase {
    func testPreselectedFirstRowOpensPreviewAndSurvivesCaptureRefresh() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-FirstClick-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(rootURL: root)
        try await store.insert(.plainText("First selection fixture"))
        let controller = HistoryWindowController(store: store, settings: SettingsStore(persistent: false), paste: PasteCoordinator(sessionToken: "test", testMode: true))
        let window = try XCTUnwrap(controller.window)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? HistoryTable }.first)
        controller.refresh()
        for _ in 0..<100 {
            if table.selectedRow == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(window.frame.width, 400, accuracy: 1)
        table.onSelectedRowClick?()
        for _ in 0..<100 {
            if window.frame.width > 400 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(window.frame.width, 720, accuracy: 1)
        try await store.insert(.plainText("A newer entry"))
        controller.refresh()
        for _ in 0..<100 {
            if table.numberOfRows == 2 && table.selectedRow == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 1)
        controller.dismissPopup()
    }

    func testAlreadyActiveDestinationDoesNotRequireAnotherActivationRequest() async throws {
        let restored = try await PasteActivation.restore(targetPID: 42, isTerminated: { false }, frontmostPID: { 42 }, activate: { XCTFail("An active target does not need activation"); return false })
        XCTAssertTrue(restored)
    }
    func testDestinationIsCheckedAfterCooperativeActivation() async throws {
        var pid: pid_t = 1
        var activationCount = 0
        let restored = try await PasteActivation.restore(targetPID: 42, isTerminated: { false }, frontmostPID: { pid }, activate: { activationCount += 1; pid = 42; return true })
        XCTAssertTrue(restored)
        XCTAssertEqual(activationCount, 1)
    }
    func testDisappearingDestinationStopsPaste() async throws {
        var terminated = false
        let restored = try await PasteActivation.restore(targetPID: 42, isTerminated: { terminated }, frontmostPID: { 1 }, activate: { terminated = true; return true })
        XCTAssertFalse(restored)
    }

    func testDisabledPasteDoesNotCheckPermission() async throws {
        let coordinator = PasteCoordinator(sessionToken: "test", permissionCheck: { XCTFail("Disabled paste must not check permissions"); return false })
        let outcome = try await coordinator.paste(.plainText("Private fixture"), enabled: false)
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(coordinator.lastStatus, "Stopped: automatic paste is off.")
        let failure = PasteFailurePresentation(outcome: outcome, deniedDescription: "Denied")
        XCTAssertEqual(failure.title, "Automatic paste is turned off")
    }
    func testGrantedPermissionWithoutTargetIsNotPermissionFailure() async throws {
        let coordinator = PasteCoordinator(sessionToken: "test", permissionCheck: { true })
        let outcome = try await coordinator.paste(.plainText("Private fixture"), enabled: true)
        XCTAssertEqual(outcome, .targetUnavailable)
        XCTAssertEqual(coordinator.lastStatus, "Stopped: no live destination app was remembered.")
        let failure = PasteFailurePresentation(outcome: outcome, deniedDescription: "Denied")
        XCTAssertFalse(failure.offersSettings)
        XCTAssertEqual(failure.title, "The destination app is unavailable")
    }
    func testDeniedPasteNeverAttemptsTargetActivationOrClipboardWrite() async throws {
        let coordinator = PasteCoordinator(sessionToken: "test", permissionCheck: { false })
        let outcome = try await coordinator.paste(.plainText("Private fixture"), enabled: true)
        XCTAssertEqual(outcome, .permissionRequired)
        XCTAssertEqual(coordinator.lastStatus, "Stopped: macOS denied event-posting access to this copy.")
        let failure = PasteFailurePresentation(outcome: outcome, deniedDescription: "Permission denied to running copy")
        XCTAssertEqual(failure.message, "Permission denied to running copy")
        XCTAssertTrue(failure.offersSettings)
    }

    func testPastePermissionStatusUpdatesWithoutRestart() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Access-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(rootURL: root)
        let settings = SettingsStore(persistent: false)
        try settings.update { $0.automaticPaste = true }
        var granted = false
        let controller = SettingsWindowController(settings: settings, store: store, permissionCheck: { granted })
        controller.refreshPermissionStatus()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try XCTUnwrap(controller.window?.contentView))
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Open Accessibility Settings…" && !$0.isEnabled })
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Permission required") })
        granted = true
        controller.refreshPermissionStatus()
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Automatic paste is ready") })
        try settings.update { $0.automaticPaste = false }
        controller.refreshPermissionStatus()
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Automatic paste is off") })
        let content = try XCTUnwrap(controller.window?.contentView)
        let tabs = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTabView }.first)
        XCTAssertTrue(tabs.tabViewItems.contains { $0.identifier as? String == "Permissions" })
        tabs.selectTabViewItem(withIdentifier: "Permissions")
        content.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Open Accessibility Settings…" })
        XCTAssertGreaterThanOrEqual(button.bounds.width, button.fittingSize.width - 1)
        XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/clipboard-permission-settings.png"))
        }
    }

    func testPreviewBackgroundDoesNotPaintOutsideItsBounds() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        let preview = PreviewStack(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        preview.draw(NSRect(x: 0, y: 0, width: 200, height: 200))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 150, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(outside.blueComponent, 1, accuracy: 0.01)
    }

    func testPopupLayoutKeepsSearchHistoryAndControlsVisible() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(rootURL: root)
        try await store.insert(.plainText("A small place for everything you copy."))
        let controller = HistoryWindowController(store: store, settings: SettingsStore(persistent: false), paste: PasteCoordinator(sessionToken: "test", testMode: true))
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.canBecomeMain)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        controller.refresh()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        for _ in 0..<100 {
            if table.numberOfRows == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        content.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSearchField }.first)
        XCTAssertGreaterThan(search.bounds.width, 250)
        XCTAssertGreaterThan(search.bounds.height, 15)
        XCTAssertTrue(content.bounds.contains(search.convert(search.bounds, to: content)))
        XCTAssertGreaterThan(table.enclosingScrollView?.bounds.height ?? 0, 200)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        for _ in 0..<100 {
            if descendants(content).compactMap({ $0 as? NSTextView }).contains(where: { $0.string == "A small place for everything you copy." }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(search.bounds.width, 250)
        XCTAssertEqual(table.enclosingScrollView?.bounds.width ?? 0, content.bounds.width * 0.4, accuracy: 1)
        XCTAssertGreaterThan(table.enclosingScrollView?.bounds.height ?? 0, 200)
        let searchFrame = search.convert(search.bounds, to: content)
        let listScroll = try XCTUnwrap(table.enclosingScrollView)
        let listFrame = listScroll.convert(listScroll.bounds, to: content)
        XCTAssertTrue(content.bounds.contains(searchFrame), "Search outside popup: \(searchFrame), popup \(content.bounds)")
        XCTAssertTrue(content.bounds.contains(listFrame), "List outside popup: \(listFrame)")
        XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        let title = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Text" })
        let titleFrame = title.convert(title.bounds, to: content)
        XCTAssertLessThanOrEqual(listFrame.maxX, titleFrame.minX)
        XCTAssertGreaterThan(searchFrame.minY, listFrame.maxY)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/clipboard-selection-fixed.png"))
        }
        controller.updateRecordingState(.running)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "● Recording" })
        let editor = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(editor.string, "A small place for everything you copy.")
        editor.string = "Good tools stay out of your way."
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(controller.protectedDraftIDs.count, 1)
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        for _ in 0..<100 {
            if !window.isVisible { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(window.isVisible)
        controller.refresh()
        for _ in 0..<100 {
            if editor.string == "Good tools stay out of your way." { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(editor.string, "Good tools stay out of your way.")
        try await store.insert(.plainText("Ship something simple."))
        controller.refresh()
        for _ in 0..<100 {
            if table.numberOfRows == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        for _ in 0..<100 {
            if editor.string.contains("Ship something simple.") && editor.string.contains("Good tools stay out of your way.") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.string.contains("Ship something simple."))
        for size in [NSSize(width: 660, height: 360), NSSize(width: 900, height: 560), NSSize(width: 720, height: 440)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(content.bounds.contains(search.convert(search.bounds, to: content)))
            XCTAssertTrue(content.bounds.contains(listScroll.convert(listScroll.bounds, to: content)))
            XCTAssertEqual(listScroll.bounds.width, content.bounds.width * 0.4, accuracy: 1)
        }
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/clipboard-bulk-fixed.png"))
        }
    }
    func testImageSelectionKeepsCompactSizeAndFitsPreview() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-ImageLayout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(rootURL: root)
        let controller = HistoryWindowController(store: store, settings: SettingsStore(persistent: false), paste: PasteCoordinator(sessionToken: "test", testMode: true))
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let imageView = try XCTUnwrap(descendants(content).compactMap { $0 as? ImagePreviewView }.first)
        for (index, size) in [(1200, 1800), (1800, 900)].enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            context.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 0, y: size.1 / 2, width: size.0, height: size.1 / 2))
            let source = try XCTUnwrap(context.makeImage())
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
            try await store.insert(ClipboardSnapshot(kind: .image, representations: [.init(type: "public.png", data: data)]))
            controller.refresh()
            for _ in 0..<100 {
                if table.numberOfRows == index + 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            for _ in 0..<200 {
                if let image = imageView.image, (index == 0 ? image.height > image.width : image.width > image.height) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            content.layoutSubtreeIfNeeded()
            let thumbnail = try XCTUnwrap(imageView.image)
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 1024)
            XCTAssertEqual(window.frame.width, 720, accuracy: 1)
            XCTAssertEqual(window.frame.height, 440, accuracy: 1)
            XCTAssertEqual(table.enclosingScrollView?.bounds.width ?? 0, content.bounds.width * 0.4, accuracy: 1)
            XCTAssertTrue(imageView.bounds.contains(imageView.fittedImageRect))
            XCTAssertGreaterThan(imageView.fittedImageRect.height, 80)
            XCTAssertEqual(imageView.fittedImageRect.width / imageView.fittedImageRect.height, CGFloat(size.0) / CGFloat(size.1), accuracy: 0.01)
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: index == 0 ? "/tmp/clipboard-compact-portrait.png" : "/tmp/clipboard-compact-image.png"))
            }
        }
        controller.dismissPopup()
        XCTAssertNil(imageView.image)
        window.setContentSize(NSSize(width: 900, height: 560))
        controller.open()
        XCTAssertEqual(window.frame.width, 720, accuracy: 1)
        XCTAssertEqual(window.frame.height, 440, accuracy: 1)
        controller.dismissPopup()
    }

    func testMonitoringResumesAfterStartingInsideExcludedApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-Monitor-\(UUID())")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(rootURL: root)
        var settings = AppSettings(); settings.excludedApps = ["excluded.test"]; settings.pollingInterval = 0.25
        let suspended = expectation(description: "Initially suspended")
        let resumed = expectation(description: "Resumed after excluded app")
        let captured = expectation(description: "Captured new private clipboard content")
        let paused = expectation(description: "Stopped")
        let monitor = ClipboardMonitor(store: store, pasteboard: board, onState: { state in
            if state == .suspended { suspended.fulfill() }
            if state == .running { resumed.fulfill() }
            if state == .manuallyPaused { paused.fulfill() }
        }, onCapture: { captured.fulfill() }, onError: { _ in XCTFail("Capture failed") })
        monitor.configure(settings: settings, state: .running, foregroundBundleID: "excluded.test")
        await fulfillment(of: [suspended], timeout: 2)
        board.clearContents(); board.setString("Skipped during exclusion", forType: .string)
        monitor.updateForeground("allowed.test")
        await fulfillment(of: [resumed], timeout: 2)
        board.clearContents(); board.setString("Captured after exclusion", forType: .string)
        await fulfillment(of: [captured], timeout: 3)
        monitor.configure(settings: settings, state: .manuallyPaused, foregroundBundleID: "allowed.test")
        await fulfillment(of: [paused], timeout: 2)
        let page = try await store.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.preview, "Captured after exclusion")
    }

    func testTextConversionAndPrivateCopy() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(sessionToken: "test-token", testMode: true)
        try coordinator.write(.plainText("A private clipboard test"), to: board)
        XCTAssertEqual(board.string(forType: .string), "A private clipboard test")
        let ignored = try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "test-token", excluded: [])
        XCTAssertNil(ignored)
        let decoded = try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "different-process", excluded: [])
        XCTAssertEqual(decoded?.text, "A private clipboard test")
    }
    func testSensitiveContentIsSkippedBeforePayloadConversion() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("fictional secret", forType: .string)
        board.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        XCTAssertNil(try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "test", excluded: []))
    }
    func testUnknownSourcesAreNotInventedAndMarkedExclusionsApply() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil); board.setString("text", forType: .string)
        let unknown = try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "test", excluded: [])
        XCTAssertNil(unknown?.sourceBundleID)
        board.addTypes([.init("org.nspasteboard.source")], owner: nil); board.setString("sensitive.test", forType: .init("org.nspasteboard.source"))
        XCTAssertNil(try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "test", excluded: ["sensitive.test"]))
    }
    func testMultipleFileReferencesRoundTrip() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let snapshot = ClipboardSnapshot(kind: .files, representations: [
            .init(itemIndex: 0, type: PayloadRules.fileType, data: Data("file:///fictional/first.txt".utf8)),
            .init(itemIndex: 1, type: PayloadRules.fileType, data: Data("file:///fictional/second.txt".utf8))
        ])
        try PasteCoordinator(sessionToken: "test").write(snapshot, to: board)
        let decoded = try ClipboardMonitor.decode(board: board, generation: board.changeCount, ownToken: "other", excluded: [])
        XCTAssertEqual(decoded?.kind, .files); XCTAssertEqual(decoded?.representations, snapshot.representations)
    }
    func testFixturePasteUsesPrivateBoardWithoutEventPosting() async throws {
        let coordinator = PasteCoordinator(sessionToken: "test", testMode: true)
        let result = try await coordinator.paste(.plainText("fixture"), enabled: false)
        if case .copied = result {} else { XCTFail("Fixture paste must not post events") }
    }
}
