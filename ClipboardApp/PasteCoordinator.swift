import AppKit
import ClipboardCore
import CoreGraphics
import ApplicationServices
import Security

@MainActor final class PasteCoordinator {
    var previousApplication: NSRunningApplication?
    private(set) var lastStatus = "No paste attempted in this session."
    var onStatusChanged: (() -> Void)?
    private func report(_ status: String) { lastStatus = status; onStatusChanged?() }
    let sessionToken: String
    private let testBoard: NSPasteboard?
    private let testMode: Bool
    private let permissionCheck: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let sourceIsActive: () -> Bool
    private let eventPoster: () -> Bool
    init(sessionToken: String, testMode: Bool = false, permissionCheck: (() -> Bool)? = nil, pasteboard: NSPasteboard? = nil, frontmostPID: (() -> pid_t?)? = nil, sourceIsActive: (() -> Bool)? = nil, eventPoster: (() -> Bool)? = nil) {
        precondition(eventPoster == nil || pasteboard != nil)
        self.sessionToken = sessionToken; self.testMode = testMode
        self.permissionCheck = permissionCheck ?? { PasteAccess.isGranted }
        self.frontmostPID = frontmostPID ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.sourceIsActive = sourceIsActive ?? { NSApp.isActive }
        self.eventPoster = eventPoster ?? {
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            return true
        }
        testBoard = pasteboard ?? (testMode ? NSPasteboard.withUniqueName() : nil)
    }
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
        try Task.checkCancellation()
        if testMode { try write(snapshot); report("Fixture copied privately; no event sent."); return .copied }
        guard enabled else { report("Stopped: automatic paste is off."); return .disabled }
        guard permissionCheck() else { report("Stopped: macOS denied event-posting access to this copy."); return .permissionRequired }
        guard let target = previousApplication, !target.isTerminated else { report("Stopped: no live destination app was remembered."); return .targetUnavailable }
        report("Permission allowed. Restoring \(target.localizedName ?? "destination")…")
        let restored = try await PasteActivation.restore(targetPID: target.processIdentifier, isTerminated: { target.isTerminated }, frontmostPID: frontmostPID, sourceIsActive: sourceIsActive, activate: {
            NSApp.yieldActivation(to: target)
            return target.activate(from: .current, options: [])
        })
        guard restored else { report("Stopped: destination activation failed or timed out."); return .targetUnavailable }
        try Task.checkCancellation()
        guard permissionCheck() else { report("Stopped: event-posting access was revoked while restoring the destination."); return .permissionRequired }
        guard frontmostPID() == target.processIdentifier, !sourceIsActive() else { report("Stopped: another app took focus before copying."); return .targetUnavailable }
        try write(snapshot)
        let board = testBoard ?? NSPasteboard.general
        let generation = board.changeCount
        guard permissionCheck() else { report("Stopped: event-posting access was revoked after copying. Paste manually with Command-V."); return .permissionRequired }
        guard board.changeCount == generation, frontmostPID() == target.processIdentifier, !sourceIsActive() else { report("Stopped: clipboard or destination changed before sending."); return .targetUnavailable }
        guard eventPoster() else { report("Stopped: macOS could not create the paste key events."); return .failed }
        report("Command-V sent once to \(target.localizedName ?? "destination"). Destination acceptance is not observable.")
        return .pasteEventSent
    }
}

@MainActor enum PasteAccess {
    static var isGranted: Bool { CGPreflightPostEventAccess() }
    static var status: PastePermissionStatus { .init(accessibilityTrusted: AXIsProcessTrusted(), eventPostingAllowed: isGranted) }
    static var isAdHocSigned: Bool {
        var code: SecCode?
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let flags = values[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
    static var clipboardAccessDescription: String {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return "Allowed by macOS."
            case .alwaysDeny: return "Denied by macOS. Allow Clipboard in Privacy & Security to resume capture."
            case .ask: return "macOS asks on each read. Allow ongoing clipboard access to enable background capture."
            case .default: return "System default. macOS may ask when a new clipboard item is read."
            @unknown default: return "Check Clipboard access in System Settings."
            }
        }
        return "This macOS version has no separate clipboard-reading permission control."
    }
    static func request() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else if !isGranted { _ = CGRequestPostEventAccess() }
    }
    static let deniedDescription = "Command-V event access is blocked for this running copy. In System Settings → Privacy & Security → Accessibility, remove the old Clipboard entry, add the exact app shown in Clipboard Settings → Permissions, and enable it. Then quit and reopen Clipboard. Updates to ad-hoc signed builds can invalidate an older grant."
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        if !NSWorkspace.shared.open(url), let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(fallback) }
    }
}

struct PastePermissionStatus: Equatable {
    let accessibilityTrusted: Bool
    let eventPostingAllowed: Bool
    var details: String {
        "Accessibility: \(accessibilityTrusted ? "Allowed" : "Not recognized")\nCommand-V event access: \(eventPostingAllowed ? "Allowed" : "Blocked")"
    }
    func summary(enabled: Bool) -> String {
        if !enabled { return "Automatic paste is off. Enable it below; macOS access is a separate setting." }
        if accessibilityTrusted && eventPostingAllowed { return "Automatic paste is ready. Permission checks passed; the destination must still accept Command-V." }
        if !eventPostingAllowed { return "Permission required: Command-V is blocked for this copy of Clipboard." }
        return "Permission checks disagree. Restart Clipboard; if paste still fails, renew the Accessibility entry for this exact copy."
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
            message = "Enable automatic paste in Clipboard Settings → Permissions. Your macOS permission and this app setting are separate. You can still copy and paste manually."
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
    static func restore(targetPID: pid_t, isTerminated: () -> Bool, frontmostPID: () -> pid_t?, sourceIsActive: () -> Bool = { false }, activate: () -> Bool) async throws -> Bool {
        guard !isTerminated() else { return false }
        if frontmostPID() != targetPID, !activate() { return false }
        let deadline = ContinuousClock.now + .seconds(1)
        var settled = false
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            guard !isTerminated() else { return false }
            if frontmostPID() == targetPID, !sourceIsActive() {
                if settled { return true }
                settled = true
            } else { settled = false }
        } while ContinuousClock.now < deadline
        return false
    }
}
