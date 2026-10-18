import AppKit
import ClipboardCore
import CoreGraphics

@MainActor final class PasteCoordinator {
    var previousApplication: NSRunningApplication?
    let sessionToken: String
    private let testBoard: NSPasteboard?
    private let testMode: Bool
    private let permissionCheck: () -> Bool
    init(sessionToken: String, testMode: Bool = false, permissionCheck: (() -> Bool)? = nil) { self.sessionToken = sessionToken; self.testMode = testMode; self.permissionCheck = permissionCheck ?? { PasteAccess.isGranted }; testBoard = testMode ? NSPasteboard.withUniqueName() : nil }
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
        guard enabled else { return .disabled }
        guard permissionCheck() else { return .permissionRequired }
        guard let target = previousApplication, !target.isTerminated else { return .targetUnavailable }
        let restored = try await PasteActivation.restore(targetPID: target.processIdentifier, isTerminated: { target.isTerminated }, frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }, activate: {
            NSApp.yieldActivation(to: target)
            return target.activate(from: .current, options: [])
        })
        guard restored else { return .targetUnavailable }
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
    static let deniedDescription = "macOS has not granted event-posting access to this running copy of Clipboard. If Clipboard is already enabled in Accessibility settings, quit and reopen it. If the grant belongs to an older copy, remove that entry and add the installed app from Applications again."
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        if !NSWorkspace.shared.open(url), let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(fallback) }
    }
}

struct PasteFailurePresentation {
    let title: String
    let message: String
    let offersSettings: Bool
    init(outcome: PasteOutcome, deniedDescription: String) {
        switch outcome {
        case .disabled:
            title = "Automatic paste is turned off"
            message = "Enable automatic paste in Clipboard Settings → General. Your macOS permission and this app setting are separate. You can still copy and paste manually."
            offersSettings = true
        case .permissionRequired:
            title = "macOS is blocking automatic paste"
            message = deniedDescription
            offersSettings = true
        case .targetUnavailable:
            title = "The destination app is unavailable"
            message = "Open and focus the app where you want to paste, place the cursor in a field, then open Clipboard again. Clipboard could not restore that destination; this is not a permission request."
            offersSettings = false
        default:
            title = "The paste event could not be sent"
            message = "Copy this item and paste it manually with Command-V."
            offersSettings = false
        }
    }
}

@MainActor enum PasteActivation {
    static func restore(targetPID: pid_t, isTerminated: () -> Bool, frontmostPID: () -> pid_t?, activate: () -> Bool) async throws -> Bool {
        guard !isTerminated() else { return false }
        if frontmostPID() != targetPID, !activate() { return false }
        let deadline = ContinuousClock.now + .seconds(1)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            guard !isTerminated() else { return false }
            if frontmostPID() == targetPID { return true }
        } while ContinuousClock.now < deadline
        return false
    }
}
