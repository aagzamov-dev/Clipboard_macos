import AppKit
import ClipboardCore
import ServiceManagement
import UniformTypeIdentifiers
import CoreGraphics

@MainActor final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let permissionStatus: () -> PastePermissionStatus
    private var permissionTimer: Timer?
    private let pasteStatus: () -> String
    private let clipboardAccess: () -> String
    private let clipboardPermissionLabel = label("", size: 11, color: .secondaryLabelColor)
    private let pasteAttemptLabel = label("", size: 11, color: .secondaryLabelColor)
    private let pasteTestLabel = label("No paste test run yet.", size: 11, color: .secondaryLabelColor)
    private var pasteTestButton: ActionButton?
    var onPasteTest: (() -> Void)?
    private var restartButtons: [NSButton] = []
    var onRestart: (() -> Void)? { didSet { restartButtons.forEach { $0.isEnabled = onRestart != nil } } }
    private var pasteTestRunning = false
    private var permissionLabels: [NSTextField] = []
    private let settings: SettingsStore
    private let store: HistoryStore
    private let archives: ArchiveService
    private let tabs = NSTabView(frame: NSRect(x: 0, y: 0, width: 504, height: 530))
    private let status = label("", size: 11, color: .secondaryLabelColor)
    private let progress = NSProgressIndicator()
    private let cancelButton = ActionButton("Cancel operation", action: {})
    private var task: Task<Void, Never>?
    private var textChanges: [ObjectIdentifier: (String) throws -> Void] = [:]
    private var changes: [ObjectIdentifier: (NSPopUpButton) throws -> Void] = [:]
    private var excludedLabel = label("", size: 12, color: .secondaryLabelColor)
    var updateChecksEnabled: (() -> Bool)?
    var onUpdateChecksChanged: ((Bool) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var canCheckForUpdates: (() -> Bool)?
    var onPause: (() -> Void)?
    var onShortcut: ((UInt32, UInt32) throws -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onHistoryCleared: ((Bool) -> Void)?
    var onCaptureResume: (() -> Void)?
    init(settings: SettingsStore, store: HistoryStore, permissionCheck: (() -> Bool)? = nil, permissionStatus: (() -> PastePermissionStatus)? = nil, pasteStatus: @escaping () -> String = { "No paste attempted in this session." }) {
        self.pasteStatus = pasteStatus
        self.clipboardAccess = settings.isPersistent ? { PasteAccess.clipboardAccessDescription } : { "Fixture mode: real clipboard access is disabled." }
        self.permissionStatus = permissionStatus ?? permissionCheck.map { check in { let allowed = check(); return PastePermissionStatus(accessibilityTrusted: allowed, eventPostingAllowed: allowed) } } ?? (settings.isPersistent ? { PasteAccess.status } : { .init(accessibilityTrusted: false, eventPostingAllowed: false) })
        self.settings = settings; self.store = store; archives = ArchiveService(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clipboard Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(refreshPermissionStatus), name: NSApplication.didBecomeActiveNotification, object: nil)
        let root = NSStackView(); root.orientation = .vertical; root.distribution = .fill; root.alignment = .leading; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        window.contentView = root; root.addArrangedSubview(tabs)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        cancelButton.onClick = { [weak self] in self?.task?.cancel() }; cancelButton.isHidden = true
        status.maximumNumberOfLines = 3; status.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(row([progress, status, cancelButton]))
        for view in root.arrangedSubviews {
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18)])
        }
        tabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.layoutSubtreeIfNeeded()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    func open() { NSApp.activate(ignoringOtherApps: true); showWindow(nil); window?.center(); window?.makeKeyAndOrderFront(nil); rebuild() }
    func openPasteSettings() { open(); tabs.selectTabViewItem(withIdentifier: "Permissions"); refreshPermissionStatus() }
    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissionStatus()
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(refreshPermissionStatus), userInfo: nil, repeats: true)
        timer.tolerance = 0.25; RunLoop.main.add(timer, forMode: .common); permissionTimer = timer
    }
    func windowDidResignKey(_ notification: Notification) { permissionTimer?.invalidate(); permissionTimer = nil }
    func windowWillClose(_ notification: Notification) { permissionTimer?.invalidate(); permissionTimer = nil }
    @objc func refreshPermissionStatus() {
        let access = permissionStatus()
        for label in permissionLabels {
            label.stringValue = access.summary + "\n\n" + access.details
            label.textColor = access.eventPostingAllowed && access.accessibilityTrusted ? .systemGreen : .secondaryLabelColor
        }
        clipboardPermissionLabel.stringValue = clipboardAccess()
        pasteAttemptLabel.stringValue = pasteStatus()
    }
    func showPasteTestResult(_ text: String, running: Bool = false) {
        pasteTestRunning = running
        pasteTestLabel.stringValue = text
        pasteTestButton?.isEnabled = !running && settings.isPersistent
    }
    private func pasteAccessControls() -> [NSView] {
        let summary = note(""); summary.setAccessibilityLabel("Automatic paste permission status"); permissionLabels.append(summary)
        let open = ActionButton("Open Accessibility Settings…", action: { [weak self] in
            guard let self, self.settings.isPersistent else { return }
            PasteAccess.request(); PasteAccess.openSettings(); self.refreshPermissionStatus()
        })
        open.isEnabled = settings.isPersistent
        let recheck = ActionButton("Recheck access", action: { [weak self] in self?.refreshPermissionStatus() })
        let reveal = ActionButton("Show this app in Finder", action: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) })
        reveal.isEnabled = settings.isPersistent
        let restart = ActionButton("Restart Clipboard", action: { [weak self] in self?.restartAfterPermissionChange() })
        restart.isEnabled = onRestart != nil
        restartButtons.append(restart)
        restart.toolTip = "Reopen this app and recheck permissions. Unsaved edits are protected."
        return [summary, row([open, recheck]), row([restart, reveal]), note("After allowing Accessibility, click Recheck access. If paste is still blocked, click Restart Clipboard. If it remains blocked after restarting, remove the old Accessibility entry and add this exact app again. Ad-hoc updates can require a new grant; restarting cannot grant access for you.")]
    }
    private func restartAfterPermissionChange() {
        guard task == nil, !pasteTestRunning else {
            status.stringValue = "Wait for the current operation to finish or cancel it before restarting."
            return
        }
        window?.makeFirstResponder(nil)
        onRestart?()
    }
    private func page(_ name: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: name); item.label = name
        let stack = SettingsDocumentStack(frame: NSRect(x: 0, y: 0, width: 480, height: 500)); stack.distribution = .fill; stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15; stack.edgeInsets = NSEdgeInsets(top: 24, left: 14, bottom: 16, right: 14)
        views.forEach(stack.addArrangedSubview)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical); stack.addArrangedSubview(spacer)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 500)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = stack; stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        for view in stack.arrangedSubviews {
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14), view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14)])
        }
        item.view = scroll; tabs.addTabViewItem(item)
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
        textChanges.removeAll(); changes.removeAll(); permissionLabels.removeAll(); restartButtons.removeAll()
        let login = ActionButton("Launch at login", action: {}); login.setButtonType(.switch); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = settings.isPersistent
        login.onClick = { [weak self, weak login] in guard let self, let login else { return }; self.perform { if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; if SMAppService.mainApp.status == .requiresApproval { self.status.stringValue = "Approve Clipboard in System Settings → General → Login Items." } } }
        let shortcut = ShortcutRecorder(keyCode: settings.value.shortcutKeyCode, modifiers: settings.value.shortcutModifiers)
        shortcut.onRecord = { [weak self] code, modifiers in guard let self else { return }; self.perform { try self.onShortcut?(code, modifiers); try self.settings.update { $0.shortcutKeyCode = code; $0.shortcutModifiers = modifiers } } }
        let theme = popup(["System", "Light", "Dark"], selection: ["System", "Light", "Dark"].firstIndex(of: settings.value.appearance) ?? 0) { [weak self] p in try self?.settings.update { $0.appearance = p.titleOfSelectedItem ?? "System" } }
        let updateChecks = ActionButton("Automatically check for updates", action: {})
        updateChecks.setButtonType(.switch); updateChecks.state = updateChecksEnabled?() == true ? .on : .off
        updateChecks.isEnabled = onUpdateChecksChanged != nil
        updateChecks.onClick = { [weak self, weak updateChecks] in self?.onUpdateChecksChanged?(updateChecks?.state == .on) }
        let checkUpdate = ActionButton("Check for Updates…", action: { [weak self] in self?.onCheckForUpdates?() })
        checkUpdate.isEnabled = canCheckForUpdates?() == true
        page("General", [login, row([label("Open Clipboard"), shortcut]), row([label("Appearance"), theme]), toggle("Open on active display", \.activeDisplay)] + pasteAccessControls() + [note("No Input Monitoring, Screen Recording, or Full Disk Access is requested."), row([label("Poll interval (seconds)"), field(String(settings.value.pollingInterval)) { [weak self] value in guard let number = Double(value) else { throw CoreError.invalidData }; try self?.settings.update { $0.pollingInterval = number } }])])
        let test = ActionButton("Test automatic paste…", action: { [weak self] in self?.onPasteTest?() })
        test.isEnabled = settings.isPersistent && onPasteTest != nil
        pasteTestButton = test
        for label in [clipboardPermissionLabel, pasteAttemptLabel, pasteTestLabel] { label.maximumNumberOfLines = 0; label.lineBreakMode = .byWordWrapping }
        let privacySettings = ActionButton("Open Privacy & Security…", action: { guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") else { return }; NSWorkspace.shared.open(url) })
        privacySettings.isEnabled = settings.isPersistent
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Local"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Test"
        page("Permissions", [label("Clipboard history", size: 13), clipboardPermissionLabel, privacySettings, separator(), label("Automatic paste · Accessibility", size: 13), note("Choosing a history item automatically pastes it into your previous app. macOS Accessibility access is required.")] + pasteAccessControls() + [test, pasteTestLabel, note("The test uses a separate app and a private clipboard. No text is sent to your other apps."), separator(), label("Last paste attempt", size: 13), pasteAttemptLabel, label("Not required", size: 13), note("Input Monitoring — Not used\nScreen Recording — Not used\nFull Disk Access — Not used"), note("Copy, search, and editing work without Accessibility."), note("Running version: \(version) (\(build))\nApp: \(Bundle.main.bundleURL.path)"), note(settings.isPersistent && PasteAccess.isAdHocSigned ? "Signing: ad-hoc. A new version can invalidate an old macOS permission grant. Developer ID signing is needed for a stable publisher identity across updates." : "Signing: publisher identity available.")])
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
        page("Privacy", [ActionButton("Set up automatic paste…", action: { [weak self] in self?.tabs.selectTabViewItem(withIdentifier: "General") })] + pasteAccessControls() + [ActionButton("Pause / Resume monitoring", action: { [weak self] in self?.onPause?() }), ActionButton("Retry clipboard access", action: { [weak self] in self?.onCaptureResume?() }), note("Confidential, transient, and known password-manager markers are skipped. This cannot detect every secret."), label("Pause while these applications are active"), excludedLabel, row([ActionButton("Add application…", action: { [weak self] in self?.addExcludedApplication() }), ActionButton("Remove applications…", action: { [weak self] in self?.removeExcludedApplications() })]), note("Source markers are informational. Missing or misleading markers and background writers prevent guaranteed exclusions. Copying while an excluded app is active is not captured on returning."), note("History is local and not encrypted by this app. Private files cannot protect against processes with access to your user account. Deletion cannot erase older exports, APFS snapshots, or SSD remnants."), note(location)])
        page("Backup", [label("Settings"), row([ActionButton("Export settings…", action: { [weak self] in self?.exportSettings() }), ActionButton("Import settings…", action: { [weak self] in self?.importSettings() })]), note("Settings exports never contain clipboard history or passwords. Importing settings does not grant system permissions."), separator(), label("Clipboard history"), ActionButton("Export history…", action: { [weak self] in self?.exportHistory() }), ActionButton("Import history…", action: { [weak self] in self?.importHistory() }), note("History includes managed images and file references, not the original referenced files. Optional password encryption protects exported history; the local history database remains unencrypted."), note("Keep your backup password safe. Clipboard cannot recover forgotten passwords.")])
        page("Updates", [label("Clipboard \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Local")", size: 14), updateChecks, checkUpdate, note("Checks GitHub Releases about once a day. Updates are verified before installation. You choose when to install and restart."), note("Clipboard contents, searches, and file references are never sent. System profiling is disabled. A cancelled draft prompt keeps the update pending; choose Check for Updates again when ready.")])
        refreshPermissionStatus()
        if let selected, let item = tabs.tabViewItems.first(where: { $0.identifier as? String == selected }) { tabs.selectTabViewItem(item) } else { tabs.selectTabViewItem(withIdentifier: "General") }
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

@MainActor private final class SettingsDocumentStack: NSStackView { override var isFlipped: Bool { true } }
