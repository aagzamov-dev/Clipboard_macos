import AppKit
import ClipboardCore

@MainActor final class PasteCheckController {
    private let sessionToken: String
    private var running = false
    init(sessionToken: String) { self.sessionToken = sessionToken }
    func run() async -> String {
        guard !running else { return "A paste test is already running." }
        guard PasteAccess.isGranted else { return "Test blocked: macOS has not allowed Command-V for this copy. Renew its Accessibility entry, then choose Restart Clipboard in Permissions." }
        running = true
        defer { running = false }
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard-PasteCheck-\(UUID())", isDirectory: true)
        var target: NSRunningApplication?
        defer {
            target?.terminate()
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let resultURL = folder.appendingPathComponent("result")
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClipboardPasteCheck.app")
            guard FileManager.default.fileExists(atPath: helper.path) else { return "Test unavailable: the app is missing its paste-test helper. Reinstall the complete app bundle." }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [board.name.rawValue, resultURL.path]
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
            target = app
            let coordinator = PasteCoordinator(sessionToken: sessionToken, pasteboard: board)
            coordinator.previousApplication = app
            let outcome = try await coordinator.paste(.plainText("Clipboard paste test"))
            guard outcome == .pasteEventSent else { return "Test stopped. \(coordinator.lastStatus)" }
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                if (try? String(contentsOf: resultURL, encoding: .utf8)) == "passed" { return "Passed: the separate test app received Command-V and the private test text. Your real clipboard was untouched." }
                if app.isTerminated { return "Test cancelled: the test window closed before receiving paste." }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return "Test failed: macOS reported access, but the test app received no paste. Renew Clipboard’s Accessibility entry, then choose Restart Clipboard in Permissions."
        } catch { return "Paste test could not finish. \(error.localizedDescription)" }
    }
}
