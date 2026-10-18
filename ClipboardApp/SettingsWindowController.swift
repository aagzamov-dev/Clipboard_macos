import AppKit
import ClipboardCore
import ServiceManagement
import UniformTypeIdentifiers
import CoreGraphics

@MainActor final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let settings: SettingsStore
    private let store: HistoryStore
    private let archives: ArchiveService
    private let tabs = NSTabView()
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private let cancelButton = ActionButton("Cancel operation", action: {})
    private var task: Task<Void, Never>?
    private var textChanges: [ObjectIdentifier: (String) throws -> Void] = [:]
    private var changes: [ObjectIdentifier: (NSPopUpButton) throws -> Void] = [:]
    private var excludedLabel = label("", size: 12, color: .secondaryLabelColor)
    var onPause: (() -> Void)?
    var onShortcut: ((UInt32, UInt32) throws -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onHistoryCleared: ((Bool) -> Void)?
    var onCaptureResume: (() -> Void)?
    init(settings: SettingsStore, store: HistoryStore) {
        self.settings = settings; self.store = store; archives = ArchiveService(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clipboard Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .width; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        window.contentView = root; root.addArrangedSubview(tabs)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        cancelButton.onClick = { [weak self] in self?.task?.cancel() }; cancelButton.isHidden = true
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(row([progress, status, cancelButton]))
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    func open() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil); rebuild() }
    private func page(_ name: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: name); item.label = name
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 15; stack.edgeInsets = NSEdgeInsets(top: 24, left: 14, bottom: 16, right: 14)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical); stack.addArrangedSubview(spacer)
        item.view = stack; tabs.addTabViewItem(item)
    }
    private func note(_ text: String) -> NSTextField { let l = label(text, size: 11, color: .secondaryLabelColor); l.maximumNumberOfLines = 0; l.lineBreakMode = .byWordWrapping; return l }
    private func toggle(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>) -> NSButton {
        let button = ActionButton(title, action: {}); button.setButtonType(.switch); button.state = settings.value[keyPath: key] ? .on : .off
        button.onClick = { [weak self, weak button] in guard let self, let button else { return }; self.perform { try self.settings.update { $0[keyPath: key] = button.state == .on } } }
        return button
    }
    private func field(_ value: String, placeholder: String = "", change: @escaping (String) throws -> Void) -> NSTextField {
        let text = NSTextField(string: value); text.placeholderString = placeholder; text.delegate = self; text.font = .systemFont(ofSize: 12)
        textChanges[ObjectIdentifier(text)] = change; text.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        return text
    }
    private func popup(_ options: [String], selection: Int, change: @escaping (NSPopUpButton) throws -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(); popup.addItems(withTitles: options); popup.selectItem(at: selection); popup.target = self; popup.action = #selector(popupChanged)
        changes[ObjectIdentifier(popup)] = change; return popup
    }
    @objc private func popupChanged(_ sender: NSPopUpButton) { perform { try changes[ObjectIdentifier(sender)]?(sender) } }
    func controlTextDidEndEditing(_ obj: Notification) { if let text = obj.object as? NSTextField { perform { try textChanges[ObjectIdentifier(text)]?(text.stringValue) } } }
    private func perform(_ action: () throws -> Void) { do { try action(); status.stringValue = "" } catch { status.stringValue = error.localizedDescription; rebuild() } }
    private func rebuild() {
        let selected = tabs.selectedTabViewItem?.identifier as? String
        tabs.tabViewItems.forEach(tabs.removeTabViewItem)
        textChanges.removeAll(); changes.removeAll()
        let login = ActionButton("Launch at login", action: {}); login.setButtonType(.switch); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = settings.isPersistent
        login.onClick = { [weak self, weak login] in guard let self, let login else { return }; self.perform { if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; if SMAppService.mainApp.status == .requiresApproval { self.status.stringValue = "Approve Clipboard in System Settings → General → Login Items." } } }
        let shortcut = ShortcutRecorder(keyCode: settings.value.shortcutKeyCode, modifiers: settings.value.shortcutModifiers)
        shortcut.onRecord = { [weak self] code, modifiers in guard let self else { return }; self.perform { try self.onShortcut?(code, modifiers); try self.settings.update { $0.shortcutKeyCode = code; $0.shortcutModifiers = modifiers } } }
        let theme = popup(["System", "Light", "Dark"], selection: ["System", "Light", "Dark"].firstIndex(of: settings.value.appearance) ?? 0) { [weak self] p in try self?.settings.update { $0.appearance = p.titleOfSelectedItem ?? "System" } }
        let autoPaste = ActionButton("Enable automatic paste", action: {}); autoPaste.setButtonType(.switch); autoPaste.state = settings.value.automaticPaste ? .on : .off
        autoPaste.isEnabled = settings.isPersistent
        autoPaste.onClick = { [weak self, weak autoPaste] in
            guard let self, let autoPaste else { return }
            if autoPaste.state == .on {
                let alert = NSAlert(); alert.messageText = "Allow automatic pasting?"; alert.informativeText = "Clipboard sends Command-V only after you choose Paste. macOS may require Accessibility access. Copy works without this permission."
                alert.addButton(withTitle: "Enable and request access"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { autoPaste.state = .off; return }
                _ = CGRequestPostEventAccess()
            }
            self.perform { try self.settings.update { $0.automaticPaste = autoPaste.state == .on } }
        }
        page("General", [login, row([label("Open Clipboard"), shortcut]), row([label("Appearance"), theme]), toggle("Open on active display", \.activeDisplay), autoPaste, note("No Input Monitoring, Screen Recording, or Full Disk Access is requested."), row([label("Poll interval (seconds)"), field(String(settings.value.pollingInterval)) { [weak self] value in guard let number = Double(value) else { throw CoreError.invalidData }; try self?.settings.update { $0.pollingInterval = number } }])])
        let days: [Int?] = [30, 7, 1, nil]
        let retention = popup(["30 days", "7 days", "1 day", "Forever", "Custom"], selection: days.firstIndex(where: { $0 == settings.value.retentionDays }) ?? 4) { [weak self] p in
            guard let self else { return }
            if p.indexOfSelectedItem < days.count { try settings.update { $0.retentionDays = days[p.indexOfSelectedItem] } }
            else { let alert = NSAlert(); alert.messageText = "Keep history for how many days?"; let input = NSTextField(string: String(settings.value.retentionDays ?? 30)); input.frame = NSRect(x: 0, y: 0, width: 150, height: 24); alert.accessoryView = input; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); if alert.runModal() == .alertFirstButtonReturn { guard let count = Int(input.stringValue), count > 0 else { throw CoreError.invalidData }; try settings.update { $0.retentionDays = count } } }
        }
        let maxCount = field(settings.value.maximumCount.map(String.init) ?? "", placeholder: "Unlimited") { [weak self] value in if value.isEmpty { try self?.settings.update { $0.maximumCount = nil } } else { guard let count = Int(value), count > 0 else { throw CoreError.invalidData }; try self?.settings.update { $0.maximumCount = count } } }
        let sepOptions = ["Blank line", "Newline", "Custom"]
        let separatorSelection = settings.value.mergeSeparator == "\n\n" ? 0 : settings.value.mergeSeparator == "\n" ? 1 : 2
        let merge = popup(sepOptions, selection: separatorSelection) { [weak self] p in
            guard let self else { return }
            if p.indexOfSelectedItem < 2 { try settings.update { $0.mergeSeparator = p.indexOfSelectedItem == 0 ? "\n\n" : "\n" } }
            else { let alert = NSAlert(); alert.messageText = "Separate copied entries with"; let input = NSTextField(string: settings.value.mergeSeparator); input.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = input; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); if alert.runModal() == .alertFirstButtonReturn { try settings.update { $0.mergeSeparator = input.stringValue } } }
        }
        page("History", [row([label("Keep unpinned history"), retention]), note("Pinned entries are never removed by automatic cleanup."), row([label("Maximum unpinned entries"), maxCount]), toggle("Run cleanup weekly instead of daily", \.weeklyCleanup), toggle("Show pinned entries first", \.pinnedFirst), row([label("Combine copied text using"), merge]), ActionButton("Clear unpinned history…", action: { [weak self] in self?.clearHistory(includePinned: false) }), ActionButton("Clear all history…", action: { [weak self] in self?.clearHistory(includePinned: true) })])
        excludedLabel = note(settings.value.excludedApps.isEmpty ? "No applications selected." : settings.value.excludedApps.joined(separator: "\n"))
        let location = store.rootURL.path
        page("Privacy", [ActionButton("Pause / Resume monitoring", action: { [weak self] in self?.onPause?() }), ActionButton("Retry clipboard access", action: { [weak self] in self?.onCaptureResume?() }), note("Confidential, transient, and known password-manager markers are skipped. This cannot detect every secret."), label("Pause while these applications are active"), excludedLabel, row([ActionButton("Add application…", action: { [weak self] in self?.addExcludedApplication() }), ActionButton("Remove applications…", action: { [weak self] in self?.removeExcludedApplications() })]), note("Source markers are informational. Missing or misleading markers and background writers prevent guaranteed exclusions. Copying while an excluded app is active is not captured on returning."), note("History is local and not encrypted by this app. Private files cannot protect against processes with access to your user account. Deletion cannot erase older exports, APFS snapshots, or SSD remnants."), note(location)])
        page("Backup", [label("Settings"), row([ActionButton("Export settings…", action: { [weak self] in self?.exportSettings() }), ActionButton("Import settings…", action: { [weak self] in self?.importSettings() })]), note("Settings exports never contain clipboard history or passwords. Importing settings does not grant system permissions."), separator(), label("Clipboard history"), ActionButton("Export history…", action: { [weak self] in self?.exportHistory() }), ActionButton("Import history…", action: { [weak self] in self?.importHistory() }), note("History includes managed images and file references, not the original referenced files. Optional password encryption protects exported history; the local history database remains unencrypted."), note("Keep your backup password safe. Clipboard cannot recover forgotten passwords.")])
        if let selected, let item = tabs.tabViewItems.first(where: { $0.identifier as? String == selected }) { tabs.selectTabViewItem(item) }
    }
    private func clearHistory(includePinned: Bool) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = includePinned ? "Clear all clipboard history?" : "Clear unpinned clipboard history?"
        alert.informativeText = "This permanently removes \(includePinned ? "all entries, including pinned entries" : "unpinned entries") and managed attachments, including pending deletions. There is no Undo. Unsaved edits to removed entries are discarded. Original files and exported backups are unaffected."
        alert.addButton(withTitle: "Clear history"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { [self] in try await store.clear(includePinned: includePinned); onHistoryCleared?(includePinned); status.stringValue = "History cleared." }
    }
    private func addExcludedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        perform { try settings.update { if !$0.excludedApps.contains(bundleID) { $0.excludedApps.append(bundleID) } }; rebuild() }
    }
    private func removeExcludedApplications() {
        guard !settings.value.excludedApps.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Remove which application?"; let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28)); picker.addItems(withTitles: settings.value.excludedApps); alert.accessoryView = picker; alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let selected = picker.titleOfSelectedItem { perform { try settings.update { $0.excludedApps.removeAll { $0 == selected } }; rebuild() } }
    }
    private func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Clipboard-settings.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { let data = try JSONEncoder().encode(settings.value); try replace(data, at: url); status.stringValue = "Settings exported." }
    }
    private func replace(_ data: Data, at destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".clipboard-\(UUID().uuidString)")
        do { try PrivateFiles.write(data, to: temporary); if FileManager.default.fileExists(atPath: destination.path) { try PrivateFiles.rejectLink(destination); _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) } else { try FileManager.default.moveItem(at: temporary, to: destination) } }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    private func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Replace Clipboard preferences?"; alert.informativeText = "History is unchanged. Automatic paste permission and first-run consent will not be imported."; alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { let data = try PrivateFiles.read(url, limit: 1024 * 1024); let imported = try AppSettings.decode(data); try onShortcut?(imported.shortcutKeyCode, imported.shortcutModifiers); try settings.importSettings(data); rebuild(); status.stringValue = "Settings imported." }
    }
    private func backupPassword(export: Bool) -> (accepted: Bool, password: String?) {
        let alert = NSAlert(); alert.messageText = export ? "Protect this history backup" : "Open history backup"
        alert.informativeText = export ? "Enter a password of at least 12 characters, or leave both fields empty for an unencrypted archive. The password is never saved." : "If this archive is encrypted, enter its password. Leave empty for an unencrypted backup."
        let first = NSSecureTextField(); first.placeholderString = "Password"
        let second = NSSecureTextField(); second.placeholderString = "Confirm password"
        let stack = NSStackView(views: export ? [first, second] : [first]); stack.orientation = .vertical; stack.spacing = 8; stack.frame = NSRect(x: 0, y: 0, width: 300, height: export ? 60 : 28)
        alert.accessoryView = stack; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return (false, nil) }
        if export && (!first.stringValue.isEmpty || !second.stringValue.isEmpty) && (first.stringValue != second.stringValue || first.stringValue.count < 12) { status.stringValue = "Passwords must match and contain at least 12 characters."; return (false, nil) }
        return (true, first.stringValue.isEmpty ? nil : first.stringValue)
    }
    private func exportHistory() {
        let secret = backupPassword(export: true); guard secret.accepted else { return }
        if secret.password == nil {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Export unencrypted history?"; alert.informativeText = "Anyone who can read this backup can read its clipboard contents. History may contain private information."; alert.addButton(withTitle: "Export unencrypted"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = secret.password == nil ? "Clipboard-history.cliparchive" : "Clipboard-history.clipencrypted"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { [self] in try await archives.export(to: url, password: secret.password); status.stringValue = "History exported." }
    }
    private func importHistory() {
        let panel = NSOpenPanel(); guard panel.runModal() == .OK, let url = panel.url else { return }
        let secret = backupPassword(export: false); guard secret.accepted else { return }
        run { [self] in
            let prepared = try await archives.prepareImport(from: url, password: secret.password)
            do {
                try Task.checkCancellation()
                let alert = NSAlert(); alert.messageText = "Import \(prepared.entryCount) entries?"
                let size = ByteCountFormatter.string(fromByteCount: prepared.expandedBytes, countStyle: .file)
                var message = "Validated archive: \(size) expanded. Matching identities are skipped; conflicting identities abort the import."
                if let oldest = prepared.oldestUnpinnedDate, let days = settings.value.retentionDays, oldest < Date().addingTimeInterval(-Double(days) * 86400) { message += " Some unpinned entries are older than your retention period and will be eligible for the next cleanup. Change retention before importing if you want to keep them." }
                alert.informativeText = message; alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { try await archives.discard(prepared); return }
                let count = try await store.commitImport(prepared); try await archives.discard(prepared); onHistoryChanged?(); status.stringValue = "Imported \(count) entries."
            } catch { try? await archives.discard(prepared); throw error }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard task == nil else { status.stringValue = "Wait for the current operation or cancel it first."; return }
        progress.startAnimation(nil); cancelButton.isHidden = false; status.stringValue = "Working…"
        task = Task { [weak self] in
            guard let self else { return }
            do { try await operation() } catch is CancellationError { status.stringValue = "Cancelled. Existing history is preserved." } catch { status.stringValue = error.localizedDescription }
            progress.stopAnimation(nil); cancelButton.isHidden = true; task = nil
        }
    }
}

@MainActor final class ShortcutRecorder: NSButton {
    var onRecord: ((UInt32, UInt32) -> Void)?
    private var recording = false
    init(keyCode: UInt32, modifiers: UInt32) {
        super.init(frame: .zero); bezelStyle = .rounded
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",49:"Space"]
        title = (modifiers & 4096 != 0 ? "⌃" : "") + (modifiers & 2048 != 0 ? "⌥" : "") + (modifiers & 512 != 0 ? "⇧" : "") + (modifiers & 256 != 0 ? "⌘" : "") + (names[keyCode] ?? "Key \(keyCode)")
        target = self; action = #selector(record); setAccessibilityLabel("Record global shortcut")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc private func record() { recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "Click to record"; return }
        let f = event.modifierFlags; var modifiers: UInt32 = 0
        if f.contains(.command) { modifiers |= 256 }; if f.contains(.shift) { modifiers |= 512 }; if f.contains(.option) { modifiers |= 2048 }; if f.contains(.control) { modifiers |= 4096 }
        guard modifiers & (256 | 2048 | 4096) != 0 else { NSSound.beep(); return }
        recording = false; onRecord?(UInt32(event.keyCode), modifiers); title = event.charactersIgnoringModifiers?.uppercased() ?? "Recorded"
    }
}
