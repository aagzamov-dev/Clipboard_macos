import AppKit
import ClipboardCore
import CoreGraphics

@MainActor final class PasteCoordinator {
    var previousApplication: NSRunningApplication?
    let sessionToken: String
    private let testBoard: NSPasteboard?
    private let testMode: Bool
    init(sessionToken: String, testMode: Bool = false) { self.sessionToken = sessionToken; self.testMode = testMode; testBoard = testMode ? NSPasteboard.withUniqueName() : nil }
    func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = app }
    }
    func write(_ snapshot: ClipboardSnapshot, to requested: NSPasteboard? = nil) throws {
        if testMode && requested == nil && testBoard == nil { throw CoreError.invalidData }
        let board = requested ?? testBoard ?? .general
        try PayloadRules.validate(snapshot)
        let indices = Set(snapshot.representations.map(\.itemIndex)).sorted()
        var items: [NSPasteboardItem] = []
        for index in indices {
            let item = NSPasteboardItem()
            for rep in snapshot.representations where rep.itemIndex == index {
                guard item.setData(rep.data, forType: .init(rep.type)) else { throw CoreError.invalidData }
            }
            item.setString(sessionToken, forType: ClipboardMonitor.tokenType)
            item.setString(snapshot.sourceBundleID ?? "", forType: .init("org.nspasteboard.source"))
            items.append(item)
        }
        board.prepareForNewContents(with: [.currentHostOnly])
        guard board.writeObjects(items) else { throw CoreError.invalidData }
    }
    func paste(_ snapshot: ClipboardSnapshot, enabled: Bool) async throws -> PasteOutcome {
        if testMode { try write(snapshot); return .copied }
        guard enabled, PasteAccess.isGranted else { return .permissionRequired }
        guard let target = previousApplication, !target.isTerminated else { return .targetUnavailable }
        guard target.activate(options: []) else { return .targetUnavailable }
        let deadline = ContinuousClock.now + .seconds(1)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard ContinuousClock.now < deadline, !target.isTerminated else { return .targetUnavailable }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return .targetUnavailable }
        try write(snapshot)
        let generation = NSPasteboard.general.changeCount
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return .failed }
        down.flags = .maskCommand; up.flags = .maskCommand
        guard NSPasteboard.general.changeCount == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return .targetUnavailable }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return .pasteEventSent
    }
}

@MainActor enum PasteAccess {
    static var isGranted: Bool { CGPreflightPostEventAccess() }
    static func request() { _ = CGRequestPostEventAccess() }
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        if !NSWorkspace.shared.open(url), let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(fallback) }
    }
}
