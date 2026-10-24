import AppKit

@MainActor final class TestTextView: NSTextView {
    let board: NSPasteboard
    let resultURL: URL
    init(board: NSPasteboard, resultURL: URL) {
        self.board = board; self.resultURL = resultURL
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        isEditable = false; isSelectable = false
        font = .systemFont(ofSize: 17, weight: .medium)
        textContainerInset = NSSize(width: 22, height: 22)
        string = "Waiting for Clipboard’s paste command…"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func paste(_ sender: Any?) {
        guard board.string(forType: .string) == "Clipboard paste test" else { return }
        string = "✓ Paste received successfully"
        try? Data("passed".utf8).write(to: resultURL, options: .atomic)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.keyCode == 9 {
            paste(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard args.count == 3 else { NSApp.terminate(nil); return }
        let result = URL(fileURLWithPath: args[2]).standardizedFileURL
        let folder = result.deletingLastPathComponent()
        guard result.lastPathComponent == "result", folder.lastPathComponent.hasPrefix("Clipboard-PasteCheck-"),
              folder.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { NSApp.terminate(nil); return }
        let editor = TestTextView(board: NSPasteboard(name: .init(args[1])), resultURL: result)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clipboard Paste Test"; window.contentView = editor; window.isReleasedWhenClosed = false
        self.window = window
        window.center(); NSApp.activate(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate(); app.delegate = delegate; app.run()
