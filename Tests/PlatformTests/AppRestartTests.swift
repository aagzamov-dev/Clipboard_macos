import Foundation
import AppKit
import ClipboardCore
import XCTest
@testable import ClipboardPlatform

final class AppRestartTests: XCTestCase {
    @MainActor func testPermissionRestartButtonAndBusyPasteTest() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-RestartSettings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SettingsWindowController(settings: SettingsStore(persistent: false), store: try HistoryStore(rootURL: root))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? NSButton }.filter { $0.title == "Restart Clipboard" }
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
        var restarts = 0
        controller.onRestart = { restarts += 1 }
        XCTAssertTrue(buttons.allSatisfy(\.isEnabled))
        let button = try XCTUnwrap(buttons.first)
        button.performClick(nil)
        XCTAssertEqual(restarts, 1)
        controller.showPasteTestResult("Testing", running: true)
        button.performClick(nil)
        XCTAssertEqual(restarts, 1)
        controller.showPasteTestResult("Finished")
        button.performClick(nil)
        XCTAssertEqual(restarts, 2)
    }

    func testRestartWaitsForOriginalProcessAndOpensExactBundleOnce() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Clipboard with spaces.app")
        var running = true, ready = false, waits = 0, launches = 0
        try AppRestart.runHelper(arguments: ["Clipboard", AppRestart.helperArgument, "42"], bundleURL: bundle, parentPID: 42, isRunning: { pid in
            XCTAssertEqual(pid, 42); XCTAssertTrue(ready)
            return running
        }, wait: {
            waits += 1
            if waits == 3 { running = false }
        }, ready: { ready = true }, launch: { url in
            XCTAssertFalse(running)
            XCTAssertEqual(url, bundle)
            launches += 1
        })
        XCTAssertEqual(waits, 3)
        XCTAssertEqual(launches, 1)
    }

    func testRestartRejectsWrongParentWithoutLaunching() {
        XCTAssertThrowsError(try AppRestart.runHelper(arguments: ["Clipboard", AppRestart.helperArgument, "42"], bundleURL: URL(fileURLWithPath: "/Applications/Clipboard.app"), parentPID: 43, isRunning: { _ in XCTFail("Must validate first"); return false }, wait: {}, ready: { XCTFail("Must not acknowledge invalid request") }, launch: { _ in XCTFail("Must not launch") }))
    }

    func testFailedReadinessDoesNotLaunchReplacement() {
        XCTAssertThrowsError(try AppRestart.runHelper(arguments: ["Clipboard", AppRestart.helperArgument, "42"], bundleURL: URL(fileURLWithPath: "/Applications/Clipboard.app"), parentPID: 42, isRunning: { _ in XCTFail("Readiness failed"); return false }, wait: {}, ready: { throw AppRestart.RestartError.helperFailed }, launch: { _ in XCTFail("Must not launch") }))
    }

    func testLaunchFailureIsReportedWithoutRetrying() {
        var attempts = 0
        XCTAssertThrowsError(try AppRestart.runHelper(arguments: ["Clipboard", AppRestart.helperArgument, "42"], bundleURL: URL(fileURLWithPath: "/Applications/Clipboard.app"), parentPID: 42, isRunning: { _ in false }, wait: { XCTFail("Parent already exited") }, ready: {}, launch: { _ in
            attempts += 1
            throw AppRestart.RestartError.launchFailed
        }))
        XCTAssertEqual(attempts, 1)
    }

    func testRestartDoesNotOpenSecondCopyIfOriginalNeverExits() {
        var waits = 0
        XCTAssertThrowsError(try AppRestart.runHelper(arguments: ["Clipboard", AppRestart.helperArgument, "42"], bundleURL: URL(fileURLWithPath: "/Applications/Clipboard.app"), parentPID: 42, isRunning: { _ in true }, wait: { waits += 1 }, ready: {}, launch: { _ in XCTFail("Original is still running") }))
        XCTAssertEqual(waits, 300)
    }
}
